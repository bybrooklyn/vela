import Foundation

/// The body format shared by receipt and typing wire messages.
///
/// Neither carries message text, so the body is reused to carry a detail word
/// and, for receipts, the send timestamps of the messages being acknowledged.
/// Encoding and decoding live together so the transport and the receiver cannot
/// drift apart.
public struct ControlPayload: Hashable, Sendable {
    /// `delivered`, `read` or `viewed` for a receipt; `started` or `stopped`
    /// for a typing indicator.
    public var detail: String
    /// Messages a receipt refers to. Always empty for typing.
    public var targets: [MessageID]

    public init(detail: String, targets: [MessageID] = []) {
        self.detail = detail
        self.targets = targets
    }

    public init(wire: WireMessage) {
        self.init(encoded: wire.body)
    }

    public init(encoded: String?) {
        let parts = (encoded ?? "").split(separator: ",").map(String.init)
        detail = parts.first ?? ""
        targets = parts.dropFirst().map { MessageID($0) }
    }

    public var encoded: String {
        ([detail] + targets.map(\.rawValue)).joined(separator: ",")
    }

    /// Convenience for callers that only need the detail word.
    public static func detail(of wire: WireMessage) -> String {
        ControlPayload(wire: wire).detail
    }
}

extension MessageDeliveryState {
    /// How far along delivery this state represents.
    ///
    /// Receipts arrive out of order and are re-sent, so state is only ever moved
    /// forward by comparing ranks — a late `delivered` must not undo a `read`.
    public var receiptRank: Int {
        switch self {
        case .queued: 0
        case .sending: 1
        case .failedRetryable: 1
        case .failedPermanent: 1
        case .sent: 2
        case .delivered: 3
        case .read: 4
        }
    }
}
