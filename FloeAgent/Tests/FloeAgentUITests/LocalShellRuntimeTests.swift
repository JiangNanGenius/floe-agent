#if canImport(UIKit)
import Foundation
import Testing
import FloeExecution
import FloeTools
@testable import FloeApp

@Suite("FloeApp.LocalShell", .serialized)
struct LocalShellRuntimeTests {
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
        floe_missing_qualification_command
        result=$?
        if [ "$result" -eq 127 ]; then printf 'missing-command-ok\\n'; else exit 9; fi
        """, cwd: ".", rootURL: root, timeout: 20, sessionID: UUID().uuidString), cancellation: nil)
        guard case .exited(let code, let output, let errors, _, _, _) = result else { Issue.record("Stdin workflow failed: \(result)"); return }
        #expect(code == 0, "\(errors)")
        #expect(output.contains("stdin-ok"))
        #expect(output.contains("python-stdin-ok"))
        #expect(output.contains("missing-command-ok"))
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
