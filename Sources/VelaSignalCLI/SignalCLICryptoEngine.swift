import Foundation
import VelaCore
import VelaCrypto
import VelaDomain

/// A deliberate pass-through `CryptoEngine` for the signal-cli backend.
///
/// **This engine performs no encryption.** signal-cli owns the libsignal session
/// state and encrypts on the wire, so by the time a payload reaches Vela it is
/// already plaintext, and anything Vela sends is encrypted downstream. Vela's
/// envelope is therefore a local container used to reuse the existing outbox,
/// replay-suppression and mutation pipeline — not a security boundary.
///
/// It reports `protection == .signalCLIBridge` rather than `.libsignal` so no
/// part of the system can mistake a container for a sealed envelope.
public struct SignalCLICryptoEngine: CryptoEngine {
    public let protection: EnvelopeProtection = .signalCLIBridge

    public init() {}

    public func generateIdentityHandle() async throws -> String {
        // Identity keys live inside signal-cli; Vela never holds one.
        UUID().uuidString.lowercased()
    }

    public func seal(
        _ plaintext: Data,
        envelopeID: EnvelopeID,
        source: DeviceAddress,
        destination: DeviceAddress,
        timestamp: Date,
        contentType: EnvelopeContentType
    ) async throws -> EncryptedEnvelope {
        EncryptedEnvelope(
            id: envelopeID,
            source: source,
            destination: destination,
            serverTimestamp: timestamp,
            contentType: contentType,
            protection: protection,
            ciphertext: plaintext
        )
    }

    public func open(_ envelope: EncryptedEnvelope, localAddress: DeviceAddress) async throws -> Data {
        guard envelope.protection == protection else {
            throw CryptoEngineError.unexpectedProtection(
                expected: protection,
                actual: envelope.protection
            )
        }
        guard envelope.destination.recipientID == localAddress.recipientID else {
            throw CryptoEngineError.invalidDestination
        }
        return envelope.ciphertext
    }
}

/// Resolves a conversation to the recipient signal-cli should address.
///
/// `RecipientID.rawValue` carries an E.164 number or ACI UUID — whatever
/// signal-cli reported at link time. Device fan-out is signal-cli's job, so the
/// device component is a fixed marker rather than a real device identifier.
public actor SignalCLIRecipientRouter: RecipientRouter {
    public static let backendDeviceID = DeviceID("signal-cli")

    /// Unknown until linking completes, so it is set afterwards rather than
    /// injected at construction.
    private var localRecipientID: RecipientID?

    public init(localRecipientID: RecipientID? = nil) {
        self.localRecipientID = localRecipientID
    }

    public func adopt(localRecipientID: RecipientID) {
        self.localRecipientID = localRecipientID
    }

    public func destination(for conversation: ConversationSeed) async throws -> DeviceAddress {
        switch conversation.kind {
        case .direct(let recipientID):
            return DeviceAddress(recipientID: recipientID, deviceID: Self.backendDeviceID)
        case .group(let groupID, _):
            // Groups address the group itself; signal-cli expands membership.
            return DeviceAddress(recipientID: RecipientID(groupID), deviceID: Self.backendDeviceID)
        case .noteToSelf:
            guard let localRecipientID else { throw VelaError.notLinked }
            return DeviceAddress(recipientID: localRecipientID, deviceID: Self.backendDeviceID)
        }
    }
}
