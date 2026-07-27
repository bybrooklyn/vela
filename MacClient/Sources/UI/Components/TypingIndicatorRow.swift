#if os(macOS)
    import SwiftUI

    /// The "… is typing" row, with Signal's three-dot pulse.
    struct TypingIndicatorRow: View {
        let text: String

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.colorSchemeContrast) private var contrast
        @State private var phase = 0

        private let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

        var body: some View {
            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .frame(width: 5, height: 5)
                            .opacity(opacity(for: index))
                    }
                }
                .foregroundStyle(SignalPalette.ultramarine)

                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .onReceive(timer) { _ in
                guard !reduceMotion else { return }
                phase = (phase + 1) % 3
            }
            .onChange(of: reduceMotion) { _, isReduced in
                if isReduced { phase = 0 }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
        }

        /// With Reduce Motion the dots hold steady rather than pulsing.
        private func opacity(for index: Int) -> Double {
            guard !reduceMotion else { return contrast == .increased ? 1 : 0.7 }
            return index == phase ? 1 : (contrast == .increased ? 0.6 : 0.3)
        }
    }
#endif
