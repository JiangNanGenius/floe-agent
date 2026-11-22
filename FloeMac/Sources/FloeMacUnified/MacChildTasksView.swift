// SPDX-License-Identifier: MPL-2.0
import SwiftUI

struct MacChildTasksView: View {
    @ObservedObject var controller: HostChildSubagentController
    let conversationID: UUID
    var isInspector = false
    @State private var expanded = false
    @State private var detail: HostChildSubagentSnapshot?
    #if FLOE_MAC_HOST_SMOKE
    static var smokeDisclosureFrame: CGRect?
    static var smokeDetailFrame: CGRect?
    #endif
    @State private var cancelling = Set<UUID>()
    @State private var failedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if controller.presentedConversationID == conversationID, !controller.presentedChildren.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Button { expanded.toggle() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2)
                            Label { Text("mac.child.title") + Text(verbatim: " (\(controller.presentedChildren.count))") }
                                icon: { Image(systemName: "point.3.connected.trianglepath.dotted") }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("mac.child.disclosure")
                    #if FLOE_MAC_HOST_SMOKE
                    .background(MacWorkbenchButtonFrameReader { Self.smokeDisclosureFrame = $0 })
                    #endif
                    if expanded || isInspector {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(controller.presentedChildren) { child in
                                    row(child)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: isInspector ? .infinity : 145)
                    }
                }
                .font(.callout)
                .padding(.horizontal, 18)
                .padding(.vertical, 4)
            } else if isInspector {
                ContentUnavailableView(MacPermissionsText.t("暂无子代理", "No Subagents"), systemImage: "person.2")
            }
        }
        .sheet(item: $detail) { selected in
            if selected.conversationID == conversationID,
               controller.presentedConversationID == conversationID,
               let current = controller.presentedChildren.first(where: { $0.id == selected.id }) {
                MacChildTaskDetails(child: current)
            }
        }
        .task(id: conversationID) {
            detail = nil
            expanded = false
            failedID = nil
            await controller.present(conversationID: conversationID)
        }
    }

    private func row(_ child: HostChildSubagentSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Button { detail = child } label: {
                    HStack(spacing: 5) {
                        Text(verbatim: child.taskSummary).lineLimit(2)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("mac.child.details")
                .accessibilityIdentifier("mac.child.details." + child.id.uuidString)
                #if FLOE_MAC_HOST_SMOKE
                .background(MacWorkbenchButtonFrameReader { Self.smokeDetailFrame = $0 })
                #endif
                Spacer()
                Text(LocalizedStringKey("mac.child." + child.status.rawValue)).font(.caption)
                Text(child.startedAt, style: .time).font(.caption).foregroundStyle(.secondary)
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
                Text(verbatim: findings).font(.caption).lineLimit(2).textSelection(.enabled)
            }
            // Durable failure/unfinished detail from the child store, shown
            // for reopened rows exactly as persisted (active and completed
            // children read identically after relaunch).
            if let error = child.error, !error.isEmpty {
                Text(verbatim: error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            if failedID == child.id {
                Text("mac.child.cancelFailed").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("mac.child.row." + child.id.uuidString)
    }
}

private struct MacChildTaskDetails: View {
    let child: HostChildSubagentSnapshot
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("mac.child.details").font(.headline)
                Spacer()
                Button("mac.composer.done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("mac.child.details.done")
            }.padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: child.taskSummary).font(.headline)
                    HStack {
                        Text(LocalizedStringKey("mac.child." + child.status.rawValue))
                        Spacer()
                        Text(child.startedAt, style: .time)
                        if let end = child.endedAt {
                            Image(systemName: "arrow.right").accessibilityHidden(true)
                            Text(end, style: .time)
                        }
                    }.foregroundStyle(.secondary)
                    if let result = child.findings, !result.isEmpty {
                        Divider()
                        Text("mac.child.result").font(.headline)
                        Text(verbatim: result)
                    }
                    if let error = child.error, !error.isEmpty {
                        Divider()
                        Text("mac.child.outcomeDetail").font(.headline)
                        Text(verbatim: error)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
        .frame(minWidth: 400, idealWidth: 500, minHeight: 240, idealHeight: 340)
    }
}
