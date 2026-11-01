// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench

import com.floe.android.feature.canvas.CreativeStorageLayer
import kotlinx.serialization.json.JsonObject

/**
 * Media schema-1 project projection.
 *
 * Recorded `ownerKind`/`ownerID`/`environmentID`/`taskWorkspacePath` are
 * PROVENANCE, never storage authority. The host re-resolves an explicit
 * [CreativeStorageLayer] against the accepted composition on every open and
 * refuses a mismatch; a UI never joins a recorded absolute path itself.
 */
data class MediaCanvas(
    val width: Int,
    val height: Int,
    val frameRate: Double? = null,
)

data class MediaAssetMetadata(
    val width: Int? = null,
    val height: Int? = null,
    val durationSeconds: Double? = null,
    val frameRate: Double? = null,
    val audioTracks: Int? = null,
    val rotationDegrees: Double? = null,
    val hasAlpha: Boolean? = null,
)

data class MediaAssetReference(
    val id: String,
    val kind: String,
    val relativePath: String,
    val originalName: String,
    val byteCount: Long? = null,
    val contentHash: String? = null,
    val metadata: MediaAssetMetadata? = null,
)

data class NormalizedRect(
    val x: Double,
    val y: Double,
    val width: Double,
    val height: Double,
) {
    companion object {
        val UNIT = NormalizedRect(0.0, 0.0, 1.0, 1.0)
    }
}

data class ImageLayerTransform(
    val centerX: Double = 0.5,
    val centerY: Double = 0.5,
    val scale: Double = 1.0,
    val rotationDegrees: Double = 0.0,
    val flipX: Boolean? = null,
    val flipY: Boolean? = null,
)

data class ImageTextShadow(
    val colorHex: String,
    val blur: Double,
    val offsetX: Double,
    val offsetY: Double,
)

data class ImageTextContent(
    val text: String,
    val fontSize: Double = 48.0,
    val colorHex: String = "#000000",
    val fontName: String? = null,
    val tracking: Double? = null,
    val leading: Double? = null,
    val alignment: String? = null,
    val strokeColorHex: String? = null,
    val strokeWidth: Double? = null,
    val shadow: ImageTextShadow? = null,
)

data class ImageFreehandPoint(
    val x: Double,
    val y: Double,
    val pressure: Double? = null,
)

data class ImageFreehandStroke(
    val points: List<ImageFreehandPoint>,
    val width: Double = 4.0,
    val colorHex: String = "#000000",
    val hardness: Double? = null,
    val opacity: Double? = null,
)

data class ImageFreehandContent(
    val strokes: List<ImageFreehandStroke> = emptyList(),
)

data class ImageLayerAdjustment(
    val saturation: Double? = null,
    val contrast: Double? = null,
    val brightness: Double? = null,
    val exposureEV: Double? = null,
    val blurRadius: Double? = null,
    val sharpenRadius: Double? = null,
    val temperature: Double? = null,
    val hueDegrees: Double? = null,
    val levels: JsonObject? = null,
    val mosaicBlockSize: Int? = null,
    val filterID: String? = null,
)

data class ImageLayer(
    val id: String,
    val kind: String,
    val name: String,
    val assetID: String? = null,
    val transform: ImageLayerTransform = ImageLayerTransform(),
    val opacity: Double = 1.0,
    val isHidden: Boolean = false,
    val isLocked: Boolean = false,
    val text: ImageTextContent? = null,
    val freehand: ImageFreehandContent? = null,
    val crop: NormalizedRect? = null,
    /** Opaque non-destructive masks/selections preserved byte-for-byte. */
    val mask: JsonObject? = null,
    val selectionMask: JsonObject? = null,
    val fillColorHex: String? = null,
    val adjustment: ImageLayerAdjustment = ImageLayerAdjustment(),
)

data class MediaProject(
    val id: String,
    val schemaVersion: Int = 1,
    val kind: String,
    val name: String,
    val createdAt: String,
    val updatedAt: String,
    val revision: Long,
    val canvas: MediaCanvas? = null,
    val assets: List<MediaAssetReference> = emptyList(),
    val sourceAssetID: String? = null,
    val imageLayers: List<ImageLayer> = emptyList(),
    val canvasAdjustment: ImageLayerAdjustment = ImageLayerAdjustment(),
    /** R2 owns timeline/export playback; R1 preserves the opaque subtree. */
    val videoTimeline: JsonObject? = null,
    val lastImageExport: JsonObject? = null,
    val lastVideoExport: JsonObject? = null,
    val ownerKind: String,
    val ownerID: String? = null,
    val environmentID: String? = null,
    val taskWorkspacePath: String? = null,
    val unknownOperations: List<JsonObject> = emptyList(),
    val recoveryWarnings: List<String> = emptyList(),
    val canUndo: Boolean = false,
    val canRedo: Boolean = false,
    val parentProjectID: String? = null,
    val imageSelection: JsonObject? = null,
)

data class MediaProjectSummary(
    val id: String,
    val name: String,
    val kind: String,
    val revision: Long,
    val updatedAt: String,
    val ownerKind: String,
    val ownerID: String? = null,
    val environmentID: String? = null,
    val assetCount: Int,
    val layerCount: Int,
    val corrupt: Boolean,
    val writable: Boolean,
    val provenanceWarning: Boolean,
)

data class MediaProjectEnvelope(
    val project: MediaProject,
    /** Read-only trusted media root; never accepted as a write path. */
    val mediaRootPath: String,
    val storage: CreativeStorageLayer,
    val writable: Boolean,
    val warnings: List<String> = emptyList(),
)

data class MediaProjectReceipt(
    val projectID: String,
    val revision: Long,
    val canUndo: Boolean,
    val canRedo: Boolean,
    val opID: String,
    val idempotent: Boolean,
)

data class MediaMutationReceipt(
    val projectID: String,
    val name: String?,
    val revision: Long,
    val deleted: Boolean,
    val canUndo: Boolean,
    val canRedo: Boolean,
    val opID: String,
    val idempotent: Boolean,
)

data class MediaAssetReceipt(
    val projectID: String,
    val asset: MediaAssetReference,
    val revision: Long,
    val canUndo: Boolean,
    val canRedo: Boolean,
    val opID: String,
    val idempotent: Boolean,
)

fun MediaProject.asset(id: String): MediaAssetReference? =
    assets.firstOrNull { it.id == id }

fun MediaProject.layer(id: String): ImageLayer? =
    imageLayers.firstOrNull { it.id == id }
