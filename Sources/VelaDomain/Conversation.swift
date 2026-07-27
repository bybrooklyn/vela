import Foundation

public enum ConversationKind: Hashable, Codable, Sendable {
    case direct(recipientID: RecipientID)
    case group(groupID: String, memberIDs: [RecipientID])
    case noteToSelf
}

public struct ConversationSeed: Hashable, Codable, Sendable {
    public var id: ConversationID
    public var kind: ConversationKind
    public var title: String

    public init(id: ConversationID, kind: ConversationKind, title: String) {
        self.id = id
        self.kind = kind
        self.title = title
    }
}

public struct MessagePreview: Hashable, Codable, Sendable {
    public var text: String
    public var timestamp: Date
    public var isOutgoing: Bool

    public init(text: String, timestamp: Date, isOutgoing: Bool) {
        self.text = text
        self.timestamp = timestamp
        self.isOutgoing = isOutgoing
    }
}

public struct Conversation: Identifiable, Hashable, Codable, Sendable {
    public var id: ConversationID
    public var kind: ConversationKind
    public var title: String
    public var subtitle: String?
    public var avatarToken: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var lastMessage: MessagePreview?
    public var unreadCount: Int
    public var isPinned: Bool
    public var isArchived: Bool
    public var mutedUntil: Date?
    public var disappearingMessageDuration: TimeInterval?

    public init(
        id: ConversationID,
        kind: ConversationKind,
        title: String,
        subtitle: String? = nil,
        avatarToken: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        lastMessage: MessagePreview? = nil,
        unreadCount: Int = 0,
        isPinned: Bool = false,
        isArchived: Bool = false,
        mutedUntil: Date? = nil,
        disappearingMessageDuration: TimeInterval? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.avatarToken = avatarToken
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastMessage = lastMessage
        self.unreadCount = unreadCount
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.mutedUntil = mutedUntil
        self.disappearingMessageDuration = disappearingMessageDuration
    }

    public static func from(seed: ConversationSeed, at date: Date) -> Conversation {
        Conversation(
            id: seed.id,
            kind: seed.kind,
            title: seed.title,
            createdAt: date,
            updatedAt: date
        )
    }
}
