// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.canvas.ui

import android.app.Activity
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Slider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
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
import com.floe.android.design.FloeInlineSwitch
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloeText
import com.floe.android.design.FloeToolbar
import com.floe.android.design.IconGlyph
import com.floe.android.feature.canvas.CanvasDocument
import com.floe.android.feature.canvas.CanvasNode
import com.floe.android.feature.canvas.ui.api.CanvasPickedSource
import com.floe.android.feature.canvas.ui.presentation.CanvasFailureKind
import com.floe.android.feature.canvas.ui.presentation.CanvasNodeSemantics
import com.floe.android.feature.canvas.ui.state.CanvasEditorController
import com.floe.android.feature.canvas.ui.state.CanvasWorkspaceSession
import kotlinx.coroutines.launch

/**
 * Feature-owned full-window Canvas editor cover.
 *
 * Used by the Creative destination's Canvas library. All editor panels
 * (tabs, add sheet, inspector sheet, close decisions) stay INSIDE this cover;
 * the outer App split/sidebar and its navigation authority are untouched.
 */
@Composable
internal fun CanvasEditorCover(
    session: CanvasWorkspaceSession,
    editor: CanvasEditorController,
    pickImage: suspend () -> CanvasPickedSource?,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var showAdd by remember(editor) { mutableStateOf(false) }
    var showInspector by remember(editor) { mutableStateOf(false) }
    var showMore by remember(editor) { mutableStateOf(false) }
    var showRename by remember(editor) { mutableStateOf(false) }
    var showClose by remember(editor) { mutableStateOf(false) }
    var showDeleteNode by remember(editor) { mutableStateOf(false) }
    var closeAfterBusy by remember(editor) { mutableStateOf(false) }

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
                val compact = maxWidth < 720.dp
                Column(Modifier.fillMaxSize()) {
                    FloeToolbar(
                        title = editor.canvasName,
                        background = Floe.colors.readingSurface,
                        navigation = {
                            FloeCircleButton(
                                icon = FloeIcons.ChevronBack,
                                contentDescription = stringResource(R.string.canvas_back_to_library),
                                onClick = requestClose,
                            )
                        },
                        actions = {
                            if (!compact) {
                                ToolbarTextAction(
                                    label = stringResource(R.string.canvas_undo),
                                    enabled = editor.canUndo && !editor.busy,
                                    onClick = { editor.undo() },
                                )
                                ToolbarTextAction(
                                    label = stringResource(R.string.canvas_redo),
                                    enabled = editor.canRedo && !editor.busy,
                                    onClick = { editor.redo() },
                                )
                                Spacer(Modifier.width(2.dp))
                            }
                            FloeCircleButton(
                                icon = FloeIcons.Plus,
                                contentDescription = stringResource(R.string.canvas_add),
                                onClick = { showAdd = true },
                                enabled = editor.writable && !editor.busy && !editor.needsReload,
                            )
                            FloeCircleButton(
                                icon = FloeIcons.Pencil,
                                contentDescription = stringResource(R.string.canvas_inspector_title),
                                onClick = { showInspector = true },
                                enabled = editor.selectedNode != null,
                            )
                            FloeCircleButton(
                                icon = FloeIcons.Ellipsis,
                                contentDescription = stringResource(R.string.canvas_more),
                                onClick = { showMore = true },
                            )
                        },
                        showHairline = true,
                    )
                    CanvasEditorStatus(editor)
                    CanvasEditorNotices(editor)
                    FloeDivider()
                    if (editor.documents.size > 1) {
                        CanvasDocumentTabs(editor)
                        FloeDivider()
                    }
                    CanvasSurface(editor = editor, modifier = Modifier.weight(1f))
                }
            }
        }
    }

    if (showAdd) {
        CanvasAddSheet(
            editor = editor,
            onDismiss = { showAdd = false },
            onAddText = { kind, text ->
                showAdd = false
                editor.createNode(kind, text)
            },
            onImportImage = {
                showAdd = false
                scope.launch {
                    val picked = pickImage() ?: return@launch
                    editor.importImage(picked)
                }
            },
        )
    }
    val node = editor.selectedNode
    if (showInspector && node != null) {
        CanvasInspectorSheet(
            editor = editor,
            node = node,
            onDismiss = { showInspector = false },
            onReplaceImage = {
                scope.launch {
                    val picked = pickImage() ?: return@launch
                    editor.importReplacementImage(picked)
                }
            },
            onDelete = {
                showInspector = false
                showDeleteNode = true
            },
        )
    }
    if (showMore) {
        CanvasMoreSheet(
            editor = editor,
            onDismiss = { showMore = false },
            onRename = { showMore = false; showRename = true },
            onClose = { showMore = false; requestClose() },
        )
    }
    if (showRename) {
        CanvasRenameSheet(
            initial = editor.canvasName,
            busy = editor.busy,
            onDismiss = { showRename = false },
            onConfirm = {
                showRename = false
                editor.rename(it)
            },
        )
    }
    if (showClose) {
        CanvasCloseSheet(
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
    if (showDeleteNode) {
        FloeConfirmDialog(
            title = stringResource(R.string.canvas_delete_node_title),
            message = stringResource(R.string.canvas_delete_node_body),
            confirmLabel = stringResource(R.string.canvas_delete_confirm),
            dismissLabel = stringResource(R.string.canvas_cancel),
            onConfirm = {
                showDeleteNode = false
                editor.deleteSelected()
            },
            onDismiss = { showDeleteNode = false },
        )
    }
}

@Composable
private fun CanvasEditorStatus(editor: CanvasEditorController) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 32.dp)
            .padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        when {
            editor.busy -> {
                FloeActivityIndicator()
                FloeText(
                    stringResource(R.string.canvas_busy_saving),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
            editor.needsReload || editor.failure != null -> {
                IconGlyph(FloeIcons.WarningTriangle, Floe.colors.pending, 14.dp)
                FloeText(
                    stringResource(R.string.canvas_failure_unknown_title),
                    style = Floe.typography.metadata,
                    color = Floe.colors.pending,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.canvas_failure_reload),
                    onClick = { editor.reload() },
                    enabled = !editor.busy,
                )
            }
            else -> {
                IconGlyph(FloeIcons.CheckCircle, Floe.colors.success, 14.dp)
                FloeText(
                    stringResource(R.string.canvas_saved, editor.revision),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
        }
        Spacer(Modifier.weight(1f))
        if (!editor.writable) {
            FloeBadgePill(
                text = stringResource(R.string.canvas_read_only),
                tone = FloeBadgeTone.SECONDARY,
            )
        }
        if (editor.isRetired) {
            FloeBadgePill(
                text = stringResource(R.string.canvas_failure_session_title),
                tone = FloeBadgeTone.SECONDARY,
            )
        }
    }
    val failure = editor.failure
    if (failure != null && !editor.busy) {
        CanvasInlineFailure(
            failure = failure,
            onRetry = if (failure.kind == CanvasFailureKind.SESSION_LOST ||
                failure.kind == CanvasFailureKind.NEEDS_CORE_UPDATE
            ) null else ({ editor.reload() }),
        )
    }
}

@Composable
private fun CanvasEditorNotices(editor: CanvasEditorController) {
    val document = editor.activeDocument
    val noticeText = editor.notice?.let { stringResource(it.textRes()) }
    val pending = editor.recovery?.pendingOperations ?: 0
    val pendingText = if (pending > 0) {
        stringResource(R.string.canvas_recovery_pending, pending)
    } else null
    val designText = if (editor.project.designProjectAuthority != null) {
        stringResource(R.string.canvas_notice_design_metadata)
    } else null
    val inkText = if (document?.pencilDrawingData != null) {
        stringResource(R.string.canvas_notice_legacy_ink)
    } else null
    val strokesText = if (document?.strokes?.isNotEmpty() == true) {
        stringResource(R.string.canvas_notice_legacy_strokes)
    } else null
    listOfNotNull(noticeText, pendingText, designText, inkText, strokesText)
        .take(3)
        .forEach { CanvasInlineNotice(it) }
}

@Composable
private fun CanvasDocumentTabs(editor: CanvasEditorController) {
    val label = stringResource(R.string.canvas_document_tabs)
    LazyRow(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .padding(horizontal = 12.dp)
            .semantics { contentDescription = label },
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        items(editor.documents, key = { it.id }) { document ->
            CanvasDocumentTab(
                document = document,
                selected = document.id == editor.selectedDocumentID,
                onClick = { editor.selectDocument(document.id) },
            )
        }
    }
}

@Composable
private fun CanvasDocumentTab(document: CanvasDocument, selected: Boolean, onClick: () -> Unit) {
    Box(
        Modifier
            .heightIn(min = FloeLayout.MinimumTarget)
            .clip(RoundedCornerShape(10.dp))
            .background(if (selected) Floe.colors.accentFillFaint else Floe.colors.fillTertiary)
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 8.dp)
            .testTag("canvas.documentTab.${document.id}"),
        contentAlignment = Alignment.Center,
    ) {
        FloeText(
            document.name.ifBlank { stringResource(R.string.canvas_document_unnamed) },
            style = if (selected) Floe.typography.bodyEmphasized else Floe.typography.body,
            color = if (selected) Floe.colors.accent else Floe.colors.label,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun CanvasAddSheet(
    editor: CanvasEditorController,
    onDismiss: () -> Unit,
    onAddText: (String, String) -> Unit,
    onImportImage: () -> Unit,
) {
    FloeActionSheet(visible = true, onDismiss = onDismiss) {
        Column(Modifier.fillMaxWidth().padding(20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                FloeText(
                    stringResource(R.string.canvas_add_title),
                    style = Floe.typography.section,
                    modifier = Modifier.weight(1f),
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.canvas_done),
                    onClick = onDismiss,
                )
            }
            Spacer(Modifier.height(10.dp))
            val textLabel = stringResource(R.string.canvas_add_text)
            val stickyLabel = stringResource(R.string.canvas_add_sticky)
            val cardLabel = stringResource(R.string.canvas_add_card)
            AddNodeOption(
                icon = FloeIcons.Pencil,
                label = textLabel,
                enabled = !editor.busy,
            ) { onAddText(CanvasNodeSemantics.KIND_TEXT, textLabel) }
            AddNodeOption(
                icon = FloeIcons.Checkmark,
                label = stickyLabel,
                enabled = !editor.busy,
            ) { onAddText(CanvasNodeSemantics.KIND_STICKY, stickyLabel) }
            AddNodeOption(
                icon = FloeIcons.BookPages,
                label = cardLabel,
                enabled = !editor.busy,
            ) { onAddText(CanvasNodeSemantics.KIND_CARD, cardLabel) }
            AddNodeOption(
                icon = FloeIcons.Creative,
                label = stringResource(R.string.canvas_add_shape),
                enabled = !editor.busy,
            ) {
                onAddText(CanvasNodeSemantics.KIND_SHAPE, "")
            }
            AddNodeOption(
                icon = FloeIcons.Photo,
                label = stringResource(R.string.canvas_add_image),
                enabled = !editor.busy,
                onClick = onImportImage,
            )
        }
    }
}

@Composable
private fun AddNodeOption(
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
            IconGlyph(icon, Floe.colors.accent, 18.dp)
        }
        FloeText(label, style = Floe.typography.body)
    }
}

@Composable
private fun CanvasInspectorSheet(
    editor: CanvasEditorController,
    node: CanvasNode,
    onDismiss: () -> Unit,
    onReplaceImage: () -> Unit,
    onDelete: () -> Unit,
) {
    val displayKind = CanvasNodeSemantics.displayKind(node.kind)
    val typeLabel = stringResource(displayKind.labelRes())
    val readOnly = CanvasNodeSemantics.isReadOnly(node) || !editor.writable
    var text by remember(node.id) { mutableStateOf(node.text) }
    var rotation by remember(node.id) { mutableFloatStateOf(node.rotation.toFloat()) }
    LaunchedEffect(node.text) {
        if (node.text != text) text = node.text
    }
    LaunchedEffect(node.rotation) {
        rotation = node.rotation.toFloat()
    }
    FloeActionSheet(visible = true, onDismiss = onDismiss) {
        Column(
            Modifier.fillMaxWidth().padding(20.dp).heightIn(max = 640.dp)
                .verticalScroll(rememberScrollState()),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    FloeText(
                        nodeAccessibleTitle(node, typeLabel),
                        style = Floe.typography.section,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    FloeText(
                        typeLabel,
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                }
                FloeCapsuleAction(
                    label = stringResource(R.string.canvas_done),
                    onClick = onDismiss,
                )
            }
            if (readOnly) {
                FloeText(
                    if (CanvasNodeSemantics.isCadBound(node)) {
                        stringResource(R.string.canvas_node_cad_body)
                    } else {
                        stringResource(R.string.canvas_node_read_only_body)
                    },
                    style = Floe.typography.body,
                    color = Floe.colors.secondaryLabel,
                    modifier = Modifier.padding(top = 16.dp),
                )
                return@Column
            }
            if (node.kind in setOf(
                    CanvasNodeSemantics.KIND_TEXT,
                    CanvasNodeSemantics.KIND_STICKY,
                    CanvasNodeSemantics.KIND_CARD,
                )
            ) {
                FloeText(
                    stringResource(R.string.canvas_inspector_text),
                    style = Floe.typography.groupHeader,
                    color = Floe.colors.secondaryLabel,
                    modifier = Modifier.padding(top = 14.dp),
                )
                FloePlainFormField(
                    label = stringResource(R.string.canvas_text_hint),
                    value = text,
                    onValueChange = { text = it },
                    singleLine = false,
                    maxLines = 8,
                    minLines = 3,
                )
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    FloeCapsuleAction(
                        label = stringResource(R.string.canvas_apply),
                        onClick = { editor.updateText(text) },
                        enabled = text != node.text && !editor.busy && editor.writable,
                        tint = Floe.colors.accent,
                    )
                }
            }
            if (node.kind == CanvasNodeSemantics.KIND_SHAPE) {
                FloeText(
                    stringResource(R.string.canvas_inspector_shape),
                    style = Floe.typography.groupHeader,
                    color = Floe.colors.secondaryLabel,
                    modifier = Modifier.padding(top = 14.dp),
                )
                Row(
                    Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    CanvasNodeSemantics.shapeKinds.forEach { shape ->
                        FloeCapsuleAction(
                            label = stringResource(shapeLabelRes(shape)),
                            onClick = { editor.updateShape(shape) },
                            tint = if (node.shape == shape) Floe.colors.accent else null,
                            enabled = !editor.busy && editor.writable,
                        )
                    }
                }
            }
            if (node.kind == CanvasNodeSemantics.KIND_IMAGE) {
                FloeText(
                    stringResource(R.string.canvas_inspector_image),
                    style = Floe.typography.groupHeader,
                    color = Floe.colors.secondaryLabel,
                    modifier = Modifier.padding(top = 14.dp),
                )
                Row(
                    Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    IconGlyph(FloeIcons.Photo, Floe.colors.secondaryLabel, 20.dp)
                    FloeText(
                        node.asset?.localRelativePath ?: stringResource(
                            R.string.canvas_image_unavailable),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                    FloeCapsuleAction(
                        label = stringResource(R.string.canvas_inspector_replace_image),
                        onClick = onReplaceImage,
                        enabled = !editor.busy && editor.writable,
                    )
                }
            }
            FloeText(
                stringResource(R.string.canvas_inspector_rotation),
                style = Floe.typography.groupHeader,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.padding(top = 14.dp),
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                FloeText(
                    "${rotation.toInt()}°",
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                    modifier = Modifier.width(52.dp),
                )
                Slider(
                    value = rotation,
                    onValueChange = { rotation = it },
                    onValueChangeFinished = { editor.setRotation(rotation.toDouble()) },
                    valueRange = -180f..180f,
                    enabled = !editor.busy && editor.writable,
                    modifier = Modifier.weight(1f),
                )
            }
            FloeText(
                stringResource(R.string.canvas_inspector_size) + ": " +
                    "${node.size.width.toInt()} × ${node.size.height.toInt()}",
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.padding(top = 4.dp),
            )
            Row(
                Modifier.fillMaxWidth().padding(top = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FloeText(
                    stringResource(R.string.canvas_inspector_lock),
                    style = Floe.typography.body,
                    modifier = Modifier.weight(1f),
                )
                FloeInlineSwitch(
                    checked = node.isLocked,
                    onCheckedChange = { editor.setLocked(it) },
                    description = stringResource(R.string.canvas_inspector_lock),
                    enabled = !editor.busy && editor.writable,
                )
            }
            FloeDivider(Modifier.padding(vertical = 8.dp))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                FloeCapsuleAction(
                    label = stringResource(R.string.canvas_inspector_delete),
                    onClick = onDelete,
                    tint = Floe.colors.destructive,
                    enabled = !editor.busy && !node.isLocked && editor.writable,
                )
            }
        }
    }
}

@Composable
private fun CanvasMoreSheet(
    editor: CanvasEditorController,
    onDismiss: () -> Unit,
    onRename: () -> Unit,
    onClose: () -> Unit,
) {
    FloeActionSheet(visible = true, onDismiss = onDismiss) {
        Column(Modifier.fillMaxWidth().padding(20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                FloeText(
                    stringResource(R.string.canvas_more),
                    style = Floe.typography.section,
                    modifier = Modifier.weight(1f),
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.canvas_done),
                    onClick = onDismiss,
                )
            }
            AddNodeOption(
                icon = FloeIcons.ChevronBack,
                label = stringResource(R.string.canvas_undo),
                enabled = editor.canUndo && !editor.busy,
            ) { onDismiss(); editor.undo() }
            AddNodeOption(
                icon = FloeIcons.ChevronForward,
                label = stringResource(R.string.canvas_redo),
                enabled = editor.canRedo && !editor.busy,
            ) { onDismiss(); editor.redo() }
            AddNodeOption(
                icon = FloeIcons.Pencil,
                label = stringResource(R.string.canvas_rename),
                enabled = editor.writable && !editor.busy,
                onClick = onRename,
            )
            AddNodeOption(
                icon = FloeIcons.Refresh,
                label = stringResource(R.string.canvas_reload),
                enabled = !editor.busy,
            ) { onDismiss(); editor.reload() }
            AddNodeOption(
                icon = FloeIcons.Xmark,
                label = stringResource(R.string.canvas_close_menu),
                enabled = !editor.busy,
                onClick = onClose,
            )
        }
    }
}

@Composable
private fun CanvasRenameSheet(
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
                stringResource(R.string.canvas_rename_title),
                style = Floe.typography.section,
            )
            Spacer(Modifier.height(12.dp))
            FloePlainFormField(
                label = stringResource(R.string.canvas_name_label),
                value = name,
                onValueChange = { name = it.take(120) },
                enabled = !busy,
            )
            Row(
                Modifier.fillMaxWidth().padding(top = 16.dp),
                horizontalArrangement = Arrangement.End,
            ) {
                FloeCapsuleAction(
                    label = stringResource(R.string.canvas_cancel),
                    onClick = onDismiss,
                    enabled = !busy,
                )
                Spacer(Modifier.width(10.dp))
                FloeCapsuleAction(
                    label = stringResource(R.string.canvas_save),
                    onClick = { onConfirm(name.trim()) },
                    enabled = valid,
                    tint = Floe.colors.accent,
                )
            }
        }
    }
}

@Composable
private fun CanvasCloseSheet(
    editor: CanvasEditorController,
    onDismiss: () -> Unit,
    onReload: () -> Unit,
    onClose: () -> Unit,
) {
    val needsCheck = editor.failure != null || editor.needsReload
    FloeActionSheet(visible = true, onDismiss = onDismiss) {
        Column(Modifier.fillMaxWidth().padding(20.dp)) {
            FloeText(
                stringResource(
                    if (needsCheck) R.string.canvas_close_failed_title
                    else R.string.canvas_close_title),
                style = Floe.typography.section,
            )
            FloeText(
                stringResource(
                    if (needsCheck) R.string.canvas_close_failed_body
                    else R.string.canvas_close_body),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.padding(top = 8.dp),
            )
            Row(
                Modifier.fillMaxWidth().padding(top = 18.dp),
                horizontalArrangement = Arrangement.End,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (needsCheck) {
                    FloeCapsuleAction(
                        label = stringResource(R.string.canvas_cancel),
                        onClick = onDismiss,
                    )
                    Spacer(Modifier.width(10.dp))
                    FloeCapsuleAction(
                        label = stringResource(R.string.canvas_failure_reload),
                        onClick = onReload,
                    )
                    Spacer(Modifier.width(10.dp))
                    FloeCapsuleAction(
                        label = stringResource(R.string.canvas_close_anyway),
                        onClick = onClose,
                        tint = Floe.colors.destructive,
                    )
                } else {
                    FloeCapsuleAction(
                        label = stringResource(R.string.canvas_cancel),
                        onClick = onDismiss,
                    )
                    Spacer(Modifier.width(10.dp))
                    FloeCapsuleAction(
                        label = stringResource(R.string.canvas_close),
                        onClick = onClose,
                        tint = Floe.colors.accent,
                    )
                }
            }
        }
    }
}

@Composable
private fun ToolbarTextAction(label: String, enabled: Boolean, onClick: () -> Unit) {
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
