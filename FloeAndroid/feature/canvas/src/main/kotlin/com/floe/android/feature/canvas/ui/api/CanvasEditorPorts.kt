// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.canvas.ui.api

import android.net.Uri
import com.floe.android.feature.canvas.CanvasAssetReceipt
import com.floe.android.feature.canvas.CanvasProjectEnvelope

/**
 * One user-selected source file, resolved by the App host immediately after
 * the system picker returned. [uri] carries only the temporary read grant the
 * App received; this module never retains or logs it.
 */
data class CanvasPickedSource(
    val uri: Uri,
    val displayName: String,
    val mimeType: String? = null,
    val byteCount: Long? = null,
)

/**
 * Atomic "new Canvas from this source" host callback.
 *
 * The App facade stages/verifies the bytes and publishes exactly one non-empty
 * Canvas project only after the source was ingested; a failed or cancelled
 * import publishes nothing. This module must never approximate it by creating
 * an empty project and cleaning up afterwards.
 */
fun interface CanvasSourceCreate {
    suspend fun createCanvasFromSource(
        source: CanvasPickedSource,
        name: String,
        workspaceID: String?,
        sessionToken: String,
        opID: String,
    ): CanvasProjectEnvelope
}

/**
 * Import one image into an EXISTING Canvas through the App host's bounded SAF
 * staging + native asset ingest. The returned [CanvasAssetReceipt.asset] is
 * the trusted content-addressed reference a node may carry.
 */
fun interface CanvasAssetImport {
    suspend fun importCanvasAsset(
        source: CanvasPickedSource,
        canvasID: String,
        sessionToken: String,
        opID: String,
    ): CanvasAssetReceipt
}

/**
 * Required host callbacks. There is deliberately no default implementation:
 * a missing binding must fail the Canvas library honestly instead of showing
 * a fake local store or a dummy success.
 */
interface CanvasEditorPorts {
    val sourceCreate: CanvasSourceCreate
    val assetImport: CanvasAssetImport
}
