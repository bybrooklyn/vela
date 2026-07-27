#if os(macOS)
    import AppKit
    import SwiftUI
    import VelaDomain

    /// The message composer.
    ///
    /// Return sends and Shift-Return (or Option-Return) inserts a newline, which
    /// is what Signal does everywhere. Requiring Command-Return to send is the
    /// single most jarring thing about typing in a chat app.
    ///
    /// Text stays plain; formatting rides alongside as `TextStyleRange`s over
    /// UTF-16 offsets, matching how Signal represents it on the wire.
    struct NativeComposerView: NSViewRepresentable {
        @Binding var text: String
        @Binding var styles: [TextStyleRange]
        /// Height the laid-out text needs, so the composer can start one line
        /// tall and grow. `NSScrollView` has no intrinsic content size, so
        /// without measuring, SwiftUI just hands it the whole maximum.
        @Binding var measuredHeight: CGFloat
        let placeholder: String
        let onSend: () -> Void
        /// Reports the selection so the formatting popover knows whether
        /// anything is selected.
        var onSelectionChange: (NSRange) -> Void = { _ in }

        /// Padding between the text view and the edge of the composer's glass.
        static let verticalInset: CGFloat = 5

        /// One line of text plus the container insets. Also the floor for the
        /// measured height, so an empty composer is exactly one line.
        ///
        /// Derived rather than chosen: the glass around this must come to
        /// `Metrics.composerBoxHeight`, because the composer's corner radius is
        /// half that. Hardcoding both is how they drift apart.
        static let minimumHeight: CGFloat = Metrics.composerBoxHeight - verticalInset * 2
        /// Past this the composer stops growing and scrolls instead.
        static let maximumHeight: CGFloat = 140

        func makeCoordinator() -> Coordinator {
            Coordinator(
                text: $text,
                styles: $styles,
                measuredHeight: $measuredHeight,
                onSend: onSend,
                onSelectionChange: onSelectionChange
            )
        }

        func makeNSView(context: Context) -> NSScrollView {
            let scrollView = NSScrollView()
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = false
            scrollView.autohidesScrollers = true

            let textView = ComposerTextView()
            textView.delegate = context.coordinator
            textView.coordinator = context.coordinator
            // Rich only so formatting is visible while typing. Pasted content is
            // flattened, so no foreign fonts or colours survive.
            textView.isRichText = true
            textView.importsGraphics = false
            textView.allowsUndo = true
            textView.isAutomaticQuoteSubstitutionEnabled = true
            textView.isAutomaticDashSubstitutionEnabled = true
            textView.isAutomaticTextReplacementEnabled = true
            textView.isAutomaticLinkDetectionEnabled = false
            textView.font = Coordinator.baseFont
            textView.textColor = .labelColor
            textView.backgroundColor = .clear
            textView.drawsBackground = false
            // Height 6, not 7: one line plus twice this must stay under
            // `minimumHeight`, so an empty composer sits exactly on the floor.
            textView.textContainerInset = NSSize(width: 6, height: 6)
            textView.textContainer?.widthTracksTextView = true
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.placeholder = placeholder
            textView.setAccessibilityLabel("Message composer")
            textView.setAccessibilityHelp("Return sends. Shift-Return or Option-Return inserts a new line.")

            scrollView.documentView = textView
            context.coordinator.scrollView = scrollView
            context.coordinator.textView = textView
            context.coordinator.applyToTextView(text: text, styles: styles)
            context.coordinator.reportHeight()
            return scrollView
        }

        func updateNSView(_ scrollView: NSScrollView, context: Context) {
            guard let textView = scrollView.documentView as? ComposerTextView else { return }
            context.coordinator.onSend = onSend
            context.coordinator.onSelectionChange = onSelectionChange
            if textView.placeholder != placeholder {
                textView.placeholder = placeholder
            }

            // Only rewrite the view when the model genuinely differs, otherwise
            // every keystroke round-trips through SwiftUI and resets the cursor.
            guard context.coordinator.shouldSync(text: text, styles: styles) else { return }
            let selected = textView.selectedRange()
            context.coordinator.applyToTextView(text: text, styles: styles)
            let length = (text as NSString).length
            let location = min(selected.location, length)
            let clamped = NSRange(location: location, length: min(selected.length, length - location))
            textView.setSelectedRange(clamped)
            context.coordinator.reportHeight()
        }

        /// Intercepts formatting shortcuts before the text system sees them.
        final class ComposerTextView: NSTextView {
            weak var coordinator: Coordinator?
            var placeholder = "" {
                didSet {
                    setAccessibilityPlaceholderValue(placeholder)
                    needsDisplay = true
                }
            }

            override func draw(_ dirtyRect: NSRect) {
                super.draw(dirtyRect)
                guard string.isEmpty, !placeholder.isEmpty else { return }
                placeholder.draw(
                    at: textContainerOrigin,
                    withAttributes: [
                        .font: font ?? Coordinator.baseFont,
                        .foregroundColor: NSColor.placeholderTextColor,
                    ]
                )
            }

            override func performKeyEquivalent(with event: NSEvent) -> Bool {
                let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
                guard
                    flags.contains(.command),
                    let characters = event.charactersIgnoringModifiers?.lowercased()
                else {
                    return super.performKeyEquivalent(with: event)
                }

                let style: TextStyleRange.Style? =
                    switch (characters, flags) {
                    case ("b", .command): .bold
                    case ("i", .command): .italic
                    case ("x", [.command, .shift]): .strikethrough
                    case ("m", [.command, .shift]): .monospace
                    case ("s", [.command, .shift]): .spoiler
                    default: nil
                    }

                guard let style else { return super.performKeyEquivalent(with: event) }
                coordinator?.toggle(style)
                return true
            }

            /// Handle Return before AppKit maps modified variants to different
            /// command selectors. Marked text still goes through input method.
            override func keyDown(with event: NSEvent) {
                let isReturn = event.keyCode == 36 || event.keyCode == 76
                guard isReturn, !hasMarkedText() else {
                    super.keyDown(with: event)
                    return
                }

                let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
                if flags.contains(.shift) || flags.contains(.option) {
                    insertNewlineIgnoringFieldEditor(nil)
                } else if flags.isDisjoint(with: [.command, .control]) {
                    coordinator?.onSend()
                } else {
                    super.keyDown(with: event)
                }
            }

            /// Paste as plain text: a copied web page must not drag its styling
            /// into a Signal message.
            override func paste(_ sender: Any?) {
                pasteAsPlainText(sender)
            }
        }

        @MainActor
        final class Coordinator: NSObject, NSTextViewDelegate {
            /// Computed rather than stored: `NSFont` is not `Sendable`, so a
            /// static instance is not safe under strict concurrency.
            static var baseFont: NSFont { .systemFont(ofSize: NSFont.systemFontSize) }
            /// Marks spoiler runs in the composer. Never sent; it exists so the
            /// style survives a round trip through the text view.
            static let spoilerAttribute = NSAttributedString.Key("velaSpoiler")

            @Binding var text: String
            @Binding var styles: [TextStyleRange]
            @Binding var measuredHeight: CGFloat
            var onSend: () -> Void
            var onSelectionChange: (NSRange) -> Void
            weak var textView: NSTextView?
            weak var scrollView: NSScrollView?

            /// Set while writing into the text view, so the resulting delegate
            /// callbacks are not mistaken for user edits.
            private var isApplying = false
            /// Last attributed state visible in AppKit. Binding getters already
            /// expose new SwiftUI values, so comparing against `styles` cannot
            /// detect toolbar-only formatting changes.
            private var displayedText = ""
            private var displayedStyles: [TextStyleRange] = []

            init(
                text: Binding<String>,
                styles: Binding<[TextStyleRange]>,
                measuredHeight: Binding<CGFloat>,
                onSend: @escaping () -> Void,
                onSelectionChange: @escaping (NSRange) -> Void
            ) {
                _text = text
                _styles = styles
                _measuredHeight = measuredHeight
                self.onSend = onSend
                self.onSelectionChange = onSelectionChange
            }

            /// Measures the laid-out text and publishes the height the composer
            /// needs.
            ///
            /// Written asynchronously and only on a real change: assigning
            /// SwiftUI state from inside a layout pass otherwise both warns and
            /// risks oscillating between two heights.
            func reportHeight() {
                guard
                    let textView,
                    let layoutManager = textView.layoutManager,
                    let container = textView.textContainer
                else { return }

                layoutManager.ensureLayout(for: container)
                let used = layoutManager.usedRect(for: container).height
                let desired = used + textView.textContainerInset.height * 2
                let clamped = min(
                    max(desired, NativeComposerView.minimumHeight),
                    NativeComposerView.maximumHeight
                )

                // Only scrollable once the text outgrows the cap, so a short
                // message cannot be scrolled around inside its own box.
                scrollView?.hasVerticalScroller = desired > NativeComposerView.maximumHeight

                guard abs(clamped - measuredHeight) > 0.5 else { return }
                let binding = _measuredHeight
                DispatchQueue.main.async {
                    guard abs(clamped - binding.wrappedValue) > 0.5 else { return }
                    binding.wrappedValue = clamped
                }
            }

            func shouldSync(text newText: String, styles newStyles: [TextStyleRange]) -> Bool {
                let normalized = newStyles.normalized(forUTF16Length: (newText as NSString).length)
                return displayedText != newText || displayedStyles != normalized
            }

            // MARK: - Model to view

            func applyToTextView(text newText: String, styles newStyles: [TextStyleRange]) {
                guard let textView else { return }
                isApplying = true
                defer { isApplying = false }

                let attributed = NSMutableAttributedString(
                    string: newText,
                    attributes: [.font: Self.baseFont, .foregroundColor: NSColor.labelColor]
                )
                let normalized = newStyles.normalized(forUTF16Length: (newText as NSString).length)
                for range in normalized {
                    apply(range.style, to: attributed, in: range.nsRange)
                }
                textView.textStorage?.setAttributedString(attributed)
                textView.typingAttributes = [
                    .font: Self.baseFont, .foregroundColor: NSColor.labelColor,
                ]
                displayedText = newText
                displayedStyles = normalized
            }

            private func apply(
                _ style: TextStyleRange.Style,
                to attributed: NSMutableAttributedString,
                in range: NSRange
            ) {
                let existing = attributed.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
                let current = existing ?? Self.baseFont

                switch style {
                case .bold:
                    attributed.addAttribute(
                        .font,
                        value: NSFontManager.shared.convert(current, toHaveTrait: .boldFontMask),
                        range: range
                    )
                case .italic:
                    attributed.addAttribute(
                        .font,
                        value: NSFontManager.shared.convert(current, toHaveTrait: .italicFontMask),
                        range: range
                    )
                case .strikethrough:
                    attributed.addAttribute(
                        .strikethroughStyle,
                        value: NSUnderlineStyle.single.rawValue,
                        range: range
                    )
                case .monospace:
                    var monospaced = NSFont.monospacedSystemFont(
                        ofSize: NSFont.systemFontSize,
                        weight: .regular
                    )
                    let traits = NSFontManager.shared.traits(of: current)
                    if traits.contains(.boldFontMask) {
                        monospaced = NSFontManager.shared.convert(monospaced, toHaveTrait: .boldFontMask)
                    }
                    if traits.contains(.italicFontMask) {
                        monospaced = NSFontManager.shared.convert(monospaced, toHaveTrait: .italicFontMask)
                    }
                    attributed.addAttribute(
                        .font,
                        value: monospaced,
                        range: range
                    )
                case .spoiler:
                    attributed.addAttribute(Self.spoilerAttribute, value: true, range: range)
                    attributed.addAttribute(
                        .backgroundColor,
                        value: NSColor.labelColor.withAlphaComponent(0.22),
                        range: range
                    )
                }
            }

            // MARK: - View to model

            /// Reads formatting back out of the text view, so styles survive
            /// editing rather than being recomputed from scratch.
            private func harvestStyles() -> [TextStyleRange] {
                guard let storage = textView?.textStorage else { return [] }
                var found: [TextStyleRange] = []
                let full = NSRange(location: 0, length: storage.length)

                storage.enumerateAttributes(in: full) { attributes, range, _ in
                    if let font = attributes[.font] as? NSFont {
                        let traits = NSFontManager.shared.traits(of: font)
                        if traits.contains(.boldFontMask) {
                            found.append(TextStyleRange(start: range.location, length: range.length, style: .bold))
                        }
                        if traits.contains(.italicFontMask) {
                            found.append(TextStyleRange(start: range.location, length: range.length, style: .italic))
                        }
                        if font.fontDescriptor.symbolicTraits.contains(.monoSpace) {
                            found.append(
                                TextStyleRange(start: range.location, length: range.length, style: .monospace))
                        }
                    }
                    if attributes[.strikethroughStyle] != nil {
                        found.append(
                            TextStyleRange(start: range.location, length: range.length, style: .strikethrough))
                    }
                    if attributes[Self.spoilerAttribute] != nil {
                        found.append(TextStyleRange(start: range.location, length: range.length, style: .spoiler))
                    }
                }
                return found.normalized(forUTF16Length: storage.length)
            }

            func textDidChange(_ notification: Notification) {
                guard !isApplying, let textView = notification.object as? NSTextView else { return }
                text = textView.string
                let harvested = harvestStyles()
                styles = harvested
                displayedText = textView.string
                displayedStyles = harvested
                reportHeight()
            }

            func textViewDidChangeSelection(_ notification: Notification) {
                guard !isApplying, let textView = notification.object as? NSTextView else { return }
                onSelectionChange(textView.selectedRange())
            }

            func toggle(_ style: TextStyleRange.Style) {
                guard let textView else { return }
                let range = textView.selectedRange()
                guard range.length > 0 else { return }

                var updated = styles
                let covering = updated.filter { $0.style == style && covers(range, by: $0) }
                if covering.isEmpty {
                    updated.append(TextStyleRange(start: range.location, length: range.length, style: style))
                } else {
                    // Toggling off: cut the selected span out of matching runs.
                    updated = updated.flatMap { existing -> [TextStyleRange] in
                        guard existing.style == style else { return [existing] }
                        return subtract(range, from: existing)
                    }
                }

                let normalized = updated.normalized(forUTF16Length: (textView.string as NSString).length)
                styles = normalized
                applyToTextView(text: textView.string, styles: normalized)
                textView.setSelectedRange(range)
            }

            private func covers(_ range: NSRange, by style: TextStyleRange) -> Bool {
                style.start <= range.location
                    && (style.start + style.length) >= (range.location + range.length)
            }

            private func subtract(_ range: NSRange, from style: TextStyleRange) -> [TextStyleRange] {
                let styleEnd = style.start + style.length
                let cutStart = range.location
                let cutEnd = range.location + range.length
                guard cutStart < styleEnd, cutEnd > style.start else { return [style] }

                var pieces: [TextStyleRange] = []
                if style.start < cutStart {
                    pieces.append(
                        TextStyleRange(start: style.start, length: cutStart - style.start, style: style.style))
                }
                if cutEnd < styleEnd {
                    pieces.append(TextStyleRange(start: cutEnd, length: styleEnd - cutEnd, style: style.style))
                }
                return pieces
            }

            func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
                guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }

                let modifiers = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
                // Shift or Option means "new line"; a bare Return sends.
                if modifiers.contains(.shift) || modifiers.contains(.option) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                onSend()
                return true
            }
        }
    }
#endif
