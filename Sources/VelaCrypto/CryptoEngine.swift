import Foundation
import VelaDomain

public protocol CryptoEngine: Sendable {
    var protection: EnvelopeProtection { get }

    func generateIdentityHandle() async throws -> String

    func seal(
        _ plaintext: Data,
        envelopeID: EnvelopeID,
        source: DeviceAddress,
        destination: DeviceAddress,
        timestamp: Date,
        contentType: EnvelopeContentType
    ) async throws -> EncryptedEnvelope

    func open(_ envelope: EncryptedEnvelope, localAddress: DeviceAddress) async throws -> Data
}

public enum CryptoEngineError: Error, Sendable, LocalizedError {
    case insecureDevelopmentModeDisabled
    case unexpectedProtection(expected: EnvelopeProtection, actual: EnvelopeProtection)
    case invalidDestination
    case adapterUnavailable(String)
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .insecureDevelopmentModeDisabled:
            "The plaintext development crypto engine was used without explicit opt-in."
        case .unexpectedProtection(let expected, let actual):
            "Expected envelope protection \(expected.rawValue), found \(actual.rawValue)."
        case .invalidDestination:
            "The envelope was not addressed to this device."
        case .adapterUnavailable(let detail):
            "The official libsignal adapter is unavailable: \(detail)."
        case .operationFailed(let category):
            "The cryptographic operation failed: \(category)."
        }
    }
}
