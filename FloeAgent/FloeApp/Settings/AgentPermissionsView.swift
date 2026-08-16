// FloeApp — Agent & permissions settings section.
//
// SPDX-License-Identifier: MPL-2.0
//
// See docs/ARCHITECTURE_SETTINGS.md §5 row 4: default approval mode
// (honest fail-closed note), full-control explanation, saved grant
// management (list + revoke) and the catastrophic-gate status. The gate
// state is shown read-only; nothing here weakens it.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import LocalAuthentication
import FloeCore
import FloePersistence

struct AgentPermissionsView: View {
    @ObservedObject var center: SettingsCenter
    @State private var isConfirmingFullAccess = false
    @State private var authenticationError: String?

    var body: some View {
        Form {
            Section {
                Picker("settings.permissions.default_mode", selection: Binding(
                    get: { center.defaultAgentMode },
                    set: { newValue in
                        if newValue == .fullControl {
                            isConfirmingFullAccess = true
                        } else {
                            Task { await center.setDefaultAgentMode(newValue) }
                        }
                    }
                )) {
                    Text("询问").tag(AgentMode.human)
                    Text("自动审批").tag(AgentMode.approvalModel)
                    Text("完全放开").tag(AgentMode.fullControl)
                }
                .frame(minHeight: FloeTheme.minimumTarget)
                .pickerStyle(.segmented)
            } header: {
                Text("settings.section.permissions")
            } footer: {
                Text("settings.general.agent_mode.footer")
            }

            Section {
                Label("settings.permissions.full_control.info", systemImage: "info.circle")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
            } header: {
                Text("settings.permissions.full_control")
            }

            if let authenticationError {
                Section { Text(authenticationError).foregroundStyle(FloeTheme.destructive) }
            }

            Section {
                if center.gateIsFailClosed {
                    Label("settings.permissions.gate.fail_closed", systemImage: "shield.slash")
                        .foregroundStyle(FloeTheme.destructive)
                } else {
                    Label("settings.permissions.gate.armed", systemImage: "shield.checkered")
                        .foregroundStyle(FloeTheme.success)
                }
            } header: {
                Text("settings.permissions.gate")
            } footer: {
                Text("settings.permissions.gate.footer")
            }

            Section {
                if center.savedGrants.isEmpty && center.memoryGrants.isEmpty {
                    Text("settings.permissions.grants.empty")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(center.savedGrants) { grant in
                        grantRow(
                            title: grant.toolName,
                            scope: describe(workspaceID: grant.workspaceID, hostID: grant.hostID, paths: grant.paths),
                            detail: grant.policyName,
                            date: grant.decidedAt,
                            id: grant.id
                        )
                    }
                    ForEach(center.memoryGrants) { grant in
                        grantRow(
                            title: grant.scope.toolName,
                            scope: describe(hostID: grant.scope.hostID, paths: grant.scope.paths),
                            detail: String(localized: "settings.permissions.grants.session"),
                            date: grant.decidedAt,
                            id: grant.id
                        )
                    }
                }
            } header: {
                Text("settings.permissions.grants")
            } footer: {
                Text("settings.permissions.grants.footer")
            }
        }
        .navigationTitle("settings.section.permissions")
        .task { await center.load() }
        .alert("确认将完全放开设为默认？", isPresented: $isConfirmingFullAccess) {
            Button("取消", role: .cancel) {}
            Button("继续并验证身份", role: .destructive) {
                Task { await authenticateFullAccess() }
            }
        } message: {
            Text("该设置只影响以后新建的任务。普通操作可自动执行；删除、凭据和上传仍会询问，灾难性命令始终阻止。")
        }
    }

    private func authenticateFullAccess() async {
        let context = LAContext()
        do {
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
                authenticationError = "设备未设置可用的身份验证。"
                return
            }
            guard try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "确认新任务默认使用完全放开权限"
            ) else { return }
            await center.setDefaultAgentMode(.fullControl)
            authenticationError = nil
        } catch {
            authenticationError = error.localizedDescription
        }
    }

    private func grantRow(
        title: String,
        scope: String,
        detail: String,
        date: Date,
        id: UUID
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(FloeTheme.Typography.body)
                Text(scope)
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(detail)
                    Text("·")
                    Text(date, style: .relative)
                }
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                Task { await center.revokeGrant(id: id) }
            } label: {
                Text("settings.permissions.grants.revoke")
            }
            .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
        }
        .frame(minHeight: FloeTheme.minimumTarget)
    }

    private func describe(workspaceID: UUID? = nil, hostID: UUID?, paths: [String]) -> String {
        var parts: [String] = []
        if let workspaceID {
            parts.append(String(localized: "settings.permissions.scope.project") + " " + workspaceID.uuidString.prefix(8))
        }
        if let hostID {
            parts.append(String(localized: "settings.permissions.scope.host") + " " + hostID.uuidString.prefix(8))
        }
        if !paths.isEmpty {
            parts.append(paths.joined(separator: ", "))
        }
        return parts.isEmpty ? String(localized: "settings.permissions.scope.global") : parts.joined(separator: " · ")
    }
}
#endif
