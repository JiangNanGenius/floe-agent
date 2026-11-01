// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui.api

import android.net.Uri
import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.workbench.CreativeProjectContext
import com.floe.android.feature.workbench.MediaAssetReceipt
import com.floe.android.feature.workbench.MediaExportReceipt
import com.floe.android.feature.workbench.MediaProjectEnvelope
import kotlinx.serialization.json.JsonObject

/** One user-selected media source, resolved by the App host after the picker. */
data class MediaPickedSource(
    val uri: Uri,
    val displayName: String,
    val mimeType: String? = null,
    val byteCount: Long? = null,
)

/**
 * Atomic "new media project from this source" host callback.
 *
 * The App facade verifies the bytes/metadata and publishes exactly one
 * non-empty project only after the source was accepted. This module never
 * creates an empty project first and cleans up on failure.
 */
fun interface MediaSourceCreate {
    suspend fun createMediaFromSource(
        source: MediaPickedSource,
        name: String,
        kind: String,
        storage: CreativeStorageLayer,
        origin: CreativeOriginContext?,
        sessionToken: String,
        opID: String,
    ): MediaProjectEnvelope
}

/**
 * Import one file into an EXISTING media project through the App host's
 * bounded SAF staging + native asset ingest.
 */
fun interface MediaAssetImport {
    suspend fun importMediaAsset(
        source: MediaPickedSource,
        projectID: String,
        expectedRevision: Long,
        storage: CreativeStorageLayer?,
        origin: CreativeOriginContext?,
        sessionToken: String,
        opID: String,
    ): MediaAssetReceipt
}

/** One real project CAS receipt returned by the C03 subtitle write-back. */
data class MediaTranscriptionReceipt(
    val projectID: String,
    val revision: Long,
    val operationID: String,
    val idempotent: Boolean,
)

/**
 * Optional C03 long-file transcription entry. It must resolve the EXACT
 * selected media project/asset and write timed captions through the existing
 * project CAS; a preview blob or filename lookup is not a valid implementation.
 */
fun interface MediaTranscriptionPort {
    suspend fun transcribeAndApply(
        context: CreativeProjectContext,
        assetID: String,
        expectedRevision: Long,
    ): MediaTranscriptionReceipt
}

/**
 * One renderer-produced, verified full-canvas layer raster. It is produced by
 * the platform image renderer from an immutable native snapshot, written under
 * the trusted project root, and committed through `addAsset` + the existing
 * merge/copy command path. It is deliberately not a caller path or asset
 * reference.
 */
data class MediaLayerRasterRequest(
    val layerIDs: List<String>,
    /** Complete project selection JSON for COPY_SELECTION. */
    val selection: JsonObject? = null,
    val name: String? = null,
)

data class MediaLayerRasterReceipt(
    val assetID: String,
    val relativePath: String,
    val originalName: String,
    val byteCount: Long,
    val sha256: String,
    val width: Int,
    val height: Int,
    val projectID: String,
    val projectRevision: Long,
)

/** Required for merge/copy: renders the exact selected layers/selection. */
fun interface MediaLayerRasterPort {
    suspend fun renderLayerRaster(
        context: CreativeProjectContext,
        expectedRevision: Long,
        mode: String,
        request: MediaLayerRasterRequest,
    ): MediaLayerRasterReceipt
}

enum class MediaGalleryCollection {
    IMAGE,
    VIDEO,
}

sealed interface MediaGallerySaveOutcome {
    data class Saved(
        val contentURI: String,
        val displayName: String,
        val byteCount: Long,
        val sha256: String,
        val readbackSha256: String,
    ) : MediaGallerySaveOutcome

    data class PermissionRequired(val permission: String) : MediaGallerySaveOutcome

    data class Failed(
        val code: String,
        val retryable: Boolean = false,
        val pendingCleaned: Boolean = true,
    ) : MediaGallerySaveOutcome
}

/**
 * App-owned Save-to-gallery service for a VERIFIED export receipt. The App
 * re-proves the live project owner/root and performs a real ContentResolver
 * MediaStore write + readback; the feature never passes a raw path.
 */
fun interface MediaGallerySavePort {
    suspend fun saveToGallery(
        context: CreativeProjectContext,
        receipt: MediaExportReceipt,
        collection: MediaGalleryCollection,
    ): MediaGallerySaveOutcome
}

/** Required host callbacks; no default implementation exists on purpose. */
interface MediaEditorPorts {
    val sourceCreate: MediaSourceCreate
    val assetImport: MediaAssetImport
    /** Null means the media editor keeps automatic transcription unavailable. */
    val transcription: MediaTranscriptionPort? get() = null
    /** Null keeps merge/copy honestly unavailable in this editor session. */
    val layerRaster: MediaLayerRasterPort? get() = null
    /** Null keeps direct gallery save honestly unavailable. */
    val gallerySave: MediaGallerySavePort? get() = null
}
