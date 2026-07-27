import CSQLite
import Foundation
import VelaCrypto
import VelaDomain

public actor SQLiteStore: ClientStore {
    private let connection: SQLiteConnection
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL, security: DatabaseSecurity) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        self.connection = try SQLiteConnection(path: url.path)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder

        // SQLCipher requires the key before any operation that reads database pages.
        switch security {
        case .plaintextDevelopmentOnly:
            break
        case .sqlCipher(let key):
            let keyHex = key.bytes.map { String(format: "%02x", $0) }.joined()
            try connection.execute("PRAGMA key = \"x'\(keyHex)'\";")
            let version = try connection.singleText("PRAGMA cipher_version;")
            guard let version, !version.isEmpty else {
                throw StoreError.sqlCipherUnavailable
            }
        }

        try connection.execute("PRAGMA foreign_keys = ON;")
        try connection.execute("PRAGMA secure_delete = ON;")
        try connection.execute("PRAGMA journal_mode = WAL;")
        try connection.execute("PRAGMA synchronous = FULL;")
        try connection.execute("PRAGMA busy_timeout = 5000;")
    }

    public func migrate() async throws {
        do {
            let versionText = try connection.singleText("PRAGMA user_version;") ?? "0"
            guard let version = Int(versionText), version <= 5 else {
                throw StoreError.migrationFailed("unsupported-schema-version")
            }

            if version == 0 {
                try transaction {
                    try connection.execute(
                        """
                        CREATE TABLE IF NOT EXISTS linked_account (
                            singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                            payload BLOB NOT NULL
                        );

                        CREATE TABLE IF NOT EXISTS conversations (
                            id TEXT PRIMARY KEY,
                            updated_at REAL NOT NULL,
                            pinned INTEGER NOT NULL DEFAULT 0,
                            archived INTEGER NOT NULL DEFAULT 0,
                            payload BLOB NOT NULL
                        );

                        CREATE INDEX IF NOT EXISTS conversations_sort_idx
                        ON conversations(pinned DESC, updated_at DESC);

                        CREATE TABLE IF NOT EXISTS messages (
                            id TEXT PRIMARY KEY,
                            conversation_id TEXT NOT NULL,
                            sent_at REAL NOT NULL,
                            expires_at REAL,
                            body_text TEXT NOT NULL,
                            payload BLOB NOT NULL,
                            FOREIGN KEY(conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
                        );

                        CREATE INDEX IF NOT EXISTS messages_conversation_time_idx
                        ON messages(conversation_id, sent_at DESC);

                        CREATE INDEX IF NOT EXISTS messages_expiry_idx
                        ON messages(expires_at) WHERE expires_at IS NOT NULL;

                        CREATE TABLE IF NOT EXISTS outbox (
                            message_id TEXT PRIMARY KEY,
                            next_attempt_at REAL NOT NULL,
                            created_at REAL NOT NULL,
                            payload BLOB NOT NULL
                        );

                        CREATE INDEX IF NOT EXISTS outbox_due_idx
                        ON outbox(next_attempt_at, created_at);

                        CREATE TABLE IF NOT EXISTS seen_envelopes (
                            id TEXT PRIMARY KEY,
                            received_at REAL NOT NULL
                        );

                        PRAGMA user_version = 2;
                        """
                    )
                }
            } else if version == 1 {
                // Version 1 tied every outbox row to a visible message row. Signal
                // edits, deletes, reactions, receipts, and sync controls also need
                // durable outbox rows, so version 2 deliberately removes that FK.
                try transaction {
                    try connection.execute(
                        """
                        DROP INDEX IF EXISTS outbox_due_idx;
                        CREATE TABLE outbox_v2 (
                            message_id TEXT PRIMARY KEY,
                            next_attempt_at REAL NOT NULL,
                            created_at REAL NOT NULL,
                            payload BLOB NOT NULL
                        );
                        INSERT INTO outbox_v2(message_id, next_attempt_at, created_at, payload)
                            SELECT message_id, next_attempt_at, created_at, payload FROM outbox;
                        DROP TABLE outbox;
                        ALTER TABLE outbox_v2 RENAME TO outbox;
                        CREATE INDEX outbox_due_idx ON outbox(next_attempt_at, created_at);
                        PRAGMA user_version = 2;
                        """
                    )
                }
            }

            // Version 3 adds the contact cache. It is a mirror of what the
            // primary device knows, so it is safe to drop and re-sync; nothing
            // else references it.
            if version <= 2 {
                try transaction {
                    try connection.execute(
                        """
                        CREATE TABLE IF NOT EXISTS contacts (
                            recipient_id TEXT PRIMARY KEY,
                            display_name TEXT NOT NULL,
                            blocked INTEGER NOT NULL DEFAULT 0,
                            updated_at REAL NOT NULL,
                            payload BLOB NOT NULL
                        );

                        CREATE INDEX IF NOT EXISTS contacts_name_idx
                        ON contacts(blocked, display_name);

                        PRAGMA user_version = 3;
                        """
                    )
                }
            }

            // Version 4 makes compact previews and the searchable index safe
            // for messages containing Signal spoiler ranges. Full bodies remain
            // in encrypted payloads for explicit timeline reveal.
            if version <= 3 {
                try transaction {
                    try rebuildPrivacySafePreviewsAndSearchIndexSync()
                    try connection.execute("PRAGMA user_version = 4;")
                }
            }

            // Version 5 stores only libsignal's opaque serialized records. The
            // account, namespace and length-prefixed component key form the
            // complete primary key; SQLCipher protects every payload page.
            if version <= 4 {
                try transaction {
                    try connection.execute(
                        """
                        CREATE TABLE IF NOT EXISTS libsignal_records (
                            account_id TEXT NOT NULL,
                            record_namespace TEXT NOT NULL,
                            record_key BLOB NOT NULL,
                            payload BLOB NOT NULL,
                            PRIMARY KEY(account_id, record_namespace, record_key)
                        ) WITHOUT ROWID;

                        PRAGMA user_version = 5;
                        """
                    )
                }
            }
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.migrationFailed(Self.category(error))
        }
    }

    public func loadLinkedAccount() async throws -> LinkedAccount? {
        let sql = "SELECT payload FROM linked_account WHERE singleton = 1 LIMIT 1;"
        return try connection.withStatement(sql) { statement in
            switch try connection.step(statement) {
            case .row:
                return try decode(LinkedAccount.self, from: connection.columnData(statement, index: 0))
            case .done:
                return nil
            }
        }
    }

    public func saveLinkedAccount(_ account: LinkedAccount) async throws {
        let payload = try encode(account)
        let sql =
            "INSERT INTO linked_account(singleton, payload) VALUES(1, ?) ON CONFLICT(singleton) DO UPDATE SET payload = excluded.payload;"
        try connection.withStatement(sql) { statement in
            try connection.bind(payload, to: statement, index: 1)
            try connection.expectDone(statement)
        }
    }

    public func deleteAllLocalData() async throws {
        try transaction {
            try connection.execute("DELETE FROM outbox;")
            try connection.execute("DELETE FROM messages;")
            try connection.execute("DELETE FROM conversations;")
            try connection.execute("DELETE FROM seen_envelopes;")
            try connection.execute("DELETE FROM contacts;")
            try connection.execute("DELETE FROM libsignal_records;")
            try connection.execute("DELETE FROM linked_account;")
        }

        // Ensure deleted pages are not retained in the WAL or freelist. Release
        // builds additionally protect the file with SQLCipher; this path also
        // makes the development database deletion semantics testable.
        try connection.execute("PRAGMA wal_checkpoint(TRUNCATE);")
        try connection.execute("VACUUM;")
    }

    public func loadConversations(includeArchived: Bool) async throws -> [Conversation] {
        let sql =
            includeArchived
            ? "SELECT payload FROM conversations ORDER BY pinned DESC, updated_at DESC, id ASC;"
            : "SELECT payload FROM conversations WHERE archived = 0 ORDER BY pinned DESC, updated_at DESC, id ASC;"
        return try connection.withStatement(sql) { statement in
            var result: [Conversation] = []
            while true {
                switch try connection.step(statement) {
                case .row:
                    result.append(try decode(Conversation.self, from: connection.columnData(statement, index: 0)))
                case .done:
                    return result
                }
            }
        }
    }

    public func loadConversation(id: ConversationID) async throws -> Conversation? {
        try loadConversationSync(id: id)
    }

    public func loadMessages(conversationID: ConversationID, before: Date?, limit: Int) async throws -> [ChatMessage] {
        let boundedLimit = max(0, limit)
        let sql: String
        if before == nil {
            sql = "SELECT payload FROM messages WHERE conversation_id = ? ORDER BY sent_at DESC LIMIT ?;"
        } else {
            sql = "SELECT payload FROM messages WHERE conversation_id = ? AND sent_at < ? ORDER BY sent_at DESC LIMIT ?;"
        }

        return try connection.withStatement(sql) { statement in
            try connection.bind(conversationID.rawValue, to: statement, index: 1)
            if let before {
                try connection.bind(before.timeIntervalSince1970, to: statement, index: 2)
                try connection.bind(Int64(boundedLimit), to: statement, index: 3)
            } else {
                try connection.bind(Int64(boundedLimit), to: statement, index: 2)
            }

            var descending: [ChatMessage] = []
            while true {
                switch try connection.step(statement) {
                case .row:
                    descending.append(try decode(ChatMessage.self, from: connection.columnData(statement, index: 0)))
                case .done:
                    return descending.reversed()
                }
            }
        }
    }

    public func loadMessage(id: MessageID) async throws -> ChatMessage? {
        try loadMessageSync(id: id)
    }

    public func searchMessages(query: String, limit: Int) async throws -> [ChatMessage] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let escaped = Self.escapeForLike(trimmed)

        let sql = "SELECT payload FROM messages WHERE body_text LIKE ? ESCAPE '\\' ORDER BY sent_at DESC LIMIT ?;"
        return try connection.withStatement(sql) { statement in
            try connection.bind("%\(escaped)%", to: statement, index: 1)
            try connection.bind(Int64(max(0, limit)), to: statement, index: 2)
            var result: [ChatMessage] = []
            while true {
                switch try connection.step(statement) {
                case .row:
                    result.append(try decode(ChatMessage.self, from: connection.columnData(statement, index: 0)))
                case .done:
                    return result
                }
            }
        }
    }

    public func persistOutgoing(
        message: ChatMessage,
        conversationSeed: ConversationSeed,
        outboxItem: OutboxItem
    ) async throws {
        try transaction {
            let conversation = try updatedConversation(
                seed: conversationSeed,
                message: message,
                incrementUnread: false
            )
            try saveConversationSync(conversation)
            try saveMessageSync(message)
            try saveOutboxSync(outboxItem)
        }
    }

    public func persistIncoming(
        message: ChatMessage,
        conversationSeed: ConversationSeed,
        envelopeID: EnvelopeID,
        incrementUnread: Bool
    ) async throws -> Bool {
        try transaction {
            guard try !hasSeenEnvelopeSync(envelopeID) else { return false }

            let conversation = try updatedConversation(
                seed: conversationSeed,
                message: message,
                incrementUnread: incrementUnread
            )
            try saveConversationSync(conversation)
            try saveMessageSync(message)
            try insertSeenEnvelopeSync(envelopeID, at: message.receivedAt ?? message.sentAt)
            return true
        }
    }

    public func persistOutgoingMutation(
        targetMessage: ChatMessage,
        outboxItem: OutboxItem
    ) async throws {
        try transaction {
            try saveMessageSync(targetMessage)
            try saveOutboxSync(outboxItem)
            try rebuildConversationPreviewSync(targetMessage.conversationID)
        }
    }

    public func persistIncomingMutation(
        targetMessage: ChatMessage,
        envelopeID: EnvelopeID,
        receivedAt: Date
    ) async throws -> Bool {
        try transaction {
            guard try !hasSeenEnvelopeSync(envelopeID) else { return false }
            try saveMessageSync(targetMessage)
            try insertSeenEnvelopeSync(envelopeID, at: receivedAt)
            try rebuildConversationPreviewSync(targetMessage.conversationID)
            return true
        }
    }

    public func recordSeenEnvelope(_ id: EnvelopeID, at date: Date) async throws -> Bool {
        try transaction {
            guard try !hasSeenEnvelopeSync(id) else { return false }
            try insertSeenEnvelopeSync(id, at: date)
            return true
        }
    }

    public func loadDueOutbox(at date: Date, limit: Int) async throws -> [OutboxItem] {
        let sql = "SELECT payload FROM outbox WHERE next_attempt_at <= ? ORDER BY next_attempt_at ASC, created_at ASC LIMIT ?;"
        return try connection.withStatement(sql) { statement in
            try connection.bind(date.timeIntervalSince1970, to: statement, index: 1)
            try connection.bind(Int64(max(0, limit)), to: statement, index: 2)
            var result: [OutboxItem] = []
            while true {
                switch try connection.step(statement) {
                case .row:
                    result.append(try decode(OutboxItem.self, from: connection.columnData(statement, index: 0)))
                case .done:
                    return result
                }
            }
        }
    }

    public func updateOutboxItem(_ item: OutboxItem, messageState: MessageDeliveryState) async throws {
        try transaction {
            try saveOutboxSync(item)
            if var message = try loadMessageSync(id: item.messageID) {
                message.deliveryState = messageState
                try saveMessageSync(message)
            }
        }
    }

    public func completeOutboxItem(messageID: MessageID, serverTimestamp: Date) async throws {
        try transaction {
            try deleteOutboxSync(messageID)
            if var message = try loadMessageSync(id: messageID) {
                message.deliveryState = .sent(serverTimestamp: serverTimestamp)
                try saveMessageSync(message)
            }
        }
    }

    public func permanentlyFailOutboxItem(messageID: MessageID, category: String) async throws {
        try transaction {
            let item = try loadOutboxSync(id: messageID)
            try deleteOutboxSync(messageID)
            if let targetID = item?.mutationTargetID,
                let rollback = item?.rollbackTarget,
                rollback.id == targetID
            {
                try saveMessageSync(rollback)
                try rebuildConversationPreviewSync(rollback.conversationID)
                return
            }
            if var message = try loadMessageSync(id: messageID) {
                message.deliveryState = .failedPermanent(reason: category)
                try saveMessageSync(message)
            }
        }
    }

    public func upsertConversations(_ seeds: [ConversationSeed], at date: Date) async throws {
        guard !seeds.isEmpty else { return }
        try transaction {
            for seed in seeds {
                // Refresh the name and membership without disturbing local state
                // such as unread count, pin or archive.
                if var existing = try loadConversationSync(id: seed.id) {
                    existing.kind = seed.kind
                    existing.title = seed.title
                    try saveConversationSync(existing)
                } else {
                    try saveConversationSync(.from(seed: seed, at: date))
                }
            }
        }
    }

    public func setConversationDisappearingDuration(
        _ duration: TimeInterval?,
        for id: ConversationID
    ) async throws {
        guard var conversation = try loadConversationSync(id: id) else { return }
        conversation.disappearingMessageDuration = duration
        try saveConversationSync(conversation)
    }

    public func loadContacts(includeBlocked: Bool) async throws -> [Contact] {
        let sql =
            includeBlocked
            ? "SELECT payload FROM contacts ORDER BY display_name COLLATE NOCASE ASC;"
            : "SELECT payload FROM contacts WHERE blocked = 0 ORDER BY display_name COLLATE NOCASE ASC;"
        return try connection.withStatement(sql) { statement in
            var result: [Contact] = []
            while true {
                switch try connection.step(statement) {
                case .row:
                    result.append(try decode(Contact.self, from: connection.columnData(statement, index: 0)))
                case .done:
                    return result
                }
            }
        }
    }

    public func loadContact(recipientID: RecipientID) async throws -> Contact? {
        let sql = "SELECT payload FROM contacts WHERE recipient_id = ? LIMIT 1;"
        return try connection.withStatement(sql) { statement in
            try connection.bind(recipientID.rawValue, to: statement, index: 1)
            switch try connection.step(statement) {
            case .row:
                return try decode(Contact.self, from: connection.columnData(statement, index: 0))
            case .done:
                return nil
            }
        }
    }

    public func replaceContacts(_ contacts: [Contact]) async throws {
        try transaction {
            try connection.execute("DELETE FROM contacts;")
            for contact in contacts {
                try upsertContactSync(contact)
            }
        }
    }

    public func upsertContacts(_ contacts: [Contact]) async throws {
        guard !contacts.isEmpty else { return }
        try transaction {
            for contact in contacts {
                try upsertContactSync(contact)
            }
        }
    }

    public func searchContacts(query: String, limit: Int) async throws -> [Contact] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try await loadContacts(includeBlocked: false) }

        // Escaped so a user typing % or _ searches for those characters rather
        // than turning them into wildcards.
        let pattern = "%" + Self.escapeForLike(trimmed) + "%"
        let sql = """
            SELECT payload FROM contacts
            WHERE blocked = 0 AND display_name LIKE ? ESCAPE '\\'
            ORDER BY display_name COLLATE NOCASE ASC
            LIMIT ?;
            """
        return try connection.withStatement(sql) { statement in
            try connection.bind(pattern, to: statement, index: 1)
            try connection.bind(Int64(limit), to: statement, index: 2)
            var result: [Contact] = []
            while true {
                switch try connection.step(statement) {
                case .row:
                    result.append(try decode(Contact.self, from: connection.columnData(statement, index: 0)))
                case .done:
                    return result
                }
            }
        }
    }

    /// Escapes LIKE wildcards so a user searching for "%" finds a literal "%".
    /// Used with `ESCAPE '\'`.
    private static func escapeForLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private func upsertContactSync(_ contact: Contact) throws {
        let payload = try encode(contact)
        let sql = """
            INSERT INTO contacts(recipient_id, display_name, blocked, updated_at, payload)
            VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(recipient_id) DO UPDATE SET
                display_name = excluded.display_name,
                blocked = excluded.blocked,
                updated_at = excluded.updated_at,
                payload = excluded.payload;
            """
        try connection.withStatement(sql) { statement in
            try connection.bind(contact.recipientID.rawValue, to: statement, index: 1)
            try connection.bind(contact.displayName, to: statement, index: 2)
            try connection.bind(contact.isBlocked ? Int64(1) : Int64(0), to: statement, index: 3)
            try connection.bind(contact.updatedAt.timeIntervalSince1970, to: statement, index: 4)
            try connection.bind(payload, to: statement, index: 5)
            try connection.expectDone(statement)
        }
    }

    public func markConversationRead(_ id: ConversationID, at date: Date) async throws {
        guard var conversation = try loadConversationSync(id: id) else { return }
        conversation.unreadCount = 0
        try saveConversationSync(conversation)
    }

    public func setConversationPinned(_ id: ConversationID, pinned: Bool) async throws {
        guard var conversation = try loadConversationSync(id: id) else { return }
        conversation.isPinned = pinned
        try saveConversationSync(conversation)
    }

    public func setConversationArchived(_ id: ConversationID, archived: Bool) async throws {
        guard var conversation = try loadConversationSync(id: id) else { return }
        conversation.isArchived = archived
        try saveConversationSync(conversation)
    }

    public func removeExpiredMessages(at date: Date) async throws -> Int {
        try transaction {
            let ids = try expiredMessageIDsSync(at: date)
            for id in ids {
                try deleteMessageSync(id)
            }
            try rebuildConversationPreviewsSync()
            return ids.count
        }
    }

    public func statistics() async throws -> StoreStatistics {
        StoreStatistics(
            accountCount: try connection.count("linked_account"),
            conversationCount: try connection.count("conversations"),
            messageCount: try connection.count("messages"),
            pendingOutboxCount: try connection.count("outbox"),
            seenEnvelopeCount: try connection.count("seen_envelopes")
        )
    }

    private func updatedConversation(
        seed: ConversationSeed,
        message: ChatMessage,
        incrementUnread: Bool
    ) throws -> Conversation {
        var conversation = try loadConversationSync(id: seed.id) ?? .from(seed: seed, at: message.sentAt)
        conversation.kind = seed.kind
        conversation.title = seed.title
        conversation.updatedAt = max(conversation.updatedAt, message.sentAt)
        conversation.lastMessage = MessagePreview(
            text: message.content.privacySafePreviewText,
            timestamp: message.sentAt,
            isOutgoing: message.direction == .outgoing
        )
        if incrementUnread {
            conversation.unreadCount += 1
        }
        return conversation
    }

    private func loadConversationSync(id: ConversationID) throws -> Conversation? {
        let sql = "SELECT payload FROM conversations WHERE id = ? LIMIT 1;"
        return try connection.withStatement(sql) { statement in
            try connection.bind(id.rawValue, to: statement, index: 1)
            switch try connection.step(statement) {
            case .row:
                return try decode(Conversation.self, from: connection.columnData(statement, index: 0))
            case .done:
                return nil
            }
        }
    }

    private func saveConversationSync(_ conversation: Conversation) throws {
        let payload = try encode(conversation)
        let sql = """
            INSERT INTO conversations(id, updated_at, pinned, archived, payload)
            VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                updated_at = excluded.updated_at,
                pinned = excluded.pinned,
                archived = excluded.archived,
                payload = excluded.payload;
            """
        try connection.withStatement(sql) { statement in
            try connection.bind(conversation.id.rawValue, to: statement, index: 1)
            try connection.bind(conversation.updatedAt.timeIntervalSince1970, to: statement, index: 2)
            try connection.bind(conversation.isPinned ? Int64(1) : Int64(0), to: statement, index: 3)
            try connection.bind(conversation.isArchived ? Int64(1) : Int64(0), to: statement, index: 4)
            try connection.bind(payload, to: statement, index: 5)
            try connection.expectDone(statement)
        }
    }

    private func loadMessageSync(id: MessageID) throws -> ChatMessage? {
        let sql = "SELECT payload FROM messages WHERE id = ? LIMIT 1;"
        return try connection.withStatement(sql) { statement in
            try connection.bind(id.rawValue, to: statement, index: 1)
            switch try connection.step(statement) {
            case .row:
                return try decode(ChatMessage.self, from: connection.columnData(statement, index: 0))
            case .done:
                return nil
            }
        }
    }

    private func saveMessageSync(_ message: ChatMessage) throws {
        let payload = try encode(message)
        let sql = """
            INSERT INTO messages(id, conversation_id, sent_at, expires_at, body_text, payload)
            VALUES(?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                conversation_id = excluded.conversation_id,
                sent_at = excluded.sent_at,
                expires_at = excluded.expires_at,
                body_text = excluded.body_text,
                payload = excluded.payload;
            """
        try connection.withStatement(sql) { statement in
            try connection.bind(message.id.rawValue, to: statement, index: 1)
            try connection.bind(message.conversationID.rawValue, to: statement, index: 2)
            try connection.bind(message.sentAt.timeIntervalSince1970, to: statement, index: 3)
            if let expiresAt = message.expiresAt {
                try connection.bind(expiresAt.timeIntervalSince1970, to: statement, index: 4)
            } else {
                try connection.bindNull(to: statement, index: 4)
            }
            try connection.bind(message.content.privacySafePreviewText, to: statement, index: 5)
            try connection.bind(payload, to: statement, index: 6)
            try connection.expectDone(statement)
        }
    }

    private func saveOutboxSync(_ item: OutboxItem) throws {
        let payload = try encode(item)
        let sql = """
            INSERT INTO outbox(message_id, next_attempt_at, created_at, payload)
            VALUES(?, ?, ?, ?)
            ON CONFLICT(message_id) DO UPDATE SET
                next_attempt_at = excluded.next_attempt_at,
                created_at = excluded.created_at,
                payload = excluded.payload;
            """
        try connection.withStatement(sql) { statement in
            try connection.bind(item.messageID.rawValue, to: statement, index: 1)
            try connection.bind(item.nextAttemptAt.timeIntervalSince1970, to: statement, index: 2)
            try connection.bind(item.createdAt.timeIntervalSince1970, to: statement, index: 3)
            try connection.bind(payload, to: statement, index: 4)
            try connection.expectDone(statement)
        }
    }

    private func loadOutboxSync(id: MessageID) throws -> OutboxItem? {
        let sql = "SELECT payload FROM outbox WHERE message_id = ? LIMIT 1;"
        return try connection.withStatement(sql) { statement in
            try connection.bind(id.rawValue, to: statement, index: 1)
            switch try connection.step(statement) {
            case .row:
                return try decode(OutboxItem.self, from: connection.columnData(statement, index: 0))
            case .done:
                return nil
            }
        }
    }

    private func deleteOutboxSync(_ messageID: MessageID) throws {
        try connection.withStatement("DELETE FROM outbox WHERE message_id = ?;") { statement in
            try connection.bind(messageID.rawValue, to: statement, index: 1)
            try connection.expectDone(statement)
        }
    }

    private func hasSeenEnvelopeSync(_ id: EnvelopeID) throws -> Bool {
        try connection.withStatement("SELECT 1 FROM seen_envelopes WHERE id = ? LIMIT 1;") { statement in
            try connection.bind(id.rawValue, to: statement, index: 1)
            switch try connection.step(statement) {
            case .row: return true
            case .done: return false
            }
        }
    }

    private func insertSeenEnvelopeSync(_ id: EnvelopeID, at date: Date) throws {
        try connection.withStatement("INSERT INTO seen_envelopes(id, received_at) VALUES(?, ?);") { statement in
            try connection.bind(id.rawValue, to: statement, index: 1)
            try connection.bind(date.timeIntervalSince1970, to: statement, index: 2)
            try connection.expectDone(statement)
        }
    }

    private func expiredMessageIDsSync(at date: Date) throws -> [MessageID] {
        try connection.withStatement("SELECT id FROM messages WHERE expires_at IS NOT NULL AND expires_at <= ?;") { statement in
            try connection.bind(date.timeIntervalSince1970, to: statement, index: 1)
            var result: [MessageID] = []
            while true {
                switch try connection.step(statement) {
                case .row:
                    result.append(MessageID(connection.columnText(statement, index: 0)))
                case .done:
                    return result
                }
            }
        }
    }

    private func deleteMessageSync(_ id: MessageID) throws {
        // Outbox control rows intentionally have no foreign key, because edits,
        // reactions, and receipts do not always map to visible messages. A
        // visible message that expires is different: its matching queued send
        // must disappear with it or Vela could transmit content after expiry.
        try connection.withStatement("DELETE FROM outbox WHERE message_id = ?;") { statement in
            try connection.bind(id.rawValue, to: statement, index: 1)
            try connection.expectDone(statement)
        }
        try connection.withStatement("DELETE FROM messages WHERE id = ?;") { statement in
            try connection.bind(id.rawValue, to: statement, index: 1)
            try connection.expectDone(statement)
        }
    }

    private func rebuildConversationPreviewsSync() throws {
        let conversations = try loadConversationRowsSync()
        for conversation in conversations {
            try rebuildConversationPreviewSync(conversation.id)
        }
    }

    /// Updates user-visible compact text after a privacy-policy migration.
    /// Message payloads remain untouched so the timeline retains formatting and
    /// can reveal spoilers only after an explicit user action.
    private func rebuildPrivacySafePreviewsAndSearchIndexSync() throws {
        let messages = try connection.withStatement("SELECT payload FROM messages;") { statement in
            var result: [ChatMessage] = []
            while true {
                switch try connection.step(statement) {
                case .row:
                    result.append(try decode(ChatMessage.self, from: connection.columnData(statement, index: 0)))
                case .done:
                    return result
                }
            }
        }

        for message in messages {
            try connection.withStatement("UPDATE messages SET body_text = ? WHERE id = ?;") { statement in
                try connection.bind(message.content.privacySafePreviewText, to: statement, index: 1)
                try connection.bind(message.id.rawValue, to: statement, index: 2)
                try connection.expectDone(statement)
            }
        }

        try rebuildConversationPreviewsSync()
    }

    private func rebuildConversationPreviewSync(_ conversationID: ConversationID) throws {
        guard var conversation = try loadConversationSync(id: conversationID) else { return }
        let latest = try latestMessageSync(conversationID: conversation.id)
        conversation.lastMessage = latest.map {
            MessagePreview(
                text: $0.content.privacySafePreviewText,
                timestamp: $0.sentAt,
                isOutgoing: $0.direction == .outgoing
            )
        }
        if let latest {
            conversation.updatedAt = latest.sentAt
        }
        try saveConversationSync(conversation)
    }

    private func loadConversationRowsSync() throws -> [Conversation] {
        try connection.withStatement("SELECT payload FROM conversations;") { statement in
            var result: [Conversation] = []
            while true {
                switch try connection.step(statement) {
                case .row:
                    result.append(try decode(Conversation.self, from: connection.columnData(statement, index: 0)))
                case .done:
                    return result
                }
            }
        }
    }

    private func latestMessageSync(conversationID: ConversationID) throws -> ChatMessage? {
        let sql = "SELECT payload FROM messages WHERE conversation_id = ? ORDER BY sent_at DESC LIMIT 1;"
        return try connection.withStatement(sql) { statement in
            try connection.bind(conversationID.rawValue, to: statement, index: 1)
            switch try connection.step(statement) {
            case .row:
                return try decode(ChatMessage.self, from: connection.columnData(statement, index: 0))
            case .done:
                return nil
            }
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try encoder.encode(value)
        } catch {
            throw StoreError.encodingFailed(Self.category(error))
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw StoreError.decodingFailed(Self.category(error))
        }
    }

    private func transaction<T>(_ operation: () throws -> T) throws -> T {
        try connection.execute("BEGIN IMMEDIATE;")
        do {
            let result = try operation()
            try connection.execute("COMMIT;")
            return result
        } catch {
            try? connection.execute("ROLLBACK;")
            throw error
        }
    }

    private static func category(_ error: any Error) -> String {
        String(reflecting: type(of: error))
    }
}

final class SQLiteConnection {
    private let handle: OpaquePointer

    init(path: String) throws {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw StoreError.openFailed("sqlite-code-\(result)")
        }
        self.handle = database
    }

    deinit {
        sqlite3_close(handle)
    }

    func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        if let errorMessage { sqlite3_free(errorMessage) }
        guard result == SQLITE_OK else {
            throw StoreError.statementFailed("sqlite-code-\(result)")
        }
    }

    func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw StoreError.statementFailed("prepare-code-\(result)")
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    func step(_ statement: OpaquePointer) throws -> StepResult {
        let result = sqlite3_step(statement)
        switch result {
        case SQLITE_ROW: return .row
        case SQLITE_DONE: return .done
        default: throw StoreError.statementFailed("step-code-\(result)")
        }
    }

    func expectDone(_ statement: OpaquePointer) throws {
        guard try step(statement) == .done else {
            throw StoreError.statementFailed("unexpected-row")
        }
    }

    func bind(_ value: String, to statement: OpaquePointer, index: Int32) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let result = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, transient)
        }
        guard result == SQLITE_OK else {
            throw StoreError.statementFailed("bind-text-code-\(result)")
        }
    }

    func bind(_ value: Data, to statement: OpaquePointer, index: Int32) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), transient)
        }
        guard result == SQLITE_OK else {
            throw StoreError.statementFailed("bind-blob-code-\(result)")
        }
    }

    func bind(_ value: Double, to statement: OpaquePointer, index: Int32) throws {
        let result = sqlite3_bind_double(statement, index, value)
        guard result == SQLITE_OK else {
            throw StoreError.statementFailed("bind-double-code-\(result)")
        }
    }

    func bind(_ value: Int64, to statement: OpaquePointer, index: Int32) throws {
        let result = sqlite3_bind_int64(statement, index, value)
        guard result == SQLITE_OK else {
            throw StoreError.statementFailed("bind-int-code-\(result)")
        }
    }

    func bindNull(to statement: OpaquePointer, index: Int32) throws {
        let result = sqlite3_bind_null(statement, index)
        guard result == SQLITE_OK else {
            throw StoreError.statementFailed("bind-null-code-\(result)")
        }
    }

    func columnData(_ statement: OpaquePointer, index: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    func columnText(_ statement: OpaquePointer, index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    func singleText(_ sql: String) throws -> String? {
        try withStatement(sql) { statement in
            switch try step(statement) {
            case .row: return columnText(statement, index: 0)
            case .done: return nil
            }
        }
    }

    func count(_ table: String) throws -> Int {
        let allowed = ["linked_account", "conversations", "messages", "outbox", "seen_envelopes"]
        guard allowed.contains(table) else {
            throw StoreError.constraintViolation("invalid-count-table")
        }
        return try withStatement("SELECT COUNT(*) FROM \(table);") { statement in
            switch try step(statement) {
            case .row: return Int(sqlite3_column_int64(statement, 0))
            case .done: return 0
            }
        }
    }
}

enum StepResult: Equatable {
    case row
    case done
}
