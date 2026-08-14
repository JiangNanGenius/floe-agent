// FloeApp — Approval card for a pending human decision.
//
// SPDX-License-Identifier: MPL-2.0
//
// Shows the exact action, scope, risk rationale and request time before
// the user acts. Amber marks the pending decision; the destructive style
// is reserved for high-risk (side-effecting) actions. Approve/Deny funnel
// through ConversationCenter so the runtime and the persisted thread never
// diverge.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeSecurity

/// An actionable approval prompt bound to one PendingApproval.
struct ApprovalCardView: View {
    let approval: PendingApproval
    let onResolve: (ApprovalDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            detailRows
            if !approval.riskLabels.isEmpty {
                riskLabels
            }
            actionButtons
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FloeTheme.groupedSurface, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(FloeTheme.pending.opacity(0.6), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("approval.required")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(FloeTheme.pending)
                .accessibilityHidden(true)
            Text("approval.required")
                .font(FloeTheme.Typography.section)
            Spacer()
            Text(approval.requestedAt, style: .time)
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Action, scope, rationale

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
                    .foregroundStyle(.secondary)
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
                onResolve(.allow(
                    scope: ApprovalScope(
                        toolName: approval.toolCall.toolName,
                        singleUse: true
                    ),
                    expiresAt: nil
                ))
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

    /// Maps a deterministic catalog risk label to a localized description.
    /// Unknown labels fall back to the raw value (still non-secret).
    static func localizedRiskLabel(_ raw: String) -> LocalizedStringKey {
        switch raw {
        case "readsFiles": "risk.reads_files"
        case "writesFiles": "risk.writes_files"
        case "deletesFiles": "risk.deletes_files"
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
