import Foundation
import VelaDomain

public struct TransportSendReceipt: Hashable, Codable, Sendable {
    public var envelopeID: EnvelopeID
    public var acceptedAt: Date

    public init(envelopeID: EnvelopeID, acceptedAt: Date) {
        self.envelopeID = envelopeID
        self.acceptedAt = acceptedAt
    }
}

public protocol ServiceTransport: Sendable {
    func connect(account: LinkedAccount) async throws
    func disconnect(reason: OfflineReason) async
    func connectionStates() async -> AsyncStream<TransportConnectionState>
    func incomingEnvelopes() async -> AsyncStream<EncryptedEnvelope>
    func send(_ envelope: EncryptedEnvelope) async throws -> TransportSendReceipt
}

public enum TransportError: Error, Sendable, LocalizedError {
    case notConnected
    case authenticationRejected
    case serviceUnavailable
    case intentionallyInjectedFailure
    case productionIntegrationRequired

    public var errorDescription: String? {
        switch self {
        case .notConnected: "The transport is not connected."
        case .authenticationRejected: "The service rejected this linked device."
        case .serviceUnavailable: "The service is unavailable."
        case .intentionallyInjectedFailure: "A development failure was injected."
        case .productionIntegrationRequired: "A version-pinned Signal service transport must be provided by VelaSignalBridge."
        }
    }
}
