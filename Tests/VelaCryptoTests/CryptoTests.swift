import Foundation
import Testing

@testable import VelaCrypto
@testable import VelaDomain

@Suite struct CryptoTests {
    @Test func developmentCryptoRequiresExplicitOptIn() async {
        let crypto = DevelopmentPlaintextCryptoEngine(explicitlyAllowInsecurePlaintext: false)
        do {
            _ = try await crypto.generateIdentityHandle()
            Issue.record("Expected explicit opt-in failure")
        } catch let error as CryptoEngineError {
            guard case .insecureDevelopmentModeDisabled = error else {
                Issue.record("Unexpected crypto error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(type(of: error))")
        }
    }

    @Test func developmentCryptoRejectsWrongDestination() async throws {
        let crypto = DevelopmentPlaintextCryptoEngine(explicitlyAllowInsecurePlaintext: true)
        let envelope = try await crypto.seal(
            Data("payload".utf8),
            envelopeID: "envelope",
            source: DeviceAddress(recipientID: "sender", deviceID: "phone"),
            destination: DeviceAddress(recipientID: "recipient", deviceID: "mac"),
            timestamp: Date(timeIntervalSince1970: 1),
            contentType: .message
        )

        do {
            _ = try await crypto.open(
                envelope,
                localAddress: DeviceAddress(recipientID: "someone-else", deviceID: "mac")
            )
            Issue.record("Expected destination validation failure")
        } catch let error as CryptoEngineError {
            guard case .invalidDestination = error else {
                Issue.record("Unexpected crypto error: \(error)")
                return
            }
        }
    }

    @Test func wireCodecRejectsUnsupportedVersion() throws {
        let encoded = Data(#"{"version":999,"id":"m"}"#.utf8)
        do {
            _ = try WireCodec().decode(encoded)
            Issue.record("Expected unsupported wire version to throw")
        } catch {
            // Expected.
        }
    }
}
