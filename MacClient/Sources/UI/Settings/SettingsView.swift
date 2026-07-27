#if os(macOS)
    import AppKit
    import SwiftUI

    struct SettingsView: View {
        @EnvironmentObject private var model: AppModel
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize
        @Binding private var isActive: Bool
        @State private var isShowingDiagnostics = false

        init(isActive: Binding<Bool> = .constant(true)) {
            _isActive = isActive
        }

        var body: some View {
            Group {
                if model.isAppLocked {
                    LockView()
                } else {
                    settingsTabs
                }
            }
            .onChange(of: model.isAppLocked) { _, isLocked in
                if isLocked {
                    isShowingDiagnostics = false
                }
            }
            .onAppear { isActive = true }
            .onDisappear { isActive = false }
            .alert(
                model.alertTitle,
                isPresented: Binding(
                    get: { !model.isAppLocked && model.alertMessage != nil },
                    set: { showing in if !showing { model.alertMessage = nil } }
                ),
                actions: {
                    Button("OK") { model.alertMessage = nil }
                },
                message: {
                    Text(model.alertMessage ?? "")
                }
            )
        }

        private var settingsTabs: some View {
            TabView {
                GeneralSettingsView()
                    .tabItem { Label("General", systemImage: "gear") }

                PrivacySettingsView()
                    .tabItem { Label("Privacy", systemImage: "hand.raised") }

                StorageSettingsView()
                    .tabItem { Label("Storage", systemImage: "externaldrive") }

                DiagnosticsSettingsView {
                    model.refreshDiagnostics()
                    isShowingDiagnostics = true
                }
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }

                AboutSettingsView()
                    .tabItem { Label("About", systemImage: "info.circle") }
            }
            .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 8 : 16)
            .padding(.bottom, dynamicTypeSize.isAccessibilitySize ? 4 : 12)
            .controlSize(dynamicTypeSize.isAccessibilitySize ? .large : .regular)
            .onAppear { model.refreshDiagnostics() }
            .sheet(isPresented: $isShowingDiagnostics) {
                DiagnosticsView()
                    .environmentObject(model)
                    .frame(minWidth: 700, idealWidth: 820, minHeight: 480, idealHeight: 560)
            }
        }
    }

    private struct GeneralSettingsView: View {
        @EnvironmentObject private var model: AppModel
        @State private var isShowingResetConfirmation = false

        var body: some View {
            Form {
                Section("Startup") {
                    Toggle(
                        "Open Vela at login",
                        isOn: Binding(
                            get: { model.launchAtLogin.isEnabled },
                            set: { model.launchAtLogin.setEnabled($0) }
                        )
                    )
                    if let error = model.launchAtLogin.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Startup settings")

                Section("Signal backend") {
                    LabeledContent("signal-cli") {
                        switch model.backendStatus {
                        case .checking:
                            ProgressView().controlSize(.small)
                        case .ready(let version):
                            Label(version, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .notEmbedded:
                            Label(model.backendStatus.summary, systemImage: "xmark.circle")
                                .foregroundStyle(.secondary)
                        case .failed:
                            Label("Unavailable", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                    if case .failed(let reason) = model.backendStatus {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    Button("Re-check") {
                        Task { await model.refreshBackendStatus() }
                    }
                    .accessibilityHint("Checks embedded signal-cli availability and version")

                    if model.snapshot.linkedAccount != nil,
                        model.snapshot.connection != .connected
                    {
                        LabeledContent("Connection", value: connectionSummary)
                        if model.canRetryConnection {
                            Button {
                                model.retryConnection()
                            } label: {
                                if model.isRetryingConnection {
                                    Label("Retrying…", systemImage: "arrow.clockwise")
                                } else {
                                    Label("Retry connection", systemImage: "arrow.clockwise")
                                }
                            }
                            .disabled(model.isRetryingConnection)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Signal backend settings")

                Section("Contacts") {
                    LabeledContent("Synced", value: "\(model.contacts.count)")
                    Button("Sync from phone") {
                        Task { await model.syncContacts() }
                    }
                    .disabled(model.isSyncingContacts || model.snapshot.linkedAccount == nil)
                    if model.isSyncingContacts {
                        ProgressView().controlSize(.small)
                    }
                    Text("Names and avatars are copied from your phone. Signal keeps the authoritative list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Contact sync settings")

                Section("Account") {
                    if let account = model.snapshot.linkedAccount {
                        LabeledContent("Device name", value: account.deviceName)
                        LabeledContent("Linked", value: account.linkedAt.formatted(date: .abbreviated, time: .shortened))
                        Button("Reset and unlink", role: .destructive) {
                            isShowingResetConfirmation = true
                        }
                        .accessibilityHint("Requests confirmation before deleting local Vela data")
                        Text(
                            "Deletes all local messages, contacts and account data, then shows a new QR code. Remove the old device from Linked Devices on your phone as well."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        Text("No linked account")
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Linked account settings")
            }
            .formStyle(.grouped)
            .confirmationDialog(
                "Reset and unlink Vela?",
                isPresented: $isShowingResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Reset and Unlink", role: .destructive) {
                    model.unlinkAndDelete()
                }
            } message: {
                Text(
                    "Local messages, contacts, and account data will be deleted. "
                        + "This cannot be undone. You must also remove Vela from linked devices on your phone."
                )
            }
        }

        private var connectionSummary: String {
            switch model.snapshot.connection {
            case .connected: "Connected"
            case .connecting: "Connecting"
            case .backingOff(let attempt, let retryAt):
                "Retry \(attempt) at \(retryAt.formatted(date: .omitted, time: .shortened))"
            case .disconnected: "Offline"
            case .failed(let category): "Failed: \(category)"
            }
        }
    }

    private struct PrivacySettingsView: View {
        @EnvironmentObject private var model: AppModel

        var body: some View {
            Form {
                Section("Application lock") {
                    LabeledContent("System authentication") {
                        Text(model.localAppLock.isAvailable ? "Available" : "Unavailable")
                            .foregroundStyle(.secondary)
                    }
                    Button("Lock now") {
                        model.lock()
                    }
                    .disabled(model.snapshot.linkedAccount == nil || !model.localAppLock.isAvailable)
                    if !model.localAppLock.isAvailable {
                        Text("Set a Mac login password before using Vela's application lock.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(
                        "Vela also locks automatically when the Mac sleeps. This protects casual local access, not malware running as your logged-in user."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Application lock settings")

                Section("Read receipts and typing") {
                    Toggle("Send read receipts", isOn: $model.sendsReadReceipts)
                    Toggle("Send typing indicators", isOn: $model.sendsTypingIndicators)
                    Text(
                        "These switches control what Vela sends. Incoming read receipts and typing indicators may still appear when the other person sends them."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    // Say this plainly rather than leaving it to be discovered:
                    // the asymmetry is in the backend, not a bug in Vela.
                    Text(
                        "Reading a conversation on your phone clears it here. The reverse does not yet work — reading here leaves your phone's badge in place."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Read receipt and typing privacy settings")

                Section("Notifications") {
                    LabeledContent("Permission") {
                        switch model.notificationAuthorization {
                        case .pending:
                            ProgressView().controlSize(.small)
                        case .granted:
                            Label("Allowed", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .denied:
                            Label("Turned off", systemImage: "bell.slash")
                                .foregroundStyle(.secondary)
                        case .unavailable:
                            Label("Unavailable", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    // Nothing in Vela can grant this, so say where it lives
                    // rather than leaving the app silently mute.
                    if case .unavailable(let reason) = model.notificationAuthorization {
                        Text("macOS refused the request: \(reason)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if model.notificationAuthorization != .granted {
                        Button("Open Notification Settings") {
                            NSWorkspace.shared.open(
                                URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
                            )
                        }
                    }

                    Label("Notifications use generic text and never include message contents.", systemImage: "eye.slash")
                    Text("Message previews remain intentionally disabled until the production notification path is security-reviewed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Notification privacy settings")

                Section("Indexing") {
                    Label("Message contents are not submitted to Spotlight.", systemImage: "checkmark.shield")
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Search indexing status")
            }
            .formStyle(.grouped)
        }
    }

    private struct StorageSettingsView: View {
        @EnvironmentObject private var model: AppModel

        var body: some View {
            Form {
                Section("Local database") {
                    if let stats = model.storageStatistics {
                        LabeledContent("Accounts", value: String(stats.accountCount))
                        LabeledContent("Conversations", value: String(stats.conversationCount))
                        LabeledContent("Messages", value: String(stats.messageCount))
                        LabeledContent("Pending sends", value: String(stats.pendingOutboxCount))
                        LabeledContent("Processed envelopes", value: String(stats.seenEnvelopeCount))
                    } else {
                        ProgressView()
                            .accessibilityLabel("Loading local database statistics")
                    }
                    Button("Refresh") { model.refreshDiagnostics() }
                        .accessibilityHint("Refreshes local counts and diagnostic events")
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Local database statistics")

                Section("Encryption") {
                    if model.isDevelopmentMode {
                        Label("Development database is plaintext by explicit build configuration.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } else {
                        Label(
                            "The Vela message database is encrypted with SQLCipher.",
                            systemImage: "lock.shield"
                        )
                        Text(
                            "A random key is stored in an owner-only file beside the database inside Vela's sandbox container. Copying only the database does not expose its contents; anyone who obtains both files can decrypt it. This statement covers the message database, not attachment files selected elsewhere on your Mac."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Local data encryption status")
            }
            .formStyle(.grouped)
        }
    }

    private struct DiagnosticsSettingsView: View {
        @EnvironmentObject private var model: AppModel
        let openDiagnostics: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                Text(
                    "Diagnostics contain categories and counts only. Message bodies, recipient identifiers, group names, attachment names, and decrypted envelopes are excluded."
                )
                .foregroundStyle(.secondary)
                Button("Open diagnostic viewer", action: openDiagnostics)
                    .accessibilityHint("Opens redacted operational events in this Settings window")
                LabeledContent("Events this run", value: String(model.diagnosticEvents.count))
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private struct AboutSettingsView: View {
        @EnvironmentObject private var model: AppModel
        @State private var legalDocument: LegalDocument?

        var body: some View {
            VStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                Text("Vela")
                    .font(.title.bold())
                Text("Native macOS linked-device client architecture")
                    .foregroundStyle(.secondary)
                Text("Version \(version)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("AGPL-3.0-only · Unofficial · Not affiliated with Signal Technology Foundation")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("View source") { model.openSourceRepository() }
                    Button("License") { legalDocument = .license }
                    Button("Notices") { legalDocument = .notices }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .sheet(item: $legalDocument) { document in
                LegalDocumentView(document: document)
            }
        }

        private var version: String {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        }
    }

    private enum LegalDocument: String, Identifiable {
        case license
        case notices

        var id: String { rawValue }

        var title: String {
            switch self {
            case .license: "GNU Affero General Public License v3"
            case .notices: "Open-source notices"
            }
        }

        var resourceName: String {
            switch self {
            case .license: "AGPL-3.0"
            case .notices: "NOTICE"
            }
        }
    }

    private struct LegalDocumentView: View {
        let document: LegalDocument
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            VStack(spacing: 0) {
                HStack {
                    Text(document.title)
                        .font(.headline)
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding()
                Divider()
                ScrollView {
                    Text(contents)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
            .frame(minWidth: 720, minHeight: 520)
        }

        private var contents: String {
            guard let url = Bundle.main.url(forResource: document.resourceName, withExtension: "txt") else {
                return "The bundled legal document could not be loaded."
            }
            return (try? String(contentsOf: url, encoding: .utf8)) ?? "The bundled legal document could not be read."
        }
    }
#endif
