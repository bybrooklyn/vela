import Foundation
import VelaCrypto
import VelaDomain
import VelaStorage
import VelaTransport

public struct OutboxFlushReport: Hashable, Sendable {
    public var attempted: Int
    public var sent: Int
    public var scheduledForRetry: Int
    public var permanentlyFailed: Int

    public init(attempted: Int = 0, sent: Int = 0, scheduledForRetry: Int = 0, permanentlyFailed: Int = 0) {
        self.attempted = attempted
        self.sent = sent
        self.scheduledForRetry = scheduledForRetry
        self.permanentlyFailed = permanentlyFailed
    }
}

public actor OutboxProcessor {
    private let store: any ClientStore
    private let crypto: any CryptoEngine
    private let transport: any ServiceTransport
    private let clock: any VelaClock
    private let backoff: BackoffPolicy
    private let events: ClientEventHub
    private let diagnostics: DiagnosticsRecorder
    private var loopTask: Task<Void, Never>?
    private var account: LinkedAccount?
    /// Messages currently being sent.
    ///
    /// `flushOnce` suspends while the transport works, and actor reentrancy lets
    /// another flush start during that window and load the same due row. Without
    /// this guard the periodic loop and an explicit flush can both send the same
    /// message, which the recipient sees twice.
    private var inFlight: Set<MessageID> = []
    /// True while a coalesced flush is already scheduled.
    ///
    /// Sending is optimistic, so every send, edit, reaction and delete asks for a
    /// flush. Spawning a task per request produced a burst that all contended on
    /// this actor and mostly found nothing to do; one pending wake is enough.
    private var isFlushScheduled = false

    public init(
        store: any ClientStore,
        crypto: any CryptoEngine,
        transport: any ServiceTransport,
        clock: any VelaClock = SystemVelaClock(),
        backoff: BackoffPolicy = BackoffPolicy(),
        events: ClientEventHub,
        diagnostics: DiagnosticsRecorder
    ) {
        self.store = store
        self.crypto = crypto
        self.transport = transport
        self.clock = clock
        self.backoff = backoff
        self.events = events
        self.diagnostics = diagnostics
    }

    /// Binds the account so `flushOnce` can run, without starting the periodic
    /// loop. Callers that drive flushing themselves use this to keep the timing
    /// deterministic; `start` layers the background loop on top.
    public func configure(account: LinkedAccount) {
        self.account = account
    }

    public func start(account: LinkedAccount) {
        configure(account: account)
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        account = nil
    }

    /// Asks for a flush without waiting for it, collapsing repeated requests
    /// into a single pending run.
    public func requestFlush() {
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        Task { [weak self] in
            await self?.runScheduledFlush()
        }
    }

    /// Makes every retained outbox row immediately due, then attempts a flush.
    ///
    /// Transient failures stay in the outbox indefinitely with capped backoff.
    /// This explicit path lets a user-initiated reconnect bypass the remaining
    /// delay without weakening duplicate-send protection.
    @discardableResult
    public func retryPending(limit: Int = 128) async -> OutboxFlushReport {
        guard account != nil else { return OutboxFlushReport() }
        let boundedLimit = max(1, limit)

        do {
            let pending = try await store.loadDueOutbox(at: .distantFuture, limit: boundedLimit)
            for var item in pending where !inFlight.contains(item.messageID) {
                item.nextAttemptAt = clock.now
                item.attemptCount = 0
                item.lastFailureCategory = nil
                try await store.updateOutboxItem(item, messageState: .queued)
            }
        } catch {
            await recordFailure(category: "manual-retry-load-failed", error: error)
            return OutboxFlushReport()
        }

        return await flushOnce(limit: boundedLimit)
    }

    private func runScheduledFlush() async {
        isFlushScheduled = false
        _ = await flushOnce()
    }

    public func flushOnce(limit: Int = 32) async -> OutboxFlushReport {
        guard let account else { return OutboxFlushReport() }
        var report = OutboxFlushReport()

        do {
            let items = try await store.loadDueOutbox(at: clock.now, limit: limit)
            for item in items {
                guard !Task.isCancelled else { break }
                guard inFlight.insert(item.messageID).inserted else { continue }
                defer { inFlight.remove(item.messageID) }

                report.attempted += 1
                let result = await process(item: item, account: account)
                switch result {
                case .sent: report.sent += 1
                case .retry: report.scheduledForRetry += 1
                case .permanent: report.permanentlyFailed += 1
                }
            }
        } catch {
            await diagnostics.record(
                subsystem: "outbox",
                category: "load-failed",
                detail: DiagnosticsRecorder.errorCategory(error),
                at: clock.now
            )
            await events.publish(.diagnosticsChanged)
        }
        return report
    }

    private enum ProcessResult {
        case sent
        case retry
        case permanent
    }

    private func process(item: OutboxItem, account: LinkedAccount) async -> ProcessResult {
        var mutableItem = item
        mutableItem.attemptCount += 1

        do {
            try await store.updateOutboxItem(
                mutableItem,
                messageState: .sending(attempt: mutableItem.attemptCount)
            )

            let source = DeviceAddress(
                recipientID: account.localRecipientID,
                deviceID: account.deviceID
            )
            let now = clock.now
            let envelope = try await crypto.seal(
                mutableItem.plaintextPayload,
                envelopeID: .random(),
                source: source,
                destination: mutableItem.destination,
                timestamp: now,
                contentType: .message
            )
            let receipt = try await transport.send(envelope)
            try await store.completeOutboxItem(
                messageID: mutableItem.messageID,
                serverTimestamp: receipt.acceptedAt
            )
            if let message = try await store.loadMessage(id: mutableItem.messageID) {
                await events.publish(.messagesChanged(message.conversationID))
            }
            return .sent
        } catch {
            let category = DiagnosticsRecorder.errorCategory(error)
            if isPermanent(error) {
                try? await store.permanentlyFailOutboxItem(
                    messageID: mutableItem.messageID,
                    category: category
                )
                if let message = try? await store.loadMessage(id: mutableItem.messageID) {
                    await events.publish(.messagesChanged(message.conversationID))
                }
                await diagnostics.record(
                    subsystem: "outbox",
                    category: "permanent-failure",
                    detail: category,
                    at: clock.now
                )
                await events.publish(.diagnosticsChanged)
                return .permanent
            }

            let delay = backoff.delay(afterAttempt: mutableItem.attemptCount)
            mutableItem.nextAttemptAt = clock.now.addingTimeInterval(delay)
            mutableItem.lastFailureCategory = category
            try? await store.updateOutboxItem(
                mutableItem,
                messageState: .failedRetryable(reason: category)
            )
            if let message = try? await store.loadMessage(id: mutableItem.messageID) {
                await events.publish(.messagesChanged(message.conversationID))
            }
            return .retry
        }
    }

    private func isPermanent(_ error: any Error) -> Bool {
        guard let transportError = error as? TransportError else { return false }
        switch transportError {
        case .authenticationRejected, .productionIntegrationRequired:
            return true
        default:
            return false
        }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            _ = await flushOnce()
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                break
            }
        }
    }

    private func recordFailure(category: String, error: any Error) async {
        await diagnostics.record(
            subsystem: "outbox",
            category: category,
            detail: DiagnosticsRecorder.errorCategory(error),
            at: clock.now
        )
        await events.publish(.diagnosticsChanged)
    }
}
