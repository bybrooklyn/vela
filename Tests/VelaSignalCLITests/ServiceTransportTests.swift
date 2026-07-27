import Foundation
import Testing
import VelaCrypto
import VelaDomain
import VelaTransport

@testable import VelaSignalCLI

/// Records every call so tests can assert on the request Vela sent, not just the
/// reply it got back.
private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(method: String, params: JSONValue)] = []

    func record(_ method: String, _ params: JSONValue) {
        lock.lock()
        calls.append((method, params))
        lock.unlock()
    }

    func params(for method: String) -> JSONValue? {
        lock.lock()
        defer { lock.unlock() }
        return calls.last { $0.method == method }?.params
    }

    var methods: [String] {
        lock.lock()
        defer { lock.unlock() }
        return calls.map(\.method)
    }
}

private let account = LinkedAccount(
    id: "+15550001111",
    localRecipientID: "+15550001111",
    deviceID: "3",
    deviceName: "Mac",
    serviceIdentifier: .opaque("+15550001111"),
    identityHandle: "+15550001111",
    linkedAt: Date()
)

private func makeTransport(
    log: CallLog,
    extra: @escaping @Sendable (String, JSONValue) -> JSONValue? = { _, _ in nil }
) throws -> (FakeSignalCLIPeer, JSONRPCClient, SignalCLIServiceTransport, SignalCLIMessageIndex) {
    let peer = try FakeSignalCLIPeer { method, params in
        log.record(method, params)
        if let custom = extra(method, params) { return .success(custom) }
        switch method {
        case "subscribeReceive": return .success(.integer(1))
        default: return .success(.object(["timestamp": .integer(1_700_000_000_000)]))
        }
    }
    let client = JSONRPCClient()
    let index = SignalCLIMessageIndex()
    let transport = SignalCLIServiceTransport(client: client, index: index)
    return (peer, client, transport, index)
}

private func envelope(for wire: WireMessage) throws -> EncryptedEnvelope {
    EncryptedEnvelope(
        id: .random(),
        source: DeviceAddress(recipientID: wire.senderID, deviceID: "signal-cli"),
        destination: DeviceAddress(recipientID: wire.recipientID, deviceID: "signal-cli"),
        serverTimestamp: wire.sentAt,
        contentType: .message,
        protection: .signalCLIBridge,
        ciphertext: try WireCodec().encode(wire)
    )
}

private func textWire(body: String = "hello") -> WireMessage {
    WireMessage(
        id: "local-1",
        conversation: ConversationSeed(
            id: "c",
            kind: .direct(recipientID: "+15559998888"),
            title: "Remote"
        ),
        senderID: account.localRecipientID,
        recipientID: "+15559998888",
        kind: .text,
        body: body,
        sentAt: Date()
    )
}

@Suite(.serialized) struct ServiceTransportTests {
    @Test func connectingSubscribesForThisAccount() async throws {
        let log = CallLog()
        let (peer, client, transport, _) = try makeTransport(log: log)
        defer { peer.stop() }
        try await client.connect(socketPath: peer.socketPath)
        defer { Task { await client.disconnect() } }

        try await transport.connect(account: account)

        // Without an explicit subscription the multi-account daemon never sends
        // a `receive` notification, and incoming messages are silently lost.
        #expect(log.methods.contains("subscribeReceive"))
        #expect(log.params(for: "subscribeReceive")?["account"]?.stringValue == "+15550001111")
    }

    @Test func sendNamesTheAccountAndRecipient() async throws {
        let log = CallLog()
        let (peer, client, transport, _) = try makeTransport(log: log)
        defer { peer.stop() }
        try await client.connect(socketPath: peer.socketPath)
        defer { Task { await client.disconnect() } }
        try await transport.connect(account: account)

        let receipt = try await transport.send(try envelope(for: textWire()))

        let params = try #require(log.params(for: "send"))
        // The daemon serves several accounts, so an unqualified send is ambiguous.
        #expect(params["account"]?.stringValue == "+15550001111")
        #expect(params["recipient"]?.arrayValue?.first?.stringValue == "+15559998888")
        #expect(params["message"]?.stringValue == "hello")
        #expect(receipt.acceptedAt.timeIntervalSince1970 == 1_700_000_000)
    }

    @Test func noteToSelfAddressesTheLocalAccount() async throws {
        let log = CallLog()
        let (peer, client, transport, _) = try makeTransport(log: log)
        defer { peer.stop() }
        try await client.connect(socketPath: peer.socketPath)
        defer { Task { await client.disconnect() } }
        try await transport.connect(account: account)

        var wire = textWire()
        wire.conversation = ConversationSeed(id: "self", kind: .noteToSelf, title: "Note to Self")
        _ = try await transport.send(try envelope(for: wire))

        #expect(log.params(for: "send")?["recipient"]?.arrayValue?.first?.stringValue == "+15550001111")
    }

    @Test func mutationsUseTheSignalTimestampOfTheirTarget() async throws {
        let log = CallLog()
        let (peer, client, transport, index) = try makeTransport(log: log)
        defer { peer.stop() }
        try await client.connect(socketPath: peer.socketPath)
        defer { Task { await client.disconnect() } }
        try await transport.connect(account: account)

        // Signal identifies a message by when it was sent, so the mapping has to
        // exist before an edit, reaction or delete can be expressed at all.
        await index.record(
            messageID: "target-1",
            signalTimestamp: 1_699_000_000_000,
            author: account.localRecipientID
        )

        var edit = textWire(body: "corrected")
        edit.kind = .edit
        edit.targetMessageID = "target-1"
        _ = try await transport.send(try envelope(for: edit))
        #expect(log.params(for: "send")?["editTimestamp"]?.intValue == 1_699_000_000_000)

        var reaction = textWire(body: "🎉")
        reaction.kind = .reaction
        reaction.targetMessageID = "target-1"
        _ = try await transport.send(try envelope(for: reaction))
        let reactionParams = try #require(log.params(for: "sendReaction"))
        #expect(reactionParams["targetTimestamp"]?.intValue == 1_699_000_000_000)
        #expect(reactionParams["emoji"]?.stringValue == "🎉")
        #expect(reactionParams["remove"]?.boolValue == false)
        #expect(reactionParams["targetAuthor"]?.stringValue == "+15550001111")

        reaction.isReactionRemoval = true
        _ = try await transport.send(try envelope(for: reaction))
        #expect(log.params(for: "sendReaction")?["emoji"]?.stringValue == "🎉")
        #expect(log.params(for: "sendReaction")?["remove"]?.boolValue == true)

        var remove = textWire()
        remove.kind = .delete
        remove.targetMessageID = "target-1"
        _ = try await transport.send(try envelope(for: remove))
        #expect(log.params(for: "remoteDelete")?["targetTimestamp"]?.intValue == 1_699_000_000_000)
    }

    @Test func sendingWithoutConnectingFails() async throws {
        let log = CallLog()
        let (peer, client, transport, _) = try makeTransport(log: log)
        defer { peer.stop() }
        try await client.connect(socketPath: peer.socketPath)
        defer { Task { await client.disconnect() } }

        await #expect(throws: TransportError.notConnected) {
            _ = try await transport.send(try envelope(for: textWire()))
        }
    }

    @Test func incomingMessageBecomesAnEnvelopeForTheExistingPipeline() async throws {
        let log = CallLog()
        let (peer, client, transport, _) = try makeTransport(log: log)
        defer { peer.stop() }
        try await client.connect(socketPath: peer.socketPath)
        defer { Task { await client.disconnect() } }

        let stream = await transport.incomingEnvelopes()
        try await transport.connect(account: account)

        peer.send(
            notification: "receive",
            params: .object([
                "envelope": .object([
                    "sourceNumber": .string("+15559998888"),
                    "timestamp": .integer(1_700_000_111_000),
                    "dataMessage": .object([
                        "timestamp": .integer(1_700_000_111_000),
                        "message": .string("from the other side"),
                    ]),
                ])
            ])
        )

        var iterator = stream.makeAsyncIterator()
        let received = try #require(await iterator.next())
        #expect(received.protection == .signalCLIBridge)
        #expect(received.source.recipientID == RecipientID("+15559998888"))
        #expect(received.destination.recipientID == account.localRecipientID)

        let wire = try WireCodec().decode(received.ciphertext)
        #expect(wire.body == "from the other side")
        // The identifier is the send timestamp, so a later reaction naming that
        // timestamp resolves to this same message.
        #expect(wire.id == MessageID("1700000111000"))
    }

    @Test func socketClosurePublishesDisconnectedState() async throws {
        let log = CallLog()
        let (peer, client, transport, _) = try makeTransport(log: log)
        let states = await transport.connectionStates()
        var iterator = states.makeAsyncIterator()
        #expect(await iterator.next() == .disconnected)

        try await client.connect(socketPath: peer.socketPath)
        try await transport.connect(account: account)
        #expect(await iterator.next() == .connecting)
        #expect(await iterator.next() == .connected)

        peer.stop()
        #expect(await iterator.next() == .disconnected)
    }

    @Test func pendingInboundAttachmentIsDownloadedBeforeDelivery() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vela-attachment-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data("attachment body".utf8)
        let log = CallLog()
        let peer = try FakeSignalCLIPeer { method, params in
            log.record(method, params)
            switch method {
            case "subscribeReceive": return .success(.integer(1))
            case "getAttachment":
                return .success(.object(["data": .string(bytes.base64EncodedString())]))
            default: return .success(.null)
            }
        }
        let client = JSONRPCClient()
        let transport = SignalCLIServiceTransport(
            client: client,
            index: SignalCLIMessageIndex(),
            attachmentDirectory: directory,
            maximumConcurrentAttachmentDownloads: 2
        )
        try await client.connect(socketPath: peer.socketPath)
        defer {
            peer.stop()
            Task { await client.disconnect() }
        }
        let incoming = await transport.incomingEnvelopes()
        try await transport.connect(account: account)

        peer.send(
            notification: "receive",
            params: .object([
                "envelope": .object([
                    "sourceNumber": .string("+15559998888"),
                    "timestamp": .integer(1_700_000_222_000),
                    "dataMessage": .object([
                        "timestamp": .integer(1_700_000_222_000),
                        "attachments": .array([
                            .object([
                                "id": .string("attachment-1"),
                                "filename": .string("note.txt"),
                                "contentType": .string("text/plain"),
                                "size": .integer(Int64(bytes.count)),
                            ])
                        ]),
                    ]),
                ])
            ])
        )

        var iterator = incoming.makeAsyncIterator()
        let envelope = try #require(await iterator.next())
        let wire = try WireCodec().decode(envelope.ciphertext)
        let attachment = try #require(wire.attachments.first)
        guard case .available(let path) = attachment.state else {
            Issue.record("Pending attachment did not become available")
            return
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
        #expect(log.params(for: "getAttachment")?["id"]?.stringValue == "attachment-1")
        #expect(log.params(for: "getAttachment")?["recipient"]?.stringValue == "+15559998888")
    }
}
