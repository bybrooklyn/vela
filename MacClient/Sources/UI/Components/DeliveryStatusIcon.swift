#if os(macOS)
    import SwiftUI
    import VelaDomain

    /// Google Messages' delivery iconography.
    ///
    /// Stopwatch while sending, one hollow circled check once sent, two once
    /// delivered, and the pair filled once read. Drawn rather than taken from SF
    /// Symbols because there is no double-circled check in the system set.
    struct DeliveryStatusIcon: View {
        let state: MessageDeliveryState
        /// Bubbles are ultramarine or grey, so the glyph has to adapt.
        let isOutgoing: Bool
        var size: CGFloat = 11

        var body: some View {
            content
                .foregroundStyle(tint)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel)
                .help(accessibilityLabel)
        }

        @ViewBuilder
        private var content: some View {
            switch state {
            case .queued:
                Image(systemName: "clock")
                    .font(.system(size: size, weight: .medium))
            case .sending:
                Image(systemName: "stopwatch")
                    .font(.system(size: size, weight: .medium))
            case .sent:
                CircledCheck(size: size, filled: false, knockout: bubbleColor)
            case .delivered:
                DoubleCircledCheck(size: size, filled: false, knockout: bubbleColor)
            case .read:
                DoubleCircledCheck(size: size, filled: true, knockout: bubbleColor)
            case .failedRetryable, .failedPermanent:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: size, weight: .medium))
            }
        }

        /// What the glyph sits on. A filled check is drawn as a disc with the
        /// tick punched out of it, so the tick has to be painted in the colour
        /// behind the icon rather than simply left blank.
        private var bubbleColor: Color {
            isOutgoing ? SignalPalette.outgoingBubble : SignalPalette.incomingBubble
        }

        private var tint: Color {
            switch state {
            case .failedRetryable, .failedPermanent:
                // Failure must read as failure even on an ultramarine bubble.
                return isOutgoing ? Color.white : Color.red
            case .read:
                // Full strength, so read is distinguishable from delivered at a
                // glance rather than only by looking closely at the fill.
                return isOutgoing ? Color.white : Color(nsColor: .labelColor)
            default:
                return SignalPalette.secondaryText(outgoing: isOutgoing)
            }
        }

        private var accessibilityLabel: String {
            switch state {
            case .queued: "Queued"
            case .sending: "Sending"
            case .sent: "Sent"
            case .delivered: "Delivered"
            case .read: "Read"
            case .failedRetryable(let reason): "Failed, will retry. \(reason)"
            case .failedPermanent(let reason): "Failed to send. \(reason)"
            }
        }
    }

    /// A check inside a circle. Hollow means the step is complete but unread.
    private struct CircledCheck: View {
        let size: CGFloat
        let filled: Bool
        /// Colour for the tick once the disc is filled.
        let knockout: Color
        /// The circle behind a stacked pair omits its tick: most of it is bitten
        /// away by the one in front, and the surviving sliver reads as a stray
        /// mark rather than as a check.
        var showsCheck: Bool = true

        var body: some View {
            ZStack {
                if filled {
                    // `.foreground` rather than `.tint`: tint resolves to the
                    // app's accent, which is the same ultramarine as an outgoing
                    // bubble, so a "read" disc was painting itself invisible.
                    Circle().fill(.foreground)
                } else {
                    Circle().strokeBorder(lineWidth: size * 0.09)
                }
                if showsCheck {
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.5, weight: .bold))
                        .foregroundStyle(filled ? AnyShapeStyle(knockout) : AnyShapeStyle(.foreground))
                }
            }
            .frame(width: size, height: size)
        }
    }

    /// Two circled checks, the second resting on the first.
    ///
    /// The trailing circle is not merely drawn later — the leading one has a
    /// disc-shaped bite taken out of it first. Without that, two hollow strokes
    /// simply cross and the pair reads as a Venn diagram rather than as one
    /// badge overlapping another.
    private struct DoubleCircledCheck: View {
        let size: CGFloat
        let filled: Bool
        let knockout: Color

        /// How far along the trailing circle sits.
        private var step: CGFloat { size * 0.52 }
        /// Clear space left around the trailing circle, so the two stay visually
        /// separate where they meet.
        private var gap: CGFloat { size * 0.1 }

        var body: some View {
            ZStack(alignment: .leading) {
                CircledCheck(size: size, filled: filled, knockout: knockout, showsCheck: false)
                    .mask {
                        CircleBite(
                            hole: CGRect(
                                x: step - gap,
                                y: -gap,
                                width: size + gap * 2,
                                height: size + gap * 2
                            )
                        )
                        .fill(style: FillStyle(eoFill: true))
                    }

                CircledCheck(size: size, filled: filled, knockout: knockout)
                    .offset(x: step)
            }
            .frame(width: size + step, height: size, alignment: .leading)
        }
    }

    /// The full rectangle with a circle removed, for use as a mask. Even-odd
    /// filling is what turns the second subpath into a hole rather than more
    /// coverage.
    private struct CircleBite: Shape {
        let hole: CGRect

        func path(in rect: CGRect) -> Path {
            var path = Path(rect)
            path.addEllipse(in: hole)
            return path
        }
    }
#endif
