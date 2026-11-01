// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench

import com.floe.android.feature.canvas.CanvasHostApi
import com.floe.android.feature.canvas.CreativeBinding
import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeServiceStatus
import com.floe.android.feature.canvas.CreativeStorageLayer

/**
 * G09-R1 media workbench consumer API.
 *
 * The media project store is deliberately separate from Canvas: projects are
 * plain schema-1 JSON documents with persisted undo/redo and project-relative
 * asset references. The host re-derives the media root from the accepted root
 * and an explicit [CreativeStorageLayer] on every open; a recorded
 * `taskWorkspacePath`/`environmentID` is never treated as permission.
 *
 * All mutation methods carry an editor [sessionToken] plus exact expected
 * revision and a durable operation ID. A stale session/epoch never retargets
 * a replacement editor; a retried committed operation returns the recorded
 * receipt instead of applying twice.
 */
interface WorkbenchHostApi {
    suspend fun bind(epoch: Long): CreativeBinding

    suspend fun status(): CreativeServiceStatus

    suspend fun mediaLibrary(): List<MediaProjectSummary>

    suspend fun open(
        projectID: String,
        sessionToken: String,
        storage: CreativeStorageLayer? = null,
        origin: CreativeOriginContext? = null,
    ): MediaProjectEnvelope

    suspend fun create(
        name: String,
        kind: String,
        width: Int,
        height: Int,
        frameRate: Double?,
        storage: CreativeStorageLayer,
        origin: CreativeOriginContext,
        sessionToken: String,
    ): MediaProjectEnvelope

    suspend fun apply(
        projectID: String,
        expectedRevision: Long,
        sessionToken: String,
        storage: CreativeStorageLayer?,
        origin: CreativeOriginContext? = null,
        opID: String,
        commands: List<MediaEditCommand>,
    ): MediaProjectReceipt

    suspend fun undo(
        projectID: String,
        expectedRevision: Long,
        sessionToken: String,
        storage: CreativeStorageLayer?,
        origin: CreativeOriginContext? = null,
        opID: String,
    ): MediaProjectReceipt

    suspend fun redo(
        projectID: String,
        expectedRevision: Long,
        sessionToken: String,
        storage: CreativeStorageLayer?,
        origin: CreativeOriginContext? = null,
        opID: String,
    ): MediaProjectReceipt

    suspend fun rename(
        projectID: String,
        expectedRevision: Long,
        name: String,
        sessionToken: String,
        storage: CreativeStorageLayer?,
        origin: CreativeOriginContext? = null,
        opID: String? = null,
    ): MediaMutationReceipt

    suspend fun delete(
        projectID: String,
        expectedRevision: Long,
        sessionToken: String,
        storage: CreativeStorageLayer?,
        origin: CreativeOriginContext? = null,
        opID: String? = null,
    )

    suspend fun importAsset(
        token: String,
        opID: String,
        projectID: String,
        expectedRevision: Long,
        sessionToken: String,
        storage: CreativeStorageLayer?,
        origin: CreativeOriginContext? = null,
        fileName: String,
        mimeType: String?,
        byteCount: Long,
        sha256: String,
    ): MediaAssetReceipt

    suspend fun relink(
        projectID: String,
        expectedRevision: Long,
        sessionToken: String,
        storage: CreativeStorageLayer?,
        origin: CreativeOriginContext? = null,
        assetID: String,
        relativePath: String,
        opID: String? = null,
    ): MediaProjectReceipt

    /**
     * Token-scoped editor close. A stale close never retires a replacement
     * editor; global runtime shutdown is lifecycle-internal only.
     */
    suspend fun closeWorkbenchEditor(projectID: String, sessionToken: String): Boolean
}

/** The two independently-owned editors share only this host contract seam. */
interface CreativeHostApi : CanvasHostApi, WorkbenchHostApi
