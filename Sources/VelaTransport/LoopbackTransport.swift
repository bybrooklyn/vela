import Foundation
import VelaDomain

/// Deterministic, process-local transport used by the demo app and tests.
/// It never talks to Signal services.
public actor LoopbackTransport: ServiceTransport {
    private var account: LinkedAccount?
    private var state: TransportConnectionState = .disconnected
    private var stateContinuations: [UUID: AsyncStream<TransportConnectionState>.Continuation] = [:]
    private var envelopeContinuations: [UUID: AsyncStream<EncryptedEnvelope>.Continuation] = [:]
    private var outbound: [EncryptedEnvelope] = []
    private var failNextSendCount = 0

    public init() {}

    public func connect(account: LinkedAccount) async throws {
        self.account = account
        publishState(.connecting)
        publishState(.connected)
    }

    public func disconnect(reason: OfflineReason) async {
        account = nil
        publishState(.disconnected)
    }

    public func connectionStates() async -> AsyncStream<TransportConnectionState> {
        let id = UUID()
        let pair = AsyncStream<TransportConnectionState>.makeStream(bufferingPolicy: .bufferingNewest(16))
        stateContinuations[id] = pair.continuation
        pair.continuation.yield(state)
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStateContinuation(id) }
        }
        return pair.stream
    }

    public func incomingEnvelopes() async -> AsyncStream<EncryptedEnvelope> {
        let id = UUID()
        let pair = AsyncStream<EncryptedEnvelope>.makeStream(bufferingPolicy: .bufferingNewest(512))
        envelopeContinuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeEnvelopeContinuation(id) }
        }
        return pair.stream
    }

    public func send(_ envelope: EncryptedEnvelope) async throws -> TransportSendReceipt {
        guard account != nil, state == .connected else {
            throw TransportError.notConnected
        }
        if failNextSendCount > 0 {
            failNextSendCount -= 1
            throw TransportError.intentionallyInjectedFailure
        }
        outbound.append(envelope)
        return TransportSendReceipt(envelopeID: envelope.id, acceptedAt: Date())
    }

    public func injectIncoming(_ envelope: EncryptedEnvelope) {
        for continuation in envelopeContinuations.values {
            continuation.yield(envelope)
        }
    }

    public func sentEnvelopes() -> [EncryptedEnvelope] {
        outbound
    }

    public func removeAllSentEnvelopes() {
        outbound.removeAll(keepingCapacity: true)
    }

    public func failNextSends(_ count: Int) {
        failNextSendCount = max(0, count)
    }

    public func simulateConnectionState(_ state: TransportConnectionState) {
        publishState(state)
    }

    private func publishState(_ state: TransportConnectionState) {
        self.state = state
        for continuation in stateContinuations.values {
            continuation.yield(state)
        }
    }

    private func removeStateContinuation(_ id: UUID) {
        stateContinuations.removeValue(forKey: id)
    }

    private func removeEnvelopeContinuation(_ id: UUID) {
        envelopeContinuations.removeValue(forKey: id)
    }
}
