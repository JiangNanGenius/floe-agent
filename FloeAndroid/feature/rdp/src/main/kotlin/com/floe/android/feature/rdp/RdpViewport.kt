// SPDX-License-Identifier: MPL-2.0
//
// Pure touch-to-framebuffer mapping for the RDP viewport. It handles fit,
// zoom, pan, letterboxing and orientation/size changes. Kept outside Compose
// so the coordinate math is deterministic and testable.

package com.floe.android.feature.rdp

import kotlin.math.max
import kotlin.math.min

data class RdpTransform(
    val scale: Float,
    val offsetX: Float,
    val offsetY: Float,
    val displayWidth: Float,
    val displayHeight: Float,
    val frameWidth: Int,
    val frameHeight: Int,
)

fun rdpClampPan(
    viewWidth: Float,
    viewHeight: Float,
    frameWidth: Int,
    frameHeight: Int,
    zoom: Float,
    panX: Float,
    panY: Float,
): Pair<Float, Float> {
    if (viewWidth <= 0f || viewHeight <= 0f || frameWidth <= 0 || frameHeight <= 0) {
        return 0f to 0f
    }
    val boundedZoom = zoom.coerceIn(1f, 8f)
    val base = min(viewWidth / frameWidth, viewHeight / frameHeight)
    val displayWidth = frameWidth * base * boundedZoom
    val displayHeight = frameHeight * base * boundedZoom
    val maxX = max(0f, (displayWidth - viewWidth) / 2f)
    val maxY = max(0f, (displayHeight - viewHeight) / 2f)
    return panX.coerceIn(-maxX, maxX) to panY.coerceIn(-maxY, maxY)
}

fun rdpTransform(
    viewWidth: Float,
    viewHeight: Float,
    frameWidth: Int,
    frameHeight: Int,
    zoom: Float,
    panX: Float,
    panY: Float,
): RdpTransform {
    if (viewWidth <= 0f || viewHeight <= 0f || frameWidth <= 0 || frameHeight <= 0) {
        return RdpTransform(1f, 0f, 0f, 0f, 0f, frameWidth, frameHeight)
    }
    val boundedZoom = zoom.coerceIn(1f, 8f)
    val base = min(viewWidth / frameWidth, viewHeight / frameHeight)
    val scale = base * boundedZoom
    val displayWidth = frameWidth * scale
    val displayHeight = frameHeight * scale
    val (clampedX, clampedY) = rdpClampPan(
        viewWidth, viewHeight, frameWidth, frameHeight, boundedZoom, panX, panY,
    )
    return RdpTransform(
        scale = scale,
        offsetX = (viewWidth - displayWidth) / 2f + clampedX,
        offsetY = (viewHeight - displayHeight) / 2f + clampedY,
        displayWidth = displayWidth,
        displayHeight = displayHeight,
        frameWidth = frameWidth,
        frameHeight = frameHeight,
    )
}

/** Returns the framebuffer pixel for a view point, or null in letterboxing
 * / outside the fitted image. Values are clamped to the last pixel. */
fun rdpMapPoint(transform: RdpTransform, viewX: Float, viewY: Float): Pair<Int, Int>? {
    if (transform.frameWidth <= 0 || transform.frameHeight <= 0 || transform.scale <= 0f) return null
    val localX = viewX - transform.offsetX
    val localY = viewY - transform.offsetY
    if (localX < 0f || localY < 0f) return null
    if (localX > transform.displayWidth || localY > transform.displayHeight) return null
    val x = (localX / transform.scale).toInt().coerceIn(0, transform.frameWidth - 1)
    val y = (localY / transform.scale).toInt().coerceIn(0, transform.frameHeight - 1)
    return x to y
}

fun rdpClampZoom(zoom: Float, delta: Float): Float = (zoom * delta).coerceIn(1f, 8f)
