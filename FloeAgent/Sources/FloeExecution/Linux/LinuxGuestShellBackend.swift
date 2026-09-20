// FloeExecution — Linux guest shell backend.
//
// exec.shell in a Floe Linux environment runs inside the environment's
// guest, on the same interpreter/channel that serves apt/dpkg, localPython
// and localService. The shell command string is handed to the guest's own
// /bin/sh unchanged (no host re-parsing, no native callback interception);
// the host only frames argv for the console channel.
//
// Interactive terminal sessions run in the guest over the console's PTY
// session frames (protocol v2): openSession starts /bin/sh (or the requested
// command) inside the guest, exchangeSession streams raw terminal bytes,
// signal maps to guest SIGINT/TERM/KILL and close tears the PTY down. Resize
// is best-effort: the console has no window-size channel yet, so the guest
// keeps its initial geometry and resize is a documented no-op.

import Foundation
import FloeCore
import FloeTools

public struct LinuxGuestShellBackend: LocalShellBackend {
    private let runner: any LinuxCommandRunning
    private let sessions: (any LinuxGuestControlling)?
    private let limits: LinuxGuestLimits

    public init(
        runner: any LinuxCommandRunning,
        sessions: (any LinuxGuestControlling)? = nil,
        limits: LinuxGuestLimits = .standard
    ) {
        self.runner = runner
        self.sessions = sessions ?? (runner as? any LinuxGuestControlling)
        self.limits = limits
    }

    public func run(_ request: ShellRunRequest, cancellation: CancellationToken?) async -> ShellRunOutcome {
        guard let environmentID = request.toolEnvironment?.id else {
            return .failed(message: "Linux shell execution requires an environment id")
        }
        guard await runner.supports(environmentID: environmentID) else {
            guard await runner.ownsLinuxEnvironment(environmentID: environmentID) else {
                return .failed(message: LinuxGuestError.notOwned(environmentID: environmentID).localizedDescription)
            }
            return .failed(message: LinuxGuestError.notRunning(environmentID: environmentID).localizedDescription)
        }

        let started = Date()
        let timeout = limits.clampedTimeout(request.timeout)
        let maxOutput = limits.clampedOutputBytes(request.maxOutputBytes)
        do {
            // The environment's shared Python venv comes first on PATH when it
            // exists, so `python3`/`pip` in a shell command are the same
            // interpreter and site-packages as exec.localPython and the
            // managed installer. The preamble is a guarded no-op before the
            // first Python use and never renames the commands.
            let command = LinuxGuestPythonEnvironment.activationPreamble() + request.command
            let result = try await runner.run(
                environmentID: environmentID,
                argv: ["/bin/sh", "-c", command],
                workingDirectory: request.cwd,
                standardInput: request.stdin,
                timeout: timeout,
                maxOutputBytes: maxOutput,
                cancellation: cancellation
            )
            let durationMs = Int(Date().timeIntervalSince(started) * 1000)
            return .exited(
                code: result.exitCode,
                stdout: result.stdout,
                stderr: result.stderr,
                truncated: false,
                stderrTruncated: false,
                durationMs: durationMs
            )
        } catch FloeError.cancelled {
            return .cancelled
        } catch let error as LinuxGuestError {
            if case .timedOut(let seconds) = error {
                return .timedOut(partialStdout: "", partialStderr: "", durationMs: Int(seconds * 1000))
            }
            return .failed(message: error.localizedDescription)
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    public func openSession(_ request: ShellOpenRequest, cancellation: CancellationToken?) async throws -> ShellOpenResult {
        guard let environmentID = request.toolEnvironment?.id else {
            throw LinuxGuestError.notOwned(environmentID: "shell session")
        }
        guard let sessions else {
            throw LinuxGuestError.consoleUnavailable("this Linux backend has no session support")
        }
        guard await runner.supports(environmentID: environmentID) else {
            throw LinuxGuestError.notRunning(environmentID: environmentID)
        }
        let command = request.command.trimmingCharacters(in: .whitespacesAndNewlines)
        // Interactive shells enter the environment's shared Python venv as
        // well (guarded no-op when it does not exist yet), so a terminal
        // `python3`/`pip` matches exec.localPython.
        let preamble = LinuxGuestPythonEnvironment.activationPreamble()
        let argv = command.isEmpty
            ? ["/bin/sh", "-c", preamble + "exec /bin/sh -i"]
            : ["/bin/sh", "-c", preamble + command]
        let workingDirectory = request.cwd.isEmpty ? nil : request.cwd
        try await sessions.openSession(
            environmentID: environmentID,
            sessionID: request.sessionID,
            argv: argv,
            workingDirectory: workingDirectory,
            columns: request.columns,
            rows: request.rows
        )
        // Give the shell a moment to draw its first prompt.
        let first = await sessions.readSession(sessionID: request.sessionID, maxBytes: 16 * 1024, waitMs: 400)
        let output = first?.output ?? Data()
        let alive = first?.info.alive ?? true
        return ShellOpenResult(
            sessionID: request.sessionID,
            initialOutput: String(decoding: output, as: UTF8.self),
            alive: alive,
            terminalOutput: output
        )
    }

    public func exchangeSession(_ request: ShellExchangeRequest, cancellation: CancellationToken?) async throws -> ShellExchangeResult {
        guard let sessions else {
            throw LinuxGuestError.consoleUnavailable("this Linux backend has no session support")
        }
        if let input = request.input, !input.isEmpty {
            try await sessions.writeSession(sessionID: request.sessionID, text: input)
        }
        guard let read = await sessions.readSession(
            sessionID: request.sessionID,
            maxBytes: max(1, request.maxBytes),
            waitMs: max(0, request.waitMs)
        ) else {
            throw LinuxGuestError.notRunning(environmentID: "session \(request.sessionID)")
        }
        return ShellExchangeResult(
            output: String(decoding: read.output, as: UTF8.self),
            alive: read.info.alive,
            exitCode: read.info.alive ? nil : read.info.exitCode,
            terminalOutput: read.output,
            bytesRead: read.output.count,
            bytesWritten: request.input?.utf8.count ?? 0
        )
    }

    public func closeSession(sessionID: String) async {
        await sessions?.closeSession(sessionID: sessionID)
    }

    public func signalSession(sessionID: String, signal: ShellSignal) async {
        let mapped: LinuxGuestSessionSignal
        switch signal {
        case .interrupt: mapped = .interrupt
        case .terminate: mapped = .terminate
        case .kill: mapped = .kill
        }
        await sessions?.signalSession(sessionID: sessionID, signal: mapped)
    }

    /// Resize rides the agreed FLOE-SIGNAL WINCH frame with the new
    /// geometry, so a guest PTY does resize instead of silently keeping the
    /// openSession size.
    public func resizeSession(sessionID: String, columns: Int, rows: Int) async {
        await sessions?.resizeSession(sessionID: sessionID, columns: columns, rows: rows)
    }
}
