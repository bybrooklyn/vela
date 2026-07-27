import Foundation
import VelaCrypto

/// Synchronous libsignal callback storage backed by Vela's SQLCipher database.
///
/// libsignal's store protocols are synchronous, so this object owns a separate
/// full-mutex SQLite connection instead of blocking on `SQLiteStore`'s actor.
/// `BEGIN IMMEDIATE` preserves atomic compare-and-insert behavior across other
/// processes or connections to the same database.
public final class SQLiteLibSignalRecordPersistence: LibSignalRecordPersistence, @unchecked Sendable {
    private let connection: SQLiteConnection
    private let lock = NSLock()

    public init(url: URL, security: DatabaseSecurity) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let connection = try SQLiteConnection(path: url.path)
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
        try connection.execute(
            """
            CREATE TABLE IF NOT EXISTS libsignal_records (
                account_id TEXT NOT NULL,
                record_namespace TEXT NOT NULL,
                record_key BLOB NOT NULL,
                payload BLOB NOT NULL,
                PRIMARY KEY(account_id, record_namespace, record_key)
            ) WITHOUT ROWID;
            """
        )
        self.connection = connection
    }

    public func load(_ key: LibSignalRecordKey) throws -> Data? {
        try lock.withLock {
            try loadLocked(key)
        }
    }

    public func replace(_ value: Data, for key: LibSignalRecordKey) throws -> Data? {
        try lock.withLock {
            try transactionLocked {
                let prior = try loadLocked(key)
                try connection.withStatement(
                    """
                    INSERT INTO libsignal_records(account_id, record_namespace, record_key, payload)
                    VALUES(?, ?, ?, ?)
                    ON CONFLICT(account_id, record_namespace, record_key)
                    DO UPDATE SET payload = excluded.payload;
                    """
                ) { statement in
                    try bind(key, to: statement)
                    try connection.bind(value, to: statement, index: 4)
                    try connection.expectDone(statement)
                }
                return prior
            }
        }
    }

    public func remove(_ key: LibSignalRecordKey) throws {
        try lock.withLock {
            try connection.withStatement(
                """
                DELETE FROM libsignal_records
                WHERE account_id = ? AND record_namespace = ? AND record_key = ?;
                """
            ) { statement in
                try bind(key, to: statement)
                try connection.expectDone(statement)
            }
        }
    }

    public func insertIfAbsent(_ value: Data, for key: LibSignalRecordKey) throws -> Bool {
        try lock.withLock {
            try transactionLocked {
                guard try loadLocked(key) == nil else { return false }
                try connection.withStatement(
                    """
                    INSERT INTO libsignal_records(account_id, record_namespace, record_key, payload)
                    VALUES(?, ?, ?, ?);
                    """
                ) { statement in
                    try bind(key, to: statement)
                    try connection.bind(value, to: statement, index: 4)
                    try connection.expectDone(statement)
                }
                return true
            }
        }
    }

    private func loadLocked(_ key: LibSignalRecordKey) throws -> Data? {
        try connection.withStatement(
            """
            SELECT payload FROM libsignal_records
            WHERE account_id = ? AND record_namespace = ? AND record_key = ?
            LIMIT 1;
            """
        ) { statement in
            try bind(key, to: statement)
            switch try connection.step(statement) {
            case .row:
                return connection.columnData(statement, index: 0)
            case .done:
                return nil
            }
        }
    }

    private func bind(_ key: LibSignalRecordKey, to statement: OpaquePointer) throws {
        try connection.bind(key.accountID, to: statement, index: 1)
        try connection.bind(key.namespace.rawValue, to: statement, index: 2)
        try connection.bind(Self.encodeComponents(key.components), to: statement, index: 3)
    }

    private func transactionLocked<T>(_ operation: () throws -> T) throws -> T {
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

    private static func encodeComponents(_ components: [Data]) throws -> Data {
        guard let componentCount = UInt32(exactly: components.count) else {
            throw StoreError.constraintViolation("libsignal-record-component-count")
        }

        var encoded = Data()
        encoded.append(contentsOf: bigEndianBytes(componentCount))
        for component in components {
            guard let byteCount = UInt32(exactly: component.count) else {
                throw StoreError.constraintViolation("libsignal-record-component-size")
            }
            encoded.append(contentsOf: bigEndianBytes(byteCount))
            encoded.append(component)
        }
        return encoded
    }

    private static func bigEndianBytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ]
    }
}
