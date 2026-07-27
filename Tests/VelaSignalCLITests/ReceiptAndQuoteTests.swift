import Foundation
import Testing
import VelaCrypto
import VelaDomain

@testable import VelaSignalCLI

@Suite(.serialized) struct ReceiptAndQuoteTests {
    private static let herACI = "11111111-2222-4333-8444-555555555555"
    private static let myACI = "99999999-8888-4777-8666-555555555555"

    private static var account: LinkedAccount {
        LinkedAccount(
            id: AccountID(myACI),
            localRecipientID: RecipientID(myACI),
            deviceID: "3",
            deviceName: "Mac",
            serviceIdentifier: .aci(UUID(uuidString: myACI)!),
            identityHandle: myACI,
            linkedAt: Date()
        )
    }

    private func translate(_ envelope: JSONValue) -> SignalCLIEnvelopeTranslator.Translated? {
        SignalCLIEnvelopeTranslator.translate(
            .object(["envelope": envelope]),
            account: Self.account,
            directory: RecipientDirectory()
        )
    }

    @Test func aReadReceiptNamesTheMessagesItAcknowledges() throws {
        let translated = try #require(
            translate(
                .object([
                    "sourceUuid": .string(Self.herACI),
                    "timestamp": .integer(1_700_000_100_000),
                    "receiptMessage": .object([
                        "isRead": .bool(true),
                        "timestamps": .array([.integer(1_700_000_001_000), .integer(1_700_000_002_000)]),
                    ]),
                ]))
        )

        #expect(translated.wire.kind == .receipt)
        let payload = ControlPayload(wire: translated.wire)
        #expect(payload.detail == "read")
        // Targets resolve to the same IDs incoming messages are stored under.
        #expect(
            payload.targets == [
                MessageID("1700000001000"), MessageID("1700000002000"),
            ])
    }

    @Test func aDeliveryReceiptIsDistinguishedFromARead() throws {
        let delivered = try #require(
            translate(
                .object([
                    "sourceUuid": .string(Self.herACI),
                    "timestamp": .integer(1_700_000_100_000),
                    "receiptMessage": .object([
                        "isDelivery": .bool(true),
                        "timestamps": .array([.integer(1_700_000_001_000)]),
                    ]),
                ]))
        )
        #expect(ControlPayload(wire: delivered.wire).detail == "delivered")
    }

    @Test func typingStartAndStopAreDistinguished() throws {
        func detail(action: String) throws -> String {
            let translated = try #require(
                translate(
                    .object([
                        "sourceUuid": .string(Self.herACI),
                        "timestamp": .integer(1_700_000_200_000),
                        "typingMessage": .object(["action": .string(action)]),
                    ]))
            )
            #expect(translated.wire.kind == .typing)
            return ControlPayload(wire: translated.wire).detail
        }

        #expect(try detail(action: "STARTED") == "started")
        #expect(try detail(action: "STOPPED") == "stopped")
    }

    @Test func receiptStatesOnlyEverMoveForward() {
        // Receipts arrive out of order and are re-sent, so a late `delivered`
        // must not undo a `read`.
        let now = Date()
        #expect(MessageDeliveryState.sent(serverTimestamp: now).receiptRank < MessageDeliveryState.delivered(at: now).receiptRank)
        #expect(MessageDeliveryState.delivered(at: now).receiptRank < MessageDeliveryState.read(at: now).receiptRank)
        #expect(MessageDeliveryState.queued.receiptRank < MessageDeliveryState.sent(serverTimestamp: now).receiptRank)
    }

    @Test func controlPayloadSurvivesARoundTrip() {
        let payload = ControlPayload(detail: "read", targets: ["1700000001000", "1700000002000"])
        #expect(ControlPayload(encoded: payload.encoded) == payload)
        // A typing payload has no targets.
        let typing = ControlPayload(detail: "started")
        #expect(ControlPayload(encoded: typing.encoded) == typing)
    }

    @Test func anIncomingQuoteResolvesToTheMessageItAnswers() throws {
        let translated = try #require(
            translate(
                .object([
                    "sourceUuid": .string(Self.herACI),
                    "timestamp": .integer(1_700_000_300_000),
                    "dataMessage": .object([
                        "timestamp": .integer(1_700_000_300_000),
                        "message": .string("answering that"),
                        "quote": .object([
                            "id": .integer(1_700_000_001_000),
                            "author": .string(Self.myACI),
                        ]),
                    ]),
                ]))
        )

        #expect(translated.wire.replyToMessageID == MessageID("1700000001000"))
    }

    @Test func outgoingQuotesCarryTimestampAndAuthor() async throws {
        let log = QuoteCallLog()
        let peer = try FakeSignalCLIPeer { method, params in
            log.record(method, params)
            return .success(.object(["timestamp": .integer(1_700_000_400_000)]))
        }
        defer { peer.stop() }

        let client = JSONRPCClient()
        try await client.connect(socketPath: peer.socketPath)
        defer { Task { await client.disconnect() } }

        let index = SignalCLIMessageIndex()
        await index.record(
            messageID: "quoted-1",
            signalTimestamp: 1_700_000_001_000,
            author: RecipientID(Self.herACI)
        )
        let transport = SignalCLIServiceTransport(client: client, index: index)
        try await transport.connect(account: Self.account)

        let conversation = ConversationSeed(
            id: .direct(with: RecipientID(Self.herACI)),
            kind: .direct(recipientID: RecipientID(Self.herACI)),
            title: "Her"
        )
        let wire = WireMessage(
            id: "reply-1",
            conversation: conversation,
            senderID: Self.account.localRecipientID,
            recipientID: RecipientID(Self.herACI),
            kind: .text,
            body: "my reply",
            sentAt: Date(),
            replyToMessageID: "quoted-1"
        )
        _ = try await transport.send(
            EncryptedEnvelope(
                id: .random(),
                source: DeviceAddress(recipientID: wire.senderID, deviceID: "signal-cli"),
                destination: DeviceAddress(recipientID: wire.recipientID, deviceID: "signal-cli"),
                serverTimestamp: wire.sentAt,
                contentType: .message,
                protection: .signalCLIBridge,
                ciphertext: try WireCodec().encode(wire)
            )
        )

        let params = try #require(log.params(for: "send"))
        #expect(params["quoteTimestamp"]?.intValue == 1_700_000_001_000)
        #expect(params["quoteAuthor"]?.stringValue == Self.herACI)
    }
}

private final class QuoteCallLog: @unchecked Sendable {
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
