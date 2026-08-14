// FloeApp — One event in the canonical thread.
//
// SPDX-License-Identifier: MPL-2.0
//
// Renders one RunEventRecord by kind with fold/collapse and monospaced
// evidence. Colors come from FloeTheme (amber pending, red destructive,
// green confirmed, brand accent for progress). No hard-coded strings.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeModels

/// Renders a single persisted run event. Long payloads fold behind a
/// disclosure; evidence (raw payload) uses the monospaced typography role.
struct ThreadEventView: View {
    let event: RunEventRecord

    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var payload: [String: String] {
        ConversationCenter.decodePayload(event.payloadJSON)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            content
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Header: kind chip + timestamp + fold control

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
            Text(payload["text"] ?? "")
                .font(FloeTheme.Typography.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)

        case .reasoning:
            if isExpanded {
                Text(payload["text"] ?? "")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(FloeTheme.groupedSurface, in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text(reasoningPreview)
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

        case .toolRequest:
            foldableBody(
                summary: payload["tool"] ?? "",
                evidence: event.payloadJSON
            )

        case .toolResult:
            foldableBody(
                summary: payload["summary"] ?? "",
                evidence: event.payloadJSON,
                tint: (payload["status"] == "ok") ? FloeTheme.success : FloeTheme.destructive
            )

        case .approval:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(FloeTheme.pending)
                Text(payload["reason"] ?? "")
                    .font(FloeTheme.Typography.body)
            }

        case .error:
            Text(payload["message"] ?? event.payloadJSON)
                .font(FloeTheme.Typography.body)
                .foregroundStyle(FloeTheme.destructive)

        case .usage:
            usageBody

        case .terminal, .file, .checkpoint, .status:
            foldableBody(
                summary: payload["state"]
                    ?? payload["stopReason"]
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

    private var reasoningPreview: String {
        (payload["text"] ?? "")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
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
        case .assistantText, .approval, .error, .usage:
            return false
        case .reasoning, .toolRequest, .toolResult, .terminal, .file, .checkpoint, .status:
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
