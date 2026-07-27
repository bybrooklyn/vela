#if os(macOS)
    import AppKit
    import SwiftUI
    import VelaDomain

    /// A contact's avatar, falling back to initials on a colour derived from the
    /// recipient identifier so the same person keeps the same colour everywhere.
    struct ContactAvatarView: View {
        let contact: Contact?
        let fallbackText: String
        var size: CGFloat = Metrics.compactAvatarDiameter

        @EnvironmentObject private var model: AppModel
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            ZStack {
                Circle().fill(background)
                if let image = avatarImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(Circle())
                } else {
                    Text(initials)
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
            .overlay {
                Circle().strokeBorder(
                    contrast == .increased ? SignalPalette.strongBorder : SignalPalette.subtleBorder,
                    lineWidth: contrast == .increased ? 2 : 1
                )
            }
            // Every use is adjacent to the same visible contact name. Reading
            // both produced a duplicate VoiceOver announcement.
            .accessibilityHidden(true)
        }

        private var initials: String {
            if let contact { return contact.initials }
            let words = fallbackText.split(separator: " ").prefix(2).compactMap(\.first)
            return words.isEmpty ? "?" : String(words).uppercased()
        }

        private var avatarImage: NSImage? {
            guard
                let relativePath = contact?.avatarRelativePath,
                let directory = model.container?.avatarDirectory
            else { return nil }
            return NSImage(contentsOf: directory.appendingPathComponent(relativePath))
        }

        /// Stable hue per identifier. Not security-relevant — only needs to be
        /// deterministic and spread out.
        private var background: Color {
            let key = contact?.recipientID.rawValue ?? fallbackText
            return SignalPalette.avatarBackground(for: key)
        }
    }
#endif
