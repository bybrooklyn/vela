import Foundation
import Testing
import VelaDomain

@testable import VelaSignalCLI

@Suite(.serialized) struct ContactSyncTests {
    @Test func decodesContactWithLocalAndProfileNames() throws {
        let value = JSONValue.object([
            "number": .string("+15550001111"),
            "uuid": .string("8a1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5d"),
            "givenName": .string("Ada"),
            "familyName": .string("Lovelace"),
            "profile": .object([
                "givenName": .string("Ada L."),
                "familyName": .string(""),
            ]),
            "isBlocked": .bool(false),
        ])

        let contact = try #require(SignalCLIContactSync.contact(from: value, now: Date()))
        // The ACI is canonical: numbers change hands and can be withheld, so
        // keying identity on them is what let one person occupy two threads.
        #expect(contact.recipientID == RecipientID("8a1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5d"))
        #expect(contact.aci == "8a1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5d")
        #expect(contact.phoneNumber == "+15550001111")
        // A locally set name wins over the contact's published profile name.
        #expect(contact.displayName == "Ada Lovelace")
        #expect(contact.initials == "AL")
        #expect(contact.hasResolvedName)
    }

    @Test func fallsBackThroughProfileThenNumber() throws {
        let profileOnly = JSONValue.object([
            "number": .string("+15552223333"),
            "profile": .object(["givenName": .string("Grace"), "familyName": .string("Hopper")]),
        ])
        let contact = try #require(SignalCLIContactSync.contact(from: profileOnly, now: Date()))
        #expect(contact.displayName == "Grace Hopper")

        let bare = JSONValue.object(["number": .string("+15554445555")])
        let unnamed = try #require(SignalCLIContactSync.contact(from: bare, now: Date()))
        // With nothing to show, the identifier is the display name — and the UI
        // uses that to decide not to override the conversation title.
        #expect(unnamed.displayName == "+15554445555")
        #expect(!unnamed.hasResolvedName)
        #expect(unnamed.initials == "+")
    }

    @Test func contactWithoutAnyIdentifierIsRejected() {
        #expect(SignalCLIContactSync.contact(from: .object(["givenName": .string("Nobody")]), now: Date()) == nil)
        #expect(SignalCLIContactSync.contact(from: .object(["number": .string("")]), now: Date()) == nil)
    }

    @Test func blockedFlagIsCarriedThrough() throws {
        let value = JSONValue.object([
            "number": .string("+15556667777"),
            "blocked": .bool(true),
        ])
        let contact = try #require(SignalCLIContactSync.contact(from: value, now: Date()))
        #expect(contact.isBlocked)
    }

    @Test func avatarFileNamesAreFilesystemSafeAndStable() {
        // E.164 numbers and UUIDs both have to produce a usable filename.
        let phone = SignalCLIContactSync.avatarFileName(for: RecipientID("+1555/000?1111"))
        #expect(!phone.contains("/"))
        #expect(!phone.contains("?"))
        #expect(!phone.contains("+"))
        #expect(phone == SignalCLIContactSync.avatarFileName(for: RecipientID("+1555/000?1111")))

        let uuid = SignalCLIContactSync.avatarFileName(for: RecipientID("8a1b2c3d-4e5f-4a6b"))
        #expect(uuid != phone)
    }

    @Test func fetchContactsParsesAListFromTheBackend() async throws {
        let peer = try FakeSignalCLIPeer { method, _ in
            guard method == "listContacts" else { return .success(.null) }
            return .success(
                .array([
                    .object(["number": .string("+15550001111"), "givenName": .string("Ada")]),
                    .object(["number": .string("+15552223333"), "givenName": .string("Grace")]),
                    // Unusable rows are skipped rather than failing the sync.
                    .object(["givenName": .string("Broken")]),
                ]))
        }
        defer { peer.stop() }

        let client = JSONRPCClient()
        try await client.connect(socketPath: peer.socketPath)
        defer { Task { await client.disconnect() } }

        let contacts = try await SignalCLIContactSync(client: client).fetchContacts()
        #expect(contacts.count == 2)
        #expect(contacts.map(\.displayName) == ["Ada", "Grace"])
    }

    @Test func malformedContactResultDoesNotMasqueradeAsEmptySnapshot() async throws {
        let peer = try FakeSignalCLIPeer { method, _ in
            guard method == "listContacts" else { return .success(.null) }
            return .success(.object(["unexpected": .bool(true)]))
        }
        defer { peer.stop() }

        let client = JSONRPCClient()
        try await client.connect(socketPath: peer.socketPath)
        defer { Task { await client.disconnect() } }

        await #expect(throws: JSONRPCClientError.self) {
            _ = try await SignalCLIContactSync(client: client).fetchContacts()
        }
    }
}
