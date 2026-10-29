#if canImport(UIKit)
import Foundation
import FloeCore
import FloeTools
import FloeExecution
import FloePersistence
import FloeWorkspace
import FloeMacBridgeProtocol

/// Existing jobs.submit/exec.localService lifecycle, running on the explicitly
/// selected Mac. MCP uses native HTTP, never an echoing terminal as stdio.
enum MacBridgeLocalServiceRunner {
    static func run(
        args: LocalServiceTool.Arguments, jobID: UUID, conversationID: UUID,
        environment: ToolEnvironment, entry: URL, cwd: URL,
        variables: [String: String], endpoint: URL, probe: URLSession,
        context: ToolContext, store: BackgroundJobStore,
        onServiceReady: (@Sendable (UUID) async -> Void)?
    ) async throws -> ToolExecutionOutput {
        guard environment.variables["FLOE_EXECUTION_BACKEND"] == "macBridge",
              let root = context.workspaceRootURL else { throw FloeError.validationFailed("A Mac environment is required.") }
        try context.cancellation.throwIfCancelled()
        let client = MacBridgeClient.shared
        let id = jobID.uuidString
        let workspaceID = try await client.synchronizeBeforeExecution(root: root)
        let relativeEntry = try relative(entry, root: root)
        let relativeCWD = try relative(cwd, root: root)
        var effective = variables
        effective["HOST"] = "127.0.0.1"
        effective["FLOE_MCP_ALLOWED_HOSTS"] = "127.0.0.1,localhost,[::1]"
        let command: String
        switch args.runtime {
        case "node": command = "exec node " + quote(relativeEntry) + arguments(args.arguments)
        case "python": command = "exec python3 " + quote(relativeEntry) + arguments(args.arguments)
        case "shell": command = "exec /bin/zsh " + quote(relativeEntry) + arguments(args.arguments)
        case "static": command = "exec python3 -m http.server " + String(args.port) + " --bind 127.0.0.1 --directory " + quote(URL(fileURLWithPath: relativeEntry).deletingLastPathComponent().path)
        default: throw FloeError.validationFailed("This service runtime is unavailable.")
        }
        // Entry is workspace-relative, while cwd may be a subdirectory. Use
        // the actual host workspace root for the entry and keep cwd explicit.
        let host = try await client.call("workspace", ["workspaceID": .string(workspaceID)])
        guard let hostRoot = host["root"]?.string else { throw BridgeFailure.incompatible }
        let hostEntry = URL(fileURLWithPath: hostRoot).appendingPathComponent(relativeEntry).path
        let executable: String
        switch args.runtime {
        case "node": executable = "exec node " + quote(hostEntry) + arguments(args.arguments)
        case "python": executable = "exec python3 " + quote(hostEntry) + arguments(args.arguments)
        case "shell": executable = "exec /bin/zsh " + quote(hostEntry) + arguments(args.arguments)
        case "static": executable = "exec python3 -m http.server " + String(args.port) + " --bind 127.0.0.1 --directory " + quote(URL(fileURLWithPath: hostEntry).deletingLastPathComponent().path)
        default: executable = command
        }
        var snapshot = LocalServiceProgress(state: "starting", runtime: args.runtime, stdout: "", stderr: "", truncated: false)
        try await store.updateProgress(id: jobID, data: JSONEncoder().encode(snapshot))
        var submitted = false, acknowledged = false, stopping = false, announcedReady = false
        var offset: Int64 = 0
        var confirmedExitCode: Int64?
        do {
            let existing = try await client.savedJobs().contains { $0.id == id }
            if !existing {
                try context.cancellation.throwIfCancelled()
                try await client.recordJobAttempt(id: id, root: root, sessionID: "service-" + id)
                submitted = true
                _ = try await client.call("start", ["jobID": .string(id), "workspaceID": .string(workspaceID),
                    "command": .string(executable), "cwd": .string(relativeCWD),
                    "environment": .object(effective.mapValues(BridgeValue.string))])
            } else { submitted = true }
            acknowledged = true
            let previewEndpoint = args.runtime == "static" ? endpoint.appendingPathComponent(entry.lastPathComponent) : endpoint
            var request = URLRequest(url: previewEndpoint); request.httpMethod = "HEAD"
            var stopBegan: ContinuousClock.Instant?
            while true {
                if context.cancellation.isCancelled || Task.isCancelled {
                    if !stopping {
                        stopping = true; stopBegan = .now
                        _ = try await client.call("signal", ["jobID": .string(id), "signal": .string("TERM")])
                    }
                }
                if let stopBegan, ContinuousClock.now - stopBegan > .seconds(4) {
                    _ = try await client.call("signal", ["jobID": .string(id), "signal": .string("KILL")])
                }
                let page = try await client.call("poll", ["jobID": .string(id), "offset": .integer(offset), "limit": .integer(Int64(BridgeWire.pageBytes))])
                if page["outcomeUnknown"]?.bool == true { throw BridgeFailure.ambiguous }
                guard let encoded = page["data"]?.string, let data = Data(base64Encoded: encoded) else { throw BridgeFailure.incompatible }
                offset += Int64(data.count)
                snapshot.stdout = String(decoding: (Data(snapshot.stdout.utf8) + data).suffix(4_096), as: UTF8.self)
                snapshot.truncated = offset > 4_096
                let alive = page["alive"]?.bool ?? false
                if !alive {
                    confirmedExitCode = page["exitCode"]?.integer
                    snapshot.previewURL = nil; BrowserURLPolicy.revokeService(owner: jobID)
                    // A finished process is not a delivered artifact. Commit the
                    // terminal status only after CAS file reconciliation succeeds.
                    try await client.synchronizeAfterExecution(root: root)
                    snapshot.state = stopping ? "stopped" : (confirmedExitCode == 0 ? "completed" : "failed")
                    snapshot.boundAndRedact(); try await store.updateProgress(id: jobID, data: JSONEncoder().encode(snapshot))
                    return ToolExecutionOutput(digesting: String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self), exitStatus: stopping || page["exitCode"]?.integer == 0 ? 0 : 1)
                }
                snapshot.state = stopping ? "stopping" : "running"
                if !stopping, await responds(probe, request: request, successfulOnly: args.runtime == "static") {
                    snapshot.previewURL = previewEndpoint.absoluteString
                    BrowserURLPolicy.authorizeService(endpoint, owner: jobID, conversationID: conversationID)
                    if !announcedReady { announcedReady = true; await onServiceReady?(jobID) }
                } else { snapshot.previewURL = nil; BrowserURLPolicy.revokeService(owner: jobID) }
                snapshot.boundAndRedact()
                try await store.updateProgress(id: jobID, data: JSONEncoder().encode(snapshot))
                try? await Task.sleep(for: .seconds(1))
            }
        } catch {
            BrowserURLPolicy.revokeService(owner: jobID)
            let bridgeConnected = await client.isConnected()
            if acknowledged, confirmedExitCode == nil,
               context.cancellation.isCancelled || Task.isCancelled || bridgeConnected {
                let drained = await Task.detached {
                    do {
                        _ = try await client.call("signal", ["jobID": .string(id), "signal": .string("TERM")])
                        for attempt in 0..<80 {
                            let page = try await client.call("poll", ["jobID": .string(id), "offset": .integer(0), "limit": .integer(1)])
                            if page["outcomeUnknown"]?.bool == true { return false }
                            if page["alive"]?.bool == false { return true }
                            if attempt == 30 { _ = try await client.call("signal", ["jobID": .string(id), "signal": .string("KILL")]) }
                            try await Task.sleep(for: .milliseconds(100))
                        }
                    } catch { }
                    return false
                }.value
                if drained && (context.cancellation.isCancelled || Task.isCancelled) { throw FloeError.cancelled }
            }
            if submitted {
                snapshot.state = "unavailable"; snapshot.previewURL = nil
                if let code = confirmedExitCode {
                    snapshot.stderr = "The Mac service finished with exit code \(code), but delivery is pending: \(error.localizedDescription). Sync Files in saved job \(id); do not restart it."
                } else {
                    snapshot.stderr = "The Mac service outcome is unknown. Reconnect and inspect job " + id + "; it was not restarted."
                }
                snapshot.boundAndRedact(); try? await store.updateProgress(id: jobID, data: JSONEncoder().encode(snapshot))
                return ToolExecutionOutput(digesting: String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self), exitStatus: 1, outcomeUnknown: true)
            }
            throw error
        }
    }
    private static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func arguments(_ values: [String]?) -> String { (values ?? []).map { " " + quote($0) }.joined() }
    private static func relative(_ file: URL, root: URL) throws -> String {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let path = file.resolvingSymlinksInPath().standardizedFileURL.path
        guard path == base || path.hasPrefix(base + "/") else { throw BridgeFailure.unsafePath }
        return path == base ? "." : String(path.dropFirst(base.count + 1))
    }
    private static func responds(_ session: URLSession, request: URLRequest, successfulOnly: Bool) async -> Bool {
        do {
            let (bytes, response) = try await session.bytes(for: request); defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else { return false }
            return !successfulOnly || (200..<300).contains(response.statusCode)
        } catch { return false }
    }
}
#endif
