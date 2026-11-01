// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.canvas.ui.presentation

import com.floe.android.feature.canvas.CanvasNode
import com.floe.android.feature.canvas.CanvasPoint
import com.floe.android.feature.canvas.CanvasSize
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * Screen-space viewport for the Canvas surface.
 *
 * World units are density-independent (the persisted geometry is treated as
 * dp-equivalent while rendering), [panX]/[panY] are screen pixels and [zoom]
 * is a uniform scale. The pure functions here are shared by the Compose
 * surface, the editor controller and JVM tests.
 */
data class CanvasView(
    val panX: Float = 0f,
    val panY: Float = 0f,
    val zoom: Float = 1f,
) {
    fun worldToScreen(point: CanvasPoint, density: Float): Pair<Float, Float> =
        ((point.x.toFloat() * density) * zoom + panX) to
            ((point.y.toFloat() * density) * zoom + panY)

    fun screenToWorld(x: Float, y: Float, density: Float): CanvasPoint = CanvasPoint(
        x = ((x - panX) / zoom / density).toDouble(),
        y = ((y - panY) / zoom / density).toDouble(),
    )

    /** Screen-pixel drag converted into world units for node movement. */
    fun screenDeltaToWorld(dxPx: Float, dyPx: Float, density: Float): Pair<Double, Double> =
        ((dxPx / zoom / density).toDouble()) to ((dyPx / zoom / density).toDouble())
}

object CanvasViewportPolicy {
    const val MIN_ZOOM = 0.2f
    const val MAX_ZOOM = 4f
    const val FIT_PADDING_WORLD = 48.0

    fun clampZoom(value: Float): Float =
        if (!value.isFinite()) 1f else value.coerceIn(MIN_ZOOM, MAX_ZOOM)

    /** Zoom around a screen-space anchor while keeping the world point fixed. */
    fun zoomAround(view: CanvasView, anchorX: Float, anchorY: Float, factor: Float): CanvasView {
        if (!factor.isFinite() || factor <= 0f) return view
        val next = clampZoom(view.zoom * factor)
        if (next == view.zoom) return view
        val ratio = next / view.zoom
        return CanvasView(
            panX = anchorX - (anchorX - view.panX) * ratio,
            panY = anchorY - (anchorY - view.panY) * ratio,
            zoom = next,
        )
    }

    fun pan(view: CanvasView, dxPx: Float, dyPx: Float): CanvasView =
        view.copy(panX = view.panX + dxPx, panY = view.panY + dyPx)

    /** Axis-aligned world bounds (rotation ignored for fitting). */
    fun contentBounds(nodes: List<CanvasNode>): WorldBounds? {
        if (nodes.isEmpty()) return null
        var minX = Double.MAX_VALUE
        var minY = Double.MAX_VALUE
        var maxX = -Double.MAX_VALUE
        var maxY = -Double.MAX_VALUE
        for (node in nodes) {
            minX = min(minX, node.position.x - node.size.width / 2)
            minY = min(minY, node.position.y - node.size.height / 2)
            maxX = max(maxX, node.position.x + node.size.width / 2)
            maxY = max(maxY, node.position.y + node.size.height / 2)
        }
        return WorldBounds(minX, minY, maxX, maxY)
    }

    /**
     * Fit [bounds] into the measured surface. Never zooms beyond 100% on an
     * open so a small canvas does not appear unexpectedly magnified.
     */
    fun fit(
        bounds: WorldBounds?,
        surfaceWidthPx: Int,
        surfaceHeightPx: Int,
        density: Float,
        paddingWorld: Double = FIT_PADDING_WORLD,
    ): CanvasView {
        if (bounds == null || surfaceWidthPx <= 1 || surfaceHeightPx <= 1 ||
            density <= 0f || !density.isFinite()
        ) {
            return CanvasView()
        }
        val contentWidthPx = max(1.0, (bounds.width + paddingWorld * 2) * density)
        val contentHeightPx = max(1.0, (bounds.height + paddingWorld * 2) * density)
        val fitZoom = min(
            surfaceWidthPx / contentWidthPx,
            surfaceHeightPx / contentHeightPx,
        ).toFloat()
        val zoom = clampZoom(min(1f, fitZoom))
        val centerX = ((bounds.minX + bounds.maxX) / 2 * density).toFloat()
        val centerY = ((bounds.minY + bounds.maxY) / 2 * density).toFloat()
        return CanvasView(
            panX = surfaceWidthPx / 2f - centerX * zoom,
            panY = surfaceHeightPx / 2f - centerY * zoom,
            zoom = zoom,
        )
    }

    fun surfaceCenterWorld(
        view: CanvasView,
        surfaceWidthPx: Int,
        surfaceHeightPx: Int,
        density: Float,
    ): CanvasPoint = view.screenToWorld(
        surfaceWidthPx / 2f, surfaceHeightPx / 2f, density)

    fun zoomPercent(view: CanvasView): Int = (view.zoom * 100).roundToInt()
}

data class WorldBounds(
    val minX: Double,
    val minY: Double,
    val maxX: Double,
    val maxY: Double,
) {
    val width: Double get() = (maxX - minX).coerceAtLeast(0.0)
    val height: Double get() = (maxY - minY).coerceAtLeast(0.0)
    val centerX: Double get() = (minX + maxX) / 2
    val centerY: Double get() = (minY + maxY) / 2
}

enum class ResizeCorner(val sx: Int, val sy: Int) {
    TOP_LEFT(-1, -1),
    TOP_RIGHT(1, -1),
    BOTTOM_LEFT(-1, 1),
    BOTTOM_RIGHT(1, 1),
}

data class NodeGeometry(
    val position: CanvasPoint,
    val size: CanvasSize,
)

object CanvasGeometry {
    const val MIN_NODE_SIZE = 40.0

    /**
     * Resize while keeping the OPPOSITE corner fixed. Drag deltas are world
     * units; the result is clamped to [MIN_NODE_SIZE] without letting the
     * clamped node drift away from its anchor.
     */
    fun resizeFromCorner(
        origin: NodeGeometry,
        corner: ResizeCorner,
        deltaX: Double,
        deltaY: Double,
    ): NodeGeometry {
        if (!deltaX.isFinite() || !deltaY.isFinite()) return origin
        val fixedX = origin.position.x - corner.sx * origin.size.width / 2
        val fixedY = origin.position.y - corner.sy * origin.size.height / 2
        val proposedWidth = origin.size.width + corner.sx * deltaX
        val proposedHeight = origin.size.height + corner.sy * deltaY
        val width = proposedWidth.coerceAtLeast(MIN_NODE_SIZE)
        val height = proposedHeight.coerceAtLeast(MIN_NODE_SIZE)
        return NodeGeometry(
            position = CanvasPoint(
                x = fixedX + corner.sx * width / 2,
                y = fixedY + corner.sy * height / 2,
            ),
            size = CanvasSize(width = width, height = height),
        )
    }

    fun move(origin: CanvasPoint, deltaX: Double, deltaY: Double): CanvasPoint =
        CanvasPoint(origin.x + deltaX, origin.y + deltaY)

    fun rotatedPoint(
        centerX: Double,
        centerY: Double,
        offsetX: Double,
        offsetY: Double,
        degrees: Double,
    ): Pair<Double, Double> {
        if (abs(degrees) < 0.0001) return (centerX + offsetX) to (centerY + offsetY)
        val radians = degrees * PI / 180.0
        val c = cos(radians)
        val s = sin(radians)
        return (centerX + offsetX * c - offsetY * s) to
            (centerY + offsetX * s + offsetY * c)
    }

    fun normalizedRotation(degrees: Double): Double {
        if (!degrees.isFinite()) return 0.0
        val wrapped = ((degrees % 360.0) + 360.0) % 360.0
        return if (wrapped > 180.0) wrapped - 360.0 else wrapped
    }

    fun sameGeometry(a: NodeGeometry, b: NodeGeometry): Boolean =
        a.position.x == b.position.x && a.position.y == b.position.y &&
            a.size.width == b.size.width && a.size.height == b.size.height
}

/** Which persisted node kinds this UI can actually edit in R1. */
object CanvasNodeSemantics {
    const val KIND_TEXT = "text"
    const val KIND_STICKY = "stickyNote"
    const val KIND_CARD = "card"
    const val KIND_SHAPE = "shape"
    const val KIND_IMAGE = "image"
    const val KIND_VIDEO = "video"
    const val KIND_AUDIO = "audio"
    const val KIND_FILE = "file"
    const val KIND_GROUP = "group"
    const val KIND_GENERATION = "generationTask"
    const val KIND_SCENE_3D = "scene3D"

    val editableKinds = setOf(KIND_TEXT, KIND_STICKY, KIND_CARD, KIND_SHAPE, KIND_IMAGE)
    val shapeKinds = listOf(
        "rectangle", "roundedRectangle", "ellipse", "diamond", "triangle",
    )

    /** Mirrors the native `CADCanvasNodePlanner.isNativeCADNode` guard. */
    fun isCadBound(node: CanvasNode): Boolean {
        val sourcePath = node.metadata["canvas.nativeCAD.sourcePath"]
        val relative = node.asset?.localRelativePath
        return (node.kind == KIND_FILE && relative?.lowercase()?.endsWith(".floecad") == true) ||
            sourcePath != null
    }

    fun isReadOnly(node: CanvasNode): Boolean =
        node.kind !in editableKinds || node.isLocked || node.scene3D != null ||
            isCadBound(node)

    fun defaultSize(kind: String): CanvasSize = when (kind) {
        KIND_TEXT -> CanvasSize(260.0, 150.0)
        KIND_STICKY -> CanvasSize(260.0, 180.0)
        KIND_CARD -> CanvasSize(300.0, 200.0)
        KIND_SHAPE -> CanvasSize(220.0, 140.0)
        KIND_IMAGE -> CanvasSize(320.0, 260.0)
        else -> CanvasSize(260.0, 160.0)
    }

    fun displayKind(kind: String): NodeDisplayKind = when (kind) {
        KIND_TEXT -> NodeDisplayKind.TEXT
        KIND_STICKY -> NodeDisplayKind.STICKY
        KIND_CARD -> NodeDisplayKind.CARD
        KIND_SHAPE -> NodeDisplayKind.SHAPE
        KIND_IMAGE -> NodeDisplayKind.IMAGE
        KIND_VIDEO -> NodeDisplayKind.VIDEO
        KIND_AUDIO -> NodeDisplayKind.AUDIO
        KIND_FILE -> NodeDisplayKind.FILE
        KIND_GROUP -> NodeDisplayKind.GROUP
        KIND_GENERATION -> NodeDisplayKind.GENERATION
        KIND_SCENE_3D -> NodeDisplayKind.SCENE_3D
        else -> NodeDisplayKind.UNKNOWN
    }
}

enum class NodeDisplayKind {
    TEXT,
    STICKY,
    CARD,
    SHAPE,
    IMAGE,
    VIDEO,
    AUDIO,
    FILE,
    GROUP,
    GENERATION,
    SCENE_3D,
    UNKNOWN,
    ;
    val isBasic: Boolean
        get() = this in setOf(TEXT, STICKY, CARD, SHAPE, IMAGE)
}
