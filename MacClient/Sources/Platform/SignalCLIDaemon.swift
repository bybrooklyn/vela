#if os(macOS)
    import Foundation
    import VelaSignalCLI
    import os

    /// Owns the long-lived `signal-cli daemon` child process and the JSON-RPC
    /// connection to it.
    ///
    /// The daemon is started before the account exists — linking itself happens
    /// over this connection via `startLink`/`finishLink` — so it must come up
    /// cleanly with zero configured accounts.
    @MainActor
    final class SignalCLIDaemon {
        private static let log = Logger(subsystem: "works.deadsignal.vela", category: "signal-cli-daemon")

        enum State: Equatable {
            case stopped
            case starting
            case running
            case failed(reason: String)
        }

        private(set) var state: State = .stopped
        let rpc = JSONRPCClient()

        private var process: Process?
        private var disconnectTask: Task<Void, Never>?

        /// Launches the daemon and connects once its socket accepts.
        func start() async throws {
            guard state != .running, state != .starting else { return }
            guard let layout = SignalCLIBackend.layout() else {
                state = .failed(reason: "The signal-cli backend is not embedded in this build.")
                throw SignalCLIBackend.BackendError.notEmbedded
            }
            state = .starting

            // `stop()` is synchronous for AppKit termination hooks, so its RPC
            // close runs in a task. A restart must join that close before opening
            // a new socket or the stale task can disconnect the new daemon.
            if let disconnectTask {
                await disconnectTask.value
                self.disconnectTask = nil
            } else {
                await rpc.disconnect()
            }

            // A socket left behind by a crashed daemon would make us connect to
            // nothing, so clear it before starting.
            try? FileManager.default.removeItem(at: layout.socketPath)

            let daemon = try SignalCLIBackend.launch(arguments: [
                "--config", layout.configDirectory.path,
                "daemon",
                "--socket", layout.socketPath.path,
                // Deliberately not `on-start`: that receives and acknowledges
                // messages from Signal even with no JSON-RPC client attached, so
                // anything arriving before Vela connects is consumed and never
                // delivered. `on-connection` ties receiving to our connection, so
                // messages stay queued server-side until we can store them.
                "--receive-mode", "on-connection",
                "--ignore-stories",
            ])
            process = daemon
            daemon.terminationHandler = { [weak self] finished in
                Task { @MainActor in
                    self?.handleTermination(process: finished, status: finished.terminationStatus)
                }
            }

            do {
                try await connectWhenReady(socketPath: layout.socketPath.path, process: daemon)
                state = .running
                Self.log.info("signal-cli daemon ready")
            } catch {
                stop()
                let reason = error.localizedDescription
                state = .failed(reason: reason)
                throw error
            }
        }

        func stop() {
            let stoppedProcess = process
            process = nil
            state = .stopped
            disconnectTask?.cancel()
            disconnectTask = Task { await rpc.disconnect() }
            if let stoppedProcess, stoppedProcess.isRunning {
                stoppedProcess.terminate()
            }
        }

        /// The daemon needs a few seconds to boot the JVM before its socket
        /// exists, so connection is retried until it accepts or the process dies.
        private func connectWhenReady(socketPath: String, process: Process) async throws {
            let deadline = ContinuousClock.now + .seconds(45)
            var lastError: (any Error)?

            while ContinuousClock.now < deadline {
                if !process.isRunning {
                    throw SignalCLIBackend.BackendError.exited(
                        code: process.terminationStatus,
                        message: Self.recentLog() ?? "the daemon exited before its socket was ready"
                    )
                }
                if FileManager.default.fileExists(atPath: socketPath) {
                    do {
                        try await rpc.connect(socketPath: socketPath)
                        return
                    } catch {
                        lastError = error
                    }
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            throw lastError
                ?? SignalCLIBackend.BackendError.launchFailed("timed out waiting for the daemon socket")
        }

        /// The last few lines the daemon wrote before dying, so a failure is
        /// diagnosable from the log and from Settings.
        private static func recentLog() -> String? {
            guard
                let layout = SignalCLIBackend.layout(),
                let contents = try? String(contentsOf: layout.logFile, encoding: .utf8)
            else { return nil }
            let lines = contents.split(separator: "\n").suffix(5)
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }

        private func handleTermination(process finishedProcess: Process, status: Int32) {
            // Ignore a process deliberately stopped before a replacement began.
            // Identity, unlike a shared boolean, cannot be reset by the restart.
            guard process === finishedProcess else { return }
            let detail = Self.recentLog() ?? "no output"
            Self.log.error(
                "signal-cli daemon exited unexpectedly (status \(status, privacy: .public)): \(detail, privacy: .public)"
            )
            process = nil
            state = .failed(reason: "The Signal backend stopped unexpectedly (status \(status)).")
            disconnectTask?.cancel()
            disconnectTask = Task { await rpc.disconnect() }
        }
    }
#endif
