import Foundation
import VelaDomain

/// Turns a signal-cli `receive` notification into Vela's `WireMessage`.
///
/// Only the fields Vela models are read, and unknown shapes are dropped rather
/// than guessed at, so an upstream addition cannot corrupt stored history.
public enum SignalCLIEnvelopeTranslator {
    public struct Translated {
        public var wire: WireMessage
        public var envelopeID: EnvelopeID
        public var signalTimestamp: Int64
    }

    public static func translate(
        _ params: JSONValue,
        account: LinkedAccount,
        directory: RecipientDirectory = RecipientDirectory()
    ) -> Translated? {
        // `subscribeReceive` wraps notifications in `params.result`, while
        // automatic receive mode puts `envelope` directly under `params`.
        // Accept both shapes so linked-device syncs from the phone are not
        // silently discarded.
        guard let envelope = params["result"]?["envelope"] ?? params["envelope"] else { return nil }

        // Resolve through the directory so a sender reported by UUID and the
        // same person reported by number land in one conversation.
        let senderID =
            directory.canonical(
                aci: envelope["sourceUuid"]?.stringValue,
                number: envelope["sourceNumber"]?.stringValue,
                username: envelope["sourceName"]?.stringValue
            ) ?? envelope["source"]?.stringValue.map { directory.canonical(for: $0) }
        guard let senderID, !senderID.rawValue.isEmpty else { return nil }

        // Our own account reporting, from another device, that it has read
        // messages. Each entry names whoever *sent* the message that was read,
        // not the thread it lives in, so the conversation is resolved later by
        // looking the message up rather than trusted from here.
        if let read = envelope["syncMessage"]?["readMessages"]?.arrayValue, !read.isEmpty {
            return control(
                kind: .readSync,
                envelope: envelope,
                senderID: account.localRecipientID,
                account: account,
                timestamps: read.compactMap { $0["timestamp"]?.intValue },
                detail: "read"
            )
        }

        // A sync message is our own account acting on another device; the
        // conversation is the destination, not the sender.
        if let sync = envelope["syncMessage"]?["sentMessage"] {
            let destination =
                directory.canonical(
                    aci: sync["destinationUuid"]?.stringValue,
                    number: sync["destinationNumber"]?.stringValue
                ) ?? sync["destination"]?.stringValue.map { directory.canonical(for: $0) }

            return translate(
                dataMessage: sync,
                envelope: envelope,
                senderID: account.localRecipientID,
                destination: destination,
                account: account,
                directory: directory,
                isOutgoingSync: true
            )
        }

        // Receipts and typing carry no body, so they are translated separately
        // from data messages and never become timeline rows.
        if let receipt = envelope["receiptMessage"] {
            return control(
                kind: .receipt,
                envelope: envelope,
                senderID: senderID,
                account: account,
                timestamps: receipt["timestamps"]?.arrayValue?.compactMap(\.intValue) ?? [],
                detail: receiptDetail(receipt)
            )
        }

        if let typing = envelope["typingMessage"] {
            return control(
                kind: .typing,
                envelope: envelope,
                senderID: senderID,
                account: account,
                timestamps: [],
                detail: typing["action"]?.stringValue?.uppercased() == "STOPPED" ? "stopped" : "started"
            )
        }

        if let data = envelope["dataMessage"] {
            return translate(
                dataMessage: data,
                envelope: envelope,
                senderID: senderID,
                destination: nil,
                account: account,
                directory: directory,
                isOutgoingSync: false
            )
        }

        return nil
    }

    /// Decodes one attachment from a `receive` notification.
    ///
    /// signal-cli has already downloaded the file into its own directory, which
    /// lives inside our sandbox container, so the stored path can be read
    /// directly. `id` is kept as the attachment identifier so `getAttachment`
    /// can fetch anything missing from disk.
    private static func attachment(from value: JSONValue) -> AttachmentReference? {
        guard let id = value["id"]?.stringValue, !id.isEmpty else { return nil }

        let state: AttachmentTransferState
        if let path = value["file"]?.stringValue ?? value["storedFilename"]?.stringValue,
            !path.isEmpty
        {
            state = .available(localRelativePath: path)
        } else {
            state = .pending
        }

        return AttachmentReference(
            id: AttachmentID(id),
            fileName: value["filename"]?.stringValue ?? value["fileName"]?.stringValue,
            mimeType: value["contentType"]?.stringValue ?? "application/octet-stream",
            byteCount: value["size"]?.intValue ?? 0,
            caption: value["caption"]?.stringValue,
            isViewOnce: value["isViewOnce"]?.boolValue ?? false,
            state: state
        )
    }

    /// Decodes one formatting run. Offsets are already UTF-16, matching how
    /// `TextStyleRange` stores them, so no conversion is needed.
    private static func textStyle(from value: JSONValue) -> TextStyleRange? {
        guard
            let start = value["start"]?.intValue,
            let length = value["length"]?.intValue,
            let name = value["style"]?.stringValue,
            let style = TextStyleRange.Style(rawValue: name.uppercased())
        else { return nil }
        return TextStyleRange(start: Int(start), length: Int(length), style: style)
    }

    /// `read` outranks `delivered`, and `viewed` outranks both, so the strongest
    /// state a receipt reports is the one that wins.
    private static func receiptDetail(_ receipt: JSONValue) -> String {
        if receipt["isViewed"]?.boolValue == true { return "viewed" }
        if receipt["isRead"]?.boolValue == true { return "read" }
        return "delivered"
    }

    /// Builds a wire message for a receipt or typing indicator. The body carries
    /// the detail and the target timestamps, since neither has message content.
    private static func control(
        kind: WireMessageKind,
        envelope: JSONValue,
        senderID: RecipientID,
        account: LinkedAccount,
        timestamps: [Int64],
        detail: String
    ) -> Translated? {
        guard let envelopeTimestamp = envelope["timestamp"]?.intValue else { return nil }
        let sentAt = Date(timeIntervalSince1970: Double(envelopeTimestamp) / 1000)

        let conversationKind = ConversationKind.direct(recipientID: senderID)
        let wire = WireMessage(
            id: MessageID("\(kind.rawValue):\(senderID.rawValue):\(envelopeTimestamp)"),
            conversation: ConversationSeed(
                id: .of(conversationKind),
                kind: conversationKind,
                title: senderID.rawValue
            ),
            senderID: senderID,
            recipientID: account.localRecipientID,
            kind: kind,
            body: ControlPayload(
                detail: detail,
                targets: timestamps.map { SignalCLIMessageIndex.messageID(forSignalTimestamp: $0) }
            ).encoded,
            sentAt: sentAt
        )

        return Translated(
            wire: wire,
            envelopeID: EnvelopeID("\(kind.rawValue):\(senderID.rawValue):\(envelopeTimestamp)"),
            signalTimestamp: envelopeTimestamp
        )
    }

    private static func translate(
        dataMessage: JSONValue,
        envelope: JSONValue,
        senderID: RecipientID,
        destination: RecipientID?,
        account: LinkedAccount,
        directory: RecipientDirectory,
        isOutgoingSync: Bool
    ) -> Translated? {
        guard let timestamp = dataMessage["timestamp"]?.intValue ?? envelope["timestamp"]?.intValue
        else { return nil }
        let sentAt = Date(timeIntervalSince1970: Double(timestamp) / 1000)

        let conversation = conversationSeed(
            dataMessage: dataMessage,
            senderID: senderID,
            destination: destination,
            account: account,
            directory: directory,
            isOutgoingSync: isOutgoingSync
        )
        guard let conversation else { return nil }

        let messageID = SignalCLIMessageIndex.messageID(forSignalTimestamp: timestamp)
        var kind: WireMessageKind = .text
        var body = dataMessage["message"]?.stringValue
        var targetMessageID: MessageID?
        var isReactionRemoval: Bool?
        var revision = 0

        if dataMessage["isExpirationUpdate"]?.boolValue == true {
            kind = .expirationUpdate
        } else if let reaction = dataMessage["reaction"] {
            kind = .reaction
            // Signal requires the emoji even for removal. Keep it and carry the
            // removal bit separately; receivers still accept legacy empty-body
            // removals for backward compatibility.
            isReactionRemoval = reaction["isRemove"]?.boolValue == true
            body = reaction["emoji"]?.stringValue
            if let target = reaction["targetSentTimestamp"]?.intValue {
                targetMessageID = SignalCLIMessageIndex.messageID(forSignalTimestamp: target)
            }
        } else if let remoteDelete = dataMessage["remoteDelete"] {
            kind = .delete
            if let target = remoteDelete["timestamp"]?.intValue {
                targetMessageID = SignalCLIMessageIndex.messageID(forSignalTimestamp: target)
            }
            revision = 1
        } else if let editTarget = dataMessage["editTargetTimestamp"]?.intValue
            ?? envelope["editMessage"]?["targetSentTimestamp"]?.intValue
        {
            kind = .edit
            targetMessageID = SignalCLIMessageIndex.messageID(forSignalTimestamp: editTarget)
            revision = 1
        }

        let attachments = (dataMessage["attachments"]?.arrayValue ?? []).compactMap(attachment(from:))
        let textStyles = (dataMessage["textStyles"]?.arrayValue ?? []).compactMap(textStyle(from:))
        // An attachment-only message has no text, so it must not be discarded by
        // the empty-body check below.
        let hasContent = (body?.isEmpty == false) || !attachments.isEmpty

        guard kind != .text || hasContent else { return nil }
        if kind == .edit || kind == .delete || kind == .reaction, targetMessageID == nil {
            return nil
        }

        let expiresIn = dataMessage["expiresInSeconds"]?.intValue.map(Double.init)
        let expirationStart = dataMessage["expirationStartTimestamp"]?.intValue.map {
            Date(timeIntervalSince1970: Double($0) / 1000)
        }
        let expiresAt = expiresIn.flatMap { duration -> Date? in
            guard isOutgoingSync, duration > 0 else { return nil }
            return (expirationStart ?? sentAt).addingTimeInterval(duration)
        }

        // A quote identifies its target by send timestamp, which is exactly how
        // message IDs are derived, so it resolves without a lookup.
        let replyToMessageID = (dataMessage["quote"]?["id"]?.intValue).map {
            SignalCLIMessageIndex.messageID(forSignalTimestamp: $0)
        }

        let wire = WireMessage(
            id: messageID,
            conversation: conversation,
            senderID: senderID,
            // Truthful rather than always the local account: for a message we
            // sent from another device this is the person we sent it to, which
            // is what lets the receiver tell outgoing from incoming.
            recipientID: isOutgoingSync ? (destination ?? account.localRecipientID) : account.localRecipientID,
            kind: kind,
            body: body,
            sentAt: sentAt,
            replyToMessageID: replyToMessageID,
            targetMessageID: targetMessageID,
            isReactionRemoval: isReactionRemoval,
            revision: revision,
            expiresAt: expiresAt,
            expiresIn: expiresIn,
            attachments: attachments,
            textStyles: textStyles.normalized(forUTF16Length: ((body ?? "") as NSString).length)
        )

        return Translated(
            wire: wire,
            envelopeID: EnvelopeID("\(senderID.rawValue):\(timestamp)"),
            signalTimestamp: timestamp
        )
    }

    private static func conversationSeed(
        dataMessage: JSONValue,
        senderID: RecipientID,
        destination: RecipientID?,
        account: LinkedAccount,
        directory: RecipientDirectory,
        isOutgoingSync: Bool
    ) -> ConversationSeed? {
        if let group = dataMessage["groupInfo"],
            let groupID = group["groupId"]?.stringValue
        {
            return ConversationSeed(
                id: .group(with: groupID),
                kind: .group(groupID: groupID, memberIDs: []),
                title: group["groupName"]?.stringValue ?? "Group"
            )
        }

        // Keyed by the other party, so a message sent from the phone and the
        // reply that follows land in one thread.
        let counterpart = isOutgoingSync ? destination : senderID
        guard let counterpart, !counterpart.rawValue.isEmpty else { return nil }

        let localID = directory.canonical(for: account.localRecipientID)
        if directory.canonical(for: counterpart) == localID {
            return ConversationSeed(id: .noteToSelf, kind: .noteToSelf, title: "Note to Self")
        }

        let kind = ConversationKind.direct(recipientID: counterpart)
        return ConversationSeed(
            id: .of(kind),
            kind: kind,
            // A placeholder; the UI resolves the display name from contacts.
            title: counterpart.rawValue
        )
    }
}
