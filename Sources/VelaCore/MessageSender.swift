import Foundation
import VelaCrypto
import VelaDomain
import VelaStorage

public actor MessageSender {
    private let store: any ClientStore
    private let router: any RecipientRouter
    private let codec: WireCodec
    private let clock: any VelaClock
    private let events: ClientEventHub

    public init(
        store: any ClientStore,
        router: any RecipientRouter,
        codec: WireCodec = WireCodec(),
        clock: any VelaClock = SystemVelaClock(),
        events: ClientEventHub
    ) {
        self.store = store
        self.router = router
        self.codec = codec
        self.clock = clock
        self.events = events
    }

    @discardableResult
    public func enqueue(
        draft: MessageDraft,
        conversation: ConversationSeed,
        account: LinkedAccount,
        disappearingDuration: TimeInterval? = nil
    ) async throws -> MessageID {
        guard !draft.isEmpty else { throw VelaError.emptyMessage }

        let now = clock.now
        let messageID = MessageID.random()
        let styles = draft.textStyles.normalized(forUTF16Length: (draft.text as NSString).length)
        let content: MessageContent =
            styles.isEmpty ? .text(draft.text) : .styledText(draft.text, styles)
        let expiresAt = disappearingDuration.map { now.addingTimeInterval($0) }
        let destination = try await router.destination(for: conversation)

        let message = ChatMessage(
            id: messageID,
            conversationID: conversation.id,
            senderID: account.localRecipientID,
            direction: .outgoing,
            content: content,
            sentAt: now,
            deliveryState: .queued,
            replyToMessageID: draft.replyToMessageID,
            expiresAt: expiresAt,
            attachments: draft.attachments
        )

        let wire = WireMessage(
            id: messageID,
            conversation: conversation,
            senderID: account.localRecipientID,
            recipientID: destination.recipientID,
            kind: .text,
            body: draft.text,
            sentAt: now,
            replyToMessageID: draft.replyToMessageID,
            expiresAt: expiresAt,
            attachments: draft.attachments,
            textStyles: styles
        )

        let payload = try codec.encode(wire)
        let item = OutboxItem(
            messageID: messageID,
            destination: destination,
            plaintextPayload: payload,
            createdAt: now,
            nextAttemptAt: now
        )

        try await store.persistOutgoing(
            message: message,
            conversationSeed: conversation,
            outboxItem: item
        )
        await publishChanges(conversationID: conversation.id)
        return messageID
    }

    @discardableResult
    public func enqueueEdit(
        messageID: MessageID,
        newText: String,
        textStyles: [TextStyleRange] = [],
        account: LinkedAccount
    ) async throws -> MessageID {
        let normalized = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw VelaError.emptyMessage }

        var (target, conversation) = try await mutationContext(messageID: messageID)
        let rollbackTarget = target
        guard target.direction == .outgoing else { throw VelaError.messageNotEditable }
        switch target.content {
        case .text, .styledText:
            break
        default:
            throw VelaError.messageNotEditable
        }

        let styles = textStyles.normalized(forUTF16Length: (newText as NSString).length)
        target.content = styles.isEmpty ? .text(newText) : .styledText(newText, styles)
        target.revision += 1
        return try await enqueueMutation(
            kind: .edit,
            body: newText,
            textStyles: styles,
            target: target,
            rollbackTarget: rollbackTarget,
            conversation: conversation,
            account: account
        )
    }

    @discardableResult
    public func enqueueDelete(
        messageID: MessageID,
        account: LinkedAccount
    ) async throws -> MessageID {
        var (target, conversation) = try await mutationContext(messageID: messageID)
        let rollbackTarget = target
        guard target.direction == .outgoing else { throw VelaError.messageNotEditable }
        guard case .deleted = target.content else {
            target.content = .deleted(deletedBy: account.localRecipientID)
            target.reactions.removeAll()
            target.revision += 1
            return try await enqueueMutation(
                kind: .delete,
                body: nil,
                target: target,
                rollbackTarget: rollbackTarget,
                conversation: conversation,
                account: account
            )
        }
        throw VelaError.messageNotEditable
    }

    @discardableResult
    public func enqueueReaction(
        messageID: MessageID,
        emoji: String,
        account: LinkedAccount
    ) async throws -> MessageID {
        let normalized = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 16 else {
            throw VelaError.invalidReaction
        }

        var (target, conversation) = try await mutationContext(messageID: messageID)
        let rollbackTarget = target
        guard case .deleted = target.content else {
            let controlID = MessageID.random()
            target.reactions.removeAll { $0.authorID == account.localRecipientID }
            target.reactions.append(
                MessageReaction(
                    id: ReactionID(controlID.rawValue),
                    authorID: account.localRecipientID,
                    emoji: normalized,
                    createdAt: clock.now
                )
            )
            return try await enqueueMutation(
                controlID: controlID,
                kind: .reaction,
                body: normalized,
                target: target,
                rollbackTarget: rollbackTarget,
                conversation: conversation,
                account: account
            )
        }
        throw VelaError.messageNotEditable
    }

    /// Removes this account's current reaction while retaining its emoji in the
    /// wire control. Signal requires the original emoji alongside `remove=true`.
    @discardableResult
    public func enqueueRemoveReaction(
        messageID: MessageID,
        account: LinkedAccount
    ) async throws -> MessageID {
        var (target, conversation) = try await mutationContext(messageID: messageID)
        let rollbackTarget = target
        guard case .deleted = target.content else {
            guard let reaction = target.reactions.first(where: { $0.authorID == account.localRecipientID }) else {
                throw VelaError.invalidReaction
            }

            target.reactions.removeAll { $0.authorID == account.localRecipientID }
            return try await enqueueMutation(
                kind: .reaction,
                body: reaction.emoji,
                isReactionRemoval: true,
                target: target,
                rollbackTarget: rollbackTarget,
                conversation: conversation,
                account: account
            )
        }
        throw VelaError.messageNotEditable
    }

    private func mutationContext(messageID: MessageID) async throws -> (ChatMessage, ConversationSeed) {
        guard let target = try await store.loadMessage(id: messageID) else {
            throw VelaError.messageMissing
        }
        guard let conversation = try await store.loadConversation(id: target.conversationID) else {
            throw VelaError.conversationMissing
        }
        return (
            target,
            ConversationSeed(id: conversation.id, kind: conversation.kind, title: conversation.title)
        )
    }

    private func enqueueMutation(
        controlID: MessageID = .random(),
        kind: WireMessageKind,
        body: String?,
        isReactionRemoval: Bool? = nil,
        textStyles: [TextStyleRange] = [],
        target: ChatMessage,
        rollbackTarget: ChatMessage,
        conversation: ConversationSeed,
        account: LinkedAccount
    ) async throws -> MessageID {
        let now = clock.now
        let destination = try await router.destination(for: conversation)
        let wire = WireMessage(
            id: controlID,
            conversation: conversation,
            senderID: account.localRecipientID,
            recipientID: destination.recipientID,
            kind: kind,
            body: body,
            sentAt: now,
            targetMessageID: target.id,
            isReactionRemoval: isReactionRemoval,
            revision: target.revision,
            textStyles: textStyles
        )
        let item = OutboxItem(
            messageID: controlID,
            destination: destination,
            plaintextPayload: try codec.encode(wire),
            createdAt: now,
            nextAttemptAt: now,
            mutationTargetID: target.id,
            rollbackTarget: rollbackTarget
        )
        try await store.persistOutgoingMutation(targetMessage: target, outboxItem: item)
        await publishChanges(conversationID: conversation.id)
        return controlID
    }

    private func publishChanges(conversationID: ConversationID) async {
        await events.publish(.conversationsChanged)
        await events.publish(.messagesChanged(conversationID))
    }
}
