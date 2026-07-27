#if os(macOS)
    import AppKit
    import SwiftUI

    /// Signal's own colours, so Vela looks like Signal rather than like whatever
    /// accent colour the user happens to have set in System Settings.
    ///
    /// Deliberately not `Color.accentColor`: that follows the system accent, so a
    /// green accent produced green message bubbles. Signal is ultramarine
    /// everywhere, on every platform.
    enum SignalPalette {
        /// Signal's brand blue (#2C6BED), used for outgoing bubbles and actions.
        static let ultramarine = Color(nsColor: NSColor(srgbRed: 0.173, green: 0.420, blue: 0.929, alpha: 1))

        /// A slightly deeper ultramarine for pressed and prominent states.
        static let ultramarineDeep = Color(nsColor: NSColor(srgbRed: 0.129, green: 0.333, blue: 0.812, alpha: 1))

        /// Incoming bubble fill. Adapts to appearance the way Signal's does:
        /// near-white in light mode, a soft charcoal in dark.
        static let incomingBubble = Color(
            nsColor: NSColor(name: nil) { appearance in
                appearance.isDark
                    ? NSColor(srgbRed: 0.235, green: 0.235, blue: 0.247, alpha: 1)
                    : NSColor(srgbRed: 0.914, green: 0.914, blue: 0.922, alpha: 1)
            }
        )

        /// Text on an outgoing bubble is always white; Signal does not invert it.
        static let outgoingText = Color.white

        static let incomingText = Color(nsColor: .labelColor)

        /// Timestamps and delivery ticks inside a bubble, per direction.
        static func secondaryText(outgoing: Bool) -> Color {
            // Secondary system labels and translucent white both fall below
            // small-text contrast on message fills. These remain visually
            // subordinate through size and weight rather than low opacity.
            outgoing
                ? .white
                : adaptive(
                    light: NSColor(srgbRed: 0.255, green: 0.255, blue: 0.286, alpha: 1),
                    dark: NSColor(srgbRed: 0.850, green: 0.850, blue: 0.875, alpha: 1)
                )
        }

        /// Fill for an outgoing bubble.
        static let outgoingBubble = ultramarine

        /// Colour for a group sender's name, derived from the name itself so it
        /// matches the hue `ContactAvatarView` gives that person's avatar.
        static func senderColor(for name: String) -> Color {
            senderColors[stableIndex(for: name, count: senderColors.count)]
        }

        /// Avatar fills use a bounded palette rather than arbitrary HSB hues.
        /// Every entry has sufficient contrast with white initials and remains
        /// stable across launches and processes.
        static func avatarBackground(for identifier: String) -> Color {
            avatarColors[stableIndex(for: identifier, count: avatarColors.count)]
        }

        /// Unread badges and other emphasis that must read as Signal, not accent.
        static let badge = ultramarine

        /// Fill behind small inline chips — attachment pills, connection state,
        /// date separators.
        ///
        /// One opaque value on purpose: these were `.quaternary` at 0.5 and at
        /// 0.6, which read as two different materials and ignored Reduce
        /// Transparency because these call sites do not receive that setting.
        static let chipFill = AnyShapeStyle(secondarySurface)

        /// Fill behind a reaction pill.
        ///
        /// Not `chipFill`: a reaction sits on the open timeline directly under a
        /// bubble rather than on chrome, and has to read as a raised object.
        /// `.quaternary` all but vanishes there against a dark background. An
        /// opaque surface also keeps this component honest under Reduce
        /// Transparency without every reaction call site needing a second path.
        static let reactionFill = AnyShapeStyle(opaqueSurface)

        /// Hairline around a badge that sits over other content, so it stays
        /// legible whatever is behind it.
        static let badgeStroke = Color(
            nsColor: NSColor(name: nil) { appearance in
                appearance.isDark
                    ? NSColor(white: 1, alpha: 0.1)
                    : NSColor(white: 0, alpha: 0.1)
            }
        )

        // MARK: - Adaptive surfaces

        static let appBackground = adaptive(
            light: NSColor(srgbRed: 0.975, green: 0.978, blue: 0.985, alpha: 1),
            dark: NSColor(srgbRed: 0.075, green: 0.078, blue: 0.090, alpha: 1)
        )

        /// Solid replacement for glass when Reduce Transparency is enabled.
        static let opaqueSurface = adaptive(
            light: NSColor(srgbRed: 0.965, green: 0.968, blue: 0.975, alpha: 1),
            dark: NSColor(srgbRed: 0.135, green: 0.140, blue: 0.155, alpha: 1)
        )

        static let secondarySurface = adaptive(
            light: NSColor(srgbRed: 0.925, green: 0.932, blue: 0.945, alpha: 1),
            dark: NSColor(srgbRed: 0.105, green: 0.110, blue: 0.125, alpha: 1)
        )

        static let subtleBorder = adaptive(
            light: NSColor(white: 0, alpha: 0.14),
            dark: NSColor(white: 1, alpha: 0.16)
        )

        static let strongBorder = adaptive(
            light: NSColor(white: 0, alpha: 0.48),
            dark: NSColor(white: 1, alpha: 0.58)
        )

        private static let avatarColors: [Color] = [
            Color(nsColor: NSColor(srgbRed: 0.620, green: 0.090, blue: 0.150, alpha: 1)),
            Color(nsColor: NSColor(srgbRed: 0.500, green: 0.230, blue: 0.015, alpha: 1)),
            Color(nsColor: NSColor(srgbRed: 0.210, green: 0.390, blue: 0.035, alpha: 1)),
            Color(nsColor: NSColor(srgbRed: 0.000, green: 0.390, blue: 0.290, alpha: 1)),
            Color(nsColor: NSColor(srgbRed: 0.000, green: 0.350, blue: 0.450, alpha: 1)),
            Color(nsColor: NSColor(srgbRed: 0.120, green: 0.290, blue: 0.620, alpha: 1)),
            Color(nsColor: NSColor(srgbRed: 0.300, green: 0.210, blue: 0.620, alpha: 1)),
            Color(nsColor: NSColor(srgbRed: 0.480, green: 0.120, blue: 0.560, alpha: 1)),
        ]

        private static let senderColors: [Color] = [
            adaptive(light: color(0.500, 0.055, 0.100), dark: color(1.000, 0.650, 0.690)),
            adaptive(light: color(0.430, 0.190, 0.000), dark: color(1.000, 0.740, 0.430)),
            adaptive(light: color(0.170, 0.340, 0.000), dark: color(0.700, 0.860, 0.450)),
            adaptive(light: color(0.000, 0.350, 0.240), dark: color(0.390, 0.850, 0.690)),
            adaptive(light: color(0.000, 0.330, 0.410), dark: color(0.390, 0.820, 0.900)),
            adaptive(light: color(0.100, 0.260, 0.570), dark: color(0.650, 0.750, 1.000)),
            adaptive(light: color(0.260, 0.170, 0.560), dark: color(0.790, 0.700, 1.000)),
            adaptive(light: color(0.430, 0.100, 0.500), dark: color(0.900, 0.650, 0.980)),
        ]

        private static func stableIndex(for value: String, count: Int) -> Int {
            var hash: UInt64 = 5381
            for byte in value.utf8 {
                hash = (hash &* 33) &+ UInt64(byte)
            }
            return Int(hash % UInt64(count))
        }

        private static func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
            NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }

        private static func adaptive(light: NSColor, dark: NSColor) -> Color {
            Color(nsColor: NSColor(name: nil) { $0.isDark ? dark : light })
        }
    }

    extension NSAppearance {
        /// True when the effective appearance is one of the dark variants.
        var isDark: Bool {
            bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }
#endif
