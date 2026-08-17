// FloeApp — Inline approval card for a pending human decision.
//
// SPDX-License-Identifier: MPL-2.0
//
// Renders inline in the thread (never a full-screen modal): tool name,
// risk-label chips, target (host / normalized path), an argument
// summary, and — for write-class tools — a foldable Diff/evidence
// preview. The user picks one of four grant scopes (§6.1): just once /
// this task / this project / this host. Catastrophic-gate `.stopped`
// decisions render in destructive red and are never weakened by the
// chosen scope. Approve/Deny funnel through ConversationCenter so the
// runtime and the persisted thread never diverge.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeSecurity

/// The four authorization scopes offered on an inline approval card.
/// Mapping to ApprovalScope (§6.1/§10):
/// - once    → singleUse = true
/// - task    → singleUse = false (run-lifetime in-memory grant)
/// - project → singleUse = false + workspace-scoped paths (approval_grants
///   persistence lands with the workspace store; scope value carries the
///   normalized paths today)
/// - host    → host-wide grant (hostID without path constraint)
enum ApprovalScopeChoice: String, CaseIterable, Identifiable, Sendable {
    case once
    case task
    case project
    case host

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .once: "approval.scope.once"
        case .task: "approval.scope.task"
        case .project: "approval.scope.project"
        case .host: "approval.scope.host"
        }
    }
}

/// An actionable, inline approval prompt bound to one PendingApproval.
struct ApprovalCardView: View {
    let approval: PendingApproval
    let onResolve: (ApprovalDecision) -> Void

    @State private var scopeChoice: ApprovalScopeChoice = .once
    @State private var isEvidenceExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            detailRows
            if !approval.riskLabels.isEmpty {
                riskLabels
            }
            if requiresExactEvidence {
                evidenceDisclosure
            }
            scopePicker
            actionButtons
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FloeTheme.groupedSurface, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(borderColor, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("approval.required")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: headerIcon)
                .foregroundStyle(headerColor)
                .accessibilityHidden(true)
            Text("approval.required")
                .font(FloeTheme.Typography.section)
            Spacer()
            Text(approval.requestedAt, style: .time)
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.secondary)
        }
    }

    /// Catastrophic-gate stops render red; ordinary pending is amber.
    private var headerIcon: String {
        isGateStopped ? "hand.raised.fill" : "exclamationmark.shield.fill"
    }

    private var headerColor: Color {
        isGateStopped ? FloeTheme.destructive : FloeTheme.pending
    }

    private var borderColor: Color {
        isGateStopped
            ? FloeTheme.destructive.opacity(0.6)
            : FloeTheme.pending.opacity(0.6)
    }

    // MARK: - Action, target, rationale

    private var detailRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent {
                Text(approval.toolCall.toolName)
                    .font(FloeTheme.Typography.evidence)
                    .textSelection(.enabled)
            } label: {
                Text("approval.action")
            }
            LabeledContent {
                Text(approval.scopeDescription)
                    .font(FloeTheme.Typography.evidence)
                    .textSelection(.enabled)
            } label: {
                Text("approval.scope")
            }
            if !approval.reason.isEmpty {
                Text(approval.reason)
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(isGateStopped ? FloeTheme.destructive : .secondary)
            }
        }
    }

    // MARK: - Risk labels

    private var riskLabels: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(approval.riskLabels.sorted(), id: \.self) { label in
                    Text(Self.localizedRiskLabel(label))
                        .font(FloeTheme.Typography.metadata)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            FloeTheme.pending.opacity(0.16),
                            in: Capsule()
                        )
                        .foregroundStyle(FloeTheme.pending)
                }
            }
        }
        .accessibilityLabel("approval.risks")
    }

    // MARK: - Evidence / Diff preview (write-class tools)

    /// Write-class = side-effecting tool touching files (diff-bearing
    /// per §6). The preview shows the raw argument evidence until the
    /// workspace Diff surface (T05) provides a rendered diff.
    private var isWriteClass: Bool {
        approval.isSideEffecting
            && (approval.riskLabels.contains("writesFiles")
                || approval.riskLabels.contains("deletesFiles"))
    }

    /// Remote command approval must expose the exact executable body as well
    /// as file diffs. A generic tool name is not informed authorization.
    private var requiresExactEvidence: Bool {
        isWriteClass || approval.riskLabels.contains("executesRemoteCommand")
    }

    private var evidenceDisclosure: some View {
        DisclosureGroup(isExpanded: $isEvidenceExpanded) {
            Text(argumentSummary)
                .font(FloeTheme.Typography.evidence)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    FloeTheme.readingSurface,
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .padding(.top, 6)
        } label: {
            Label("approval.evidence", systemImage: "doc.text.magnifyingglass")
                .font(FloeTheme.Typography.metadata.weight(.semibold))
                .foregroundStyle(FloeTheme.primary)
        }
        .animation(FloeTheme.motionAnimation(reduceMotion: reduceMotion), value: isEvidenceExpanded)
    }

    /// One-line-plus argument projection for the evidence fold. The
    /// payload stays non-secret by construction (tool arguments are
    /// size-capped and redacted upstream).
    private var argumentSummary: String {
        guard let object = try? JSONSerialization.jsonObject(
            with: approval.toolCall.argumentsJSON
        ) as? [String: Any] else {
            return String(decoding: approval.toolCall.argumentsJSON, as: UTF8.self)
        }
        return object
            .sorted { $0.key < $1.key }
            .map { key, value in "\(key): \(value)" }
            .joined(separator: "\n")
    }

    // MARK: - Scope picker (four tiers)

    private var scopePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("approval.scope.choose")
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.secondary)
            Picker("approval.scope.choose", selection: $scopeChoice) {
                ForEach(ApprovalScopeChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("approval.scope.choose")
        }
    }

    // MARK: - Approve / Deny

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button(role: .cancel) {
                onResolve(.deny(reason: "user denied"))
            } label: {
                Text("action.deny")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .frame(minHeight: FloeTheme.minimumTarget)
            .accessibilityLabel("action.deny")

            Button {
                onResolve(.allow(scope: approvalScope, expiresAt: nil))
            } label: {
                Text("action.approve")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(approval.isSideEffecting ? FloeTheme.destructive : FloeTheme.primary)
            .frame(minHeight: FloeTheme.minimumTarget)
            .accessibilityLabel("action.approve")
        }
    }

    /// Maps the four-tier choice onto ApprovalScope. The catastrophic
    /// gate is unaffected: a `.stopped` decision still requires the
    /// runtime's second local authentication — the scope only narrows
    /// what the human's "allow" remembers.
    private var approvalScope: ApprovalScope {
        let toolName = approval.toolCall.toolName
        switch approval.toolCall.scope {
        case .local:
            return ApprovalScope(
                toolName: toolName,
                paths: scopeChoice == .project ? [approval.scopeDescription] : [],
                singleUse: scopeChoice == .once
            )
        case .host(let hostID):
            return ApprovalScope(
                toolName: toolName,
                hostID: hostID,
                singleUse: scopeChoice == .once
            )
        case .hostPath(let hostID, let path):
            return ApprovalScope(
                toolName: toolName,
                hostID: hostID,
                // "This host" drops the path constraint; narrower scopes
                // keep the exact normalized path.
                paths: scopeChoice == .host ? [] : [path],
                singleUse: scopeChoice == .once
            )
        }
    }

    /// True when the pending decision carries a catastrophic-gate stop.
    /// The runtime encodes gate stops in the escalation reason.
    private var isGateStopped: Bool {
        approval.reason.lowercased().contains("gate")
            || approval.reason.lowercased().contains("catastrophic")
    }

    /// Maps a deterministic catalog risk label to a localized description.
    /// Unknown labels fall back to the raw value (still non-secret).
    static func localizedRiskLabel(_ raw: String) -> LocalizedStringKey {
        switch raw {
        case "readsFiles": "risk.reads_files"
        case "writesFiles": "risk.writes_files"
        case "deletesFiles": "risk.deletes_files"
        case "executesLocalCode": "运行设备上的 Python 代码"
        case "executesRemoteCommand": "risk.executes_remote_command"
        case "modifiesRemoteSystem": "risk.modifies_remote_system"
        case "networkAccess": "risk.network_access"
        case "sendsDataToProvider": "risk.sends_data_to_provider"
        case "controlsGUI": "risk.controls_gui"
        case "accessesCredentials": "risk.accesses_credentials"
        default: LocalizedStringKey(raw)
        }
    }
}
#endif
