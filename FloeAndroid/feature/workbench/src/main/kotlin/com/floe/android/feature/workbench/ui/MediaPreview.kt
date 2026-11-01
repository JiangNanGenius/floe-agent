// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui

import android.graphics.Paint
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeText
import com.floe.android.design.IconGlyph
import com.floe.android.feature.workbench.ImageFreehandPoint
import com.floe.android.feature.workbench.ImageFreehandStroke
import com.floe.android.feature.workbench.ImageLayer
import com.floe.android.feature.workbench.MediaAssetReference
import com.floe.android.feature.workbench.MediaCanvas
import com.floe.android.feature.workbench.MediaProject
import com.floe.android.feature.workbench.ui.presentation.MediaColor
import com.floe.android.feature.workbench.ui.presentation.MediaLayerGeometry
import com.floe.android.feature.workbench.ui.r2.MediaVideoSurface
import com.floe.android.feature.workbench.ui.state.MediaEditorController
import kotlin.math.abs
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Non-destructive image preview.
 *
 * Layer content is drawn from the trusted project assets in stacking order;
 * crop, aspect-fit natural placement, transform, opacity and supported color
 * adjustments match the shared renderer semantics. Video projects deliberately
 * show metadata only (no fake timeline or playback).
 */
@Composable
internal fun MediaPreview(
    controller: MediaEditorController,
    drawMode: Boolean,
    brushWidth: Float,
    brushColorHex: String,
    onStroke: (ImageFreehandStroke) -> Unit,
    modifier: Modifier = Modifier,
    compact: Boolean = false,
) {
    val project = controller.project
    val previewRevision = controller.previewRevision
    val canvas = project.canvas
    val r2 = controller.r2
    val density = LocalDensity.current
    var draftPoints by remember(controller.projectID) {
        mutableStateOf<List<ImageFreehandPoint>>(emptyList())
    }
    val previewLabel = stringResource(R.string.media_preview_description)

    if (project.kind == "video" && r2 != null) {
        Box(modifier.fillMaxSize()) {
            MediaVideoSurface(
                controller = controller,
                compact = compact,
                modifier = Modifier.fillMaxSize(),
            )
            if (controller.videoLoading) {
                Row(
                    Modifier
                        .align(Alignment.TopCenter)
                        .padding(8.dp)
                        .background(Floe.colors.readingSurface.copy(alpha = 0.9f))
                        .padding(horizontal = 10.dp, vertical = 6.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    com.floe.android.design.FloeActivityIndicator()
                    FloeText(
                        stringResource(R.string.media_busy_loading),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                }
            }
        }
        return
    }

    BoxWithConstraints(modifier.fillMaxSize().background(Floe.colors.groupedSurface)) {
        val availableWidth = with(density) { maxWidth.toPx() }
        val availableHeight = with(density) { maxHeight.toPx() }
        val canvasWidth = (canvas?.width ?: 2048).coerceAtLeast(2)
        val canvasHeight = (canvas?.height ?: 2048).coerceAtLeast(2)
        val displayScale = min(
            availableWidth.coerceAtLeast(1f) / canvasWidth,
            availableHeight.coerceAtLeast(1f) / canvasHeight,
        ) * 0.94f
        val displayWidth = (canvasWidth * displayScale).coerceAtLeast(1f)
        val displayHeight = (canvasHeight * displayScale).coerceAtLeast(1f)
        Box(
            Modifier
                .align(Alignment.Center)
                .then(
                    with(density) {
                        Modifier.size(
                            displayWidth.toDp(),
                            displayHeight.toDp(),
                        )
                    },
                )
                .clipToBounds()
                .background(Color(0xFFF2F2F2))
                .testTag("media.preview.canvas")
                .pointerInput(project.id, project.revision, drawMode, controller.busy) {
                    if (drawMode && !controller.busy && controller.writable && !controller.needsReload) {
                        detectDragGestures(
                            onDragStart = { offset ->
                                draftPoints = listOf(
                                    ImageFreehandPoint(
                                        x = (offset.x / displayWidth).toDouble().coerceIn(0.0, 1.0),
                                        y = (offset.y / displayHeight).toDouble().coerceIn(0.0, 1.0),
                                    ),
                                )
                            },
                            onDragCancel = { draftPoints = emptyList() },
                            onDragEnd = {
                                val points = draftPoints
                                draftPoints = emptyList()
                                if (points.size >= 2) {
                                    onStroke(
                                        ImageFreehandStroke(
                                            points = points,
                                            width = brushWidth.toDouble().coerceIn(1.0, 400.0),
                                            colorHex = brushColorHex,
                                        ),
                                    )
                                }
                            },
                        ) { change, drag ->
                            change.consume()
                            val current = draftPoints.toMutableList()
                            val last = current.lastOrNull()
                            val x = (change.position.x / displayWidth).toDouble().coerceIn(0.0, 1.0)
                            val y = (change.position.y / displayHeight).toDouble().coerceIn(0.0, 1.0)
                            val farEnough = last == null ||
                                abs(last.x - x) * displayWidth > 2f ||
                                abs(last.y - y) * displayHeight > 2f
                            if (farEnough && current.size < 400) {
                                current += ImageFreehandPoint(x = x, y = y)
                                draftPoints = current
                            }
                        }
                    } else {
                        detectTapGestures { offset ->
                            selectAt(
                                controller = controller,
                                x = offset.x / displayWidth,
                                y = offset.y / displayHeight,
                            )
                        }
                    }
                },
        ) {
            val renderedPreview = r2?.imagePreview
                ?.takeIf { r2?.imagePreviewRevision == project.revision }
            if (renderedPreview != null) {
                Image(
                    bitmap = renderedPreview.asImageBitmap(),
                    contentDescription = previewLabel,
                    modifier = Modifier.fillMaxSize(),
                    contentScale = ContentScale.Fit,
                )
            } else {
                Canvas(Modifier.fillMaxSize()) {
                    drawProject(
                        controller = controller,
                        project = project,
                        displayWidth = displayWidth,
                        displayHeight = displayHeight,
                        previewRevision = previewRevision,
                    )
                }
            }
            if (draftPoints.size >= 2) {
                val accent = Floe.colors.accent
                Canvas(Modifier.fillMaxSize()) {
                    val path = Path()
                    val first = draftPoints.first()
                    path.moveTo((first.x * displayWidth).toFloat(), (first.y * displayHeight).toFloat())
                    for (point in draftPoints.drop(1)) {
                        path.lineTo(
                            (point.x * displayWidth).toFloat(),
                            (point.y * displayHeight).toFloat(),
                        )
                    }
                    drawPath(
                        path,
                        color = accent,
                        style = Stroke(
                            width = (brushWidth * displayScale).coerceAtLeast(1f),
                            cap = StrokeCap.Round,
                        ),
                    )
                }
            }
            if (project.kind == "video") {
                Column(
                    Modifier
                        .align(Alignment.Center)
                        .background(Floe.colors.readingSurface.copy(alpha = 0.92f))
                        .padding(horizontal = 18.dp, vertical = 14.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    IconGlyph(FloeIcons.PlayRuns, Floe.colors.secondaryLabel, 30.dp)
                    FloeText(
                        stringResource(R.string.media_video_unavailable_title),
                        style = Floe.typography.bodyEmphasized,
                    )
                    androidx.compose.material3.Text(
                        text = stringResource(R.string.media_video_unavailable_body),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                        textAlign = TextAlign.Center,
                    )
                }
            }
            if (r2 != null) {
                val previewBadge = when {
                    r2.imagePreviewBusy -> stringResource(R.string.media_r2_preview_updating)
                    r2.imagePreviewFailure != null ->
                        stringResource(R.string.media_r2_rendered_unavailable)
                    r2.imagePreviewRevision == project.revision ->
                        stringResource(R.string.media_r2_rendered_preview)
                    else -> null
                }
                if (previewBadge != null) {
                    FloeText(
                        previewBadge,
                        style = Floe.typography.metadata,
                        color = Floe.colors.tertiaryLabel,
                        modifier = Modifier
                            .align(Alignment.TopEnd)
                            .padding(8.dp)
                            .background(Floe.colors.readingSurface.copy(alpha = 0.85f))
                            .padding(horizontal = 8.dp, vertical = 4.dp),
                    )
                }
            }
            if (drawMode) {
                FloeText(
                    stringResource(R.string.media_draw_hint),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                    modifier = Modifier
                        .align(Alignment.TopStart)
                        .padding(8.dp)
                        .background(Floe.colors.readingSurface.copy(alpha = 0.85f))
                        .padding(horizontal = 8.dp, vertical = 4.dp),
                )
            }
        }
    }
}

private fun selectAt(controller: MediaEditorController, x: Float, y: Float) {
    val project = controller.project
    val previewRevision = controller.previewRevision
    val canvas = project.canvas ?: return
    val r2 = controller.r2 ?: return
    val canvasX = x.toDouble() * canvas.width
    val canvasY = y.toDouble() * canvas.height
    val hit = project.imageLayers.asReversed().firstOrNull { layer ->
        if (layer.isHidden) return@firstOrNull false
        val asset = layer.assetID?.let { id ->
            project.assets.firstOrNull { it.id == id }
        }
        val bounds = MediaLayerGeometry.placedBounds(
            layer = layer,
            asset = asset,
            bitmap = layer.assetID?.let { controller.assetBitmaps[it] },
            canvas = canvas,
        )
        abs(canvasX - bounds.centerX) <= bounds.width / 2 &&
            abs(canvasY - bounds.centerY) <= bounds.height / 2
    }
    controller.selectLayer(hit?.id)
}

private fun DrawScope.drawProject(
    controller: MediaEditorController,
    project: MediaProject,
    displayWidth: Float,
    displayHeight: Float,
    @Suppress("UNUSED_PARAMETER") previewRevision: Int,
) {
    val canvasWidth = (project.canvas?.width ?: 2048).toDouble()
    val canvasHeight = (project.canvas?.height ?: 2048).toDouble()
    val scale = displayWidth / canvasWidth.toFloat()
    val canvasCenter = Offset(displayWidth / 2f, displayHeight / 2f)
    project.imageLayers.forEach { layer ->
        if (layer.isHidden) return@forEach
        val asset = layer.assetID?.let { id -> project.assets.firstOrNull { it.id == id } }
        val bitmap = layer.assetID?.let { controller.assetBitmaps[it] }?.asImageBitmap()
        val bounds = MediaLayerGeometry.placedBounds(
            layer = layer,
            asset = asset,
            bitmap = layer.assetID?.let { controller.assetBitmaps[it] },
            canvas = project.canvas,
        )
        val targetX = (layer.transform.centerX * displayWidth).toFloat()
        val targetY = (layer.transform.centerY * displayHeight).toFloat()
        val flipX = if (layer.transform.flipX == true) -1f else 1f
        val flipY = if (layer.transform.flipY == true) -1f else 1f
        // Image bounds already include the uniform layer scale; text,
        // freehand and fill are full-canvas content and need the transform
        // scale applied here.
        val contentScale = if (layer.kind == "image") 1f else layer.transform.scale.toFloat()
        withTransform({
            translate(targetX, targetY)
            rotate(layer.transform.rotationDegrees.toFloat())
            scale(
                scaleX = contentScale * flipX,
                scaleY = contentScale * flipY,
                pivot = Offset.Zero,
            )
            translate(-canvasCenter.x, -canvasCenter.y)
        }) {
            when (layer.kind) {
                "image" -> drawImageLayer(
                    layer = layer,
                    bitmap = bitmap,
                    displayScale = scale,
                    canvasCenter = canvasCenter,
                    bounds = bounds,
                )
                "text" -> drawTextLayer(layer, scale, canvasCenter)
                "freehand" -> drawFreehandLayer(layer, displayWidth, displayHeight, scale)
                "fill" -> drawFillLayer(layer, displayWidth, displayHeight, canvasCenter)
            }
            if (controller.selectedLayerID == layer.id) {
                drawSelectionOutline(
                    layer = layer,
                    bounds = bounds,
                    displayWidth = displayWidth,
                    displayHeight = displayHeight,
                    scale = scale,
                    canvasCenter = canvasCenter,
                    color = Color(0xFF0081F6),
                )
            }
        }
    }
}

private fun DrawScope.drawImageLayer(
    layer: ImageLayer,
    bitmap: androidx.compose.ui.graphics.ImageBitmap?,
    displayScale: Float,
    canvasCenter: Offset,
    bounds: com.floe.android.feature.workbench.ui.presentation.PlacedLayerBounds,
) {
    val width = (bounds.width * displayScale).toFloat().coerceAtLeast(1f)
    val height = (bounds.height * displayScale).toFloat().coerceAtLeast(1f)
    val left = canvasCenter.x - width / 2f
    val top = canvasCenter.y - height / 2f
    if (bitmap != null) {
        val crop = MediaLayerGeometry.cropRect(
            layer.crop, bitmap.width, bitmap.height)
        val colorFilter = MediaColor.previewMatrix(layer.adjustment)?.let {
            ColorFilter.colorMatrix(it)
        }
        drawImage(
            image = bitmap,
            srcOffset = IntOffset(crop.left, crop.top),
            srcSize = IntSize(crop.width, crop.height),
            dstOffset = IntOffset(left.roundToInt(), top.roundToInt()),
            dstSize = IntSize(width.roundToInt(), height.roundToInt()),
            alpha = layer.opacity.toFloat().coerceIn(0f, 1f),
            colorFilter = colorFilter,
            filterQuality = FilterQuality.Medium,
        )
    } else {
        val alpha = layer.opacity.toFloat().coerceIn(0f, 1f)
        drawRect(
            Color(0xFFBDBDBD),
            topLeft = Offset(left, top),
            size = Size(width, height),
            alpha = alpha,
        )
        drawRect(
            Color(0xFF8A8A8A),
            topLeft = Offset(left, top),
            size = Size(width, height),
            style = Stroke(1.dp.toPx()),
            alpha = alpha,
        )
        drawLine(
            Color(0xFF8A8A8A),
            Offset(left, top),
            Offset(left + width, top + height),
            strokeWidth = 1.dp.toPx(),
            alpha = alpha,
        )
    }
}

private fun DrawScope.drawTextLayer(layer: ImageLayer, scale: Float, canvasCenter: Offset) {
    val text = layer.text ?: return
    if (text.text.isBlank()) return
    val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = (text.fontSize * scale).toFloat().coerceAtLeast(1f)
        color = MediaColor.parseArgb(text.colorHex) ?: 0xFF000000.toInt()
        alpha = (layer.opacity.coerceIn(0.0, 1.0) * 255).toInt()
        textAlign = Paint.Align.CENTER
    }
    val lines = text.text.split('\n')
    val lineHeight = paint.fontSpacing
    val totalHeight = lineHeight * lines.size
    drawIntoCanvas { canvas ->
        val native = canvas.nativeCanvas
        lines.forEachIndexed { index, line ->
            val baseline = canvasCenter.y - totalHeight / 2f + lineHeight * (index + 0.8f)
            native.drawText(line, canvasCenter.x, baseline, paint)
        }
    }
}

private fun DrawScope.drawFreehandLayer(
    layer: ImageLayer,
    displayWidth: Float,
    displayHeight: Float,
    displayScale: Float,
) {
    val freehand = layer.freehand ?: return
    freehand.strokes.forEach { stroke ->
        if (stroke.points.size < 2) return@forEach
        val path = Path()
        val first = stroke.points.first()
        path.moveTo(
            (first.x * displayWidth).toFloat(),
            (first.y * displayHeight).toFloat(),
        )
        for (point in stroke.points.drop(1)) {
            path.lineTo(
                (point.x * displayWidth).toFloat(),
                (point.y * displayHeight).toFloat(),
            )
        }
        drawPath(
            path = path,
            color = MediaColor.parseCompose(stroke.colorHex, Color.Black),
            alpha = (layer.opacity * (stroke.opacity ?: 1.0)).toFloat().coerceIn(0f, 1f),
            style = Stroke(
                width = (stroke.width * displayScale).toFloat().coerceAtLeast(1f),
                cap = StrokeCap.Round,
            ),
        )
    }
}

private fun DrawScope.drawFillLayer(
    layer: ImageLayer,
    displayWidth: Float,
    displayHeight: Float,
    canvasCenter: Offset,
) {
    val color = MediaColor.parseCompose(layer.fillColorHex, Color.Black)
    drawRect(
        color = color,
        topLeft = Offset.Zero,
        size = Size(displayWidth, displayHeight),
        alpha = layer.opacity.toFloat().coerceIn(0f, 1f),
    )
}

private fun DrawScope.drawSelectionOutline(
    layer: ImageLayer,
    bounds: com.floe.android.feature.workbench.ui.presentation.PlacedLayerBounds,
    displayWidth: Float,
    displayHeight: Float,
    scale: Float,
    canvasCenter: Offset,
    color: Color,
) {
    val width: Float
    val height: Float
    if (layer.kind == "image") {
        width = (bounds.width * scale).toFloat()
        height = (bounds.height * scale).toFloat()
    } else {
        width = displayWidth
        height = displayHeight
    }
    drawRect(
        color = color,
        topLeft = Offset(canvasCenter.x - width / 2f, canvasCenter.y - height / 2f),
        size = Size(width, height),
        style = Stroke(2.dp.toPx()),
    )
}
