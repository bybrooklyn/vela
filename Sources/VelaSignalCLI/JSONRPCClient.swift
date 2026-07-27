import Foundation

public struct JSONRPCError: Error, Hashable, Sendable, LocalizedError {
    public var code: Int
    public var message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { "signal-cli reported error \(code): \(message)." }
}

public enum JSONRPCClientError: Error, Sendable, LocalizedError {
    case notConnected
    case malformedResponse(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notConnected: "The signal-cli backend is not connected."
        case .malformedResponse(let detail): "The signal-cli backend sent a malformed response: \(detail)."
        case .cancelled: "The request was cancelled."
        }
    }
}

/// A server-initiated message, such as an incoming Signal message.
public struct JSONRPCNotification: Hashable, Sendable {
    public var method: String
    public var params: JSONValue

    public init(method: String, params: JSONValue) {
        self.method = method
        self.params = params
    }
}

/// Newline-delimited JSON-RPC 2.0 over a UNIX socket, as spoken by
/// `signal-cli daemon --socket`.
///
/// Requests are correlated by `id`. Anything arriving without an `id` is a
/// notification and is published on `notifications()`.
public actor JSONRPCClient {
    private let socket: UnixSocketConnection
    private var pending: [String: CheckedContinuation<JSONValue, any Error>] = [:]
    private var nextRequestID = 1
    private var notificationContinuation: AsyncStream<JSONRPCNotification>.Continuation?
    private var notificationStream: AsyncStream<JSONRPCNotification>?
    private var connected = false

    public init(socket: UnixSocketConnection = UnixSocketConnection()) {
        self.socket = socket
    }

    public var isConnected: Bool { connected }

    public func connect(socketPath: String) throws {
        guard !connected else { return }
        try socket.connect(
            path: socketPath,
            onFrame: { [weak self] frame in
                guard let self else { return }
                Task { await self.handle(frame: frame) }
            },
            onClose: { [weak self] error in
                guard let self else { return }
                Task { await self.handleClose(error: error) }
            }
        )
        connected = true
    }

    public func disconnect() {
        guard connected else { return }
        connected = false
        socket.close()
        failAllPending(with: JSONRPCClientError.notConnected)
        notificationContinuation?.finish()
        notificationContinuation = nil
        notificationStream = nil
    }

    /// Server-initiated messages. The stream is shared; the first caller creates it.
    public func notifications() -> AsyncStream<JSONRPCNotification> {
        if let notificationStream { return notificationStream }
        let (stream, continuation) = AsyncStream<JSONRPCNotification>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        notificationStream = stream
        notificationContinuation = continuation
        return stream
    }

    /// Sends a request and waits for its response.
    ///
    /// There is deliberately no timeout: `finishLink` legitimately blocks until
    /// the user scans a QR code with their phone. Callers that need a deadline
    /// wrap the call in their own cancellation.
    @discardableResult
    public func call(_ method: String, params: JSONValue = .object([:])) async throws -> JSONValue {
        guard connected else { throw JSONRPCClientError.notConnected }

        let id = String(nextRequestID)
        nextRequestID += 1

        let request = JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .string(id),
            "method": .string(method),
            "params": params,
        ])
        let payload = try JSONEncoder().encode(request)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                do {
                    try socket.write(payload)
                } catch {
                    pending.removeValue(forKey: id)
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { await self.cancelPending(id: id) }
        }
    }

    private func cancelPending(id: String) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: JSONRPCClientError.cancelled)
    }

    private func handle(frame: Data) {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: frame) else { return }

        // signal-cli ids are strings in our requests, but be tolerant of numbers.
        let id = message["id"].flatMap { value -> String? in
            if let text = value.stringValue { return text }
            if let number = value.intValue { return String(number) }
            return nil
        }

        guard let id else {
            if let method = message["method"]?.stringValue {
                let params = message["params"] ?? .null
                notificationContinuation?.yield(JSONRPCNotification(method: method, params: params))
            }
            return
        }

        guard let continuation = pending.removeValue(forKey: id) else { return }

        if let error = message["error"], !error.isNull {
            let code = Int(error["code"]?.intValue ?? -1)
            let text = error["message"]?.stringValue ?? "unknown error"
            continuation.resume(throwing: JSONRPCError(code: code, message: text))
            return
        }
        continuation.resume(returning: message["result"] ?? .null)
    }

    private func handleClose(error: Error?) {
        connected = false
        failAllPending(with: error ?? JSONRPCClientError.notConnected)
        notificationContinuation?.finish()
        notificationContinuation = nil
        notificationStream = nil
    }

    private func failAllPending(with error: any Error) {
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values {
            continuation.resume(throwing: error)
        }
    }
}
