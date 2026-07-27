#if os(macOS)
    import SwiftUI
    import VelaDomain

    struct ConversationSidebarView: View {
        @EnvironmentObject private var model: AppModel
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

        var body: some View {
            List(selection: selectionBinding) {
                if model.filteredConversations.isEmpty {
                    emptyState
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(model.filteredConversations) { conversation in
                        HStack(spacing: 6) {
                            ConversationRow(conversation: conversation)
                            if conversation.isArchived {
                                Button {
                                    model.setArchived(false, conversationID: conversation.id)
                                } label: {
                                    Image(systemName: "tray.and.arrow.up")
                                }
                                .buttonStyle(.plain)
                                .help("Unarchive")
                                .accessibilityLabel("Unarchive \(model.displayName(for: conversation))")
                            }
                        }
                        .tag(conversation.id)
                        .contextMenu {
                            Button(conversation.isPinned ? "Unpin" : "Pin") {
                                model.setPinned(!conversation.isPinned, conversationID: conversation.id)
                            }
                            Button(conversation.isArchived ? "Unarchive" : "Archive") {
                                model.setArchived(!conversation.isArchived, conversationID: conversation.id)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollEdgeEffectStyle(.soft, for: .top)
            // Overlay rather than a permanent track down the edge.
            .scrollIndicators(.automatic)
            .environment(\.defaultMinListRowHeight, 44)
            .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search conversations")
            .navigationTitle(model.isShowingArchivedConversations ? "Archived" : "Vela")
            .safeAreaInset(edge: .bottom) {
                HStack {
                    if let account = model.snapshot.linkedAccount {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(account.deviceName)
                                .font(.callout.weight(.medium))
                            Text(model.isDevelopmentMode ? "Local development account" : "Linked device")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        model.isShowingArchivedConversations.toggle()
                        model.searchText = ""
                        model.selectConversation(nil)
                    } label: {
                        Label(
                            model.isShowingArchivedConversations ? "Inbox" : "Archived",
                            systemImage: model.isShowingArchivedConversations ? "tray" : "archivebox"
                        )
                        .labelStyle(.iconOnly)
                        .overlay(alignment: .topTrailing) {
                            if !model.isShowingArchivedConversations,
                                model.archivedConversationCount > 0
                            {
                                Text(model.archivedConversationCount > 99 ? "99+" : String(model.archivedConversationCount))
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 3)
                                    .background(SignalPalette.badge, in: Capsule())
                                    .offset(x: 7, y: -5)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help(model.isShowingArchivedConversations ? "Return to conversations" : "Browse archived conversations")
                    .accessibilityLabel(model.isShowingArchivedConversations ? "Show conversations" : "Show archived conversations")
                    .accessibilityValue(
                        model.isShowingArchivedConversations
                            ? ""
                            : "\(model.archivedConversationCount) archived"
                    )

                    SettingsLink {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.plain)
                    .help("Settings")
                    .accessibilityLabel("Open Settings")
                }
                .padding(10)
                .velaGlass(
                    .regular,
                    radius: 0,
                    reduceTransparency: reduceTransparency
                )
                .overlay(alignment: .top) { Divider() }
            }
        }

        private var selectionBinding: Binding<ConversationID?> {
            Binding(
                get: { model.selectedConversationID },
                set: { model.selectConversation($0) }
            )
        }

        @ViewBuilder
        private var emptyState: some View {
            if !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            } else if model.isShowingArchivedConversations {
                ContentUnavailableView(
                    "No archived conversations",
                    systemImage: "archivebox",
                    description: Text("Archived conversations appear here. You can restore them at any time.")
                )
            } else {
                ContentUnavailableView(
                    "No conversations",
                    systemImage: "message",
                    description: Text("Start a new conversation to see it here.")
                )
            }
        }
    }

    private struct ConversationRow: View {
        let conversation: Conversation
        @EnvironmentObject private var model: AppModel

        var body: some View {
            HStack(spacing: 10) {
                ContactAvatarView(
                    contact: contact,
                    fallbackText: displayName,
                    size: 32
                )

                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(displayName)
                            .font(.callout.weight(conversation.unreadCount > 0 ? .semibold : .regular))
                            .lineLimit(1)
                        if conversation.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let timestamp = conversation.lastMessage?.timestamp {
                            SidebarTimestamp(timestamp: timestamp)
                        }
                    }

                    HStack {
                        Text(previewText)
                            .font(.caption)
                            .foregroundStyle(conversation.unreadCount > 0 ? .primary : .secondary)
                            .lineLimit(1)
                        Spacer()
                        if conversation.unreadCount > 0 {
                            Text(conversation.unreadCount > 99 ? "99+" : String(conversation.unreadCount))
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(SignalPalette.badge, in: Capsule())
                                .contentTransition(.numericText())
                        }
                    }
                }
            }
            .padding(.vertical, 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityValue(
                conversation.unreadCount > 0
                    ? "\(conversation.unreadCount) unread"
                    : "Read"
            )
        }

        /// Prefers a synced contact name over the identifier the conversation
        /// was created with, so threads stop showing raw phone numbers.
        private var displayName: String {
            model.displayName(for: conversation)
        }

        private var contact: Contact? {
            guard case .direct(let recipientID) = conversation.kind else { return nil }
            return model.contact(for: recipientID)
        }

        private var previewText: String {
            guard let preview = conversation.lastMessage else { return "No messages yet" }
            let text = preview.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let content = text.isEmpty ? "Attachment" : text
            return preview.isOutgoing ? "You: \(content)" : content
        }

        private var accessibilitySummary: String {
            [displayName, previewText]
                .joined(separator: ", ")
        }
    }

    private struct SidebarTimestamp: View {
        let timestamp: Date

        var body: some View {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(RelativeTime.short(for: timestamp, reference: context.date))
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .help(RelativeTime.full(for: timestamp))
            .accessibilityLabel(RelativeTime.full(for: timestamp))
        }
    }
#endif
