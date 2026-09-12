// FloeAgentRuntimeTests — Harness reminder center and failure circuit breaker.

import Foundation
import Testing
@testable import FloeAgentRuntime
@testable import FloeModels
@testable import FloeTools
@testable import FloeCore

@Suite("Harness reminders")
struct AgentReminderCenterTests {
    @Test func providersFireOncePerContentAndRespectOwnCooldown() async {
        var center = AgentReminderCenter()
        center.register(variant: "plan") { context in
            // Cooldown owned by the provider: at most every 8 tool calls.
            if let last = context.lastInjectedAtToolCall, context.toolCallCount - last < 8 { return nil }
            return context.toolCallCount >= 10 ? "stale plan" : nil
        }
        #expect(await center.evaluate(toolCallCount: 5).isEmpty)
        let fired = await center.evaluate(toolCallCount: 10)
        #expect(fired.count == 1)
        #expect(fired[0].hasPrefix("<system-reminder>") && fired[0].contains("stale plan"))
        // Cooldown active: silent.
        #expect(await center.evaluate(toolCallCount: 12).isEmpty)
        // Cooldown over but content unchanged: still silent (no repeats).
        #expect(await center.evaluate(toolCallCount: 20).isEmpty)
    }

    @Test func emptyAndUnchangedContentStaySilent() async {
        var center = AgentReminderCenter()
        center.register(variant: "empty") { _ in "   " }
        center.register(variant: "steady") { _ in "constant note" }
        #expect(await center.evaluate(toolCallCount: 1).count == 1)
        #expect(await center.evaluate(toolCallCount: 2).isEmpty)
    }
}

@Suite("Failure circuit breaker")
struct ToolFailureBreakerTests {
    private func call(_ tool: String, _ argKey: String) -> ToolCall {
        // literals only; construction cannot fail
        try! ToolCall(id: "c-\(argKey)", toolName: tool, argumentsJSON: Data("{\"\(argKey)\":1}".utf8), scope: .local)
    }

    private func failure(_ text: String) -> ToolResult {
        ToolResult(callID: "x", status: .failed, outputSummary: text, outputDigest: "")
    }

    private func ok() -> ToolResult {
        ToolResult(callID: "x", status: .ok, outputSummary: "done", outputDigest: "")
    }

    @Test func threeConsecutiveFailuresTripBreakerEvenWithDifferentArguments() {
        var guard_ = ToolLoopGuard()
        // Distinct arguments: the unchanged-outcome guard must stay silent;
        // the streak breaker is what fires.
        _ = guard_.record(call: call("checklist.updatePlan", "a"), result: failure("error one"), isSideEffecting: false)
        _ = guard_.record(call: call("checklist.updatePlan", "b"), result: failure("error two"), isSideEffecting: false)
        let third = guard_.record(call: call("checklist.updatePlan", "c"), result: failure("error three names the field"), isSideEffecting: false)
        #expect(third?.shouldStop == false)
        #expect(third?.message.contains("Circuit breaker") == true)
        #expect(third?.message.contains("checklist.updatePlan") == true)
        #expect(third?.message.contains("error three names the field") == true)
        #expect(third?.message.contains("3 times") == true)
    }

    @Test func successResetsTheStreak() {
        var guard_ = ToolLoopGuard()
        _ = guard_.record(call: call("t", "a"), result: failure("e1"), isSideEffecting: true)
        _ = guard_.record(call: call("t", "b"), result: failure("e2"), isSideEffecting: true)
        _ = guard_.record(call: call("t", "c"), result: ok(), isSideEffecting: true)
        _ = guard_.record(call: call("t", "d"), result: failure("e3"), isSideEffecting: true)
        let fifth = guard_.record(call: call("t", "e"), result: failure("e4"), isSideEffecting: true)
        // Streak is 2 after the reset — no breaker.
        #expect(fifth?.message.contains("Circuit breaker") != true)
    }

    @Test func otherToolSuccessDoesNotResetTheStreak() {
        var guard_ = ToolLoopGuard()
        _ = guard_.record(call: call("a.tool", "1"), result: failure("e1"), isSideEffecting: false)
        _ = guard_.record(call: call("a.tool", "2"), result: failure("e2"), isSideEffecting: false)
        _ = guard_.record(call: call("b.tool", "1"), result: ok(), isSideEffecting: false)
        let third = guard_.record(call: call("a.tool", "3"), result: failure("e3"), isSideEffecting: false)
        #expect(third?.message.contains("Circuit breaker") == true)
    }
}
