// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.canvas.ui

import android.graphics.Bitmap
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeText
import com.floe.android.feature.canvas.CanvasDocument
import com.floe.android.feature.canvas.CanvasProject
import com.floe.android.feature.canvas.ui.presentation.CanvasNodeSemantics
import com.floe.android.feature.canvas.ui.presentation.CanvasView
import com.floe.android.feature.canvas.ui.presentation.CanvasViewportPolicy
import kotlin.math.roundToInt

/**
 * Read-only projection of one REAL Canvas document for the design preview.
 *
 * This reuses the editing surface's geometry policy, background/stroke/
 * connection layers and node content/chrome. It is not a parallel Canvas
 * store, a second renderer or a mutable editor: the caller supplies the
 * canonical document and the verified image bitmaps it already owns; nothing
 * here writes a Canvas, selects a node or installs drag/zoom input.
 */
internal object CanvasReadOnlyProjection {
    fun document(project: CanvasProject, documentID: String): CanvasDocument? =
        project.documents.firstOrNull { it.id == documentID }

    fun sortedNodes(document: CanvasDocument) =
        document.nodes.sortedWith(compareBy({ it.zIndex }, { it.id }))

    /** Fit the actual document content into the measured preview box. */
    fun fitView(
        document: CanvasDocument,
        widthPx: Int,
        heightPx: Int,
        density: Float,
    ): CanvasView = CanvasViewportPolicy.fit(
        bounds = CanvasViewportPolicy.contentBounds(document.nodes),
        surfaceWidthPx = widthPx,
        surfaceHeightPx = heightPx,
        density = density,
    )

    fun bitmapFor(assetID: String?, bitmaps: Map<String, Bitmap>): Bitmap? {
        if (assetID.isNullOrEmpty()) return null
        return bitmaps[assetID]
    }
}

/** Bounded read-only Canvas scene used by the design preview. */
@Composable
internal fun CanvasReadOnlyScene(
    project: CanvasProject,
    documentID: String,
    selectedNodeID: String,
    assetBitmaps: Map<String, Bitmap>,
    modifier: Modifier = Modifier,
) {
    val document = CanvasReadOnlyProjection.document(project, documentID) ?: return
    val density = LocalDensity.current.density
    var sizePx by remember { mutableStateOf(IntSize.Zero) }
    val nodes = remember(document) { CanvasReadOnlyProjection.sortedNodes(document) }
    val view = remember(document, sizePx, density) {
        CanvasReadOnlyProjection.fitView(document, sizePx.width, sizePx.height, density)
    }
    val surfaceLabel = stringResource(R.string.canvas_readonly_description)

    Box(
        modifier = modifier
            .clipToBounds()
            .background(Floe.colors.groupedSurface)
            .onSizeChanged { sizePx = it }
            .semantics { contentDescription = surfaceLabel }
            .testTag("canvas.readonly.preview"),
    ) {
        CanvasBackground(
            style = document.backgroundStyle ?: "grid",
            view = view,
            density = density,
            modifier = Modifier.fillMaxSize(),
        )
        LegacyStrokeLayer(
            strokes = document.strokes,
            view = view,
            density = density,
            modifier = Modifier.fillMaxSize(),
        )
        CanvasConnectionsLayer(
            document = document,
            view = view,
            density = density,
            modifier = Modifier.fillMaxSize(),
        )
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
            nodes.forEach { node ->
                key(node.id) {
                    val displayKind = CanvasNodeSemantics.displayKind(node.kind)
                    val topLeftX = with(LocalDensity.current) {
                        (node.position.x - node.size.width / 2).toFloat().dp.roundToPx()
                    }
                    val topLeftY = with(LocalDensity.current) {
                        (node.position.y - node.size.height / 2).toFloat().dp.roundToPx()
                    }
                    CanvasNodeChrome(
                        node = node,
                        displayKind = displayKind,
                        bitmap = CanvasReadOnlyProjection.bitmapFor(
                            node.asset?.id, assetBitmaps),
                        container = canvasNodeContainer(displayKind),
                        shape = RoundedCornerShape(10.dp),
                        selected = node.id == selectedNodeID,
                        modifier = Modifier
                            .offset { IntOffset(topLeftX, topLeftY) }
                            .size(node.size.width.dp, node.size.height.dp)
                            .graphicsLayer {
                                rotationZ = node.rotation.toFloat()
                                transformOrigin = TransformOrigin.Center
                            },
                    )
                }
            }
        }
        if (nodes.isEmpty()) {
            FloeText(
                stringResource(R.string.canvas_readonly_empty),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.align(Alignment.Center),
            )
        }
    }
}
