// FloeApp — Tool call card.
//
// SPDX-License-Identifier: MPL-2.0
//
// One card per tool invocation: name, semantic status chip, optional
// duration, foldable input/result summaries (monospaced evidence
// typography). Status colors come exclusively from FloeTheme semantic
// tokens — pending amber, success green, failure red.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// Presentation model for one tool call card. `status` accepts the
/// producer's raw vocabulary (`ok` / `failed` / `pending`) plus the
/// run-state name when available; colors resolve through RunStateLocalizer.
struct ToolCallCardView: View {
    /// Tool name (e.g. "workspace.readFile").
    let name: String
    /// Raw status: "pending", "ok", "failed" (payload vocabulary).
    var status: String = "pending"
    /// One-line summary of the arguments (input).
    var inputSummary: String? = nil
    /// One-line summary of the result (output).
    var resultSummary: String? = nil
    /// Wall-clock duration when known.
    var duration: TimeInterval? = nil

    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isExpanded {
                detail
            }
        }
        .padding(10)
        .background(FloeTheme.groupedSurface, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Header: icon + name + status chip + duration + fold

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)
            Text(name)
                .font(FloeTheme.Typography.metadata.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(statusTitle)
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(statusColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(statusColor.opacity(0.12), in: Capsule())
            if let duration {
                Text(durationText(duration))
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if hasDetail {
                Button {
                    withAnimation(FloeTheme.motionAnimation(reduceMotion: reduceMotion)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(
                    minWidth: FloeTheme.minimumTarget,
                    minHeight: FloeTheme.minimumTarget
                )
                .accessibilityLabel(
                    isExpanded
                        ? LocalizedStringKey("thread.collapse")
                        : LocalizedStringKey("thread.expand")
                )
            }
        }
    }

    // MARK: - Folded-out detail

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let inputSummary, !inputSummary.isEmpty {
                labeledEvidence(title: "tool.input", text: inputSummary)
            }
            if let resultSummary, !resultSummary.isEmpty {
                labeledEvidence(title: "tool.result", text: resultSummary)
            }
        }
    }

    private func labeledEvidence(title: LocalizedStringKey, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(FloeTheme.Typography.evidence)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Status mapping

    private var hasDetail: Bool {
        (inputSummary?.isEmpty == false) || (resultSummary?.isEmpty == false)
    }

    private var statusIcon: String {
        switch status {
        case "ok", "completed": "checkmark.circle"
        case "failed", "error": "xmark.octagon"
        default: "wrench.and.screwdriver"
        }
    }

    private var statusColor: Color {
        switch status {
        case "ok", "completed": FloeTheme.success
        case "failed", "error": FloeTheme.destructive
        case "running", "executingTool": FloeTheme.primary
        default: FloeTheme.pending
        }
    }

    private var statusTitle: LocalizedStringKey {
        switch status {
        case "ok", "completed": "tool.status.succeeded"
        case "failed", "error": "tool.status.failed"
        case "running", "executingTool": "tool.status.running"
        default: "tool.status.pending"
        }
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        if seconds < 1 {
            return String(
                format: String(localized: "tool.duration.ms"),
                Int((seconds * 1000).rounded())
            )
        }
        return String(format: String(localized: "tool.duration.s"), seconds)
    }
}
#endif
