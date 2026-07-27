import Foundation
import VelaDomain

public actor InMemoryStore: ClientStore {
    private var account: LinkedAccount?
    private var conversations: [ConversationID: Conversation] = [:]
    private var contacts: [RecipientID: Contact] = [:]
    private var messages: [MessageID: ChatMessage] = [:]
    private var outbox: [MessageID: OutboxItem] = [:]
    private var seenEnvelopes: Set<EnvelopeID> = []

    public init() {}

    public func migrate() async throws {}

    public func loadLinkedAccount() async throws -> LinkedAccount? {
        account
    }

    public func saveLinkedAccount(_ account: LinkedAccount) async throws {
        self.account = account
    }

    public func deleteAllLocalData() async throws {
        account = nil
        conversations.removeAll(keepingCapacity: false)
        messages.removeAll(keepingCapacity: false)
        outbox.removeAll(keepingCapacity: false)
        seenEnvelopes.removeAll(keepingCapacity: false)
        contacts.removeAll(keepingCapacity: false)
    }

    public func loadConversations(includeArchived: Bool) async throws -> [Conversation] {
        conversations.values
            .filter { includeArchived || !$0.isArchived }
            .sorted(by: Self.conversationOrdering)
    }

    public func loadConversation(id: ConversationID) async throws -> Conversation? {
        conversations[id]
    }

    public func loadMessages(conversationID: ConversationID, before: Date?, limit: Int) async throws -> [ChatMessage] {
        messages.values
            .filter { message in
                message.conversationID == conversationID && (before == nil || message.sentAt < before!)
            }
            .sorted { $0.sentAt < $1.sentAt }
            .suffix(max(0, limit))
    }

    public func loadMessage(id: MessageID) async throws -> ChatMessage? {
        messages[id]
    }

    public func searchMessages(query: String, limit: Int) async throws -> [ChatMessage] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard !normalized.isEmpty else { return [] }

        return messages.values
            .filter { message in
                message.content.privacySafePreviewText
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    .contains(normalized)
            }
            .sorted { $0.sentAt > $1.sentAt }
            .prefix(max(0, limit))
            .map { $0 }
    }

    public func persistOutgoing(
        message: ChatMessage,
        conversationSeed: ConversationSeed,
        outboxItem: OutboxItem
    ) async throws {
        messages[message.id] = message
        outbox[message.id] = outboxItem
        upsertConversation(seed: conversationSeed, message: message, incrementUnread: false)
    }

    public func persistIncoming(
        message: ChatMessage,
        conversationSeed: ConversationSeed,
        envelopeID: EnvelopeID,
        incrementUnread: Bool
    ) async throws -> Bool {
        guard !seenEnvelopes.contains(envelopeID) else { return false }
        seenEnvelopes.insert(envelopeID)
        messages[message.id] = message
        upsertConversation(seed: conversationSeed, message: message, incrementUnread: incrementUnread)
        return true
    }

    public func persistOutgoingMutation(
        targetMessage: ChatMessage,
        outboxItem: OutboxItem
    ) async throws {
        messages[targetMessage.id] = targetMessage
        outbox[outboxItem.messageID] = outboxItem
        rebuildConversationPreview(targetMessage.conversationID)
    }

    public func persistIncomingMutation(
        targetMessage: ChatMessage,
        envelopeID: EnvelopeID,
        receivedAt: Date
    ) async throws -> Bool {
        guard !seenEnvelopes.contains(envelopeID) else { return false }
        seenEnvelopes.insert(envelopeID)
        messages[targetMessage.id] = targetMessage
        rebuildConversationPreview(targetMessage.conversationID)
        return true
    }

    public func recordSeenEnvelope(_ id: EnvelopeID, at date: Date) async throws -> Bool {
        seenEnvelopes.insert(id).inserted
    }

    public func loadDueOutbox(at date: Date, limit: Int) async throws -> [OutboxItem] {
        outbox.values
            .filter { $0.nextAttemptAt <= date }
            .sorted { lhs, rhs in
                if lhs.nextAttemptAt != rhs.nextAttemptAt { return lhs.nextAttemptAt < rhs.nextAttemptAt }
                return lhs.createdAt < rhs.createdAt
            }
            .prefix(max(0, limit))
            .map { $0 }
    }

    public func updateOutboxItem(_ item: OutboxItem, messageState: MessageDeliveryState) async throws {
        outbox[item.messageID] = item
        guard var message = messages[item.messageID] else { return }
        message.deliveryState = messageState
        messages[item.messageID] = message
    }

    public func completeOutboxItem(messageID: MessageID, serverTimestamp: Date) async throws {
        outbox.removeValue(forKey: messageID)
        guard var message = messages[messageID] else { return }
        message.deliveryState = .sent(serverTimestamp: serverTimestamp)
        messages[messageID] = message
    }

    public func permanentlyFailOutboxItem(messageID: MessageID, category: String) async throws {
        let item = outbox.removeValue(forKey: messageID)
        if let targetID = item?.mutationTargetID,
            let rollback = item?.rollbackTarget,
            rollback.id == targetID
        {
            messages[targetID] = rollback
            rebuildConversationPreview(rollback.conversationID)
            return
        }
        guard var message = messages[messageID] else { return }
        message.deliveryState = .failedPermanent(reason: category)
        messages[messageID] = message
    }

    public func upsertConversations(_ seeds: [ConversationSeed], at date: Date) async throws {
        for seed in seeds {
            if var existing = conversations[seed.id] {
                existing.kind = seed.kind
                existing.title = seed.title
                conversations[seed.id] = existing
            } else {
                conversations[seed.id] = .from(seed: seed, at: date)
            }
        }
    }

    public func setConversationDisappearingDuration(
        _ duration: TimeInterval?,
        for id: ConversationID
    ) async throws {
        guard var conversation = conversations[id] else { return }
        conversation.disappearingMessageDuration = duration
        conversations[id] = conversation
    }

    public func loadContacts(includeBlocked: Bool) async throws -> [Contact] {
        contacts.values
            .filter { includeBlocked || !$0.isBlocked }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public func loadContact(recipientID: RecipientID) async throws -> Contact? {
        contacts[recipientID]
    }

    public func replaceContacts(_ contacts: [Contact]) async throws {
        self.contacts = Dictionary(contacts.map { ($0.recipientID, $0) }, uniquingKeysWith: { _, new in new })
    }

    public func upsertContacts(_ contacts: [Contact]) async throws {
        for contact in contacts {
            self.contacts[contact.recipientID] = contact
        }
    }

    public func searchContacts(query: String, limit: Int) async throws -> [Contact] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = try await loadContacts(includeBlocked: false)
        guard !trimmed.isEmpty else { return Array(matches.prefix(limit)) }
        return
            matches
            .filter { $0.displayName.localizedCaseInsensitiveContains(trimmed) }
            .prefix(limit)
            .map { $0 }
    }

    public func markConversationRead(_ id: ConversationID, at date: Date) async throws {
        guard var conversation = conversations[id] else { return }
        conversation.unreadCount = 0
        conversations[id] = conversation
    }

    public func setConversationPinned(_ id: ConversationID, pinned: Bool) async throws {
        guard var conversation = conversations[id] else { return }
        conversation.isPinned = pinned
        conversations[id] = conversation
    }

    public func setConversationArchived(_ id: ConversationID, archived: Bool) async throws {
        guard var conversation = conversations[id] else { return }
        conversation.isArchived = archived
        conversations[id] = conversation
    }

    public func removeExpiredMessages(at date: Date) async throws -> Int {
        let expiredIDs = messages.values
            .filter { message in
                guard let expiresAt = message.expiresAt else { return false }
                return expiresAt <= date
            }
            .map(\.id)

        for id in expiredIDs {
            messages.removeValue(forKey: id)
            outbox.removeValue(forKey: id)
        }
        rebuildConversationPreviews()
        return expiredIDs.count
    }

    public func statistics() async throws -> StoreStatistics {
        StoreStatistics(
            accountCount: account == nil ? 0 : 1,
            conversationCount: conversations.count,
            messageCount: messages.count,
            pendingOutboxCount: outbox.count,
            seenEnvelopeCount: seenEnvelopes.count
        )
    }

    private func upsertConversation(seed: ConversationSeed, message: ChatMessage, incrementUnread: Bool) {
        var conversation = conversations[seed.id] ?? .from(seed: seed, at: message.sentAt)
        conversation.title = seed.title
        conversation.kind = seed.kind
        conversation.updatedAt = max(conversation.updatedAt, message.sentAt)
        conversation.lastMessage = MessagePreview(
            text: message.content.privacySafePreviewText,
            timestamp: message.sentAt,
            isOutgoing: message.direction == .outgoing
        )
        if incrementUnread {
            conversation.unreadCount += 1
        }
        conversations[seed.id] = conversation
    }

    private func rebuildConversationPreviews() {
        for id in conversations.keys {
            rebuildConversationPreview(id)
        }
    }

    private func rebuildConversationPreview(_ id: ConversationID) {
        guard var conversation = conversations[id] else { return }
        let latest = messages.values
            .filter { $0.conversationID == id }
            .max { $0.sentAt < $1.sentAt }
        conversation.lastMessage = latest.map {
            MessagePreview(
                text: $0.content.privacySafePreviewText,
                timestamp: $0.sentAt,
                isOutgoing: $0.direction == .outgoing
            )
        }
        if let latest {
            conversation.updatedAt = latest.sentAt
        }
        conversations[id] = conversation
    }

    private static func conversationOrdering(_ lhs: Conversation, _ rhs: Conversation) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id.rawValue < rhs.id.rawValue
    }
}
