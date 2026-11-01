// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import com.floe.android.feature.canvas.ui.api.CanvasAssetImport
import com.floe.android.feature.canvas.ui.api.CanvasEditorPorts
import com.floe.android.feature.canvas.ui.api.CanvasPickedSource
import com.floe.android.feature.canvas.ui.api.CanvasSourceCreate
import com.floe.android.feature.canvas.ui.state.CanvasWorkspaceSession
import com.floe.android.feature.workbench.ui.api.MediaAssetImport
import com.floe.android.feature.workbench.ui.api.MediaEditorPorts
import com.floe.android.feature.workbench.ui.api.MediaPickedSource
import com.floe.android.feature.workbench.ui.api.MediaSourceCreate
import com.floe.android.feature.workbench.ui.state.MediaWorkspaceSession
import com.floe.android.host.Owner
import com.floe.android.host.RuntimeHost
import com.floe.android.host.WorkspaceOfficeSnapshotStager
import java.io.File
import java.util.Locale
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
        ).also { mediaLibrary = it }
    }

    fun mediaRouteSession(app: FloeApplication, key: String): MediaWorkspaceSession {
        mediaRoutes[key]?.let { return it }
        synchronized(lock) {
            mediaRoutes[key]?.let { return it }
            val (scope, bundle) = ensure(app)
            val created = MediaWorkspaceSession(
                host = bundle.app.creativeHost.services,
                ports = MediaPorts(bundle),
                scope = scope,
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
}

/**
 * Thin holder so the ports read the CURRENT CreativeHostController rather
 * than capturing a stale service instance across an epoch replacement.
 */
internal class CreativeHostControllerBundle(val app: FloeApplication)

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
            CreativeDocumentSourceStaging.consume(source.uri)
        }
    }

    override val assetImport = MediaAssetImport {
            source, projectID, expectedRevision, storage, origin, sessionToken, opID ->
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

    fun consume(uri: Uri) {
        val directory = directories.remove(uri.toString()) ?: return
        runCatching { directory.deleteRecursively() }
    }
}

internal fun mediaSourceFormats(kind: String): Set<String> = when (kind) {
    // ISO-BMFF only: the host measures MP4/MOV/M4V and refuses the rest.
    "video" -> setOf("mov", "mp4", "m4v")
    else -> setOf("png", "jpg", "jpeg", "webp", "gif", "bmp", "heic", "heif")
}

internal suspend fun stageWorkspaceMediaSource(
    context: Context,
    host: RuntimeHost,
    owner: Owner,
    relativePath: String,
    kind: String,
): MediaPickedSource = withContext(Dispatchers.IO) {
    val stager = WorkspaceOfficeSnapshotStager(
        File(context.applicationContext.applicationInfo.dataDir, "files/CreativeDocumentSource"),
    )
    val snapshot = stager.stage(
        owner = WorkspaceOfficeSnapshotStager.Owner(
            taskID = owner.taskID,
            workspaceID = owner.workspaceID,
            nativeEpoch = owner.nativeEpoch,
            hostGeneration = owner.hostGeneration,
        ),
        relativePath = relativePath,
        formats = mediaSourceFormats(kind),
        maxBytes = 64L * 1024 * 1024,
        isCurrent = {
            host.nativeRootEpoch() == owner.nativeEpoch &&
                host.commandClient.generation() == owner.hostGeneration
        },
    )
    val uri = Uri.fromFile(snapshot.file)
    CreativeDocumentSourceStaging.register(uri, snapshot.file.parentFile ?: snapshot.file)
    val extension = relativePath.substringAfterLast('.', "").lowercase(Locale.ROOT)
    val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
    MediaPickedSource(
        uri = uri,
        displayName = relativePath.substringAfterLast('/'),
        mimeType = mime,
        byteCount = snapshot.bytes,
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
