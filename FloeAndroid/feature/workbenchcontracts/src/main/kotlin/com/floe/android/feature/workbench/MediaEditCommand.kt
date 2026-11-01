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
 * R1 supports image-project structural edits and ordinary undo/redo. Timeline
 * trim/split, captions, music, renderer raster merges and selection fill/cut
 * remain R2; unknown host command types are rejected, never silently applied.
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
}
