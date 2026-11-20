// SPDX-License-Identifier: MPL-2.0

import FloeMacSelfCore
import SwiftUI

struct MacSavedApprovalGrantsView: View {
    @ObservedObject var workspace: HostAgentWorkspace
    @State private var grants: [FloeMacFileGrant] = []
    @State private var problem: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let problem {
                Text(problem).foregroundStyle(.red)
                Button("mac.permissions.reload") { Task { await reload() } }
            } else if grants.isEmpty {
                Text("mac.permissions.noGrants").foregroundStyle(.secondary)
            }
            ForEach(grants) { grant in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: grant.path).lineLimit(2).truncationMode(.middle)
                        let project = workspace.workspaces.first { $0.id == grant.workspaceID }?.name
                        let owner = grant.conversationID.flatMap { id in workspace.conversations.first { $0.id == id }?.title }
                        let scope = grant.conversationID == nil ? String(localized: "mac.permissions.project") : String(localized: "mac.permissions.task")
                        let operation = grant.toolName == "workspace.createFile" ? String(localized: "mac.permissions.create") : String(localized: "mac.permissions.edit")
                        Text(verbatim: ([operation, scope, project, owner].compactMap { $0 }).joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("mac.permissions.revoke", role: .destructive) {
                        Task { await revoke(grant) }
                    }.disabled(busy)
                }
            }
        }.task(id: workspace.isReady) { if workspace.isReady { await reload() } }
    }

    private func reload() async {
        do {
            let store = try await workspace.approvalGrantStore()
            grants = try await store.list()
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
}
