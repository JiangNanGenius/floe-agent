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
        self.pendingApprovals = pendingApprovals
        self.onResolveApproval = onResolveApproval
        // The active/latest group is the user's only view into current tool
        // progress. Historical groups stay compact, while the latest group
        // and human decisions open at their exact call site.
        self._isExpanded = State(initialValue: StepGroupDisclosurePolicy.initiallyExpanded(
            isLatest: isLatest, isLive: isLive, hasError: hasError,
            hasPendingApproval: !pendingApprovals.isEmpty
        ))
    }

    private var summary: String {
        let count = events.count
        let lastTool = events.last(where: { $0.kind == .toolRequest || $0.kind == .toolResult })
        let lastName = lastTool.map {
            let payload = decodePayload($0.payloadJSON)
            return payload["tool"] ?? payload["name"] ?? "工具"
        } ?? "思考"
        let status = lastTool.map { event in
            if event.kind == .toolRequest {
                return requestStatus(for: event) ?? "pending"
            }
            return decodePayload(event.payloadJSON)["status"] ?? ""
        } ?? ""
        return "\(count) 个步骤 · 最后：\(lastName)\(status.isEmpty ? "" : " (\(status))")"
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if isExpanded {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(events) { event in
                        if isDetachedApproval(event) || isPairedToolResult(event) {
                            EmptyView()
                        } else {
                            ThreadEventView(
                                event: event,
                                isLive: isLive,
                                hasError: hasError,
                                onRetry: nil,
                                approvalSummary: approvalSummary(for: event),
                                toolRequestStatus: requestStatus(for: event),
                                toolRequestResultPayloadJSON: matchingResult(for: event)?.payloadJSON
                            )
                            if event.kind == .toolRequest,
                               let pending = pendingApproval(for: event) {
                                ApprovalCardView(approval: pending) { decision in
                                    onResolveApproval(pending, decision)
                                }
                                .padding(.leading, 8)
                            }
                        }
                    }
                }
                .padding(.leading, 8)
            }
        } label: {
            HStack {
                Text(summary)
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy) { isExpanded.toggle() } }
        }
        .padding(.vertical, 2)
        .onChange(of: pendingApprovals.map(\.id)) { _, approvalIDs in
            if !approvalIDs.isEmpty {
                withAnimation(.snappy) { isExpanded = true }
            }
        }
        .onChange(of: events.map(\.id)) { _, _ in
            if isLatest || isLive || hasError {
                withAnimation(.snappy) { isExpanded = true }
            }
        }
    }

    private func decodePayload(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private var approvalSummariesByCallID: [String: String] {
        var result: [String: String] = [:]
        for event in events where event.kind == .approval || event.kind == .autoApproved {
            let payload = decodePayload(event.payloadJSON)
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
        let payload = decodePayload(event.payloadJSON)
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
            return decodePayload(result.payloadJSON)["status"] ?? "completed"
        }
        if pendingApproval(for: event) != nil { return "pending" }
        return isLive ? "running" : "failed"
    }

    private func matchingResult(for event: RunEventRecord) -> RunEventRecord? {
        guard event.kind == .toolRequest, let requestID = callID(for: event) else { return nil }
        return events.last { candidate in
            candidate.kind == .toolResult && callID(for: candidate) == requestID
        }
    }

    private func isPairedToolResult(_ event: RunEventRecord) -> Bool {
        guard event.kind == .toolResult, let resultID = callID(for: event) else { return false }
        return events.contains { candidate in
            candidate.kind == .toolRequest && callID(for: candidate) == resultID
        }
    }

    private func isDetachedApproval(_ event: RunEventRecord) -> Bool {
        guard event.kind == .approval || event.kind == .autoApproved else { return false }
        let payload = decodePayload(event.payloadJSON)
        let approvalCallID = payload["callID"] ?? payload["id"] ?? ""
        let hasMatchingTool = events.contains { callID(for: $0) == approvalCallID }
        return !approvalCallID.isEmpty && hasMatchingTool && approvalSummariesByCallID[approvalCallID] != nil
    }
}
#endif
