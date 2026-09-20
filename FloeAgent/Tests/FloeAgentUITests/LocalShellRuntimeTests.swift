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
