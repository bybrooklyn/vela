import Foundation
import VelaDomain

/// A deliberately insecure codec for local UI and pipeline development only.
///
/// It does not encrypt, authenticate, or attempt to emulate Signal Protocol.
/// Production composition roots must never instantiate this type.
public struct DevelopmentPlaintextCryptoEngine: CryptoEngine {
    public let protection: EnvelopeProtection = .developmentPlaintext
    private let explicitOptIn: Bool

    public init(explicitlyAllowInsecurePlaintext: Bool) {
        self.explicitOptIn = explicitlyAllowInsecurePlaintext
    }

    public func generateIdentityHandle() async throws -> String {
        try validateOptIn()
        return "development-identity-\(UUID().uuidString.lowercased())"
    }

    public func seal(
        _ plaintext: Data,
        envelopeID: EnvelopeID,
        source: DeviceAddress,
        destination: DeviceAddress,
        timestamp: Date,
        contentType: EnvelopeContentType
    ) async throws -> EncryptedEnvelope {
        try validateOptIn()
        return EncryptedEnvelope(
            id: envelopeID,
            source: source,
            destination: destination,
            serverTimestamp: timestamp,
            contentType: contentType,
            protection: .developmentPlaintext,
            ciphertext: plaintext
        )
    }

    public func open(_ envelope: EncryptedEnvelope, localAddress: DeviceAddress) async throws -> Data {
        try validateOptIn()
        guard envelope.protection == .developmentPlaintext else {
            throw CryptoEngineError.unexpectedProtection(
                expected: .developmentPlaintext,
                actual: envelope.protection
            )
        }
        guard envelope.destination == localAddress else {
            throw CryptoEngineError.invalidDestination
        }
        return envelope.ciphertext
    }

    private func validateOptIn() throws {
        guard explicitOptIn else {
            throw CryptoEngineError.insecureDevelopmentModeDisabled
        }
    }
}
