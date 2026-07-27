import CSQLite
import Foundation
import Testing

@testable import VelaDomain
@testable import VelaStorage

@Suite struct PrivacyMigrationTests {
    @Test func versionThreeMigrationRedactsSpoilerIndexesButPreservesPayload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vela-v3-privacy-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("test.sqlite")
        let spoilerText = "Meet launch-code-8249 at lobby"
        let hidden = (spoilerText as NSString).range(of: "launch-code-8249")
        let spoilerContent = MessageContent.styledText(
            spoilerText,
            [try #require(TextStyleRange(nsRange: hidden, style: .spoiler))]
        )
        let sentAt = Date(timeIntervalSince1970: 1_700_000_000)
        let message = ChatMessage(
            id: "legacy-spoiler",
            conversationID: "legacy-conversation",
            senderID: "remote",
            direction: .incoming,
            content: spoilerContent,
            sentAt: sentAt,
            receivedAt: sentAt,
            deliveryState: .delivered(at: sentAt)
        )
        let conversation = Conversation(
            id: message.conversationID,
            kind: .direct(recipientID: message.senderID),
            title: "Remote",
            createdAt: sentAt,
            updatedAt: sentAt,
            lastMessage: MessagePreview(text: spoilerText, timestamp: sentAt, isOutgoing: false),
            unreadCount: 1
        )

        try createVersionThreeDatabase(
            at: databaseURL,
            conversation: conversation,
            message: message,
            rawBodyText: spoilerText
        )
        let legacyState = try databaseState(at: databaseURL, messageID: message.id)
        #expect(legacyState.version == 3)
        #expect(legacyState.bodyText == spoilerText)

        let store = try SQLiteStore(url: databaseURL, security: .plaintextDevelopmentOnly)
        try await store.migrate()

        let migratedState = try databaseState(at: databaseURL, messageID: message.id)
        #expect(migratedState.version == 5)
        #expect(migratedState.bodyText == spoilerContent.privacySafePreviewText)
        #expect(!migratedState.bodyText.contains("launch-code-8249"))

        let migratedConversation = try #require(try await store.loadConversation(id: conversation.id))
        #expect(migratedConversation.lastMessage?.text == spoilerContent.privacySafePreviewText)
        #expect(!(migratedConversation.lastMessage?.text.contains("launch-code-8249") ?? true))

        #expect(try await store.searchMessages(query: "launch-code-8249", limit: 10).isEmpty)
        #expect(try await store.searchMessages(query: "lobby", limit: 10).map(\.id) == [message.id])

        let loadedMessage = try #require(try await store.loadMessage(id: message.id))
        #expect(loadedMessage == message)
        #expect(loadedMessage.content.previewText == spoilerText)
        #expect(loadedMessage.content.privacySafePreviewText == spoilerContent.privacySafePreviewText)
    }

    private func createVersionThreeDatabase(
        at url: URL,
        conversation: Conversation,
        message: ChatMessage,
        rawBodyText: String
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw StoreError.openFailed("v3-privacy-fixture-open")
        }
        defer { sqlite3_close(database) }

        try execute(
            """
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
            CREATE INDEX conversations_sort_idx ON conversations(pinned DESC, updated_at DESC);
            CREATE TABLE messages (
                id TEXT PRIMARY KEY,
                conversation_id TEXT NOT NULL,
                sent_at REAL NOT NULL,
                expires_at REAL,
                body_text TEXT NOT NULL,
                payload BLOB NOT NULL,
                FOREIGN KEY(conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
            );
            CREATE INDEX messages_conversation_time_idx ON messages(conversation_id, sent_at DESC);
            CREATE INDEX messages_expiry_idx ON messages(expires_at) WHERE expires_at IS NOT NULL;
            CREATE TABLE outbox (
                message_id TEXT PRIMARY KEY,
                next_attempt_at REAL NOT NULL,
                created_at REAL NOT NULL,
                payload BLOB NOT NULL
            );
            CREATE INDEX outbox_due_idx ON outbox(next_attempt_at, created_at);
            CREATE TABLE seen_envelopes (
                id TEXT PRIMARY KEY,
                received_at REAL NOT NULL
            );
            CREATE TABLE contacts (
                recipient_id TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                blocked INTEGER NOT NULL DEFAULT 0,
                updated_at REAL NOT NULL,
                payload BLOB NOT NULL
            );
            CREATE INDEX contacts_name_idx ON contacts(blocked, display_name);
            PRAGMA user_version = 3;
            """,
            on: database
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]

        try insertConversation(try encoder.encode(conversation), conversation: conversation, into: database)
        try insertMessage(
            try encoder.encode(message),
            message: message,
            rawBodyText: rawBodyText,
            into: database
        )
    }

    private func insertConversation(
        _ payload: Data,
        conversation: Conversation,
        into database: OpaquePointer
    ) throws {
        let sql =
            "INSERT INTO conversations(id, updated_at, pinned, archived, payload) VALUES(?, ?, ?, ?, ?);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.statementFailed("v3-conversation-prepare")
        }
        defer { sqlite3_finalize(statement) }

        try bind(conversation.id.rawValue, to: statement, index: 1)
        sqlite3_bind_double(statement, 2, conversation.updatedAt.timeIntervalSince1970)
        sqlite3_bind_int(statement, 3, conversation.isPinned ? 1 : 0)
        sqlite3_bind_int(statement, 4, conversation.isArchived ? 1 : 0)
        try bind(payload, to: statement, index: 5)
        try expectDone(statement, category: "v3-conversation-insert")
    }

    private func insertMessage(
        _ payload: Data,
        message: ChatMessage,
        rawBodyText: String,
        into database: OpaquePointer
    ) throws {
        let sql =
            "INSERT INTO messages(id, conversation_id, sent_at, expires_at, body_text, payload) VALUES(?, ?, ?, NULL, ?, ?);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.statementFailed("v3-message-prepare")
        }
        defer { sqlite3_finalize(statement) }

        try bind(message.id.rawValue, to: statement, index: 1)
        try bind(message.conversationID.rawValue, to: statement, index: 2)
        sqlite3_bind_double(statement, 3, message.sentAt.timeIntervalSince1970)
        try bind(rawBodyText, to: statement, index: 4)
        try bind(payload, to: statement, index: 5)
        try expectDone(statement, category: "v3-message-insert")
    }

    private func databaseState(
        at url: URL,
        messageID: MessageID
    ) throws -> (version: Int, bodyText: String) {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw StoreError.openFailed("privacy-state-open")
        }
        defer { sqlite3_close(database) }

        var versionStatement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version;", -1, &versionStatement, nil) == SQLITE_OK,
            let versionStatement
        else {
            throw StoreError.statementFailed("privacy-version-prepare")
        }
        defer { sqlite3_finalize(versionStatement) }
        guard sqlite3_step(versionStatement) == SQLITE_ROW else {
            throw StoreError.statementFailed("privacy-version-read")
        }
        let version = Int(sqlite3_column_int(versionStatement, 0))

        var bodyStatement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database,
                "SELECT body_text FROM messages WHERE id = ?;",
                -1,
                &bodyStatement,
                nil
            ) == SQLITE_OK,
            let bodyStatement
        else {
            throw StoreError.statementFailed("privacy-body-prepare")
        }
        defer { sqlite3_finalize(bodyStatement) }
        try bind(messageID.rawValue, to: bodyStatement, index: 1)
        guard sqlite3_step(bodyStatement) == SQLITE_ROW, let rawText = sqlite3_column_text(bodyStatement, 0) else {
            throw StoreError.statementFailed("privacy-body-read")
        }
        return (version, String(cString: rawText))
    }

    private func execute(_ sql: String, on database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        if let errorMessage { sqlite3_free(errorMessage) }
        guard result == SQLITE_OK else {
            throw StoreError.statementFailed("privacy-fixture-schema-\(result)")
        }
    }

    private func bind(_ value: String, to statement: OpaquePointer, index: Int32) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let result = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
        guard result == SQLITE_OK else {
            throw StoreError.statementFailed("privacy-text-bind-\(index)")
        }
    }

    private func bind(_ value: Data, to statement: OpaquePointer, index: Int32) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient)
        }
        guard result == SQLITE_OK else {
            throw StoreError.statementFailed("privacy-blob-bind-\(index)")
        }
    }

    private func expectDone(_ statement: OpaquePointer, category: String) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.statementFailed(category)
        }
    }
}
