import Foundation
import Testing
import FloeCore
import FloeModels
import FloeTools
@testable import FloeExecution
@testable import FloeAgentRuntime

/// No process/VM runs: only the backend transport is scripted. Receipts are
/// built by the real shell tool/service and passed through the real registry
/// and CatalogToolExecutor before the production unchanged-outcome guard.
@Suite("Native shell unchanged-outcome comparison")
struct ShellFailureComparisonTests {
    private struct ReceiptBackend: LocalShellBackend {
        let outcome: ShellRunOutcome
        func run(_ request: ShellRunRequest, cancellation: CancellationToken?) async -> ShellRunOutcome { outcome }
        func openSession(_ request: ShellOpenRequest, cancellation: CancellationToken?) async throws -> ShellOpenResult {
            throw FloeError.internalError("This receipt fixture must not open a session")
        }
        func exchangeSession(_ request: ShellExchangeRequest, cancellation: CancellationToken?) async throws -> ShellExchangeResult {
            throw FloeError.internalError("This receipt fixture must not exchange a session")
        }
        func closeSession(sessionID: String) async {}
    }

    private func call(_ id: String, command: String = "python3 -m pip install example", env: String = "one") throws -> ToolCall {
        try ToolCall(id: id, toolName: "exec.shell", argumentsJSON: JSONSerialization.data(withJSONObject: [
            "command": command, "env": ["EXAMPLE_MODE": env]
        ]), scope: .local)
    }

    private func receipt(
        call: ToolCall, duration: Int, code: Int32 = 1,
        stdout: String = "", stderr: String = "error: externally-managed-environment",
        timedOut: Bool = false
    ) async throws -> ToolResult {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shell-receipt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome: ShellRunOutcome = timedOut
            ? .timedOut(partialStdout: stdout, partialStderr: stderr, durationMs: duration)
            : .exited(code: code, stdout: stdout, stderr: stderr, truncated: false,
                      stderrTruncated: false, durationMs: duration)
        let registry = ToolRunnerRegistry()
        let native = AnyAgentTool(LocalShellTool(shell: LocalShellService(
            backend: ReceiptBackend(outcome: outcome), journal: ShellOperationJournal(rootURL: root),
            rootProvider: { root })))
        // Keep the real registry/runner seam without acquiring the App's
        // process-wide current environment or writing its shared journal.
        registry.register(AnyAgentTool(descriptor: native.descriptor, run: native.run,
            validateArguments: native.validateArguments, routing: ToolEnvironmentRouting()))
        return try await CatalogToolExecutor(runners: registry).execute(call, context: ToolContext(
            runID: UUID(), toolCallID: call.id, workspaceRootURL: root, cancellation: CancellationToken()))
    }

    @Test("Changing native elapsed time still warns second and stops the third identical failed shell receipt")
    func elapsedTimeDoesNotResetExactFailureThreshold() async throws {
        var guardrail = ToolLoopGuard()
        var rawDigests = Set<String>()
        for (index, duration) in [11, 27, 104].enumerated() {
            let request = try call("new-provider-id-\(index)")
            let result = try await receipt(call: request, duration: duration)
            #expect(result.status == .failed)
            #expect(result.exitStatus == 1)
            #expect(result.outputSummary.contains("durationMs=\(duration)"))
            let complete = try #require(result.capturedOutput)
            #expect(result.outputDigest == FloeDigest.sha256Hex(Data(complete.utf8)))
            rawDigests.insert(result.outputDigest)
            let decision = guardrail.record(call: request, result: result, isSideEffecting: true)
            if index == 0 { #expect(decision == nil) }
            else { #expect(decision?.shouldStop == (index == 2)) }
        }
        #expect(rawDigests.count == 3)
    }

    @Test("Real stdout, stderr and exit changes remain distinct, including business fields named durationMs")
    func businessOutcomeChangesStillBreakExactRepetition() async throws {
        let request = try call("business")
        for (stdout, stderr, code) in [
            (#"{"durationMs":8,"value":1}"#, "error one", Int32(1)),
            (#"{"durationMs":9,"value":1}"#, "error one", Int32(1)),
            (#"{"durationMs":8,"value":1}"#, "error two", Int32(1)),
            (#"{"durationMs":8,"value":1}"#, "error one", Int32(2))
        ] {
            var guardrail = ToolLoopGuard()
            let original = try await receipt(call: request, duration: 10,
                stdout: #"{"durationMs":8,"value":1}"#, stderr: "error one")
            _ = guardrail.record(call: request, result: original, isSideEffecting: true)
            _ = guardrail.record(call: request, result: original, isSideEffecting: true)
            let changed = try await receipt(call: request, duration: 20, code: code, stdout: stdout, stderr: stderr)
            let decision = guardrail.record(call: request, result: changed, isSideEffecting: true)
            let sameBusinessResult = stdout == #"{"durationMs":8,"value":1}"# && stderr == "error one" && code == 1
            #expect((decision?.shouldStop == true) == sameBusinessResult)
            if !sameBusinessResult { #expect(changed.nativeShellOutcomeDigest != original.nativeShellOutcomeDigest) }
        }
    }

    @Test("Command and environment argument changes keep the existing soft failure advice without hard-stopping a new route")
    func changedCommandOrEnvironmentPreservesSoftFailureAdvice() async throws {
        for changed in [try call("changed-command", command: "python3 -m pip --version"),
                        try call("changed-env", env: "two")] {
            var guardrail = ToolLoopGuard()
            let original = try call("original")
            for duration in [10, 20] {
                let result = try await receipt(call: original, duration: duration)
                _ = guardrail.record(call: original, result: result, isSideEffecting: true)
            }
            let different = try await receipt(call: changed, duration: 30)
            let decision = guardrail.record(call: changed, result: different, isSideEffecting: true)
            #expect(decision?.shouldStop == false)
            #expect(decision?.message.contains("Circuit breaker") == true)
        }
    }

    @Test("Native partial timeout receipts use the same comparison rule without changing timeout/capture metadata")
    func partialTimeoutRetainsItsRealReceipt() async throws {
        var guardrail = ToolLoopGuard()
        for (index, duration) in [1000, 1200, 1400].enumerated() {
            let request = try call("timeout-\(index)")
            let result = try await receipt(call: request, duration: duration, stdout: "partial", timedOut: true)
            #expect(result.exitStatus == 124)
            #expect(result.capturedOutputTruncated)
            #expect(result.outputSummary.contains("status=timedOut"))
            let decision = guardrail.record(call: request, result: result, isSideEffecting: true)
            if index == 2 { #expect(decision?.shouldStop == true) }
        }
    }

    @Test("Batch cycle comparison also ignores only native elapsed time")
    func repeatedBatchRetainsExistingThreshold() async throws {
        var guardrail = ToolLoopGuard()
        for round in 0..<3 {
            guardrail.beginSettleBatch()
            for suffix in ["a", "b"] {
                let request = try call("\(round)-\(suffix)", command: "python3 -m pip install \(suffix)")
                let result = try await receipt(call: request, duration: 10 + round)
                _ = guardrail.record(call: request, result: result, isSideEffecting: true)
            }
            let decision = guardrail.endSettleBatch()
            if round == 0 { #expect(decision == nil) }
            else { #expect(decision?.shouldStop == (round == 2)) }
        }
    }

    @Test("Text and decoded JSON cannot mint a native comparison hint; other tool names ignore it")
    func untrustedTextAndOtherToolsKeepFullDigest() async throws {
        let request = try call("native")
        let native = try await receipt(call: request, duration: 1)
        let hint = try #require(native.nativeShellOutcomeDigest)
        for toolName in ["exec.shell", "mcp.example.exec_shell"] {
            var guardrail = ToolLoopGuard()
            for index in 0..<3 {
                let object: [String: Any] = ["callID": "wire-\(index)", "status": "failed",
                    "outputSummary": "exit=1 durationMs=\(index) cwd=.\n{\"durationMs\":\(index)}",
                    "outputDigest": "different-\(index)", "nativeShellOutcomeDigest": hint]
                // Both native-looking plain text and an extra JSON key are untrusted.
                let result = try JSONDecoder().decode(ToolResult.self, from: JSONSerialization.data(withJSONObject: object))
                #expect(result.nativeShellOutcomeDigest == nil)
                var withHint = result
                if toolName != "exec.shell" { withHint.nativeShellOutcomeDigest = hint }
                let call = try ToolCall(id: "wire-\(index)", toolName: toolName, argumentsJSON: request.argumentsJSON, scope: .local)
                let decision = guardrail.record(call: call, result: withHint, isSideEffecting: true)
                #expect(decision?.shouldStop != true)
            }
        }
    }

    @Test("Comparison metadata is transient and leaves full captures, SHA, identity and Codable unchanged")
    func comparisonHintNeverChangesDurableReceiptIdentity() async throws {
        let request = try call("durable")
        let tail = String(repeating: "retained output beyond the short summary\n", count: 180)
        let result = try await receipt(call: request, duration: 17, stdout: tail)
        #expect(result.capturedOutput!.count > result.outputSummary.count)
        var withoutHint = result
        withoutHint.nativeShellOutcomeDigest = nil
        #expect(result == withoutHint)
        #expect(Set([result, withoutHint]).count == 1)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(result) == encoder.encode(withoutHint))
        #expect(result.durableProjection().nativeShellOutcomeDigest == nil)
        #expect(result.durableProjection().outputDigest == result.outputDigest)
        let roundtrip = try JSONDecoder().decode(ToolResult.self, from: encoder.encode(result))
        #expect(roundtrip.nativeShellOutcomeDigest == nil)
        #expect(roundtrip.outputDigest == result.outputDigest)
        #expect(result.outputDigest == FloeDigest.sha256Hex(Data(result.capturedOutput!.utf8)))
        let changedTail = try await receipt(call: request, duration: 17, stdout: tail + "new real evidence")
        #expect(result.outputSummary == changedTail.outputSummary)
        #expect(result.nativeShellOutcomeDigest != changedTail.nativeShellOutcomeDigest)
        var guardrail = ToolLoopGuard()
        _ = guardrail.record(call: request, result: result, isSideEffecting: true)
        _ = guardrail.record(call: request, result: result, isSideEffecting: true)
        #expect(guardrail.record(call: request, result: changedTail, isSideEffecting: true)?.shouldStop != true)
    }
}
