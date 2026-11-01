// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui

import com.floe.android.feature.workbench.ImageLayer
import com.floe.android.feature.workbench.ImageLayerAdjustment
import com.floe.android.feature.workbench.MediaCanvas
import com.floe.android.feature.workbench.NormalizedRect
import com.floe.android.feature.workbench.ui.presentation.MediaColor
import com.floe.android.feature.workbench.ui.presentation.MediaLayerGeometry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class MediaGeometryTest {
    @Test
    fun aspectFitPreservesRatio() {
        val fitted = MediaLayerGeometry.fitInto(2000.0, 1000.0, 1000.0, 1000.0)
        assertEquals(1000.0, fitted.first, 0.0001)
        assertEquals(500.0, fitted.second, 0.0001)
    }

    @Test
    fun cropRectUsesSourcePixels() {
        val rect = MediaLayerGeometry.cropRect(
            NormalizedRect(0.25, 0.0, 0.5, 1.0), 2000, 1000)
        assertEquals(500, rect.left)
        assertEquals(0, rect.top)
        assertEquals(1000, rect.width)
        assertEquals(1000, rect.height)
    }

    @Test
    fun centeredSquareCropFitsWideSource() {
        val crop = MediaLayerGeometry.centeredCrop(1.0, 2000, 1000)
        assertEquals(0.25, crop.x, 0.0001)
        assertEquals(0.0, crop.y, 0.0001)
        assertEquals(0.5, crop.width, 0.0001)
        assertEquals(1.0, crop.height, 0.0001)
    }

    @Test
    fun centeredCropOfTallSourceFitsWideAspect() {
        val crop = MediaLayerGeometry.centeredCrop(16.0 / 9.0, 1000, 2000)
        assertEquals(0.0, crop.x, 0.0001)
        assertEquals((1.0 - (1000.0 / 2000.0) / (16.0 / 9.0)) / 2, crop.y, 0.0001)
        assertEquals(1.0, crop.width, 0.0001)
        assertEquals(9.0 / 32.0, crop.height, 0.0001)
    }

    @Test
    fun placedBoundsAppliesNormalizedCenterAndScale() {
        val layer = ImageLayer(
            id = "layer",
            kind = "text",
            name = "Text",
            transform = com.floe.android.feature.workbench.ImageLayerTransform(
                centerX = 0.25,
                centerY = 0.75,
                scale = 2.0,
                rotationDegrees = 30.0,
            ),
        )
        val bounds = MediaLayerGeometry.placedBounds(
            layer = layer,
            asset = null,
            bitmap = null,
            canvas = MediaCanvas(1000, 500),
        )
        assertEquals(250.0, bounds.centerX, 0.0001)
        assertEquals(375.0, bounds.centerY, 0.0001)
        assertEquals(2000.0, bounds.width, 0.0001)
        assertEquals(1000.0, bounds.height, 0.0001)
        assertEquals(30.0, bounds.rotationDegrees, 0.0001)
    }

    @Test
    fun identityAdjustmentHasNoPreviewFilter() {
        assertNull(MediaColor.previewMatrix(ImageLayerAdjustment()))
        assertNotNull(MediaColor.previewMatrix(ImageLayerAdjustment(brightness = 0.2)))
    }

    @Test
    fun parsesSixAndEightDigitColors() {
        assertEquals(0xFF0081F6.toInt(), MediaColor.parseArgb("#0081F6"))
        assertEquals(0x800081F6.toInt(), MediaColor.parseArgb("#800081F6"))
        assertNull(MediaColor.parseArgb("nope"))
    }
}
