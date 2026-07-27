import Foundation
import Testing

@testable import VelaCore
@testable import VelaCrypto
@testable import VelaDomain
@testable import VelaStorage
@testable import VelaTransport

@Suite(.serialized) struct CoreTests {
    @Test func completeDevelopmentMessagingPipeline() async throws {
        let store = InMemoryStore()
        let crypto = DevelopmentPlaintextCryptoEngine(explicitlyAllowInsecurePlaintext: true)
        let service = LoopbackTransport()
        let provisioning = DevelopmentProvisioningTransport()
        let client = VelaClient(
            dependencies: VelaClientDependencies(
                store: store,
                crypto: crypto,
                serviceTransport: service,
                provisioningTransport: provisioning,
                recipientRouter: DevelopmentRecipientRouter(),
                backoffPolicy: BackoffPolicy(initialDelay: 0, maximumDelay: 0, maximumAttempts: 2)
            )
        )

        await client.bootstrap()
        let session = try await client.beginProvisioning(deviceName: "Test Mac")
        _ = try await provisioning.completeDevelopmentLink(
            sessionID: session.id,
            deviceName: "Test Mac",
            identityHandle: try await crypto.generateIdentityHandle()
        )
        let account = try await waitForReady(client)

        let remote: RecipientID = "remote"
        let conversation = ConversationSeed(
            id: "conversation",
            kind: .direct(recipientID: remote),
            title: "Remote"
        )
        _ = try await client.send(MessageDraft(text: "outgoing"), to: conversation)
        // Sending is optimistic, so the transmission may already be in flight
        // from the background flush: an explicit flush correctly skips a message
        // another flush is holding, and reports nothing sent.
        _ = await client.flushOutbox()
        try await eventually { await service.sentEnvelopes().count == 1 }

        let wire = WireMessage(
            id: "incoming-message",
            conversation: conversation,
            senderID: remote,
            recipientID: account.localRecipientID,
            kind: .text,
            body: "incoming",
            sentAt: Date()
        )
        let envelope = try await crypto.seal(
            try WireCodec().encode(wire),
            envelopeID: "incoming-envelope",
            source: DeviceAddress(recipientID: remote, deviceID: "phone"),
            destination: DeviceAddress(recipientID: account.localRecipientID, deviceID: account.deviceID),
            timestamp: Date(),
            contentType: .message
        )
        await service.injectIncoming(envelope)
        try await eventually {
            (try await client.messages(in: conversation.id)).count == 2
        }

        let beforeRead = try await client.conversations()
        #expect(beforeRead.first?.unreadCount == 1)
        try await client.markRead(conversation.id)
        let afterRead = try await client.conversations()
        #expect(afterRead.first?.unreadCount == 0)
        await client.shutdown()
    }

    @Test func outgoingEditReactionAndDeleteUseDurableControlEnvelopes() async throws {
        let store = InMemoryStore()
        let crypto = DevelopmentPlaintextCryptoEngine(explicitlyAllowInsecurePlaintext: true)
        let service = LoopbackTransport()
        let provisioning = DevelopmentProvisioningTransport()
        let client = makeClient(
            store: store,
            crypto: crypto,
            service: service,
            provisioning: provisioning
        )

        await client.bootstrap()
        let session = try await client.beginProvisioning(deviceName: "Mutation Mac")
        _ = try await provisioning.completeDevelopmentLink(
            sessionID: session.id,
            deviceName: "Mutation Mac",
            identityHandle: try await crypto.generateIdentityHandle()
        )
        let account = try await waitForReady(client)

        let conversation = ConversationSeed(
            id: "mutation-conversation",
            kind: .direct(recipientID: "remote"),
            title: "Remote"
        )
        let messageID = try await client.send(MessageDraft(text: "before"), to: conversation)

        _ = try await client.editMessage(messageID, newText: "after")
        let editedMessage = try await store.loadMessage(id: messageID)
        var message = try #require(editedMessage)
        #expect(message.content == .text("after"))
        #expect(message.revision == 1)

        _ = try await client.react(to: messageID, emoji: "✨")
        let reactedMessage = try await store.loadMessage(id: messageID)
        message = try #require(reactedMessage)
        #expect(message.reactions.map(\.emoji) == ["✨"])

        _ = try await client.deleteMessage(messageID)
        let deletedMessage = try await store.loadMessage(id: messageID)
        message = try #require(deletedMessage)
        #expect(message.content == .deleted(deletedBy: account.localRecipientID))
        #expect(message.revision == 2)
        #expect(message.reactions.isEmpty)
        // Sending is optimistic: the local change lands immediately and the
        // transmission happens in the background, so the outbox is drained
        // asynchronously rather than by the time the call returns.
        try await eventually { await service.sentEnvelopes().count == 4 }
        try await eventually { try await store.statistics().pendingOutboxCount == 0 }
        await client.shutdown()
    }

    @Test func incomingEditReactionDeleteAndReplaySuppression() async throws {
        let store = InMemoryStore()
        let crypto = DevelopmentPlaintextCryptoEngine(explicitlyAllowInsecurePlaintext: true)
        let service = LoopbackTransport()
        let provisioning = DevelopmentProvisioningTransport()
        let client = makeClient(
            store: store,
            crypto: crypto,
            service: service,
            provisioning: provisioning
        )

        await client.bootstrap()
        let session = try await client.beginProvisioning(deviceName: "Receive Mac")
        _ = try await provisioning.completeDevelopmentLink(
            sessionID: session.id,
            deviceName: "Receive Mac",
            identityHandle: try await crypto.generateIdentityHandle()
        )
        let account = try await waitForReady(client)
        let remote: RecipientID = "remote"
        let conversation = ConversationSeed(
            id: "incoming-mutations",
            kind: .direct(recipientID: remote),
            title: "Remote"
        )

        let base = WireMessage(
            id: "remote-message",
            conversation: conversation,
            senderID: remote,
            recipientID: account.localRecipientID,
            kind: .text,
            body: "original",
            sentAt: Date()
        )
        await service.injectIncoming(
            try await envelope(
                wire: base,
                envelopeID: "base-envelope",
                remote: remote,
                account: account,
                crypto: crypto
            )
        )
        try await eventually {
            try await store.loadMessage(id: base.id) != nil
        }

        let edit = WireMessage(
            id: "edit-control",
            conversation: conversation,
            senderID: remote,
            recipientID: account.localRecipientID,
            kind: .edit,
            body: "edited",
            sentAt: Date(),
            targetMessageID: base.id,
            revision: 1
        )
        await service.injectIncoming(
            try await envelope(
                wire: edit,
                envelopeID: "edit-envelope",
                remote: remote,
                account: account,
                crypto: crypto
            )
        )
        try await eventually {
            try await store.loadMessage(id: base.id)?.content == .text("edited")
        }

        let reaction = WireMessage(
            id: "reaction-control",
            conversation: conversation,
            senderID: remote,
            recipientID: account.localRecipientID,
            kind: .reaction,
            body: "💜",
            sentAt: Date(),
            targetMessageID: base.id
        )
        let reactionEnvelope = try await envelope(
            wire: reaction,
            envelopeID: "reaction-envelope",
            remote: remote,
            account: account,
            crypto: crypto
        )
        await service.injectIncoming(reactionEnvelope)
        await service.injectIncoming(reactionEnvelope)
        try await eventually {
            try await store.loadMessage(id: base.id)?.reactions.count == 1
        }

        let deletion = WireMessage(
            id: "delete-control",
            conversation: conversation,
            senderID: remote,
            recipientID: account.localRecipientID,
            kind: .delete,
            sentAt: Date(),
            targetMessageID: base.id,
            revision: 2
        )
        await service.injectIncoming(
            try await envelope(
                wire: deletion,
                envelopeID: "delete-envelope",
                remote: remote,
                account: account,
                crypto: crypto
            )
        )
        try await eventually {
            try await store.loadMessage(id: base.id)?.content == .deleted(deletedBy: remote)
        }
        let finalMessage = try await store.loadMessage(id: base.id)
        let final = try #require(finalMessage)
        let statistics = try await store.statistics()
        #expect(final.reactions.isEmpty)
        #expect(statistics.seenEnvelopeCount == 4)
        await client.shutdown()
    }

    @Test func outboxRetriesAfterInjectedTransportFailure() async throws {
        let store = InMemoryStore()
        let crypto = DevelopmentPlaintextCryptoEngine(explicitlyAllowInsecurePlaintext: true)
        let service = LoopbackTransport()
        let events = ClientEventHub()
        let diagnostics = DiagnosticsRecorder()
        let account = LinkedAccount(
            id: "account",
            localRecipientID: "local",
            deviceID: "mac",
            deviceName: "Mac",
            serviceIdentifier: .opaque("local"),
            identityHandle: "dev",
            linkedAt: Date()
        )
        try await service.connect(account: account)

        let sender = MessageSender(
            store: store,
            router: DevelopmentRecipientRouter(),
            events: events
        )
        let outbox = OutboxProcessor(
            store: store,
            crypto: crypto,
            transport: service,
            backoff: BackoffPolicy(initialDelay: 0, maximumDelay: 0, maximumAttempts: 3),
            events: events,
            diagnostics: diagnostics
        )
        // Deliberately not `start`: this test asserts exact per-flush counts, and
        // the background loop would race the explicit flushes below.
        await outbox.configure(account: account)
        await service.failNextSends(1)

        let conversation = ConversationSeed(
            id: "c",
            kind: .direct(recipientID: "remote"),
            title: "Remote"
        )
        let messageID = try await sender.enqueue(
            draft: MessageDraft(text: "retry me"),
            conversation: conversation,
            account: account
        )

        let first = await outbox.flushOnce()
        #expect(first.scheduledForRetry == 1)
        let second = await outbox.flushOnce()
        #expect(second.sent == 1)
        let storedMessage = try await store.loadMessage(id: messageID)
        #expect(storedMessage?.deliveryState.isSent == true)
        await outbox.stop()
    }

    private func makeClient(
        store: InMemoryStore,
        crypto: DevelopmentPlaintextCryptoEngine,
        service: LoopbackTransport,
        provisioning: DevelopmentProvisioningTransport
    ) -> VelaClient {
        VelaClient(
            dependencies: VelaClientDependencies(
                store: store,
                crypto: crypto,
                serviceTransport: service,
                provisioningTransport: provisioning,
                recipientRouter: DevelopmentRecipientRouter(),
                backoffPolicy: BackoffPolicy(initialDelay: 0, maximumDelay: 0, maximumAttempts: 2)
            )
        )
    }

    private func envelope(
        wire: WireMessage,
        envelopeID: EnvelopeID,
        remote: RecipientID,
        account: LinkedAccount,
        crypto: DevelopmentPlaintextCryptoEngine
    ) async throws -> EncryptedEnvelope {
        try await crypto.seal(
            try WireCodec().encode(wire),
            envelopeID: envelopeID,
            source: DeviceAddress(recipientID: remote, deviceID: "phone"),
            destination: DeviceAddress(recipientID: account.localRecipientID, deviceID: account.deviceID),
            timestamp: Date(),
            contentType: .message
        )
    }

    // These poll against a wall-clock deadline rather than a fixed attempt count.
    // A satisfied condition returns immediately, so a generous deadline costs
    // nothing when the suite passes, but it stops the whole suite running in
    // parallel from timing a test out purely because the machine was busy.
    private func waitForReady(
        _ client: VelaClient,
        timeout: Duration = .seconds(45)
    ) async throws -> LinkedAccount {
        let deadline = ContinuousClock.now + timeout
        repeat {
            let snapshot = await client.snapshot()
            if snapshot.state == .ready, let account = snapshot.linkedAccount {
                return account
            }
            try await Task.sleep(for: .milliseconds(5))
        } while ContinuousClock.now < deadline
        throw VelaError.invalidState(expected: "ready", actual: "timeout")
    }

    private func eventually(
        timeout: Duration = .seconds(45),
        operation: @escaping @Sendable () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        repeat {
            if try await operation() { return }
            try await Task.sleep(for: .milliseconds(5))
        } while ContinuousClock.now < deadline
        Issue.record("Condition did not become true within \(timeout)")
    }
}

extension MessageDeliveryState {
    fileprivate var isSent: Bool {
        if case .sent = self { return true }
        return false
    }
}
