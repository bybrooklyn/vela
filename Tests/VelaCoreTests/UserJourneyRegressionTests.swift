import Foundation
import Testing

@testable import VelaCore
@testable import VelaCrypto
@testable import VelaDomain
@testable import VelaStorage
@testable import VelaTransport

/// Core events are UI contracts: AppModel uses them to refresh lists and the
/// selected timeline after background changes.
@Suite(.serialized) struct UserJourneyRegressionTests {
    private static let account = LinkedAccount(
        id: "account",
        localRecipientID: "me",
        deviceID: "mac",
        deviceName: "Mac",
        serviceIdentifier: .opaque("me"),
        identityHandle: "development",
        linkedAt: Date(timeIntervalSince1970: 1)
    )

    private static let conversation = ConversationSeed(
        id: "conversation",
        kind: .direct(recipientID: "remote"),
        title: "Remote"
    )

    @Test func inMemoryContactSyncReplacesStaleCacheAndPublishesRefresh() async throws {
        try await assertContactReplacement(store: InMemoryStore())
    }

    @Test func sQLiteContactSyncReplacesStaleCacheAndPublishesRefresh() async throws {
        try await withSQLiteStore { store in
            try await assertContactReplacement(store: store)
        }
    }

    private func assertContactReplacement(store: any ClientStore) async throws {
        let client = makeClient(store: store)
        let old = Contact(recipientID: "old", givenName: "Old", updatedAt: Date(timeIntervalSince1970: 1))
        let retained = Contact(
            recipientID: "retained",
            givenName: "Before",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        try await client.replaceContacts([old, retained])

        let stream = await client.events()
        var iterator = stream.makeAsyncIterator()
        let updated = Contact(
            recipientID: retained.recipientID,
            givenName: "After",
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        try await client.replaceContacts([updated])

        #expect(await iterator.next() == .contactsChanged)
        #expect(try await client.contacts(includeBlocked: true) == [updated])
        #expect(try await client.contact(for: old.recipientID) == nil)

        try await client.replaceContacts([])
        #expect(try await client.contacts(includeBlocked: true).isEmpty)
        await client.shutdown()
    }

    @Test func resetPurgesJourneyStateAndReturnsClientToUnlinked() async throws {
        let store = InMemoryStore()
        try await store.migrate()
        try await store.saveLinkedAccount(Self.account)
        try await store.upsertContacts([
            Contact(recipientID: "remote", givenName: "Remote", updatedAt: Date(timeIntervalSince1970: 1))
        ])

        let attachment = AttachmentReference(
            fileName: "draft.txt",
            mimeType: "text/plain",
            byteCount: 12,
            state: .available(localRelativePath: "/tmp/draft.txt")
        )
        let message = ChatMessage(
            id: "queued-message",
            conversationID: Self.conversation.id,
            senderID: Self.account.localRecipientID,
            direction: .outgoing,
            content: .text("queued"),
            sentAt: Date(timeIntervalSince1970: 2),
            deliveryState: .queued,
            attachments: [attachment]
        )
        let outbox = OutboxItem(
            messageID: message.id,
            destination: DeviceAddress(recipientID: "remote", deviceID: "phone"),
            plaintextPayload: Data("queued".utf8),
            createdAt: message.sentAt,
            nextAttemptAt: message.sentAt
        )
        try await store.persistOutgoing(message: message, conversationSeed: Self.conversation, outboxItem: outbox)
        _ = try await store.recordSeenEnvelope("seen", at: message.sentAt)

        let client = makeClient(store: store)
        await client.bootstrap()
        try await client.unlinkAndDeleteLocalData()

        let snapshot = await client.snapshot()
        #expect(snapshot.state == .unlinked)
        #expect(snapshot.connection == .disconnected)
        #expect(snapshot.linkedAccount == nil)
        #expect(snapshot.unreadCount == 0)
        #expect(try await client.conversations(includeArchived: true).isEmpty)
        #expect(try await client.messages(in: Self.conversation.id).isEmpty)
        #expect(try await client.contacts(includeBlocked: true).isEmpty)
        #expect(
            try await client.statistics()
                == StoreStatistics(
                    accountCount: 0,
                    conversationCount: 0,
                    messageCount: 0,
                    pendingOutboxCount: 0,
                    seenEnvelopeCount: 0
                ))
        await client.shutdown()
    }

    @Test func expiryRemovalPublishesConversationRefreshAndRebuildsPreview() async throws {
        let cutoff = Date(timeIntervalSince1970: 100)
        let store = InMemoryStore()
        try await insertIncoming(
            ChatMessage(
                id: "retained",
                conversationID: Self.conversation.id,
                senderID: "remote",
                direction: .incoming,
                content: .text("retained"),
                sentAt: Date(timeIntervalSince1970: 10),
                deliveryState: .delivered(at: Date(timeIntervalSince1970: 10))
            ),
            envelopeID: "retained-envelope",
            store: store
        )
        try await insertIncoming(
            ChatMessage(
                id: "expired",
                conversationID: Self.conversation.id,
                senderID: "remote",
                direction: .incoming,
                content: .text("expired"),
                sentAt: Date(timeIntervalSince1970: 20),
                deliveryState: .delivered(at: Date(timeIntervalSince1970: 20)),
                expiresAt: cutoff
            ),
            envelopeID: "expired-envelope",
            store: store
        )

        let client = makeClient(store: store, clock: FixedVelaClock(now: cutoff))
        let stream = await client.events()
        var iterator = stream.makeAsyncIterator()

        #expect(try await client.removeExpiredMessages() == 1)
        #expect(await iterator.next() == .conversationsChanged)
        #expect(try await client.messages(in: Self.conversation.id).map(\.id) == [MessageID("retained")])
        #expect(try await client.conversations().first?.lastMessage?.text == "retained")
        await client.shutdown()
    }

    @Test func readSyncAndReactionRemovalPublishRequiredUIRefreshes() async throws {
        let store = InMemoryStore()
        let crypto = DevelopmentPlaintextCryptoEngine(explicitlyAllowInsecurePlaintext: true)
        let events = ClientEventHub()
        let receiver = MessageReceiver(
            store: store,
            crypto: crypto,
            transport: LoopbackTransport(),
            events: events,
            diagnostics: DiagnosticsRecorder()
        )
        await receiver.start(account: Self.account)
        let stream = await events.stream()
        var iterator = stream.makeAsyncIterator()

        let base = WireMessage(
            id: "base",
            conversation: Self.conversation,
            senderID: "remote",
            recipientID: Self.account.localRecipientID,
            kind: .text,
            body: "hello",
            sentAt: Date(timeIntervalSince1970: 10)
        )
        #expect(await receiver.process(try await seal(base, envelopeID: "base-envelope", crypto: crypto)))
        #expect(await iterator.next() == .conversationsChanged)
        #expect(await iterator.next() == .messagesChanged(Self.conversation.id))

        let read = WireMessage(
            id: "read",
            conversation: Self.conversation,
            senderID: Self.account.localRecipientID,
            recipientID: Self.account.localRecipientID,
            kind: .readSync,
            body: ControlPayload(detail: "read", targets: [base.id]).encoded,
            sentAt: Date(timeIntervalSince1970: 11)
        )
        #expect(await receiver.process(try await seal(read, envelopeID: "read-envelope", crypto: crypto)))
        #expect(await iterator.next() == .conversationsChanged)

        let addReaction = WireMessage(
            id: "add-reaction",
            conversation: Self.conversation,
            senderID: "remote",
            recipientID: Self.account.localRecipientID,
            kind: .reaction,
            body: "👍",
            sentAt: Date(timeIntervalSince1970: 12),
            targetMessageID: base.id
        )
        #expect(await receiver.process(try await seal(addReaction, envelopeID: "add-envelope", crypto: crypto)))
        #expect(await iterator.next() == .conversationsChanged)
        #expect(await iterator.next() == .messagesChanged(Self.conversation.id))

        var removeReaction = addReaction
        removeReaction.id = "remove-reaction"
        removeReaction.body = ""
        removeReaction.sentAt = Date(timeIntervalSince1970: 13)
        #expect(await receiver.process(try await seal(removeReaction, envelopeID: "remove-envelope", crypto: crypto)))
        #expect(await iterator.next() == .conversationsChanged)
        #expect(await iterator.next() == .messagesChanged(Self.conversation.id))
        #expect(try await store.loadMessage(id: base.id)?.reactions.isEmpty == true)
        #expect(try await store.loadConversation(id: Self.conversation.id)?.unreadCount == 0)
        await receiver.stop()
    }

    @Test func retryKeepsAttachmentAndPublishesTimelineStateChanges() async throws {
        let store = InMemoryStore()
        let crypto = DevelopmentPlaintextCryptoEngine(explicitlyAllowInsecurePlaintext: true)
        let service = LoopbackTransport()
        let events = ClientEventHub()
        try await service.connect(account: Self.account)
        let sender = MessageSender(
            store: store,
            router: DevelopmentRecipientRouter(),
            clock: FixedVelaClock(now: Date(timeIntervalSince1970: 20)),
            events: events
        )
        let outbox = OutboxProcessor(
            store: store,
            crypto: crypto,
            transport: service,
            clock: FixedVelaClock(now: Date(timeIntervalSince1970: 20)),
            backoff: BackoffPolicy(initialDelay: 0, maximumDelay: 0, maximumAttempts: 3),
            events: events,
            diagnostics: DiagnosticsRecorder()
        )
        await outbox.configure(account: Self.account)
        let attachment = AttachmentReference(
            fileName: "draft.txt",
            mimeType: "text/plain",
            byteCount: 12,
            state: .available(localRelativePath: "/tmp/draft.txt")
        )
        let messageID = try await sender.enqueue(
            draft: MessageDraft(text: "with attachment", attachments: [attachment]),
            conversation: Self.conversation,
            account: Self.account
        )
        let stream = await events.stream()
        var iterator = stream.makeAsyncIterator()
        await service.failNextSends(1)

        #expect(await outbox.flushOnce().scheduledForRetry == 1)
        #expect(await iterator.next() == .messagesChanged(Self.conversation.id))
        let failed = try #require(try await store.loadMessage(id: messageID))
        #expect(failed.attachments == [attachment])
        if case .failedRetryable = failed.deliveryState {
        } else {
            Issue.record("Expected retryable failure, got \(failed.deliveryState)")
        }

        #expect(await outbox.flushOnce().sent == 1)
        #expect(await iterator.next() == .messagesChanged(Self.conversation.id))
        let sent = try #require(try await store.loadMessage(id: messageID))
        #expect(sent.attachments == [attachment])
        if case .sent = sent.deliveryState {
        } else {
            Issue.record("Expected sent state, got \(sent.deliveryState)")
        }
        await outbox.stop()
    }

    private func makeClient(
        store: any ClientStore,
        clock: any VelaClock = SystemVelaClock()
    ) -> VelaClient {
        VelaClient(
            dependencies: VelaClientDependencies(
                store: store,
                crypto: DevelopmentPlaintextCryptoEngine(explicitlyAllowInsecurePlaintext: true),
                serviceTransport: LoopbackTransport(),
                provisioningTransport: DevelopmentProvisioningTransport(),
                recipientRouter: DevelopmentRecipientRouter(),
                clock: clock,
                backoffPolicy: BackoffPolicy(initialDelay: 0, maximumDelay: 0, maximumAttempts: 3)
            )
        )
    }

    private func insertIncoming(
        _ message: ChatMessage,
        envelopeID: EnvelopeID,
        store: InMemoryStore
    ) async throws {
        _ = try await store.persistIncoming(
            message: message,
            conversationSeed: Self.conversation,
            envelopeID: envelopeID,
            incrementUnread: true
        )
    }

    private func withSQLiteStore(
        _ body: (SQLiteStore) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vela-journey-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteStore(
            url: directory.appendingPathComponent("test.sqlite"),
            security: .plaintextDevelopmentOnly
        )
        try await store.migrate()
        try await body(store)
    }

    private func seal(
        _ wire: WireMessage,
        envelopeID: EnvelopeID,
        crypto: DevelopmentPlaintextCryptoEngine
    ) async throws -> EncryptedEnvelope {
        try await crypto.seal(
            try WireCodec().encode(wire),
            envelopeID: envelopeID,
            source: DeviceAddress(recipientID: wire.senderID, deviceID: "phone"),
            destination: DeviceAddress(recipientID: Self.account.localRecipientID, deviceID: Self.account.deviceID),
            timestamp: wire.sentAt,
            contentType: .message
        )
    }
}
