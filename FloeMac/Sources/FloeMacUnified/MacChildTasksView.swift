// SPDX-License-Identifier: MPL-2.0
import SwiftUI

struct MacChildTasksView: View {
    @ObservedObject var controller: HostChildSubagentController
    let conversationID: UUID
    @State private var expanded = false
    @State private var cancelling = Set<UUID>()
    @State private var failedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if controller.presentedConversationID == conversationID, !controller.presentedChildren.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(controller.presentedChildren) { child in
                                row(child)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 145)
                } label: {
                    Label {
                        Text("mac.child.title") + Text(verbatim: " (\(controller.presentedChildren.count))")
                    } icon: { Image(systemName: "point.3.connected.trianglepath.dotted") }
                }
                .font(.callout)
                .padding(.horizontal, 18)
                .padding(.vertical, 4)
            }
        }
        .task(id: conversationID) {
            expanded = false
            failedID = nil
            await controller.present(conversationID: conversationID)
        }
    }

    private func row(_ child: HostChildSubagentSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(verbatim: child.taskSummary).font(.callout).lineLimit(2).help(child.taskSummary)
                Spacer()
                Text(LocalizedStringKey("mac.child." + child.status.rawValue)).font(.caption)
                if child.status == .running || child.status == .preparing {
                    Button("mac.child.cancel") {
                        let owner = conversationID
                        cancelling.insert(child.id)
                        Task {
                            let accepted = await controller.cancelChild(runID: child.parentRunID, conversationID: owner, childID: child.id)
                            cancelling.remove(child.id)
                            if !accepted, controller.presentedConversationID == owner { failedID = child.id }
                        }
                    }
                    .disabled(cancelling.contains(child.id))
                    .controlSize(.small)
                }
            }
            if let findings = child.findings, !findings.isEmpty {
                Text(verbatim: findings).font(.caption).textSelection(.enabled)
            }
            if failedID == child.id {
                Text("mac.child.cancelFailed").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("mac.child.row." + child.id.uuidString)
    }
}
