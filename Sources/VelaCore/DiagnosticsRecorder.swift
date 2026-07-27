import Foundation
import VelaDomain

public actor DiagnosticsRecorder {
    private var events: [DiagnosticEvent] = []
    private let capacity: Int

    public init(capacity: Int = 500) {
        self.capacity = max(1, capacity)
    }

    public func record(
        subsystem: String,
        category: String,
        detail: String,
        at date: Date = Date()
    ) {
        events.append(
            DiagnosticEvent(
                timestamp: date,
                subsystem: subsystem,
                category: category,
                detail: detail
            )
        )
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
    }

    public func snapshot() -> [DiagnosticEvent] {
        events
    }

    public func clear() {
        events.removeAll(keepingCapacity: true)
    }

    public static func errorCategory(_ error: any Error) -> String {
        String(reflecting: type(of: error))
    }
}
