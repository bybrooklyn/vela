#if os(macOS)
    import SwiftUI

    /// Jumps the timeline back to the newest message, showing how many unread
    /// messages are waiting there.
    ///
    /// Modelled on Signal-iOS's `ConversationScrollButton`: a 40pt circle with a
    /// neutral chevron and an accent-coloured count riding over its top edge.
    /// Deliberately *not* tinted with ultramarine — this is a navigation
    /// affordance, and Signal reserves the accent for the badge so the button
    /// does not read as a primary action.
    struct ScrollToLatestButton: View {
        /// Unread messages in this conversation. As in Signal, this is the
        /// thread's count rather than "how many are below the fold".
        let unreadCount: Int
        let action: () -> Void

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

        var body: some View {
            Button(action: action) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(
                        width: Metrics.scrollButtonDiameter,
                        height: Metrics.scrollButtonDiameter
                    )
                    .velaGlass(
                        .regular,
                        radius: Metrics.scrollButtonDiameter / 2,
                        reduceTransparency: reduceTransparency
                    )
                    .frame(
                        width: Metrics.minimumInteractiveDiameter,
                        height: Metrics.minimumInteractiveDiameter
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .overlay(alignment: .top) { badge }
            .help("Jump to latest")
            .accessibilityLabel(
                unreadCount > 0
                    ? "Jump to latest message, \(unreadCount) unread"
                    : "Jump to latest message"
            )
        }

        @ViewBuilder
        private var badge: some View {
            if unreadCount > 0 {
                Text(badgeText)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    // Never narrower than it is tall, so a single digit stays a
                    // circle rather than a squashed pill.
                    .frame(minWidth: badgeHeight)
                    .background(SignalPalette.badge, in: Capsule())
                    .overlay { Capsule().strokeBorder(SignalPalette.badgeStroke, lineWidth: 1) }
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    // Rides up over the circle's edge rather than sitting beside
                    // it, which is what keeps the pair compact.
                    .alignmentGuide(.top) { $0[.bottom] - Metrics.scrollButtonBadgeOverlap }
            }
        }

        private var badgeHeight: CGFloat { 18 }

        private var badgeText: String {
            unreadCount > 99 ? "99+" : String(unreadCount)
        }
    }
#endif
