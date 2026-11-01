// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui

import com.floe.android.feature.workbench.ImageFreehandPoint
import com.floe.android.feature.workbench.ImageFreehandStroke
import com.floe.android.feature.workbench.ImageLayer
import com.floe.android.feature.workbench.ImageLayerTransform
import com.floe.android.feature.workbench.MediaAssetReference
import com.floe.android.feature.workbench.MediaEditCommand
import com.floe.android.feature.workbench.NormalizedRect
import com.floe.android.feature.workbench.OptionalUpdate
import com.floe.android.feature.workbench.ui.presentation.MediaCommandPlanner
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaCommandPlannerTest {
    private val asset = MediaAssetReference(
        id = "asset-1",
        kind = "image",
        relativePath = "Workbench/Assets/image.png",
        originalName = "image.png",
    )

    @Test
    fun imageLayerKeepsExplicitIdentityAndAsset() {
        val command = MediaCommandPlanner.addImageLayer(
            asset, name = "Layer", id = "layer-1")
        val layer = (command as MediaEditCommand.AddImageLayer).layer
        assertEquals("layer-1", layer.id)
        assertEquals("asset-1", layer.assetID)
        assertEquals("Layer", layer.name)
        assertEquals("image", layer.kind)
    }

    @Test
    fun textLayerCarriesTextStyle() {
        val command = MediaCommandPlanner.addTextLayer(
            "Hello", fontSize = 72.0, colorHex = "#FF3B30", id = "text-1")
        val layer = (command as MediaEditCommand.AddImageLayer).layer
        assertEquals("text-1", layer.id)
        assertEquals("Hello", layer.text?.text)
        assertEquals(72.0, layer.text?.fontSize ?: 0.0, 0.0001)
        assertEquals("#FF3B30", layer.text?.colorHex)
    }

    @Test
    fun freehandLayerCarriesStroke() {
        val stroke = ImageFreehandStroke(
            points = listOf(ImageFreehandPoint(0.1, 0.1), ImageFreehandPoint(0.9, 0.9)),
            width = 12.0,
            colorHex = "#0081F6",
        )
        val command = MediaCommandPlanner.addFreehandLayer(stroke, id = "draw-1", name = "Drawing")
        val layer = (command as MediaEditCommand.AddImageLayer).layer
        assertEquals("draw-1", layer.id)
        assertEquals("freehand", layer.kind)
        assertEquals(1, layer.freehand?.strokes?.size)
    }

    @Test
    fun transformClampsToNativeValidationRanges() {
        val layer = ImageLayer(id = "layer", kind = "image", name = "Image")
        val command = MediaCommandPlanner.updateTransform(
            layer,
            centerX = 5.0,
            centerY = -1.0,
            scale = 100.0,
            rotationDegrees = 30.0,
        )
        val transform = requireNotNull(command.transform)
        assertEquals(2.0, transform.centerX, 0.0001)
        assertEquals(0.0, transform.centerY, 0.0001)
        assertEquals(20.0, transform.scale, 0.0001)
    }

    @Test
    fun cropDistinguishesClearFromSet() {
        val layer = ImageLayer(id = "layer", kind = "image", name = "Image")
        val set = MediaCommandPlanner.setCrop(
            layer, NormalizedRect(0.1, 0.1, 0.8, 0.8))
        assertTrue(set.crop is OptionalUpdate.Set)
        val clear = MediaCommandPlanner.setCrop(layer, null)
        assertTrue(clear.crop is OptionalUpdate.Clear)
    }

    @Test
    fun flipAndMoveUseLayerIdentity() {
        val layer = ImageLayer(
            id = "layer",
            kind = "image",
            name = "Image",
            transform = ImageLayerTransform(),
        )
        assertEquals("layer", MediaCommandPlanner.flip(layer, true).id)
        assertEquals(2, MediaCommandPlanner.move(layer, 2).toIndex)
    }
}
