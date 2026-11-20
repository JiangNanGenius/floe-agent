// SPDX-License-Identifier: MPL-2.0

import AppKit
import FloeSecurity
import SwiftUI

struct MacWorkspaceApprovalView: View {
    @ObservedObject var workspace: HostAgentWorkspace
    let approval: HostAgentApproval

    var body: some View {
        var card = ApprovalCardView(
            approval: approval.cardRequest,
            singleUseOnly: true,
            canApprove: approval.canAllow,
            isResolving: workspace.isStopping || workspace.isResolvingApproval || workspace.isTerminating,
            displayedScope: fileScope,
            displayedAction: action,
            evidenceOverride: AnyView(fileEvidence)
        ) { decision in
            switch decision {
            case .allow: Task { await workspace.resolveApproval(approval, allow: true) }
            case .deny: Task { await workspace.resolveApproval(approval, allow: false) }
            default: break
            }
        }
        #if FLOE_MAC_HOST_SMOKE
        card.onActionFrame = { allow, frame in workspace.smokeApprovalFrames[allow] = frame }
        #endif
        return card.id(approval.cardRequest)
    }

    private var fileScope: String? {
        guard let path = approval.path else { return nil }
        guard let project = workspace.workspaces.first(where: { $0.id == approval.workspaceID }) else { return path }
        return "\(project.name) / \(path)"
    }

    private var action: String {
        if approval.previousText != nil { return String(localized: "mac.agent.replaceTextApproval") }
        if approval.path != nil { return String(localized: "mac.agent.createFileApproval") }
        return String(localized: "mac.agent.approvalRequired")
    }

    @ViewBuilder private var fileEvidence: some View {
        if let previous = approval.previousText, let replacement = approval.text {
            DisclosureGroup("mac.agent.reviewReplacement") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("mac.agent.originalText").font(.caption.weight(.semibold))
                        preview(previous)
                        Text("mac.agent.replacementText").font(.caption.weight(.semibold))
                        if replacement.isEmpty {
                            Text("mac.agent.removeText").font(.caption).foregroundStyle(.secondary)
                        } else {
                            preview(replacement)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 135)
            }
        } else if let text = approval.text, !text.isEmpty {
            DisclosureGroup("mac.agent.reviewFileContents") {
                ScrollView { preview(text) }
                    .frame(maxHeight: 120)
            }
        }
    }

    private func preview(_ text: String) -> some View {
        let excerpt = text.prefix(24_000)
        return VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: String(excerpt))
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if excerpt.endIndex != text.endIndex {
                Button("mac.agent.copyFullApprovalText") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
        }
    }
}

#if FLOE_MAC_HOST_SMOKE
struct MacWorkbenchButtonFrameReader: NSViewRepresentable {
    let record: (CGRect) -> Void

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ view: Anchor, context: Context) {
        view.record = record
        view.recordFrame()
    }

    final class Anchor: NSView {
        var record: ((CGRect) -> Void)?

        override func viewDidMoveToWindow() { recordFrame() }

        override func layout() {
            super.layout()
            recordFrame()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func recordFrame() {
            if window != nil, !bounds.isEmpty { record?(convert(bounds, to: nil)) }
        }
    }
}
#endif
