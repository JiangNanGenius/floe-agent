// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.canvas

/**
 * G09-R1 Canvas consumer API.
 *
 * Authority and lifetime:
 * * Canvas files live under the accepted runtime root
 *   (`FloeAgent/Canvases/<uuid>.json`) and are owned by the native side.
 *   There is no Kotlin file store, no first-project/temp fallback and no
 *   fabricated AI task/environment.
 * * The accepted storage root is only reachable through the Application's
 *   runtime generation; a direct Canvas open does not require Linux,
 *   rootfs, an AI chat or a run.
 * * [open] registers a unique editor session token. Every mutation must
 *   present the SAME token, project ID and revision. A stale/late callback
 *   fails with [CreativeException] code `staleSession`/`staleGeneration`
 *   and never retargets a replacement editor.
 * * Asset bytes never cross this API as base64. [importAsset] consumes an
 *   opaque staging token created by the App host from SAF input.
 *
 * Cancellation:
 * * Methods are `suspend`; cancellation before the native dispatch means no
 *   edit. A dispatched mutation that committed has a durable native receipt,
 *   and retrying the same [opID] returns the known outcome (idempotent).
 */
interface CanvasHostApi {
    /** Bind to the current accepted runtime epoch; no store opens here. */
    suspend fun bind(epoch: Long): CreativeBinding

    suspend fun status(): CreativeServiceStatus

    suspend fun canvasLibrary(): List<CanvasProjectSummary>

    /** Opens a project and registers [sessionToken] for subsequent writes. */
    suspend fun open(canvasID: String, sessionToken: String): CanvasProjectEnvelope

    suspend fun create(
        name: String,
        workspaceID: String? = null,
        sessionToken: String,
    ): CanvasProjectEnvelope

    suspend fun patch(request: CanvasPatchRequest): CanvasOperationResult

    suspend fun rename(
        canvasID: String,
        expectedRevision: Long,
        name: String,
        sessionToken: String,
        opID: String? = null,
    ): CanvasMutationReceipt

    suspend fun delete(
        canvasID: String,
        expectedRevision: Long,
        sessionToken: String,
        opID: String? = null,
    )

    suspend fun importAsset(
        token: String,
        opID: String,
        fileName: String,
        mimeType: String?,
        byteCount: Long,
        sha256: String,
        sessionToken: String,
    ): CanvasAssetReceipt

    suspend fun discardAsset(token: String)

    suspend fun referenceOp(
        canvasID: String,
        sessionToken: String,
        operations: List<CanvasAssetReferenceOperation>,
    ): CanvasRecoveryState

    /** Reconciles the durable reference journal; never guesses reference counts. */
    suspend fun recover(canvasID: String): CanvasRecoveryState

    /**
     * Token-scoped editor close. Closing an old editor after a replacement
     * opened the same canvas returns false and leaves the replacement
     * writable. Global runtime shutdown stays lifecycle-internal.
     */
    suspend fun closeCanvasEditor(canvasID: String, sessionToken: String): Boolean
}
