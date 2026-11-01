// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui

import android.app.Activity
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.floe.android.design.Floe
import com.floe.android.design.FloeActionSheet
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeBadgePill
import com.floe.android.design.FloeBadgeTone
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeConfirmDialog
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloeSegmented
import com.floe.android.design.FloeText
import com.floe.android.design.FloeToolbar
import com.floe.android.design.FloeVerticalDivider
import com.floe.android.design.IconGlyph
import com.floe.android.feature.workbench.ui.api.MediaAgentAskAiSheet
import com.floe.android.feature.workbench.ui.api.MediaPickedSource
import com.floe.android.feature.workbench.ui.presentation.MediaFailureKind
import com.floe.android.feature.workbench.ui.r2.MediaExportSheet
import com.floe.android.feature.workbench.ui.r2.MediaGenerationSheet
import com.floe.android.feature.workbench.ui.r2.MediaVideoAssetsPanel
import com.floe.android.feature.workbench.ui.r2.MediaVideoAssetsSheet
import com.floe.android.feature.workbench.ui.r2.MediaVideoPanelSheet
import com.floe.android.feature.workbench.ui.r2.MediaVideoPropertiesPanel
import com.floe.android.feature.workbench.ui.r2.MediaVideoTimeline
import com.floe.android.feature.workbench.ui.r2.WorkbenchMediaPickKind
import com.floe.android.feature.workbench.ui.r2.WorkbenchMediaPicker
import com.floe.android.feature.workbench.ui.state.MediaEditorController
import com.floe.android.feature.workbench.ui.state.MediaWorkspaceSession
import kotlinx.coroutines.launch

private enum class MediaPanel { ASSETS, LAYERS, PROPERTIES }

/**
 * Feature-owned full-window media workbench cover.
 *
 * Wide windows keep assets/layers left, preview center and properties right;
 * compact windows keep the preview plus bottom drawers. Every panel belongs to
 * this editor cover, not to the outer App split.
 */
@Composable
internal fun MediaEditorCover(
    session: MediaWorkspaceSession,
    editor: MediaEditorController,
    pickImage: suspend () -> MediaPickedSource?,
    mediaPicker: WorkbenchMediaPicker? = null,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var showMore by remember(editor) { mutableStateOf(false) }
    var showRename by remember(editor) { mutableStateOf(false) }
    var showClose by remember(editor) { mutableStateOf(false) }
    var showDeleteLayer by remember(editor) { mutableStateOf(false) }
    var showAddText by remember(editor) { mutableStateOf(false) }
    var showPanel by remember(editor) { mutableStateOf<MediaPanel?>(null) }
    var leftPanel by rememberSaveable(editor.projectID) { mutableIntStateOf(0) }
    var drawMode by remember(editor) { mutableStateOf(false) }
    var brushWidth by remember(editor) { mutableFloatStateOf(16f) }
    var brushColor by remember(editor) { mutableStateOf("#0081F6") }
    var closeAfterBusy by remember(editor) { mutableStateOf(false) }
    var showVideoPanel by remember(editor) { mutableStateOf(false) }
    var showVideoAssets by remember(editor) { mutableStateOf(false) }
    var showAi by remember(editor) { mutableStateOf(false) }
    var showAskAi by remember(editor) { mutableStateOf(false) }
    var showExport by remember(editor) { mutableStateOf(false) }
    val drawingLayerName = stringResource(R.string.media_layer_freehand)
    val importVideo: (() -> Unit)? = mediaPicker?.let { picker ->
        {
            scope.launch {
                val picked = picker.pickMedia(WorkbenchMediaPickKind.VIDEO) ?: return@launch
                editor.importVideoClip(picked)
            }
            Unit
        }
    }
    val importMusic: (() -> Unit)? = mediaPicker?.let { picker ->
        {
            scope.launch {
                val picked = picker.pickMedia(WorkbenchMediaPickKind.AUDIO) ?: return@launch
                editor.importMusic(picked)
            }
            Unit
        }
    }

    LaunchedEffect(editor.isImageProject) {
        if (!editor.isImageProject) drawMode = false
    }
    val requestClose: () -> Unit = {
        if (editor.busy) closeAfterBusy = true else showClose = true
    }
    LaunchedEffect(editor.busy, closeAfterBusy) {
        if (!editor.busy && closeAfterBusy) {
            closeAfterBusy = false
            showClose = true
        }
    }
    DisposableEffect(editor) {
        onDispose {
            val changing = (context as? Activity)?.isChangingConfigurations == true
            if (!changing && !editor.isRetired) session.retireFromUi(editor)
        }
    }

    Dialog(
        onDismissRequest = requestClose,
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
            decorFitsSystemWindows = false,
            dismissOnBackPress = false,
            dismissOnClickOutside = false,
        ),
    ) {
        BackHandler(onBack = requestClose)
        Box(
            Modifier
                .fillMaxSize()
                .background(Floe.colors.readingSurface)
                .windowInsetsPadding(WindowInsets.safeDrawing),
        ) {
            BoxWithConstraints(Modifier.fillMaxSize()) {
                val wide = maxWidth >= 1180.dp && maxWidth > maxHeight
                Column(Modifier.fillMaxSize()) {
                    FloeToolbar(
                        title = editor.project.name,
                        background = Floe.colors.readingSurface,
                        navigation = {
                            FloeCircleButton(
                                icon = FloeIcons.ChevronBack,
                                contentDescription = stringResource(R.string.media_back_to_library),
                                onClick = requestClose,
                            )
                        },
                        actions = {
                            if (wide) {
                                MediaToolbarTextAction(
                                    label = stringResource(R.string.media_undo),
                                    enabled = editor.canUndo,
                                    onClick = { editor.undo() },
                                )
                                MediaToolbarTextAction(
                                    label = stringResource(R.string.media_redo),
                                    enabled = editor.canRedo,
                                    onClick = { editor.redo() },
                                )
                            }
                            if (editor.isImageProject) {
                                FloeCircleButton(
                                    icon = FloeIcons.Wand,
                                    contentDescription = stringResource(
                                        if (drawMode) R.string.media_draw_stop else R.string.media_draw),
                                    onClick = { drawMode = !drawMode },
                                    tint = if (drawMode) Floe.colors.accent else Floe.colors.label,
                                    enabled = editor.writable && !editor.busy && !editor.needsReload,
                                )
                            }
                            if (editor.r2 != null) {
                                FloeCircleButton(
                                    icon = FloeIcons.Wand,
                                    contentDescription = stringResource(R.string.media_r2_ai),
                                    onClick = { showAi = true },
                                )
                                if (session.agentAvailable) {
                                    FloeCircleButton(
                                        icon = FloeIcons.NewTask,
                                        contentDescription = stringResource(R.string.media_ask_ai),
                                        onClick = { showAskAi = true },
                                    )
                                }
                                FloeCircleButton(
                                    icon = FloeIcons.ArrowUp,
                                    contentDescription = stringResource(R.string.media_r2_export),
                                    onClick = { showExport = true },
                                )
                            }
                            FloeCircleButton(
                                icon = FloeIcons.Ellipsis,
                                contentDescription = stringResource(R.string.media_more),
                                onClick = { showMore = true },
                            )
                        },
                        showHairline = true,
                    )
                    MediaEditorStatus(editor)
                    MediaEditorNotices(editor)
                    FloeDivider()
                    val videoEditing = editor.isVideoProject && editor.r2 != null
                    if (wide) {
                        Column(Modifier.weight(1f).fillMaxWidth()) {
                            Row(Modifier.weight(1f).fillMaxWidth()) {
                                Column(
                                    Modifier.width(270.dp).fillMaxHeight(),
                                ) {
                                    if (videoEditing) {
                                        MediaVideoAssetsPanel(
                                            controller = editor,
                                            onImportVideo = importVideo,
                                            onImportMusic = importMusic,
                                            modifier = Modifier.weight(1f),
                                        )
                                    } else {
                                        FloeSegmented(
                                            options = listOf(
                                                stringResource(R.string.media_assets),
                                                stringResource(R.string.media_layers),
                                            ),
                                            selectedIndex = leftPanel,
                                            onSelect = { leftPanel = it },
                                            modifier = Modifier.padding(horizontal = 8.dp),
                                        )
                                        FloeDivider()
                                        if (leftPanel == 0) {
                                            MediaAssetsPanel(
                                                controller = editor,
                                                onImport = {
                                                    scope.launch {
                                                        val picked = pickImage() ?: return@launch
                                                        editor.importAsset(picked)
                                                    }
                                                },
                                                modifier = Modifier.weight(1f),
                                            )
                                        } else {
                                            MediaLayersPanel(
                                                controller = editor,
                                                onAddText = { showAddText = true },
                                                modifier = Modifier.weight(1f),
                                            )
                                        }
                                    }
                                }
                                FloeVerticalDivider()
                                MediaPreview(
                                    controller = editor,
                                    drawMode = drawMode,
                                    brushWidth = brushWidth,
                                    brushColorHex = brushColor,
                                    onStroke = { editor.addFreehandStroke(it, drawingLayerName) },
                                    modifier = Modifier.weight(1f).fillMaxHeight(),
                                    compact = false,
                                )
                                FloeVerticalDivider()
                                if (videoEditing) {
                                    MediaVideoPropertiesPanel(
                                        controller = editor,
                                        modifier = Modifier.width(310.dp).fillMaxHeight(),
                                    )
                                } else {
                                    MediaPropertiesPanel(
                                        controller = editor,
                                        drawMode = drawMode,
                                        onToggleDraw = { drawMode = !drawMode },
                                        brushWidth = brushWidth,
                                        onBrushWidth = { brushWidth = it },
                                        brushColorHex = brushColor,
                                        onBrushColor = { brushColor = it },
                                        onDeleteLayer = { showDeleteLayer = true },
                                        modifier = Modifier.width(310.dp).fillMaxHeight(),
                                    )
                                }
                            }
                            if (videoEditing) {
                                FloeDivider()
                                MediaVideoTimeline(
                                    controller = editor,
                                    compact = false,
                                    modifier = Modifier.fillMaxWidth().height(210.dp),
                                )
                            }
                        }
                    } else {
                        MediaPreview(
                            controller = editor,
                            drawMode = drawMode,
                            brushWidth = brushWidth,
                            brushColorHex = brushColor,
                            onStroke = { editor.addFreehandStroke(it, drawingLayerName) },
                            modifier = Modifier.weight(1f).fillMaxWidth(),
                            compact = true,
                        )
                        if (videoEditing) {
                            FloeDivider()
                            MediaVideoTimeline(
                                controller = editor,
                                compact = true,
                                modifier = Modifier.fillMaxWidth().height(170.dp),
                            )
                        }
                        FloeDivider()
                        Row(
                            Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 6.dp),
                            horizontalArrangement = Arrangement.spacedBy(4.dp),
                        ) {
                            if (videoEditing) {
                                MediaCompactButton(
                                    icon = FloeIcons.Photo,
                                    label = stringResource(R.string.media_assets),
                                    onClick = { showVideoAssets = true },
                                    modifier = Modifier.weight(1f),
                                )
                                MediaCompactButton(
                                    icon = FloeIcons.Gauge,
                                    label = stringResource(R.string.media_r2_video),
                                    onClick = { showVideoPanel = true },
                                    modifier = Modifier.weight(1f),
                                )
                            } else {
                                MediaCompactButton(
                                    icon = FloeIcons.Photo,
                                    label = stringResource(R.string.media_assets),
                                    onClick = { showPanel = MediaPanel.ASSETS },
                                    modifier = Modifier.weight(1f),
                                )
                                MediaCompactButton(
                                    icon = FloeIcons.Creative,
                                    label = stringResource(R.string.media_layers),
                                    onClick = { showPanel = MediaPanel.LAYERS },
                                    modifier = Modifier.weight(1f),
                                )
                                MediaCompactButton(
                                    icon = FloeIcons.Gauge,
                                    label = stringResource(R.string.media_properties),
                                    onClick = { showPanel = MediaPanel.PROPERTIES },
                                    modifier = Modifier.weight(1f),
                                )
                            }
                            if (editor.r2 != null) {
                                MediaCompactButton(
                                    icon = FloeIcons.Wand,
                                    label = stringResource(R.string.media_r2_ai),
                                    onClick = { showAi = true },
                                    modifier = Modifier.weight(1f),
                                )
                                if (session.agentAvailable) {
                                    MediaCompactButton(
                                        icon = FloeIcons.NewTask,
                                        label = stringResource(R.string.media_ask_ai),
                                        onClick = { showAskAi = true },
                                        modifier = Modifier.weight(1f),
                                    )
                                }
                                MediaCompactButton(
                                    icon = FloeIcons.ArrowUp,
                                    label = stringResource(R.string.media_r2_export),
                                    onClick = { showExport = true },
                                    modifier = Modifier.weight(1f),
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    val panel = showPanel
    if (panel != null) {
        MediaPanelSheet(
            panel = panel,
            editor = editor,
            drawMode = drawMode,
            onToggleDraw = { drawMode = !drawMode },
            brushWidth = brushWidth,
            onBrushWidth = { brushWidth = it },
            brushColorHex = brushColor,
            onBrushColor = { brushColor = it },
            onDismiss = { showPanel = null },
            onImport = {
                scope.launch {
                    val picked = pickImage() ?: return@launch
                    editor.importAsset(picked)
                }
            },
            onAddText = { showPanel = null; showAddText = true },
            onDeleteLayer = { showDeleteLayer = true },
        )
    }
    if (showVideoAssets) {
        MediaVideoAssetsSheet(
            controller = editor,
            onImportVideo = importVideo,
            onImportMusic = importMusic,
            onDismiss = { showVideoAssets = false },
        )
    }
    if (showVideoPanel) {
        MediaVideoPanelSheet(
            controller = editor,
            onDismiss = { showVideoPanel = false },
        )
    }
    if (showAi) {
        MediaGenerationSheet(
            controller = editor,
            onDismiss = { showAi = false },
        )
    }
    if (showAskAi && session.agentAvailable) {
        MediaAgentAskAiSheet(
            projectName = editor.project.name,
            usesCurrentTask = session.agentOwner != null,
            busy = session.agentBusy,
            failureCode = session.agentFailure,
            onDismiss = {
                showAskAi = false
                session.dismissAgentFailure()
            },
            onConfirm = { instruction -> session.askAi(editor, instruction) },
        )
    }
    if (showExport) {
        MediaExportSheet(
            controller = editor,
            onDismiss = { showExport = false },
        )
    }
    if (showAddText) {
        MediaTextLayerSheet(
            busy = editor.busy,
            onDismiss = { showAddText = false },
            onConfirm = { text, size, color ->
                showAddText = false
                editor.addTextLayer(text, size, color)
            },
        )
    }
    if (showMore) {
        MediaMoreSheet(
            editor = editor,
            onDismiss = { showMore = false },
            onRename = { showMore = false; showRename = true },
            onClose = { showMore = false; requestClose() },
        )
    }
    if (showRename) {
        MediaRenameSheet(
            initial = editor.project.name,
            busy = editor.busy,
            onDismiss = { showRename = false },
            onConfirm = {
                showRename = false
                editor.rename(it)
            },
        )
    }
    if (showClose) {
        MediaCloseSheet(
            editor = editor,
            onDismiss = { showClose = false },
            onReload = {
                showClose = false
                editor.reload()
            },
            onClose = {
                showClose = false
                scope.launch { session.closeEditor(editor) }
            },
        )
    }
    if (showDeleteLayer) {
        FloeConfirmDialog(
            title = stringResource(R.string.media_remove_layer_title),
            message = stringResource(R.string.media_remove_layer_body),
            confirmLabel = stringResource(R.string.media_delete_confirm),
            dismissLabel = stringResource(R.string.media_cancel),
            onConfirm = {
                showDeleteLayer = false
                editor.removeSelectedLayer()
            },
            onDismiss = { showDeleteLayer = false },
        )
    }
}

@Composable
private fun MediaEditorStatus(editor: MediaEditorController) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 32.dp).padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        when {
            editor.busy -> {
                FloeActivityIndicator()
                FloeText(
                    stringResource(R.string.media_busy_saving),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
            editor.needsReload || editor.failure != null -> {
                IconGlyph(FloeIcons.WarningTriangle, Floe.colors.pending, 14.dp)
                FloeText(
                    stringResource(R.string.media_failure_unknown_title),
                    style = Floe.typography.metadata,
                    color = Floe.colors.pending,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.media_failure_reload),
                    onClick = { editor.reload() },
                    enabled = !editor.busy,
                )
            }
            else -> {
                IconGlyph(FloeIcons.CheckCircle, Floe.colors.success, 14.dp)
                FloeText(
                    stringResource(R.string.media_saved, editor.revision),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
        }
        Spacer(Modifier.weight(1f))
        FloeText(
            stringResource(mediaKindLabelRes(editor.project.kind)),
            style = Floe.typography.metadata,
            color = Floe.colors.tertiaryLabel,
        )
        if (editor.missingAssetIDs.isNotEmpty()) {
            FloeBadgePill(
                text = stringResource(
                    R.string.media_missing_assets, editor.missingAssetIDs.size),
                tone = FloeBadgeTone.PENDING,
            )
        }
        if (editor.editCopy) {
            FloeBadgePill(
                text = stringResource(R.string.media_provenance_copy),
                tone = FloeBadgeTone.SECONDARY,
            )
        }
    }
    val failure = editor.failure
    if (failure != null && !editor.busy) {
        MediaInlineFailure(
            failure = failure,
            onRetry = if (failure.kind == MediaFailureKind.SESSION_LOST ||
                failure.kind == MediaFailureKind.NEEDS_CORE_UPDATE
            ) null else ({ editor.reload() }),
        )
    }
}

@Composable
private fun MediaEditorNotices(editor: MediaEditorController) {
    val notice = editor.notice?.let { stringResource(it.textRes()) }
    val videoNotice = editor.videoNotice?.let { stringResource(it.textRes()) }
    val readOnly = if (!editor.writable) {
        stringResource(R.string.media_read_only)
    } else null
    listOfNotNull(videoNotice, notice, readOnly).take(2).forEach { MediaInlineNotice(it) }
}

@Composable
private fun MediaCompactButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier
            .heightIn(min = FloeLayout.MinimumTarget)
            .clip(RoundedCornerShape(10.dp))
            .clickable(role = Role.Button, onClick = onClick)
            .padding(vertical = 6.dp)
            .semantics { contentDescription = label },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        IconGlyph(icon, Floe.colors.accent, 20.dp)
        FloeText(
            label,
            style = Floe.typography.metadata,
            color = Floe.colors.label,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun MediaToolbarTextAction(label: String, enabled: Boolean, onClick: () -> Unit) {
    Box(
        Modifier
            .heightIn(min = FloeLayout.MinimumTarget)
            .width(52.dp)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        FloeText(
            label,
            style = Floe.typography.metadata,
            color = if (enabled) Floe.colors.accent else Floe.colors.tertiaryLabel,
            maxLines = 1,
        )
    }
}

@Composable
private fun MediaPanelSheet(
    panel: MediaPanel,
    editor: MediaEditorController,
    drawMode: Boolean,
    onToggleDraw: () -> Unit,
    brushWidth: Float,
    onBrushWidth: (Float) -> Unit,
    brushColorHex: String,
    onBrushColor: (String) -> Unit,
    onDismiss: () -> Unit,
    onImport: () -> Unit,
    onAddText: () -> Unit,
    onDeleteLayer: () -> Unit,
) {
    val title = stringResource(
        when (panel) {
            MediaPanel.ASSETS -> R.string.media_assets
            MediaPanel.LAYERS -> R.string.media_layers
            MediaPanel.PROPERTIES -> R.string.media_properties
        },
    )
    FloeActionSheet(visible = true, onDismiss = onDismiss) {
        Column(Modifier.fillMaxSize()) {
            Row(
                Modifier.fillMaxWidth().padding(start = 16.dp, end = 10.dp, top = 8.dp, bottom = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FloeText(
                    title,
                    style = Floe.typography.section,
                    modifier = Modifier.weight(1f),
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.media_done),
                    onClick = onDismiss,
                )
            }
            FloeDivider()
            when (panel) {
                MediaPanel.ASSETS -> MediaAssetsPanel(
                    controller = editor,
                    onImport = onImport,
                    modifier = Modifier.weight(1f),
                )
                MediaPanel.LAYERS -> MediaLayersPanel(
                    controller = editor,
                    onAddText = onAddText,
                    modifier = Modifier.weight(1f),
                )
                MediaPanel.PROPERTIES -> MediaPropertiesPanel(
                    controller = editor,
                    drawMode = drawMode,
                    onToggleDraw = onToggleDraw,
                    brushWidth = brushWidth,
                    onBrushWidth = onBrushWidth,
                    brushColorHex = brushColorHex,
                    onBrushColor = onBrushColor,
                    onDeleteLayer = onDeleteLayer,
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

@Composable
private fun MediaMoreSheet(
    editor: MediaEditorController,
    onDismiss: () -> Unit,
    onRename: () -> Unit,
    onClose: () -> Unit,
) {
    FloeActionSheet(visible = true, onDismiss = onDismiss) {
        Column(Modifier.fillMaxWidth().padding(20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                FloeText(
                    stringResource(R.string.media_more),
                    style = Floe.typography.section,
                    modifier = Modifier.weight(1f),
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.media_done),
                    onClick = onDismiss,
                )
            }
            MediaMoreRow(
                icon = FloeIcons.ChevronBack,
                label = stringResource(R.string.media_undo),
                enabled = editor.canUndo,
            ) { onDismiss(); editor.undo() }
            MediaMoreRow(
                icon = FloeIcons.ChevronForward,
                label = stringResource(R.string.media_redo),
                enabled = editor.canRedo,
            ) { onDismiss(); editor.redo() }
            MediaMoreRow(
                icon = FloeIcons.Pencil,
                label = stringResource(R.string.media_rename),
                enabled = editor.writable && !editor.busy,
                onClick = onRename,
            )
            MediaMoreRow(
                icon = FloeIcons.Refresh,
                label = stringResource(R.string.media_reload),
                enabled = !editor.busy,
            ) { onDismiss(); editor.reload() }
            MediaMoreRow(
                icon = FloeIcons.Xmark,
                label = stringResource(R.string.media_close),
                enabled = !editor.busy,
                onClick = onClose,
            )
        }
    }
}

@Composable
private fun MediaMoreRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = FloeLayout.MinimumTarget)
            .clip(RoundedCornerShape(10.dp))
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            Modifier.size(36.dp).clip(RoundedCornerShape(9.dp))
                .background(Floe.colors.accentFillFaint),
            contentAlignment = Alignment.Center,
        ) {
            IconGlyph(icon, if (enabled) Floe.colors.accent else Floe.colors.tertiaryLabel, 18.dp)
        }
        FloeText(
            label,
            style = Floe.typography.body,
            color = if (enabled) Floe.colors.label else Floe.colors.tertiaryLabel,
        )
    }
}

@Composable
private fun MediaRenameSheet(
    initial: String,
    busy: Boolean,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit,
) {
    var name by remember(initial) { mutableStateOf(initial) }
    val valid = name.trim().isNotEmpty() && !busy
    FloeActionSheet(visible = true, onDismiss = onDismiss) {
        Column(Modifier.fillMaxWidth().padding(20.dp)) {
            FloeText(
                stringResource(R.string.media_rename_title),
                style = Floe.typography.section,
            )
            Spacer(Modifier.size(12.dp))
            FloePlainFormField(
                label = stringResource(R.string.media_name_label),
                value = name,
                onValueChange = { name = it.take(120) },
                enabled = !busy,
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
                    label = stringResource(R.string.media_save),
                    onClick = { onConfirm(name.trim()) },
                    enabled = valid,
                    tint = Floe.colors.accent,
                )
            }
        }
    }
}

@Composable
private fun MediaCloseSheet(
    editor: MediaEditorController,
    onDismiss: () -> Unit,
    onReload: () -> Unit,
    onClose: () -> Unit,
) {
    val needsCheck = editor.failure != null || editor.needsReload
    FloeActionSheet(visible = true, onDismiss = onDismiss) {
        Column(Modifier.fillMaxWidth().padding(20.dp)) {
            FloeText(
                stringResource(
                    if (needsCheck) R.string.media_close_failed_title
                    else R.string.media_close_title),
                style = Floe.typography.section,
            )
            FloeText(
                stringResource(
                    if (needsCheck) R.string.media_close_failed_body
                    else R.string.media_close_body),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.padding(top = 8.dp),
            )
            Row(
                Modifier.fillMaxWidth().padding(top = 18.dp),
                horizontalArrangement = Arrangement.End,
            ) {
                if (needsCheck) {
                    FloeCapsuleAction(
                        label = stringResource(R.string.media_cancel),
                        onClick = onDismiss,
                    )
                    Spacer(Modifier.width(10.dp))
                    FloeCapsuleAction(
                        label = stringResource(R.string.media_failure_reload),
                        onClick = onReload,
                    )
                    Spacer(Modifier.width(10.dp))
                    FloeCapsuleAction(
                        label = stringResource(R.string.media_close_anyway),
                        onClick = onClose,
                        tint = Floe.colors.destructive,
                    )
                } else {
                    FloeCapsuleAction(
                        label = stringResource(R.string.media_cancel),
                        onClick = onDismiss,
                    )
                    Spacer(Modifier.width(10.dp))
                    FloeCapsuleAction(
                        label = stringResource(R.string.media_close),
                        onClick = onClose,
                        tint = Floe.colors.accent,
                    )
                }
            }
        }
    }
}
