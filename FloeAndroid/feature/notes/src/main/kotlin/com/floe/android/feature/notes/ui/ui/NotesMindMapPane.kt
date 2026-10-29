// SPDX-License-Identifier: MPL-2.0
@file:OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)

package com.floe.android.feature.notes.ui.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTransformGestures
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActionSheet
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloeText
import com.floe.android.design.FloeUnavailableView
import com.floe.android.design.IconGlyph
import com.floe.android.feature.notes.MindMapNode
import com.floe.android.feature.notes.NoteDocument
import com.floe.android.feature.notes.NoteDocumentKind
import com.floe.android.feature.notes.NotesEdit
import com.floe.android.feature.notes.ui.NotesIcons
import com.floe.android.feature.notes.ui.R
import com.floe.android.feature.notes.ui.api.NotesOpenAttachmentOutcome
import com.floe.android.feature.notes.ui.api.NotesOpenAttachmentRequest
import com.floe.android.feature.notes.ui.presentation.MindMapLayoutDirection
import com.floe.android.feature.notes.ui.presentation.MindMapLayoutEngine
import com.floe.android.feature.notes.ui.state.NotesDocumentSession
import com.floe.android.feature.notes.ui.state.NotesWorkspaceController
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlinx.coroutines.launch

@Composable
internal fun NotesMindMapEditor(
    controller: NotesWorkspaceController,
    session: NotesDocumentSession,
    onShowMore: () -> Unit,
) {
    val document = session.document ?: return
    val scope = rememberCoroutineScope()
    var showLayout by remember { mutableStateOf(false) }
    var showConnections by remember { mutableStateOf(false) }
    var editingNode by remember { mutableStateOf<MindMapNode?>(null) }
    var connectSource by remember { mutableStateOf<String?>(null) }
    val selectedNode = session.nodeByID(session.selectedMindMapNodeID)
    val root = document.nodes.firstOrNull { it.parentID == null }
    val newTopicTitle = stringResource(R.string.notes_mindmap_new_topic)

    if (document.nodes.isEmpty()) {
        FloeUnavailableView(
            icon = NotesIcons.MindMap,
            title = stringResource(R.string.notes_mindmap_empty),
            description = stringResource(R.string.notes_mindmap_empty),
            action = {
                FloeCapsuleAction(
                    stringResource(R.string.notes_mindmap_add_central),
                    onClick = {
                        session.addMindMapRoot(document.title)
                    },
                )
            },
        )
        return
    }

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
            NotesIconAction(
                NotesIcons.MindMap,
                stringResource(R.string.notes_mindmap_outline),
                { session.showOutline = !session.showOutline },
                tint = if (session.showOutline) Floe.colors.accent else Floe.colors.label,
                visualSize = 36.dp,
            )
            if (!session.showOutline) {
                NotesIconAction(
                    FloeIcons.Plus,
                    stringResource(R.string.notes_mindmap_add_child),
                    {
                        val reference = selectedNode ?: root
                        if (reference != null) {
                            session.addMindMapChild(reference.id, newTopicTitle)
                        }
                    },
                    enabled = selectedNode != null || root != null,
                    visualSize = 36.dp,
                )
                NotesIconAction(
                    NotesIcons.MindMap,
                    stringResource(R.string.notes_mindmap_add_sibling),
                    {
                        val reference = selectedNode
                        if (reference?.parentID != null) {
                            session.addMindMapSibling(reference.id, newTopicTitle)
                        }
                    },
                    enabled = selectedNode?.parentID != null,
                    visualSize = 36.dp,
                )
                NotesIconAction(
                    NotesIcons.Connect,
                    stringResource(R.string.notes_mindmap_connect),
                    {
                        if (connectSource == null) {
                            connectSource = selectedNode?.id ?: root?.id
                        } else {
                            connectSource = null
                        }
                    },
                    tint = if (connectSource != null) Floe.colors.accent else Floe.colors.label,
                    visualSize = 36.dp,
                )
                NotesIconAction(
                    NotesIcons.Layers,
                    stringResource(R.string.notes_mindmap_connections),
                    { showConnections = true },
                    enabled = document.connections.isNotEmpty(),
                    visualSize = 36.dp,
                )
                NotesIconAction(
                    NotesIcons.Sort,
                    stringResource(R.string.notes_mindmap_layout),
                    { showLayout = true },
                    visualSize = 36.dp,
                )
            }
            NotesIconAction(
                FloeIcons.Ellipsis,
                stringResource(R.string.notes_document_actions),
                onShowMore,
                visualSize = 36.dp,
            )
        }
        FloeDivider()
        if (connectSource != null) {
            NotesBanner(
                icon = NotesIcons.Connect,
                text = stringResource(R.string.notes_mindmap_connect_hint),
                tone = Floe.colors.accent,
            )
        }
        Box(Modifier.weight(1f).fillMaxWidth()) {
            if (session.showOutline) {
                MindMapOutline(
                    controller = controller,
                    session = session,
                    document = document,
                    onEdit = { editingNode = it },
                    onAddChild = { node -> session.addMindMapChild(node.id, newTopicTitle) },
                    onDelete = { node -> session.deleteMindMapBranch(node.id) },
                )
            } else {
                MindMapCanvas(
                    controller = controller,
                    session = session,
                    document = document,
                    connectSource = connectSource,
                    onNodeSelected = { node ->
                        if (connectSource != null) {
                            if (connectSource == node.id) {
                                connectSource = null
                            } else {
                                val source = connectSource
                                if (source != null) {
                                    session.connectMindMapNodes(source, node.id)
                                    connectSource = null
                                }
                            }
                        } else {
                            session.selectedMindMapNodeID = node.id
                        }
                    },
                    onNodeLongPress = { node -> editingNode = node },
                    onNodeMoved = { node, frame ->
                        session.setMindMapNodePosition(node.id, frame.x, frame.y)
                    },
                )
            }
        }
    }

    if (showLayout) {
        NotesActionSheet(
            visible = true,
            title = stringResource(R.string.notes_mindmap_layout),
            onDismiss = { showLayout = false },
            actions = listOf(
                NotesActionItem(stringResource(R.string.notes_mindmap_layout_right), NotesIcons.MindMap) {
                    session.setMindMapDirection(MindMapLayoutDirection.RIGHT)
                },
                NotesActionItem(stringResource(R.string.notes_mindmap_layout_left), NotesIcons.MindMap) {
                    session.setMindMapDirection(MindMapLayoutDirection.LEFT)
                },
                NotesActionItem(stringResource(R.string.notes_mindmap_layout_down), NotesIcons.MindMap) {
                    session.setMindMapDirection(MindMapLayoutDirection.DOWN)
                },
                NotesActionItem(stringResource(R.string.notes_mindmap_fit), NotesIcons.Fit) {
                    session.resetMindMapPositions()
                },
            ),
        )
    }
    if (showConnections) {
        FloeActionSheet(visible = true, onDismiss = { showConnections = false }, maxCardWidth = 560.dp) {
            Column(Modifier.fillMaxWidth().padding(18.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                FloeText(stringResource(R.string.notes_mindmap_connections), style = Floe.typography.title)
                LazyColumn(Modifier.heightIn(max = 440.dp)) {
                    items(document.connections, key = { it.id }) { connection ->
                        val from = document.nodes.firstOrNull { it.id == connection.from }?.title.orEmpty()
                        val to = document.nodes.firstOrNull { it.id == connection.to }?.title.orEmpty()
                        Row(
                            modifier = Modifier.fillMaxWidth().heightIn(min = FloeLayout.MinimumTarget),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            IconGlyph(NotesIcons.Connect, Floe.colors.accent, 18.dp)
                            FloeText("$from → $to", style = Floe.typography.body, modifier = Modifier.weight(1f))
                            NotesIconAction(
                                FloeIcons.Trash,
                                stringResource(R.string.notes_mindmap_delete_connection),
                                { session.deleteMindMapConnection(connection.id) },
                                visualSize = 30.dp,
                            )
                        }
                    }
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    FloeCapsuleAction(stringResource(R.string.notes_done), onClick = { showConnections = false })
                }
            }
        }
    }
    editingNode?.let { node ->
        NotesMindMapNodeSheet(
            controller = controller,
            session = session,
            node = node,
            onDismiss = { editingNode = null },
        )
    }
}

@Composable
private fun MindMapOutline(
    controller: NotesWorkspaceController,
    session: NotesDocumentSession,
    document: NoteDocument,
    onEdit: (MindMapNode) -> Unit,
    onAddChild: (MindMapNode) -> Unit,
    onDelete: (MindMapNode) -> Unit,
) {
    val outline = remember(document.nodes, document.connections) {
        MindMapLayoutEngine.outline(document)
    }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = androidx.compose.foundation.layout.PaddingValues(12.dp)) {
        items(outline, key = { it.first.id }) { (node, depth) ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = FloeLayout.MinimumTarget)
                    .clickable(role = Role.Button) {
                        session.selectedMindMapNodeID = node.id
                        onEdit(node)
                    }
                    .padding(start = (min(depth, 12) * 16).dp, top = 4.dp, bottom = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                if (node.isCollapsed) {
                    IconGlyph(FloeIcons.ChevronForward, Floe.colors.secondaryLabel, 14.dp)
                } else {
                    IconGlyph(FloeIcons.ChevronDown, Floe.colors.secondaryLabel, 14.dp)
                }
                FloeText(
                    node.title,
                    style = Floe.typography.body,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                NotesIconAction(
                    FloeIcons.Plus,
                    stringResource(R.string.notes_mindmap_add_child),
                    { onAddChild(node) },
                    visualSize = 28.dp,
                )
                if (node.parentID != null) {
                    NotesIconAction(
                        FloeIcons.Trash,
                        stringResource(R.string.notes_mindmap_delete_branch),
                        { onDelete(node) },
                        visualSize = 28.dp,
                    )
                }
            }
        }
    }
}

@Composable
private fun MindMapCanvas(
    controller: NotesWorkspaceController,
    session: NotesDocumentSession,
    document: NoteDocument,
    connectSource: String?,
    onNodeSelected: (MindMapNode) -> Unit,
    onNodeLongPress: (MindMapNode) -> Unit,
    onNodeMoved: (MindMapNode, com.floe.android.feature.notes.NoteRect) -> Unit,
) {
    val layout = remember(document.nodes, document.connections, document.mindMapDirection) {
        MindMapLayoutEngine.layout(document)
    }
    val originX = layout.bounds.x - 90.0
    val originY = layout.bounds.y - 90.0
    val worldWidth = (layout.bounds.width + 180.0).coerceAtLeast(320.0)
    val worldHeight = (layout.bounds.height + 180.0).coerceAtLeast(320.0)
    var scale by remember(document.id) { mutableStateOf(1f) }
    var panX by remember(document.id) { mutableStateOf(0f) }
    var panY by remember(document.id) { mutableStateOf(0f) }
    var fitted by remember(document.id) { mutableStateOf(false) }
    var dragNodeID by remember { mutableStateOf<String?>(null) }
    var dragDX by remember { mutableStateOf(0.0) }
    var dragDY by remember { mutableStateOf(0.0) }
    val density = LocalDensity.current.density

    BoxWithConstraints(Modifier.fillMaxSize().clipToBounds()) {
        val viewWidthPx = maxWidth.value * density
        val viewHeightPx = maxHeight.value * density
        LaunchedEffect(document.id, maxWidth, maxHeight, layout.bounds) {
            if (!fitted) {
                fitted = true
                val worldWidthPx = (worldWidth * density).toFloat()
                val worldHeightPx = (worldHeight * density).toFloat()
                scale = min(1.4f, min(viewWidthPx / worldWidthPx, viewHeightPx / worldHeightPx) * 0.92f)
                    .coerceAtLeast(0.2f)
                panX = (viewWidthPx - worldWidthPx * scale) / 2f
                panY = (viewHeightPx - worldHeightPx * scale) / 2f
            }
        }
        Box(
            Modifier
                .fillMaxSize()
                .pointerInput(Unit) {
                    detectTransformGestures { _, pan, zoom, _ ->
                        scale = (scale * zoom).coerceIn(0.2f, 2.8f)
                        panX += pan.x
                        panY += pan.y
                    }
                },
        ) {
            Box(
                modifier = Modifier
                    .width(worldWidth.dp)
                    .height(worldHeight.dp)
                    .graphicsLayer(
                        scaleX = scale,
                        scaleY = scale,
                        translationX = panX,
                        translationY = panY,
                        transformOrigin = TransformOrigin(0f, 0f),
                    ),
            ) {
                val edgeColor = Floe.colors.separator
                val edgeAccent = Floe.colors.accent
                Canvas(Modifier.fillMaxSize()) {
                    layout.edges.forEach { edge ->
                        val from = layout.frames[edge.from] ?: return@forEach
                        val to = layout.frames[edge.to] ?: return@forEach
                        val fromX = ((from.x + from.width / 2.0 - originX) * density).toFloat()
                        val fromY = ((from.y + from.height / 2.0 - originY) * density).toFloat()
                        val toX = ((to.x + to.width / 2.0 - originX) * density).toFloat()
                        val toY = ((to.y + to.height / 2.0 - originY) * density).toFloat()
                        val path = Path().apply {
                            moveTo(fromX, fromY)
                            val midX = (fromX + toX) / 2f
                            cubicTo(midX, fromY, midX, toY, toX, toY)
                        }
                        drawPath(
                            path,
                            color = if (edge.tree) edgeColor else edgeAccent.copy(alpha = 0.7f),
                            style = androidx.compose.ui.graphics.drawscope.Stroke(
                                width = if (edge.tree) 1.6f * density else 2f * density,
                                cap = StrokeCap.Round,
                            ),
                        )
                    }
                }
                layout.visibleNodes.forEach { node ->
                    val base = layout.frames[node.id] ?: return@forEach
                    val frame = if (dragNodeID == node.id) {
                        base.copy(x = base.x + dragDX, y = base.y + dragDY)
                    } else {
                        base
                    }
                    MindMapNodeCard(
                        controller = controller,
                        session = session,
                        node = node,
                        frame = frame,
                        originX = originX,
                        originY = originY,
                        selected = session.selectedMindMapNodeID == node.id ||
                            connectSource == node.id,
                        connecting = connectSource != null,
                        onTap = { onNodeSelected(node) },
                        onLongPress = { onNodeLongPress(node) },
                        onDragStart = {
                            dragNodeID = node.id
                            dragDX = 0.0
                            dragDY = 0.0
                        },
                        onDrag = { amount ->
                            dragDX += amount.x / density
                            dragDY += amount.y / density
                        },
                        onDragEnd = {
                            if (dragNodeID == node.id &&
                                (dragDX != 0.0 || dragDY != 0.0)) {
                                onNodeMoved(
                                    node,
                                    base.copy(x = base.x + dragDX, y = base.y + dragDY),
                                )
                            }
                            dragNodeID = null
                            dragDX = 0.0
                            dragDY = 0.0
                        },
                        onToggleFold = {
                            session.updateMindMapNode(node.copy(isCollapsed = !node.isCollapsed))
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun MindMapNodeCard(
    controller: NotesWorkspaceController,
    session: NotesDocumentSession,
    node: MindMapNode,
    frame: com.floe.android.feature.notes.NoteRect,
    originX: Double,
    originY: Double,
    selected: Boolean,
    connecting: Boolean,
    onTap: () -> Unit,
    onLongPress: () -> Unit,
    onDragStart: () -> Unit,
    onDrag: (Offset) -> Unit,
    onDragEnd: () -> Unit,
    onToggleFold: () -> Unit,
) {
    var image by remember(node.id, node.imageResourceID) { mutableStateOf<ByteArray?>(null) }
    LaunchedEffect(node.imageResourceID) {
        image = node.imageResourceID?.let { id ->
            runCatching { controller.resources.readAll(id, maxBytes = 12L * 1024L * 1024L) }.getOrNull()
        }
    }
    val hasChildren = session.document?.nodes?.any { it.parentID == node.id } == true
    val background = node.color?.let { notesColorFromHex(it, Floe.colors.sectionCardSurface) }
        ?: Floe.colors.sectionCardSurface
    Box(
        modifier = Modifier
            .offset(
                x = (frame.x - originX).toFloat().dp,
                y = (frame.y - originY).toFloat().dp,
            )
            .width(frame.width.toFloat().dp)
            .height(frame.height.toFloat().dp)
            .pointerInput(node.id, connecting) {
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
                onLongClick = onLongPress,
            ),
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .clip(RoundedCornerShape(12.dp))
                .background(background)
                .border(
                    width = if (selected) 2.dp else 0.5.dp,
                    color = if (selected) Floe.colors.accent else Floe.colors.chromeHairline,
                    shape = RoundedCornerShape(12.dp),
                )
                .padding(10.dp),
            verticalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                FloeText(
                    node.title.ifBlank { stringResource(R.string.notes_mindmap_new_topic) },
                    style = Floe.typography.bodyEmphasized.copy(fontSize = 15.sp),
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                if (node.isAIGenerated == true) {
                    IconGlyph(FloeIcons.Wand, Floe.colors.accent, 13.dp)
                }
                if (hasChildren) {
                    Box(
                        modifier = Modifier
                            .size(28.dp)
                            .clickable(role = Role.Button, onClick = onToggleFold),
                        contentAlignment = Alignment.Center,
                    ) {
                        IconGlyph(
                            if (node.isCollapsed) FloeIcons.ChevronDown else FloeIcons.ChevronUp,
                            Floe.colors.secondaryLabel,
                            14.dp,
                        )
                    }
                }
            }
            if (node.note.isNotBlank() && node.imageResourceID == null) {
                FloeText(
                    node.note,
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                    maxLines = 3,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (image != null) {
                NotesImageBytes(
                    bytes = image,
                    contentDescription = null,
                    modifier = Modifier.fillMaxWidth().height(70.dp).clip(RoundedCornerShape(8.dp)),
                )
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                node.attachments?.takeIf { it.isNotEmpty() }?.let {
                    IconGlyph(FloeIcons.Paperclip, Floe.colors.secondaryLabel, 12.dp)
                    FloeText("${it.size}", style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                }
                node.tags?.takeIf { it.isNotEmpty() }?.let {
                    IconGlyph(NotesIcons.Tag, Floe.colors.secondaryLabel, 12.dp)
                    FloeText("${it.size}", style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                }
            }
        }
    }
}

@Composable
private fun NotesMindMapNodeSheet(
    controller: NotesWorkspaceController,
    session: NotesDocumentSession,
    node: MindMapNode,
    onDismiss: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val document = session.document ?: return
    var title by remember(node.id) { mutableStateOf(node.title) }
    var note by remember(node.id) { mutableStateOf(node.note) }
    var color by remember(node.id) { mutableStateOf(node.color) }
    var attachmentFailed by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    val liveNode = session.document?.nodes?.firstOrNull { it.id == node.id } ?: node
    val hasParent = node.parentID != null
    FloeActionSheet(visible = true, onDismiss = onDismiss, maxCardWidth = 620.dp, maxCardHeightFraction = 0.92f) {
        Column(
            Modifier.fillMaxWidth().padding(20.dp).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            FloeText(stringResource(R.string.notes_mindmap_edit_topic), style = Floe.typography.title)
            FloePlainFormField(
                label = stringResource(R.string.notes_mindmap_title),
                value = title,
                onValueChange = { title = it },
                enabled = !busy,
                singleLine = true,
            )
            FloePlainFormField(
                label = stringResource(R.string.notes_mindmap_note),
                value = note,
                onValueChange = { note = it },
                enabled = !busy,
                singleLine = false,
                minLines = 3,
                maxLines = 8,
            )
            FloeText(stringResource(R.string.notes_mindmap_color), style = Floe.typography.section)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf("#FFFFFF", "#FFF2CC", "#DDEBF7", "#E2EFDA", "#FCE4D6", "#EDE7F6").forEach { hex ->
                    Box(
                        Modifier
                            .size(38.dp)
                            .clip(RoundedCornerShape(8.dp))
                            .background(notesColorFromHex(hex, Color.White))
                            .border(
                                if (color == hex) 2.dp else 0.5.dp,
                                if (color == hex) Floe.colors.accent else Floe.colors.separator,
                                RoundedCornerShape(8.dp),
                            )
                            .clickable(role = Role.Button) { color = hex },
                    )
                }
                Box(
                    Modifier
                        .size(38.dp)
                        .clip(RoundedCornerShape(8.dp))
                        .border(0.5.dp, Floe.colors.separator, RoundedCornerShape(8.dp))
                        .clickable(role = Role.Button) { color = null },
                    contentAlignment = Alignment.Center,
                ) { FloeText("—", style = Floe.typography.metadata) }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                FloeText(stringResource(R.string.notes_mindmap_fold), modifier = Modifier.weight(1f))
                com.floe.android.design.FloeInlineSwitch(
                    checked = liveNode.isCollapsed,
                    onCheckedChange = { collapsed ->
                        session.updateMindMapNode(liveNode.copy(isCollapsed = collapsed))
                    },
                    description = stringResource(R.string.notes_mindmap_fold),
                )
            }
            FloeDivider()
            FloeText(stringResource(R.string.notes_mindmap_attachments), style = Floe.typography.section)
            liveNode.attachments.orEmpty().forEach { attachment ->
                Row(
                    modifier = Modifier.fillMaxWidth().heightIn(min = FloeLayout.MinimumTarget),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    IconGlyph(FloeIcons.Paperclip, Floe.colors.secondaryLabel, 16.dp)
                    FloeText(
                        attachment.fileName,
                        style = Floe.typography.body,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                    NotesIconAction(
                        FloeIcons.Eye,
                        stringResource(R.string.notes_attachment_open),
                        {
                            scope.launch {
                                when (controller.ports.exchange.openAttachment(
                                    NotesOpenAttachmentRequest(
                                        attachment.resourceID,
                                        attachment.fileName,
                                        attachment.mediaType,
                                    ),
                                )) {
                                    NotesOpenAttachmentOutcome.Opened -> Unit
                                    is NotesOpenAttachmentOutcome.Unavailable,
                                    is NotesOpenAttachmentOutcome.Failed ->
                                        attachmentFailed = true
                                }
                            }
                        },
                        visualSize = 30.dp,
                    )
                    NotesIconAction(
                        FloeIcons.Trash,
                        stringResource(R.string.notes_delete),
                        {
                            session.updateMindMapNode(
                                liveNode.copy(attachments = liveNode.attachments.orEmpty() - attachment),
                            )
                        },
                        visualSize = 30.dp,
                    )
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FloeCapsuleAction(
                    stringResource(R.string.notes_mindmap_add_image),
                    onClick = {
                        scope.launch {
                            busy = true
                            controller.setActiveMindMapNodeImage(node.id)
                            busy = false
                        }
                    },
                    enabled = !busy,
                )
                FloeCapsuleAction(
                    stringResource(R.string.notes_mindmap_add_file),
                    onClick = {
                        scope.launch {
                            busy = true
                            controller.attachFileToActiveMindMapNode(node.id)
                            busy = false
                        }
                    },
                    enabled = !busy,
                )
                if (liveNode.imageResourceID != null) {
                    FloeCapsuleAction(
                        stringResource(R.string.notes_mindmap_remove_image),
                        onClick = { session.updateMindMapNodeImage(node.id, null) },
                        enabled = !busy,
                    )
                }
            }
            liveNode.source?.let { source ->
                FloeCapsuleAction(
                    stringResource(R.string.notes_mindmap_link_source),
                    onClick = {
                        if (source.space == com.floe.android.feature.notes.NoteSourceSpace.NOTES) {
                            controller.openSource(source)
                        }
                    },
                )
            }
            if (attachmentFailed) {
                FloeText(
                    stringResource(R.string.notes_attachment_unavailable),
                    style = Floe.typography.metadata,
                    color = Floe.colors.destructive,
                )
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End)) {
                if (busy) FloeActivityIndicator()
                if (hasParent) {
                    FloeCapsuleAction(
                        stringResource(R.string.notes_mindmap_delete_branch),
                        onClick = {
                            session.deleteMindMapBranch(node.id)
                            onDismiss()
                        },
                        tint = Floe.colors.destructive,
                        enabled = !busy,
                    )
                }
                FloeCapsuleAction(stringResource(R.string.notes_cancel), onClick = onDismiss, enabled = !busy)
                FloeCapsuleAction(
                    stringResource(R.string.notes_save),
                    onClick = {
                        val current = session.document?.nodes?.firstOrNull { it.id == node.id } ?: node
                        session.updateMindMapNode(
                            current.copy(
                                title = title.trim().ifBlank { current.title },
                                note = note,
                                color = color,
                            ),
                        )
                        onDismiss()
                    },
                    enabled = title.trim().isNotEmpty() && !busy,
                )
            }
        }
    }
}
