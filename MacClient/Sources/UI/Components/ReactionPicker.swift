#if os(macOS)
    import SwiftUI

    /// The emoji popover behind the pill's react button.
    ///
    /// Keeps the six quick reactions one click away — they are the common case —
    /// while not forcing a six-emoji strip to sit permanently beside every
    /// message.
    struct ReactionPicker: View {
        let onSelect: (String) -> Void

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovered: String?
        @FocusState private var focusedEmoji: String?

        private static let emoji = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

        var body: some View {
            HStack(spacing: 4) {
                ForEach(Self.emoji, id: \.self) { emoji in
                    Button {
                        onSelect(emoji)
                    } label: {
                        Text(emoji)
                            .font(.system(size: 22))
                            .padding(5)
                            .scaleEffect(hovered == emoji && !reduceMotion ? 1.25 : 1)
                    }
                    .buttonStyle(.plain)
                    .focused($focusedEmoji, equals: emoji)
                    .onHover { isHovered in
                        withAnimation(reduceMotion ? nil : GlassStyle.springy) {
                            hovered = isHovered ? emoji : nil
                        }
                    }
                    .help("React \(emoji)")
                    .accessibilityLabel("React with \(emoji)")
                    .accessibilityHint("Sets your reaction.")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .focusSection()
            .onAppear { focusedEmoji = Self.emoji.first }
            .onMoveCommand { direction in
                guard let current = focusedEmoji, let index = Self.emoji.firstIndex(of: current) else {
                    focusedEmoji = Self.emoji.first
                    return
                }
                switch direction {
                case .left:
                    focusedEmoji = Self.emoji[max(0, index - 1)]
                case .right:
                    focusedEmoji = Self.emoji[min(Self.emoji.count - 1, index + 1)]
                default:
                    break
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Reaction picker")
        }
    }
#endif
