import CSQLite
import Foundation
import Testing

@testable import VelaDomain
@testable import VelaStorage

@Suite struct StorageTests {
    @Test func inMemoryStoreDeduplicatesIncomingEnvelope() async throws {
        let store = InMemoryStore()
        let seed = ConversationSeed(
            id: "conversation",
            kind: .direct(recipientID: "remote"),
            title: "Remote"
        )
        let message = ChatMessage(
            id: "message",
            conversationID: seed.id,
            senderID: "remote",
            direction: .incoming,
            content: .text("hello"),
            sentAt: Date(timeIntervalSince1970: 10),
            receivedAt: Date(timeIntervalSince1970: 11),
            deliveryState: .delivered(at: Date(timeIntervalSince1970: 11))
        )

        let firstInsert = try await store.persistIncoming(
            message: message, conversationSeed: seed, envelopeID: "envelope", incrementUnread: true)
        let duplicateInsert = try await store.persistIncoming(
            message: message, conversationSeed: seed, envelopeID: "envelope", incrementUnread: true)
        #expect(firstInsert)
        #expect(!(duplicateInsert))

        let stats = try await store.statistics()
        let loadedConversation = try await store.loadConversation(id: seed.id)
        #expect(stats.messageCount == 1)
        #expect(stats.seenEnvelopeCount == 1)
        #expect(loadedConversation?.unreadCount == 1)
    }

    @Test func sQLiteRoundTripAndOutboxCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vela-storage-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteStore(
            url: directory.appendingPathComponent("test.sqlite"),
            security: .plaintextDevelopmentOnly
        )
        try await store.migrate()

        let account = LinkedAccount(
            id: "account",
            localRecipientID: "local",
            deviceID: "device",
            deviceName: "Test Mac",
            serviceIdentifier: .opaque("test"),
            identityHandle: "keychain-reference",
            linkedAt: Date(timeIntervalSince1970: 1)
        )
        try await store.saveLinkedAccount(account)

        let seed = ConversationSeed(
            id: "conversation",
            kind: .direct(recipientID: "remote"),
            title: "Remote"
        )
        let message = ChatMessage(
            id: "message",
            conversationID: seed.id,
            senderID: account.localRecipientID,
            direction: .outgoing,
            content: .text("persist me"),
            sentAt: Date(timeIntervalSince1970: 20),
            deliveryState: .queued
        )
        let item = OutboxItem(
            messageID: message.id,
            destination: DeviceAddress(recipientID: "remote", deviceID: "remote-device"),
            plaintextPayload: Data("payload".utf8),
            createdAt: message.sentAt,
            nextAttemptAt: message.sentAt
        )

        try await store.persistOutgoing(message: message, conversationSeed: seed, outboxItem: item)
        let loadedAccount = try await store.loadLinkedAccount()
        let loadedMessages = try await store.loadMessages(conversationID: seed.id, before: nil, limit: 10)
        let dueItems = try await store.loadDueOutbox(at: Date(timeIntervalSince1970: 21), limit: 10)
        #expect(loadedAccount == account)
        #expect(loadedMessages.count == 1)
        #expect(dueItems.count == 1)

        let acceptedAt = Date(timeIntervalSince1970: 22)
        try await store.completeOutboxItem(messageID: message.id, serverTimestamp: acceptedAt)
        let maybeUpdated = try await store.loadMessage(id: message.id)
        let updated = try #require(maybeUpdated)
        let finalStats = try await store.statistics()
        #expect(updated.deliveryState == .sent(serverTimestamp: acceptedAt))
        #expect(finalStats.pendingOutboxCount == 0)
    }

    @Test func migratesVersionOneOutboxForControlEnvelopes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vela-v1-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("test.sqlite")
        try createVersionOneDatabase(at: databaseURL)

        let store = try SQLiteStore(url: databaseURL, security: .plaintextDevelopmentOnly)
        try await store.migrate()

        let seed = ConversationSeed(id: "c", kind: .direct(recipientID: "remote"), title: "Remote")
        let message = ChatMessage(
            id: "message",
            conversationID: seed.id,
            senderID: "local",
            direction: .outgoing,
            content: .text("before"),
            sentAt: Date(timeIntervalSince1970: 1),
            deliveryState: .queued
        )
        let original = OutboxItem(
            messageID: message.id,
            destination: DeviceAddress(recipientID: "remote", deviceID: "phone"),
            plaintextPayload: Data("message".utf8),
            createdAt: message.sentAt,
            nextAttemptAt: message.sentAt
        )
        try await store.persistOutgoing(message: message, conversationSeed: seed, outboxItem: original)
        try await store.completeOutboxItem(messageID: message.id, serverTimestamp: Date(timeIntervalSince1970: 2))

        var edited = message
        edited.content = .text("after")
        edited.revision = 1
        let control = OutboxItem(
            messageID: "control-without-visible-message",
            destination: DeviceAddress(recipientID: "remote", deviceID: "phone"),
            plaintextPayload: Data("edit".utf8),
            createdAt: Date(timeIntervalSince1970: 3),
            nextAttemptAt: Date(timeIntervalSince1970: 3)
        )
        try await store.persistOutgoingMutation(targetMessage: edited, outboxItem: control)
        let due = try await store.loadDueOutbox(at: Date(timeIntervalSince1970: 4), limit: 10)
        #expect(due.map(\.messageID) == [control.messageID])
    }

    @Test func sQLiteMutationAndControlEnvelopePersistence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vela-mutation-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(
            url: directory.appendingPathComponent("test.sqlite"),
            security: .plaintextDevelopmentOnly
        )
        try await store.migrate()

        let seed = ConversationSeed(id: "c", kind: .direct(recipientID: "remote"), title: "Remote")
        let original = ChatMessage(
            id: "message",
            conversationID: seed.id,
            senderID: "local",
            direction: .outgoing,
            content: .text("before"),
            sentAt: Date(timeIntervalSince1970: 1),
            deliveryState: .sent(serverTimestamp: Date(timeIntervalSince1970: 2))
        )
        let originalOutbox = OutboxItem(
            messageID: original.id,
            destination: DeviceAddress(recipientID: "remote", deviceID: "phone"),
            plaintextPayload: Data("original".utf8),
            createdAt: original.sentAt,
            nextAttemptAt: original.sentAt
        )
        try await store.persistOutgoing(message: original, conversationSeed: seed, outboxItem: originalOutbox)
        try await store.completeOutboxItem(messageID: original.id, serverTimestamp: Date(timeIntervalSince1970: 2))

        var edited = original
        edited.content = .text("after")
        edited.revision = 1
        let control = OutboxItem(
            messageID: "edit-control",
            destination: DeviceAddress(recipientID: "remote", deviceID: "phone"),
            plaintextPayload: Data("edit".utf8),
            createdAt: Date(timeIntervalSince1970: 3),
            nextAttemptAt: Date(timeIntervalSince1970: 3)
        )
        try await store.persistOutgoingMutation(targetMessage: edited, outboxItem: control)

        let loaded = try await store.loadMessage(id: edited.id)
        let conversation = try await store.loadConversation(id: seed.id)
        let due = try await store.loadDueOutbox(at: Date(timeIntervalSince1970: 4), limit: 10)
        #expect(loaded?.content == .text("after"))
        #expect(loaded?.revision == 1)
        #expect(conversation?.lastMessage?.text == "after")
        #expect(due.map(\.messageID) == [control.messageID])

        let incoming = try await store.persistIncomingMutation(
            targetMessage: edited,
            envelopeID: "mutation-envelope",
            receivedAt: Date(timeIntervalSince1970: 5)
        )
        let duplicate = try await store.persistIncomingMutation(
            targetMessage: edited,
            envelopeID: "mutation-envelope",
            receivedAt: Date(timeIntervalSince1970: 6)
        )
        #expect(incoming)
        #expect(!(duplicate))
    }

    @Test func permanentlyFailedMutationRollsBackOptimisticTarget() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vela-mutation-rollback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(
            url: directory.appendingPathComponent("test.sqlite"),
            security: .plaintextDevelopmentOnly
        )
        try await store.migrate()

        let seed = ConversationSeed(id: "c", kind: .direct(recipientID: "remote"), title: "Remote")
        let original = ChatMessage(
            id: "message",
            conversationID: seed.id,
            senderID: "local",
            direction: .outgoing,
            content: .text("before"),
            sentAt: Date(timeIntervalSince1970: 1),
            deliveryState: .read(at: Date(timeIntervalSince1970: 2))
        )
        let initial = OutboxItem(
            messageID: original.id,
            destination: DeviceAddress(recipientID: "remote", deviceID: "phone"),
            plaintextPayload: Data("original".utf8),
            createdAt: original.sentAt,
            nextAttemptAt: original.sentAt
        )
        try await store.persistOutgoing(message: original, conversationSeed: seed, outboxItem: initial)
        try await store.completeOutboxItem(messageID: original.id, serverTimestamp: original.sentAt)

        var edited = original
        edited.content = .text("after")
        edited.revision = 1
        let control = OutboxItem(
            messageID: "edit-control",
            destination: initial.destination,
            plaintextPayload: Data("edit".utf8),
            createdAt: Date(timeIntervalSince1970: 3),
            nextAttemptAt: Date(timeIntervalSince1970: 3),
            mutationTargetID: original.id,
            rollbackTarget: original
        )
        try await store.persistOutgoingMutation(targetMessage: edited, outboxItem: control)
        try await store.permanentlyFailOutboxItem(messageID: control.messageID, category: "rejected")

        #expect(try await store.loadMessage(id: original.id) == original)
        #expect(try await store.loadConversation(id: seed.id)?.lastMessage?.text == "before")
        #expect((try await store.statistics()).pendingOutboxCount == 0)
    }

    @Test func olderOutboxPayloadDecodesWithoutMutationRollbackFields() throws {
        let item = OutboxItem(
            messageID: "legacy",
            destination: DeviceAddress(recipientID: "remote", deviceID: "phone"),
            plaintextPayload: Data("payload".utf8),
            createdAt: Date(timeIntervalSince1970: 1),
            nextAttemptAt: Date(timeIntervalSince1970: 2)
        )
        let encoded = try JSONEncoder().encode(item)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "mutationTargetID")
        object.removeValue(forKey: "rollbackTarget")
        let legacyPayload = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(OutboxItem.self, from: legacyPayload)
        #expect(decoded.messageID == item.messageID)
        #expect(decoded.mutationTargetID == nil)
        #expect(decoded.rollbackTarget == nil)
    }

    @Test func contactSnapshotReplacementRemovesStaleAndAcceptsEmpty() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vela-contact-replace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var stores: [any ClientStore] = [
            InMemoryStore(),
            try SQLiteStore(
                url: directory.appendingPathComponent("test.sqlite"),
                security: .plaintextDevelopmentOnly
            ),
        ]

        for store in stores {
            try await store.migrate()
            let stale = Contact(recipientID: "stale", givenName: "Stale", updatedAt: .distantPast)
            let current = Contact(recipientID: "current", givenName: "Current", updatedAt: .distantPast)
            try await store.replaceContacts([stale, current])
            try await store.replaceContacts([current])
            #expect(try await store.loadContact(recipientID: stale.recipientID) == nil)
            #expect(try await store.loadContacts(includeBlocked: true) == [current])

            try await store.replaceContacts([])
            #expect(try await store.loadContacts(includeBlocked: true).isEmpty)
        }
        stores.removeAll()
        try FileManager.default.removeItem(at: directory)
    }

    @Test func expiredMessagesAreRemoved() async throws {
        let store = InMemoryStore()
        let seed = ConversationSeed(id: "c", kind: .direct(recipientID: "r"), title: "R")
        let message = ChatMessage(
            id: "m",
            conversationID: seed.id,
            senderID: "r",
            direction: .incoming,
            content: .text("temporary"),
            sentAt: Date(timeIntervalSince1970: 1),
            deliveryState: .delivered(at: Date(timeIntervalSince1970: 1)),
            expiresAt: Date(timeIntervalSince1970: 2)
        )
        _ = try await store.persistIncoming(message: message, conversationSeed: seed, envelopeID: "e", incrementUnread: true)
        let removed = try await store.removeExpiredMessages(at: Date(timeIntervalSince1970: 3))
        let loaded = try await store.loadMessage(id: message.id)
        #expect(removed == 1)
        #expect(loaded == nil)
    }

    @Test func sQLCipherEncryptsTheDatabaseOnDisk() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vela-sqlcipher-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("test.sqlite")
        let key = try DatabaseKey(bytes: Data(repeating: 0xA5, count: 32))

        let store = try SQLiteStore(url: databaseURL, security: .sqlCipher(key: key))
        try await store.migrate()
        try await store.saveLinkedAccount(
            LinkedAccount(
                id: "account",
                localRecipientID: "local",
                deviceID: "mac",
                deviceName: "Mac",
                serviceIdentifier: .opaque("local"),
                identityHandle: "handle",
                linkedAt: Date()
            )
        )

        // An unencrypted SQLite file starts with this exact magic. Its absence
        // is what proves the pages on disk are actually enciphered.
        let header = try Data(contentsOf: databaseURL).prefix(16)
        #expect(header != Data("SQLite format 3\u{0}".utf8))
    }

    @Test func sQLCipherRejectsTheWrongKey() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vela-sqlcipher-key-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("test.sqlite")

        let store = try SQLiteStore(
            url: databaseURL,
            security: .sqlCipher(key: try DatabaseKey(bytes: Data(repeating: 0xA5, count: 32)))
        )
        try await store.migrate()

        // Opening with a different key must fail rather than silently yielding
        // an empty database, which would look like data loss.
        await #expect(throws: (any Error).self) {
            let wrong = try SQLiteStore(
                url: databaseURL,
                security: .sqlCipher(key: try DatabaseKey(bytes: Data(repeating: 0x5A, count: 32)))
            )
            _ = try await wrong.statistics()
        }
    }

    @Test func deleteAllLocalDataClearsRowsAndPlaintextPages() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vela-delete-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("test.sqlite")
        let store = try SQLiteStore(url: databaseURL, security: .plaintextDevelopmentOnly)
        try await store.migrate()

        let account = LinkedAccount(
            id: "account",
            localRecipientID: "local",
            deviceID: "mac",
            deviceName: "Mac",
            serviceIdentifier: .opaque("local"),
            identityHandle: "identity",
            linkedAt: .distantPast
        )
        try await store.saveLinkedAccount(account)
        let seed = ConversationSeed(id: "conversation", kind: .direct(recipientID: "remote"), title: "Remote")
        let secret = "needle-private-message-732849"
        let message = ChatMessage(
            id: "message",
            conversationID: seed.id,
            senderID: account.localRecipientID,
            direction: .outgoing,
            content: .text(secret),
            sentAt: Date(),
            deliveryState: .queued
        )
        let outbox = OutboxItem(
            messageID: message.id,
            destination: DeviceAddress(recipientID: "remote", deviceID: "device"),
            plaintextPayload: Data(secret.utf8),
            createdAt: message.sentAt,
            nextAttemptAt: message.sentAt
        )
        try await store.persistOutgoing(message: message, conversationSeed: seed, outboxItem: outbox)

        try await store.deleteAllLocalData()
        let statistics = try await store.statistics()
        #expect(statistics.accountCount == 0)
        #expect(statistics.conversationCount == 0)
        #expect(statistics.messageCount == 0)
        #expect(statistics.pendingOutboxCount == 0)
        let remainingAccount = try await store.loadLinkedAccount()
        #expect(remainingAccount == nil)

        let bytes = try Data(contentsOf: databaseURL)
        #expect(bytes.range(of: Data(secret.utf8)) == nil)
    }

    private func createVersionOneDatabase(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw StoreError.openFailed("v1-fixture-open")
        }
        defer { sqlite3_close(database) }
        let sql = """
            PRAGMA foreign_keys = ON;
            CREATE TABLE linked_account (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                payload BLOB NOT NULL
            );
            CREATE TABLE conversations (
                id TEXT PRIMARY KEY,
                updated_at REAL NOT NULL,
                pinned INTEGER NOT NULL DEFAULT 0,
                archived INTEGER NOT NULL DEFAULT 0,
                payload BLOB NOT NULL
            );
            CREATE TABLE messages (
                id TEXT PRIMARY KEY,
                conversation_id TEXT NOT NULL,
                sent_at REAL NOT NULL,
                expires_at REAL,
                body_text TEXT NOT NULL,
                payload BLOB NOT NULL,
                FOREIGN KEY(conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
            );
            CREATE TABLE outbox (
                message_id TEXT PRIMARY KEY,
                next_attempt_at REAL NOT NULL,
                created_at REAL NOT NULL,
                payload BLOB NOT NULL,
                FOREIGN KEY(message_id) REFERENCES messages(id) ON DELETE CASCADE
            );
            CREATE INDEX outbox_due_idx ON outbox(next_attempt_at, created_at);
            CREATE TABLE seen_envelopes (
                id TEXT PRIMARY KEY,
                received_at REAL NOT NULL
            );
            PRAGMA user_version = 1;
            """
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        if let errorMessage { sqlite3_free(errorMessage) }
        guard result == SQLITE_OK else {
            throw StoreError.migrationFailed("v1-fixture-code-\(result)")
        }
    }

}
