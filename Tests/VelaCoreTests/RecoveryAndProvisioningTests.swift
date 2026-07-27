import Foundation
import Testing

@testable import VelaCore
@testable import VelaCrypto
@testable import VelaDomain
@testable import VelaStorage
@testable import VelaTransport

@Suite(.serialized) struct RecoveryAndProvisioningTests {
    @Test func provisioningFailureReturnsToUnlinkedAndRecordsReason() async throws {
        let transport = ImmediateFailureProvisioningTransport(category: "backend-unreachable")
        let client = VelaClient(
            dependencies: VelaClientDependencies(
                store: InMemoryStore(),
                crypto: DevelopmentPlaintextCryptoEngine(explicitlyAllowInsecurePlaintext: true),
                serviceTransport: LoopbackTransport(),
                provisioningTransport: transport,
                recipientRouter: DevelopmentRecipientRouter()
            )
        )

        await client.bootstrap()
        _ = try await client.beginProvisioning(deviceName: "Test Mac")

        try await eventually {
            await client.diagnostics().contains {
                $0.subsystem == "provisioning"
                    && $0.category == "link-failed"
                    && $0.detail == "backend-unreachable"
            }
        }
        #expect(await client.snapshot().state == .unlinked)
        await client.shutdown()
    }

    @Test func startupRecoveryDistinguishesMigrationAndStateFailures() {
        #expect(VelaClient.recoveryReason(for: StoreError.migrationFailed("v4")) == .migrationFailed)
        #expect(VelaClient.recoveryReason(for: StoreError.decodingFailed("account")) == .localStateInconsistent)
        #expect(VelaClient.recoveryReason(for: StoreError.openFailed("locked")) == .databaseCorrupt)
    }

    @Test func bootstrapRemovesMessagesThatExpiredWhileAppWasClosed() async throws {
        let cutoff = Date(timeIntervalSince1970: 100)
        let store = InMemoryStore()
        let conversation = ConversationSeed(
            id: "expiry",
            kind: .direct(recipientID: "remote"),
            title: "Remote"
        )
        let expired = ChatMessage(
            id: "expired",
            conversationID: conversation.id,
            senderID: "remote",
            direction: .incoming,
            content: .text("expired"),
            sentAt: Date(timeIntervalSince1970: 10),
            deliveryState: .delivered(at: Date(timeIntervalSince1970: 10)),
            expiresAt: cutoff
        )
        _ = try await store.persistIncoming(
            message: expired,
            conversationSeed: conversation,
            envelopeID: "expired-envelope",
            incrementUnread: true
        )
        let client = VelaClient(
            dependencies: VelaClientDependencies(
                store: store,
                crypto: DevelopmentPlaintextCryptoEngine(explicitlyAllowInsecurePlaintext: true),
                serviceTransport: LoopbackTransport(),
                provisioningTransport: DevelopmentProvisioningTransport(),
                recipientRouter: DevelopmentRecipientRouter(),
                clock: FixedVelaClock(now: cutoff)
            )
        )

        await client.bootstrap()

        #expect(try await client.messages(in: conversation.id).isEmpty)
        #expect(try await client.conversations().first?.lastMessage == nil)
        await client.shutdown()
    }

    @Test func publicClientCanAddThenRemoveOwnReaction() async throws {
        let store = InMemoryStore()
        let account = LinkedAccount(
            id: "account",
            localRecipientID: "me",
            deviceID: "mac",
            deviceName: "Mac",
            serviceIdentifier: .opaque("me"),
            identityHandle: "development",
            linkedAt: Date(timeIntervalSince1970: 1)
        )
        let conversation = ConversationSeed(
            id: "reaction",
            kind: .direct(recipientID: "remote"),
            title: "Remote"
        )
        let message = ChatMessage(
            id: "message",
            conversationID: conversation.id,
            senderID: "remote",
            direction: .incoming,
            content: .text("hello"),
            sentAt: Date(),
            deliveryState: .delivered(at: Date())
        )
        try await store.saveLinkedAccount(account)
        _ = try await store.persistIncoming(
            message: message,
            conversationSeed: conversation,
            envelopeID: "message-envelope",
            incrementUnread: true
        )
        let client = VelaClient(
            dependencies: VelaClientDependencies(
                store: store,
                crypto: DevelopmentPlaintextCryptoEngine(explicitlyAllowInsecurePlaintext: true),
                serviceTransport: LoopbackTransport(),
                provisioningTransport: DevelopmentProvisioningTransport(),
                recipientRouter: DevelopmentRecipientRouter()
            )
        )
        await client.bootstrap()

        _ = try await client.react(to: message.id, emoji: "👍")
        #expect(try await store.loadMessage(id: message.id)?.reactions.map(\.emoji) == ["👍"])

        _ = try await client.removeReaction(from: message.id)
        #expect(try await store.loadMessage(id: message.id)?.reactions.isEmpty == true)
        await client.shutdown()
    }

    private func eventually(
        timeout: Duration = .seconds(5),
        operation: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        repeat {
            if await operation() { return }
            try await Task.sleep(for: .milliseconds(5))
        } while ContinuousClock.now < deadline
        Issue.record("Condition did not become true within \(timeout)")
    }
}

private actor ImmediateFailureProvisioningTransport: ProvisioningTransport {
    let category: String

    init(category: String) {
        self.category = category
    }

    func begin(deviceName: String) async throws -> ProvisioningSession {
        ProvisioningSession(
            id: .random(),
            linkingURI: URL(string: "vela-test://link")!,
            expiresAt: Date().addingTimeInterval(60)
        )
    }

    func events(sessionID: ProvisioningSessionID) async -> AsyncStream<ProvisioningEvent> {
        AsyncStream { continuation in
            continuation.yield(.awaitingScan)
            continuation.yield(.failed(category: category))
            continuation.finish()
        }
    }

    func cancel(sessionID: ProvisioningSessionID) async {}
}
