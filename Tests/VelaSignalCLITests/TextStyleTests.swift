import Foundation
import Testing
import VelaCrypto
import VelaDomain

@testable import VelaSignalCLI

/// Formatting is expressed as offsets, so the UTF-16 boundary is where it
/// silently breaks: Swift indexes by grapheme, Signal by UTF-16 code unit, and
/// they diverge the moment an emoji appears.
@Suite(.serialized) struct TextStyleTests {
    @Test func rangesAreUTF16NotCharacterOffsets() throws {
        // "👋" is one Character but two UTF-16 code units.
        let body = "👋 hello"
        #expect(body.count == 7)
        #expect((body as NSString).length == 8)

        // Bold "hello", which starts at UTF-16 offset 3.
        let style = TextStyleRange(start: 3, length: 5, style: .bold)
        let range = try #require(style.range(in: body))
        #expect(String(body[range]) == "hello")
    }

    @Test func rangesSurviveCombiningCharacters() throws {
        let body = "café ☕️ done"
        let nsLength = (body as NSString).length
        // Style the trailing word, computed the way an NSTextView reports it.
        let location = (body as NSString).range(of: "done").location
        let style = TextStyleRange(start: location, length: 4, style: .italic)
        let range = try #require(style.range(in: body))
        #expect(String(body[range]) == "done")
        #expect(style.clamped(toUTF16Length: nsLength) != nil)
    }

    @Test func outOfBoundsRangesAreClampedOrDropped() {
        // Ranges arrive from the network and cannot be trusted to fit.
        #expect(TextStyleRange(start: 0, length: 100, style: .bold).clamped(toUTF16Length: 5)?.length == 5)
        #expect(TextStyleRange(start: 9, length: 2, style: .bold).clamped(toUTF16Length: 5) == nil)
        #expect(TextStyleRange(start: 0, length: 0, style: .bold).clamped(toUTF16Length: 5) == nil)
    }

    @Test func adjacentRunsOfTheSameStyleMerge() {
        let merged = [
            TextStyleRange(start: 0, length: 3, style: .bold),
            TextStyleRange(start: 3, length: 4, style: .bold),
        ].normalized(forUTF16Length: 20)

        #expect(merged.count == 1)
        #expect(merged[0].start == 0)
        #expect(merged[0].length == 7)
    }

    @Test func differentStylesOverlapWithoutMerging() {
        let normalized = [
            TextStyleRange(start: 0, length: 5, style: .bold),
            TextStyleRange(start: 2, length: 5, style: .italic),
        ].normalized(forUTF16Length: 20)

        #expect(normalized.count == 2)
        #expect(Set(normalized.map(\.style)) == [.bold, .italic])
    }

    @Test func commandArgumentMatchesSignalCLISyntax() {
        // signal-cli documents `--text-style start:length:STYLE`.
        #expect(TextStyleRange(start: 10, length: 3, style: .bold).commandArgument == "10:3:BOLD")
        #expect(TextStyleRange(start: 0, length: 1, style: .spoiler).commandArgument == "0:1:SPOILER")
        #expect(
            TextStyleRange(start: 4, length: 2, style: .strikethrough).commandArgument == "4:2:STRIKETHROUGH")
    }

    @Test func inboundStylesDecodeFromAReceiveNotification() throws {
        let account = LinkedAccount(
            id: "acct",
            localRecipientID: "me",
            deviceID: "1",
            deviceName: "Mac",
            serviceIdentifier: .opaque("me"),
            identityHandle: "me",
            linkedAt: Date()
        )
        let translated = try #require(
            SignalCLIEnvelopeTranslator.translate(
                .object([
                    "envelope": .object([
                        "sourceNumber": .string("+15550001111"),
                        "timestamp": .integer(1_700_000_000_000),
                        "dataMessage": .object([
                            "timestamp": .integer(1_700_000_000_000),
                            "message": .string("hello world"),
                            "textStyles": .array([
                                .object(["start": .integer(0), "length": .integer(5), "style": .string("BOLD")]),
                                .object([
                                    "start": .integer(6), "length": .integer(5), "style": .string("SPOILER"),
                                ]),
                            ]),
                        ]),
                    ])
                ]),
                account: account,
                directory: RecipientDirectory()
            )
        )

        let styles = translated.wire.textStyles
        #expect(styles.count == 2)
        #expect(styles.contains(TextStyleRange(start: 0, length: 5, style: .bold)))
        #expect(styles.contains(TextStyleRange(start: 6, length: 5, style: .spoiler)))
    }

    @Test func unknownStyleNamesAreIgnoredRatherThanFailingTheMessage() throws {
        let account = LinkedAccount(
            id: "acct",
            localRecipientID: "me",
            deviceID: "1",
            deviceName: "Mac",
            serviceIdentifier: .opaque("me"),
            identityHandle: "me",
            linkedAt: Date()
        )
        let translated = try #require(
            SignalCLIEnvelopeTranslator.translate(
                .object([
                    "envelope": .object([
                        "sourceNumber": .string("+15550001111"),
                        "timestamp": .integer(1_700_000_000_000),
                        "dataMessage": .object([
                            "timestamp": .integer(1_700_000_000_000),
                            "message": .string("hello"),
                            "textStyles": .array([
                                .object([
                                    "start": .integer(0), "length": .integer(5),
                                    "style": .string("RAINBOW"),
                                ])
                            ]),
                        ]),
                    ])
                ]),
                account: account,
                directory: RecipientDirectory()
            )
        )

        // The message still arrives; only the unrecognised run is dropped.
        #expect(translated.wire.body == "hello")
        #expect(translated.wire.textStyles.isEmpty)
    }

    @Test func outboundStylesBecomeTextStyleParameters() async throws {
        let log = StyleCallLog()
        let peer = try FakeSignalCLIPeer { method, params in
            log.record(method, params)
            return .success(.object(["timestamp": .integer(1_700_000_000_000)]))
        }
        defer { peer.stop() }

        let client = JSONRPCClient()
        try await client.connect(socketPath: peer.socketPath)
        defer { Task { await client.disconnect() } }

        let account = LinkedAccount(
            id: "acct",
            localRecipientID: "+15550001111",
            deviceID: "1",
            deviceName: "Mac",
            serviceIdentifier: .opaque("+15550001111"),
            identityHandle: "me",
            linkedAt: Date()
        )
        let transport = SignalCLIServiceTransport(client: client, index: SignalCLIMessageIndex())
        try await transport.connect(account: account)

        let conversation = ConversationSeed(
            id: .direct(with: "+15559998888"),
            kind: .direct(recipientID: "+15559998888"),
            title: "Them"
        )
        let wire = WireMessage(
            id: "m1",
            conversation: conversation,
            senderID: account.localRecipientID,
            recipientID: "+15559998888",
            kind: .text,
            body: "hello world",
            sentAt: Date(),
            textStyles: [
                TextStyleRange(start: 0, length: 5, style: .bold),
                TextStyleRange(start: 6, length: 5, style: .spoiler),
            ]
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
        let sent = try #require(params["textStyle"]?.arrayValue).compactMap(\.stringValue)
        #expect(sent.contains("0:5:BOLD"))
        #expect(sent.contains("6:5:SPOILER"))
    }
}

private final class StyleCallLog: @unchecked Sendable {
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
