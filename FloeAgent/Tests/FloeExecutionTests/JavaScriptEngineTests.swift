// FloeExecutionTests — JavaScriptCore engine behavior.
// See docs/ARCHITECTURE_EXECUTION.md §6.1: console capture, exception
// mapping, timeout, cancellation, output caps, input injection, run
// isolation, and printJSON result collection. Runs against real
// JavaScriptCore on the macOS host.

import Foundation
import Testing
@testable import FloeExecution
import FloeCore
import FloeTools

@Suite("FloeExecution.JavaScriptEngine")
struct JavaScriptEngineTests {

    private let service = JavaScriptExecutionService()

    // MARK: console.log

    @Test("console.log output is captured in stdout")
    func consoleLog() async {
        let outcome = await service.run(
            ScriptExecutionRequest(script: "console.log(1 + 1);"),
            cancellation: nil
        )
        guard case .ok(_, let stdout, let truncated, _) = outcome else {
            Issue.record("expected ok, got \(outcome)")
            return
        }
        #expect(stdout.contains("2"))
        #expect(!truncated)
    }

    @Test("Multi-line console output concatenates in order")
    func consoleMultiLine() async {
        let outcome = await service.run(
            ScriptExecutionRequest(script: "console.log('a'); console.warn('b'); console.error('c');"),
            cancellation: nil
        )
        guard case .ok(_, let stdout, _, _) = outcome else {
            Issue.record("expected ok, got \(outcome)")
            return
        }
        let lines = stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines == ["a", "b", "c"])
    }

    // MARK: Exceptions

    @Test("A thrown JS error maps to jsException without a Swift throw")
    func jsException() async {
        let outcome = await service.run(
            ScriptExecutionRequest(script: "throw new Error('boom');"),
            cancellation: nil
        )
        guard case .jsException(let message, _) = outcome else {
            Issue.record("expected jsException, got \(outcome)")
            return
        }
        #expect(message.contains("boom"))
    }

    @Test("console output before the throw is preserved")
    func jsExceptionKeepsStdout() async {
        let outcome = await service.run(
            ScriptExecutionRequest(script: "console.log('before'); throw new Error('x');"),
            cancellation: nil
        )
        guard case .jsException(_, let stdout) = outcome else {
            Issue.record("expected jsException, got \(outcome)")
            return
        }
        #expect(stdout.contains("before"))
    }

    // MARK: Timeout

    @Test("while(true){} returns timedOut near the deadline, not a hang")
    func timeout() async {
        let started = Date()
        let outcome = await service.run(
            ScriptExecutionRequest(script: "while (true) {}", timeout: 0.5),
            cancellation: nil
        )
        let elapsed = Date().timeIntervalSince(started)
        guard case .timedOut(let afterMs, _) = outcome else {
            Issue.record("expected timedOut, got \(outcome)")
            return
        }
        #expect(afterMs == 500)
        // The caller returns promptly (well under any "wait forever").
        #expect(elapsed < 2.0)
    }

    // MARK: Cancellation

    @Test("Cancellation before start returns cancelled")
    func cancellationBeforeStart() async {
        let token = CancellationToken()
        token.cancel()
        let outcome = await service.run(
            ScriptExecutionRequest(script: "console.log('never');"),
            cancellation: token
        )
        #expect(outcome == .cancelled)
    }

    @Test("Cancellation during a long script wins the race")
    func cancellationDuringRun() async {
        let token = CancellationToken()
        let task = Task {
            await service.run(
                ScriptExecutionRequest(script: "while (true) {}", timeout: 30),
                cancellation: token
            )
        }
        try? await Task.sleep(for: .milliseconds(100))
        token.cancel()
        let outcome = await task.value
        #expect(outcome == .cancelled)
    }

    // MARK: Output cap

    @Test("Output beyond maxOutputBytes truncates and flags truncated")
    func outputCap() async {
        // Each line is ~40 bytes; 100 lines ≈ 4 KB, over the 1 KB cap.
        let script = "for (var i = 0; i < 100; i++) { console.log('line-' + i + '-padding-padding'); }"
        let outcome = await service.run(
            ScriptExecutionRequest(script: script, maxOutputBytes: 1024),
            cancellation: nil
        )
        guard case .ok(_, let stdout, let truncated, _) = outcome else {
            Issue.record("expected ok, got \(outcome)")
            return
        }
        #expect(truncated)
        #expect(stdout.utf8.count <= 1024)
    }

    // MARK: Input injection

    @Test("inputJSON is readable as the JS input value")
    func inputInjection() async {
        let outcome = await service.run(
            ScriptExecutionRequest(
                script: "console.log(input.x * 2);",
                inputJSON: #"{"x": 5}"#
            ),
            cancellation: nil
        )
        guard case .ok(_, let stdout, _, _) = outcome else {
            Issue.record("expected ok, got \(outcome)")
            return
        }
        #expect(stdout.contains("10"))
    }

    // MARK: Isolation

    @Test("Two runs do not share JS state")
    func runIsolation() async {
        let first = await service.run(
            ScriptExecutionRequest(script: "var leaked = 'secret'; console.log('first');"),
            cancellation: nil
        )
        guard case .ok = first else {
            Issue.record("first run failed: \(first)")
            return
        }
        let second = await service.run(
            ScriptExecutionRequest(script: "console.log(typeof leaked);"),
            cancellation: nil
        )
        guard case .ok(_, let stdout, _, _) = second else {
            Issue.record("expected ok, got \(second)")
            return
        }
        // A fresh JSContext per run: `leaked` is undefined in the second.
        #expect(stdout.contains("undefined"))
        #expect(!stdout.contains("secret"))
    }

    // MARK: printJSON

    @Test("printJSON collects a structured result")
    func printJSONResult() async throws {
        let outcome = await service.run(
            ScriptExecutionRequest(script: "printJSON({ a: 1, b: 'two' });"),
            cancellation: nil
        )
        guard case .ok(let resultJSON, _, _, _) = outcome else {
            Issue.record("expected ok, got \(outcome)")
            return
        }
        let json = try #require(resultJSON)
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect(object?["a"] as? Int == 1)
        #expect(object?["b"] as? String == "two")
    }

    @Test("A script without printJSON yields a nil resultJSON")
    func noPrintJSON() async {
        let outcome = await service.run(
            ScriptExecutionRequest(script: "console.log('no result');"),
            cancellation: nil
        )
        guard case .ok(let resultJSON, _, _, _) = outcome else {
            Issue.record("expected ok, got \(outcome)")
            return
        }
        #expect(resultJSON == nil)
    }
}
