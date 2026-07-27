import Foundation

public enum MessageDirection: String, Hashable, Codable, Sendable {
    case incoming
    case outgoing
    case system
}

public enum MessageContent: Hashable, Codable, Sendable {
    case text(String)
    /// Text carrying Signal formatting runs. Kept separate from `.text` so
    /// existing stored messages decode unchanged.
    case styledText(String, [TextStyleRange])
    case deleted(deletedBy: RecipientID?)
    case unsupported(requiredVersion: Int, description: String)
    case system(String)

    /// The formatting runs, if any.
    public var textStyles: [TextStyleRange] {
        if case .styledText(_, let styles) = self { return styles }
        return []
    }

    public var previewText: String {
        switch self {
        case .text(let text): text
        case .styledText(let text, _): text
        case .deleted: "Message deleted"
        case .unsupported: "Unsupported message"
        case .system(let text): text
        }
    }

    /// Whether the body contains at least one Signal spoiler range.
    ///
    /// A spoiler must stay private in compact surfaces such as conversation
    /// previews, search indexes, reply snippets, and accessibility labels until
    /// the user deliberately reveals it in the message timeline.
    public var containsSpoiler: Bool {
        guard case .styledText(_, let styles) = self else { return false }
        return styles.contains { $0.style == .spoiler && !$0.isEmpty }
    }

    /// A compact body suitable for surfaces that cannot represent spoiler state.
    ///
    /// Keep non-spoiler text readable, but replace every hidden range with a
    /// neutral token. Ranges are UTF-16 because that is Signal's wire format;
    /// applying them from the end avoids changing earlier offsets.
    public var privacySafePreviewText: String {
        guard case .styledText(let text, let styles) = self else { return previewText }

        let length = (text as NSString).length
        let spoilerRanges =
            styles
            .normalized(forUTF16Length: length)
            .filter { $0.style == .spoiler }
            .sorted { $0.start > $1.start }

        guard !spoilerRanges.isEmpty else { return text }

        var result = text
        for style in spoilerRanges {
            result = (result as NSString).replacingCharacters(in: style.nsRange, with: "Spoiler")
        }
        return result
    }
}

public enum MessageDeliveryState: Hashable, Codable, Sendable {
    case queued
    case sending(attempt: Int)
    case sent(serverTimestamp: Date)
    case delivered(at: Date)
    case read(at: Date)
    case failedRetryable(reason: String)
    case failedPermanent(reason: String)
}

public struct MessageReaction: Identifiable, Hashable, Codable, Sendable {
    public var id: ReactionID
    public var authorID: RecipientID
    public var emoji: String
    public var createdAt: Date

    public init(id: ReactionID = .random(), authorID: RecipientID, emoji: String, createdAt: Date) {
        self.id = id
        self.authorID = authorID
        self.emoji = emoji
        self.createdAt = createdAt
    }
}

public enum AttachmentTransferState: Hashable, Codable, Sendable {
    case pending
    case transferring(progress: Double)
    case available(localRelativePath: String)
    case failed(reason: String)
}

public struct AttachmentReference: Identifiable, Hashable, Codable, Sendable {
    public var id: AttachmentID
    public var fileName: String?
    public var mimeType: String
    public var byteCount: Int64
    public var digest: Data?
    public var caption: String?
    public var isViewOnce: Bool
    public var state: AttachmentTransferState

    public init(
        id: AttachmentID = .random(),
        fileName: String? = nil,
        mimeType: String,
        byteCount: Int64,
        digest: Data? = nil,
        caption: String? = nil,
        isViewOnce: Bool = false,
        state: AttachmentTransferState = .pending
    ) {
        self.id = id
        self.fileName = fileName
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.digest = digest
        self.caption = caption
        self.isViewOnce = isViewOnce
        self.state = state
    }
}

public struct ChatMessage: Identifiable, Hashable, Codable, Sendable {
    public var id: MessageID
    public var conversationID: ConversationID
    public var senderID: RecipientID
    public var direction: MessageDirection
    public var content: MessageContent
    public var sentAt: Date
    public var receivedAt: Date?
    public var deliveryState: MessageDeliveryState
    public var replyToMessageID: MessageID?
    public var replacesMessageID: MessageID?
    public var revision: Int
    public var expiresAt: Date?
    public var attachments: [AttachmentReference]
    public var reactions: [MessageReaction]

    public init(
        id: MessageID,
        conversationID: ConversationID,
        senderID: RecipientID,
        direction: MessageDirection,
        content: MessageContent,
        sentAt: Date,
        receivedAt: Date? = nil,
        deliveryState: MessageDeliveryState,
        replyToMessageID: MessageID? = nil,
        replacesMessageID: MessageID? = nil,
        revision: Int = 0,
        expiresAt: Date? = nil,
        attachments: [AttachmentReference] = [],
        reactions: [MessageReaction] = []
    ) {
        self.id = id
        self.conversationID = conversationID
        self.senderID = senderID
        self.direction = direction
        self.content = content
        self.sentAt = sentAt
        self.receivedAt = receivedAt
        self.deliveryState = deliveryState
        self.replyToMessageID = replyToMessageID
        self.replacesMessageID = replacesMessageID
        self.revision = revision
        self.expiresAt = expiresAt
        self.attachments = attachments
        self.reactions = reactions
    }
}

public struct MessageDraft: Hashable, Codable, Sendable {
    public var text: String
    public var replyToMessageID: MessageID?
    public var attachments: [AttachmentReference]
    /// Formatting runs over `text`, in UTF-16 offsets.
    public var textStyles: [TextStyleRange]

    public init(
        text: String,
        replyToMessageID: MessageID? = nil,
        attachments: [AttachmentReference] = [],
        textStyles: [TextStyleRange] = []
    ) {
        self.text = text
        self.replyToMessageID = replyToMessageID
        self.attachments = attachments
        self.textStyles = textStyles
    }

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }
}
