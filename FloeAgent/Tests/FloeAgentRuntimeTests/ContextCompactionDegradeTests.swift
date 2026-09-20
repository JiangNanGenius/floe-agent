// FloeAgentRuntimeTests — compaction degrade on small local windows.

import Foundation
import Testing
@testable import FloeAgentRuntime
@testable import FloeCore

@Suite("Context compaction degrade")
struct ContextCompactionDegradeTests {
    private func transcript(_ count: Int, characters: Int = 1_200) -> [ConversationMessage] {
        (0..<count).map {
            ConversationMessage(
                role: $0.isMultiple(of: 2) ? "user" : "assistant",
                content: "Turn \($0): " + String(repeating: "evidence\($0) ", count: characters / 10)
            )
        }
    }

    @Test("Tiny local window compaction fits the usable budget instead of failing")
    func tinyWindowDegrades() async throws {
        // 32K window: the summary allowance fits the whole deterministic
        // record, so a failing model summarizer must still retain historical
        // facts rather than silently dropping them.
        let policy = ContextCompressionPolicy.local(
            contextWindowTokens: 32_768,
            reservedOutputTokens: 512
        )
        let engine = HybridContextEngine(summarizer: DeterministicContextSummarizer())
        let history = transcript(30)
        let latestUserID = try #require(history.last(where: { $0.role == "user" })?.id)
        let result = try await engine.compact(CompactionRequest(
            context: ContextRequest(
                messages: history,
                budget: policy.budget,
                protection: ContextProtection(messageIDs: [latestUserID])
            ),
            force: true
        ))
        let usable = policy.budget.availableInputTokens
        #expect(result.estimatedTokens <= usable)
        #expect(result.record.beforeEstimatedTokens > result.record.afterEstimatedTokens)
        #expect(result.messages.contains { $0.id == latestUserID })
        #expect(result.messages.contains { $0.content.contains("[Context compaction notice]") })
        // Every compacted-away message is recorded; originals stay in the durable record.
        let remainingIDs = Set(result.messages.map(\.id))
        #expect(result.record.sourceMessageIDs.count > 0)
        #expect(result.record.sourceMessageIDs.allSatisfy { !remainingIDs.contains($0) })
    }

    @Test("A failing summarizer falls back instead of failing the run")
    func summarizerFailureFallsBack() async throws {
        struct Probe: Error {}
        struct Throwing: ContextSummarizer {
            func summarize(messages: [ConversationMessage], maximumCharacters: Int) async throws -> String { throw Probe() }
        }
        let policy = ContextCompressionPolicy.local(
            contextWindowTokens: 8_192,
            reservedOutputTokens: 512
        )
        let engine = HybridContextEngine(summarizer: Throwing())
        var history = transcript(24)
        // Newest-candidate position: degrade rounds drop the OLDEST
        // summarized messages first, so this fact must survive every round
        // that keeps any summary at all.
        history.insert(ConversationMessage(
            role: "user",
            content: "关键事实：部署口令是 delta-905，后续步骤都依赖它。"
        ), at: 10)
        let result = try await engine.compact(CompactionRequest(
            context: ContextRequest(messages: history, budget: policy.budget),
            force: true
        ))
        #expect(result.estimatedTokens <= policy.budget.availableInputTokens)
        #expect(result.messages.contains { $0.content.contains("[Context compaction notice]") })
        // The deterministic fallback must retain real historical content —
        // acceptance with an empty summary would silently drop every fact.
        let summaryMessage = result.messages.first {
            $0.content.contains("Historical summary:") || $0.content.contains("[Context compaction notice]")
        }
        #expect(summaryMessage?.content.contains("delta-905") == true)
    }

    @Test("Cancellation always propagates")
    func cancellationPropagates() async throws {
        struct Cancelling: ContextSummarizer {
            func summarize(messages: [ConversationMessage], maximumCharacters: Int) async throws -> String {
                throw CancellationError()
            }
        }
        let policy = ContextCompressionPolicy.local(
            contextWindowTokens: 8_192,
            reservedOutputTokens: 512
        )
        let engine = HybridContextEngine(summarizer: Cancelling())
        await #expect(throws: CancellationError.self) {
            try await engine.compact(CompactionRequest(
                context: ContextRequest(messages: transcript(24), budget: policy.budget),
                force: true
            ))
        }
    }

    @Test("Unresolved tool-pair messages survive compaction verbatim")
    func toolPairPreservation() async throws {
        let policy = ContextCompressionPolicy.local(
            contextWindowTokens: 8_192,
            reservedOutputTokens: 512
        )
        let engine = HybridContextEngine(summarizer: DeterministicContextSummarizer())
        var history = transcript(24)
        let toolMessage = ConversationMessage(role: "tool", content: "call-42 result: the exact bytes the next turn needs 0123456789")
        history.insert(toolMessage, at: 2)
        let result = try await engine.compact(CompactionRequest(
            context: ContextRequest(
                messages: history,
                budget: policy.budget,
                protection: ContextProtection(unresolvedToolPairMessageIDs: [toolMessage.id])
            ),
            force: true
        ))
        #expect(result.messages.contains { $0.id == toolMessage.id && $0.content == toolMessage.content })
    }

    @Test("Honest failure only when the fixed floor alone exceeds the window")
    func honestFailureNamesTheFixedFloor() async throws {
        // usable = 1_000 tokens while a single recent message is ~1_300
        // tokens: the protected tail always keeps at least one message, so
        // even the minimal notice cannot fit, and compaction must fail with
        // the accurate reason, not "did not reduce".
        let budget = ContextBudget(
            contextWindowTokens: 1_000,
            reservedOutputTokens: 0,
            triggerRatio: 0.5,
            targetRatio: 0.3,
            protectedTailTokens: 1_200
        )
        let engine = HybridContextEngine(summarizer: DeterministicContextSummarizer())
        let history = transcript(30, characters: 4_000)
        do {
            _ = try await engine.compact(CompactionRequest(
                context: ContextRequest(messages: history, budget: budget),
                force: true
            ))
            Issue.record("compaction should have failed honestly")
        } catch {
            #expect(error.localizedDescription.contains("protected recent messages"))
        }
    }
}
