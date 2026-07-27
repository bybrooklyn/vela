import Foundation

/// Where a message sits within a run of consecutive messages from one sender.
///
/// Messaging apps do not draw every message as an identical box: consecutive
/// messages tuck into each other by tightening the corners where they meet, and
/// only the last of a run carries a timestamp and delivery status.
public enum MessageClusterPosition: Equatable, Sendable {
    /// Alone in its run.
    case single
    /// Opens a run.
    case first
    /// Inside a run.
    case middle
    /// Closes a run.
    case last

    public var isRunStart: Bool { self == .single || self == .first }
    public var isRunEnd: Bool { self == .single || self == .last }
}

/// Decides which messages tuck together into a run.
///
/// This lives in the domain rather than in the timeline view because it is a
/// rule about messages, not about drawing, and because the view layer is not
/// covered by the test suite.
///
/// The rule matches Signal's `canClusterMessages`: same author, same direction,
/// inside a short window, and the earlier message must carry no reactions.
public enum MessageClustering {
    /// How far apart two messages from one sender can be and still tuck
    /// together. Signal uses three minutes.
    public static let window: TimeInterval = 3 * 60

    /// Whether `message` continues the run that `previous` belongs to.
    ///
    /// - Parameter previous: the message immediately before, or `nil` at the
    ///   start of a day group, which always begins a run.
    public static func continuesRun(
        _ message: ChatMessage,
        after previous: ChatMessage?,
        window: TimeInterval = window
    ) -> Bool {
        guard let previous else { return false }
        // A reaction pill hangs below its bubble and would collide with the one
        // tucked underneath, so a reacted-to message always closes its run.
        guard previous.reactions.isEmpty else { return false }
        guard previous.senderID == message.senderID,
            previous.direction == message.direction
        else { return false }

        // Ordering is not guaranteed across devices with skewed clocks, so
        // compare magnitude rather than assuming the later one is later.
        let gap = abs(message.sentAt.timeIntervalSince(previous.sentAt))
        return gap < window
    }

    /// The run position of every message in a day group, in order.
    public static func positions(
        for messages: [ChatMessage],
        window: TimeInterval = window
    ) -> [MessageClusterPosition] {
        messages.indices.map { index in
            let continues = continuesRun(
                messages[index],
                after: index > 0 ? messages[index - 1] : nil,
                window: window
            )
            let nextContinues =
                index + 1 < messages.count
                && continuesRun(messages[index + 1], after: messages[index], window: window)

            return switch (continues, nextContinues) {
            case (false, false): .single
            case (false, true): .first
            case (true, true): .middle
            case (true, false): .last
            }
        }
    }
}
