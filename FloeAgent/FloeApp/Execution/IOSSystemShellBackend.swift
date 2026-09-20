import Foundation
import Darwin
import FloeCore
import FloeExecution
import FloeTools

final class IOSSystemShellBackend: LocalShellBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: SessionIO] = [:]

    func run(_ request: ShellRunRequest, cancellation: CancellationToken?) async -> ShellRunOutcome {
        guard FloeShellEngineAvailable() else { return .failed(message: "Local shell engine is unavailable") }
        let directory: URL
        do { directory = try ShellInputValidation.directory(cwd: request.cwd, root: request.rootURL) }
        catch { return .failed(message: String(describing: error)) }
        if cancellation?.isCancelled == true { return .cancelled }
        FloeShellCommandRegistry.shared.bind(sessionID: request.sessionID, rootURL: request.rootURL, runID: request.runID, cancellation: cancellation, environment: request.toolEnvironment)
        defer { FloeShellCommandRegistry.shared.unbind(sessionID: request.sessionID) }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.runBlocking(request, directory: directory, cancellation: cancellation))
            }
        }
    }

    private static func runBlocking(_ request: ShellRunRequest, directory: URL, cancellation: CancellationToken?) -> ShellRunOutcome {
            let started = DispatchTime.now().uptimeNanoseconds
            var stdout: NSString?, stderr: NSString?
            var code: Int32 = 125
            let escaped = request.command.replacingOccurrences(of: "'", with: "'\\''")
            let command = "dash -c '\(escaped)'"
            let status = FloeShellRunCommand(command, request.rootURL.path, directory.path, request.sessionID, (request.toolEnvironment?.variables ?? [:]).merging(request.environment) { _, user in user }, request.stdin.map { Data($0.utf8) }, request.timeout, request.gateTimeout, UInt(max(1, request.maxOutputBytes)), { cancellation?.isCancelled == true }, &stdout, &stderr, &code)
            let duration = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            let out = stdout as String? ?? "", err = stderr as String? ?? ""
            if cancellation?.isCancelled == true { return .cancelled }
            switch status {
            case .OK: return .exited(code: code, stdout: out, stderr: err, truncated: out.utf8.count >= request.maxOutputBytes, stderrTruncated: err.utf8.count >= request.maxOutputBytes, durationMs: duration)
            case .timedOut: return .timedOut(partialStdout: out, partialStderr: err, durationMs: duration)
            case .cancelled: return .cancelled
            case .busy:
                // Nothing of this command ran. Say exactly why the engine
                // could not take it: a quarantined worker (one that ignored
                // cancellation and is still stopping) keeps the gate until it
                // actually stops, unlike a merely busy one.
                let diagnostics = FloeShellRunGateDiagnostics()
                var reason = "The local shell engine is busy; nothing was started (exit 75). " + diagnostics
                if !diagnostics.contains("quarantineOwner=none") {
                    reason += " A previous command ignored cancellation and is still stopping; the engine stays locked until it actually stops, then retries succeed. If it never stops, close the app to reset the engine."
                }
                return .notStarted(reason: reason)
            default: return .failed(message: "Local shell could not start")
            }
    }

    func openSession(_ request: ShellOpenRequest, cancellation: CancellationToken?) async throws -> ShellOpenResult {
        try cancellation?.throwIfCancelled()
        let directory = try ShellInputValidation.directory(cwd: request.cwd, root: request.rootURL)
        FloeShellCommandRegistry.shared.bind(sessionID: request.sessionID, rootURL: request.rootURL, runID: request.runID, cancellation: cancellation, environment: request.toolEnvironment, interactiveSession: true)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do { continuation.resume(returning: try openSessionBlocking(request, directory: directory, cancellation: cancellation)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func openSessionBlocking(_ request: ShellOpenRequest, directory: URL, cancellation: CancellationToken?) throws -> ShellOpenResult {
            var inputFD: Int32 = -1, outputFD: Int32 = -1
            var initial: NSString?
            let escaped = request.command.replacingOccurrences(of: "'", with: "'\\''")
            let body = request.command.isEmpty ? "dash -i" : "dash -c '\(escaped)'"
            let status = FloeShellOpenSession(body, request.rootURL.path, directory.path, request.sessionID, (request.toolEnvironment?.variables ?? [:]).merging(request.environment) { _, user in user }, request.columns, request.rows, request.gateTimeout, { cancellation?.isCancelled == true }, &inputFD, &outputFD, &initial)
            guard status == .OK, inputFD >= 0, outputFD >= 0 else {
                FloeShellCommandRegistry.shared.unbind(sessionID: request.sessionID)
                switch status {
                case .busy:
                    // The engine is owned by a running or stopping worker
                    // (one-shot command or another live session). Nothing was
                    // started; the interactive caller gets the same honest
                    // not-started style as exec.shell.
                    throw FloeError.validationFailed("The local shell engine is busy; the session never started. " + FloeShellRunGateDiagnostics())
                case .cancelled:
                    throw FloeError.cancelled
                default:
                    throw FloeError.internalError("The local shell could not open a session")
                }
            }
            if cancellation?.isCancelled == true {
                FloeShellCloseSession(request.sessionID)
                FloeShellCommandRegistry.shared.unbind(sessionID: request.sessionID)
                throw FloeError.cancelled
            }
            let text = initial as String? ?? ""
            guard FloeShellSessionAlive(request.sessionID) else {
                // The program exited during the bounded readiness window.
                // Return the drained output and let the session center close
                // the record; no pump is started for a dead process.
                FloeShellCloseSession(request.sessionID)
                FloeShellCommandRegistry.shared.unbind(sessionID: request.sessionID)
                return ShellOpenResult(sessionID: request.sessionID, initialOutput: text, alive: false, terminalOutput: Data(text.utf8))
            }
            // Claim ownership before constructing the pump: a concurrent close
            // or expiry may already have removed the record and closed these
            // descriptors, and SessionIO's fcntl/read on a recycled descriptor
            // number would corrupt an unrelated file. Only after a successful
            // claim does the pump own read/write and teardown.
            guard FloeShellClaimSessionDescriptors(request.sessionID) else {
                FloeShellCommandRegistry.shared.unbind(sessionID: request.sessionID)
                throw FloeError.cancelled
            }
            let io = SessionIO(id: request.sessionID, input: inputFD, output: outputFD)
            io.onFinish = { [weak self] id in
                guard let self else { return }
                _ = self.lock.withLock { self.sessions.removeValue(forKey: id) }
            }
            lock.withLock { sessions[request.sessionID] = io }
            io.start()
            return ShellOpenResult(sessionID: request.sessionID, initialOutput: text, alive: true, terminalOutput: Data(text.utf8))
    }

    func exchangeSession(_ request: ShellExchangeRequest, cancellation: CancellationToken?) async throws -> ShellExchangeResult {
        guard let io = lock.withLock({ sessions[request.sessionID] }) else { throw FloeError.notFound("Unknown shell session") }
        try cancellation?.throwIfCancelled()
        if request.input == "\u{4}" {
            // Ctrl-D over a pipe is a byte, not EOF: close the session's stdin
            // write end so the program observes a real end-of-file.
            try io.sendEOF()
        } else if let input = request.input {
            try io.enqueue(Data(input.utf8))
        }
        let deadline = Date().addingTimeInterval(Double(request.waitMs) / 1000)
        while !io.hasOutput && io.alive && Date() < deadline {
            try cancellation?.throwIfCancelled()
            try await Task.sleep(for: .milliseconds(20))
        }
        let result = io.drain(maxBytes: request.maxBytes)
        if !result.alive { _ = lock.withLock { sessions.removeValue(forKey: request.sessionID) } }
        return result
    }

    func closeSession(sessionID: String) async {
        let io = lock.withLock { sessions.removeValue(forKey: sessionID) }
        io?.close()
    }
    func signalSession(sessionID: String, signal: ShellSignal) async {
        FloeShellCommandRegistry.shared.cancelCurrent(sessionID: sessionID)
        FloeShellSignalSession(sessionID, signal == .interrupt ? SIGINT : SIGTERM)
    }
    func resizeSession(sessionID: String, columns: Int, rows: Int) async {
        FloeShellResizeSession(sessionID, columns, rows)
    }

    /// Continually drains output into a bounded ring even when no terminal is visible.
    private final class SessionIO: @unchecked Sendable {
        let id: String
        let input: Int32
        let output: Int32
        private let lock = NSLock()
        /// Wakes the pump promptly when input arrives or EOF/close is
        /// requested, so an exchange never reports bytesWritten=0 for input
        /// the pump simply has not flushed yet within its old 20 ms poll.
        private let wake = DispatchSemaphore(value: 0)
        private var buffered = Data()
        private var pendingInput = Data()
        private var finished = false
        private var closing = false
        private var inputClosed = false
        private var exitCode: Int32?
        private var bytesRead = 0
        private var bytesWritten = 0
        private var outputClosed = false
        /// Called once the pump has stopped and the descriptors are closed, so
        /// the backend can forget the finished session without a second owner.
        var onFinish: (@Sendable (String) -> Void)?
        var alive: Bool { lock.withLock { !finished && !closing } }
        var hasOutput: Bool { lock.withLock { !buffered.isEmpty } }
        init(id: String, input: Int32, output: Int32) {
            self.id = id; self.input = input; self.output = output
            _ = fcntl(input, F_SETFL, fcntl(input, F_GETFL, 0) | O_NONBLOCK)
            _ = fcntl(output, F_SETFL, fcntl(output, F_GETFL, 0) | O_NONBLOCK)
            _ = fcntl(input, F_SETNOSIGPIPE, 1)
        }
        func enqueue(_ data: Data) throws {
            lock.lock()
            defer { lock.unlock() }
            guard !closing && !finished else { throw FloeError.validationFailed("Terminal input is closed") }
            guard !inputClosed else { throw FloeError.validationFailed("Terminal stdin is closed (EOF was sent); open a new session for more input") }
            guard pendingInput.count + data.count <= 256 * 1024 else {
                throw FloeError.validationFailed("Terminal input queue is full")
            }
            pendingInput.append(data)
            wake.signal()
        }
        /// Closes the session's stdin write end once. The program observes a
        /// real EOF (read returns 0) instead of a stray Ctrl-D byte, which a
        /// pipe has no line discipline to translate.
        func sendEOF() throws {
            lock.lock()
            defer { lock.unlock() }
            guard !closing && !finished else { throw FloeError.validationFailed("Terminal input is closed") }
            guard !inputClosed else { return }
            inputClosed = true
            Darwin.close(input)
            wake.signal()
        }
        func start() {
            DispatchQueue.global(qos: .utility).async { [self] in
                while alive {
                    // Writes happen under the lock so EOF/close can never
                    // close the descriptor concurrently with a write, and so
                    // an exchange's enqueue is reflected in bytesWritten as
                    // soon as the pump has run once.
                    lock.lock()
                    if !pendingInput.isEmpty && !inputClosed {
                        let written = pendingInput.withUnsafeBytes { Darwin.write(input, $0.baseAddress, $0.count) }
                        if written > 0 {
                            pendingInput.removeFirst(written); bytesWritten += written
                        } else if written < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                            // The program stopped reading (EPIPE/EBADF): mark
                            // stdin closed but keep draining its output.
                            inputClosed = true
                            pendingInput.removeAll()
                        }
                    }
                    lock.unlock()
                    var chunk = [UInt8](repeating: 0, count: 16 * 1024)
                    let count = Darwin.read(output, &chunk, chunk.count)
                    if count > 0 {
                        lock.withLock {
                            buffered.append(contentsOf: chunk.prefix(count))
                            if buffered.count > 256 * 1024 { buffered = Data(buffered.suffix(256 * 1024)) }
                            bytesRead += count
                        }
                    } else if count == 0 { break }
                    else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { break }
                    if count <= 0 {
                        _ = wake.wait(timeout: .now() + 0.02)
                    }
                }
                var code: Int32 = 0
                let hasCode = FloeShellSessionExitCode(id, &code)
                lock.withLock {
                    finished = true
                    exitCode = hasCode ? code : nil
                    closeDescriptorsLocked()
                }
                // Descriptor teardown already happened in the pump thread, so
                // the bridge only forgets the record. Closing a descriptor
                // from another thread while this pump reads it can hand back a
                // recycled descriptor and corrupt unrelated files.
                FloeShellEndSession(id)
                FloeShellCommandRegistry.shared.unbind(sessionID: id)
                onFinish?(id)
            }
        }
        private func closeDescriptorsLocked() {
            // Per-descriptor flags: sendEOF() may already have closed stdin,
            // and a recycled descriptor number must never be closed twice.
            if !inputClosed { inputClosed = true; Darwin.close(input) }
            if !outputClosed { outputClosed = true; Darwin.close(output) }
        }
        func drain(maxBytes: Int) -> ShellExchangeResult {
            lock.withLock {
                let data = Data(buffered.prefix(max(1, min(maxBytes, 256 * 1024))))
                buffered.removeFirst(data.count)
                return ShellExchangeResult(output: String(decoding: data, as: UTF8.self), alive: !finished || !buffered.isEmpty, exitCode: exitCode, terminalOutput: data, bytesRead: bytesRead, bytesWritten: bytesWritten)
            }
        }
        func close() {
            lock.withLock { closing = true }
            wake.signal()
            // The pump owns descriptor teardown and serializes it with reads/writes.
            FloeShellCommandRegistry.shared.cancelCurrent(sessionID: id)
            FloeShellSignalSession(id, SIGTERM)
        }
    }
}
