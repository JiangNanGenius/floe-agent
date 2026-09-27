// FloeLocalModelsTests — Build 230/231 streamed local-turn delivery.
//
// The Build 230 on-device feedback reported that the local model no longer
// crashed but produced no reply: the adapter buffered the complete generation
// (plus a possible missing-tool repair) and only then emitted one textDelta,
// with no no-progress terminal. These tests pin the delivery contract with a
// deterministic engine double — no weights, no GPU:
//
//   * prose streams before completion, exactly once;
//   * cross-chunk think markup never leaks and reasoning is never displayed;
//   * tool envelopes (whole payload, split across chunks) are withheld from
//     the visible stream and still parsed into tool requests;
//   * an empty generation ends as an explicit empty `endTurn` (the harness
//     owns the one bounded no-visible-answer continuation);
//   * a stalled generation ends with one explicit no-progress error, and the
//     engine observes cancellation before teardown;
//   * cancellation remains a plain cancellation.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
@testable import FloeLocalModelCatalog
@testable import FloeLocalModels

// MARK: - Framer

@Suite("Local stream framer")
struct LocalStreamFramerTests {
    private static func toolEnvelope(_ path: String) -> String {
        #"{"tool_call":{"name":"workspace.readFile","arguments":{"path":"\#(path)"}}}"#
    }

    @available(macOS 15.4, iOS 26.0, *)
    private static func framer(offered: Set<String> = ["workspace.readFile"]) -> LocalStreamFramer {
        LocalStreamFramer { payload in
            guard let calls = try? LocalProviderAdapter.toolCalls(
                from: payload,
                offeredToolNames: offered
            ) else { return false }
            return !calls.isEmpty
        }
    }

    @available(macOS 15.4, iOS 26.0, *)
    @Test("Plain prose streams once and the final reconciliation adds nothing")
    func plainProseStreamsOnce() {
        var framer = Self.framer()
        #expect(framer.ingest("你好") == "你好")
        #expect(framer.ingest("，世界") == "，世界")
        #expect(framer.finish(visibleAnswer: "你好，世界") == nil)
        #expect(framer.emitted == "你好，世界")
    }

    @available(macOS 15.4, iOS 26.0, *)
    @Test("A trailing space is not re-emitted by the trimmed final answer")
    func trailingWhitespaceReconciliation() {
        var framer = Self.framer()
        #expect(framer.ingest("答案 ") == "答案 ")
        #expect(framer.finish(visibleAnswer: "答案") == nil)
    }

    @available(macOS 15.4, iOS 26.0, *)
    @Test("Inline prose braces are released and never held")
    func inlineProseBraces() {
        var framer = Self.framer()
        let text = "使用 {x} 变量替换。"
        #expect(framer.ingest(text) == text)
        #expect(framer.finish(visibleAnswer: text) == nil)
    }

    @available(macOS 15.4, iOS 26.0, *)
    @Test("Cross-chunk think markup never leaks into the visible stream")
    func crossChunkThinkIsWithheld() {
        var framer = Self.framer()
        #expect(framer.ingest("<thi") == "")
        #expect(framer.ingest("nk>这是私有推理</think") == "")
        #expect(framer.ingest(">最终答案") == "最终答案")
        #expect(framer.finish(visibleAnswer: "最终答案") == nil)
        #expect(!framer.emitted.contains("私有推理"))
    }

    @available(macOS 15.4, iOS 26.0, *)
    @Test("A whole-payload tool envelope is withheld from prose")
    func wholePayloadToolEnvelopeIsWithheld() {
        var framer = Self.framer()
        #expect(framer.ingest(#"{"tool_call":{"name":"workspace.readFile","#) == "")
        #expect(framer.ingest(#""arguments":{"path":"a.md"}}}"#) == "")
        #expect(framer.emitted.isEmpty)
        // The adapter takes the tool branch and never asks for prose, so the
        // authoritative answer is empty and nothing is displayed.
        #expect(framer.finish(visibleAnswer: "") == nil)
    }

    @available(macOS 15.4, iOS 26.0, *)
    @Test("A mid-prose tool envelope holds the rest; reconciliation never duplicates")
    func midProseToolEnvelopeHoldsRest() {
        var framer = Self.framer()
        #expect(framer.ingest("先读取文件。") == "先读取文件。")
        #expect(framer.ingest(Self.toolEnvelope("a.md")) == "")
        #expect(framer.emitted == "先读取文件。")
        let full = "先读取文件。" + Self.toolEnvelope("a.md")
        // If the authoritative parse had found no call, the held remainder is
        // released exactly once.
        #expect(framer.finish(visibleAnswer: full) == Self.toolEnvelope("a.md"))
    }

    @available(macOS 15.4, iOS 26.0, *)
    @Test("A Thinking Process scratchpad is withheld and its final answer emitted once")
    func scratchpadExtraction() {
        var framer = Self.framer()
        #expect(framer.ingest("Thinking Process: draft one") == "")
        #expect(framer.ingest(" Final answer: 最终答案") == "")
        #expect(framer.emitted.isEmpty)
        #expect(framer.finish(visibleAnswer: "最终答案") == "最终答案")
    }

    @available(macOS 15.4, iOS 26.0, *)
    @Test("A partial tag at the tail is held until the next chunk decides")
    func partialTagHoldback() {
        var framer = Self.framer()
        // The trailing `<t` is held (it could become `<think`); the prose
        // before it is released immediately.
        #expect(framer.ingest("比较 a <t") == "比较 a ")
        #expect(framer.ingest("hin") == "")
        // `<thinking` is not `<think\b`, so it is ordinary prose and the
        // held buffer is released verbatim.
        #expect(framer.ingest("king 不是标签") == "<thinking 不是标签")
        #expect(framer.finish(visibleAnswer: "比较 a <thinking 不是标签") == nil)
        #expect(framer.emitted == "比较 a <thinking 不是标签")
    }
}

// MARK: - Watchdog state

@Suite("Local generation watchdog state")
struct LocalGenerationWatchdogStateTests {
    @Test("The first-activity deadline and the idle deadline are distinct")
    func deadlinesDiffer() {
        let policy = LocalGenerationWatchdogPolicy(
            firstActivitySeconds: 10,
            idleSeconds: 2,
            pollIntervalSeconds: 0.1
        )
        let start = Date()
        let state = LocalGenerationWatchdogState(policy: policy, now: start)
        #expect(state.expiredSnapshot(now: start.addingTimeInterval(9)) == nil)
        #expect(state.expiredSnapshot(now: start.addingTimeInterval(11)) != nil)

        let activityAt = Date()
        state.noteOutput()
        #expect(state.expiredSnapshot(now: activityAt.addingTimeInterval(1)) == nil)
        #expect(state.expiredSnapshot(now: activityAt.addingTimeInterval(3)) != nil)
    }

    @Test("The timeout marker is published at most once")
    func timeoutIsOnce() {
        let state = LocalGenerationWatchdogState(policy: .production)
        #expect(state.markTimedOut())
        #expect(!state.markTimedOut())
        #expect(state.timedOut)
    }

    @Test("Progress records stage, chunk count and input tokens")
    func progressIsRecorded() {
        let policy = LocalGenerationWatchdogPolicy(
            firstActivitySeconds: 30,
            idleSeconds: 2,
            pollIntervalSeconds: 0.1
        )
        let state = LocalGenerationWatchdogState(policy: policy)
        state.noteProgress(LocalInferenceProgress(
            stage: .prefill,
            prefilledTokens: 0,
            totalInputTokens: 4_822,
            emittedChunks: 0
        ))
        state.noteProgress(LocalInferenceProgress(
            stage: .decoding,
            prefilledTokens: 4_822,
            totalInputTokens: 4_822,
            emittedChunks: 7
        ))
        let snapshot = state.expiredSnapshot(now: Date().addingTimeInterval(10_000))
        #expect(snapshot?.phase == "decoding")
        #expect(snapshot?.emittedChunks == 7)
        #expect(snapshot?.inputTokens == 4_822)
        #expect(snapshot?.sawActivity == true)
    }

    @Test("A preparing stage extends the first-activity window, not the idle one")
    func preparingStaysOnTheLongWindow() {
        let policy = LocalGenerationWatchdogPolicy(
            firstActivitySeconds: 30,
            idleSeconds: 1,
            pollIntervalSeconds: 0.1
        )
        let start = Date()
        let state = LocalGenerationWatchdogState(policy: policy, now: start)
        // A cold model load reports `preparing`; the 1 s idle deadline must
        // not apply to it, but the 30 s first-activity bound still does.
        let loadAt = start.addingTimeInterval(5)
        state.noteProgress(LocalInferenceProgress(stage: .preparing))
        #expect(state.expiredSnapshot(now: loadAt) == nil)
        #expect(state.expiredSnapshot(now: Date()) == nil)
        // Only once prefill/decoding progress arrives does idle apply.
        state.noteProgress(LocalInferenceProgress(stage: .prefill, totalInputTokens: 100))
        let prefillAt = Date()
        #expect(state.expiredSnapshot(now: prefillAt.addingTimeInterval(0.5)) == nil)
        #expect(state.expiredSnapshot(now: prefillAt.addingTimeInterval(2)) != nil)
    }
}
