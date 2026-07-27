#if os(macOS)
    import Foundation
    import os

    /// Locates and runs the signal-cli backend embedded in `Vela.app`.
    ///
    /// The backend is vendored by `Scripts/macOS/vendor-signal-cli.sh` and copied
    /// into the bundle by `Scripts/macOS/build.sh`. Everything it writes stays
    /// inside the App Sandbox container, and the JSON-RPC socket is a UNIX socket
    /// in that container rather than a TCP port, so nothing else on the machine
    /// can reach it.
    enum SignalCLIBackend {
        private static let log = Logger(subsystem: "works.deadsignal.vela", category: "signal-cli")

        enum BackendError: Error, LocalizedError {
            case notEmbedded
            case launchFailed(String)
            case exited(code: Int32, message: String)
            case cleanupFailed([String])

            var errorDescription: String? {
                switch self {
                case .notEmbedded:
                    "This build of Vela does not embed the signal-cli backend."
                case .launchFailed(let detail):
                    "The signal-cli backend could not be launched: \(detail)."
                case .exited(let code, let message):
                    "The signal-cli backend exited with status \(code): \(message)."
                case .cleanupFailed(let artifacts):
                    "Could not remove local account data: \(artifacts.joined(separator: ", "))."
                }
            }
        }

        struct Layout {
            let executable: URL
            let nativeLibraryDirectory: URL
            let configDirectory: URL
            let socketPath: URL
            let logFile: URL
        }

        /// System properties prepended to every invocation.
        ///
        /// Both JNI libraries are loaded from the code-signed copies inside the
        /// app bundle. Without these, their loaders extract unsigned copies into
        /// a temp directory at runtime, which Gatekeeper blocks as malware.
        private static func runtimeProperties(for layout: Layout) -> [String] {
            let native = layout.nativeLibraryDirectory.path
            return [
                // GraalVM's signal handling opens a named POSIX semaphore whose
                // name the App Sandbox will not permit, and the image aborts with
                // "CSunMiscSignal.open() failed" before it starts. Vela stops the
                // daemon by terminating the process, so it needs no handlers.
                "-XX:-EnableSignalHandling",
                "-Djava.library.path=\(native)",
                "-Dorg.sqlite.lib.path=\(native)",
                "-Dorg.sqlite.lib.name=libsqlitejdbc.dylib",
            ]
        }

        /// Resolves the embedded backend, or nil when this build has none.
        static func layout() -> Layout? {
            guard let resources = Bundle.main.resourceURL else { return nil }
            let executable = resources.appendingPathComponent("signal-cli/signal-cli")
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                return nil
            }

            let support = try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let root = (support ?? URL(fileURLWithPath: NSTemporaryDirectory()))
                .appendingPathComponent("Vela/signal-cli", isDirectory: true)

            // AF_UNIX paths are capped near 104 bytes. The container's
            // Application Support path is already ~105 bytes before a filename,
            // so the socket lives in the container's tmp directory (~79 bytes)
            // instead. It is recreated on every launch, so tmp is the right home
            // for it anyway.
            let socket = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("vela-rpc.sock")

            return Layout(
                executable: executable,
                nativeLibraryDirectory: resources.appendingPathComponent("signal-cli/lib/native"),
                configDirectory: root,
                socketPath: socket,
                logFile: root.appendingPathComponent("daemon.log")
            )
        }

        /// Starts the backend without waiting for it to exit. Used for the
        /// long-lived daemon; the caller owns the returned process.
        static func launch(arguments: [String]) throws -> Process {
            guard let layout = layout() else { throw BackendError.notEmbedded }
            try FileManager.default.createDirectory(
                at: layout.configDirectory,
                withIntermediateDirectories: true
            )

            let process = Process()
            process.executableURL = layout.executable
            process.arguments = runtimeProperties(for: layout) + arguments

            // Written to a file rather than a pipe: nothing would drain a pipe
            // over the daemon's lifetime and a full buffer would wedge it. A
            // file also means a crash leaves evidence behind to diagnose.
            FileManager.default.createFile(atPath: layout.logFile.path, contents: nil)
            if let handle = try? FileHandle(forWritingTo: layout.logFile) {
                process.standardOutput = handle
                process.standardError = handle
            } else {
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
            }

            do {
                try process.run()
            } catch {
                throw BackendError.launchFailed(error.localizedDescription)
            }
            log.info("signal-cli daemon started (pid \(process.processIdentifier, privacy: .public))")
            return process
        }

        /// Runs the backend to completion and returns its trimmed stdout.
        /// Used for short commands such as `--version`; the daemon is long-lived
        /// and is managed separately.
        @discardableResult
        static func run(arguments: [String], timeout: TimeInterval = 60) throws -> String {
            guard let layout = layout() else { throw BackendError.notEmbedded }
            try FileManager.default.createDirectory(
                at: layout.configDirectory,
                withIntermediateDirectories: true
            )

            let process = Process()
            process.executableURL = layout.executable
            process.arguments = runtimeProperties(for: layout) + arguments

            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err

            do {
                try process.run()
            } catch {
                throw BackendError.launchFailed(error.localizedDescription)
            }

            // Read before waiting so a chatty child cannot fill the pipe buffer
            // and deadlock against waitUntilExit.
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let stdout = String(decoding: outData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let stderr = String(decoding: errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard process.terminationStatus == 0 else {
                throw BackendError.exited(code: process.terminationStatus, message: stderr)
            }
            return stdout
        }

        /// Deletes signal-cli's account state so the next launch shows a QR code.
        ///
        /// This only clears local state. The device remains listed under Linked
        /// Devices on the phone until it is removed there, so the caller should
        /// say so rather than implying a full revoke.
        static func eraseAccountData() throws {
            guard let layout = layout() else { throw BackendError.notEmbedded }
            try eraseAccountData(
                layout: layout,
                applicationSupportRoot: layout.configDirectory.deletingLastPathComponent()
            )
        }

        /// Deletes every account-derived file outside Vela's open database.
        ///
        /// Cleanup attempts every path before returning an error, making a retry
        /// useful after a partial filesystem failure. The database directory is
        /// deliberately excluded: SQLCipher owns an open handle while the app is
        /// running, so deleting its file or key here would make a same-session
        /// relink unrecoverable on next launch.
        static func eraseAccountData(layout: Layout?, applicationSupportRoot: URL) throws {
            let candidates: [(String, URL?)] = [
                ("signal-cli state", layout?.configDirectory),
                ("contact avatars", applicationSupportRoot.appendingPathComponent("avatars", isDirectory: true)),
                ("attachments", applicationSupportRoot.appendingPathComponent("attachments", isDirectory: true)),
                ("diagnostics", applicationSupportRoot.appendingPathComponent("diagnostics", isDirectory: true)),
                ("backend socket", layout?.socketPath),
            ]
            let targets: [(String, URL)] = candidates.compactMap { label, url in
                url.map { (label, $0) }
            }

            let manager = FileManager.default
            var failures: [String] = []
            for (label, url) in targets {
                guard manager.fileExists(atPath: url.path) else { continue }
                do {
                    try manager.removeItem(at: url)
                } catch {
                    failures.append(label)
                }
            }

            guard failures.isEmpty else {
                throw BackendError.cleanupFailed(failures)
            }
            log.info("signal-cli account data erased")
        }

        /// Confirms the embedded backend can actually execute under the sandbox.
        /// Returns the reported version string.
        static func probeVersion() throws -> String {
            let version = try run(arguments: ["--version"])
            log.info("signal-cli backend available: \(version, privacy: .public)")
            return version
        }
    }
#endif
