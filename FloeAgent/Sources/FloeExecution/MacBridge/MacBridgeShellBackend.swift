import Foundation
import FloeCore
import FloeTools
import FloeMacBridgeProtocol

/// One authenticated host-backed shell. All output remains on disk; only
/// the inline summary obeys the existing service's requested display bound.
public actor MacBridgeShellBackend: LocalShellBackend {
    private struct Session: Sendable { let jobID: String; let root: URL; var offset: Int64 }
    private let client: MacBridgeClient
    private var sessions: [String: Session] = [:]
    public init(client: MacBridgeClient = .shared) { self.client = client }

    public func run(_ request: ShellRunRequest, cancellation: CancellationToken?) async -> ShellRunOutcome {
        let started = ContinuousClock.now
        let jobID = UUID().uuidString
        var created = false
        var submitted = false
        defer {
            if !submitted {
                Task { [client] in _ = try? await client.call("command.discard", ["jobID": .string(jobID)]) }
            }
        }
        do {
            try check(cancellation)
            let workspaceID = try await client.synchronizeBeforeExecution(root: request.rootURL)
            let remoteWorkspace = try await client.workspace(root: request.rootURL)
            let executableCommand = Self.withManagedPaths(request.command, root: remoteWorkspace.path)
            try check(cancellation)
            var payload = startPayload(jobID: jobID, workspaceID: workspaceID,
                command: executableCommand, cwd: request.cwd, environment: request.environment, columns: 100, rows: 30)
            if MacBridgeCommandTransfer.requiresStaging(utf8Bytes: executableCommand.utf8.count) {
                let digest = try await client.stageCommand(executableCommand, jobID: jobID, cancellation: cancellation)
                payload["command"] = nil; payload["commandFile"] = .string(jobID); payload["commandDigest"] = .string(digest)
            }
            try check(cancellation)
            try await client.recordJobAttempt(id: jobID, root: request.rootURL, sessionID: request.sessionID)
            submitted = true
            _ = try await client.call("start", payload)
            created = true
            if let stdin = request.stdin, !stdin.isEmpty {
                try await sendInput(Data(stdin.utf8), jobID: jobID)
                try await sendInput(Data([4]), jobID: jobID)
            }
            let outputRoot = request.rootURL.appendingPathComponent(".floe/terminal", isDirectory: true)
            try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
            let log = outputRoot.appendingPathComponent(jobID + ".log")
            guard FileManager.default.createFile(atPath: log.path, contents: nil) else { throw BridgeFailure.remote("Cannot save terminal output.") }
            let writer = try FileHandle(forWritingTo: log)
            defer { try? writer.close() }
            var offset: Int64 = 0, preview = Data(), exitCode: Int32 = 0
            var timedOut = false, cancelling = false
            var cancelStarted: ContinuousClock.Instant?
            let deadline: ContinuousClock.Instant? = if case .seconds(let value) = request.deadline { started.advanced(by: .seconds(value)) } else { nil }
            while true {
                if !cancelling && (cancellation?.isCancelled == true || Task.isCancelled || deadline.map({ ContinuousClock.now >= $0 }) == true) {
                    cancelling = true; cancelStarted = .now; timedOut = cancellation?.isCancelled != true && !Task.isCancelled
                    _ = try await client.call("signal", ["jobID": .string(jobID), "signal": .string("TERM")])
                }
                let page = try await client.call("poll", ["jobID": .string(jobID), "offset": .integer(offset), "limit": .integer(Int64(BridgeWire.pageBytes))])
                if page["outcomeUnknown"]?.bool == true { return .outcomeUnknown(jobID: jobID, message: "The companion restarted before this command's exit was confirmed. Its saved output is available; it was not rerun.") }
                let bytes = try bytes(page)
                if !bytes.isEmpty {
                    try writer.write(contentsOf: bytes)
                    if preview.count < request.maxOutputBytes { preview.append(bytes.prefix(max(0, request.maxOutputBytes - preview.count))) }
                    offset += Int64(bytes.count)
                }
                let alive = page["alive"]?.bool ?? false
                let total = page["totalBytes"]?.integer ?? offset
                if !alive && offset >= total { exitCode = Int32(clamping: page["exitCode"]?.integer ?? 0); break }
                // Drain cancellation is finite. Escalation targets only this
                // owned process group; a dead bridge never starts a replacement.
                if let cancelStarted, ContinuousClock.now - cancelStarted > .seconds(5), alive {
                    _ = try await client.call("signal", ["jobID": .string(jobID), "signal": .string("KILL")])
                }
                if let cancelStarted, ContinuousClock.now - cancelStarted > .seconds(8), alive {
                    return .outcomeUnknown(jobID: jobID, message: "The Mac command did not confirm exit after cancellation. Inspect the saved job before continuing; no replacement was started.")
                }
                try await Task.sleep(for: .milliseconds(bytes.isEmpty ? 80 : 1))
            }
            try writer.close()
            let note = "Full terminal output: .floe/terminal/\(jobID).log"
            do { try await client.synchronizeAfterExecution(root: request.rootURL) }
            catch { return .outcomeUnknown(jobID: jobID, message: "The command finished with exit code \(exitCode), but file transfer is pending: \(error.localizedDescription). Use Sync Files in the saved job; do not run the command again.") }
            let duration = Self.milliseconds(started.duration(to: .now))
            if cancelling && !timedOut { return .cancelled }
            if timedOut { return .timedOut(partialStdout: String(decoding: preview, as: UTF8.self), partialStderr: note, durationMs: duration) }
            return .exited(code: exitCode, stdout: String(decoding: preview, as: UTF8.self), stderr: note,
                           truncated: offset > Int64(preview.count), stderrTruncated: false, durationMs: duration)
        } catch {
            if created, cancellation?.isCancelled == true || Task.isCancelled {
                let drained = await Task.detached { [client] in
                    do {
                        _ = try await client.call("signal", ["jobID": .string(jobID), "signal": .string("TERM")])
                        for attempt in 0..<80 {
                            let page = try await client.call("poll", ["jobID": .string(jobID), "offset": .integer(0), "limit": .integer(1)])
                            if page["outcomeUnknown"]?.bool == true { return false }
                            if page["alive"]?.bool == false { return true }
                            if attempt == 30 { _ = try await client.call("signal", ["jobID": .string(jobID), "signal": .string("KILL")]) }
                            try await Task.sleep(for: .milliseconds(100))
                        }
                    } catch { }
                    return false
                }.value
                if drained { return .cancelled }
                return .outcomeUnknown(jobID: jobID, message: "Mac job cancellation could not be confirmed. Reconnect to inspect it; no replacement was started.")
            }
            if submitted {
                // Retain job ID for inspection after a lost response. Do not
                // use the default backend or automatically issue start again.
                return .outcomeUnknown(jobID: jobID, message: "\(error.localizedDescription). Reconnect to inspect the saved output; it was not run again.")
            }
            if cancellation?.isCancelled == true || Task.isCancelled { return .cancelled }
            return .notStarted(reason: error.localizedDescription)
        }
    }
    public func openSession(_ request: ShellOpenRequest, cancellation: CancellationToken?) async throws -> ShellOpenResult {
        try check(cancellation)
        let workspaceID = try await client.synchronizeBeforeExecution(root: request.rootURL)
            let remoteWorkspace = try await client.workspace(root: request.rootURL)
            let executableCommand = Self.withManagedPaths(request.command, root: remoteWorkspace.path)
        let jobID = UUID().uuidString
        var submitted = false
        defer {
            if !submitted { Task { [client] in _ = try? await client.call("command.discard", ["jobID": .string(jobID)]) } }
        }
        var payload = startPayload(jobID: jobID, workspaceID: workspaceID,
            command: executableCommand, cwd: request.cwd, environment: request.environment, columns: request.columns, rows: request.rows)
        if MacBridgeCommandTransfer.requiresStaging(utf8Bytes: executableCommand.utf8.count) {
            let digest = try await client.stageCommand(executableCommand, jobID: jobID, cancellation: cancellation)
            payload["command"] = nil; payload["commandFile"] = .string(jobID); payload["commandDigest"] = .string(digest)
        }
        try check(cancellation)
        try await client.recordJobAttempt(id: jobID, root: request.rootURL, sessionID: request.sessionID)
        sessions[request.sessionID] = Session(jobID: jobID, root: request.rootURL, offset: 0)
        submitted = true
        do { _ = try await client.call("start", payload) }
        catch { throw ToolExecutionOutcomeUnknownError(reference: jobID, message: "The Mac terminal start could not be confirmed. Reconnect and inspect this existing job; do not open a replacement.") }
        return ShellOpenResult(sessionID: request.sessionID, initialOutput: "", alive: true, terminalOutput: Data())
    }
    public func exchangeSession(_ request: ShellExchangeRequest, cancellation: CancellationToken?) async throws -> ShellExchangeResult {
        try check(cancellation)
        guard var session = sessions[request.sessionID] else { throw BridgeFailure.disconnected }
        do {
        if let input = request.input {
            if input == "\u{03}" { _ = try await client.call("signal", ["jobID": .string(session.jobID), "signal": .string("INT")]) }
            else { try await sendInput(Data(input.utf8), jobID: session.jobID) }
        }
        let page = try await client.call("poll", ["jobID": .string(session.jobID), "offset": .integer(session.offset),
            "limit": .integer(Int64(min(max(request.maxBytes, 1), BridgeWire.pageBytes)))])
        if page["outcomeUnknown"]?.bool == true { throw ToolExecutionOutcomeUnknownError(reference: session.jobID, message: "The Mac terminal exit was not confirmed after reconnect.") }
        let data = try bytes(page); session.offset += Int64(data.count)
        sessions[request.sessionID] = session
        let alive = page["alive"]?.bool ?? false
        if !alive { try await client.synchronizeAfterExecution(root: session.root) }
        return ShellExchangeResult(output: String(decoding: data, as: UTF8.self), alive: alive,
            exitCode: page["exitCode"]?.integer.map { Int32(clamping: $0) }, terminalOutput: data,
            bytesRead: Int(clamping: page["totalBytes"]?.integer ?? session.offset), bytesWritten: Int(clamping: page["inputBytes"]?.integer ?? 0))
        } catch let error as ToolExecutionOutcomeUnknownError { throw error }
        catch {
            throw ToolExecutionOutcomeUnknownError(reference: session.jobID,
                message: "The existing Mac terminal requires inspection: \(error.localizedDescription). Do not resend its input or open a replacement. Sync Files retries delivery after a confirmed exit.")
        }
    }
    public func closeSession(sessionID: String) async {
        guard let session = sessions[sessionID] else { return }
        do {
            _ = try await client.call("signal", ["jobID": .string(session.jobID), "signal": .string("TERM")])
            // Actual exit must be observed before dropping ownership.
            for attempt in 0..<60 {
                let page = try await client.call("poll", ["jobID": .string(session.jobID), "offset": .integer(0), "limit": .integer(1)])
                if page["outcomeUnknown"]?.bool == true { return }
                if page["alive"]?.bool == false {
                    try await client.synchronizeAfterExecution(root: session.root)
                    sessions.removeValue(forKey: sessionID); return
                }
                if attempt == 30 { _ = try await client.call("signal", ["jobID": .string(session.jobID), "signal": .string("KILL")]) }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch { /* Retain the session and its immutable job ID for reconnect. */ }
    }
    public func signalSession(sessionID: String, signal: ShellSignal) async {
        guard let session = sessions[sessionID] else { return }
        _ = try? await client.call("signal", ["jobID": .string(session.jobID), "signal": .string(signal.rawValue)])
    }
    public func resizeSession(sessionID: String, columns: Int, rows: Int) async {
        guard let session = sessions[sessionID] else { return }
        _ = try? await client.call("resize", ["jobID": .string(session.jobID), "columns": .integer(Int64(columns)), "rows": .integer(Int64(rows))])
    }
    private static func withManagedPaths(_ command: String, root: String) -> String {
        guard !command.isEmpty else { return command }
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return "export PATH=" + quote(root + "/.floe-env/bin") + ":" + quote(root + "/.floe-node/node_modules/.bin") + ":\"$PATH\"; export NODE_PATH=" + quote(root + "/.floe-node/node_modules") + "\"${NODE_PATH:+:$NODE_PATH}\";\n" + command
    }

    private func startPayload(jobID: String, workspaceID: String, command: String, cwd: String,
                              environment: [String: String], columns: Int, rows: Int) -> [String: BridgeValue] {
        ["jobID": .string(jobID), "workspaceID": .string(workspaceID), "command": .string(command), "cwd": .string(cwd),
         "environment": .object(environment.mapValues(BridgeValue.string)), "columns": .integer(Int64(columns)), "rows": .integer(Int64(rows))]
    }
    private func sendInput(_ data: Data, jobID: String) async throws {
        var offset = 0
        while offset < data.count {
            let end = min(offset + BridgeWire.pageBytes, data.count)
            _ = try await client.call("input", ["jobID": .string(jobID), "data": .string(data[offset..<end].base64EncodedString())])
            offset = end
        }
    }
    private func bytes(_ page: [String: BridgeValue]) throws -> Data {
        guard let text = page["data"]?.string, let data = Data(base64Encoded: text) else { throw BridgeFailure.incompatible }
        return data
    }
    private func check(_ cancellation: CancellationToken?) throws {
        try Task.checkCancellation(); try cancellation?.throwIfCancelled()
    }
    private static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(clamping: parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }
}

/// Routing is based exclusively on the trusted environment lease. A model's
/// command environment cannot promote an iOS/Linux task to host execution.
public actor MacBridgeExecutionRouter: LocalShellBackend {
    private let defaultBackend: any LocalShellBackend
    private let bridge: MacBridgeShellBackend
    private var macSessions = Set<String>()
    public init(defaultBackend: any LocalShellBackend, client: MacBridgeClient = .shared) {
        self.defaultBackend = defaultBackend; self.bridge = MacBridgeShellBackend(client: client)
    }
    public nonisolated func normalizedRunDeadline(_ requested: ShellExecutionDeadline) -> ShellExecutionDeadline {
        defaultBackend.normalizedRunDeadline(requested)
    }
    private func isMac(_ environment: ToolEnvironment?) -> Bool { environment?.variables["FLOE_EXECUTION_BACKEND"] == "macBridge" }
    public func run(_ request: ShellRunRequest, cancellation: CancellationToken?) async -> ShellRunOutcome {
        if isMac(request.toolEnvironment) { return await bridge.run(request, cancellation: cancellation) }
        return await defaultBackend.run(request, cancellation: cancellation)
    }
    public func openSession(_ request: ShellOpenRequest, cancellation: CancellationToken?) async throws -> ShellOpenResult {
        if isMac(request.toolEnvironment) {
            macSessions.insert(request.sessionID)
            return try await bridge.openSession(request, cancellation: cancellation)
        }
        return try await defaultBackend.openSession(request, cancellation: cancellation)
    }
    public func exchangeSession(_ request: ShellExchangeRequest, cancellation: CancellationToken?) async throws -> ShellExchangeResult {
        if macSessions.contains(request.sessionID) { return try await bridge.exchangeSession(request, cancellation: cancellation) }
        return try await defaultBackend.exchangeSession(request, cancellation: cancellation)
    }
    public func closeSession(sessionID: String) async {
        if macSessions.contains(sessionID) { await bridge.closeSession(sessionID: sessionID) }
        else { await defaultBackend.closeSession(sessionID: sessionID) }
    }
    public func signalSession(sessionID: String, signal: ShellSignal) async {
        if macSessions.contains(sessionID) { await bridge.signalSession(sessionID: sessionID, signal: signal) }
        else { await defaultBackend.signalSession(sessionID: sessionID, signal: signal) }
    }
    public func resizeSession(sessionID: String, columns: Int, rows: Int) async {
        if macSessions.contains(sessionID) { await bridge.resizeSession(sessionID: sessionID, columns: columns, rows: rows) }
        else { await defaultBackend.resizeSession(sessionID: sessionID, columns: columns, rows: rows) }
    }
}

/// Below Darwin's argv budget; this chooses chunked script delivery, not a
/// maximum accepted command size. Both run and interactive launch share it.
public enum MacBridgeCommandTransfer {
    public static let inlineUTF8Bytes = 48 * 1_024
    public static func requiresStaging(utf8Bytes: Int) -> Bool { utf8Bytes > inlineUTF8Bytes }
}
