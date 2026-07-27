#if os(macOS)
    import SwiftUI
    import VelaDomain

    /// Signal's circular send button.
    ///
    /// Deliberately a filled ultramarine circle rather than a glass capsule: it
    /// is the primary action in the window and should read as one obvious
    /// target, not as another piece of chrome.
    struct SendButton: View {
        let isEditing: Bool
        let isEnabled: Bool
        let action: () -> Void

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                Image(systemName: isEditing ? "checkmark" : "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: Metrics.composerButtonDiameter, height: Metrics.composerButtonDiameter)
                    .background(background, in: Circle())
                    .scaleEffect(isHovered && isEnabled ? 1.06 : 1)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .onHover { hovering in
                withAnimation(reduceMotion ? nil : GlassStyle.springy) { isHovered = hovering }
            }
            // Return sends, so the button is a pointer affordance rather than
            // the only route. No keyboard shortcut here: it would swallow
            // Return before the composer sees it.
            .help(
                isEditing
                    ? "Save edit (Return · Shift-Return or Option-Return for a new line)"
                    : "Send (Return · Shift-Return or Option-Return for a new line)"
            )
            .accessibilityLabel(isEditing ? "Save edit" : "Send message")
            .accessibilityHint("Return sends. Shift-Return or Option-Return inserts a new line.")
        }

        private var background: Color {
            isEnabled ? SignalPalette.ultramarine : Color(nsColor: .quaternaryLabelColor)
        }
    }

    /// Formatting actions for the current selection, matching the five styles
    /// Signal supports on the wire.
    struct FormattingBar: View {
        let activeStyles: Set<TextStyleRange.Style>
        let apply: (TextStyleRange.Style) -> Void

        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

        private static let items: [(TextStyleRange.Style, String, String, String)] = [
            (.bold, "bold", "Bold", "Command-B"),
            (.italic, "italic", "Italic", "Command-I"),
            (.strikethrough, "strikethrough", "Strikethrough", "Shift-Command-X"),
            (.monospace, "chevron.left.forwardslash.chevron.right", "Monospace", "Shift-Command-M"),
            (.spoiler, "eye.slash", "Spoiler", "Shift-Command-S"),
        ]

        var body: some View {
            HStack(spacing: 2) {
                ForEach(Self.items, id: \.1) { style, icon, title, shortcut in
                    Button {
                        apply(style)
                    } label: {
                        Image(systemName: icon)
                            .frame(width: 24, height: 22)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(activeStyles.contains(style) ? Color.accentColor : Color.primary)
                    .background(
                        activeStyles.contains(style) ? Color.accentColor.opacity(0.16) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                    )
                    // NSTextView owns these shortcuts. Registering them again
                    // here can make SwiftUI consume the event using stale selection.
                    .help("\(title) (\(shortcut))")
                    .accessibilityLabel(title)
                    .accessibilityValue(activeStyles.contains(style) ? "On" : "Off")
                    .accessibilityHint("Keyboard shortcut \(shortcut)")
                }
                Spacer()
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .velaGlass(.regular, radius: Metrics.controlRadius, reduceTransparency: reduceTransparency)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
    }
#endif
