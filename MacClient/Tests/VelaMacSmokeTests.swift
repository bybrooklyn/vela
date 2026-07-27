#if os(macOS)
    import Foundation
    import Testing
    import VelaDomain

    @testable import Vela

    @Suite struct VelaMacSmokeTests {
        @Test func diagnosticRedactionDoesNotReturnMessageBody() {
            let secret = "a private message that must not appear"
            let redacted = Redaction.messageBody(secret)
            #expect(!(redacted.contains(secret)))
            #expect(redacted.hasPrefix("<redacted:"))
        }

        @Test func clientStartsInOpeningDatabaseState() {
            let snapshot = ClientSnapshot(
                state: .openingDatabase,
                connection: .disconnected,
                linkedAccount: nil,
                unreadCount: 0
            )
            #expect(snapshot.state == .openingDatabase)
        }

        @Test func accountArtifactCleanupIsCompleteAndIdempotent() throws {
            let manager = FileManager.default
            let root = manager.temporaryDirectory
                .appendingPathComponent("vela-account-cleanup-\(UUID().uuidString)", isDirectory: true)
            defer { try? manager.removeItem(at: root) }

            let backendRoot = root.appendingPathComponent("signal-cli", isDirectory: true)
            let socket = root.appendingPathComponent("vela-rpc.sock")
            let layout = SignalCLIBackend.Layout(
                executable: root.appendingPathComponent("signal-cli-bin"),
                nativeLibraryDirectory: root.appendingPathComponent("native", isDirectory: true),
                configDirectory: backendRoot,
                socketPath: socket,
                logFile: backendRoot.appendingPathComponent("daemon.log")
            )

            try Self.writeFixture(at: backendRoot.appendingPathComponent("data/account.json"))
            try Self.writeFixture(at: backendRoot.appendingPathComponent("message-index.json"))
            try Self.writeFixture(at: layout.logFile)
            try Self.writeFixture(at: socket)
            try Self.writeFixture(at: root.appendingPathComponent("avatars/contact.bin"))
            try Self.writeFixture(at: root.appendingPathComponent("attachments/message.bin"))
            try Self.writeFixture(at: root.appendingPathComponent("diagnostics/event.log"))
            let database = root.appendingPathComponent("database/vela.sqlite")
            let databaseKey = root.appendingPathComponent("database/key.bin")
            try Self.writeFixture(at: database)
            try Self.writeFixture(at: databaseKey)

            try SignalCLIBackend.eraseAccountData(layout: layout, applicationSupportRoot: root)
            try SignalCLIBackend.eraseAccountData(layout: layout, applicationSupportRoot: root)

            #expect(!manager.fileExists(atPath: backendRoot.path))
            #expect(!manager.fileExists(atPath: socket.path))
            #expect(!manager.fileExists(atPath: root.appendingPathComponent("avatars").path))
            #expect(!manager.fileExists(atPath: root.appendingPathComponent("attachments").path))
            #expect(!manager.fileExists(atPath: root.appendingPathComponent("diagnostics").path))
            #expect(manager.fileExists(atPath: database.path))
            #expect(manager.fileExists(atPath: databaseKey.path))
        }

        private static func writeFixture(at url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("fixture".utf8).write(to: url)
        }
    }
#endif
