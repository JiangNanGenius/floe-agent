// FloeApp — Collapsible step-group row for the unified timeline.
//
// Groups consecutive reasoning/tool events between two text messages into
// one collapsible card. Only the latest group is expanded by default; history
// groups collapse to a single summary row so long runs stay readable.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeModels
import FloePersistence
import FloeSecurity
import FloeTools

import FloeCore
enum StepGroupDisclosurePolicy {
    static func initiallyExpanded(
        isLatest: Bool, isLive: Bool, hasError: Bool, hasPendingApproval: Bool
    ) -> Bool {
        isLatest || isLive || hasError || hasPendingApproval
    }
}

struct StepGroupView: View {
    let events: [RunEventRecord]
    let isLatest: Bool
    let isLive: Bool
    let hasError: Bool
    private let liveFinishedTools: [String: String]
    private let allPendingApprovals: [PendingApproval]
    /// Decision records projected onto this group's tool calls (see
    /// `ToolDecisionAnnotation`). Empty for callers without decision
    /// projection (e.g. the canvas surface).
    private let decisions: [ToolDecisionAnnotation]
    /// Durable delegated-child records, resolved per call AND per run: a raw
    /// provider call id is not unique across runs, so a delegate card may only
    /// match a child whose parent run is the run that rendered the call.
    private let childRunRecords: [ChildRunRecord]
    private let onOpenChild: ((ChildRunRecord?) -> Void)?
    private let onOpenGameFiles: ((UUID) -> Void)?
    private let conversationID: UUID?
    private let toolDetailExpansion: (@MainActor (RunEventRecord) -> Binding<Bool?>)?
    let onResolveApproval: (PendingApproval, ApprovalDecision) -> Void
    @StateObject private var projection = StepGroupMetadata()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded: Bool

    private func callID(for event: RunEventRecord, payloads: [UUID: [String: String]]) -> String? {
        let payload = (payloads[event.id] ?? [:])
        guard event.kind == .toolRequest || event.kind == .toolResult else { return nil }
        let callID = payload["callID"] ?? payload["id"] ?? ""
        return callID.isEmpty ? nil : callID
    }

    private func matchingResult(
        for event: RunEventRecord, snapshot: StepGroupMetadata.Snapshot
    ) -> RunEventRecord? {
        guard event.kind == .toolRequest, let requestID = callID(for: event, payloads: snapshot.payloads)
        else { return nil }
        return snapshot.results[requestID]
    }

    private func displayedEvents(_ snapshot: StepGroupMetadata.Snapshot) -> [RunEventRecord] {
        events.filter {
            !isDetachedApproval($0, snapshot: snapshot) && !isPairedToolResult($0, snapshot: snapshot)
        }
    }
    private func activeTools(_ displayed: [RunEventRecord], snapshot: StepGroupMetadata.Snapshot) -> [RunEventRecord] {
        displayed.filter { $0.kind == .toolRequest && matchingResult(for: $0, snapshot: snapshot) == nil
            && callID(for: $0, payloads: snapshot.payloads).flatMap { liveFinishedTools[$0] } == nil && isLive }
    }
    private func failedTools(
        _ displayed: [RunEventRecord], snapshot: StepGroupMetadata.Snapshot, pending: [PendingApproval]
    ) -> [RunEventRecord] {
        displayed.filter {
            guard $0.kind == .toolRequest || $0.kind == .toolResult else { return $0.kind == .error }
            return ["failed", "error", "denied", "expired", "needsUser"].contains(
                requestStatus(for: $0, snapshot: snapshot, pending: pending)
                ?? (snapshot.payloads[$0.id] ?? [:])["status"] ?? "")
        }
    }
    private func summary(_ displayed: [RunEventRecord]) -> String {
        let tools = displayed.filter { $0.kind == .toolRequest || $0.kind == .toolResult }.count
        let reasoningCount = displayed.filter { $0.kind == .reasoning }.count
        return [tools > 0 ? FloeL10n.plural("chat.step_group_view.tool_calls", count: tools) : nil,
                reasoningCount > 0 ? FloeL10n.plural("chat.step_group_view.thinking_segments", count: reasoningCount) : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
    private func stateTitle(displayed: [RunEventRecord], snapshot: StepGroupMetadata.Snapshot, pending: [PendingApproval]) -> String {
        if !pending.isEmpty { return FloeL10n.l("chat.step_group_view.waiting_for_confirmation") }
        let failed = failedTools(displayed, snapshot: snapshot, pending: pending)
        if !failed.isEmpty { return FloeL10n.plural("chat.step_group_view.items_need_review", count: failed.count) }
        let active = activeTools(displayed, snapshot: snapshot)
        if !active.isEmpty { return FloeL10n.plural("chat.step_group_view.items_running", count: active.count) }
        return isLive ? FloeL10n.l("chat.step_group_view.run_records") : FloeL10n.l("chat.step_group_view.view_run_records")
    }
    private func stateColor(displayed: [RunEventRecord], snapshot: StepGroupMetadata.Snapshot, pending: [PendingApproval]) -> Color {
        if !pending.isEmpty { return FloeTheme.pending }
        if !failedTools(displayed, snapshot: snapshot, pending: pending).isEmpty { return FloeTheme.destructive }
        return !activeTools(displayed, snapshot: snapshot).isEmpty ? FloeTheme.primary : .secondary
    }
    private func visibleEvents(_ displayed: [RunEventRecord], snapshot: StepGroupMetadata.Snapshot, pending: [PendingApproval]) -> [RunEventRecord] {
        if isExpanded { return displayed }
        // A collapsed batch never hides a decision, current activity or error.
        var urgent = Set((activeTools(displayed, snapshot: snapshot)
            + failedTools(displayed, snapshot: snapshot, pending: pending)).map(\.id))
        for event in displayed where decisionSummary(for: event, payloads: snapshot.payloads) != nil {
            urgent.insert(event.id)
        }
        // A completed export is a user result, even after the outer activity
        // group collapses. Keep its invocation/file row reachable without
        // exposing unrelated diagnostic events or arbitrary tool paths. The
        // receipt/GitHub scans are derived once per event-set change by the
        // projection, not re-decoded on every body evaluation.
        for event in displayed
        where snapshot.receiptEventIDs.contains(event.id) || snapshot.gitHubSourceEventIDs.contains(event.id) {
            urgent.insert(event.id)
        }
        return displayed.filter { urgent.contains($0.id) || pendingApproval(for: $0, snapshot: snapshot, pending: pending) != nil }
    }

    var body: some View {
        // One projection read per body evaluation. Every row lookup below
        // shares this snapshot; the projection itself only re-derives when
        // the event set (or owning conversation) actually changes.
        let snapshot = projection.read(events, conversationID: conversationID)
        let pending = allPendingApprovals.filter { snapshot.requests.contains($0.toolCall.id) }
        let displayed = displayedEvents(snapshot)
        let rows = visibleEvents(displayed, snapshot: snapshot, pending: pending)
        let title = summary(displayed)
        let state = stateTitle(displayed: displayed, snapshot: snapshot, pending: pending)
        let color = stateColor(displayed: displayed, snapshot: snapshot, pending: pending)
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(FloeTheme.motionAnimation(reduceMotion: reduceMotion)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up").foregroundStyle(color)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title.isEmpty ? "chat.step_group_view.run_records" : title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Text(state).font(.caption).foregroundStyle(color)
                    }
                    Spacer(minLength: 8)
                    Text(isExpanded ? "terminal.hide" : "chat.step_group_view.expand").font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0)).foregroundStyle(.secondary)
                }
                .frame(minHeight: FloeTheme.minimumTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("thread.steps.toggle")
            .accessibilityValue(isExpanded ? FloeL10n.l("chat.step_group_view.expanded") : FloeL10n.l("chat.step_group_view.collapsed"))
            if let onOpenGameFiles, let projectID = snapshot.createdGameID {
                Button {
                    onOpenGameFiles(projectID)
                } label: {
                    Label(IDELanguageRunText.t("工程文件", "Project files"), systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("thread.game.files")
            }
            if !rows.isEmpty {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(rows) { event in
                        ThreadEventView(
                            event: event, isLive: isLive, hasError: hasError, onRetry: nil,
                            approvalSummary: approvalSummary(for: event, snapshot: snapshot),
                            toolRequestStatus: requestStatus(for: event, snapshot: snapshot, pending: pending),
                            toolRequestResultPayloadJSON: matchingResult(for: event, snapshot: snapshot)?.payloadJSON,
                            toolRequestResultEvent: matchingResult(for: event, snapshot: snapshot),
                            toolRequestIsWaiting: pendingApproval(for: event, snapshot: snapshot, pending: pending) != nil,
                            decisionSummary: decisionSummary(for: event, payloads: snapshot.payloads),
                            childRun: childRun(for: event, payloads: snapshot.payloads),
                            onOpenChild: onOpenChild,
                            conversationID: conversationID,
                            toolDetailExpansion: toolDetailExpansion?(event)
                        )
                        .transition(isLive ? FloeTheme.stepTransition(reduceMotion: reduceMotion) : .identity)
                        if event.kind == .toolRequest,
                           let pendingCard = pendingApproval(for: event, snapshot: snapshot, pending: pending) {
                            ApprovalCardView(approval: pendingCard) { onResolveApproval(pendingCard, $0) }
                        }
                    }
                }
                .animation(isLive && !reduceMotion ? .easeOut(duration: 0.22) : nil, value: rows.map(\.id))
            }
        }
        .padding(.vertical, 6)
        // Do not expand on every event update: an explicit collapse remains
        // effective throughout a long batch. Urgent rows remain visible above.
        .onChange(of: isLatest) { wasLatest, latest in
            if wasLatest && !latest {
                withAnimation(FloeTheme.motionAnimation(reduceMotion: reduceMotion)) { isExpanded = false }
            }
        }
        .onChange(of: pending.map(\.id), initial: true) { _, ids in
            if !ids.isEmpty {
                withAnimation(FloeTheme.motionAnimation(reduceMotion: reduceMotion)) { isExpanded = true }
            }
        }
    }

    private func approvalSummary(for event: RunEventRecord, snapshot: StepGroupMetadata.Snapshot) -> String? {
        guard let callID = callID(for: event, payloads: snapshot.payloads) else { return nil }
        guard let summary = snapshot.approvals[callID] else { return nil }
        return summary.isEmpty ? FloeL10n.l("chat.step_group_view.auto_approved") : summary
    }

    init(
        events: [RunEventRecord],
        isLatest: Bool,
        isLive: Bool,
        hasError: Bool,
        liveFinishedTools: [String: String] = [:],
        pendingApprovals: [PendingApproval] = [],
        decisions: [ToolDecisionAnnotation] = [],
        childRunRecords: [ChildRunRecord] = [],
        onOpenChild: ((ChildRunRecord?) -> Void)? = nil,
        conversationID: UUID? = nil,
        onOpenGameFiles: ((UUID) -> Void)? = nil,
        toolDetailExpansion: (@MainActor (RunEventRecord) -> Binding<Bool?>)? = nil,
        onResolveApproval: @escaping (PendingApproval, ApprovalDecision) -> Void = { _, _ in }
    ) {
        self.events = events
        self.isLatest = isLatest
        self.isLive = isLive
        self.hasError = hasError
        self.liveFinishedTools = liveFinishedTools
        self.allPendingApprovals = pendingApprovals
        self.decisions = decisions
        self.childRunRecords = childRunRecords
        self.onOpenChild = onOpenChild
        self.onOpenGameFiles = onOpenGameFiles
        self.conversationID = conversationID
        self.toolDetailExpansion = toolDetailExpansion
        self.onResolveApproval = onResolveApproval
        // The active/latest group is the user's only view into current tool
        // progress. Historical groups stay compact, while the latest group
        // and human decisions open at their exact call site.
        self._isExpanded = State(initialValue: StepGroupDisclosurePolicy.initiallyExpanded(
            isLatest: isLatest, isLive: isLive, hasError: hasError,
            hasPendingApproval: false
        ))
    }

    /// The projected decision line for this call, matched by the same callID
    /// vocabulary the approval summaries use, scoped to the run that owns the
    /// call. Works for both the request row (which owns the disclosure) and a
    /// detached result row. Every automatic decision correlated to this exact
    /// call is shown (a later decision is never hidden by an earlier one).
    private func decisionSummary(
        for event: RunEventRecord, payloads: [UUID: [String: String]]
    ) -> String? {
        let summaries = ThreadRunScopedResolution.decisionSummaries(
            callID: callID(for: event, payloads: payloads),
            runID: event.runID, in: decisions)
        return summaries.isEmpty ? nil : summaries.joined(separator: "\n")
    }

    /// The durable delegated-child record for this call, scoped to the run
    /// that rendered the call: raw provider call ids repeat across runs, so an
    /// unscoped callID lookup could open another run's transcript.
    private func childRun(
        for event: RunEventRecord, payloads: [UUID: [String: String]]
    ) -> ChildRunRecord? {
        ThreadRunScopedResolution.child(
            callID: callID(for: event, payloads: payloads),
            parentRunID: event.runID, in: childRunRecords)
    }

    private func pendingApproval(
        for event: RunEventRecord, snapshot: StepGroupMetadata.Snapshot, pending: [PendingApproval]
    ) -> PendingApproval? {
        guard let callID = callID(for: event, payloads: snapshot.payloads) else { return nil }
        return pending.first { $0.toolCall.id == callID }
    }

    private func requestStatus(
        for event: RunEventRecord, snapshot: StepGroupMetadata.Snapshot, pending: [PendingApproval]
    ) -> String? {
        guard event.kind == .toolRequest else { return nil }
        if let result = matchingResult(for: event, snapshot: snapshot) {
            return (snapshot.payloads[result.id] ?? [:])["status"] ?? "completed"
        }
        if let callID = callID(for: event, payloads: snapshot.payloads),
           let status = liveFinishedTools[callID] { return status }
        if pendingApproval(for: event, snapshot: snapshot, pending: pending) != nil { return "pending" }
        return isLive ? "running" : "failed"
    }

    private func isPairedToolResult(_ event: RunEventRecord, snapshot: StepGroupMetadata.Snapshot) -> Bool {
        guard event.kind == .toolResult,
              let resultID = callID(for: event, payloads: snapshot.payloads) else { return false }
        // Only the result presented inside the request card can be hidden.
        // A late retry can reuse a call ID after an earlier export succeeded.
        return snapshot.pairsResult(event.id, with: resultID)
    }

    private func isDetachedApproval(_ event: RunEventRecord, snapshot: StepGroupMetadata.Snapshot) -> Bool {
        guard event.kind == .approval || event.kind == .autoApproved else { return false }
        let payload = (snapshot.payloads[event.id] ?? [:])
        let approvalCallID = payload["callID"] ?? payload["id"] ?? ""
        return snapshot.approvals[approvalCallID] != nil
            && (snapshot.requests.contains(approvalCallID) || snapshot.results[approvalCallID] != nil)
    }
}
/// Decode only the small header fields needed by collapsed groups, once per
/// event-set change; full evidence stays in lazy row views and the receipt
/// payloads are derived once per change, not per body evaluation.
@MainActor
final class StepGroupMetadata: ObservableObject {
    struct Snapshot {
        var payloads: [UUID: [String: String]] = [:]
        var results: [String: RunEventRecord] = [:]
        var requests = Set<String>()
        func pairsResult(_ eventID: UUID, with callID: String) -> Bool {
            requests.contains(callID) && results[callID]?.id == eventID
        }
        var createdGameID: UUID?
        // Empty marks an implicit automatic approval, localized when rendered.
        var approvals: [String: String] = [:]
        /// Events that keep a row visible while the group is collapsed: the
        /// event itself (or its paired request) owns at least one
        /// gate-accepted run-output receipt. Derived once per event-set
        /// change so a long chat with many completed tool batches never
        /// re-decodes receipt payloads on every timeline revision.
        var receiptEventIDs = Set<UUID>()
        /// Events carrying a verified GitHub source reference (same
        /// derivation cadence as `receiptEventIDs`).
        var gitHubSourceEventIDs = Set<UUID>()
    }
    private struct Header: Decodable {
        let values: [String: String]
        enum CodingKeys: String, CodingKey, CaseIterable { case id, callID, status, outcome, reason, tool }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            var values: [String: String] = [:]
            for key in CodingKeys.allCases {
                if let value = try? container.decode(String.self, forKey: key) { values[key.rawValue] = value }
            }
            self.values = values
        }
    }
    /// Retained content of the last derived event set. Persisted rows can be
    /// re-promoted with a refreshed payload for the SAME id (the durable
    /// promoter upserts run_events on conflict(id)), and synthetic streaming
    /// updates may reuse identities, so id+sequence+kind alone cannot prove
    /// the bytes are unchanged. Exact payload equality keeps the projection
    /// correct under those replacements; in the common path the same array
    /// value is re-passed per body evaluation, the payload strings share
    /// storage, and the equality check stays far cheaper than re-decoding.
    private var previousEvents: [RunEventRecord] = []
    private var previousConversationID: UUID?
    private var snapshot = Snapshot()

    func read(_ events: [RunEventRecord], conversationID: UUID? = nil) -> Snapshot {
        // One cheap element pass; unchanged groups skip every payload decode.
        if events.count == previousEvents.count,
           conversationID == previousConversationID,
           events.indices.allSatisfy({ index in
               let previous = previousEvents[index]
               let event = events[index]
               return previous.id == event.id && previous.sequence == event.sequence
                   && previous.kind == event.kind && previous.payloadJSON == event.payloadJSON
           }) {
            return snapshot
        }
        var next = Snapshot()
        for event in events {
            let payload = (try? JSONDecoder().decode(Header.self, from: Data(event.payloadJSON.utf8)))?.values ?? [:]
            if event.kind == .toolResult, payload["tool"] == "game.create", payload["status"] == "ok",
               let receipt = ChatGameProjectLink.receipt(from: event.payloadJSON) {
                next.createdGameID = receipt
            }
            next.payloads[event.id] = payload
            if let call = payload["callID"] ?? payload["id"], !call.isEmpty {
                if event.kind == .toolRequest { next.requests.insert(call) }
                if event.kind == .toolResult { next.results[call] = event }
                if event.kind == .approval || event.kind == .autoApproved {
                    if let summary = payload["outcome"] ?? payload["reason"] {
                        if !summary.isEmpty { next.approvals[call] = summary }
                    } else if event.kind == .autoApproved {
                        next.approvals[call] = ""
                    }
                }
            }
        }
        // Derive collapsed-path urgency once per event-set change. Receipt
        // payloads are only decoded for rows whose header says a result may
        // carry them, and each qualifying row is decoded exactly once.
        for event in events where event.kind == .toolRequest || event.kind == .toolResult {
            let payload = next.payloads[event.id] ?? [:]
            let call = payload["callID"] ?? payload["id"] ?? ""
            let result: RunEventRecord?
            if event.kind == .toolRequest {
                result = call.isEmpty ? nil : next.results[call]
            } else {
                result = event
            }
            guard let result, result.kind == .toolResult, result.runID == event.runID else { continue }
            let values = ConversationCenter.decodePayload(result.payloadJSON)
            if let encoded = values["outputFilesJSON"], encoded.utf8.count <= 196_608,
               let data = encoded.data(using: .utf8),
               let receipts = try? JSONDecoder().decode([RunOutputFile].self, from: data),
               !receipts.isEmpty {
                let context = RunOutputReceiptContext(runID: result.runID, conversationID: conversationID,
                    callID: values["id"], toolName: values["tool"])
                if receipts.contains(where: { RunOutputReceiptGate.accepts($0, in: context) }) {
                    next.receiptEventIDs.insert(event.id)
                }
            }
            if GitHubSourceReference.make(result: result, conversationID: conversationID) != nil {
                next.gitHubSourceEventIDs.insert(event.id)
            }
        }
        previousEvents = events
        previousConversationID = conversationID
        snapshot = next
        return next
    }
}
#endif
