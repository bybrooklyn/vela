#if os(macOS)
    import SwiftUI

    struct LockView: View {
        @EnvironmentObject private var model: AppModel

        var body: some View {
            LockContent(lock: model.localAppLock) {
                model.isAppLocked = false
            }
        }
    }

    private struct LockContent: View {
        @ObservedObject var lock: LocalAppLock
        let onUnlock: () -> Void
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
        @Environment(\.colorSchemeContrast) private var contrast
        @FocusState private var unlockFocused: Bool

        var body: some View {
            VStack(spacing: 20) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Vela is locked")
                    .font(.largeTitle.bold())
                Text(lockDescription)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)

                if let error = lock.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .accessibilityLabel("Unlock failed. \(error)")
                }

                if lock.isAvailable {
                    Button {
                        Task {
                            if await lock.authenticate() {
                                onUnlock()
                            }
                        }
                    } label: {
                        if lock.isAuthenticating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Unlock", systemImage: "touchid")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(lock.isAuthenticating)
                    .keyboardShortcut(.defaultAction)
                    .focused($unlockFocused)
                    .accessibilityLabel(
                        lock.isAuthenticating ? "Authenticating" : "Unlock Vela"
                    )
                } else {
                    Button("Return to Vela") {
                        // No available authentication means lock offers no
                        // protection. Never trap user behind an unusable policy.
                        lock.clearError()
                        onUnlock()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .focused($unlockFocused)
                    .accessibilityHint(
                        "Returns without authentication because system authentication is unavailable"
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                reduceTransparency || contrast == .increased
                    ? SignalPalette.opaqueSurface : SignalPalette.appBackground.opacity(0.82)
            )
            .overlay {
                if contrast == .increased {
                    Rectangle().strokeBorder(SignalPalette.strongBorder, lineWidth: 1)
                }
            }
            .onAppear {
                lock.clearError()
                unlockFocused = true
            }
        }

        private var lockDescription: String {
            lock.unavailableMessage
                ?? "Authenticate with Touch ID or your Mac login password."
        }
    }
#endif
