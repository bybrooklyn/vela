import Foundation
import VelaDomain

public enum InitialCallMedia: String, Hashable, Codable, Sendable {
    case audio
    case video
}

public enum CallState: Hashable, Codable, Sendable {
    case idle
    case outgoingRinging
    case incomingRinging
    case connecting
    case connected
    case reconnecting
    case ended(reason: String)
}

public struct CallSession: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var conversationID: ConversationID
    public var media: InitialCallMedia
    public var state: CallState
    public var startedAt: Date

    public init(
        id: UUID = UUID(),
        conversationID: ConversationID,
        media: InitialCallMedia,
        state: CallState,
        startedAt: Date
    ) {
        self.id = id
        self.conversationID = conversationID
        self.media = media
        self.state = state
        self.startedAt = startedAt
    }
}

public protocol CallEngine: Sendable {
    func startOutgoingCall(to conversationID: ConversationID, media: InitialCallMedia) async throws -> CallSession
    func answer(callID: UUID) async throws
    func decline(callID: UUID) async
    func hangUp(callID: UUID) async
    func sessions() async -> AsyncStream<CallSession>
}

public struct UnavailableCallEngine: CallEngine {
    public init() {}

    public func startOutgoingCall(to conversationID: ConversationID, media: InitialCallMedia) async throws -> CallSession {
        throw VelaError.productionIntegrationRequired("native macOS RingRTC")
    }

    public func answer(callID: UUID) async throws {
        throw VelaError.productionIntegrationRequired("native macOS RingRTC")
    }

    public func decline(callID: UUID) async {}
    public func hangUp(callID: UUID) async {}

    public func sessions() async -> AsyncStream<CallSession> {
        AsyncStream { continuation in continuation.finish() }
    }
}
