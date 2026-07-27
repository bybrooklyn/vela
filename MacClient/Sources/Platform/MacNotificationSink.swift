#if os(macOS)
    import AppKit
    import Foundation
    import UserNotifications
    import VelaCore
    import VelaDomain
    import os

    /// Where notification permission currently stands, for display in Settings.
    ///
    /// A failure here is worth showing rather than logging: the user cannot tell
    /// a silent app from a broken one, and the fix is in System Settings, not in
    /// Vela.
    enum NotificationAuthorization: Equatable, Sendable {
        case pending
        case granted
        /// The user said no, or macOS has the app switched off.
        case denied
        /// macOS refused to even ask. `detail` is its reason.
        case unavailable(String)

        var summary: String {
            switch self {
            case .pending: "Checking…"
            case .granted: "Allowed"
            case .denied: "Turned off"
            case .unavailable: "Unavailable"
            }
        }
    }

    /// Delivers incoming-message notifications to Notification Center.
    ///
    /// Three things stopped these ever appearing. macOS suppresses banners while
    /// the app is frontmost unless a delegate explicitly asks for them, and no
    /// delegate was set. Authorisation failures were swallowed by `try?`, so a
    /// denied prompt looked identical to a working one. And authorisation was
    /// requested unconditionally: macOS already has `works.deadsignal.vela`
    /// recorded as denied, and re-requesting from `denied` throws
    /// "Notifications are not allowed for this application" rather than
    /// re-prompting. The same bundle under a different identifier reports
    /// `notDetermined`, so this is a stale per-identifier record and not the
    /// sandbox or the ad-hoc signature.
    final class MacNotificationSink: IncomingMessageNotificationSink, @unchecked Sendable {
        private static let log = Logger(subsystem: "works.deadsignal.vela", category: "notifications")

        private let delegate = NotificationDelegate()

        /// Called when the user clicks a banner, so the app can open that thread.
        var onOpenConversation: (@Sendable (ConversationID) -> Void)? {
            get { delegate.onOpenConversation }
            set { delegate.onOpenConversation = newValue }
        }

        /// Reports the settled authorisation state so Settings can show it.
        var onAuthorizationChange: (@Sendable (NotificationAuthorization) -> Void)?

        init() {
            // Must be set before any notification is delivered, and before the
            // app finishes launching, or early banners are dropped.
            UNUserNotificationCenter.current().delegate = delegate
        }

        func requestAuthorization() async {
            await waitForAppLaunch()

            let center = UNUserNotificationCenter.current()

            // Read before asking. Asking is only valid from `notDetermined`;
            // from `denied` it throws, which is what produced five identical
            // "Notifications are not allowed for this application" errors.
            let settings = await center.notificationSettings()
            Self.log.info(
                """
                notification settings: \
                status=\(settings.authorizationStatus.rawValue, privacy: .public) \
                alerts=\(settings.alertSetting.rawValue, privacy: .public) \
                sound=\(settings.soundSetting.rawValue, privacy: .public)
                """
            )

            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                onAuthorizationChange?(.granted)
                return
            case .denied:
                // Only the user can undo this, in System Settings. Vela cannot
                // re-prompt, so Settings offers the way there instead.
                Self.log.error("notifications are denied for this app; banners stay hidden until enabled in System Settings")
                onAuthorizationChange?(.denied)
                return
            case .notDetermined:
                break
            @unknown default:
                break
            }

            do {
                let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
                Self.log.info("notification authorisation granted=\(granted, privacy: .public)")
                onAuthorizationChange?(granted ? .granted : .denied)
            } catch {
                Self.log.error("notification authorisation failed: \(error.localizedDescription, privacy: .public)")
                onAuthorizationChange?(.unavailable(error.localizedDescription))
            }
        }

        /// The request is only valid once the app is up; from a view's `task` it
        /// can run before `NSApplication` has finished launching.
        private func waitForAppLaunch() async {
            if await MainActor.run(body: { NSApp?.isRunning ?? false }) { return }
            for await _ in NotificationCenter.default.notifications(
                named: NSApplication.didFinishLaunchingNotification
            ) {
                return
            }
        }

        func notifyIncoming(messageID: MessageID, conversationID: ConversationID) async {
            let content = UNMutableNotificationContent()
            content.title = "Vela"
            // Deliberately generic: previews stay off until that decision is
            // revisited, and the privacy note in Settings says so.
            content.body = "New message"
            content.sound = .default
            content.threadIdentifier = conversationID.rawValue
            content.userInfo = ["conversationID": conversationID.rawValue]

            let request = UNNotificationRequest(
                identifier: messageID.rawValue,
                content: content,
                trigger: nil
            )
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                Self.log.error("could not post notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Asks macOS to show banners even while Vela is frontmost, and routes a
    /// click back to the conversation it came from.
    private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
        var onOpenConversation: (@Sendable (ConversationID) -> Void)?

        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification
        ) async -> UNNotificationPresentationOptions {
            // Without this the system silently drops the banner whenever the app
            // has focus, which is most of the time while you are using it.
            [.banner, .list, .sound]
        }

        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse
        ) async {
            let info = response.notification.request.content.userInfo
            guard let raw = info["conversationID"] as? String else { return }
            onOpenConversation?(ConversationID(raw))
        }
    }
#endif
