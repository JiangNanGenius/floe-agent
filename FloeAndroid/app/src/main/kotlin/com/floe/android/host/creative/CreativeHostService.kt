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
import com.floe.android.feature.canvas.DesignHostApi
import com.floe.android.feature.workbench.CreativeHostApi
import com.floe.android.feature.workbench.MediaAssetReceipt
import com.floe.android.feature.workbench.MediaEditCommand
import com.floe.android.feature.workbench.MediaMutationReceipt
import com.floe.android.feature.workbench.MediaProjectEnvelope
import com.floe.android.feature.workbench.MediaProjectReceipt
import com.floe.android.feature.workbench.MediaProjectSummary
import com.floe.android.feature.workbench.WorkbenchGenerationHostApi
import com.floe.android.feature.workbench.WorkbenchLargeImportPort
import com.floe.android.feature.workbench.MediaRenderTicketTransport
import com.floe.android.feature.workbench.WorkbenchRenderSnapshotPort
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
    private val epochProvider: () -> Long?,
    designAuthorityIssuer: DesignAuthorityIssuer? = null,
    private val transport: CreativeTransport = SwiftCreativeTransport,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) : CreativeHostApi {
    init {
        // Data-only: no service/channel/permission is touched here. The real
        // bounded dataSync owner starts only for a persisted generation job.
        GenerationForegroundOwner.initializeApplicationContext(context)
    }

    private val project = CreativeProjectController(
        transport = transport, epochProvider = epochProvider,
        ioDispatcher = ioDispatcher)
    private val imports = CreativeAssetImportController(
        context = context,
        acceptedRootProvider = acceptedRootProvider,
        liveEpochProvider = epochProvider,
        pump = CreativeSourcePump(ioDispatcher))
    /**
     * G09-R2 configured-provider image/video generation and candidate
     * adoption. Lazy: no native/disk work is performed at construction.
     * The Main App DI delegates the frozen UI port to this exact accessor.
     */
    val generationHost: WorkbenchGenerationHostApi by lazy {
        CreativeR2GenerationHost(
            transport = transport, epochProvider = epochProvider,
            ioDispatcher = ioDispatcher)
    }

    /**
     * G09-R2 real design workflow over the frozen DesignHostApi. Constructing
     * it performs no native/disk work. The native design service is bound to
     * the same accepted creative epoch/root as Canvas/media.
     */
    private val design = CreativeR2DesignHost(
        context = context,
        acceptedRootProvider = acceptedRootProvider,
        epochProvider = epochProvider,
        designAuthorityIssuer = designAuthorityIssuer,
        transport = transport,
        ioDispatcher = ioDispatcher)
    val designHost: DesignHostApi get() = design
    internal val designStagingHost: CreativeR2DesignHost get() = design

    /**
     * Typed trusted UI callback for RESTRUCTURE preservation confirmation.
     * The App shows the prepared display data and calls confirm only from the
     * explicit user action; the native design service burns the single-use
     * grant immediately before freeze/propose/adopt.
     */
    val designTrustedApprovals: DesignTrustedApprovalController
        get() = design.trustedApprovals

    /** Creative START request in the SAME owner envelope (trusted UI). */
    suspend fun beginCreative(
        binding: com.floe.android.feature.canvas.DesignTargetBinding,
        expectedRevision: Long?,
        opID: String,
        brief: com.floe.android.feature.canvas.DesignBriefModel? = null,
        spec: com.floe.android.feature.canvas.DesignSpecModel? = null,
    ) = design.beginCreative(binding, expectedRevision, opID, brief, spec)

    /** Verified first-result bind over the retained creative asset. */
    suspend fun bindCreativeFirstResult(
        binding: com.floe.android.feature.canvas.DesignTargetBinding,
        expectedRevision: Long,
        opID: String,
        boundResultID: String,
        payload: com.floe.android.feature.canvas.StagedDesignPayload,
        displayName: String? = null,
    ) = design.bindCreativeFirstResult(
        binding, expectedRevision, opID, boundResultID, payload, displayName)

    /**
     * Bounded retained-asset metadata for the first-material picker. No bytes
     * or paths cross the bridge; a selected asset id is bound directly below.
     */
    suspend fun creativeAssets(
        cursor: String? = null,
        limit: Int = 24,
    ): CreativeDesignAssetPage = design.creativeAssets(cursor, limit)

    /** Bounded pending-request reopen list from the same owner-envelope store. */
    suspend fun creativePendingRequests(
        cursor: String? = null,
        limit: Int = 24,
    ): CreativeDesignPendingPage = design.creativePendingRequests(cursor, limit)

    /**
     * Bind an EXISTING retained creative asset as the first result. Native
     * reads/verifies the asset bytes; the caller supplies only its real id.
     */
    suspend fun bindCreativeRetainedFirstResult(
        binding: com.floe.android.feature.canvas.DesignTargetBinding,
        expectedRevision: Long,
        opID: String,
        boundResultID: String,
        displayName: String? = null,
    ): com.floe.android.feature.canvas.DesignStateProjection =
        design.bindCreativeRetainedFirstResult(
            binding, expectedRevision, opID, boundResultID, displayName)

    /**
     * Stage-once SAF/manual import into the EXISTING creative asset library,
     * then the same verified first-result bind. The staged token is released
     * only after a committed bind.
     */
    suspend fun importCreativeFirstResult(
        binding: com.floe.android.feature.canvas.DesignTargetBinding,
        expectedRevision: Long,
        opID: String,
        payload: com.floe.android.feature.canvas.StagedDesignPayload,
        displayName: String? = null,
    ): CreativeDesignImportReceipt = design.importCreativeFirstResult(
        binding, expectedRevision, opID, payload, displayName)

    /** Bounded, Root-owned design proposal staging. */
    suspend fun stageDesignPayload(
        source: Uri,
        sessionToken: String,
    ) = design.stagePayload(source, sessionToken)

    fun discardDesignPayload(token: String) = design.discardPayload(token)

    /** Root stop: fence/cancel/close/join REAL design staging copies. */
    suspend fun fenceDesignStaging(): Boolean = design.fenceStaging()

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
     * Additive R1 commit bridges used only by the Main constructor patch. They
     * keep the private `project` controller the ONE R1 project authority; the
     * production large-import path now uses the V6 service above.
     */
    internal suspend fun createMediaFromStagedForImport(
        request: CreativeMediaSourceRequest,
    ): MediaProjectEnvelope = project.createMediaFromStaged(request)

    internal suspend fun importMediaAssetForImport(
        commit: MediaImportCommit,
    ): MediaAssetReceipt = project.importAsset(
        token = commit.token,
        opID = commit.opID,
        projectID = commit.context.projectID,
        expectedRevision = commit.expectedRevision,
        sessionToken = commit.context.sessionToken,
        storage = commit.context.storage,
        origin = commit.context.origin,
        fileName = commit.fileName,
        mimeType = commit.mimeType,
        byteCount = commit.byteCount,
        sha256 = commit.sha256)

    /**
     * Lifecycle-internal global shutdown; not exposed by CreativeHostApi.
     * Token-scoped editor closes are the only public session-retirement API.
     */
    internal suspend fun shutdown() {
        design.trustedApprovals.retire()
        design.shutdownStaging()
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
    private val appContext: android.content.Context,
    private val epochProvider: () -> Long?,
    private val acceptedRootProvider: () -> CreativeAcceptedRoot?,
    designAuthorityIssuer: DesignAuthorityIssuer? = null,
    private val transport: CreativeTransport = SwiftCreativeTransport,
) {
    private val adapter = CreativeHostService(
        context = appContext,
        acceptedRootProvider = acceptedRootProvider,
        epochProvider = epochProvider,
        designAuthorityIssuer = designAuthorityIssuer,
        transport = transport)

    val services: CreativeHostApi get() = adapter

    /** G09-R2 typed video read/apply on floe.creative/6. */
    val r2Video: CreativeR2VideoHost by lazy {
        CreativeR2VideoHost(transport = transport, epochProvider = epochProvider)
    }

    /** G09-R2 native-issued immutable render snapshot lease port. */
    val r2Snapshots: WorkbenchRenderSnapshotPort by lazy {
        CreativeRenderSnapshotPort(epochProvider = epochProvider)
    }

    /** G09-R2 bounded render-ticket pump (platform12 is the consumer). */
    internal val r2RenderTransport: MediaRenderTicketNativeTransport by lazy {
        MediaRenderTicketNativeTransport()
    }
    val r2RenderTickets: MediaRenderTicketTransport get() = r2RenderTransport

    /** Plain native-record-backed epoch/root + lease authority proofs. */
    val r2Authority: CreativeR2HostAuthority by lazy {
        CreativeR2HostAuthority(
            epochProvider = epochProvider,
            acceptedRootProvider = acceptedRootProvider)
    }

    /** G09-R2 configured-provider generation and candidate adoption. */
    val generationHost: WorkbenchGenerationHostApi get() = adapter.generationHost

    /** G09-R2 real Canvas/workspace/chat/creative design workflow. */
    val designHost: DesignHostApi get() = adapter.designHost

    /** Typed trusted UI callback for restructure confirmation. */
    val designTrustedApprovals: DesignTrustedApprovalController
        get() = adapter.designTrustedApprovals

    /** Creative START request + verified first-result bind host methods. */
    suspend fun beginCreative(
        binding: com.floe.android.feature.canvas.DesignTargetBinding,
        expectedRevision: Long?,
        opID: String,
        brief: com.floe.android.feature.canvas.DesignBriefModel? = null,
        spec: com.floe.android.feature.canvas.DesignSpecModel? = null,
    ) = adapter.beginCreative(
        binding, expectedRevision, opID, brief, spec)

    suspend fun bindCreativeFirstResult(
        binding: com.floe.android.feature.canvas.DesignTargetBinding,
        expectedRevision: Long,
        opID: String,
        boundResultID: String,
        payload: com.floe.android.feature.canvas.StagedDesignPayload,
        displayName: String? = null,
    ) = adapter.bindCreativeFirstResult(
        binding, expectedRevision, opID, boundResultID, payload, displayName)

    /** Bounded retained-asset metadata for the first-material picker. */
    suspend fun creativeAssets(
        cursor: String? = null,
        limit: Int = 24,
    ): CreativeDesignAssetPage = adapter.creativeAssets(cursor, limit)

    /** Bounded pending-request reopen list. */
    suspend fun creativePendingRequests(
        cursor: String? = null,
        limit: Int = 24,
    ): CreativeDesignPendingPage = adapter.creativePendingRequests(cursor, limit)

    /** Direct bind of an EXISTING retained creative asset. */
    suspend fun bindCreativeRetainedFirstResult(
        binding: com.floe.android.feature.canvas.DesignTargetBinding,
        expectedRevision: Long,
        opID: String,
        boundResultID: String,
        displayName: String? = null,
    ): com.floe.android.feature.canvas.DesignStateProjection =
        adapter.bindCreativeRetainedFirstResult(
            binding, expectedRevision, opID, boundResultID, displayName)

    /** Stage-once SAF/manual import + verified first-result bind. */
    suspend fun importCreativeFirstResult(
        binding: com.floe.android.feature.canvas.DesignTargetBinding,
        expectedRevision: Long,
        opID: String,
        payload: com.floe.android.feature.canvas.StagedDesignPayload,
        displayName: String? = null,
    ): CreativeDesignImportReceipt = adapter.importCreativeFirstResult(
        binding, expectedRevision, opID, payload, displayName)

    /** The explicit App staging seam for proposal payload bytes. */
    suspend fun stageDesignPayload(
        source: Uri,
        sessionToken: String,
    ) = adapter.stageDesignPayload(source, sessionToken)

    fun discardDesignPayload(token: String) =
        adapter.discardDesignPayload(token)

    /** G09-R2 service-owned large-import App facade over the REAL V6 actions. */
    internal val r2ImportHost: CreativeLargeImportHost by lazy {
        CreativeLargeImportHost(
            context = appContext,
            acceptedRootProvider = acceptedRootProvider,
            liveEpochProvider = epochProvider,
            transport = transport)
    }
    val r2LargeImports: WorkbenchLargeImportPort get() = r2ImportHost

    suspend fun bindCurrent(): CreativeBinding {
        val epoch = epochProvider()?.takeIf { it > 0L }
            ?: throw CreativeException(
                "runtimeUnavailable", "acceptedRootNotLive", retryable = true)
        return services.bind(epoch)
    }

    /**
     * Root order step 2: App staging must stop first, then the native
     * aggregate gate (imports + render claims + binding pins) must report
     * drained. FALSE keeps Root/root references bound and surfaces pending.
     */
    suspend fun beginR2NativeRootStop(): Boolean {
        val epoch = epochProvider()?.takeIf { it > 0L } ?: return true
        // Retire every prepared/confirmed restructure claim BEFORE native
        // Root drains, so a late confirmation cannot mint a grant for a
        // replacement generation.
        adapter.designTrustedApprovals.retire()
        // Root order step 1: fence new App staging, cancel/close REAL SAF
        // copies and join their workers. A still-running copy keeps Root
        // pending; a cancelled Job flag is never reported as drained. Native
        // workers are fenced in the same step so no new work starts while the
        // copy is settling.
        val stagingDrained = adapter.fenceDesignStaging()
        val nativeFirst = r2Authority.rootStop()
        if (!r2ImportHost.drainStaging(epoch)) return false
        if (!nativeFirst) {
            GenerationForegroundOwner.releaseAll(epoch)
            if (!r2Authority.rootStop()) return false
        }
        return stagingDrained
    }

    suspend fun r2DrainPending(): Int {
        val epoch = epochProvider()?.takeIf { it > 0L } ?: return 0
        return r2ImportHost.activeStagingCount() + r2Authority.drainPending()
    }

    suspend fun stop() {
        GenerationForegroundOwner.stopAll()
        r2ImportHost.shutdown()
        adapter.shutdown()
    }

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
