import SwiftUI
import FloeWorkspace

/// Decisions are scoped to one observed disk version. The caller revalidates
/// that version on commit and presents a new review if it changed again.
struct TextConflictReviewView: View {
    let conflict: WorkspaceEditConflict
    let onResolve: (String) async -> Void
    let onCancel: () -> Void
    @State private var choices: [Int: TextMergePlan.Choice] = [:]
    @State private var saving = false
    @State private var showsResult = false
    @State private var manualResult: String?
    private let plan: TextMergePlan
    init(conflict: WorkspaceEditConflict, onResolve: @escaping (String) async -> Void, onCancel: @escaping () -> Void) {
        self.conflict = conflict; self.onResolve = onResolve; self.onCancel = onCancel
        plan = conflict.plan
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("edit.conflict.explanation").foregroundStyle(.secondary)
                    if let recovery = conflict.recoveryPath {
                        Label("edit.conflict.recovery", systemImage: "doc.on.doc")
                        Text(recovery).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if plan.conflicts.isEmpty {
                        Label("edit.conflict.automatic", systemImage: "checkmark.circle")
                    }
                    ForEach(plan.conflicts) { block in
                        VStack(alignment: .leading, spacing: 12) {
                            Text("edit.conflict.region \(block.id + 1)").font(.headline)
                            if conflict.base != nil {
                                DisclosureGroup("edit.conflict.original") { code(block.base) }
                            }
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .top, spacing: 12) { variants(block) }
                                    .frame(minWidth: 600)
                                VStack(alignment: .leading, spacing: 12) { variants(block) }
                            }
                            Picker("edit.conflict.keep", selection: Binding(
                                get: { choices[block.id]?.rawValue ?? "" },
                                set: { choices[block.id] = TextMergePlan.Choice(rawValue: $0) })) {
                                Text("edit.conflict.choose").tag("")
                                Text("edit.conflict.mine").tag("mine")
                                Text("edit.conflict.current").tag("current")
                            }.pickerStyle(.segmented)
                            .accessibilityIdentifier("edit.conflict.choice.\(block.id)")
                        }.padding(16).background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                    }
                    if let result = plan.resolved(choices) {
                        DisclosureGroup("edit.conflict.result", isExpanded: $showsResult) {
                            Text("edit.conflict.manualHint").font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: Binding(get: { manualResult ?? result }, set: { manualResult = $0 }))
                                .font(.system(.callout, design: .monospaced))
                                .frame(minHeight: 240)
                                .accessibilityIdentifier("edit.conflict.mergedText")
                        }
                    }
                }.padding(20)
            }
            .navigationTitle("edit.conflict.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("edit.conflict.later", action: onCancel).disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("edit.conflict.save") {
                        guard let result = plan.resolved(choices) else { return }
                        saving = true
                        Task { await onResolve(manualResult ?? result); saving = false }
                    }.disabled(saving || plan.resolved(choices) == nil)
                    .accessibilityIdentifier("edit.conflict.save")
                }
            }
        }.interactiveDismissDisabled(saving)
        .onChange(of: choices) { _, _ in manualResult = nil }
    }
    @ViewBuilder private func variants(_ block: TextMergePlan.Block) -> some View {
        VStack(alignment: .leading) { Text("edit.conflict.mine").font(.subheadline.bold()); code(block.mine) }
            .frame(maxWidth: .infinity, alignment: .leading)
        VStack(alignment: .leading) { Text("edit.conflict.current").font(.subheadline.bold()); code(block.current) }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func code(_ lines: [String]) -> some View {
        let full = lines.joined(separator: "\n")
        let preview = String(full.prefix(24_000))
        return VStack(alignment: .leading) {
            Text(lines.isEmpty ? String(localized: "edit.conflict.deleted") : preview)
                .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            if preview.count < full.count { Text("edit.conflict.previewLimited").font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
