#if canImport(UIKit)
import Foundation
import Darwin
import Testing
import FloeCore
import FloeExecution
import FloePersistence
import FloeTools
import FloeEnvironments
@testable import FloeApp

/// Real production-runtime acceptance for two open lifecycle gaps recorded in
/// `docs/qualification/build179-release/runtime/README.md`:
///   1. `BackgroundJobService.restartLocalService` for Node and Python must
///      produce a service whose HTTP endpoint actually responds, then stop.
///   2. Deleting an environment through `FloePlatformServices.deleteEnvironment`
///      must wait for its owned Node/Python services to stop (port unreachable)
///      while an unrelated environment keeps serving.
///
/// These tests use the real app-hosted environment registry and the real
/// `EnvironmentExecutionCoordinator` routing injected by `AppEnvironment`.
/// They never substitute a mock runtime. They require the FloeApp test host
/// (`FloeAppTests`) and a simulator/macOS host with the bundled Node/CPython
/// runtimes; on a build without them they fail loudly instead of skipping.
@Suite("FloeApp.LocalServiceLifecycle", .serialized)
struct LocalServiceLifecycleTests {

    // MARK: - Fixtures

    private struct EnvironmentFixture {
        /// Canonical workspace root used as the job workspace and routing key.
        let root: URL
        /// Real project container id created by the app platform service.
        let id: String
        /// sha256 of the canonical root; equals `ContainerRecord.ownerID`.
        let owner: String
    }

    private func makeEnvironment(_ label: String) async throws -> EnvironmentFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-lifecycle-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        // Production path: the app registry materializes the project container
        // and records the workspace→container mapping used by routing.
        try await FloePlatformServices.shared.prepareWorkspaceEnvironment(root: root)
        let owner = FloeDigest.sha256Hex(Data(root.path.utf8))
        let reports = try await FloePlatformServices.shared.environmentReports()
        let report = try #require(
            reports.first(where: { $0.record.kind == .project && $0.record.ownerID == owner }),
            "prepareWorkspaceEnvironment did not register a project environment for \(root.path)"
        )
        return EnvironmentFixture(root: root, id: report.record.id, owner: owner)
    }

    private func cleanup(_ fixture: EnvironmentFixture) async {
        // Failure paths may still own a native worker whose durable job never
        // reached a terminal state. Stop the owned runtimes first so deletion
        // cannot orphan a Node/Python service and leak across tests.
        await stopOwnedServices(fixture.id)
        try? await FloePlatformServices.shared.deleteEnvironment(id: fixture.id)
        try? FileManager.default.removeItem(at: fixture.root)
    }

    private func databaseFixture() async throws -> (DatabaseManager, UUID, UUID) {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversation = UUID(), run = UUID()
        try await database.writer { db in
            try db.execute(sql: "INSERT INTO conversations (id,title,created_at,updated_at) VALUES (?, 'Lifecycle test', ?, ?)",
                           arguments: [conversation.uuidString, Date(), Date()])
            try db.execute(sql: "INSERT INTO runs (id,conversation_id,state,goal,started_at) VALUES (?,?,'running','Lifecycle test',?)",
                           arguments: [run.uuidString, conversation.uuidString, Date()])
        }
        return (database, conversation, run)
    }

    private func freeLoopbackPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #expect(fd >= 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        close(fd)
        #expect(bound == 0 && named == 0)
        let port = Int(UInt16(bigEndian: address.sin_port))
        guard (1024...65535).contains(port) else {
            throw FloeError.validationFailed("Could not reserve a loopback port (got \(port))")
        }
        return port
    }

    private func httpBody(_ port: Int, timeout: TimeInterval = 2) async -> String? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    // MARK: - 1. BackgroundJobService.restartLocalService

    @Test(.timeLimit(.minutes(3)))
    func restartLocalServiceServesRealHTTPForNodeAndPython() async throws {
        try #require(FloePlatformServices.shared.isConfigured,
                     "FloePlatformServices is not configured in this test host; the app environment did not initialize")

        for runtime in ["node", "python"] {
            let environment = try await makeEnvironment("restart-\(runtime)")
            do {
                try await runRestartScenario(runtime: runtime, environment: environment)
            } catch {
                await cleanup(environment)
                throw error
            }
            await cleanup(environment)
        }
    }

    private func runRestartScenario(runtime: String, environment: EnvironmentFixture) async throws {
        let (database, conversation, run) = try await databaseFixture()
        let port = try freeLoopbackPort()
        let entry = runtime == "node" ? "server.cjs" : "server.py"
        let body = "floe-restart-\(runtime)"
        let script = runtime == "node" ? """
            const server = require('node:http').createServer((req,res)=>{res.end('\(body)')});
            server.listen(Number(process.env.PORT),'127.0.0.1',()=>console.log('service-ready'));
            """ : """
            import os
            from http.server import HTTPServer, BaseHTTPRequestHandler
            class Handler(BaseHTTPRequestHandler):
                def do_HEAD(self):
                    self.send_response(200); self.end_headers()
                def do_GET(self):
                    self.send_response(200); self.end_headers(); self.wfile.write(b'\(body)')
                def log_message(self, *args): pass
            print('service-ready', flush=True)
            HTTPServer(('127.0.0.1', int(os.environ['PORT'])), Handler).serve_forever(poll_interval=0.1)
            """
        try Data(script.utf8).write(to: environment.root.appendingPathComponent(entry))

        // A terminal durable job is the exact precondition restartLocalService
        // requires; the payload is the real LocalServiceTool arguments.
        let arguments = LocalServiceTool.Arguments(runtime: runtime, entry: entry, arguments: nil, cwd: nil, port: port)
        let store = BackgroundJobStore(database: database)
        let terminal = try await store.save(BackgroundJob(
            conversationID: conversation, runID: run, kind: .tool, targetTool: "exec.localService",
            payloadJSON: JSONEncoder().encode(arguments), state: .completed,
            workspaceRootPath: environment.root.path, environmentID: environment.id))

        // A runner bound to this store is registered in a private registry so
        // restart acts on the same durable job store the test observes. Tool
        // environment resolution still flows through the app-injected
        // ToolEnvironmentRouting (real EnvironmentExecutionCoordinator).
        let registry = ToolRunnerRegistry()
        registry.register(LocalServiceTool(store: store))
        let service = BackgroundJobService(store: store, registry: registry)

        let restarted = try await service.restartLocalService(id: terminal.id)
        #expect(restarted.id != terminal.id)
        #expect(restarted.targetTool == "exec.localService")
        #expect(restarted.environmentID == environment.id)
        #expect(restarted.workspaceRootPath == environment.root.path)

        let preview = await waitForPreview(service, id: restarted.id)
        let previewURL = try #require(preview, "restarted \(runtime) service never published an HTTP preview")
        let url = try BrowserURLPolicy.validate(previewURL, conversationID: conversation)
        let (data, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == body)

        _ = try await service.cancel(id: restarted.id)
        let finalState = try await waitForTerminal(service, id: restarted.id)
        #expect(finalState.state.isTerminal)
        #expect(!finalState.state.canTransition(to: .running))

        if runtime == "node" {
            #expect(!FloeNodeHasActiveTask(environment.id), "Node worker survived restart cancellation")
        } else {
            #expect(!CPythonLocalRuntime.hasActiveWork(environmentID: environment.id), "Python worker survived restart cancellation")
        }
        #expect(await httpBody(port) == nil, "restarted \(runtime) service still accepted HTTP after cancellation")
        #expect(throws: BrowserPolicyError.self) {
            try BrowserURLPolicy.validate(previewURL, conversationID: conversation)
        }
    }

    private func waitForPreview(_ service: BackgroundJobService, id: UUID) async -> String? {
        for _ in 0..<120 {
            if let job = try? await service.job(id: id) {
                if job.state.isTerminal { return nil }
                if let data = job.progressJSON,
                   let progress = try? JSONDecoder().decode(LocalServiceProgress.self, from: data),
                   let url = progress.previewURL {
                    return url
                }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    private func waitForTerminal(_ service: BackgroundJobService, id: UUID) async throws -> BackgroundJob {
        for _ in 0..<120 {
            if let job = try await service.job(id: id), job.state.isTerminal { return job }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw FloeError.internalError("restarted service job did not reach a terminal state in time")
    }

    // MARK: - 2. Environment deletion stops owned services

    @Test(.timeLimit(.minutes(3)))
    func environmentDeletionStopsOwnedServicesAndLeavesOthersRunning() async throws {
        try #require(FloePlatformServices.shared.isConfigured,
                     "FloePlatformServices is not configured in this test host; the app environment did not initialize")

        let deleted = try await makeEnvironment("delete-a")
        let survivor = try await makeEnvironment("delete-b")
        var services: [(id: String, port: Int, runtime: String, environmentID: String)] = []
        do {
            // Two real services owned by the environment being deleted plus one
            // owned by an independent environment.
            services.append(try await startNodeService(environmentID: deleted.id, root: deleted.root, body: "floe-node-deleted"))
            services.append(try await startPythonService(environmentID: deleted.id, root: deleted.root, body: "floe-python-deleted"))
            services.append(try await startNodeService(environmentID: survivor.id, root: survivor.root, body: "floe-node-survivor"))

            for service in services {
                #expect(await httpBody(service.port) != nil,
                        "\(service.runtime) service for \(service.environmentID) did not answer before deletion")
            }
            #expect(FloeNodeHasActiveTask(deleted.id))
            #expect(CPythonLocalRuntime.hasActiveWork(environmentID: deleted.id))
            #expect(FloeNodeHasActiveTask(survivor.id))

            // Production deletion path: stops sessions, cancels package jobs,
            // stops Node/Python services, waits for workers, then removes the
            // layer. It must not return while an owned port is still listening.
            try await FloePlatformServices.shared.deleteEnvironment(id: deleted.id)

            for service in services where service.environmentID == deleted.id {
                #expect(await httpBody(service.port) == nil,
                        "\(service.runtime) port \(service.port) was still reachable when deleteEnvironment returned")
            }
            #expect(!FloeNodeHasActiveTask(deleted.id))
            #expect(!CPythonLocalRuntime.hasActiveWork(environmentID: deleted.id))

            let reports = try await FloePlatformServices.shared.environmentReports()
            #expect(!reports.contains { $0.record.id == deleted.id }, "deleted environment is still registered")
            #expect(reports.contains { $0.record.id == survivor.id }, "unrelated environment disappeared")

            // The unrelated environment keeps its worker and endpoint.
            #expect(FloeNodeHasActiveTask(survivor.id))
            let survivorService = try #require(services.first { $0.environmentID == survivor.id })
            #expect(await httpBody(survivorService.port) == "floe-node-survivor",
                    "deleting one environment stopped an unrelated environment's service")
        } catch {
            await stopOwnedServices(survivor.id)
            await stopOwnedServices(deleted.id)
            await cleanup(deleted)
            await cleanup(survivor)
            throw error
        }
        await stopOwnedServices(survivor.id)
        await cleanup(deleted)
        await cleanup(survivor)
    }

    private func stopOwnedServices(_ environmentID: String) async {
        try? await IOSSystemNodeRuntime.shared.stopServices(environmentID: environmentID)
        try? await CPythonLocalRuntime.shared.stopServices(environmentID: environmentID)
    }

    private func startNodeService(environmentID: String, root: URL, body: String) async throws -> (id: String, port: Int, runtime: String, environmentID: String) {
        let script = """
            const server = require('node:http').createServer((req,res)=>{res.end('\(body)')});
            server.listen(0,'127.0.0.1',()=>console.log(server.address().port));
            """
        let started = await IOSSystemNodeRuntime.shared.startService(.init(
            entryScript: nil, arguments: ["-e", script], workingDirectory: root,
            environment: ["FLOE_ENVIRONMENT_ID": environmentID]), environmentID: environmentID)
        let id = try #require(started.serviceID, "Node service did not start: \(started.state) \(started.stderr)")
        var port: Int?
        for _ in 0..<200 {
            let status = await IOSSystemNodeRuntime.shared.serviceStatus(id: id, environmentID: environmentID)
            port = Int(status.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            if port != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let boundPort = try #require(port, "Node service never reported its loopback port")
        return (id, boundPort, "node", environmentID)
    }

    private func startPythonService(environmentID: String, root: URL, body: String) async throws -> (id: String, port: Int, runtime: String, environmentID: String) {
        let script = """
            from http.server import HTTPServer, BaseHTTPRequestHandler
            class Handler(BaseHTTPRequestHandler):
                def do_HEAD(self):
                    self.send_response(200); self.end_headers()
                def do_GET(self):
                    self.send_response(200); self.end_headers(); self.wfile.write(b'\(body)')
                def log_message(self, *args): pass
            server = HTTPServer(('127.0.0.1', 0), Handler)
            print(server.server_address[1], flush=True)
            server.serve_forever(poll_interval=0.05)
            """
        let started = await CPythonLocalRuntime.shared.startService(.init(
            script: script,
            pythonContext: .init(environmentID: environmentID, workingDirectory: root.path)),
            environmentID: environmentID)
        let id = try #require(started.serviceID, "Python service did not start: \(started.state) \(started.error ?? "")")
        var port: Int?
        for _ in 0..<200 {
            let status = await CPythonLocalRuntime.shared.serviceStatus(id: id, environmentID: environmentID)
            port = Int(status.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            if port != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let boundPort = try #require(port, "Python service never reported its loopback port")
        return (id, boundPort, "python", environmentID)
    }
}
#endif
