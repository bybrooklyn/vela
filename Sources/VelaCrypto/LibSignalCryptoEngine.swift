import Foundation
import VelaDomain

/// Narrow boundary around the official libsignal Swift/Rust implementation.
///
/// The concrete adapter lives in the vendored Signal-iOS integration layer because
/// libsignal's public Swift surface changes with the upstream Signal release. Keeping
/// that churn behind this protocol lets the rest of Vela remain stable and testable.
public protocol LibSignalClientAdapter: Sendable {
    func createIdentityHandle() async throws -> String

    func encrypt(
        plaintext: Data,
        source: DeviceAddress,
        destination: DeviceAddress,
        contentType: EnvelopeContentType
    ) async throws -> Data

    func decrypt(
        ciphertext: Data,
        envelope: EncryptedEnvelope,
        localAddress: DeviceAddress
    ) async throws -> Data
}

public struct LibSignalCryptoEngine: CryptoEngine {
    public let protection: EnvelopeProtection = .libsignal
    private let adapter: any LibSignalClientAdapter

    public init(adapter: any LibSignalClientAdapter) {
        self.adapter = adapter
    }

    public func generateIdentityHandle() async throws -> String {
        do {
            return try await adapter.createIdentityHandle()
        } catch {
            throw CryptoEngineError.operationFailed(Self.redactedCategory(error))
        }
    }

    public func seal(
        _ plaintext: Data,
        envelopeID: EnvelopeID,
        source: DeviceAddress,
        destination: DeviceAddress,
        timestamp: Date,
        contentType: EnvelopeContentType
    ) async throws -> EncryptedEnvelope {
        do {
            let ciphertext = try await adapter.encrypt(
                plaintext: plaintext,
                source: source,
                destination: destination,
                contentType: contentType
            )
            return EncryptedEnvelope(
                id: envelopeID,
                source: source,
                destination: destination,
                serverTimestamp: timestamp,
                contentType: contentType,
                protection: .libsignal,
                ciphertext: ciphertext
            )
        } catch {
            throw CryptoEngineError.operationFailed(Self.redactedCategory(error))
        }
    }

    public func open(_ envelope: EncryptedEnvelope, localAddress: DeviceAddress) async throws -> Data {
        guard envelope.protection == .libsignal else {
            throw CryptoEngineError.unexpectedProtection(expected: .libsignal, actual: envelope.protection)
        }
        guard envelope.destination == localAddress else {
            throw CryptoEngineError.invalidDestination
        }
        do {
            return try await adapter.decrypt(
                ciphertext: envelope.ciphertext,
                envelope: envelope,
                localAddress: localAddress
            )
        } catch {
            throw CryptoEngineError.operationFailed(Self.redactedCategory(error))
        }
    }

    private static func redactedCategory(_ error: any Error) -> String {
        String(reflecting: type(of: error))
    }
}

public struct UnavailableLibSignalClientAdapter: LibSignalClientAdapter {
    private let reason: String

    public init(reason: String = "Vendor Signal-iOS and implement the version-pinned adapter in VelaSignalBridge.") {
        self.reason = reason
    }

    public func createIdentityHandle() async throws -> String {
        throw CryptoEngineError.adapterUnavailable(reason)
    }

    public func encrypt(
        plaintext: Data,
        source: DeviceAddress,
        destination: DeviceAddress,
        contentType: EnvelopeContentType
    ) async throws -> Data {
        throw CryptoEngineError.adapterUnavailable(reason)
    }

    public func decrypt(
        ciphertext: Data,
        envelope: EncryptedEnvelope,
        localAddress: DeviceAddress
    ) async throws -> Data {
        throw CryptoEngineError.adapterUnavailable(reason)
    }
}
