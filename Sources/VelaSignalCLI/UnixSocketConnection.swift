import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

public enum SocketError: Error, Sendable, LocalizedError {
    case pathTooLong(String)
    case cannotCreate(String)
    case cannotConnect(path: String, reason: String)
    case closed
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .pathTooLong(let path):
            "The socket path is too long for a UNIX domain socket: \(path)."
        case .cannotCreate(let reason):
            "The socket could not be created: \(reason)."
        case .cannotConnect(let path, let reason):
            "Could not connect to \(path): \(reason)."
        case .closed:
            "The socket is closed."
        case .writeFailed(let reason):
            "The socket write failed: \(reason)."
        }
    }
}

/// A blocking `AF_UNIX` stream socket that delivers newline-delimited frames.
///
/// Reads run on a dedicated thread rather than the Swift concurrency pool: the
/// backend connection is idle most of the time, and a blocking `read` would
/// otherwise occupy a cooperative thread indefinitely.
public final class UnixSocketConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var readThread: Thread?
    private var isClosed = false

    public init() {}

    deinit { close() }

    public var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return descriptor >= 0 && !isClosed
    }

    /// Connects and starts delivering frames. `onFrame` is called once per
    /// newline-terminated message; `onClose` once when the peer goes away.
    public func connect(
        path: String,
        onFrame: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable (Error?) -> Void
    ) throws {
        let pathBytes = Array(path.utf8)
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else { throw SocketError.pathTooLong(path) }

        address.sun_family = sa_family_t(AF_UNIX)
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
        guard fd >= 0 else { throw SocketError.cannotCreate(Self.errnoDescription()) }

        // Writing to a socket whose peer has gone away raises SIGPIPE, which
        // terminates the process by default. If the signal-cli daemon dies, Vela
        // must see an EPIPE error it can recover from, not be killed.
        #if canImport(Darwin)
            var noSignal: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        #endif

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                #if canImport(Darwin)
                    Darwin.connect(fd, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
                #else
                    Glibc.connect(fd, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
                #endif
            }
        }
        guard connected == 0 else {
            let reason = Self.errnoDescription()
            _ = Self.closeDescriptor(fd)
            throw SocketError.cannotConnect(path: path, reason: reason)
        }

        lock.lock()
        descriptor = fd
        isClosed = false
        lock.unlock()

        let thread = Thread { [weak self] in
            self?.readLoop(fd: fd, onFrame: onFrame, onClose: onClose)
        }
        thread.name = "works.deadsignal.vela.signal-cli-rpc"
        thread.stackSize = 512 * 1024
        readThread = thread
        thread.start()
    }

    public func write(_ frame: Data) throws {
        lock.lock()
        let fd = descriptor
        let closed = isClosed
        lock.unlock()
        guard fd >= 0, !closed else { throw SocketError.closed }

        var payload = frame
        if payload.last != UInt8(ascii: "\n") {
            payload.append(UInt8(ascii: "\n"))
        }

        try payload.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                // Linux has no SO_NOSIGPIPE, so suppress the signal per call.
                #if canImport(Darwin)
                    let written = Foundation.write(
                        fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                #else
                    let written = Glibc.send(
                        fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset,
                        Int32(MSG_NOSIGNAL))
                #endif
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                throw SocketError.writeFailed(Self.errnoDescription())
            }
        }
    }

    public func close() {
        lock.lock()
        let fd = descriptor
        let alreadyClosed = isClosed
        isClosed = true
        descriptor = -1
        lock.unlock()
        guard !alreadyClosed, fd >= 0 else { return }
        // Shutting down first unblocks the reader so its thread can exit.
        shutdown(fd, Int32(SHUT_RDWR))
        _ = Self.closeDescriptor(fd)
    }

    private func readLoop(
        fd: Int32,
        onFrame: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable (Error?) -> Void
    ) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var failure: Error?

        loop: while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                Foundation.read(fd, raw.baseAddress, raw.count)
            }
            if count > 0 {
                pending.append(contentsOf: buffer[0..<count])
                while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    let frame = pending[pending.startIndex..<newline]
                    pending = pending[pending.index(after: newline)...]
                    if !frame.isEmpty { onFrame(Data(frame)) }
                }
                continue
            }
            if count == 0 { break loop }  // peer closed
            if errno == EINTR { continue }
            lock.lock()
            let deliberate = isClosed
            lock.unlock()
            if !deliberate { failure = SocketError.writeFailed(Self.errnoDescription()) }
            break loop
        }

        onClose(failure)
    }

    private static func closeDescriptor(_ fd: Int32) -> Int32 {
        #if canImport(Darwin)
            Darwin.close(fd)
        #else
            Glibc.close(fd)
        #endif
    }

    private static func errnoDescription() -> String {
        String(cString: strerror(errno))
    }
}
