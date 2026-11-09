// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeElectronicsCore

struct EDBackAnnotationSheet: View {
    @Bindable var session: EDWorkbenchSession
    @Environment(\.dismiss) private var dismiss
    @State private var boardID: UUID
    @State private var options = EDABackAnnotationOptions()
    @State private var plan: EDABackAnnotationPlan?
    @State private var loading = true
    @State private var applying = false
    @State private var message: String?
    private struct PreviewKey: Hashable {
        let revision: UInt64
        let boardID: UUID
        let options: EDABackAnnotationOptions
    }
    init(session: EDWorkbenchSession, boardID: UUID) {
        self.session = session; _boardID = State(initialValue: boardID)
    }
    var body: some View {
        NavigationStack {
            Form {
                choices
                if loading { ProgressView(edText("正在比较…", "Comparing…")) }
                if let message { Text(message).foregroundStyle(.red) }
                if let preview = plan?.preview { changes(preview); issues(preview) }
            }
            .navigationTitle(edText("从 PCB 更新原理图", "Update schematic from PCB"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(edText("取消", "Cancel")) { dismiss() }.disabled(applying)
                        .accessibilityIdentifier("electronics.backAnnotation.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(edText("更新", "Update")) { apply() }
                        .disabled(loading || applying || session.busy || session.isClosed || session.isRouting || session.isFilling
                                  || plan?.preview.canApply != true || plan?.preview.changes.isEmpty != false)
                        .accessibilityIdentifier("electronics.backAnnotation.apply")
                }
            }
            .task(id: PreviewKey(revision: session.revision, boardID: boardID, options: options)) { await refresh() }
        }
        .presentationDetents([.large])
        .accessibilityIdentifier("electronics.backAnnotation.preview")
    }
    private var choices: some View {
        Section {
            if session.project.boards.count > 1 {
                Picker("PCB", selection: $boardID) {
                    ForEach(session.project.boards) { Text($0.name).tag($0.id) }
                }
            }
            Toggle(edText("位号", "References"), isOn: $options.references)
            Toggle(edText("元件值", "Values"), isOn: $options.values)
            Toggle(edText("封装分配", "Footprint assignments"), isOn: $options.footprintAssignments)
        } header: { Text(edText("从 PCB 同步", "Sync from PCB")) }
        footer: { Text(edText("先查看更改，再更新原理图。", "Review the changes before updating the schematic.")) }
        .disabled(applying)
    }
    private func changes(_ preview: EDABackAnnotationPreview) -> some View {
        Section(edText("待应用更改（\(preview.changes.count)）", "Changes to apply (\(preview.changes.count))")) {
            if preview.changes.isEmpty { Text(edText("没有需要同步的更改", "No changes to sync")).foregroundStyle(.secondary) }
            ForEach(preview.changes) { change in
                VStack(alignment: .leading, spacing: 6) {
                    Text(change.before.reference.isEmpty ? edText("未编号元件", "Unannotated part") : change.before.reference)
                        .font(.headline)
                    if change.before.reference != change.after.reference {
                        changeLine(edText("位号", "Reference"), change.before.reference, change.after.reference)
                    }
                    if change.before.value != change.after.value {
                        changeLine(edText("值", "Value"), change.before.value, change.after.value)
                    }
                    if change.before.footprintID != change.after.footprintID {
                        changeLine(edText("封装", "Footprint"), footprintName(change.before.footprintID), footprintName(change.after.footprintID))
                    }
                }.accessibilityElement(children: .combine)
            }
        }
    }
    @ViewBuilder private func issues(_ preview: EDABackAnnotationPreview) -> some View {
        if !preview.issues.isEmpty {
            Section(edText("需要留意", "Review")) {
                ForEach(Array(preview.issues.enumerated()), id: \.offset) { _, issue in
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(issueTitle(issue.code))
                            if !issue.reference.isEmpty { Text(issue.reference).font(.caption).foregroundStyle(.secondary) }
                        }
                    } icon: {
                        Image(systemName: issue.blocking ? "exclamationmark.triangle" : "info.circle")
                            .foregroundStyle(issue.blocking ? Color.orange : Color.secondary)
                    }
                }
            }
        }
    }
    private func changeLine(_ title: String, _ before: String, _ after: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text((before.isEmpty ? "—" : before) + " → " + (after.isEmpty ? "—" : after))
                .font(.subheadline).textSelection(.enabled)
        }
    }
    private func footprintName(_ id: UUID?) -> String {
        session.project.footprints.first(where: { $0.id == id })?.name ?? edText("未分配", "Unassigned")
    }
    private func issueTitle(_ code: EDABackAnnotationIssue.Code) -> String {
        switch code {
        case .unlinkedFootprint: edText("跳过未关联原理图的封装", "Skip a footprint without a schematic link")
        case .missingComponent: edText("关联元件已移除，跳过该封装", "Skip a footprint whose linked part was removed")
        case .multipleFootprints: edText("同一元件关联了多个封装，请先调整", "Resolve multiple footprints linked to the same part")
        case .invalidReference: edText("位号为空或格式有误，请先修改 PCB 位号", "Fix the empty or invalid PCB reference")
        case .duplicateReference: edText("更新后的位号重复，请先修改 PCB 位号", "Resolve duplicate PCB references")
        case .incompatibleFootprint: edText("封装缺少元件引脚对应的焊盘，请先检查", "Check the footprint's missing pin-to-pad assignments")
        }
    }
    @MainActor private func refresh() async {
        plan = nil; message = nil; loading = true
        let source = session.project, selected = boardID, requested = options
        let worker = Task.detached(priority: .userInitiated) {
            try EDABackAnnotation.plan(source, boardID: selected, options: requested, cancelled: { Task.isCancelled })
        }
        do {
            let value = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            try Task.checkCancellation()
            guard !session.isClosed, session.project == source, boardID == selected, options == requested else { return }
            plan = value; loading = false
        } catch {
            guard !Task.isCancelled else { return }
            message = edText("暂时无法比较，请重新打开此窗口。", "Could not compare the design. Reopen this window to retry.")
            loading = false
        }
    }
    private func apply() {
        guard let plan, plan.preview.canApply, !applying else { return }
        applying = true; message = nil
        Task { @MainActor in
            defer { applying = false }
            do { try await session.backAnnotation(plan); dismiss() }
            catch { message = edText("未能保存更新，请检查当前设计后重试。", "Could not save the update. Review the current design and retry.") }
        }
    }
}
