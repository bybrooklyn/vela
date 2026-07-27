import Foundation

public enum EnvelopeContentType: String, Hashable, Codable, Sendable {
    case message
    case receipt
    case typing
    case sync
    case provisioning
    case unknown
}

public enum EnvelopeProtection: String, Hashable, Codable, Sendable {
    case libsignal
    case developmentPlaintext
    /// The envelope is a transport-local container and Vela did not encrypt it.
    /// Real end-to-end encryption happens downstream inside signal-cli, which
    /// owns the libsignal session state. Kept distinct from `libsignal` so this
    /// never claims protection Vela did not apply.
    case signalCLIBridge
}

public struct EncryptedEnvelope: Identifiable, Hashable, Codable, Sendable {
    public var id: EnvelopeID
    public var source: DeviceAddress
    public var destination: DeviceAddress
    public var serverTimestamp: Date
    public var contentType: EnvelopeContentType
    public var protection: EnvelopeProtection
    public var ciphertext: Data

    public init(
        id: EnvelopeID,
        source: DeviceAddress,
        destination: DeviceAddress,
        serverTimestamp: Date,
        contentType: EnvelopeContentType,
        protection: EnvelopeProtection,
        ciphertext: Data
    ) {
        self.id = id
        self.source = source
        self.destination = destination
        self.serverTimestamp = serverTimestamp
        self.contentType = contentType
        self.protection = protection
        self.ciphertext = ciphertext
    }
}

public enum WireMessageKind: String, Hashable, Codable, Sendable {
    case text
    case edit
    case delete
    case receipt
    case typing
    case reaction
    /// Signal reporting that a conversation's disappearing-message timer changed.
    /// This is conversation metadata, not a timeline message.
    case expirationUpdate
    /// Our own account reporting, from another device, that it has read
    /// something. Distinct from `receipt`, which is somebody else telling us
    /// they read ours.
    case readSync
    case unsupported
}

public struct WireMessage: Hashable, Codable, Sendable {
    public var version: Int
    public var id: MessageID
    public var conversation: ConversationSeed
    public var senderID: RecipientID
    public var recipientID: RecipientID
    public var kind: WireMessageKind
    public var body: String?
    public var sentAt: Date
    public var replyToMessageID: MessageID?
    public var targetMessageID: MessageID?
    /// True when a reaction control removes the named emoji. Optional so wire
    /// messages encoded before explicit reaction removal continue to decode.
    public var isReactionRemoval: Bool?
    public var revision: Int
    public var expiresAt: Date?
    /// Relative disappearing-message lifetime. Signal supplies a duration,
    /// while `expiresAt` remains available for callers that know the absolute
    /// deadline. Optional so older encoded messages continue to decode.
    public var expiresIn: TimeInterval?
    public var attachments: [AttachmentReference]
    /// Formatting runs over `body`, in UTF-16 offsets.
    public var textStyles: [TextStyleRange]

    public init(
        version: Int = 1,
        id: MessageID,
        conversation: ConversationSeed,
        senderID: RecipientID,
        recipientID: RecipientID,
        kind: WireMessageKind,
        body: String? = nil,
        sentAt: Date,
        replyToMessageID: MessageID? = nil,
        targetMessageID: MessageID? = nil,
        isReactionRemoval: Bool? = nil,
        revision: Int = 0,
        expiresAt: Date? = nil,
        expiresIn: TimeInterval? = nil,
        attachments: [AttachmentReference] = [],
        textStyles: [TextStyleRange] = []
    ) {
        self.version = version
        self.id = id
        self.conversation = conversation
        self.senderID = senderID
        self.recipientID = recipientID
        self.kind = kind
        self.body = body
        self.sentAt = sentAt
        self.replyToMessageID = replyToMessageID
        self.targetMessageID = targetMessageID
        self.isReactionRemoval = isReactionRemoval
        self.revision = revision
        self.expiresAt = expiresAt
        self.expiresIn = expiresIn
        self.attachments = attachments
        self.textStyles = textStyles
    }
}

public struct OutboxItem: Identifiable, Hashable, Codable, Sendable {
    public var id: MessageID { messageID }
    public var messageID: MessageID
    public var destination: DeviceAddress
    public var plaintextPayload: Data
    public var createdAt: Date
    public var nextAttemptAt: Date
    public var attemptCount: Int
    public var lastFailureCategory: String?
    /// Present for an optimistic edit, delete, or reaction whose outbox row has
    /// a different ID from the visible message it changes.
    public var mutationTargetID: MessageID?
    /// Snapshot restored if the mutation can never be delivered. Optional for
    /// backward-compatible decoding of outbox rows written before rollback was
    /// supported.
    public var rollbackTarget: ChatMessage?

    public init(
        messageID: MessageID,
        destination: DeviceAddress,
        plaintextPayload: Data,
        createdAt: Date,
        nextAttemptAt: Date,
        attemptCount: Int = 0,
        lastFailureCategory: String? = nil,
        mutationTargetID: MessageID? = nil,
        rollbackTarget: ChatMessage? = nil
    ) {
        self.messageID = messageID
        self.destination = destination
        self.plaintextPayload = plaintextPayload
        self.createdAt = createdAt
        self.nextAttemptAt = nextAttemptAt
        self.attemptCount = attemptCount
        self.lastFailureCategory = lastFailureCategory
        self.mutationTargetID = mutationTargetID
        self.rollbackTarget = rollbackTarget
    }
}
