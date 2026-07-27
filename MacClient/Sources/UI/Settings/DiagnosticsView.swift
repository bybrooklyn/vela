#if os(macOS)
    import AppKit
    import SwiftUI
    import VelaDomain

    struct DiagnosticsView: View {
        @EnvironmentObject private var model: AppModel
        @Environment(\.dismiss) private var dismiss
        @State private var copyConfirmation: String?

        var body: some View {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Diagnostics")
                            .font(.title2.bold())
                        Text("Redacted operational events only")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        copyDiagnostics()
                    } label: {
                        Label(copyConfirmation ?? "Copy", systemImage: "doc.on.doc")
                    }
                    .disabled(model.diagnosticEvents.isEmpty)
                    .accessibilityLabel("Copy redacted diagnostics")
                    .accessibilityHint("Copies visible event time, subsystem, category, and detail as tab-separated text")
                    Button("Refresh") { model.refreshDiagnostics() }
                        .accessibilityHint("Reloads redacted events from this run")
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding()

                Divider()

                if let startupFailure = model.startupFailure {
                    ContentUnavailableView(
                        "Database unavailable",
                        systemImage: "externaldrive.badge.exclamationmark",
                        description: Text(startupFailure + " Retry opening the database from the recovery screen.")
                    )
                } else if model.diagnosticEvents.isEmpty {
                    ContentUnavailableView(
                        "No diagnostic events",
                        systemImage: "checkmark.circle",
                        description: Text("No operational events have been recorded in this run.")
                    )
                } else {
                    Table(model.diagnosticEvents) {
                        TableColumn("Time") { event in
                            Text(event.timestamp, format: .dateTime.hour().minute().second())
                                .font(.system(.caption, design: .monospaced))
                        }
                        .width(min: 80, ideal: 100)

                        TableColumn("Subsystem") { event in
                            Text(event.subsystem)
                        }
                        .width(min: 90, ideal: 120)

                        TableColumn("Category") { event in
                            Text(event.category)
                        }
                        .width(min: 120, ideal: 180)

                        TableColumn("Detail") { event in
                            Text(event.detail)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .onAppear { model.refreshDiagnostics() }
        }

        private func copyDiagnostics() {
            let header = "Time\tSubsystem\tCategory\tDetail"
            let rows = model.diagnosticEvents.map { event in
                [
                    event.timestamp.formatted(.iso8601),
                    event.subsystem,
                    event.category,
                    event.detail,
                ]
                .map(Self.singleLine)
                .joined(separator: "\t")
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(([header] + rows).joined(separator: "\n"), forType: .string)
            copyConfirmation = "Copied"
            Task {
                try? await Task.sleep(for: .seconds(2))
                copyConfirmation = nil
            }
        }

        private static func singleLine(_ value: String) -> String {
            value.replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
        }
    }
#endif
