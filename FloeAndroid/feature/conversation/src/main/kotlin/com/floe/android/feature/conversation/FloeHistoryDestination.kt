// SPDX-License-Identifier: MPL-2.0
//
// Conversation history surfaces (⇄ ConversationListView.swift +
// ArchivedConversationsView + ConversationBatchManagementView +
// ConversationListViewModel + TaskBulkManagement presentation state).
//
// One destination with three modes: LIST (Chat tab root), ARCHIVE (the
// archived slice with restore/permanent delete), MANAGE (the canonical task
// management screen with select-all scoped to the visible slice, frozen
// confirmation targets and truthful per-item receipts). All mutations are
// host effects over the EXISTING single-target lifecycle commands; this
// module never deletes/archives by itself and never re-derives durable rows.
// Search content is the host FTS projection (CJK included); title matching
// is the local rule. Wide layout = a list column inside the host shell;
// compact = full width. The module owns no navigation rail or scaffold.

package com.floe.android.feature.conversation

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeChipMenu
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeConfirmDialog
import com.floe.android.design.CupertinoMenuEntry
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloeSearchField
import com.floe.android.design.FloeSelectionSlot
import com.floe.android.design.FloeSegmented
import com.floe.android.design.FloeText
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloeSheetPlacement
import com.floe.android.design.FloeSettingsSectionCard
import com.floe.android.design.FloeFormTextField
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeToolbar
import com.floe.android.design.FloeUnavailableView
import com.floe.android.design.IconGlyph

enum class HistoryDestinationMode { LIST, ARCHIVE, MANAGE }

@Composable
fun FloeConversationHistoryDestination(
    holder: ConversationHistoryHolder,
    mode: HistoryDestinationMode = HistoryDestinationMode.LIST,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    onOpenArchive: () -> Unit = {},
    onOpenManagement: () -> Unit = {},
) {
    val state = holder.state.value
    val untitled = stringResource(R.string.history_untitled)
    val title = stringResource(
        when (mode) {
            HistoryDestinationMode.LIST -> R.string.history_title
            HistoryDestinationMode.ARCHIVE -> R.string.history_archive_title
            HistoryDestinationMode.MANAGE -> R.string.history_manage_title
        }
    )
    val needsProvider = state?.needsProvider == true

    Column(modifier = modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
        HistoryToolbar(
            holder = holder,
            mode = mode,
            title = title,
            onBack = onBack,
            onOpenArchive = onOpenArchive,
            onOpenManagement = onOpenManagement,
        )
        FloeDivider()

        // ⇄ errorBanner: the host already publishes ONLY a REAL typed
        // settlement code into holder.actionError (a rejected/failed
        // archive/delete/rename, or "revision_unavailable"/
        // "runtime_unavailable" for a refusal before dispatch). The surface
        // shows that existing truth; it re-derives nothing and never claims
        // an outcome the host did not report.
        holder.actionError?.let { code ->
            InlineBanner(
                icon = FloeIcons.XOctagon,
                text = historyActionErrorText(code),
                tint = Floe.colors.destructive,
                onDismiss = holder::dismissActionError,
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
            )
        }

        // Search field: LIST and MANAGE both expose it (ARCHIVE keeps the
        // simpler archive list, matching the native archived sheet).
        if (mode != HistoryDestinationMode.ARCHIVE) {
            FloeSearchField(
                value = holder.searchQuery,
                onValueChange = holder::setSearchQuery,
                placeholder = stringResource(R.string.history_search_hint),
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
            )
        }
        if (mode == HistoryDestinationMode.MANAGE) {
            FloeSegmented(
                options = listOf(
                    stringResource(R.string.history_filter_tasks),
                    stringResource(R.string.history_filter_archive),
                ),
                selectedIndex = if (holder.managementFilter == TaskManagementFilterUi.ARCHIVED) 1 else 0,
                onSelect = { index ->
                    holder.setManagementFilter(
                        if (index == 0) TaskManagementFilterUi.ACTIVE else TaskManagementFilterUi.ARCHIVED
                    )
                },
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
            )
        }

        val archivedFilter = when (mode) {
            HistoryDestinationMode.ARCHIVE -> true
            HistoryDestinationMode.MANAGE -> holder.managementFilter == TaskManagementFilterUi.ARCHIVED
            HistoryDestinationMode.LIST -> false
        }
        // ⇄ summarySection: the last batch receipt stays visible above the
        // slice it belongs to (filter changes clear it in the holder).
        holder.bulkReceipt.value?.let { receipt ->
            if (mode == HistoryDestinationMode.MANAGE) BulkReceiptSummary(receipt)
        }
        val rows = holder.visibleItems(archivedFilter)
        val searching = state?.isSearching == true && holder.searchQuery.isNotBlank()
        // Local non-null capture so the branch bodies can read projection
        // fields without relying on smart casts across `when` branches.
        val loaded = state
        val contentSnippets = loaded?.contentSnippets ?: emptyMap()
        val initialLoading = loaded != null &&
            loaded.isLoading && loaded.items.isEmpty() && loaded.archivedItems.isEmpty()

        Box(modifier = Modifier.weight(1f)) {
            when {
                loaded == null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    FloeActivityIndicator(description = stringResource(R.string.loading_cd))
                }
                initialLoading ->
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        FloeActivityIndicator(description = stringResource(R.string.loading_cd))
                    }
                rows.isEmpty() && holder.searchQuery.isNotBlank() && !searching ->
                    FloeUnavailableView(
                        icon = FloeIcons.Magnifier,
                        title = stringResource(R.string.history_search_no_results),
                        description = holder.searchQuery,
                    )
                rows.isEmpty() && archivedFilter ->
                    FloeUnavailableView(
                        icon = FloeIcons.BookPages,
                        title = stringResource(R.string.history_archive_empty_title),
                        description = stringResource(R.string.history_archive_empty_hint),
                    )
                rows.isEmpty() && needsProvider ->
                    FloeUnavailableView(
                        icon = FloeIcons.Antenna,
                        title = stringResource(R.string.history_needs_provider_title),
                        description = stringResource(R.string.add_provider_hint),
                    )
                rows.isEmpty() ->
                    FloeUnavailableView(
                        icon = FloeIcons.Bubble,
                        title = stringResource(R.string.history_empty_title),
                        description = stringResource(R.string.history_empty_hint),
                    )
                else -> LazyColumn(
                    contentPadding = PaddingValues(horizontal = 8.dp, vertical = 4.dp),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    items(rows, key = { it.id }) { item ->
                        HistoryRow(
                            item = item,
                            title = conversationDisplayTitle(item, untitled),
                            snippet = contentSnippets[item.id],
                            selectionMode = mode == HistoryDestinationMode.MANAGE ||
                                (mode == HistoryDestinationMode.LIST && holder.editModeActive),
                            selected = item.id in holder.selectedIds.value,
                            mode = mode,
                            onTap = {
                                if (mode == HistoryDestinationMode.LIST && holder.editModeActive) {
                                    holder.toggleSelect(item.id)
                                } else if (mode == HistoryDestinationMode.MANAGE) {
                                    holder.toggleSelect(item.id)
                                } else {
                                    holder.openConversation(item.id)
                                }
                            },
                            onArchive = { holder.archiveConversation(item.id) },
                            onRestore = { holder.restoreConversation(item.id) },
                            onRequestDelete = { holder.requestSingleDeletion(item.id) },
                            onRename = { holder.requestRename(item) },
                            onSelectMultiple = {
                                holder.setEditMode(true)
                                holder.toggleSelect(item.id)
                            },
                        )
                    }
                }
            }
            if (searching) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(12.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    FloeActivityIndicator()
                    FloeText(stringResource(R.string.history_searching), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                }
            }
        }

        if (mode == HistoryDestinationMode.MANAGE) {
            ManagementBottomBar(holder)
        } else if (mode == HistoryDestinationMode.LIST && holder.editModeActive) {
            ListSelectionBar(holder)
        }
        state?.bulkProgress?.let { progress ->
            BulkBusyOverlay(holder, progress)
        }
    }

    holder.pendingRename.value?.let { draft ->
        val wide = LocalConfiguration.current.screenWidthDp >= 700
        FloePageSheet(
            visible = true,
            onDismiss = { holder.cancelRename() },
            widthFraction = if (wide) 0.6f else 1f,
            heightFraction = if (wide) 0.5f else 0.8f,
            placement = if (wide) FloeSheetPlacement.CENTER else FloeSheetPlacement.BOTTOM,
        ) {
            Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                FloeText(stringResource(R.string.history_rename_title), style = Floe.typography.section)
                FloeSettingsSectionCard(title = null) {
                    FloeFormTextField(
                        label = stringResource(R.string.history_rename_name),
                        value = draft.title,
                        onValueChange = holder::updateRenameTitle,
                        enabled = !draft.inFlight,
                    )
                }
                if (draft.failed) {
                    FloeText(stringResource(R.string.history_rename_failed), color = Floe.colors.pending)
                }
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    FloeCapsuleAction(
                        label = stringResource(R.string.history_rename_save),
                        enabled = !draft.inFlight && draft.title.isNotBlank(),
                        onClick = { holder.confirmRename() },
                    )
                    FloeCapsuleAction(
                        label = stringResource(R.string.action_cancel),
                        onClick = { holder.cancelRename() },
                    )
                    if (draft.inFlight) FloeActivityIndicator()
                }
            }
        }
    }

    // Confirmations + receipts (management mode owns the bulk dialogs).
    holder.confirmation.value?.let { confirmation ->
        BulkConfirmationDialog(holder, confirmation)
    }
    holder.pendingDeletionId.value?.let {
        FloeConfirmDialog(
            title = stringResource(R.string.history_delete_confirm_title),
            message = stringResource(R.string.history_delete_confirm_message),
            confirmLabel = stringResource(R.string.action_delete),
            dismissLabel = stringResource(R.string.action_cancel),
            onConfirm = { holder.confirmSingleDeletion() },
            onDismiss = { holder.cancelConfirmation() },
        )
    }
}

/* --------------------------------- toolbar ---------------------------------- */

/** Closed-set localization for the REAL typed settlement code published by
 * the host ([ConversationHistoryHolder.applyActionError]). The exact wire
 * code stays in the holder/diagnostics; the ordinary surface says what
 * happened and what the user can do, and unknown codes get the honest
 * generic line — nothing is ever presented as success here. */
@Composable
private fun historyActionErrorText(code: String): String = when (code) {
    "staleRevision" -> stringResource(R.string.history_action_failed_stale)
    "revision_unavailable", "runtime_unavailable", "runtimeUnavailable",
    "exchangeUnavailable" -> stringResource(R.string.history_action_failed_unavailable)
    else -> stringResource(R.string.history_action_failed)
}

@Composable
private fun HistoryToolbar(
    holder: ConversationHistoryHolder,
    mode: HistoryDestinationMode,
    title: String,
    onBack: (() -> Unit)?,
    onOpenArchive: () -> Unit,
    onOpenManagement: () -> Unit,
) {
    val newLabel = stringResource(R.string.history_new)
    val archiveLabel = stringResource(R.string.history_archive_title)
    val manageLabel = stringResource(R.string.history_manage_title)
    val closeLabel = stringResource(R.string.action_cancel)
    FloeToolbar(
        title = title,
        navigation = onBack?.let { back ->
            {
                FloeCircleButton(
                    icon = FloeIcons.ChevronBack,
                    contentDescription = stringResource(R.string.action_back),
                    onClick = back,
                    hairline = false,
                )
            }
        },
        actions = {
            if (mode == HistoryDestinationMode.LIST) {
                if (holder.editModeActive) {
                    // Selection mode: the visible exit (⇄ editMode.inactive).
                    val cancelLabel = stringResource(R.string.action_cancel)
                    Box(
                        modifier = Modifier
                            .heightIn(min = FloeLayout.MinimumTarget)
                            .clickable { holder.cancelSelection() }
                            .padding(horizontal = 10.dp)
                            .semantics { contentDescription = cancelLabel },
                        contentAlignment = Alignment.Center,
                    ) { FloeText(cancelLabel, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel) }
                } else {
                    Box(
                        modifier = Modifier
                            .heightIn(min = FloeLayout.MinimumTarget)
                            .clickable(onClick = onOpenManagement)
                            .padding(horizontal = 10.dp)
                            .semantics { contentDescription = manageLabel },
                        contentAlignment = Alignment.Center,
                    ) { FloeText(manageLabel, style = Floe.typography.metadata, color = Floe.colors.label) }
                }
                Box(
                    modifier = Modifier
                        .heightIn(min = FloeLayout.MinimumTarget)
                        .clickable(onClick = onOpenArchive)
                        .padding(horizontal = 10.dp)
                        .semantics { contentDescription = archiveLabel },
                    contentAlignment = Alignment.Center,
                ) { IconGlyph(FloeIcons.BookPages, Floe.colors.label, 18.dp) }
                Box(
                    modifier = Modifier
                        .heightIn(min = FloeLayout.MinimumTarget)
                        // G05-R3 first use: a durable ordinary task row needs
                        // NO provider — creation is the existing real
                        // `conversation.create` ownership API and a model run
                        // stays gated where it already is. A pre-dispatch
                        // refusal (conversation domain not ready) is the only
                        // typed rejection this button can produce; it settles
                        // honestly through the SAME error banner instead of a
                        // disabled control, so a fresh no-provider user can
                        // open a task and reach the manual terminal from its
                        // Thread options.
                        .clickable {
                            if (holder.createConversation() is
                                ConversationFlowResult.Rejected
                            ) {
                                holder.applyActionError("runtime_unavailable")
                            }
                        }
                        .padding(horizontal = 10.dp)
                        .semantics { contentDescription = newLabel },
                    contentAlignment = Alignment.Center,
                ) { IconGlyph(FloeIcons.NewTask, Floe.colors.accent, 20.dp) }
            } else if (mode == HistoryDestinationMode.MANAGE) {
                val selectAllLabel = if (holder.allVisibleSelected()) {
                    stringResource(R.string.history_deselect_all)
                } else {
                    stringResource(R.string.history_select_all)
                }
                Box(
                    modifier = Modifier
                        .heightIn(min = FloeLayout.MinimumTarget)
                        .clickable { holder.toggleSelectAll() }
                        .padding(horizontal = 10.dp)
                        .semantics { contentDescription = selectAllLabel },
                    contentAlignment = Alignment.Center,
                ) { FloeText(selectAllLabel, style = Floe.typography.metadata, color = Floe.colors.accent) }
                if (holder.selectedIds.value.isNotEmpty()) {
                    Box(
                        modifier = Modifier
                            .heightIn(min = FloeLayout.MinimumTarget)
                            .clickable { holder.cancelSelection() }
                            .padding(horizontal = 10.dp)
                            .semantics { contentDescription = closeLabel },
                        contentAlignment = Alignment.Center,
                    ) { FloeText(closeLabel, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel) }
                }
            }
        },
    )
}

/* ----------------------------------- row ------------------------------------ */

@Composable
private fun HistoryRow(
    item: ConversationListItemUi,
    title: String,
    snippet: String?,
    selectionMode: Boolean,
    selected: Boolean,
    mode: HistoryDestinationMode,
    onTap: () -> Unit,
    onArchive: () -> Unit,
    onRestore: () -> Unit,
    onRequestDelete: () -> Unit,
    onRename: () -> Unit,
    onSelectMultiple: () -> Unit,
) {
    val colors = Floe.colors
    var menuExpanded by remember(item.id) { mutableStateOf(false) }
    val rowShape = RoundedCornerShape(10.dp)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = FloeLayout.MinimumTarget)
            .clip(rowShape)
            .background(if (selected) colors.accent.copy(alpha = 0.12f) else colors.readingSurface)
            .clickable(onClick = onTap)
            .padding(horizontal = 6.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        if (selectionMode) {
            FloeSelectionSlot(
                checked = selected,
                onCheckedChange = { onTap() },
                description = title,
            )
        }
        Column(modifier = Modifier.weight(1f)) {
            FloeText(title, style = Floe.typography.body, color = colors.label, maxLines = 1, overflow = TextOverflow.Ellipsis)
            snippet?.let {
                FloeText(it, style = Floe.typography.metadata, color = colors.secondaryLabel, maxLines = 3, overflow = TextOverflow.Ellipsis)
            }
            FloeText(
                item.updatedAtLabel,
                style = Floe.typography.metadata,
                color = colors.secondaryLabel,
            )
        }
        item.projectedStateName?.let { stateName ->
            ActivityBadge(stateName)
        }
        if (!selectionMode) {
            Box {
                val menuCd = stringResource(R.string.history_row_actions)
                Box(
                    modifier = Modifier
                        .heightIn(min = FloeLayout.MinimumTarget)
                        .clickable { menuExpanded = true }
                        .padding(horizontal = 6.dp)
                        .semantics { contentDescription = menuCd },
                    contentAlignment = Alignment.Center,
                ) { IconGlyph(FloeIcons.ChevronUpDown, colors.secondaryLabel, 16.dp) }
                FloeChipMenu(expanded = menuExpanded, onDismiss = { menuExpanded = false }) {
                    CupertinoMenuEntry(
                        title = stringResource(R.string.history_rename_title),
                        selected = false,
                        onClick = { menuExpanded = false; onRename() },
                    )
                    when (mode) {
                        HistoryDestinationMode.ARCHIVE -> {
                            CupertinoMenuEntry(
                                title = stringResource(R.string.history_restore_action),
                                selected = false,
                                onClick = { menuExpanded = false; onRestore() },
                            )
                            CupertinoMenuEntry(
                                title = stringResource(R.string.history_delete_forever),
                                selected = false,
                                onClick = { menuExpanded = false; onRequestDelete() },
                            )
                        }
                        else -> {
                            CupertinoMenuEntry(
                                title = stringResource(R.string.history_select_multiple),
                                selected = false,
                                onClick = { menuExpanded = false; onSelectMultiple() },
                            )
                            CupertinoMenuEntry(
                                title = stringResource(R.string.history_archive_action),
                                selected = false,
                                onClick = { menuExpanded = false; onArchive() },
                            )
                            CupertinoMenuEntry(
                                title = stringResource(R.string.action_delete),
                                selected = false,
                                onClick = { menuExpanded = false; onRequestDelete() },
                            )
                        }
                    }
                }
            }
        }
    }
}

/** ⇄ ConversationActivityBadge: spinner for loading states, warning/check
 * glyphs otherwise; the color is the shared run-state role mapping. */
@Composable
private fun ActivityBadge(stateName: String) {
    val role = FloeRunStateLocalizer.colorRole(stateName)
    val tint = floeStatusColor(role)
    when {
        FloeRunStateLocalizer.isLoading(stateName, hasError = false) -> FloeActivityIndicator()
        FloeRunStateLocalizer.attentionSymbolKey(stateName) != null -> IconGlyph(FloeIcons.WarningTriangle, tint, 14.dp)
        stateName == "completed" -> IconGlyph(FloeIcons.Checkmark, tint, 14.dp)
        else -> Unit
    }
}

/* ------------------------------- management bar ------------------------------- */

@Composable
private fun ManagementBottomBar(holder: ConversationHistoryHolder) {
    val selected = holder.selectedIds.value
    val count = selected.size
    val archivedSlice = holder.managementFilter == TaskManagementFilterUi.ARCHIVED
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(Floe.colors.groupedSurface)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (count == 0) {
            FloeText(
                stringResource(R.string.history_select_hint),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
        } else {
            FloeText(
                stringResource(R.string.history_selected_count, count),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
            Spacer(Modifier.weight(1f))
            if (archivedSlice) {
                ActionChip(
                    label = stringResource(R.string.history_restore_action),
                    enabled = !holder.bulkInFlight,
                    prominent = false,
                ) { holder.restoreSelected() }
            } else {
                ActionChip(
                    label = stringResource(R.string.history_archive_action),
                    enabled = !holder.bulkInFlight,
                    prominent = false,
                ) { holder.requestArchiveConfirmation() }
            }
            ActionChip(
                label = stringResource(R.string.action_delete),
                enabled = !holder.bulkInFlight,
                prominent = false,
                destructive = true,
            ) { holder.requestDeleteConfirmation() }
        }
    }
}

@Composable
private fun ListSelectionBar(holder: ConversationHistoryHolder) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(Floe.colors.groupedSurface)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        FloeText(
            stringResource(R.string.history_selected_count, holder.selectedIds.value.size),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
        Spacer(Modifier.weight(1f))
        ActionChip(
            label = stringResource(R.string.history_archive_action),
            enabled = holder.selectedIds.value.isNotEmpty() && !holder.bulkInFlight,
            prominent = false,
        ) { holder.requestArchiveConfirmation() }
        ActionChip(
            label = stringResource(R.string.action_delete),
            enabled = holder.selectedIds.value.isNotEmpty() && !holder.bulkInFlight,
            prominent = false,
            destructive = true,
        ) { holder.requestDeleteConfirmation() }
    }
}

@Composable
private fun ActionChip(
    label: String,
    enabled: Boolean,
    prominent: Boolean,
    destructive: Boolean = false,
    onClick: () -> Unit,
) {
    val shape = RoundedCornerShape(9.dp)
    Box(
        modifier = Modifier
            .heightIn(min = FloeLayout.MinimumTarget)
            .clip(shape)
            .background(
                when {
                    !enabled -> Floe.colors.fillTertiary
                    destructive -> Floe.colors.destructive
                    prominent -> Floe.colors.accent
                    else -> Floe.colors.sectionCardSurface
                }
            )
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 8.dp)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        FloeText(
            label,
            style = Floe.typography.metadata,
            color = when {
                !enabled -> Floe.colors.tertiaryLabel
                destructive || prominent -> Floe.colors.readingSurface
                else -> Floe.colors.label
            },
        )
    }
}

/* ------------------------------- confirmations ------------------------------- */

@Composable
private fun BulkConfirmationDialog(holder: ConversationHistoryHolder, confirmation: TaskConfirmationUi) {
    val archive = confirmation.operation == TaskBulkOperationUi.ARCHIVE
    val count = confirmation.frozenIds.size
    val baseMessage = if (archive) {
        stringResource(R.string.history_archive_confirm_message)
    } else {
        stringResource(R.string.history_delete_confirm_message)
    }
    val message = if (confirmation.runningImpact > 0) {
        baseMessage + "\n" + stringResource(R.string.history_running_impact, confirmation.runningImpact)
    } else {
        baseMessage
    }
    FloeConfirmDialog(
        title = if (archive) {
            stringResource(R.string.history_archive_confirm_title, count)
        } else {
            stringResource(R.string.history_delete_confirm_title) // selection count is in the message
        },
        message = message,
        confirmLabel = stringResource(if (archive) R.string.history_archive_action else R.string.action_delete),
        dismissLabel = stringResource(R.string.action_cancel),
        onConfirm = { holder.confirmBulkFromDialog() },
        onDismiss = { holder.cancelConfirmation() },
    )
}

/* -------------------------------- busy overlay ------------------------------- */

@Composable
private fun BulkBusyOverlay(holder: ConversationHistoryHolder, progress: BulkProgressUi) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(Floe.colors.pending.copy(alpha = 0.10f))
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        FloeActivityIndicator()
        FloeText(
            stringResource(R.string.history_working, progress.doneCount, progress.totalCount),
            style = Floe.typography.metadata,
            color = Floe.colors.label,
            modifier = Modifier.weight(1f),
        )
        ActionChip(
            label = stringResource(R.string.history_stop_batch),
            enabled = true,
            prominent = false,
        ) { holder.cancelBulk() }
    }
}

/* -------------------------------- receipts ---------------------------------- */

/** ⇄ summarySection: the batch receipt line + unresolved item reasons and the
 * cancel/retry notes. Rendered above the list when present. */
@Composable
fun BulkReceiptSummary(receipt: BulkReceiptUi, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .background(Floe.colors.groupedSurface)
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        val parts = buildList {
            if (receipt.archivedCount > 0) add(stringResource(R.string.bulk_result_archived, receipt.archivedCount))
            if (receipt.restoredCount > 0) add(stringResource(R.string.bulk_result_restored, receipt.restoredCount))
            if (receipt.deletedCount > 0) add(stringResource(R.string.bulk_result_deleted, receipt.deletedCount))
            if (receipt.skippedCount > 0) add(stringResource(R.string.bulk_result_skipped, receipt.skippedCount))
            if (receipt.failedCount > 0) add(stringResource(R.string.bulk_result_failed, receipt.failedCount))
            if (receipt.unverifiedCount > 0) add(stringResource(R.string.bulk_result_unverified, receipt.unverifiedCount))
            if (receipt.notAttemptedCount > 0) add(stringResource(R.string.bulk_result_not_attempted, receipt.notAttemptedCount))
        }
        FloeText(parts.joinToString(" · "), style = Floe.typography.metadata, color = Floe.colors.label)
        receipt.unresolvedItems.forEach { result ->
            FloeText(
                "${result.title} · ${result.outcome.issueText.orEmpty()}",
                style = Floe.typography.metadata,
                color = Floe.colors.destructive,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (receipt.wasCancelled) {
            FloeText(stringResource(R.string.bulk_cancelled_note), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
        } else if (receipt.retainedIds.isNotEmpty()) {
            FloeText(stringResource(R.string.bulk_keep_failed_note), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
        }
    }
}
