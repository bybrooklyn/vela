import Foundation
import Testing

@testable import VelaDomain

/// Clustering decides both the gap between bubbles and which one carries the
/// timestamp, so the boundaries have to be exact. The values mirror Signal's
/// `canClusterMessages`.
@Suite struct MessageClusteringTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private let alice = RecipientID("alice")
    private let bob = RecipientID("bob")

    private func message(
        _ name: String,
        from sender: RecipientID,
        direction: MessageDirection = .incoming,
        secondsAfterBase: TimeInterval,
        reactions: [MessageReaction] = []
    ) -> ChatMessage {
        ChatMessage(
            id: MessageID(name),
            conversationID: ConversationID("thread"),
            senderID: sender,
            direction: direction,
            content: .text(name),
            sentAt: base.addingTimeInterval(secondsAfterBase),
            deliveryState: .sent(serverTimestamp: base),
            reactions: reactions
        )
    }

    private func reaction(at seconds: TimeInterval) -> MessageReaction {
        MessageReaction(authorID: bob, emoji: "👍", createdAt: base.addingTimeInterval(seconds))
    }

    // MARK: - The window

    @Test func messagesInsideTheWindowCluster() {
        let first = message("a", from: alice, secondsAfterBase: 0)
        let second = message("b", from: alice, secondsAfterBase: 2 * 60 + 59)
        #expect(MessageClustering.continuesRun(second, after: first))
    }

    @Test func messagesOutsideTheWindowDoNot() {
        let first = message("a", from: alice, secondsAfterBase: 0)
        let second = message("b", from: alice, secondsAfterBase: 3 * 60 + 1)
        #expect(!MessageClustering.continuesRun(second, after: first))
    }

    @Test func theWindowBoundaryItselfIsExclusive() {
        let first = message("a", from: alice, secondsAfterBase: 0)
        let second = message("b", from: alice, secondsAfterBase: MessageClustering.window)
        #expect(!MessageClustering.continuesRun(second, after: first))
    }

    // MARK: - Author and direction

    @Test func aDifferentSenderBreaksTheRunHoweverClose() {
        let first = message("a", from: alice, secondsAfterBase: 0)
        let second = message("b", from: bob, secondsAfterBase: 1)
        #expect(!MessageClustering.continuesRun(second, after: first))
    }

    @Test func aDifferentDirectionBreaksTheRun() {
        // Note to Self: the same identifier speaks in both directions, so
        // sender alone is not enough to tell a run apart.
        let sent = message("a", from: alice, direction: .outgoing, secondsAfterBase: 0)
        let received = message("b", from: alice, direction: .incoming, secondsAfterBase: 1)
        #expect(!MessageClustering.continuesRun(received, after: sent))
    }

    @Test func theFirstMessageNeverContinuesAnything() {
        let only = message("a", from: alice, secondsAfterBase: 0)
        #expect(!MessageClustering.continuesRun(only, after: nil))
    }

    // MARK: - Reactions

    @Test func areactionOnTheEarlierMessageBreaksTheRun() {
        // The reaction pill hangs below its bubble; a message tucked underneath
        // would collide with it.
        let first = message("a", from: alice, secondsAfterBase: 0, reactions: [reaction(at: 5)])
        let second = message("b", from: alice, secondsAfterBase: 10)
        #expect(!MessageClustering.continuesRun(second, after: first))
    }

    @Test func areactionOnTheLaterMessageDoesNot() {
        let first = message("a", from: alice, secondsAfterBase: 0)
        let second = message("b", from: alice, secondsAfterBase: 10, reactions: [reaction(at: 20)])
        #expect(MessageClustering.continuesRun(second, after: first))
    }

    // MARK: - Clock skew

    @Test func aMessageStampedSlightlyEarlierStillClusters() {
        // Another device's clock can run behind ours; the gap is a magnitude,
        // not a signed difference, or a run would split on skew alone.
        let first = message("a", from: alice, secondsAfterBase: 30)
        let second = message("b", from: alice, secondsAfterBase: 0)
        #expect(MessageClustering.continuesRun(second, after: first))
    }

    // MARK: - Positions across a group

    @Test func asingleMessageIsAlone() {
        let positions = MessageClustering.positions(for: [
            message("a", from: alice, secondsAfterBase: 0)
        ])
        #expect(positions == [.single])
    }

    @Test func arunOfThreeOpensFillsAndCloses() {
        let positions = MessageClustering.positions(for: [
            message("a", from: alice, secondsAfterBase: 0),
            message("b", from: alice, secondsAfterBase: 10),
            message("c", from: alice, secondsAfterBase: 20),
        ])
        #expect(positions == [.first, .middle, .last])
    }

    @Test func alternatingSpeakersAreAllSingles() {
        let positions = MessageClustering.positions(for: [
            message("a", from: alice, secondsAfterBase: 0),
            message("b", from: bob, secondsAfterBase: 10),
            message("c", from: alice, secondsAfterBase: 20),
        ])
        #expect(positions == [.single, .single, .single])
    }

    @Test func atimeGapSplitsOneSpeakerIntoTwoRuns() {
        let positions = MessageClustering.positions(for: [
            message("a", from: alice, secondsAfterBase: 0),
            message("b", from: alice, secondsAfterBase: 10),
            // Past the window, so this opens a new run.
            message("c", from: alice, secondsAfterBase: 10 + 4 * 60),
            message("d", from: alice, secondsAfterBase: 20 + 4 * 60),
        ])
        #expect(positions == [.first, .last, .first, .last])
    }

    @Test func runStartAndEndAgreeWithPosition() {
        let positions = MessageClustering.positions(for: [
            message("a", from: alice, secondsAfterBase: 0),
            message("b", from: alice, secondsAfterBase: 10),
            message("c", from: alice, secondsAfterBase: 20),
        ])
        #expect(positions.map(\.isRunStart) == [true, false, false])
        // Only the last of a run renders a timestamp and delivery status.
        #expect(positions.map(\.isRunEnd) == [false, false, true])
    }

    @Test func anEmptyGroupHasNoPositions() {
        #expect(MessageClustering.positions(for: []).isEmpty)
    }
}
