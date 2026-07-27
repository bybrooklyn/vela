#if os(macOS)
    import SwiftUI
    import VelaDomain

    struct NewConversationSheet: View {
        @EnvironmentObject private var model: AppModel
        @Environment(\.dismiss) private var dismiss
        @State private var kind: ConversationCreationKind = .direct
        @State private var title = ""
        @State private var recipients = ""
        @State private var search = ""
        @State private var selected: Set<RecipientID> = []
        @State private var didRequestContactSync = false

        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                Text("New Conversation")
                    .font(.title2.bold())

                Picker("Kind", selection: $kind) {
                    ForEach(ConversationCreationKind.allCases) { kind in
                        Label(kind.title, systemImage: kind.systemImage)
                            .tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                if kind == .noteToSelf {
                    Text("Messages to yourself, synced across your devices.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if !didRequestContactSync && model.contacts.isEmpty {
                    contactLoading
                } else if model.contacts.isEmpty {
                    manualEntry
                } else {
                    contactPicker
                }

                HStack {
                    if model.isSyncingContacts {
                        ProgressView().controlSize(.small)
                        Text("Syncing contacts…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Create") {
                        create()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
                }
            }
            .padding(24)
            .frame(minWidth: 460, idealWidth: 560, maxWidth: 680)
            .frame(
                minHeight: kind == .noteToSelf ? 220 : 440,
                idealHeight: kind == .noteToSelf ? 240 : 560,
                maxHeight: kind == .noteToSelf ? 280 : 720
            )
            .presentationSizing(.fitted)
            .task {
                await model.syncContacts()
                didRequestContactSync = true
            }
            .onChange(of: kind) { _, _ in
                selected.removeAll()
                search = ""
                recipients = ""
                title = ""
            }
            .onChange(of: recipients) { _, value in
                if kind == .direct,
                    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    selected.removeAll()
                }
            }
        }

        private var contactLoading: some View {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading contacts…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
            .accessibilityElement(children: .combine)
        }

        // Shown before the first contact sync completes, and in builds with no
        // backend, so a conversation can always be started.
        private var manualEntry: some View {
            Form {
                TextField(kind == .group ? "Group name" : "Display name (optional)", text: $title)
                if kind == .direct {
                    TextField("Phone number or username", text: $recipients)
                } else {
                    TextField("Members, comma separated", text: $recipients, axis: .vertical)
                        .lineLimit(2...5)
                }
            }
            .formStyle(.grouped)
        }

        private var contactPicker: some View {
            VStack(alignment: .leading, spacing: 10) {
                if kind == .group {
                    TextField("Group name", text: $title)
                        .textFieldStyle(.roundedBorder)
                }

                TextField(
                    kind == .direct
                        ? "Username or phone number"
                        : "Additional members, comma separated",
                    text: $recipients,
                    axis: kind == .group ? .vertical : .horizontal
                )
                .lineLimit(kind == .group ? 2...4 : 1...1)
                .textFieldStyle(.roundedBorder)

                TextField("Search contacts, usernames, or phone numbers", text: $search)
                    .textFieldStyle(.roundedBorder)

                if !selectedContacts.isEmpty {
                    selectionReview
                }

                if filteredContacts.isEmpty {
                    ContentUnavailableView.search(text: search)
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    List(filteredContacts, id: \.recipientID) { contact in
                        let isSelected = selected.contains(contact.recipientID)
                        Button {
                            toggle(contact)
                        } label: {
                            HStack(spacing: 10) {
                                ContactAvatarView(contact: contact, fallbackText: contact.displayName)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(contact.displayName)
                                    if let detail = contactDetail(contact), detail != contact.displayName {
                                        Text(detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if isSelected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                        .accessibilityHidden(true)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(contactAccessibilityLabel(contact))
                        .accessibilityValue(isSelected ? "Selected" : "Not selected")
                        .accessibilityHint(
                            kind == .direct
                                ? "Selects this contact as the recipient."
                                : "Toggles this contact in the group."
                        )
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                    .listStyle(.inset)
                }
            }
        }

        private var selectionReview: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(kind == .direct ? "Selected recipient" : "Selected members (\(selected.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(selectedContacts, id: \.recipientID) { contact in
                            Button {
                                selected.remove(contact.recipientID)
                            } label: {
                                Label(contact.displayName, systemImage: "xmark.circle.fill")
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                            .accessibilityLabel("Remove \(contact.displayName) from selection")
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            .accessibilityElement(children: .contain)
        }

        private var filteredContacts: [Contact] {
            let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return model.contacts }
            return model.contacts.filter {
                $0.displayName.localizedCaseInsensitiveContains(trimmed)
                    || ($0.phoneNumber?.localizedCaseInsensitiveContains(trimmed) ?? false)
                    || ($0.username?.localizedCaseInsensitiveContains(trimmed) ?? false)
                    || ($0.aci?.localizedCaseInsensitiveContains(trimmed) ?? false)
                    || $0.recipientID.rawValue.localizedCaseInsensitiveContains(trimmed)
            }
        }

        private var selectedContacts: [Contact] {
            model.contacts
                .filter { selected.contains($0.recipientID) }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }

        private func contactAccessibilityLabel(_ contact: Contact) -> String {
            guard let detail = contactDetail(contact), detail != contact.displayName else {
                return contact.displayName
            }
            return "\(contact.displayName), \(detail)"
        }

        private func contactDetail(_ contact: Contact) -> String? {
            contact.username ?? contact.phoneNumber ?? contact.aci
        }

        private func toggle(_ contact: Contact) {
            if kind == .direct {
                // A direct conversation has exactly one counterpart.
                selected = selected.contains(contact.recipientID) ? [] : [contact.recipientID]
                if !selected.isEmpty { recipients = "" }
            } else if selected.contains(contact.recipientID) {
                selected.remove(contact.recipientID)
            } else {
                selected.insert(contact.recipientID)
            }
        }

        private var isValid: Bool {
            switch kind {
            case .noteToSelf:
                return true
            case .direct:
                return selected.count == 1
                    || !recipients.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .group:
                let named = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                return named && (!selected.isEmpty || !manualRecipients.isEmpty)
            }
        }

        private var manualRecipients: [String] {
            recipients
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        private func create() {
            switch kind {
            case .noteToSelf:
                model.createNoteToSelfConversation()
            case .direct:
                if let recipientID = selected.first {
                    let name = model.contact(for: recipientID)?.displayName ?? recipientID.rawValue
                    model.createDirectConversation(title: name, recipient: recipientID.rawValue)
                } else {
                    let recipient = recipients.trimmingCharacters(in: .whitespacesAndNewlines)
                    let displayName = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.createDirectConversation(
                        title: displayName.isEmpty ? recipient : displayName,
                        recipient: recipient
                    )
                }
            case .group:
                model.createGroupConversation(
                    title: title,
                    members: (selected.map(\.rawValue) + manualRecipients).sorted()
                )
            }
        }
    }

    private enum ConversationCreationKind: String, CaseIterable, Identifiable {
        case direct
        case group
        case noteToSelf

        var id: String { rawValue }

        var title: String {
            switch self {
            case .direct: "Direct"
            case .group: "Group"
            case .noteToSelf: "Self"
            }
        }

        var systemImage: String {
            switch self {
            case .direct: "person"
            case .group: "person.3"
            case .noteToSelf: "note.text"
            }
        }
    }
#endif
