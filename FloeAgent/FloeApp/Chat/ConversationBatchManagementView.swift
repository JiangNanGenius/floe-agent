// FloeApp — Canonical task management surface.
//
// SPDX-License-Identifier: MPL-2.0
//
// One management screen for every entry point: the Task Center (管理),
// Settings > Data Management and the run-history screen present THIS view.
// It lists TASKS (conversation identity), never individual RunRecords: one
// task owns zero or more runs, and archive/restore/delete act on the task
// exactly once.
//
// The screen only composes existing single-target lifecycle commands through
// `ConversationTaskBulkService` — no second store. Select-all is scoped to
// the rows the user can currently see (filter + search); hidden tasks are
// never swept in. Resolved items leave the selection from the real per-item
// results, unresolved items stay selected for a truthful retry.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloePersistence

import FloeCore

struct ConversationBatchManagementView: View {
    /// Which task list the screen manages. Tasks and the archive share one
    /// store; the filter only changes the visible slice.
    enum Filter: Hashable {
        case active
        case archived
    }

    /// How the screen is hosted: its own sheet stack, or pushed inside an
    /// existing navigation stack (Settings). The content is identical.
    enum Presentation {
        case sheet
        case pushed
    }

    @ObservedObject var center: ConversationCenter
    @Environment(\.dismiss) private var dismiss

    private let presentation: Presentation
    @State private var filter: Filter
    @State private var conversations: [ConversationRecord] = []
    @State private var selected: Set<UUID> = []
    @State private var query = ""
    @State private var contentMatches: [UUID: String] = [:]
    @State private var searching = false
    @State private var busy = false
    @State private var errorText: String?
    @State private var summary: TaskBulkSummary?
    @State private var cancellation: TaskBulkCancellationToken?
    @State private var confirmingArchive = false
    @State private var confirmingDelete = false
    /// The EXACT identities each pending confirmation was requested for. The
    /// dialog's count and its action both use this frozen set, so a filter,
    /// search or selection change while the dialog is open can never redirect
    /// the operation to a different set of tasks than the one confirmed.
    @State private var pendingArchiveTargets: [ConversationRecord] = []
    @State private var pendingDeleteTargets: [ConversationRecord] = []
    @State private var pendingArchiveRunningImpact = 0
    @State private var pendingDeleteRunningImpact = 0

    init(
        center: ConversationCenter,
        initialConversation: ConversationRecord? = nil,
        initialFilter: Filter? = nil,
        presentation: Presentation = .sheet
    ) {
        self.center = center
        self.presentation = presentation
        _filter = State(initialValue: initialFilter ?? (initialConversation?.archivedAt != nil ? .archived : .active))
        _selected = State(initialValue: initialConversation.map { [$0.id] } ?? [])
    }

    // MARK: - Visible slice

    private var visible: [ConversationRecord] {
        conversations.filter {
            ($0.archivedAt != nil) == (filter == .archived)
                && (query.isEmpty
                    || $0.title.localizedStandardContains(query)
                    || contentMatches[$0.id] != nil)
        }
    }

    private var visibleIDs: Set<UUID> { Set(visible.map(\.id)) }
    private var isArchivedFilter: Bool { filter == .archived }

    private var selectedRecords: [ConversationRecord] {
        visible.filter { selected.contains($0.id) }
    }

    private var selectAllTitle: String {
        TaskBulkSelectionRules.allVisibleSelected(selected, visible: visibleIDs)
            ? FloeL10n.l("chat.conversation_batch_management_view.deselect_all")
            : FloeL10n.l("composer.editor.select_all")
    }

    var body: some View {
        Group {
            if presentation == .sheet {
                NavigationStack { content }
            } else {
                content
            }
        }
    }

    // MARK: - Content

    private var content: some View {
        List {
            Section {
                Picker(TaskManagementCopy.title, selection: $filter) {
                    Text(TaskManagementCopy.tasksFilter).tag(Filter.active)
                    Text("settings.all_workspaces_files_view.archived").tag(Filter.archived)
                }
                .pickerStyle(.segmented)
                .disabled(busy)
            }

            if let errorText {
                Section {
                    Text(errorText).foregroundStyle(FloeTheme.destructive).textSelection(.enabled)
                }
            }

            if let summary, !summary.isEmpty {
                summarySection(summary)
            }

            if searching {
                Section {
                    ProgressView("chat.conversation_batch_management_view.searching_conversations")
                        .foregroundStyle(.secondary)
                }
            }

            if visible.isEmpty && !searching {
                ContentUnavailableView {
                    Label(
                        TaskManagementCopy.title,
                        systemImage: isArchivedFilter ? "archivebox" : "checklist"
                    )
                } description: {
                    Text(query.isEmpty
                         ? (isArchivedFilter
                            ? FloeL10n.l("chat.conversation_list_view.the_archive_is_empty")
                            : TaskManagementCopy.noTasks)
                         : FloeL10n.l("chat.conversation_batch_management_view.no_matching_tasks"))
                }
            } else {
                Section {
                    ForEach(visible) { conversation in
                        row(conversation)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(
            text: $query,
            prompt: Text("chat.conversation_batch_management_view.search_titles_and_conversation_content")
        )
        .navigationTitle(TaskManagementCopy.title)
        .toolbar { toolbarContent }
        .disabled(busy)
        .overlay {
            if busy {
                busyOverlay
            }
        }
        .interactiveDismissDisabled(busy)
        .task { await load() }
        .task(id: query) { await searchContents() }
        .onChange(of: filter) { _, _ in
            // Tasks and archive are disjoint scopes: a selection never crosses
            // the filter boundary, and the previous batch receipt refers to
            // the other slice.
            selected.removeAll()
            summary = nil
        }
        .onChange(of: query) { _, _ in
            contentMatches = [:]
            selected = TaskBulkSelectionRules.pruned(selected, to: visibleIDs)
        }
        .confirmationDialog(
            "chat.conversation_batch_management_view.stop_and_archive_the_selected_tasks",
            isPresented: $confirmingArchive,
            titleVisibility: .visible
        ) {
            Button("chat.conversation_batch_management_view.stop_and_archive") {
                let records = pendingArchiveTargets
                pendingArchiveTargets = []
                Task { await perform(.archive, targets: records) }
            }
            Button("action.cancel", role: .cancel) { pendingArchiveTargets = [] }
        } message: {
            Text(archiveConfirmationMessage)
        }
        .confirmationDialog(
            FloeL10n.l("chat.conversation_batch_management_view.delete_the_selected_tasks", pendingDeleteTargets.count),
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("workspace.workspace_canvas_view.delete", role: .destructive) {
                let records = pendingDeleteTargets
                pendingDeleteTargets = []
                Task { await perform(.delete, targets: records) }
            }
            Button("action.cancel", role: .cancel) { pendingDeleteTargets = [] }
        } message: {
            Text(deleteConfirmationMessage)
        }
    }

    @ViewBuilder
    private func row(_ conversation: ConversationRecord) -> some View {
        Button {
            selected = TaskBulkSelectionRules.toggled(selected, id: conversation.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected.contains(conversation.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected.contains(conversation.id) ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayTitle(conversation)).foregroundStyle(.primary).lineLimit(2)
                    if let snippet = contentMatches[conversation.id] {
                        Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                    Text(conversation.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                ConversationActivityBadge(conversationID: conversation.id, center: center)
            }
            .frame(minHeight: FloeTheme.minimumTarget)
            // The whole row is the target: without an explicit content shape
            // the trailing spacer (and the empty area beside the title) is not
            // hit-testable, so a tap there did nothing.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected.contains(conversation.id) ? .isSelected : [])
        .accessibilityIdentifier("tasks.batch.row.\(conversation.id)")
    }

    @ViewBuilder
    private func summarySection(_ summary: TaskBulkSummary) -> some View {
        Section {
            Text(summaryText(summary))
                .font(.footnote)
            ForEach(summary.unresolvedItems) { result in
                Text("\(result.item.title) · \(result.outcome.issueText ?? "")")
                    .font(.caption).foregroundStyle(FloeTheme.destructive).lineLimit(2)
            }
            if summary.wasCancelled {
                Text(TaskManagementCopy.cancelledNote)
                    .font(.caption).foregroundStyle(.secondary)
            } else if !summary.retainedIDs.isEmpty {
                Text(TaskManagementCopy.keepFailedSelected)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var busyOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(TaskManagementCopy.working)
                .font(.footnote).foregroundStyle(.secondary)
            Button(TaskManagementCopy.stopBatch) { cancellation?.cancel() }
                .buttonStyle(.bordered)
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if presentation == .sheet {
            ToolbarItem(placement: .cancellationAction) {
                Button("action.done") { dismiss() }.disabled(busy)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button(selectAllTitle) {
                selected = TaskBulkSelectionRules.selectionAfterSelectAllToggle(selected, visible: visibleIDs)
            }
            .disabled(visible.isEmpty || busy)
            .accessibilityIdentifier("tasks.manage.selectAll")
            if !selected.isEmpty {
                Button("action.cancel") { selected.removeAll() }
                    .disabled(busy)
                    .accessibilityIdentifier("tasks.manage.cancelSelection")
            }
        }
        if !selected.isEmpty {
            ToolbarItemGroup(placement: .bottomBar) {
                Text(FloeL10n.l("chat.conversation_batch_management_view.selected", selected.count))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if isArchivedFilter {
                    Button {
                        let records = selectedRecords
                        Task { await perform(.restore, targets: records) }
                    } label: {
                        Label(FloeL10n.l("canvas.drawingHistory.restore"), systemImage: "arrow.uturn.backward")
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("tasks.manage.restore")
                } else {
                    Button { requestArchive() } label: {
                        Label(FloeL10n.l("app.floe_agent_app.archive"), systemImage: "archivebox")
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("tasks.manage.archive")
                }
                Button(role: .destructive) { requestDelete() } label: {
                    Label(FloeL10n.l("workspace.workspace_canvas_view.delete"), systemImage: "trash")
                }
                .disabled(busy)
                .accessibilityIdentifier("tasks.manage.delete")
            }
        }
    }

    // MARK: - Actions

    private func displayTitle(_ conversation: ConversationRecord) -> String {
        conversation.title.isEmpty ? FloeL10n.l("chat.untitled") : conversation.title
    }

    /// The archive confirmation always names the existing command's
    /// semantics (it stops the selected tasks' own running work first —
    /// `ConversationCenter.archiveConversation`); when live work is known it
    /// also states the count, and it never claims that nothing is running.
    private var archiveConfirmationMessage: String {
        var text = TaskManagementCopy.archiveStopsRunningWork
        if pendingArchiveRunningImpact > 0 {
            text += "\n" + TaskManagementCopy.runningImpact(pendingArchiveRunningImpact)
        }
        return text
    }

    private var deleteConfirmationMessage: String {
        var text = FloeL10n.l("chat.conversation_batch_management_view.the_task_and_its_private_workspace")
        text += "\n" + TaskManagementCopy.deleteStopsRunningWork
        if pendingDeleteRunningImpact > 0 {
            text += "\n" + TaskManagementCopy.runningImpact(pendingDeleteRunningImpact)
        }
        return text
    }

    /// Archiving is a destructive-in-progress change for a running task, so
    /// a non-empty selection is ALWAYS confirmed before anything is stopped.
    /// The live count is only a hint; the copy never asserts that a zero
    /// count means no related work exists. The confirmed identities are
    /// FROZEN here: the dialog and its action use exactly this set.
    private func requestArchive() {
        let records = selectedRecords
        guard !records.isEmpty else { return }
        pendingArchiveTargets = records
        pendingArchiveRunningImpact = ConversationTaskBulkService(center: center)
            .runningCount(among: Set(records.map(\.id)))
        confirmingArchive = true
    }

    /// Delete is always confirmed, with the selected count and the real
    /// running impact stated before anything is stopped. The confirmed
    /// identities are frozen here as well.
    private func requestDelete() {
        let records = selectedRecords
        guard !records.isEmpty else { return }
        pendingDeleteTargets = records
        pendingDeleteRunningImpact = ConversationTaskBulkService(center: center)
            .runningCount(among: Set(records.map(\.id)))
        confirmingDelete = true
    }

    private func perform(_ operation: TaskBulkOperation, targets: [ConversationRecord]) async {
        guard !busy else { return }
        let items = targets.map { TaskBulkItem(id: $0.id, title: displayTitle($0)) }
        guard !items.isEmpty else { return }
        busy = true
        errorText = nil
        let token = TaskBulkCancellationToken()
        cancellation = token
        // One batch of this operation only. There is deliberately NO
        // lifetime exclusion set across operations: each archive/restore/
        // delete request is its own authority, and the durable per-item
        // preflight already makes an accidental replay safe. Resolved items
        // are removed from the selection below, so a retry targets exactly
        // the unresolved remainder.
        let result = await ConversationTaskBulkService(center: center).run(
            operation: operation,
            items: items,
            cancellation: token
        )
        cancellation = nil
        summary = result
        selected.subtract(result.removedIDs)
        await load()
        selected = TaskBulkSelectionRules.pruned(selected, to: visibleIDs)
        busy = false
    }

    // MARK: - Loading

    private func load() async {
        do {
            let records = try await center.environment.conversationStore.conversations(includeArchived: true)
            conversations = records
            selected = TaskBulkSelectionRules.pruned(selected, to: Set(records.map(\.id)))
        } catch {
            // Ordinary UI: a concise localized error, never a raw
            // implementation string. The failure itself stays in the logs.
            errorText = TaskManagementCopy.readFailure
        }
    }

    private func searchContents() async {
        contentMatches = [:]
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            searching = false
            return
        }
        searching = true
        do {
            try await Task.sleep(for: .milliseconds(220))
            let hits = try await center.environment.intelligenceStore.matchingConversationSnippets(value)
            guard !Task.isCancelled else { return }
            contentMatches = hits
            searching = false
            selected = TaskBulkSelectionRules.pruned(selected, to: visibleIDs)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorText = ConversationTaskBulkService.failureText(for: error)
            searching = false
        }
    }

    // MARK: - Summary copy

    private func summaryText(_ summary: TaskBulkSummary) -> String {
        var parts: [String] = []
        if summary.archivedCount > 0 {
            parts.append(TaskManagementCopy.resultArchived(summary.archivedCount))
        }
        if summary.restoredCount > 0 {
            parts.append(TaskManagementCopy.resultRestored(summary.restoredCount))
        }
        if summary.deletedCount > 0 {
            parts.append(TaskManagementCopy.resultDeleted(summary.deletedCount))
        }
        if summary.skippedCount > 0 {
            parts.append(TaskManagementCopy.resultSkipped(summary.skippedCount))
        }
        if summary.failedCount > 0 {
            parts.append(TaskManagementCopy.resultFailed(summary.failedCount))
        }
        if summary.unverifiedCount > 0 {
            parts.append(TaskManagementCopy.resultUnverified(summary.unverifiedCount))
        }
        if summary.notAttemptedCount > 0 {
            parts.append(TaskManagementCopy.resultNotAttempted(summary.notAttemptedCount))
        }
        return parts.joined(separator: " · ")
    }
}
#endif
