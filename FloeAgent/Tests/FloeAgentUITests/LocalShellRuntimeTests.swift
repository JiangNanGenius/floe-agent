#if canImport(UIKit)
import Foundation
import Darwin
import Testing
import FloeExecution
import FloeTools
@testable import FloeApp

@Suite("FloeApp.LocalShell", .serialized)
struct LocalShellRuntimeTests {
    @Test(.timeLimit(.minutes(3))) func managedNpmAndPnpmInstallAndExecuteRealPackages() async throws {
        let runtime = IOSSystemNodeRuntime.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let owner = UUID().uuidString
        defer { if !FloeNodeHasActiveTask(owner) { try? FileManager.default.removeItem(at: root) } }
        let npm = try #require(FloeNodeBundledToolPath("npm"))
        let env = ToolEnvironment(id: owner, writableLayerURL: root, layerURLs: [root], variables: ["FLOE_ENVIRONMENT_ID": owner])
        let installer = ManagedNodeInstallService(runtime: runtime, npmEntry: npm) { environment, directory in
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
        // `pkg` remains the limited compatibility catalog; the configured App
        // replaces `apt` with PackagesCLI, where `update` is a valid operation.
        let result = await IOSSystemShellBackend().run(.init(command: "pkg update", cwd: ".", rootURL: root,
            timeout: 5, sessionID: UUID().uuidString), cancellation: nil)
        guard case .exited(let code, _, let errors, _, _, _) = result else {
            Issue.record("Unsupported package command did not terminate: \(result)"); return
        }
        #expect(code == 2)
        #expect(errors.contains("unsupported command"))
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

    @Test(.timeLimit(.minutes(1))) func timeoutRetainsWorkerUntilItStopsAndNextRunCanProceed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = IOSSystemShellBackend()
        let id = UUID().uuidString
        let first = await backend.run(.init(command: "sleep 2", cwd: ".", rootURL: root, timeout: 0.1, sessionID: id), cancellation: nil)
        guard case .timedOut = first else { Issue.record("Expected sleep timeout: \(first)"); return }
        let next = await backend.run(.init(command: "printf 'after-worker'", cwd: ".", rootURL: root, timeout: 5, sessionID: UUID().uuidString), cancellation: nil)
        guard case .exited(let code, let output, _, _, _, _) = next else { Issue.record("Worker lease did not recover: \(next)"); return }
        #expect(code == 0 && output == "after-worker")
        #expect(!FloeShellHasActiveWorker(id))
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
