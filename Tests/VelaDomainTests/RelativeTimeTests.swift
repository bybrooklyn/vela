import Foundation
import Testing

@testable import VelaDomain

/// Relative labels sit inside the bubble and are the only timestamp a message
/// shows, so the boundaries between units have to be exact.
@Suite struct RelativeTimeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func label(secondsAgo: TimeInterval) -> String {
        RelativeTime.short(for: now.addingTimeInterval(-secondsAgo), reference: now)
    }

    @Test func underAMinuteReadsAsNow() {
        #expect(label(secondsAgo: 0) == "Now")
        #expect(label(secondsAgo: 59) == "Now")
    }

    @Test func minutesBeginAtSixtySeconds() {
        #expect(label(secondsAgo: 60) == "1m")
        #expect(label(secondsAgo: 61) == "1m")
        #expect(label(secondsAgo: 19 * 60) == "19m")
        #expect(label(secondsAgo: 59 * 60 + 59) == "59m")
    }

    @Test func hoursBeginAtSixtyMinutes() {
        #expect(label(secondsAgo: 60 * 60) == "1h")
        #expect(label(secondsAgo: 2 * 60 * 60) == "2h")
        #expect(label(secondsAgo: 23 * 60 * 60 + 3599) == "23h")
    }

    @Test func daysBeginAtTwentyFourHours() {
        #expect(label(secondsAgo: 24 * 60 * 60) == "1d")
        #expect(label(secondsAgo: 3 * 24 * 60 * 60) == "3d")
        #expect(label(secondsAgo: 6 * 24 * 60 * 60 + 1000) == "6d")
    }

    @Test func pastAWeekFallsBackToADate() {
        // Beyond a week an age stops being useful, so it becomes a date. The
        // exact wording is locale-dependent; what matters is that it is no
        // longer a relative unit.
        let old = label(secondsAgo: 30 * 24 * 60 * 60)
        #expect(!old.hasSuffix("d"))
        #expect(!old.hasSuffix("h"))
        #expect(old != "Now")
        #expect(!old.isEmpty)
    }

    @Test func aClockSlightlyAheadStillReadsAsNow() {
        // Another device's clock can be a little ahead of ours; a message must
        // never be labelled with a negative age.
        #expect(RelativeTime.short(for: now.addingTimeInterval(30), reference: now) == "Now")
    }
}
