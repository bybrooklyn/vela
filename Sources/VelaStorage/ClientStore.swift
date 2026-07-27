import Foundation
import VelaDomain

public protocol ClientStore: Sendable {
    func migrate() async throws

    func loadLinkedAccount() async throws -> LinkedAccount?
    func saveLinkedAccount(_ account: LinkedAccount) async throws
    func deleteAllLocalData() async throws

    func loadConversations(includeArchived: Bool) async throws -> [Conversation]
    func loadConversation(id: ConversationID) async throws -> Conversation?
    func loadMessages(conversationID: ConversationID, before: Date?, limit: Int) async throws -> [ChatMessage]
    func loadMessage(id: MessageID) async throws -> ChatMessage?
    func searchMessages(query: String, limit: Int) async throws -> [ChatMessage]

    func persistOutgoing(
        message: ChatMessage,
        conversationSeed: ConversationSeed,
        outboxItem: OutboxItem
    ) async throws

    /// Returns false when the envelope was already committed previously.
    /// - Parameter incrementUnread: false for a message this account sent from
    ///   another device, which arrives here as a sync and must not mark the
    ///   conversation unread.
    func persistIncoming(
        message: ChatMessage,
        conversationSeed: ConversationSeed,
        envelopeID: EnvelopeID,
        incrementUnread: Bool
    ) async throws -> Bool

    /// Atomically applies an optimistic local mutation and queues its control envelope.
    func persistOutgoingMutation(
        targetMessage: ChatMessage,
        outboxItem: OutboxItem
    ) async throws

    /// Atomically applies an incoming mutation and records the envelope for replay suppression.
    func persistIncomingMutation(
        targetMessage: ChatMessage,
        envelopeID: EnvelopeID,
        receivedAt: Date
    ) async throws -> Bool

    /// Records a non-display control envelope such as typing or a receipt.
    func recordSeenEnvelope(_ id: EnvelopeID, at date: Date) async throws -> Bool

    func loadDueOutbox(at date: Date, limit: Int) async throws -> [OutboxItem]
    func updateOutboxItem(_ item: OutboxItem, messageState: MessageDeliveryState) async throws
    func completeOutboxItem(messageID: MessageID, serverTimestamp: Date) async throws
    func permanentlyFailOutboxItem(messageID: MessageID, category: String) async throws

    /// Creates or refreshes conversations that have no message yet, such as
    /// groups discovered by syncing from the primary device. Existing
    /// conversations keep their unread count, pin and archive state.
    func upsertConversations(_ seeds: [ConversationSeed], at date: Date) async throws
    func setConversationDisappearingDuration(_ duration: TimeInterval?, for id: ConversationID) async throws

    /// Contacts mirror the primary device and are replaced wholesale on sync.
    func loadContacts(includeBlocked: Bool) async throws -> [Contact]
    func loadContact(recipientID: RecipientID) async throws -> Contact?
    /// Atomically replaces the complete primary-device contact snapshot.
    func replaceContacts(_ contacts: [Contact]) async throws
    /// Merges individual contacts without removing records omitted by the caller.
    func upsertContacts(_ contacts: [Contact]) async throws
    func searchContacts(query: String, limit: Int) async throws -> [Contact]

    func markConversationRead(_ id: ConversationID, at date: Date) async throws
    func setConversationPinned(_ id: ConversationID, pinned: Bool) async throws
    func setConversationArchived(_ id: ConversationID, archived: Bool) async throws

    func removeExpiredMessages(at date: Date) async throws -> Int
    func statistics() async throws -> StoreStatistics
}

public enum DatabaseSecurity: Sendable, Equatable {
    case plaintextDevelopmentOnly
    case sqlCipher(key: DatabaseKey)
}

public struct DatabaseKey: Sendable, Equatable {
    public let bytes: Data

    public init(bytes: Data) throws {
        guard bytes.count >= 32 else {
            throw StoreError.invalidDatabaseKey
        }
        self.bytes = bytes
    }
}

public enum StoreError: Error, Sendable, LocalizedError {
    case invalidDatabaseKey
    case sqlCipherUnavailable
    case openFailed(String)
    case statementFailed(String)
    case encodingFailed(String)
    case decodingFailed(String)
    case migrationFailed(String)
    case constraintViolation(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDatabaseKey: "The database key is too short."
        case .sqlCipherUnavailable: "SQLCipher is required, but the linked SQLite library is not SQLCipher."
        case .openFailed(let category): "Could not open the database: \(category)."
        case .statementFailed(let category): "A database statement failed: \(category)."
        case .encodingFailed(let category): "Could not encode local data: \(category)."
        case .decodingFailed(let category): "Could not decode local data: \(category)."
        case .migrationFailed(let category): "A database migration failed: \(category)."
        case .constraintViolation(let category): "A database constraint was violated: \(category)."
        }
    }
}
