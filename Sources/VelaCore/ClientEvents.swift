import Foundation
import VelaDomain

public enum ClientEvent: Hashable, Sendable {
    case snapshotChanged(ClientSnapshot)
    case conversationsChanged
    case messagesChanged(ConversationID)
    case provisioningChanged(ProvisioningEvent)
    case contactsChanged
    /// Ephemeral presence. Never persisted; the UI clears it on a timer.
    case typingChanged(conversationID: ConversationID, senderID: RecipientID, isTyping: Bool)
    case diagnosticsChanged
}

public actor ClientEventHub {
    private var continuations: [UUID: AsyncStream<ClientEvent>.Continuation] = [:]

    public init() {}

    public func stream() -> AsyncStream<ClientEvent> {
        let id = UUID()
        let pair = AsyncStream<ClientEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        continuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.remove(id) }
        }
        return pair.stream
    }

    public func publish(_ event: ClientEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    public func finish() {
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll(keepingCapacity: false)
    }

    private func remove(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
