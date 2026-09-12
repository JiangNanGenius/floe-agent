#if canImport(UIKit)
import Foundation
import Testing
import FloeExecution
import FloeTools
@testable import FloeApp

@Suite("FloeApp.LocalShell", .serialized)
struct LocalShellRuntimeTests {
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
