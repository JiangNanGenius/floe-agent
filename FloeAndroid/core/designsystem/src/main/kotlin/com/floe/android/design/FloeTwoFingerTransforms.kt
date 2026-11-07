// SPDX-License-Identifier: MPL-2.0
package com.floe.android.design

import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroid
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.PointerInputScope

/** Leaves a single pointer to the remote mouse/pen drag handler. Once two
 * fingers take over, release remote buttons and consume the rest of this
 * gesture, including the final remaining finger, so it cannot draw a tail. */
suspend fun PointerInputScope.detectFloeTwoFingerTransforms(
    onTakeover: () -> Unit,
    onTransform: (centroid: Offset, pan: Offset, zoom: Float) -> Unit,
) {
    awaitEachGesture {
        awaitFirstDown(requireUnconsumed = false)
        var transforming = false
        do {
            // See the second finger before the single-pointer recognizers
            // consume movement. Consuming here cancels their pressed drag.
            val event = awaitPointerEvent(PointerEventPass.Initial)
            val pressed = event.changes.count { it.pressed }
            if (pressed >= 2) {
                if (!transforming) {
                    transforming = true
                    onTakeover()
                }
                if (event.changes.count { it.pressed && it.previousPressed } >= 2) {
                    onTransform(event.calculateCentroid(useCurrent = false),
                        event.calculatePan(), event.calculateZoom())
                }
            }
            if (transforming) event.changes.forEach { it.consume() }
        } while (event.changes.any { it.pressed })
    }
}
