// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench

import kotlinx.serialization.json.JsonObject

/**
 * Explicit three-way nullable update. `Unchanged` and `Clear` are different
 * user intents and must never collapse into a missing/null JSON value.
 */
sealed interface OptionalUpdate<out T> {
    data object Unchanged : OptionalUpdate<Nothing>
    data object Clear : OptionalUpdate<Nothing>
    data class Set<T>(val value: T) : OptionalUpdate<T>
}

/**
 * Closed R1 media edit vocabulary.
 *
 * R1 supports image-project structural edits and ordinary undo/redo. The
 * C03 image closure adds the fixed-iOS layer operations that are still backed
 * by the same validated transaction engine: selection fill (a real `.fill`
 * layer), non-destructive selection cut (one region mask stroke), and
 * renderer-produced copy/merge rasters committed through `addAsset`. A caller
 * never supplies a raster path or hash authority; the C03 raster port and the
 * native command validator own those checks.
 */
sealed interface MediaEditCommand {
    data class AddAsset(val asset: MediaAssetReference) : MediaEditCommand

    data class RelinkAsset(val assetID: String, val relativePath: String) : MediaEditCommand

    data class SetCanvas(
        val width: Int,
        val height: Int,
        val frameRate: Double? = null,
    ) : MediaEditCommand

    data class AddImageLayer(val layer: ImageLayer) : MediaEditCommand

    data class UpdateLayer(
        val id: String,
        val transform: ImageLayerTransform? = null,
        val opacity: Double? = null,
        val isHidden: Boolean? = null,
        val isLocked: Boolean? = null,
        val adjustment: ImageLayerAdjustment? = null,
        val text: ImageTextContent? = null,
        val crop: OptionalUpdate<NormalizedRect> = OptionalUpdate.Unchanged,
    ) : MediaEditCommand

    data class ReorderLayers(val orderedIDs: List<String>) : MediaEditCommand

    data class MoveLayer(val id: String, val toIndex: Int) : MediaEditCommand

    data class RemoveLayer(val id: String) : MediaEditCommand

    data class DuplicateLayer(val id: String, val name: String? = null) : MediaEditCommand

    data class AddFreehandStroke(
        val id: String,
        val stroke: ImageFreehandStroke,
    ) : MediaEditCommand

    data class SetCanvasAdjustment(val adjustment: ImageLayerAdjustment) : MediaEditCommand

    data class SetImageSelection(val selection: JsonObject?) : MediaEditCommand

    data class FlipLayer(val id: String, val horizontal: Boolean) : MediaEditCommand

    data class ClearLayerMask(val id: String) : MediaEditCommand

    data class SetLayerSelectionMask(
        val id: String,
        val selection: OptionalUpdate<JsonObject>,
    ) : MediaEditCommand

    /** Non-destructive cut: appends one region mask stroke for the selection. */
    data class CutSelection(val layerID: String) : MediaEditCommand

    /** Raster merge of two or more contiguous layers (renderer-staged asset). */
    data class MergeLayers(
        val ids: List<String>,
        val name: String? = null,
        val raster: MergedLayerRaster,
    ) : MediaEditCommand

    /** Copy the selection ∩ source layer into a new full-canvas image layer. */
    data class CopySelection(
        val sourceLayerID: String,
        val name: String? = null,
        val raster: MergedLayerRaster,
    ) : MediaEditCommand
}

/**
 * Renderer-produced full-canvas transparent raster. `assetID` must name the
 * exact asset registered by the host; `contentHash` is checked by the native
 * command path and never treated as caller write authority.
 */
data class MergedLayerRaster(
    val assetID: String,
    val width: Int,
    val height: Int,
    val contentHash: String? = null,
)
