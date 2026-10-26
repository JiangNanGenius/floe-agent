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
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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

    /// The guest runner documents a 1-second minimum for a real finite
    /// deadline (`LinuxGuestLimits.executionDeadline`, LinuxGuestService.swift):
    /// reporting that real floor here keeps the exec.shell receipt honest
    /// about the deadline the command actually received. `.unlimited` stays
    /// `.unlimited` — the EXEC wire payload carries no duration field, so the
    /// pinned guest runner needs no change and no cap ever stands in for the
    /// policy default.
    public func normalizedRunDeadline(_ requested: ShellExecutionDeadline) -> ShellExecutionDeadline {
        limits.executionDeadline(requested)
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
        let deadline = limits.executionDeadline(request.deadline)
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
            let workingDirectory = try Self.guestWorkingDirectory(cwd: request.cwd, root: request.rootURL)
            let result: LinuxCommandResult
            let stdinBytes = request.stdin?.utf8.count ?? 0
            let directCommandBytes = Self.framedPayloadBytes(
                workingDirectory: workingDirectory,
                standardInput: nil,
                argv: ["/bin/sh", "-c", command]
            )
            let directEnvelopeBytes = directCommandBytes + 4 + stdinBytes
            if directCommandBytes <= limits.maxCommandBytes, directEnvelopeBytes <= limits.maxEnvelopeBytes {
                // Small commands travel exactly as before: one inline/chunked
                // EXEC whose argv carries the assembled script text.
                result = try await runner.run(
                    environmentID: environmentID,
                    argv: ["/bin/sh", "-c", command],
                    workingDirectory: workingDirectory,
                    standardInput: request.stdin,
                    deadline: deadline,
                    maxOutputBytes: maxOutput,
                    cancellation: cancellation
                )
            } else {
                // Large script bodies are staged as a file in THIS task's
                // workspace share (streamed, bounded memory, exclusive
                // creation) and executed through a tiny `.` wrapper inside
                // the same -c form, so the command text is still guest
                // /bin/sh code, never an argv blob, stdin stays an
                // independent channel, and the guest's own exec never
                // approaches ARG_MAX. cwd, exit status, timeout budget and
                // cancellation semantics are unchanged; the staged file is
                // removed on every path.
                result = try await Self.runStaged(
                    command: command,
                    runner: runner,
                    environmentID: environmentID,
                    request: request,
                    workingDirectory: workingDirectory,
                    started: started,
                    deadline: deadline,
                    maxOutputBytes: maxOutput,
                    limits: limits,
                    cancellation: cancellation
                )
            }
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

// MARK: - Large-script staging transport
//
// `exec.shell` has no application-level command-size ceiling: a script body
// is a file, not an argv blob. Commands whose assembled EXEC envelope would
// exceed the guest command budget are staged into THIS task's workspace
// share (the same host directory the guest already mounts at /workspace) and
// executed through a tiny `/bin/sh -c ". '<staged>'"` wrapper:
//   * the command text still runs as guest /bin/sh code, so pipelines,
//     redirections, loops and the env preamble keep working verbatim;
//   * stdin stays an independent channel: the EXEC stdin field is still
//     piped to the child by the runner (`feed_stdin`), so script size and
//     stdin size never share a budget;
//   * the guest `execvp` never approaches ARG_MAX, and the reassembled
//     console envelope stays inside the runner's fixed 256 KiB MAX_PAYLOAD
//     (a protocol-safety bound the host never tries to raise);
//   * exit code, working directory, timeout budget, interrupt/cancellation
//     and the poisoned-channel semantics are exactly the single-EXEC
//     semantics from before — only where the script bytes live changed.
//
// Staging is reached ONLY through directory descriptors opened from the
// trusted workspace root: nothing is written, replaced or deleted through a
// re-resolved parent path, so a writable guest share cannot redirect this
// code with a racing symlink. Every invocation gets a fresh random name
// (run identity is recorded only as metadata), entries are created with
// `openat(O_CREAT|O_EXCL)` and cleanup unlinks ONLY the exact inode this
// operation created; a failed exclusive create never touches the
// pre-existing entry. There is deliberately no stale-file sweep: UUID-shaped
// names or a producer string in a model-writable marker are not proof of
// ownership. Crash leftovers are inert hidden files inside the task
// workspace and leave with the task workspace itself.
extension LinuxGuestShellBackend {
    /// Workspace-relative staging entrypoint. A dot-name keeps it out of
    /// ordinary workspace listings while staying inside the task's own
    /// share, so another task's workspace root can never contain these paths.
    static let stagingDirectoryName = ".floe-shell"
    /// Durable marker written (exclusively) before each script. It records
    /// run correlation for operators and app-side lifecycle cleanup; cleanup
    /// in this module never trusts the marker for ownership — it trusts the
    /// inode this exact operation created.
    static let stagingMarkerSuffix = ".floe-staged"
    /// Bounded write window: the script streams through host memory 64 KiB
    /// at a time regardless of total script size.
    static let stagingChunkBytes = 64 * 1_024

    struct StagedScript {
        var rootFD: Int32
        var directoryFD: Int32
        var directoryName: String
        var scriptName: String
        var scriptInode: UInt64
        var markerName: String
        var markerInode: UInt64
        var guestPath: String
    }

    /// Exact size of one EXEC/OPEN reassembled envelope: u32 field count,
    /// then u32 length + raw bytes per field, in the framing order
    /// [cwd, stdin, argv...]. Computed from the strings without building a
    /// copy of the payload, so a multi-megabyte script never allocates a
    /// second full buffer just to measure it.
    static func framedPayloadBytes(
        workingDirectory: String?,
        standardInput: String?,
        argv: [String]
    ) -> Int {
        var total = 4
        total += 4 + (workingDirectory?.utf8.count ?? 0)
        total += 4 + (standardInput?.utf8.count ?? 0)
        for field in argv { total += 4 + field.utf8.count }
        return total
    }

    static func runStaged(
        command: String,
        runner: any LinuxCommandRunning,
        environmentID: String,
        request: ShellRunRequest,
        workingDirectory: String,
        started: Date,
        deadline: ShellExecutionDeadline,
        maxOutputBytes: Int,
        limits: LinuxGuestLimits,
        cancellation: CancellationToken?
    ) async throws -> LinuxCommandResult {
        let staged = try stageScript(
            command,
            root: request.rootURL,
            runID: request.runID,
            cancellation: cancellation
        )
        defer { closeStaged(staged) }
        let wrapper = ". '" + staged.guestPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let envelopeBytes = framedPayloadBytes(
            workingDirectory: workingDirectory,
            standardInput: request.stdin,
            argv: ["/bin/sh", "-c", wrapper]
        )
        guard envelopeBytes <= limits.maxEnvelopeBytes else {
            // The wrapper is tiny: this can only be the stdin field. Name
            // the actual bound precisely — it is the guest reassembly
            // envelope, not a script or file-size limit.
            throw LinuxGuestError.invalidConfiguration(
                "stdin plus framing exceeds the \(limits.maxEnvelopeBytes)-byte guest envelope; script size is unlimited on the staged path, stdin is capped by this envelope and by the tool's stdin policy"
            )
        }
        if cancellation?.isCancelled == true { throw FloeError.cancelled }
        // A finite deadline shares the run's single wall-clock budget: the
        // host staging write already consumed part of it, so the guest gets
        // what is left and never a fresh full deadline. A budget exhausted
        // before the guest could start is a real deadline, not a started
        // command that timed out with empty output. An UNLIMITED deadline
        // has no budget to consume: staging time is not execution time and
        // the guest execution stays unlimited.
        let guestDeadline: ShellExecutionDeadline
        switch deadline {
        case .unlimited:
            guestDeadline = .unlimited
        case .seconds(let total):
            let remaining = total - Date().timeIntervalSince(started)
            // The guest channel's own floor is one second, so a smaller
            // leftover budget could not be honoured: report the deadline
            // instead of starting a command that is allowed to outlive it.
            guard remaining >= 1 else {
                throw LinuxGuestError.timedOut(seconds: total)
            }
            guestDeadline = .seconds(remaining)
        }
        return try await runner.run(
            environmentID: environmentID,
            argv: ["/bin/sh", "-c", wrapper],
            workingDirectory: workingDirectory,
            standardInput: request.stdin,
            deadline: guestDeadline,
            maxOutputBytes: maxOutputBytes,
            cancellation: cancellation
        )
    }

    /// Creates `<workspace>/.floe-shell/<random UUID>.sh` plus its marker
    /// through directory descriptors opened from the trusted workspace root.
    /// Every entry name is fresh per invocation; a pre-existing name is never
    /// adopted, and a failure to create exclusively deletes nothing.
    static func stageScript(
        _ command: String,
        root: URL,
        runID: UUID?,
        cancellation: CancellationToken?
    ) throws -> StagedScript {
        if cancellation?.isCancelled == true { throw FloeError.cancelled }
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let rootFD = open(rootPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else {
            throw LinuxGuestError.invalidConfiguration(
                "the task workspace is unavailable for large-script staging"
            )
        }
        var directoryFD = openat(
            rootFD,
            stagingDirectoryName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        if directoryFD < 0, errno == ENOENT {
            // Another command may create the shared directory after our
            // first open. Reopen it with O_NOFOLLOW in either case.
            guard mkdirat(rootFD, stagingDirectoryName, mode_t(0o700)) == 0 || errno == EEXIST else {
                close(rootFD)
                throw LinuxGuestError.invalidConfiguration(
                    "the task workspace share is not writable, so a large script could not be staged"
                )
            }
            directoryFD = openat(
                rootFD,
                stagingDirectoryName,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard directoryFD >= 0 else {
            close(rootFD)
            throw LinuxGuestError.invalidConfiguration(
                "workspace staging entrypoint '\(stagingDirectoryName)' is not a plain directory (alias or file present); nothing was executed and nothing was deleted there"
            )
        }
        do {
            let stem = UUID().uuidString.lowercased()
            let markerName = stem + stagingMarkerSuffix
            let scriptName = stem + ".sh"
            let markerPayload = try JSONEncoder().encode([
                "producer": "exec.shell",
                "run": runID?.uuidString ?? "unbound",
                "createdAt": String(Int(Date().timeIntervalSince1970)),
            ])
            let markerInode = try writeNewFile(
                directoryFD: directoryFD,
                name: markerName,
                data: markerPayload,
                cancellation: cancellation
            )
            let scriptInode: UInt64
            do {
                scriptInode = try writeNewScript(
                    directoryFD: directoryFD,
                    name: scriptName,
                    text: command,
                    cancellation: cancellation
                )
            } catch {
                // Only the marker this operation created is removed; the
                // failed script create never had an inode to own.
                unlinkOwned(directoryFD: directoryFD, name: markerName, inode: markerInode)
                throw error
            }
            return StagedScript(
                rootFD: rootFD,
                directoryFD: directoryFD,
                directoryName: stagingDirectoryName,
                scriptName: scriptName,
                scriptInode: scriptInode,
                markerName: markerName,
                markerInode: markerInode,
                guestPath: LinuxGuestMountPoint.workspace + "/" + stagingDirectoryName + "/" + scriptName
            )
        } catch {
            close(directoryFD)
            close(rootFD)
            throw error
        }
    }

    /// Removes only this invocation's inode-guarded entries. The empty
    /// service directory remains stable: a concurrent invocation can already
    /// hold its descriptor before creating files, so removing even an empty
    /// directory here would detach that invocation from the guest mount.
    static func closeStaged(_ staged: StagedScript) {
        unlinkOwned(directoryFD: staged.directoryFD, name: staged.scriptName, inode: staged.scriptInode)
        unlinkOwned(directoryFD: staged.directoryFD, name: staged.markerName, inode: staged.markerInode)
        close(staged.directoryFD)
        close(staged.rootFD)
    }

    /// Unlinks `name` only when it is still the plain regular file with the
    /// inode number this operation created. Never follows a symlink and
    /// never removes a substituted file.
    private static func unlinkOwned(directoryFD: Int32, name: String, inode: UInt64) {
        var info = stat()
        guard fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              UInt64(info.st_ino) == inode else { return }
        _ = unlinkat(directoryFD, name, 0)
    }

    /// Exclusive create of one staging entry, returning the open descriptor
    /// and the inode this operation now owns.
    private static func createExclusive(
        directoryFD: Int32,
        name: String
    ) throws -> (fd: Int32, inode: UInt64) {
        let fd = openat(
            directoryFD,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard fd >= 0 else {
            throw LinuxGuestError.invalidConfiguration(
                "staging entry '\(name)' could not be created exclusively; refusing to adopt a pre-existing entry"
            )
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            close(fd)
            throw LinuxGuestError.invalidConfiguration("staging entry '\(name)' is not a plain file")
        }
        return (fd, UInt64(info.st_ino))
    }

    /// Bounded, cancellation-checked write of one byte run to an open
    /// descriptor. `EINTR` is retried; a zero-byte write is a failure, never
    /// an assumed completion.
    private static func writeAll(
        fd: Int32,
        base: UnsafePointer<UInt8>,
        count: Int,
        cancellation: CancellationToken?
    ) throws {
        var offset = 0
        while offset < count {
            if cancellation?.isCancelled == true { throw FloeError.cancelled }
            let written = write(fd, base.advanced(by: offset), count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                throw LinuxGuestError.invalidConfiguration("staging write failed")
            }
            guard written > 0 else {
                throw LinuxGuestError.invalidConfiguration("staging write stalled")
            }
            offset += written
        }
    }

    private static func writeNewFile(
        directoryFD: Int32,
        name: String,
        data: Data,
        cancellation: CancellationToken?
    ) throws -> UInt64 {
        let created = try createExclusive(directoryFD: directoryFD, name: name)
        do {
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                try writeAll(
                    fd: created.fd,
                    base: base,
                    count: data.count,
                    cancellation: cancellation
                )
            }
        } catch {
            close(created.fd)
            unlinkOwned(directoryFD: directoryFD, name: name, inode: created.inode)
            throw error
        }
        _ = fsync(created.fd)
        close(created.fd)
        return created.inode
    }

    /// Streams arbitrary-length script text through a fixed-size window: no
    /// path ever holds more than one 64 KiB chunk in addition to the caller's
    /// own string.
    private static func writeNewScript(
        directoryFD: Int32,
        name: String,
        text: String,
        cancellation: CancellationToken?
    ) throws -> UInt64 {
        let created = try createExclusive(directoryFD: directoryFD, name: name)
        do {
            var index = text.utf8.startIndex
            let view = text.utf8
            while index < view.endIndex {
                if cancellation?.isCancelled == true { throw FloeError.cancelled }
                let next = view.index(
                    index,
                    offsetBy: stagingChunkBytes,
                    limitedBy: view.endIndex
                ) ?? view.endIndex
                let chunk = Array(view[index..<next])
                try chunk.withUnsafeBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return }
                    try writeAll(
                        fd: created.fd,
                        base: base,
                        count: chunk.count,
                        cancellation: cancellation
                    )
                }
                index = next
            }
        } catch {
            close(created.fd)
            unlinkOwned(directoryFD: directoryFD, name: name, inode: created.inode)
            throw error
        }
        _ = fsync(created.fd)
        close(created.fd)
        return created.inode
    }
}
