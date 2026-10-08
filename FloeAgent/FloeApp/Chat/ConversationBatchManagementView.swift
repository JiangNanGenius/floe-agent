#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloePersistence

import FloeCore
/// One batch flow for sidebar, workbench and chat history. Only successful
/// items leave the selection, so partial failures remain actionable.
struct ConversationBatchManagementView: View {
    @ObservedObject var center: ConversationCenter
    @Environment(\.dismiss) private var dismiss
    @State private var conversations: [ConversationRecord] = []
    @State private var selected: Set<UUID> = []
    @State private var archived = false
    @State private var query = ""
    @State private var contentMatches: [UUID: String] = [:]
    @State private var searching = false
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
            ($0.archivedAt != nil) == archived && (query.isEmpty || $0.title.localizedStandardContains(query) || contentMatches[$0.id] != nil)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("background.task.name_fallback", selection: $archived) {
                    Text("settings.all_workspaces_files_view.chat").tag(false)
                    Text("settings.all_workspaces_files_view.archived").tag(true)
                }.pickerStyle(.segmented)
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if searching { ProgressView("chat.conversation_batch_management_view.searching_conversations") }
                if visible.isEmpty && !searching {
                    ContentUnavailableView("chat.conversation_batch_management_view.no_matching_tasks", systemImage: "bubble.left.and.bubble.right")
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
                                if let snippet = contentMatches[conversation.id] {
                                    Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                }
                                Text(conversation.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                        }.frame(minHeight: 44)
                    }
                    .accessibilityAddTraits(selected.contains(conversation.id) ? .isSelected : [])
                    .accessibilityIdentifier("tasks.batch.row.\(conversation.id)")
                }
            }
            .navigationTitle("chat.conversation_batch_management_view.select_tasks")
            .searchable(text: $query, prompt: "chat.conversation_batch_management_view.search_titles_and_conversation_content")
            .task(id: query) { await searchContents() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("action.done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button(selected == Set(visible.map(\.id)) && !selected.isEmpty ? "chat.conversation_batch_management_view.deselect_all" : "composer.editor.select_all") {
                        let ids = Set(visible.map(\.id))
                        selected = selected == ids ? [] : ids
                    }.disabled(visible.isEmpty)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Text(FloeL10n.l("chat.conversation_batch_management_view.selected", selected.count)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(archived ? "canvas.drawingHistory.restore" : "app.floe_agent_app.archive", systemImage: "archivebox") {
                        if !archived, center.activeRuns.values.contains(where: { selected.contains($0.conversationID) }) {
                            confirmingArchive = true
                        } else { Task { await perform(deleting: false) } }
                    }
                        .disabled(selected.isEmpty)
                    Button("workspace.workspace_canvas_view.delete", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                        .disabled(selected.isEmpty)
                }
            }
            .disabled(busy)
            .overlay { if busy { ProgressView() } }
            .interactiveDismissDisabled(busy)
            .task { await load() }
            .onChange(of: archived) { _, _ in selected.removeAll() }

            .confirmationDialog("chat.conversation_batch_management_view.stop_and_archive_the_selected_tasks", isPresented: $confirmingArchive, titleVisibility: .visible) {
                Button("chat.conversation_batch_management_view.stop_and_archive") { Task { await perform(deleting: false) } }
                Button("action.cancel", role: .cancel) {}
            } message: { Text("chat.conversation_batch_management_view.the_selected_task_is_still_running") }
            .confirmationDialog(FloeL10n.l("chat.conversation_batch_management_view.delete_the_selected_tasks", selected.count), isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("workspace.workspace_canvas_view.delete", role: .destructive) { Task { await perform(deleting: true) } }
                Button("action.cancel", role: .cancel) {}
            } message: {
                Text("chat.conversation_batch_management_view.the_task_and_its_private_workspace")
            }
        }
    }

    private func searchContents() async {
        contentMatches = [:]
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { searching = false; return }
        searching = true
        do {
            try await Task.sleep(for: .milliseconds(220))
            let hits = try await center.environment.intelligenceStore.matchingConversationSnippets(value)
            guard !Task.isCancelled else { return }
            contentMatches = hits; searching = false
        } catch is CancellationError { return }
        catch { guard !Task.isCancelled else { return }; self.error = error.localizedDescription; searching = false }
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
