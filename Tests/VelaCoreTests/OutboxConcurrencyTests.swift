import Foundation
import Testing

@testable import VelaCore
@testable import VelaCrypto
@testable import VelaDomain
@testable import VelaStorage
@testable import VelaTransport

/// Sending is now optimistic: the flush runs in the background while the UI
/// paints. That means the periodic loop, an explicit flush and a send can all
/// overlap, and the outbox must never hand the same message to the transport
/// twice — the recipient would see a duplicate.
@Suite(.serialized) struct OutboxConcurrencyTests {
    private static var account: LinkedAccount {
        LinkedAccount(
            id: "account",
            localRecipientID: "me",
            deviceID: "mac",
            deviceName: "Mac",
            serviceIdentifier: .opaque("me"),
            identityHandle: "dev",
            linkedAt: Date()
        )
    }

    @Test func overlappingFlushesSendEachMessageOnce() async throws {
        let store = InMemoryStore()
        let crypto = DevelopmentPlaintextCryptoEngine(explicitlyAllowInsecurePlaintext: true)
        let service = LoopbackTransport()
        let events = ClientEventHub()
        try await service.connect(account: Self.account)

        let sender = MessageSender(store: store, router: DevelopmentRecipientRouter(), events: events)
        let outbox = OutboxProcessor(
            store: store,
            crypto: crypto,
            transport: service,
            backoff: BackoffPolicy(initialDelay: 0, maximumDelay: 0, maximumAttempts: 3),
            events: events,
            diagnostics: DiagnosticsRecorder()
        )
        await outbox.configure(account: Self.account)

        let conversation = ConversationSeed(
            id: .direct(with: "remote"),
            kind: .direct(recipientID: "remote"),
            title: "Remote"
        )
        for index in 0..<5 {
            _ = try await sender.enqueue(
                draft: MessageDraft(text: "message \(index)"),
                conversation: conversation,
                account: Self.account
            )
        }

        // Eight flushes at once, mimicking the background loop racing explicit
        // flushes from send, wake and manual refresh.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { _ = await outbox.flushOnce() }
            }
        }

        let sent = await service.sentEnvelopes().count
        #expect(sent == 5)

        let statistics = try await store.statistics()
        #expect(statistics.pendingOutboxCount == 0)
    }

    @Test func aRetryStillHappensAfterConcurrentFlushes() async throws {
        let store = InMemoryStore()
        let crypto = DevelopmentPlaintextCryptoEngine(explicitlyAllowInsecurePlaintext: true)
        let service = LoopbackTransport()
        let events = ClientEventHub()
        try await service.connect(account: Self.account)

        let sender = MessageSender(store: store, router: DevelopmentRecipientRouter(), events: events)
        let outbox = OutboxProcessor(
            store: store,
            crypto: crypto,
            transport: service,
            backoff: BackoffPolicy(initialDelay: 0, maximumDelay: 0, maximumAttempts: 3),
            events: events,
            diagnostics: DiagnosticsRecorder()
        )
        await outbox.configure(account: Self.account)
        await service.failNextSends(1)

        let conversation = ConversationSeed(
            id: .direct(with: "remote"),
            kind: .direct(recipientID: "remote"),
            title: "Remote"
        )
        let messageID = try await sender.enqueue(
            draft: MessageDraft(text: "retry me"),
            conversation: conversation,
            account: Self.account
        )

        // The in-flight guard must not swallow the retry: after the failure the
        // message has to remain sendable.
        _ = await outbox.flushOnce()
        _ = await outbox.flushOnce()

        let stored = try #require(try await store.loadMessage(id: messageID))
        if case .sent = stored.deliveryState {
        } else {
            Issue.record("Expected .sent after retry, got \(stored.deliveryState)")
        }
        #expect(await service.sentEnvelopes().count == 1)
    }

    @Test func transientFailuresRemainRetryablePastLegacyAttemptLimit() async throws {
        let store = InMemoryStore()
        let crypto = DevelopmentPlaintextCryptoEngine(explicitlyAllowInsecurePlaintext: true)
        let service = LoopbackTransport()
        let events = ClientEventHub()
        try await service.connect(account: Self.account)
        await service.failNextSends(4)

        let sender = MessageSender(store: store, router: DevelopmentRecipientRouter(), events: events)
        let outbox = OutboxProcessor(
            store: store,
            crypto: crypto,
            transport: service,
            backoff: BackoffPolicy(initialDelay: 0, maximumDelay: 0, maximumAttempts: 2),
            events: events,
            diagnostics: DiagnosticsRecorder()
        )
        await outbox.configure(account: Self.account)
        let messageID = try await sender.enqueue(
            draft: MessageDraft(text: "survive outage"),
            conversation: ConversationSeed(
                id: .direct(with: "remote"),
                kind: .direct(recipientID: "remote"),
                title: "Remote"
            ),
            account: Self.account
        )

        for _ in 0..<4 {
            #expect(await outbox.flushOnce().scheduledForRetry == 1)
        }
        #expect(try await store.statistics().pendingOutboxCount == 1)
        if case .failedRetryable = try #require(try await store.loadMessage(id: messageID)).deliveryState {
        } else {
            Issue.record("Transient send became permanent")
        }

        #expect(await outbox.flushOnce().sent == 1)
        #expect(try await store.statistics().pendingOutboxCount == 0)
    }

    @Test func manualRetryBypassesOutstandingBackoff() async throws {
        let store = InMemoryStore()
        let crypto = DevelopmentPlaintextCryptoEngine(explicitlyAllowInsecurePlaintext: true)
        let service = LoopbackTransport()
        let events = ClientEventHub()
        try await service.connect(account: Self.account)
        await service.failNextSends(1)

        let sender = MessageSender(store: store, router: DevelopmentRecipientRouter(), events: events)
        let outbox = OutboxProcessor(
            store: store,
            crypto: crypto,
            transport: service,
            backoff: BackoffPolicy(initialDelay: 3_600, maximumDelay: 3_600),
            events: events,
            diagnostics: DiagnosticsRecorder()
        )
        await outbox.configure(account: Self.account)
        _ = try await sender.enqueue(
            draft: MessageDraft(text: "retry now"),
            conversation: ConversationSeed(
                id: .direct(with: "remote"),
                kind: .direct(recipientID: "remote"),
                title: "Remote"
            ),
            account: Self.account
        )

        #expect(await outbox.flushOnce().scheduledForRetry == 1)
        #expect(await outbox.flushOnce().attempted == 0)
        #expect(await outbox.retryPending().sent == 1)
    }

    @Test func permanentMutationFailureRollsBackOptimisticReaction() async throws {
        let store = InMemoryStore()
        let crypto = DevelopmentPlaintextCryptoEngine(explicitlyAllowInsecurePlaintext: true)
        let events = ClientEventHub()
        let sender = MessageSender(store: store, router: DevelopmentRecipientRouter(), events: events)
        let conversation = ConversationSeed(
            id: .direct(with: "remote"),
            kind: .direct(recipientID: "remote"),
            title: "Remote"
        )
        let messageID = try await sender.enqueue(
            draft: MessageDraft(text: "original"),
            conversation: conversation,
            account: Self.account
        )
        try await store.completeOutboxItem(messageID: messageID, serverTimestamp: Date())
        _ = try await sender.enqueueReaction(messageID: messageID, emoji: "👍", account: Self.account)
        #expect(try await store.loadMessage(id: messageID)?.reactions.map(\.emoji) == ["👍"])

        let outbox = OutboxProcessor(
            store: store,
            crypto: crypto,
            transport: AuthenticationRejectingTransport(),
            backoff: BackoffPolicy(initialDelay: 0, maximumDelay: 0),
            events: events,
            diagnostics: DiagnosticsRecorder()
        )
        await outbox.configure(account: Self.account)

        #expect(await outbox.flushOnce().permanentlyFailed == 1)
        #expect(try await store.loadMessage(id: messageID)?.reactions.isEmpty == true)
        #expect(try await store.statistics().pendingOutboxCount == 0)
    }
}

private actor AuthenticationRejectingTransport: ServiceTransport {
    func connect(account: LinkedAccount) async throws {}
    func disconnect(reason: OfflineReason) async {}

    func connectionStates() async -> AsyncStream<TransportConnectionState> {
        AsyncStream { $0.yield(.connected) }
    }

    func incomingEnvelopes() async -> AsyncStream<EncryptedEnvelope> {
        AsyncStream { _ in }
    }

    func send(_ envelope: EncryptedEnvelope) async throws -> TransportSendReceipt {
        throw TransportError.authenticationRejected
    }
}
