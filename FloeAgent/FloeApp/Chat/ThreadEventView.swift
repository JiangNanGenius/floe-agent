// FloeApp — One event in the canonical thread.
//
// SPDX-License-Identifier: MPL-2.0
//
// Dispatches a RunEventRecord to the typed component per kind (T02):
// assistantText → AssistantMessageView (real Markdown rendering, no raw
// `###` text), reasoning → ReasoningBlockView, toolRequest/toolResult →
// ToolCallCardView, error → ErrorEventView. Approval/usage/terminal/
// file/checkpoint/status keep their honest foldable rendering. State
// copy and colors resolve exclusively through RunStateLocalizer (§6.2).

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeModels
import FloePersistence
import FloeAgentRuntime

import FloeCore
/// Renders a single persisted run event by kind.
struct ThreadEventView: View {
    let event: RunEventRecord
    /// True while the owning run is non-terminal (assistant text streams
    /// incrementally; errors are suppressed in favor of the live tail).
    var isLive: Bool = false
    /// True once any error event exists in this run — pins the loading
    /// state to "ended" per §6.2 (views never re-interpret this).
    var hasError: Bool = false
    /// Retry entry point forwarded to ErrorEventView.
    var onRetry: (() -> Void)? = nil
    /// Approval result/reason associated with this tool call ID.
    var approvalSummary: String? = nil
    /// Derived by the owning step group from the live run and matching
    /// approval. Request rows cannot infer this from their persisted event.
    var toolRequestStatus: String? = nil
    /// Final payload for the same call ID. This lets one expandable invocation
    /// own its arguments, approval, output, artifacts, and duration.
    var toolRequestResultPayloadJSON: String? = nil
    /// True while this call is the one a human approval card is waiting on.
    var toolRequestIsWaiting: Bool = false
    /// Concise decision record projected onto this call (see
    /// `ToolDecisionAnnotation`).
    var decisionSummary: String? = nil
    /// The durable delegated-child record for this call, when the parent
    /// relation maps the delegate call id to a child run.
    var childRun: ChildRunRecord? = nil
    /// Opens the durable child detail/inspector; supplied only by a host that
    /// owns the navigation (the delegate card's "View" action). The optional
    /// record is the specific child when known, nil for the inspector list.
    var onOpenChild: ((ChildRunRecord?) -> Void)? = nil

    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var payload: [String: String] {
        ConversationCenter.decodePayload(event.payloadJSON)
    }

    private var toolRequestResultPayload: [String: String] {
        guard let toolRequestResultPayloadJSON else { return [:] }
        return ConversationCenter.decodePayload(toolRequestResultPayloadJSON)
    }

    /// True for the main-run delegation tool. The child identity itself is
    /// durable (persisted by the lifecycle owner); this row only renders the
    /// honest status derived from the persisted call/result.
    private var isDelegateCall: Bool {
        (payload["tool"] ?? "") == DelegateTool.name
    }

    /// Decoded delegate arguments (persisted `input` is the redacted JSON
    /// prefix of the call). Never trusted for anything but display.
    private var delegateArguments: [String: Any] {
        guard let input = payload["input"], let data = input.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    /// The subtask title the card leads with: the real `task` argument when
    /// present, else the redacted input itself, else the tool name.
    private var delegateTaskTitle: String {
        if let task = delegateArguments["task"] as? String {
            let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return String(trimmed.prefix(500)) }
        }
        let raw = (payload["input"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? (payload["tool"] ?? "delegate") : String(raw.prefix(500))
    }

    private var delegateKindHint: String? {
        guard let type = delegateArguments["type"] as? String, !type.isEmpty else { return nil }
        return type
    }

    var body: some View {
        if isDelegateCall {
            // A delegate row must NOT be combined into one accessibility
            // element: the card owns a real "View subagents" button, and
            // combining made the row container inherit that button's
            // identifier and swallow its hit target (taps never reached the
            // action). Delegate rows keep their children as separate
            // elements; every other row keeps the historical combine.
            rowBody
        } else {
            rowBody
                .accessibilityElement(children: .combine)
        }
    }

    private var rowBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsHeader {
                header
            }
            content
        }
        .padding(.vertical, 4)
    }

    // MARK: - Header: kind chip + timestamp + fold control

    /// The assistant answer is the visual subject — it carries no
    /// chrome header. Everything else keeps the metadata header.
    private var showsHeader: Bool {
        ![.assistantText, .reasoning, .toolRequest, .toolResult].contains(event.kind)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: kindIcon)
                .foregroundStyle(kindColor)
                .accessibilityHidden(true)
            Text(kindTitle)
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.secondary)
            Spacer()
            Text(event.createdAt, style: .time)
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.secondary)
            if isFoldable {
                Button {
                    withAnimation(FloeTheme.motionAnimation(reduceMotion: reduceMotion)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded
                    ? LocalizedStringKey("thread.collapse")
                    : LocalizedStringKey("thread.expand"))
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
            }
        }
    }

    // MARK: - Content by kind

    @ViewBuilder
    private var content: some View {
        switch event.kind {
        case .assistantText:
            AssistantMessageView(
                text: payload["text"] ?? "",
                isStreaming: isLive
            )

        case .reasoning:
            ReasoningBlockView(text: payload["text"] ?? "", isStreaming: false)

        case .toolRequest:
            if isDelegateCall {
                DelegateChildCallCard(
                    title: delegateTaskTitle,
                    kindHint: delegateKindHint,
                    startedAt: childRun?.startedAt ?? event.createdAt,
                    isWaiting: toolRequestIsWaiting,
                    isLive: isLive,
                    childRun: childRun,
                    resultSummary: toolRequestResultPayload["summary"],
                    resultFailed: ["failed", "error"].contains(toolRequestResultPayload["status"] ?? ""),
                    onOpen: onOpenChild
                )
            } else {
                ToolCallCardView(
                    name: payload["tool"] ?? event.kind.rawValue,
                    status: toolRequestStatus ?? payload["status"] ?? "pending",
                    inputSummary: payload["input"] ?? payload["summary"],
                    resultSummary: toolRequestResultPayload["summary"],
                    approvalSummary: approvalSummary,
                    decisionSummary: decisionSummary,
                    duration: duration(from: toolRequestResultPayload),
                    artifacts: artifacts(from: toolRequestResultPayload)
                )
            }

        case .toolResult:
            let status = payload["status"] ?? "ok"
            if isDelegateCall {
                DelegateChildCallCard(
                    title: delegateTaskTitle,
                    kindHint: delegateKindHint,
                    startedAt: childRun?.startedAt ?? event.createdAt,
                    isWaiting: false,
                    isLive: false,
                    childRun: childRun,
                    resultSummary: payload["summary"],
                    resultFailed: ["failed", "error"].contains(status),
                    onOpen: onOpenChild
                )
            } else {
                ToolCallCardView(
                    name: payload["tool"]
                        ?? String(localized: "tool.result"),
                    status: status,
                    inputSummary: payload["input"],
                    resultSummary: payload["summary"],
                    approvalSummary: approvalSummary,
                    decisionSummary: decisionSummary,
                    duration: duration(from: payload),
                    artifacts: artifacts(from: payload)
                )
            }

        case .approval:
            if let outcome = payload["outcome"] {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield")
                        .foregroundStyle(FloeTheme.success)
                    Text(outcome)
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.shield")
                        .foregroundStyle(FloeTheme.pending)
                    Text(payload["reason"] ?? "")
                        .font(FloeTheme.Typography.body)
                }
            }

        case .error:
            ErrorEventView(
                message: payload["message"] ?? event.payloadJSON,
                onRetry: onRetry
            )

        case .usage:
            usageBody

        case .status:
            statusBody

        case .notice:
            NoticeEventView(machineMessage: payload["message"] ?? "", payload: payload)

        case .terminal, .file, .checkpoint:
            foldableBody(
                summary: payload["stopReason"]
                    ?? payload["summary"]
                    ?? event.kind.rawValue,
                evidence: event.payloadJSON
            )

        case .autoApproved:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield")
                    .foregroundStyle(FloeTheme.success)
                Text(FloeL10n.l("chat.thread_event_view.auto_approved", payload["tool"] ?? ""))
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func duration(from payload: [String: String]) -> TimeInterval? {
        payload["durationMs"].flatMap(Double.init).map { $0 / 1_000 }
    }

    private func artifacts(from payload: [String: String]) -> [ToolArtifactReference] {
        guard let encoded = payload["artifactRefsJSON"],
              let data = encoded.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode(
            [ToolArtifactReference].self,
            from: data
        )) ?? []
    }

    private var usageBody: some View {
        HStack(spacing: 12) {
            Label(payload["input"] ?? "0", systemImage: "arrow.up")
            Label(payload["output"] ?? "0", systemImage: "arrow.down")
            if let cost = payload["cost"], !cost.isEmpty {
                Text(cost)
            }
        }
        .font(FloeTheme.Typography.metadata)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    /// State transitions resolve through RunStateLocalizer — the view
    /// never interprets machine names itself (§6.2).
    private var statusBody: some View {
        let state = payload["state"] ?? ""
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if RunStateLocalizer.isLoading(stateName: state, hasError: hasError) {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(RunStateLocalizer.title(for: state))
                    .font(FloeTheme.Typography.body)
                    .foregroundStyle(RunStateLocalizer.color(for: state))
            }
            if let reason = payload["reason"], !reason.isEmpty {
                Text(reason)
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A one-line summary that unfolds to monospaced evidence.
    private func foldableBody(
        summary: String,
        evidence: String,
        tint: Color = .secondary
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(summary)
                .font(FloeTheme.Typography.body)
                .foregroundStyle(tint)
                .lineLimit(isExpanded ? nil : 2)
            if isExpanded {
                Text(evidence)
                    .font(FloeTheme.Typography.evidence)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(FloeTheme.groupedSurface, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Kind mapping

    private var isFoldable: Bool {
        switch event.kind {
        case .assistantText, .approval, .error, .usage, .reasoning,
             .toolRequest, .toolResult, .status, .autoApproved, .notice:
            // These kinds carry their own folding affordance
            // (DisclosureGroup / card chevron); no outer fold.
            return false
        case .terminal, .file, .checkpoint:
            return true
        }
    }

    private var kindIcon: String {
        switch event.kind {
        case .assistantText: "text.bubble"
        case .reasoning: "brain"
        case .toolRequest: "wrench.and.screwdriver"
        case .toolResult: "checkmark.circle"
        case .terminal: "terminal"
        case .file: "doc"
        case .approval: "exclamationmark.shield"
        case .autoApproved: "checkmark.shield"
        case .error: "xmark.octagon"
        case .usage: "chart.bar"
        case .checkpoint: "bookmark"
        case .status: "info.circle"
        case .notice: "exclamationmark.triangle"
        }
    }

    private var kindColor: Color {
        switch event.kind {
        case .approval: FloeTheme.pending
        case .error: FloeTheme.destructive
        case .toolResult:
            (payload["status"] == "ok") ? FloeTheme.success : FloeTheme.destructive
        case .assistantText: FloeTheme.primary
        default: .secondary
        }
    }

    private var kindTitle: LocalizedStringKey {
        switch event.kind {
        case .assistantText: "thread.kind.assistant"
        case .reasoning: "thread.kind.reasoning"
        case .toolRequest: "thread.kind.tool_request"
        case .toolResult: "thread.kind.tool_result"
        case .terminal: "thread.kind.terminal"
        case .file: "thread.kind.file"
        case .approval: "thread.kind.approval"
        case .autoApproved: "thread.kind.auto_approved"
        case .error: "thread.kind.error"
        case .usage: "thread.kind.usage"
        case .checkpoint: "thread.kind.checkpoint"
        case .status: "thread.kind.status"
        case .notice: "thread.kind.notice"
        }
    }
}

/// Compact card for one `delegate` tool call: the real subtask title, start
/// time, honest status (working / waiting for approval / done / failed /
/// cancelled) derived only from the persisted call+result, and a "View"
/// action into the durable child-agents inspector. No percentage and no raw
/// internal reasoning is ever shown; the child transcript itself lives in the
/// inspector.
struct DelegateChildCallCard: View {
    let title: String
    let kindHint: String?
    let startedAt: Date
    let isWaiting: Bool
    let isLive: Bool
    /// The durable delegated-child record (lifecycle owner's store). When
    /// present it is the authority for the card's state; the persisted tool
    /// result is the fallback for older rows without a child record.
    let childRun: ChildRunRecord?
    let resultSummary: String?
    let resultFailed: Bool
    let onOpen: ((ChildRunRecord?) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: status.systemImage)
                    .font(.body.weight(.medium))
                    .foregroundStyle(status.color)
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 8) {
                        Text(status.title)
                            .foregroundStyle(status.color)
                        Text(startedAt, style: .time)
                            .foregroundStyle(.secondary)
                        if let kindHint = Self.userFacingKind(kindHint) {
                            Text(kindHint)
                                .foregroundStyle(.secondary)
                        }
                        if let childRun, childRun.iterationCount > 0 {
                            // Labeled rounds, never a bare digit on the card.
                            Text("\(FloeL10n.l("workbench.task_inspector_views.iterations")) \(childRun.iterationCount)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .font(.caption)
                }
                Spacer(minLength: 4)
            }
            if let resultSummary = Self.userFacingSummary(resultSummary), !resultSummary.isEmpty {
                BoundedDelegateSummary(text: resultSummary)
            }
            if let onOpen {
                Button {
                    onOpen(childRun)
                } label: {
                    Label(openTitle, systemImage: "person.2")
                }
                .font(FloeTheme.Typography.metadata)
                .frame(minHeight: FloeTheme.minimumTarget, alignment: .leading)
                .accessibilityIdentifier("thread.delegate.viewChild.action")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FloeTheme.stepSurface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(
            FloeTheme.separator.opacity(0.45), lineWidth: 0.5))
        // No container-level accessibility element or named action: either one
        // turned the whole card into a synthetic button that absorbed the
        // inner View action's identifier and hit target, so tapping "View
        // subagents" never opened the child. The inner button below is the
        // single actionable element and the only owner of its identifier.
    }

    private var displayTitle: String {
        if let summary = childRun?.taskSummary.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return summary
        }
        return title
    }

    private var openTitle: String {
        ChatBilingualCatalog.localized(
            key: "chat.delegate_card.view_child_agents", en: "View subagents", zh: "查看子代理")
    }

    /// Human words for the delegate kind; raw enum tokens never reach the
    /// card (the inspector keeps the exact record).
    static func userFacingKind(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        switch raw.lowercased() {
        case "explore":
            return ChatBilingualCatalog.localized(
                key: "chat.delegate_card.kind.explore", en: "Local check", zh: "本地检查")
        case "research":
            return ChatBilingualCatalog.localized(
                key: "chat.delegate_card.kind.research", en: "Research", zh: "调研")
        case "execute":
            return ChatBilingualCatalog.localized(
                key: "chat.delegate_card.kind.execute", en: "Execution", zh: "执行")
        default:
            return raw.count <= 24 ? raw : nil
        }
    }

    /// The persisted delegate result is a machine summary
    /// (`status=ok iterationsUsed=3 findings=…`). The card shows the human
    /// part only (the findings text, without its machine key); the raw bytes
    /// stay in the transcript and the inspector, so no evidence is lost.
    static func userFacingSummary(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        var pieces: [String] = []
        for token in raw.split(separator: " ", omittingEmptySubsequences: true) {
            let value = String(token)
            if value.hasPrefix("findings=") {
                let text = String(value.dropFirst("findings=".count))
                if !text.isEmpty { pieces.append(text) }
                continue
            }
            if ["status=", "iterationsUsed=", "budget=", "digest=", "callID="]
                .contains(where: { value.hasPrefix($0) }) {
                continue
            }
            pieces.append(value)
        }
        let text = pieces.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private var status: DelegateCallStatus {
        if let childRun {
            return DelegateCallStatus(childState: childRun.state, isWaiting: isWaiting)
        }
        if let resultSummary {
            return DelegateCallStatus(summary: resultSummary, failed: resultFailed)
        }
        if isWaiting { return .waiting }
        return isLive ? .working : .cancelled
    }
}

/// Honest lifecycle mapping for a delegate card. The durable child state is
/// preferred when the record exists; otherwise the `status=` token written by
/// `DelegateTool.render` (`ok`, `partial`, `budgetExhausted`, `cancelled`,
/// `providerError`, `toolError`) is used, falling back to the persisted tool
/// result status.
enum DelegateCallStatus: Equatable {
    case working
    case waiting
    case done
    case failed
    case cancelled

    init(childState: ChildRunState, isWaiting: Bool) {
        switch childState {
        case .registered: self = isWaiting ? .waiting : .working
        case .running: self = .working
        case .completed: self = .done
        case .partial, .budgetExhausted, .providerError, .toolError, .interrupted:
            self = .failed
        case .cancelled: self = .cancelled
        }
    }

    init(summary: String, failed: Bool) {
        if let token = Self.statusToken(in: summary) {
            switch token {
            case "ok": self = .done
            case "cancelled", "canceled": self = .cancelled
            case "partial", "budgetexhausted", "budget_exhausted": self = .failed
            default: self = .failed
            }
            return
        }
        self = failed ? .failed : .done
    }

    static func statusToken(in summary: String) -> String? {
        for token in summary.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            if token.hasPrefix("status=") {
                return String(token.dropFirst("status=".count)).lowercased()
            }
        }
        return nil
    }

    var title: String {
        switch self {
        case .working:
            ChatBilingualCatalog.localized(
                key: "chat.delegate_card.working", en: "Working", zh: "进行中")
        case .waiting:
            ChatBilingualCatalog.localized(
                key: "chat.delegate_card.waiting", en: "Waiting", zh: "等待中")
        case .done:
            ChatBilingualCatalog.localized(
                key: "chat.delegate_card.done", en: "Done", zh: "已完成")
        case .failed:
            ChatBilingualCatalog.localized(
                key: "chat.delegate_card.failed", en: "Failed", zh: "失败")
        case .cancelled:
            ChatBilingualCatalog.localized(
                key: "chat.delegate_card.cancelled", en: "Cancelled", zh: "已取消")
        }
    }

    var systemImage: String {
        switch self {
        case .working: "person.crop.circle.badge.clock"
        case .waiting: "hourglass"
        case .done: "checkmark.circle"
        case .failed: "xmark.octagon"
        case .cancelled: "stop.circle"
        }
    }

    var color: Color {
        switch self {
        case .working: FloeTheme.primary
        case .waiting: FloeTheme.pending
        case .done: FloeTheme.success
        case .failed, .cancelled: FloeTheme.destructive
        }
    }
}

/// Bounded child-result preview: the full transcript is in the inspector, so
/// the card only shows a readable prefix and never claims to be complete.
private struct BoundedDelegateSummary: View {
    let text: String

    var body: some View {
        let limit = 1_200
        let end = text.index(text.startIndex, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
        Text(String(text[..<end]))
            .font(FloeTheme.Typography.evidence)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Non-fatal notice card. Uses the pending/warning accent, never the
/// destructive error color, so a successful run that was locally truncated
/// does not read as a failure. Known machine messages resolve through the
/// bilingual catalog; unknown ones fall back to the raw payload.
private struct NoticeEventView: View {
    let machineMessage: String
    let payload: [String: String]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(FloeTheme.pending)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(titleKey)
                    .font(FloeTheme.Typography.metadata.weight(.semibold))
                    .foregroundStyle(FloeTheme.pending)
                Text(message)
                    .font(FloeTheme.Typography.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            FloeTheme.pending.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .accessibilityElement(children: .combine)
    }

    private var titleKey: LocalizedStringKey {
        switch machineMessage {
        case "outputTruncated": "chat.notice.output_truncated.title"
        default: "thread.kind.notice"
        }
    }

    private var message: String {
        switch machineMessage {
        case "outputTruncated":
            let received = Int(payload["receivedBytes"] ?? "") ?? 0
            let limit = Int(payload["limitBytes"] ?? "") ?? 0
            return FloeL10n.l(
                "chat.notice.output_truncated.message",
                received,
                limit
            )
        default:
            return payload["message"] ?? payload["summary"] ?? ""
        }
    }
}
#endif
