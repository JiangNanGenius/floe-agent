// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.canvas.ui

import com.floe.android.feature.canvas.CanvasPoint
import com.floe.android.feature.canvas.CanvasSize
import com.floe.android.feature.canvas.ui.presentation.CanvasGeometry
import com.floe.android.feature.canvas.ui.presentation.CanvasView
import com.floe.android.feature.canvas.ui.presentation.CanvasViewportPolicy
import com.floe.android.feature.canvas.ui.presentation.NodeGeometry
import com.floe.android.feature.canvas.ui.presentation.ResizeCorner
import com.floe.android.feature.canvas.ui.presentation.WorldBounds
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CanvasGeometryTest {
    @Test
    fun zoomKeepsAnchorWorldPointStable() {
        val view = CanvasView(panX = 10f, panY = 20f, zoom = 1f)
        val anchor = 100f to 80f
        val before = view.screenToWorld(anchor.first, anchor.second, 2f)
        val zoomed = CanvasViewportPolicy.zoomAround(view, anchor.first, anchor.second, 2f)
        val after = zoomed.screenToWorld(anchor.first, anchor.second, 2f)
        assertEquals(before.x, after.x, 0.0001)
        assertEquals(before.y, after.y, 0.0001)
        assertEquals(2f, zoomed.zoom, 0.0001f)
    }

    @Test
    fun zoomIsClamped() {
        assertEquals(CanvasViewportPolicy.MIN_ZOOM,
            CanvasViewportPolicy.zoomAround(CanvasView(zoom = 0.2f), 0f, 0f, 0.01f).zoom,
            0.0001f)
        assertEquals(CanvasViewportPolicy.MAX_ZOOM,
            CanvasViewportPolicy.zoomAround(CanvasView(zoom = 1f), 0f, 0f, 100f).zoom,
            0.0001f)
    }

    @Test
    fun resizeFromBottomRightKeepsTopLeftFixed() {
        val origin = NodeGeometry(CanvasPoint(100.0, 100.0), CanvasSize(120.0, 80.0))
        val resized = CanvasGeometry.resizeFromCorner(
            origin, ResizeCorner.BOTTOM_RIGHT, 40.0, 20.0)
        // Deltas are the dragged corner's world displacement, so the new width
        // is 120 + 40 = 160 (the sibling TOP_LEFT case confirms the same
        // convention); the height assertion below already applied the full +20.
        assertEquals(160.0, resized.size.width, 0.0001)
        assertEquals(100.0, resized.size.height, 0.0001)
        // Top-left was (40,60) and must stay fixed.
        assertEquals(40.0, resized.position.x - resized.size.width / 2, 0.0001)
        assertEquals(60.0, resized.position.y - resized.size.height / 2, 0.0001)
    }

    @Test
    fun resizeFromTopLeftKeepsBottomRightFixed() {
        val origin = NodeGeometry(CanvasPoint(100.0, 100.0), CanvasSize(120.0, 80.0))
        val resized = CanvasGeometry.resizeFromCorner(
            origin, ResizeCorner.TOP_LEFT, -30.0, -20.0)
        assertEquals(150.0, resized.size.width, 0.0001)
        assertEquals(100.0, resized.size.height, 0.0001)
        assertEquals(160.0, resized.position.x + resized.size.width / 2, 0.0001)
        assertEquals(140.0, resized.position.y + resized.size.height / 2, 0.0001)
    }

    @Test
    fun resizeClampsToMinimumWithoutDriftingAnchor() {
        val origin = NodeGeometry(CanvasPoint(0.0, 0.0), CanvasSize(120.0, 80.0))
        val resized = CanvasGeometry.resizeFromCorner(
            origin, ResizeCorner.BOTTOM_RIGHT, -1000.0, -1000.0)
        assertEquals(CanvasGeometry.MIN_NODE_SIZE, resized.size.width, 0.0001)
        assertEquals(CanvasGeometry.MIN_NODE_SIZE, resized.size.height, 0.0001)
        assertEquals(-60.0, resized.position.x - resized.size.width / 2, 0.0001)
        assertEquals(-40.0, resized.position.y - resized.size.height / 2, 0.0001)
    }

    @Test
    fun rotationWrapsIntoCanonicalRange() {
        assertEquals(-90.0, CanvasGeometry.normalizedRotation(270.0), 0.0001)
        assertEquals(180.0, CanvasGeometry.normalizedRotation(180.0), 0.0001)
        assertEquals(0.0, CanvasGeometry.normalizedRotation(0.0), 0.0001)
    }

    @Test
    fun fitCentersContentAndDoesNotMagnifyPastHundredPercent() {
        val bounds = WorldBounds(0.0, 0.0, 100.0, 100.0)
        val view = CanvasViewportPolicy.fit(
            bounds, surfaceWidthPx = 1000, surfaceHeightPx = 1000, density = 1f)
        assertEquals(1f, view.zoom, 0.0001f)
        val center = CanvasViewportPolicy.surfaceCenterWorld(view, 1000, 1000, 1f)
        assertEquals(50.0, center.x, 0.0001)
        assertEquals(50.0, center.y, 0.0001)
    }

    @Test
    fun screenDeltaConvertsThroughZoomAndDensity() {
        val view = CanvasView(zoom = 2f)
        val (dx, dy) = view.screenDeltaToWorld(40f, 20f, density = 2f)
        assertEquals(10.0, dx, 0.0001)
        assertEquals(5.0, dy, 0.0001)
        assertTrue(dx > 0)
    }
}
