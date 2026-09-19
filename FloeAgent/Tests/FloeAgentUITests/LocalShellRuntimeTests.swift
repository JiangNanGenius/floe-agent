#if canImport(UIKit)
import Foundation
import Darwin
import Testing
import FloeExecution
import FloeTools
import FloePersistence
@testable import FloeApp

@Suite("FloeApp.LocalShell", .serialized)
struct LocalShellRuntimeTests {
    @Test func serviceProgressStaysBoundedAfterJSONEscaping() throws {
        var progress = LocalServiceProgress(state: "running", runtime: "python", stdout: String(repeating: "\0", count: 30_000), stderr: String(repeating: "错误", count: 30_000), truncated: false)
        progress.boundAndRedact()
        let encoded = try JSONEncoder().encode(progress)
        #expect(encoded.count < 65_536)
        #expect(progress.truncated)
        #expect(try JSONDecoder().decode(LocalServiceProgress.self, from: encoded).state == "running")
    }
    @Test(.timeLimit(.minutes(2))) func serviceToolPublishesLivePreviewAndRevokesAfterStop() async throws {
        for runtime in ["node", "python"] {
            let database = try DatabaseManager.inMemory()
            try await database.migrate()
            let conversation = UUID(), run = UUID(), owner = UUID().uuidString
            try await database.writer { db in
                try db.execute(sql: "INSERT INTO conversations (id,title,created_at,updated_at) VALUES (?, 'Service test', ?, ?)", arguments: [conversation.uuidString, Date(), Date()])
                try db.execute(sql: "INSERT INTO runs (id,conversation_id,state,goal,started_at) VALUES (?,?,'running','Service test',?)", arguments: [run.uuidString, conversation.uuidString, Date()])
            }
            let socketFD = socket(AF_INET, SOCK_STREAM, 0)
            #expect(socketFD >= 0)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &address) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &address) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
            }
            close(socketFD)
            #expect(bound == 0 && named == 0)
            let port = Int(UInt16(bigEndian: address.sin_port))
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { if !FloeNodeHasActiveTask(owner) && !CPythonLocalRuntime.hasActiveWork(environmentID: owner) { try? FileManager.default.removeItem(at: root) } }
            let entry = runtime == "node" ? "server.cjs" : "server.py"
            let script = runtime == "node" ? "require('node:http').createServer((q,r)=>r.end('floe-service')).listen(Number(process.env.PORT),'127.0.0.1'); console.log('service-ready');" : """
            import os
            from http.server import HTTPServer, BaseHTTPRequestHandler
            class Handler(BaseHTTPRequestHandler):
                def do_HEAD(self):
                    self.send_response(200); self.end_headers()
                def do_GET(self):
                    self.send_response(200); self.end_headers(); self.wfile.write(b'floe-service')
            print('service-ready', flush=True)
            HTTPServer(('127.0.0.1', int(os.environ['PORT'])), Handler).serve_forever(poll_interval=0.1)
            """
            try Data(script.utf8).write(to: root.appendingPathComponent(entry))
            let args = LocalServiceTool.Arguments(runtime: runtime, entry: entry, port: port)
            let store = BackgroundJobStore(database: database)
            let job = try await store.save(BackgroundJob(conversationID: conversation, runID: run, kind: .tool,
                targetTool: "exec.localService", payloadJSON: JSONEncoder().encode(args), state: .running,
                workspaceRootPath: root.path, environmentID: owner))
            let token = CancellationToken()
            let tool = LocalServiceTool(store: store)
            try tool.validate(args)
            let context = ToolContext(runID: run, toolCallID: "jobs." + job.id.uuidString, workspaceRootURL: root,
                cancellation: token, environmentID: owner, conversationID: conversation,
                environment: ToolEnvironment(id: owner, writableLayerURL: root, layerURLs: [root], variables: [:]))
            let task = Task { try await tool.execute(args, context: context) }
            do {
                var progress: LocalServiceProgress?
                for _ in 0..<100 {
                    if let data = try await store.job(id: job.id)?.progressJSON { progress = try JSONDecoder().decode(LocalServiceProgress.self, from: data) }
                    if progress?.previewURL != nil { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                let urlText = try #require(progress?.previewURL)
                let url = try BrowserURLPolicy.validate(urlText, conversationID: conversation)
                let (data, _) = try await URLSession.shared.data(from: url)
                #expect(String(decoding: data, as: UTF8.self) == "floe-service")
                // HTTP readiness and the worker's stdout arrive independently.
                // The snapshot preceding the successful probe may not contain
                // console output yet. Still require that output to reach the
                // durable job while the service remains alive.
                for _ in 0..<50 where progress?.stdout.contains("service-ready") != true {
                    try await Task.sleep(for: .milliseconds(100))
                    if let data = try await store.job(id: job.id)?.progressJSON {
                        progress = try JSONDecoder().decode(LocalServiceProgress.self, from: data)
                    }
                }
                #expect(progress?.stdout.contains("service-ready") == true)
                token.cancel()
                #expect(try await task.value.exitStatus == 0)
                #expect(throws: BrowserPolicyError.self) { try BrowserURLPolicy.validate(urlText, conversationID: conversation) }
                #expect(!FloeNodeHasActiveTask(owner))
                #expect(!CPythonLocalRuntime.hasActiveWork(environmentID: owner))
            } catch {
                token.cancel()
                _ = try? await task.value
                throw error
            }
        }
    }

    @Test(.timeLimit(.minutes(3))) func managedNpmAndPnpmInstallAndExecuteRealPackages() async throws {
        let runtime = IOSSystemNodeRuntime.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let owner = UUID().uuidString
        defer { if !FloeNodeHasActiveTask(owner) { try? FileManager.default.removeItem(at: root) } }
        let npm = try #require(FloeNodeBundledToolPath("npm"))
        let env = ToolEnvironment(id: owner, writableLayerURL: root, layerURLs: [root], variables: ["FLOE_ENVIRONMENT_ID": owner])
        let installer = ManagedNodeInstallService(runtime: runtime, npmEntry: npm, pnpmEntry: FloeNodeBundledToolPath("pnpm")) { environment, directory in
            IOSSystemNodeRuntime.defaultEnvironment(containerRoot: environment.writableLayerURL, workspaceRoot: directory)
        }
        _ = try await installer.change(env, specification: "is-number@7.0.0", remove: false, cancellation: CancellationToken())
        var variables = IOSSystemNodeRuntime.defaultEnvironment(containerRoot: root, workspaceRoot: root)
        variables["FLOE_ENVIRONMENT_ID"] = owner
        variables["NODE_PATH"] = root.appendingPathComponent("usr/lib/node_modules").path
        let imported = await runtime.run(.init(entryScript: nil, arguments: ["-e", "console.log(require('is-number')(42))"], workingDirectory: root, environment: variables), cancellation: nil)
        guard case .exited(let code, let output, let errors, _, _) = imported else { Issue.record("Managed npm import failed: \(imported)"); return }
        #expect(code == 0 && output == "true\n", "\(errors)")
        _ = try await installer.change(env, specification: "is-number", remove: true, cancellation: CancellationToken())
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("usr/lib/node_modules/is-number").path))

        _ = try await installer.change(env, specification: "is-number@7.0.0", remove: false, manager: .pnpm, cancellation: CancellationToken())
        let managedPnpm = await runtime.run(.init(entryScript: nil, arguments: ["-e", "console.log(require('is-number')(42))"], workingDirectory: root, environment: variables), cancellation: nil)
        guard case .exited(let managedCode, let managedOutput, let managedErrors, _, _) = managedPnpm else { Issue.record("Managed pnpm import failed: \(managedPnpm)"); return }
        #expect(managedCode == 0 && managedOutput == "true\n", "\(managedErrors)")
        let esmEntry = root.appendingPathComponent("environment-import.mjs")
        try Data("import isNumber from 'is-number'; console.log(isNumber(42));".utf8).write(to: esmEntry)
        let esm = await runtime.run(.init(entryScript: esmEntry.path, arguments: [], workingDirectory: root,
                                         environment: variables), cancellation: nil)
        guard case .exited(let esmCode, let esmOutput, let esmErrors, _, _) = esm else { Issue.record("ESM import failed: \(esm)"); return }
        #expect(esmCode == 0 && esmOutput == "true\n", "\(esmErrors)")
        _ = try await installer.change(env, specification: "is-number", remove: true, manager: .pnpm, cancellation: CancellationToken())
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("usr/lib/node_modules/is-number").path))

        let project = root.appendingPathComponent("pnpm-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data(#"{"name":"floe-registry-test","version":"1.0.0","private":true}"#.utf8).write(to: project.appendingPathComponent("package.json"))
        let pnpm = try #require(FloeNodeBundledToolPath("pnpm"))
        variables = IOSSystemNodeRuntime.defaultEnvironment(containerRoot: root, workspaceRoot: project)
        variables["FLOE_ENVIRONMENT_ID"] = owner
        variables["CI"] = "1"
        let installed = await runtime.run(.init(entryScript: pnpm,
            arguments: ["add", "--ignore-scripts", "--config.node-linker=hoisted", "--package-import-method=copy", "--registry=https://registry.npmjs.org/", "is-number@7.0.0"],
            workingDirectory: project, environment: variables, timeout: 60), cancellation: nil)
        guard case .exited(let installCode, _, let installErrors, _, _) = installed else { Issue.record("pnpm install failed: \(installed)"); return }
        #expect(installCode == 0, "\(installErrors)")
        let loaded = await runtime.run(.init(entryScript: nil, arguments: ["-e", "console.log(require('is-number')(42))"], workingDirectory: project, environment: variables), cancellation: nil)
        guard case .exited(let loadCode, let value, let loadErrors, _, _) = loaded else { Issue.record("pnpm import failed: \(loaded)"); return }
        #expect(loadCode == 0 && value == "true\n", "\(loadErrors)")
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent("pnpm-lock.yaml").path))
    }

    @Test(.timeLimit(.minutes(1))) func nodeServiceSurvivesForegroundCommandsAndStopsOnlyItsOwner() async throws {
        let runtime = IOSSystemNodeRuntime.shared
        let owner = "service-test-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory
        let started = await runtime.startService(.init(entryScript: nil, arguments: ["-e", """
            const server = require('node:http').createServer((req,res) => res.end('service-response'));
            server.listen(0,'127.0.0.1',() => console.log(server.address().port));
            """], workingDirectory: root, environment: ["FLOE_ENVIRONMENT_ID": owner]), environmentID: owner)
        let id = try #require(started.serviceID)
        do {
            #expect(started.state == "started")
            #expect(FloeNodeHasActiveTask(owner))
            var port: Int?
            for _ in 0..<100 {
                let status = await runtime.serviceStatus(id: id, environmentID: owner)
                port = Int(status.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
                if port != nil { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            let endpointPort = try #require(port)
            let wrongOwner = await runtime.stopService(id: id, environmentID: "different-environment")
            #expect(wrongOwner.state == "notFound")
            for _ in 0..<3 {
                let response = await runtime.run(.init(entryScript: nil, arguments: ["-e", """
                    require('node:http').get('http://127.0.0.1:\(endpointPort)/',r=>r.on('data',b=>process.stdout.write(b))).on('error',e=>{console.error(e.code);process.exitCode=1});
                    """], workingDirectory: root, timeout: 5), cancellation: nil)
                guard case .exited(let code, let output, let errors, _, _) = response else {
                    Issue.record("Foreground HTTP call failed while service was alive: \(response)")
                    break
                }
                #expect(code == 0 && output == "service-response", "\(errors)")
            }
            try await runtime.stopServices(environmentID: owner)
            #expect(!FloeNodeHasActiveTask(owner))
            let stopped = await runtime.serviceStatus(id: id, environmentID: owner)
            #expect(stopped.state == "notFound")
            let closed = await runtime.run(.init(entryScript: nil, arguments: ["-e", """
                require('node:http').get('http://127.0.0.1:\(endpointPort)/',r=>{r.resume();process.exitCode=1}).on('error',e=>console.log(e.code));
                """], workingDirectory: root, timeout: 5), cancellation: nil)
            guard case .exited(let code, let output, _, _, _) = closed else {
                Issue.record("Stopped endpoint check did not finish: \(closed)")
                return
            }
            #expect(code == 0 && output.contains("ECONNREFUSED"))
        } catch {
            try? await runtime.stopServices(environmentID: owner)
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1))) func unsupportedPackageCommandsCannotReportSuccess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // All package aliases now use the same environment-bound service.
        // Even `pkg` must fail without an owner instead of inventing a root.
        let result = await IOSSystemShellBackend().run(.init(command: "pkg update", cwd: ".", rootURL: root,
            timeout: 5, sessionID: UUID().uuidString), cancellation: nil)
        guard case .exited(let code, _, let errors, _, _, _) = result else {
            Issue.record("Unsupported package command did not terminate: \(result)"); return
        }
        #expect(code == 100)
        #expect(errors.contains("no active container"))
        // The full apt implementation must also fail when this bare shell
        // request has no resolved environment. It must not invent a container.
        let unbound = await IOSSystemShellBackend().run(.init(command: "apt update", cwd: ".", rootURL: root,
            timeout: 5, sessionID: UUID().uuidString), cancellation: nil)
        guard case .exited(let unboundCode, let output, let unboundErrors, _, _, _) = unbound else {
            Issue.record("Unbound apt did not terminate: \(unbound)"); return
        }
        #expect(unboundCode == 100)
        #expect(output.isEmpty)
        #expect(unboundErrors.contains("no active container"))
    }

    @Test(.timeLimit(.minutes(1))) func pipelineTimeoutDrainsAndNextCommandRuns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = IOSSystemShellBackend()
        let first = await backend.run(.init(command: "while :; do printf data; done | cat", cwd: ".", rootURL: root,
            timeout: 0.2, sessionID: UUID().uuidString), cancellation: nil)
        guard case .timedOut = first else { Issue.record("Expected pipeline timeout: \(first)"); return }
        let next = await backend.run(.init(command: "printf after-pipeline", cwd: ".", rootURL: root,
            timeout: 5, sessionID: UUID().uuidString), cancellation: nil)
        guard case .exited(let code, let out, _, _, _, _) = next else { Issue.record("Pipeline retained its output stream: \(next)"); return }
        #expect(code == 0 && out == "after-pipeline")
    }

    @Test(.timeLimit(.minutes(2))) func httpsThroughCurlPythonAndNode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = IOSSystemShellBackend()
        let commands = [
            "curl --fail --silent --show-error --location --max-time 20 https://example.com",
            "python3 -c 'import ssl,urllib.request; assert ssl.create_default_context().verify_mode == ssl.CERT_REQUIRED; r=urllib.request.urlopen(\"https://example.com\",timeout=20); print(r.read(16384).decode())'",
            "node -e 'require(\"https\").get(\"https://example.com\",r=>{if(r.statusCode!==200)process.exitCode=1;r.on(\"data\",b=>process.stdout.write(b));}).on(\"error\",e=>{console.error(e.code,e.message);process.exitCode=1})'"
        ]
        for command in commands {
            let result = await backend.run(.init(command: command, cwd: ".", rootURL: root,
                timeout: 25, sessionID: UUID().uuidString), cancellation: nil)
            guard case .exited(let code, let output, let errors, _, _, _) = result else {
                Issue.record("HTTPS runtime failed: \(result)"); continue
            }
            #expect(code == 0, "\(errors)")
            #expect(output.contains("Example Domain"), "HTTPS body was not received: \(errors)")
        }
    }

    @Test(.timeLimit(.minutes(1))) func nativeNodeLiveInputAndCancellation() async throws {
        var descriptors: [Int32] = [-1, -1]
        #expect(pipe(&descriptors) == 0)
        let reader = descriptors[0], writer = descriptors[1]
        defer { close(reader); close(writer) }
        let root = FileManager.default.temporaryDirectory
        let runtime = IOSSystemNodeRuntime()
        let feeder = Task.detached {
            try? await Task.sleep(for: .milliseconds(200))
            let bytes = Array("live-native\n".utf8)
            _ = bytes.withUnsafeBytes { write(writer, $0.baseAddress, $0.count) }
        }
        let first = await runtime.run(.init(entryScript: nil,
            arguments: ["-e", "process.stdin.once('data', b => { console.log(b.toString().trim()); process.exit(0); })"],
            workingDirectory: root, stdinFileDescriptor: reader, timeout: 5), cancellation: nil)
        await feeder.value
        guard case .exited(let code, let out, let error, _, _) = first else {
            Issue.record("Live native input failed: \(first)"); return
        }
        #expect(code == 0 && out == "live-native\n", "\(error)")
        let token = CancellationToken()
        let cancel = Task { try? await Task.sleep(for: .milliseconds(200)); token.cancel() }
        let waiting = await runtime.run(.init(entryScript: nil,
            arguments: ["-e", "require('fs').readFileSync(0, 'utf8')"], workingDirectory: root,
            stdinFileDescriptor: reader, timeout: 5), cancellation: token)
        cancel.cancel()
        #expect(waiting == .cancelled)
        let next = await runtime.run(.init(entryScript: nil, arguments: ["-e", "console.log('after-input')"],
            workingDirectory: root, timeout: 5), cancellation: nil)
        guard case .exited(let nextCode, let nextOut, _, _, _) = next else {
            Issue.record("Native worker did not release input: \(next)"); return
        }
        #expect(nextCode == 0 && nextOut == "after-input\n")
    }

    @Test(.timeLimit(.minutes(2))) func batchWorkflowUsesShellPythonAndNodeRepeatedly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = IOSSystemShellBackend()
        for _ in 0..<3 {
            let result = await backend.run(.init(command: """
            set -e
            mkdir -p batch
            for x in one two three; do printf '%s\\n' "$x"; done | tr a-z A-Z | sort > batch/words.txt
            export FLOE_SCRIPT_VALUE=from-shell
            node -e 'const fs=require("fs"); if(process.env.FLOE_SCRIPT_VALUE!=="from-shell") throw Error("env missing"); fs.writeFileSync("batch/node.txt","node-ok")'
            python3 -c 'from pathlib import Path; p=Path("batch/words.txt"); assert p.read_text().splitlines()==["ONE","THREE","TWO"]; assert Path("batch/node.txt").read_text()=="node-ok"; import os; assert os.environ["FLOE_SCRIPT_VALUE"]=="from-shell"; print("workflow-ok")'
            """, cwd: ".", rootURL: root, timeout: 30, sessionID: UUID().uuidString), cancellation: nil)
            guard case .exited(let code, let output, let errors, _, _, _) = result else { Issue.record("Script workflow failed: \(result)"); return }
            #expect(code == 0, "\(errors)")
            #expect(output.contains("workflow-ok"), "\(output) \(errors)")
        }
    }

    @Test(.timeLimit(.minutes(1))) func nodeReceivesPipedInputAndShellRecoversFromMissingCommand() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = await IOSSystemShellBackend().run(.init(command: """
        printf 'console.log("stdin-ok")' | node -
        printf 'print("python-stdin-ok")' | python3 -
        python3 -c 'import sys; sys.exit(7)'
        if [ "$?" -ne 7 ]; then exit 8; fi
        printf 'input' | floe_missing_qualification_command
        result=$?
        if [ "$result" -eq 127 ]; then printf 'missing-command-ok\\n'; else exit 9; fi
        """, cwd: ".", rootURL: root, timeout: 20, sessionID: UUID().uuidString), cancellation: nil)
        guard case .exited(let code, let output, let errors, _, _, _) = result else { Issue.record("Stdin workflow failed: \(result)"); return }
        #expect(code == 0, "\(errors)")
        #expect(output.contains("stdin-ok"))
        #expect(output.contains("python-stdin-ok"))
        #expect(output.contains("missing-command-ok"))
    }

    @Test(.timeLimit(.minutes(1))) func timeoutDoesNotPoisonTheGateAndNextRunProceeds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = IOSSystemShellBackend()
        let id = UUID().uuidString
        // `sleep` is a cooperative Floe command: when its deadline passes the
        // bridge requests cooperative cancellation and the worker actually
        // stops inside the bounded grace. The worker's own teardown then
        // releases the run gate before this caller returns, so the next run
        // starts immediately — the engine never hosts two commands at once.
        let first = await backend.run(.init(command: "sleep 5", cwd: ".", rootURL: root, timeout: 0.1, sessionID: id), cancellation: nil)
        guard case .timedOut = first else { Issue.record("Expected sleep timeout: \(first)"); return }
        // Output produced before the deadline is preserved, never a fabricated
        // timeout after a hung finalizer.
        let second = await backend.run(.init(command: "printf 'after-worker'", cwd: ".", rootURL: root, timeout: 5, sessionID: UUID().uuidString), cancellation: nil)
        guard case .exited(let code, let output, _, _, _, _) = second else { Issue.record("Worker lease did not recover: \(second)"); return }
        #expect(code == 0 && output == "after-worker")
        // The stopped worker is untracked again; nothing quarantined remains.
        let deadline = Date().addingTimeInterval(8)
        while FloeShellHasActiveWorker(id) && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!FloeShellHasActiveWorker(id))
    }

    @Test(.timeLimit(.minutes(1))) func timedOutCommandKeepsPartialOutputAndNextRunProceeds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = IOSSystemShellBackend()
        let first = await backend.run(.init(command: "printf 'partial-output\\n'; sleep 5", cwd: ".", rootURL: root,
            timeout: 0.4, sessionID: UUID().uuidString), cancellation: nil)
        guard case .timedOut(let partial, _, _) = first else { Issue.record("Expected timeout with partial output: \(first)"); return }
        #expect(partial.contains("partial-output"))
        let next = await backend.run(.init(command: "printf 'after-timeout'", cwd: ".", rootURL: root,
            timeout: 5, sessionID: UUID().uuidString), cancellation: nil)
        guard case .exited(let code, let output, _, _, _, _) = next else { Issue.record("Gate stayed poisoned: \(next)"); return }
        #expect(code == 0 && output == "after-timeout")
    }

    @Test(.timeLimit(.minutes(1))) func interactiveSessionReceivesInputAndReturnsOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = IOSSystemShellBackend()
        let sessionID = UUID().uuidString.lowercased()
        let opened = try await backend.openSession(.init(cwd: ".", rootURL: root, sessionID: sessionID), cancellation: nil)
        #expect(opened.alive)
        do {
            // The interactive shell must read the session's stdin descriptor
            // (thread_stdin), not the App's process fd 0.
            let typed = try await backend.exchangeSession(.init(sessionID: sessionID,
                input: "printf 'interactive-ok\\n'\n", waitMs: 500, maxBytes: 4096), cancellation: nil)
            var received = typed.output
            for _ in 0..<10 where !received.contains("interactive-ok") {
                let next = try await backend.exchangeSession(.init(sessionID: sessionID, input: nil,
                    waitMs: 500, maxBytes: 4096), cancellation: nil)
                received += next.output
                if !next.alive { break }
            }
            #expect(received.contains("interactive-ok"), "interactive session returned: \(received)")
        } catch {
            await backend.closeSession(sessionID: sessionID)
            throw error
        }
        await backend.closeSession(sessionID: sessionID)
    }

    @Test func posixLoopAndPipe() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = await IOSSystemShellBackend().run(.init(command: "for x in hello world; do echo \"$x\"; done | tr a-z A-Z", cwd: ".", rootURL: root, sessionID: UUID().uuidString), cancellation: nil)
        guard case .exited(let code, let stdout, let stderr, _, _, _) = outcome else { Issue.record("Unexpected outcome: \(outcome)"); return }
        #expect(code == 0, "\(stderr)")
        #expect(stdout == "HELLO\nWORLD\n")
    }

    @Test func environmentDoesNotLeakAcrossRuns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = IOSSystemShellBackend()
        let first = await backend.run(.init(command: "printf '%s' \"$FLOE_SHELL_TEST_SCOPE\"", cwd: ".", rootURL: root, environment: ["FLOE_SHELL_TEST_SCOPE": "scoped"], sessionID: UUID().uuidString), cancellation: nil)
        let second = await backend.run(.init(command: "printf '%s' \"${FLOE_SHELL_TEST_SCOPE-unset}\"", cwd: ".", rootURL: root, sessionID: UUID().uuidString), cancellation: nil)
        guard case .exited(let firstCode, let firstOut, _, _, _, _) = first,
              case .exited(let secondCode, let secondOut, _, _, _, _) = second else { Issue.record("Shell environment runs did not exit"); return }
        #expect(firstCode == 0 && firstOut == "scoped")
        #expect(secondCode == 0 && secondOut == "unset")
    }

    @Test func inputOutputAndExitStatus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = await IOSSystemShellBackend().run(.init(command: "cat; exit 7", cwd: ".", rootURL: root, stdin: String(repeating: "a", count: 32768), maxOutputBytes: 100, sessionID: UUID().uuidString), cancellation: nil)
        guard case .exited(let code, let stdout, _, let truncated, _, _) = outcome else { Issue.record("Unexpected outcome: \(outcome)"); return }
        #expect(code == 7)
        #expect(stdout.utf8.count == 100)
        #expect(truncated)
    }
    @Test(.timeLimit(.minutes(1))) func cancellationReturnsAndNextCommandRuns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = IOSSystemShellBackend()
        let token = CancellationToken()
        let trigger = Task { try? await Task.sleep(for: .milliseconds(200)); token.cancel() }
        defer { trigger.cancel() }
        let cancelled = await backend.run(.init(command: "while :; do :; done", cwd: ".", rootURL: root, timeout: 5, sessionID: UUID().uuidString), cancellation: token)
        #expect(cancelled == .cancelled)
        let next = await backend.run(.init(command: "echo after-cancel", cwd: ".", rootURL: root, sessionID: UUID().uuidString), cancellation: nil)
        guard case .exited(let code, let output, _, _, _, _) = next else { Issue.record("Execution after cancellation failed"); return }
        #expect(code == 0 && output == "after-cancel\n")
    }

    @Test(.timeLimit(.minutes(1))) func loopTimeoutReturnsWithoutTerminatingCaller() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = await IOSSystemShellBackend().run(.init(command: "while :; do :; done", cwd: ".", rootURL: root, timeout: 0.2, sessionID: UUID().uuidString), cancellation: nil)
        guard case .timedOut = result else { Issue.record("Loop did not report timeout"); return }
    }

}
#endif
