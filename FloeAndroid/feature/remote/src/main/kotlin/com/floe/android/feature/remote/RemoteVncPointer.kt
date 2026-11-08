// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.remote

import kotlin.math.hypot
import kotlin.math.roundToInt

internal enum class VncInputMode(val value: String) {
    DIRECT("direct"), TRACKPAD("trackpad");

    companion object {
        fun restore(value: String?): VncInputMode = entries.firstOrNull { it.value == value } ?: DIRECT
    }
}

internal data class VncPointerPosition(val x: Float, val y: Float) {
    val pixel: Pair<Int, Int> get() = x.roundToInt() to y.roundToInt()
}

internal sealed interface VncPointerAction {
    data class Move(val x: Int, val y: Int) : VncPointerAction
    data class Button(val button: String, val down: Boolean, val x: Int, val y: Int) : VncPointerAction
}

/** Touch-only input state. The actual Compose event loop drives both events
 * and deadlines; there are no detached click jobs that can outlive a viewer.
 * Framebuffer coordinates retain fractions across small relative movements. */
internal class VncTouchPointer(
    private var width: Int,
    private var height: Int,
    var mode: VncInputMode,
    private val doubleTapMillis: Long,
    private val longPressMillis: Long,
    private val touchSlop: Float,
) {
    private var initialized = width > 0 && height > 0
    var position = VncPointerPosition((width - 1).coerceAtLeast(0) / 2f, (height - 1).coerceAtLeast(0) / 2f)
        private set

    private data class Press(
        val x: Float, val y: Float, val time: Long, val second: Boolean,
        val start: VncPointerPosition,
        var lastX: Float = x, var lastY: Float = y,
        var moved: Boolean = false, var long: Boolean = false, var held: Boolean = false,
    )
    private data class Tap(val at: VncPointerPosition, val deadline: Long)
    private var press: Press? = null
    private var tap: Tap? = null

    val deadline: Long?
        get() = press?.takeIf { !it.moved && !it.long }?.let { it.time + longPressMillis }
            ?: tap?.takeIf { press == null }?.deadline

    fun resize(width: Int, height: Int): List<VncPointerAction> {
        val actions = cancel()
        this.width = width
        this.height = height
        position = if (!initialized && width > 0 && height > 0) {
            initialized = true
            VncPointerPosition((width - 1) / 2f, (height - 1) / 2f)
        } else clamp(position)
        return actions
    }

    fun changeMode(mode: VncInputMode): List<VncPointerAction> = cancel().also { this.mode = mode }

    fun down(x: Float, y: Float, time: Long, transform: RemoteVncTransform): List<VncPointerAction> {
        if (width <= 0 || height <= 0) return emptyList()
        val expired = tick(time)
        val absolute = if (mode == VncInputMode.DIRECT) vncMapPoint(transform, x, y) else null
        if (mode == VncInputMode.DIRECT && absolute == null) return expired
        val second = tap?.let { time < it.deadline } == true
        tap = null
        val move = if (absolute != null) setAbsolute(absolute.first, absolute.second) else emptyList()
        press = Press(x, y, time, second, position)
        return expired + move
    }

    fun move(x: Float, y: Float, transform: RemoteVncTransform): List<VncPointerAction> {
        val p = press ?: return emptyList()
        if (p.long && mode == VncInputMode.DIRECT) return emptyList()
        val firstMovement = !p.moved
        if (!p.held && !p.moved && hypot(x - p.x, y - p.y) < touchSlop) return emptyList()
        p.moved = true
        tap = null
        val actions = mutableListOf<VncPointerAction>()
        if (mode == VncInputMode.DIRECT) {
            if (!p.held) {
                p.held = true
                actions += button("left", true, p.start)
            }
            vncMapPoint(transform, x, y)?.let { actions += setAbsolute(it.first, it.second) }
        } else if (transform.scale > 0f) {
            val fromX = if (firstMovement && !p.held) p.x else p.lastX
            val fromY = if (firstMovement && !p.held) p.y else p.lastY
            position = clamp(VncPointerPosition(
                position.x + (x - fromX) / transform.scale,
                position.y + (y - fromY) / transform.scale,
            ))
            actions += VncPointerAction.Move(position.pixel.first, position.pixel.second)
        }
        p.lastX = x
        p.lastY = y
        return actions
    }

    fun up(time: Long): List<VncPointerAction> {
        val p = press ?: return emptyList()
        press = null
        return when {
            p.held -> listOf(button("left", false, position))
            p.moved || p.long -> emptyList()
            mode == VncInputMode.DIRECT -> click("left", position)
            p.second -> click("right", position)
            else -> {
                tap = Tap(position, time + doubleTapMillis)
                emptyList()
            }
        }
    }

    fun tick(time: Long): List<VncPointerAction> {
        val p = press
        if (p != null && !p.moved && !p.long && time >= p.time + longPressMillis) {
            p.long = true
            tap = null
            return if (mode == VncInputMode.TRACKPAD) {
                p.held = true
                listOf(button("left", true, position))
            } else click("right", position)
        }
        val pending = tap
        if (p == null && pending != null && time >= pending.deadline) {
            tap = null
            return click("left", pending.at)
        }
        return emptyList()
    }

    /** Also used for multitouch takeover, menus, lifecycle and session changes. */
    fun cancel(): List<VncPointerAction> {
        val held = press?.held == true
        press = null
        tap = null
        return if (held) listOf(button("left", false, position)) else emptyList()
    }

    fun setAbsolute(x: Int, y: Int): List<VncPointerAction> {
        position = clamp(VncPointerPosition(x.toFloat(), y.toFloat()))
        return listOf(VncPointerAction.Move(position.pixel.first, position.pixel.second))
    }

    private fun clamp(point: VncPointerPosition) = VncPointerPosition(
        point.x.coerceIn(0f, (width - 1).coerceAtLeast(0).toFloat()),
        point.y.coerceIn(0f, (height - 1).coerceAtLeast(0).toFloat()),
    )

    private fun button(name: String, down: Boolean, at: VncPointerPosition): VncPointerAction.Button =
        VncPointerAction.Button(name, down, at.pixel.first, at.pixel.second)

    private fun click(name: String, at: VncPointerPosition): List<VncPointerAction> =
        listOf(button(name, true, at), button(name, false, at))
}

internal fun vncPanToPointer(
    transform: RemoteVncTransform, point: VncPointerPosition,
    viewWidth: Float, viewHeight: Float, zoom: Float, panX: Float, panY: Float,
    margin: Float,
): Pair<Float, Float> {
    fun correction(value: Float, extent: Float): Float {
        val inset = margin.coerceIn(0f, extent.coerceAtLeast(0f) / 2f)
        return when {
            value < inset -> inset - value
            value > extent - inset -> extent - inset - value
            else -> 0f
        }
    }
    return vncClampPan(
        viewWidth, viewHeight, transform.frameWidth, transform.frameHeight, zoom,
        panX + correction(transform.offsetX + point.x * transform.scale, viewWidth),
        panY + correction(transform.offsetY + point.y * transform.scale, viewHeight),
    )
}
