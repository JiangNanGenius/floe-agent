// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.ink

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.DashPathEffect
import android.graphics.Matrix
import android.graphics.Paint
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.View
import android.widget.FrameLayout
import androidx.ink.authoring.InProgressStrokeId
import androidx.ink.authoring.InProgressStrokesFinishedListener
import androidx.ink.authoring.InProgressStrokesView
import androidx.ink.rendering.android.canvas.CanvasStrokeRenderer
import androidx.ink.rendering.android.view.ViewStrokeRenderer
import androidx.ink.strokes.Stroke
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/**
 * Reusable Android-VIEW ink authoring surface for one Notes page.
 *
 * Why a View (not Compose): androidx.ink 1.0.0's stable authoring widget is
 * [InProgressStrokesView] (a FrameLayout). Embedding it directly gives the UI
 * owner a plain `View` usable from an `AndroidView`, a Fragment or a test host,
 * with no Compose authoring dependency and no alpha library.
 *
 * Coordinate contract:
 *  - [InkDocument] stores strokes in PAPER POINTS (top-left origin, y down);
 *  - this view keeps only a paper→view transform (zoom/pan/rotation); the
 *    in-progress surface is given the inverse transform, so every finished
 *    stroke arrives already in paper coordinates;
 *  - two-finger gestures pan/zoom and CANCEL the in-progress stroke, exactly
 *    the official Ink guidance; system-cancelled pointers (palm) never commit;
 *  - the eraser is a gesture (never a stored stroke) that removes whole
 *    strokes under the pointer inside one undo group per drag.
 *
 * What this view deliberately does NOT do: synthesize pressure/tilt, claim
 * palm rejection (the platform's cancel events are honoured, not predicted),
 * or share editor state across pages — one view owns one [InkDocument].
 */
class InkCanvasView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0,
) : FrameLayout(context, attrs, defStyleAttr) {

    /** Callbacks into the Notes editor (all on the main thread). */
    interface Listener {
        fun onDocumentChanged(snapshot: InkSnapshot, canUndo: Boolean, canRedo: Boolean) {}
        fun onStrokeCommitted(stroke: InkStroke) {}
        fun onSelectionChanged(selected: Set<Long>) {}
        fun onInkCanceled() {}
    }

    private val paperLayer = PaperLayer(context)
    private val inProgress = InProgressStrokesView(context)

    private var document: InkDocument? = null
    private var pageWidthPt: Float = 0f
    private var pageHeightPt: Float = 0f

    private var inputConfig = InkInputConfig()
    private val router = InkPointerRouter { inputConfig }

    private var currentBrush: InkBrushSpec = InkBrushSpec.pen(Color.BLACK)
    private var eraserRadiusPt: Float = 9f
    private var selectionMode: Boolean = false
    private var paperColor: Int = Color.WHITE

    // View transform state (paper points -> view pixels).
    private var scalePxPerPt: Float = 1f
    private var baseScalePxPerPt: Float = 1f
    private var panXPx: Float = 0f
    private var panYPx: Float = 0f
    private var rotationQuarterTurns: Int = 0
    private var fitted = false

    private var nextStrokeId: Long = 1L
    private val nativeIds = HashMap<Int, Long>() // pointerId -> model stroke id
    private val inProgressIds = HashMap<InProgressStrokeId, Long>()
    private var eraseGroupOpen = false
    private var moveGroupOpen = false
    private var lastErasePoint: Pair<Float, Float>? = null
    private var downX: Float = 0f
    private var downY: Float = 0f
    private var movedBeyondSlop = false
    private var lastSelectionPoint: Pair<Float, Float>? = null

    var listener: Listener? = null

    init {
        setWillNotDraw(false)
        paperLayer.layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
        inProgress.layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
        addView(paperLayer)
        addView(inProgress)
        inProgress.addFinishedStrokesListener(
            object : InProgressStrokesFinishedListener {
                override fun onStrokesFinished(strokes: Map<InProgressStrokeId, Stroke>) {
                    commitFinished(strokes)
                    inProgress.removeFinishedStrokes(strokes.keys)
                }
            },
        )
    }

    // ------------------------------------------------------------------
    // Public editor API
    // ------------------------------------------------------------------

    val snapshot: InkSnapshot? get() = document?.snapshot()

    fun loadDocument(document: InkDocument?) {
        if (this.document !== document) {
            cancelInProgress()
            this.document = document
            paperLayer.invalidateStrokeCache()
        }
        document?.let {
            pageWidthPt = it.geometry.widthPt
            pageHeightPt = it.geometry.heightPt
        }
        fitted = false
        requestFit()
        notifyChanged()
    }

    fun setBrush(brush: InkBrushSpec) {
        currentBrush = brush
    }

    fun setEraserRadiusPt(radiusPt: Float) {
        eraserRadiusPt = radiusPt.coerceIn(1f, 64f)
    }

    fun setSelectionMode(enabled: Boolean) {
        selectionMode = enabled
        if (!enabled) {
            document?.clearSelection()
            notifySelection()
        }
    }

    fun setInputConfig(config: InkInputConfig) {
        inputConfig = config
    }

    fun setEraserMode(enabled: Boolean) {
        inputConfig = inputConfig.copy(eraserMode = enabled)
        setSelectionMode(false)
    }

    fun setPenOnly(enabled: Boolean) {
        inputConfig = if (enabled) {
            inputConfig.copy(penOnly = true, fingerWriting = false)
        } else {
            inputConfig.copy(penOnly = false, fingerWriting = true)
        }
    }

    fun setPaperColor(color: Int) {
        paperColor = color
        paperLayer.invalidate()
    }

    fun undo(): Boolean {
        val doc = document ?: return false
        cancelInProgress()
        val changed = doc.undo()
        if (changed) {
            paperLayer.invalidateStrokeCache()
            notifyChanged()
        }
        return changed
    }

    fun redo(): Boolean {
        val doc = document ?: return false
        cancelInProgress()
        val changed = doc.redo()
        if (changed) {
            paperLayer.invalidateStrokeCache()
            notifyChanged()
        }
        return changed
    }

    /** Commits nothing: drops any in-progress stroke (page change/background). */
    fun cancelInProgress() {
        if (inProgress.hasUnfinishedStrokes()) inProgress.cancelUnfinishedStrokes()
        inProgressIds.clear()
        nativeIds.clear()
        document?.cancelAllPending()
        router.reset()
        closeGroups()
        lastErasePoint = null
        paperLayer.invalidate()
    }

    fun deleteSelection(): Boolean {
        val doc = document ?: return false
        val changed = doc.deleteSelection()
        if (changed) {
            paperLayer.invalidateStrokeCache()
            notifyChanged()
        }
        return changed
    }

    fun resetView() {
        rotationQuarterTurns = 0
        fitted = false
        requestFit()
    }

    /** 1.0 == fit page at load; exposed for pinch-to-zoom UI affordances. */
    val zoomFraction: Float
        get() = if (baseScalePxPerPt <= 0f) 1f else scalePxPerPt / baseScalePxPerPt

    fun zoomBy(factor: Float, focusX: Float = width / 2f, focusY: Float = height / 2f) {
        if (!factor.isFinite() || factor <= 0f) return
        val old = scalePxPerPt
        val target = (old * factor).coerceIn(baseScalePxPerPt * MIN_ZOOM, baseScalePxPerPt * MAX_ZOOM)
        if (target == old) return
        val paper = viewToPaper(focusX, focusY) ?: return
        scalePxPerPt = target
        val after = paperToView(paper.first, paper.second) ?: return
        panXPx += focusX - after.first
        panYPx += focusY - after.second
        paperLayer.invalidate()
    }

    fun currentPaperTransform(): Matrix = paperToViewMatrix()

    // ------------------------------------------------------------------
    // Layout / fit
    // ------------------------------------------------------------------

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        if (!fitted) requestFit() else paperLayer.invalidate()
    }

    private fun requestFit() {
        post {
            if (width <= 0 || height <= 0 || pageWidthPt <= 0f || pageHeightPt <= 0f) return@post
            val (w, h) = effectivePageSize()
            baseScalePxPerPt = min(width / w, height / h).coerceAtLeast(MIN_SCALE_PX_PER_PT)
            scalePxPerPt = baseScalePxPerPt
            panXPx = 0f
            panYPx = 0f
            fitted = true
            invalidateAll()
        }
    }

    private fun effectivePageSize(): Pair<Float, Float> =
        if (rotationQuarterTurns % 2 == 0) pageWidthPt to pageHeightPt else pageHeightPt to pageWidthPt

    private fun invalidateAll() {
        paperLayer.invalidate()
        inProgress.invalidate()
    }

    // ------------------------------------------------------------------
    // Touch
    // ------------------------------------------------------------------

    override fun onInterceptTouchEvent(ev: MotionEvent): Boolean = true

    override fun onTouchEvent(event: MotionEvent): Boolean {
        val doc = document ?: return false
        if (doc.geometry.widthPt <= 0f) return false
        val sample = toSample(event)
        if (sample == null) {
            cancelInProgress()
            return true
        }
        if (event.actionMasked == MotionEvent.ACTION_HOVER_MOVE ||
            event.actionMasked == MotionEvent.ACTION_HOVER_ENTER ||
            event.actionMasked == MotionEvent.ACTION_HOVER_EXIT
        ) {
            return true
        }
        if (event.actionMasked == MotionEvent.ACTION_DOWN) {
            downX = event.x
            downY = event.y
            movedBeyondSlop = false
            lastSelectionPoint = null
            requestUnbuffered(event)
        }
        if (event.actionMasked == MotionEvent.ACTION_MOVE) {
            if (hypot(event.x - downX, event.y - downY) > TOUCH_SLOP_PX) movedBeyondSlop = true
        }
        for (intent in router.onSample(sample)) {
            handleIntent(intent, event, doc)
        }
        return true
    }

    private fun handleIntent(intent: InkGestureIntent, event: MotionEvent, doc: InkDocument) {
        when (intent) {
            is InkGestureIntent.BeginStroke -> {
                if (selectionMode && samplePointInSelectionMode(event)) {
                    // Tap select on DOWN is deferred to UP; drag moves selection.
                    return
                }
                val brush = currentBrush
                val modelId = nextStrokeId++
                if (!doc.beginStroke(modelId, brush, System.currentTimeMillis())) return
                val viewToPaper = viewToPaperMatrix()
                val strokeId = try {
                    inProgress.startStroke(event, intent.pointerId, InkNativeBridge.brushFor(brush) ?: run {
                        doc.cancelStroke(modelId)
                        return
                    }, viewToPaper)
                } catch (_: Exception) {
                    doc.cancelStroke(modelId)
                    return
                }
                inProgressIds[strokeId] = modelId
                nativeIds[intent.pointerId] = modelId
            }

            is InkGestureIntent.ExtendStroke -> {
                if (selectionMode) {
                    moveSelectionDrag(event, doc)
                    return
                }
                try {
                    inProgress.addToStroke(event, intent.pointerId)
                } catch (_: Exception) {
                    cancelPointerStroke(intent.pointerId)
                }
            }

            is InkGestureIntent.EndStroke -> {
                if (selectionMode) {
                    handleSelectionTapOrMoveEnd(event, doc)
                    return
                }
                try {
                    inProgress.finishStroke(event, intent.pointerId)
                } catch (_: Exception) {
                    cancelPointerStroke(intent.pointerId)
                }
                nativeIds.remove(intent.pointerId)
            }

            InkGestureIntent.CancelInk -> {
                inProgress.cancelUnfinishedStrokes()
                inProgressIds.values.forEach { doc.cancelStroke(it) }
                inProgressIds.clear()
                nativeIds.clear()
                // A cancelled gesture must not leave an open undo group behind.
                closeGroups()
                lastSelectionPoint = null
                listener?.onInkCanceled()
                paperLayer.invalidate()
            }

            is InkGestureIntent.BeginErase -> {
                moveGroupOpen = false
                eraseGroupOpen = doc.beginGroup() > 0
                lastErasePoint = eraseAt(intent.xPx, intent.yPx, doc)
            }

            is InkGestureIntent.ExtendErase -> {
                lastErasePoint = eraseAt(intent.xPx, intent.yPx, doc)
            }

            InkGestureIntent.EndErase -> {
                lastErasePoint = null
                if (eraseGroupOpen) {
                    doc.endGroup()
                    eraseGroupOpen = false
                    notifyChanged()
                }
                paperLayer.invalidate()
            }

            is InkGestureIntent.TransformStart -> {
                closeGroups()
                lastErasePoint = null
            }

            is InkGestureIntent.TransformMove -> {
                if (intent.scaleFactor != 1f && intent.scaleFactor.isFinite()) {
                    val target = (scalePxPerPt * intent.scaleFactor)
                        .coerceIn(baseScalePxPerPt * MIN_ZOOM, baseScalePxPerPt * MAX_ZOOM)
                    val actual = target / scalePxPerPt
                    val paper = viewToPaper(intent.focusX, intent.focusY)
                    scalePxPerPt = target
                    if (paper != null) {
                        val after = paperToView(paper.first, paper.second)
                        if (after != null) {
                            panXPx += intent.focusX - after.first
                            panYPx += intent.focusY - after.second
                        }
                    }
                    clampPan()
                }
                panXPx += intent.dxPx
                panYPx += intent.dyPx
                clampPan()
                paperLayer.invalidate()
                inProgress.invalidate()
            }

            InkGestureIntent.TransformEnd -> paperLayer.invalidate()

            InkGestureIntent.Ignored -> Unit
        }
    }

    private fun samplePointInSelectionMode(event: MotionEvent): Boolean =
        selectionMode && event.actionMasked == MotionEvent.ACTION_DOWN

    private fun handleSelectionTapOrMoveEnd(event: MotionEvent, doc: InkDocument) {
        val paper = viewToPaper(event.x, event.y) ?: return
        if (!movedBeyondSlop) {
            val hit = InkNativeBridge.topmostHit(doc.strokes, paper.first, paper.second, SELECT_TOLERANCE_PT)
            if (hit == null) {
                doc.clearSelection()
            } else {
                doc.setSelection(setOf(hit.id))
            }
            notifySelection()
            paperLayer.invalidate()
            return
        }
        lastSelectionPoint = null
        if (moveGroupOpen) {
            doc.endGroup()
            moveGroupOpen = false
            notifyChanged()
        }
    }

    /** Drags the current selection with the finger/pen (selection mode only). */
    private fun moveSelectionDrag(event: MotionEvent, doc: InkDocument) {
        if (doc.selectedStrokeIds.isEmpty()) return
        val paper = viewToPaper(event.x, event.y) ?: return
        val previous = lastSelectionPoint
        lastSelectionPoint = paper
        if (previous == null || !movedBeyondSlop) return
        if (!moveGroupOpen) {
            doc.beginGroup()
            moveGroupOpen = true
        }
        val dx = paper.first - previous.first
        val dy = paper.second - previous.second
        if (dx == 0f && dy == 0f) return
        if (doc.moveSelection(dx, dy)) {
            paperLayer.invalidate()
        }
    }

    /** Erases every topmost stroke at the pointer and returns the paper point. */
    private fun eraseAt(xPx: Float, yPx: Float, doc: InkDocument): Pair<Float, Float>? {
        val paper = viewToPaper(xPx, yPx) ?: return null
        val hits = ArrayList<Long>(2)
        for (stroke in doc.strokes) {
            if (InkNativeBridge.isHit(stroke, paper.first, paper.second, eraserRadiusPt)) {
                hits.add(stroke.id)
            }
        }
        if (hits.isNotEmpty()) {
            doc.deleteStrokes(hits.toSet())
            paperLayer.invalidateStrokeCache()
            paperLayer.invalidate()
        }
        return paper
    }

    /** Erase handled on MOVE in selection-less eraser mode (drag). */
    private fun cancelPointerStroke(pointerId: Int) {
        val modelId = nativeIds.remove(pointerId) ?: return
        document?.cancelStroke(modelId)
        runCatching { inProgress.cancelUnfinishedStrokes() }
        inProgressIds.values.forEach { document?.cancelStroke(it) }
        inProgressIds.clear()
        listener?.onInkCanceled()
        paperLayer.invalidate()
    }

    private fun commitFinished(strokes: Map<InProgressStrokeId, Stroke>) {
        val doc = document ?: return
        var changed = false
        for ((nativeId, stroke) in strokes) {
            val modelId = inProgressIds.remove(nativeId) ?: continue
            val bytes = InkNativeBridge.encodeStrokeInputs(stroke.inputs)
            val bounds = InkNativeBridge.localBounds(stroke)
            if (bytes == null || bounds == null) {
                doc.cancelStroke(modelId)
                continue
            }
            if (!doc.appendStrokeInput(modelId, bytes, bounds)) {
                doc.cancelStroke(modelId)
                continue
            }
            // Model ids are pre-registered on DOWN; finish commits under that id.
            val committed = doc.finishStroke(modelId)
            if (committed == null) continue
            changed = true
            listener?.onStrokeCommitted(committed)
        }
        nativeIds.clear()
        if (changed) {
            paperLayer.invalidateStrokeCache()
            paperLayer.invalidate()
            notifyChanged()
        }
    }

    private fun closeGroups() {
        val doc = document ?: return
        if (eraseGroupOpen) {
            doc.endGroup()
            eraseGroupOpen = false
        }
        if (moveGroupOpen) {
            doc.endGroup()
            moveGroupOpen = false
        }
    }

    private fun notifyChanged() {
        val doc = document ?: return
        listener?.onDocumentChanged(doc.snapshot(), doc.canUndo, doc.canRedo)
        notifySelection()
    }

    private fun notifySelection() {
        listener?.onSelectionChanged(document?.selectedStrokeIds ?: emptySet())
    }

    // ------------------------------------------------------------------
    // Transform math
    // ------------------------------------------------------------------

    private fun paperToViewMatrix(): Matrix {
        val matrix = Matrix()
        val (w, h) = pageWidthPt to pageHeightPt
        matrix.postTranslate(-w / 2f, -h / 2f)
        matrix.postRotate(rotationQuarterTurns * 90f)
        matrix.postScale(scalePxPerPt, scalePxPerPt)
        matrix.postTranslate(width / 2f + panXPx, height / 2f + panYPx)
        return matrix
    }

    private fun viewToPaperMatrix(): Matrix {
        val inverse = Matrix()
        if (!paperToViewMatrix().invert(inverse)) inverse.reset()
        return inverse
    }

    private fun paperToView(x: Float, y: Float): Pair<Float, Float>? {
        val points = floatArrayOf(x, y)
        paperToViewMatrix().mapPoints(points)
        return if (points[0].isFinite() && points[1].isFinite()) points[0] to points[1] else null
    }

    private fun viewToPaper(x: Float, y: Float): Pair<Float, Float>? {
        val points = floatArrayOf(x, y)
        viewToPaperMatrix().mapPoints(points)
        return if (points[0].isFinite() && points[1].isFinite()) points[0] to points[1] else null
    }

    private fun clampPan() {
        if (width <= 0 || height <= 0) return
        val (w, h) = effectivePageSize()
        val contentW = w * scalePxPerPt
        val contentH = h * scalePxPerPt
        val maxX = max(contentW, width.toFloat()) / 2f
        val maxY = max(contentH, height.toFloat()) / 2f
        panXPx = panXPx.coerceIn(-maxX, maxX)
        panYPx = panYPx.coerceIn(-maxY, maxY)
    }

    // ------------------------------------------------------------------
    // MotionEvent conversion
    // ------------------------------------------------------------------

    private fun toSample(event: MotionEvent): InkPointerSample? {
        val action = when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> InkPointerAction.DOWN
            MotionEvent.ACTION_POINTER_DOWN -> InkPointerAction.POINTER_DOWN
            MotionEvent.ACTION_MOVE -> InkPointerAction.MOVE
            MotionEvent.ACTION_POINTER_UP -> InkPointerAction.POINTER_UP
            MotionEvent.ACTION_UP -> InkPointerAction.UP
            MotionEvent.ACTION_CANCEL -> InkPointerAction.CANCEL
            MotionEvent.ACTION_HOVER_MOVE, MotionEvent.ACTION_HOVER_ENTER, MotionEvent.ACTION_HOVER_EXIT ->
                InkPointerAction.HOVER
            else -> return null
        }
        val index = if (event.actionMasked == MotionEvent.ACTION_POINTER_DOWN ||
            event.actionMasked == MotionEvent.ACTION_POINTER_UP
        ) {
            event.actionIndex.coerceIn(0, max(0, event.pointerCount - 1))
        } else {
            0
        }
        if (event.pointerCount <= 0) return null
        val pointers = ArrayList<InkPointerPosition>(event.pointerCount)
        for (i in 0 until event.pointerCount) {
            pointers.add(InkPointerPosition(event.getPointerId(i), event.getX(i), event.getY(i)))
        }
        return InkPointerSample(
            action = action,
            pointerId = event.getPointerId(index),
            pointerCount = event.pointerCount,
            toolType = when (event.getToolType(index)) {
                MotionEvent.TOOL_TYPE_STYLUS -> InkPointerKind.PEN
                MotionEvent.TOOL_TYPE_ERASER -> InkPointerKind.ERASER
                MotionEvent.TOOL_TYPE_FINGER -> InkPointerKind.FINGER
                MotionEvent.TOOL_TYPE_MOUSE -> InkPointerKind.MOUSE
                else -> InkPointerKind.UNKNOWN
            },
            xPx = event.getX(index),
            yPx = event.getY(index),
            pressure = event.getPressure(index),
            hasPressure = event.getToolType(index) == MotionEvent.TOOL_TYPE_STYLUS,
            primaryButtonPressed = (event.buttonState and MotionEvent.BUTTON_PRIMARY) != 0,
            canceledBySystem = event.flags and MotionEvent.FLAG_CANCELED != 0,
            pointers = pointers,
        )
    }

    private fun requestUnbuffered(event: MotionEvent) {
        runCatching { requestUnbufferedDispatch(event) }
    }

    override fun onDetachedFromWindow() {
        cancelInProgress()
        inProgress.clearFinishedStrokesListeners()
        super.onDetachedFromWindow()
    }

    // ------------------------------------------------------------------
    // Rendering layer
    // ------------------------------------------------------------------

    private inner class PaperLayer(context: Context) : View(context) {
        private val canvasStrokeRenderer: CanvasStrokeRenderer = CanvasStrokeRenderer.create()
        private val viewStrokeRenderer = ViewStrokeRenderer(canvasStrokeRenderer, this)
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        private val strokeCache = HashMap<Long, Stroke>()
        private val cacheSource = HashMap<Long, InkStroke>()

        private val selectionPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            color = SELECTION_COLOR
            strokeWidth = 1.5f
            pathEffect = DashPathEffect(floatArrayOf(8f, 6f), 0f)
        }
        private val cursorPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            color = ERASER_COLOR
            strokeWidth = 2f
        }

        fun invalidateStrokeCache() {
            strokeCache.clear()
            cacheSource.clear()
        }

        override fun onDraw(canvas: Canvas) {
            canvas.drawColor(paperColor)
            val matrix = paperToViewMatrix()
            val doc = document
            if (doc != null) {
                val currentIds = HashSet<Long>(doc.strokeCount)
                viewStrokeRenderer.drawWithStrokes(canvas) { scope ->
                    canvas.concat(matrix)
                    for (record in doc.strokes) {
                        currentIds.add(record.id)
                        val stroke = nativeStroke(record) ?: continue
                        val checkpoint = canvas.save()
                        canvas.concat(InkNativeBridge.toAndroidMatrix(record.transform))
                        scope.drawStroke(stroke)
                        canvas.restoreToCount(checkpoint)
                    }
                }
                if (currentIds.size != strokeCache.size || !strokeCache.keys.containsAll(currentIds)) {
                    strokeCache.keys.retainAll(currentIds)
                    cacheSource.keys.retainAll(currentIds)
                }
                drawSelection(canvas, doc, matrix)
            }
            drawEraserCursor(canvas)
        }

        private fun nativeStroke(record: InkStroke): Stroke? {
            val cached = strokeCache[record.id]
            if (cached != null && cacheSource[record.id] === record) return cached
            val stroke = InkNativeBridge.toStroke(record) ?: return null
            strokeCache[record.id] = stroke
            cacheSource[record.id] = record
            return stroke
        }

        private fun drawSelection(canvas: Canvas, doc: InkDocument, matrix: Matrix) {
            if (doc.selectedStrokeIds.isEmpty()) return
            for (stroke in doc.strokes) {
                if (stroke.id !in doc.selectedStrokeIds) continue
                val bounds = stroke.transformedBounds()
                val points = floatArrayOf(
                    bounds.left, bounds.top,
                    bounds.right, bounds.top,
                    bounds.right, bounds.bottom,
                    bounds.left, bounds.bottom,
                )
                matrix.mapPoints(points)
                var left = points[0]
                var top = points[1]
                var right = points[0]
                var bottom = points[1]
                for (i in 0 until 4) {
                    left = min(left, points[i * 2])
                    right = max(right, points[i * 2])
                    top = min(top, points[i * 2 + 1])
                    bottom = max(bottom, points[i * 2 + 1])
                }
                canvas.drawRect(left, top, right, bottom + 1f, selectionPaint)
            }
        }

        private fun drawEraserCursor(canvas: Canvas) {
            val point = lastErasePoint ?: return
            val viewPoint = paperToView(point.first, point.second) ?: return
            canvas.drawCircle(viewPoint.first, viewPoint.second, eraserRadiusPt * scalePxPerPt, cursorPaint)
        }
    }

    companion object {
        const val MIN_ZOOM: Float = 0.5f
        const val MAX_ZOOM: Float = 6f
        const val MIN_SCALE_PX_PER_PT: Float = 0.1f
        const val TOUCH_SLOP_PX: Float = 8f
        const val SELECT_TOLERANCE_PT: Float = 4f
        const val SELECTION_COLOR: Int = 0xFF2F6BFF.toInt()
        const val ERASER_COLOR: Int = 0xCC555555.toInt()
    }
}
