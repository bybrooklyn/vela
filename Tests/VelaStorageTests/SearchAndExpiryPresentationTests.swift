import Foundation
import Testing

@testable import VelaDomain
@testable import VelaStorage

/// Store behavior directly visible in search results and conversation previews.
/// Both implementations run the same contracts so test doubles cannot teach UI
/// code behavior that production SQLite does not have.
@Suite struct SearchAndExpiryPresentationTests {
    @Test func inMemorySearchPresentationContract() async throws {
        try await assertSearchPresentationContract(InMemoryStore())
    }

    @Test func sQLiteSearchPresentationContract() async throws {
        try await withSQLiteStore { store in
            try await assertSearchPresentationContract(store)
        }
    }

    @Test func inMemoryExpiryPresentationContract() async throws {
        try await assertExpiryPresentationContract(InMemoryStore())
    }

    @Test func sQLiteExpiryPresentationContract() async throws {
        try await withSQLiteStore { store in
            try await assertExpiryPresentationContract(store)
        }
    }

    private func assertSearchPresentationContract(_ store: any ClientStore) async throws {
        try await store.migrate()
        let seed = ConversationSeed(id: "search", kind: .direct(recipientID: "remote"), title: "Remote")

        try await insertIncoming(
            id: "old-needle",
            text: "Alpha needle",
            sentAt: Date(timeIntervalSince1970: 10),
            seed: seed,
            store: store
        )
        try await insertIncoming(
            id: "new-needle",
            text: "new NEEDLE result",
            sentAt: Date(timeIntervalSince1970: 30),
            seed: seed,
            store: store
        )
        try await insertIncoming(
            id: "percent",
            text: "100% ready",
            sentAt: Date(timeIntervalSince1970: 20),
            seed: seed,
            store: store
        )
        try await insertIncoming(
            id: "underscore",
            text: "literal_underbar",
            sentAt: Date(timeIntervalSince1970: 25),
            seed: seed,
            store: store
        )

        let spoilerText = "Meet launch-code-8249 at lobby"
        let hidden = (spoilerText as NSString).range(of: "launch-code-8249")
        let spoilerContent = MessageContent.styledText(
            spoilerText,
            [try #require(TextStyleRange(nsRange: hidden, style: .spoiler))]
        )
        let spoilerMessage = ChatMessage(
            id: "spoiler",
            conversationID: seed.id,
            senderID: "remote",
            direction: .incoming,
            content: spoilerContent,
            sentAt: Date(timeIntervalSince1970: 40),
            deliveryState: .delivered(at: Date(timeIntervalSince1970: 40))
        )
        _ = try await store.persistIncoming(
            message: spoilerMessage,
            conversationSeed: seed,
            envelopeID: "envelope-spoiler",
            incrementUnread: true
        )

        let trimmed = try await store.searchMessages(query: "  needle\n", limit: 10)
        #expect(trimmed.map(\.id) == [MessageID("new-needle"), MessageID("old-needle")])

        let limited = try await store.searchMessages(query: "needle", limit: 1)
        #expect(limited.map(\.id) == [MessageID("new-needle")])

        let percent = try await store.searchMessages(query: "%", limit: 10)
        #expect(percent.map(\.id) == [MessageID("percent")])

        let underscore = try await store.searchMessages(query: "_", limit: 10)
        #expect(underscore.map(\.id) == [MessageID("underscore")])

        #expect(try await store.searchMessages(query: " \n\t ", limit: 10).isEmpty)
        #expect(try await store.searchMessages(query: "needle", limit: 0).isEmpty)

        let preview = try #require(try await store.loadConversation(id: seed.id)?.lastMessage?.text)
        #expect(preview == spoilerContent.privacySafePreviewText)
        #expect(!preview.contains("launch-code-8249"))
        #expect(try await store.searchMessages(query: "launch-code-8249", limit: 10).isEmpty)
        #expect(try await store.searchMessages(query: "lobby", limit: 10).map(\.id) == [spoilerMessage.id])
    }

    private func assertExpiryPresentationContract(_ store: any ClientStore) async throws {
        try await store.migrate()
        let seed = ConversationSeed(id: "expiry", kind: .direct(recipientID: "remote"), title: "Remote")
        let cutoff = Date(timeIntervalSince1970: 100)

        try await insertIncoming(
            id: "retained",
            text: "retained preview",
            sentAt: Date(timeIntervalSince1970: 10),
            seed: seed,
            store: store
        )

        let expiring = ChatMessage(
            id: "expiring",
            conversationID: seed.id,
            senderID: "local",
            direction: .outgoing,
            content: .text("temporary preview"),
            sentAt: Date(timeIntervalSince1970: 20),
            deliveryState: .queued,
            expiresAt: cutoff
        )
        let outbox = OutboxItem(
            messageID: expiring.id,
            destination: DeviceAddress(recipientID: "remote", deviceID: "remote-device"),
            plaintextPayload: Data("temporary preview".utf8),
            createdAt: expiring.sentAt,
            nextAttemptAt: expiring.sentAt
        )
        try await store.persistOutgoing(message: expiring, conversationSeed: seed, outboxItem: outbox)

        #expect(try await store.loadConversation(id: seed.id)?.lastMessage?.text == "temporary preview")
        #expect(try await store.removeExpiredMessages(at: cutoff.addingTimeInterval(-0.001)) == 0)
        #expect(try await store.loadMessage(id: expiring.id) != nil)

        #expect(try await store.removeExpiredMessages(at: cutoff) == 1)
        #expect(try await store.loadMessage(id: expiring.id) == nil)
        #expect(try await store.loadConversation(id: seed.id)?.lastMessage?.text == "retained preview")
        #expect(try await store.loadDueOutbox(at: cutoff, limit: 10).isEmpty)
    }

    private func insertIncoming(
        id: MessageID,
        text: String,
        sentAt: Date,
        seed: ConversationSeed,
        store: any ClientStore
    ) async throws {
        let message = ChatMessage(
            id: id,
            conversationID: seed.id,
            senderID: "remote",
            direction: .incoming,
            content: .text(text),
            sentAt: sentAt,
            deliveryState: .delivered(at: sentAt)
        )
        _ = try await store.persistIncoming(
            message: message,
            conversationSeed: seed,
            envelopeID: EnvelopeID("envelope-\(id.rawValue)"),
            incrementUnread: true
        )
    }

    private func withSQLiteStore(
        _ body: (SQLiteStore) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vela-presentation-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteStore(
            url: directory.appendingPathComponent("test.sqlite"),
            security: .plaintextDevelopmentOnly
        )
        try await body(store)
    }
}
