#if os(macOS)
    import AppKit
    import Foundation
    import ImageIO
    import SwiftUI
    import VelaDomain

    struct MessageTimelineView: View {
        @EnvironmentObject private var model: AppModel
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isNearBottom = true
        @State private var pendingDeletion: ChatMessage?
        /// Sender names only make sense where more than one person can speak.
        var isGroup = false
        /// Relative labels ("Now", "19m") would otherwise freeze at whatever they
        /// said when drawn. One shared clock re-renders them all together.
        @State private var now = Date()
        private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
        let messages: [ChatMessage]
        let onReply: (ChatMessage) -> Void
        let onEdit: (ChatMessage) -> Void
        let onDelete: (ChatMessage) -> Void
        let onReact: (ChatMessage, String) -> Void
        let onRemoveReaction: (ChatMessage) -> Void
        /// Optional hooks keep timeline reusable while AppModel owns paging.
        var onLoadEarlier: (() -> Void)? = nil
        var hasEarlierMessages = false
        var isLoadingEarlier = false

        var body: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    // Deliberately no `GlassEffectContainer` and no glass on
                    // bubbles. Liquid Glass unions shapes that fall within a
                    // container's spacing, so once stacked bubbles moved to 2pt
                    // apart a narrow bubble and a wider one below it fused into
                    // one stepped slab. Signal's bubbles are flat fills anyway;
                    // glass stays on the chrome, where it reads as depth rather
                    // than as an artefact.
                    LazyVStack(spacing: 0) {
                        if messages.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .font(.system(size: 34, weight: .light))
                                    .foregroundStyle(.quaternary)
                                Text("No messages yet")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                // Signal never backfills history to a newly
                                // linked device, so an empty thread is
                                // expected rather than broken.
                                Text(
                                    "Messages appear here from now on. Signal does not copy earlier history to a newly linked device."
                                )
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 340)
                            }
                            .frame(maxWidth: .infinity, minHeight: 460)
                        } else {
                            if hasEarlierMessages || isLoadingEarlier {
                                loadEarlierControl
                            }
                            ForEach(groupedMessages) { group in
                                DateSeparator(date: group.date)
                                ForEach(Array(group.messages.enumerated()), id: \.element.id) { index, message in
                                    MessageRow(
                                        message: message,
                                        position: position(of: index, in: group.messages),
                                        showsTimestamp: isRunEnd(index, in: group.messages),
                                        showsReadLabel: message.id == newestReadOutgoingID,
                                        senderName: senderName(for: message, at: index, in: group.messages),
                                        accessibilityAuthor: accessibilityAuthor(for: message),
                                        now: now,
                                        replyPreview: replyPreview(for: message),
                                        onReply: { onReply(message) },
                                        onEdit: { onEdit(message) },
                                        onDelete: { pendingDeletion = message },
                                        onReact: { onReact(message, $0) },
                                        onRemoveReaction: { onRemoveReaction(message) },
                                        localReactionEmoji: localReactionEmoji(for: message)
                                    )
                                    .id(message.id)
                                    .padding(
                                        .top,
                                        isRunStart(index, in: group.messages)
                                            ? Metrics.separatedMessageSpacing
                                            : Metrics.stackedMessageSpacing
                                    )
                                    .transition(
                                        reduceMotion
                                            ? .opacity
                                            : .asymmetric(
                                                insertion: .scale(scale: 0.94, anchor: .bottom)
                                                    .combined(with: .opacity),
                                                removal: .opacity
                                            )
                                    )
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .animation(GlassStyle.springy, value: messages.count)
                }
                .background(.background)
                // Content dissolves under the toolbar instead of clipping.
                .scrollEdgeEffectStyle(.soft, for: .top)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    // "Near the bottom" rather than exactly at it, so a small
                    // scroll does not stop new messages following.
                    geometry.contentOffset.y + geometry.containerSize.height
                        >= geometry.contentSize.height - 120
                } action: { _, nearBottom in
                    isNearBottom = nearBottom
                }
                .onChange(of: messages.last?.id) { _, id in
                    guard let id, isNearBottom else { return }
                    withAnimation(reduceMotion ? nil : .snappy) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    // Reading back through history must not be yanked away by an
                    // arriving message; offer the jump instead.
                    if !isNearBottom, let last = messages.last?.id {
                        ScrollToLatestButton(unreadCount: unreadCount) {
                            withAnimation(reduceMotion ? nil : .snappy) {
                                proxy.scrollTo(last, anchor: .bottom)
                            }
                        }
                        .padding(16)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .onAppear {
                    if let id = messages.last?.id {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
                .onReceive(clock) { now = $0 }
                .alert(
                    "Delete message for everyone?",
                    isPresented: Binding(
                        get: { pendingDeletion != nil },
                        set: { if !$0 { pendingDeletion = nil } }
                    ),
                    presenting: pendingDeletion
                ) { message in
                    Button("Delete for everyone", role: .destructive) {
                        pendingDeletion = nil
                        onDelete(message)
                    }
                    Button("Cancel", role: .cancel) { pendingDeletion = nil }
                } message: { _ in
                    Text("This removes message from conversation for every participant. This cannot be undone.")
                }
            }
        }

        @ViewBuilder
        private var loadEarlierControl: some View {
            if isLoadingEarlier {
                ProgressView("Loading earlier messages")
                    .controlSize(.small)
                    .padding(.vertical, 10)
            } else if let onLoadEarlier {
                Button("Load earlier messages", action: onLoadEarlier)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .padding(.vertical, 8)
            }
        }

        /// What the jump button badges. The thread's unread count, which is what
        /// Signal shows too — not a count of messages below the scroll position.
        private var unreadCount: Int {
            model.selectedConversation?.unreadCount ?? 0
        }

        private var groupedMessages: [MessageDayGroup] {
            let calendar = Calendar.current
            let dictionary = Dictionary(grouping: messages) {
                calendar.startOfDay(for: $0.sentAt)
            }
            return dictionary.keys.sorted().map { date in
                MessageDayGroup(date: date, messages: dictionary[date, default: []])
            }
        }

        /// The most recent of your own messages that has been read. Only that one
        /// carries the "Read" label, so it moves down the thread rather than
        /// accumulating.
        private var newestReadOutgoingID: MessageID? {
            messages.last { message in
                guard message.direction == .outgoing else { return false }
                if case .read = message.deliveryState { return true }
                return false
            }?.id
        }

        /// In a group the sender is named above the first bubble of their run. A
        /// direct conversation already names them in the header.
        private func senderName(for message: ChatMessage, at index: Int, in messages: [ChatMessage]) -> String? {
            guard isGroup, message.direction == .incoming, isRunStart(index, in: messages) else {
                return nil
            }
            return model.displayName(for: message.senderID)
        }

        private func accessibilityAuthor(for message: ChatMessage) -> String {
            message.direction == .outgoing ? "You" : model.displayName(for: message.senderID)
        }

        private func localReactionEmoji(for message: ChatMessage) -> String? {
            guard let localID = model.snapshot.linkedAccount?.localRecipientID else { return nil }
            return message.reactions.first(where: { $0.authorID == localID })?.emoji
        }

        /// Consecutive messages from one sender form a run, so they tuck together
        /// instead of each being an isolated box. The rule itself lives in
        /// `MessageClustering` so it can be tested.
        private func continuesRun(_ index: Int, in messages: [ChatMessage]) -> Bool {
            MessageClustering.continuesRun(
                messages[index],
                after: index > 0 ? messages[index - 1] : nil
            )
        }

        private func isRunStart(_ index: Int, in messages: [ChatMessage]) -> Bool {
            !continuesRun(index, in: messages)
        }

        private func isRunEnd(_ index: Int, in messages: [ChatMessage]) -> Bool {
            index == messages.count - 1 || !continuesRun(index + 1, in: messages)
        }

        private func position(of index: Int, in messages: [ChatMessage]) -> BubblePosition {
            switch (isRunStart(index, in: messages), isRunEnd(index, in: messages)) {
            case (true, true): .single
            case (true, false): .first
            case (false, true): .last
            case (false, false): .middle
            }
        }

        /// Signal shows who was quoted, not just the quoted text, so a reply is
        /// readable without scrolling back.
        private func replyPreview(for message: ChatMessage) -> String? {
            guard let replyID = message.replyToMessageID else { return nil }
            guard let quoted = messages.first(where: { $0.id == replyID }) else {
                // The quoted message predates linking; Signal never backfills
                // history to a new linked device.
                return "Original message unavailable"
            }
            let author =
                quoted.direction == .outgoing ? "You" : model.displayName(for: quoted.senderID)
            let preview = quoted.content.privacySafePreviewText
            return "\(author): \(preview.isEmpty && !quoted.attachments.isEmpty ? "Attachment" : preview)"
        }
    }

    private struct MessageDayGroup: Identifiable {
        var id: Date { date }
        let date: Date
        let messages: [ChatMessage]
    }

    private struct DateSeparator: View {
        let date: Date

        var body: some View {
            Text(date, format: .dateTime.month(.abbreviated).day().year())
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(SignalPalette.chipFill, in: Capsule())
                // A day break should read as a stronger division than a change
                // of speaker, so it gets more room than `separatedMessageSpacing`.
                .padding(.vertical, Metrics.systemMessageSpacing / 2)
        }
    }

    private struct PillChrome: ViewModifier {
        let visible: Bool
        let reduceTransparency: Bool

        func body(content: Content) -> some View {
            if visible {
                content.velaGlass(
                    .regular,
                    radius: Metrics.controlRadius,
                    reduceTransparency: reduceTransparency
                )
            } else {
                content.opacity(0)
            }
        }
    }

    private struct MessageTextSelection: ViewModifier {
        let enabled: Bool

        @ViewBuilder
        func body(content: Content) -> some View {
            if enabled {
                content.textSelection(.enabled)
            } else {
                content.textSelection(.disabled)
            }
        }
    }

    private struct MessageRow: View {
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovered = false
        @State private var revealedSpoilers: Set<SpoilerID> = []
        @State private var isShowingReactions = false
        @FocusState private var isKeyboardFocused: Bool

        /// Whether the action pill should be shown and clickable.
        ///
        /// The reaction picker is a popover in its own window, so moving the
        /// pointer into it leaves the row and clears `isHovered` — which used to
        /// hide the pill and disable hit testing mid-gesture, closing the picker
        /// the moment you reached for an emoji.
        private var isActive: Bool { isHovered || isShowingReactions || isKeyboardFocused }
        static let quickReactions = ["👍", "❤️", "😂", "😮", "😢", "🙏"]
        let message: ChatMessage
        let position: BubblePosition
        let showsTimestamp: Bool
        let showsReadLabel: Bool
        let senderName: String?
        let accessibilityAuthor: String
        let now: Date
        let replyPreview: String?
        let onReply: () -> Void
        let onEdit: () -> Void
        let onDelete: () -> Void
        let onReact: (String) -> Void
        let onRemoveReaction: () -> Void
        let localReactionEmoji: String?

        @ViewBuilder
        var body: some View {
            if message.direction == .system {
                systemMessage
            } else {
                standardMessage
            }
        }

        private var standardMessage: some View {
            HStack(alignment: .bottom, spacing: 8) {
                if message.direction == .outgoing { Spacer(minLength: 44) }

                // Tight: reactions and the "Read" label are attachments to the
                // bubble above them, and at 4pt they drifted far enough to read
                // as belonging to neither message.
                VStack(alignment: message.direction == .outgoing ? .trailing : .leading, spacing: 2) {
                    // Bubble and pill share a row that hugs its content, so the
                    // pill sits against the bubble rather than at the column edge.
                    // Centred rather than bottom-aligned: bottom alignment needed
                    // a hand-tuned offset to look right, which only held for a
                    // one-line bubble and drifted on every taller one.
                    HStack(alignment: .center, spacing: 6) {
                        if message.direction == .outgoing { actionPill }

                        VStack(alignment: .leading, spacing: 7) {
                            if let senderName {
                                Text(senderName)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(SignalPalette.senderColor(for: senderName))
                            }

                            if let replyPreview {
                                HStack(spacing: 6) {
                                    RoundedRectangle(cornerRadius: Metrics.quoteBarRadius)
                                        .frame(width: 3)
                                    Text(replyPreview)
                                        .lineLimit(2)
                                }
                                .font(.caption)
                                .foregroundStyle(
                                    message.direction == .outgoing
                                        ? SignalPalette.secondaryText(outgoing: true)
                                        : SignalPalette.secondaryText(outgoing: false)
                                )
                            }

                            if !message.attachments.isEmpty {
                                AttachmentList(
                                    attachments: message.attachments,
                                    isOutgoing: message.direction == .outgoing
                                )
                            }

                            // Keep compact messages inline. Long text falls back
                            // to a separate trailing metadata row instead of
                            // squeezing into a narrow unreadable column.
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .lastTextBaseline, spacing: 6) {
                                    messageContent
                                    if showsTimestamp { metaRow }
                                }
                                VStack(alignment: .trailing, spacing: 3) {
                                    messageContent
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if showsTimestamp { metaRow }
                                }
                            }
                        }
                        // Selection would copy covered spoiler text. Enable it
                        // only after every spoiler in this message is revealed.
                        .modifier(MessageTextSelection(enabled: hiddenSpoilers.isEmpty))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .background(bubbleBackground, in: bubbleShape)

                        if message.direction != .outgoing { actionPill }
                    }

                    if !message.reactions.isEmpty {
                        ReactionSummary(
                            reactions: message.reactions,
                            localReactionEmoji: localReactionEmoji,
                            onSelect: toggleReaction
                        )
                    }

                    // iMessage's convention, kept subtle and only on the newest
                    // read message so it does not fight the Google-style glyph.
                    // No horizontal padding: it lines up flush with the bubble's
                    // trailing edge, or it reads as floating between two
                    // messages rather than belonging to the one above.
                    if showsReadLabel {
                        Text("Read")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: 600, alignment: message.direction == .outgoing ? .trailing : .leading)

                if message.direction != .outgoing { Spacer(minLength: 44) }
            }
            // Quick actions appear on hover, as on Signal Desktop, rather than
            // hiding every action behind a right-click.
            .onHover { hovering in
                withAnimation(reduceMotion ? nil : GlassStyle.springy) { isHovered = hovering }
            }
            .focusable()
            .focused($isKeyboardFocused)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityDescription)
            .accessibilityHint("Use VoiceOver actions or context menu for message actions.")
            .accessibilityActions { accessibleMessageActions }
            .contextMenu { messageActions }
            .onChange(of: spoilerIDs) { _, _ in revealedSpoilers.removeAll() }
        }

        private var systemMessage: some View {
            HStack {
                Spacer(minLength: 24)
                Label(message.content.privacySafePreviewText, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(SignalPalette.chipFill, in: Capsule())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(message.content.privacySafePreviewText)
                Spacer(minLength: 24)
            }
            .padding(.vertical, Metrics.systemMessageSpacing / 2)
        }

        /// Shared by the right-click menu and the pill's "more" button, so the
        /// two routes cannot drift apart.
        @ViewBuilder
        private var messageActions: some View {
            if copyableText != nil {
                Button("Copy", action: copyMessageText)
            }

            Button("Reply", action: onReply)
                .disabled(message.direction == .system)

            Menu("React") {
                ForEach(Self.quickReactions, id: \.self) { emoji in
                    Button(emoji) { toggleReaction(emoji) }
                }
                if localReactionEmoji != nil {
                    Divider()
                    Button("Remove Reaction", action: onRemoveReaction)
                }
            }
            .disabled(isDeleted)

            if canEdit {
                Button("Edit", action: onEdit)
            }
            if canDelete {
                Button("Delete for everyone", role: .destructive, action: onDelete)
            }

            Divider()
            Button("Copy Message ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.id.rawValue, forType: .string)
            }
        }

        /// Mirrors every meaningful pointer action for VoiceOver users.
        @ViewBuilder
        private var accessibleMessageActions: some View {
            Button("Reply", action: onReply)
            if !isDeleted {
                ForEach(Self.quickReactions, id: \.self) { emoji in
                    Button(
                        localReactionEmoji == emoji ? "Remove reaction \(emoji)" : "React with \(emoji)"
                    ) {
                        toggleReaction(emoji)
                    }
                }
            }
            if copyableText != nil {
                Button("Copy", action: copyMessageText)
            }
            if canEdit {
                Button("Edit", action: onEdit)
            }
            if canDelete {
                Button("Delete for everyone", action: onDelete)
            }
        }

        private var copyableText: String? {
            switch message.content {
            case .text(let text): text
            case .styledText: visibleMessageText
            default: nil
            }
        }

        private func copyMessageText() {
            guard let copyableText else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copyableText, forType: .string)
        }

        private func toggleReaction(_ emoji: String) {
            if localReactionEmoji == emoji {
                onRemoveReaction()
            } else {
                onReact(emoji)
            }
        }

        @ViewBuilder
        private var messageContent: some View {
            switch message.content {
            case .text(let text):
                styledBody(text, styles: [])
            case .styledText(let text, let styles):
                styledBody(text, styles: styles)
            case .deleted:
                Label("Message deleted", systemImage: "trash")
                    .foregroundStyle(
                        SignalPalette.secondaryText(outgoing: message.direction == .outgoing)
                    )
                    .italic()
            case .unsupported(_, let description):
                Label(description, systemImage: "arrow.down.app")
                    .foregroundStyle(.secondary)
            case .system(let text):
                Text(text)
                    .foregroundStyle(.secondary)
                    .italic()
            }
        }

        /// Hover actions, sitting immediately beside the bubble on the side
        /// facing the middle of the window.
        ///
        /// Width is reserved even when hidden, so bubbles do not shuffle
        /// sideways as the pointer moves between messages.
        @ViewBuilder
        private var actionPill: some View {
            if message.direction == .system {
                Color.clear.frame(width: 0)
            } else {
                HStack(spacing: 2) {
                    Button {
                        isShowingReactions = true
                    } label: {
                        Image(systemName: "heart")
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "plus")
                                    .font(.system(size: 6, weight: .bold))
                                    .offset(x: 2, y: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(isDeleted)
                    .help("React")
                    .accessibilityLabel("React")
                    .popover(isPresented: $isShowingReactions, arrowEdge: .bottom) {
                        ReactionPicker { emoji in
                            isShowingReactions = false
                            toggleReaction(emoji)
                        }
                    }

                    Button(action: onReply) {
                        Image(systemName: "arrowshape.turn.up.left")
                    }
                    .buttonStyle(.plain)
                    .help("Reply")
                    .accessibilityLabel("Reply")

                    // Mirrors the right-click menu so both routes agree.
                    Menu {
                        messageActions
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .tint(.secondary)
                    .frame(width: 18)
                    .help("More")
                    .accessibilityLabel("More actions")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                // Glass renders into its own layer and ignores a parent's
                // opacity, so hiding the pill means not applying the material at
                // all. Padding stays either way, holding the bubble in place.
                .modifier(PillChrome(visible: isActive, reduceTransparency: reduceTransparency))
                .allowsHitTesting(isActive)
            }
        }

        /// Time, edit marker, expiry and delivery status, sized to sit inside the
        /// bubble beside the last line of text.
        private var metaRow: some View {
            HStack(spacing: 4) {
                if message.revision > 0 {
                    Text("Edited")
                }
                Text(RelativeTime.short(for: message.sentAt, reference: now))
                if let expiresAt = message.expiresAt {
                    Image(systemName: "timer")
                        .help("Expires \(expiresAt.formatted())")
                        .accessibilityLabel("Expires \(expiresAt.formatted())")
                }
                if message.direction == .outgoing {
                    DeliveryStatusIcon(state: message.deliveryState, isOutgoing: true)
                }
            }
            .font(.caption2)
            .foregroundStyle(SignalPalette.secondaryText(outgoing: message.direction == .outgoing))
            .help(RelativeTime.full(for: message.sentAt))
            // Pushes the meta to the trailing edge without stretching the bubble.
            .fixedSize()
        }

        /// One spoken sentence per message: who, what, when, and delivery state.
        /// Without this VoiceOver reads the bubble's parts as separate elements.
        private var accessibilityDescription: String {
            var parts = [accessibilityAuthor, accessibilityBodyText]
            if !message.attachments.isEmpty {
                parts.append("\(message.attachments.count) attachment\(message.attachments.count == 1 ? "" : "s")")
            }
            if message.revision > 0 { parts.append("edited") }
            parts.append(message.sentAt.formatted(date: .omitted, time: .shortened))
            if message.direction == .outgoing { parts.append(deliveryDescription) }
            return parts.joined(separator: ", ")
        }

        private var accessibilityBodyText: String {
            visibleMessageText
        }

        /// Text exposed outside visual cover. Each deliberately revealed range
        /// becomes readable while every remaining spoiler stays redacted.
        private var visibleMessageText: String {
            guard case .styledText(let text, let styles) = message.content else {
                return message.content.previewText
            }
            guard !revealedSpoilers.isEmpty else {
                return message.content.privacySafePreviewText
            }

            let hidden =
                styles
                .normalized(forUTF16Length: (text as NSString).length)
                .filter { $0.style == .spoiler && !revealedSpoilers.contains(SpoilerID($0)) }
                .sorted { $0.start > $1.start }
            var result = text
            for range in hidden {
                result = (result as NSString).replacingCharacters(in: range.nsRange, with: "Spoiler")
            }
            return result
        }

        private var deliveryDescription: String {
            switch message.deliveryState {
            case .queued: "queued"
            case .sending: "sending"
            case .sent: "sent"
            case .delivered: "delivered"
            case .read: "read"
            case .failedRetryable: "failed, will retry"
            case .failedPermanent: "failed"
            }
        }

        /// Renders a body with Signal's formatting runs applied.
        ///
        /// Spoilers stay hidden until clicked, so a spoiler is not defeated by
        /// simply appearing on screen.
        private func styledBody(_ text: String, styles: [TextStyleRange]) -> some View {
            let isOutgoing = message.direction == .outgoing
            return Text(attributed(text, styles: styles))
                .foregroundStyle(isOutgoing ? SignalPalette.outgoingText : SignalPalette.incomingText)
                // Hidden spoiler ranges are internal links. This keeps normal
                // links clickable and reveals only clicked spoiler range.
                .environment(
                    \.openURL,
                    OpenURLAction { url in
                        guard let spoiler = spoilerID(from: url), spoilerIDs.contains(spoiler) else {
                            return .systemAction
                        }
                        withAnimation(reduceMotion ? nil : GlassStyle.springy) {
                            _ = revealedSpoilers.insert(spoiler)
                        }
                        return .handled
                    }
                )
                .help(hiddenSpoilers.isEmpty ? "" : "Click hidden text to reveal that spoiler")
                .accessibilityLabel(accessibilityBodyText)
        }

        private func attributed(_ text: String, styles: [TextStyleRange]) -> AttributedString {
            var result = AttributedString(text)
            for style in styles.normalized(forUTF16Length: (text as NSString).length) {
                guard
                    let stringRange = style.range(in: text),
                    let range = Range(stringRange, in: result)
                else { continue }

                switch style.style {
                case .bold:
                    result[range].font = .body.bold()
                case .italic:
                    result[range].font = .body.italic()
                case .strikethrough:
                    result[range].strikethroughStyle = .single
                case .monospace:
                    result[range].font = .system(.body, design: .monospaced)
                case .spoiler:
                    let spoiler = SpoilerID(style)
                    if !revealedSpoilers.contains(spoiler) {
                        // Background matched to foreground blacks the text out
                        // rather than blurring, which cannot be screenshotted around.
                        let cover =
                            message.direction == .outgoing
                            ? SignalPalette.outgoingText
                            : SignalPalette.incomingText
                        result[range].backgroundColor = cover
                        result[range].foregroundColor = cover
                        result[range].link = spoiler.url
                    }
                }
            }

            addLinks(to: &result, in: text, styles: styles)
            return result
        }

        /// Marks detected URLs as links so they can be clicked.
        ///
        /// Signal sends plain text, so a shared URL is just characters — nothing
        /// upstream tells us where the links are. Detection happens here rather
        /// than at ingest so the stored message stays exactly what was sent.
        private func addLinks(to result: inout AttributedString, in text: String, styles: [TextStyleRange]) {
            guard
                let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            else { return }

            // A URL hidden behind an unrevealed spoiler must not be clickable,
            // or the spoiler leaks its destination to a hover.
            let hiddenRanges =
                styles
                .normalized(forUTF16Length: (text as NSString).length)
                .filter { $0.style == .spoiler && !revealedSpoilers.contains(SpoilerID($0)) }
                .compactMap { $0.range(in: text) }

            let full = NSRange(location: 0, length: (text as NSString).length)
            let isOutgoing = message.direction == .outgoing

            for match in detector.matches(in: text, range: full) {
                guard let url = match.url, let matched = Range(match.range, in: text) else { continue }
                guard !hiddenRanges.contains(where: { $0.overlaps(matched) }) else { continue }
                guard let range = Range(matched, in: result) else { continue }

                result[range].link = url
                // On ultramarine, white with an underline; the brand blue would
                // vanish into the bubble. On grey, the blue reads as a link.
                result[range].foregroundColor = isOutgoing ? .white : SignalPalette.ultramarine
                result[range].underlineStyle = .single
            }
        }

        private var bubbleShape: BubbleShape {
            BubbleShape(isOutgoing: message.direction == .outgoing, position: position)
        }

        private var bubbleBackground: AnyShapeStyle {
            // Signal's ultramarine, not the system accent: a green accent colour
            // was turning every outgoing bubble green.
            AnyShapeStyle(
                message.direction == .outgoing
                    ? SignalPalette.outgoingBubble
                    : SignalPalette.incomingBubble
            )
        }

        private var canEdit: Bool {
            guard message.direction == .outgoing else { return false }
            switch message.content {
            case .text, .styledText: return true
            default: return false
            }
        }

        private var canDelete: Bool {
            message.direction == .outgoing && !isDeleted
        }

        private var isDeleted: Bool {
            if case .deleted = message.content { return true }
            return false
        }

        private var spoilerIDs: Set<SpoilerID> {
            Set(
                message.content.textStyles
                    .normalized(forUTF16Length: (message.content.previewText as NSString).length)
                    .filter { $0.style == .spoiler }
                    .map(SpoilerID.init)
            )
        }

        private var hiddenSpoilers: Set<SpoilerID> {
            spoilerIDs.subtracting(revealedSpoilers)
        }

        private func spoilerID(from url: URL) -> SpoilerID? {
            guard url.scheme == SpoilerID.scheme, url.host == "reveal" else { return nil }
            let parts = url.pathComponents.filter { $0 != "/" }
            guard parts.count == 2, let start = Int(parts[0]), let length = Int(parts[1]) else {
                return nil
            }
            return SpoilerID(start: start, length: length)
        }

        private struct SpoilerID: Hashable {
            static let scheme = "vela-spoiler"
            let start: Int
            let length: Int

            init(start: Int, length: Int) {
                self.start = start
                self.length = length
            }

            init(_ range: TextStyleRange) {
                self.init(start: range.start, length: range.length)
            }

            var url: URL {
                // Numeric offsets reveal no message content to link previews.
                URL(string: "\(Self.scheme)://reveal/\(start)/\(length)")!
            }
        }
    }

    private struct ReactionSummary: View {
        let reactions: [MessageReaction]
        let localReactionEmoji: String?
        let onSelect: (String) -> Void

        var body: some View {
            HStack(spacing: 4) {
                ForEach(groups) { group in
                    Button {
                        onSelect(group.emoji)
                    } label: {
                        HStack(spacing: 3) {
                            Text(group.emoji)
                            if group.count > 1 {
                                Text(String(group.count))
                                    .font(.caption2.weight(.semibold))
                            }
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(SignalPalette.reactionFill, in: Capsule())
                        .overlay { Capsule().strokeBorder(SignalPalette.badgeStroke, lineWidth: 1) }
                    }
                    .buttonStyle(.plain)
                    .help(
                        localReactionEmoji == group.emoji
                            ? "Remove your \(group.emoji) reaction"
                            : "React with \(group.emoji)"
                    )
                    .accessibilityLabel(
                        "\(group.emoji), \(group.count) reaction\(group.count == 1 ? "" : "s")"
                    )
                    .accessibilityHint(
                        localReactionEmoji == group.emoji
                            ? "Removes your reaction."
                            : "Sets your reaction."
                    )
                }
            }
        }

        private var groups: [ReactionGroup] {
            Dictionary(grouping: reactions, by: \.emoji)
                .map { ReactionGroup(emoji: $0.key, count: $0.value.count) }
                .sorted { $0.emoji < $1.emoji }
        }

        private struct ReactionGroup: Identifiable {
            var id: String { emoji }
            let emoji: String
            let count: Int
        }
    }

    private struct AttachmentList: View {
        let attachments: [AttachmentReference]
        let isOutgoing: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(attachments) { attachment in
                    AttachmentRow(attachment: attachment, isOutgoing: isOutgoing)
                }
            }
            .foregroundStyle(
                isOutgoing
                    ? SignalPalette.secondaryText(outgoing: true)
                    : SignalPalette.secondaryText(outgoing: false)
            )
        }

    }

    private struct AttachmentRow: View {
        let attachment: AttachmentReference
        let isOutgoing: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 5) {
                if attachment.isViewOnce {
                    attachmentLabel(
                        icon: "eye.slash",
                        title: "View-once attachment",
                        detail: "Open on linked phone"
                    )
                    .accessibilityHint("Vela does not open view-once media outside protected viewer.")
                } else if shouldShowThumbnail, let localPath {
                    Button {
                        open(path: localPath)
                    } label: {
                        AttachmentThumbnail(path: localPath)
                    }
                    .buttonStyle(.plain)
                    .help("Open \(attachment.fileName ?? "image")")
                    .accessibilityLabel("Open \(attachment.fileName ?? "image attachment")")
                } else if let localPath {
                    Button {
                        open(path: localPath)
                    } label: {
                        attachmentLabel(
                            icon: icon,
                            title: attachment.fileName ?? "Attachment",
                            detail: sizeDescription
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Open \(attachment.fileName ?? "attachment")")
                    .accessibilityLabel("Open \(attachment.fileName ?? "attachment"), \(sizeDescription)")
                } else {
                    transferLabel
                }

                if let caption = attachment.caption, !caption.isEmpty {
                    Text(caption)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Caption: \(caption)")
                }
            }
        }

        @ViewBuilder
        private var transferLabel: some View {
            switch attachment.state {
            case .pending:
                attachmentLabel(
                    icon: "clock",
                    title: attachment.fileName ?? "Attachment",
                    detail: isOutgoing ? "Waiting to upload" : "Waiting to download"
                )
            case .transferring(let progress):
                VStack(alignment: .leading, spacing: 4) {
                    attachmentLabel(
                        icon: icon,
                        title: attachment.fileName ?? "Attachment",
                        detail: isOutgoing ? "Uploading" : "Downloading"
                    )
                    ProgressView(value: clamped(progress))
                        .frame(maxWidth: 180)
                        .accessibilityLabel(isOutgoing ? "Upload progress" : "Download progress")
                        .accessibilityValue("\(Int(clamped(progress) * 100)) percent")
                }
            case .failed(let reason):
                attachmentLabel(
                    icon: "exclamationmark.triangle.fill",
                    title: attachment.fileName ?? "Attachment failed",
                    detail: reason
                )
                .accessibilityLabel("Attachment failed: \(reason)")
            case .available:
                EmptyView()
            }
        }

        private func attachmentLabel(icon: String, title: String, detail: String) -> some View {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption2)
                        .opacity(0.75)
                        .lineLimit(2)
                }
            }
            .font(.caption)
        }

        private var localPath: String? {
            guard case .available(let path) = attachment.state else { return nil }
            return path
        }

        private var shouldShowThumbnail: Bool {
            attachment.mimeType.hasPrefix("image/")
                && attachment.byteCount <= Self.inlineImageByteLimit
        }

        private var sizeDescription: String {
            ByteCountFormatter.string(fromByteCount: attachment.byteCount, countStyle: .file)
        }

        private var icon: String {
            if attachment.mimeType.hasPrefix("image/") { return "photo" }
            if attachment.mimeType.hasPrefix("video/") { return "video" }
            if attachment.mimeType.hasPrefix("audio/") { return "waveform" }
            return "doc"
        }

        private func clamped(_ progress: Double) -> Double {
            min(max(progress, 0), 1)
        }

        private func open(path: String) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }

        /// 25 MB, matching Signal's attachment ceiling.
        private static let inlineImageByteLimit: Int64 = 25 * 1024 * 1024
    }

    private struct AttachmentThumbnail: View {
        let path: String
        @State private var image: NSImage?
        @State private var didFinishLoading = false

        var body: some View {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if !didFinishLoading {
                    ZStack {
                        RoundedRectangle(cornerRadius: Metrics.thumbnailRadius, style: .continuous)
                            .fill(.quaternary.opacity(0.35))
                        ProgressView()
                            .controlSize(.small)
                    }
                    .frame(width: 180, height: 120)
                } else {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 28, weight: .light))
                        .frame(width: 180, height: 120)
                }
            }
            .frame(maxWidth: 320, maxHeight: 320)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.thumbnailRadius, style: .continuous))
            .accessibilityHidden(true)
            .task(id: path) {
                didFinishLoading = false
                image = await AttachmentThumbnailCache.shared.thumbnail(path: path, maxPixelSize: 640)
                didFinishLoading = true
            }
        }
    }

    /// Caches display-sized images. ImageIO decodes off main actor, avoiding a
    /// full-resolution decode every time LazyVStack recycles a message row.
    @MainActor
    private final class AttachmentThumbnailCache {
        static let shared = AttachmentThumbnailCache()
        private let images: NSCache<NSString, NSImage>

        private init() {
            images = NSCache()
            images.totalCostLimit = 48 * 1024 * 1024
            images.countLimit = 80
        }

        func thumbnail(path: String, maxPixelSize: Int) async -> NSImage? {
            let key = "\(path)#\(maxPixelSize)" as NSString
            if let cached = images.object(forKey: key) { return cached }

            let decoded = await Task.detached(priority: .utility) {
                let url = URL(fileURLWithPath: path) as CFURL
                let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
                guard let source = CGImageSourceCreateWithURL(url, sourceOptions) else { return SendableCGImage?.none }
                let options =
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                    ] as CFDictionary
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
                    return SendableCGImage?.none
                }
                return SendableCGImage(image)
            }.value

            guard !Task.isCancelled, let decoded else { return nil }
            let image = NSImage(cgImage: decoded.value, size: .zero)
            let cost = decoded.value.bytesPerRow * decoded.value.height
            images.setObject(image, forKey: key, cost: cost)
            return image
        }
    }

    private struct SendableCGImage: @unchecked Sendable {
        let value: CGImage

        init(_ value: CGImage) {
            self.value = value
        }
    }
#endif
