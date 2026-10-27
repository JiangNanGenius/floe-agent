// FloeApp — Inline conversation selection + the corrected row long-press menu.
//
// SPDX-License-Identifier: MPL-2.0
//
// User-corrected contract (2026-10-27, binding): an ORDINARY conversation row
// shows NO trailing ellipsis and NO circles. A long press opens the NATIVE
// context menu (Pin/Unpin, Rename, Move, Multi-select, Archive, Delete) — it
// never enters selection directly. Only choosing Multi-select activates the
// inline circles and selects the invoking row; tapping a row or circle then
// toggles WITHOUT navigating, and Done restores the ordinary rows plus the
// current conversation (the router selection is never touched by the mode).
// The open mode shows a compact HEADER (count · select-all · Done) above the
// list and a two-row BATCH BAR at the bottom (archive / delete, plus rename
// / move when exactly one row is selected) so controls never cram into one
// horizontal bar at sidebar width. Pin writes the durable conversation row
// (schema v55) through the center; bulk archive/delete route through the
// existing `ConversationTaskBulkService` / `TaskBulkRunner` engine (frozen
// confirmation targets, cooperative stop between items, truthful per-item
// results, unresolved items stay selected for a retry) — the same engine
// the dedicated management pages use. There is no second store, queue or
// permission path here, and no separate management modal to enter selection.
//
// Scope discipline: selection suspends row navigation only. It never touches
// `AppRouter`, the outer split navigation, the running conversation or the
// temporary-session lifecycle. Successful changes flow through the center's
// existing reload / router reconciliation, so list, active selection and
// navigation refresh with real state — nothing is fabricated. The legacy
// direct long-press entry (`inlineSelectionLongPress`) and single bottom bar
// stay only for the Task Center surface this round (its host file is owned
// elsewhere); the sidebar and Chat list use the corrected menu + split bars.

#if canImport(SwiftUI) && canImport(UIKit)
import Combine
import Foundation
import SwiftUI
import FloeCore

/// Stable accessibility identifiers for the inline selection controls. The
/// row identifiers of the hosting lists (`sidebar.conversation.<UUID>`,
/// `chat.row.<UUID>`, `workbench.row.<UUID>`) stay owned by the hosts; the
/// circles carry these identifiers so automation can assert selection state.
enum InlineSelectionIdentifiers {
    static func circle(_ conversationID: UUID) -> String {
        "tasks.inline.circle.\(conversationID.uuidString)"
    }

    static let selectAll = "tasks.inline.selectAll"
    static let done = "tasks.inline.done"
    static let count = "tasks.inline.count"
    static let archive = "tasks.inline.archive"
    static let delete = "tasks.inline.delete"
    static let stop = "tasks.inline.stop"
    static let confirmArchive = "tasks.inline.confirm.archive"
    static let confirmDelete = "tasks.inline.confirm.delete"
    static let confirmCancel = "tasks.inline.confirm.cancel"
    static let rename = "tasks.inline.rename"
    static let move = "tasks.inline.move"
    /// Row context-menu items (best effort: system menu surfaces often match
    /// by label; the identifiers keep SwiftUI-level automation anchors).
    static let menuPin = "conversation.menu.pin"
    static let menuUnpin = "conversation.menu.unpin"
    static let menuRename = "conversation.menu.rename"
    static let menuMove = "conversation.menu.move"
    static let menuMultiSelect = "conversation.menu.multiSelect"
    static let menuArchive = "conversation.menu.archive"
    static let menuDelete = "conversation.menu.delete"
}

enum InlineSelectionTiming {
    /// Recognizes before the system context menu and before a release
    /// commits list selection, while movement still cancels it so scrolling
    /// keeps working.
    static let longPressDuration: Double = 0.4
    static let longPressMaximumDistance: CGFloat = 10
}

/// Concise bilingual copy for controls without a dedicated catalog entry
/// yet; everything else reuses existing registered keys.
enum InlineSelectionCopy {
    static func rowState(_ selected: Bool) -> String {
        ChatBilingualCatalog.localized(
            key: "chat.inline_selection.row_state",
            en: selected ? "Selected" : "Unselected",
            zh: selected ? "已选择" : "未选择"
        )
    }

    static var done: String { FloeL10n.l("action.done") }
    static var archive: String { FloeL10n.l("app.floe_agent_app.archive") }
    static var delete: String { FloeL10n.l("workspace.workspace_canvas_view.delete") }
    static var selectAll: String { FloeL10n.l("composer.editor.select_all") }
    static var deselectAll: String {
        FloeL10n.l("chat.conversation_batch_management_view.deselect_all")
    }
    static func selected(_ count: Int) -> String {
        FloeL10n.l("chat.conversation_batch_management_view.selected", count)
    }
    static func untitled(_ title: String) -> String {
        title.isEmpty ? FloeL10n.l("chat.untitled") : title
    }

    /// Row context-menu labels. Rename/Move/Archive/Delete reuse the exact
    /// registered keys the former per-row menu used; only the pin pair and
    /// Multi-select are new, with the established bilingual catalog fallback
    /// until Main registers them in `Localizable.xcstrings` (handoff lists
    /// the keys).
    static var pin: String {
        ChatBilingualCatalog.localized(key: "chat.conversation_menu.pin", en: "Pin", zh: "置顶")
    }
    static var unpin: String {
        ChatBilingualCatalog.localized(key: "chat.conversation_menu.unpin", en: "Unpin", zh: "取消置顶")
    }
    static var multiSelect: String {
        ChatBilingualCatalog.localized(
            key: "chat.conversation_menu.multi_select", en: "Multi-select", zh: "多选")
    }
    static var rename: String { FloeL10n.l("workspace.file_tree_view.rename") }
    static var move: String { FloeL10n.l("app.floe_agent_app.move_to_project") }
    /// Honest disabled hint when the user has no project to move into yet.
    static var noProjects: String {
        ChatBilingualCatalog.localized(
            key: "chat.conversation_menu.no_projects",
            en: "No projects yet",
            zh: "暂无项目")
    }
}

/// Same truthful receipt vocabulary as the dedicated management page,
/// composed as one compact line for the inline bar.
enum InlineSelectionResultCopy {
    static func text(for summary: TaskBulkSummary) -> String {
        var parts: [String] = []
        if summary.archivedCount > 0 { parts.append(TaskManagementCopy.resultArchived(summary.archivedCount)) }
        if summary.restoredCount > 0 { parts.append(TaskManagementCopy.resultRestored(summary.restoredCount)) }
        if summary.deletedCount > 0 { parts.append(TaskManagementCopy.resultDeleted(summary.deletedCount)) }
        if summary.skippedCount > 0 { parts.append(TaskManagementCopy.resultSkipped(summary.skippedCount)) }
        if summary.failedCount > 0 { parts.append(TaskManagementCopy.resultFailed(summary.failedCount)) }
        if summary.unverifiedCount > 0 { parts.append(TaskManagementCopy.resultUnverified(summary.unverifiedCount)) }
        if summary.notAttemptedCount > 0 { parts.append(TaskManagementCopy.resultNotAttempted(summary.notAttemptedCount)) }
        return parts.joined(separator: " · ")
    }
}

/// One bulk lane across all inline selection surfaces: only ONE frozen
/// batch runs at a time app-wide (the canonical management sheet was a
/// single presentation, so batches never overlapped; inline surfaces are
/// simultaneous by nature — sidebar plus content column — so the lane keeps
/// the existing bounded-serial guarantee across them). Hosts normally share
/// `InlineConversationBulkLane.shared`; tests inject private lanes.
@MainActor
final class InlineConversationBulkLane {
    static let shared = InlineConversationBulkLane()

    private weak var owner: InlineConversationSelectionModel?

    var isOccupied: Bool { owner != nil }

    @discardableResult
    func claim(_ model: InlineConversationSelectionModel) -> Bool {
        guard owner == nil || owner === model else { return false }
        owner = model
        return true
    }

    func release(_ model: InlineConversationSelectionModel) {
        if owner === model { owner = nil }
    }
}

/// The shared selection state machine. Deliberately store-free: hosts bind
/// it to their own visible slice and pass the EXISTING bulk service through
/// `run(operation:frozen:execute:afterRun:)`. Every mutation is gated while
/// a batch is in flight, and confirmation freezes the exact targets.
@MainActor
final class InlineConversationSelectionModel: ObservableObject {
    /// The executor contract: run one batch through the canonical engine.
    typealias BatchExecute = @MainActor @Sendable (
        TaskBulkOperation, [TaskBulkItem], TaskBulkCancellationToken
    ) async -> TaskBulkSummary
    /// Host refresh (reload the list) while the batch is still marked busy.
    typealias AfterBatch = @MainActor @Sendable () async -> Void

    @Published private(set) var isActive = false
    @Published private(set) var selectedIDs: Set<UUID> = []
    @Published private(set) var busy = false
    @Published private(set) var summary: TaskBulkSummary?

    let lane: InlineConversationBulkLane

    init(lane: InlineConversationBulkLane = .shared) {
        self.lane = lane
    }

    /// The dialog presentation flags plus the FROZEN targets each request
    /// captured — mirroring the dedicated management page, a filter, search
    /// or selection change while the dialog is open can never redirect the
    /// operation to a different set of tasks than the one confirmed.
    @Published private(set) var confirmingArchive = false
    @Published private(set) var confirmingDelete = false
    @Published private(set) var pendingArchiveItems: [TaskBulkItem] = []
    @Published private(set) var pendingDeleteItems: [TaskBulkItem] = []
    @Published private(set) var pendingArchiveRunningImpact = 0
    @Published private(set) var pendingDeleteRunningImpact = 0

    private var cancellation: TaskBulkCancellationToken?

    var selectedCount: Int { selectedIDs.count }
    var isSelected: Bool { !selectedIDs.isEmpty }
    /// A new confirmation may only be requested while no batch is running
    /// anywhere on this lane (sidebar and content column are simultaneous
    /// surfaces; batches stay bounded-serial app-wide).
    var canRequestBatch: Bool { !busy && !lane.isOccupied }

    // MARK: - Mode and selection

    /// Corrected menu entry (sidebar + Chat list): the row's native context
    /// menu was long-pressed open and the user chose Multi-select. Activates
    /// the inline circles HERE and selects the invoking row; the long press
    /// itself never enters selection, and nothing navigates. While a batch
    /// runs the request is refused like every other mutation.
    func startMultiSelect(with conversationID: UUID) {
        guard !busy else { return }
        summary = nil
        isActive = true
        selectedIDs.insert(conversationID)
    }

    /// Legacy direct long-press entry, retained ONLY for the Task Center
    /// host this round (its file is owned elsewhere): pressing selects the
    /// row immediately (or toggles it when the mode is already open).
    /// `begin(with: nil)` is the explicit "Manage" entry: activates with an
    /// empty selection. New hosts use `startMultiSelect(with:)` from the
    /// row context menu instead.
    func begin(with conversationID: UUID?) {
        guard !busy else { return }
        summary = nil
        if isActive {
            if let conversationID { toggle(conversationID) }
            return
        }
        isActive = true
        selectedIDs = conversationID.map { [$0] } ?? []
    }

    func toggle(_ conversationID: UUID) {
        guard isActive, !busy else { return }
        selectedIDs = TaskBulkSelectionRules.toggled(selectedIDs, id: conversationID)
    }

    /// Select-all is scoped to the rows the user currently sees (filter +
    /// search); hidden tasks are never swept in.
    func toggleSelectAll(visible: Set<UUID>) {
        guard isActive, !busy, !visible.isEmpty else { return }
        selectedIDs = TaskBulkSelectionRules.selectionAfterSelectAllToggle(selectedIDs, visible: visible)
    }

    /// Filter/search changes and disappearing rows must never leave an
    /// invisible pending selection. Frozen confirmation targets are
    /// deliberately NOT pruned: the confirmed dialog acts on exactly what
    /// the user confirmed.
    func pruneInvisible(_ visible: Set<UUID>) {
        guard isActive else { return }
        selectedIDs = TaskBulkSelectionRules.pruned(selectedIDs, to: visible)
    }

    func allVisibleSelected(visible: Set<UUID>) -> Bool {
        TaskBulkSelectionRules.allVisibleSelected(selectedIDs, visible: visible)
    }

    /// Done: leaves the mode. Refused while a batch is in flight (the Stop
    /// control owns cancellation), so the receipt can never disappear under
    /// the user.
    func end() {
        guard !busy else { return }
        isActive = false
        selectedIDs = []
        summary = nil
        clearPending()
    }

    // MARK: - Confirmation (frozen at request time)

    /// `runningImpact` is the existing `activeRuns` HINT (never claimed
    /// complete); the confirmation always states that a selected task's own
    /// running work stops first.
    func requestArchive(items: [TaskBulkItem], runningImpact: Int) {
        guard isActive, canRequestBatch, !items.isEmpty else { return }
        pendingDeleteItems = []
        confirmingDelete = false
        pendingArchiveItems = items
        pendingArchiveRunningImpact = runningImpact
        confirmingArchive = true
    }

    func requestDelete(items: [TaskBulkItem], runningImpact: Int) {
        guard isActive, canRequestBatch, !items.isEmpty else { return }
        pendingArchiveItems = []
        confirmingArchive = false
        pendingDeleteItems = items
        pendingDeleteRunningImpact = runningImpact
        confirmingDelete = true
    }

    func cancelArchiveConfirmation() {
        pendingArchiveItems = []
        pendingArchiveRunningImpact = 0
        confirmingArchive = false
    }

    func cancelDeleteConfirmation() {
        pendingDeleteItems = []
        pendingDeleteRunningImpact = 0
        confirmingDelete = false
    }

    /// Takes the frozen archive targets and closes the dialog.
    func takeFrozenArchiveTargets() -> [TaskBulkItem] {
        let items = pendingArchiveItems
        cancelArchiveConfirmation()
        return items
    }

    /// Takes the frozen delete targets and closes the dialog.
    func takeFrozenDeleteTargets() -> [TaskBulkItem] {
        let items = pendingDeleteItems
        cancelDeleteConfirmation()
        return items
    }

    // MARK: - Batch execution (canonical engine)

    /// Runs ONE frozen batch through the host-supplied canonical executor.
    /// Resolved items leave the selection; failed / unverified / not
    /// attempted items stay selected for a truthful retry. The host refresh
    /// happens before `busy` clears, so a second batch can never race the
    /// first and the list never shows a stale receipt.
    func run(
        operation: TaskBulkOperation,
        frozen items: [TaskBulkItem],
        execute: @escaping BatchExecute,
        afterRun: @escaping AfterBatch
    ) async {
        guard !busy, !items.isEmpty, lane.claim(self) else { return }
        busy = true
        summary = nil
        let token = TaskBulkCancellationToken()
        cancellation = token
        let result = await execute(operation, items, token)
        cancellation = nil
        apply(result)
        await afterRun()
        busy = false
        lane.release(self)
    }

    /// Cooperative stop between items only — the in-flight single-target
    /// command is never interrupted halfway (existing engine guarantee).
    func stopRunning() {
        cancellation?.cancel()
    }

    /// Applies one real batch receipt: resolved identities leave the
    /// selection, everything unresolved (failed, unverified, not attempted)
    /// stays actionable.
    func apply(_ result: TaskBulkSummary) {
        summary = result
        selectedIDs.subtract(result.removedIDs)
    }

    // MARK: - Confirmation copy

    var archiveConfirmationMessage: String {
        var text = TaskManagementCopy.archiveStopsRunningWork
        if pendingArchiveRunningImpact > 0 {
            text += "\n" + TaskManagementCopy.runningImpact(pendingArchiveRunningImpact)
        }
        return text
    }

    var deleteConfirmationMessage: String {
        var text = FloeL10n.l("chat.conversation_batch_management_view.the_task_and_its_private_workspace")
        text += "\n" + TaskManagementCopy.deleteStopsRunningWork
        if pendingDeleteRunningImpact > 0 {
            text += "\n" + TaskManagementCopy.runningImpact(pendingDeleteRunningImpact)
        }
        return text
    }

    private func clearPending() {
        pendingArchiveItems = []
        pendingDeleteItems = []
        pendingArchiveRunningImpact = 0
        pendingDeleteRunningImpact = 0
        confirmingArchive = false
        confirmingDelete = false
    }
}

/// Leading unselected / selected circle. Hidden until the mode is active;
/// the row itself carries the `.isSelected` trait and toggles on tap.
struct InlineSelectionCircle: View {
    let conversationID: UUID
    let isSelected: Bool

    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 20))
            .foregroundStyle(isSelected ? FloeTheme.primary : Color.secondary)
            .accessibilityLabel(InlineSelectionCopy.rowState(isSelected))
            .accessibilityIdentifier(InlineSelectionIdentifiers.circle(conversationID))
    }
}

/// LEGACY single-bar surface (still the Task Center host's control this
/// round; the corrected sidebar and Chat list use
/// `InlineConversationSelectionHeader` + `InlineConversationSelectionActionBar`
/// instead). Compact inline bottom bar: Done, scoped select-all, selected
/// count, and the archive / delete actions. Results appear as a quiet
/// receipt line above the controls while the selection stays for a retry.
struct InlineConversationSelectionBar: View {
    @ObservedObject var model: InlineConversationSelectionModel
    let center: ConversationCenter
    let visibleIDs: @MainActor () -> Set<UUID>
    let selectedItems: @MainActor () -> [TaskBulkItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let summary = model.summary, !summary.isEmpty {
                receiptLine(summary)
            }
            HStack(spacing: 12) {
                Button(InlineSelectionCopy.done) { model.end() }
                    .disabled(model.busy)
                    .accessibilityIdentifier(InlineSelectionIdentifiers.done)
                Button(model.allVisibleSelected(visible: visibleIDs())
                       ? InlineSelectionCopy.deselectAll
                       : InlineSelectionCopy.selectAll) {
                    model.toggleSelectAll(visible: visibleIDs())
                }
                .disabled(model.busy || visibleIDs().isEmpty)
                .accessibilityIdentifier(InlineSelectionIdentifiers.selectAll)
                Text(InlineSelectionCopy.selected(model.selectedCount))
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(InlineSelectionIdentifiers.count)
                Spacer(minLength: 8)
                Button(InlineSelectionCopy.archive) { request(.archive) }
                    .disabled(!model.canRequestBatch || model.selectedCount == 0)
                    .accessibilityIdentifier(InlineSelectionIdentifiers.archive)
                Button(InlineSelectionCopy.delete, role: .destructive) { request(.delete) }
                    .disabled(!model.canRequestBatch || model.selectedCount == 0)
                    .accessibilityIdentifier(InlineSelectionIdentifiers.delete)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    @ViewBuilder
    private func receiptLine(_ summary: TaskBulkSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(InlineSelectionResultCopy.text(for: summary))
                .font(.footnote)
            ForEach(summary.unresolvedItems) { result in
                Text("\(result.item.title) · \(result.outcome.issueText ?? "")")
                    .font(.caption)
                    .foregroundStyle(FloeTheme.destructive)
                    .lineLimit(2)
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

    private func request(_ operation: TaskBulkOperation) {
        let items = selectedItems()
        guard !items.isEmpty else { return }
        let impact = ConversationTaskBulkService(center: center)
            .runningCount(among: Set(items.map(\.id)))
        switch operation {
        case .archive:
            model.requestArchive(items: items, runningImpact: impact)
        case .delete:
            model.requestDelete(items: items, runningImpact: impact)
        case .restore:
            // Restore stays on the dedicated archive-management surfaces;
            // inline selection never offers it (active/archived scopes never
            // mix in one batch, same rule as the canonical page).
            break
        }
    }
}

// MARK: - Corrected selection chrome (header + compact two-row batch bar)

/// Selection mode header: the count, the visible-scoped select-all and Done.
/// Three compact controls in ONE native strip above the list — no oversized
/// drawn buttons, no second toolbar, nothing else competing for width.
struct InlineConversationSelectionHeader: View {
    @ObservedObject var model: InlineConversationSelectionModel
    let visibleIDs: @MainActor () -> Set<UUID>

    var body: some View {
        HStack(spacing: 8) {
            Text(InlineSelectionCopy.selected(model.selectedCount))
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityIdentifier(InlineSelectionIdentifiers.count)
            Spacer(minLength: 4)
            Button(model.allVisibleSelected(visible: visibleIDs())
                   ? InlineSelectionCopy.deselectAll
                   : InlineSelectionCopy.selectAll) {
                model.toggleSelectAll(visible: visibleIDs())
            }
            .disabled(model.busy || visibleIDs().isEmpty)
            .buttonStyle(.borderless)
            .accessibilityIdentifier(InlineSelectionIdentifiers.selectAll)
            Button(InlineSelectionCopy.done) { model.end() }
                .disabled(model.busy)
                .buttonStyle(.borderless)
                .accessibilityIdentifier(InlineSelectionIdentifiers.done)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// Pure placement rule for the batch bar: archive/delete act on any
/// selection; rename and move (which have no batch semantics) appear only
/// when EXACTLY one row is selected. Single source of truth for the view
/// and its regression tests.
enum InlineSelectionCommandScope {
    static func offersSingleItemCommands(selectedCount: Int) -> Bool { selectedCount == 1 }
    static func offersBatchCommands(selectedCount: Int) -> Bool { selectedCount > 0 }
}

/// One project the selection can move into (decoupled from workspace types).
struct InlineMoveTarget: Identifiable, Hashable {
    let id: UUID
    let name: String
}

/// Bottom batch area for the corrected surfaces: the receipt line plus AT
/// MOST two short rows — batch archive/delete, then rename / move when
/// exactly one row is selected. Never one overloaded horizontal row at
/// sidebar width; Done/select-all/count live in the header instead.
struct InlineConversationSelectionActionBar: View {
    @ObservedObject var model: InlineConversationSelectionModel
    let center: ConversationCenter
    let selectedItems: @MainActor () -> [TaskBulkItem]
    /// Host-owned presentation (rename sheet / move target list + command).
    /// A nil capability simply omits that control.
    var onRename: (@MainActor (UUID) -> Void)?
    var moveTargets: (@MainActor () -> [InlineMoveTarget])?
    var onMove: (@MainActor (UUID, UUID) -> Void)?

    private var singleSelectedID: UUID? {
        guard InlineSelectionCommandScope.offersSingleItemCommands(
            selectedCount: model.selectedCount) else { return nil }
        return model.selectedIDs.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let summary = model.summary, !summary.isEmpty {
                receiptLine(summary)
            }
            HStack(spacing: 12) {
                Button(InlineSelectionCopy.archive) { request(.archive) }
                    .disabled(!model.canRequestBatch
                              || !InlineSelectionCommandScope.offersBatchCommands(
                                  selectedCount: model.selectedCount))
                    .accessibilityIdentifier(InlineSelectionIdentifiers.archive)
                Button(InlineSelectionCopy.delete, role: .destructive) { request(.delete) }
                    .disabled(!model.canRequestBatch
                              || !InlineSelectionCommandScope.offersBatchCommands(
                                  selectedCount: model.selectedCount))
                    .accessibilityIdentifier(InlineSelectionIdentifiers.delete)
                Spacer(minLength: 8)
            }
            if let targetID = singleSelectedID {
                HStack(spacing: 12) {
                    if let onRename {
                        Button(InlineSelectionCopy.rename) { onRename(targetID) }
                            .disabled(model.busy)
                            .accessibilityIdentifier(InlineSelectionIdentifiers.rename)
                    }
                    if let moveTargets, let onMove {
                        let targets = moveTargets()
                        if targets.isEmpty {
                            Button(InlineSelectionCopy.noProjects) {}
                                .disabled(true)
                        } else {
                            Menu(InlineSelectionCopy.move) {
                                ForEach(targets) { target in
                                    Button(target.name) { onMove(targetID, target.id) }
                                }
                            }
                            .disabled(model.busy)
                            .accessibilityIdentifier(InlineSelectionIdentifiers.move)
                        }
                    }
                    Spacer(minLength: 8)
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    @ViewBuilder
    private func receiptLine(_ summary: TaskBulkSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(InlineSelectionResultCopy.text(for: summary))
                .font(.footnote)
            ForEach(summary.unresolvedItems) { result in
                Text("\(result.item.title) · \(result.outcome.issueText ?? "")")
                    .font(.caption)
                    .foregroundStyle(FloeTheme.destructive)
                    .lineLimit(2)
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

    private func request(_ operation: TaskBulkOperation) {
        let items = selectedItems()
        guard !items.isEmpty else { return }
        let impact = ConversationTaskBulkService(center: center)
            .runningCount(among: Set(items.map(\.id)))
        switch operation {
        case .archive:
            model.requestArchive(items: items, runningImpact: impact)
        case .delete:
            model.requestDelete(items: items, runningImpact: impact)
        case .restore:
            break
        }
    }
}

// MARK: - Corrected row long-press: native context menu

/// The single-row actions the context menu offers. Hosts supply their own
/// presentation state (rename sheets, delete confirmations) and the durable
/// commands through the center; the menu content itself is shared so every
/// corrected surface keeps the SAME item set and order (Pin/Unpin, Rename,
/// Move, Multi-select, Archive, Delete).
struct ConversationRowMenuActions {
    let isPinned: Bool
    let onPinToggle: @MainActor () -> Void
    let onRename: @MainActor () -> Void
    let moveTargets: @MainActor () -> [InlineMoveTarget]
    let onMove: @MainActor (UUID) -> Void
    let onMultiSelect: @MainActor () -> Void
    let onArchive: @MainActor () -> Void
    let onDelete: @MainActor () -> Void
}

extension View {
    /// Corrected long press: opens the NATIVE context menu — it must not
    /// enter selection directly; only the Multi-select item does, through
    /// `ConversationRowMenuActions.onMultiSelect` (host → `startMultiSelect`).
    /// While the mode is open the menu is suppressed entirely: rows are
    /// toggle targets then, and the single-task actions are the conflicting
    /// controls (same hiding rule the trailing ellipsis used before).
    @ViewBuilder
    func conversationRowContextMenu(
        selectionModel: InlineConversationSelectionModel,
        actions: ConversationRowMenuActions
    ) -> some View {
        if selectionModel.isActive {
            self
        } else {
            contextMenu {
                Button(action: actions.onPinToggle) {
                    Label(actions.isPinned ? InlineSelectionCopy.unpin : InlineSelectionCopy.pin,
                          systemImage: actions.isPinned ? "pin.slash" : "pin")
                }
                .accessibilityIdentifier(actions.isPinned
                    ? InlineSelectionIdentifiers.menuUnpin
                    : InlineSelectionIdentifiers.menuPin)
                Button(action: actions.onRename) {
                    Label(InlineSelectionCopy.rename, systemImage: "pencil")
                }
                .accessibilityIdentifier(InlineSelectionIdentifiers.menuRename)
                let targets = actions.moveTargets()
                if targets.isEmpty {
                    Button(InlineSelectionCopy.noProjects) {}
                        .disabled(true)
                        .accessibilityIdentifier(InlineSelectionIdentifiers.menuMove)
                } else {
                    Menu {
                        ForEach(targets) { target in
                            Button(target.name) { actions.onMove(target.id) }
                        }
                    } label: {
                        Label(InlineSelectionCopy.move, systemImage: "folder")
                    }
                    .accessibilityIdentifier(InlineSelectionIdentifiers.menuMove)
                }
                Button(action: actions.onMultiSelect) {
                    Label(InlineSelectionCopy.multiSelect, systemImage: "checkmark.circle")
                }
                .accessibilityIdentifier(InlineSelectionIdentifiers.menuMultiSelect)
                Button(action: actions.onArchive) {
                    Label(InlineSelectionCopy.archive, systemImage: "archivebox")
                }
                .accessibilityIdentifier(InlineSelectionIdentifiers.menuArchive)
                Button(role: .destructive, action: actions.onDelete) {
                    Label(InlineSelectionCopy.delete, systemImage: "trash")
                }
                .accessibilityIdentifier(InlineSelectionIdentifiers.menuDelete)
            }
        }
    }
}

/// The busy + Stop card while a frozen batch runs.
struct InlineSelectionBusyOverlay: View {
    let onStop: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(TaskManagementCopy.working)
                .font(.footnote).foregroundStyle(.secondary)
            Button(TaskManagementCopy.stopBatch) { onStop() }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(InlineSelectionIdentifiers.stop)
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Runs one batch on the EXISTING canonical service. A named MainActor
/// struct instead of a captured self-method: the executor closure must stay
/// @MainActor @Sendable-clean under Swift 6 strict concurrency.
@MainActor
struct InlineConversationBulkExecutor {
    let center: ConversationCenter

    func callAsFunction(
        _ operation: TaskBulkOperation,
        _ items: [TaskBulkItem],
        _ token: TaskBulkCancellationToken
    ) async -> TaskBulkSummary {
        await ConversationTaskBulkService(center: center)
            .run(operation: operation, items: items, cancellation: token)
    }
}

/// Shared confirmation dialogs + busy card for one inline selection surface.
/// The batch always routes through the existing `ConversationTaskBulkService`
/// (which composes the existing single-target lifecycle commands); hosts
/// only supply their own list refresh.
struct InlineConversationSelectionChromeModifier: ViewModifier {
    @ObservedObject var model: InlineConversationSelectionModel
    let center: ConversationCenter
    let afterRun: InlineConversationSelectionModel.AfterBatch

    private var executor: InlineConversationBulkExecutor {
        InlineConversationBulkExecutor(center: center)
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                Text("chat.conversation_batch_management_view.stop_and_archive_the_selected_tasks"),
                isPresented: Binding(
                    get: { model.confirmingArchive },
                    set: { presented in if !presented { model.cancelArchiveConfirmation() } }
                ),
                titleVisibility: .visible
            ) {
                Button("chat.conversation_batch_management_view.stop_and_archive") {
                    let items = model.takeFrozenArchiveTargets()
                    let executor = executor
                    Task { await model.run(
                        operation: .archive,
                        frozen: items,
                        execute: { operation, batch, token in
                            await executor(operation, batch, token)
                        },
                        afterRun: afterRun
                    ) }
                }
                .accessibilityIdentifier(InlineSelectionIdentifiers.confirmArchive)
                Button("action.cancel", role: .cancel) { model.cancelArchiveConfirmation() }
                    .accessibilityIdentifier(InlineSelectionIdentifiers.confirmCancel)
            } message: {
                Text(model.archiveConfirmationMessage)
            }
            .confirmationDialog(
                FloeL10n.l(
                    "chat.conversation_batch_management_view.delete_the_selected_tasks",
                    model.pendingDeleteItems.count
                ),
                isPresented: Binding(
                    get: { model.confirmingDelete },
                    set: { presented in if !presented { model.cancelDeleteConfirmation() } }
                ),
                titleVisibility: .visible
            ) {
                Button("workspace.workspace_canvas_view.delete", role: .destructive) {
                    let items = model.takeFrozenDeleteTargets()
                    let executor = executor
                    Task { await model.run(
                        operation: .delete,
                        frozen: items,
                        execute: { operation, batch, token in
                            await executor(operation, batch, token)
                        },
                        afterRun: afterRun
                    ) }
                }
                .accessibilityIdentifier(InlineSelectionIdentifiers.confirmDelete)
                Button("action.cancel", role: .cancel) { model.cancelDeleteConfirmation() }
            } message: {
                Text(model.deleteConfirmationMessage)
            }
            .overlay {
                if model.busy {
                    InlineSelectionBusyOverlay { model.stopRunning() }
                }
            }
    }
}

extension View {
    func inlineConversationSelectionChrome(
        model: InlineConversationSelectionModel,
        center: ConversationCenter,
        afterRun: @escaping InlineConversationSelectionModel.AfterBatch
    ) -> some View {
        modifier(InlineConversationSelectionChromeModifier(
            model: model, center: center, afterRun: afterRun))
    }

    /// A long press on a conversation row immediately enters (or extends)
    /// the inline selection WITHOUT navigating: the recognized gesture
    /// consumes the touch sequence, so the release does not commit a row
    /// tap / list selection, and movement past the small slop cancels the
    /// press so scrolling keeps working.
    func inlineSelectionLongPress(
        conversationID: UUID,
        model: InlineConversationSelectionModel
    ) -> some View {
        highPriorityGesture(
            LongPressGesture(
                minimumDuration: InlineSelectionTiming.longPressDuration,
                maximumDistance: InlineSelectionTiming.longPressMaximumDistance
            )
            .onEnded { _ in
                Task { @MainActor in
                    model.begin(with: conversationID)
                }
            }
        )
    }

    /// Row selection-state traits while the inline mode is open.
    @ViewBuilder
    func inlineSelectionRowTraits(
        model: InlineConversationSelectionModel,
        conversationID: UUID
    ) -> some View {
        let selected = model.isActive && model.selectedIDs.contains(conversationID)
        if selected {
            accessibilityAddTraits(.isSelected)
        } else {
            self
        }
    }
}
#endif
