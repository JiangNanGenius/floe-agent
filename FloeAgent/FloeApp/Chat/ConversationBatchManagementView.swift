#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloePersistence

/// One batch flow for sidebar, workbench and chat history. Only successful
/// items leave the selection, so partial failures remain actionable.
struct ConversationBatchManagementView: View {
    @ObservedObject var center: ConversationCenter
    @Environment(\.dismiss) private var dismiss
    @State private var conversations: [ConversationRecord] = []
    @State private var selected: Set<UUID> = []
    @State private var archived = false
    @State private var query = ""
    @State private var busy = false
    @State private var error: String?
    @State private var confirmingDelete = false
    @State private var confirmingArchive = false

    init(center: ConversationCenter, initialConversation: ConversationRecord? = nil) {
        self.center = center
        _selected = State(initialValue: initialConversation.map { [$0.id] } ?? [])
        _archived = State(initialValue: initialConversation?.archivedAt != nil)
    }

    private var visible: [ConversationRecord] {
        conversations.filter {
            ($0.archivedAt != nil) == archived && (query.isEmpty || $0.title.localizedStandardContains(query))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("任务", selection: $archived) {
                    Text("聊天").tag(false)
                    Text("已归档").tag(true)
                }.pickerStyle(.segmented)
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if visible.isEmpty {
                    ContentUnavailableView("没有匹配的任务", systemImage: "bubble.left.and.bubble.right")
                }
                ForEach(visible) { conversation in
                    Button {
                        if !selected.insert(conversation.id).inserted { selected.remove(conversation.id) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selected.contains(conversation.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(conversation.id) ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(conversation.title).foregroundStyle(.primary).lineLimit(2)
                                Text(conversation.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                        }.frame(minHeight: 44)
                    }
                    .accessibilityAddTraits(selected.contains(conversation.id) ? .isSelected : [])
                    .accessibilityIdentifier("tasks.batch.row.\(conversation.id)")
                }
            }
            .navigationTitle("选择任务")
            .searchable(text: $query, prompt: "搜索任务")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("action.done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button(selected == Set(visible.map(\.id)) && !selected.isEmpty ? "取消全选" : "全选") {
                        let ids = Set(visible.map(\.id))
                        selected = selected == ids ? [] : ids
                    }.disabled(visible.isEmpty)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Text("已选 \(selected.count)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(archived ? "恢复" : "归档", systemImage: "archivebox") {
                        if !archived, center.activeRuns.values.contains(where: { selected.contains($0.conversationID) }) {
                            confirmingArchive = true
                        } else { Task { await perform(deleting: false) } }
                    }
                        .disabled(selected.isEmpty)
                    Button("删除", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                        .disabled(selected.isEmpty)
                }
            }
            .disabled(busy)
            .overlay { if busy { ProgressView() } }
            .interactiveDismissDisabled(busy)
            .task { await load() }
            .onChange(of: archived) { _, _ in selected.removeAll() }
            .onChange(of: query) { _, _ in selected.formIntersection(Set(visible.map(\.id))) }
            .confirmationDialog("停止运行并归档所选任务？", isPresented: $confirmingArchive, titleVisibility: .visible) {
                Button("停止并归档") { Task { await perform(deleting: false) } }
                Button("action.cancel", role: .cancel) {}
            } message: { Text("所选任务仍在运行。归档会先停止执行，之后可从归档区恢复。") }
            .confirmationDialog("删除所选的 \(selected.count) 个任务？", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) { Task { await perform(deleting: true) } }
                Button("action.cancel", role: .cancel) {}
            } message: {
                Text("任务及其私有工作区将被删除，共享项目文件保留。此操作不可撤销。")
            }
        }
    }

    private func load() async {
        do {
            conversations = try await center.environment.conversationStore.conversations(includeArchived: true)
            selected.formIntersection(Set(conversations.map(\.id)))
        } catch { self.error = error.localizedDescription }
    }

    private func perform(deleting: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        error = nil
        var failures: [String] = []
        let targets = conversations.filter { selected.contains($0.id) }
        for conversation in targets {
            do {
                if deleting { try await center.deleteConversation(id: conversation.id) }
                else if archived { try await center.restoreConversation(id: conversation.id) }
                else { try await center.archiveConversation(id: conversation.id) }
                selected.remove(conversation.id)
            } catch { failures.append("\(conversation.title): \(error.localizedDescription)") }
        }
        if !failures.isEmpty { error = failures.joined(separator: "\n") }
        await load()
    }
}
#endif
