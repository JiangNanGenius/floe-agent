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
    @Test("Latest and live tool groups are visible without an extra tap")
    func latestToolGroupExpansionPolicy() {
        #expect(StepGroupDisclosurePolicy.initiallyExpanded(
            isLatest: true, isLive: false, hasError: false, hasPendingApproval: false
        ))
        #expect(StepGroupDisclosurePolicy.initiallyExpanded(
            isLatest: false, isLive: true, hasError: false, hasPendingApproval: false
        ))
        #expect(!StepGroupDisclosurePolicy.initiallyExpanded(
            isLatest: false, isLive: false, hasError: false, hasPendingApproval: false
        ))
    }

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

    @Test("A confirmed final-answer review never renders trailing reasoning below the answer")
    func confirmedVerificationReasoningIsHidden() {
        let conversationID = UUID()
        let run = makeRun(state: "completed", conversationID: conversationID)
        let verificationReasoning = makeEvent(
            runID: run.id, sequence: 5, kind: .reasoning,
            payload: ["text": "Internal verification before CONFIRM"]
        )
        let terminal = makeEvent(
            runID: run.id, sequence: 6, kind: .terminal,
            payload: ["stopReason": "endTurn"]
        )
        let events = [
            makeEvent(runID: run.id, sequence: 1, kind: .reasoning,
                      payload: ["text": "Reasoning that produced the answer"]),
            makeEvent(runID: run.id, sequence: 2, kind: .toolRequest,
                      payload: ["tool": "canvas.getState", "id": "state-1"]),
            makeEvent(runID: run.id, sequence: 3, kind: .toolResult,
                      payload: ["tool": "canvas.getState", "id": "state-1", "status": "ok"]),
            makeEvent(runID: run.id, sequence: 4, kind: .assistantText,
                      payload: ["text": "最终答案"]),
            verificationReasoning,
            terminal
        ]

        let items = ThreadTimelineBuilder.build(
            messages: [], events: events, run: run,
            isRunning: false, liveStreamedText: "", liveReasoningText: "",
            pendingApprovals: []
        )

        let projectedSequences = items.flatMap { item -> [Int] in
            switch item {
            case .event(let event): [event.sequence]
            case .stepGroup(let events, _): events.map(\.sequence)
            default: []
            }
        }
        #expect(projectedSequences == [1, 2, 3])
        #expect(!projectedSequences.contains(verificationReasoning.sequence))
        #expect(items.last?.id == "terminal.\(terminal.id.uuidString)")
    }

    @Test("Reasoning after assistant text stays visible when it leads to a tool")
    func postAnswerReasoningBeforeToolRemainsVisible() {
        let conversationID = UUID()
        let run = makeRun(state: "completed", conversationID: conversationID)
        let reasoning = makeEvent(
            runID: run.id, sequence: 2, kind: .reasoning,
            payload: ["text": "Need one real tool check"]
        )
        let events = [
            makeEvent(runID: run.id, sequence: 1, kind: .assistantText,
                      payload: ["text": "Intermediate answer"]),
            reasoning,
            makeEvent(runID: run.id, sequence: 3, kind: .toolRequest,
                      payload: ["tool": "canvas.getState", "id": "state-2"]),
            makeEvent(runID: run.id, sequence: 4, kind: .toolResult,
                      payload: ["tool": "canvas.getState", "id": "state-2", "status": "ok"]),
            makeEvent(runID: run.id, sequence: 5, kind: .terminal,
                      payload: ["stopReason": "endTurn"])
        ]

        let items = ThreadTimelineBuilder.build(
            messages: [], events: events, run: run,
            isRunning: false, liveStreamedText: "", liveReasoningText: "",
            pendingApprovals: []
        )
        let projectedSequences = items.flatMap { item -> [Int] in
            if case .stepGroup(let events, _) = item { return events.map(\.sequence) }
            return []
        }
        #expect(projectedSequences.contains(reasoning.sequence))
    }

    @Test("A persisted terminal suppresses stale live animation tails")
    func terminalSuppressesAnimatorDrainTail() {
        let conversationID = UUID()
        let run = makeRun(state: "completed", conversationID: conversationID)
        let terminal = makeEvent(
            runID: run.id, sequence: 2, kind: .terminal,
            payload: ["stopReason": "endTurn"]
        )
        let items = ThreadTimelineBuilder.build(
            messages: [],
            events: [
                makeEvent(runID: run.id, sequence: 1, kind: .assistantText,
                          payload: ["text": "已经持久化的最终答案"]),
                terminal
            ],
            run: run,
            isRunning: true,
            liveStreamedText: "尚未排空的动画文本",
            liveReasoningText: "尚未排空的动画思考",
            pendingApprovals: []
        )

        #expect(!items.contains { item in
            switch item {
            case .liveReasoning, .liveAssistantTail, .liveThinking: true
            default: false
            }
        })
        #expect(items.last?.id == "terminal.\(terminal.id.uuidString)")
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

    @Test("Completed tool keeps its request so the card can show exact input and output")
    func completedToolKeepsRequestAndResultTogether() {
        let conversationID = UUID()
        let run = makeRun(state: "completed", conversationID: conversationID)
        let request = makeEvent(
            runID: run.id, sequence: 1, kind: .toolRequest,
            payload: [
                "tool": "ssh.execute", "id": "ssh-1", "status": "pending",
                "input": #"{"command":"uname -a"}"#
            ]
        )
        let result = makeEvent(
            runID: run.id, sequence: 2, kind: .toolResult,
            payload: [
                "tool": "ssh.execute", "id": "ssh-1", "status": "ok",
                "summary": "exitCode=0\\nstdout:\\nLinux"
            ]
        )

        let items = ThreadTimelineBuilder.build(
            messages: [], events: [request, result], run: run,
            isRunning: false, liveStreamedText: "", liveReasoningText: "",
            pendingApprovals: []
        )

        let groups = items.compactMap { item -> [RunEventRecord]? in
            if case .stepGroup(let events, _) = item { return events }
            return nil
        }
        #expect(groups.count == 1)
        #expect(groups.first?.map(\.kind) == [.toolRequest, .toolResult])
    }

    @Test("Reasoning after a tool result starts the next step group")
    func nextTurnReasoningStartsNewStepGroup() {
        let conversationID = UUID()
        let run = makeRun(state: "streamingModel", conversationID: conversationID)
        let events = [
            makeEvent(runID: run.id, sequence: 1, kind: .toolRequest,
                      payload: ["tool": "ssh.execute", "id": "ssh-1"]),
            makeEvent(runID: run.id, sequence: 2, kind: .toolResult,
                      payload: ["tool": "ssh.execute", "id": "ssh-1", "status": "ok"]),
            makeEvent(runID: run.id, sequence: 3, kind: .reasoning,
                      payload: ["text": "检查结果后决定下一步"]),
            makeEvent(runID: run.id, sequence: 4, kind: .toolRequest,
                      payload: ["tool": "workspace.readFile", "id": "read-2"])
        ]

        let items = ThreadTimelineBuilder.build(
            messages: [], events: events, run: run,
            isRunning: true, liveStreamedText: "", liveReasoningText: "",
            pendingApprovals: []
        )
        let groups = items.compactMap { item -> [RunEventRecord]? in
            if case .stepGroup(let events, _) = item { return events }
            return nil
        }

        #expect(groups.count == 2)
        #expect(groups[0].map(\.sequence) == [1, 2])
        #expect(groups[1].map(\.sequence) == [3, 4])
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
        // The durable launch marker is stale after streaming begins; only
        // current content events remain in the visible timeline.
        #expect(eventIDs == [2])
    }

    @Test("Preparing status disappears as soon as generation starts")
    func stalePreparingStatusIsHidden() {
        let conversationID = UUID()
        let run = makeRun(state: "streamingModel", conversationID: conversationID)
        let preparing = makeEvent(
            runID: run.id,
            sequence: 1,
            kind: .status,
            payload: ["state": "preparing"]
        )

        let items = ThreadTimelineBuilder.build(
            messages: [], events: [preparing], run: run,
            isRunning: true, liveStreamedText: "已经开始生成", liveReasoningText: "",
            pendingApprovals: []
        )

        #expect(!items.contains { item in
            if case .event(let event) = item { return event.id == preparing.id }
            return false
        })
        #expect(items.contains { if case .liveAssistantTail = $0 { true } else { false } })
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

    @Test("A suspended run keeps its pending approval card actionable")
    func suspendedRunKeepsApprovalCard() throws {
        let conversationID = UUID()
        let run = makeRun(state: "waitingApproval", conversationID: conversationID)
        let toolCall = try ToolCall(
            id: "approval-call",
            toolName: "workspace.writeFile",
            argumentsJSON: Data(#"{"path":"note.txt","content":"hello"}"#.utf8),
            scope: .local
        )
        let approval = PendingApproval(
            runID: run.id,
            conversationID: conversationID,
            toolCall: toolCall,
            reason: "Review before writing",
            riskLabels: ["write"],
            isSideEffecting: true,
            requestedAt: Date(),
            workspaceID: nil
        )

        let items = ThreadTimelineBuilder.buildConversation(
            messages: [],
            runs: [run],
            eventsByRun: [:],
            liveRunID: nil,
            isRunning: false,
            liveStreamedText: "",
            liveReasoningText: "",
            pendingApprovals: [approval]
        )

        #expect(items.contains { item in
            if case .approval(let value) = item { return value.id == approval.id }
            return false
        })
    }

    @Test("Guidance consumed by an active run remains visible in conversation history")
    func consumedGuidanceRemainsVisible() {
        let conversationID = UUID()
        let start = Date()
        let run = RunRecord(
            id: UUID(),
            conversationID: conversationID,
            state: "completed",
            goal: "先整理文档",
            startedAt: start,
            endedAt: start.addingTimeInterval(8)
        )
        let goal = PersistedMessage(
            id: UUID(), conversationID: conversationID, role: "user",
            content: "先整理文档", createdAt: start, parts: [], runID: run.id
        )
        let guidance = PersistedMessage(
            id: UUID(), conversationID: conversationID, role: "user",
            content: "引导：先处理 PDF", createdAt: start.addingTimeInterval(3),
            parts: [], runID: run.id
        )
        var firstAnswer = makeEvent(
            runID: run.id, sequence: 1, kind: .assistantText,
            payload: ["text": "我先检查文件"]
        )
        firstAnswer.createdAt = start.addingTimeInterval(2)
        var finalAnswer = makeEvent(
            runID: run.id, sequence: 2, kind: .assistantText,
            payload: ["text": "已按引导完成"]
        )
        finalAnswer.createdAt = start.addingTimeInterval(6)
        var terminal = makeEvent(
            runID: run.id, sequence: 3, kind: .terminal,
            payload: ["stopReason": "endTurn"]
        )
        terminal.createdAt = start.addingTimeInterval(8)

        let items = ThreadTimelineBuilder.buildConversation(
            messages: [goal, guidance],
            runs: [run],
            eventsByRun: [run.id: [firstAnswer, finalAnswer, terminal]],
            liveRunID: nil,
            isRunning: false,
            liveStreamedText: "",
            liveReasoningText: "",
            pendingApprovals: []
        )

        let guidanceIndex = items.firstIndex {
            if case .userMessage(let message) = $0 { return message.id == guidance.id }
            return false
        }
        let firstAnswerIndex = items.firstIndex {
            if case .assistantMessage(let text, _) = $0 { return text == "我先检查文件" }
            return false
        }
        let finalAnswerIndex = items.firstIndex {
            if case .assistantMessage(let text, _) = $0 { return text == "已按引导完成" }
            return false
        }
        #expect(guidanceIndex != nil)
        if let firstAnswerIndex, let guidanceIndex, let finalAnswerIndex {
            #expect(firstAnswerIndex < guidanceIndex)
            #expect(guidanceIndex < finalAnswerIndex)
        }
    }
}
#endif
