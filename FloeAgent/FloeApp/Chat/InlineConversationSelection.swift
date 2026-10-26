// FloeApp — Inline conversation selection (long press selects in place).
//
// SPDX-License-Identifier: MPL-2.0
//
// The conversation surfaces (app sidebar, Chat tab list, Task Center
// overview) share ONE lightweight multi-select state: a long press on a
// conversation immediately selects it and reveals leading unselected /
// selected circles INSIDE the original list — it never opens a management
// sheet. Bulk archive/delete route through the existing
// `ConversationTaskBulkService` / `TaskBulkRunner` engine (frozen
// confirmation targets, cooperative stop between items, truthful per-item
// results, unresolved items stay selected for a retry) — the same engine
// the dedicated management pages use. There is no second store, queue or
// permission path here.
//
// Scope discipline: selection suspends row navigation only. It never touches
// `AppRouter`, the outer split navigation, the running conversation or the
// temporary-session lifecycle. Successful changes flow through the center's
// existing reload / router reconciliation, so list, active selection and
// navigation refresh with real state — nothing is fabricated.

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

    /// Long press entry: immediately activates and selects the pressed row
    /// (or toggles it when the mode is already open). `begin(with: nil)` is
    /// the explicit "Manage" entry: activates with an empty selection.
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

/// Compact inline bottom bar: Done, scoped select-all, selected count, and
/// the archive / delete actions. Results appear as a quiet receipt line
/// above the controls while the selection stays for a retry.
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
