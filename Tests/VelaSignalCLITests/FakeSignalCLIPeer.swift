import Foundation

@testable import VelaSignalCLI

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// A scripted stand-in for `signal-cli daemon --socket`.
///
/// Listens on a real UNIX socket and answers newline-delimited JSON-RPC, so the
/// tests exercise the actual socket and framing code rather than a mock. No
/// network and no Signal account are involved, so this runs in Linux CI.
final class FakeSignalCLIPeer: @unchecked Sendable {
    typealias Handler = @Sendable (_ method: String, _ params: JSONValue) -> Result<JSONValue, JSONRPCError>

    let socketPath: String
    private var listenDescriptor: Int32 = -1
    private var clientDescriptor: Int32 = -1
    private let lock = NSLock()
    private var handler: Handler
    private var thread: Thread?
    private(set) var receivedMethods: [String] = []

    init(handler: @escaping Handler) throws {
        self.handler = handler
        // UNIX socket paths are capped near 104 bytes, so keep this short.
        let name = "vela-\(UUID().uuidString.prefix(8)).sock"
        socketPath = (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
        try start()
    }

    deinit { stop() }

    private func start() throws {
        unlink(socketPath)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw SocketError.pathTooLong(socketPath)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }

        #if canImport(Darwin)
            let streamType = SOCK_STREAM
        #else
            let streamType = Int32(SOCK_STREAM.rawValue)
        #endif
        let fd = socket(AF_UNIX, streamType, 0)
        guard fd >= 0 else { throw SocketError.cannotCreate("socket") }

        // Same SIGPIPE protection as the client: the peer writes to sockets the
        // test may have already torn down.
        #if canImport(Darwin)
            var noSignal: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        #endif

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                #if canImport(Darwin)
                    Darwin.bind(fd, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
                #else
                    Glibc.bind(fd, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
                #endif
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            close(fd)
            throw SocketError.cannotCreate("bind/listen")
        }

        listenDescriptor = fd
        let thread = Thread { [weak self] in self?.serve(listenFD: fd) }
        thread.name = "fake-signal-cli-peer"
        self.thread = thread
        thread.start()
    }

    /// Pushes a server-initiated notification to the connected client.
    func send(notification method: String, params: JSONValue) {
        let message = JSONValue.object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params,
        ])
        guard var data = try? JSONEncoder().encode(message) else { return }
        data.append(UInt8(ascii: "\n"))

        lock.lock()
        let fd = clientDescriptor
        lock.unlock()
        guard fd >= 0 else { return }
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    func methodsSeen() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return receivedMethods
    }

    func stop() {
        lock.lock()
        let listenFD = listenDescriptor
        let clientFD = clientDescriptor
        listenDescriptor = -1
        clientDescriptor = -1
        lock.unlock()

        if clientFD >= 0 {
            shutdown(clientFD, Int32(SHUT_RDWR))
            close(clientFD)
        }
        if listenFD >= 0 {
            shutdown(listenFD, Int32(SHUT_RDWR))
            close(listenFD)
        }
        unlink(socketPath)
    }

    private func serve(listenFD: Int32) {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        #if canImport(Darwin)
            var noSignal: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        #endif
        lock.lock()
        clientDescriptor = client
        lock.unlock()

        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)

        while true {
            let count = buffer.withUnsafeMutableBytes { read(client, $0.baseAddress, $0.count) }
            guard count > 0 else { break }
            pending.append(contentsOf: buffer[0..<count])

            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let frame = Data(pending[pending.startIndex..<newline])
                pending = pending[pending.index(after: newline)...]
                respond(to: frame, on: client)
            }
        }
    }

    private func respond(to frame: Data, on client: Int32) {
        guard
            let request = try? JSONDecoder().decode(JSONValue.self, from: frame),
            let id = request["id"],
            let method = request["method"]?.stringValue
        else { return }

        lock.lock()
        receivedMethods.append(method)
        let currentHandler = handler
        lock.unlock()

        let outcome = currentHandler(method, request["params"] ?? .null)
        let response: JSONValue
        switch outcome {
        case .success(let result):
            response = .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
        case .failure(let error):
            response = .object([
                "jsonrpc": .string("2.0"),
                "id": id,
                "error": .object([
                    "code": .integer(Int64(error.code)),
                    "message": .string(error.message),
                ]),
            ])
        }

        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(UInt8(ascii: "\n"))
        _ = data.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
    }
}
