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

    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var payload: [String: String] {
        ConversationCenter.decodePayload(event.payloadJSON)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsHeader {
                header
            }
            content
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Header: kind chip + timestamp + fold control

    /// The assistant answer is the visual subject — it carries no
    /// chrome header. Everything else keeps the metadata header.
    private var showsHeader: Bool {
        event.kind != .assistantText
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
            ToolCallCardView(
                name: payload["tool"] ?? event.kind.rawValue,
                status: "pending",
                inputSummary: payload["input"] ?? payload["summary"]
            )

        case .toolResult:
            let status = payload["status"] ?? "ok"
            ToolCallCardView(
                name: payload["tool"]
                    ?? String(localized: "tool.result"),
                status: status,
                inputSummary: payload["input"],
                resultSummary: payload["summary"],
                duration: payload["durationMs"].flatMap(Double.init)
                    .map { $0 / 1000 }
            )

        case .approval:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(FloeTheme.pending)
                Text(payload["reason"] ?? "")
                    .font(FloeTheme.Typography.body)
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

        case .terminal, .file, .checkpoint:
            foldableBody(
                summary: payload["stopReason"]
                    ?? payload["summary"]
                    ?? event.kind.rawValue,
                evidence: event.payloadJSON
            )
        }
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
        return HStack(spacing: 8) {
            if RunStateLocalizer.isLoading(stateName: state, hasError: hasError) {
                ProgressView()
                    .controlSize(.small)
            }
            Text(RunStateLocalizer.title(for: state))
                .font(FloeTheme.Typography.body)
                .foregroundStyle(RunStateLocalizer.color(for: state))
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
             .toolRequest, .toolResult, .status:
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
        case .error: "xmark.octagon"
        case .usage: "chart.bar"
        case .checkpoint: "bookmark"
        case .status: "info.circle"
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
        case .error: "thread.kind.error"
        case .usage: "thread.kind.usage"
        case .checkpoint: "thread.kind.checkpoint"
        case .status: "thread.kind.status"
        }
    }
}
#endif
