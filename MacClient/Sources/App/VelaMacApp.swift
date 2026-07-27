#if os(macOS)
    import AppKit
    import SwiftUI

    @main
    struct VelaMacApp: App {
        @NSApplicationDelegateAdaptor(VelaAppDelegate.self) private var appDelegate
        @StateObject private var model = AppModel()
        @State private var isSettingsActive = false

        var body: some Scene {
            WindowGroup(id: "main") {
                RootView()
                    .environmentObject(model)
                    // Signal is ultramarine on every platform; without this the
                    // whole UI follows the user's system accent colour.
                    .tint(SignalPalette.ultramarine)
                    .frame(minWidth: 880, minHeight: 600)
                    .task { model.start() }
                    .onChange(of: model.snapshot.unreadCount) { _, count in
                        NSApplication.shared.dockTile.badgeLabel = count > 0 ? String(count) : nil
                    }
                    .sheet(isPresented: $model.isShowingDiagnostics) {
                        DiagnosticsView()
                            .environmentObject(model)
                            .tint(SignalPalette.ultramarine)
                            .frame(minWidth: 700, idealWidth: 820, minHeight: 480, idealHeight: 560)
                    }
                    .alert(
                        model.alertTitle,
                        isPresented: Binding(
                            get: { !isSettingsActive && model.alertMessage != nil },
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
            .defaultSize(width: 1180, height: 760)
            .windowResizability(.contentMinSize)
            .commands {
                VelaCommands(model: model)
            }

            Settings {
                SettingsView(isActive: $isSettingsActive)
                    .environmentObject(model)
                    .tint(SignalPalette.ultramarine)
                    .frame(minWidth: 620, idealWidth: 700, minHeight: 520, idealHeight: 600)
            }
            .defaultSize(width: 700, height: 600)
            .windowResizability(.contentMinSize)
        }
    }

    final class VelaAppDelegate: NSObject, NSApplicationDelegate {
        /// Set by `AppModel` so the backend can be shut down on quit.
        @MainActor static weak var container: AppContainer?

        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
            false
        }

        /// The backend is a child process, but it does not die with its parent.
        /// Without this it survives quit, holding the account and the socket.
        func applicationWillTerminate(_ notification: Notification) {
            MainActor.assumeIsolated {
                Self.container?.daemon?.stop()
            }
        }

        func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
            if !flag {
                sender.windows.first?.makeKeyAndOrderFront(nil)
            }
            return true
        }
    }

    struct VelaCommands: Commands {
        @ObservedObject var model: AppModel

        var body: some Commands {
            CommandGroup(after: .newItem) {
                Button("New Conversation…") {
                    model.isShowingNewConversation = true
                }
                .keyboardShortcut("n", modifiers: [.command])
                .disabled(model.snapshot.linkedAccount == nil || model.isAppLocked)
            }

            CommandMenu("Conversation") {
                Button("Simulate Incoming Reply") {
                    model.simulateIncomingReply()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!model.isDevelopmentMode || model.selectedConversationID == nil)

                Divider()

                Button("Lock Vela") {
                    model.lock()
                }
                .keyboardShortcut("l", modifiers: [.command, .control])
                .disabled(model.snapshot.linkedAccount == nil || model.isAppLocked)
            }

            CommandGroup(replacing: .help) {
                Button("Vela Source Code") {
                    model.openSourceRepository()
                }
            }
        }
    }
#endif
