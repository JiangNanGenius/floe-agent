// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.remote

import android.os.SystemClock
import androidx.compose.foundation.gestures.calculateCentroid
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.PointerId
import androidx.compose.ui.input.pointer.PointerInputScope
import androidx.compose.ui.input.pointer.PointerType
import androidx.compose.ui.input.pointer.isPrimaryPressed
import androidx.compose.ui.input.pointer.isSecondaryPressed
import androidx.compose.ui.input.pointer.isTertiaryPressed
import kotlin.math.abs
import kotlin.math.roundToInt

/** One recognizer owns taps, movement, deadlines and multitouch takeover.
 * Physical mouse buttons bypass the touchpad tap mapping completely. */
internal suspend fun PointerInputScope.detectVncPointerInput(
    pointer: VncTouchPointer,
    transform: () -> RemoteVncTransform,
    onInput: (List<VncPointerAction>) -> Unit,
    onReleaseAll: () -> Unit,
    onWheel: (String, Int, Int, Int) -> Unit,
    onTransform: (Offset, Offset, Float) -> Unit,
) {
    var active: PointerId? = null
    var multiTouch = false
    var mouseButtons = emptySet<String>()
    try {
        awaitPointerEventScope {
            while (true) {
                val deadline = pointer.deadline
                val event = if (deadline == null) awaitPointerEvent() else {
                    withTimeoutOrNull((deadline - SystemClock.uptimeMillis()).coerceAtLeast(1L)) {
                        awaitPointerEvent()
                    }
                }
                if (event == null) {
                    onInput(pointer.tick(SystemClock.uptimeMillis()))
                    continue
                }
                val first = event.changes.firstOrNull() ?: continue
                val pressed = event.changes.count { it.pressed }
                if (first.type == PointerType.Mouse) {
                    onInput(pointer.cancel())
                    active = null
                    val at = vncMapPoint(transform(), first.position.x, first.position.y)
                    if (at != null) onInput(pointer.setAbsolute(at.first, at.second))
                    val buttons = buildSet {
                        if (event.buttons.isPrimaryPressed) add("left")
                        if (event.buttons.isSecondaryPressed) add("right")
                        if (event.buttons.isTertiaryPressed) add("middle")
                    }
                    val (x, y) = pointer.position.pixel
                    onInput((mouseButtons - buttons).map { VncPointerAction.Button(it, false, x, y) } +
                        (buttons - mouseButtons).filter { at != null }.map { VncPointerAction.Button(it, true, x, y) })
                    // Only remember presses actually sent inside the image.
                    mouseButtons = buttons.intersect(mouseButtons) + if (at != null) buttons else emptySet()
                    if (event.type == PointerEventType.Scroll) {
                        val delta = first.scrollDelta.y
                        if (at != null && abs(delta) > 0.01f) {
                            onWheel(if (delta < 0f) "up" else "down",
                                abs(delta).roundToInt().coerceIn(1, 20), x, y)
                        }
                    }
                    event.changes.forEach { it.consume() }
                    continue
                }
                if (pressed >= 2 || multiTouch) {
                    if (!multiTouch) {
                        onInput(pointer.cancel())
                        onReleaseAll()
                        active = null
                        multiTouch = true
                    }
                    if (event.changes.count { it.pressed && it.previousPressed } >= 2) {
                        onTransform(event.calculateCentroid(useCurrent = false), event.calculatePan(), event.calculateZoom())
                    }
                    event.changes.forEach { it.consume() }
                    if (pressed == 0) multiTouch = false
                    continue
                }
                if (first.isConsumed) {
                    onInput(pointer.cancel())
                    active = null
                    // Drain until all fingers are up, just as after takeover.
                    multiTouch = pressed > 0
                    continue
                }
                if (active == null && first.pressed && !first.previousPressed) {
                    active = first.id
                    onInput(pointer.down(first.position.x, first.position.y, first.uptimeMillis, transform()))
                } else {
                    val change = event.changes.firstOrNull { it.id == active } ?: continue
                    onInput(pointer.tick(change.uptimeMillis))
                    if (change.position != change.previousPosition) {
                        onInput(pointer.move(change.position.x, change.position.y, transform()))
                    }
                    if (!change.pressed && change.previousPressed) {
                        onInput(pointer.up(change.uptimeMillis))
                        active = null
                    }
                }
                event.changes.forEach { it.consume() }
            }
        }
    } finally {
        onInput(pointer.cancel())
        onReleaseAll()
    }
}
