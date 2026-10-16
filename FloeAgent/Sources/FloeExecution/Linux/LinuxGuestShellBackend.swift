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
// signal maps to guest SIGINT/TERM/KILL and close tears the PTY down.
// Resize forwards the visible terminal geometry to the guest PTY.

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
            // The environment's shared Python venv and Node prefix come first
            // on PATH when they exist, so `python3`/`pip`/`node` in a shell
            // command resolve to the same interpreter, environment-level
            // modules and package directories as exec.localPython, npm/pnpm
            // and the package UI. The preamble is a guarded no-op before the
            // first use and never renames the commands.
            //
            // The per-run environment (`exec.shell` env argument) is exported
            // inside the command itself: the console protocol carries no env
            // field, and silently dropping a documented parameter would make
            // two clients with different env values see the same environment.
            // Validation already constrained the names/values; quoting here
            // keeps values verbatim.
            let environmentPreamble = try Self.environmentPreamble(request.environment)
            let command = LinuxGuestPythonEnvironment.activationPreamble()
                + LinuxGuestNodeEnvironment.activationPreamble()
                + environmentPreamble
                + request.command
            let result = try await runner.run(
                environmentID: environmentID,
                argv: ["/bin/sh", "-c", command],
                workingDirectory: try Self.guestWorkingDirectory(cwd: request.cwd, root: request.rootURL),
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
        } catch let error as LinuxGuestCommandTimeout {
            let truncation = error.outputTruncated ? "\n[output truncated]" : ""
            return .timedOut(partialStdout: error.partialStdout,
                partialStderr: error.partialStderr + truncation,
                durationMs: Int(error.seconds * 1000))
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
        // Interactive shells enter the environment's shared Python venv and
        // Node prefix as well (guarded no-ops when they do not exist yet), so
        // a terminal `python3`/`pip`/`node` matches the package entries. The
        // per-run environment is exported in the same command string for the
        // same reason as the one-shot path: the protocol has no env field and
        // a dropped env would silently ignore the caller's contract.
        let preamble = LinuxGuestPythonEnvironment.activationPreamble()
            + LinuxGuestNodeEnvironment.activationPreamble()
            + (try Self.environmentPreamble(request.environment))
        let argv = command.isEmpty
            ? ["/bin/sh", "-c", preamble + "export TERM=xterm-256color; stty sane 2>/dev/null; if command -v bash >/dev/null 2>&1; then exec bash --noprofile --norc -i; else exec /bin/sh -i; fi"]
            : ["/bin/sh", "-c", preamble + command]
        // A relative cwd is relative to the pinned workspace, never the
        // runner process (usually /). Session framing does not map paths.
        let workingDirectory = try Self.guestWorkingDirectory(cwd: request.cwd, root: request.rootURL)
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

    static func guestWorkingDirectory(cwd: String, root: URL) throws -> String {
        let directory = try ShellInputValidation.directory(cwd: cwd.isEmpty ? "." : cwd, root: root)
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        return LinuxGuestMountPoint.workspace + String(directory.path.dropFirst(rootPath.count))
    }

    /// One `export NAME='value';` statement per run-scoped variable, or an
    /// empty string. The console protocol carries no environment field, so
    /// the variables are exported at the top of the command's own script —
    /// each guest command runs in its own shell, so nothing leaks between
    /// clients or into later commands. Names are the validated POSIX subset
    /// (`ShellInputValidation`); values are single-quoted verbatim so `$`,
    /// spaces, quotes and backticks cannot change the command's meaning.
    static func environmentPreamble(_ environment: [String: String]) throws -> String {
        guard !environment.isEmpty else { return "" }
        var statements: [String] = []
        statements.reserveCapacity(environment.count)
        for (name, value) in environment.sorted(by: { $0.key < $1.key }) {
            guard name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil,
                  !value.contains("\u{0}") else {
                throw LinuxGuestError.invalidConfiguration(
                    "environment variable '\(name)' is not a POSIX name/value this backend can export"
                )
            }
            let quoted = "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
            statements.append("export \(name)=\(quoted);")
        }
        return statements.joined(separator: " ") + " "
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
            failure: read.info.failure,
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
