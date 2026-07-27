import Foundation
import VelaDomain

public protocol ProvisioningTransport: Sendable {
    /// - Parameter deviceName: shown in the primary device's linked-device list.
    func begin(deviceName: String) async throws -> ProvisioningSession
    func events(sessionID: ProvisioningSessionID) async -> AsyncStream<ProvisioningEvent>
    func cancel(sessionID: ProvisioningSessionID) async
}

public enum ProvisioningTransportError: Error, Sendable, LocalizedError {
    case unknownSession
    case expired
    case productionIntegrationRequired

    public var errorDescription: String? {
        switch self {
        case .unknownSession: "The provisioning session does not exist."
        case .expired: "The provisioning session expired."
        case .productionIntegrationRequired: "The Signal provisioning bridge has not been integrated."
        }
    }
}

public actor DevelopmentProvisioningTransport: ProvisioningTransport {
    private struct SessionState {
        var session: ProvisioningSession
        var continuation: AsyncStream<ProvisioningEvent>.Continuation?
        var pendingEvents: [ProvisioningEvent]
    }

    private var sessions: [ProvisioningSessionID: SessionState] = [:]

    public init() {}

    public func begin(deviceName: String) async throws -> ProvisioningSession {
        let id = ProvisioningSessionID.random()
        guard let uri = URL(string: "vela-development://link-device?session=\(id.rawValue)") else {
            throw ProvisioningTransportError.unknownSession
        }
        let session = ProvisioningSession(
            id: id,
            linkingURI: uri,
            expiresAt: Date().addingTimeInterval(10 * 60),
            verificationCode: String(Int.random(in: 100_000...999_999))
        )
        sessions[id] = SessionState(session: session, continuation: nil, pendingEvents: [.awaitingScan])
        return session
    }

    public func events(sessionID: ProvisioningSessionID) async -> AsyncStream<ProvisioningEvent> {
        guard var state = sessions[sessionID] else {
            return AsyncStream { continuation in
                continuation.yield(.failed(category: "unknown-session"))
                continuation.finish()
            }
        }

        let pair = AsyncStream<ProvisioningEvent>.makeStream(bufferingPolicy: .bufferingNewest(32))
        state.continuation = pair.continuation
        for event in state.pendingEvents {
            pair.continuation.yield(event)
        }
        state.pendingEvents.removeAll(keepingCapacity: true)
        sessions[sessionID] = state
        return pair.stream
    }

    public func cancel(sessionID: ProvisioningSessionID) async {
        emit(.cancelled, sessionID: sessionID, finish: true)
        sessions.removeValue(forKey: sessionID)
    }

    public func completeDevelopmentLink(
        sessionID: ProvisioningSessionID,
        deviceName: String,
        identityHandle: String
    ) throws -> ProvisioningPayload {
        guard let state = sessions[sessionID] else {
            throw ProvisioningTransportError.unknownSession
        }
        guard state.session.expiresAt > Date() else {
            emit(.failed(category: "expired"), sessionID: sessionID, finish: true)
            throw ProvisioningTransportError.expired
        }

        emit(.phoneConnected, sessionID: sessionID)
        emit(.transferringCredentials, sessionID: sessionID)

        let payload = ProvisioningPayload(
            accountID: .random(),
            localRecipientID: .random(),
            deviceID: .random(),
            serviceIdentifier: .aci(UUID()),
            identityHandle: identityHandle,
            capabilities: [.textMessages, .attachments, .reactions, .edits, .deletes, .disappearingMessages]
        )
        emit(.completed(payload), sessionID: sessionID, finish: true)
        return payload
    }

    private func emit(_ event: ProvisioningEvent, sessionID: ProvisioningSessionID, finish: Bool = false) {
        guard var state = sessions[sessionID] else { return }
        if let continuation = state.continuation {
            continuation.yield(event)
            if finish { continuation.finish() }
        } else {
            state.pendingEvents.append(event)
        }
        sessions[sessionID] = state
    }
}

public struct UnavailableSignalProvisioningTransport: ProvisioningTransport {
    public init() {}

    public func begin(deviceName: String) async throws -> ProvisioningSession {
        throw ProvisioningTransportError.productionIntegrationRequired
    }

    public func events(sessionID: ProvisioningSessionID) async -> AsyncStream<ProvisioningEvent> {
        AsyncStream { continuation in
            continuation.yield(.failed(category: "signal-provisioning-bridge-unavailable"))
            continuation.finish()
        }
    }

    public func cancel(sessionID: ProvisioningSessionID) async {}
}
