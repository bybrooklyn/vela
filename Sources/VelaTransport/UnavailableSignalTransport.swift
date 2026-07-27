import Foundation
import VelaDomain

/// Fail-closed transport used when the upstream Signal-iOS service bridge has not
/// been compiled into the app. It intentionally performs no network requests.
public struct UnavailableSignalTransport: ServiceTransport {
    public init() {}

    public func connect(account: LinkedAccount) async throws {
        throw TransportError.productionIntegrationRequired
    }

    public func disconnect(reason: OfflineReason) async {}

    public func connectionStates() async -> AsyncStream<TransportConnectionState> {
        AsyncStream { continuation in
            continuation.yield(.failed(category: "signal-bridge-unavailable"))
            continuation.finish()
        }
    }

    public func incomingEnvelopes() async -> AsyncStream<EncryptedEnvelope> {
        AsyncStream { continuation in continuation.finish() }
    }

    public func send(_ envelope: EncryptedEnvelope) async throws -> TransportSendReceipt {
        throw TransportError.productionIntegrationRequired
    }
}
