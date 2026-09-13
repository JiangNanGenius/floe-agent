#if canImport(UIKit)
import Foundation
import Darwin
import Testing
import FloeExecution
import FloeTools
@testable import FloeApp

@Suite("FloeApp.LocalShell", .serialized)
struct LocalShellRuntimeTests {
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
