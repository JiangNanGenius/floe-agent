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
    let pendingApprovals: [PendingApproval]
    let onResolveApproval: (PendingApproval, ApprovalDecision) -> Void
    private let payloads: [UUID: [String: String]]
    private let resultByCallID: [String: RunEventRecord]
    private let requestCallIDs: Set<String>
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded: Bool

    init(
        events: [RunEventRecord],
        isLatest: Bool,
        isLive: Bool,
        hasError: Bool,
        pendingApprovals: [PendingApproval] = [],
        onResolveApproval: @escaping (PendingApproval, ApprovalDecision) -> Void = { _, _ in }
    ) {
        self.events = events
        self.isLatest = isLatest
        self.isLive = isLive
        self.hasError = hasError
        var payloads: [UUID: [String: String]] = [:]
        var results: [String: RunEventRecord] = [:]
        var callIDs = Set<String>()
        for event in events {
            let payload = (try? JSONDecoder().decode([String: String].self, from: Data(event.payloadJSON.utf8))) ?? [:]
            payloads[event.id] = payload
            if let id = payload["callID"] ?? payload["id"], !id.isEmpty {
                if event.kind == .toolRequest { callIDs.insert(id) }
                if event.kind == .toolResult { results[id] = event }
            }
        }
        self.payloads = payloads
        self.resultByCallID = results
        self.requestCallIDs = callIDs
        self.pendingApprovals = pendingApprovals.filter { callIDs.contains($0.toolCall.id) }
        self.onResolveApproval = onResolveApproval
        // The active/latest group is the user's only view into current tool
        // progress. Historical groups stay compact, while the latest group
        // and human decisions open at their exact call site.
        self._isExpanded = State(initialValue: StepGroupDisclosurePolicy.initiallyExpanded(
            isLatest: isLatest, isLive: isLive, hasError: hasError,
            hasPendingApproval: !self.pendingApprovals.isEmpty
        ))
    }

    private var displayedEvents: [RunEventRecord] {
        events.filter { !isDetachedApproval($0) && !isPairedToolResult($0) }
    }
    private var toolCount: Int { displayedEvents.filter { $0.kind == .toolRequest || $0.kind == .toolResult }.count }
    private var activeTools: [RunEventRecord] {
        displayedEvents.filter { $0.kind == .toolRequest && matchingResult(for: $0) == nil && isLive }
    }
    private var failedTools: [RunEventRecord] {
        displayedEvents.filter {
            guard $0.kind == .toolRequest || $0.kind == .toolResult else { return $0.kind == .error }
            return ["failed", "error", "denied", "expired", "needsUser"].contains(requestStatus(for: $0) ?? (payloads[$0.id] ?? [:])["status"] ?? "")
        }
    }
    private var summary: String {
        let reasoningCount = displayedEvents.filter { $0.kind == .reasoning }.count
        return [toolCount > 0 ? "\(toolCount) 个工具调用" : nil,
                reasoningCount > 0 ? "\(reasoningCount) 段思考" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
    private var stateTitle: String {
        if !pendingApprovals.isEmpty { return "等待确认" }
        if !failedTools.isEmpty { return "\(failedTools.count) 项需要查看" }
        if !activeTools.isEmpty { return "\(activeTools.count) 项运行中" }
        return isLive ? "执行记录" : "查看执行记录"
    }
    private var stateColor: Color {
        if !pendingApprovals.isEmpty { return FloeTheme.pending }
        if !failedTools.isEmpty { return FloeTheme.destructive }
        return !activeTools.isEmpty ? FloeTheme.primary : .secondary
    }
    private var visibleEvents: [RunEventRecord] {
        if isExpanded { return displayedEvents }
        // A collapsed batch never hides a decision, current activity or error.
        let urgent = Set((activeTools + failedTools).map(\.id))
        return displayedEvents.filter { urgent.contains($0.id) || pendingApproval(for: $0) != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(FloeTheme.motionAnimation(reduceMotion: reduceMotion)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up").foregroundStyle(stateColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(summary.isEmpty ? "执行记录" : summary).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Text(stateTitle).font(.caption).foregroundStyle(stateColor)
                    }
                    Spacer(minLength: 8)
                    Text(isExpanded ? "收起" : "展开").font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0)).foregroundStyle(.secondary)
                }
                .frame(minHeight: FloeTheme.minimumTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("thread.steps.toggle")
            .accessibilityValue(isExpanded ? "已展开" : "已折叠")
            if !visibleEvents.isEmpty {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(visibleEvents) { event in
                        ThreadEventView(
                            event: event, isLive: isLive, hasError: hasError, onRetry: nil,
                            approvalSummary: approvalSummary(for: event),
                            toolRequestStatus: requestStatus(for: event),
                            toolRequestResultPayloadJSON: matchingResult(for: event)?.payloadJSON
                        )
                        .transition(isLive ? FloeTheme.stepTransition(reduceMotion: reduceMotion) : .identity)
                        if event.kind == .toolRequest, let pending = pendingApproval(for: event) {
                            ApprovalCardView(approval: pending) { onResolveApproval(pending, $0) }
                        }
                    }
                }
                .animation(isLive && !reduceMotion ? .easeOut(duration: 0.22) : nil, value: visibleEvents.map(\.id))
            }
        }
        .padding(.vertical, 6)
        // Do not expand on every event update: an explicit collapse remains
        // effective throughout a long batch. Urgent rows remain visible above.
        .onChange(of: pendingApprovals.map(\.id)) { _, ids in
            if !ids.isEmpty {
                withAnimation(FloeTheme.motionAnimation(reduceMotion: reduceMotion)) { isExpanded = true }
            }
        }
    }

    private var approvalSummariesByCallID: [String: String] {
        var result: [String: String] = [:]
        for event in events where event.kind == .approval || event.kind == .autoApproved {
            let payload = (payloads[event.id] ?? [:])
            let callID = payload["callID"] ?? payload["id"] ?? ""
            let summary = payload["outcome"] ?? payload["reason"]
                ?? (event.kind == .autoApproved ? "已自动批准" : "")
            if !callID.isEmpty, !summary.isEmpty {
                result[callID] = summary
            }
        }
        return result
    }

    private func callID(for event: RunEventRecord) -> String? {
        let payload = (payloads[event.id] ?? [:])
        guard event.kind == .toolRequest || event.kind == .toolResult else { return nil }
        let callID = payload["callID"] ?? payload["id"] ?? ""
        return callID.isEmpty ? nil : callID
    }

    private func approvalSummary(for event: RunEventRecord) -> String? {
        guard let callID = callID(for: event) else { return nil }
        return approvalSummariesByCallID[callID]
    }

    private func pendingApproval(for event: RunEventRecord) -> PendingApproval? {
        guard let callID = callID(for: event) else { return nil }
        return pendingApprovals.first { $0.toolCall.id == callID }
    }

    private func requestStatus(for event: RunEventRecord) -> String? {
        guard event.kind == .toolRequest else { return nil }
        if let result = matchingResult(for: event) {
            return (payloads[result.id] ?? [:])["status"] ?? "completed"
        }
        if pendingApproval(for: event) != nil { return "pending" }
        return isLive ? "running" : "failed"
    }

    private func matchingResult(for event: RunEventRecord) -> RunEventRecord? {
        guard event.kind == .toolRequest, let requestID = callID(for: event) else { return nil }
        return resultByCallID[requestID]
    }

    private func isPairedToolResult(_ event: RunEventRecord) -> Bool {
        guard event.kind == .toolResult, let resultID = callID(for: event) else { return false }
        return requestCallIDs.contains(resultID)
    }

    private func isDetachedApproval(_ event: RunEventRecord) -> Bool {
        guard event.kind == .approval || event.kind == .autoApproved else { return false }
        let payload = (payloads[event.id] ?? [:])
        let approvalCallID = payload["callID"] ?? payload["id"] ?? ""
        let hasMatchingTool = events.contains { callID(for: $0) == approvalCallID }
        return !approvalCallID.isEmpty && hasMatchingTool && approvalSummariesByCallID[approvalCallID] != nil
    }
}
#endif
