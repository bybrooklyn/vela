import Foundation
import Testing

@testable import VelaCore
@testable import VelaCrypto
@testable import VelaDomain
@testable import VelaStorage
@testable import VelaTransport

/// Reading a conversation on the phone must clear Vela's unread badge.
///
/// The subtle part is which conversation gets cleared: a read entry names
/// whoever *sent* the message that was read, not the thread it lives in, so
/// resolving from the sender would send every group read to a direct
/// conversation with whoever happened to speak.
@Suite(.serialized) struct ReadSyncTests {
    private static let me: RecipientID = "me"
    private static let alice: RecipientID = "alice"

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

    private static let group = ConversationSeed(
        id: .of(.group(groupID: "team", memberIDs: [me, alice])),
        kind: .group(groupID: "team", memberIDs: [me, alice]),
        title: "Team"
    )

    private func makeReceiver(
        store: InMemoryStore,
        crypto: DevelopmentPlaintextCryptoEngine
    ) -> MessageReceiver {
        MessageReceiver(
            store: store,
            crypto: crypto,
            transport: LoopbackTransport(),
            events: ClientEventHub(),
            diagnostics: DiagnosticsRecorder()
        )
    }

    private func seal(
        _ wire: WireMessage,
        id: EnvelopeID,
        from sender: RecipientID,
        crypto: DevelopmentPlaintextCryptoEngine
    ) async throws -> EncryptedEnvelope {
        try await crypto.seal(
            try WireCodec().encode(wire),
            envelopeID: id,
            source: DeviceAddress(recipientID: sender, deviceID: "phone"),
            destination: DeviceAddress(recipientID: Self.me, deviceID: "mac"),
            timestamp: Date(),
            contentType: .message
        )
    }

    @Test func readingAGroupOnThePhoneClearsThatGroupNotTheSender() async throws {
        let store = InMemoryStore()
        let crypto = DevelopmentPlaintextCryptoEngine(explicitlyAllowInsecurePlaintext: true)
        let receiver = makeReceiver(store: store, crypto: crypto)
        await receiver.start(account: Self.account)

        // Alice speaks in the group, leaving it unread.
        let incoming = WireMessage(
            id: MessageID("msg-1"),
            conversation: Self.group,
            senderID: Self.alice,
            recipientID: Self.me,
            kind: .text,
            body: "standup in five",
            sentAt: Date()
        )
        #expect(await receiver.process(try await seal(incoming, id: "e-1", from: Self.alice, crypto: crypto)))

        let before = try #require(try await store.loadConversation(id: Self.group.id))
        #expect(before.unreadCount == 1)

        // We read it on the phone. The entry names Alice, but the thread is the
        // group.
        let readSync = WireMessage(
            id: MessageID("read-1"),
            conversation: ConversationSeed(
                id: .direct(with: Self.alice),
                kind: .direct(recipientID: Self.alice),
                title: "Alice"
            ),
            senderID: Self.me,
            recipientID: Self.me,
            kind: .readSync,
            body: ControlPayload(detail: "read", targets: [MessageID("msg-1")]).encoded,
            sentAt: Date()
        )
        #expect(await receiver.process(try await seal(readSync, id: "e-2", from: Self.me, crypto: crypto)))

        let after = try #require(try await store.loadConversation(id: Self.group.id))
        #expect(after.unreadCount == 0)
    }

    @Test func areadSyncForAnUnknownMessageChangesNothing() async throws {
        let store = InMemoryStore()
        let crypto = DevelopmentPlaintextCryptoEngine(explicitlyAllowInsecurePlaintext: true)
        let receiver = makeReceiver(store: store, crypto: crypto)
        await receiver.start(account: Self.account)

        let incoming = WireMessage(
            id: MessageID("msg-1"),
            conversation: Self.group,
            senderID: Self.alice,
            recipientID: Self.me,
            kind: .text,
            body: "hello",
            sentAt: Date()
        )
        #expect(await receiver.process(try await seal(incoming, id: "e-1", from: Self.alice, crypto: crypto)))

        // A message from before linking, which we never stored. It must be
        // skipped rather than clearing something arbitrary.
        let readSync = WireMessage(
            id: MessageID("read-1"),
            conversation: Self.group,
            senderID: Self.me,
            recipientID: Self.me,
            kind: .readSync,
            body: ControlPayload(detail: "read", targets: [MessageID("never-seen")]).encoded,
            sentAt: Date()
        )
        #expect(await receiver.process(try await seal(readSync, id: "e-2", from: Self.me, crypto: crypto)))

        let after = try #require(try await store.loadConversation(id: Self.group.id))
        #expect(after.unreadCount == 1)
    }

    @Test func removingAReactionOnThePhoneClearsItHere() async throws {
        let store = InMemoryStore()
        let crypto = DevelopmentPlaintextCryptoEngine(explicitlyAllowInsecurePlaintext: true)
        let receiver = makeReceiver(store: store, crypto: crypto)
        await receiver.start(account: Self.account)

        let incoming = WireMessage(
            id: MessageID("msg-1"),
            conversation: Self.group,
            senderID: Self.alice,
            recipientID: Self.me,
            kind: .text,
            body: "ship it",
            sentAt: Date()
        )
        #expect(await receiver.process(try await seal(incoming, id: "e-1", from: Self.alice, crypto: crypto)))

        func reaction(_ body: String, id: String, envelope: EnvelopeID) -> WireMessage {
            WireMessage(
                id: MessageID(id),
                conversation: Self.group,
                senderID: Self.alice,
                recipientID: Self.me,
                kind: .reaction,
                body: body,
                sentAt: Date(),
                targetMessageID: MessageID("msg-1")
            )
        }

        let added = reaction("👍", id: "react-1", envelope: "e-2")
        #expect(await receiver.process(try await seal(added, id: "e-2", from: Self.alice, crypto: crypto)))
        let withReaction = try #require(try await store.loadMessage(id: MessageID("msg-1")))
        #expect(withReaction.reactions.count == 1)

        // An empty body is the removal. Before this it was dropped in the
        // translator, so a reaction taken back on the phone stayed forever.
        let removed = reaction("", id: "react-2", envelope: "e-3")
        #expect(await receiver.process(try await seal(removed, id: "e-3", from: Self.alice, crypto: crypto)))
        let cleared = try #require(try await store.loadMessage(id: MessageID("msg-1")))
        #expect(cleared.reactions.isEmpty)
    }

    @Test func delayedIncomingDisappearingMessageStartsAtReceipt() async throws {
        let store = InMemoryStore()
        let crypto = DevelopmentPlaintextCryptoEngine(explicitlyAllowInsecurePlaintext: true)
        let receivedAt = Date(timeIntervalSince1970: 10_000)
        let receiver = MessageReceiver(
            store: store,
            crypto: crypto,
            transport: LoopbackTransport(),
            clock: FixedVelaClock(now: receivedAt),
            events: ClientEventHub(),
            diagnostics: DiagnosticsRecorder()
        )
        await receiver.start(account: Self.account)

        let incoming = WireMessage(
            id: "temporary",
            conversation: Self.group,
            senderID: Self.alice,
            recipientID: Self.me,
            kind: .text,
            body: "arrived late",
            sentAt: Date(timeIntervalSince1970: 100),
            expiresIn: 60
        )
        #expect(await receiver.process(try await seal(incoming, id: "expiry-envelope", from: Self.alice, crypto: crypto)))

        let stored = try #require(try await store.loadMessage(id: incoming.id))
        #expect(stored.expiresAt == receivedAt.addingTimeInterval(60))
    }

    @Test func expirationUpdateChangesConversationWithoutTimelineRow() async throws {
        let store = InMemoryStore()
        let crypto = DevelopmentPlaintextCryptoEngine(explicitlyAllowInsecurePlaintext: true)
        let receiver = makeReceiver(store: store, crypto: crypto)
        await receiver.start(account: Self.account)

        let update = WireMessage(
            id: "timer-update",
            conversation: Self.group,
            senderID: Self.alice,
            recipientID: Self.me,
            kind: .expirationUpdate,
            sentAt: Date(timeIntervalSince1970: 100),
            expiresIn: 3_600
        )
        #expect(await receiver.process(try await seal(update, id: "timer-envelope", from: Self.alice, crypto: crypto)))

        let conversation = try #require(try await store.loadConversation(id: Self.group.id))
        #expect(conversation.disappearingMessageDuration == 3_600)
        #expect(try await store.loadMessages(conversationID: Self.group.id, before: nil, limit: 10).isEmpty)
    }
}
