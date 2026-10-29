// SPDX-License-Identifier: MPL-2.0
@file:OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)

package com.floe.android.feature.notes.ui.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
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
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeConfirmDialog
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloePrimaryAction
import com.floe.android.design.FloeSearchField
import com.floe.android.design.FloeText
import com.floe.android.design.FloeUnavailableView
import com.floe.android.design.IconGlyph
import com.floe.android.feature.notes.NoteDocumentKind
import com.floe.android.feature.notes.NoteDocumentSummary
import com.floe.android.feature.notes.ui.NotesIcons
import com.floe.android.feature.notes.ui.R
import com.floe.android.feature.notes.ui.api.NotesOfficeBlankKind
import com.floe.android.feature.notes.ui.presentation.NotesFailure
import com.floe.android.feature.notes.ui.presentation.NotesLibraryFilter
import com.floe.android.feature.notes.ui.presentation.NotesSortOrder
import com.floe.android.feature.notes.ui.state.NotesLibraryController
import com.floe.android.feature.notes.ui.state.NotesWorkspaceController
import kotlinx.coroutines.launch

@Composable
internal fun NotesLibraryPane(
    controller: NotesWorkspaceController,
    modifiers: Modifier = Modifier,
    onRequestSidebar: (() -> Unit)? = null,
) {
    val library = controller.library
    val scope = rememberCoroutineScope()
    var createOpen by remember { mutableStateOf(false) }
    var sortOpen by remember { mutableStateOf(false) }
    var actionsTarget by remember { mutableStateOf<NoteDocumentSummary?>(null) }
    var renameTarget by remember { mutableStateOf<NoteDocumentSummary?>(null) }
    var tagsTarget by remember { mutableStateOf<NoteDocumentSummary?>(null) }
    var moveTarget by remember { mutableStateOf<NoteDocumentSummary?>(null) }
    var coverTarget by remember { mutableStateOf<NoteDocumentSummary?>(null) }
    var deleteTarget by remember { mutableStateOf<NoteDocumentSummary?>(null) }
    var newNotebookName by remember { mutableStateOf<String?>(null) }
    var renameNotebookID by remember { mutableStateOf<String?>(null) }

    Column(modifiers.fillMaxSize().background(Floe.colors.groupedSurface)) {
        NotesToolbar(
            title = stringResource(R.string.notes_title),
            subtitle = stringResource(R.string.notes_document_count, library.counts.documents),
            navigation = {
                if (onRequestSidebar != null) {
                    NotesIconAction(
                        FloeIcons.SidebarToggle,
                        stringResource(R.string.notes_back),
                        onRequestSidebar,
                    )
                }
            },
            actions = {
                if (library.busy) FloeActivityIndicator(Modifier.padding(horizontal = 6.dp))
                NotesIconAction(
                    NotesIcons.Sort,
                    stringResource(R.string.notes_sort),
                    { sortOpen = true },
                )
                NotesIconAction(
                    if (library.grid) NotesIcons.List else NotesIcons.Grid,
                    stringResource(if (library.grid) R.string.notes_layout_list else R.string.notes_layout_grid),
                    { library.toggleGrid() },
                )
                NotesIconAction(
                    FloeIcons.Plus,
                    stringResource(R.string.notes_new),
                    { createOpen = true },
                )
            },
        )
        Column(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp)) {
            FloeSearchField(
                value = library.query,
                onValueChange = library::applySearch,
                placeholder = stringResource(R.string.notes_search_placeholder),
            )
        }
        NotesChipRow {
            FilterChipFor(library, NotesLibraryFilter.RECENT, library.recentDocumentIDs.size)
            FilterChipFor(library, NotesLibraryFilter.ALL, library.counts.documents)
            FilterChipFor(library, NotesLibraryFilter.MIND_MAPS, library.counts.mindMaps)
            FilterChipFor(library, NotesLibraryFilter.FAVORITES, library.counts.favorites)
            FilterChipFor(library, NotesLibraryFilter.TRASH, library.counts.trashed)
        }
        if (library.notebooks.isNotEmpty()) {
            NotesChipRow {
                NotesFilterChip(
                    label = stringResource(R.string.notes_all_notebooks),
                    selected = library.selectedNotebookID == null,
                    onClick = { library.selectNotebook(null) },
                )
                library.notebooks.forEach { notebook ->
                    NotesFilterChip(
                        label = notebook.title,
                        selected = library.selectedNotebookID == notebook.id,
                        onClick = { library.selectNotebook(notebook.id) },
                    )
                }
                if (library.selectedNotebookID != null) {
                    NotesIconAction(
                        FloeIcons.Pencil,
                        stringResource(R.string.notes_rename_notebook),
                        { renameNotebookID = library.selectedNotebookID },
                    )
                }
                NotesIconAction(
                    FloeIcons.Plus,
                    stringResource(R.string.notes_new_notebook),
                    { newNotebookName = "" },
                )
            }
        } else {
            NotesChipRow {
                NotesFilterChip(
                    label = stringResource(R.string.notes_new_notebook),
                    selected = false,
                    onClick = { newNotebookName = "" },
                )
            }
        }
        library.failure?.let { failure ->
            NotesErrorBanner(
                failure = failure,
                onRetry = { scope.launch { library.load(initial = true) } },
                onDismiss = library::clearFailure,
            )
        }
        library.notice?.let { notice ->
            val text = when (notice) {
                com.floe.android.feature.notes.ui.state.NotesLibraryNotice.IMPORTED ->
                    stringResource(R.string.notes_import_done, 1)
                com.floe.android.feature.notes.ui.state.NotesLibraryNotice.IMPORTED_PDF ->
                    stringResource(R.string.notes_import_done, 1)
                com.floe.android.feature.notes.ui.state.NotesLibraryNotice.COVER_UPDATED ->
                    stringResource(R.string.notes_saved)
                com.floe.android.feature.notes.ui.state.NotesLibraryNotice.NOTEBOOK_CREATED ->
                    stringResource(R.string.notes_new_notebook)
                com.floe.android.feature.notes.ui.state.NotesLibraryNotice.TRASH_UPDATED ->
                    stringResource(R.string.notes_trash)
            }
            NotesBanner(
                icon = FloeIcons.CheckCircle,
                text = text,
                tone = Floe.colors.success,
                onDismiss = library::clearNotice,
                dismissLabel = stringResource(R.string.notes_dismiss),
            )
        }

        val visible = library.visibleDocuments()
        Box(Modifier.weight(1f).fillMaxWidth()) {
            when {
                library.loading && library.documents.isEmpty() -> {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        FloeActivityIndicator()
                    }
                }
                library.failure != null && library.documents.isEmpty() -> {
                    FloeUnavailableView(
                        icon = FloeIcons.WarningTriangle,
                        title = stringResource(R.string.notes_open_failed),
                        description = NotesFailureText(library.failure!!),
                        action = {
                            FloePrimaryAction(
                                label = stringResource(R.string.notes_retry),
                                onClick = { scope.launch { library.load(initial = true) } },
                            )
                        },
                    )
                }
                visible.isEmpty() -> {
                    val searching = library.query.isNotBlank()
                    val trashed = library.filter == NotesLibraryFilter.TRASH
                    val emptyAction: (@Composable () -> Unit)? = if (searching || trashed) {
                        null
                    } else {
                        {
                            FloePrimaryAction(
                                label = stringResource(R.string.notes_create),
                                onClick = { createOpen = true },
                            )
                        }
                    }
                    FloeUnavailableView(
                        icon = when {
                            searching -> FloeIcons.Magnifier
                            trashed -> FloeIcons.Trash
                            else -> FloeIcons.BookPages
                        },
                        title = stringResource(
                            when {
                                searching -> R.string.notes_search_empty_title
                                trashed -> R.string.notes_trash_empty_title
                                library.selectedNotebookID != null -> R.string.notes_notebook_empty_title
                                else -> R.string.notes_empty_title
                            },
                        ),
                        description = stringResource(
                            when {
                                searching -> R.string.notes_search_empty_body
                                trashed -> R.string.notes_trash_empty_body
                                library.selectedNotebookID != null -> R.string.notes_notebook_empty_body
                                else -> R.string.notes_empty_body
                            },
                        ),
                        action = emptyAction,
                    )
                }
                library.grid -> {
                    LazyVerticalGrid(
                        columns = GridCells.Adaptive(minSize = 158.dp),
                        contentPadding = PaddingValues(14.dp),
                        horizontalArrangement = Arrangement.spacedBy(14.dp),
                        verticalArrangement = Arrangement.spacedBy(14.dp),
                        modifier = Modifier.fillMaxSize(),
                    ) {
                        items(visible, key = { it.id }) { summary ->
                            NotesLibraryCard(
                                summary = summary,
                                library = library,
                                grid = true,
                                onOpen = { controller.openDocument(summary.id, null) },
                                onMenu = { actionsTarget = summary },
                            )
                        }
                    }
                }
                else -> {
                    LazyColumn(
                        contentPadding = PaddingValues(10.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                        modifier = Modifier.fillMaxSize(),
                    ) {
                        items(visible, key = { it.id }) { summary ->
                            NotesLibraryCard(
                                summary = summary,
                                library = library,
                                grid = false,
                                onOpen = { controller.openDocument(summary.id, null) },
                                onMenu = { actionsTarget = summary },
                            )
                        }
                    }
                }
            }
        }
    }

    NotesCreateSheet(
        visible = createOpen,
        controller = controller,
        onDismiss = { createOpen = false },
    )
    NotesSortSheet(
        visible = sortOpen,
        current = library.sort,
        onSelect = { library.applySort(it); sortOpen = false },
        onDismiss = { sortOpen = false },
    )
    actionsTarget?.let { target ->
        NotesDocumentActionsSheet(
            target = target,
            controller = controller,
            onDismiss = { actionsTarget = null },
            onRename = { renameTarget = target },
            onTags = { tagsTarget = target },
            onMove = { moveTarget = target },
            onCover = { coverTarget = target },
            onDelete = { deleteTarget = target },
        )
    }
    renameTarget?.let { target ->
        NotesNameSheet(
            visible = true,
            title = stringResource(R.string.notes_rename_document_title),
            initial = target.title,
            label = stringResource(R.string.notes_name_placeholder),
            onDismiss = { renameTarget = null },
            onSave = { title ->
                val session = controller.session(target.id)
                if (session != null) session.rename(title) else library.rename(target, title)
            },
        )
    }
    tagsTarget?.let { target ->
        NotesTagsSheet(
            target = target,
            controller = controller,
            onDismiss = { tagsTarget = null },
        )
    }
    moveTarget?.let { target ->
        NotesMoveSheet(
            target = target,
            controller = controller,
            onDismiss = { moveTarget = null },
        )
    }
    coverTarget?.let { target ->
        NotesCoverSheet(
            target = target,
            library = library,
            onDismiss = { coverTarget = null },
        )
    }
    deleteTarget?.let { target ->
        FloeConfirmDialog(
            title = stringResource(R.string.notes_delete_document_title, target.title),
            message = stringResource(R.string.notes_delete_document_body),
            confirmLabel = stringResource(R.string.notes_delete_permanently),
            dismissLabel = stringResource(R.string.notes_cancel),
            onConfirm = {
                deleteTarget = null
                scope.launch {
                    controller.session(target.id)?.let { controller.closeTab(target.id) }
                    library.deletePermanently(target)
                }
            },
            onDismiss = { deleteTarget = null },
        )
    }
    newNotebookName?.let { initial ->
        NotesNameSheet(
            visible = true,
            title = stringResource(R.string.notes_new_notebook),
            initial = initial,
            label = stringResource(R.string.notes_new_notebook_name),
            onDismiss = { newNotebookName = null },
            onSave = { title -> library.createNotebook(title) != null },
        )
    }
    renameNotebookID?.let { id ->
        val notebook = library.notebooks.firstOrNull { it.id == id }
        if (notebook != null) {
            NotesNameSheet(
                visible = true,
                title = stringResource(R.string.notes_rename_notebook),
                initial = notebook.title,
                label = stringResource(R.string.notes_new_notebook_name),
                onDismiss = { renameNotebookID = null },
                onSave = { title -> library.renameNotebook(id, title) },
            )
        }
    }
}

@Composable
private fun FilterChipFor(
    library: NotesLibraryController,
    filter: NotesLibraryFilter,
    count: Int,
) {
    NotesFilterChip(
        label = stringResource(
            when (filter) {
                NotesLibraryFilter.RECENT -> R.string.notes_filter_recent
                NotesLibraryFilter.ALL -> R.string.notes_filter_all
                NotesLibraryFilter.MIND_MAPS -> R.string.notes_filter_mind_maps
                NotesLibraryFilter.FAVORITES -> R.string.notes_filter_favorites
                NotesLibraryFilter.TRASH -> R.string.notes_filter_trash
            },
        ),
        selected = library.filter == filter,
        onClick = { library.applyFilter(filter) },
        count = count,
    )
}

@Composable
private fun NotesLibraryCard(
    summary: NoteDocumentSummary,
    library: NotesLibraryController,
    grid: Boolean,
    onOpen: () -> Unit,
    onMenu: () -> Unit,
) {
    val cover = library.coverFor(summary)
    LaunchedEffect(summary.id, summary.coverRevision, summary.coverResourceID) {
        library.ensureCover(summary)
    }
    val shape = RoundedCornerShape(12.dp)
    val cardModifier = Modifier
        .fillMaxWidth()
        .clip(shape)
        .background(Floe.colors.readingSurface)
        .border(0.5.dp, Floe.colors.chromeHairline, shape)
        .combinedClickable(
            role = Role.Button,
            onClick = onOpen,
            onLongClick = onMenu,
        )
        .padding(if (grid) 10.dp else 8.dp)
    if (grid) {
        Column(cardModifier) {
            CoverBox(
                summary = summary,
                coverBytes = cover,
                library = library,
                modifier = Modifier.fillMaxWidth().height(168.dp),
            )
            Spacer(Modifier.height(9.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                FloeText(
                    summary.title,
                    style = Floe.typography.section,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                if (summary.isFavorite) {
                    IconGlyph(NotesIcons.StarFilled, Floe.colors.pending, 15.dp)
                }
                NotesIconAction(
                    FloeIcons.Ellipsis,
                    stringResource(R.string.notes_document_actions),
                    onMenu,
                    visualSize = 28.dp,
                )
            }
            FloeText(
                NotesSummaryLine(summary),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                maxLines = 1,
            )
            FloeText(
                stringResource(R.string.notes_updated, notesDate(summary.updatedAt)),
                style = Floe.typography.metadata,
                color = Floe.colors.tertiaryLabel,
                maxLines = 1,
            )
            if (summary.deletedAt != null) {
                TrashActions(summary, library)
            }
        }
    } else {
        Row(cardModifier, verticalAlignment = Alignment.Top) {
            CoverBox(
                summary = summary,
                coverBytes = cover,
                library = library,
                modifier = Modifier.width(68.dp).height(84.dp),
            )
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    FloeText(
                        summary.title,
                        style = Floe.typography.bodyEmphasized,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                    if (summary.isFavorite) {
                        IconGlyph(NotesIcons.StarFilled, Floe.colors.pending, 15.dp)
                    }
                    NotesIconAction(
                        FloeIcons.Ellipsis,
                        stringResource(R.string.notes_document_actions),
                        onMenu,
                        visualSize = 28.dp,
                    )
                }
                FloeText(
                    NotesSummaryLine(summary),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                    maxLines = 1,
                )
                FloeText(
                    stringResource(R.string.notes_updated, notesDate(summary.updatedAt)),
                    style = Floe.typography.metadata,
                    color = Floe.colors.tertiaryLabel,
                    maxLines = 1,
                )
                if (summary.deletedAt != null) {
                    TrashActions(summary, library)
                }
            }
        }
    }
}

@Composable
private fun TrashActions(summary: NoteDocumentSummary, library: NotesLibraryController) {
    val scope = rememberCoroutineScope()
    Row(
        modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .heightIn(min = FloeLayout.MinimumTarget)
                .clickable(role = Role.Button) { scope.launch { library.restore(summary) } }
                .padding(horizontal = 4.dp),
            contentAlignment = Alignment.CenterStart,
        ) { FloeText(stringResource(R.string.notes_restore), style = Floe.typography.metadata, color = Floe.colors.accent) }
    }
}

@Composable
private fun CoverBox(
    summary: NoteDocumentSummary,
    coverBytes: ByteArray?,
    library: NotesLibraryController,
    modifier: Modifier,
) {
    val shape = RoundedCornerShape(8.dp)
    if (summary.coverResourceID == null) {
        NotesAutomaticCover(summary, modifier)
        return
    }
    Box(
        modifier = modifier
            .clip(shape)
            .background(Floe.colors.fillTertiary)
            .border(0.5.dp, Floe.colors.chromeHairline, shape),
        contentAlignment = Alignment.Center,
    ) {
        if (coverBytes != null) {
            NotesImageBytes(
                bytes = coverBytes,
                contentDescription = stringResource(R.string.notes_cover_custom),
                modifier = Modifier.fillMaxSize(),
            )
        } else {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                FloeActivityIndicator()
                FloeText(
                    stringResource(R.string.notes_cover_loading),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
        }
    }
}

private enum class NotesCreateKind { NOTE, MIND_MAP, NOTEBOOK, WORD, SHEET, SLIDES, IMPORT }

@Composable
private fun NotesCreateSheet(
    visible: Boolean,
    controller: NotesWorkspaceController,
    onDismiss: () -> Unit,
) {
    if (!visible) return
    val library = controller.library
    val scope = rememberCoroutineScope()
    var kind by remember(visible) { mutableStateOf<NotesCreateKind?>(null) }
    var title by remember(visible) { mutableStateOf("") }
    var saving by remember(visible) { mutableStateOf(false) }
    var localFailure by remember(visible) { mutableStateOf<NotesFailure?>(null) }
    val options = listOf(
        NotesCreateKind.NOTE to (R.string.notes_new_note to NotesIcons.NewNote),
        NotesCreateKind.MIND_MAP to (R.string.notes_new_mind_map to NotesIcons.MindMap),
        NotesCreateKind.NOTEBOOK to (R.string.notes_new_notebook to FloeIcons.Folder),
        NotesCreateKind.WORD to (R.string.notes_new_office_word to NotesIcons.Document),
        NotesCreateKind.SHEET to (R.string.notes_new_office_sheet to NotesIcons.Document),
        NotesCreateKind.SLIDES to (R.string.notes_new_office_slides to NotesIcons.Document),
        NotesCreateKind.IMPORT to (R.string.notes_create_import to NotesIcons.Import),
    )
    com.floe.android.design.FloeActionSheet(
        visible = visible,
        onDismiss = { if (!saving) onDismiss() },
        maxCardWidth = 560.dp,
        maxCardHeightFraction = 0.9f,
    ) {
        Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            FloeText(stringResource(R.string.notes_new), style = Floe.typography.title)
            options.forEach { (value, pair) ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 50.dp)
                        .clip(RoundedCornerShape(12.dp))
                        .background(if (kind == value) Floe.colors.accentFillFaint else Color.Transparent)
                        .clickable(enabled = !saving) { kind = value }
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    IconGlyph(pair.second, if (kind == value) Floe.colors.accent else Floe.colors.secondaryLabel, 22.dp)
                    FloeText(
                        stringResource(pair.first),
                        style = Floe.typography.body,
                        modifier = Modifier.weight(1f),
                    )
                    if (kind == value && value != NotesCreateKind.IMPORT) {
                        IconGlyph(FloeIcons.Checkmark, Floe.colors.accent, 18.dp)
                    }
                }
            }
            if (kind != null && kind != NotesCreateKind.IMPORT) {
                FloePlainFormField(
                    label = stringResource(R.string.notes_name_placeholder),
                    value = title,
                    onValueChange = { title = it },
                    enabled = !saving,
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                )
            }
            (localFailure ?: library.failure)?.let { failure ->
                FloeText(
                    NotesFailureText(failure),
                    style = Floe.typography.metadata,
                    color = Floe.colors.destructive,
                )
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.End),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (saving) FloeActivityIndicator()
                FloeCapsuleAction(
                    stringResource(R.string.notes_cancel),
                    onClick = { if (!saving) onDismiss() },
                    enabled = !saving,
                )
                FloeCapsuleAction(
                    if (kind == NotesCreateKind.IMPORT) {
                        stringResource(R.string.notes_import_choose)
                    } else {
                        stringResource(R.string.notes_create)
                    },
                    onClick = {
                        val selected = kind
                        if (selected != null &&
                            (selected == NotesCreateKind.IMPORT || title.trim().isNotEmpty())
                        ) {
                            saving = true
                            localFailure = null
                            val choice = selected
                            scope.launch {
                            val trimmed = title.trim()
                            val ok = when (choice) {
                                NotesCreateKind.NOTE -> library.createDocument(
                                    NoteDocumentKind.NOTEBOOK,
                                    trimmed,
                                ) != null
                                NotesCreateKind.MIND_MAP -> library.createDocument(
                                    NoteDocumentKind.MIND_MAP,
                                    trimmed,
                                ) != null
                                NotesCreateKind.NOTEBOOK -> library.createNotebook(trimmed) != null
                                NotesCreateKind.WORD -> library.createOfficeBlank(
                                    NotesOfficeBlankKind.WORD,
                                    trimmed,
                                )
                                NotesCreateKind.SHEET -> library.createOfficeBlank(
                                    NotesOfficeBlankKind.SHEET,
                                    trimmed,
                                )
                                NotesCreateKind.SLIDES -> library.createOfficeBlank(
                                    NotesOfficeBlankKind.SLIDES,
                                    trimmed,
                                )
                                NotesCreateKind.IMPORT -> library.importAny()
                            }
                                saving = false
                                if (ok) onDismiss() else localFailure = library.failure
                            }
                        }
                    },
                    enabled = !saving && (kind == NotesCreateKind.IMPORT ||
                        (kind != null && title.trim().isNotEmpty())),
                )
            }
        }
    }
}

@Composable
private fun NotesSortSheet(
    visible: Boolean,
    current: NotesSortOrder,
    onSelect: (NotesSortOrder) -> Unit,
    onDismiss: () -> Unit,
) {
    NotesActionSheet(
        visible = visible,
        title = stringResource(R.string.notes_sort),
        onDismiss = onDismiss,
        actions = NotesSortOrder.entries.map { order ->
            NotesActionItem(
                label = (if (order == current) "✓ " else "") + stringResource(
                    when (order) {
                        NotesSortOrder.UPDATED -> R.string.notes_sort_updated
                        NotesSortOrder.CREATED -> R.string.notes_sort_created
                        NotesSortOrder.TITLE -> R.string.notes_sort_title
                    },
                ),
                icon = NotesIcons.Sort,
                onClick = { onSelect(order) },
            )
        },
    )
}

@Composable
private fun NotesDocumentActionsSheet(
    target: NoteDocumentSummary,
    controller: NotesWorkspaceController,
    onDismiss: () -> Unit,
    onRename: () -> Unit,
    onTags: () -> Unit,
    onMove: () -> Unit,
    onCover: () -> Unit,
    onDelete: () -> Unit,
) {
    val library = controller.library
    val scope = rememberCoroutineScope()
    val actions = if (target.deletedAt != null) {
        listOf(
            NotesActionItem(stringResource(R.string.notes_restore), FloeIcons.Refresh) {
                scope.launch { library.restore(target) }
            },
            NotesActionItem(
                stringResource(R.string.notes_delete_permanently),
                FloeIcons.Trash,
                destructive = true,
                onClick = onDelete,
            ),
        )
    } else {
        listOf(
            NotesActionItem(stringResource(R.string.notes_rename), FloeIcons.Pencil, onClick = onRename),
            NotesActionItem(stringResource(R.string.notes_tags), NotesIcons.Tag, onClick = onTags),
            NotesActionItem(stringResource(R.string.notes_move_to_notebook), FloeIcons.Folder, onClick = onMove),
            NotesActionItem(
                stringResource(
                    if (target.coverResourceID == null) R.string.notes_cover_set else R.string.notes_cover_change,
                ),
                FloeIcons.Photo,
                onClick = onCover,
            ),
            NotesActionItem(
                stringResource(
                    if (target.isFavorite) R.string.notes_remove_favorite else R.string.notes_add_favorite,
                ),
                if (target.isFavorite) NotesIcons.Star else NotesIcons.StarFilled,
                onClick = {
                    scope.launch {
                        controller.session(target.id)?.setFavorite(!target.isFavorite)
                            ?: library.setFavorite(target, !target.isFavorite)
                    }
                },
            ),
            NotesActionItem(stringResource(R.string.notes_duplicate), NotesIcons.Pages) {
                scope.launch { library.duplicate(target) }
            },
            NotesActionItem(
                stringResource(R.string.notes_move_to_trash),
                FloeIcons.Trash,
                destructive = true,
                onClick = {
                    scope.launch {
                        val session = controller.session(target.id)
                        if (session != null) {
                            if (session.setTrashed(true)) controller.closeTab(target.id)
                        } else {
                            library.trash(target)
                        }
                    }
                },
            ),
        )
    }
    NotesActionSheet(
        visible = true,
        title = target.title,
        onDismiss = onDismiss,
        actions = actions,
        message = NotesSummaryLine(target),
    )
}

@Composable
private fun NotesMoveSheet(
    target: NoteDocumentSummary,
    controller: NotesWorkspaceController,
    onDismiss: () -> Unit,
) {
    val library = controller.library
    val scope = rememberCoroutineScope()
    val actions = buildList {
        add(
            NotesActionItem(stringResource(R.string.notes_uncategorized), FloeIcons.Folder) {
                scope.launch {
                    controller.session(target.id)?.moveToNotebook(null)
                        ?: library.moveToNotebook(target, null)
                }
            },
        )
        library.notebooks.forEach { notebook ->
            add(
                NotesActionItem(notebook.title, FloeIcons.Folder) {
                    scope.launch {
                        controller.session(target.id)?.moveToNotebook(notebook.id)
                            ?: library.moveToNotebook(target, notebook.id)
                    }
                },
            )
        }
    }
    NotesActionSheet(
        visible = true,
        title = stringResource(R.string.notes_move_to_notebook),
        onDismiss = onDismiss,
        actions = actions,
    )
}

@Composable
private fun NotesCoverSheet(
    target: NoteDocumentSummary,
    library: NotesLibraryController,
    onDismiss: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    val actions = buildList {
        add(
            NotesActionItem(stringResource(R.string.notes_cover_choose), FloeIcons.Photo, enabled = !busy) {
                scope.launch {
                    busy = true
                    library.setCover(target)
                    busy = false
                    onDismiss()
                }
            },
        )
        if (target.coverResourceID != null) {
            add(
                NotesActionItem(stringResource(R.string.notes_cover_restore), NotesIcons.Pages, enabled = !busy) {
                    scope.launch {
                        busy = true
                        library.restoreAutomaticCover(target)
                        busy = false
                        onDismiss()
                    }
                },
            )
        }
    }
    NotesActionSheet(
        visible = true,
        title = stringResource(R.string.notes_cover_title),
        onDismiss = onDismiss,
        actions = actions,
        message = stringResource(R.string.notes_cover_automatic),
    )
}

@Composable
private fun NotesTagsSheet(
    target: NoteDocumentSummary,
    controller: NotesWorkspaceController,
    onDismiss: () -> Unit,
) {
    val library = controller.library
    val scope = rememberCoroutineScope()
    var tags by remember(target.id) { mutableStateOf(target.tags) }
    var draft by remember(target.id) { mutableStateOf("") }
    var saving by remember { mutableStateOf(false) }
    com.floe.android.design.FloeActionSheet(
        visible = true,
        onDismiss = { if (!saving) onDismiss() },
        maxCardWidth = 520.dp,
    ) {
        Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            FloeText(stringResource(R.string.notes_tags_title), style = Floe.typography.title)
            if (tags.isEmpty()) {
                FloeText(
                    stringResource(R.string.notes_tags_empty),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
            tags.forEach { tag ->
                Row(
                    modifier = Modifier.fillMaxWidth().heightIn(min = FloeLayout.MinimumTarget),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    NotesPill(tag, Floe.colors.accent)
                    Spacer(Modifier.weight(1f))
                    NotesIconAction(
                        FloeIcons.Xmark,
                        stringResource(R.string.notes_tags_remove, tag),
                        { tags = tags - tag },
                        visualSize = 28.dp,
                    )
                }
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Box(Modifier.weight(1f)) {
                    FloePlainFormField(
                        label = stringResource(R.string.notes_tags_placeholder),
                        value = draft,
                        onValueChange = { draft = it },
                        enabled = !saving,
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    )
                }
                FloeCapsuleAction(
                    stringResource(R.string.notes_tags_add),
                    onClick = {
                        val value = draft.trim()
                        if (value.isNotEmpty() && value !in tags) tags = tags + value
                        draft = ""
                    },
                    enabled = !saving && draft.trim().isNotEmpty(),
                )
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.End),
            ) {
                if (saving) FloeActivityIndicator()
                FloeCapsuleAction(stringResource(R.string.notes_cancel), onClick = {
                    if (!saving) onDismiss()
                }, enabled = !saving)
                FloeCapsuleAction(
                    stringResource(R.string.notes_save),
                    onClick = {
                        if (!saving) {
                            saving = true
                            scope.launch {
                                val session = controller.session(target.id)
                                val ok = if (session != null) session.setTags(tags) else library.setTags(target, tags)
                                saving = false
                                if (ok) onDismiss()
                            }
                        }
                    },
                    enabled = !saving,
                )
            }
        }
    }
}
