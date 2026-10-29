// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.foundation.focusable
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.isMetaPressed
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActionSheet
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeCapsuleButton
import com.floe.android.design.FloeConfirmDialog
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloeText
import com.floe.android.design.IconGlyph
import com.floe.android.feature.notes.NoteDocumentKind
import com.floe.android.feature.notes.NoteElement
import com.floe.android.feature.notes.ui.NotesIcons
import com.floe.android.feature.notes.ui.R
import com.floe.android.feature.notes.ui.api.NotesWorkspaceCallbacks
import com.floe.android.feature.notes.ui.presentation.NotesFailure
import com.floe.android.feature.notes.ui.presentation.NotesSaveStatus
import com.floe.android.feature.notes.ui.presentation.resolveElementText
import com.floe.android.feature.notes.ui.state.NotesAttachmentOpenResult
import com.floe.android.feature.notes.ui.state.NotesDocumentSession
import com.floe.android.feature.notes.ui.state.NotesOfficeActionResult
import com.floe.android.feature.notes.ui.state.NotesWorkspaceAlert
import com.floe.android.feature.notes.ui.state.NotesWorkspaceController
import kotlinx.coroutines.launch

@Composable
internal fun NotesDocumentPane(
    controller: NotesWorkspaceController,
    session: NotesDocumentSession,
    wide: Boolean,
    compact: Boolean,
    callbacks: NotesWorkspaceCallbacks,
    modifiers: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    val document = session.document
    var showMore by remember(session.documentID) { mutableStateOf(false) }
    var showRename by remember(session.documentID) { mutableStateOf(false) }
    var showTags by remember(session.documentID) { mutableStateOf(false) }
    var showMove by remember(session.documentID) { mutableStateOf(false) }
    var showCover by remember(session.documentID) { mutableStateOf(false) }
    var showTrash by remember(session.documentID) { mutableStateOf(false) }
    var showPages by remember(session.documentID) { mutableStateOf(false) }
    var showFind by remember(session.documentID) { mutableStateOf(false) }
    var showExport by remember(session.documentID) { mutableStateOf(false) }
    var showLinkedMaps by remember(session.documentID) { mutableStateOf(false) }
    var showOcr by remember(session.documentID) { mutableStateOf(false) }
    var showInkOptions by remember(session.documentID) { mutableStateOf(false) }
    var showInspector by remember(session.documentID) { mutableStateOf(false) }
    var showAssistantSave by remember(session.documentID) { mutableStateOf(false) }
    var showTabPicker by remember(session.documentID) { mutableStateOf(false) }
    var textTarget by remember(session.documentID) { mutableStateOf<NoteElement?>(null) }
    var officeMessage by remember(session.documentID) { mutableStateOf<NotesOfficeActionResult?>(null) }
    val focusRequester = remember { FocusRequester() }
    LaunchedEffect(session.documentID) {
        runCatching { focusRequester.requestFocus() }
    }

    Row(
        modifiers
            .fillMaxSize()
            .background(Floe.colors.groupedSurface)
            .focusRequester(focusRequester)
            .focusable()
            .onPreviewKeyEvent { event ->
                if (event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                val shortcut = event.isCtrlPressed || event.isMetaPressed
                when {
                    shortcut && event.key == Key.Z && event.isShiftPressed -> {
                        scope.launch { session.undo(redo = true) }
                        true
                    }
                    shortcut && event.key == Key.Z -> {
                        scope.launch { session.undo(redo = false) }
                        true
                    }
                    shortcut && event.key == Key.Y -> {
                        scope.launch { session.undo(redo = true) }
                        true
                    }
                    shortcut && event.key == Key.S -> {
                        scope.launch { session.retrySave() }
                        true
                    }
                    shortcut && event.key == Key.F -> {
                        showFind = true
                        true
                    }
                    event.key == Key.Delete && session.selectedElementIDs.isNotEmpty() -> {
                        session.deleteSelectedElements()
                        true
                    }
                    event.key == Key.Escape -> {
                        session.clearSelection()
                        true
                    }
                    else -> false
                }
            },
    ) {
        Column(Modifier.weight(1f).fillMaxHeight()) {
            NotesToolbar(
                title = document?.title ?: stringResource(R.string.notes_loading_document),
                subtitle = document?.let {
                    "${NotesKindLabel(it.kind)} · ${NotesSaveStatusLabel(session.saveStatus)}"
                },
                navigation = {
                    NotesIconAction(
                        FloeIcons.ChevronBack,
                        stringResource(R.string.notes_back),
                        { controller.goBack() },
                    )
                },
                actions = {
                    NotesIconAction(
                        NotesIcons.Undo,
                        stringResource(R.string.notes_undo),
                        { scope.launch { session.undo(redo = false) } },
                        enabled = session.canUndo && session.pendingEditCount == 0,
                    )
                    // iOS keeps redo out of the compact header; the title
                    // needs the width. Redo remains available from the
                    // keyboard shortcut and reappears when it is actionable.
                    if (!compact || session.canRedo) {
                        NotesIconAction(
                            NotesIcons.Redo,
                            stringResource(R.string.notes_redo),
                            { scope.launch { session.undo(redo = true) } },
                            enabled = session.canRedo && session.pendingEditCount == 0,
                        )
                    }
                    NotesIconAction(
                        FloeIcons.ChatRole,
                        stringResource(R.string.notes_assistant),
                        { session.assistant.open(); session.assistantOpen = true },
                        tint = if (session.assistantOpen) Floe.colors.accent else Floe.colors.label,
                    )
                    if (wide) {
                        NotesIconAction(
                            FloeIcons.Magnifier,
                            stringResource(R.string.notes_find),
                            { showFind = true },
                        )
                    }
                    NotesIconAction(
                        FloeIcons.Ellipsis,
                        stringResource(R.string.notes_document_actions),
                        { showMore = true },
                    )
                },
            )
            NotesTabsRow(controller = controller, onOpenPicker = { showTabPicker = true })
            NotesStatusStrip(session)
            NotesDocumentBanners(controller, session, scope)
            if (document == null) {
                Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                    if (session.loadStatus == com.floe.android.feature.notes.ui.presentation.NotesLoadStatus.FAILED) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            FloeText(
                                session.loadFailure?.let { NotesFailureText(it) }
                                    ?: stringResource(R.string.notes_open_failed),
                                style = Floe.typography.body,
                            )
                            FloeCapsuleAction(
                                stringResource(R.string.notes_retry),
                                onClick = { scope.launch { session.load() } },
                                modifier = Modifier.padding(top = 8.dp),
                            )
                        }
                    } else {
                        FloeActivityIndicator()
                    }
                }
            } else {
                Box(Modifier.weight(1f).fillMaxWidth()) {
                    when (document.kind) {
                        NoteDocumentKind.NOTEBOOK -> NotesNotebookEditor(
                            controller = controller,
                            session = session,
                            compact = compact,
                            onOpenText = { element -> textTarget = element },
                            onShowPages = { showPages = true },
                            onShowInkOptions = { showInkOptions = true },
                            onShowFind = { showFind = true },
                            onShowInspector = { showInspector = true },
                        )
                        NoteDocumentKind.MIND_MAP -> NotesMindMapEditor(
                            controller = controller,
                            session = session,
                            onShowMore = { showMore = true },
                        )
                        NoteDocumentKind.OFFICE -> NotesOfficePage(
                            controller = controller,
                            session = session,
                            message = officeMessage,
                            onOpen = {
                                scope.launch {
                                    officeMessage = controller.editActiveOfficeDocument()
                                }
                            },
                            onReplace = {
                                scope.launch { controller.replaceActiveOfficeFile() }
                            },
                        )
                        NoteDocumentKind.ENGINEERING -> NotesEngineeringPage(
                            controller = controller,
                            session = session,
                        )
                    }
                }
            }
        }
        if (wide && session.assistant.isOpen) {
            Box(Modifier.width(0.5.dp).fillMaxHeight().background(Floe.colors.separator))
            NotesAssistantPanel(
                controller = controller,
                session = session,
                modifier = Modifier.width(390.dp).fillMaxHeight(),
                onClose = { session.assistant.close(); session.assistantOpen = false },
                onOpenSettings = callbacks.onOpenSettings,
            )
        }
    }

    if (!wide && session.assistant.isOpen) {
        FloeActionSheet(
            visible = true,
            onDismiss = { session.assistant.close(); session.assistantOpen = false },
            maxCardWidth = 560.dp,
            maxCardHeightFraction = 0.92f,
        ) {
            NotesAssistantPanel(
                controller = controller,
                session = session,
                modifier = Modifier.fillMaxSize(),
                onClose = { session.assistant.close(); session.assistantOpen = false },
                onOpenSettings = callbacks.onOpenSettings,
            )
        }
    }

    val doc = session.document
    if (doc != null) {
        val page = session.currentPage
        if (showMore) {
            NotesDocumentMoreSheet(
                controller = controller,
                session = session,
                onDismiss = { showMore = false },
                onRename = { showRename = true },
                onTags = { showTags = true },
                onMove = { showMove = true },
                onCover = { showCover = true },
                onTrash = { showTrash = true },
                onExport = { showExport = true },
                onLinkedMaps = { showLinkedMaps = true },
                onOcr = { showOcr = true },
                onAssistantSave = { showAssistantSave = true },
                onPages = { showPages = true },
                onFind = { showFind = true },
            )
        }
        if (showRename) {
            NotesNameSheet(
                visible = true,
                title = stringResource(R.string.notes_rename_document_title),
                initial = doc.title,
                label = stringResource(R.string.notes_name_placeholder),
                onDismiss = { showRename = false },
                onSave = { title -> session.rename(title) },
            )
        }
        if (showTags) {
            NotesTagsEditorSheet(
                visible = true,
                initialTags = doc.tags,
                onSave = { tags -> session.setTags(tags) },
                onDismiss = { showTags = false },
            )
        }
        if (showMove) {
            NotesMoveToNotebookSheet(
                visible = true,
                notebooks = controller.library.notebooks,
                onPick = { notebookID -> session.moveToNotebook(notebookID) },
                onDismiss = { showMove = false },
            )
        }
        if (showCover) {
            NotesActiveCoverSheet(
                controller = controller,
                session = session,
                onDismiss = { showCover = false },
            )
        }
        if (showTrash) {
            FloeConfirmDialog(
                title = stringResource(R.string.notes_move_to_trash),
                message = stringResource(R.string.notes_delete_document_body),
                confirmLabel = stringResource(R.string.notes_move_to_trash),
                dismissLabel = stringResource(R.string.notes_cancel),
                onConfirm = {
                    showTrash = false
                    scope.launch {
                        if (session.setTrashed(true)) controller.closeTab(session.documentID)
                    }
                },
                onDismiss = { showTrash = false },
            )
        }
        if (showPages) {
            NotesPagesSheet(
                session = session,
                visible = true,
                onDismiss = { showPages = false },
            )
        }
        if (showFind) {
            NotesFindSheet(
                controller = controller,
                session = session,
                visible = true,
                onDismiss = { showFind = false },
                onRequestOcr = {
                    showFind = false
                    showOcr = true
                },
            )
        }
        if (showExport) {
            NotesExportSheet(
                controller = controller,
                session = session,
                visible = true,
                onDismiss = { showExport = false },
            )
        }
        if (showLinkedMaps) {
            NotesLinkedMapsSheet(
                controller = controller,
                session = session,
                visible = true,
                onDismiss = { showLinkedMaps = false },
            )
        }
        if (showOcr) {
            NotesOcrSheet(
                session = session,
                visible = true,
                onDismiss = { showOcr = false },
                onOpenSettings = callbacks.onOpenSettings,
            )
        }
        if (showInkOptions) {
            NotesInkOptionsSheet(
                session = session,
                visible = true,
                onDismiss = { showInkOptions = false },
            )
        }
        if (showInspector) {
            NotesElementInspectorSheet(
                controller = controller,
                session = session,
                visible = true,
                onDismiss = { showInspector = false },
                onEditText = { element ->
                    showInspector = false
                    textTarget = element
                },
            )
        }
        if (showAssistantSave) {
            NotesAssistantSaveSheet(
                session = session,
                visible = true,
                onDismiss = { showAssistantSave = false },
            )
        }
        val target = textTarget
        if (target != null) {
            NotesTextEditorSheet(
                document = doc,
                element = target,
                visible = true,
                onDismiss = { textTarget = null },
                onSave = { text, markdown ->
                    val plan = session.commitElementText(target, text, markdown)
                    plan != null
                },
            )
        }
        if (showTabPicker) {
            NotesTabPickerSheet(
                controller = controller,
                visible = true,
                onDismiss = { showTabPicker = false },
            )
        }
    }
}

@Composable
private fun NotesStatusStrip(session: NotesDocumentSession) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(Floe.colors.chromeSurface)
            .padding(horizontal = 12.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        NotesStatusDot(session.saveStatus)
        FloeText(
            if (session.saveStatus == NotesSaveStatus.BLOCKED && !session.isReadOnly) {
                stringResource(R.string.notes_failure_not_ready)
            } else {
                NotesSaveStatusLabel(session.saveStatus)
            },
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
            maxLines = 1,
        )
        if (session.largeEditPending) {
            FloeText(
                stringResource(R.string.notes_large_edit_notice),
                style = Floe.typography.metadata,
                color = Floe.colors.pending,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Spacer(Modifier.weight(1f))
        if (session.inkSelectionCount > 0) {
            FloeText(
                stringResource(R.string.notes_ink_selection_count, session.inkSelectionCount),
                style = Floe.typography.metadata,
                color = Floe.colors.accent,
                maxLines = 1,
            )
        }
        val page = session.currentPage
        if (page != null && session.document?.kind == NoteDocumentKind.NOTEBOOK) {
            FloeText(
                stringResource(
                    R.string.notes_page_of,
                    (session.currentPageIndex ?: 0) + 1,
                    session.document?.pages?.size ?: 0,
                ),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                maxLines = 1,
            )
        }
    }
    FloeDivider()
}

@Composable
private fun NotesTabsRow(controller: NotesWorkspaceController, onOpenPicker: () -> Unit) {
    val scope = rememberCoroutineScope()
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(Floe.colors.chromeSurface)
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 8.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        controller.tabs.forEach { id ->
            val active = controller.activeDocumentID == id
            val dirty = controller.session(id)?.pendingEditCount?.let { it > 0 } == true
            Row(
                modifier = Modifier
                    .heightIn(min = 40.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .background(if (active) Floe.colors.accentFillFaint else Color.Transparent)
                    .clickable(role = Role.Tab) { controller.activateTab(id) }
                    .padding(start = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (dirty) {
                    Box(Modifier.size(6.dp).clip(RoundedCornerShape(3.dp)).background(Floe.colors.pending))
                    Spacer(Modifier.width(4.dp))
                }
                FloeText(
                    controller.tabTitle(id),
                    style = Floe.typography.metadata,
                    color = if (active) Floe.colors.accent else Floe.colors.secondaryLabel,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.width(120.dp),
                )
                Box(
                    modifier = Modifier
                        .size(FloeLayout.MinimumTarget)
                        .clickable(role = Role.Button) {
                            scope.launch { controller.closeTab(id) }
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    IconGlyph(FloeIcons.Xmark, Floe.colors.tertiaryLabel, 14.dp)
                }
            }
        }
        NotesIconAction(
            FloeIcons.Plus,
            stringResource(R.string.notes_tabs_open),
            onOpenPicker,
            visualSize = 32.dp,
        )
    }
    FloeDivider()
}

@Composable
private fun NotesDocumentBanners(
    controller: NotesWorkspaceController,
    session: NotesDocumentSession,
    scope: kotlinx.coroutines.CoroutineScope,
) {
    controller.alert?.let { alert ->
        NotesBanner(
            icon = FloeIcons.WarningTriangle,
            text = when (alert) {
                NotesWorkspaceAlert.CLOSE_TAB_BLOCKED -> stringResource(R.string.notes_save_failed)
                NotesWorkspaceAlert.NOT_FOUND -> stringResource(R.string.notes_failure_not_found)
                NotesWorkspaceAlert.DOCUMENT_DELETED -> stringResource(R.string.notes_failure_not_found)
            },
            tone = Floe.colors.destructive,
            onDismiss = controller::dismissAlert,
            dismissLabel = stringResource(R.string.notes_dismiss),
        )
    }
    controller.lastFailure?.let { failure ->
        NotesErrorBanner(failure, onDismiss = controller::clearFailure)
    }
    session.document?.deletedAt?.let {
        NotesBanner(
            icon = FloeIcons.Trash,
            text = stringResource(R.string.notes_read_only_deleted),
            tone = Floe.colors.pending,
        )
    }
    when (session.saveStatus) {
        NotesSaveStatus.FAILED -> session.saveFailure?.let { failure ->
            NotesErrorBanner(
                failure = failure,
                onRetry = { scope.launch { session.retrySave() } },
            )
        }
        NotesSaveStatus.CONFLICT -> {
            Column(Modifier.fillMaxWidth().background(Floe.colors.pending.copy(alpha = 0.10f))) {
                NotesBanner(
                    icon = FloeIcons.WarningTriangle,
                    text = stringResource(R.string.notes_conflict_body),
                    tone = Floe.colors.pending,
                    actionLabel = stringResource(R.string.notes_discard_and_reload),
                    onAction = { scope.launch { session.reloadDiscardingPending() } },
                )
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
                    horizontalArrangement = Arrangement.End,
                ) {
                    FloeCapsuleAction(
                        stringResource(R.string.notes_keep_my_edits),
                        onClick = { scope.launch { session.retryWithBase() } },
                    )
                }
            }
        }
        NotesSaveStatus.BLOCKED -> {
            NotesBanner(
                icon = FloeIcons.InfoCircle,
                text = if (session.isReadOnly) stringResource(R.string.notes_read_only_deleted)
                else stringResource(R.string.notes_failure_not_ready),
                tone = Floe.colors.secondaryLabel,
            )
        }
        else -> Unit
    }
    if (session.recoveryKept) {
        NotesBanner(
            icon = FloeIcons.InfoCircle,
            text = stringResource(R.string.notes_recovery_body),
            tone = Floe.colors.pending,
            actionLabel = stringResource(R.string.notes_recovery_restore),
            onAction = { scope.launch { session.resumeAfterRoot() } },
            dismissLabel = stringResource(R.string.notes_recovery_discard),
            onDismiss = { session.discardRecovery() },
        )
    }
    session.externalRevision?.let { revision ->
        if (revision > session.currentRevision) {
            NotesBanner(
                icon = FloeIcons.Refresh,
                text = stringResource(R.string.notes_external_change),
                tone = Floe.colors.accent,
                actionLabel = stringResource(R.string.notes_external_reload),
                onAction = { scope.launch { session.reloadExternal() } },
            )
        }
    }
    if (session.inkSaveStatus == NotesSaveStatus.FAILED) {
        NotesErrorBanner(
            failure = session.inkSaveFailure ?: NotesFailure("storageUnavailable"),
            onRetry = { scope.launch { session.retryInk() } },
        )
    }
}

@Composable
private fun NotesDocumentMoreSheet(
    controller: NotesWorkspaceController,
    session: NotesDocumentSession,
    onDismiss: () -> Unit,
    onRename: () -> Unit,
    onTags: () -> Unit,
    onMove: () -> Unit,
    onCover: () -> Unit,
    onTrash: () -> Unit,
    onExport: () -> Unit,
    onLinkedMaps: () -> Unit,
    onOcr: () -> Unit,
    onAssistantSave: () -> Unit,
    onPages: () -> Unit,
    onFind: () -> Unit,
) {
    val doc = session.document ?: return
    val scope = rememberCoroutineScope()
    val actions = buildList {
        add(NotesActionItem(stringResource(R.string.notes_rename), FloeIcons.Pencil, onClick = onRename))
        add(NotesActionItem(stringResource(R.string.notes_tags), NotesIcons.Tag, onClick = onTags))
        add(NotesActionItem(stringResource(R.string.notes_move_to_notebook), FloeIcons.Folder, onClick = onMove))
        add(NotesActionItem(stringResource(R.string.notes_cover_title), FloeIcons.Photo, onClick = onCover))
        if (doc.kind == NoteDocumentKind.NOTEBOOK) {
            add(NotesActionItem(stringResource(R.string.notes_pages), NotesIcons.Pages, onClick = onPages))
        }
        add(NotesActionItem(stringResource(R.string.notes_find), FloeIcons.Magnifier, onClick = onFind))
        add(NotesActionItem(stringResource(R.string.notes_export), NotesIcons.Share, onClick = onExport))
        if (doc.kind != NoteDocumentKind.MIND_MAP) {
            add(NotesActionItem(stringResource(R.string.notes_mindmap_linked_maps), NotesIcons.MindMap, onClick = onLinkedMaps))
        }
        if (doc.kind == NoteDocumentKind.NOTEBOOK) {
            add(NotesActionItem(stringResource(R.string.notes_ocr_recognize), NotesIcons.ScanText, onClick = onOcr))
        }
        add(NotesActionItem(stringResource(R.string.notes_assistant_save_to_notes), FloeIcons.ChatRole, onClick = onAssistantSave))
        val duplicateSummary = controller.library.documents.firstOrNull { it.id == doc.id }
        add(
            NotesActionItem(
                stringResource(R.string.notes_duplicate),
                NotesIcons.Pages,
                enabled = duplicateSummary != null,
            ) {
                if (duplicateSummary != null) scope.launch { controller.library.duplicate(duplicateSummary) }
            },
        )
        add(
            NotesActionItem(
                stringResource(R.string.notes_move_to_trash),
                FloeIcons.Trash,
                destructive = true,
                onClick = onTrash,
            ),
        )
    }
    NotesActionSheet(
        visible = true,
        title = doc.title,
        onDismiss = onDismiss,
        actions = actions,
    )
}

@Composable
private fun NotesActiveCoverSheet(
    controller: NotesWorkspaceController,
    session: NotesDocumentSession,
    onDismiss: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val summary = controller.library.documents.firstOrNull { it.id == session.documentID }
    var busy by remember { mutableStateOf(false) }
    NotesActionSheet(
        visible = true,
        title = stringResource(R.string.notes_cover_title),
        onDismiss = onDismiss,
        actions = buildList {
            add(
                NotesActionItem(
                    stringResource(R.string.notes_cover_choose),
                    FloeIcons.Photo,
                    enabled = !busy && summary != null,
                ) {
                    scope.launch {
                        busy = true
                        if (summary != null) controller.library.setCover(summary)
                        busy = false
                        onDismiss()
                    }
                },
            )
            if (session.document?.coverResourceID != null) {
                add(
                    NotesActionItem(
                        stringResource(R.string.notes_cover_restore),
                        NotesIcons.Pages,
                        enabled = !busy && summary != null,
                    ) {
                        scope.launch {
                            busy = true
                            if (summary != null) controller.library.restoreAutomaticCover(summary)
                            busy = false
                            onDismiss()
                        }
                    },
                )
            }
        },
    )
}

@Composable
private fun NotesTabPickerSheet(
    controller: NotesWorkspaceController,
    visible: Boolean,
    onDismiss: () -> Unit,
) {
    if (!visible) return
    FloeActionSheet(visible = true, onDismiss = onDismiss, maxCardWidth = 560.dp, maxCardHeightFraction = 0.86f) {
        Column(Modifier.fillMaxSize()) {
            FloeText(
                stringResource(R.string.notes_open_document),
                style = Floe.typography.section,
                modifier = Modifier.padding(20.dp),
            )
            FloeDivider()
            LazyColumn(Modifier.weight(1f)) {
                items(controller.library.documents.filter { it.deletedAt == null }, key = { it.id }) { summary ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = 52.dp)
                            .clickable(role = Role.Button) {
                                controller.openDocument(summary.id, null)
                                onDismiss()
                            }
                            .padding(horizontal = 20.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        IconGlyph(NotesKindIcon(summary.kind), Floe.colors.secondaryLabel, 20.dp)
                        Column(Modifier.weight(1f)) {
                            FloeText(summary.title, style = Floe.typography.body, maxLines = 1)
                            FloeText(
                                NotesSummaryLine(summary),
                                style = Floe.typography.metadata,
                                color = Floe.colors.secondaryLabel,
                                maxLines = 1,
                            )
                        }
                    }
                    FloeDivider(Modifier.padding(start = 52.dp))
                }
            }
            Row(
                modifier = Modifier.fillMaxWidth().padding(16.dp),
                horizontalArrangement = Arrangement.End,
            ) {
                FloeCapsuleAction(stringResource(R.string.notes_cancel), onClick = onDismiss)
            }
        }
    }
}

@Composable
private fun NotesOfficePage(
    controller: NotesWorkspaceController,
    session: NotesDocumentSession,
    message: NotesOfficeActionResult?,
    onOpen: () -> Unit,
    onReplace: () -> Unit,
) {
    val doc = session.document ?: return
    var preview by remember(session.documentID, doc.revision, doc.officePreviewSourceID) {
        mutableStateOf<ByteArray?>(null)
    }
    val previewID = doc.matchingOfficePreviewResourceID
    LaunchedEffect(previewID) {
        preview = if (previewID != null) {
            runCatching { controller.resources.readAll(previewID, maxBytes = 16L * 1024L * 1024L) }
                .getOrNull()
        } else {
            null
        }
    }
    Column(
        modifier = Modifier.fillMaxSize().padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            IconGlyph(NotesIcons.Document, Floe.colors.accent, 42.dp)
            Column(Modifier.weight(1f)) {
                FloeText(
                    doc.officeFileName ?: stringResource(R.string.notes_office_file),
                    style = Floe.typography.section,
                    maxLines = 2,
                )
                FloeText(
                    NotesKindLabel(doc.kind),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
        }
        if (preview != null) {
            NotesImageBytes(
                bytes = preview,
                contentDescription = doc.officeFileName,
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f)
                    .clip(RoundedCornerShape(10.dp))
                    .background(Floe.colors.readingSurface),
            )
        } else {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f)
                    .clip(RoundedCornerShape(10.dp))
                    .background(Floe.colors.readingSurface),
                contentAlignment = Alignment.Center,
            ) {
                FloeText(
                    stringResource(R.string.notes_office_preview_missing),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
        }
        message?.let {
            FloeText(
                stringResource(
                    when (it) {
                        NotesOfficeActionResult.SAVED -> R.string.notes_office_saved
                        NotesOfficeActionResult.NO_CHANGES -> R.string.notes_office_no_changes
                        NotesOfficeActionResult.UNAVAILABLE -> R.string.notes_office_unsupported
                        NotesOfficeActionResult.FAILED -> R.string.notes_office_failed
                    },
                ),
                style = Floe.typography.metadata,
                color = if (it == NotesOfficeActionResult.SAVED) Floe.colors.success else Floe.colors.secondaryLabel,
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            FloeCapsuleButton(
                stringResource(R.string.notes_office_open_editor),
                onClick = onOpen,
                modifier = Modifier.weight(1f),
                prominent = true,
            )
            FloeCapsuleButton(
                stringResource(R.string.notes_office_replace),
                onClick = onReplace,
                modifier = Modifier.weight(1f),
            )
        }
    }
}

@Composable
private fun NotesEngineeringPage(
    controller: NotesWorkspaceController,
    session: NotesDocumentSession,
) {
    val doc = session.document ?: return
    val scope = rememberCoroutineScope()
    var message by remember(session.documentID) { mutableStateOf<NotesAttachmentOpenResult?>(null) }
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        IconGlyph(NotesIcons.Document, Floe.colors.secondaryLabel, 54.dp)
        FloeText(
            doc.engineeringFileName ?: stringResource(R.string.notes_engineering_file),
            style = Floe.typography.section,
            modifier = Modifier.padding(top = 12.dp),
        )
        FloeText(
            stringResource(R.string.notes_engineering_read_only),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
            modifier = Modifier.padding(top = 4.dp),
        )
        message?.let {
            FloeText(
                stringResource(
                    when (it) {
                        NotesAttachmentOpenResult.OPENED -> R.string.notes_open_external
                        NotesAttachmentOpenResult.UNAVAILABLE -> R.string.notes_engineering_unsupported
                        NotesAttachmentOpenResult.FAILED -> R.string.notes_attachment_unavailable
                    },
                ),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.padding(top = 6.dp),
            )
        }
        FloeCapsuleButton(
            stringResource(R.string.notes_engineering_open),
            onClick = { scope.launch { message = controller.openActiveEngineeringAttachment() } },
            modifier = Modifier.padding(top = 18.dp).width(260.dp),
            prominent = true,
        )
    }
}
