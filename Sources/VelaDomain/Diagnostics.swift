import Foundation

public struct StoreStatistics: Hashable, Codable, Sendable {
    public var accountCount: Int
    public var conversationCount: Int
    public var messageCount: Int
    public var pendingOutboxCount: Int
    public var seenEnvelopeCount: Int

    public init(
        accountCount: Int,
        conversationCount: Int,
        messageCount: Int,
        pendingOutboxCount: Int,
        seenEnvelopeCount: Int
    ) {
        self.accountCount = accountCount
        self.conversationCount = conversationCount
        self.messageCount = messageCount
        self.pendingOutboxCount = pendingOutboxCount
        self.seenEnvelopeCount = seenEnvelopeCount
    }
}

public struct DiagnosticEvent: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var subsystem: String
    public var category: String
    public var detail: String

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        subsystem: String,
        category: String,
        detail: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.subsystem = subsystem
        self.category = category
        self.detail = detail
    }
}

public enum Redaction {
    public static func identifier(_ value: String) -> String {
        guard value.count > 8 else { return "<redacted>" }
        return "\(value.prefix(4))…\(value.suffix(4))"
    }

    public static func messageBody(_ value: String?) -> String {
        guard let value else { return "<none>" }
        return "<redacted:\(value.utf8.count)-bytes>"
    }

    public static func fileName(_ value: String?) -> String {
        value == nil ? "<none>" : "<redacted-filename>"
    }
}
