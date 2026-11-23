// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.ink

/**
 * Pointer classification. Derived from `MotionEvent.getToolType`, never from a
 * device model or a stylus-brand assumption.
 */
enum class InkPointerKind { PEN, ERASER, FINGER, MOUSE, UNKNOWN }

enum class InkPointerAction {
    DOWN,
    POINTER_DOWN,
    MOVE,
    POINTER_UP,
    UP,
    CANCEL,
    HOVER,
}

/**
 * One normalized pointer sample. [pressure] is the value the platform
 * REPORTED (0..1); it is never synthesized, and [hasPressure] is false when the
 * source did not provide it. Palm rejection/pressure are therefore reported
 * honestly, not simulated.
 */
data class InkPointerPosition(val pointerId: Int, val xPx: Float, val yPx: Float)

data class InkPointerSample(
    val action: InkPointerAction,
    val pointerId: Int,
    val pointerCount: Int,
    val toolType: InkPointerKind,
    val xPx: Float,
    val yPx: Float,
    val pressure: Float = 0f,
    val hasPressure: Boolean = false,
    val primaryButtonPressed: Boolean = false,
    val canceledBySystem: Boolean = false,
    /** All pointers currently in the event (needed for pinch focus/span). */
    val pointers: List<InkPointerPosition> = emptyList(),
)

/** User input configuration for one editor surface. */
data class InkInputConfig(
    /** Finger writing is ON by default; pen-only hides finger strokes. */
    val fingerWriting: Boolean = true,
    /** When true, only stylus/eraser tools draw; fingers pan/zoom. */
    val penOnly: Boolean = false,
    /** Mouse/trackpad primary-button drag draws. */
    val mouseDraws: Boolean = true,
    /** Two-finger gestures pan/zoom (and cancel an in-progress stroke). */
    val twoFingerTransform: Boolean = true,
    /** Eraser tool selected in the UI: pen/finger strokes erase instead of ink. */
    val eraserMode: Boolean = false,
) {
    init {
        require(!(penOnly && fingerWriting)) { "penOnly implies finger writing is disabled" }
    }
}

/**
 * Intents the router emits; the Android view maps them to native callbacks.
 * They contain no Android types so the routing rules are JVM-testable.
 */
sealed class InkGestureIntent {
    data class BeginStroke(val pointerId: Int, val kind: InkPointerKind) : InkGestureIntent()
    data class ExtendStroke(val pointerId: Int, val xPx: Float, val yPx: Float) : InkGestureIntent()
    data class EndStroke(val pointerId: Int) : InkGestureIntent()
    data class BeginErase(val pointerId: Int, val xPx: Float, val yPx: Float) : InkGestureIntent()
    data class ExtendErase(val xPx: Float, val yPx: Float) : InkGestureIntent()
    object EndErase : InkGestureIntent()
    object CancelInk : InkGestureIntent()
    data class TransformStart(val focusX: Float, val focusY: Float) : InkGestureIntent()
    data class TransformMove(
        val dxPx: Float,
        val dyPx: Float,
        val scaleFactor: Float,
        val focusX: Float,
        val focusY: Float,
    ) : InkGestureIntent()
    object TransformEnd : InkGestureIntent()
    object Ignored : InkGestureIntent()
}

/**
 * Pure pointer router for one ink canvas.
 *
 * Rules encoded (and unit-tested):
 *  - a contact cancelled by Android cannot commit ink;
 *  - pen and eraser input take precedence when a hand is resting on the
 *    screen. Two fingers still transform when no hardware pen is active;
 *  - finger writing is on by default; [InkInputConfig.penOnly] turns fingers
 *    into navigation only;
 *  - the eraser tool emits erase intents instead of strokes;
 *  - a gesture that starts with two fingers never starts a stroke when one
 *    remains (no accidental ink after a pinch).
 */
class InkPointerRouter(private val config: () -> InkInputConfig) {

    private var activeStroke: Int? = null
    private var activeErase: Int? = null
    private var hardwarePenPointer: Int? = null
    private var transforming = false
    private var transformPointerCount = 0
    private var lastFocusX = 0f
    private var lastFocusY = 0f
    private var lastSpan = 0f
    private val pointerPositions = HashMap<Int, Pair<Float, Float>>()

    fun reset() {
        activeStroke = null
        activeErase = null
        hardwarePenPointer = null
        transforming = false
        transformPointerCount = 0
        lastSpan = 0f
        pointerPositions.clear()
    }

    fun onSample(sample: InkPointerSample): List<InkGestureIntent> {
        val cfg = config()
        remember(sample)
        return when (sample.action) {
            InkPointerAction.HOVER -> listOf(InkGestureIntent.Ignored)
            InkPointerAction.CANCEL -> {
                val intents = ArrayList<InkGestureIntent>(2)
                if (activeStroke != null || activeErase != null) intents.add(InkGestureIntent.CancelInk)
                if (transforming) intents.add(InkGestureIntent.TransformEnd)
                reset()
                if (intents.isEmpty()) intents.add(InkGestureIntent.Ignored)
                intents
            }

            InkPointerAction.DOWN -> {
                if (sample.canceledBySystem) {
                    return listOf(InkGestureIntent.CancelInk)
                }
                if (activeStroke != null || activeErase != null) {
                    // A fresh DOWN while a stroke is open is a protocol error;
                    // cancel the old one instead of leaking it.
                    activeStroke = null
                    activeErase = null
                    hardwarePenPointer = null
                    return listOf(InkGestureIntent.CancelInk)
                }
                listOf(beginInput(sample, cfg))
            }

            InkPointerAction.POINTER_DOWN -> {
                if (hardwarePenPointer != null || sample.canceledBySystem) {
                    listOf(InkGestureIntent.Ignored)
                } else if (sample.isHardwarePen) {
                    val intents = ArrayList<InkGestureIntent>(3)
                    if (activeStroke != null || activeErase != null) intents.add(InkGestureIntent.CancelInk)
                    if (transforming) intents.add(InkGestureIntent.TransformEnd)
                    activeStroke = null
                    activeErase = null
                    transforming = false
                    transformPointerCount = 0
                    intents.add(beginInput(sample, cfg))
                    intents
                } else if (cfg.twoFingerTransform && sample.pointerCount >= 2) {
                    val intents = ArrayList<InkGestureIntent>(2)
                    if (activeStroke != null || activeErase != null) {
                        intents.add(InkGestureIntent.CancelInk)
                    }
                    activeStroke = null
                    activeErase = null
                    transforming = true
                    transformPointerCount = sample.pointerCount
                    val focus = focus()
                    lastFocusX = focus.first
                    lastFocusY = focus.second
                    lastSpan = span()
                    intents.add(InkGestureIntent.TransformStart(focus.first, focus.second))
                    intents
                } else if (activeStroke == null && activeErase == null &&
                    classify(sample, cfg) == Decision.PEN_STROKE
                ) {
                    listOf(beginInput(sample, cfg))
                } else {
                    listOf(InkGestureIntent.Ignored)
                }
            }

            InkPointerAction.MOVE -> {
                if (transforming && sample.pointerCount >= 2) {
                    val focus = focus()
                    val currentSpan = span()
                    val scale = if (lastSpan > 1f && currentSpan > 1f) currentSpan / lastSpan else 1f
                    val intent = InkGestureIntent.TransformMove(
                        dxPx = focus.first - lastFocusX,
                        dyPx = focus.second - lastFocusY,
                        scaleFactor = scale,
                        focusX = focus.first,
                        focusY = focus.second,
                    )
                    lastFocusX = focus.first
                    lastFocusY = focus.second
                    lastSpan = currentSpan
                    return listOf(intent)
                }
                val activePointer = activeStroke ?: activeErase
                val position = if (activePointer == sample.pointerId) {
                    InkPointerPosition(sample.pointerId, sample.xPx, sample.yPx)
                } else {
                    sample.pointers.firstOrNull { it.pointerId == activePointer }
                }
                if (position != null && activeStroke != null) {
                    return listOf(InkGestureIntent.ExtendStroke(position.pointerId, position.xPx, position.yPx))
                }
                if (position != null && activeErase != null) {
                    return listOf(InkGestureIntent.ExtendErase(position.xPx, position.yPx))
                }
                listOf(InkGestureIntent.Ignored)
            }

            InkPointerAction.POINTER_UP, InkPointerAction.UP -> {
                val intents = ArrayList<InkGestureIntent>(2)
                if (transforming) {
                    transformPointerCount = (sample.pointerCount - 1).coerceAtLeast(1)
                    if (transformPointerCount < 2) {
                        transforming = false
                        intents.add(InkGestureIntent.TransformEnd)
                    }
                }
                if (hardwarePenPointer == sample.pointerId) hardwarePenPointer = null
                if (activeStroke == sample.pointerId) {
                    activeStroke = null
                    intents.add(if (sample.canceledBySystem) InkGestureIntent.CancelInk
                        else InkGestureIntent.EndStroke(sample.pointerId))
                } else if (activeErase == sample.pointerId) {
                    activeErase = null
                    intents.add(if (sample.canceledBySystem) InkGestureIntent.CancelInk else InkGestureIntent.EndErase)
                }
                pointerPositions.remove(sample.pointerId)
                if (intents.isEmpty()) intents.add(InkGestureIntent.Ignored)
                intents
            }

        }
    }

    val hasActiveStroke: Boolean get() = activeStroke != null
    val isErasing: Boolean get() = activeErase != null
    val isTransforming: Boolean get() = transforming

    private enum class Decision { PEN_STROKE, ERASE, NAVIGATE }

    private val InkPointerSample.isHardwarePen: Boolean
        get() = toolType == InkPointerKind.PEN || toolType == InkPointerKind.ERASER

    private fun beginInput(sample: InkPointerSample, cfg: InkInputConfig): InkGestureIntent =
        when (classify(sample, cfg)) {
            Decision.PEN_STROKE -> {
                activeStroke = sample.pointerId
                if (sample.isHardwarePen) hardwarePenPointer = sample.pointerId
                InkGestureIntent.BeginStroke(sample.pointerId, sample.toolType)
            }
            Decision.ERASE -> {
                activeErase = sample.pointerId
                if (sample.isHardwarePen) hardwarePenPointer = sample.pointerId
                InkGestureIntent.BeginErase(sample.pointerId, sample.xPx, sample.yPx)
            }
            Decision.NAVIGATE -> InkGestureIntent.Ignored
        }

    private fun classify(sample: InkPointerSample, cfg: InkInputConfig): Decision = when {
        cfg.penOnly && !sample.isHardwarePen -> Decision.NAVIGATE
        cfg.eraserMode && sample.toolType != InkPointerKind.UNKNOWN -> Decision.ERASE
        else -> classifyByTool(sample, cfg)
    }

    private fun classifyByTool(sample: InkPointerSample, cfg: InkInputConfig): Decision = when (sample.toolType) {
        InkPointerKind.ERASER -> Decision.ERASE
        InkPointerKind.PEN -> Decision.PEN_STROKE
        InkPointerKind.MOUSE -> if (cfg.mouseDraws && sample.primaryButtonPressed) Decision.PEN_STROKE else Decision.NAVIGATE
        InkPointerKind.FINGER -> when {
            cfg.fingerWriting -> Decision.PEN_STROKE
            else -> Decision.NAVIGATE
        }
        InkPointerKind.UNKNOWN -> if (cfg.fingerWriting) Decision.PEN_STROKE else Decision.NAVIGATE
    }

    private fun remember(sample: InkPointerSample) {
        when (sample.action) {
            InkPointerAction.UP,
            InkPointerAction.POINTER_UP,
            InkPointerAction.CANCEL,
            -> pointerPositions.remove(sample.pointerId)
            else -> {
                pointerPositions[sample.pointerId] = sample.xPx to sample.yPx
                for (p in sample.pointers) {
                    if (p.pointerId == sample.pointerId) continue
                    pointerPositions[p.pointerId] = p.xPx to p.yPx
                }
            }
        }
    }

    private fun focus(): Pair<Float, Float> {
        if (pointerPositions.isEmpty()) return 0f to 0f
        var x = 0f
        var y = 0f
        for (p in pointerPositions.values) {
            x += p.first
            y += p.second
        }
        return (x / pointerPositions.size) to (y / pointerPositions.size)
    }

    private fun span(): Float {
        if (pointerPositions.size < 2) return 0f
        val points = pointerPositions.values.toList()
        var max = 0f
        for (i in points.indices) {
            for (j in i + 1 until points.size) {
                val dx = points[i].first - points[j].first
                val dy = points[i].second - points[j].second
                val d = kotlin.math.sqrt(dx * dx + dy * dy)
                if (d > max) max = d
            }
        }
        return max
    }
}
