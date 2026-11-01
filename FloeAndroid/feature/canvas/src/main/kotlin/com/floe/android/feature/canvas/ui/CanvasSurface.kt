// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.canvas.ui

import android.graphics.Bitmap
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeText
import com.floe.android.design.IconGlyph
import com.floe.android.feature.canvas.CanvasDocument
import com.floe.android.feature.canvas.CanvasNode
import com.floe.android.feature.canvas.CanvasStroke
import com.floe.android.feature.canvas.ui.presentation.CanvasBitmapLoader
import com.floe.android.feature.canvas.ui.presentation.CanvasGeometry
import com.floe.android.feature.canvas.ui.presentation.CanvasNodeSemantics
import com.floe.android.feature.canvas.ui.presentation.CanvasView
import com.floe.android.feature.canvas.ui.presentation.NodeDisplayKind
import com.floe.android.feature.canvas.ui.presentation.ResizeCorner
import com.floe.android.feature.canvas.ui.state.CanvasEditorController
import kotlin.math.roundToInt

/**
 * The Canvas editing surface.
 *
 * World geometry is drawn inside one scaled/translated layer (pan + pinch);
 * the selection chrome and resize/rotate handles live in screen space so they
 * stay usable at every zoom. Node drags update only a local preview and commit
 * one native `update` patch on release.
 */
@Composable
internal fun CanvasSurface(
    editor: CanvasEditorController,
    modifier: Modifier = Modifier,
) {
    val document = editor.activeDocument ?: return
    val density = LocalDensity.current
    val view = editor.viewportFor(document.id)
    var sizePx by remember { mutableStateOf(IntSize.Zero) }
    val surfaceLabel = stringResource(R.string.canvas_surface_description)

    LaunchedEffect(document.id, sizePx) {
        if (sizePx.width > 0 && sizePx.height > 0) {
            editor.onSurfaceMeasured(sizePx.width, sizePx.height, density.density)
            editor.ensureInitialViewport()
        }
    }

    Box(
        modifier
            .fillMaxSize()
            .background(Floe.colors.groupedSurface)
            .onSizeChanged { sizePx = it }
            .semantics { contentDescription = surfaceLabel }
            .testTag("canvas.surface")
            .pointerInput(document.id) {
                detectTapGestures(onTap = { editor.clearSelection() })
            }
            .pointerInput(document.id, editor.needsReload, editor.busy) {
                detectTransformGestures { centroid, pan, zoom, _ ->
                    if (editor.busy || editor.needsReload) return@detectTransformGestures
                    if (zoom != 1f) {
                        editor.zoomBy(zoom, centroid.x, centroid.y)
                    }
                    if (pan != Offset.Zero) {
                        editor.panBy(pan.x, pan.y)
                    }
                }
            },
    ) {
        CanvasBackground(
            style = document.backgroundStyle ?: "grid",
            view = view,
            density = density.density,
            modifier = Modifier.fillMaxSize(),
        )
        LegacyStrokeLayer(
            strokes = document.strokes,
            view = view,
            density = density.density,
            modifier = Modifier.fillMaxSize(),
        )
        CanvasConnectionsLayer(
            document = document,
            view = view,
            density = density.density,
            modifier = Modifier.fillMaxSize(),
        )
        Box(Modifier.fillMaxSize().clipToBounds()) {
            Box(
                Modifier
                    .fillMaxSize()
                    .graphicsLayer {
                        scaleX = view.zoom
                        scaleY = view.zoom
                        translationX = view.panX
                        translationY = view.panY
                        transformOrigin = TransformOrigin(0f, 0f)
                    },
            ) {
                document.nodes.sortedWith(compareBy({ it.zIndex }, { it.id })).forEach { node ->
                    key(node.id) {
                        CanvasNodeCard(
                            editor = editor,
                            node = node,
                            view = view,
                            density = density.density,
                        )
                    }
                }
            }
        }
        val selected = editor.selectedNode
        if (selected != null) {
            val preview = editor.gesturePreview?.takeIf { it.nodeID == selected.id }
            CanvasSelectionOverlay(
                editor = editor,
                node = selected,
                view = view,
                density = density.density,
                previewPosition = preview?.position ?: selected.position,
                previewSize = preview?.size ?: selected.size,
                previewRotation = preview?.rotation ?: selected.rotation,
            )
        }
        CanvasZoomControls(
            editor = editor,
            view = view,
            modifier = Modifier.align(Alignment.BottomEnd).padding(12.dp),
        )
        if (document.nodes.isEmpty() && document.strokes.isEmpty()) {
            FloeText(
                stringResource(R.string.canvas_selection_hint),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.align(Alignment.BottomStart).padding(16.dp),
            )
        }
    }
}

@Composable
private fun CanvasBackground(
    style: String,
    view: CanvasView,
    density: Float,
    modifier: Modifier = Modifier,
) {
    if (style == "blank") return
    val lineColor = Floe.colors.separator.copy(alpha = 0.45f)
    Canvas(modifier) {
        val spacingPx = (24f * density * view.zoom)
        if (spacingPx < 6f) return@Canvas
        val dot = style == "dots"
        var x = ((view.panX % spacingPx) + spacingPx) % spacingPx
        while (x < size.width) {
            var y = ((view.panY % spacingPx) + spacingPx) % spacingPx
            while (y < size.height) {
                if (dot) {
                    drawCircle(lineColor, radius = 1.1f, center = Offset(x, y))
                } else {
                    drawLine(lineColor, Offset(x, 0f), Offset(x, size.height), 0.6f)
                }
                y += spacingPx
            }
            x += spacingPx
        }
        if (!dot) {
            var y = ((view.panY % spacingPx) + spacingPx) % spacingPx
            while (y < size.height) {
                drawLine(lineColor, Offset(0f, y), Offset(size.width, y), 0.6f)
                y += spacingPx
            }
        }
    }
}

@Composable
private fun LegacyStrokeLayer(
    strokes: List<CanvasStroke>,
    view: CanvasView,
    density: Float,
    modifier: Modifier = Modifier,
) {
    if (strokes.isEmpty()) return
    val accent = Floe.colors.accent
    Canvas(modifier) {
        strokes.forEach { stroke ->
            if (stroke.points.size < 2) return@forEach
            val path = Path()
            val first = stroke.points.first()
            val (firstX, firstY) = view.worldToScreen(first, density)
            path.moveTo(firstX, firstY)
            for (point in stroke.points.drop(1)) {
                val (x, y) = view.worldToScreen(point, density)
                path.lineTo(x, y)
            }
            drawPath(
                path = path,
                color = parseColor(stroke.color, accent),
                style = Stroke(
                    width = (stroke.width.toFloat() * density * view.zoom)
                        .coerceAtLeast(1f),
                    cap = StrokeCap.Round,
                ),
            )
        }
    }
}

@Composable
private fun CanvasConnectionsLayer(
    document: CanvasDocument,
    view: CanvasView,
    density: Float,
    modifier: Modifier = Modifier,
) {
    if (document.connections.isEmpty()) return
    val accent = Floe.colors.accent
    val byID = remember(document.nodes) { document.nodes.associateBy { it.id } }
    Canvas(modifier) {
        document.connections.forEach { connection ->
            val source = byID[connection.sourceNodeID] ?: return@forEach
            val destination = byID[connection.destinationNodeID] ?: return@forEach
            val (sx, sy) = view.worldToScreen(source.position, density)
            val (dx, dy) = view.worldToScreen(destination.position, density)
            drawLine(
                color = accent.copy(alpha = 0.55f),
                start = Offset(sx, sy),
                end = Offset(dx, dy),
                strokeWidth = 1.5.dp.toPx(),
            )
            val angle = kotlin.math.atan2((dy - sy).toDouble(), (dx - sx).toDouble())
            val arrow = 8.dp.toPx()
            val left = Offset(
                dx - (arrow * kotlin.math.cos(angle - 0.5)).toFloat(),
                dy - (arrow * kotlin.math.sin(angle - 0.5)).toFloat(),
            )
            val right = Offset(
                dx - (arrow * kotlin.math.cos(angle + 0.5)).toFloat(),
                dy - (arrow * kotlin.math.sin(angle + 0.5)).toFloat(),
            )
            drawLine(accent.copy(alpha = 0.7f), Offset(dx, dy), left, 1.5.dp.toPx())
            drawLine(accent.copy(alpha = 0.7f), Offset(dx, dy), right, 1.5.dp.toPx())
        }
    }
}

@Composable
private fun CanvasNodeCard(
    editor: CanvasEditorController,
    node: CanvasNode,
    view: CanvasView,
    density: Float,
) {
    val preview = editor.gesturePreview?.takeIf { it.nodeID == node.id }
    val position = preview?.position ?: node.position
    val size = preview?.size ?: node.size
    val rotation = preview?.rotation ?: node.rotation
    val editable = editor.writable && !CanvasNodeSemantics.isReadOnly(node)
    val displayKind = CanvasNodeSemantics.displayKind(node.kind)
    val topLeftX = with(androidx.compose.ui.platform.LocalDensity.current) {
        (position.x - size.width / 2).toFloat().dp.roundToPx()
    }
    val topLeftY = with(androidx.compose.ui.platform.LocalDensity.current) {
        (position.y - size.height / 2).toFloat().dp.roundToPx()
    }
    val label = stringResource(displayKind.labelRes())
    val accessibleTitle = nodeAccessibleTitle(node, label)
    val shape = RoundedCornerShape(10.dp)
    val container: Color = when (displayKind) {
        NodeDisplayKind.STICKY -> Floe.colors.pending.copy(alpha = 0.16f)
        NodeDisplayKind.CARD, NodeDisplayKind.TEXT -> Floe.colors.sectionCardSurface
        else -> Color.Transparent
    }

    Box(
        modifier = Modifier
            .offset { IntOffset(topLeftX, topLeftY) }
            .size(size.width.dp, size.height.dp)
            .graphicsLayer {
                rotationZ = rotation.toFloat()
                transformOrigin = TransformOrigin.Center
            }
            .clip(shape)
            .then(
                if (container != Color.Transparent) {
                    Modifier.background(container)
                        .border(0.5.dp, Floe.colors.separator, shape)
                } else {
                    Modifier
                },
            )
            .pointerInput(node.id, editable, editor.busy, editor.needsReload) {
                detectTapGestures { editor.selectNode(node.id) }
            }
            .then(
                if (editable) {
                    Modifier.pointerInput(node.id, view.zoom, editor.busy, editor.needsReload) {
                        detectDragGestures(
                            onDragStart = { editor.beginMove(node.id) },
                            onDragCancel = { editor.cancelGesture() },
                            onDragEnd = { editor.commitGesture() },
                        ) { change, drag ->
                            if (editor.busy || editor.needsReload) return@detectDragGestures
                            change.consume()
                            val (dx, dy) = view.screenDeltaToWorld(drag.x, drag.y, density)
                            editor.dragMove(dx, dy)
                        }
                    }
                } else {
                    Modifier
                },
            )
            .semantics { contentDescription = accessibleTitle }
            .testTag("canvas.node.${node.id}"),
    ) {
        when (displayKind) {
            NodeDisplayKind.TEXT, NodeDisplayKind.CARD -> NodeTextContent(node)
            NodeDisplayKind.STICKY -> NodeTextContent(node)
            NodeDisplayKind.SHAPE -> NodeShapeContent(node)
            NodeDisplayKind.IMAGE -> CanvasImageNode(editor, node)
            else -> NodeReadOnlyContent(node, displayKind)
        }
        if (node.isLocked) {
            com.floe.android.design.FloeBadgePill(
                text = stringResource(R.string.canvas_node_locked),
                tone = com.floe.android.design.FloeBadgeTone.SECONDARY,
                modifier = Modifier.align(Alignment.TopEnd).padding(6.dp),
            )
        }
        if (CanvasNodeSemantics.isCadBound(node)) {
            com.floe.android.design.FloeBadgePill(
                text = stringResource(R.string.canvas_node_cad),
                tone = com.floe.android.design.FloeBadgeTone.PENDING,
                modifier = Modifier.align(Alignment.BottomStart).padding(6.dp),
            )
        }
    }
}

@Composable
private fun NodeTextContent(node: CanvasNode) {
    Box(Modifier.fillMaxSize().padding(12.dp)) {
        if (node.text.isBlank()) {
            FloeText(
                stringResource(R.string.canvas_node_placeholder),
                style = Floe.typography.body,
                color = Floe.colors.placeholderText,
                maxLines = 6,
                overflow = TextOverflow.Ellipsis,
            )
        } else {
            FloeText(
                node.text,
                style = Floe.typography.body,
                color = Floe.colors.label,
                maxLines = 12,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun NodeShapeContent(node: CanvasNode) {
    val fill = Floe.colors.accentFillFaint
    val stroke = Floe.colors.accent
    Box(Modifier.fillMaxSize()) {
        Canvas(Modifier.fillMaxSize()) {
            val inset = 1.dp.toPx()
            val width = size.width - inset * 2
            val height = size.height - inset * 2
            val topLeft = Offset(inset, inset)
            when (node.shape) {
                "ellipse" -> drawOval(fill, topLeft, Size(width, height))
                "diamond" -> {
                    val path = Path().apply {
                        moveTo(size.width / 2, inset)
                        lineTo(size.width - inset, size.height / 2)
                        lineTo(size.width / 2, size.height - inset)
                        lineTo(inset, size.height / 2)
                        close()
                    }
                    drawPath(path, fill)
                    drawPath(path, stroke, style = Stroke(1.5.dp.toPx()))
                }
                "triangle" -> {
                    val path = Path().apply {
                        moveTo(size.width / 2, inset)
                        lineTo(size.width - inset, size.height - inset)
                        lineTo(inset, size.height - inset)
                        close()
                    }
                    drawPath(path, fill)
                    drawPath(path, stroke, style = Stroke(1.5.dp.toPx()))
                }
                "rectangle" -> {
                    drawRect(fill, topLeft, Size(width, height))
                    drawRect(stroke, topLeft, Size(width, height), style = Stroke(1.5.dp.toPx()))
                }
                else -> {
                    drawRoundRect(
                        fill, topLeft, Size(width, height),
                        cornerRadius = androidx.compose.ui.geometry.CornerRadius(18.dp.toPx()),
                    )
                    drawRoundRect(
                        stroke, topLeft, Size(width, height),
                        cornerRadius = androidx.compose.ui.geometry.CornerRadius(18.dp.toPx()),
                        style = Stroke(1.5.dp.toPx()),
                    )
                }
            }
        }
        if (node.text.isNotBlank()) {
            FloeText(
                node.text,
                style = Floe.typography.body,
                color = Floe.colors.label,
                maxLines = 6,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.align(Alignment.Center).padding(14.dp),
            )
        }
    }
}

@Composable
private fun NodeReadOnlyContent(node: CanvasNode, kind: NodeDisplayKind) {
    val icon = when (kind) {
        NodeDisplayKind.VIDEO -> FloeIcons.PlayRuns
        NodeDisplayKind.AUDIO -> FloeIcons.Mic
        NodeDisplayKind.FILE -> FloeIcons.Folder
        NodeDisplayKind.GENERATION -> FloeIcons.Wand
        NodeDisplayKind.SCENE_3D -> FloeIcons.Creative
        NodeDisplayKind.GROUP -> FloeIcons.Folder
        else -> FloeIcons.InfoCircle
    }
    Column(
        modifier = Modifier.fillMaxSize().background(Floe.colors.sectionCardSurface).padding(12.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        IconGlyph(icon, Floe.colors.secondaryLabel, 24.dp)
        FloeText(
            stringResource(kind.labelRes()),
            style = Floe.typography.bodyEmphasized,
            color = Floe.colors.label,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 6.dp),
        )
        FloeText(
            if (CanvasNodeSemantics.isCadBound(node)) {
                stringResource(R.string.canvas_node_cad_body)
            } else {
                stringResource(R.string.canvas_node_read_only)
            },
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
            maxLines = 3,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 4.dp),
        )
    }
}

@Composable
private fun CanvasImageNode(editor: CanvasEditorController, node: CanvasNode) {
    val bitmap by produceState<Bitmap?>(
        initialValue = null,
        node.asset?.id,
        node.asset?.contentHash,
        editor.assetsBasePath,
    ) {
        value = CanvasBitmapLoader.load(editor.assetsBasePath, node.asset)
    }
    Box(
        Modifier
            .fillMaxSize()
            .background(Floe.colors.fillTertiary),
        contentAlignment = Alignment.Center,
    ) {
        val image = bitmap
        if (image != null) {
            Image(
                bitmap = image.asImageBitmap(),
                contentDescription = node.text.ifBlank {
                    stringResource(R.string.canvas_inspector_image)
                },
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
            if (node.text.isNotBlank()) {
                FloeText(
                    node.text,
                    style = Floe.typography.metadata,
                    color = Color.White,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier
                        .align(Alignment.BottomStart)
                        .background(Color.Black.copy(alpha = 0.45f))
                        .padding(horizontal = 8.dp, vertical = 4.dp),
                )
            }
        } else {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                IconGlyph(FloeIcons.Photo, Floe.colors.secondaryLabel, 26.dp)
                FloeText(
                    stringResource(R.string.canvas_image_unavailable),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                    modifier = Modifier.padding(top = 6.dp),
                )
            }
        }
    }
}

@Composable
private fun CanvasSelectionOverlay(
    editor: CanvasEditorController,
    node: CanvasNode,
    view: CanvasView,
    density: Float,
    previewPosition: com.floe.android.feature.canvas.CanvasPoint,
    previewSize: com.floe.android.feature.canvas.CanvasSize,
    previewRotation: Double,
) {
    if (editor.needsReload) return
    val accent = Floe.colors.accent
    val handleSize = 32.dp
    val widthPx = (previewSize.width.toFloat() * density * view.zoom)
    val heightPx = (previewSize.height.toFloat() * density * view.zoom)
    val centerX = (previewPosition.x.toFloat() * density * view.zoom) + view.panX
    val centerY = (previewPosition.y.toFloat() * density * view.zoom) + view.panY
    val halfW = widthPx / 2
    val halfH = heightPx / 2
    Canvas(Modifier.fillMaxSize()) {
        rotate(
            degrees = previewRotation.toFloat(),
            pivot = Offset(centerX, centerY),
        ) {
            drawRoundRect(
                color = accent,
                topLeft = Offset(centerX - halfW, centerY - halfH),
                size = Size(widthPx, heightPx),
                cornerRadius = androidx.compose.ui.geometry.CornerRadius(10f * density),
                style = Stroke(2.dp.toPx()),
            )
        }
    }
    val editable = editor.writable && !CanvasNodeSemantics.isReadOnly(node) && !editor.busy
    if (!editable) return
    val densityScope = androidx.compose.ui.platform.LocalDensity.current
    ResizeCorner.entries.forEach { corner ->
        val (cornerX, cornerY) = CanvasGeometry.rotatedPoint(
            centerX.toDouble(), centerY.toDouble(),
            corner.sx * halfW.toDouble(), corner.sy * halfH.toDouble(),
            previewRotation,
        )
        Box(
            Modifier
                .offset {
                    IntOffset(
                        (cornerX - with(densityScope) { handleSize.toPx() } / 2).roundToInt(),
                        (cornerY - with(densityScope) { handleSize.toPx() } / 2).roundToInt(),
                    )
                }
                .size(handleSize)
                .pointerInput(node.id, corner, view.zoom, density) {
                    detectDragGestures(
                        onDragStart = { editor.beginResize(node.id) },
                        onDragCancel = { editor.cancelGesture() },
                        onDragEnd = { editor.commitGesture() },
                    ) { change, drag ->
                        change.consume()
                        val (dx, dy) = view.screenDeltaToWorld(drag.x, drag.y, density)
                        editor.resizeBy(corner, dx, dy)
                    }
                }
                .testTag("canvas.handle.${corner.name}"),
            contentAlignment = Alignment.Center,
        ) {
            Box(
                Modifier.size(12.dp).clip(CircleShape).background(Color.White)
                    .border(2.dp, accent, CircleShape),
            )
        }
    }
    val (topX, topY) = CanvasGeometry.rotatedPoint(
        centerX.toDouble(), centerY.toDouble(), 0.0, -halfH.toDouble() - 26.0,
        previewRotation,
    )
    Box(
        Modifier
            .offset {
                IntOffset(
                    (topX - with(densityScope) { handleSize.toPx() } / 2).roundToInt(),
                    (topY - with(densityScope) { handleSize.toPx() } / 2).roundToInt(),
                )
            }
            .size(handleSize)
            .pointerInput(node.id, view.zoom) {
                detectDragGestures(
                    onDragStart = { editor.beginRotate(node.id) },
                    onDragCancel = { editor.cancelGesture() },
                    onDragEnd = { editor.commitGesture() },
                ) { change, drag ->
                    change.consume()
                    editor.rotateBy(drag.x * 0.6)
                }
            }
            .testTag("canvas.handle.rotate"),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier.size(12.dp).clip(CircleShape).background(accent),
        )
    }
}

@Composable
private fun CanvasZoomControls(
    editor: CanvasEditorController,
    view: CanvasView,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.End,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        ZoomControl(stringResource(R.string.canvas_zoom_in), "+") {
            editor.zoomBy(1.25f, editor.surfaceWidthPx / 2f, editor.surfaceHeightPx / 2f)
        }
        FloeText(
            stringResource(R.string.canvas_zoom_percent,
                com.floe.android.feature.canvas.ui.presentation.CanvasViewportPolicy.zoomPercent(view)),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
            modifier = Modifier
                .background(Floe.colors.chromeSurface, RoundedCornerShape(8.dp))
                .padding(horizontal = 8.dp, vertical = 3.dp),
        )
        ZoomControl(stringResource(R.string.canvas_zoom_out), "−") {
            editor.zoomBy(0.8f, editor.surfaceWidthPx / 2f, editor.surfaceHeightPx / 2f)
        }
        ZoomControl(stringResource(R.string.canvas_zoom_fit), stringResource(R.string.canvas_zoom_fit)) {
            editor.fitToContent()
        }
    }
}

@Composable
private fun ZoomControl(description: String, label: String, onClick: () -> Unit) {
    Box(
        Modifier
            .size(44.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(Floe.colors.chromeSurface)
            .border(0.5.dp, Floe.colors.chromeHairline, RoundedCornerShape(10.dp))
            .pointerInput(description) { detectTapGestures { onClick() } }
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        FloeText(label, style = if (label.length > 1) Floe.typography.metadata else Floe.typography.bodyEmphasized)
    }
}

private fun parseColor(raw: String, fallback: Color): Color {
    if (!raw.startsWith("#")) return fallback
    return try {
        val hex = raw.removePrefix("#")
        val value = when (hex.length) {
            6 -> 0xFF000000L or hex.toLong(16)
            8 -> hex.toLong(16)
            else -> return fallback
        }
        Color(value)
    } catch (_: Throwable) {
        fallback
    }
}
