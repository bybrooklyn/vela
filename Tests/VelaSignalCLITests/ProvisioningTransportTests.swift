import Foundation
import Testing
import VelaDomain
import VelaTransport

@testable import VelaSignalCLI

/// Collects the params signal-cli was called with, so tests can assert on the
/// request Vela actually sent rather than only on the reply it got back.
private final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String: JSONValue] = [:]

    func record(_ method: String, _ params: JSONValue) {
        lock.lock()
        calls[method] = params
        lock.unlock()
    }

    func params(for method: String) -> JSONValue? {
        lock.lock()
        defer { lock.unlock() }
        return calls[method]
    }
}

private let linkURI =
    "sgnl://linkdevice?uuid=2isj28DKW5OD8wYep0-B-A%3D%3D&pub_key=BQYLA6Bx387THpcpFK%2BpTC2bF2ZPcSrN1%2FxKHwtFZKUv"

@Suite(.serialized) struct ProvisioningTransportTests {
    @Test func beginReturnsTheDeviceLinkURIForTheQRCode() async throws {
        let peer = try FakeSignalCLIPeer { method, _ in
            method == "startLink"
                ? .success(.object(["deviceLinkUri": .string(linkURI)]))
                : .success(.null)
        }
        defer { peer.stop() }

        let client = JSONRPCClient()
        try await client.connect(socketPath: peer.socketPath)
        defer { Task { await client.disconnect() } }

        let transport = SignalCLIProvisioningTransport(client: client)
        let session = try await transport.begin(deviceName: "Test Mac")

        #expect(session.linkingURI.absoluteString == linkURI)
        // Signal's linking flow has no numeric code; showing one would be a lie.
        #expect(session.verificationCode == nil)
        #expect(session.expiresAt > Date())
    }

    @Test func successfulLinkReportsCompletionWithAccountIdentity() async throws {
        let recorder = CallRecorder()
        let peer = try FakeSignalCLIPeer { method, params in
            recorder.record(method, params)
            switch method {
            case "startLink":
                return .success(.object(["deviceLinkUri": .string(linkURI)]))
            case "finishLink":
                return .success(
                    .object([
                        "number": .string("+15550001111"),
                        "aci": .string("8a1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5d"),
                        "deviceId": .integer(3),
                    ]))
            default:
                return .success(.null)
            }
        }
        defer { peer.stop() }

        let client = JSONRPCClient()
        try await client.connect(socketPath: peer.socketPath)
        defer { Task { await client.disconnect() } }

        let transport = SignalCLIProvisioningTransport(client: client)
        let session = try await transport.begin(deviceName: "Test Mac")

        var events: [ProvisioningEvent] = []
        for await event in await transport.events(sessionID: session.id) {
            events.append(event)
            if case .completed = event { break }
            if case .failed = event { break }
        }

        #expect(events.first == .awaitingScan)
        guard case .completed(let payload) = events.last else {
            Issue.record("Expected completion, got \(String(describing: events.last))")
            return
        }
        #expect(payload.localRecipientID == RecipientID("+15550001111"))
        #expect(payload.deviceID == DeviceID("3"))
        #expect(payload.serviceIdentifier == .aci(UUID(uuidString: "8a1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5d")!))
        #expect(payload.capabilities.contains(.textMessages))

        // The name the user typed must reach the phone's linked-device list.
        #expect(recorder.params(for: "finishLink")?["deviceName"]?.stringValue == "Test Mac")
        #expect(recorder.params(for: "finishLink")?["deviceLinkUri"]?.stringValue == linkURI)
    }

    @Test func identityFallsBackToListAccountsWhenFinishLinkIsSparse() async throws {
        // Older signal-cli builds return an empty finishLink result.
        let peer = try FakeSignalCLIPeer { method, _ in
            switch method {
            case "startLink":
                return .success(.object(["deviceLinkUri": .string(linkURI)]))
            case "finishLink":
                return .success(.object([:]))
            case "listAccounts":
                return .success(.array([.object(["number": .string("+15557778888")])]))
            default:
                return .success(.null)
            }
        }
        defer { peer.stop() }

        let client = JSONRPCClient()
        try await client.connect(socketPath: peer.socketPath)
        defer { Task { await client.disconnect() } }

        let transport = SignalCLIProvisioningTransport(client: client)
        let session = try await transport.begin(deviceName: "Mac")

        var completion: ProvisioningPayload?
        for await event in await transport.events(sessionID: session.id) {
            if case .completed(let payload) = event {
                completion = payload
                break
            }
            if case .failed = event { break }
        }

        #expect(completion?.localRecipientID == RecipientID("+15557778888"))
        #expect(completion?.serviceIdentifier == .opaque("+15557778888"))
    }

    @Test func linkFailureIsReportedWithoutLeakingDetail() async throws {
        let peer = try FakeSignalCLIPeer { method, _ in
            switch method {
            case "startLink":
                return .success(.object(["deviceLinkUri": .string(linkURI)]))
            default:
                return .failure(JSONRPCError(code: -32000, message: "link timed out"))
            }
        }
        defer { peer.stop() }

        let client = JSONRPCClient()
        try await client.connect(socketPath: peer.socketPath)
        defer { Task { await client.disconnect() } }

        let transport = SignalCLIProvisioningTransport(client: client)
        let session = try await transport.begin(deviceName: "Mac")

        var failure: String?
        for await event in await transport.events(sessionID: session.id) {
            if case .failed(let category) = event {
                failure = category
                break
            }
            if case .completed = event { break }
        }

        // A category, not the raw server text.
        #expect(failure == "signal-cli-error--32000")
    }

    @Test func unknownSessionFailsClosed() async throws {
        let peer = try FakeSignalCLIPeer { _, _ in .success(.null) }
        defer { peer.stop() }

        let client = JSONRPCClient()
        try await client.connect(socketPath: peer.socketPath)
        defer { Task { await client.disconnect() } }

        let transport = SignalCLIProvisioningTransport(client: client)
        var events: [ProvisioningEvent] = []
        for await event in await transport.events(sessionID: .random()) {
            events.append(event)
        }
        #expect(events == [.failed(category: "unknown-session")])
    }
}
