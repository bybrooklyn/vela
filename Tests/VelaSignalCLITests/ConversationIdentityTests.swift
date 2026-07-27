import Foundation
import Testing
import VelaDomain

@testable import VelaSignalCLI

/// Regression tests for the two bugs that made Vela unusable in real use:
/// a reply opening a second thread, and your own messages appearing to come
/// from the other person.
@Suite(.serialized) struct ConversationIdentityTests {
    private static let herACI = "11111111-2222-4333-8444-555555555555"
    private static let herNumber = "+15559998888"
    private static let myACI = "99999999-8888-4777-8666-555555555555"
    private static let myNumber = "+16019668473"

    private static var account: LinkedAccount {
        LinkedAccount(
            id: AccountID(myACI),
            localRecipientID: RecipientID(myACI),
            deviceID: "3",
            deviceName: "Mac",
            serviceIdentifier: .aci(UUID(uuidString: myACI)!),
            identityHandle: myACI,
            linkedAt: Date()
        )
    }

    private static var directory: RecipientDirectory {
        var directory = RecipientDirectory()
        directory.associate(aci: herACI, number: herNumber)
        directory.associate(aci: myACI, number: myNumber)
        return directory
    }

    @Test func aReplyLandsInTheConversationWeStartedRatherThanANewOne() throws {
        // What the UI created when the user picked her from the contact list.
        let outbound = ConversationKind.direct(recipientID: RecipientID(Self.herACI))
        let outboundID = ConversationID.of(outbound)

        // Her reply, which signal-cli reports by phone number rather than ACI.
        let inbound = try #require(
            SignalCLIEnvelopeTranslator.translate(
                .object([
                    "envelope": .object([
                        "sourceNumber": .string(Self.herNumber),
                        "timestamp": .integer(1_700_000_000_000),
                        "dataMessage": .object([
                            "timestamp": .integer(1_700_000_000_000),
                            "message": .string("hi back"),
                        ]),
                    ])
                ]),
                account: Self.account,
                directory: Self.directory
            )
        )

        #expect(inbound.wire.conversation.id == outboundID)
    }

    @Test func aSenderReportedByUUIDMatchesOneReportedByNumber() throws {
        func conversationID(for envelope: JSONValue) throws -> ConversationID {
            let translated = try #require(
                SignalCLIEnvelopeTranslator.translate(
                    .object(["envelope": envelope]),
                    account: Self.account,
                    directory: Self.directory
                )
            )
            return translated.wire.conversation.id
        }

        let body = JSONValue.object([
            "timestamp": .integer(1_700_000_000_000),
            "message": .string("hello"),
        ])
        let byNumber = try conversationID(
            for: .object([
                "sourceNumber": .string(Self.herNumber),
                "timestamp": .integer(1_700_000_000_000),
                "dataMessage": body,
            ]))
        let byUUID = try conversationID(
            for: .object([
                "sourceUuid": .string(Self.herACI),
                "timestamp": .integer(1_700_000_001_000),
                "dataMessage": .object([
                    "timestamp": .integer(1_700_000_001_000),
                    "message": .string("hello"),
                ]),
            ]))

        #expect(byNumber == byUUID)
    }

    @Test func aMessageSentFromMyPhoneIsAttributedToMe() throws {
        // Replying on the phone syncs the message back to this linked device.
        let translated = try #require(
            SignalCLIEnvelopeTranslator.translate(
                .object([
                    "envelope": .object([
                        "sourceNumber": .string(Self.myNumber),
                        "sourceUuid": .string(Self.myACI),
                        "timestamp": .integer(1_700_000_002_000),
                        "syncMessage": .object([
                            "sentMessage": .object([
                                "timestamp": .integer(1_700_000_002_000),
                                "destinationNumber": .string(Self.herNumber),
                                "message": .string("sent from my phone"),
                            ])
                        ]),
                    ])
                ]),
                account: Self.account,
                directory: Self.directory
            )
        )

        // Attributed to me, not to her — this is what rendered on the wrong side.
        #expect(translated.wire.senderID == Self.account.localRecipientID)
        // And filed under her thread, because she is who it was sent to.
        #expect(
            translated.wire.conversation.id
                == ConversationID.of(.direct(recipientID: RecipientID(Self.herACI)))
        )
    }

    @Test func myOwnSyncedMessageSharesTheThreadWithHerReply() throws {
        func translate(_ envelope: JSONValue) throws -> ConversationID {
            try #require(
                SignalCLIEnvelopeTranslator.translate(
                    .object(["envelope": envelope]),
                    account: Self.account,
                    directory: Self.directory
                )
            ).wire.conversation.id
        }

        let mine = try translate(
            .object([
                "sourceUuid": .string(Self.myACI),
                "timestamp": .integer(1_700_000_003_000),
                "syncMessage": .object([
                    "sentMessage": .object([
                        "timestamp": .integer(1_700_000_003_000),
                        "destinationUuid": .string(Self.herACI),
                        "message": .string("mine"),
                    ])
                ]),
            ]))
        let hers = try translate(
            .object([
                "sourceNumber": .string(Self.herNumber),
                "timestamp": .integer(1_700_000_004_000),
                "dataMessage": .object([
                    "timestamp": .integer(1_700_000_004_000),
                    "message": .string("hers"),
                ]),
            ]))

        #expect(mine == hers)
    }

    @Test func messagingMyselfResolvesToNoteToSelf() throws {
        let translated = try #require(
            SignalCLIEnvelopeTranslator.translate(
                .object([
                    "envelope": .object([
                        "sourceUuid": .string(Self.myACI),
                        "timestamp": .integer(1_700_000_005_000),
                        "syncMessage": .object([
                            "sentMessage": .object([
                                "timestamp": .integer(1_700_000_005_000),
                                // Reported by number while the account is keyed
                                // by ACI, so this only works via the directory.
                                "destinationNumber": .string(Self.myNumber),
                                "message": .string("note"),
                            ])
                        ]),
                    ])
                ]),
                account: Self.account,
                directory: Self.directory
            )
        )

        #expect(translated.wire.conversation.id == ConversationID.noteToSelf)
        #expect(translated.wire.conversation.kind == .noteToSelf)
    }

    @Test func unknownSendersStillGetAStableThread() throws {
        // Nothing is known about this number yet, but two messages from it must
        // not produce two conversations.
        func translate(_ timestamp: Int64) throws -> ConversationID {
            try #require(
                SignalCLIEnvelopeTranslator.translate(
                    .object([
                        "envelope": .object([
                            "sourceNumber": .string("+15551234567"),
                            "timestamp": .integer(timestamp),
                            "dataMessage": .object([
                                "timestamp": .integer(timestamp),
                                "message": .string("stranger"),
                            ]),
                        ])
                    ]),
                    account: Self.account,
                    directory: RecipientDirectory()
                )
            ).wire.conversation.id
        }

        #expect(try translate(1_700_000_006_000) == (try translate(1_700_000_007_000)))
    }

    @Test func phoneNumberFormattingDoesNotSplitAThread() {
        var directory = RecipientDirectory()
        directory.associate(aci: Self.herACI, number: Self.herNumber)
        // Humans and APIs write the same number differently.
        #expect(directory.canonical(for: "+1 (555) 999-8888") == RecipientID(Self.herACI))
        #expect(directory.canonical(for: Self.herACI.uppercased()) == RecipientID(Self.herACI))
    }
}
