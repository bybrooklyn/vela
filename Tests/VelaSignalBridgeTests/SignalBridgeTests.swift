import Testing

@testable import VelaDomain
@testable import VelaSignalBridge

@Suite struct SignalBridgeTests {
    @Test func unavailableBridgeFailsClosed() async {
        let bridge = UnavailableSignalUpstreamBridge(reason: "not-vendored")
        do {
            try await bridge.connect(
                account: LinkedAccount(
                    id: "account",
                    localRecipientID: "local",
                    deviceID: "mac",
                    deviceName: "Mac",
                    serviceIdentifier: .opaque("local"),
                    identityHandle: "handle",
                    linkedAt: .distantPast
                )
            )
            Issue.record("Unavailable bridge must not connect")
        } catch let error as VelaError {
            guard case .productionIntegrationRequired = error else {
                Issue.record("Unexpected Vela error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(type(of: error))")
        }
    }
}
