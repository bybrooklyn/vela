import Foundation
import VelaCrypto
import VelaDomain
import VelaStorage
import VelaTransport

public actor MessageReceiver {
    private let store: any ClientStore
    private let crypto: any CryptoEngine
    private let transport: any ServiceTransport
    private let codec: WireCodec
    private let clock: any VelaClock
    private let events: ClientEventHub
    private let diagnostics: DiagnosticsRecorder
    private let notifications: any IncomingMessageNotificationSink
    private var receiveTask: Task<Void, Never>?
    private var account: LinkedAccount?

    public init(
        store: any ClientStore,
        crypto: any CryptoEngine,
        transport: any ServiceTransport,
        codec: WireCodec = WireCodec(),
        clock: any VelaClock = SystemVelaClock(),
        events: ClientEventHub,
        diagnostics: DiagnosticsRecorder,
        notifications: any IncomingMessageNotificationSink = NullIncomingMessageNotificationSink()
    ) {
        self.store = store
        self.crypto = crypto
        self.transport = transport
        self.codec = codec
        self.clock = clock
        self.events = events
        self.diagnostics = diagnostics
        self.notifications = notifications
    }

    public func start(account: LinkedAccount) {
        self.account = account
        guard receiveTask == nil else { return }
        receiveTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() {
        receiveTask?.cancel()
        receiveTask = nil
        account = nil
    }

    @discardableResult
    public func process(_ envelope: EncryptedEnvelope) async -> Bool {
        guard let account else { return false }
        let localAddress = DeviceAddress(
            recipientID: account.localRecipientID,
            deviceID: account.deviceID
        )

        do {
            let plaintext = try await crypto.open(envelope, localAddress: localAddress)
            let wire = try codec.decode(plaintext)
            try validate(wire: wire, envelope: envelope, account: account)

            switch wire.kind {
            case .text, .unsupported:
                return try await persistDisplayMessage(wire: wire, envelope: envelope, account: account)
            case .edit, .delete, .reaction:
                return try await persistMutation(wire: wire, envelope: envelope)
            case .receipt:
                return try await applyReceipt(wire: wire, envelope: envelope)
            case .expirationUpdate:
                return try await applyExpirationUpdate(wire: wire, envelope: envelope)
            case .readSync:
                return try await applyReadSync(wire: wire, envelope: envelope)
            case .typing:
                // Ephemeral: published for the UI, never persisted.
                await events.publish(
                    .typingChanged(
                        conversationID: wire.conversation.id,
                        senderID: wire.senderID,
                        isTyping: ControlPayload.detail(of: wire) == "started"
                    )
                )
                return try await store.recordSeenEnvelope(envelope.id, at: clock.now)
            }
        } catch {
            await diagnostics.record(
                subsystem: "receiver",
                category: "envelope-rejected",
                detail: DiagnosticsRecorder.errorCategory(error),
                at: clock.now
            )
            await events.publish(.diagnosticsChanged)
            return false
        }
    }

    private func persistDisplayMessage(
        wire: WireMessage,
        envelope: EncryptedEnvelope,
        account: LinkedAccount
    ) async throws -> Bool {
        let content: MessageContent
        switch wire.kind {
        case .text:
            let body = wire.body ?? ""
            let styles = wire.textStyles.normalized(forUTF16Length: (body as NSString).length)
            content = styles.isEmpty ? .text(body) : .styledText(body, styles)
        case .unsupported:
            content = .unsupported(
                requiredVersion: wire.version,
                description: wire.body ?? "Unsupported wire message"
            )
        default:
            throw VelaError.invalidEnvelope("display-kind-mismatch")
        }

        // A message whose sender is this account is one we sent from another
        // device and Signal synced back. Treating it as incoming is what made
        // your own replies appear to come from the other person.
        let isOwnMessage = wire.senderID == account.localRecipientID

        let receivedAt = clock.now
        let expiresAt: Date?
        if let explicitDeadline = wire.expiresAt {
            expiresAt = explicitDeadline
        } else if let duration = wire.expiresIn, duration > 0, duration.isFinite {
            // Signal sends a duration, not a deadline. An incoming message may
            // spend a long time queued before this linked device receives it,
            // so its local lifetime begins when it arrives. Our own synced
            // message began counting when it was sent.
            expiresAt = (isOwnMessage ? wire.sentAt : receivedAt).addingTimeInterval(duration)
        } else {
            expiresAt = nil
        }

        let message = ChatMessage(
            id: wire.id,
            conversationID: wire.conversation.id,
            senderID: wire.senderID,
            direction: isOwnMessage ? .outgoing : .incoming,
            content: content,
            sentAt: wire.sentAt,
            receivedAt: receivedAt,
            deliveryState: isOwnMessage
                ? .sent(serverTimestamp: envelope.serverTimestamp)
                : .delivered(at: envelope.serverTimestamp),
            replyToMessageID: wire.replyToMessageID,
            revision: wire.revision,
            expiresAt: expiresAt,
            attachments: wire.attachments
        )

        let inserted = try await store.persistIncoming(
            message: message,
            conversationSeed: wire.conversation,
            envelopeID: envelope.id,
            // Your own message must not mark the thread unread.
            incrementUnread: !isOwnMessage
        )
        guard inserted else { return false }

        await publishChanges(conversationID: wire.conversation.id)
        guard !isOwnMessage else { return true }
        await notifications.notifyIncoming(
            messageID: message.id,
            conversationID: message.conversationID
        )
        return true
    }

    /// Advances the delivery state of the messages a receipt names.
    ///
    /// Receipts arrive out of order and repeatedly, so state is only ever moved
    /// forward: a late `delivered` must not undo a `read`.
    private func applyReceipt(wire: WireMessage, envelope: EncryptedEnvelope) async throws -> Bool {
        let payload = ControlPayload(wire: wire)
        var touched: Set<ConversationID> = []

        for messageID in payload.targets {
            guard var message = try await store.loadMessage(id: messageID) else { continue }
            guard message.direction == .outgoing else { continue }

            let next: MessageDeliveryState =
                switch payload.detail {
                case "read", "viewed": .read(at: wire.sentAt)
                default: .delivered(at: wire.sentAt)
                }
            guard next.receiptRank > message.deliveryState.receiptRank else { continue }

            message.deliveryState = next
            _ = try await store.persistIncomingMutation(
                targetMessage: message,
                envelopeID: EnvelopeID("\(envelope.id.rawValue):\(messageID.rawValue)"),
                receivedAt: clock.now
            )
            touched.insert(message.conversationID)
        }

        for conversationID in touched {
            await events.publish(.messagesChanged(conversationID))
        }
        return try await store.recordSeenEnvelope(envelope.id, at: clock.now)
    }

    /// Clears unread state for conversations we read on another device.
    ///
    /// A read entry names whoever *sent* the message that was read, not the
    /// thread, so each target is looked up to find its conversation. Using the
    /// sender directly would route every group read into a direct conversation
    /// with whoever happened to speak.
    private func applyReadSync(wire: WireMessage, envelope: EncryptedEnvelope) async throws -> Bool {
        let payload = ControlPayload(wire: wire)
        var touched: Set<ConversationID> = []

        for messageID in payload.targets {
            guard let message = try await store.loadMessage(id: messageID) else { continue }
            touched.insert(message.conversationID)
        }

        for conversationID in touched {
            try await store.markConversationRead(conversationID, at: clock.now)
        }
        if !touched.isEmpty {
            await events.publish(.conversationsChanged)
        }
        return try await store.recordSeenEnvelope(envelope.id, at: clock.now)
    }

    /// Applies Signal's conversation timer update without creating a fake
    /// timeline row. Zero disables disappearing messages.
    private func applyExpirationUpdate(
        wire: WireMessage,
        envelope: EncryptedEnvelope
    ) async throws -> Bool {
        guard let duration = wire.expiresIn, duration >= 0, duration.isFinite else {
            throw VelaError.invalidEnvelope("expiration-duration-invalid")
        }

        try await store.upsertConversations([wire.conversation], at: wire.sentAt)
        try await store.setConversationDisappearingDuration(
            duration > 0 ? duration : nil,
            for: wire.conversation.id
        )
        let inserted = try await store.recordSeenEnvelope(envelope.id, at: clock.now)
        guard inserted else { return false }
        await events.publish(.conversationsChanged)
        return true
    }

    private func persistMutation(
        wire: WireMessage,
        envelope: EncryptedEnvelope
    ) async throws -> Bool {
        guard let targetID = wire.targetMessageID else {
            throw VelaError.invalidEnvelope("mutation-target-missing")
        }
        guard var target = try await store.loadMessage(id: targetID) else {
            throw VelaError.messageMissing
        }
        guard target.conversationID == wire.conversation.id else {
            throw VelaError.invalidEnvelope("mutation-conversation-mismatch")
        }

        switch wire.kind {
        case .edit:
            guard target.senderID == wire.senderID else {
                throw VelaError.invalidEnvelope("edit-author-mismatch")
            }
            guard wire.revision > target.revision else {
                return try await store.recordSeenEnvelope(envelope.id, at: clock.now)
            }
            guard let body = wire.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw VelaError.invalidEnvelope("edit-body-empty")
            }
            switch target.content {
            case .text, .styledText:
                break
            default:
                throw VelaError.invalidEnvelope("edit-target-not-text")
            }
            let styles = wire.textStyles.normalized(forUTF16Length: (body as NSString).length)
            target.content = styles.isEmpty ? .text(body) : .styledText(body, styles)
            target.revision = wire.revision

        case .delete:
            guard target.senderID == wire.senderID else {
                throw VelaError.invalidEnvelope("delete-author-mismatch")
            }
            guard wire.revision > target.revision else {
                return try await store.recordSeenEnvelope(envelope.id, at: clock.now)
            }
            target.content = .deleted(deletedBy: wire.senderID)
            target.reactions.removeAll()
            target.revision = wire.revision

        case .reaction:
            // An empty body is a removal rather than a malformed reaction: one
            // author holds at most one reaction, so removing is just the clear
            // below without the append that follows it.
            let emoji = (wire.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard emoji.count <= 16 else {
                throw VelaError.invalidEnvelope("reaction-invalid")
            }
            guard case .deleted = target.content else {
                target.reactions.removeAll { $0.authorID == wire.senderID }
                if wire.isReactionRemoval != true, !emoji.isEmpty {
                    target.reactions.append(
                        MessageReaction(
                            id: ReactionID(wire.id.rawValue),
                            authorID: wire.senderID,
                            emoji: emoji,
                            createdAt: wire.sentAt
                        )
                    )
                }
                break
            }
            throw VelaError.invalidEnvelope("reaction-target-deleted")

        default:
            throw VelaError.invalidEnvelope("mutation-kind-mismatch")
        }

        let inserted = try await store.persistIncomingMutation(
            targetMessage: target,
            envelopeID: envelope.id,
            receivedAt: clock.now
        )
        guard inserted else { return false }
        await publishChanges(conversationID: target.conversationID)
        return true
    }

    private func publishChanges(conversationID: ConversationID) async {
        await events.publish(.conversationsChanged)
        await events.publish(.messagesChanged(conversationID))
    }

    private func runLoop() async {
        let stream = await transport.incomingEnvelopes()
        for await envelope in stream {
            guard !Task.isCancelled else { break }
            _ = await process(envelope)
        }
    }

    private func validate(
        wire: WireMessage,
        envelope: EncryptedEnvelope,
        account: LinkedAccount
    ) throws {
        guard wire.version <= 1 else {
            throw VelaError.unsupportedMessageVersion(wire.version)
        }
        guard wire.senderID == envelope.source.recipientID else {
            throw VelaError.invalidEnvelope("sender-mismatch")
        }
        // The local account must be one end of the conversation. It is the
        // recipient for an ordinary incoming message, and the sender for one we
        // sent from another device that Signal synced back to us.
        guard
            wire.recipientID == account.localRecipientID
                || wire.senderID == account.localRecipientID
        else {
            throw VelaError.invalidEnvelope("recipient-mismatch")
        }
        guard !wire.id.rawValue.isEmpty, !wire.conversation.id.rawValue.isEmpty else {
            throw VelaError.invalidEnvelope("missing-identifiers")
        }
    }
}
