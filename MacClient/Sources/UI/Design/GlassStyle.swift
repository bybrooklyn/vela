#if os(macOS)
    import SwiftUI

    /// Liquid Glass styling, applied in one place so every surface agrees and so
    /// accessibility fallbacks are handled once rather than per view.
    ///
    /// Reduce Transparency must produce solid surfaces: glass over glass is
    /// unreadable for people who turn it on, and the system does not do that
    /// substitution for custom views.
    enum GlassStyle {
        /// Motion used when messages arrive and surfaces morph.
        static let springy = Animation.spring(response: 0.34, dampingFraction: 0.82)
    }

    private struct VelaGlassModifier: ViewModifier {
        let glass: Glass
        let radius: CGFloat
        let reduceTransparency: Bool

        @Environment(\.colorSchemeContrast) private var contrast

        @ViewBuilder
        func body(content: Content) -> some View {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

            Group {
                if reduceTransparency {
                    // Materials remain translucent. Reduce Transparency needs a
                    // genuinely opaque replacement, not another material.
                    content.background(SignalPalette.opaqueSurface, in: shape)
                } else {
                    content.glassEffect(glass, in: shape)
                }
            }
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(SignalPalette.strongBorder, lineWidth: 1)
                }
            }
        }
    }

    extension View {
        /// Glass on a rounded rectangle, falling back to a solid colour when
        /// the user has asked for reduced transparency.
        @ViewBuilder
        func velaGlass(
            _ glass: Glass = .regular,
            radius: CGFloat = Metrics.controlRadius,
            reduceTransparency: Bool
        ) -> some View {
            modifier(
                VelaGlassModifier(
                    glass: glass,
                    radius: radius,
                    reduceTransparency: reduceTransparency
                )
            )
        }

        /// Animates a real state value only when the user allows motion.
        /// A generated UUID here caused every render to start a new animation.
        func velaMotion<Value: Equatable>(
            _ enabled: Bool,
            value: Value,
            animation: Animation = GlassStyle.springy
        ) -> some View {
            self.animation(enabled ? animation : nil, value: value)
        }
    }
#endif
