#if os(macOS)
    import AppKit
    import SwiftUI
    import Testing

    @testable import Vela

    /// Deterministic contracts behind Vela's visual language.
    ///
    /// Full rendered snapshots intentionally do not live here yet. This source
    /// package has no snapshot dependency, and its supported command-line build
    /// environment does not include Xcode's UI-test runner. When that harness is
    /// added, fixtures should render conversation list, empty timeline, incoming
    /// and outgoing bubble runs, styled text with an unrevealed spoiler, reply,
    /// attachment, reactions, delivery states, composer, and lock screen. Capture
    /// each fixture in light/dark appearances, normal/increased contrast,
    /// reduced-transparency on/off, and at 100%/200% text size. Every capture
    /// should pair pixel comparison with an accessibility-tree assertion for
    /// labels, values, enabled state, focus order, and spoiler concealment.
    @Suite struct VisualAccessibilityContractTests {
        @Test func outgoingBubblePrimaryTextMeetsNormalTextContrast() throws {
            let background = try #require(Self.sRGBColor(SignalPalette.outgoingBubble))
            let foreground = try #require(Self.sRGBColor(SignalPalette.outgoingText))

            #expect(Self.contrastRatio(foreground, background) >= 4.5)
        }

        @Test func coreGeometryTokensKeepTheirVisualHierarchy() {
            #expect(Metrics.bubbleTightRadius < Metrics.bubbleRadius)
            #expect(Metrics.quoteThumbnailRadius < Metrics.thumbnailRadius)
            #expect(Metrics.stackedMessageSpacing < Metrics.separatedMessageSpacing)
            #expect(Metrics.separatedMessageSpacing < Metrics.systemMessageSpacing)
            #expect(Metrics.composerRadius == Metrics.composerBoxHeight / 2)
            #expect(Metrics.composerButtonDiameter > 0)
            #expect(Metrics.scrollButtonDiameter > 0)
        }

        @Test func appearanceClassificationTracksAquaVariants() throws {
            let light = try #require(NSAppearance(named: .aqua))
            let dark = try #require(NSAppearance(named: .darkAqua))

            #expect(!light.isDark)
            #expect(dark.isDark)
        }

        @Test func senderColorIsStableForSameDisplayName() throws {
            let first = try #require(Self.sRGBColor(SignalPalette.senderColor(for: "Ada")))
            let second = try #require(Self.sRGBColor(SignalPalette.senderColor(for: "Ada")))

            #expect(Self.rgba(first) == Self.rgba(second))
        }

        private static func sRGBColor(_ color: Color) -> NSColor? {
            NSColor(color).usingColorSpace(.sRGB)
        }

        private static func rgba(_ color: NSColor) -> [CGFloat] {
            [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
        }

        private static func contrastRatio(_ foreground: NSColor, _ background: NSColor) -> CGFloat {
            let foregroundLuminance = relativeLuminance(foreground)
            let backgroundLuminance = relativeLuminance(background)
            let lighter = max(foregroundLuminance, backgroundLuminance)
            let darker = min(foregroundLuminance, backgroundLuminance)
            return (lighter + 0.05) / (darker + 0.05)
        }

        private static func relativeLuminance(_ color: NSColor) -> CGFloat {
            0.2126 * linearized(color.redComponent)
                + 0.7152 * linearized(color.greenComponent)
                + 0.0722 * linearized(color.blueComponent)
        }

        private static func linearized(_ component: CGFloat) -> CGFloat {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
    }
#endif
