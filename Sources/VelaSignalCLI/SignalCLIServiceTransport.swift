import Foundation
import VelaCore
import VelaCrypto
import VelaDomain
import VelaTransport

/// Carries Vela's messages over signal-cli's JSON-RPC interface.
///
/// Outgoing: the `WireMessage` is decoded back out of the envelope and mapped to
/// the signal-cli command that expresses that intent — Signal has no generic
/// "send bytes" call, so edits, reactions and deletes are distinct methods keyed
/// by the target message's send timestamp.
///
/// Incoming: `receive` notifications are translated into `WireMessage`s and
/// re-wrapped as envelopes, so the existing `MessageReceiver` replay-suppression
/// and mutation logic applies unchanged.
public actor SignalCLIServiceTransport: ServiceTransport {
    private let client: JSONRPCClient
    private let index: SignalCLIMessageIndex
    private let codec = WireCodec()
    private let attachmentDownloads: AttachmentDownloadQueue
    private let attachmentDirectory: URL

    private var account: LinkedAccount?
    /// Kept in step with the contact cache so inbound senders resolve to the
    /// same canonical identity the UI used when creating the conversation.
    private var directory = RecipientDirectory()
    private var connectionContinuation: AsyncStream<TransportConnectionState>.Continuation?
    private var connectionStream: AsyncStream<TransportConnectionState>?
    private var envelopeContinuation: AsyncStream<EncryptedEnvelope>.Continuation?
    private var envelopeStream: AsyncStream<EncryptedEnvelope>?
    private var receiveTask: Task<Void, Never>?
    private var connectionState: TransportConnectionState = .disconnected

    public init(
        client: JSONRPCClient,
        index: SignalCLIMessageIndex,
        attachmentDirectory: URL? = nil,
        maximumConcurrentAttachmentDownloads: Int = 3
    ) {
        self.client = client
        self.index = index
        self.attachmentDownloads = AttachmentDownloadQueue(
            maximumConcurrent: maximumConcurrentAttachmentDownloads
        )
        self.attachmentDirectory = attachmentDirectory ?? Self.defaultAttachmentDirectory()
    }

    // MARK: - Lifecycle

    public func connect(account: LinkedAccount) async throws {
        self.account = account
        publishConnection(.connecting)
        guard await client.isConnected else {
            publishConnection(.failed(category: "service-unavailable"))
            throw TransportError.serviceUnavailable
        }
        startReceiving(account: account)

        // The daemon runs in multi-account mode, so receiving has to be
        // requested explicitly for this account. Without it no `receive`
        // notification is ever delivered and incoming messages are silently lost.
        do {
            _ = try await client.call(
                "subscribeReceive",
                params: .object(["account": .string(account.localRecipientID.rawValue)])
            )
        } catch {
            receiveTask?.cancel()
            receiveTask = nil
            let mapped = (error as? JSONRPCError).map(Self.transportError(for:)) ?? .serviceUnavailable
            publishConnection(.failed(category: Self.category(for: mapped)))
            throw mapped
        }

        publishConnection(.connected)
    }

    public func disconnect(reason: OfflineReason) async {
        receiveTask?.cancel()
        receiveTask = nil
        account = nil
        publishConnection(.disconnected)
    }

    public func connectionStates() async -> AsyncStream<TransportConnectionState> {
        if let connectionStream { return connectionStream }
        let (stream, continuation) = AsyncStream<TransportConnectionState>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        connectionStream = stream
        connectionContinuation = continuation
        continuation.yield(connectionState)
        return stream
    }

    public func incomingEnvelopes() async -> AsyncStream<EncryptedEnvelope> {
        if let envelopeStream { return envelopeStream }
        let (stream, continuation) = AsyncStream<EncryptedEnvelope>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        envelopeStream = stream
        envelopeContinuation = continuation
        return stream
    }

    // MARK: - Sending

    public func send(_ envelope: EncryptedEnvelope) async throws -> TransportSendReceipt {
        guard account != nil else { throw TransportError.notConnected }
        guard let wire = try? codec.decode(envelope.ciphertext) else {
            throw TransportError.serviceUnavailable
        }

        let recipient = try recipientParams(for: wire)
        let result: JSONValue

        do {
            switch wire.kind {
            case .text:
                var params = recipient
                params["message"] = .string(wire.body ?? "")
                // Signal quotes carry the target's send timestamp and author, so
                // the recipient's client can render the excerpt inline.
                if let replyTo = wire.replyToMessageID,
                    let quotedAt = await index.signalTimestamp(for: replyTo)
                {
                    params["quoteTimestamp"] = .integer(quotedAt)
                    if let author = await index.author(for: replyTo) {
                        params["quoteAuthor"] = .string(author.rawValue)
                    }
                }
                // Outgoing attachments are referenced by the local path recorded
                // when the user picked them.
                let paths = wire.attachments.compactMap { attachment -> JSONValue? in
                    guard case .available(let path) = attachment.state else { return nil }
                    return .string(path)
                }
                if !paths.isEmpty {
                    params["attachment"] = .array(paths)
                }
                // signal-cli takes formatting as `start:length:STYLE` over
                // UTF-16 offsets, which is exactly how TextStyleRange stores it.
                if !wire.textStyles.isEmpty {
                    params["textStyle"] = .array(
                        wire.textStyles.map { .string($0.commandArgument) }
                    )
                }
                result = try await client.call("send", params: .object(params))

            case .edit:
                guard let target = wire.targetMessageID,
                    let timestamp = await index.signalTimestamp(for: target)
                else {
                    throw TransportError.serviceUnavailable
                }
                var params = recipient
                params["message"] = .string(wire.body ?? "")
                params["editTimestamp"] = .integer(timestamp)
                if !wire.textStyles.isEmpty {
                    params["textStyle"] = .array(
                        wire.textStyles.map { .string($0.commandArgument) }
                    )
                }
                result = try await client.call("send", params: .object(params))

            case .reaction:
                guard let target = wire.targetMessageID,
                    let timestamp = await index.signalTimestamp(for: target),
                    let author = await index.author(for: target)
                else {
                    throw TransportError.serviceUnavailable
                }
                var params = recipient
                params["emoji"] = .string(wire.body ?? "")
                params["remove"] = .bool(wire.isReactionRemoval == true)
                params["targetAuthor"] = .string(author.rawValue)
                params["targetTimestamp"] = .integer(timestamp)
                result = try await client.call("sendReaction", params: .object(params))

            case .delete:
                guard let target = wire.targetMessageID,
                    let timestamp = await index.signalTimestamp(for: target)
                else {
                    throw TransportError.serviceUnavailable
                }
                var params = recipient
                params["targetTimestamp"] = .integer(timestamp)
                result = try await client.call("remoteDelete", params: .object(params))

            case .receipt, .typing, .expirationUpdate, .readSync, .unsupported:
                // Not carried through the durable outbox. `readSync` is inbound
                // only: signal-cli has no command to tell our own other devices
                // that we read something, so Vela follows the phone rather than
                // the other way round.
                return TransportSendReceipt(envelopeID: envelope.id, acceptedAt: Date())
            }
        } catch let error as JSONRPCError {
            let mapped = Self.transportError(for: error)
            if case .serviceUnavailable = mapped { publishConnection(.disconnected) }
            throw mapped
        } catch is JSONRPCClientError {
            publishConnection(.disconnected)
            throw TransportError.serviceUnavailable
        } catch is SocketError {
            publishConnection(.disconnected)
            throw TransportError.serviceUnavailable
        }

        // Signal identifies the message by the timestamp it was accepted at, and
        // every later edit/reaction/delete refers back to it.
        let acceptedMilliseconds = result["timestamp"]?.intValue
        let acceptedAt = acceptedMilliseconds.map {
            Date(timeIntervalSince1970: Double($0) / 1000)
        }
        if let acceptedMilliseconds, wire.kind == .text {
            await index.record(
                messageID: wire.id,
                signalTimestamp: acceptedMilliseconds,
                author: wire.senderID
            )
        }

        return TransportSendReceipt(envelopeID: envelope.id, acceptedAt: acceptedAt ?? Date())
    }

    /// Base parameters for any send. The daemon is in multi-account mode, so
    /// every call must name the account it acts for.
    private func recipientParams(for wire: WireMessage) throws -> [String: JSONValue] {
        guard let account else { throw TransportError.notConnected }
        var params: [String: JSONValue] = [
            "account": .string(account.localRecipientID.rawValue)
        ]

        switch wire.conversation.kind {
        case .direct(let recipientID):
            params["recipient"] = .array([.string(recipientID.rawValue)])
        case .group(let groupID, _):
            params["groupId"] = .string(groupID)
        case .noteToSelf:
            params["recipient"] = .array([.string(account.localRecipientID.rawValue)])
        }
        return params
    }

    private static func transportError(for error: JSONRPCError) -> TransportError {
        switch error.code {
        case -32000...(-31999): .serviceUnavailable
        case -1: .authenticationRejected
        default: .serviceUnavailable
        }
    }

    private static func category(for error: TransportError) -> String {
        switch error {
        case .authenticationRejected: "authentication-rejected"
        case .notConnected: "not-connected"
        case .serviceUnavailable: "service-unavailable"
        case .intentionallyInjectedFailure: "injected-failure"
        case .productionIntegrationRequired: "production-integration-required"
        }
    }

    private func publishConnection(_ state: TransportConnectionState) {
        guard connectionState != state else { return }
        connectionState = state
        connectionContinuation?.yield(state)
    }

    // MARK: - Receiving

    private func startReceiving(account: LinkedAccount) {
        receiveTask?.cancel()
        let client = self.client
        receiveTask = Task { [weak self] in
            let stream = await client.notifications()
            for await notification in stream {
                guard !Task.isCancelled else { break }
                guard notification.method == "receive" else { continue }
                await self?.ingest(notification.params, account: account)
            }
            guard !Task.isCancelled else { return }
            await self?.receiveStreamEnded(for: account)
        }
    }

    private func receiveStreamEnded(for connectedAccount: LinkedAccount) {
        guard account?.id == connectedAccount.id else { return }
        receiveTask = nil
        publishConnection(.disconnected)
    }

    public func updateDirectory(_ directory: RecipientDirectory) {
        self.directory = directory
    }

    /// Tells the other side a conversation has been read.
    ///
    /// Best-effort: a failed receipt must never surface as a messaging error,
    /// because nothing the user did has failed.
    public func sendReadReceipt(to recipientID: RecipientID, messageIDs: [MessageID]) async {
        guard let account, !messageIDs.isEmpty else { return }
        let timestamps = await index.signalTimestamps(for: messageIDs)
        guard !timestamps.isEmpty else { return }

        _ = try? await client.call(
            "sendReceipt",
            params: .object([
                "account": .string(account.localRecipientID.rawValue),
                "recipient": .string(recipientID.rawValue),
                "targetTimestamp": .array(timestamps.map { .integer($0) }),
                "type": .string("read"),
            ])
        )
    }

    /// Signal's indicator lasts about 15 seconds; the caller debounces so this
    /// is not sent on every keystroke.
    public func sendTyping(to conversation: ConversationSeed, isTyping: Bool) async {
        guard let account else { return }
        var params: [String: JSONValue] = [
            "account": .string(account.localRecipientID.rawValue),
            "stop": .bool(!isTyping),
        ]
        switch conversation.kind {
        case .direct(let recipientID):
            params["recipient"] = .array([.string(recipientID.rawValue)])
        case .group(let groupID, _):
            params["groupId"] = .string(groupID)
        case .noteToSelf:
            // Typing to yourself is noise.
            return
        }
        _ = try? await client.call("sendTyping", params: .object(params))
    }

    private func ingest(_ params: JSONValue, account: LinkedAccount) async {
        guard
            let translated = SignalCLIEnvelopeTranslator.translate(
                params,
                account: account,
                directory: directory
            )
        else {
            return
        }
        var wire = translated.wire
        if wire.kind == .text, wire.attachments.contains(where: Self.needsDownload) {
            wire.attachments = await resolvePendingAttachments(in: wire, account: account)
        }
        if wire.kind == .text {
            await index.record(
                messageID: wire.id,
                signalTimestamp: translated.signalTimestamp,
                author: wire.senderID
            )
        }
        guard let payload = try? codec.encode(wire) else { return }

        let envelope = EncryptedEnvelope(
            id: translated.envelopeID,
            source: DeviceAddress(
                recipientID: wire.senderID,
                deviceID: SignalCLIRecipientRouter.backendDeviceID
            ),
            destination: DeviceAddress(
                recipientID: account.localRecipientID,
                deviceID: account.deviceID
            ),
            serverTimestamp: wire.sentAt,
            contentType: .message,
            protection: .signalCLIBridge,
            ciphertext: payload
        )
        envelopeContinuation?.yield(envelope)
    }

    private static func needsDownload(_ reference: AttachmentReference) -> Bool {
        if case .pending = reference.state { return !reference.isViewOnce }
        return false
    }

    private func resolvePendingAttachments(
        in wire: WireMessage,
        account: LinkedAccount
    ) async -> [AttachmentReference] {
        let client = self.client
        let queue = attachmentDownloads
        let directory = attachmentDirectory

        return await withTaskGroup(of: (Int, AttachmentReference).self) { group in
            for (index, reference) in wire.attachments.enumerated() {
                guard Self.needsDownload(reference) else { continue }
                let params = Self.attachmentParameters(
                    reference: reference,
                    wire: wire,
                    account: account
                )
                let destination = directory.appendingPathComponent(
                    Self.attachmentFileName(reference),
                    isDirectory: false
                )

                group.addTask {
                    var resolved = reference
                    do {
                        try await queue.enqueue(attachmentID: reference.id) {
                            let result = try await client.call("getAttachment", params: .object(params))
                            guard
                                let encoded = result["data"]?.stringValue ?? result.stringValue,
                                let data = Data(base64Encoded: encoded)
                            else {
                                throw TransportError.serviceUnavailable
                            }
                            try FileManager.default.createDirectory(
                                at: directory,
                                withIntermediateDirectories: true
                            )
                            try data.write(to: destination, options: .atomic)
                        }
                        resolved.state = .available(localRelativePath: destination.path)
                    } catch {
                        resolved.state = .failed(reason: "attachment-download-failed")
                    }
                    return (index, resolved)
                }
            }

            var result = wire.attachments
            for await (index, reference) in group {
                result[index] = reference
            }
            return result
        }
    }

    private static func attachmentParameters(
        reference: AttachmentReference,
        wire: WireMessage,
        account: LinkedAccount
    ) -> [String: JSONValue] {
        var params: [String: JSONValue] = [
            "account": .string(account.localRecipientID.rawValue),
            "id": .string(reference.id.rawValue),
        ]
        switch wire.conversation.kind {
        case .direct(let recipientID):
            params["recipient"] = .string(recipientID.rawValue)
        case .group(let groupID, _):
            params["groupId"] = .string(groupID)
        case .noteToSelf:
            params["recipient"] = .string(account.localRecipientID.rawValue)
        }
        return params
    }

    private static func attachmentFileName(_ reference: AttachmentReference) -> String {
        let allowed = CharacterSet.alphanumerics
        let stem = reference.id.rawValue.unicodeScalars
            .prefix(128)
            .map { allowed.contains($0) ? Character($0) : "_" }
            .reduce(into: "") { $0.append($1) }
        let sourceExtension = reference.fileName.map { URL(fileURLWithPath: $0).pathExtension } ?? ""
        let safeExtension = sourceExtension.unicodeScalars
            .prefix(12)
            .filter { allowed.contains($0) }
            .map(String.init)
            .joined()
        return safeExtension.isEmpty ? stem : "\(stem).\(safeExtension)"
    }

    private static func defaultAttachmentDirectory() -> URL {
        let base =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Vela/attachments", isDirectory: true)
    }
}
