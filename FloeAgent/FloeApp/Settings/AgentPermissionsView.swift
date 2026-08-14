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
import FloeCore
import FloePersistence

struct AgentPermissionsView: View {
    @ObservedObject var center: SettingsCenter

    var body: some View {
        Form {
            Section {
                Picker("settings.permissions.default_mode", selection: Binding(
                    get: { center.defaultAgentMode },
                    set: { Task { await center.setDefaultAgentMode($0) } }
                )) {
                    Text("settings.general.agent_mode.human").tag(AgentMode.human)
                    Text("settings.general.agent_mode.approval_model").tag(AgentMode.approvalModel)
                    Text("settings.general.agent_mode.full_control").tag(AgentMode.fullControl)
                }
                .frame(minHeight: FloeTheme.minimumTarget)
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
