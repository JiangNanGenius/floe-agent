// SPDX-License-Identifier: MPL-2.0

import AppKit
import FloeAgentRuntime
import FloeMacSelfCore
import FloeSecurity
import FloeTools
import SwiftUI

struct MacWorkspaceApprovalView: View {
    @ObservedObject var workspace: HostAgentWorkspace
    let approval: HostAgentApproval
    @State private var grantScope: FloeMacFileGrantScope?
    @State private var scopeOwner: HostAgentApproval?
    @State private var toolGrantScope: MacScopedApprovalScope?
    @State private var toolScopeOwner: HostAgentApproval?

    private var selectedScope: Binding<FloeMacFileGrantScope?> {
        Binding(get: { scopeOwner == approval ? grantScope : nil }, set: { grantScope = $0; scopeOwner = approval })
    }

    private var selectedToolScope: Binding<MacScopedApprovalScope?> {
        Binding(get: { toolScopeOwner == approval ? toolGrantScope : nil },
                set: { toolGrantScope = $0; toolScopeOwner = approval })
    }

    var body: some View {
        var card = ApprovalCardView(
            approval: approval.cardRequest,
            singleUseOnly: true,
            approveTitleOverride: (selectedScope.wrappedValue == nil && selectedToolScope.wrappedValue == nil) ? nil : "action.approve",
            canApprove: approval.canAllow,
            isResolving: workspace.isStopping || workspace.isResolvingApproval || workspace.isTerminating,
            displayedScope: fileScope,
            displayedAction: action,
            evidenceOverride: AnyView(fileEvidence)
        ) { decision in
            switch decision {
            case .allow:
                let scope = selectedScope.wrappedValue
                let toolScope = selectedToolScope.wrappedValue
                Task {
                    await workspace.resolveApproval(approval, allow: true,
                                                    remember: scope,
                                                    rememberScopedTool: toolScope)
                }
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
        if approval.toolName == DelegateTool.name {
            return workspace.workspaces.first { $0.id == approval.workspaceID }?.name
        }
        guard let path = approval.path else { return nil }
        guard let project = workspace.workspaces.first(where: { $0.id == approval.workspaceID }) else { return path }
        return "\(project.name) / \(path)"
    }

    private var action: String {
        if let extensionAction = approval.extensionAction { return extensionAction.title }
        if let review = MacNativeCommandPolicy.review(approval.toolCall) {
            let target = review.host ? MacPermissionsText.t("本机", "This Mac") : MacPermissionsText.t("工作区", "Workspace")
            return review.risk.title + " · " + target
        }
        if approval.toolName == DelegateTool.name { return String(localized: "mac.child.approve") }
        if approval.toolName == WorkspaceOutputPublication.name { return String(localized: "mac.agent.publishOutputApproval") }
        if MacTaskBrowserApproval.applies(to: approval.toolCall) {
            switch approval.toolName {
            case "browser.previewWorkspace": return MacPermissionsText.t("预览工作区网页", "Preview a workspace webpage")
            case "browser.exportFile": return MacPermissionsText.t("保存网页原图", "Save the original webpage image")
            case "browser.clickVisualText", "browser.clickPoint":
                return MacPermissionsText.t("点击网页画布或图形", "Click a canvas or graphic in the webpage")
            default: return MacPermissionsText.t("操作任务内浏览器", "Use the task browser")
            }
        }
        if let action = MacTaskActionPreview(approval.toolCall) { return action.title }
        switch approval.toolName {
        case MacAgentWorkspaceTools.createFileToolName: return String(localized: "mac.agent.createFileApproval")
        case MacAgentWorkspaceTools.replaceTextToolName: return String(localized: "mac.agent.replaceTextApproval")
        case MacAgentWorkspaceTools.writeFileToolName: return String(localized: "mac.agent.writeFileApproval")
        case MacAgentWorkspaceTools.appendFileToolName: return String(localized: "mac.agent.appendFileApproval")
        case MacAgentWorkspaceTools.applyPatchToolName: return String(localized: "mac.agent.applyPatchApproval")
        case MacAgentWorkspaceTools.createDirectoryToolName: return String(localized: "mac.agent.createDirectoryApproval")
        default: break
        }
        if approval.previousText != nil { return String(localized: "mac.agent.replaceTextApproval") }
        if approval.path != nil { return String(localized: "mac.agent.createFileApproval") }
        return String(localized: "mac.agent.approvalRequired")
    }

    @ViewBuilder private var fileEvidence: some View {
        if approval.canAllow, let path = approval.path, MacAgentWorkspaceTools.canRememberFile(path),
           FloeMacSelfApprovalGrants.canRemember(toolName: approval.toolName) {
            Picker("mac.permissions.remember", selection: selectedScope) {
                Text("mac.permissions.once").tag(nil as FloeMacFileGrantScope?)
                Text("mac.permissions.taskFile").tag(Optional(FloeMacFileGrantScope.task))
                if workspace.workspaces.contains(where: { $0.id == approval.workspaceID && $0.kind == .project }) {
                    Text("mac.permissions.projectFile").tag(Optional(FloeMacFileGrantScope.workspace))
                }
            }.pickerStyle(.menu).controlSize(.small)
        }
        if approval.canAllow, workspace.canRememberScopedTool(approval) {
            Picker(MacPermissionsText.t("记住此工具", "Remember this tool"), selection: selectedToolScope) {
                Text(MacPermissionsText.t("仅此一次", "Just once"))
                    .tag(nil as MacScopedApprovalScope?)
                Text(MacPermissionsText.t("在此任务中", "For this task"))
                    .tag(Optional(MacScopedApprovalScope.toolTask))
                if workspace.workspaces.contains(where: { $0.id == approval.workspaceID && $0.kind == .project }) {
                    Text(MacPermissionsText.t("在此项目中", "For this project"))
                        .tag(Optional(MacScopedApprovalScope.toolProject))
                }
                Text(MacPermissionsText.t("本次会话", "For this session"))
                    .tag(Optional(MacScopedApprovalScope.toolSession))
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .accessibilityIdentifier("approval.rememberToolScope")
        }
        if let detail = MacNativeCommandPolicy.preview(approval.toolCall) {
            ScrollView { preview(detail) }.frame(maxHeight: 135)
        } else if approval.extensionAction != nil, let details = approval.text {
            ScrollView { preview(details) }.frame(maxHeight: 135)
        } else if let action = MacTaskActionPreview(approval.toolCall) {
            ScrollView { preview(action.detail) }.frame(maxHeight: 135)
        } else if MacTaskBrowserApproval.applies(to: approval.toolCall), let text = approval.text {
            Text(verbatim: text).font(.callout).lineLimit(2)
        } else if approval.toolName == DelegateTool.name, let task = approval.text {
            Text(verbatim: task).font(.callout).lineLimit(6).textSelection(.enabled)
            DisclosureGroup("mac.child.details") {
                ScrollView { preview(task) }.frame(maxHeight: 135)
            }
        } else if let previous = approval.previousText, let replacement = approval.text {
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
        } else if approval.toolName == MacAgentWorkspaceTools.applyPatchToolName,
                  let patch = approval.text, !patch.isEmpty {
            DisclosureGroup("mac.agent.reviewPatch") {
                ScrollView { preview(patch) }
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
    var marker: String? = nil
    let record: (CGRect) -> Void

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ view: Anchor, context: Context) {
        view.identifier = marker.map { NSUserInterfaceItemIdentifier($0) }
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
