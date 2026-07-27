import Foundation
import VelaCrypto
import VelaDomain
import VelaTransport

public struct SignalBridgeManifest: Hashable, Codable, Sendable {
    public var signalIOSCommit: String
    public var libSignalVersion: String
    public var ringRTCVersion: String?
    public var databaseSchemaVersion: Int
    public var generatedAt: Date

    public init(
        signalIOSCommit: String,
        libSignalVersion: String,
        ringRTCVersion: String? = nil,
        databaseSchemaVersion: Int,
        generatedAt: Date
    ) {
        self.signalIOSCommit = signalIOSCommit
        self.libSignalVersion = libSignalVersion
        self.ringRTCVersion = ringRTCVersion
        self.databaseSchemaVersion = databaseSchemaVersion
        self.generatedAt = generatedAt
    }
}

public enum SignalBridgeAvailability: Hashable, Codable, Sendable {
    case unavailable(reason: String)
    case available(manifest: SignalBridgeManifest)
}

/// Contract implemented by the version-pinned adapter target that is generated
/// after Signal-iOS and libsignal are vendored. The main repository intentionally
/// does not guess at unstable upstream APIs.
public protocol SignalUpstreamBridge: LibSignalClientAdapter, ServiceTransport, ProvisioningTransport {
    var availability: SignalBridgeAvailability { get }
}

public struct UnavailableSignalUpstreamBridge: SignalUpstreamBridge {
    public let availability: SignalBridgeAvailability

    public init(reason: String = "Run Scripts/vendor-signal-ios.sh, pin an upstream commit, and implement the generated adapter target.") {
        self.availability = .unavailable(reason: reason)
    }

    public func createIdentityHandle() async throws -> String {
        throw VelaError.productionIntegrationRequired("libsignal identity creation")
    }

    public func encrypt(
        plaintext: Data,
        source: DeviceAddress,
        destination: DeviceAddress,
        contentType: EnvelopeContentType
    ) async throws -> Data {
        throw VelaError.productionIntegrationRequired("libsignal encryption")
    }

    public func decrypt(
        ciphertext: Data,
        envelope: EncryptedEnvelope,
        localAddress: DeviceAddress
    ) async throws -> Data {
        throw VelaError.productionIntegrationRequired("libsignal decryption")
    }

    public func connect(account: LinkedAccount) async throws {
        throw VelaError.productionIntegrationRequired("Signal authenticated service transport")
    }

    public func disconnect(reason: OfflineReason) async {}

    public func connectionStates() async -> AsyncStream<TransportConnectionState> {
        AsyncStream { continuation in
            continuation.yield(.failed(category: "signal-upstream-bridge-unavailable"))
            continuation.finish()
        }
    }

    public func incomingEnvelopes() async -> AsyncStream<EncryptedEnvelope> {
        AsyncStream { continuation in continuation.finish() }
    }

    public func send(_ envelope: EncryptedEnvelope) async throws -> TransportSendReceipt {
        throw VelaError.productionIntegrationRequired("Signal message submission")
    }

    public func begin(deviceName: String) async throws -> ProvisioningSession {
        throw VelaError.productionIntegrationRequired("Signal linked-device provisioning")
    }

    public func events(sessionID: ProvisioningSessionID) async -> AsyncStream<ProvisioningEvent> {
        AsyncStream { continuation in
            continuation.yield(.failed(category: "signal-upstream-bridge-unavailable"))
            continuation.finish()
        }
    }

    public func cancel(sessionID: ProvisioningSessionID) async {}
}
