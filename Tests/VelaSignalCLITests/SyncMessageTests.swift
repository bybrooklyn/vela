import Foundation
import Testing
import VelaDomain

@testable import VelaSignalCLI

/// What arrives under `syncMessage` is our own account acting on another device.
/// Getting these wrong is silent: nothing errors, the state simply never
/// changes in Vela.
@Suite struct SyncMessageTests {
    private let account = LinkedAccount(
        id: "acct",
        localRecipientID: "me",
        deviceID: "2",
        deviceName: "Mac",
        serviceIdentifier: .opaque("me"),
        identityHandle: "me",
        linkedAt: Date()
    )

    private func translate(_ envelope: JSONValue) -> SignalCLIEnvelopeTranslator.Translated? {
        SignalCLIEnvelopeTranslator.translate(
            .object(["envelope": envelope]),
            account: account,
            directory: RecipientDirectory()
        )
    }

    private func translateParams(_ params: JSONValue) -> SignalCLIEnvelopeTranslator.Translated? {
        SignalCLIEnvelopeTranslator.translate(
            params,
            account: account,
            directory: RecipientDirectory()
        )
    }

    // MARK: - Read state from the phone

    @Test func readMessagesSyncBecomesAReadSync() throws {
        let translated = try #require(
            translate(
                .object([
                    "sourceNumber": .string("+15550001111"),
                    "timestamp": .integer(1_700_000_005_000),
                    "syncMessage": .object([
                        "readMessages": .array([
                            .object([
                                "sender": .string("+15552223333"),
                                "timestamp": .integer(1_700_000_000_000),
                            ]),
                            .object([
                                "sender": .string("+15554445555"),
                                "timestamp": .integer(1_700_000_001_000),
                            ]),
                        ])
                    ]),
                ])
            )
        )

        #expect(translated.wire.kind == .readSync)
        // Both messages that were read must be carried, or only one thread
        // clears.
        let targets = ControlPayload(wire: translated.wire).targets
        #expect(targets.count == 2)
        #expect(targets.contains(SignalCLIMessageIndex.messageID(forSignalTimestamp: 1_700_000_000_000)))
        #expect(targets.contains(SignalCLIMessageIndex.messageID(forSignalTimestamp: 1_700_000_001_000)))
    }

    @Test func subscribedReadSyncUnwrapsResultEnvelope() throws {
        let translated = try #require(
            translateParams(
                .object([
                    "subscription": .integer(0),
                    "result": .object([
                        "envelope": .object([
                            "sourceNumber": .string("+15550001111"),
                            "timestamp": .integer(1_700_000_005_000),
                            "syncMessage": .object([
                                "readMessages": .array([
                                    .object(["timestamp": .integer(1_700_000_000_000)])
                                ])
                            ]),
                        ])
                    ]),
                ])
            )
        )

        #expect(translated.wire.kind == .readSync)
        #expect(
            ControlPayload(wire: translated.wire).targets
                == [SignalCLIMessageIndex.messageID(forSignalTimestamp: 1_700_000_000_000)]
        )
    }

    @Test func readSyncIsAttributedToUsRatherThanTheMessageSender() throws {
        let translated = try #require(
            translate(
                .object([
                    "sourceNumber": .string("+15552223333"),
                    "timestamp": .integer(1_700_000_005_000),
                    "syncMessage": .object([
                        "readMessages": .array([
                            .object([
                                "sender": .string("+15552223333"),
                                "timestamp": .integer(1_700_000_000_000),
                            ])
                        ])
                    ]),
                ])
            )
        )

        // We read it, not them. Attributing it to the sender would make it
        // indistinguishable from their read receipt for our message.
        #expect(translated.wire.senderID == account.localRecipientID)
    }

    @Test func anEmptyReadListIsNotASync() {
        // Falls through rather than producing a sync that marks nothing read.
        #expect(
            translate(
                .object([
                    "sourceNumber": .string("+15550001111"),
                    "timestamp": .integer(1_700_000_005_000),
                    "syncMessage": .object(["readMessages": .array([])]),
                ])
            ) == nil
        )
    }

    @Test func aSentMessageSyncStillTranslates() throws {
        // The read branch runs first, so it must not shadow this one.
        let translated = try #require(
            translate(
                .object([
                    "sourceNumber": .string("+15550001111"),
                    "timestamp": .integer(1_700_000_000_000),
                    "syncMessage": .object([
                        "sentMessage": .object([
                            "destinationNumber": .string("+15552223333"),
                            "timestamp": .integer(1_700_000_000_000),
                            "message": .string("sent from my phone"),
                        ])
                    ]),
                ])
            )
        )

        #expect(translated.wire.kind == .text)
        #expect(translated.wire.body == "sent from my phone")
        // Ours, so it renders as outgoing rather than as the other person.
        #expect(translated.wire.senderID == account.localRecipientID)
    }

    // MARK: - Removing a reaction

    @Test func aRemovedReactionRetainsEmojiAndCarriesRemovalFlag() throws {
        let translated = try #require(
            translate(
                .object([
                    "sourceNumber": .string("+15552223333"),
                    "timestamp": .integer(1_700_000_002_000),
                    "dataMessage": .object([
                        "timestamp": .integer(1_700_000_002_000),
                        "reaction": .object([
                            "emoji": .string("👍"),
                            "targetSentTimestamp": .integer(1_700_000_000_000),
                            "isRemove": .bool(true),
                        ]),
                    ]),
                ])
            )
        )

        // Previously dropped outright, which left a reaction removed on the
        // phone stuck on screen in Vela forever.
        #expect(translated.wire.kind == .reaction)
        #expect(translated.wire.body == "👍")
        #expect(translated.wire.isReactionRemoval == true)
        #expect(
            translated.wire.targetMessageID
                == SignalCLIMessageIndex.messageID(forSignalTimestamp: 1_700_000_000_000)
        )
    }

    @Test func anAddedReactionStillCarriesItsEmoji() throws {
        let translated = try #require(
            translate(
                .object([
                    "sourceNumber": .string("+15552223333"),
                    "timestamp": .integer(1_700_000_002_000),
                    "dataMessage": .object([
                        "timestamp": .integer(1_700_000_002_000),
                        "reaction": .object([
                            "emoji": .string("👍"),
                            "targetSentTimestamp": .integer(1_700_000_000_000),
                            "isRemove": .bool(false),
                        ]),
                    ]),
                ])
            )
        )

        #expect(translated.wire.kind == .reaction)
        #expect(translated.wire.body == "👍")
        #expect(translated.wire.isReactionRemoval == false)
    }

    // MARK: - Disappearing messages

    @Test func incomingDisappearingMessageCarriesDurationNotStaleDeadline() throws {
        let translated = try #require(
            translate(
                .object([
                    "sourceNumber": .string("+15552223333"),
                    "timestamp": .integer(1_700_000_000_000),
                    "dataMessage": .object([
                        "timestamp": .integer(1_700_000_000_000),
                        "message": .string("temporary"),
                        "expiresInSeconds": .integer(60),
                    ]),
                ])
            )
        )

        #expect(translated.wire.expiresIn == 60)
        #expect(translated.wire.expiresAt == nil)
    }

    @Test func expirationTimerUpdateBecomesConversationControl() throws {
        let translated = try #require(
            translate(
                .object([
                    "sourceNumber": .string("+15552223333"),
                    "timestamp": .integer(1_700_000_000_000),
                    "dataMessage": .object([
                        "timestamp": .integer(1_700_000_000_000),
                        "expiresInSeconds": .integer(3_600),
                        "isExpirationUpdate": .bool(true),
                    ]),
                ])
            )
        )

        #expect(translated.wire.kind == .expirationUpdate)
        #expect(translated.wire.expiresIn == 3_600)
    }

    @Test func areactionWithoutATargetIsRejected() {
        // Nothing to attach it to; better dropped than attached to a guess.
        #expect(
            translate(
                .object([
                    "sourceNumber": .string("+15552223333"),
                    "timestamp": .integer(1_700_000_002_000),
                    "dataMessage": .object([
                        "timestamp": .integer(1_700_000_002_000),
                        "reaction": .object(["emoji": .string("👍"), "isRemove": .bool(true)]),
                    ]),
                ])
            ) == nil
        )
    }
}
