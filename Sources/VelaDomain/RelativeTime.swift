import Foundation

/// Short relative timestamps, the way messaging apps label a bubble.
///
/// Deliberately terse — "Now", "19m", "2h" — because it sits inside the bubble
/// next to the message text, not on a line of its own.
public enum RelativeTime {
    /// - Parameters:
    ///   - date: when the message was sent.
    ///   - reference: "now", injectable so the boundaries can be tested.
    public static func short(
        for date: Date,
        reference: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let seconds = reference.timeIntervalSince(date)

        // A message sent moments ago, or one whose clock is slightly ahead of
        // ours, both read as "Now" rather than a negative age.
        if seconds < 60 { return "Now" }

        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }

        let days = hours / 24
        if days < 7 { return "\(days)d" }

        // Past a week the age stops being useful and the date is clearer.
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .current
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: reference)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "MMMdyyyy")
        return formatter.string(from: date)
    }

    /// The full date and time, for the tooltip behind the short form.
    public static func full(for date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
