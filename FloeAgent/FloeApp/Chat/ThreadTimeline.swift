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
import FloeCore
import FloeModels
import FloePersistence
import FloeAgentRuntime
import FloeExecution

/// One compact decision record projected onto the tool invocation that
/// produced the proposal. The durable decision message is never deleted or
/// rewritten by this projection: the standalone row is replaced by this
/// annotation inside the matching tool step, so the audit bytes stay in the
/// transcript while the chat stream stops repeating one bubble per automatic
/// apply.
struct ToolDecisionAnnotation: Identifiable, Hashable {
    /// The durable decision message id (deterministic per proposal+decision).
    let id: UUID
    /// The tool call this decision belongs to (the same callID vocabulary the
    /// tool cards and approval summaries use).
    let callID: String
    /// The run that owns the correlated tool call. Raw provider call ids are
    /// NOT unique across runs (the approval-card contract scopes by
    /// `runID + callID` for the same reason), so a card only renders the
    /// decision whose correlated call belongs to the SAME run. Nil only for
    /// legacy/uncorrelated callers.
    let runID: UUID?
    let proposalID: UUID
    /// The raw recorded decision vocabulary ("applied", "rejected", …).
    let decision: String
    /// Concise, decision-specific localized sentence.
    let summary: String
}

/// Run-scoped resolution of delegated-child cards and decision annotations.
///
/// Raw provider tool-call ids are NOT unique across runs (the app's approval
/// cards scope by `runID + callID` for exactly this reason), so an unscoped
/// callID lookup can open another run's child transcript or decorate the
/// wrong row with a decision. These pure helpers are the single rule every
/// card site uses and are directly testable without a live view model.
enum ThreadRunScopedResolution {
    /// The child created by `callID` inside exactly `parentRunID`; within one
    /// run the newest child wins when a provider repeats an id.
    static func child(
        callID: String?,
        parentRunID: UUID,
        in records: [ChildRunRecord]
    ) -> ChildRunRecord? {
        guard let callID, !callID.isEmpty else { return nil }
        return records
            .filter { $0.delegateCallID == callID && $0.parentRunID == parentRunID }
            .max { $0.startedAt < $1.startedAt }
    }

    /// Decision summaries correlated to `callID` in exactly `runID`, in
    /// annotation order, deduplicated. A legacy annotation without a run is
    /// accepted only when no run-scoped annotation matches (historical
    /// callers keep rendering; every automatic correlation carries its run).
    static func decisionSummaries(
        callID: String?,
        runID: UUID,
        in annotations: [ToolDecisionAnnotation]
    ) -> [String] {
        guard let callID, !callID.isEmpty else { return [] }
        var matched = annotations.filter { $0.callID == callID && $0.runID == runID }
        if matched.isEmpty {
            matched = annotations.filter { $0.callID == callID && $0.runID == nil }
        }
        var seen = Set<String>()
        return matched.map(\.summary).filter { seen.insert($0).inserted }
    }
}

/// Catalog lookup with a bilingual source fallback, shared by the chat
/// presentation helpers. Before the integration owner registers a new key in
/// `Localizable.xcstrings`, the exact same EN/ZH sentence is shown inline
/// instead of a raw dotted key; the catalog wins as soon as it exists (see
/// `A/INTEGRATION.md` for the key list).
enum ChatBilingualCatalog {
    static func localized(key: String, en: String, zh: String) -> String {
        let value = FloeL10n.l(key)
        if value != key { return value }
        return FloeL10n.isChinese ? zh : en
    }
}

/// Presentation projection for `ProposalDecisionNoticeProjection` rows.
///
/// The generic "design decision recorded" sentence is only correct for an
/// unknown decision vocabulary. Every known decision gets its own concise
/// sentence, and a decision whose trusted producer marker is
/// `tool-automatic` is correlated to the tool call that produced/applied its
/// proposal (the persisted apply receipt carries the proposal id and the
/// `runtime-authority` mode, which disambiguates propose vs apply when both
/// are present), so it renders inside that step instead of as a separate chat
/// bubble. Body/text deduplication is deliberately NOT used: two applies on
/// different proposals are two legitimate records, and a `user` decision
/// always keeps its own concise row.
enum ProposalDecisionPresentation {

    struct Notice: Identifiable, Equatable {
        let id: UUID
        let decision: String
        let proposalID: UUID
        let summary: String
        /// The trusted producer marker (`user` / `tool-automatic`), parsed
        /// from the event itself; historical rows default to `.user`.
        let origin: ProposalDecisionNoticeProjection.DecisionOrigin
        /// Non-nil when this decision is a tool-originated automatic decision
        /// and the matching tool call is present in the loaded events.
        let automaticCallID: String?
        /// The run that owns the correlated tool call (`automaticCallID`).
        /// Raw provider call ids repeat across runs, so both the annotation
        /// and the standalone-row suppression stay scoped to this run.
        let automaticRunID: UUID?
        var annotation: ToolDecisionAnnotation? {
            automaticCallID.map {
                ToolDecisionAnnotation(
                    id: id, callID: $0, runID: automaticRunID, proposalID: proposalID,
                    decision: decision, summary: summary)
            }
        }
    }

    /// One validated notice for a durable message, or nil for every other row.
    static func trustedNotice(for message: PersistedMessage) -> Notice? {
        guard let event = ProposalDecisionNoticeProjection.trustedEvent(in: message) else {
            return nil
        }
        return Notice(
            id: message.id, decision: event.decision, proposalID: event.proposalID,
            summary: summary(for: event.decision), origin: event.origin,
            automaticCallID: nil, automaticRunID: nil)
    }

    /// Decision-specific concise summary for a queued/promoted steering row of
    /// the same trusted decision event (a pending row carries no role, so the
    /// deterministic derivation is the proof). Nil for every other row, which
    /// then keeps the existing projection.
    static func summary(for input: PendingUserInput) -> String? {
        guard let event = ProposalDecisionNoticeProjection.derivedEvent(
            id: input.id, conversationID: input.conversationID, content: input.content)
        else { return nil }
        return summary(for: event.decision)
    }

    /// All validated decision notices of the conversation, correlated with the
    /// loaded events (correlation is additive: an uncorrelated notice keeps a
    /// concise standalone row and is never hidden).
    static func notices(
        messages: [PersistedMessage],
        events: [RunEventRecord]
    ) -> [Notice] {
        messages.compactMap { message in
            guard let event = ProposalDecisionNoticeProjection.trustedEvent(in: message) else {
                return nil
            }
            let correlation = event.origin == .toolAutomatic
                ? applyCall(proposalID: event.proposalID, events: events)
                : nil
            return Notice(
                id: message.id, decision: event.decision, proposalID: event.proposalID,
                summary: summary(for: event.decision), origin: event.origin,
                automaticCallID: correlation?.callID,
                automaticRunID: correlation?.runID)
        }
    }

    /// The tool call that produced (or applied) this proposal inside the
    /// loaded events, WITH the run that owns it. The trusted `origin` marker
    /// is the authority; the apply receipt (`runtime-authority`) is preferred
    /// only to pick the right call when both the propose and apply calls
    /// reference the proposal. Returns nil when no loaded event references the
    /// proposal, in which case the notice keeps its standalone concise row
    /// rather than disappearing. The run is carried because raw provider call
    /// ids are not unique across runs.
    private static func applyCall(
        proposalID: UUID, events: [RunEventRecord]
    ) -> (callID: String, runID: UUID)? {
        let needle = proposalID.uuidString
        var fallback: (callID: String, runID: UUID)?
        for event in events.reversed()
        where event.kind == .toolRequest || event.kind == .toolResult {
            guard event.payloadJSON.contains(needle) else { continue }
            guard let callID = callID(in: event.payloadJSON) else { continue }
            // The apply receipt is preferred over the propose call; the marker
            // may sit in the flat payload or (escaped) inside the summary, so
            // both the raw and the nested shapes are matched.
            if event.payloadJSON.contains("runtime-authority") {
                return (callID, event.runID)
            }
            if fallback == nil { fallback = (callID, event.runID) }
        }
        return fallback
    }

    /// `callID` / `id` from one tool event payload.
    ///
    /// Production payloads are flat string maps, but a receipt-style nested
    /// payload must not silently lose its correlation, so both shapes are
    /// read. A payload with no usable call id returns nil (the notice then
    /// keeps its standalone row instead of decorating the wrong step).
    private static func callID(in payloadJSON: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(
            with: Data(payloadJSON.utf8)) as? [String: Any] else { return nil }
        for key in ["callID", "id"] {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    /// Decision-specific concise summary. The verb is classified from the
    /// app-generated decision vocabulary; anything unknown keeps the existing
    /// generic key, so a new producer value can never be misstated.
    static func summary(for decision: String) -> String {
        switch verb(for: decision) {
        case .applied:
            return localized(
                key: "design.owner.decision_applied_note",
                en: "Design decision recorded: the proposed change was applied. This task is not restarted automatically.",
                zh: "已记录设计决定：提案修改已应用。本任务不会自动重启。")
        case .rejected:
            return localized(
                key: "design.owner.decision_rejected_note",
                en: "Design decision recorded: the proposal was rejected. This task is not restarted automatically.",
                zh: "已记录设计决定：提案已被拒绝。本任务不会自动重启。")
        case .failed:
            return localized(
                key: "design.owner.decision_failed_note",
                en: "Design decision recorded: the proposed change was not applied. This task is not restarted automatically.",
                zh: "已记录设计决定：提案修改未能应用。本任务不会自动重启。")
        case .adopted:
            return localized(
                key: "design.owner.decision_adopted_note",
                en: "Design decision recorded: the result was adopted. This task is not restarted automatically.",
                zh: "已记录设计决定：结果已采纳。本任务不会自动重启。")
        case .recorded:
            return FloeL10n.l("design.owner.decision_recorded_note")
        }
    }

    enum Verb: Equatable {
        case applied
        case rejected
        case failed
        case adopted
        case recorded
    }

    static func verb(for decision: String) -> Verb {
        let value = decision.lowercased()
        if value.contains("adopt") { return .adopted }
        if value.contains("reject") || value.contains("discard") || value.contains("declin") {
            return .rejected
        }
        if value.contains("fail") || value.contains("interrupt")
            || value.contains("invalidat") || value.contains("error") {
            return .failed
        }
        if value.contains("appl") { return .applied }
        return .recorded
    }

    /// Catalog lookup with a bilingual source fallback: before the integration
    /// owner adds the key, the same exact sentence is shown inline instead of
    /// a raw dotted key, and the catalog wins as soon as it exists.
    private static func localized(key: String, en: String, zh: String) -> String {
        ChatBilingualCatalog.localized(key: key, en: en, zh: zh)
    }
}

/// One row of the unified thread timeline.
enum ThreadTimelineItem: Identifiable, Hashable {
    case earlierEvents(runID: UUID)
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
        case .earlierEvents(let runID):
            return "earlier-events.\(runID.uuidString)"
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

    /// Per-build payload decode cache. Every predicate in one build reads the
    /// same immutable event bytes, so each event is decoded at most once per
    /// build instead of 3–6 times with a fresh decoder each time.
    private final class PayloadCache {
        private let decoder = JSONDecoder()
        private var values: [UUID: [String: String]] = [:]

        func payload(for event: RunEventRecord) -> [String: String] {
            if let cached = values[event.id] { return cached }
            let decoded = Self.decode(event.payloadJSON, decoder: decoder)
            values[event.id] = decoded
            return decoded
        }

        static func decode(_ json: String, decoder: JSONDecoder) -> [String: String] {
            guard let data = json.data(using: .utf8) else { return [:] }
            return (try? decoder.decode([String: String].self, from: data)) ?? [:]
        }
    }

    static func buildConversation(
        messages: [PersistedMessage],
        runs: [RunRecord],
        eventsByRun: [UUID: [RunEventRecord]],
        liveRunID: UUID?,
        isRunning: Bool,
        liveStreamedText: String,
        liveReasoningText: String,
        pendingApprovals: [PendingApproval],
        earlierEventRunIDs: Set<UUID> = [],
        // Decision notices that are projected INTO their tool step (see
        // `ToolDecisionAnnotation`): their standalone row is replaced by the
        // in-step decision line the caller renders. Never used for an
        // uncorrelated/manual decision.
        suppressedDecisionNoticeIDs: Set<UUID> = []
    ) -> [ThreadTimelineItem] {
        let payloadCache = PayloadCache()
        let sortedRuns = runs.sorted { $0.startedAt < $1.startedAt }
        // Index the loaded messages once; `build` previously re-filtered the
        // full message array per run (O(runs × messages) per rebuild).
        var boundByRun: [UUID: [PersistedMessage]] = [:]
        var unboundUserMessages: [PersistedMessage] = []
        var unboundAssistantMessages: [PersistedMessage] = []
        for message in messages {
            if let runID = message.runID {
                boundByRun[runID, default: []].append(message)
            } else if message.role == "user" {
                unboundUserMessages.append(message)
            } else if message.role == "assistant" {
                unboundAssistantMessages.append(message)
            }
        }
        var result: [ThreadTimelineItem] = []
        for run in sortedRuns {
            let isLive = run.id == liveRunID && isRunning
            if earlierEventRunIDs.contains(run.id) {
                result.append(.earlierEvents(runID: run.id))
            }
            let runItems = build(
                messagesForRun: boundByRun[run.id, default: []],
                unboundUserMessages: unboundUserMessages,
                unboundAssistantMessages: unboundAssistantMessages,
                events: eventsByRun[run.id, default: []],
                run: run,
                isRunning: isLive,
                liveStreamedText: isLive ? liveStreamedText : "",
                liveReasoningText: isLive ? liveReasoningText : "",
                // A run waiting for a human decision may be represented as
                // suspended rather than "running". Keep its decision card in
                // the timeline until the runtime consumes the answer.
                pendingApprovals: pendingApprovals.filter { $0.runID == run.id },
                payloadCache: payloadCache
            )
            result += runItems.map { item in
                if run.id != liveRunID, case .stepGroup(let events, _) = item {
                    return .stepGroup(events: events, isLatest: false)
                }
                return item
            }
        }
        let represented = Set(sortedRuns.map(\.id))
        let taskLevel = messages.filter {
            $0.role != "goalContinuation"
                && $0.runID.map(represented.contains) != true
                && !ConversationHistoryAssembler.isLegacyWorkspaceContextNotice($0)
        }
        result += taskLevel.compactMap { message -> ThreadTimelineItem? in
            // A decision projected into its tool step does not repeat as a
            // standalone row. The durable message itself is untouched.
            guard !suppressedDecisionNoticeIDs.contains(message.id) else { return nil }
            // A trusted proposal decision gets its decision-specific concise
            // sentence (applied / rejected / failed / adopted); an unknown
            // decision vocabulary keeps the existing generic summary.
            if let notice = ProposalDecisionPresentation.trustedNotice(for: message) {
                return .assistantMessage(text: notice.summary, idSuffix: message.id.uuidString)
            }
            // The trusted internal notices (design-assistant confirmation and
            // structured proposal decision) are internal structured events.
            // Ordinary surfaces show the concise localized summary instead of
            // the raw template; user and assistant text (even bytes carrying
            // the same marker) and every unrecognized system notice keep their
            // existing rendering.
            if let summary = InternalNoticeProjection.userFacingSummary(for: message) {
                return .assistantMessage(text: summary, idSuffix: message.id.uuidString)
            }
            return message.role == "user"
                ? .userMessage(message)
                : .assistantMessage(text: message.content, idSuffix: message.id.uuidString)
        }
        return result
    }

    /// Single-run convenience entry for tests and previews: performs the
    /// per-run message grouping and owns a fresh payload cache.
    static func build(
        messages: [PersistedMessage],
        events: [RunEventRecord],
        run: RunRecord?,
        isRunning: Bool,
        liveStreamedText: String,
        liveReasoningText: String,
        pendingApprovals: [PendingApproval]
    ) -> [ThreadTimelineItem] {
        var boundByRun: [UUID: [PersistedMessage]] = [:]
        var unboundUserMessages: [PersistedMessage] = []
        var unboundAssistantMessages: [PersistedMessage] = []
        for message in messages {
            if let runID = message.runID {
                boundByRun[runID, default: []].append(message)
            } else if message.role == "user" {
                unboundUserMessages.append(message)
            } else if message.role == "assistant" {
                unboundAssistantMessages.append(message)
            }
        }
        let payloadCache = PayloadCache()
        return build(
            messagesForRun: run.map { boundByRun[$0.id, default: []] } ?? [],
            unboundUserMessages: unboundUserMessages,
            unboundAssistantMessages: unboundAssistantMessages,
            events: events,
            run: run,
            isRunning: isRunning,
            liveStreamedText: liveStreamedText,
            liveReasoningText: liveReasoningText,
            pendingApprovals: pendingApprovals,
            payloadCache: payloadCache
        )
    }

    private static func build(
        messagesForRun: [PersistedMessage],
        unboundUserMessages: [PersistedMessage],
        unboundAssistantMessages: [PersistedMessage],
        events: [RunEventRecord],
        run: RunRecord?,
        isRunning: Bool,
        liveStreamedText: String,
        liveReasoningText: String,
        pendingApprovals: [PendingApproval],
        payloadCache: PayloadCache
    ) -> [ThreadTimelineItem] {
        var items: [ThreadTimelineItem] = []
        var startingGoalMessageID: UUID?

        // 1. The user goal of the selected run anchors the block. Duplicate
        //    prompts are common, so choose the matching message nearest to
        //    this run's start instead of the last equal string globally.
        if let run {
            let directlyBound = messagesForRun.filter { $0.role == "user" }
            let candidates = directlyBound.isEmpty ? unboundUserMessages.filter {
                $0.content == run.goal
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
        // The provider still receives one paired result for every call ID,
        // including calls that the Harness intentionally coalesced or blocked.
        // Those synthetic pairs are protocol bookkeeping, not user steps;
        // omit the matching request/result/approval rows so the timeline shows
        // the single authoritative execution instead of duplicate failures.
        let suppressedToolCallIDs = Set(sortedEvents.compactMap { event -> String? in
            guard event.kind == .toolResult else { return nil }
            let payload = payloadCache.payload(for: event)
            guard payload["summary"]?.hasPrefix("Harness suppression:") == true else {
                return nil
            }
            let callID = payload["callID"] ?? payload["id"] ?? ""
            return callID.isEmpty ? nil : callID
        })
        let isStandaloneNativeService = run.map { run in
            sortedEvents.contains {
                NativeServiceRunMetadata.matches($0, runID: run.id, conversationID: run.conversationID)
            }
        } ?? false
        let terminalEvent = sortedEvents.last(where: { $0.kind == .terminal })
        let hasReachedTerminal = terminalEvent != nil
            || run.map { RunStateLocalizer.isTerminal($0.state) } == true
        let lastAssistantTextSequence = sortedEvents
            .last(where: { $0.kind == .assistantText })?
            .sequence
        let lastToolSequence = sortedEvents
            .last(where: { $0.kind == .toolRequest || $0.kind == .toolResult })?
            .sequence
        let nonTerminalEvents = sortedEvents.filter { event in
            event.kind != .terminal
                && !(run.map { run in
                    NativeServiceRunMetadata.matches(event, runID: run.id, conversationID: run.conversationID)
                } ?? false)
                && !isTerminalStatusEvent(event, payloadCache: payloadCache)
                && !isStaleStatusEvent(event, currentState: run?.state, payloadCache: payloadCache)
                && !isSuppressedToolProtocolEvent(
                    event,
                    suppressedCallIDs: suppressedToolCallIDs,
                    payloadCache: payloadCache
                )
                && !isTrailingVerificationReasoning(
                    event,
                    hasReachedTerminal: hasReachedTerminal,
                    lastAssistantTextSequence: lastAssistantTextSequence,
                    lastToolSequence: lastToolSequence
                )
        }
        var finalReplyRendered = false
        var currentStepGroup: [RunEventRecord] = []
        var guidedMessages = run.map { _ in
            messagesForRun
                .filter { $0.role == "user" && $0.id != startingGoalMessageID }
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
                let text = payloadCache.payload(for: event)["text"] ?? ""
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
            // A new provider turn begins after the preceding tool result.
            // Keep its reasoning above the next invocation instead of
            // appending it below the tool that produced the result. The
            // request row remains in the group even after completion: the
            // card pairs it with the result by call ID so one disclosure owns
            // the exact input command, approval, output and duration.
            if event.kind == .reasoning,
               currentStepGroup.last?.kind == .toolResult {
                flushStepGroup()
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
            let directlyBound = messagesForRun.filter { $0.role == "assistant" }
            let assistantMessages = directlyBound.isEmpty ? unboundAssistantMessages.filter {
                $0.createdAt >= run.startedAt
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
           !isStandaloneNativeService,
           !isRunning {
            items.append(.missingFinalMessage(idSuffix: run.id.uuidString))
        }

        // 5. Live slots, after persisted rows, while the run is active. A
        //    terminal event wins over a stale animator-drain flag: the final
        //    assistantText is already durable, so replaying the live tail here
        //    would make text or reasoning jump below the terminal row.
        if isRunning && terminalEvent == nil {
            if !liveReasoningText.isEmpty {
                items.append(.liveReasoning)
            }
            if !liveStreamedText.isEmpty {
                items.append(.liveAssistantTail)
            }
            if liveStreamedText.isEmpty && liveReasoningText.isEmpty,
               run.map({ ["preparing", "streamingModel", "reconnecting"].contains($0.state) }) ?? true {
                items.append(.liveThinking)
            }
        }

        // 6. Modern approvals render inside their matching tool disclosure.
        // Keep the standalone row only for legacy events that lack a durable
        // call ID, so no approval card is pinned independently at the bottom.
        let representedApprovalCallIDs = Set(sortedEvents.compactMap { event -> String? in
            guard event.kind == .toolRequest || event.kind == .toolResult else { return nil }
            let payload = payloadCache.payload(for: event)
            let value = payload["callID"] ?? payload["id"] ?? ""
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
    private static func isTerminalStatusEvent(
        _ event: RunEventRecord,
        payloadCache: PayloadCache
    ) -> Bool {
        guard event.kind == .status else { return false }
        let state = payloadCache.payload(for: event)["state"] ?? ""
        return RunStateLocalizer.isTerminal(state)
    }

    private static func isSuppressedToolProtocolEvent(
        _ event: RunEventRecord,
        suppressedCallIDs: Set<String>,
        payloadCache: PayloadCache
    ) -> Bool {
        guard event.kind == .toolRequest
                || event.kind == .toolResult
                || event.kind == .approval
                || event.kind == .autoApproved else { return false }
        let payload = payloadCache.payload(for: event)
        let callID = payload["callID"] ?? payload["id"] ?? ""
        return !callID.isEmpty && suppressedCallIDs.contains(callID)
    }

    /// Final-answer verification is deliberately private harness work. When
    /// the draft answer has already been persisted and the tool-free review
    /// returns a bare confirmation, only its reasoning remains in the event
    /// store. Do not project that tail below the user-visible final answer.
    /// Reasoning which still leads to a tool stays visible.
    private static func isTrailingVerificationReasoning(
        _ event: RunEventRecord,
        hasReachedTerminal: Bool,
        lastAssistantTextSequence: Int?,
        lastToolSequence: Int?
    ) -> Bool {
        guard hasReachedTerminal,
              event.kind == .reasoning,
              let lastAssistantTextSequence,
              event.sequence > lastAssistantTextSequence else { return false }
        return lastToolSequence.map { $0 < event.sequence } ?? true
    }

    /// Launch preparation is persisted for recovery, but it is not a
    /// historical chat message. Once the run advances, retaining that row in
    /// the timeline falsely says "preparing" while tokens or tools are
    /// already arriving. The toolbar/live projection owns the current state.
    private static func isStaleStatusEvent(
        _ event: RunEventRecord,
        currentState: String?,
        payloadCache: PayloadCache
    ) -> Bool {
        guard event.kind == .status, let currentState else { return false }
        return payloadCache.payload(for: event)["state"] != currentState
    }

}
#endif
