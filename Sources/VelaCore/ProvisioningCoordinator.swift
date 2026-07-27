import Foundation
import VelaCrypto
import VelaDomain
import VelaStorage
import VelaTransport

public actor ProvisioningCoordinator {
    private let transport: any ProvisioningTransport
    private let crypto: any CryptoEngine
    private let store: any ClientStore
    private let clock: any VelaClock
    private let events: ClientEventHub
    private let diagnostics: DiagnosticsRecorder
    private var task: Task<Void, Never>?

    public init(
        transport: any ProvisioningTransport,
        crypto: any CryptoEngine,
        store: any ClientStore,
        clock: any VelaClock = SystemVelaClock(),
        events: ClientEventHub,
        diagnostics: DiagnosticsRecorder
    ) {
        self.transport = transport
        self.crypto = crypto
        self.store = store
        self.clock = clock
        self.events = events
        self.diagnostics = diagnostics
    }

    public func begin(deviceName: String) async throws -> ProvisioningSession {
        task?.cancel()
        let session = try await transport.begin(deviceName: deviceName)
        task = Task { [weak self] in
            await self?.observe(session: session, deviceName: deviceName)
        }
        return session
    }

    public func cancel(sessionID: ProvisioningSessionID) async {
        task?.cancel()
        task = nil
        await transport.cancel(sessionID: sessionID)
    }

    private func observe(session: ProvisioningSession, deviceName: String) async {
        let stream = await transport.events(sessionID: session.id)
        for await event in stream {
            guard !Task.isCancelled else { break }
            switch event {
            case .completed(let payload):
                let account = LinkedAccount(
                    id: payload.accountID,
                    localRecipientID: payload.localRecipientID,
                    deviceID: payload.deviceID,
                    deviceName: deviceName,
                    serviceIdentifier: payload.serviceIdentifier,
                    identityHandle: payload.identityHandle,
                    linkedAt: clock.now,
                    capabilities: payload.capabilities
                )
                do {
                    try await store.saveLinkedAccount(account)
                    await events.publish(.provisioningChanged(event))
                } catch {
                    await diagnostics.record(
                        subsystem: "provisioning",
                        category: "save-account-failed",
                        detail: DiagnosticsRecorder.errorCategory(error),
                        at: clock.now
                    )
                    await events.publish(.diagnosticsChanged)
                    await events.publish(.provisioningChanged(.failed(category: "local-account-save-failed")))
                }
                return
            case .failed, .cancelled:
                await events.publish(.provisioningChanged(event))
                return
            default:
                await events.publish(.provisioningChanged(event))
                continue
            }
        }
    }
}
