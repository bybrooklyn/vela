import VelaDomain

public protocol IncomingMessageNotificationSink: Sendable {
    func notifyIncoming(messageID: MessageID, conversationID: ConversationID) async
}

public struct NullIncomingMessageNotificationSink: IncomingMessageNotificationSink {
    public init() {}
    public func notifyIncoming(messageID: MessageID, conversationID: ConversationID) async {}
}
