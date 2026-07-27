#if os(macOS)
    import AppKit
    import Foundation
    import SwiftUI
    import VelaCore
    import VelaCrypto
    import VelaDomain
    import VelaStorage
    import VelaTransport

    @MainActor
    final class AppModel: ObservableObject {
        @Published private(set) var snapshot = ClientSnapshot(
            state: .openingDatabase,
            connection: .disconnected,
            linkedAccount: nil,
            unreadCount: 0
        )
        @Published private(set) var conversations: [Conversation] = []
        @Published private(set) var messages: [ChatMessage] = []
        @Published private(set) var isLoadingMessages = false
        @Published private(set) var canLoadOlderMessages = false
        @Published private(set) var isLoadingOlderMessages = false
        @Published var selectedConversationID: ConversationID?
        @Published var searchText = "" {
            didSet { scheduleConversationSearch() }
        }
        @Published var isShowingArchivedConversations = false
        @Published var composerText = ""
        /// Formatting runs over `composerText`, in UTF-16 offsets.
        @Published var composerStyles: [TextStyleRange] = []
        @Published var replyingToMessageID: MessageID?
        @Published var editingMessageID: MessageID?
        @Published var deviceName = Host.current().localizedName ?? "Mac"
        @Published private(set) var provisioningSession: ProvisioningSession?
        @Published private(set) var storageStatistics: StoreStatistics?
        @Published private(set) var diagnosticEvents: [DiagnosticEvent] = []
        @Published private(set) var startupFailure: String? = nil
        @Published var alertTitle = "Vela"
        @Published var alertMessage: String?
        @Published var isShowingNewConversation = false
        @Published var isShowingDiagnostics = false
        @Published var isShowingResetConfirmation = false
        @Published var isAppLocked = false
        @Published private(set) var isRetryingConnection = false
        @Published private(set) var isRetryingStartup = false
        @Published private(set) var backendStatus: BackendStatus = .checking
        @Published private(set) var contacts: [Contact] = []
        @Published private(set) var isSyncingContacts = false
        /// Shown in Settings so a silent app is distinguishable from a broken one.
        @Published private(set) var notificationAuthorization: NotificationAuthorization = .pending
        /// Who is currently typing, per conversation. Ephemeral and never stored.
        @Published private(set) var typingParticipants: [ConversationID: Set<RecipientID>] = [:]

        private struct TypingParticipantKey: Hashable {
            let conversationID: ConversationID
            let senderID: RecipientID
        }

        private var typingExpiry: [TypingParticipantKey: Task<Void, Never>] = [:]

        /// Signal's typing indicator lasts about 15 seconds, and a "stopped"
        /// message can be lost, so each one is expired on its own timer.
        private func setTyping(_ isTyping: Bool, conversationID: ConversationID, senderID: RecipientID) {
            let key = TypingParticipantKey(conversationID: conversationID, senderID: senderID)
            typingExpiry[key]?.cancel()
            typingExpiry[key] = nil

            guard isTyping else {
                typingParticipants[conversationID]?.remove(senderID)
                if typingParticipants[conversationID]?.isEmpty == true {
                    typingParticipants[conversationID] = nil
                }
                return
            }

            typingParticipants[conversationID, default: []].insert(senderID)
            typingExpiry[key] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.setTyping(false, conversationID: conversationID, senderID: senderID)
                }
            }
        }

        /// Files staged for the next send, shown above the composer.
        @Published private(set) var pendingAttachments: [AttachmentReference] = []
        @Published private(set) var attachmentStagingCounts: [ConversationID: Int] = [:]

        /// Signal's own ceiling. Rejecting here gives a clear message instead of
        /// a send that fails somewhere in the backend.
        private nonisolated static let attachmentByteLimit: Int64 = 100 * 1024 * 1024

        func attachFiles(_ urls: [URL]) {
            guard !urls.isEmpty, let targetConversationID = selectedConversationID else { return }
            let draftGeneration = composerDraftGeneration
            attachmentStagingCounts[targetConversationID, default: 0] += urls.count
            Task {
                defer {
                    let remaining = attachmentStagingCounts[targetConversationID, default: 0] - urls.count
                    attachmentStagingCounts[targetConversationID] = remaining > 0 ? remaining : nil
                }
                for url in urls {
                    do {
                        let attachment = try await Task.detached(priority: .userInitiated) {
                            try Self.prepareAttachment(at: url)
                        }.value
                        guard draftGeneration == composerDraftGeneration else {
                            removeManagedAttachmentFile(attachment)
                            return
                        }
                        appendAttachment(attachment, to: targetConversationID)
                    } catch AttachmentStagingError.tooLarge {
                        alertTitle = "Attachment Too Large"
                        alertMessage = "\(url.lastPathComponent) is larger than the 100 MB attachment limit."
                    } catch {
                        alertTitle = "Can’t Attach File"
                        alertMessage = "\(url.lastPathComponent) could not be read and copied into Vela."
                    }
                }
            }
        }

        func isStagingAttachments(in conversationID: ConversationID?) -> Bool {
            guard let conversationID else { return false }
            return attachmentStagingCounts[conversationID, default: 0] > 0
        }

        private func appendAttachment(_ attachment: AttachmentReference, to conversationID: ConversationID) {
            if selectedConversationID == conversationID {
                pendingAttachments.append(attachment)
                return
            }

            var draft =
                composerDrafts[conversationID]
                ?? ComposerDraftState(
                    text: "",
                    styles: [],
                    attachments: [],
                    replyingToMessageID: nil,
                    editingMessageID: nil
                )
            draft.attachments.append(attachment)
            composerDrafts[conversationID] = draft
        }

        private enum AttachmentStagingError: Error, Sendable {
            case notReadable
            case tooLarge
        }

        private nonisolated static func prepareAttachment(at url: URL) throws -> AttachmentReference {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }

            let values = try url.resourceValues(
                forKeys: [.fileSizeKey, .contentTypeKey, .isRegularFileKey, .isReadableKey]
            )
            guard values.isRegularFile == true, values.isReadable != false else {
                throw AttachmentStagingError.notReadable
            }

            let size = Int64(values.fileSize ?? 0)
            guard size <= attachmentByteLimit else {
                throw AttachmentStagingError.tooLarge
            }

            let id = AttachmentID.random()
            let stagedURL = try stageAttachment(at: url, id: id)
            let stagedSize = Int64(
                try stagedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            )
            guard stagedSize <= attachmentByteLimit else {
                try? FileManager.default.removeItem(at: stagedURL.deletingLastPathComponent())
                throw AttachmentStagingError.tooLarge
            }

            return AttachmentReference(
                id: id,
                fileName: url.lastPathComponent,
                mimeType: values.contentType?.preferredMIMEType ?? "application/octet-stream",
                byteCount: stagedSize,
                state: .available(localRelativePath: stagedURL.path)
            )
        }

        private nonisolated static func stageAttachment(at sourceURL: URL, id: AttachmentID) throws -> URL {
            let fileManager = FileManager.default
            let support = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory =
                support
                .appendingPathComponent("Vela/attachments/outgoing", isDirectory: true)
                .appendingPathComponent(id.rawValue, isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: false)
            do {
                try fileManager.copyItem(at: sourceURL, to: destination)
                return destination
            } catch {
                try? fileManager.removeItem(at: directory)
                throw error
            }
        }

        /// Applies a formatting style to the composer selection.
        func applyComposerStyle(_ style: TextStyleRange.Style, to selection: NSRange) {
            guard selection.length > 0 else { return }
            let limit = (composerText as NSString).length
            let addition = TextStyleRange(start: selection.location, length: selection.length, style: style)
            composerStyles = (composerStyles + [addition]).normalized(forUTF16Length: limit)
        }

        func removeAttachment(_ id: AttachmentID) {
            guard let attachment = pendingAttachments.first(where: { $0.id == id }) else { return }
            pendingAttachments.removeAll { $0.id == id }
            removeManagedAttachmentFile(attachment)
        }

        private func removeManagedAttachmentFile(_ attachment: AttachmentReference) {
            guard case .available(let path) = attachment.state else { return }
            let fileURL = URL(fileURLWithPath: path).standardizedFileURL
            guard
                let support = try? FileManager.default.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: false
                )
            else { return }
            let managedRoot =
                support
                .appendingPathComponent("Vela/attachments/outgoing", isDirectory: true)
                .standardizedFileURL
            guard fileURL.path.hasPrefix(managedRoot.path + "/") else { return }
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }

        /// Tells senders their messages were read, when the user allows it.
        private func sendReadReceipts(for messages: [ChatMessage]) async {
            guard sendsReadReceipts, let transport = container?.serviceTransport else { return }

            // Group by sender: a receipt is addressed to whoever sent the
            // messages, which in a group is several different people.
            let unreadBySender = Dictionary(
                grouping: messages.filter { $0.direction == .incoming },
                by: \.senderID
            )
            for (senderID, group) in unreadBySender {
                await transport.sendReadReceipt(to: senderID, messageIDs: group.map(\.id))
            }
        }

        /// Both leak activity to the other side, so both are user-controlled.
        /// Default on, matching Signal.
        @AppStorage("vela.sendReadReceipts") var sendsReadReceipts = true
        @AppStorage("vela.sendTypingIndicators") var sendsTypingIndicators = true

        private var lastTypingSentAt: [ConversationID: Date] = [:]

        /// Called as the composer changes. Debounced to roughly one message per
        /// ten seconds, since Signal's indicator lasts about fifteen.
        func composerActivity() {
            guard
                sendsTypingIndicators,
                let transport = container?.serviceTransport,
                let seed = selectedConversationSeed
            else { return }

            let now = Date()
            if let last = lastTypingSentAt[seed.id], now.timeIntervalSince(last) < 10 { return }
            lastTypingSentAt[seed.id] = now
            Task { await transport.sendTyping(to: seed, isTyping: true) }
        }

        /// Sent after a message goes out, so the indicator clears immediately
        /// rather than lingering for its full timeout.
        private func stopTyping(in seed: ConversationSeed? = nil) {
            guard
                sendsTypingIndicators,
                let transport = container?.serviceTransport,
                let seed = seed ?? selectedConversationSeed
            else { return }
            lastTypingSentAt[seed.id] = nil
            Task { await transport.sendTyping(to: seed, isTyping: false) }
        }

        /// Names to show in the "… is typing" row for the open conversation.
        func typingDescription(for conversationID: ConversationID) -> String? {
            guard let participants = typingParticipants[conversationID], !participants.isEmpty else {
                return nil
            }
            let names = participants.map { displayName(for: $0) }.sorted()
            return switch names.count {
            case 1: "\(names[0]) is typing…"
            case 2: "\(names[0]) and \(names[1]) are typing…"
            default: "\(names.count) people are typing…"
            }
        }

        /// Contacts keyed by recipient for O(1) display-name lookup from views.
        private(set) var contactsByRecipient: [RecipientID: Contact] = [:]
        /// Maps every identifier a person is known by to one canonical identity.
        private(set) var recipientDirectory = RecipientDirectory()

        /// Name to show for a conversation, preferring a synced contact name over
        /// the raw identifier the conversation was created with.
        func displayName(for conversation: Conversation) -> String {
            switch conversation.kind {
            case .direct(let recipientID):
                if let contact = contact(for: recipientID), contact.hasResolvedName {
                    return contact.displayName
                }
                return conversation.title
            case .group, .noteToSelf:
                return conversation.title
            }
        }

        func displayName(for recipientID: RecipientID) -> String {
            contact(for: recipientID)?.displayName ?? recipientID.rawValue
        }

        func contact(for recipientID: RecipientID) -> Contact? {
            contactsByRecipient[recipientID]
                ?? contactsByRecipient[recipientDirectory.canonical(for: recipientID)]
        }

        /// Resolves a conversation's participants to their canonical identities,
        /// so a thread created from a phone number and one created from an ACI
        /// are the same thread.
        private func canonicalized(_ kind: ConversationKind) -> ConversationKind {
            switch kind {
            case .direct(let recipientID):
                .direct(recipientID: recipientDirectory.canonical(for: recipientID))
            case .group(let groupID, let memberIDs):
                .group(
                    groupID: groupID,
                    memberIDs: memberIDs.map { recipientDirectory.canonical(for: $0) }
                )
            case .noteToSelf:
                .noteToSelf
            }
        }

        enum BackendStatus: Equatable {
            case checking
            case notEmbedded
            case ready(version: String)
            case failed(reason: String)

            var summary: String {
                switch self {
                case .checking: "Checking…"
                case .notEmbedded: "Not embedded in this build"
                case .ready(let version): version
                case .failed(let reason): reason
                }
            }
        }

        let launchAtLogin = LaunchAtLoginManager()
        let localAppLock = LocalAppLock()

        private(set) var container: AppContainer?
        private var eventTask: Task<Void, Never>?
        private var startupTask: Task<Void, Never>?
        private var contactSyncTask: Task<Void, Never>?
        private var conversationSearchTask: Task<Void, Never>?
        private var conversationLoadTask: Task<Void, Never>?
        private var olderMessagesTask: Task<Void, Never>?
        private var messageSearchConversationIDs: Set<ConversationID> = []
        private var expiryTask: Task<Void, Never>?
        private var foregroundObserver: (any NSObjectProtocol)?

        private static let expirySweepInterval: TimeInterval = 30
        private static let messagePageSize = 200
        private static let messageSearchResultLimit = 10_000

        private struct ComposerDraftState {
            var text: String
            var styles: [TextStyleRange]
            var attachments: [AttachmentReference]
            var replyingToMessageID: MessageID?
            var editingMessageID: MessageID?

            var isEmpty: Bool {
                text.isEmpty
                    && attachments.isEmpty
                    && replyingToMessageID == nil
                    && editingMessageID == nil
            }
        }

        private var composerDrafts: [ConversationID: ComposerDraftState] = [:]
        private var composerDraftGeneration = 0

        /// Deletes messages whose timer has run out.
        ///
        /// The client publishes `.conversationsChanged`, which refreshes the
        /// sidebar but not an open thread, so the visible timeline is reloaded
        /// here too — otherwise an expired message stays on screen until you
        /// switch conversations.
        private func sweepExpiredMessages() async {
            guard let container, snapshot.linkedAccount != nil else { return }
            let removed = (try? await container.client.removeExpiredMessages()) ?? 0
            guard removed > 0, let selectedConversationID else { return }
            try? await reloadVisibleMessages(in: selectedConversationID)
        }
        private var hasStarted = false
        private var draftConversationSeeds: [ConversationID: ConversationSeed] = [:]
        private var sleepWakeMonitor: SleepWakeMonitor?

        init() {
            do {
                container = try AppContainer.makeDefault()
                VelaAppDelegate.container = container
            } catch {
                container = nil
                startupFailure = Self.userFacingError(error)
                alertMessage = startupFailure
                snapshot.state = .recoveryRequired(.databaseCorrupt)
            }

            sleepWakeMonitor = SleepWakeMonitor(
                onSleep: { [weak self] in
                    guard let self else { return }
                    if self.snapshot.linkedAccount != nil, self.localAppLock.isAvailable {
                        self.isAppLocked = true
                    }
                },
                onWake: { [weak self] in
                    guard let self else { return }
                    Task { await self.container?.client.flushOutbox() }
                }
            )
        }

        var isDevelopmentMode: Bool {
            container?.isDevelopmentMode ?? false
        }

        var canRetryConnection: Bool {
            snapshot.linkedAccount != nil
                && container?.daemon != nil
                && container?.serviceTransport != nil
        }

        var filteredConversations: [Conversation] {
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let visible = conversations.filter { $0.isArchived == isShowingArchivedConversations }
            guard !trimmed.isEmpty else { return visible }

            // Match every word, but allow each word to occur in a different
            // field. This handles searches such as "alex budget" while still
            // matching synced names, usernames, phone numbers and group members.
            let terms = trimmed.split(whereSeparator: \Character.isWhitespace).map(String.init)
            return visible.filter { conversation in
                let searchable = searchableText(for: conversation)
                return messageSearchConversationIDs.contains(conversation.id)
                    || terms.allSatisfy { searchable.localizedCaseInsensitiveContains($0) }
            }
        }

        var archivedConversationCount: Int {
            conversations.count(where: \.isArchived)
        }

        private func searchableText(for conversation: Conversation) -> String {
            var values = [
                conversation.title,
                displayName(for: conversation),
                conversation.subtitle,
                conversation.lastMessage?.text,
            ].compactMap { $0 }

            let participantIDs: [RecipientID]
            switch conversation.kind {
            case .direct(let recipientID):
                participantIDs = [recipientID]
            case .group(_, let memberIDs):
                participantIDs = memberIDs
            case .noteToSelf:
                participantIDs = []
            }

            for recipientID in participantIDs {
                values.append(recipientID.rawValue)
                guard let contact = contact(for: recipientID) else { continue }
                values.append(
                    contentsOf: [
                        contact.displayName,
                        contact.username,
                        contact.phoneNumber,
                        contact.aci,
                    ].compactMap { $0 })
            }
            return values.joined(separator: "\n")
        }

        /// Adds bounded full-history message matches after short debounce. Each
        /// word may occur in different message, matching metadata search rules.
        /// Spoiler-bearing messages never influence sidebar results.
        private func scheduleConversationSearch() {
            conversationSearchTask?.cancel()
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty, let container else {
                messageSearchConversationIDs = []
                return
            }
            messageSearchConversationIDs = []

            let terms = query.split(whereSeparator: \Character.isWhitespace).map(String.init)
            conversationSearchTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }

                do {
                    var intersection: Set<ConversationID>?
                    for term in terms {
                        let hits = try await container.client.search(
                            term,
                            limit: Self.messageSearchResultLimit
                        )
                        guard !Task.isCancelled else { return }
                        let conversations = Set(
                            hits.lazy
                                .filter { !$0.content.containsSpoiler }
                                .map(\.conversationID)
                        )
                        intersection = intersection.map { $0.intersection(conversations) } ?? conversations
                        if intersection?.isEmpty == true { break }
                    }

                    guard let self, self.searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else {
                        return
                    }
                    self.messageSearchConversationIDs = intersection ?? []
                    // Set is intentionally not @Published; nudging searchText's
                    // publisher makes filteredConversations reevaluate once.
                    self.objectWillChange.send()
                } catch {
                    // Metadata search remains useful if message index fails.
                }
            }
        }

        var selectedConversation: Conversation? {
            guard let selectedConversationID else { return nil }
            if let stored = conversations.first(where: { $0.id == selectedConversationID }) {
                return stored
            }
            guard let seed = draftConversationSeeds[selectedConversationID] else { return nil }
            return .from(seed: seed, at: Date())
        }

        var selectedConversationSeed: ConversationSeed? {
            guard let selectedConversationID else { return nil }
            if let draft = draftConversationSeeds[selectedConversationID] {
                return draft
            }
            guard let conversation = conversations.first(where: { $0.id == selectedConversationID }) else {
                return nil
            }
            return ConversationSeed(id: conversation.id, kind: conversation.kind, title: conversation.title)
        }

        var replyingToMessage: ChatMessage? {
            guard let replyingToMessageID else { return nil }
            return messages.first { $0.id == replyingToMessageID }
        }

        var editingMessage: ChatMessage? {
            guard let editingMessageID else { return nil }
            return messages.first { $0.id == editingMessageID }
        }

        private var currentComposerDraft: ComposerDraftState {
            ComposerDraftState(
                text: composerText,
                styles: composerStyles,
                attachments: pendingAttachments,
                replyingToMessageID: replyingToMessageID,
                editingMessageID: editingMessageID
            )
        }

        private func saveComposerDraft(for conversationID: ConversationID) {
            let draft = currentComposerDraft
            composerDrafts[conversationID] = draft.isEmpty ? nil : draft
        }

        private func restoreComposerDraft(for conversationID: ConversationID?) {
            let draft = conversationID.flatMap { composerDrafts[$0] }
            composerText = draft?.text ?? ""
            composerStyles = draft?.styles ?? []
            pendingAttachments = draft?.attachments ?? []
            replyingToMessageID = draft?.replyingToMessageID
            editingMessageID = draft?.editingMessageID
        }

        func start() {
            guard !hasStarted, let container else { return }
            hasStarted = true

            eventTask = Task { [weak self] in
                guard let self else { return }
                let stream = await container.client.events()
                for await event in stream {
                    guard !Task.isCancelled else { break }
                    await self.handle(event)
                }
            }

            container.notificationSink.onAuthorizationChange = { [weak self] state in
                Task { @MainActor in self?.notificationAuthorization = state }
            }

            // Its own task: authorisation now waits for the app to finish
            // launching and retries, so it must not hold up the backend.
            Task { await container.notificationSink.requestAuthorization() }

            startupTask = Task { [weak self] in
                guard let self else { return }
                // The backend must be up before bootstrap, because linking and
                // every send run over its socket.
                await self.startBackendIfNeeded()
                guard !Task.isCancelled else { return }
                await container.client.bootstrap()
                guard !Task.isCancelled else { return }
                self.snapshot = await container.client.snapshot()
                await self.adoptLocalIdentity()
                await self.reloadAll()
                await self.reloadContacts()
                // Refresh in the background: the cached list renders immediately
                // and the primary device may have changed it since last launch.
                await self.syncContacts()
            }

            Task { await refreshBackendStatus() }

            // Disappearing messages have to actually disappear. Nothing swept
            // them before, so a message that had already vanished from the phone
            // stayed in Vela's database indefinitely.
            expiryTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.sweepExpiredMessages()
                    // Signal's shortest timer is 30 seconds, so this is the
                    // coarsest interval that cannot leave one visible for longer
                    // than its own lifetime.
                    try? await Task.sleep(for: .seconds(Self.expirySweepInterval))
                }
            }

            // The phone is the authority on names, groups and avatars, and it
            // changes while Vela is open. Both paths are rate-limited by
            // `syncContactsIfStale`.
            contactSyncTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Self.contactSyncInterval))
                    guard !Task.isCancelled else { break }
                    await self?.syncContactsIfStale()
                }
            }

            foregroundObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.syncContactsIfStale() }
            }

            // Clicking a banner should land on the conversation it came from.
            container.notificationSink.onOpenConversation = { [weak self] conversationID in
                Task { @MainActor in
                    NSApp.activate(ignoringOtherApps: true)
                    self?.selectConversation(conversationID)
                }
            }
        }

        private func startBackendIfNeeded() async {
            guard let daemon = container?.daemon else { return }
            do {
                try await daemon.start()
            } catch {
                alertMessage = Self.userFacingError(error)
            }
        }

        /// The recipient router needs the local account for Note to Self, and
        /// that identity only exists once linking has completed.
        private func adoptLocalIdentity() async {
            guard
                let router = container?.recipientRouter,
                let account = snapshot.linkedAccount
            else { return }
            await router.adopt(localRecipientID: account.localRecipientID)
        }

        private func reloadContacts() async {
            guard let container else { return }
            contacts = (try? await container.client.contacts()) ?? []
            contactsByRecipient = Dictionary(
                contacts.map { ($0.recipientID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            recipientDirectory = RecipientDirectory(contacts: contacts)
            if let account = snapshot.linkedAccount {
                recipientDirectory.associate(
                    aci: account.serviceIdentifier.aciString,
                    number: account.localRecipientID.rawValue
                )
            }
            // The inbound path resolves identities with the same directory, so a
            // reply joins the thread it belongs to.
            await container.serviceTransport?.updateDirectory(recipientDirectory)
        }

        /// Pulls the contact list from the primary device. Safe to call
        /// repeatedly; it replaces the cache rather than merging.
        func syncContacts() async {
            guard
                let container,
                let sync = container.contactSync,
                snapshot.linkedAccount != nil,
                !isSyncingContacts
            else { return }

            isSyncingContacts = true
            defer { isSyncingContacts = false }
            lastContactSyncAt = Date()

            do {
                // Ask the phone to resend first, or this only re-reads the copy
                // signal-cli already had and a rename made on the phone never
                // appears. The reply arrives asynchronously, so the fetch below
                // may still see the previous list and pick the change up on the
                // next pass.
                await sync.requestSyncFromPrimary()

                // Groups first: contact resolution feeds their member lists.
                await syncGroups()

                var fetched = try await sync.fetchContacts()
                // Avatars are a round trip each, so only fetch for contacts we
                // will actually draw, and never let a failure block the sync.
                for index in fetched.indices.prefix(Self.avatarFetchLimit) {
                    if let path = await sync.fetchAvatar(for: fetched[index].recipientID) {
                        fetched[index].avatarRelativePath = path
                    }
                }
                try await container.client.replaceContacts(fetched)
            } catch {
                present(error)
            }
        }

        /// Bounded so a large address book cannot stall startup on avatar fetches.
        private static let avatarFetchLimit = 200

        /// When the contact and group sync last ran, so a refresh triggered by
        /// the app becoming active does not fire on every window switch.
        private var lastContactSyncAt: Date?

        /// Deliberately generous. `sendSyncRequest` makes the phone resend its
        /// whole contact, group and configuration set, so this should be a slow
        /// background correction, not a poll.
        private static let contactSyncInterval: TimeInterval = 30 * 60

        /// Re-syncs if it has been long enough. Called on a timer and when the
        /// app returns to the foreground, since a rename or a new group made on
        /// the phone would otherwise wait for a restart.
        func syncContactsIfStale() async {
            if let lastContactSyncAt,
                Date().timeIntervalSince(lastContactSyncAt) < Self.contactSyncInterval
            {
                return
            }
            await syncContacts()
        }

        /// Brings group threads into the sidebar even before a message arrives.
        /// A failure here must not abort the contact sync that follows.
        private func syncGroups() async {
            guard
                let container,
                let groupSync = container.groupSync,
                let account = snapshot.linkedAccount
            else { return }

            do {
                let seeds = try await groupSync.fetchGroups(
                    account: account,
                    directory: recipientDirectory
                )
                guard !seeds.isEmpty else { return }
                try await container.client.mergeConversations(seeds)
            } catch {
                // Groups are secondary; a failure should not block messaging.
                await container.client.recordDiagnostic(
                    subsystem: "groups",
                    category: "sync-failed",
                    detail: String(describing: type(of: error))
                )
            }
        }

        /// Runs the embedded signal-cli once so an unusable backend surfaces in
        /// Settings at launch rather than at the moment the user tries to link.
        func refreshBackendStatus() async {
            backendStatus = await Task.detached(priority: .utility) {
                guard SignalCLIBackend.layout() != nil else { return BackendStatus.notEmbedded }
                do {
                    return .ready(version: try SignalCLIBackend.probeVersion())
                } catch {
                    return .failed(reason: error.localizedDescription)
                }
            }.value
        }

        func selectConversation(_ id: ConversationID?) {
            guard id != selectedConversationID else { return }

            if let previousID = selectedConversationID {
                saveComposerDraft(for: previousID)
                stopTyping(in: selectedConversationSeed)
            }
            conversationLoadTask?.cancel()
            olderMessagesTask?.cancel()
            selectedConversationID = id
            restoreComposerDraft(for: id)
            messages = []
            canLoadOlderMessages = false
            isLoadingOlderMessages = false
            guard let id, let container else {
                isLoadingMessages = false
                return
            }

            isLoadingMessages = true
            conversationLoadTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    if selectedConversationID == id {
                        isLoadingMessages = false
                    }
                }
                do {
                    let loaded = try await container.client.messages(
                        in: id,
                        limit: Self.messagePageSize
                    )
                    guard selectedConversationID == id else { return }
                    messages = loaded
                    canLoadOlderMessages = loaded.count == Self.messagePageSize
                    try await container.client.markRead(id)
                    await sendReadReceipts(for: messages)
                    await reloadConversations()
                } catch {
                    guard !Task.isCancelled, selectedConversationID == id else { return }
                    present(error)
                }
            }
        }

        /// Prepends one bounded page without replacing messages already on
        /// screen. Timeline calls this when its oldest row becomes visible.
        func loadOlderMessages() {
            guard
                !isLoadingOlderMessages,
                canLoadOlderMessages,
                let conversationID = selectedConversationID,
                let oldestTimestamp = messages.first?.sentAt,
                let container
            else { return }

            isLoadingOlderMessages = true
            olderMessagesTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    if selectedConversationID == conversationID {
                        isLoadingOlderMessages = false
                    }
                }
                do {
                    let older = try await container.client.messages(
                        in: conversationID,
                        before: oldestTimestamp,
                        limit: Self.messagePageSize
                    )
                    guard selectedConversationID == conversationID else { return }
                    let existingIDs = Set(messages.map(\.id))
                    messages = older.filter { !existingIDs.contains($0.id) } + messages
                    canLoadOlderMessages = older.count == Self.messagePageSize
                } catch {
                    guard !Task.isCancelled, selectedConversationID == conversationID else { return }
                    present(error, title: "Couldn’t Load Earlier Messages")
                }
            }
        }

        func beginProvisioning() {
            guard let container else { return }
            Task {
                do {
                    provisioningSession = try await container.client.beginProvisioning(deviceName: deviceName)
                } catch {
                    present(error)
                }
            }
        }

        func completeDevelopmentProvisioning() {
            guard
                let container,
                let provisioning = container.developmentProvisioningTransport,
                let crypto = container.developmentCrypto,
                let session = provisioningSession
            else {
                alertTitle = "Can’t Complete Linking"
                alertMessage = "The production Signal provisioning bridge is not present in this build."
                return
            }

            Task {
                do {
                    let identity = try await crypto.generateIdentityHandle()
                    _ = try await provisioning.completeDevelopmentLink(
                        sessionID: session.id,
                        deviceName: deviceName,
                        identityHandle: identity
                    )
                } catch {
                    present(error)
                }
            }
        }

        func cancelProvisioning() {
            guard let container, let session = provisioningSession else { return }
            Task {
                await container.client.cancelProvisioning(sessionID: session.id)
                provisioningSession = nil
            }
        }

        func createDirectConversation(title: String, recipient: String) {
            let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedRecipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedTitle.isEmpty, !normalizedRecipient.isEmpty else {
                alertTitle = "Can’t Start Conversation"
                alertMessage = "A title and recipient identifier are required."
                return
            }
            createDraftConversation(
                title: normalizedTitle,
                kind: .direct(recipientID: RecipientID(normalizedRecipient))
            )
        }

        func createGroupConversation(title: String, members: [String]) {
            let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let memberIDs =
                members
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { RecipientID($0) }
            guard !normalizedTitle.isEmpty, !memberIDs.isEmpty else {
                alertTitle = "Can’t Start Group"
                alertMessage = "A group title and at least one member identifier are required."
                return
            }
            createDraftConversation(
                title: normalizedTitle,
                kind: .group(groupID: UUID().uuidString.lowercased(), memberIDs: Array(Set(memberIDs)))
            )
        }

        func createNoteToSelfConversation() {
            if let existing = conversations.first(where: {
                if case .noteToSelf = $0.kind { return true }
                return false
            }) {
                isShowingNewConversation = false
                selectConversation(existing.id)
                return
            }
            createDraftConversation(title: "Note to Self", kind: .noteToSelf)
        }

        private func createDraftConversation(title: String, kind: ConversationKind) {
            // Derived from the counterpart, never random: an inbound reply
            // resolves to the same identity and so must land in this thread
            // rather than opening a second one.
            let seed = ConversationSeed(
                id: .of(canonicalized(kind)),
                kind: canonicalized(kind),
                title: String(title.prefix(128))
            )

            // Selecting an existing thread instead of shadowing it with a draft.
            if conversations.contains(where: { $0.id == seed.id }) {
                isShowingNewConversation = false
                selectConversation(seed.id)
                return
            }
            draftConversationSeeds[seed.id] = seed
            selectConversation(seed.id)
            isShowingNewConversation = false
        }

        func sendComposerMessage() {
            guard let container, let seed = selectedConversationSeed else { return }
            guard !isStagingAttachments(in: seed.id) else { return }
            let draft = MessageDraft(
                text: composerText,
                replyToMessageID: replyingToMessageID,
                attachments: pendingAttachments,
                textStyles: composerStyles.normalized(forUTF16Length: (composerText as NSString).length)
            )
            guard !draft.isEmpty else { return }
            let editTarget = editingMessageID
            stopTyping(in: seed)
            pendingAttachments = []
            composerText = ""
            composerStyles = []
            replyingToMessageID = nil
            editingMessageID = nil
            composerDrafts[seed.id] = nil

            Task {
                do {
                    if let editTarget {
                        _ = try await container.client.editMessage(
                            editTarget,
                            newText: draft.text,
                            textStyles: draft.textStyles
                        )
                    } else {
                        _ = try await container.client.send(draft, to: seed)
                        draftConversationSeeds.removeValue(forKey: seed.id)
                    }
                    // No reload here: `enqueue` publishes messagesChanged, so the
                    // bubble is already on screen. Refetching would replace the
                    // array and undo the insertion animation.
                    await reloadConversations()
                } catch {
                    let failedDraft = ComposerDraftState(
                        text: draft.text,
                        styles: draft.textStyles,
                        attachments: draft.attachments,
                        replyingToMessageID: editTarget == nil ? draft.replyToMessageID : nil,
                        editingMessageID: editTarget
                    )
                    if selectedConversationID == seed.id, currentComposerDraft.isEmpty {
                        composerText = failedDraft.text
                        composerStyles = failedDraft.styles
                        pendingAttachments = failedDraft.attachments
                        replyingToMessageID = failedDraft.replyingToMessageID
                        editingMessageID = failedDraft.editingMessageID
                    } else {
                        composerDrafts[seed.id] = failedDraft
                    }
                    present(error, title: "Couldn’t Send in \(seed.title)")
                }
            }
        }

        func beginReply(to message: ChatMessage) {
            editingMessageID = nil
            replyingToMessageID = message.id
        }

        func beginEdit(_ message: ChatMessage) {
            guard message.direction == .outgoing else { return }
            guard currentComposerDraft.isEmpty else {
                alertTitle = "Finish Current Draft"
                alertMessage = "Send or clear the current draft before editing another message."
                return
            }
            let text: String
            let styles: [TextStyleRange]
            switch message.content {
            case .text(let value):
                text = value
                styles = []
            case .styledText(let value, let valueStyles):
                text = value
                styles = valueStyles
            default:
                return
            }
            replyingToMessageID = nil
            editingMessageID = message.id
            composerText = text
            composerStyles = styles
        }

        func cancelComposerContext(clearText: Bool = false) {
            replyingToMessageID = nil
            editingMessageID = nil
            if clearText {
                composerText = ""
                composerStyles = []
            }
        }

        private func clearAllComposerDrafts() {
            composerDraftGeneration += 1
            composerDrafts.removeAll()
            attachmentStagingCounts.removeAll()
            composerText = ""
            composerStyles = []
            pendingAttachments = []
            replyingToMessageID = nil
            editingMessageID = nil
        }

        func deleteMessage(_ message: ChatMessage) {
            guard let container else { return }
            Task {
                do {
                    _ = try await container.client.deleteMessage(message.id)
                    if editingMessageID == message.id {
                        cancelComposerContext(clearText: true)
                    }
                    if let selectedConversationID {
                        try await reloadVisibleMessages(in: selectedConversationID)
                    }
                    await reloadConversations()
                } catch {
                    present(error)
                }
            }
        }

        func react(to message: ChatMessage, emoji: String) {
            guard let container else { return }
            Task {
                do {
                    _ = try await container.client.react(to: message.id, emoji: emoji)
                    if let selectedConversationID {
                        try await reloadVisibleMessages(in: selectedConversationID)
                    }
                } catch {
                    present(error)
                }
            }
        }

        func removeReaction(from message: ChatMessage) {
            guard let container else { return }
            Task {
                do {
                    _ = try await container.client.removeReaction(from: message.id)
                    if let selectedConversationID {
                        try await reloadVisibleMessages(in: selectedConversationID)
                    }
                } catch {
                    present(error)
                }
            }
        }

        func simulateIncomingReply() {
            guard
                let container,
                let crypto = container.developmentCrypto,
                let transport = container.developmentServiceTransport,
                let seed = selectedConversationSeed,
                let account = snapshot.linkedAccount
            else {
                alertTitle = "Development Feature Unavailable"
                alertMessage = "Incoming-message simulation is only available in the development build."
                return
            }

            let senderID: RecipientID
            switch seed.kind {
            case .direct(let recipient): senderID = recipient
            case .group(_, let members): senderID = members.first ?? RecipientID("development-group-member")
            case .noteToSelf: senderID = account.localRecipientID
            }

            Task {
                do {
                    let wire = WireMessage(
                        id: .random(),
                        conversation: seed,
                        senderID: senderID,
                        recipientID: account.localRecipientID,
                        kind: .text,
                        body: "This is a locally simulated incoming message.",
                        sentAt: Date()
                    )
                    let payload = try WireCodec().encode(wire)
                    let envelope = try await crypto.seal(
                        payload,
                        envelopeID: .random(),
                        source: DeviceAddress(recipientID: senderID, deviceID: DeviceID("development-phone")),
                        destination: DeviceAddress(recipientID: account.localRecipientID, deviceID: account.deviceID),
                        timestamp: Date(),
                        contentType: .message
                    )
                    await transport.injectIncoming(envelope)
                } catch {
                    present(error)
                }
            }
        }

        func setPinned(_ pinned: Bool, conversationID: ConversationID) {
            guard let container else { return }
            Task {
                do {
                    try await container.client.setPinned(pinned, conversationID: conversationID)
                    await reloadConversations()
                } catch {
                    present(error)
                }
            }
        }

        func setArchived(_ archived: Bool, conversationID: ConversationID) {
            guard let container else { return }
            Task {
                do {
                    try await container.client.setArchived(archived, conversationID: conversationID)
                    if archived, selectedConversationID == conversationID {
                        selectConversation(nil)
                    }
                    await reloadConversations()
                } catch {
                    present(error)
                }
            }
        }

        func requestUnlinkAndDelete() {
            isShowingResetConfirmation = true
        }

        func confirmUnlinkAndDelete() {
            isShowingResetConfirmation = false
            unlinkAndDelete()
        }

        /// Performs reset after caller has obtained confirmation. Recovery UI
        /// may call this directly because its only action is already destructive.
        func unlinkAndDelete() {
            guard let container else { return }
            Task {
                do {
                    // Stop the backend first: it holds the account files that are
                    // about to be deleted, and would rewrite them on the way out.
                    container.daemon?.stop()
                    // Purge filesystem artifacts before the database transition.
                    // If cleanup fails, the linked state remains intact and the
                    // user can retry instead of landing in an unlinked half-reset.
                    try await container.eraseAccountArtifacts()
                    try await container.client.unlinkAndDeleteLocalData()

                    provisioningSession = nil
                    selectedConversationID = nil
                    clearAllComposerDrafts()
                    conversations = []
                    messages = []
                    isLoadingMessages = false
                    canLoadOlderMessages = false
                    isLoadingOlderMessages = false
                    contacts = []
                    contactsByRecipient = [:]
                    recipientDirectory = RecipientDirectory()
                    snapshot = await container.client.snapshot()

                    // Back to a usable, unlinked app rather than a dead window.
                    await startBackendIfNeeded()
                    alertTitle = "Reset Complete"
                    alertMessage =
                        "Vela has been reset. Scan the new QR code to link again, and remove the old device from Linked Devices on your phone."
                } catch {
                    present(error, title: "Reset Failed")
                }
            }
        }

        /// Restarts signal-cli and re-subscribes transport for current account.
        /// Core connection monitor observes transport's `.connected` event and
        /// moves snapshot back to ready. Development transport is already local
        /// and does not need this repair path.
        func retryConnection() {
            guard
                !isRetryingConnection,
                let container,
                let account = snapshot.linkedAccount,
                let daemon = container.daemon,
                let transport = container.serviceTransport
            else { return }

            isRetryingConnection = true
            Task {
                defer { isRetryingConnection = false }
                do {
                    daemon.stop()
                    // `Process.terminate()` is asynchronous. Let old daemon
                    // release socket before resetting daemon state in `start()`.
                    try await Task.sleep(for: .milliseconds(500))
                    try await daemon.start()
                    try await transport.connect(account: account)
                    _ = await container.client.retryOutbox()
                    snapshot = await container.client.snapshot()
                    await refreshBackendStatus()
                } catch {
                    await refreshBackendStatus()
                    present(error, title: "Connection Retry Failed")
                }
            }
        }

        func lock() {
            guard snapshot.linkedAccount != nil, localAppLock.isAvailable else { return }
            isAppLocked = true
        }

        func unlock() {
            Task {
                if await localAppLock.authenticate() {
                    isAppLocked = false
                }
            }
        }

        func refreshDiagnostics() {
            guard let container else { return }
            Task {
                storageStatistics = try? await container.client.statistics()
                diagnosticEvents = await container.client.diagnostics()
            }
        }

        func retryStartup() {
            guard !isRetryingStartup else { return }
            isRetryingStartup = true
            let oldContainer = container
            let oldStartupTask = startupTask
            cancelRuntimeTasks()
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Bootstrap can fail after the container was constructed. Close
                // that client before reopening the same SQLCipher file so Retry
                // never becomes a no-op or races an old database handle.
                await oldStartupTask?.value
                await oldContainer?.client.shutdown()
                oldContainer?.daemon?.stop()
                container = nil
                VelaAppDelegate.container = nil

                do {
                    let rebuilt = try AppContainer.makeDefault()
                    container = rebuilt
                    VelaAppDelegate.container = rebuilt
                    startupFailure = nil
                    alertMessage = nil
                    snapshot.state = .openingDatabase
                    hasStarted = false
                    start()
                } catch {
                    startupFailure = Self.userFacingError(error)
                    alertTitle = "Database Still Unavailable"
                    alertMessage = startupFailure
                    snapshot.state = .recoveryRequired(.databaseCorrupt)
                }
                isRetryingStartup = false
            }
        }

        private func cancelRuntimeTasks() {
            startupTask?.cancel()
            startupTask = nil
            eventTask?.cancel()
            eventTask = nil
            contactSyncTask?.cancel()
            contactSyncTask = nil
            conversationSearchTask?.cancel()
            conversationSearchTask = nil
            conversationLoadTask?.cancel()
            conversationLoadTask = nil
            olderMessagesTask?.cancel()
            olderMessagesTask = nil
            expiryTask?.cancel()
            expiryTask = nil
            if let foregroundObserver {
                NotificationCenter.default.removeObserver(foregroundObserver)
            }
            foregroundObserver = nil
            for task in typingExpiry.values { task.cancel() }
            typingExpiry.removeAll()
            typingParticipants.removeAll()
        }

        func openSourceRepository() {
            guard let url = URL(string: "https://github.com/bybrooklyn/vela") else { return }
            NSWorkspace.shared.open(url)
        }

        private func handle(_ event: ClientEvent) async {
            switch event {
            case .snapshotChanged(let snapshot):
                let wasUnlinked = self.snapshot.linkedAccount == nil
                self.snapshot = snapshot
                if case .recoveryRequired(let reason) = snapshot.state {
                    startupFailure = Self.recoveryMessage(for: reason)
                    alertTitle = "Local Data Needs Recovery"
                    alertMessage = startupFailure
                } else if startupFailure != nil {
                    startupFailure = nil
                }
                if wasUnlinked, snapshot.linkedAccount != nil {
                    await adoptLocalIdentity()
                    // First sync right after linking is what turns raw phone
                    // numbers into names.
                    await syncContacts()
                }
            case .conversationsChanged:
                await reloadConversations()
            case .messagesChanged(let conversationID):
                if selectedConversationID == conversationID {
                    try? await reloadVisibleMessages(in: conversationID)
                }
                await reloadConversations()
            case .provisioningChanged(let event):
                if case .completed = event {
                    provisioningSession = nil
                }
            case .contactsChanged:
                await reloadContacts()
            case .typingChanged(let conversationID, let senderID, let isTyping):
                setTyping(isTyping, conversationID: conversationID, senderID: senderID)
            case .diagnosticsChanged:
                refreshDiagnostics()
            }
        }

        private func reloadAll() async {
            await reloadConversations()
            if let selectedConversationID {
                try? await reloadVisibleMessages(in: selectedConversationID)
            }
            refreshDiagnostics()
        }

        /// Refreshes every page currently visible, so an incoming event does
        /// not collapse a paginated timeline back to latest page.
        private func reloadVisibleMessages(in conversationID: ConversationID) async throws {
            guard let container else { return }
            let limit = max(Self.messagePageSize, messages.count)
            let loaded = try await container.client.messages(in: conversationID, limit: limit)
            guard selectedConversationID == conversationID else { return }
            messages = loaded
            canLoadOlderMessages = loaded.count == limit
        }

        private func reloadConversations() async {
            guard let container else { return }
            do {
                conversations = try await container.client.conversations(includeArchived: true)
            } catch {
                present(error)
            }
        }

        private func present(_ error: any Error, title: String = "Couldn’t Complete Action") {
            alertTitle = title
            alertMessage = Self.userFacingError(error)
        }

        private static func userFacingError(_ error: any Error) -> String {
            if let localized = error as? LocalizedError, let description = localized.errorDescription {
                return description
            }
            return "Operation failed: \(String(reflecting: type(of: error)))"
        }

        private static func recoveryMessage(for reason: RecoveryReason) -> String {
            switch reason {
            case .databaseCorrupt:
                "Vela could not open its local database. The database may be damaged or its encryption key may be unavailable."
            case .migrationFailed:
                "Vela could not migrate its local database safely. Your existing data was left untouched."
            case .credentialsMissing:
                "Vela found linked-device state without the credentials needed to use it."
            case .localStateInconsistent:
                "Vela found inconsistent local state and stopped before changing your message history."
            }
        }
    }
#endif
