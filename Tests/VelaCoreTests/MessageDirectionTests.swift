import Foundation
import Testing

@testable import VelaCore
@testable import VelaCrypto
@testable import VelaDomain
@testable import VelaStorage
@testable import VelaTransport

/// Counts alerts so the tests can assert that your own messages stay silent.
private actor NotificationSpy: IncomingMessageNotificationSink {
    private(set) var count = 0

    func notifyIncoming(messageID: MessageID, conversationID: ConversationID) async {
        count += 1
    }
}

/// Regression tests for messages this account sent on another device. Signal
/// syncs them back to every linked device, and treating them as inbound made
/// them render as if the other person had sent them.
@Suite(.serialized) struct MessageDirectionTests {
    private static let me: RecipientID = "me"
    private static let them: RecipientID = "them"

    private static var account: LinkedAccount {
        LinkedAccount(
            id: "account",
            localRecipientID: me,
            deviceID: "mac",
            deviceName: "Mac",
            serviceIdentifier: .opaque("me"),
            identityHandle: "dev",
            linkedAt: Date()
        )
    }

    private static let conversation = ConversationSeed(
        id: .direct(with: them),
        kind: .direct(recipientID: them),
        title: "Them"
    )

    /// Builds an envelope the way the signal-cli transport does.
    private func envelope(
        from sender: RecipientID,
        to recipient: RecipientID,
        body: String,
        id: EnvelopeID,
        crypto: DevelopmentPlaintextCryptoEngine
    ) async throws -> EncryptedEnvelope {
        let wire = WireMessage(
            id: MessageID(id.rawValue),
            conversation: Self.conversation,
            senderID: sender,
            recipientID: recipient,
            kind: .text,
            body: body,
            sentAt: Date()
        )
        return try await crypto.seal(
            try WireCodec().encode(wire),
            envelopeID: id,
            source: DeviceAddress(recipientID: sender, deviceID: "phone"),
            destination: DeviceAddress(recipientID: Self.me, deviceID: "mac"),
            timestamp: Date(),
            contentType: .message
        )
    }

    private func makeReceiver(
        store: InMemoryStore,
        crypto: DevelopmentPlaintextCryptoEngine,
        notifications: NotificationSpy
    ) -> MessageReceiver {
        MessageReceiver(
            store: store,
            crypto: crypto,
            transport: LoopbackTransport(),
            events: ClientEventHub(),
            diagnostics: DiagnosticsRecorder(),
            notifications: notifications
        )
    }

    @Test func myOwnMessageSyncedFromAnotherDeviceIsStoredAsOutgoing() async throws {
        let store = InMemoryStore()
        let crypto = DevelopmentPlaintextCryptoEngine(explicitlyAllowInsecurePlaintext: true)
        let spy = NotificationSpy()
        let receiver = makeReceiver(store: store, crypto: crypto, notifications: spy)
        await receiver.start(account: Self.account)

        let sealed = try await envelope(
            from: Self.me,
            to: Self.them,
            body: "sent from my phone",
            id: "own-1",
            crypto: crypto
        )
        #expect(await receiver.process(sealed))

        let stored = try #require(try await store.loadMessage(id: "own-1"))
        // Rendered on the right, as mine.
        #expect(stored.direction == .outgoing)
        #expect(stored.senderID == Self.me)
        if case .sent = stored.deliveryState {
        } else {
            Issue.record("Expected .sent, got \(stored.deliveryState)")
        }

        let conversation = try #require(try await store.loadConversation(id: Self.conversation.id))
        // My own message must not make the thread look unread...
        #expect(conversation.unreadCount == 0)
        // ...nor raise a notification for something I just typed elsewhere.
        #expect(await spy.count == 0)

        await receiver.stop()
    }

    @Test func aMessageFromSomeoneElseStaysIncomingAndNotifies() async throws {
        let store = InMemoryStore()
        let crypto = DevelopmentPlaintextCryptoEngine(explicitlyAllowInsecurePlaintext: true)
        let spy = NotificationSpy()
        let receiver = makeReceiver(store: store, crypto: crypto, notifications: spy)
        await receiver.start(account: Self.account)

        let sealed = try await envelope(
            from: Self.them,
            to: Self.me,
            body: "hi",
            id: "their-1",
            crypto: crypto
        )
        #expect(await receiver.process(sealed))

        let stored = try #require(try await store.loadMessage(id: "their-1"))
        #expect(stored.direction == .incoming)
        let conversation = try #require(try await store.loadConversation(id: Self.conversation.id))
        #expect(conversation.unreadCount == 1)
        #expect(await spy.count == 1)

        await receiver.stop()
    }

    @Test func bothDirectionsShareOneConversation() async throws {
        let store = InMemoryStore()
        let crypto = DevelopmentPlaintextCryptoEngine(explicitlyAllowInsecurePlaintext: true)
        let spy = NotificationSpy()
        let receiver = makeReceiver(store: store, crypto: crypto, notifications: spy)
        await receiver.start(account: Self.account)

        _ = await receiver.process(
            try await envelope(from: Self.me, to: Self.them, body: "mine", id: "a", crypto: crypto)
        )
        _ = await receiver.process(
            try await envelope(from: Self.them, to: Self.me, body: "theirs", id: "b", crypto: crypto)
        )

        let conversations = try await store.loadConversations(includeArchived: true)
        // The whole point: one thread, not one per direction.
        #expect(conversations.count == 1)
        let messages = try await store.loadMessages(
            conversationID: Self.conversation.id,
            before: nil,
            limit: 50
        )
        #expect(messages.count == 2)
        #expect(messages.filter { $0.direction == .outgoing }.count == 1)
        #expect(messages.filter { $0.direction == .incoming }.count == 1)

        await receiver.stop()
    }
}
