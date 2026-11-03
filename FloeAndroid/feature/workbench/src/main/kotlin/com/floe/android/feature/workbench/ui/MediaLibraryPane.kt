// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui

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
import androidx.compose.runtime.mutableIntStateOf
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
import com.floe.android.design.FloeInfoDialog
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloeSearchField
import com.floe.android.design.FloeSegmented
import com.floe.android.design.FloeText
import com.floe.android.design.FloeUnavailableView
import com.floe.android.design.IconGlyph
import com.floe.android.feature.canvas.CreativeAvailability
import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.workbench.MediaProjectSummary
import com.floe.android.feature.workbench.ui.api.MediaPickedSource
import com.floe.android.feature.workbench.ui.state.MediaWorkspaceSession
import kotlinx.coroutines.launch

/**
 * Public media project library + editor entry.
 *
 * Content-only surface: the App's existing Creative destination owns the
 * toolbar and Canvas/Media tab selection.
 */
@Composable
fun FloeMediaLibrary(
    session: MediaWorkspaceSession,
    pickImage: suspend () -> MediaPickedSource?,
    pickVideo: suspend () -> MediaPickedSource?,
    modifier: Modifier = Modifier,
    mediaPicker: com.floe.android.feature.workbench.ui.r2.WorkbenchMediaPicker? = null,
) {
    LaunchedEffect(session) { session.start() }
    val editor = session.editor
    if (editor != null) {
        MediaEditorCover(
            session = session,
            editor = editor,
            pickImage = pickImage,
            mediaPicker = mediaPicker,
        )
        return
    }
    MediaLibraryContent(
        session = session,
        pickImage = pickImage,
        pickVideo = pickVideo,
        modifier = modifier,
    )
}

@Composable
private fun MediaLibraryContent(
    session: MediaWorkspaceSession,
    pickImage: suspend () -> MediaPickedSource?,
    pickVideo: suspend () -> MediaPickedSource?,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    var query by remember { mutableStateOf("") }
    var newImage by remember { mutableStateOf(false) }
    var importDialog by remember { mutableStateOf<MediaImportDialog?>(null) }
    var renameTarget by remember { mutableStateOf<MediaProjectSummary?>(null) }
    var deleteTarget by remember { mutableStateOf<MediaProjectSummary?>(null) }
    var openChoice by remember { mutableStateOf<MediaProjectSummary?>(null) }
    var corruptTarget by remember { mutableStateOf<MediaProjectSummary?>(null) }

    val filtered = remember(session.projects, query) {
        val text = query.trim()
        if (text.isEmpty()) session.projects
        else session.projects.filter { it.name.contains(text, ignoreCase = true) }
    }

    Column(modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
        if (session.loading && session.projects.isEmpty()) {
            Column(
                Modifier.fillMaxSize(),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                FloeActivityIndicator()
                FloeText(
                    stringResource(R.string.media_library_loading),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                    modifier = Modifier.padding(top = 10.dp),
                )
            }
            return@Column
        }
        if (session.showAvailabilityState) {
            val availability = session.availability
            val failure = session.failure
            val icon = when (availability) {
                CreativeAvailability.NeedsCoreUpdate -> FloeIcons.ShieldAlert
                CreativeAvailability.WaitingForRuntime -> FloeIcons.Clock
                else -> FloeIcons.WarningTriangle
            }
            val title = failure?.let { stringResource(it.titleRes()) }
                ?: when (availability) {
                    CreativeAvailability.NeedsCoreUpdate ->
                        stringResource(R.string.media_core_update_title)
                    CreativeAvailability.WaitingForRuntime ->
                        stringResource(R.string.media_runtime_waiting_title)
                    else -> stringResource(R.string.media_unavailable_title)
                }
            val body = failure?.let { stringResource(it.bodyRes()) }
                ?: when (availability) {
                    CreativeAvailability.NeedsCoreUpdate ->
                        stringResource(R.string.media_core_update_body)
                    CreativeAvailability.WaitingForRuntime ->
                        stringResource(R.string.media_runtime_waiting_body)
                    else -> stringResource(R.string.media_unavailable_body)
                }
            FloeUnavailableView(
                icon = icon,
                title = title,
                description = body,
                action = {
                    FloeCapsuleAction(
                        label = stringResource(R.string.media_retry),
                        onClick = { session.refresh(initial = true) },
                    )
                },
            )
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
                placeholder = stringResource(R.string.media_search_hint),
                modifier = Modifier.weight(1f),
            )
            FloeCircleButton(
                icon = FloeIcons.Refresh,
                contentDescription = stringResource(R.string.media_refresh),
                onClick = { session.refresh() },
                enabled = !session.refreshing,
            )
        }
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp)) {
            MediaQuickAction(
                icon = FloeIcons.Photo,
                title = stringResource(R.string.media_new_image),
                subtitle = stringResource(R.string.media_new_image_body),
                enabled = !session.busy,
                onClick = { newImage = true },
                testTag = "media.library.newImage",
            )
            MediaQuickAction(
                icon = FloeIcons.ImageRole,
                title = stringResource(R.string.media_import_image),
                subtitle = stringResource(R.string.media_new_image_body),
                enabled = !session.busy,
                onClick = {
                    scope.launch {
                        val picked = pickImage() ?: return@launch
                        importDialog = MediaImportDialog(
                            source = picked,
                            kind = "image",
                            initialName = defaultProjectName(picked.displayName),
                            opID = java.util.UUID.randomUUID().toString(),
                        )
                    }
                },
                testTag = "media.library.importImage",
            )
            MediaQuickAction(
                icon = FloeIcons.PlayRuns,
                title = stringResource(R.string.media_new_video),
                subtitle = stringResource(R.string.media_new_video_body),
                enabled = !session.busy,
                onClick = {
                    scope.launch {
                        val picked = pickVideo() ?: return@launch
                        importDialog = MediaImportDialog(
                            source = picked,
                            kind = "video",
                            initialName = defaultProjectName(picked.displayName),
                            opID = java.util.UUID.randomUUID().toString(),
                        )
                    }
                },
                testTag = "media.library.newVideo",
            )
        }
        if (session.failure != null) {
            MediaInlineFailure(
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
                    stringResource(R.string.media_working),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
        }
        if (filtered.isEmpty()) {
            FloeUnavailableView(
                icon = FloeIcons.ImageRole,
                title = stringResource(
                    if (query.isBlank()) R.string.media_empty_title
                    else R.string.media_no_matches_title),
                description = stringResource(
                    if (query.isBlank()) R.string.media_empty_body
                    else R.string.media_no_matches_body),
                modifier = Modifier.weight(1f),
            )
        } else {
            LazyColumn(Modifier.weight(1f).fillMaxWidth()) {
                items(filtered, key = { it.id }) { summary ->
                    MediaSummaryRow(
                        summary = summary,
                        busy = session.busy,
                        onOpen = {
                            if (summary.ownerKind == "standalone") {
                                session.open(summary)
                            } else {
                                openChoice = summary
                            }
                        },
                        onRename = { renameTarget = summary },
                        onDelete = { deleteTarget = summary },
                        onCorrupt = { corruptTarget = summary },
                    )
                }
                item { Spacer(Modifier.height(24.dp)) }
            }
        }
    }

    if (newImage) {
        NewImageProjectSheet(
            busy = session.busy,
            onDismiss = { newImage = false },
            onConfirm = { name, width, height ->
                newImage = false
                session.createBlank(name = name, width = width, height = height)
            },
        )
    }
    val importing = importDialog
    if (importing != null) {
        MediaNameSheet(
            titleRes = if (importing.kind == "video") R.string.media_new_video_title
            else R.string.media_import_title,
            initialName = importing.initialName,
            busy = session.busy,
            onDismiss = { importDialog = null },
            onConfirm = { name ->
                importDialog = null
                session.importNew(
                    name = name,
                    source = importing.source,
                    kind = importing.kind,
                    storage = CreativeStorageLayer.AppOwned,
                    origin = CreativeOriginContext.standalone(),
                    opID = importing.opID,
                )
            },
        )
    }
    val renaming = renameTarget
    if (renaming != null) {
        MediaNameSheet(
            titleRes = R.string.media_rename_title,
            initialName = renaming.name,
            busy = session.busy,
            onDismiss = { renameTarget = null },
            onConfirm = { name ->
                renameTarget = null
                session.rename(renaming, name)
            },
        )
    }
    val deleting = deleteTarget
    if (deleting != null) {
        FloeConfirmDialog(
            title = stringResource(R.string.media_delete_title, deleting.name),
            message = stringResource(R.string.media_delete_body),
            confirmLabel = stringResource(R.string.media_delete_confirm),
            dismissLabel = stringResource(R.string.media_cancel),
            onConfirm = {
                deleteTarget = null
                session.delete(deleting)
            },
            onDismiss = { deleteTarget = null },
        )
    }
    val choice = openChoice
    if (choice != null) {
        MediaOpenChoiceSheet(
            summary = choice,
            busy = session.busy,
            onDismiss = { openChoice = null },
            onOpenWorkspace = {
                openChoice = null
                session.open(
                    summary = choice,
                    origin = originFromSummary(choice),
                    storage = CreativeStorageLayer.Workspace(
                        requireNotNull(choice.ownerID)),
                    editCopy = false,
                )
            },
            onOpenEditCopy = {
                openChoice = null
                session.open(
                    summary = choice,
                    origin = originFromSummary(choice),
                    storage = CreativeStorageLayer.AppOwned,
                    editCopy = true,
                )
            },
        )
    }
    val corrupt = corruptTarget
    if (corrupt != null) {
        FloeInfoDialog(
            title = stringResource(R.string.media_corrupt_title),
            message = stringResource(R.string.media_corrupt_body),
            confirmLabel = stringResource(R.string.media_done),
            onDismiss = { corruptTarget = null },
        )
    }
}

@Composable
private fun MediaQuickAction(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    subtitle: String,
    enabled: Boolean,
    onClick: () -> Unit,
    testTag: String,
) {
    Row(
        Modifier
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
            Modifier.size(44.dp).clip(RoundedCornerShape(10.dp))
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
private fun MediaSummaryRow(
    summary: MediaProjectSummary,
    busy: Boolean,
    onOpen: () -> Unit,
    onRename: () -> Unit,
    onDelete: () -> Unit,
    onCorrupt: () -> Unit,
) {
    var menuOpen by remember { mutableStateOf(false) }
    val originOwned = summary.ownerKind != "standalone"
    Row(
        Modifier
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
            Modifier.size(44.dp).clip(RoundedCornerShape(8.dp))
                .background(Floe.colors.accentFillFaint),
            contentAlignment = Alignment.Center,
        ) {
            IconGlyph(
                when {
                    summary.corrupt -> FloeIcons.WarningTriangle
                    summary.kind == "video" -> FloeIcons.PlayRuns
                    else -> FloeIcons.Photo
                },
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
                    summary.name.ifBlank { stringResource(R.string.media_corrupt_title) },
                    style = Floe.typography.bodyEmphasized,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    color = if (summary.corrupt) Floe.colors.secondaryLabel else Floe.colors.label,
                    modifier = Modifier.weight(1f, fill = false),
                )
                if (summary.corrupt) {
                    FloeBadgePill(
                        text = stringResource(R.string.media_corrupt_title),
                        tone = FloeBadgeTone.DESTRUCTIVE,
                    )
                } else if (!summary.writable) {
                    FloeBadgePill(
                        text = stringResource(R.string.media_read_only),
                        tone = FloeBadgeTone.SECONDARY,
                    )
                }
                if (summary.provenanceWarning) {
                    FloeBadgePill(
                        text = stringResource(R.string.media_provenance_warning),
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
                        stringResource(R.string.media_updated,
                            formatMediaDate(summary.updatedAt)),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    FloeText(
                        stringResource(
                            R.string.media_counts,
                            summary.assetCount,
                            summary.layerCount,
                        ),
                        style = Floe.typography.metadata,
                        color = Floe.colors.tertiaryLabel,
                        maxLines = 1,
                    )
                }
            }
        }
        if (!summary.corrupt && summary.writable && !originOwned) {
            Box {
                FloeCircleButton(
                    icon = FloeIcons.Ellipsis,
                    contentDescription = stringResource(
                        R.string.media_more_actions, summary.name),
                    onClick = { menuOpen = true },
                    visualSize = 32.dp,
                    iconSize = 15.dp,
                )
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    DropdownMenuItem(
                        text = { FloeText(stringResource(R.string.media_open)) },
                        onClick = { menuOpen = false; onOpen() },
                    )
                    DropdownMenuItem(
                        text = { FloeText(stringResource(R.string.media_rename)) },
                        onClick = { menuOpen = false; onRename() },
                    )
                    DropdownMenuItem(
                        text = {
                            FloeText(
                                stringResource(R.string.media_delete),
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

/**
 * Explicit storage choice for an origin-owned saved project. The library must
 * never guess whether a workspace/file/chat/canvas project lives in its real
 * workspace or in an app-owned edit copy: the user chooses, and the matching
 * origin context is reconstructed from the frozen summary fields.
 */
@Composable
private fun MediaOpenChoiceSheet(
    summary: MediaProjectSummary,
    busy: Boolean,
    onDismiss: () -> Unit,
    onOpenWorkspace: () -> Unit,
    onOpenEditCopy: () -> Unit,
) {
    val workspaceAvailable = workspaceCopyAvailable(summary)
    val editCopyAvailable = editCopyOriginAvailable(summary)
    FloeActionSheet(visible = true, onDismiss = onDismiss) {
        Column(Modifier.fillMaxWidth().padding(20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                FloeText(
                    stringResource(R.string.media_open_project),
                    style = Floe.typography.section,
                    modifier = Modifier.weight(1f),
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.media_cancel),
                    onClick = onDismiss,
                )
            }
            FloeText(
                summary.name,
                style = Floe.typography.body,
                color = Floe.colors.secondaryLabel,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(top = 4.dp, bottom = 8.dp),
            )
            if (workspaceAvailable) {
                MediaOpenOption(
                    icon = FloeIcons.Folder,
                    title = stringResource(R.string.media_open_workspace_copy),
                    subtitle = stringResource(R.string.media_open_workspace_copy_body),
                    enabled = !busy,
                    onClick = onOpenWorkspace,
                    testTag = "media.open.workspaceCopy",
                )
            }
            if (editCopyAvailable) {
                MediaOpenOption(
                    icon = FloeIcons.Photo,
                    title = stringResource(R.string.media_open_edit_copy),
                    subtitle = stringResource(R.string.media_open_edit_copy_body),
                    enabled = !busy,
                    onClick = onOpenEditCopy,
                    testTag = "media.open.editCopy",
                )
            }
            if (!workspaceAvailable && !editCopyAvailable) {
                FloeText(
                    stringResource(R.string.media_open_origin_unavailable),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                    modifier = Modifier.padding(vertical = 12.dp),
                )
            }
            FloeText(
                stringResource(
                    R.string.media_origin_label,
                    stringResource(originLabelRes(summary.ownerKind)),
                ),
                style = Floe.typography.metadata,
                color = Floe.colors.tertiaryLabel,
                modifier = Modifier.padding(top = 10.dp),
            )
            FloeText(
                stringResource(R.string.media_manage_at_origin),
                style = Floe.typography.metadata,
                color = Floe.colors.tertiaryLabel,
                modifier = Modifier.padding(top = 4.dp),
            )
        }
    }
}

@Composable
private fun MediaOpenOption(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    subtitle: String,
    enabled: Boolean,
    onClick: () -> Unit,
    testTag: String,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = FloeLayout.MinimumTarget)
            .clip(RoundedCornerShape(10.dp))
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 8.dp)
            .testTag(testTag),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            Modifier.size(40.dp).clip(RoundedCornerShape(9.dp))
                .background(Floe.colors.accentFillFaint),
            contentAlignment = Alignment.Center,
        ) {
            IconGlyph(icon, Floe.colors.accent, 20.dp)
        }
        Column(Modifier.weight(1f)) {
            FloeText(title, style = Floe.typography.bodyEmphasized)
            FloeText(
                subtitle,
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
            )
        }
        IconGlyph(FloeIcons.ChevronForward, Floe.colors.tertiaryLabel, 16.dp)
    }
}

internal fun workspaceCopyAvailable(summary: MediaProjectSummary): Boolean =
    summary.ownerKind == "workspace" && !summary.ownerID.isNullOrBlank()

internal fun editCopyOriginAvailable(summary: MediaProjectSummary): Boolean =
    when (summary.ownerKind) {
        "workspace", "chat", "canvas" -> !summary.ownerID.isNullOrBlank()
        "files" -> true
        else -> false
    }

internal fun originFromSummary(summary: MediaProjectSummary): CreativeOriginContext =
    CreativeOriginContext(
        kind = summary.ownerKind,
        ownerID = summary.ownerID,
        environmentID = summary.environmentID,
    )

@Composable
private fun MediaNameSheet(
    titleRes: Int,
    initialName: String,
    busy: Boolean,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit,
) {
    var name by remember(initialName) { mutableStateOf(initialName) }
    val valid = name.trim().isNotEmpty() && !busy
    FloeActionSheet(visible = true, onDismiss = onDismiss) {
        Column(Modifier.fillMaxWidth().padding(20.dp)) {
            FloeText(stringResource(titleRes), style = Floe.typography.section)
            Spacer(Modifier.height(12.dp))
            FloePlainFormField(
                label = stringResource(R.string.media_name_label),
                value = name,
                onValueChange = { name = it.take(120) },
                enabled = !busy,
            )
            if (name.trim().isEmpty() && name.isNotEmpty()) {
                FloeText(
                    stringResource(R.string.media_name_required),
                    style = Floe.typography.metadata,
                    color = Floe.colors.destructive,
                    modifier = Modifier.padding(top = 6.dp),
                )
            }
            Row(
                Modifier.fillMaxWidth().padding(top = 16.dp),
                horizontalArrangement = Arrangement.End,
            ) {
                FloeCapsuleAction(
                    label = stringResource(R.string.media_cancel),
                    onClick = onDismiss,
                    enabled = !busy,
                )
                Spacer(Modifier.width(10.dp))
                FloeCapsuleAction(
                    label = stringResource(R.string.media_create),
                    onClick = { onConfirm(name.trim()) },
                    enabled = valid,
                    tint = Floe.colors.accent,
                )
            }
        }
    }
}

@Composable
private fun NewImageProjectSheet(
    busy: Boolean,
    onDismiss: () -> Unit,
    onConfirm: (String, Int, Int) -> Unit,
) {
    var name by remember { mutableStateOf("") }
    var sizeIndex by remember { mutableIntStateOf(0) }
    val sizes = listOf(
        2048 to 2048,
        1080 to 1920,
        1920 to 1080,
    )
    val valid = name.trim().isNotEmpty() && !busy
    FloeActionSheet(visible = true, onDismiss = onDismiss) {
        Column(Modifier.fillMaxWidth().padding(20.dp)) {
            FloeText(
                stringResource(R.string.media_new_image_title),
                style = Floe.typography.section,
            )
            Spacer(Modifier.height(12.dp))
            FloePlainFormField(
                label = stringResource(R.string.media_name_label),
                value = name,
                onValueChange = { name = it.take(120) },
                enabled = !busy,
            )
            Spacer(Modifier.height(12.dp))
            val labels = sizes.map { (width, height) ->
                stringResource(R.string.media_canvas_size, width, height)
            }
            FloeSegmented(
                options = labels,
                selectedIndex = sizeIndex,
                onSelect = { sizeIndex = it },
            )
            Spacer(Modifier.height(8.dp))
            FloeText(
                stringResource(R.string.media_new_image_note),
                style = Floe.typography.metadata,
                color = Floe.colors.tertiaryLabel,
            )
            Row(
                Modifier.fillMaxWidth().padding(top = 16.dp),
                horizontalArrangement = Arrangement.End,
            ) {
                FloeCapsuleAction(
                    label = stringResource(R.string.media_cancel),
                    onClick = onDismiss,
                    enabled = !busy,
                )
                Spacer(Modifier.width(10.dp))
                FloeCapsuleAction(
                    label = stringResource(R.string.media_create),
                    onClick = {
                        val (width, height) = sizes[sizeIndex]
                        onConfirm(name.trim(), width, height)
                    },
                    enabled = valid,
                    tint = Floe.colors.accent,
                )
            }
        }
    }
}

private data class MediaImportDialog(
    val source: MediaPickedSource,
    val kind: String,
    val initialName: String,
    val opID: String,
)

private fun defaultProjectName(displayName: String): String {
    val base = displayName.substringBeforeLast('.', displayName).trim()
    return base.ifEmpty { "Media" }.take(96)
}
