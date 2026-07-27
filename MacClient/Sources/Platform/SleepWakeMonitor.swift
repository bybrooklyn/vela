#if os(macOS)
    import AppKit
    import Foundation

    @MainActor
    final class SleepWakeMonitor {
        private var tokens: [NSObjectProtocol] = []

        init(onSleep: @escaping @MainActor () -> Void, onWake: @escaping @MainActor () -> Void) {
            let center = NSWorkspace.shared.notificationCenter
            tokens.append(
                center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
                    Task { @MainActor in onSleep() }
                }
            )
            tokens.append(
                center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                    Task { @MainActor in onWake() }
                }
            )
        }

        func invalidate() {
            let center = NSWorkspace.shared.notificationCenter
            for token in tokens {
                center.removeObserver(token)
            }
            tokens.removeAll()
        }
    }
#endif
