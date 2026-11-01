// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.creative

import android.net.Uri
import com.floe.android.feature.canvas.CanvasAssetReceipt
import com.floe.android.feature.canvas.CanvasAssetReferenceOperation
import com.floe.android.feature.canvas.CanvasHostApi
import com.floe.android.feature.canvas.CanvasMutationReceipt
import com.floe.android.feature.canvas.CanvasOperationResult
import com.floe.android.feature.canvas.CanvasPatchRequest
import com.floe.android.feature.canvas.CanvasProjectEnvelope
import com.floe.android.feature.canvas.CanvasProjectSummary
import com.floe.android.feature.canvas.CanvasRecoveryState
import com.floe.android.feature.canvas.CreativeBinding
import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeServiceStatus
import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.workbench.CreativeHostApi
import com.floe.android.feature.workbench.MediaAssetReceipt
import com.floe.android.feature.workbench.MediaEditCommand
import com.floe.android.feature.workbench.MediaMutationReceipt
import com.floe.android.feature.workbench.MediaProjectEnvelope
import com.floe.android.feature.workbench.MediaProjectReceipt
import com.floe.android.feature.workbench.MediaProjectSummary
import java.util.UUID
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers

/**
 * The single Application-owned creative service. It composes the typed
 * project controller and the bounded SAF staging controller; it owns no
 * project bytes, no fallback store and no task/environment identity.
 *
 * UI conveniences ([importCanvasAsset], [importMediaAsset]) still use the
 * same opaque staging tokens; they never pass a caller path across the wire.
 */
class CreativeHostService(
    context: android.content.Context,
    acceptedRootProvider: () -> CreativeAcceptedRoot?,
    epochProvider: () -> Long?,
    transport: CreativeTransport = SwiftCreativeTransport,
    ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) : CreativeHostApi {
    private val project = CreativeProjectController(
        transport = transport, epochProvider = epochProvider,
        ioDispatcher = ioDispatcher)
    private val imports = CreativeAssetImportController(
        context = context,
        acceptedRootProvider = acceptedRootProvider,
        liveEpochProvider = epochProvider,
        pump = CreativeSourcePump(ioDispatcher))
    private val sourceCreate = CreativeSourceCreateController<Uri>(
        stage = { uri, token -> imports.stage(uri, token) },
        inspect = { file -> CreativeSourceInspector.inspect(file) },
        discard = { token -> imports.discard(token) },
        canvasCommit = { request -> project.createCanvasFromStaged(request) },
        mediaCommit = { request -> project.createMediaFromStaged(request) },
        ioDispatcher = ioDispatcher)

    override suspend fun bind(epoch: Long): CreativeBinding = project.bind(epoch)

    override suspend fun status(): CreativeServiceStatus = project.status()

    override suspend fun canvasLibrary(): List<CanvasProjectSummary> = project.canvasLibrary()

    override suspend fun open(canvasID: String, sessionToken: String): CanvasProjectEnvelope =
        project.open(canvasID, sessionToken)

    override suspend fun create(
        name: String,
        workspaceID: String?,
        sessionToken: String,
    ): CanvasProjectEnvelope = project.create(name, workspaceID, sessionToken)

    override suspend fun patch(request: CanvasPatchRequest): CanvasOperationResult =
        project.patch(request)

    override suspend fun rename(
        canvasID: String,
        expectedRevision: Long,
        name: String,
        sessionToken: String,
        opID: String?,
    ): CanvasMutationReceipt = project.rename(
        canvasID, expectedRevision, name, sessionToken, opID)

    override suspend fun delete(
        canvasID: String,
        expectedRevision: Long,
        sessionToken: String,
        opID: String?,
    ) = project.delete(canvasID, expectedRevision, sessionToken, opID)

    override suspend fun importAsset(
        token: String,
        opID: String,
        fileName: String,
        mimeType: String?,
        byteCount: Long,
        sha256: String,
        sessionToken: String,
    ): CanvasAssetReceipt = project.importAsset(
        token, opID, fileName, mimeType, byteCount, sha256, sessionToken)

    override suspend fun discardAsset(token: String) {
        imports.discard(token)
        runCatching { project.discardAsset(token) }
    }

    override suspend fun referenceOp(
        canvasID: String,
        sessionToken: String,
        operations: List<CanvasAssetReferenceOperation>,
    ): CanvasRecoveryState = project.referenceOp(canvasID, sessionToken, operations)

    override suspend fun recover(canvasID: String): CanvasRecoveryState =
        project.recover(canvasID)

    override suspend fun mediaLibrary(): List<MediaProjectSummary> = project.mediaLibrary()

    override suspend fun open(
        projectID: String,
        sessionToken: String,
        storage: CreativeStorageLayer?,
        origin: CreativeOriginContext?,
    ): MediaProjectEnvelope = project.open(projectID, sessionToken, storage, origin)

    override suspend fun create(
        name: String,
        kind: String,
        width: Int,
        height: Int,
        frameRate: Double?,
        storage: CreativeStorageLayer,
        origin: CreativeOriginContext,
        sessionToken: String,
    ): MediaProjectEnvelope = project.create(
        name, kind, width, height, frameRate, storage, origin, sessionToken)

    override suspend fun apply(
        projectID: String,
        expectedRevision: Long,
        sessionToken: String,
        storage: CreativeStorageLayer?,
        origin: CreativeOriginContext?,
        opID: String,
        commands: List<MediaEditCommand>,
    ): MediaProjectReceipt = project.apply(
        projectID, expectedRevision, sessionToken, storage, origin, opID, commands)

    override suspend fun undo(
        projectID: String,
        expectedRevision: Long,
        sessionToken: String,
        storage: CreativeStorageLayer?,
        origin: CreativeOriginContext?,
        opID: String,
    ): MediaProjectReceipt = project.undo(
        projectID, expectedRevision, sessionToken, storage, origin, opID)

    override suspend fun redo(
        projectID: String,
        expectedRevision: Long,
        sessionToken: String,
        storage: CreativeStorageLayer?,
        origin: CreativeOriginContext?,
        opID: String,
    ): MediaProjectReceipt = project.redo(
        projectID, expectedRevision, sessionToken, storage, origin, opID)

    override suspend fun rename(
        projectID: String,
        expectedRevision: Long,
        name: String,
        sessionToken: String,
        storage: CreativeStorageLayer?,
        origin: CreativeOriginContext?,
        opID: String?,
    ): MediaMutationReceipt = project.rename(
        projectID, expectedRevision, name, sessionToken, storage, origin, opID)

    override suspend fun delete(
        projectID: String,
        expectedRevision: Long,
        sessionToken: String,
        storage: CreativeStorageLayer?,
        origin: CreativeOriginContext?,
        opID: String?,
    ) = project.delete(projectID, expectedRevision, sessionToken, storage, origin, opID)

    override suspend fun importAsset(
        token: String,
        opID: String,
        projectID: String,
        expectedRevision: Long,
        sessionToken: String,
        storage: CreativeStorageLayer?,
        origin: CreativeOriginContext?,
        fileName: String,
        mimeType: String?,
        byteCount: Long,
        sha256: String,
    ): MediaAssetReceipt = project.importAsset(
        token, opID, projectID, expectedRevision, sessionToken, storage,
        origin, fileName, mimeType, byteCount, sha256)

    override suspend fun relink(
        projectID: String,
        expectedRevision: Long,
        sessionToken: String,
        storage: CreativeStorageLayer?,
        origin: CreativeOriginContext?,
        assetID: String,
        relativePath: String,
        opID: String?,
    ): MediaProjectReceipt = project.relink(
        projectID, expectedRevision, sessionToken, storage, origin,
        assetID, relativePath, opID)

    /**
     * Lifecycle-internal global shutdown; not exposed by CreativeHostApi.
     * Token-scoped editor closes are the only public session-retirement API.
     */
    internal suspend fun shutdown() {
        imports.discardAll()
        project.shutdownBinding()
    }

    override suspend fun closeCanvasEditor(canvasID: String,
                                           sessionToken: String): Boolean =
        project.closeCanvasEditor(canvasID, sessionToken)

    override suspend fun closeWorkbenchEditor(projectID: String,
                                              sessionToken: String): Boolean =
        project.closeWorkbenchEditor(projectID, sessionToken)

    suspend fun closeCanvasEditorForUi(canvasID: String,
                                       sessionToken: String): Boolean =
        closeCanvasEditor(canvasID, sessionToken)

    suspend fun closeWorkbenchEditorForUi(projectID: String,
                                          sessionToken: String): Boolean =
        closeWorkbenchEditor(projectID, sessionToken)

    // MARK: - UI-facing SAF conveniences (still token-based)

    /**
     * Atomic "new Canvas from this file": stage once, measure the actual
     * bytes, then let native ingest the asset and publish one non-empty
     * project. A failed/cancelled import leaves no empty canvas; the caller's
     * stable [opID] makes a retry idempotent.
     */
    suspend fun createCanvasFromUri(
        uri: Uri,
        name: String,
        workspaceID: String?,
        sessionToken: String,
        opID: String,
    ): CanvasProjectEnvelope = sourceCreate.createCanvas(
        uri, name, workspaceID, sessionToken, opID)

    /**
     * Atomic "new media project from this file" for the direct UI route.
     * [origin] is real provenance when the file came from an existing
     * workspace/canvas/chat/files surface; nil means the honest standalone
     * direct-UI case (no AI task/run is invented). [storage] stays explicit.
     */
    suspend fun createMediaFromUri(
        uri: Uri,
        name: String,
        kind: String,
        storage: CreativeStorageLayer,
        origin: CreativeOriginContext?,
        sessionToken: String,
        opID: String,
    ): MediaProjectEnvelope = sourceCreate.createMedia(
        uri, name, kind, storage, origin, sessionToken, opID)

    suspend fun importCanvasAsset(
        source: Uri,
        fileName: String,
        mimeType: String?,
        sessionToken: String,
        opID: String = UUID.randomUUID().toString(),
    ): CanvasAssetReceipt {
        val staged = imports.stage(source, fileName, mimeType, sessionToken)
        return try {
            project.importAsset(
                token = staged.token, opID = opID, fileName = staged.fileName,
                mimeType = staged.mimeType, byteCount = staged.byteCount,
                sha256 = staged.sha256, sessionToken = sessionToken)
        } finally {
            imports.discard(staged.token)
        }
    }

    suspend fun importMediaAsset(
        source: Uri,
        fileName: String,
        mimeType: String?,
        projectID: String,
        expectedRevision: Long,
        storage: CreativeStorageLayer?,
        origin: CreativeOriginContext?,
        sessionToken: String,
        opID: String = UUID.randomUUID().toString(),
    ): MediaAssetReceipt {
        val staged = imports.stage(source, fileName, mimeType, sessionToken)
        return try {
            project.importAsset(
                token = staged.token, opID = opID, projectID = projectID,
                expectedRevision = expectedRevision, sessionToken = sessionToken,
                storage = storage, origin = origin, fileName = staged.fileName,
                mimeType = staged.mimeType, byteCount = staged.byteCount,
                sha256 = staged.sha256)
        } finally {
            imports.discard(staged.token)
        }
    }
}

/**
 * Application wiring point. It performs no native/disk work at construction;
 * the Application binds it after the accepted runtime epoch exists.
 */
class CreativeHostController(
    context: android.content.Context,
    private val epochProvider: () -> Long?,
    acceptedRootProvider: () -> CreativeAcceptedRoot?,
    transport: CreativeTransport = SwiftCreativeTransport,
) {
    private val adapter = CreativeHostService(
        context = context,
        acceptedRootProvider = acceptedRootProvider,
        epochProvider = epochProvider,
        transport = transport)

    val services: CreativeHostApi get() = adapter

    suspend fun bindCurrent(): CreativeBinding {
        val epoch = epochProvider()?.takeIf { it > 0L }
            ?: throw CreativeException(
                "runtimeUnavailable", "acceptedRootNotLive", retryable = true)
        return services.bind(epoch)
    }

    suspend fun stop() = adapter.shutdown()

    /** Atomic new Canvas/media project from a user-selected file. */
    suspend fun createCanvasFromUri(
        uri: Uri,
        name: String,
        workspaceID: String?,
        sessionToken: String,
        opID: String,
    ): CanvasProjectEnvelope = adapter.createCanvasFromUri(
        uri, name, workspaceID, sessionToken, opID)

    suspend fun createMediaFromUri(
        uri: Uri,
        name: String,
        kind: String,
        storage: CreativeStorageLayer,
        origin: CreativeOriginContext?,
        sessionToken: String,
        opID: String,
    ): MediaProjectEnvelope = adapter.createMediaFromUri(
        uri, name, kind, storage, origin, sessionToken, opID)

    /** SAF → bounded staging → native ingest; the token is discarded after. */
    suspend fun importCanvasAsset(
        source: Uri,
        fileName: String,
        mimeType: String?,
        sessionToken: String,
        opID: String = java.util.UUID.randomUUID().toString(),
    ): CanvasAssetReceipt = adapter.importCanvasAsset(
        source, fileName, mimeType, sessionToken, opID)

    suspend fun importMediaAsset(
        source: Uri,
        fileName: String,
        mimeType: String?,
        projectID: String,
        expectedRevision: Long,
        storage: CreativeStorageLayer?,
        origin: CreativeOriginContext?,
        sessionToken: String,
        opID: String = java.util.UUID.randomUUID().toString(),
    ): MediaAssetReceipt = adapter.importMediaAsset(
        source, fileName, mimeType, projectID, expectedRevision,
        storage, origin, sessionToken, opID)
}
