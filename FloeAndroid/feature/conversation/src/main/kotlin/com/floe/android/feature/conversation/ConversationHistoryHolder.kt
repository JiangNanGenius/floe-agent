// SPDX-License-Identifier: MPL-2.0
//
// Caller-retained, RAM-only presentation holder for the Chat/history surface
// (⇄ ConversationListViewModel + ConversationListView selection state +
// ConversationBatchManagementView confirm/freeze/receipt logic).
//
// Search content and durable rows arrive ONLY as host projections (the shared
// Swift FTS authority answers CJK etc.); this holder keeps the query, the
// selection, the frozen confirmation targets and the batch receipt
// presentation. No SavedStateHandle, no Bundle, no persistence.

package com.floe.android.feature.conversation

import androidx.compose.runtime.MutableState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlin.jvm.JvmName

/** Which slice the management surface shows (⇄ ConversationBatchManagementView.Filter). */
enum class TaskManagementFilterUi { ACTIVE, ARCHIVED }

class ConversationHistoryHolder(
    private val host: ConversationUiCallbacks,
) {
    val state: MutableState<HistoryListUiState?> = mutableStateOf(null)

    /* ----------------------------- list presentation ----------------------------- */

    /** ⇄ searchText (user query text stays RAM-only; never logged). The
     * @set:JvmName avoids the property accessor clashing with the explicit
     * setSearchQuery() action (baseline "platform declaration clash"). */
    @set:JvmName("updateSearchQueryState")
    var searchQuery: String by mutableStateOf("")
        private set

    /** Monotonic search request epoch: the host echoes it into
     * HistoryListUiState.searchEpoch; pages from an older query are ignored. */
    private var searchEpoch = 0L

    /** ⇄ editMode.isEditing (the Chat list multi-select toggle). */
    var editModeActive: Boolean by mutableStateOf(false)
        private set

    /** ⇄ selectedIDs. */
    val selectedIds: MutableState<Set<String>> = mutableStateOf(emptySet())

    /** ⇄ pendingDeletion: the single-row delete dialog binds to this frozen
     * identity, so a list refresh cannot redirect it to another task. */
    val pendingDeletionId: MutableState<String?> = mutableStateOf(null)

    data class RenameDraft(val conversationId: String, val title: String, val requestToken: Long, val inFlight: Boolean = false, val failed: Boolean = false)
    private var renameSequence = 0L
    val pendingRename: MutableState<RenameDraft?> = mutableStateOf(null)

    fun requestRename(item: ConversationListItemUi) {
        if (pendingRename.value?.inFlight == true) return
        pendingRename.value = RenameDraft(item.id, item.title, ++renameSequence)
    }

    fun updateRenameTitle(title: String) {
        val draft = pendingRename.value ?: return
        // The original native rename applies its 120-grapheme normalization;
        // Kotlin UTF-16 truncation here would split emoji or CJK extensions.
        if (!draft.inFlight) pendingRename.value = draft.copy(title = title, failed = false)
    }

    fun cancelRename() { pendingRename.value = null }

    fun confirmRename(): Boolean {
        val draft = pendingRename.value ?: return false
        if (draft.inFlight || draft.title.isBlank()) return false
        pendingRename.value = draft.copy(inFlight = true, failed = false)
        if (host.renameConversation(draft.conversationId, draft.title.trim(), draft.requestToken)) return true
        pendingRename.value?.takeIf { it.requestToken == draft.requestToken }
            ?.let { pendingRename.value = it.copy(inFlight = false, failed = true) }
        return false
    }

    fun applyRenameOutcome(conversationId: String, requestToken: Long, accepted: Boolean) {
        val draft = pendingRename.value ?: return
        if (draft.conversationId != conversationId || draft.requestToken != requestToken || !draft.inFlight) return
        pendingRename.value = if (accepted) null else draft.copy(inFlight = false, failed = true)
    }

    /** ⇄ filter (tasks vs archive slice of the management surface). The
     * @set:JvmName avoids the property accessor clashing with the explicit
     * setManagementFilter() action (baseline "platform declaration clash"). */
    @set:JvmName("updateManagementFilterState")
    var managementFilter: TaskManagementFilterUi by mutableStateOf(TaskManagementFilterUi.ACTIVE)
        private set

    /** ⇄ confirmsArchive/confirmsDelete + pendingArchiveTargets/pendingDeleteTargets:
     * the EXACT frozen identities each confirmation was requested for. The
     * dialog's count and action use exactly this set, so a filter/search/
     * selection change while the dialog is open cannot redirect the
     * operation to different tasks than the one confirmed. */
    val confirmation: MutableState<TaskConfirmationUi?> = mutableStateOf(null)

    /** ⇄ busy/cancellation + summary for the management surface. */
    var bulkInFlight: Boolean by mutableStateOf(false)
        private set
    var bulkCancelToken: Long? = null
        private set
    val bulkReceipt: MutableState<BulkReceiptUi?> = mutableStateOf(null)

    /** ⇄ actionError (host-localized text). */
    var actionError: String? by mutableStateOf(null)
        private set

    /** ⇄ viewModel.isLoading gating comes from the projection. */
    fun load() = host.reloadHistory()

    fun applyHostState(next: HistoryListUiState) {
        // ⇄ searchContents guard: snippets land only for the exact query
        // generation that requested them (stale pages are dropped whole).
        if (next.searchEpoch != 0L && next.searchEpoch != searchEpoch) {
            // A page for an older query: keep the current results, ignore it.
            val current = state.value
            if (current != null) {
                state.value = current.copy(
                    isLoading = next.isLoading,
                    items = next.items,
                    archivedItems = next.archivedItems,
                    isSearching = next.isSearching,
                    needsProvider = next.needsProvider,
                    runningConversationIds = next.runningConversationIds,
                    bulkProgress = next.bulkProgress,
                    networkActionsAvailable = next.networkActionsAvailable,
                    // contentSnippets/searchEpoch stay as currently applied
                )
                pruneSelectionToVisible()
                return
            }
        }
        state.value = next
        pruneSelectionToVisible()
        // Frozen confirmation targets are deliberately NOT re-derived from
        // the live list: the dialog keeps exactly what the user saw.
        // A finished batch clears the in-flight latch via the receipt echo
        // (applyBulkReceipt); the progress projection is the visual source.
    }

    /* ------------------------------- query & search ------------------------------- */

    fun setSearchQuery(query: String) {
        searchQuery = query
        // Clear pending content matches for the OLD query immediately (⇄
        // contentMatches = [:] on query change), then request the new page.
        val current = state.value
        if (current != null) state.value = current.copy(contentSnippets = emptyMap())
        val trimmed = query.trim()
        if (trimmed.isEmpty()) {
            searchEpoch += 1 // the empty query owns the newest epoch (no page)
            return
        }
        searchEpoch += 1
        host.requestContentSearch(trimmed, searchEpoch)
    }

    fun currentSearchEpoch(): Long = searchEpoch

    /* --------------------------- visible slice (filtered) --------------------------- */

    /** ⇄ filteredConversations: title match OR content hit, in host order. */
    fun visibleItems(archivedFilter: Boolean = false): List<ConversationListItemUi> {
        val s = state.value ?: return emptyList()
        val pool = if (archivedFilter) s.archivedItems else s.items
        val query = searchQuery.trim()
        if (query.isEmpty()) return pool
        return pool.filter { ConversationSearchRules.isVisible(it, archivedFilter, query, s.contentSnippets) }
    }

    /** ⇄ visibleIDs + TaskBulkSelectionRules.pruned on every change. */
    private fun visibleIdSet(): Set<String> = visibleItems(managementFilter == TaskManagementFilterUi.ARCHIVED)
        .map { it.id }.toSet()

    private fun pruneSelectionToVisible() {
        selectedIds.value = TaskBulkSelectionRules.pruned(selectedIds.value, visibleIdSet())
    }

    fun toggleSelect(id: String) {
        selectedIds.value = TaskBulkSelectionRules.toggled(selectedIds.value, id)
    }

    fun toggleSelectAll() {
        selectedIds.value = TaskBulkSelectionRules.selectionAfterSelectAllToggle(
            selectedIds.value, visibleIdSet(),
        )
    }

    fun allVisibleSelected(): Boolean =
        TaskBulkSelectionRules.allVisibleSelected(selectedIds.value, visibleIdSet())

    fun cancelSelection() {
        selectedIds.value = emptySet()
        editModeActive = false
    }

    fun setEditMode(active: Boolean) {
        editModeActive = active
        if (!active) selectedIds.value = emptySet()
    }

    fun setManagementFilter(filter: TaskManagementFilterUi) {
        // Tasks and archive are disjoint scopes: a selection never crosses the
        // filter boundary and the previous batch receipt refers to the other
        // slice (⇄ onChange(of: filter)).
        managementFilter = filter
        selectedIds.value = emptySet()
        bulkReceipt.value = null
    }

    /* ----------------------------- navigation actions ----------------------------- */

    /** Row tap outside edit mode: a DIRECT user tap on the history surface,
     * so the source token is null (the host always navigates for it). */
    fun openConversation(id: String) {
        host.requestOpenConversation(null, id)
    }

    /** ⇄ createAndOpen: host creates the durable row and owns navigation. */
    fun createConversation(): ConversationFlowResult =
        if (host.createConversation()) ConversationFlowResult.Accepted
        else ConversationFlowResult.Rejected(ConversationRejectedReason.HOST_UNAVAILABLE)

    /* ------------------------------ confirmations ------------------------------ */

    /** ⇄ requestDelete(records): FREEZE the exact targets + the real running
     * impact before anything is dispatched; the dialog copy states both. */
    fun requestDeleteConfirmation() {
        val targets = selectedRecords()
        if (targets.isEmpty()) return
        confirmation.value = TaskConfirmationUi(
            operation = TaskBulkOperationUi.DELETE,
            frozenIds = targets.map { it.id },
            runningImpact = targets.count { it.id in (state.value?.runningConversationIds ?: emptySet()) },
        )
    }

    fun requestArchiveConfirmation() {
        val targets = selectedRecords()
        if (targets.isEmpty()) return
        confirmation.value = TaskConfirmationUi(
            operation = TaskBulkOperationUi.ARCHIVE,
            frozenIds = targets.map { it.id },
            runningImpact = targets.count { it.id in (state.value?.runningConversationIds ?: emptySet()) },
        )
    }

    fun requestSingleDeletion(id: String) {
        pendingDeletionId.value = id
    }

    fun cancelConfirmation() {
        confirmation.value = null
        pendingDeletionId.value = null
    }

    /** Dialog confirm → single-target delete (⇄ viewModel.delete(target)). */
    fun confirmSingleDeletion(): ConversationFlowResult {
        val id = pendingDeletionId.value ?: return ConversationFlowResult.Stale
        pendingDeletionId.value = null
        return if (host.deleteConversation(id)) ConversationFlowResult.Accepted
        else ConversationFlowResult.Rejected(ConversationRejectedReason.HOST_UNAVAILABLE)
    }

    /** ⇄ swipe archive (single row, no dialog on iOS). */
    fun archiveConversation(id: String): ConversationFlowResult =
        if (host.archiveConversation(id)) ConversationFlowResult.Accepted
        else ConversationFlowResult.Rejected(ConversationRejectedReason.HOST_UNAVAILABLE)

    fun restoreConversation(id: String): ConversationFlowResult =
        if (host.restoreConversation(id)) ConversationFlowResult.Accepted
        else ConversationFlowResult.Rejected(ConversationRejectedReason.HOST_UNAVAILABLE)

    /* --------------------------------- bulk ops --------------------------------- */

    /** ⇄ perform(operation, targets): uses the FROZEN set, never the live
     * selection at execution time. */
    fun confirmBulkFromDialog(): ConversationFlowResult {
        val pending = confirmation.value ?: return ConversationFlowResult.Stale
        confirmation.value = null
        return runBulk(pending.operation, pending.frozenIds)
    }

    /** Archived restore is a direct command (⇄ restore button: no dialog). */
    fun restoreSelected(): ConversationFlowResult {
        val ids = selectedRecords().map { it.id }
        if (ids.isEmpty()) return ConversationFlowResult.Rejected(ConversationRejectedReason.INPUT_INSUFFICIENT)
        return runBulk(TaskBulkOperationUi.RESTORE, ids)
    }

    private fun runBulk(operation: TaskBulkOperationUi, frozenIds: List<String>): ConversationFlowResult {
        if (bulkInFlight) return ConversationFlowResult.Rejected(ConversationRejectedReason.OPERATION_IN_FLIGHT)
        if (frozenIds.isEmpty()) return ConversationFlowResult.Rejected(ConversationRejectedReason.INPUT_INSUFFICIENT)
        val token = nextBulkToken
        nextBulkToken += 1
        val started = host.requestBulk(operation, frozenIds, token)
        if (!started) return ConversationFlowResult.Rejected(ConversationRejectedReason.HOST_UNAVAILABLE)
        bulkCancelToken = token
        bulkInFlight = true
        bulkReceipt.value = null
        return ConversationFlowResult.Accepted
    }

    private var nextBulkToken = 1L

    /** ⇄ busyOverlay's Stop: cooperative cancellation between items; the
     * receipt will show what ran, what did not. */
    fun cancelBulk() {
        val token = bulkCancelToken ?: return
        host.cancelBulk(token)
    }

    /** Host publishes the finished batch receipt for the active token. */
    fun applyBulkReceipt(receipt: BulkReceiptUi) {
        bulkInFlight = false
        bulkCancelToken = null
        bulkReceipt.value = receipt
        // Resolved items leave the selection from the REAL per-item results;
        // unresolved ones stay selected for a truthful retry.
        selectedIds.value = selectedIds.value - receipt.removedIds
        pruneSelectionToVisible()
    }

    private fun selectedRecords(): List<ConversationListItemUi> {
        val s = state.value ?: return emptyList()
        val pool = if (managementFilter == TaskManagementFilterUi.ARCHIVED) s.archivedItems else s.items
        return pool.filter { it.id in selectedIds.value }
    }

    fun dismissActionError() { actionError = null }

    /** Host publishes a typed failure from a real settlement (never a guess). */
    fun applyActionError(code: String) {
        actionError = code
    }

    /** The surface left the screen: drop transient selection/confirm state;
     * durable rows are untouched. */
    fun closeManagement() {
        pendingRename.value = null
        confirmation.value = null
        pendingDeletionId.value = null
        bulkReceipt.value = null
        selectedIds.value = emptySet()
        editModeActive = false
    }
}

/** ⇄ The frozen confirmation request (targets + honest running impact). */
data class TaskConfirmationUi(
    val operation: TaskBulkOperationUi,
    val frozenIds: List<String>,
    val runningImpact: Int,
)

/** ⇄ ConversationBatchManagementView row: displayTitle fallback. */
fun conversationDisplayTitle(item: ConversationListItemUi, untitledLabel: String): String =
    if (item.title.isEmpty()) untitledLabel else item.title
