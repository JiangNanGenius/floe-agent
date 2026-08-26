// FloeApp — Unified, sequence-ordered thread timeline projection.
//
// SPDX-License-Identifier: MPL-2.0
//
// The canonical thread must render in true chronological order. The old
// layout rendered every persisted message first and every run event after,
// which made "Completed" float above (or below) the final assistant reply
// regardless of the stored sequence. This projection merges the selected
// run's persisted events with the conversation's user/final messages into
// one strictly ordered item list.
//
// Ordering rules of record:
// - Run events order by `RunEventRecord.sequence` only — never by Date.
// - The selected run's user goal anchors the front of the run block; the
//   newest `.assistantText` event carries the final reply; `.terminal` is
//   always last.
// - Assistant messages already represented by an `.assistantText` event
//   (matched by content) are projected from the event only, so a reloaded
//   thread never shows the final reply twice.
// - Legacy runs without an `.assistantText` event fall back to the
//   persisted assistant message, inserted immediately before `.terminal`.
// - Live items (streaming tail, live reasoning, thinking indicator,
//   pending approvals) get explicit slots relative to the last persisted
//   sequence, so refreshing never rebuilds the whole list identity.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeModels
import FloePersistence
import FloeAgentRuntime

/// One row of the unified thread timeline.
enum ThreadTimelineItem: Identifiable, Hashable {
    /// The goal message that started the selected run.
    case userMessage(PersistedMessage)
    /// The final assistant answer of the selected run (from an
    /// `.assistantText` event or the legacy message fallback).
    case assistantMessage(text: String, idSuffix: String)
    /// Persisted run event (status / reasoning / tool / approval / error).
    case event(RunEventRecord)
    /// A collapsible group of consecutive reasoning/tool steps between two
    /// text messages. Only the latest group is expanded by default; history
    /// groups collapse to a single summary row so long runs stay readable.
    case stepGroup(events: [RunEventRecord], isLatest: Bool)
    /// The run's terminal marker — always the final persisted row.
    case terminal(RunEventRecord)
    /// Provider stream ended without any final assistant text.
    case missingFinalMessage(idSuffix: String)
    /// Live reasoning text while the run is active.
    case liveReasoning
    /// Live streaming assistant tail while the run is active.
    case liveAssistantTail
    /// "Contacting provider / thinking" indicator.
    case liveThinking
    /// A pending human approval card.
    case approval(PendingApproval)

    var id: String {
        switch self {
        case .userMessage(let message):
            return "user.\(message.id.uuidString)"
        case .assistantMessage(_, let idSuffix):
            return "assistant.\(idSuffix)"
        case .event(let record):
            return "event.\(record.id.uuidString)"
        case .stepGroup(let events, _):
            return "stepGroup.\(events.first?.id.uuidString ?? "empty")"
        case .terminal(let record):
            return "terminal.\(record.id.uuidString)"
        case .missingFinalMessage(let idSuffix):
            return "missingFinal.\(idSuffix)"
        case .liveReasoning:
            return "live.reasoning"
        case .liveAssistantTail:
            return "live.tail"
        case .liveThinking:
            return "live.thinking"
        case .approval(let approval):
            return "approval.\(approval.id)"
        }
    }
}

/// Builds the unified timeline from persisted state plus live flags.
enum ThreadTimelineBuilder {

    static func buildConversation(
        messages: [PersistedMessage],
        runs: [RunRecord],
        eventsByRun: [UUID: [RunEventRecord]],
        liveRunID: UUID?,
        isRunning: Bool,
        liveStreamedText: String,
        liveReasoningText: String,
        pendingApprovals: [PendingApproval]
    ) -> [ThreadTimelineItem] {
        let sortedRuns = runs.sorted { $0.startedAt < $1.startedAt }
        var result: [ThreadTimelineItem] = []
        for run in sortedRuns {
            let isLive = run.id == liveRunID && isRunning
            result += build(
                messages: messages,
                events: eventsByRun[run.id, default: []],
                run: run,
                isRunning: isLive,
                liveStreamedText: isLive ? liveStreamedText : "",
                liveReasoningText: isLive ? liveReasoningText : "",
                // A run waiting for a human decision may be represented as
                // suspended rather than "running". Keep its decision card in
                // the timeline until the runtime consumes the answer.
                pendingApprovals: pendingApprovals.filter { $0.runID == run.id }
            )
        }
        let represented = Set(sortedRuns.map(\.id))
        let taskLevel = messages.filter {
            $0.role != "goalContinuation"
                && $0.runID.map(represented.contains) != true
                && !ConversationHistoryAssembler.isLegacyWorkspaceContextNotice($0)
        }
        result += taskLevel.map { message in
            message.role == "user"
                ? .userMessage(message)
                : .assistantMessage(text: message.content, idSuffix: message.id.uuidString)
        }
        return result
    }

    static func build(
        messages: [PersistedMessage],
        events: [RunEventRecord],
        run: RunRecord?,
        isRunning: Bool,
        liveStreamedText: String,
        liveReasoningText: String,
        pendingApprovals: [PendingApproval]
    ) -> [ThreadTimelineItem] {
        var items: [ThreadTimelineItem] = []
        var startingGoalMessageID: UUID?

        // 1. The user goal of the selected run anchors the block. Duplicate
        //    prompts are common, so choose the matching message nearest to
        //    this run's start instead of the last equal string globally.
        if let run {
            let directlyBound = messages.filter { $0.role == "user" && $0.runID == run.id }
            let candidates = directlyBound.isEmpty ? messages.filter {
                $0.role == "user" && $0.runID == nil && $0.content == run.goal
            } : directlyBound
            if let goalMessage = candidates.min(by: {
                abs($0.createdAt.timeIntervalSince(run.startedAt))
                    < abs($1.createdAt.timeIntervalSince(run.startedAt))
            }) {
                startingGoalMessageID = goalMessage.id
                items.append(.userMessage(goalMessage))
            }
        }

        // 2. Persisted run events in stored sequence order. The newest
        //    assistantText event becomes the final-reply row; older ones
        //    (multi-turn text before tool calls) render in place.
        let sortedEvents = events.sorted { $0.sequence < $1.sequence }
        let terminalEvent = sortedEvents.last(where: { $0.kind == .terminal })
        let nonTerminalEvents = sortedEvents.filter {
            $0.kind != .terminal
                && !isTerminalStatusEvent($0)
                && !isStaleStatusEvent($0, currentState: run?.state)
        }
        // A tool request whose result has already arrived must not keep
        // showing "pending" next to its "success" result — that reads as a
        // hang. Match by the call id now persisted on both events.
        let completedToolCallIDs = Set(sortedEvents
            .filter { $0.kind == .toolResult }
            .compactMap { decodePayload($0.payloadJSON)["id"] }
            .filter { !$0.isEmpty })

        var finalReplyRendered = false
        var currentStepGroup: [RunEventRecord] = []
        var guidedMessages = run.map { currentRun in
            messages
                .filter {
                    $0.role == "user"
                        && $0.runID == currentRun.id
                        && $0.id != startingGoalMessageID
                }
                .sorted { lhs, rhs in
                    if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
        } ?? []
        func flushStepGroup() {
            guard !currentStepGroup.isEmpty else { return }
            items.append(.stepGroup(events: currentStepGroup, isLatest: false))
            currentStepGroup = []
        }
        func flushGuidedMessages(upTo date: Date? = nil) {
            while let next = guidedMessages.first,
                  date.map({ next.createdAt <= $0 }) ?? true {
                flushStepGroup()
                items.append(.userMessage(next))
                guidedMessages.removeFirst()
            }
        }
        for event in nonTerminalEvents {
            // Runtime guidance is persisted as another user message bound to
            // the same run. It has no provider event sequence of its own, so
            // place it at the nearest durable event boundary by timestamp
            // without ever reordering provider events relative to each other.
            flushGuidedMessages(upTo: event.createdAt)
            // Render every assistantText event in place (sequence order),
            // not just the last one. The old "final text only" rule inverted
            // the order when verifyFinalAnswer wrote a draft message.
            if event.kind == .assistantText {
                let text = decodePayload(event.payloadJSON)["text"] ?? ""
                if !text.isEmpty {
                    flushStepGroup()
                    items.append(.assistantMessage(
                        text: text,
                        idSuffix: event.id.uuidString
                    ))
                    finalReplyRendered = true
                }
                continue
            }
            if event.kind == .toolRequest,
               let callID = decodePayload(event.payloadJSON)["id"],
               completedToolCallIDs.contains(callID) {
                continue
            }
            // Group consecutive reasoning/tool events into a collapsible
            // stepGroup. userMessage/assistantText breaks the group.
            if event.kind == .reasoning
                || event.kind == .toolRequest
                || event.kind == .toolResult
                || event.kind == .approval
                || event.kind == .autoApproved {
                currentStepGroup.append(event)
                continue
            }
            flushStepGroup()
            items.append(.event(event))
        }
        flushStepGroup()
        flushGuidedMessages()
        // Preserve the true sequence while expanding only the newest group.
        if let latestIndex = items.indices.last(where: {
            if case .stepGroup = items[$0] { return true }
            return false
        }), case .stepGroup(let groupEvents, _) = items[latestIndex] {
            items[latestIndex] = .stepGroup(events: groupEvents, isLatest: true)
        }

        // 3. Legacy fallback: the run completed and persisted a final
        //    assistant message but no assistantText event (written before
        //    the ordering fix). Insert it directly before terminal.
        if !finalReplyRendered, let run, RunStateLocalizer.isTerminal(run.state) {
            // Bind the fallback to this run's time window. Otherwise an
            // older selected run can accidentally display the newest
            // assistant message from another run in the conversation.
            let upperBound = run.endedAt ?? .distantFuture
            let directlyBound = messages.filter {
                $0.role == "assistant" && $0.runID == run.id
            }
            let assistantMessages = directlyBound.isEmpty ? messages.filter {
                $0.role == "assistant"
                    && $0.runID == nil
                    && $0.createdAt >= run.startedAt
                    && $0.createdAt <= upperBound.addingTimeInterval(2)
            } : directlyBound
            if let latest = assistantMessages.last, !latest.content.isEmpty {
                items.append(.assistantMessage(
                    text: latest.content,
                    idSuffix: latest.id.uuidString
                ))
                finalReplyRendered = true
            }
        }

        // 4. A completed run with neither an assistantText event nor a
        //    persisted assistant message is an explicit "no final reply"
        //    surface — never a silent success.
        if !finalReplyRendered,
           let run, run.state == "completed",
           !isRunning {
            items.append(.missingFinalMessage(idSuffix: run.id.uuidString))
        }

        // 5. Live slots, after persisted rows, while the run is active.
        if isRunning {
            if !liveReasoningText.isEmpty {
                items.append(.liveReasoning)
            }
            if !liveStreamedText.isEmpty {
                items.append(.liveAssistantTail)
            }
            if liveStreamedText.isEmpty && liveReasoningText.isEmpty {
                items.append(.liveThinking)
            }
        }

        // 6. Modern approvals render inside their matching tool disclosure.
        // Keep the standalone row only for legacy events that lack a durable
        // call ID, so no approval card is pinned independently at the bottom.
        let representedApprovalCallIDs = Set(sortedEvents.compactMap { event -> String? in
            guard event.kind == .toolRequest || event.kind == .toolResult else { return nil }
            let value = decodePayload(event.payloadJSON)["callID"]
                ?? decodePayload(event.payloadJSON)["id"]
                ?? ""
            return value.isEmpty ? nil : value
        })
        for approval in pendingApprovals
            where !representedApprovalCallIDs.contains(approval.toolCall.id) {
            items.append(.approval(approval))
        }

        // 7. Terminal is always the last persisted row of the run block.
        if let terminalEvent {
            items.append(.terminal(terminalEvent))
        }

        return items
    }

    /// Runtime transitions persist a terminal `.status` before the final
    /// `.assistantText` event. That status belongs in the toolbar, not the
    /// visible event stream, or "Completed" appears above the answer.
    private static func isTerminalStatusEvent(_ event: RunEventRecord) -> Bool {
        guard event.kind == .status else { return false }
        let state = decodePayload(event.payloadJSON)["state"] ?? ""
        return RunStateLocalizer.isTerminal(state)
    }

    /// Launch preparation is persisted for recovery, but it is not a
    /// historical chat message. Once the run advances, retaining that row in
    /// the timeline falsely says "preparing" while tokens or tools are
    /// already arriving. The toolbar/live projection owns the current state.
    private static func isStaleStatusEvent(
        _ event: RunEventRecord,
        currentState: String?
    ) -> Bool {
        guard event.kind == .status, let currentState else { return false }
        return decodePayload(event.payloadJSON)["state"] != currentState
    }

    private static func decodePayload(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}
#endif
