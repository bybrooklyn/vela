#if os(macOS)
    import SwiftUI
    import VelaDomain

    struct RootView: View {
        @EnvironmentObject private var model: AppModel
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            Group {
                if model.isAppLocked {
                    LockView()
                } else {
                    VStack(spacing: 0) {
                        if model.isDevelopmentMode {
                            DevelopmentModeBanner()
                        }
                        content
                    }
                }
            }
            .background(SignalPalette.appBackground)
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: model.snapshot.state)
        }

        @ViewBuilder
        private var content: some View {
            switch model.snapshot.state {
            case .openingDatabase, .startingServices:
                ProgressView("Opening Vela…")
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .unlinked, .linking:
                OnboardingView()

            case .ready, .offline:
                MainSplitView()

            case .locked:
                LockView()

            case .relinkRequired:
                BlockingStateView(
                    title: "Relink required",
                    message: "The service no longer accepts this linked-device credential. Delete the local link and link the Mac again.",
                    buttonTitle: "Delete local link",
                    action: model.unlinkAndDelete
                )

            case .updateRequired(let minimumVersion):
                BlockingStateView(
                    title: "Update required",
                    message: "The service requires Vela \(minimumVersion) or later.",
                    buttonTitle: "View source",
                    action: model.openSourceRepository
                )

            case .recoveryRequired:
                BlockingStateView(
                    title: "Local data needs recovery",
                    message: model.startupFailure
                        ?? "Vela could not safely open its local database. The app stopped instead of guessing or overwriting data.",
                    buttonTitle: "Retry opening database",
                    action: model.retryStartup
                )

            case .deletingData:
                ProgressView("Deleting local data…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .importingHistory(let progress):
                VStack(spacing: 16) {
                    ProgressView(value: progress)
                        .frame(width: 320)
                    Text("Importing linked-device history")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private struct DevelopmentModeBanner: View {
        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: "hammer.fill")
                    .accessibilityHidden(true)
                Text("Local development mode — plaintext test envelopes, no connection to Signal services")
                    .font(.callout.weight(.medium))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.orange.opacity(0.18))
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Local development mode. This build is not connected to Signal services.")
        }
    }

    private struct BlockingStateView: View {
        let title: String
        let message: String
        let buttonTitle: String
        let action: () -> Void

        var body: some View {
            ContentUnavailableView {
                Label(title, systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
                    .frame(maxWidth: 520)
            } actions: {
                Button(buttonTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
#endif
