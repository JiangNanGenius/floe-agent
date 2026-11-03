// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.canvas.ui

import android.graphics.Bitmap
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeBadgePill
import com.floe.android.design.FloeBadgeTone
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeText
import com.floe.android.design.IconGlyph
import com.floe.android.feature.canvas.CanvasAssetReference
import com.floe.android.feature.canvas.CanvasNode
import com.floe.android.feature.canvas.ui.presentation.CanvasBitmapLoader
import com.floe.android.feature.canvas.ui.presentation.CanvasNodeSemantics
import com.floe.android.feature.canvas.ui.presentation.NodeDisplayKind

/**
 * Shared node PRESENTATION for the editing surface and the read-only design
 * preview.
 *
 * The Canvas surface and the design canvas snapshot render the SAME node
 * content (text, sticky, card, shape, image, read-only kind) through these
 * composables; the design preview therefore never invents a parallel
 * renderer or a simplified "summary" card. Callers own position/size/rotation
 * and an explicit [bitmap] for image nodes; no caller may fabricate an image
 * when the verified bytes are unavailable.
 */
@Composable
internal fun CanvasNodeVisualContent(
    node: CanvasNode,
    displayKind: NodeDisplayKind,
    bitmap: Bitmap?,
) {
    when (displayKind) {
        NodeDisplayKind.TEXT, NodeDisplayKind.CARD, NodeDisplayKind.STICKY ->
            CanvasNodeTextContent(node)
        NodeDisplayKind.SHAPE -> CanvasNodeShapeContent(node)
        NodeDisplayKind.IMAGE -> CanvasNodeImageContent(node, bitmap)
        else -> CanvasNodeReadOnlyContent(node, displayKind)
    }
}

/**
 * Node chrome (fill/hairline, locked/CAD badges) shared by the editor card and
 * the read-only preview. [modifier] carries the caller's placement, rotation
 * and interaction; this composable never installs pointer input itself.
 */
@Composable
internal fun CanvasNodeChrome(
    node: CanvasNode,
    displayKind: NodeDisplayKind,
    bitmap: Bitmap?,
    container: Color,
    shape: RoundedCornerShape,
    selected: Boolean,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .clip(shape)
            .then(
                if (container != Color.Transparent) {
                    Modifier.background(container)
                        .border(0.5.dp, Floe.colors.separator, shape)
                } else {
                    Modifier
                },
            )
            .then(
                if (selected) Modifier.border(2.dp, Floe.colors.accent, shape) else Modifier,
            ),
    ) {
        CanvasNodeVisualContent(node, displayKind, bitmap)
        if (node.isLocked) {
            FloeBadgePill(
                text = stringResource(R.string.canvas_node_locked),
                tone = FloeBadgeTone.SECONDARY,
                modifier = Modifier.align(Alignment.TopEnd).padding(6.dp),
            )
        }
        if (CanvasNodeSemantics.isCadBound(node)) {
            FloeBadgePill(
                text = stringResource(R.string.canvas_node_cad),
                tone = FloeBadgeTone.PENDING,
                modifier = Modifier.align(Alignment.BottomStart).padding(6.dp),
            )
        }
    }
}

/** Fill for one node kind; transparent means paint only the node content. */
@Composable
internal fun canvasNodeContainer(displayKind: NodeDisplayKind): Color = when (displayKind) {
    NodeDisplayKind.STICKY -> Floe.colors.pending.copy(alpha = 0.16f)
    NodeDisplayKind.CARD, NodeDisplayKind.TEXT -> Floe.colors.sectionCardSurface
    else -> Color.Transparent
}

/**
 * Bounded image decode for one asset reference through the existing Canvas
 * bitmap loader. The loader cache owns the returned bitmap; callers must not
 * recycle it.
 */
@Composable
internal fun rememberCanvasNodeImage(
    assetsBasePath: String,
    asset: CanvasAssetReference?,
): Bitmap? {
    // Only an image node carries an asset; avoid dispatching a decode attempt
    // for every text/sticky/shape card.
    if (asset?.id.isNullOrEmpty()) return null
    val bitmap by produceState<Bitmap?>(
        initialValue = null,
        asset?.id,
        asset?.contentHash,
        assetsBasePath,
    ) {
        value = CanvasBitmapLoader.load(assetsBasePath, asset)
    }
    return bitmap
}

@Composable
private fun CanvasNodeTextContent(node: CanvasNode) {
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
private fun CanvasNodeShapeContent(node: CanvasNode) {
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
private fun CanvasNodeReadOnlyContent(node: CanvasNode, kind: NodeDisplayKind) {
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
private fun CanvasNodeImageContent(node: CanvasNode, bitmap: Bitmap?) {
    Box(
        Modifier
            .fillMaxSize()
            .background(Floe.colors.fillTertiary),
        contentAlignment = Alignment.Center,
    ) {
        if (bitmap != null) {
            Image(
                bitmap = bitmap.asImageBitmap(),
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
