// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.canvas.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActionSheet
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeBadgePill
import com.floe.android.design.FloeBadgeTone
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeConfirmDialog
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloeSearchField
import com.floe.android.design.FloeText
import com.floe.android.design.FloeUnavailableView
import com.floe.android.design.IconGlyph
import com.floe.android.feature.canvas.CanvasProjectSummary
import com.floe.android.feature.canvas.CreativeAvailability
import com.floe.android.feature.canvas.ui.api.CanvasPickedSource
import com.floe.android.feature.canvas.ui.state.CanvasWorkspaceSession
import kotlinx.coroutines.launch

/**
 * Public Canvas library + editor entry.
 *
 * Content-only surface: the App's existing Creative destination owns the
 * toolbar and tab selection. Opening an editor presents a feature-owned
 * full-window cover (inside this module) while the library stays behind it.
 */
@Composable
fun FloeCanvasLibrary(
    session: CanvasWorkspaceSession,
    pickImage: suspend () -> CanvasPickedSource?,
    modifier: Modifier = Modifier,
) {
    LaunchedEffect(session) { session.start() }
    val editor = session.editor
    if (editor != null) {
        CanvasEditorCover(session = session, editor = editor, pickImage = pickImage)
        return
    }
    CanvasLibraryContent(session = session, pickImage = pickImage, modifier = modifier)
}

@Composable
private fun CanvasLibraryContent(
    session: CanvasWorkspaceSession,
    pickImage: suspend () -> CanvasPickedSource?,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    var query by remember { mutableStateOf("") }
    var nameDialog by remember { mutableStateOf<CanvasNameDialog?>(null) }
    var deleteTarget by remember { mutableStateOf<CanvasProjectSummary?>(null) }
    var corruptTarget by remember { mutableStateOf<CanvasProjectSummary?>(null) }

    val filtered = remember(session.projects, query) {
        val text = query.trim()
        if (text.isEmpty()) session.projects
        else session.projects.filter { it.name.contains(text, ignoreCase = true) }
    }

    Column(modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
        if (session.loading && session.projects.isEmpty()) {
            CanvasLibraryLoading()
            return@Column
        }
        if (session.showAvailabilityState) {
            CanvasAvailabilityState(session)
            return@Column
        }
        Row(
            Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            FloeSearchField(
                value = query,
                onValueChange = { query = it },
                placeholder = stringResource(R.string.canvas_search_hint),
                modifier = Modifier.weight(1f),
            )
            FloeCircleButton(
                icon = FloeIcons.Refresh,
                contentDescription = stringResource(R.string.canvas_refresh),
                onClick = { session.refresh() },
                enabled = !session.refreshing,
            )
        }
        CanvasQuickActions(
            enabled = !session.busy,
            onCreate = { nameDialog = CanvasNameDialog.Create("") },
            onImport = {
                scope.launch {
                    val picked = pickImage() ?: return@launch
                    nameDialog = CanvasNameDialog.Import(
                        source = picked,
                        initialName = defaultCanvasName(picked.displayName),
                        opID = java.util.UUID.randomUUID().toString(),
                    )
                }
            },
        )
        if (session.failure != null) {
            CanvasInlineFailure(
                failure = session.failure!!,
                onRetry = { session.refresh() },
            )
        }
        if (session.busy) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                FloeActivityIndicator()
                FloeText(
                    stringResource(R.string.canvas_working),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
        }
        if (filtered.isEmpty()) {
            FloeUnavailableView(
                icon = FloeIcons.Creative,
                title = stringResource(
                    if (query.isBlank()) R.string.canvas_empty_title
                    else R.string.canvas_no_matches_title),
                description = stringResource(
                    if (query.isBlank()) R.string.canvas_empty_body
                    else R.string.canvas_no_matches_body),
                modifier = Modifier.weight(1f),
            )
        } else {
            LazyColumn(Modifier.weight(1f).fillMaxWidth()) {
                items(filtered, key = { it.id }) { summary ->
                    CanvasSummaryRow(
                        summary = summary,
                        busy = session.busy,
                        onOpen = { session.open(summary) },
                        onRename = {
                            nameDialog = CanvasNameDialog.Rename(summary)
                        },
                        onDelete = { deleteTarget = summary },
                        onCorrupt = { corruptTarget = summary },
                    )
                }
                item { Spacer(Modifier.height(24.dp)) }
            }
        }
    }

    val dialog = nameDialog
    if (dialog != null) {
        CanvasNameSheet(
            dialog = dialog,
            busy = session.busy,
            onDismiss = { nameDialog = null },
            onConfirm = { name ->
                nameDialog = null
                when (dialog) {
                    is CanvasNameDialog.Create -> session.createBlank(name)
                    is CanvasNameDialog.Import ->
                        session.importNew(name, dialog.source, opID = dialog.opID)
                    is CanvasNameDialog.Rename ->
                        session.rename(dialog.summary, name)
                }
            },
        )
    }
    val deletion = deleteTarget
    if (deletion != null) {
        FloeConfirmDialog(
            title = stringResource(R.string.canvas_delete_title, deletion.name),
            message = stringResource(R.string.canvas_delete_body),
            confirmLabel = stringResource(R.string.canvas_delete_confirm),
            dismissLabel = stringResource(R.string.canvas_cancel),
            onConfirm = {
                deleteTarget = null
                session.delete(deletion)
            },
            onDismiss = { deleteTarget = null },
        )
    }
    val corrupt = corruptTarget
    if (corrupt != null) {
        com.floe.android.design.FloeInfoDialog(
            title = stringResource(R.string.canvas_corrupt_title),
            message = stringResource(R.string.canvas_corrupt_body),
            confirmLabel = stringResource(R.string.canvas_done),
            onDismiss = { corruptTarget = null },
        )
    }
}

@Composable
private fun CanvasLibraryLoading() {
    Column(
        Modifier.fillMaxSize(),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        FloeActivityIndicator()
        FloeText(
            stringResource(R.string.canvas_library_loading),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
            modifier = Modifier.padding(top = 10.dp),
        )
    }
}

@Composable
private fun CanvasAvailabilityState(session: CanvasWorkspaceSession) {
    val availability = session.availability
    val failure = session.failure
    val icon = when (availability) {
        CreativeAvailability.NeedsCoreUpdate -> FloeIcons.ShieldAlert
        CreativeAvailability.WaitingForRuntime -> FloeIcons.Clock
        else -> FloeIcons.WarningTriangle
    }
    val title = when {
        failure != null -> stringResource(failure.titleRes())
        availability == CreativeAvailability.NeedsCoreUpdate ->
            stringResource(R.string.canvas_core_update_title)
        availability == CreativeAvailability.WaitingForRuntime ->
            stringResource(R.string.canvas_runtime_waiting_title)
        else -> stringResource(R.string.canvas_unavailable_title)
    }
    val body = when {
        failure != null -> stringResource(failure.bodyRes())
        availability == CreativeAvailability.NeedsCoreUpdate ->
            stringResource(R.string.canvas_core_update_body)
        availability == CreativeAvailability.WaitingForRuntime ->
            stringResource(R.string.canvas_runtime_waiting_body)
        else -> stringResource(R.string.canvas_unavailable_body)
    }
    FloeUnavailableView(
        icon = icon,
        title = title,
        description = body,
        action = {
            FloeCapsuleAction(
                label = stringResource(R.string.canvas_retry),
                onClick = { session.refresh(initial = true) },
            )
        },
    )
}

@Composable
private fun CanvasQuickActions(
    enabled: Boolean,
    onCreate: () -> Unit,
    onImport: () -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp)) {
        CanvasQuickActionRow(
            icon = FloeIcons.PlusCircle,
            title = stringResource(R.string.canvas_new),
            subtitle = stringResource(R.string.canvas_new_body),
            enabled = enabled,
            testTag = "canvas.library.new",
            onClick = onCreate,
        )
        CanvasQuickActionRow(
            icon = FloeIcons.Photo,
            title = stringResource(R.string.canvas_import_new),
            subtitle = stringResource(R.string.canvas_import_new_body),
            enabled = enabled,
            testTag = "canvas.library.import",
            onClick = onImport,
        )
    }
}

@Composable
private fun CanvasQuickActionRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    subtitle: String,
    enabled: Boolean,
    testTag: String,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = FloeLayout.MinimumTarget)
            .clip(RoundedCornerShape(12.dp))
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 8.dp, vertical = 8.dp)
            .testTag(testTag),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            Modifier
                .size(44.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(Floe.colors.accentFillFaint),
            contentAlignment = Alignment.Center,
        ) {
            IconGlyph(icon, Floe.colors.accent, 22.dp)
        }
        Column(Modifier.weight(1f)) {
            FloeText(title, style = Floe.typography.bodyEmphasized)
            FloeText(
                subtitle,
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
        IconGlyph(FloeIcons.ChevronForward, Floe.colors.tertiaryLabel, 16.dp)
    }
}

@Composable
private fun CanvasSummaryRow(
    summary: CanvasProjectSummary,
    busy: Boolean,
    onOpen: () -> Unit,
    onRename: () -> Unit,
    onDelete: () -> Unit,
    onCorrupt: () -> Unit,
) {
    var menuOpen by remember { mutableStateOf(false) }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = FloeLayout.MinimumTarget)
            .clickable(enabled = !busy) {
                if (summary.corrupt) onCorrupt() else onOpen()
            }
            .padding(start = 16.dp, end = 8.dp, top = 8.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            Modifier
                .width(52.dp)
                .height(38.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(Floe.colors.accentFillFaint),
            contentAlignment = Alignment.Center,
        ) {
            IconGlyph(
                if (summary.corrupt) FloeIcons.WarningTriangle else FloeIcons.Creative,
                if (summary.corrupt) Floe.colors.pending else Floe.colors.accent,
                20.dp,
            )
        }
        Column(Modifier.weight(1f)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                FloeText(
                    summary.name.ifBlank { stringResource(R.string.canvas_corrupt_title) },
                    style = Floe.typography.bodyEmphasized,
                    color = if (summary.corrupt) Floe.colors.secondaryLabel else Floe.colors.label,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                if (summary.corrupt) {
                    FloeBadgePill(
                        text = stringResource(R.string.canvas_corrupt_title),
                        tone = FloeBadgeTone.DESTRUCTIVE,
                    )
                } else if (!summary.writable) {
                    FloeBadgePill(
                        text = stringResource(R.string.canvas_read_only),
                        tone = FloeBadgeTone.SECONDARY,
                    )
                }
                if (summary.schemaVersion > 7) {
                    FloeBadgePill(
                        text = stringResource(R.string.canvas_failure_unsupported_title),
                        tone = FloeBadgeTone.PENDING,
                    )
                }
            }
            if (!summary.corrupt) {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.padding(top = 2.dp),
                ) {
                    FloeText(
                        stringResource(R.string.canvas_updated, formatCanvasDate(summary.updatedAt)),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    FloeText(
                        stringResource(R.string.canvas_document_count, summary.documentCount),
                        style = Floe.typography.metadata,
                        color = Floe.colors.tertiaryLabel,
                        maxLines = 1,
                    )
                }
            }
        }
        if (!summary.corrupt && summary.writable) {
            Box {
                FloeCircleButton(
                    icon = FloeIcons.Ellipsis,
                    contentDescription = stringResource(R.string.canvas_more_actions, summary.name),
                    onClick = { menuOpen = true },
                    visualSize = 32.dp,
                    iconSize = 15.dp,
                )
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    DropdownMenuItem(
                        text = { FloeText(stringResource(R.string.canvas_open)) },
                        onClick = { menuOpen = false; onOpen() },
                    )
                    DropdownMenuItem(
                        text = { FloeText(stringResource(R.string.canvas_rename)) },
                        onClick = { menuOpen = false; onRename() },
                    )
                    DropdownMenuItem(
                        text = {
                            FloeText(
                                stringResource(R.string.canvas_delete),
                                color = Floe.colors.destructive,
                            )
                        },
                        onClick = { menuOpen = false; onDelete() },
                    )
                }
            }
        } else if (!summary.corrupt) {
            IconGlyph(FloeIcons.ChevronForward, Floe.colors.tertiaryLabel, 16.dp)
        }
    }
}

@Composable
private fun CanvasNameSheet(
    dialog: CanvasNameDialog,
    busy: Boolean,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit,
) {
    var name by remember(dialog) { mutableStateOf(dialog.initialName) }
    val titleRes = when (dialog) {
        is CanvasNameDialog.Create -> R.string.canvas_new_title
        is CanvasNameDialog.Import -> R.string.canvas_import_title
        is CanvasNameDialog.Rename -> R.string.canvas_rename_title
    }
    val confirmRes = when (dialog) {
        is CanvasNameDialog.Rename -> R.string.canvas_save
        else -> R.string.canvas_create
    }
    val valid = name.trim().isNotEmpty() && !busy
    FloeActionSheet(visible = true, onDismiss = onDismiss) {
        Column(Modifier.fillMaxWidth().padding(20.dp)) {
            FloeText(stringResource(titleRes), style = Floe.typography.section)
            Spacer(Modifier.height(12.dp))
            FloePlainFormField(
                label = stringResource(R.string.canvas_name_label),
                value = name,
                onValueChange = { name = it.take(120) },
                enabled = !busy,
            )
            if (name.trim().isEmpty() && name.isNotEmpty()) {
                FloeText(
                    stringResource(R.string.canvas_name_required),
                    style = Floe.typography.metadata,
                    color = Floe.colors.destructive,
                    modifier = Modifier.padding(top = 6.dp),
                )
            }
            Row(
                Modifier.fillMaxWidth().padding(top = 16.dp),
                horizontalArrangement = Arrangement.End,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FloeCapsuleAction(
                    label = stringResource(R.string.canvas_cancel),
                    onClick = onDismiss,
                    enabled = !busy,
                )
                Spacer(Modifier.width(10.dp))
                FloeCapsuleAction(
                    label = stringResource(confirmRes),
                    onClick = { onConfirm(name.trim()) },
                    enabled = valid,
                    tint = Floe.colors.accent,
                )
            }
        }
    }
}

private sealed interface CanvasNameDialog {
    val initialName: String

    data class Create(override val initialName: String) : CanvasNameDialog

    data class Import(
        val source: CanvasPickedSource,
        override val initialName: String,
        val opID: String,
    ) : CanvasNameDialog

    data class Rename(val summary: CanvasProjectSummary) : CanvasNameDialog {
        override val initialName: String get() = summary.name
    }
}

private fun defaultCanvasName(displayName: String): String {
    val base = displayName.substringBeforeLast('.', displayName).trim()
    return base.ifEmpty { "Canvas" }.take(96)
}
