// SPDX-License-Identifier: MPL-2.0
@file:OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)

package com.floe.android.feature.notes.ui.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Slider
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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActionSheet
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeCheckboxRow
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeInlineSwitch
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloeSegmented
import com.floe.android.design.FloeText
import com.floe.android.design.IconGlyph
import com.floe.android.feature.notes.NoteDocument
import com.floe.android.feature.notes.NoteDocumentKind
import com.floe.android.feature.notes.NoteElement
import com.floe.android.feature.notes.NoteElementKind
import com.floe.android.feature.notes.NotePage
import com.floe.android.feature.notes.NotesEdit
import com.floe.android.feature.notes.ui.NotesIcons
import com.floe.android.feature.notes.ui.R
import com.floe.android.feature.notes.ui.api.NotesIndexingAvailability
import com.floe.android.feature.notes.ui.api.NotesIndexingStatus
import com.floe.android.feature.notes.ui.api.NotesPdfSearchOutcome
import com.floe.android.feature.notes.ui.api.NotesPrintOutcome
import com.floe.android.feature.notes.ui.api.NotesSettingsTarget
import com.floe.android.feature.notes.ui.presentation.NotesFailure
import com.floe.android.feature.notes.ui.presentation.NotesElementGeometry
import com.floe.android.feature.notes.ui.presentation.NotesMarkdownBlock
import com.floe.android.feature.notes.ui.presentation.NoteTextMatch
import com.floe.android.feature.notes.ui.presentation.findTextMatches
import com.floe.android.feature.notes.ui.presentation.parseMarkdownBlocks
import com.floe.android.feature.notes.ui.presentation.planReplaceAll
import com.floe.android.feature.notes.ui.presentation.planReplaceMatch
import com.floe.android.feature.notes.ui.presentation.resolveElementText
import com.floe.android.feature.notes.ui.presentation.toNotesFailure
import com.floe.android.feature.notes.ui.state.NotesDocumentSession
import com.floe.android.feature.notes.ui.state.NotesWorkspaceController
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/* ------------------------------ text editor ------------------------------- */

@Composable
internal fun NotesTextEditorSheet(
    document: NoteDocument,
    element: NoteElement,
    visible: Boolean,
    onDismiss: () -> Unit,
    onSave: (String, Boolean) -> Boolean,
) {
    if (!visible) return
    val initial = remember(element.id) { resolveElementText(document, element) }
    var text by remember(element.id) { mutableStateOf(initial) }
    var markdown by remember(element.id) { mutableStateOf(element.isMarkdown) }
    var preview by remember(element.id) { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    FloeActionSheet(
        visible = true,
        onDismiss = { if (!saving) onDismiss() },
        maxCardWidth = 760.dp,
        maxCardHeightFraction = 0.92f,
    ) {
        Column(Modifier.fillMaxSize().padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                FloeText(stringResource(R.string.notes_text_editor_title), style = Floe.typography.title)
                Spacer(Modifier.weight(1f))
                Box(Modifier.width(190.dp)) {
                    FloeSegmented(
                        options = listOf(
                            stringResource(R.string.notes_text_edit),
                            stringResource(R.string.notes_text_preview),
                        ),
                        selectedIndex = if (preview) 1 else 0,
                        onSelect = { preview = it == 1 },
                    )
                }
            }
            if (!preview) {
                Box(Modifier.weight(1f)) {
                    FloePlainFormField(
                        label = stringResource(R.string.notes_text_placeholder),
                        value = text,
                        onValueChange = { text = it },
                        enabled = !saving,
                        singleLine = false,
                        minLines = 12,
                        maxLines = 24,
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Default),
                    )
                }
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    FloeCheckboxRow(
                        label = stringResource(R.string.notes_inspector_markdown),
                        checked = markdown,
                        onCheckedChange = { markdown = it },
                        modifier = Modifier.weight(1f),
                    )
                    if (text.length > 1_200) {
                        FloeText(
                            stringResource(R.string.notes_text_large_split),
                            style = Floe.typography.metadata,
                            color = Floe.colors.pending,
                            maxLines = 2,
                        )
                    }
                }
            } else {
                Box(
                    Modifier
                        .weight(1f)
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(Floe.colors.sectionCardSurface)
                        .verticalScroll(rememberScrollState())
                        .padding(14.dp),
                ) {
                    MarkdownPreview(text)
                }
            }
            if (failed) {
                FloeText(
                    stringResource(R.string.notes_save_failed),
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
                    stringResource(R.string.notes_save),
                    onClick = {
                        if (!saving && text.trim().isNotEmpty()) {
                            saving = true
                            failed = false
                            val ok = onSave(text, markdown)
                            saving = false
                            if (ok) onDismiss() else failed = true
                        }
                    },
                    enabled = !saving && text.trim().isNotEmpty(),
                )
            }
        }
    }
}

@Composable
private fun MarkdownPreview(text: String) {
    val blocks = remember(text) { parseMarkdownBlocks(text) }
    if (blocks.isEmpty()) {
        FloeText(
            stringResource(R.string.notes_text_empty),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
        return
    }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        blocks.forEach { block ->
            when (block) {
                is NotesMarkdownBlock.Heading -> FloeText(
                    block.text,
                    style = when (block.level) {
                        1 -> Floe.typography.title
                        2 -> Floe.typography.section
                        else -> Floe.typography.bodyEmphasized
                    },
                    modifier = Modifier.padding(top = if (block.level <= 2) 6.dp else 0.dp),
                )
                is NotesMarkdownBlock.Paragraph -> FloeText(block.text)
                is NotesMarkdownBlock.Bullet -> FloeText(
                    (if (block.ordered) "${block.index}. " else "• ") + block.text,
                    modifier = Modifier.padding(start = (block.indent * 16).dp),
                )
                is NotesMarkdownBlock.Quote -> Row {
                    Box(Modifier.width(3.dp).heightIn(min = 24.dp).background(Floe.colors.separator))
                    FloeText(
                        block.text,
                        color = Floe.colors.secondaryLabel,
                        modifier = Modifier.padding(start = 10.dp),
                    )
                }
                is NotesMarkdownBlock.Code -> Box(
                    Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(8.dp))
                        .background(Floe.colors.fillTertiary)
                        .padding(10.dp),
                ) {
                    FloeText(block.text, style = Floe.typography.evidence)
                }
                NotesMarkdownBlock.Divider -> FloeDivider()
            }
        }
    }
}

/* ------------------------------ page actions ------------------------------ */

@Composable
internal fun NotesPageActionsSheet(
    session: NotesDocumentSession,
    page: NotePage?,
    visible: Boolean,
    onDismiss: () -> Unit,
    onShowPages: () -> Unit,
) {
    if (!visible) return
    val document = session.document ?: return
    NotesActionSheet(
        visible = true,
        title = stringResource(R.string.notes_pages),
        onDismiss = onDismiss,
        actions = buildList {
            add(NotesActionItem(stringResource(R.string.notes_paper_plain), FloeIcons.Plus) {
                session.addPage(com.floe.android.feature.notes.NotePaper.PLAIN)
            })
            add(NotesActionItem(stringResource(R.string.notes_paper_ruled), FloeIcons.Plus) {
                session.addPage(com.floe.android.feature.notes.NotePaper.RULED)
            })
            add(NotesActionItem(stringResource(R.string.notes_paper_grid), FloeIcons.Plus) {
                session.addPage(com.floe.android.feature.notes.NotePaper.GRID)
            })
            add(NotesActionItem(stringResource(R.string.notes_pages), NotesIcons.Pages, onClick = onShowPages))
            if (page != null) {
                add(
                    NotesActionItem(
                        stringResource(
                            if (page.isBookmarked) R.string.notes_bookmark_remove else R.string.notes_bookmark_add,
                        ),
                        NotesIcons.Bookmark,
                    ) { session.toggleBookmark(page.id) },
                )
                add(NotesActionItem(stringResource(R.string.notes_duplicate_page), NotesIcons.Pages) {
                    session.duplicatePage(page.id)
                })
                add(
                    NotesActionItem(
                        stringResource(R.string.notes_delete_page),
                        FloeIcons.Trash,
                        destructive = true,
                        enabled = document.pages.size > 1,
                    ) { session.deletePage(page.id) },
                )
            }
        },
    )
}

@Composable
internal fun NotesPagesSheet(
    session: NotesDocumentSession,
    visible: Boolean,
    onDismiss: () -> Unit,
) {
    if (!visible) return
    val document = session.document ?: return
    FloeActionSheet(visible = true, onDismiss = onDismiss, maxCardWidth = 620.dp, maxCardHeightFraction = 0.92f) {
        Column(Modifier.fillMaxSize()) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FloeText(stringResource(R.string.notes_pages), style = Floe.typography.title)
                Spacer(Modifier.weight(1f))
                FloeCapsuleAction(stringResource(R.string.notes_done), onClick = onDismiss)
            }
            FloeDivider()
            LazyColumn(
                modifier = Modifier.weight(1f),
                contentPadding = PaddingValues(vertical = 8.dp),
            ) {
                itemsIndexed(document.pages, key = { _, page -> page.id }) { index, page ->
                    PageRow(
                        session = session,
                        document = document,
                        page = page,
                        index = index,
                        onOpen = {
                            session.setActivePage(page.id)
                            onDismiss()
                        },
                    )
                    FloeDivider(Modifier.padding(start = 92.dp))
                }
            }
            FloeDivider()
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FloeCapsuleAction(
                    stringResource(R.string.notes_add_page),
                    onClick = { session.addPage(com.floe.android.feature.notes.NotePaper.PLAIN) },
                )
                FloeCapsuleAction(
                    stringResource(R.string.notes_paper_ruled),
                    onClick = { session.addPage(com.floe.android.feature.notes.NotePaper.RULED) },
                )
                FloeCapsuleAction(
                    stringResource(R.string.notes_paper_grid),
                    onClick = { session.addPage(com.floe.android.feature.notes.NotePaper.GRID) },
                )
                Spacer(Modifier.weight(1f))
                FloeCapsuleAction(
                    stringResource(R.string.notes_done),
                    onClick = onDismiss,
                )
            }
        }
    }
}

@Composable
private fun PageRow(
    session: NotesDocumentSession,
    document: NoteDocument,
    page: NotePage,
    index: Int,
    onOpen: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var thumbnail by remember(page.id, page.backgroundResourceID, page.drawingResourceID) {
        mutableStateOf<ByteArray?>(null)
    }
    var pageMenu by remember(page.id) { mutableStateOf(false) }
    LaunchedEffect(page.id, page.pdfPageIndex, page.backgroundResourceID) {
        thumbnail = if (page.pdfPageIndex != null) session.pdfThumbnail(page.id, 180) else null
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(role = Role.Button, onClick = onOpen)
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        if (thumbnail != null) {
            NotesImageBytes(
                bytes = thumbnail,
                contentDescription = null,
                modifier = Modifier.width(58.dp).height(74.dp).clip(RoundedCornerShape(4.dp)),
            )
        } else {
            NotesPageMiniPreview(
                page = page,
                document = document,
                modifier = Modifier.width(58.dp).height(74.dp),
            )
        }
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                FloeText(
                    stringResource(R.string.notes_page, index + 1),
                    style = Floe.typography.bodyEmphasized,
                )
                if (page.isBookmarked) {
                    IconGlyph(NotesIcons.BookmarkFilled, Floe.colors.accent, 14.dp)
                }
                if (page.pdfPageIndex != null) {
                    NotesPill(stringResource(R.string.notes_pdf_page), Floe.colors.secondaryLabel)
                }
            }
            FloeText(
                stringResource(R.string.notes_paper),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(2.dp), verticalAlignment = Alignment.CenterVertically) {
            NotesIconAction(
                FloeIcons.ChevronUp,
                stringResource(R.string.notes_move_page_up),
                {
                    if (index > 0) session.movePage(page.id, index - 1)
                },
                enabled = index > 0,
                visualSize = 30.dp,
            )
            NotesIconAction(
                FloeIcons.ChevronDown,
                stringResource(R.string.notes_move_page_down),
                {
                    if (index < document.pages.size - 1) session.movePage(page.id, index + 1)
                },
                enabled = index < document.pages.size - 1,
                visualSize = 30.dp,
            )
            Box {
                NotesIconAction(
                    FloeIcons.Ellipsis,
                    stringResource(R.string.notes_document_actions),
                    { pageMenu = true },
                    visualSize = 30.dp,
                )
                DropdownMenu(expanded = pageMenu, onDismissRequest = { pageMenu = false }) {
                    DropdownMenuItem(
                        text = {
                            FloeText(
                                stringResource(
                                    if (page.isBookmarked) {
                                        R.string.notes_bookmark_remove
                                    } else {
                                        R.string.notes_bookmark_add
                                    },
                                ),
                                style = Floe.typography.body,
                            )
                        },
                        onClick = {
                            pageMenu = false
                            session.toggleBookmark(page.id)
                        },
                    )
                    DropdownMenuItem(
                        text = { FloeText(stringResource(R.string.notes_duplicate_page), style = Floe.typography.body) },
                        onClick = {
                            pageMenu = false
                            session.duplicatePage(page.id)
                        },
                    )
                    DropdownMenuItem(
                        text = { FloeText(stringResource(R.string.notes_delete_page), style = Floe.typography.body) },
                        onClick = {
                            pageMenu = false
                            if (document.pages.size > 1) session.deletePage(page.id)
                        },
                        enabled = document.pages.size > 1,
                    )
                }
            }
        }
    }
}

@Composable
private fun NotesPageMiniPreview(page: NotePage, document: NoteDocument, modifier: Modifier) {
    Canvas(
        modifier
            .clip(RoundedCornerShape(4.dp))
            .background(Color.White)
            .border(0.5.dp, Floe.colors.separator, RoundedCornerShape(4.dp)),
    ) {
        val sx = size.width / page.width.toFloat()
        val sy = size.height / page.height.toFloat()
        if (page.paper != com.floe.android.feature.notes.NotePaper.PLAIN) {
            val step = 14.dp.toPx()
            var y = step
            while (y < size.height) {
                drawLine(Color(0x14000000), Offset(0f, y), Offset(size.width, y), 1f)
                y += step
            }
        }
        page.elements.forEach { element ->
            drawRect(
                color = if (element.kind == com.floe.android.feature.notes.NoteElementKind.IMAGE) {
                    Color(0x1F0081F6)
                } else {
                    Color(0x33202020)
                },
                topLeft = Offset(element.frame.x.toFloat() * sx, element.frame.y.toFloat() * sy),
                size = Size(
                    (element.frame.width.toFloat() * sx).coerceAtLeast(1f),
                    (element.frame.height.toFloat() * sy).coerceAtLeast(1f),
                ),
            )
        }
    }
}

/* --------------------------------- find ---------------------------------- */

private enum class NotesFindNotice { NONE, REPLACED, READ_ONLY, PDF_NEEDS_OCR, PDF_UNAVAILABLE }

@Composable
internal fun NotesFindSheet(
    controller: NotesWorkspaceController,
    session: NotesDocumentSession,
    visible: Boolean,
    onDismiss: () -> Unit,
    onRequestOcr: (() -> Unit)? = null,
) {
    if (!visible) return
    val document = session.document ?: return
    val scope = rememberCoroutineScope()
    var query by remember(visible) { mutableStateOf("") }
    var replacement by remember(visible) { mutableStateOf("") }
    var matchCase by remember(visible) { mutableStateOf(false) }
    var matches by remember(visible) { mutableStateOf<List<NoteTextMatch>>(emptyList()) }
    var pdfOutcome by remember(visible) { mutableStateOf<NotesPdfSearchOutcome?>(null) }
    var searching by remember(visible) { mutableStateOf(false) }
    var notice by remember(visible) { mutableStateOf(NotesFindNotice.NONE) }
    var replacedCount by remember(visible) { mutableStateOf(0) }

    LaunchedEffect(query, matchCase) {
        if (query.isBlank()) {
            matches = emptyList()
            pdfOutcome = null
            return@LaunchedEffect
        }
        searching = true
        delay(180)
        matches = findTextMatches(document, query, matchCase, limit = 300)
        pdfOutcome = if (document.kind == NoteDocumentKind.NOTEBOOK) {
            session.searchPdf(query, matchCase)
        } else {
            null
        }
        searching = false
    }

    FloeActionSheet(visible = true, onDismiss = onDismiss, maxCardWidth = 700.dp, maxCardHeightFraction = 0.92f) {
        Column(Modifier.fillMaxSize().padding(18.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                FloeText(stringResource(R.string.notes_find_title), style = Floe.typography.title)
                Spacer(Modifier.weight(1f))
                if (searching) FloeActivityIndicator()
                FloeCapsuleAction(stringResource(R.string.notes_done), onClick = onDismiss)
            }
            FloePlainFormField(
                label = stringResource(R.string.notes_find_placeholder),
                value = query,
                onValueChange = { query = it },
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            )
            FloePlainFormField(
                label = stringResource(R.string.notes_replace_placeholder),
                value = replacement,
                onValueChange = { replacement = it },
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            )
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FloeCheckboxRow(
                    label = stringResource(R.string.notes_find_case),
                    checked = matchCase,
                    onCheckedChange = { matchCase = it },
                    modifier = Modifier.weight(1f),
                )
                FloeCapsuleAction(
                    stringResource(R.string.notes_replace_all),
                    onClick = {
                        val plan = planReplaceAll(document, query, replacement, matchCase)
                        if (plan.replaced > 0) {
                            session.requestEdits(plan.edits, "Replace all")
                            replacedCount = plan.replaced
                            notice = NotesFindNotice.REPLACED
                        } else if (plan.skippedReadOnly > 0) {
                            notice = NotesFindNotice.READ_ONLY
                        }
                    },
                    enabled = query.isNotBlank() && !searching,
                )
            }
            FloeText(
                stringResource(R.string.notes_find_matches, matches.size),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
            when (notice) {
                NotesFindNotice.REPLACED -> FloeText(
                    stringResource(R.string.notes_find_replaced, replacedCount),
                    style = Floe.typography.metadata,
                    color = Floe.colors.success,
                )
                NotesFindNotice.READ_ONLY -> FloeText(
                    stringResource(R.string.notes_find_index_read_only),
                    style = Floe.typography.metadata,
                    color = Floe.colors.pending,
                )
                NotesFindNotice.PDF_NEEDS_OCR -> FloeText(
                    stringResource(R.string.notes_pdf_text_unavailable),
                    style = Floe.typography.metadata,
                    color = Floe.colors.pending,
                )
                NotesFindNotice.PDF_UNAVAILABLE -> FloeText(
                    stringResource(R.string.notes_pdf_search_empty),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                NotesFindNotice.NONE -> Unit
            }
            if (query.isNotBlank() && matches.isEmpty() && searching.not()) {
                if (pdfOutcome is NotesPdfSearchOutcome.NeedsOcr) {
                    FloeText(
                        stringResource(R.string.notes_pdf_text_unavailable),
                        style = Floe.typography.metadata,
                        color = Floe.colors.pending,
                    )
                    onRequestOcr?.let { requestOcr ->
                        FloeCapsuleAction(
                            stringResource(R.string.notes_ocr_recognize),
                            onClick = requestOcr,
                        )
                    }
                } else {
                    FloeText(
                        stringResource(R.string.notes_no_matches),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                }
            }
            FloeDivider()
            LazyColumn(Modifier.weight(1f)) {
                items(matches, key = { "${it.pageID}:${it.elementID}:${it.nodeID}:${it.utf16Start}" }) { match ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = 48.dp)
                            .clickable(role = Role.Button) {
                                match.pageID?.let(session::setActivePage)
                                match.elementID?.let { session.setSelection(setOf(it)) }
                                match.nodeID?.let { session.selectedMindMapNodeID = it }
                            }
                            .padding(horizontal = 8.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        IconGlyph(
                            if (match.sourceKind == NoteTextMatch.PAGE_TEXT) NotesIcons.ScanText else NotesIcons.TextTool,
                            Floe.colors.secondaryLabel,
                            16.dp,
                        )
                        Column(Modifier.weight(1f)) {
                            FloeText(match.snippet, style = Floe.typography.body, maxLines = 2, overflow = TextOverflow.Ellipsis)
                            FloeText(
                                when {
                                    match.pageID != null -> stringResource(
                                        R.string.notes_page,
                                        (document.pages.indexOfFirst { it.id == match.pageID } + 1),
                                    )
                                    match.nodeID != null -> stringResource(R.string.notes_mindmap_title)
                                    else -> stringResource(R.string.notes_find_document_section)
                                },
                                style = Floe.typography.metadata,
                                color = Floe.colors.secondaryLabel,
                            )
                        }
                        if (match.editable) {
                            NotesIconAction(
                                FloeIcons.Pencil,
                                stringResource(R.string.notes_replace),
                                {
                                    planReplaceMatch(document, match, replacement)?.let { edit ->
                                        session.requestEdits(listOf(edit), "Replace")
                                        notice = NotesFindNotice.REPLACED
                                        replacedCount = 1
                                    }
                                },
                                visualSize = 32.dp,
                            )
                        }
                    }
                }
                val pdf = pdfOutcome
                if (pdf is NotesPdfSearchOutcome.Matches) {
                    items(pdf.hits, key = { "pdf:${it.pageIndex}:${it.snippet}" }) { hit ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .heightIn(min = 48.dp)
                                .clickable(role = Role.Button) {
                                    val target = document.pages.firstOrNull { it.pdfPageIndex == hit.pageIndex }
                                    if (target != null) {
                                        session.setActivePage(target.id)
                                        session.showPdfSearchHighlight(hit.pageIndex, hit.rects)
                                    }
                                }
                                .padding(horizontal = 8.dp, vertical = 6.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            IconGlyph(NotesIcons.ScanText, Floe.colors.secondaryLabel, 16.dp)
                            Column(Modifier.weight(1f)) {
                                FloeText(hit.snippet, style = Floe.typography.body, maxLines = 2, overflow = TextOverflow.Ellipsis)
                                FloeText(
                                    stringResource(R.string.notes_find_pdf_section),
                                    style = Floe.typography.metadata,
                                    color = Floe.colors.secondaryLabel,
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

/* ------------------------------ ink options ------------------------------- */

@Composable
internal fun NotesInkOptionsSheet(
    session: NotesDocumentSession,
    visible: Boolean,
    onDismiss: () -> Unit,
) {
    if (!visible) return
    FloeActionSheet(visible = true, onDismiss = onDismiss, maxCardWidth = 520.dp) {
        Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            FloeText(stringResource(R.string.notes_ink_options), style = Floe.typography.title)
            FloeText(stringResource(R.string.notes_pen_color), style = Floe.typography.section)
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                NotesInkColors.forEach { hex ->
                    val color = notesColorFromHex(hex, Color.Black)
                    Box(
                        modifier = Modifier
                            .size(44.dp)
                            .clip(CircleShape)
                            .background(color)
                            .border(
                                width = if (session.inkColor == hex) 3.dp else 1.dp,
                                color = if (session.inkColor == hex) Floe.colors.accent else Floe.colors.separator,
                                shape = CircleShape,
                            )
                            .clickable(role = Role.Button) { session.selectInkColor(hex) },
                    )
                }
            }
            FloeText(
                "${stringResource(R.string.notes_pen_width)} · ${session.inkWidth.toInt()}",
                style = Floe.typography.section,
            )
            Slider(
                value = session.inkWidth,
                onValueChange = { session.applyInkWidth(it) },
                valueRange = 0.5f..24f,
                steps = 46,
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                FloeText(stringResource(R.string.notes_finger_drawing), modifier = Modifier.weight(1f))
                FloeInlineSwitch(
                    checked = session.fingerDrawing,
                    onCheckedChange = { session.setFingerDrawingEnabled(it) },
                    description = stringResource(R.string.notes_finger_drawing),
                )
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                FloeText(stringResource(R.string.notes_pen_only), modifier = Modifier.weight(1f))
                FloeInlineSwitch(
                    checked = session.inkPenOnly,
                    onCheckedChange = { session.setPenOnly(it) },
                    description = stringResource(R.string.notes_pen_only),
                )
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                FloeCapsuleAction(stringResource(R.string.notes_done), onClick = onDismiss)
            }
        }
    }
}

/* --------------------------------- export -------------------------------- */

private enum class NotesExportState { IDLE, WORKING, READY, CANCELLED, FAILED, UNSUPPORTED }

@Composable
internal fun NotesExportSheet(
    controller: NotesWorkspaceController,
    session: NotesDocumentSession,
    visible: Boolean,
    onDismiss: () -> Unit,
) {
    if (!visible) return
    val document = session.document ?: return
    val scope = rememberCoroutineScope()
    var state by remember(visible) { mutableStateOf(NotesExportState.IDLE) }
    var printed by remember(visible) { mutableStateOf(false) }
    fun run(block: suspend () -> Boolean) {
        if (state == NotesExportState.WORKING) return
        scope.launch {
            state = NotesExportState.WORKING
            val ok = runCatching { block() }.getOrDefault(false)
            state = when {
                ok -> NotesExportState.READY
                controller.lastFailure != null -> NotesExportState.FAILED
                else -> NotesExportState.CANCELLED
            }
        }
    }
    FloeActionSheet(visible = true, onDismiss = { if (state != NotesExportState.WORKING) onDismiss() }, maxCardWidth = 560.dp) {
        Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            FloeText(stringResource(R.string.notes_export), style = Floe.typography.title)
            ExportRow(stringResource(R.string.notes_export_archive), !session.isReadOnly) {
                run { controller.exportArchive(session) }
            }
            if (document.pages.isNotEmpty()) {
                ExportRow(stringResource(R.string.notes_export_pdf), true) {
                    run { controller.exportPdf(session) }
                }
                ExportRow(stringResource(R.string.notes_export_page_image), true) {
                    run { controller.exportCurrentPageImage(session) }
                }
                ExportRow(stringResource(R.string.notes_print), true) {
                    scope.launch {
                        state = NotesExportState.WORKING
                        val outcome = runCatching { controller.printActiveDocument(session) }.getOrNull()
                        state = when (outcome) {
                            NotesPrintOutcome.Launched -> {
                                printed = true
                                NotesExportState.READY
                            }
                            is NotesPrintOutcome.Unavailable -> NotesExportState.UNSUPPORTED
                            is NotesPrintOutcome.Failed, null -> NotesExportState.FAILED
                        }
                    }
                }
            }
            if (document.kind == NoteDocumentKind.MIND_MAP) {
                ExportRow(stringResource(R.string.notes_export_markdown), true) {
                    run { controller.exportOutline(session) }
                }
            } else {
                ExportRow(stringResource(R.string.notes_export_text), true) {
                    run { controller.exportPlainText(session) }
                }
            }
            if (state == NotesExportState.WORKING) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FloeActivityIndicator()
                    FloeText(stringResource(R.string.notes_export_preparing), style = Floe.typography.metadata)
                }
            }
            if (state != NotesExportState.IDLE && state != NotesExportState.WORKING) {
                FloeText(
                    stringResource(
                        when (state) {
                            NotesExportState.READY -> if (printed) R.string.notes_print_launched else R.string.notes_export_ready
                            NotesExportState.CANCELLED -> R.string.notes_export_cancelled
                            NotesExportState.FAILED -> R.string.notes_export_failed
                            NotesExportState.UNSUPPORTED -> R.string.notes_export_unsupported
                            else -> R.string.notes_export_failed
                        },
                    ),
                    style = Floe.typography.metadata,
                    color = if (state == NotesExportState.READY) Floe.colors.success else Floe.colors.secondaryLabel,
                )
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                FloeCapsuleAction(
                    stringResource(R.string.notes_done),
                    onClick = onDismiss,
                    enabled = state != NotesExportState.WORKING,
                )
            }
        }
    }
}

@Composable
private fun ExportRow(label: String, enabled: Boolean, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = FloeLayout.MinimumTarget)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconGlyph(NotesIcons.Share, if (enabled) Floe.colors.label else Floe.colors.tertiaryLabel, 18.dp)
        Spacer(Modifier.width(12.dp))
        FloeText(
            label,
            style = Floe.typography.body,
            color = if (enabled) Floe.colors.label else Floe.colors.tertiaryLabel,
            modifier = Modifier.weight(1f),
        )
    }
}

/* ------------------------------ linked maps ------------------------------- */

@Composable
internal fun NotesLinkedMapsSheet(
    controller: NotesWorkspaceController,
    session: NotesDocumentSession,
    visible: Boolean,
    onDismiss: () -> Unit,
) {
    if (!visible) return
    val document = session.document ?: return
    val scope = rememberCoroutineScope()
    var newTitle by remember(visible) { mutableStateOf("") }
    var creating by remember(visible) { mutableStateOf(false) }
    var failure by remember(visible) { mutableStateOf<NotesFailure?>(null) }
    val links = document.linkedMindMaps.orEmpty()
    FloeActionSheet(visible = true, onDismiss = onDismiss, maxCardWidth = 600.dp, maxCardHeightFraction = 0.9f) {
        Column(Modifier.fillMaxSize().padding(18.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                FloeText(stringResource(R.string.notes_mindmap_linked_maps), style = Floe.typography.title)
                Spacer(Modifier.weight(1f))
                FloeCapsuleAction(stringResource(R.string.notes_done), onClick = onDismiss)
            }
            if (links.isEmpty()) {
                FloeText(
                    stringResource(R.string.notes_mindmap_linked_empty),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
            LazyColumn(Modifier.weight(1f)) {
                items(links, key = { it.id }) { link ->
                    Row(
                        modifier = Modifier.fillMaxWidth().heightIn(min = 50.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        IconGlyph(NotesIcons.MindMap, Floe.colors.accent, 20.dp)
                        Column(
                            Modifier.weight(1f).clickable(role = Role.Button) {
                                scope.launch {
                                    if (controller.openLinkedMap(document.id, session.activePageID, link.documentID)) {
                                        onDismiss()
                                    }
                                }
                            },
                        ) {
                            FloeText(
                                controller.library.documents.firstOrNull { it.id == link.documentID }?.title
                                    ?: stringResource(R.string.notes_mind_map),
                                style = Floe.typography.body,
                                maxLines = 1,
                            )
                            FloeText(
                                link.pageID?.let { pageID ->
                                    stringResource(
                                        R.string.notes_page,
                                        document.pages.indexOfFirst { it.id == pageID } + 1,
                                    )
                                } ?: stringResource(R.string.notes_assistant_context_document),
                                style = Floe.typography.metadata,
                                color = Floe.colors.secondaryLabel,
                            )
                        }
                        NotesIconAction(
                            FloeIcons.Xmark,
                            stringResource(R.string.notes_delete),
                            {
                                session.requestEdits(listOf(NotesEdit.UnlinkMindMap(link.id)), "Unlink map")
                            },
                            visualSize = 30.dp,
                        )
                    }
                }
            }
            FloeDivider()
            FloePlainFormField(
                label = stringResource(R.string.notes_new_mind_map),
                value = newTitle,
                onValueChange = { newTitle = it },
                enabled = !creating,
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            )
            failure?.let {
                FloeText(NotesFailureText(it), style = Floe.typography.metadata, color = Floe.colors.destructive)
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                if (creating) FloeActivityIndicator()
                FloeCapsuleAction(
                    stringResource(R.string.notes_mindmap_create_linked),
                    onClick = {
                        if (!creating && newTitle.trim().isNotEmpty()) {
                            creating = true
                            failure = null
                            scope.launch {
                                val map = session.createLinkedMindMap(newTitle.trim(), session.activePageID)
                                creating = false
                                if (map != null) {
                                    controller.openLinkedMap(document.id, session.activePageID, map)
                                    onDismiss()
                                } else {
                                    failure = session.saveFailure ?: NotesFailure("storageUnavailable")
                                }
                            }
                        }
                    },
                    enabled = !creating && newTitle.trim().isNotEmpty(),
                )
            }
        }
    }
}

/* ---------------------------------- OCR ----------------------------------- */

@Composable
internal fun NotesOcrSheet(
    session: NotesDocumentSession,
    visible: Boolean,
    onDismiss: () -> Unit,
    onOpenSettings: ((NotesSettingsTarget) -> Unit)? = null,
) {
    if (!visible) return
    val page = session.currentPage ?: return
    val scope = rememberCoroutineScope()
    var status by remember(visible) { mutableStateOf<NotesIndexingStatus?>(null) }
    var recognizing by remember(visible) { mutableStateOf(false) }
    var result by remember(visible) { mutableStateOf<String?>(null) }
    var failure by remember(visible) { mutableStateOf<NotesFailure?>(null) }
    LaunchedEffect(visible) {
        status = runCatching { session.indexingStatus() }.getOrNull()
    }
    FloeActionSheet(visible = true, onDismiss = onDismiss, maxCardWidth = 640.dp, maxCardHeightFraction = 0.9f) {
        Column(Modifier.fillMaxSize().padding(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            FloeText(stringResource(R.string.notes_ocr_result_title), style = Floe.typography.title)
            val existing = page.ocrText ?: page.extractedText
            if (existing != null && existing.isNotBlank()) {
                FloeText(stringResource(R.string.notes_ocr_existing_title), style = Floe.typography.section)
                Box(
                    Modifier.weight(1f).fillMaxWidth()
                        .clip(RoundedCornerShape(8.dp))
                        .background(Floe.colors.sectionCardSurface)
                        .verticalScroll(rememberScrollState())
                        .padding(10.dp),
                ) { FloeText(existing) }
            }
            val current = status
            when (current?.availability) {
                null, NotesIndexingAvailability.NOT_CONFIGURED -> {
                    FloeText(
                        stringResource(R.string.notes_ocr_unavailable),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                    onOpenSettings?.let { openSettings ->
                        FloeCapsuleAction(
                            stringResource(R.string.notes_assistant_open_settings),
                            onClick = { openSettings(NotesSettingsTarget.MODELS) },
                        )
                    }
                }
                NotesIndexingAvailability.UNSUPPORTED -> {
                    FloeText(
                        stringResource(R.string.notes_ocr_unavailable),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                }
                NotesIndexingAvailability.READY -> {
                    if (result == null) {
                        FloeCapsuleAction(
                            stringResource(R.string.notes_ocr_recognize),
                            onClick = {
                                if (!recognizing) {
                                    recognizing = true
                                    failure = null
                                    scope.launch {
                                        try {
                                            result = session.recognizeCurrentPage().text
                                        } catch (error: Throwable) {
                                            failure = error.toNotesFailure()
                                        } finally {
                                            recognizing = false
                                        }
                                    }
                                }
                            },
                            enabled = !recognizing,
                        )
                    }
                    if (recognizing) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            FloeActivityIndicator()
                            FloeText(stringResource(R.string.notes_ocr_recognizing), style = Floe.typography.metadata)
                        }
                    }
                    failure?.let {
                        FloeText(NotesFailureText(it), style = Floe.typography.metadata, color = Floe.colors.destructive)
                    }
                    result?.let { text ->
                        Box(
                            Modifier.weight(1f).fillMaxWidth()
                                .clip(RoundedCornerShape(8.dp))
                                .background(Floe.colors.sectionCardSurface)
                                .verticalScroll(rememberScrollState())
                                .padding(10.dp),
                        ) { FloeText(text) }
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            FloeCapsuleAction(
                                stringResource(R.string.notes_ocr_insert_text),
                                onClick = {
                                    if (session.insertRecognizedText(text) != null) onDismiss()
                                },
                            )
                        }
                    }
                }
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                FloeCapsuleAction(stringResource(R.string.notes_done), onClick = onDismiss)
            }
        }
    }
}


/* ----------------------------- element inspector --------------------------- */

@Composable
internal fun NotesElementInspectorSheet(
    controller: NotesWorkspaceController,
    session: NotesDocumentSession,
    visible: Boolean,
    onDismiss: () -> Unit,
    onEditText: (NoteElement) -> Unit,
) {
    if (!visible) return
    val document = session.document ?: return
    val page = session.currentPage ?: return
    val selected = page.elements.filter { it.id in session.selectedElementIDs }
    if (selected.isEmpty()) return
    val single = selected.singleOrNull()
    var frame by remember(single?.id, selected.size) { mutableStateOf(single?.frame) }
    var color by remember(single?.id, selected.size) { mutableStateOf(single?.color ?: "#202020") }
    var fontSize by remember(single?.id) { mutableStateOf(single?.fontSize ?: 20.0) }
    var markdown by remember(single?.id) { mutableStateOf(single?.isMarkdown == true) }
    val source = single?.source
    FloeActionSheet(
        visible = true,
        onDismiss = onDismiss,
        maxCardWidth = 600.dp,
        maxCardHeightFraction = 0.92f,
    ) {
        Column(
            Modifier.fillMaxWidth().padding(20.dp).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            FloeText(
                if (single == null) stringResource(R.string.notes_inspector_selected_element)
                else stringResource(R.string.notes_inspector_page_content),
                style = Floe.typography.title,
            )
            FloeText(
                stringResource(R.string.notes_selection_count, selected.size),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
            if (single != null && single.kind == NoteElementKind.TEXT) {
                FloeCapsuleAction(
                    stringResource(R.string.notes_inspector_edit_text),
                    onClick = { onEditText(single) },
                )
                FloeCheckboxRow(
                    label = stringResource(R.string.notes_inspector_markdown),
                    checked = markdown,
                    onCheckedChange = { markdown = it },
                )
                FloeText(
                    "${stringResource(R.string.notes_inspector_font_size)} · ${fontSize.toInt()}",
                    style = Floe.typography.section,
                )
                Slider(
                    value = fontSize.toFloat(),
                    onValueChange = { fontSize = it.toDouble() },
                    valueRange = 8f..128f,
                )
            }
            FloeText(stringResource(R.string.notes_inspector_color), style = Floe.typography.section)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                NotesInkColors.forEach { hex ->
                    Box(
                        Modifier
                            .size(40.dp)
                            .clip(CircleShape)
                            .background(notesColorFromHex(hex, Color.Black))
                            .border(
                                if (color == hex) 3.dp else 1.dp,
                                if (color == hex) Floe.colors.accent else Floe.colors.separator,
                                CircleShape,
                            )
                            .clickable(role = Role.Button) { color = hex },
                    )
                }
            }
            val currentFrame = frame
            if (single != null && currentFrame != null) {
                FloeText(stringResource(R.string.notes_inspector_position_and_size), style = Floe.typography.section)
                DimensionSlider(
                    label = stringResource(R.string.notes_inspector_x),
                    value = currentFrame.x.toFloat(),
                    range = 0f..(page.width - currentFrame.width).toFloat().coerceAtLeast(1f),
                ) { frame = currentFrame.copy(x = it.toDouble()) }
                DimensionSlider(
                    label = stringResource(R.string.notes_inspector_y),
                    value = currentFrame.y.toFloat(),
                    range = 0f..(page.height - currentFrame.height).toFloat().coerceAtLeast(1f),
                ) { frame = currentFrame.copy(y = it.toDouble()) }
                DimensionSlider(
                    label = stringResource(R.string.notes_inspector_width),
                    value = currentFrame.width.toFloat(),
                    range = 20f..(page.width - currentFrame.x).toFloat().coerceAtLeast(20f),
                ) { frame = currentFrame.copy(width = it.toDouble()) }
                DimensionSlider(
                    label = stringResource(R.string.notes_inspector_height),
                    value = currentFrame.height.toFloat(),
                    range = 20f..(page.height - currentFrame.y).toFloat().coerceAtLeast(20f),
                ) { frame = currentFrame.copy(height = it.toDouble()) }
                FloeCapsuleAction(
                    stringResource(R.string.notes_inspector_center),
                    onClick = {
                        frame = currentFrame.copy(
                            x = ((page.width - currentFrame.width) / 2.0).coerceAtLeast(0.0),
                            y = ((page.height - currentFrame.height) / 2.0).coerceAtLeast(0.0),
                        )
                    },
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FloeCapsuleAction(
                    stringResource(R.string.notes_inspector_layer_front),
                    onClick = { session.reorderSelected(toFront = true) },
                )
                FloeCapsuleAction(
                    stringResource(R.string.notes_inspector_layer_back),
                    onClick = { session.reorderSelected(toFront = false) },
                )
            }
            source?.let { reference ->
                FloeText(
                    stringResource(R.string.notes_inspector_source) + " · " +
                        stringResource(R.string.notes_inspector_cited_revision, reference.revision),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                if (reference.space == com.floe.android.feature.notes.NoteSourceSpace.NOTES) {
                    FloeCapsuleAction(
                        stringResource(R.string.notes_inspector_open_source),
                        onClick = {
                            controller.openSource(reference)
                            onDismiss()
                        },
                    )
                }
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End),
            ) {
                FloeCapsuleAction(
                    stringResource(R.string.notes_inspector_delete),
                    onClick = {
                        session.deleteSelectedElements()
                        onDismiss()
                    },
                    tint = Floe.colors.destructive,
                )
                FloeCapsuleAction(stringResource(R.string.notes_cancel), onClick = onDismiss)
                FloeCapsuleAction(
                    stringResource(R.string.notes_save),
                    onClick = {
                        if (single != null && frame != null) {
                            session.updateElement(
                                single.copy(
                                    frame = NotesElementGeometry.snap(frame!!),
                                    color = color,
                                    fontSize = fontSize,
                                    textFormat = if (single.kind == NoteElementKind.TEXT) {
                                        if (markdown) "markdown" else null
                                    } else {
                                        single.textFormat
                                    },
                                ),
                            )
                        } else {
                            session.updateElements(
                                page.id,
                                selected.map { it.copy(color = color) },
                            )
                        }
                        onDismiss()
                    },
                )
            }
        }
    }
}

@Composable
private fun DimensionSlider(
    label: String,
    value: Float,
    range: ClosedFloatingPointRange<Float>,
    onChange: (Float) -> Unit,
) {
    Column {
        Row(verticalAlignment = Alignment.CenterVertically) {
            FloeText(label, style = Floe.typography.metadata, modifier = Modifier.weight(1f))
            FloeText(value.toInt().toString(), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
        }
        Slider(
            value = value.coerceIn(range.start, range.endInclusive),
            onValueChange = onChange,
            valueRange = range,
        )
    }
}

/* --------------------------- assistant save sheet -------------------------- */

@Composable
internal fun NotesAssistantSaveSheet(
    session: NotesDocumentSession,
    visible: Boolean,
    onDismiss: () -> Unit,
) {
    if (!visible) return
    val document = session.document ?: return
    val text = session.assistant.lastAssistantText()
    if (text == null) {
        FloeActionSheet(visible = true, onDismiss = onDismiss, maxCardWidth = 520.dp) {
            Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                FloeText(stringResource(R.string.notes_assistant_save_to_notes), style = Floe.typography.title)
                FloeText(
                    stringResource(R.string.notes_assistant_empty),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    FloeCapsuleAction(stringResource(R.string.notes_done), onClick = onDismiss)
                }
            }
        }
        return
    }
    val scope = rememberCoroutineScope()
    val title = stringResource(R.string.notes_assistant) + " · " + document.title
    val actions = buildList {
        add(NotesActionItem(stringResource(R.string.notes_assistant_save_new_note), NotesIcons.NewNote) {
            session.assistant.saveAsNewNote(title)
            onDismiss()
        })
        if (document.kind == NoteDocumentKind.NOTEBOOK) {
            add(NotesActionItem(stringResource(R.string.notes_assistant_insert_page), NotesIcons.TextTool) {
                session.assistant.insertOnPage()
                onDismiss()
            })
        }
        if (document.kind == NoteDocumentKind.MIND_MAP) {
            add(NotesActionItem(stringResource(R.string.notes_assistant_add_topic), NotesIcons.MindMap) {
                session.assistant.addSubtopic()
                onDismiss()
            })
        }
    }
    NotesActionSheet(
        visible = true,
        title = stringResource(R.string.notes_assistant_save_to_notes),
        onDismiss = onDismiss,
        actions = actions,
    )
}
