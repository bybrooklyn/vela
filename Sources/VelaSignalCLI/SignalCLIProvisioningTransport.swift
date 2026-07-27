import Foundation
import VelaDomain
import VelaTransport

/// Links this Mac as a Signal secondary device by driving signal-cli's
/// `startLink` / `finishLink` pair.
///
/// `startLink` returns the real `sgnl://linkdevice?uuid=…&pub_key=…` URI that the
/// phone's camera expects. `finishLink` then blocks — potentially for minutes —
/// until the user scans it and approves on the phone, so it runs in a detached
/// task and reports progress through the event stream.
public actor SignalCLIProvisioningTransport: ProvisioningTransport {
    private struct Session {
        var deviceLinkURI: String
        var deviceName: String
        var task: Task<Void, Never>?
    }

    private let client: JSONRPCClient
    private let sessionLifetime: TimeInterval
    private var sessions: [ProvisioningSessionID: Session] = [:]

    public init(client: JSONRPCClient, sessionLifetime: TimeInterval = 10 * 60) {
        self.client = client
        self.sessionLifetime = sessionLifetime
    }

    public func begin(deviceName: String) async throws -> ProvisioningSession {
        let result = try await client.call("startLink")
        guard
            let uriText = result["deviceLinkUri"]?.stringValue,
            let uri = URL(string: uriText)
        else {
            throw ProvisioningTransportError.productionIntegrationRequired
        }

        let trimmedName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = ProvisioningSessionID.random()
        sessions[id] = Session(
            deviceLinkURI: uriText,
            deviceName: trimmedName.isEmpty ? "Mac" : trimmedName,
            task: nil
        )
        return ProvisioningSession(
            id: id,
            linkingURI: uri,
            expiresAt: Date().addingTimeInterval(sessionLifetime),
            // Signal's linking flow has no numeric code; the QR carries the key.
            verificationCode: nil
        )
    }

    public func events(sessionID: ProvisioningSessionID) async -> AsyncStream<ProvisioningEvent> {
        guard let session = sessions[sessionID] else {
            return AsyncStream { continuation in
                continuation.yield(.failed(category: "unknown-session"))
                continuation.finish()
            }
        }

        let (stream, continuation) = AsyncStream<ProvisioningEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        continuation.yield(.awaitingScan)

        let client = self.client
        let deviceName = session.deviceName
        let uri = session.deviceLinkURI
        let task = Task { [weak self] in
            do {
                let result = try await client.call(
                    "finishLink",
                    params: .object([
                        "deviceLinkUri": .string(uri),
                        "deviceName": .string(deviceName),
                    ])
                )
                guard !Task.isCancelled else {
                    continuation.yield(.cancelled)
                    continuation.finish()
                    return
                }
                continuation.yield(.phoneConnected)
                continuation.yield(.transferringCredentials)

                let payload = try await Self.payload(from: result, client: client)
                continuation.yield(.completed(payload))
                continuation.finish()
            } catch is CancellationError {
                continuation.yield(.cancelled)
                continuation.finish()
            } catch {
                continuation.yield(.failed(category: Self.category(for: error)))
                continuation.finish()
            }
            await self?.clear(sessionID: sessionID)
        }

        sessions[sessionID]?.task = task
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func cancel(sessionID: ProvisioningSessionID) async {
        sessions[sessionID]?.task?.cancel()
        sessions.removeValue(forKey: sessionID)
    }

    private func clear(sessionID: ProvisioningSessionID) {
        sessions.removeValue(forKey: sessionID)
    }

    /// Builds the domain payload from whatever `finishLink` reported, falling
    /// back to `listAccounts` when the result is sparse. signal-cli's response
    /// shape has varied across releases, so several field names are accepted.
    private static func payload(
        from result: JSONValue,
        client: JSONRPCClient
    ) async throws -> ProvisioningPayload {
        var number = result["number"]?.stringValue ?? result["account"]?.stringValue
        var aci = result["aci"]?.stringValue ?? result["uuid"]?.stringValue

        if number == nil || aci == nil {
            if let accounts = try? await client.call("listAccounts"),
                let first = accounts.arrayValue?.first
            {
                number = number ?? first["number"]?.stringValue ?? first["account"]?.stringValue
                aci = aci ?? first["aci"]?.stringValue ?? first["uuid"]?.stringValue
            }
        }

        // The account identifier signal-cli expects back on every later call is
        // the E.164 number, so it is what Vela stores as the recipient identity.
        guard let account = number ?? aci else {
            throw ProvisioningTransportError.productionIntegrationRequired
        }

        let service: ServiceIdentifier =
            if let aci, let uuid = UUID(uuidString: aci) {
                .aci(uuid)
            } else {
                .opaque(account)
            }

        return ProvisioningPayload(
            accountID: AccountID(account),
            localRecipientID: RecipientID(account),
            deviceID: DeviceID(String(result["deviceId"]?.intValue ?? 0)),
            serviceIdentifier: service,
            identityHandle: aci ?? account,
            capabilities: [
                .textMessages, .attachments, .reactions, .edits, .deletes, .disappearingMessages,
            ]
        )
    }

    private static func category(for error: any Error) -> String {
        if let rpc = error as? JSONRPCError { return "signal-cli-error-\(rpc.code)" }
        if error is SocketError { return "backend-unreachable" }
        return "link-failed"
    }
}
