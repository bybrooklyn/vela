#if os(macOS)
    import SwiftUI
    import VelaDomain

    struct OnboardingView: View {
        @EnvironmentObject private var model: AppModel
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
        @Environment(\.colorSchemeContrast) private var contrast
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize
        @FocusState private var deviceNameFocused: Bool
        @State private var linkFailureMessage: String?
        @State private var isCancelling = false
        @State private var isRestartPending = false

        var body: some View {
            GeometryReader { geometry in
                if usesCompactLayout(width: geometry.size.width) {
                    compactLayout
                } else {
                    wideLayout
                }
            }
            .background(SignalPalette.appBackground)
            .onAppear { deviceNameFocused = true }
            .onChange(of: model.snapshot.state) { oldState, newState in
                handleStateChange(from: oldState, to: newState)
            }
            .onChange(of: model.provisioningSession) { _, session in
                guard session == nil, isRestartPending else { return }
                isRestartPending = false
                beginProvisioning()
            }
        }

        private var wideLayout: some View {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: 24)
                    onboardingForm
                    Spacer(minLength: 24)
                }
                .padding(48)
                .frame(maxWidth: 580, alignment: .leading)

                Divider()
                    .accessibilityHidden(true)

                provisioningPanel(qrSize: Metrics.provisioningQRDiameter)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(SignalPalette.secondarySurface)
            }
        }

        private var compactLayout: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    onboardingForm

                    Divider()
                        .accessibilityHidden(true)

                    provisioningPanel(qrSize: Metrics.compactProvisioningQRDiameter)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .padding(.horizontal, 16)
                        .background(
                            SignalPalette.secondarySurface,
                            in: RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
                        )
                }
                .padding(24)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
        }

        private var onboardingForm: some View {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "message.badge.waveform.fill")
                    .font(.system(size: 48, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Link this Mac")
                        .font(.largeTitle.bold())
                    Text("Vela is a native linked-device client. Your phone remains the primary account device.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Device name")
                        .font(.headline)
                    TextField("Mac", text: $model.deviceName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                        .focused($deviceNameFocused)
                        .accessibilityLabel("Device name")
                        .submitLabel(.continue)
                        .onSubmit {
                            if model.provisioningSession == nil {
                                beginProvisioning()
                            }
                        }
                }

                if let linkFailureMessage {
                    Label(linkFailureMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Linking failed. \(linkFailureMessage)")

                    Button {
                        retryProvisioning()
                    } label: {
                        Label("Try linking again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                } else if model.provisioningSession == nil {
                    Button {
                        beginProvisioning()
                    } label: {
                        Label(
                            model.isDevelopmentMode ? "Begin local development link" : "Begin linked-device setup",
                            systemImage: "qrcode"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                } else if let session = model.provisioningSession {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        provisioningControls(session, at: context.date)
                    }
                }

                Text("Unofficial client. Not affiliated with or endorsed by Signal Technology Foundation.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        private func provisioningPanel(qrSize: CGFloat) -> some View {
            VStack(spacing: 18) {
                if let session = model.provisioningSession {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        provisioningCode(session, at: context.date, qrSize: qrSize)
                    }
                } else {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.system(size: min(qrSize * 0.4, 110), weight: .thin))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("A provisioning QR code will appear here.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }

        @ViewBuilder
        private func provisioningCode(
            _ session: ProvisioningSession,
            at date: Date,
            qrSize: CGFloat
        ) -> some View {
            if session.expiresAt <= date {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: min(qrSize * 0.35, 88), weight: .light))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Linking code expired")
                    .font(.headline)
                Text("Generate a new code to try linking again.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .accessibilityLabel("Linking code expired. Generate a new code to try again.")
            } else {
                QRCodeView(value: session.linkingURI.absoluteString)
                    .frame(width: qrSize, height: qrSize)
                    .padding(24)
                    .background(.white, in: RoundedRectangle(cornerRadius: Metrics.panelRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: Metrics.panelRadius)
                            .strokeBorder(
                                .black.opacity(contrast == .increased ? 0.55 : 0.16),
                                lineWidth: contrast == .increased ? 2 : 1
                            )
                    }
                    .shadow(
                        color: reduceTransparency || contrast == .increased
                            ? .clear : .black.opacity(0.16),
                        radius: 20,
                        y: 8
                    )

                Text(model.isDevelopmentMode ? "Development linking code" : "Scan from the primary phone")
                    .font(.headline)

                Label {
                    Text("Code expires \(session.expiresAt, style: .relative)")
                } icon: {
                    Image(systemName: "clock")
                        .accessibilityHidden(true)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)

                if let code = session.verificationCode {
                    VStack(spacing: 4) {
                        Text("Verification code")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(code)
                            .font(.system(.title2, design: .monospaced, weight: .semibold))
                            .textSelection(.enabled)
                            .accessibilityLabel("Verification code \(spokenCode(code))")
                            .accessibilityHint("Selectable text")
                    }
                }
            }
        }

        @ViewBuilder
        private func provisioningControls(_ session: ProvisioningSession, at date: Date) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                if session.expiresAt <= date {
                    Button {
                        restartProvisioning()
                    } label: {
                        Label("Generate a new linking code", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityHint("Cancels the expired setup and creates a new code")
                } else if model.isDevelopmentMode {
                    Button("Complete local link") {
                        model.completeDevelopmentProvisioning()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)

                    Text(
                        "This button simulates the phone approval step so the complete local message pipeline can be developed without live service credentials."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420, alignment: .leading)
                } else {
                    ProgressView("Waiting for the phone…")
                }

                Button("Cancel", role: .cancel) {
                    isCancelling = true
                    isRestartPending = false
                    linkFailureMessage = nil
                    model.cancelProvisioning()
                }
                .keyboardShortcut(.cancelAction)
            }
        }

        private func beginProvisioning() {
            linkFailureMessage = nil
            model.beginProvisioning()
        }

        private func restartProvisioning() {
            isCancelling = true
            isRestartPending = true
            linkFailureMessage = nil
            model.cancelProvisioning()
        }

        private func retryProvisioning() {
            if model.provisioningSession == nil {
                beginProvisioning()
            } else {
                restartProvisioning()
            }
        }

        private func handleStateChange(from oldState: ClientState, to newState: ClientState) {
            guard case .linking = oldState, newState == .unlinked else { return }
            if isCancelling {
                isCancelling = false
                return
            }
            linkFailureMessage =
                "Vela could not complete setup. Check the phone and connection, then try a new code."
            // AppModel owns displayed session. Cancelling clears stale session
            // after core reports failed provisioning.
            model.cancelProvisioning()
        }

        private func usesCompactLayout(width: CGFloat) -> Bool {
            width < 820 || dynamicTypeSize.isAccessibilitySize
        }

        private func spokenCode(_ code: String) -> String {
            code.map(String.init).joined(separator: " ")
        }
    }
#endif
