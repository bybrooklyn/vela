#if os(macOS)
    import Foundation

    /// Geometry shared across the interface: corner radii, spacing and control
    /// sizes.
    ///
    /// These lived as literals at each call site, which is how the same
    /// conceptual element ended up with three different radii. `GlassStyle` keeps
    /// the glass helpers and motion; geometry belongs here so there is one place
    /// to change it and one place to read it from.
    ///
    /// Values marked *Signal* are taken from Signal-iOS rather than chosen, so
    /// that "looks like Signal" is verifiable instead of approximate. The source
    /// file is named beside each one.
    enum Metrics {
        // MARK: - Corner radii

        /// Message bubble. *Signal:* `CVComponentMessage.bubbleWideCornerRadius`.
        static let bubbleRadius: CGFloat = 18
        /// The tucked corner where bubbles in a run meet.
        /// *Signal:* `CVComponentMessage.bubbleSharpCornerRadius`.
        static let bubbleTightRadius: CGFloat = 4

        /// Composer text box. Half of `composerBoxHeight`, so an empty composer
        /// is a true pill, and fixed rather than recomputed so growing it does
        /// not turn it into a stadium.
        /// *Signal:* `ConversationInputToolbar.LayoutMetrics.initialTextBoxHeight / 2`.
        static let composerRadius: CGFloat = composerBoxHeight / 2

        /// Buttons, popovers and other chrome.
        static let controlRadius: CGFloat = 12
        /// Small inline chips: attachments, connection state, date separators.
        static let chipRadius: CGFloat = 8
        /// Image attachment thumbnails in the timeline.
        static let thumbnailRadius: CGFloat = 10
        /// The small thumbnail in the reply/edit strip above the composer.
        static let quoteThumbnailRadius: CGFloat = 5
        /// The vertical rule marking a quoted message.
        static let quoteBarRadius: CGFloat = 2
        /// The QR panel during linking. Deliberately larger than a control: it is
        /// a full white card, not a button.
        static let panelRadius: CGFloat = 22

        // MARK: - Message spacing

        /// Between messages tucked into the same run.
        /// *Signal:* `ConversationStyle.compactMessageSpacing`.
        static let stackedMessageSpacing: CGFloat = 2
        /// Between messages from different senders, or across a run break.
        /// *Signal:* `ConversationStyle.defaultMessageSpacing`.
        static let separatedMessageSpacing: CGFloat = 12
        /// Around date separators and other non-message rows, which should read
        /// as a stronger division than a change of speaker.
        /// *Signal:* `ConversationStyle.systemMessageSpacing`.
        static let systemMessageSpacing: CGFloat = 20

        // MARK: - Control sizes

        /// One-line height of the composer text box, including its padding.
        /// *Signal:* `ConversationInputToolbar.LayoutMetrics.initialTextBoxHeight`.
        static let composerBoxHeight: CGFloat = 40
        /// Jump-to-latest button.
        /// *Signal:* `ConversationScrollButton.circleDiameter`.
        static let scrollButtonDiameter: CGFloat = 40
        /// How far the unread badge rides up over the scroll button's edge.
        /// *Signal:* `ConversationScrollButton.pillViewOverlap`.
        static let scrollButtonBadgeOverlap: CGFloat = 8
        /// Send and attach buttons in the composer bar.
        static let composerButtonDiameter: CGFloat = 30
        /// Minimum keyboard/pointer target even when visible artwork is smaller.
        static let minimumInteractiveDiameter: CGFloat = 44

        /// Contact avatar used in compact rows and pickers.
        static let compactAvatarDiameter: CGFloat = 32
        /// Contact avatar used in a conversation header.
        static let headerAvatarDiameter: CGFloat = 40

        /// QR artwork in a wide onboarding window.
        static let provisioningQRDiameter: CGFloat = 280
        /// QR artwork in the compact, vertically scrolling onboarding layout.
        static let compactProvisioningQRDiameter: CGFloat = 220

        // Clustering is a rule about messages rather than geometry, so the run
        // window lives in `VelaDomain.MessageClustering` where it is tested.
    }
#endif
