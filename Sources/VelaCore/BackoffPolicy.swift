import Foundation

public struct BackoffPolicy: Sendable {
    public var initialDelay: TimeInterval
    public var maximumDelay: TimeInterval
    public var multiplier: Double
    /// Retained for source compatibility with older callers. Transient failures
    /// are never discarded because this count was reached; only the delay is
    /// capped. Permanent failure is decided from the error category.
    public var maximumAttempts: Int

    public init(
        initialDelay: TimeInterval = 1,
        maximumDelay: TimeInterval = 5 * 60,
        multiplier: Double = 2,
        maximumAttempts: Int = 12
    ) {
        self.initialDelay = max(0, initialDelay)
        self.maximumDelay = max(self.initialDelay, maximumDelay)
        self.multiplier = max(1, multiplier)
        self.maximumAttempts = max(1, maximumAttempts)
    }

    public func delay(afterAttempt attempt: Int) -> TimeInterval {
        let exponent = max(0, attempt - 1)
        return min(maximumDelay, initialDelay * pow(multiplier, Double(exponent)))
    }
}
