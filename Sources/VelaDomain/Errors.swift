import Foundation

public enum VelaError: Error, Hashable, Codable, Sendable, LocalizedError {
    case notLinked
    case alreadyLinked
    case invalidState(expected: String, actual: String)
    case emptyMessage
    case messageMissing
    case messageNotEditable
    case invalidReaction
    case conversationMissing
    case accountMissing
    case provisioningExpired
    case provisioningCancelled
    case transportUnavailable(String)
    case cryptoUnavailable(String)
    case storageFailure(String)
    case unsupportedMessageVersion(Int)
    case invalidEnvelope(String)
    case productionIntegrationRequired(String)

    public var errorDescription: String? {
        switch self {
        case .notLinked: "This client is not linked to an account."
        case .alreadyLinked: "This client is already linked."
        case .invalidState(let expected, let actual): "Expected state \(expected), found \(actual)."
        case .emptyMessage: "The message has no text or attachments."
        case .messageMissing: "The message does not exist on this device."
        case .messageNotEditable: "This message cannot be edited or deleted."
        case .invalidReaction: "The reaction is empty or too long."
        case .conversationMissing: "The conversation does not exist."
        case .accountMissing: "The linked account is missing."
        case .provisioningExpired: "The provisioning session expired."
        case .provisioningCancelled: "The provisioning session was cancelled."
        case .transportUnavailable(let category): "The transport is unavailable: \(category)."
        case .cryptoUnavailable(let category): "The cryptographic engine is unavailable: \(category)."
        case .storageFailure(let category): "Local storage failed: \(category)."
        case .unsupportedMessageVersion(let version): "Message version \(version) is not supported."
        case .invalidEnvelope(let category): "The incoming envelope is invalid: \(category)."
        case .productionIntegrationRequired(let component): "Production integration is required for \(component)."
        }
    }
}
