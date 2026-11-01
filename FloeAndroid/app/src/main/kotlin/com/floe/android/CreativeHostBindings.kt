// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.canvas.ui.api.CanvasAssetImport
import com.floe.android.feature.canvas.ui.api.CanvasEditorPorts
import com.floe.android.feature.canvas.ui.api.CanvasPickedSource
import com.floe.android.feature.canvas.ui.api.CanvasSourceCreate
import com.floe.android.feature.canvas.ui.design.DesignSessionProvider
import com.floe.android.feature.canvas.ui.state.CanvasWorkspaceSession
import com.floe.android.feature.workbench.ui.api.MediaAgentOwnerContext
import com.floe.android.feature.workbench.ui.api.MediaAssetImport
import com.floe.android.feature.workbench.ui.api.MediaEditorPorts
import com.floe.android.feature.workbench.ui.api.MediaGallerySavePort
import com.floe.android.feature.workbench.ui.api.MediaLayerRasterPort
import com.floe.android.feature.workbench.ui.api.MediaPickedSource
import com.floe.android.feature.workbench.ui.api.MediaSourceCreate
import com.floe.android.feature.workbench.ui.api.MediaTranscriptionPort
import com.floe.android.feature.workbench.ui.api.MediaTranscriptionReceipt
import com.floe.android.host.gallery.MediaGallerySaveController
import com.floe.android.host.gallery.MediaLayerRasterController
import com.floe.android.host.voice.C03VoiceFailure
import com.floe.android.feature.workbench.ui.r2.WorkbenchR2Ports
import com.floe.android.feature.workbench.ui.state.MediaWorkspaceSession
import com.floe.android.mediaintegration.MediaWorkbenchImportPolicy
import com.floe.android.mediaintegration.MediaWorkspaceOwner
import com.floe.android.host.Owner
import com.floe.android.host.RuntimeHost
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** One user-selected source resolved by the platform picker. */
internal data class PickedFile(
    val uri: Uri,
    val displayName: String,
    val mimeType: String?,
    val byteCount: Long?,
)

/**
 * App-owned creative UI sessions.
 *
 * The sessions are retained outside composition so rotation/background/view
 * reconstruction preserve the editor token and loaded draft. Only an actual
 * close retires the exact token; process death drops the RAM-only session.
 */
internal object CreativeUiHost {
    private val lock = Any()
    private var appScope: CoroutineScope? = null
    private var canvas: CanvasWorkspaceSession? = null
    private var mediaLibrary: MediaWorkspaceSession? = null
    private val mediaRoutes = ConcurrentHashMap<String, MediaWorkspaceSession>()

    private fun ensure(
        app: FloeApplication,
    ): Pair<CoroutineScope, CreativeHostControllerBundle> = synchronized(lock) {
        val scope = appScope ?: CoroutineScope(
            SupervisorJob() + Dispatchers.Main.immediate,
        ).also { appScope = it }
        scope to CreativeHostControllerBundle(app)
    }

    /**
     * The App-owned design session provider for the Canvas Design entry. The
     * retained map and Root drain stay in [FloeApplication.designUi]; this
     * accessor is only the existing creative host binding point.
     */
    fun designSessions(app: FloeApplication): DesignSessionProvider = app.designUi

    /**
     * Trusted, read-only Materials base path of the LIVE captured Canvas
     * editor for exactly this canvas id, or null.
     *
     * Used only by the design-snapshot reader to resolve the captured
     * document's asset relative references; the path itself is native-issued
     * from the same accepted root and is re-proved before any read. This
     * accessor never creates/opens a session, never registers a token and
     * never returns a path declared by JSON.
     */
    fun canvasAssetsBasePath(app: FloeApplication, canvasID: String): String? =
        synchronized(lock) {
            val editor = canvas?.editor ?: return@synchronized null
            if (editor.canvasID != canvasID) return@synchronized null
            editor.assetsBasePath
        }

    fun canvasSession(app: FloeApplication): CanvasWorkspaceSession = synchronized(lock) {
        val (scope, bundle) = ensure(app)
        canvas ?: CanvasWorkspaceSession(
            host = bundle.app.creativeHost.services,
            ports = CanvasPorts(bundle),
            scope = scope,
        ).also { canvas = it }
    }

    fun mediaLibrarySession(app: FloeApplication): MediaWorkspaceSession = synchronized(lock) {
        val (scope, bundle) = ensure(app)
        mediaLibrary ?: MediaWorkspaceSession(
            host = bundle.app.creativeHost.services,
            ports = MediaPorts(bundle),
            scope = scope,
            r2Ports = bundle.workbenchR2Ports,
            agentBinding = bundle.app.mediaWorkbench.agentBinding,
        ).also { mediaLibrary = it }
    }

    fun mediaRouteSession(
        app: FloeApplication,
        key: String,
        agentTaskID: String? = null,
        agentWorkspaceID: String? = null,
    ): MediaWorkspaceSession {
        mediaRoutes[key]?.let { return it }
        synchronized(lock) {
            mediaRoutes[key]?.let { return it }
            val (scope, bundle) = ensure(app)
            val created = MediaWorkspaceSession(
                host = bundle.app.creativeHost.services,
                ports = MediaPorts(bundle),
                scope = scope,
                r2Ports = bundle.workbenchR2Ports,
                agentBinding = bundle.app.mediaWorkbench.agentBinding,
                agentOwner = agentTaskID?.let {
                    MediaAgentOwnerContext(it, agentWorkspaceID)
                },
            )
            mediaRoutes[key] = created
            return created
        }
    }

    fun releaseMediaRoute(key: String) {
        val session = mediaRoutes.remove(key) ?: return
        val scope = appScope
        if (scope != null) {
            scope.launch { runCatching { session.shutdown() } }
        } else {
            // No app scope means no session was ever opened; retain nothing.
        }
    }

    /**
     * Actual Root/epoch retirement: drop every retained library/route session
     * BEFORE the media platform is drained, so no editor/player/observer keeps
     * submitting against a root that is about to be replaced. The process
     * platform session itself is retired by [MediaWorkbenchHost].
     */
    suspend fun retireMediaSessions() {
        val sessions = synchronized(lock) {
            buildList {
                mediaLibrary?.let { add(it) }
                addAll(mediaRoutes.values)
                mediaLibrary = null
                mediaRoutes.clear()
            }
        }
        sessions.forEach { session -> runCatching { session.shutdown() } }
    }
}

/**
 * Thin holder so the ports read the CURRENT CreativeHostController rather
 * than capturing a stale service instance across an epoch replacement.
 *
 * The required R2 port bundle is lazy and its members resolve the CURRENT
 * App host/platform session on every call; the bundle itself is never an
 * authority and never captures a project root.
 */
internal class CreativeHostControllerBundle(val app: FloeApplication) {
    val workbenchR2Ports: WorkbenchR2Ports by lazy { app.mediaWorkbench.r2Ports }

    /** One shared App-owned layer raster bridge for the current controller. */
    val mediaLayerRaster: MediaLayerRasterPort by lazy {
        MediaLayerRasterController { app.creativeHost }
    }

    /** One shared App-owned gallery save bridge; no per-editor duplicate store. */
    val gallerySave: MediaGallerySavePort by lazy {
        MediaGallerySaveController(app, { app.creativeHost })
    }
}

private class CanvasPorts(private val bundle: CreativeHostControllerBundle) : CanvasEditorPorts {
    private val host get() = bundle.app.creativeHost

    override val sourceCreate = CanvasSourceCreate { source, name, workspaceID, sessionToken, opID ->
        host.createCanvasFromUri(
            uri = source.uri,
            name = name,
            workspaceID = workspaceID,
            sessionToken = sessionToken,
            opID = opID,
        )
    }

    override val assetImport = CanvasAssetImport { source, _, sessionToken, opID ->
        host.importCanvasAsset(
            source = source.uri,
            fileName = source.displayName,
            mimeType = source.mimeType,
            sessionToken = sessionToken,
            opID = opID,
        )
    }
}

private class MediaPorts(private val bundle: CreativeHostControllerBundle) : MediaEditorPorts {
    private val host get() = bundle.app.creativeHost

    override val sourceCreate = MediaSourceCreate {
            source, name, kind, storage, origin, sessionToken, opID ->
        try {
            if (origin != null &&
                MediaWorkbenchImportPolicy.shouldUseLargeRoute(kind, source.byteCount) &&
                MediaWorkbenchImportPolicy.newProjectKind(kind) != null
            ) {
                return@MediaSourceCreate bundle.app.mediaWorkbench.largeImport.createProject(
                    source = source,
                    name = name,
                    kind = kind,
                    storage = storage,
                    origin = origin,
                    sessionToken = sessionToken,
                    opID = opID,
                )
            }
            host.createMediaFromUri(
                uri = source.uri,
                name = name,
                kind = kind,
                storage = storage,
                origin = origin,
                sessionToken = sessionToken,
                opID = opID,
            )
        } finally {
            // Deletes only the App-owned pre-stage snapshot after the real
            // import call returned. The native staged token is owned by the
            // large-import host after an accepted submit and is never deleted
            // from this App finally.
            bundle.app.mediaWorkbench.workspacePrestage.consume(source.uri)
        }
    }

    override val layerRaster: MediaLayerRasterPort
        get() = bundle.mediaLayerRaster

    override val gallerySave: MediaGallerySavePort
        get() = bundle.gallerySave

    override val transcription = MediaTranscriptionPort { context, assetID, expectedRevision ->
        val voice = bundle.app.runtimeHost?.voiceOrNull()
            ?: throw CreativeException(
                "runtimeUnavailable", "voiceHostUnavailable", retryable = true)
        val storageKind = when (context.storage) {
            CreativeStorageLayer.AppOwned -> "appOwned"
            is CreativeStorageLayer.Workspace -> "workspace"
        }
        val workspaceID = (context.storage as? CreativeStorageLayer.Workspace)?.workspaceID
        val origin = context.origin
        try {
            val receipt = voice.transcribeAndWrite(
                projectID = context.projectID,
                sessionToken = context.sessionToken,
                storageKind = storageKind,
                workspaceID = workspaceID,
                originKind = origin?.kind,
                originOwnerID = origin?.ownerID,
                originEnvironmentID = origin?.environmentID,
                expectedRevision = expectedRevision,
                assetID = assetID,
            )
            MediaTranscriptionReceipt(
                projectID = receipt.projectID,
                revision = receipt.revision,
                operationID = receipt.operationID,
                idempotent = receipt.idempotent,
            )
        } catch (failure: C03VoiceFailure) {
            throw CreativeException(
                failure.code.wire,
                failure.reason,
                retryable = failure.retryable,
            )
        }
    }

    override val assetImport = MediaAssetImport {
            source, projectID, expectedRevision, storage, origin, sessionToken, opID ->
        if (storage != null &&
            MediaWorkbenchImportPolicy.shouldUseLargeRouteForAsset(source)
        ) {
            return@MediaAssetImport bundle.app.mediaWorkbench.largeImport.importAsset(
                source = source,
                projectID = projectID,
                expectedRevision = expectedRevision,
                storage = storage,
                origin = origin,
                sessionToken = sessionToken,
                opID = opID,
            )
        }
        host.importMediaAsset(
            source = source.uri,
            fileName = source.displayName,
            mimeType = source.mimeType,
            projectID = projectID,
            expectedRevision = expectedRevision,
            storage = storage,
            origin = origin,
            sessionToken = sessionToken,
            opID = opID,
        )
    }
}

/** Staged workspace snapshots used only by the document MEDIA/IMAGE route. */
internal object CreativeDocumentSourceStaging {
    private val directories = ConcurrentHashMap<String, File>()

    fun register(uri: Uri, directory: File) {
        directories[uri.toString()] = directory
    }

    /** Removes and deletes exactly this owned snapshot; returns its directory. */
    fun consume(uri: Uri): File? {
        val directory = directories.remove(uri.toString()) ?: return null
        runCatching { directory.deleteRecursively() }
        return directory
    }
}

internal suspend fun stageWorkspaceMediaSource(
    context: Context,
    host: RuntimeHost,
    owner: Owner,
    relativePath: String,
    kind: String,
): MediaPickedSource {
    val application = context.applicationContext as? FloeApplication
        ?: throw CreativeException(
            "unavailable", "applicationUnavailable", retryable = true)
    // The Application owns the real staging worker; this composable call only
    // awaits the exact committed result. Rotation therefore cannot kill the
    // native egress ticket half-way.
    return application.mediaWorkbench.workspacePrestage.stage(
        owner = MediaWorkspaceOwner(
            taskID = owner.taskID,
            workspaceID = owner.workspaceID,
            nativeEpoch = owner.nativeEpoch,
            hostGeneration = owner.hostGeneration,
        ),
        relativePath = relativePath,
        kind = kind,
        isCurrent = {
            host.nativeRootEpoch() == owner.nativeEpoch &&
                host.commandClient.generation() == owner.hostGeneration
        },
    )
}

@Composable
private fun rememberPickedFileLauncher(
    mimeTypes: Array<String>,
): suspend () -> PickedFile? {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var pending by remember { mutableStateOf<CompletableDeferred<PickedFile?>?>(null) }
    val launcher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        val target = pending
        pending = null
        if (uri == null) {
            target?.complete(null)
        } else {
            scope.launch {
                target?.complete(resolvePickedFile(context, uri))
            }
        }
    }
    return remember(context, launcher) {
        suspend {
            val deferred = CompletableDeferred<PickedFile?>()
            pending = deferred
            launcher.launch(mimeTypes)
            try {
                deferred.await()
            } finally {
                if (pending === deferred) pending = null
            }
        }
    }
}

private suspend fun resolvePickedFile(context: Context, uri: Uri): PickedFile? =
    withContext(Dispatchers.IO) {
        val resolver = context.contentResolver
        var displayName = uri.lastPathSegment?.substringAfterLast('/') ?: "file"
        var size: Long? = null
        runCatching {
            resolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (nameIndex >= 0 && !cursor.isNull(nameIndex)) {
                        displayName = cursor.getString(nameIndex)
                    }
                    if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                        size = cursor.getLong(sizeIndex)
                    }
                }
            }
        }
        val mime = runCatching { resolver.getType(uri) }.getOrNull()
        PickedFile(
            uri = uri,
            displayName = displayName,
            mimeType = mime,
            byteCount = size?.takeIf { it > 0 },
        )
    }

internal val CREATIVE_IMAGE_MIME_TYPES = arrayOf(
    "image/png",
    "image/jpeg",
    "image/webp",
    "image/gif",
    "image/bmp",
)

@Composable
internal fun rememberCanvasImagePicker(): suspend () -> CanvasPickedSource? {
    val pick = rememberPickedFileLauncher(CREATIVE_IMAGE_MIME_TYPES)
    return remember(pick) {
        suspend {
            pick()?.let {
                CanvasPickedSource(
                    uri = it.uri,
                    displayName = it.displayName,
                    mimeType = it.mimeType,
                    byteCount = it.byteCount,
                )
            }
        }
    }
}

@Composable
internal fun rememberMediaFilePicker(mimeTypes: Array<String>): suspend () -> MediaPickedSource? {
    val pick = rememberPickedFileLauncher(mimeTypes)
    return remember(pick) {
        suspend {
            pick()?.let {
                MediaPickedSource(
                    uri = it.uri,
                    displayName = it.displayName,
                    mimeType = it.mimeType,
                    byteCount = it.byteCount,
                )
            }
        }
    }
}
