// SPDX-License-Identifier: MPL-2.0
@file:OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)

package com.floe.android.feature.notes.ui.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.key
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.floe.android.design.Floe
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloeText
import com.floe.android.design.IconGlyph
import com.floe.android.feature.notes.NoteElement
import com.floe.android.feature.notes.NoteElementKind
import com.floe.android.feature.notes.NotePage
import com.floe.android.feature.notes.NotePaper
import com.floe.android.feature.notes.NoteRect
import com.floe.android.feature.notes.ui.NotesIcons
import com.floe.android.feature.notes.ui.R
import com.floe.android.feature.notes.ui.api.NotesInkCreateRequest
import com.floe.android.feature.notes.ui.api.NotesInkSurface
import com.floe.android.feature.notes.ui.api.NotesInkToolKind
import com.floe.android.feature.notes.ui.presentation.NotesEditorTool
import com.floe.android.feature.notes.ui.presentation.NotesElementGeometry
import com.floe.android.feature.notes.ui.presentation.NotesResizeCorner
import com.floe.android.feature.notes.ui.presentation.markdownPlainText
import com.floe.android.feature.notes.ui.presentation.resolveElementText
import com.floe.android.feature.notes.ui.state.NotesDocumentSession
import com.floe.android.feature.notes.ui.state.NotesWorkspaceController
import kotlin.math.min
import kotlin.math.roundToInt
import kotlinx.coroutines.launch

private data class PageMoveDrag(
    val startFrames: Map<String, NoteRect>,
    val deltaX: Double = 0.0,
    val deltaY: Double = 0.0,
)

private data class PageResizeDrag(
    val elementID: String,
    val start: NoteRect,
    val corner: NotesResizeCorner,
    val frame: NoteRect,
)

@Composable
internal fun NotesNotebookEditor(
    controller: NotesWorkspaceController,
    session: NotesDocumentSession,
    onOpenText: (NoteElement) -> Unit,
    onShowPages: () -> Unit,
    onShowInkOptions: () -> Unit,
    onShowFind: () -> Unit,
    onShowInspector: () -> Unit,
) {
    val document = session.document ?: return
    val page = session.currentPage
    val scope = rememberCoroutineScope()
    var shapesOpen by remember { mutableStateOf(false) }
    var showPageMenu by remember { mutableStateOf(false) }

    Column(Modifier.fillMaxSize()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(Floe.colors.chromeSurface)
                .horizontalScroll(rememberScrollState())
                .padding(horizontal = 6.dp, vertical = 3.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            NotesToolButton(
                icon = NotesIcons.Cursor,
                label = stringResource(R.string.notes_tool_select),
                selected = session.editorTool == NotesEditorTool.SELECT,
                onClick = { session.selectEditorTool(NotesEditorTool.SELECT) },
            )
            NotesToolButton(
                icon = NotesIcons.TextTool,
                label = stringResource(R.string.notes_tool_text),
                selected = session.editorTool == NotesEditorTool.TEXT,
                onClick = {
                    session.selectEditorTool(NotesEditorTool.TEXT)
                    val element = session.insertTextElement()
                    if (element != null) onOpenText(element)
                },
            )
            NotesToolButton(
                icon = FloeIcons.Pencil,
                label = stringResource(R.string.notes_tool_pen),
                selected = session.editorTool == NotesEditorTool.INK &&
                    session.inkTool == NotesInkToolKind.PEN,
                onClick = {
                    session.selectEditorTool(NotesEditorTool.INK)
                    session.selectInkTool(NotesInkToolKind.PEN)
                },
            )
            NotesToolButton(
                icon = NotesIcons.Shapes,
                label = stringResource(R.string.notes_tool_marker),
                selected = session.editorTool == NotesEditorTool.INK &&
                    session.inkTool == NotesInkToolKind.MARKER,
                onClick = {
                    session.selectEditorTool(NotesEditorTool.INK)
                    session.selectInkTool(NotesInkToolKind.MARKER)
                },
            )
            NotesToolButton(
                icon = NotesIcons.Eraser,
                label = stringResource(R.string.notes_tool_eraser),
                selected = session.editorTool == NotesEditorTool.INK &&
                    session.inkTool == NotesInkToolKind.ERASER,
                onClick = {
                    session.selectEditorTool(NotesEditorTool.INK)
                    session.selectInkTool(NotesInkToolKind.ERASER)
                },
            )
            NotesToolButton(
                icon = NotesIcons.Lasso,
                label = stringResource(R.string.notes_tool_lasso),
                selected = session.editorTool == NotesEditorTool.INK &&
                    session.inkTool == NotesInkToolKind.LASSO,
                onClick = {
                    session.selectEditorTool(NotesEditorTool.INK)
                    session.selectInkTool(NotesInkToolKind.LASSO)
                },
            )
            NotesVerticalHairline()
            Box {
                NotesToolButton(
                    icon = NotesIcons.Shapes,
                    label = stringResource(R.string.notes_tool_shapes),
                    selected = false,
                    onClick = { shapesOpen = true },
                )
                DropdownMenu(expanded = shapesOpen, onDismissRequest = { shapesOpen = false }) {
                    listOf(
                        NoteElementKind.RECTANGLE to R.string.notes_insert_rectangle,
                        NoteElementKind.ELLIPSE to R.string.notes_insert_ellipse,
                        NoteElementKind.LINE to R.string.notes_insert_line,
                        NoteElementKind.ARROW to R.string.notes_insert_arrow,
                    ).forEach { (kind, label) ->
                        DropdownMenuItem(
                            text = { FloeText(stringResource(label), style = Floe.typography.body) },
                            onClick = {
                                shapesOpen = false
                                session.insertElement(kind)
                            },
                        )
                    }
                }
            }
            NotesToolButton(
                icon = FloeIcons.Photo,
                label = stringResource(R.string.notes_insert_image),
                selected = false,
                onClick = { scope.launch { controller.insertImageIntoActivePage() } },
            )
            NotesToolButton(
                icon = FloeIcons.Pencil,
                label = stringResource(R.string.notes_ink_options),
                selected = false,
                onClick = onShowInkOptions,
            )
            NotesVerticalHairline()
            NotesToolButton(
                icon = NotesIcons.Bookmark,
                label = stringResource(
                    if (page?.isBookmarked == true) R.string.notes_bookmark_remove else R.string.notes_bookmark_add,
                ),
                selected = page?.isBookmarked == true,
                onClick = { page?.let { session.toggleBookmark(it.id) } },
            )
            NotesToolButton(
                icon = NotesIcons.Pages,
                label = stringResource(R.string.notes_pages),
                selected = false,
                onClick = onShowPages,
            )
            NotesToolButton(
                icon = NotesIcons.Layers,
                label = stringResource(R.string.notes_inspector),
                selected = session.selectedElementIDs.isNotEmpty(),
                onClick = onShowInspector,
                enabled = session.selectedElementIDs.isNotEmpty(),
            )
            NotesToolButton(
                icon = FloeIcons.Magnifier,
                label = stringResource(R.string.notes_find),
                selected = false,
                onClick = onShowFind,
            )
            NotesToolButton(
                icon = FloeIcons.Ellipsis,
                label = stringResource(R.string.notes_tool_insert),
                selected = false,
                onClick = { showPageMenu = true },
            )
        }
        FloeDivider()
        if (page == null) {
            Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    FloeText(stringResource(R.string.notes_no_page), style = Floe.typography.body)
                    NotesToolButton(
                        icon = FloeIcons.Plus,
                        label = stringResource(R.string.notes_add_page),
                        selected = false,
                        onClick = { session.addPage(NotePaper.PLAIN) },
                    )
                }
            }
        } else {
            val pageScroll = rememberScrollState()
            LaunchedEffect(page.id, pageScroll.maxValue) {
                if (pageScroll.maxValue > 0 && session.pageScrollFraction > 0f) {
                    pageScroll.scrollTo(
                        (pageScroll.maxValue * session.pageScrollFraction).roundToInt(),
                    )
                }
            }
            DisposableEffect(page.id) {
                onDispose {
                    if (pageScroll.maxValue > 0) {
                        session.setPageScroll(
                            page.id,
                            pageScroll.value.toFloat() / pageScroll.maxValue.toFloat(),
                        )
                    }
                }
            }
            BoxWithConstraints(Modifier.weight(1f).fillMaxWidth()) {
                val density = LocalDensity.current.density
                val available = (maxWidth.value - 28f).coerceAtLeast(140f)
                val fit = (available / page.width.toFloat()).coerceIn(0.2f, 1.4f)
                val scale = (fit * session.pageZoom).coerceIn(0.2f, 5f)
                val displayWidth = (page.width * scale).toFloat()
                val displayHeight = (page.height * scale).toFloat()
                val targetWidthPx = (page.width * scale * density).toInt().coerceIn(320, 4096)
                LaunchedEffect(page.id, document.revision, targetWidthPx) {
                    session.loadArtifacts(page.id, targetWidthPx)
                }
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .verticalScroll(pageScroll)
                        .horizontalScroll(rememberScrollState()),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Box(
                        modifier = Modifier
                            .padding(14.dp)
                            .width(displayWidth.dp)
                            .height(displayHeight.dp),
                    ) {
                        PageSurface(
                            controller = controller,
                            session = session,
                            page = page,
                            document = document,
                            scale = scale,
                            density = density,
                            onOpenText = onOpenText,
                        )
                    }
                }
            }
            PageFooter(
                session = session,
                page = page,
                onShowPages = onShowPages,
                onShowPageMenu = { showPageMenu = true },
            )
        }
    }

    if (showPageMenu) {
        NotesPageActionsSheet(
            session = session,
            page = page,
            visible = true,
            onDismiss = { showPageMenu = false },
            onShowPages = onShowPages,
        )
    }
}

@Composable
private fun PageSurface(
    controller: NotesWorkspaceController,
    session: NotesDocumentSession,
    page: NotePage,
    document: com.floe.android.feature.notes.NoteDocument,
    scale: Float,
    density: Float,
    onOpenText: (NoteElement) -> Unit,
) {
    val artifacts = session.artifacts
    val capabilities = remember { controller.ports.media.capabilities() }
    var moveDrag by remember(page.id) { mutableStateOf<PageMoveDrag?>(null) }
    var resizeDrag by remember(page.id) { mutableStateOf<PageResizeDrag?>(null) }
    var inkReadOnly by remember(session.documentID, page.id) { mutableStateOf(false) }
    var inkLoaded by remember(session.documentID, page.id) { mutableStateOf(false) }
    val inkBytes = session.inkFor(page.id)
    // Never accept strokes before an existing drawing is loaded: a preserved
    // PencilKit resource must not be replaced by a fresh blank FLOEINK draft.
    val inkReady = page.drawingResourceID == null || inkBytes != null
    val inkSurface = remember(page.id, session.documentID, capabilities.inkAuthoring) {
        if (!capabilities.inkAuthoring) {
            null
        } else {
            runCatching {
                controller.ports.media.createInk(
                    NotesInkCreateRequest(
                        documentID = session.documentID,
                        pageID = page.id,
                        pageWidthPt = page.width.toFloat(),
                        pageHeightPt = page.height.toFloat(),
                        tool = session.inkToolSpec(),
                        onDrawingChanged = { bytes -> session.onInkDraft(page.id, bytes) },
                    ),
                )
            }.getOrNull()
        }
    }
    DisposableEffect(inkSurface) {
        onDispose { inkSurface?.dispose() }
    }
    LaunchedEffect(inkSurface, inkBytes) {
        inkSurface?.setDrawing(inkBytes)
        // The host preserves Apple PencilKit/unknown ink bytes but cannot
        // author them. Surface that state instead of a blank editable canvas.
        inkReadOnly = inkSurface?.isReadOnly == true
        inkLoaded = inkSurface != null
    }
    LaunchedEffect(
        inkSurface,
        session.editorTool,
        session.inkTool,
        session.inkColor,
        session.inkWidth,
        session.fingerDrawing,
        session.inkPenOnly,
        inkReadOnly,
        inkReady,
        inkLoaded,
    ) {
        inkSurface?.setTool(session.inkToolSpec())
        inkSurface?.setInteractionEnabled(
            session.editorTool == NotesEditorTool.INK && !inkReadOnly && inkReady && inkLoaded,
        )
    }
    LaunchedEffect(inkSurface) {
        inkSurface?.setOnSelectionChanged { session.onInkSelectionChanged(it) }
    }

    val moveFrames = moveDrag?.let { drag ->
        drag.startFrames.mapValues { (_, frame) ->
            NotesElementGeometry.clampToPage(
                frame.copy(x = frame.x + drag.deltaX, y = frame.y + drag.deltaY),
                page,
            )
        }
    }
    fun frameOf(element: NoteElement): NoteRect {
        resizeDrag?.takeIf { it.elementID == element.id }?.let { return it.frame }
        moveFrames?.get(element.id)?.let { return it }
        return element.frame
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .clip(RoundedCornerShape(6.dp))
            .background(Color.White)
            .border(0.5.dp, Floe.colors.separator, RoundedCornerShape(6.dp)),
    ) {
        Box(
            Modifier
                .fillMaxSize()
                .pointerInput(page.id) { detectTapGestures { session.clearSelection() } },
        )
        if (artifacts?.renderedPdfPage != null) {
            NotesImageBytes(
                bytes = artifacts.renderedPdfPage,
                contentDescription = null,
                modifier = Modifier.fillMaxSize(),
            )
        } else if (artifacts?.backgroundBytes != null) {
            NotesImageBytes(
                bytes = artifacts.backgroundBytes,
                contentDescription = null,
                modifier = Modifier.fillMaxSize(),
            )
        } else {
            PaperBackground(page)
        }
        if (inkSurface != null) {
            key(inkSurface) {
                AndroidView(
                    factory = { inkSurface.view },
                    modifier = Modifier.fillMaxSize(),
                )
            }
        }
        val inkUnavailable = page.drawingResourceID != null &&
            (inkSurface == null || (!inkReady && !session.artifactsLoading))
        if (inkUnavailable) {
            FloeText(
                stringResource(R.string.notes_ink_unavailable),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.align(Alignment.BottomCenter).padding(8.dp),
            )
        }
        if (inkReadOnly && page.drawingResourceID != null) {
            FloeText(
                stringResource(R.string.notes_ink_preserved_read_only),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.align(Alignment.TopCenter).padding(8.dp),
            )
        }
        page.elements.forEach { element ->
            val frame = frameOf(element)
            val selected = element.id in session.selectedElementIDs
            NoteElementView(
                element = element,
                text = resolveElementText(document, element),
                imageBytes = artifacts?.elementImages?.get(element.resourceID),
                frame = frame,
                scale = scale,
                density = density,
                page = page,
                selected = selected,
                tool = session.editorTool,
                onTap = {
                    if (session.editorTool == NotesEditorTool.TEXT && element.kind == NoteElementKind.TEXT) {
                        session.setSelection(setOf(element.id))
                        onOpenText(element)
                    } else {
                        session.setSelection(setOf(element.id))
                    }
                },
                onLongTap = {
                    if (element.id in session.selectedElementIDs) {
                        session.setSelection(session.selectedElementIDs - element.id)
                    } else {
                        session.setSelection(session.selectedElementIDs + element.id)
                    }
                },
                onDragStart = {
                    if (session.editorTool != NotesEditorTool.INK) {
                        val ids = if (element.id in session.selectedElementIDs) {
                            session.selectedElementIDs
                        } else {
                            setOf(element.id).also(session::setSelection)
                        }
                        moveDrag = PageMoveDrag(
                            startFrames = page.elements.filter { it.id in ids }
                                .associate { it.id to it.frame },
                        )
                        resizeDrag = null
                    }
                },
                onDrag = { amount ->
                    moveDrag = moveDrag?.let {
                        it.copy(
                            deltaX = it.deltaX + amount.x / (density * scale),
                            deltaY = it.deltaY + amount.y / (density * scale),
                        )
                    }
                },
                onDragEnd = {
                    val drag = moveDrag
                    if (drag != null) {
                        session.moveSelected(
                            drag.startFrames.mapValues { (_, frame) ->
                                NotesElementGeometry.snap(
                                    NotesElementGeometry.clampToPage(
                                        frame.copy(
                                            x = frame.x + drag.deltaX,
                                            y = frame.y + drag.deltaY,
                                        ),
                                        page,
                                    ),
                                )
                            },
                        )
                    }
                    moveDrag = null
                },
                onResizeStart = { corner ->
                    if (session.selectedElementIDs.size == 1) {
                        resizeDrag = PageResizeDrag(element.id, element.frame, corner, element.frame)
                        moveDrag = null
                    }
                },
                onResize = { corner, amount ->
                    val current = resizeDrag
                    if (current != null) {
                        val start = current.start
                        val totalX = (current.frame.x - current.start.x) + amount.x / (density * scale)
                        val totalY = (current.frame.y - current.start.y) + amount.y / (density * scale)
                        resizeDrag = current.copy(
                            frame = NotesElementGeometry.resize(
                                page = page,
                                frame = start,
                                corner = corner,
                                deltaX = totalX,
                                deltaY = totalY,
                            ),
                        )
                    }
                },
                onResizeEnd = {
                    val drag = resizeDrag
                    if (drag != null) {
                        session.updateElement(element.copy(frame = NotesElementGeometry.snap(drag.frame)))
                    }
                    resizeDrag = null
                },
            )
        }
        val pdfFailure = artifacts?.pdfFailure
        if (pdfFailure != null) {
            FloeText(
                stringResource(
                    if (pdfFailure.code == "passwordRequired") {
                        R.string.notes_pdf_password_unsupported
                    } else {
                        R.string.notes_pdf_render_failed
                    },
                ),
                style = Floe.typography.metadata,
                color = Floe.colors.destructive,
                modifier = Modifier.align(Alignment.TopCenter).padding(8.dp),
            )
        }
        if (session.artifactsLoading) {
            FloeText(
                stringResource(R.string.notes_pdf_rendering),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.align(Alignment.BottomEnd).padding(8.dp),
            )
        }
        val activeInkSurface = inkSurface
        if (session.inkSelectionCount > 0 && activeInkSurface != null) {
            Box(
                Modifier
                    .align(Alignment.BottomCenter)
                    .padding(10.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(Floe.colors.chromeSurface)
                    .padding(6.dp),
            ) {
                FloeCapsuleAction(
                    stringResource(R.string.notes_delete_selection),
                    onClick = {
                        if (activeInkSurface.deleteSelection()) {
                            session.onInkSelectionChanged(0)
                            activeInkSurface.currentDrawing()?.let { session.onInkDraft(page.id, it) }
                        }
                    },
                    tint = Floe.colors.destructive,
                )
            }
        }
        if (inkSurface == null && session.editorTool == NotesEditorTool.INK) {
            FloeText(
                stringResource(R.string.notes_ink_unavailable),
                style = Floe.typography.metadata,
                color = Floe.colors.pending,
                modifier = Modifier.align(Alignment.TopCenter).padding(8.dp),
            )
        }
    }
}

@Composable
private fun PaperBackground(page: NotePage) {
    Canvas(Modifier.fillMaxSize()) {
        drawRect(Color.White)
        val step = 24.dp.toPx()
        val line = Color(0x14000000)
        when (page.paper) {
            NotePaper.PLAIN -> Unit
            NotePaper.RULED -> {
                var y = step
                while (y < size.height) {
                    drawLine(line, Offset(0f, y), Offset(size.width, y), strokeWidth = 1f)
                    y += step
                }
            }
            NotePaper.GRID -> {
                var y = step
                while (y < size.height) {
                    drawLine(line, Offset(0f, y), Offset(size.width, y), strokeWidth = 1f)
                    y += step
                }
                var x = step
                while (x < size.width) {
                    drawLine(line, Offset(x, 0f), Offset(x, size.height), strokeWidth = 1f)
                    x += step
                }
            }
        }
    }
}

@Composable
private fun NoteElementView(
    element: NoteElement,
    text: String,
    imageBytes: ByteArray?,
    frame: NoteRect,
    scale: Float,
    density: Float,
    page: NotePage,
    selected: Boolean,
    tool: NotesEditorTool,
    onTap: () -> Unit,
    onLongTap: () -> Unit,
    onDragStart: () -> Unit,
    onDrag: (Offset) -> Unit,
    onDragEnd: () -> Unit,
    onResizeStart: (NotesResizeCorner) -> Unit,
    onResize: (NotesResizeCorner, Offset) -> Unit,
    onResizeEnd: () -> Unit,
) {
    val x = (frame.x * scale).toFloat().dp
    val y = (frame.y * scale).toFloat().dp
    val width = (frame.width * scale).toFloat().dp
    val height = (frame.height * scale).toFloat().dp
    val color = notesColorFromHex(element.color, Color(0xFF202020))
    Box(
        modifier = Modifier
            .offset(x, y)
            .size(width, height)
            .then(
                if (tool != NotesEditorTool.INK) {
                    Modifier
                        .pointerInput(element.id, tool) {
                            detectDragGestures(
                                onDragStart = { onDragStart() },
                                onDrag = { change, amount ->
                                    change.consume()
                                    onDrag(amount)
                                },
                                onDragEnd = { onDragEnd() },
                                onDragCancel = { onDragEnd() },
                            )
                        }
                        .combinedClickable(
                            role = Role.Button,
                            onClick = onTap,
                            onLongClick = onLongTap,
                        )
                } else {
                    Modifier
                }
            ),
    ) {
        Box(Modifier.fillMaxSize().clip(RoundedCornerShape(3.dp)).clipToBounds()) {
            when (element.kind) {
                NoteElementKind.TEXT -> {
                    val display = if (element.isMarkdown) markdownPlainText(text) else text
                    FloeText(
                        display,
                        style = TextStyle(
                            fontSize = (element.fontSize * scale).coerceAtLeast(6.0).sp,
                            color = color,
                        ),
                        modifier = Modifier.fillMaxSize().padding(4.dp),
                        maxLines = Int.MAX_VALUE,
                        overflow = TextOverflow.Clip,
                    )
                }
                NoteElementKind.IMAGE -> {
                    NotesImageBytes(
                        bytes = imageBytes,
                        contentDescription = null,
                        modifier = Modifier.fillMaxSize(),
                    )
                }
                NoteElementKind.RECTANGLE, NoteElementKind.ELLIPSE,
                NoteElementKind.LINE, NoteElementKind.ARROW -> {
                    Canvas(Modifier.fillMaxSize().padding(1.dp)) {
                        val stroke = Stroke(width = 2.dp.toPx())
                        when (element.kind) {
                            NoteElementKind.RECTANGLE -> drawRect(
                                color = color,
                                topLeft = Offset.Zero,
                                size = size,
                                style = stroke,
                            )
                            NoteElementKind.ELLIPSE -> drawOval(
                                color = color,
                                topLeft = Offset.Zero,
                                size = size,
                                style = stroke,
                            )
                            NoteElementKind.LINE, NoteElementKind.ARROW -> {
                                val start = Offset(0f, 0f)
                                val end = Offset(size.width, size.height)
                                drawLine(color, start, end, strokeWidth = stroke.width)
                                if (element.kind == NoteElementKind.ARROW) {
                                    val path = Path().apply {
                                        moveTo(end.x, end.y)
                                        lineTo(end.x - 12.dp.toPx(), end.y - 2.dp.toPx())
                                        lineTo(end.x - 2.dp.toPx(), end.y - 12.dp.toPx())
                                        close()
                                    }
                                    drawPath(path, color)
                                }
                            }
                            else -> Unit
                        }
                    }
                }
            }
        }
        if (selected) {
            Box(
                Modifier
                    .fillMaxSize()
                    .border(2.dp, Floe.colors.accent, RoundedCornerShape(3.dp)),
            )
            if (tool != NotesEditorTool.INK) {
                listOf(
                    NotesResizeCorner.TOP_LEFT to Alignment.TopStart,
                    NotesResizeCorner.TOP_RIGHT to Alignment.TopEnd,
                    NotesResizeCorner.BOTTOM_LEFT to Alignment.BottomStart,
                    NotesResizeCorner.BOTTOM_RIGHT to Alignment.BottomEnd,
                ).forEach { (corner, alignment) ->
                    Box(
                        modifier = Modifier
                            .align(alignment)
                            .size(22.dp)
                            .offset(
                                x = if (alignment == Alignment.TopStart || alignment == Alignment.BottomStart) (-8).dp else 8.dp,
                                y = if (alignment == Alignment.TopStart || alignment == Alignment.TopEnd) (-8).dp else 8.dp,
                            )
                            .pointerInput(element.id, corner) {
                                detectDragGestures(
                                    onDragStart = { onResizeStart(corner) },
                                    onDrag = { change, amount ->
                                        change.consume()
                                        onResize(corner, amount)
                                    },
                                    onDragEnd = { onResizeEnd() },
                                    onDragCancel = { onResizeEnd() },
                                )
                            },
                        contentAlignment = Alignment.Center,
                    ) {
                        Box(
                            Modifier
                                .size(12.dp)
                                .clip(CircleShape)
                                .background(Floe.colors.readingSurface)
                                .border(2.dp, Floe.colors.accent, CircleShape),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun PageFooter(
    session: NotesDocumentSession,
    page: NotePage,
    onShowPages: () -> Unit,
    onShowPageMenu: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(Floe.colors.chromeSurface)
            .padding(horizontal = 8.dp, vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        NotesIconAction(
            FloeIcons.ChevronBack,
            stringResource(R.string.notes_previous_page),
            {
                val index = session.currentPageIndex ?: 0
                val pages = session.document?.pages.orEmpty()
                if (index > 0) session.setActivePage(pages[index - 1].id)
            },
            enabled = (session.currentPageIndex ?: 0) > 0,
            visualSize = 32.dp,
        )
        NotesIconAction(
            FloeIcons.ChevronForward,
            stringResource(R.string.notes_next_page),
            {
                val index = session.currentPageIndex ?: 0
                val pages = session.document?.pages.orEmpty()
                if (index < pages.size - 1) session.setActivePage(pages[index + 1].id)
            },
            enabled = (session.currentPageIndex ?: 0) < (session.document?.pages?.size ?: 1) - 1,
            visualSize = 32.dp,
        )
        FloeText(
            stringResource(
                R.string.notes_page_of,
                (session.currentPageIndex ?: 0) + 1,
                session.document?.pages?.size ?: 0,
            ),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
        Spacer(Modifier.weight(1f))
        NotesIconAction(
            NotesIcons.Minus,
            stringResource(R.string.notes_zoom_out),
            { session.applyPageZoom(session.pageZoom - 0.1f) },
            visualSize = 32.dp,
        )
        FloeText(
            "${(session.pageZoom * 100).toInt()}%",
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
            modifier = Modifier.width(46.dp),
        )
        NotesIconAction(
            FloeIcons.Plus,
            stringResource(R.string.notes_zoom_in),
            { session.applyPageZoom(session.pageZoom + 0.1f) },
            visualSize = 32.dp,
        )
        NotesIconAction(
            NotesIcons.Pages,
            stringResource(R.string.notes_pages),
            onShowPages,
            visualSize = 32.dp,
        )
        NotesIconAction(
            FloeIcons.Ellipsis,
            stringResource(R.string.notes_paper),
            onShowPageMenu,
            visualSize = 32.dp,
        )
    }
}

@Composable
private fun NotesToolButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    enabled: Boolean = true,
) {
    Box(
        modifier = Modifier
            .size(FloeLayout.MinimumTarget)
            .clip(CircleShape)
            .background(if (selected) Floe.colors.accentFillFaint else Color.Transparent)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics {
                contentDescription = label
                if (!enabled) disabled()
            },
        contentAlignment = Alignment.Center,
    ) {
        IconGlyph(icon, if (enabled) (if (selected) Floe.colors.accent else Floe.colors.label) else Floe.colors.tertiaryLabel, 21.dp)
    }
}
