import Foundation
import Testing
import VelaCrypto

@testable import VelaStorage

@Suite struct SQLiteLibSignalRecordPersistenceTests {
    @Test func recordsRoundTripAndRemainPartitioned() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let persistence = try SQLiteLibSignalRecordPersistence(
            url: fixture.databaseURL,
            security: .plaintextDevelopmentOnly
        )
        let first = try LibSignalRecordKey(
            accountID: "first",
            namespace: .session,
            components: [Data("a".utf8), Data("b:c".utf8)]
        )
        let delimiterCollision = try LibSignalRecordKey(
            accountID: "first",
            namespace: .session,
            components: [Data("a:b".utf8), Data("c".utf8)]
        )
        let otherAccount = try LibSignalRecordKey(
            accountID: "second",
            namespace: .session,
            components: first.components
        )

        #expect(try persistence.replace(Data("one".utf8), for: first) == nil)
        #expect(try persistence.replace(Data("two".utf8), for: delimiterCollision) == nil)
        #expect(try persistence.replace(Data("three".utf8), for: otherAccount) == nil)
        #expect(try persistence.load(first) == Data("one".utf8))
        #expect(try persistence.load(delimiterCollision) == Data("two".utf8))
        #expect(try persistence.load(otherAccount) == Data("three".utf8))

        let reopened = try SQLiteLibSignalRecordPersistence(
            url: fixture.databaseURL,
            security: .plaintextDevelopmentOnly
        )
        #expect(try reopened.load(first) == Data("one".utf8))

        #expect(try persistence.replace(Data("updated".utf8), for: first) == Data("one".utf8))
        try persistence.remove(first)
        #expect(try persistence.load(first) == nil)
    }

    @Test func insertIfAbsentIsAtomicAcrossConnections() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let first = try SQLiteLibSignalRecordPersistence(
            url: fixture.databaseURL,
            security: .plaintextDevelopmentOnly
        )
        let second = try SQLiteLibSignalRecordPersistence(
            url: fixture.databaseURL,
            security: .plaintextDevelopmentOnly
        )
        let key = try LibSignalRecordKey(
            accountID: "account",
            namespace: .kyberPreKeyUse,
            components: [Data([1]), Data([2]), Data([3])]
        )

        let insertedCount = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { try first.insertIfAbsent(Data(), for: key) }
            group.addTask { try second.insertIfAbsent(Data(), for: key) }
            var results: [Bool] = []
            for try await result in group {
                results.append(result)
            }
            return results.filter { $0 }.count
        }

        #expect(insertedCount == 1)
    }

    @Test func deleteAllLocalDataAlsoDeletesLibSignalRecords() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let persistence = try SQLiteLibSignalRecordPersistence(
            url: fixture.databaseURL,
            security: .plaintextDevelopmentOnly
        )
        let key = try LibSignalRecordKey(accountID: "account", namespace: .identityKeyPair)
        _ = try persistence.replace(Data("private-key-material".utf8), for: key)

        try await fixture.store.deleteAllLocalData()

        #expect(try persistence.load(key) == nil)
    }

    @Test func sqlCipherEncryptsLibSignalRecordsOnDisk() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vela-libsignal-sqlcipher-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("test.sqlite")
        let security = DatabaseSecurity.sqlCipher(
            key: try DatabaseKey(bytes: Data(repeating: 0xA7, count: 32))
        )
        let store = try SQLiteStore(url: databaseURL, security: security)
        try await store.migrate()
        let persistence = try SQLiteLibSignalRecordPersistence(url: databaseURL, security: security)
        let key = try LibSignalRecordKey(accountID: "account", namespace: .identityKeyPair)
        let secret = Data("needle-libsignal-private-key-984123".utf8)

        _ = try persistence.replace(secret, for: key)
        var encryptedBytes = try Data(contentsOf: databaseURL)
        let writeAheadLogURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        if FileManager.default.fileExists(atPath: writeAheadLogURL.path) {
            encryptedBytes.append(try Data(contentsOf: writeAheadLogURL))
        }

        #expect(encryptedBytes.prefix(16) != Data("SQLite format 3\u{0}".utf8))
        #expect(encryptedBytes.range(of: secret) == nil)
    }

    private func makeFixture() async throws -> (
        directory: URL,
        databaseURL: URL,
        store: SQLiteStore
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vela-libsignal-store-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = directory.appendingPathComponent("test.sqlite")
        let store = try SQLiteStore(url: databaseURL, security: .plaintextDevelopmentOnly)
        try await store.migrate()
        return (directory, databaseURL, store)
    }
}
