import Foundation
import VelaCrypto
import VelaDomain
import VelaStorage
import VelaTransport

public struct VelaClientDependencies: Sendable {
    public var store: any ClientStore
    public var crypto: any CryptoEngine
    public var serviceTransport: any ServiceTransport
    public var provisioningTransport: any ProvisioningTransport
    public var recipientRouter: any RecipientRouter
    public var notificationSink: any IncomingMessageNotificationSink
    public var clock: any VelaClock
    public var backoffPolicy: BackoffPolicy

    public init(
        store: any ClientStore,
        crypto: any CryptoEngine,
        serviceTransport: any ServiceTransport,
        provisioningTransport: any ProvisioningTransport,
        recipientRouter: any RecipientRouter,
        notificationSink: any IncomingMessageNotificationSink = NullIncomingMessageNotificationSink(),
        clock: any VelaClock = SystemVelaClock(),
        backoffPolicy: BackoffPolicy = BackoffPolicy()
    ) {
        self.store = store
        self.crypto = crypto
        self.serviceTransport = serviceTransport
        self.provisioningTransport = provisioningTransport
        self.recipientRouter = recipientRouter
        self.notificationSink = notificationSink
        self.clock = clock
        self.backoffPolicy = backoffPolicy
    }
}

public actor VelaClient {
    private let dependencies: VelaClientDependencies
    private let eventHub: ClientEventHub
    private let diagnosticsRecorder: DiagnosticsRecorder
    private let sender: MessageSender
    private let outbox: OutboxProcessor
    private let receiver: MessageReceiver
    private let provisioner: ProvisioningCoordinator

    private var state: ClientState = .unlinked
    private var connectionState: TransportConnectionState = .disconnected
    private var account: LinkedAccount?
    private var connectionTask: Task<Void, Never>?
    private var internalEventTask: Task<Void, Never>?
    private var hasBootstrapped = false

    public init(dependencies: VelaClientDependencies) {
        let eventHub = ClientEventHub()
        let diagnostics = DiagnosticsRecorder()
        self.dependencies = dependencies
        self.eventHub = eventHub
        self.diagnosticsRecorder = diagnostics
        self.sender = MessageSender(
            store: dependencies.store,
            router: dependencies.recipientRouter,
            clock: dependencies.clock,
            events: eventHub
        )
        self.outbox = OutboxProcessor(
            store: dependencies.store,
            crypto: dependencies.crypto,
            transport: dependencies.serviceTransport,
            clock: dependencies.clock,
            backoff: dependencies.backoffPolicy,
            events: eventHub,
            diagnostics: diagnostics
        )
        self.receiver = MessageReceiver(
            store: dependencies.store,
            crypto: dependencies.crypto,
            transport: dependencies.serviceTransport,
            clock: dependencies.clock,
            events: eventHub,
            diagnostics: diagnostics,
            notifications: dependencies.notificationSink
        )
        self.provisioner = ProvisioningCoordinator(
            transport: dependencies.provisioningTransport,
            crypto: dependencies.crypto,
            store: dependencies.store,
            clock: dependencies.clock,
            events: eventHub,
            diagnostics: diagnostics
        )
    }

    public func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        startInternalEventMonitor()
        await transition(to: .openingDatabase)

        do {
            try await dependencies.store.migrate()
            // Never expose messages whose timers elapsed while Vela was closed.
            // UI reload happens after bootstrap, so no refresh event is needed.
            _ = try await dependencies.store.removeExpiredMessages(at: dependencies.clock.now)
            account = try await dependencies.store.loadLinkedAccount()
            if let account {
                await startServices(account: account)
            } else {
                await transition(to: .unlinked)
            }
        } catch {
            await diagnosticsRecorder.record(
                subsystem: "bootstrap",
                category: "storage-open-failed",
                detail: DiagnosticsRecorder.errorCategory(error),
                at: dependencies.clock.now
            )
            await eventHub.publish(.diagnosticsChanged)
            await transition(to: .recoveryRequired(Self.recoveryReason(for: error)))
        }
    }

    public func events() async -> AsyncStream<ClientEvent> {
        await eventHub.stream()
    }

    public func snapshot() async -> ClientSnapshot {
        await makeSnapshot()
    }

    public func beginProvisioning(deviceName: String) async throws -> ProvisioningSession {
        guard account == nil else { throw VelaError.alreadyLinked }
        let normalized = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveName = normalized.isEmpty ? "Mac" : String(normalized.prefix(64))
        let session = try await provisioner.begin(deviceName: effectiveName)
        await transition(to: .linking(sessionID: session.id))
        return session
    }

    public func cancelProvisioning(sessionID: ProvisioningSessionID) async {
        await provisioner.cancel(sessionID: sessionID)
        await transition(to: .unlinked)
    }

    @discardableResult
    public func send(
        _ draft: MessageDraft,
        to conversationSeed: ConversationSeed
    ) async throws -> MessageID {
        guard let account else { throw VelaError.notLinked }
        let existing = try await dependencies.store.loadConversation(id: conversationSeed.id)
        let id = try await sender.enqueue(
            draft: draft,
            conversation: conversationSeed,
            account: account,
            disappearingDuration: existing?.disappearingMessageDuration
        )
        // Deliberately not awaited: `enqueue` has already persisted the message
        // and published `messagesChanged`, so the UI can paint it now. Waiting
        // for the network round-trip here is what made sending feel dead.
        if connectionState == .connected {
            await outbox.requestFlush()
        }
        await publishSnapshot()
        return id
    }

    @discardableResult
    public func editMessage(
        _ messageID: MessageID,
        newText: String,
        textStyles: [TextStyleRange] = []
    ) async throws -> MessageID {
        guard let account else { throw VelaError.notLinked }
        let controlID = try await sender.enqueueEdit(
            messageID: messageID,
            newText: newText,
            textStyles: textStyles,
            account: account
        )
        await flushAfterEnqueue()
        return controlID
    }

    @discardableResult
    public func deleteMessage(_ messageID: MessageID) async throws -> MessageID {
        guard let account else { throw VelaError.notLinked }
        let controlID = try await sender.enqueueDelete(messageID: messageID, account: account)
        await flushAfterEnqueue()
        return controlID
    }

    @discardableResult
    public func react(to messageID: MessageID, emoji: String) async throws -> MessageID {
        guard let account else { throw VelaError.notLinked }
        let controlID = try await sender.enqueueReaction(
            messageID: messageID,
            emoji: emoji,
            account: account
        )
        await flushAfterEnqueue()
        return controlID
    }

    @discardableResult
    public func removeReaction(from messageID: MessageID) async throws -> MessageID {
        guard let account else { throw VelaError.notLinked }
        let controlID = try await sender.enqueueRemoveReaction(messageID: messageID, account: account)
        await flushAfterEnqueue()
        return controlID
    }

    public func flushOutbox() async -> OutboxFlushReport {
        let report = await outbox.flushOnce()
        await publishSnapshot()
        return report
    }

    /// Retries every retained transient send immediately after a user-requested
    /// reconnect, bypassing its previous backoff delay.
    public func retryOutbox() async -> OutboxFlushReport {
        let report = await outbox.retryPending()
        await publishSnapshot()
        return report
    }

    public func conversations(includeArchived: Bool = false) async throws -> [Conversation] {
        try await dependencies.store.loadConversations(includeArchived: includeArchived)
    }

    public func messages(
        in conversationID: ConversationID,
        before: Date? = nil,
        limit: Int = 200
    ) async throws -> [ChatMessage] {
        try await dependencies.store.loadMessages(
            conversationID: conversationID,
            before: before,
            limit: limit
        )
    }

    public func search(_ query: String, limit: Int = 100) async throws -> [ChatMessage] {
        try await dependencies.store.searchMessages(query: query, limit: limit)
    }

    public func contacts(includeBlocked: Bool = false) async throws -> [Contact] {
        try await dependencies.store.loadContacts(includeBlocked: includeBlocked)
    }

    public func contact(for recipientID: RecipientID) async throws -> Contact? {
        try await dependencies.store.loadContact(recipientID: recipientID)
    }

    public func searchContacts(query: String, limit: Int = 100) async throws -> [Contact] {
        try await dependencies.store.searchContacts(query: query, limit: limit)
    }

    /// Replaces the cached contact list. The caller supplies the records because
    /// fetching them is backend-specific; the client owns persistence and events.
    public func replaceContacts(_ contacts: [Contact]) async throws {
        try await dependencies.store.replaceContacts(contacts)
        await eventHub.publish(.contactsChanged)
    }

    /// Records a redacted diagnostic from outside the core, so optional
    /// subsystems can report failures without inventing their own channel.
    public func recordDiagnostic(subsystem: String, category: String, detail: String) async {
        await diagnosticsRecorder.record(
            subsystem: subsystem,
            category: category,
            detail: detail,
            at: dependencies.clock.now
        )
        await eventHub.publish(.diagnosticsChanged)
    }

    /// Adds groups discovered by syncing, so they appear before any message.
    public func mergeConversations(_ seeds: [ConversationSeed]) async throws {
        try await dependencies.store.upsertConversations(seeds, at: dependencies.clock.now)
        await eventHub.publish(.conversationsChanged)
    }

    public func markRead(_ conversationID: ConversationID) async throws {
        try await dependencies.store.markConversationRead(conversationID, at: dependencies.clock.now)
        await eventHub.publish(.conversationsChanged)
        await publishSnapshot()
    }

    public func setPinned(_ pinned: Bool, conversationID: ConversationID) async throws {
        try await dependencies.store.setConversationPinned(conversationID, pinned: pinned)
        await eventHub.publish(.conversationsChanged)
    }

    public func setArchived(_ archived: Bool, conversationID: ConversationID) async throws {
        try await dependencies.store.setConversationArchived(conversationID, archived: archived)
        await eventHub.publish(.conversationsChanged)
    }

    @discardableResult
    public func removeExpiredMessages() async throws -> Int {
        let count = try await dependencies.store.removeExpiredMessages(at: dependencies.clock.now)
        if count > 0 {
            await eventHub.publish(.conversationsChanged)
        }
        return count
    }

    public func diagnostics() async -> [DiagnosticEvent] {
        await diagnosticsRecorder.snapshot()
    }

    public func statistics() async throws -> StoreStatistics {
        try await dependencies.store.statistics()
    }

    public func unlinkAndDeleteLocalData() async throws {
        await transition(to: .deletingData)
        await stopServices(reason: .userRequested)
        do {
            try await dependencies.store.deleteAllLocalData()
        } catch {
            await transition(to: .recoveryRequired(.localStateInconsistent))
            throw error
        }
        account = nil
        await transition(to: .unlinked)
        await eventHub.publish(.conversationsChanged)
    }

    public func shutdown() async {
        await stopServices(reason: .userRequested)
        internalEventTask?.cancel()
        internalEventTask = nil
        await eventHub.finish()
    }

    /// Edits, reactions and deletes take the same optimistic path: the local
    /// change is already stored, so the send happens in the background.
    private func flushAfterEnqueue() async {
        if connectionState == .connected {
            await outbox.requestFlush()
        }
        await publishSnapshot()
    }

    private func startServices(account: LinkedAccount) async {
        await transition(to: .startingServices)
        startConnectionMonitor()
        await receiver.start(account: account)
        await outbox.start(account: account)

        do {
            try await dependencies.serviceTransport.connect(account: account)
            self.account = account
            await transition(to: .ready)
            _ = await outbox.flushOnce()
        } catch {
            self.account = account
            await diagnosticsRecorder.record(
                subsystem: "transport",
                category: "connect-failed",
                detail: DiagnosticsRecorder.errorCategory(error),
                at: dependencies.clock.now
            )
            await eventHub.publish(.diagnosticsChanged)
            await transition(to: .offline(.serviceUnavailable))
        }
    }

    private func stopServices(reason: OfflineReason) async {
        connectionTask?.cancel()
        connectionTask = nil
        await receiver.stop()
        await outbox.stop()
        await dependencies.serviceTransport.disconnect(reason: reason)
        connectionState = .disconnected
    }

    private func startConnectionMonitor() {
        connectionTask?.cancel()
        connectionTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.dependencies.serviceTransport.connectionStates()
            for await connection in stream {
                guard !Task.isCancelled else { break }
                await self.handleConnectionState(connection)
            }
        }
    }

    private func handleConnectionState(_ connection: TransportConnectionState) async {
        connectionState = connection
        switch connection {
        case .connected:
            if account != nil {
                switch state {
                case .openingDatabase, .linking, .importingHistory, .deletingData, .recoveryRequired:
                    break
                default:
                    state = .ready
                }
            }
        case .disconnected:
            if account != nil, state == .ready {
                state = .offline(.unknown)
            }
        case .failed(let category):
            if category == "authentication-rejected" {
                state = .relinkRequired
            } else if account != nil {
                state = .offline(.serviceUnavailable)
            }
        case .connecting, .backingOff:
            break
        }
        await publishSnapshot()
    }

    private func startInternalEventMonitor() {
        internalEventTask?.cancel()
        internalEventTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.eventHub.stream()
            for await event in stream {
                guard !Task.isCancelled else { break }
                await self.handleInternalEvent(event)
            }
        }
    }

    private func handleInternalEvent(_ event: ClientEvent) async {
        switch event {
        case .provisioningChanged(.completed):
            do {
                guard let linked = try await dependencies.store.loadLinkedAccount() else {
                    await transition(to: .recoveryRequired(.credentialsMissing))
                    return
                }
                account = linked
                await startServices(account: linked)
            } catch {
                await diagnosticsRecorder.record(
                    subsystem: "provisioning",
                    category: "load-completed-account-failed",
                    detail: DiagnosticsRecorder.errorCategory(error),
                    at: dependencies.clock.now
                )
                await eventHub.publish(.diagnosticsChanged)
                await transition(to: .recoveryRequired(.credentialsMissing))
            }
        case .provisioningChanged(.failed(let category)):
            await diagnosticsRecorder.record(
                subsystem: "provisioning",
                category: "link-failed",
                detail: category,
                at: dependencies.clock.now
            )
            await eventHub.publish(.diagnosticsChanged)
            await transition(to: .unlinked)
        case .provisioningChanged(.cancelled):
            await transition(to: .unlinked)
        case .conversationsChanged, .messagesChanged:
            await publishSnapshot()
        default:
            break
        }
    }

    private func transition(to newState: ClientState) async {
        state = newState
        await publishSnapshot()
    }

    private func publishSnapshot() async {
        await eventHub.publish(.snapshotChanged(await makeSnapshot()))
    }

    private func makeSnapshot() async -> ClientSnapshot {
        let unread: Int
        do {
            unread = try await dependencies.store
                .loadConversations(includeArchived: true)
                .reduce(0) { $0 + $1.unreadCount }
        } catch {
            unread = 0
        }
        return ClientSnapshot(
            state: state,
            connection: connectionState,
            linkedAccount: account,
            unreadCount: unread
        )
    }

    static func recoveryReason(for error: any Error) -> RecoveryReason {
        guard let storeError = error as? StoreError else { return .databaseCorrupt }
        return switch storeError {
        case .migrationFailed:
            .migrationFailed
        case .decodingFailed, .constraintViolation:
            .localStateInconsistent
        case .invalidDatabaseKey, .sqlCipherUnavailable, .openFailed, .statementFailed, .encodingFailed:
            .databaseCorrupt
        }
    }
}
