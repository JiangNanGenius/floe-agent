// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui.presentation

import com.floe.android.feature.workbench.ImageFreehandStroke
import com.floe.android.feature.workbench.ImageLayer
import com.floe.android.feature.workbench.ImageLayerAdjustment
import com.floe.android.feature.workbench.ImageLayerTransform
import com.floe.android.feature.workbench.ImageTextContent
import com.floe.android.feature.workbench.MediaAssetReference
import com.floe.android.feature.workbench.MediaEditCommand
import com.floe.android.feature.workbench.NormalizedRect
import com.floe.android.feature.workbench.OptionalUpdate

/**
 * Builders for the frozen `media.project.apply` command vocabulary. Every R1
 * layer edit is one or more of these types; unsupported timeline/export
 * commands are deliberately absent instead of being simulated.
 */
object MediaCommandPlanner {
    fun addImageLayer(
        asset: MediaAssetReference,
        name: String? = null,
        id: String = java.util.UUID.randomUUID().toString(),
    ): MediaEditCommand {
        val layerName = name?.takeIf { it.isNotBlank() } ?: asset.originalName
        return MediaEditCommand.AddImageLayer(
            ImageLayer(
                id = id,
                kind = "image",
                name = layerName,
                assetID = asset.id,
            ),
        )
    }

    fun addTextLayer(
        text: String,
        fontSize: Double = 48.0,
        colorHex: String = "#000000",
        id: String = java.util.UUID.randomUUID().toString(),
    ): MediaEditCommand = MediaEditCommand.AddImageLayer(
        ImageLayer(
            id = id,
            kind = "text",
            name = text.lineSequence().firstOrNull()?.take(40) ?: "Text",
            text = ImageTextContent(
                text = text,
                fontSize = fontSize.coerceIn(8.0, 400.0),
                colorHex = colorHex,
            ),
            fillColorHex = null,
        ),
    )

    fun addFreehandLayer(
        stroke: ImageFreehandStroke,
        id: String = java.util.UUID.randomUUID().toString(),
        name: String = "Drawing",
    ): MediaEditCommand =
        MediaEditCommand.AddImageLayer(
            ImageLayer(
                id = id,
                kind = "freehand",
                name = name,
                freehand = com.floe.android.feature.workbench.ImageFreehandContent(
                    strokes = listOf(stroke)),
            ),
        )

    fun updateTransform(
        layer: ImageLayer,
        centerX: Double = layer.transform.centerX,
        centerY: Double = layer.transform.centerY,
        scale: Double = layer.transform.scale,
        rotationDegrees: Double = layer.transform.rotationDegrees,
        flipX: Boolean? = layer.transform.flipX,
        flipY: Boolean? = layer.transform.flipY,
    ): MediaEditCommand.UpdateLayer = MediaEditCommand.UpdateLayer(
        id = layer.id,
        transform = ImageLayerTransform(
            centerX = centerX.coerceIn(0.0, 2.0),
            centerY = centerY.coerceIn(0.0, 2.0),
            scale = scale.coerceIn(0.02, 20.0),
            rotationDegrees = rotationDegrees,
            flipX = flipX,
            flipY = flipY,
        ),
    )

    fun updateOpacity(layer: ImageLayer, opacity: Double): MediaEditCommand.UpdateLayer =
        MediaEditCommand.UpdateLayer(
            id = layer.id,
            opacity = opacity.coerceIn(0.0, 1.0),
        )

    fun setHidden(layer: ImageLayer, hidden: Boolean): MediaEditCommand.UpdateLayer =
        MediaEditCommand.UpdateLayer(id = layer.id, isHidden = hidden)

    fun setLocked(layer: ImageLayer, locked: Boolean): MediaEditCommand.UpdateLayer =
        MediaEditCommand.UpdateLayer(id = layer.id, isLocked = locked)

    fun updateText(layer: ImageLayer, text: ImageTextContent): MediaEditCommand.UpdateLayer =
        MediaEditCommand.UpdateLayer(id = layer.id, text = text)

    fun setCrop(layer: ImageLayer, crop: NormalizedRect?): MediaEditCommand.UpdateLayer =
        MediaEditCommand.UpdateLayer(
            id = layer.id,
            crop = if (crop == null) OptionalUpdate.Clear else OptionalUpdate.Set(crop),
        )

    fun updateAdjustment(
        layer: ImageLayer,
        adjustment: ImageLayerAdjustment,
    ): MediaEditCommand.UpdateLayer =
        MediaEditCommand.UpdateLayer(id = layer.id, adjustment = adjustment)

    fun flip(layer: ImageLayer, horizontal: Boolean): MediaEditCommand.FlipLayer =
        MediaEditCommand.FlipLayer(id = layer.id, horizontal = horizontal)

    fun move(layer: ImageLayer, toIndex: Int): MediaEditCommand.MoveLayer =
        MediaEditCommand.MoveLayer(id = layer.id, toIndex = toIndex)

    fun remove(layer: ImageLayer): MediaEditCommand.RemoveLayer =
        MediaEditCommand.RemoveLayer(id = layer.id)

    fun duplicate(layer: ImageLayer): MediaEditCommand.DuplicateLayer =
        MediaEditCommand.DuplicateLayer(id = layer.id)

    fun addFreehandStroke(layer: ImageLayer, stroke: ImageFreehandStroke): MediaEditCommand =
        MediaEditCommand.AddFreehandStroke(id = layer.id, stroke = stroke)

    fun setCanvasAdjustment(adjustment: ImageLayerAdjustment): MediaEditCommand =
        MediaEditCommand.SetCanvasAdjustment(adjustment)
}
