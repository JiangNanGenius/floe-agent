// SPDX-License-Identifier: MPL-2.0

import FloeMacSelfCore
import SwiftUI

/// Saved approval grants shown in permissions settings, mirroring the iPad
/// grant list: the EXISTING per-file task/project grants, the persisted
/// scoped tool grants (`MacScopedToolGrants`), and the process-lifetime
/// session tool grants (`MacSessionApprovalGrants`). Every row can be
/// revoked; revocation is immediate for future policy decisions. New copy
/// follows the `MacPermissionsText` inline bilingual convention.
struct MacSavedApprovalGrantsView: View {
    @ObservedObject var workspace: HostAgentWorkspace
    @State private var grants: [FloeMacFileGrant] = []
    @State private var toolGrants: [MacScopedToolGrant] = []
    @State private var sessionGrants: [MacSessionToolGrant] = []
    @State private var problem: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let problem {
                Text(problem).foregroundStyle(.red)
                Button("mac.permissions.reload") { Task { await reload() } }
            } else if grants.isEmpty && toolGrants.isEmpty && sessionGrants.isEmpty {
                Text("mac.permissions.noGrants").foregroundStyle(.secondary)
            }
            if !grants.isEmpty {
                grantSection(
                    title: MacPermissionsText.t("文件授权", "File approvals"),
                    footer: MacPermissionsText.t("只适用于选定文件和操作。",
                                                 "Applies only to the selected file and operation.")
                ) {
                    ForEach(grants) { grant in
                        fileGrantRow(grant)
                    }
                }
            }
            if !toolGrants.isEmpty {
                grantSection(
                    title: MacPermissionsText.t("工具授权", "Tool approvals"),
                    footer: MacPermissionsText.t("只适用于选定工具；撤销后按任务的审批模式处理。",
                                                 "Applies only to the selected tool; after revocation the task’s approval mode applies.")
                ) {
                    ForEach(toolGrants) { grant in
                        toolGrantRow(grant)
                    }
                }
            }
            if !sessionGrants.isEmpty {
                grantSection(
                    title: MacPermissionsText.t("本次会话授权", "This session"),
                    footer: MacPermissionsText.t("退出 Floe Agent 后自动失效。",
                                                 "Expires when Floe Agent quits.")
                ) {
                    ForEach(sessionGrants) { grant in
                        sessionGrantRow(grant)
                    }
                }
            }
        }.task(id: workspace.isReady) { if workspace.isReady { await reload() } }
    }

    @ViewBuilder
    private func grantSection<Content: View>(title: String, footer: String,
                                             @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
            Text(footer).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: File grants (existing behavior)

    @ViewBuilder
    private func fileGrantRow(_ grant: FloeMacFileGrant) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: grant.path).lineLimit(2).truncationMode(.middle)
                let project = workspace.workspaces.first { $0.id == grant.workspaceID }?.name
                let owner = grant.conversationID.flatMap { id in workspace.conversations.first { $0.id == id }?.title }
                let scope = grant.conversationID == nil ? String(localized: "mac.permissions.project") : String(localized: "mac.permissions.task")
                let operation = switch grant.toolName {
                case MacAgentWorkspaceTools.createFileToolName:
                    String(localized: "mac.permissions.create")
                case MacAgentWorkspaceTools.createDirectoryToolName:
                    String(localized: "mac.permissions.createFolder")
                default:
                    String(localized: "mac.permissions.edit")
                }
                Text(verbatim: ([operation, scope, project, owner].compactMap { $0 }).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                Text(grant.decidedAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("mac.permissions.revoke", role: .destructive) {
                Task { await revoke(grant) }
            }
            .disabled(busy)
            .accessibilityIdentifier("settings.permissions.revoke." + grant.id.uuidString)
            #if FLOE_MAC_HOST_SMOKE
            .background(MacWorkbenchButtonFrameReader(marker: "settings.permissions.revoke." + grant.id.uuidString) { _ in })
            #endif
        }
    }

    // MARK: Tool grants

    @ViewBuilder
    private func toolGrantRow(_ grant: MacScopedToolGrant) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: grant.toolName).lineLimit(1).truncationMode(.middle)
                let project = workspace.workspaces.first { $0.id == grant.workspaceID }?.name
                let owner = grant.conversationID.flatMap { id in workspace.conversations.first { $0.id == id }?.title }
                let scope = grant.conversationID == nil
                    ? MacPermissionsText.t("项目", "Project")
                    : MacPermissionsText.t("任务", "Task")
                Text(verbatim: ([scope, project, owner].compactMap { $0 }).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                Text(grant.decidedAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("mac.permissions.revoke", role: .destructive) {
                Task { await revokeTool(grant) }
            }.disabled(busy)
        }
    }

    // MARK: Session grants

    @ViewBuilder
    private func sessionGrantRow(_ grant: MacSessionToolGrant) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: grant.toolName).lineLimit(1).truncationMode(.middle)
                let project = workspace.workspaces.first { $0.id == grant.workspaceID }?.name
                let owner = workspace.conversations.first { $0.id == grant.conversationID }?.title
                Text(verbatim: ([MacPermissionsText.t("本次会话", "This session"), project, owner]
                    .compactMap { $0 }).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                Text(grant.decidedAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("mac.permissions.revoke", role: .destructive) {
                Task { await revokeSession(grant) }
            }.disabled(busy)
        }
    }

    // MARK: Loading / revocation

    private func reload() async {
        do {
            let store = try await workspace.approvalGrantStore()
            grants = try await store.list()
            toolGrants = (try? await MacScopedToolGrants.shared.list()) ?? []
            sessionGrants = await MacSessionApprovalGrants.shared.all()
            problem = nil
        } catch { problem = String(localized: "mac.permissions.loadFailed") }
    }

    private func revoke(_ grant: FloeMacFileGrant) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let store = try await workspace.approvalGrantStore()
            try await store.revoke(id: grant.id)
            await reload()
        } catch { problem = String(localized: "mac.permissions.revokeFailed") }
    }

    private func revokeTool(_ grant: MacScopedToolGrant) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await MacScopedToolGrants.shared.revoke(id: grant.id)
            await reload()
        } catch { problem = String(localized: "mac.permissions.revokeFailed") }
    }

    private func revokeSession(_ grant: MacSessionToolGrant) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await MacSessionApprovalGrants.shared.revoke(id: grant.id)
        await reload()
    }
}
