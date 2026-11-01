// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui.api

import android.net.Uri
import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.workbench.CreativeProjectContext
import com.floe.android.feature.workbench.MediaAssetReceipt
import com.floe.android.feature.workbench.MediaProjectEnvelope

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

/** Required host callbacks; no default implementation exists on purpose. */
interface MediaEditorPorts {
    val sourceCreate: MediaSourceCreate
    val assetImport: MediaAssetImport
    /** Null means the media editor keeps automatic transcription unavailable. */
    val transcription: MediaTranscriptionPort? get() = null
}
