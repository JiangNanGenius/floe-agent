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
        FloeShellCommandRegistry.shared.bind(sessionID: request.sessionID, rootURL: request.rootURL, runID: request.runID, cancellation: cancellation)
        defer { FloeShellCommandRegistry.shared.unbind(sessionID: request.sessionID) }
        return await Task.detached(priority: .userInitiated) {
            let started = DispatchTime.now().uptimeNanoseconds
            var stdout: NSString?, stderr: NSString?
            var code: Int32 = 125
            let escaped = request.command.replacingOccurrences(of: "'", with: "'\\''")
            let command = "dash -c '\(escaped)'"
            let status = FloeShellRunCommand(command, request.rootURL.path, directory.path, request.sessionID, request.environment, request.stdin.map { Data($0.utf8) }, request.timeout, UInt(max(1, request.maxOutputBytes)), { cancellation?.isCancelled == true }, &stdout, &stderr, &code)
            let duration = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            let out = stdout as String? ?? "", err = stderr as String? ?? ""
            if cancellation?.isCancelled == true { return .cancelled }
            switch status {
            case .OK: return .exited(code: code, stdout: out, stderr: err, truncated: out.utf8.count >= request.maxOutputBytes, stderrTruncated: err.utf8.count >= request.maxOutputBytes, durationMs: duration)
            case .timedOut: return .timedOut(partialStdout: out, partialStderr: err, durationMs: duration)
            case .cancelled: return .cancelled
            default: return .failed(message: "Local shell could not start")
            }
        }.value
    }

    func openSession(_ request: ShellOpenRequest, cancellation: CancellationToken?) async throws -> ShellOpenResult {
        try cancellation?.throwIfCancelled()
        let directory = try ShellInputValidation.directory(cwd: request.cwd, root: request.rootURL)
        FloeShellCommandRegistry.shared.bind(sessionID: request.sessionID, rootURL: request.rootURL, runID: request.runID, cancellation: cancellation)
        return try await Task.detached(priority: .userInitiated) { [self] in
            var inputFD: Int32 = -1, outputFD: Int32 = -1
            var initial: NSString?
            let escaped = request.command.replacingOccurrences(of: "'", with: "'\\''")
            let body = request.command.isEmpty ? "dash -i" : "dash -c '\(escaped)'"
            guard FloeShellOpenSession(body, request.rootURL.path, directory.path, request.sessionID, request.environment, request.columns, request.rows, &inputFD, &outputFD, &initial), inputFD >= 0, outputFD >= 0 else {
                FloeShellCommandRegistry.shared.unbind(sessionID: request.sessionID)
                throw FloeError.internalError("The local shell could not open a session")
            }
            if cancellation?.isCancelled == true {
                FloeShellCloseSession(request.sessionID)
                FloeShellCommandRegistry.shared.unbind(sessionID: request.sessionID)
                throw FloeError.cancelled
            }
            let io = SessionIO(id: request.sessionID, input: inputFD, output: outputFD)
            lock.withLock { sessions[request.sessionID] = io }
            io.start()
            let text = initial as String? ?? ""
            return ShellOpenResult(sessionID: request.sessionID, initialOutput: text, alive: true, terminalOutput: Data(text.utf8))
        }.value
    }

    func exchangeSession(_ request: ShellExchangeRequest, cancellation: CancellationToken?) async throws -> ShellExchangeResult {
        guard let io = lock.withLock({ sessions[request.sessionID] }) else { throw FloeError.notFound("Unknown shell session") }
        try cancellation?.throwIfCancelled()
        if let input = request.input { try io.enqueue(Data(input.utf8)) }
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
        private var buffered = Data()
        private var pendingInput = Data()
        private var finished = false
        private var closing = false
        private var exitCode: Int32?
        var alive: Bool { lock.withLock { !finished && !closing } }
        var hasOutput: Bool { lock.withLock { !buffered.isEmpty } }
        init(id: String, input: Int32, output: Int32) {
            self.id = id; self.input = input; self.output = output
            _ = fcntl(input, F_SETFL, fcntl(input, F_GETFL, 0) | O_NONBLOCK)
            _ = fcntl(output, F_SETFL, fcntl(output, F_GETFL, 0) | O_NONBLOCK)
            _ = fcntl(input, F_SETNOSIGPIPE, 1)
        }
        func enqueue(_ data: Data) throws {
            try lock.withLock {
                guard !closing && !finished, pendingInput.count + data.count <= 256 * 1024 else {
                    throw FloeError.validationFailed("Terminal input is closed or its queue is full")
                }
                pendingInput.append(data)
            }
        }
        func start() {
            DispatchQueue.global(qos: .utility).async { [self] in
                while alive {
                    let inputData = lock.withLock { pendingInput }
                    if !inputData.isEmpty {
                        let written = inputData.withUnsafeBytes { Darwin.write(input, $0.baseAddress, $0.count) }
                        if written > 0 { lock.withLock { pendingInput.removeFirst(written) } }
                        else if written < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { break }
                    }
                    var chunk = [UInt8](repeating: 0, count: 16 * 1024)
                    let count = Darwin.read(output, &chunk, chunk.count)
                    if count > 0 {
                        lock.withLock {
                            buffered.append(contentsOf: chunk.prefix(count))
                            if buffered.count > 256 * 1024 { buffered = Data(buffered.suffix(256 * 1024)) }
                        }
                    } else if count == 0 { break }
                    else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { break }
                    if count <= 0 { Thread.sleep(forTimeInterval: 0.02) }
                }
                var code: Int32 = 0
                let hasCode = FloeShellSessionExitCode(id, &code)
                lock.withLock { finished = true; exitCode = hasCode ? code : nil }
                FloeShellCloseSession(id)
                FloeShellCommandRegistry.shared.unbind(sessionID: id)
            }
        }
        func drain(maxBytes: Int) -> ShellExchangeResult {
            lock.withLock {
                let data = Data(buffered.prefix(max(1, min(maxBytes, 256 * 1024))))
                buffered.removeFirst(data.count)
                return ShellExchangeResult(output: String(decoding: data, as: UTF8.self), alive: !finished || !buffered.isEmpty, exitCode: exitCode, terminalOutput: data)
            }
        }
        func close() {
            lock.withLock { closing = true }
            // The pump owns descriptor teardown and serializes it with reads/writes.
            FloeShellSignalSession(id, SIGTERM)
        }
    }
}
