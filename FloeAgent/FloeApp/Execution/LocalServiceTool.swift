// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeTools
import FloeExecution
import FloePersistence
import FloeWorkspace

struct LocalServiceProgress: Codable, Sendable {
    var state: String
    var runtime: String
    var previewURL: String?
    var stdout: String
    var stderr: String
    var truncated: Bool

    mutating func boundAndRedact() {
        stdout = SecretRedactor.redact(stdout)
        stderr = SecretRedactor.redact(stderr)
        if stdout.utf8.count > 4_096 || stderr.utf8.count > 4_096 { truncated = true }
        // JSON escapes can expand each byte up to sixfold; retain margin under
        // the durable progress limit even for a huge exception/control stream.
        stdout = String(decoding: stdout.utf8.prefix(4_096), as: UTF8.self)
        stderr = String(decoding: stderr.utf8.prefix(4_096), as: UTF8.self)
    }
}

/// Shell is a first-class caller of the same managed lifecycle, not `command &`
/// left attached to a foreground executor that later times out.
func registerLocalServiceCommand(service: BackgroundJobService, store: BackgroundJobStore) {
    FloeShellCommandRegistry.shared.register("floe-service") { arguments, stdout, stderr in
        let usage = "floe-service start node|python ENTRY PORT [-- ARGS...] | list | status JOB_ID | logs JOB_ID | stop JOB_ID | restart JOB_ID\nUse a workspace-relative entry script; bind 127.0.0.1 using PORT. Services survive replies and closed previews, not app termination.\n"
        let args = Array(arguments.dropFirst())
        if args.isEmpty || args == ["--help"] { FloeShellWrite(stdout, usage); return 0 }
        guard let context = FloeShellCommandRegistry.shared.context, let environment = context.environment else {
            FloeShellWrite(stderr, "floe-service: an attached task and environment are required\n"); return 2
        }
        do {
            try context.cancellation.throwIfCancelled()
            guard let owner = try await store.conversationID(runID: context.runID) else {
                throw FloeError.validationFailed("Start the service from a task with a saved workspace")
            }
            if args == ["list"] {
                let jobs = try await store.jobs(environmentID: environment.id, targetTool: "exec.localService")
                    .filter { $0.conversationID == owner }
                for job in jobs { FloeShellWrite(stdout, "\(job.id.uuidString)\t\(job.state.rawValue)\n") }
                return 0
            }
            let job: BackgroundJob
            if args.first == "start", args.count >= 4, let port = Int(args[3]), args.count == 4 || args[4] == "--" {
                let root = context.rootURL.standardizedFileURL.path
                let directory = context.workingDirectory.standardizedFileURL.path
                guard directory == root || directory.hasPrefix(root + "/"), !args[2].hasPrefix("/") else {
                    throw FloeError.validationFailed("Use an entry script inside the current workspace")
                }
                let cwd = directory == root ? "." : String(directory.dropFirst(root.count + 1))
                let invocation = LocalServiceTool.Arguments(runtime: args[1], entry: cwd + "/" + args[2],
                    arguments: Array(args.dropFirst(5)), cwd: cwd, port: port)
                job = try await service.submit(runID: context.runID, toolCallID: nil, targetTool: "exec.localService",
                    payloadJSON: JSONEncoder().encode(invocation), scope: .local, workspaceRootURL: context.rootURL,
                    allowedWorkspacePaths: [], environmentID: environment.id)
            } else if args.count == 2, let id = UUID(uuidString: args[1]), ["status", "logs", "stop", "restart"].contains(args[0]) {
                let owned = try await service.ownedJob(id: id, runID: context.runID)
                guard owned.environmentID == environment.id, owned.targetTool == "exec.localService" else {
                    throw FloeError.validationFailed("This service belongs to another environment")
                }
                switch args[0] {
                case "stop": job = try await service.cancel(id: id)
                case "restart": job = try await service.restartLocalService(id: id)
                default: job = owned
                }
                if args[0] == "logs", let progress = job.progressJSON.flatMap({ try? JSONDecoder().decode(LocalServiceProgress.self, from: $0) }) {
                    FloeShellWrite(stdout, progress.stdout)
                    FloeShellWrite(stderr, progress.stderr)
                    return 0
                }
            } else { FloeShellWrite(stderr, usage); return 2 }
            let progress = job.progressJSON.flatMap { try? JSONDecoder().decode(LocalServiceProgress.self, from: $0) }
            let result = ["jobID": job.id.uuidString, "state": job.state.rawValue,
                          "previewURL": job.state.isTerminal ? "" : (progress?.previewURL ?? ""),
                          "detail": job.lastError ?? progress?.state ?? ""]
            let data = try JSONEncoder().encode(result)
            FloeShellWrite(stdout, SecretRedactor.redact(String(decoding: data, as: UTF8.self)) + "\n")
            return 0
        } catch {
            FloeShellWrite(stderr, "floe-service: " + SecretRedactor.redact(String(describing: error)) + "\n")
            return 1
        }
    }
}

private final class ServiceProbeDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Runs only inside a durable job. The registry keeps its environment lease
/// until this runner observes native shutdown, including slow cancellation.
struct LocalServiceTool: AgentTool {
    struct Arguments: Codable, Sendable {
        var runtime: String
        var entry: String
        var arguments: [String]?
        var cwd: String?
        var port: Int
    }
    private static let portsLock = NSLock()
    nonisolated(unsafe) private static var reservedPorts: Set<Int> = []
    private static func reserve(_ port: Int) -> Bool { portsLock.withLock { reservedPorts.insert(port).inserted } }
    private static func release(_ port: Int) { portsLock.withLock { _ = reservedPorts.remove(port) } }
    static let name = "exec.localService"
    static let toolDescription = "Persistent local Node/Python HTTP service inside the task environment's Linux guest. Invoke through jobs.submit with this target; do not call directly. entry is an existing workspace-relative script, cwd defaults to workspace root, port is 1024..65535. The guest process binds loopback inside the VM and Floe forwards it to 127.0.0.1; PORT/FLOE_SERVICE_PORT are set to port. Closing a tool turn or browser tab does not stop the server. jobs.status exposes bounded live logs and a previewURL only after HTTP responds; jobs.cancel waits for actual guest process exit. Stopping the environment or the app stops the guest and its services; explicitly restart if still needed."
    static let parametersJSON = #"{"type":"object","properties":{"runtime":{"type":"string","enum":["node","python"]},"entry":{"type":"string","maxLength":2048,"description":"Workspace-relative path to an existing entry script (checked when the job is submitted)"},"arguments":{"type":"array","maxItems":32,"items":{"type":"string","maxLength":2048}},"cwd":{"type":"string","maxLength":2048,"description":"Workspace-relative working directory (default: workspace root; must exist)"},"port":{"type":"integer","minimum":1024,"maximum":65535,"description":"Loopback port the service binds (1024..65535); the server reads PORT/FLOE_SERVICE_PORT"}},"required":["runtime","entry","port"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.executesLocalCode, .readsFiles, .writesFiles, .deletesFiles, .networkAccess]
    static let isSideEffecting = true
    let store: BackgroundJobStore

    private static func responds(_ session: URLSession, request: URLRequest) async -> Bool {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() } // HEAD may still receive a noncompliant, unbounded body.
            return response is HTTPURLResponse
        } catch { return false }
    }

    func validate(_ args: Arguments) throws {
        guard ["node", "python"].contains(args.runtime) else {
            throw FloeError.validationFailed("exec.localService runtime must be 'node' or 'python', got '\(args.runtime)'")
        }
        guard !args.entry.isEmpty, args.entry.utf8.count <= 2048, !args.entry.contains("\0") else {
            throw FloeError.validationFailed("exec.localService entry must be a non-empty workspace-relative path (max 2048 bytes)")
        }
        if let cwd = args.cwd, cwd.isEmpty || cwd.utf8.count > 2048 || cwd.contains("\0") {
            throw FloeError.validationFailed("exec.localService cwd must be a workspace-relative path (max 2048 bytes)")
        }
        guard (1024...65535).contains(args.port) else {
            throw FloeError.validationFailed("exec.localService port must be in 1024...65535, got \(args.port)")
        }
        guard (args.arguments?.count ?? 0) <= 32, args.arguments?.allSatisfy({ $0.utf8.count <= 2048 && !$0.contains("\0") }) != false else {
            throw FloeError.validationFailed("exec.localService arguments: at most 32 entries, each max 2048 bytes")
        }
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let call = context.toolCallID, call.hasPrefix("jobs."),
              let jobID = UUID(uuidString: String(call.dropFirst(5))),
              let job = try await store.job(id: jobID), job.conversationID == context.conversationID,
              let environment = context.environment, let root = context.workspaceRootURL else {
            throw FloeError.validationFailed("Start this persistent service through jobs.submit in the current workspace")
        }
        try context.cancellation.throwIfCancelled()
        try context.authorizeWorkspacePath(args.entry)
        try context.authorizeWorkspacePath(args.cwd ?? ".")
        let guardPaths = WorkspacePathGuard(rootURL: root)
        let entry = try guardPaths.resolve(args.entry), cwd = try guardPaths.resolve(args.cwd ?? ".")
        guard (try entry.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true,
              (try cwd.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
            throw FloeError.validationFailed("Service entry and working directory must exist")
        }
        // Phase 2: services run inside the environment's Linux guest only —
        // the in-process NodeMobile/CPython workers are gone. Only the
        // invocation identity and the loopback port cross into the guest; the
        // supervisor supplies guest HOME/TMPDIR/PATH/NODE_PATH itself.
        var variables: [String: String] = [:]
        variables["FLOE_ENVIRONMENT_ID"] = environment.id
        variables["PORT"] = String(args.port); variables["FLOE_SERVICE_PORT"] = String(args.port)
        guard Self.reserve(args.port) else { throw FloeError.validationFailed("Another managed service owns this port") }
        defer { Self.release(args.port) }
        let endpoint = URL(string: "http://127.0.0.1:\(args.port)/")!
        let delegate = ServiceProbeDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        configuration.urlCache = nil
        let probe = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { probe.invalidateAndCancel(); BrowserURLPolicy.revokeService(owner: jobID) }
        // Reject an already occupied endpoint before starting, never attribute
        // another application's listener to this newly created service.
        var request = URLRequest(url: endpoint); request.httpMethod = "HEAD"
        if await Self.responds(probe, request: request) {
            throw FloeError.validationFailed("The requested service port is already responding; choose another port")
        }
        // The service runs inside the environment's guest: the process is
        // detached there, its log is appended to a file in the environment
        // layer (readable here through the same 9p share) and its port is
        // published with slirp host forwarding, so the preview/probe path
        // below is identical to the retired native one.
        guard await FloePlatformServices.shared.linuxEnvironmentOwned(id: environment.id),
              let controller = FloePlatformServices.shared.linuxLocalServiceController() else {
            throw FloeError.validationFailed(ManagedPythonInstallService.linuxRequiredMessage)
        }
        return try await Self.runGuestService(
            controller: controller,
            args: args,
            jobID: jobID,
            conversationID: job.conversationID,
            environment: environment,
            entry: entry,
            cwd: cwd,
            variables: variables,
            endpoint: endpoint,
            probe: probe,
            context: context,
            store: store
        )
    }

    /// Linux environment variant of the ownership loop. The guest process is
    /// detached and its log lives in a 9p file, so "status" is a bounded tail
    /// read and cancellation is an explicit guest KILL rather than a signal to
    /// an in-process worker.
    private static func runGuestService(
        controller: any LinuxGuestLocalServiceControlling,
        args: Arguments,
        jobID: UUID,
        conversationID: UUID,
        environment: ToolEnvironment,
        entry: URL,
        cwd: URL,
        variables: [String: String],
        endpoint: URL,
        probe: URLSession,
        context: ToolContext,
        store: BackgroundJobStore
    ) async throws -> ToolExecutionOutput {
        // The log must live inside the environment layer so the guest and the
        // host read the same 9p file.
        let logDirectory = environment.writableLayerURL.appendingPathComponent("services", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let logFile = logDirectory.appendingPathComponent(jobID.uuidString + ".log")
        let request = LinuxGuestLocalServiceRequest(
            entry: entry.path,
            runtime: args.runtime == "node" ? .node : .python,
            arguments: args.arguments ?? [],
            workingDirectory: cwd.path,
            port: args.port,
            logFile: logFile,
            environment: variables
        )
        var snapshot = LocalServiceProgress(state: "starting", runtime: args.runtime, stdout: "", stderr: "", truncated: false)
        let handle: LinuxGuestLocalServiceHandle
        do {
            // Lazy activation: start an owned-but-stopped guest on demand so
            // a service request never dies on "not running" alone.
            try await FloePlatformServices.shared.activateLinuxGuest(id: environment.id)
            handle = try await controller.startLocalService(
                environmentID: environment.id,
                request: request,
                cancellation: context.cancellation
            )
        } catch {
            throw FloeError.validationFailed(SecretRedactor.redact(String(describing: error)))
        }
        var stopRequested = false
        var stopSent = false
        var probeRequest = URLRequest(url: endpoint); probeRequest.httpMethod = "HEAD"
        while true {
            if context.cancellation.isCancelled { stopRequested = true }
            if stopRequested && !stopSent {
                stopSent = true
                await controller.stopLocalService(handle)
            }
            let guest = await controller.localServiceSnapshot(handle)
            snapshot.state = guest.state
            snapshot.stdout = guest.stdout
            snapshot.stderr = guest.stderr
            snapshot.truncated = guest.truncated
            if let error = guest.lastError, !error.isEmpty, guest.state != "stopped" {
                snapshot.stderr += (snapshot.stderr.isEmpty ? "" : "\n") + error
            }
            if ["notFound", "stopped", "completed", "failed", "unavailable"].contains(snapshot.state) { break }
            if stopRequested {
                snapshot.state = "stopping"; snapshot.previewURL = nil
                BrowserURLPolicy.revokeService(owner: jobID)
            } else if snapshot.state == "running", await responds(probe, request: probeRequest) {
                snapshot.previewURL = endpoint.absoluteString
                BrowserURLPolicy.authorizeService(endpoint, owner: jobID, conversationID: conversationID)
            } else {
                snapshot.previewURL = nil; BrowserURLPolicy.revokeService(owner: jobID)
            }
            snapshot.boundAndRedact()
            do { try await store.updateProgress(id: jobID, data: JSONEncoder().encode(snapshot)) }
            catch { stopRequested = true } // Persistence failure must not orphan a worker.
            try? await Task.sleep(for: .seconds(2))
        }
        if !stopSent, snapshot.state == "running" || snapshot.state == "starting" {
            await controller.stopLocalService(handle)
        }
        snapshot.previewURL = nil
        snapshot.boundAndRedact()
        try await store.updateProgress(id: jobID, data: JSONEncoder().encode(snapshot))
        return ToolExecutionOutput(digesting: String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self),
            exitStatus: stopRequested || snapshot.state == "completed" ? 0 : 1)
    }
}
