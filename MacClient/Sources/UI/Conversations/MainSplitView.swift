#if os(macOS)
    import SwiftUI

    struct MainSplitView: View {
        @EnvironmentObject private var model: AppModel

        var body: some View {
            NavigationSplitView {
                ConversationSidebarView()
                    .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 380)
            } detail: {
                if let conversation = model.selectedConversation {
                    ConversationDetailView(conversation: conversation)
                } else {
                    ContentUnavailableView(
                        "No conversation selected",
                        systemImage: "message",
                        description: Text("Choose a conversation or start a new one.")
                    )
                }
            }
            .navigationSplitViewStyle(.balanced)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    ConnectionStatusView()

                    Button {
                        model.isShowingNewConversation = true
                    } label: {
                        Label("New Conversation", systemImage: "square.and.pencil")
                    }

                    Button {
                        model.lock()
                    } label: {
                        Label("Lock", systemImage: "lock")
                    }
                }
            }
            .sheet(isPresented: $model.isShowingNewConversation) {
                NewConversationSheet()
                    .environmentObject(model)
            }
        }
    }

    private struct ConnectionStatusView: View {
        @EnvironmentObject private var model: AppModel
        @State private var isShowingDetails = false

        var body: some View {
            // Working is the normal case and needs no badge; a permanent
            // "Connected" pill is chrome that only ever states the obvious.
            // Only trouble is worth the user's attention.
            if let statusText {
                Button {
                    isShowingDetails.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .frame(width: 7, height: 7)
                            .foregroundStyle(statusColor)
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(SignalPalette.chipFill, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Show connection details")
                .accessibilityLabel("Connection status: \(statusText)")
                .transition(.opacity)
                .popover(isPresented: $isShowingDetails, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(statusText, systemImage: statusSymbol)
                            .font(.headline)
                        Text(statusDetail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.canRetryConnection {
                            Button {
                                model.retryConnection()
                            } label: {
                                if model.isRetryingConnection {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Label("Retry Now", systemImage: "arrow.clockwise")
                                }
                            }
                            .disabled(model.isRetryingConnection)
                            .accessibilityLabel("Retry Signal connection")
                        }
                    }
                    .padding()
                    .frame(width: 280)
                }
            }
        }

        private var statusText: String? {
            switch model.snapshot.connection {
            case .connected: nil
            case .connecting: "Connecting"
            case .backingOff: "Retrying"
            case .disconnected: "Offline"
            case .failed: "Connection failed"
            }
        }

        private var statusColor: Color {
            switch model.snapshot.connection {
            case .connected, .connecting, .backingOff: .orange
            case .disconnected, .failed: .red
            }
        }

        private var statusSymbol: String {
            switch model.snapshot.connection {
            case .connecting, .backingOff: "arrow.clockwise.circle"
            case .disconnected: "wifi.slash"
            case .failed: "exclamationmark.triangle"
            case .connected: "checkmark.circle"
            }
        }

        private var statusDetail: String {
            switch model.snapshot.connection {
            case .connected:
                "Vela is connected to Signal."
            case .connecting:
                "Vela is establishing a connection to Signal."
            case .backingOff(let attempt, let retryAt):
                "Attempt \(attempt) failed. Automatic retry scheduled for \(retryAt.formatted(date: .omitted, time: .shortened))."
            case .disconnected:
                "Vela is not connected. Messages remain queued until connection returns."
            case .failed(let category):
                "Connection failed (\(category)). Open Diagnostics for redacted operational details."
            }
        }
    }
#endif
