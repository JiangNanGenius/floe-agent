// FloeAppTests — Unified thread timeline projection: ordering, terminal
// placement, final-reply deduplication and legacy compatibility.
//
// These are logic-level tests for the timeline builder (no UI host). They
// compile with the app target's test bundle.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp
import FloeModels
import FloePersistence

@Suite("FloeApp.ThreadTimeline")
struct ThreadTimelineTests {

    private func makeEvent(
        runID: UUID,
        sequence: Int,
        kind: RunEventRecord.Kind,
        payload: [String: String] = [:]
    ) -> RunEventRecord {
        let data = (try? JSONEncoder().encode(payload)) ?? Data("{}".utf8)
        return RunEventRecord(
            runID: runID,
            sequence: sequence,
            kind: kind,
            payloadJSON: String(data: data, encoding: .utf8) ?? "{}"
        )
    }

    private func makeMessage(role: String, content: String, conversationID: UUID) -> PersistedMessage {
        PersistedMessage(
            id: UUID(),
            conversationID: conversationID,
            role: role,
            content: content,
            createdAt: Date(),
            parts: []
        )
    }

    private func makeRun(state: String, conversationID: UUID, goal: String = "goal") -> RunRecord {
        RunRecord(
            id: UUID(),
            conversationID: conversationID,
            state: state,
            goal: goal,
            startedAt: Date(),
            endedAt: state == "completed" || state == "failed" ? Date() : nil
        )
    }

    @Test("The final assistant reply always precedes the terminal row")
    func finalReplyBeforeTerminal() {
        let conversationID = UUID()
        let run = makeRun(state: "completed", conversationID: conversationID)
        let events = [
            makeEvent(runID: run.id, sequence: 1, kind: .status, payload: ["state": "preparing"]),
            makeEvent(runID: run.id, sequence: 2, kind: .reasoning, payload: ["text": "thinking"]),
            makeEvent(runID: run.id, sequence: 3, kind: .assistantText, payload: ["text": "最终回复"]),
            makeEvent(runID: run.id, sequence: 4, kind: .terminal, payload: ["stopReason": "endTurn"])
        ]
        let messages = [
            makeMessage(role: "user", content: "goal", conversationID: conversationID),
            makeMessage(role: "assistant", content: "最终回复", conversationID: conversationID)
        ]

        let items = ThreadTimelineBuilder.build(
            messages: messages, events: events, run: run,
            isRunning: false, liveStreamedText: "", liveReasoningText: "",
            pendingApprovals: []
        )

        guard let replyIndex = items.firstIndex(where: {
            if case .assistantMessage = $0 { return true }
            return false
        }), let terminalIndex = items.firstIndex(where: {
            if case .terminal = $0 { return true }
            return false
        }) else {
            Issue.record("Expected both a final reply and a terminal row")
            return
        }
        #expect(replyIndex < terminalIndex)
        // The persisted assistant message must NOT render a second copy.
        let replyCount = items.filter {
            if case .assistantMessage = $0 { return true }
            return false
        }.count
        #expect(replyCount == 1)
    }

    @Test("A final reply stays below the tool group that produced it")
    func finalReplyAfterToolGroup() {
        let conversationID = UUID()
        let run = makeRun(state: "completed", conversationID: conversationID)
        let events = [
            makeEvent(runID: run.id, sequence: 1, kind: .toolResult,
                      payload: ["tool": "workspace.listDirectory", "id": "call-1", "status": "ok"]),
            makeEvent(runID: run.id, sequence: 2, kind: .assistantText,
                      payload: ["text": "工具调用后的最终回复"]),
            makeEvent(runID: run.id, sequence: 3, kind: .terminal,
                      payload: ["stopReason": "endTurn"])
        ]
        let items = ThreadTimelineBuilder.build(
            messages: [], events: events, run: run,
            isRunning: false, liveStreamedText: "", liveReasoningText: "",
            pendingApprovals: []
        )
        let group = items.firstIndex { if case .stepGroup = $0 { true } else { false } }
        let reply = items.firstIndex { if case .assistantMessage = $0 { true } else { false } }
        #expect(group != nil && reply != nil)
        if let group, let reply { #expect(group < reply) }
    }

    @Test("Legacy runs without assistantText fall back to the persisted message before terminal")
    func legacyFallbackBeforeTerminal() {
        let conversationID = UUID()
        let run = makeRun(state: "completed", conversationID: conversationID)
        let events = [
            makeEvent(runID: run.id, sequence: 1, kind: .status, payload: ["state": "preparing"]),
            makeEvent(runID: run.id, sequence: 2, kind: .terminal, payload: ["stopReason": "endTurn"])
        ]
        let messages = [
            makeMessage(role: "user", content: "goal", conversationID: conversationID),
            makeMessage(role: "assistant", content: "旧回复", conversationID: conversationID)
        ]

        let items = ThreadTimelineBuilder.build(
            messages: messages, events: events, run: run,
            isRunning: false, liveStreamedText: "", liveReasoningText: "",
            pendingApprovals: []
        )

        let replyIndex = items.firstIndex(where: {
            if case .assistantMessage(let text, _) = $0 { return text == "旧回复" }
            return false
        })
        let terminalIndex = items.firstIndex(where: {
            if case .terminal = $0 { return true }
            return false
        })
        #expect(replyIndex != nil)
        #expect(terminalIndex != nil)
        if let replyIndex, let terminalIndex {
            #expect(replyIndex < terminalIndex)
        }
    }

    @Test("Reloading a thread never duplicates the final reply")
    func noDuplicateReplyOnReload() {
        let conversationID = UUID()
        let run = makeRun(state: "completed", conversationID: conversationID)
        let events = [
            makeEvent(runID: run.id, sequence: 1, kind: .assistantText, payload: ["text": "回答"]),
            makeEvent(runID: run.id, sequence: 2, kind: .terminal, payload: ["stopReason": "endTurn"])
        ]
        let messages = [
            makeMessage(role: "assistant", content: "回答", conversationID: conversationID)
        ]

        let items = ThreadTimelineBuilder.build(
            messages: messages, events: events, run: run,
            isRunning: false, liveStreamedText: "", liveReasoningText: "",
            pendingApprovals: []
        )
        let replies = items.filter {
            if case .assistantMessage = $0 { return true }
            return false
        }
        #expect(replies.count == 1)
    }

    @Test("A completed run with no final text surfaces an explicit missing-reply row")
    func missingFinalReplySurface() {
        let conversationID = UUID()
        let run = makeRun(state: "completed", conversationID: conversationID)
        let events = [
            makeEvent(runID: run.id, sequence: 1, kind: .error, payload: ["message": "noFinalText"]),
            makeEvent(runID: run.id, sequence: 2, kind: .terminal, payload: ["stopReason": "endTurn"])
        ]

        let items = ThreadTimelineBuilder.build(
            messages: [], events: events, run: run,
            isRunning: false, liveStreamedText: "", liveReasoningText: "",
            pendingApprovals: []
        )
        #expect(items.contains {
            if case .missingFinalMessage = $0 { return true }
            return false
        })
    }

    @Test("Timeline item IDs are stable across rebuilds")
    func stableIDs() {
        let conversationID = UUID()
        let run = makeRun(state: "streamingModel", conversationID: conversationID)
        let event = makeEvent(runID: run.id, sequence: 1, kind: .status, payload: ["state": "preparing"])
        let first = ThreadTimelineBuilder.build(
            messages: [], events: [event], run: run,
            isRunning: true, liveStreamedText: "abc", liveReasoningText: "",
            pendingApprovals: []
        )
        let second = ThreadTimelineBuilder.build(
            messages: [], events: [event], run: run,
            isRunning: true, liveStreamedText: "abcd", liveReasoningText: "",
            pendingApprovals: []
        )
        #expect(first.map(\.id) == second.map(\.id))
    }

    @Test("Events order by sequence, never by timestamp")
    func sequenceOrdering() {
        let conversationID = UUID()
        let run = makeRun(state: "streamingModel", conversationID: conversationID)
        // Deliberately invert createdAt to prove timestamps are ignored.
        var early = makeEvent(runID: run.id, sequence: 1, kind: .status, payload: ["state": "preparing"])
        early.createdAt = Date().addingTimeInterval(1_000)
        var late = makeEvent(runID: run.id, sequence: 2, kind: .reasoning, payload: ["text": "r"])
        late.createdAt = Date().addingTimeInterval(-1_000)

        let items = ThreadTimelineBuilder.build(
            messages: [], events: [late, early], run: run,
            isRunning: true, liveStreamedText: "", liveReasoningText: "x",
            pendingApprovals: []
        )
        let eventIDs = items.flatMap { item -> [Int] in
            switch item {
            case .event(let record): [record.sequence]
            case .stepGroup(let events, _): events.map(\.sequence)
            default: []
            }
        }
        #expect(eventIDs == [1, 2])
    }

    @Test("Terminal transition status is hidden so completion appears only after the reply")
    func terminalStatusIsToolbarOnly() {
        let conversationID = UUID()
        let run = makeRun(state: "completed", conversationID: conversationID)
        let status = makeEvent(
            runID: run.id,
            sequence: 1,
            kind: .status,
            payload: ["state": "completed"]
        )
        let answer = makeEvent(
            runID: run.id,
            sequence: 2,
            kind: .assistantText,
            payload: ["text": "最终回复"]
        )
        let terminal = makeEvent(
            runID: run.id,
            sequence: 3,
            kind: .terminal,
            payload: ["stopReason": "endTurn"]
        )

        let items = ThreadTimelineBuilder.build(
            messages: [], events: [status, answer, terminal], run: run,
            isRunning: false, liveStreamedText: "", liveReasoningText: "",
            pendingApprovals: []
        )

        #expect(!items.contains { item in
            if case .event(let event) = item { return event.id == status.id }
            return false
        })
        #expect(items.last?.id == "terminal.\(terminal.id.uuidString)")
    }

    @Test("Legacy fallback never borrows an assistant reply from another run")
    func legacyFallbackUsesRunWindow() {
        let conversationID = UUID()
        let start = Date()
        let run = RunRecord(
            id: UUID(),
            conversationID: conversationID,
            state: "completed",
            goal: "same prompt",
            startedAt: start,
            endedAt: start.addingTimeInterval(5)
        )
        var correct = makeMessage(
            role: "assistant", content: "first run", conversationID: conversationID
        )
        correct.createdAt = start.addingTimeInterval(4)
        var other = makeMessage(
            role: "assistant", content: "second run", conversationID: conversationID
        )
        other.createdAt = start.addingTimeInterval(60)

        let items = ThreadTimelineBuilder.build(
            messages: [correct, other], events: [], run: run,
            isRunning: false, liveStreamedText: "", liveReasoningText: "",
            pendingApprovals: []
        )
        #expect(items.contains { item in
            if case .assistantMessage(let text, _) = item { return text == "first run" }
            return false
        })
        #expect(!items.contains { item in
            if case .assistantMessage(let text, _) = item { return text == "second run" }
            return false
        })
    }
}
#endif
