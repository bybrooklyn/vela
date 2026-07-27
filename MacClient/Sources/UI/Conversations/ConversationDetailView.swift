#if os(macOS)
    import AppKit
    import SwiftUI
    import UniformTypeIdentifiers
    import VelaDomain

    struct ConversationDetailView: View {
        @EnvironmentObject private var model: AppModel
        let conversation: Conversation

        var body: some View {
            VStack(spacing: 0) {
                header
                Divider()
                if model.isLoadingMessages {
                    ProgressView("Loading messages…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("Loading messages")
                } else {
                    MessageTimelineView(
                        isGroup: isGroup,
                        messages: model.messages,
                        onReply: model.beginReply,
                        onEdit: model.beginEdit,
                        onDelete: model.deleteMessage,
                        onReact: model.react,
                        onRemoveReaction: model.removeReaction,
                        onLoadEarlier: model.loadOlderMessages,
                        hasEarlierMessages: model.canLoadOlderMessages,
                        isLoadingEarlier: model.isLoadingOlderMessages
                    )
                }
                Divider()
                ComposerBar()
            }
            .navigationTitle(model.displayName(for: conversation))
            .toolbar {
                ToolbarItemGroup {
                    if model.isDevelopmentMode {
                        Button {
                            model.simulateIncomingReply()
                        } label: {
                            Label("Simulate Reply", systemImage: "arrow.down.message")
                        }
                        .help("Inject a local incoming envelope")
                    }

                    Menu {
                        Button(conversation.isPinned ? "Unpin" : "Pin") {
                            model.setPinned(!conversation.isPinned, conversationID: conversation.id)
                        }
                        Button("Archive") {
                            model.setArchived(true, conversationID: conversation.id)
                        }
                    } label: {
                        Label("Conversation Actions", systemImage: "ellipsis.circle")
                    }
                }
            }
        }

        private var isGroup: Bool {
            if case .group = conversation.kind { return true }
            return false
        }

        private var headerContact: Contact? {
            guard case .direct(let recipientID) = conversation.kind else { return nil }
            return model.contact(for: recipientID)
        }

        private var header: some View {
            HStack(spacing: 12) {
                ContactAvatarView(
                    contact: headerContact,
                    fallbackText: model.displayName(for: conversation),
                    size: 40
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName(for: conversation))
                        .font(.headline)
                    Text(kindDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }

        private var kindDescription: String {
            switch conversation.kind {
            case .direct: "Direct conversation"
            case .group(_, let members): "Group · \(members.count) members"
            case .noteToSelf: "Note to Self"
            }
        }
    }

    private struct ComposerBar: View {
        @EnvironmentObject private var model: AppModel
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
        @State private var selection = NSRange(location: 0, length: 0)
        @State private var composerHeight = NativeComposerView.minimumHeight
        @State private var isAttachmentPickerPresented = false
        @State private var isDropTarget = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        /// An attachment with no caption is a valid message.
        private var canSend: Bool {
            !model.isStagingAttachments(in: model.selectedConversationID)
                && (!model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || (model.editingMessageID == nil && !model.pendingAttachments.isEmpty))
        }

        var body: some View {
            VStack(spacing: 0) {
                if model.replyingToMessage != nil || model.editingMessage != nil {
                    ComposerContextStrip()
                    Divider()
                }

                HStack(alignment: .bottom, spacing: 10) {
                    Button {
                        presentAttachmentPicker()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Attach files")
                    .accessibilityLabel("Attach files")
                    .accessibilityHint("Choose one or more files to add to this message")
                    .disabled(isAttachmentPickerPresented || model.editingMessageID != nil)

                    NativeComposerView(
                        text: $model.composerText,
                        styles: $model.composerStyles,
                        measuredHeight: $composerHeight,
                        placeholder: model.editingMessageID == nil ? "Message" : "Edit message",
                        onSend: model.sendComposerMessage,
                        onSelectionChange: { selection = $0 }
                    )
                    // Exact height, not a flexible range: NSScrollView has no
                    // intrinsic size, so a range made SwiftUI hand it the full
                    // maximum and the composer was always tall.
                    .frame(minWidth: 120, maxWidth: .infinity)
                    .frame(height: composerHeight)
                    .layoutPriority(1)
                    .animation(
                        reduceMotion ? nil : GlassStyle.springy,
                        value: composerHeight
                    )
                    // Debounced inside the model; Signal's indicator lasts
                    // ~15s so this is not per keystroke.
                    .onChange(of: model.composerText) { _, newValue in
                        if !newValue.isEmpty { model.composerActivity() }
                    }
                    // Padding plus the one-line text height must come to exactly
                    // `Metrics.composerBoxHeight`, or the radius below is half of
                    // something other than the box and the pill reads as almost
                    // round rather than round.
                    .padding(NativeComposerView.verticalInset)
                    .velaGlass(
                        .regular,
                        radius: Metrics.composerRadius,
                        reduceTransparency: reduceTransparency
                    )

                    SendButton(isEditing: model.editingMessageID != nil, isEnabled: canSend) {
                        model.sendComposerMessage()
                    }
                }
                .padding(12)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if selection.length > 0 {
                    FormattingBar(activeStyles: activeStyles) { toggleComposerStyle($0) }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if !model.pendingAttachments.isEmpty {
                    PendingAttachmentStrip()
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if model.isStagingAttachments(in: model.selectedConversationID) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Copying attachments into Vela…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Copying attachments into Vela")
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let id = model.selectedConversationID,
                    let typing = model.typingDescription(for: id)
                {
                    TypingIndicatorRow(text: typing)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .spring(duration: 0.28), value: model.typingParticipants)
            .background(.bar)
            .overlay {
                if isDropTarget {
                    RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                        .stroke(SignalPalette.ultramarine, lineWidth: 2)
                        .background(
                            SignalPalette.ultramarine.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                        )
                        .padding(3)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isDropTarget)
            // Dropping onto the composer is the fastest way to send a file.
            .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
                Task { @MainActor in
                    var urls: [URL] = []
                    for provider in providers {
                        let item = try? await provider.loadItem(
                            forTypeIdentifier: UTType.fileURL.identifier
                        )
                        if let resolved = item as? URL {
                            urls.append(resolved)
                        } else if let data = item as? Data,
                            let resolved = URL(dataRepresentation: data, relativeTo: nil)
                        {
                            urls.append(resolved)
                        }
                    }
                    model.attachFiles(urls)
                }
                return true
            }
        }

        private func presentAttachmentPicker() {
            guard !isAttachmentPickerPresented else { return }
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            panel.prompt = "Attach"
            isAttachmentPickerPresented = true
            panel.begin { response in
                isAttachmentPickerPresented = false
                guard response == .OK else { return }
                model.attachFiles(panel.urls)
            }
        }

        private var activeStyles: Set<TextStyleRange.Style> {
            guard selection.location != NSNotFound, selection.length > 0 else { return [] }
            let end = selection.location + selection.length
            return Set(
                model.composerStyles.compactMap { range in
                    guard range.start <= selection.location, range.start + range.length >= end else { return nil }
                    return range.style
                })
        }

        /// Match native keyboard shortcuts: applying an active style removes it
        /// from the selection; applying an inactive style adds it.
        private func toggleComposerStyle(_ style: TextStyleRange.Style) {
            guard selection.location != NSNotFound, selection.length > 0 else { return }
            let limit = (model.composerText as NSString).length
            guard selection.location + selection.length <= limit else { return }

            var updated = model.composerStyles
            if activeStyles.contains(style) {
                updated = updated.flatMap { range in
                    guard range.style == style else { return [range] }
                    return subtract(selection, from: range)
                }
            } else {
                updated.append(
                    TextStyleRange(start: selection.location, length: selection.length, style: style)
                )
            }
            model.composerStyles = updated.normalized(forUTF16Length: limit)
        }

        private func subtract(_ selection: NSRange, from style: TextStyleRange) -> [TextStyleRange] {
            let styleEnd = style.start + style.length
            let cutEnd = selection.location + selection.length
            guard selection.location < styleEnd, cutEnd > style.start else { return [style] }

            var pieces: [TextStyleRange] = []
            if style.start < selection.location {
                pieces.append(
                    TextStyleRange(
                        start: style.start,
                        length: selection.location - style.start,
                        style: style.style
                    )
                )
            }
            if cutEnd < styleEnd {
                pieces.append(TextStyleRange(start: cutEnd, length: styleEnd - cutEnd, style: style.style))
            }
            return pieces
        }
    }

    /// Files staged for the next send, with a way to take them back off.
    private struct PendingAttachmentStrip: View {
        @EnvironmentObject private var model: AppModel

        var body: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.pendingAttachments) { attachment in
                        HStack(spacing: 8) {
                            AttachmentThumbnail(attachment: attachment)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(attachment.fileName ?? "Attachment")
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                Text(attachmentSummary(attachment))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Button {
                                model.removeAttachment(attachment.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Remove \(attachment.fileName ?? "attachment")")
                        }
                        .padding(6)
                        .frame(minWidth: 160, maxWidth: 240, alignment: .leading)
                        .background(
                            SignalPalette.chipFill,
                            in: RoundedRectangle(cornerRadius: Metrics.chipRadius, style: .continuous)
                        )
                        .accessibilityElement(children: .contain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
            .frame(height: 58)
            .accessibilityLabel("Attachments ready to send")
        }

        private func attachmentSummary(_ attachment: AttachmentReference) -> String {
            let type = UTType(mimeType: attachment.mimeType)?.localizedDescription ?? attachment.mimeType
            let size = ByteCountFormatter.string(fromByteCount: attachment.byteCount, countStyle: .file)
            return "\(type) · \(size)"
        }
    }

    private struct AttachmentThumbnail: View {
        let attachment: AttachmentReference

        var body: some View {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: iconName)
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 34, height: 34)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
        }

        private var image: NSImage? {
            guard attachment.mimeType.hasPrefix("image/"), case .available(let path) = attachment.state else {
                return nil
            }
            return NSImage(contentsOfFile: path)
        }

        private var iconName: String {
            if attachment.mimeType.hasPrefix("video/") { return "film" }
            if attachment.mimeType.hasPrefix("audio/") { return "waveform" }
            if attachment.mimeType == "application/pdf" { return "doc.richtext" }
            if attachment.mimeType.hasPrefix("text/") { return "doc.text" }
            return "doc"
        }
    }

    private struct ComposerContextStrip: View {
        @EnvironmentObject private var model: AppModel

        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: model.editingMessageID == nil ? "arrowshape.turn.up.left" : "pencil")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    // Naming who is being answered makes a reply readable
                    // without scrolling back to find it.
                    Text(headline)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 28, height: 28)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: Metrics.quoteThumbnailRadius,
                                style: .continuous
                            )
                        )
                }
                Button {
                    model.cancelComposerContext(clearText: model.editingMessageID != nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Cancel")
                .accessibilityLabel(model.editingMessageID == nil ? "Cancel reply" : "Cancel edit")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }

        private var contextMessage: ChatMessage? {
            model.editingMessage ?? model.replyingToMessage
        }

        private var headline: String {
            guard model.editingMessageID == nil else { return "Editing" }
            guard let message = contextMessage else { return "Replying" }
            let who = message.direction == .outgoing ? "yourself" : model.displayName(for: message.senderID)
            return "Replying to \(who)"
        }

        private var preview: String {
            guard let message = contextMessage else { return "Message unavailable" }
            let preview = message.content.privacySafePreviewText
            if preview.isEmpty, !message.attachments.isEmpty {
                return message.attachments.first?.fileName ?? "Attachment"
            }
            return preview
        }

        /// Shows the image being replied to, so a reply to a photo is obvious.
        private var thumbnail: NSImage? {
            guard
                let attachment = contextMessage?.attachments.first,
                attachment.mimeType.hasPrefix("image/"),
                case .available(let path) = attachment.state
            else { return nil }
            return NSImage(contentsOfFile: path)
        }
    }
#endif
