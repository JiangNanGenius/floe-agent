// SPDX-License-Identifier: MPL-2.0
//
// Application-owned C04A viewer session. It owns ONLY platform execution:
// staging through the existing G04 native workspace egress, the local-only
// WebView surface, image capture, and cancellation/root fences. Every file
// still belongs to the task/workspace authority; every rendered fact comes
// from the pinned renderer's actual frame, not from "WASM loaded".
package com.floe.android.host.cad

import android.content.Context
import android.content.res.Configuration
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.view.ViewGroup
import android.webkit.JavascriptInterface
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import com.floe.android.host.Owner
import com.floe.android.host.WorkspaceOfficeSnapshotStager
import java.io.File
import java.io.FileInputStream
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put

internal enum class C04CadFailure {
    OWNER,
    SOURCE,
    TOO_LARGE,
    INVALID,
    UNSUPPORTED,
    RESOURCE,
    TRANSPORT,
    RENDER,
    CAPTURE,
    CORE_UPDATE,
    CANCELLED,
}

internal data class C04CadCaptureReceipt(
    val receiptID: String,
    val fileName: String,
    val filePath: String,
    val sha256: String,
    val byteCount: Long,
    val pixelWidth: Int,
    val pixelHeight: Int,
    val capturedAtMillis: Long,
    val format: C04CadFormat,
)

/** Only produced after the picked SAF document was written and read back to
 * the exact capture digest. `uri` is the real user-facing document. */
internal data class C04CadCaptureExportReceipt(
    val captureReceiptID: String,
    val uri: String,
    val displayName: String,
    val sha256: String,
    val byteCount: Long,
    val pixelWidth: Int,
    val pixelHeight: Int,
    val exportedAtMillis: Long,
    val format: C04CadFormat,
)

internal sealed interface C04CadViewerState {
    data object Idle : C04CadViewerState

    data class Opening(
        val token: Long,
        val fileName: String,
    ) : C04CadViewerState

    data class Rendering(
        val token: Long,
        val fileName: String,
        val format: C04CadFormat,
        val missingResources: List<String>,
    ) : C04CadViewerState

    data class Ready(
        val token: Long,
        val fileName: String,
        val format: C04CadFormat,
        val facts: C04CadSceneFacts,
        val missingResources: List<String>,
        val capturing: Boolean = false,
        val exporting: Boolean = false,
        val lastCapture: C04CadCaptureReceipt? = null,
        val lastExport: C04CadCaptureExportReceipt? = null,
        val captureFailure: C04CadFailure? = null,
        val exportFailure: C04CadFailure? = null,
    ) : C04CadViewerState

    data class Failed(
        val token: Long,
        val fileName: String,
        val format: C04CadFormat?,
        val failure: C04CadFailure,
        val detail: String?,
        val retryable: Boolean,
        internal val owner: Owner?,
        internal val path: String,
    ) : C04CadViewerState
}

internal class C04CadViewerController(
    private val context: Context,
    private val scope: CoroutineScope,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val currentNativeEpoch: () -> Long?,
    private val currentHostGeneration: () -> Long,
    private val isTemporaryTask: (String) -> Boolean,
    private val client: C04CadHostClient = C04CadHostClient(),
    private val stager: WorkspaceOfficeSnapshotStager = WorkspaceOfficeSnapshotStager(
        File(context.applicationContext.filesDir, "CadViewer/snapshots"),
    ),
    private val captureStore: C04CadCaptureStore = C04CadCaptureStore(
        context.applicationContext,
    ),
    private val captureExporter: C04CadCaptureExporter = C04CadCaptureExporter(
        captureStore.rootDirectory,
    ),
    private val imageDecoder: C04FloecadImageDecoder = C04FloecadAndroidImageDecoder(),
) {
    private val json = Json { ignoreUnknownKeys = false }
    private val lock = Any()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val generation = AtomicLong(0)
    private val registry = C04CadAssetRegistry()
    private val assetServer = C04CadWebAssetServer(context, registry)
    private val previewComponents = com.floe.android.host.components.PreviewComponentStore.get(context)
    private val pendingCaptures = ConcurrentHashMap<String, CompletableDeferred<C04CadCapturePayload>>()
    private var jobs = LinkedHashSet<Job>()
    /** Capture/export jobs are Application-owned so view disposal cannot
     * cancel their IO and RootStop can join them. */
    private val ownedOperations = LinkedHashSet<Job>()
    /** Cleanup jobs wait for owned work and are retried/drained by RootStop. */
    private val cleanupOperations = LinkedHashSet<Job>()

    private val mutableState = MutableStateFlow<C04CadViewerState>(C04CadViewerState.Idle)
    val state: StateFlow<C04CadViewerState> = mutableState

    @Volatile
    private var active: Session? = null

    @Volatile
    private var surface: WebView? = null

    @Volatile
    private var stoppingForEpoch: Long? = null

    private class Session(
        val token: Long,
        val owner: Owner,
        val relativePath: String,
        val format: C04CadFormat,
        val generation: Long,
        val dark: Boolean,
    ) {
        var job: Job? = null
        var coreSessionID: String? = null
        var assets: C04CadAssetSession? = null
        val staged = ArrayList<WorkspaceOfficeSnapshotStager.Snapshot>()
        var facts: C04CadSceneFacts? = null
        var missing: List<String> = emptyList()
        var boundSurface: WebView? = null
        var surfaceLoadedFor: WebView? = null
        var renderTimeout: Job? = null
        var previewDirectory: File? = null
        var packageFacts: C04FloecadPreview? = null
        var closed = false
    }

    private data class C04CadCapturePayload(
        val dataUrl: String,
        val width: Int,
        val height: Int,
        val frameSequence: Int,
    )

    private data class PendingReference(
        val reference: C04CadReference,
        val baseDirectory: String,
    )

    private class SessionFailure(
        val failure: C04CadFailure,
        val detail: String?,
        val retryable: Boolean = true,
    ) : Exception(detail ?: failure.name)

    // ------------------------------------------------------------------
    // Public UI contract
    // ------------------------------------------------------------------

    fun open(
        owner: Owner,
        relativePath: String,
        token: Long,
        force: Boolean = false,
        dark: Boolean? = null,
    ): Boolean {
        val format = C04CadFormat.fromPath(relativePath)
        val desiredDark = dark ?: isDark()
        val stop = stoppingForEpoch
        if (!ownerCurrent(owner) || (stop != null && currentNativeEpoch() == stop)) {
            publishFailure(owner, relativePath, format, C04CadFailure.OWNER,
                detail = "owner", retryable = false, requestToken = token)
            return false
        }
        if (format == null) {
            val detail = if (C04CadFormat.isNativePackage(relativePath)) "floecad" else "format"
            publishFailure(owner, relativePath, null, C04CadFailure.UNSUPPORTED,
                detail = detail, retryable = false, requestToken = token)
            return false
        }
        val (retired, _) = synchronized(lock) {
            val existing = active
            if (!force && existing != null && existing.token == token &&
                existing.owner == owner && existing.relativePath == relativePath &&
                existing.format == format && existing.dark == desiredDark
            ) {
                return true
            }
            val old = existing?.let(::markClosedLocked)
            val created = Session(
                token, owner, relativePath, format, generation.incrementAndGet(),
                desiredDark)
            active = created
            mutableState.value = C04CadViewerState.Opening(token, fileName(relativePath))
            created.job = trackJob(scope.launch(ioDispatcher) { runSession(created) })
            old to created
        }
        retired?.let { retire(it) }
        return true
    }

    fun retry(token: Long, dark: Boolean? = null): Boolean {
        val failed = mutableState.value as? C04CadViewerState.Failed ?: return false
        if (failed.token != token || !failed.retryable) return false
        val owner = failed.owner ?: return false
        return open(owner, failed.path, token, force = true, dark = dark)
    }

    fun close(token: Long) {
        val retired = synchronized(lock) {
            val session = active ?: return
            if (session.token != token) return
            val old = markClosedLocked(session)
            mutableState.value = C04CadViewerState.Idle
            old
        }
        pendingCaptures.values.forEach {
            it.completeExceptionally(C04CadCaptureFailure("cancelled"))
        }
        pendingCaptures.clear()
        mainHandler.post { destroySurfaceFor(retired) }
        retired?.let { retire(it) }
    }

    fun attachSurface(view: WebView) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post { attachSurface(view) }
            return
        }
        synchronized(lock) {
            if (surface === view) {
                val current = active ?: return
                current.boundSurface = view
                if (current.assets != null && current.surfaceLoadedFor !== view) {
                    loadSurface(current, view)
                }
                return
            }
            surface?.let { old ->
                if (old !== view) destroySurfaceLocked(old)
            }
            surface = view
            active?.boundSurface = view
            configure(view, active?.dark ?: isDark())
            val session = active
            if (session?.assets != null) loadSurface(session, view)
        }
    }

    fun detachSurface(view: WebView) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post { detachSurface(view) }
            return
        }
        synchronized(lock) {
            if (surface === view) {
                surface = null
                active?.let { if (it.boundSurface === view) it.boundSurface = null }
                destroySurfaceLocked(view)
            }
        }
    }

    /** Typed camera command for the actual renderer. The JS side applies it
     * to the DXF camera or the 3D navigation camera; an unavailable surface or
     * a non-current session is a no-op, never a fake local zoom state. */
    /** C04B handoff: validate one `floe.cad-package/1` manifest through the
     * same Swift domain the viewer uses. Call from a background dispatcher
     * (the bridge is synchronous). No bytes are read or rendered here. */
    fun validateExtension(manifestJson: String): C04CadExtensionSummary =
        client.validateExtension(manifestJson)

    fun command(name: String) {
        if (name !in C04_CAD_COMMANDS) return
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post { command(name) }
            return
        }
        val session = active ?: return
        if (!isCurrent(session)) return
        val view = surface ?: return
        view.evaluateJavascript(
            "window.floeCadViewer && window.floeCadViewer.command(${quote(name)})",
            null,
        )
    }

    /**
     * Captures the ACTUAL current canvas after a fresh render. The JS side
     * returns only a data URL from `canvas.toDataURL('image/png')`; this
     * method walks the PNG, decodes only its dimensions, writes the artifact,
     * hashes the exact bytes and asks the Swift domain for the bound receipt.
     */
    suspend fun capture(expectedToken: Long? = null): C04CadCaptureReceipt =
        owned { captureNow(expectedToken) }

    private suspend fun captureNow(expectedToken: Long?): C04CadCaptureReceipt {
        val requestId = UUID.randomUUID().toString()
        val deferred = CompletableDeferred<C04CadCapturePayload>()
        val session = synchronized(lock) {
            val current = active ?: throw C04CadCaptureFailure("owner")
            val ready = mutableState.value as? C04CadViewerState.Ready
                ?: throw C04CadCaptureFailure("notReady")
            if (expectedToken != null && ready.token != expectedToken) {
                throw C04CadCaptureFailure("owner")
            }
            if (ready.token != current.token || ready.capturing || ready.exporting) {
                throw C04CadCaptureFailure("busy")
            }
            if (!isCurrentLocked(current)) throw C04CadCaptureFailure("owner")
            mutableState.value = ready.copy(
                capturing = true,
                captureFailure = null,
                exportFailure = null,
                lastCapture = null,
                lastExport = null,
            )
            pendingCaptures[requestId] = deferred
            current
        }
        try {
            val view = surface
                ?: throw C04CadCaptureFailure("surface")
            if (!isCurrent(session)) throw C04CadCaptureFailure("owner")
            withContext(Dispatchers.Main.immediate) {
                view.evaluateJavascript(
                    "window.floeCadViewer && window.floeCadViewer.capture(${quote(requestId)})",
                    null,
                )
            }
            val payload = withTimeoutOrNull(15_000L) { deferred.await() }
                ?: throw C04CadCaptureFailure("timeout")
            val raw = decodeDataUrl(payload.dataUrl)
            val info = C04CadPng.inspect(raw)
                ?: throw C04CadCaptureFailure("png")
            if (info.width != payload.width || info.height != payload.height) {
                throw C04CadCaptureFailure("dimensions")
            }
            val artifact = withContext(ioDispatcher) {
                captureStore.store(
                    sessionToken = session.coreSessionID
                        ?: throw C04CadCaptureFailure("session"),
                    sourceFileName = fileName(session.relativePath),
                    bytes = raw,
                    width = info.width,
                    height = info.height,
                    format = session.format,
                )
            }
            val core = try {
                if (!isCurrent(session)) throw C04CadCaptureFailure("owner")
                withContext(ioDispatcher) {
                    client.capture(
                        sessionID = session.coreSessionID
                            ?: throw C04CadCaptureFailure("session"),
                        pngHeaderHex = artifact.pngHeaderHex,
                        pngSHA256 = artifact.sha256,
                        byteCount = artifact.byteCount,
                        pixelWidth = artifact.pixelWidth,
                        pixelHeight = artifact.pixelHeight,
                        frameSequence = payload.frameSequence,
                    )
                }
            } catch (error: Throwable) {
                artifact.file.delete()
                throw error
            }
            if (!isCurrent(session)) {
                artifact.file.delete()
                throw C04CadCaptureFailure("owner")
            }
            val receipt = C04CadCaptureReceipt(
                receiptID = core.receiptID,
                fileName = artifact.fileName,
                filePath = artifact.file.absolutePath,
                sha256 = artifact.sha256,
                byteCount = artifact.byteCount,
                pixelWidth = artifact.pixelWidth,
                pixelHeight = artifact.pixelHeight,
                capturedAtMillis = artifact.capturedAtMillis,
                format = artifact.format,
            )
            synchronized(lock) {
                val current = mutableState.value as? C04CadViewerState.Ready
                if (current != null && current.token == session.token) {
                    mutableState.value = current.copy(
                        capturing = false,
                        lastCapture = receipt,
                        lastExport = null,
                        captureFailure = null,
                        exportFailure = null,
                    )
                }
            }
            return receipt
        } catch (error: Throwable) {
            synchronized(lock) {
                val current = mutableState.value as? C04CadViewerState.Ready
                if (current != null && current.token == session.token) {
                    mutableState.value = current.copy(
                        capturing = false,
                        captureFailure = when (error) {
                            is C04CadCaptureFailure -> C04CadFailure.CAPTURE
                            else -> C04CadFailure.TRANSPORT
                        },
                    )
                }
            }
            throw error
        } finally {
            pendingCaptures.remove(requestId)
        }
    }

    /**
     * Captures the actual frame and writes it into the document URI the user
     * picked with the SAF create-document picker. Nothing is reported as
     * saved before the picked document reads back with the exact PNG digest.
     * The App-private capture remains in place either way.
     */
    suspend fun captureAndExport(token: Long, uri: Uri): C04CadCaptureExportReceipt =
        owned { captureAndExportNow(token, uri) }

    private suspend fun captureAndExportNow(token: Long, uri: Uri): C04CadCaptureExportReceipt {
        val receipt = try {
            captureNow(token)
        } catch (error: Throwable) {
            runCatching { C04CadAndroidExportSink(context.contentResolver, uri).delete() }
            throw error
        }
        val session = synchronized(lock) { active }
        if (session == null || session.token != token || !isCurrent(session)) {
            runCatching { C04CadAndroidExportSink(context.contentResolver, uri).delete() }
            throw C04CadCaptureFailure("owner")
        }
        return try {
            exportCaptureLocked(session, receipt, uri)
        } catch (error: Throwable) {
            runCatching { C04CadAndroidExportSink(context.contentResolver, uri).delete() }
            throw error
        }
    }

    /** Exports one previously captured and still session-owned artifact. */
    suspend fun exportCapture(token: Long, uri: Uri): C04CadCaptureExportReceipt =
        owned { exportCaptureNow(token, uri) }

    private suspend fun exportCaptureNow(token: Long, uri: Uri): C04CadCaptureExportReceipt {
        val state = mutableState.value as? C04CadViewerState.Ready
            ?: throw C04CadCaptureFailure("notReady")
        if (state.token != token) throw C04CadCaptureFailure("owner")
        val receipt = state.lastCapture ?: throw C04CadCaptureFailure("capture")
        val session = synchronized(lock) { active }
            ?: throw C04CadCaptureFailure("owner")
        if (session.token != token || !isCurrent(session)) {
            runCatching { C04CadAndroidExportSink(context.contentResolver, uri).delete() }
            throw C04CadCaptureFailure("owner")
        }
        return try {
            exportCaptureLocked(session, receipt, uri)
        } catch (error: Throwable) {
            runCatching { C04CadAndroidExportSink(context.contentResolver, uri).delete() }
            throw error
        }
    }

    private suspend fun exportCaptureLocked(
        session: Session,
        receipt: C04CadCaptureReceipt,
        uri: Uri,
    ): C04CadCaptureExportReceipt {
        synchronized(lock) {
            val current = mutableState.value as? C04CadViewerState.Ready
                ?: throw C04CadCaptureFailure("notReady")
            if (current.token != session.token || current.capturing || current.exporting) {
                throw C04CadCaptureFailure("busy")
            }
            mutableState.value = current.copy(
                exporting = true,
                exportFailure = null,
                lastExport = null,
            )
        }
        try {
            if (!isCurrent(session)) throw C04CadCaptureFailure("owner")
            val artifact = C04CadCaptureArtifact(
                file = File(receipt.filePath),
                fileName = receipt.fileName,
                sha256 = receipt.sha256,
                byteCount = receipt.byteCount,
                pixelWidth = receipt.pixelWidth,
                pixelHeight = receipt.pixelHeight,
                capturedAtMillis = receipt.capturedAtMillis,
                format = receipt.format,
                pngHeaderHex = "",
            )
            val sink = C04CadAndroidExportSink(context.contentResolver, uri)
            val exported = withContext(ioDispatcher) {
                captureExporter.export(artifact, sink) { isCurrent(session) }
            }
            if (!isCurrent(session)) {
                runCatching { sink.delete() }
                throw C04CadCaptureFailure("owner")
            }
            val receiptOut = C04CadCaptureExportReceipt(
                captureReceiptID = receipt.receiptID,
                uri = exported.uri,
                displayName = exported.displayName,
                sha256 = exported.sha256,
                byteCount = exported.byteCount,
                pixelWidth = exported.pixelWidth,
                pixelHeight = exported.pixelHeight,
                exportedAtMillis = exported.exportedAtMillis,
                format = receipt.format,
            )
            synchronized(lock) {
                val current = mutableState.value as? C04CadViewerState.Ready
                if (current != null && current.token == session.token) {
                    mutableState.value = current.copy(
                        exporting = false,
                        lastExport = receiptOut,
                        exportFailure = null,
                    )
                }
            }
            return receiptOut
        } catch (error: Throwable) {
            synchronized(lock) {
                val current = mutableState.value as? C04CadViewerState.Ready
                if (current != null && current.token == session.token) {
                    mutableState.value = current.copy(
                        exporting = false,
                        exportFailure = when (error) {
                            is C04CadCaptureFailure -> C04CadFailure.CAPTURE
                            is C04CadExportFailure -> C04CadFailure.CAPTURE
                            else -> C04CadFailure.TRANSPORT
                        },
                    )
                }
            }
            throw error
        }
    }

    // ------------------------------------------------------------------
    // Session execution
    // ------------------------------------------------------------------

    private suspend fun runSession(session: Session) {
        try {
            if (!isCurrent(session)) throw SessionFailure(C04CadFailure.OWNER, "owner")
            client.handshake()
            previewComponents.acquireCad("cad-view-${session.token}") { isCurrent(session) }
            if (session.format == C04CadFormat.FLOECAD) {
                runFloecadSession(session)
                return
            }
            val main = stager.stage(
                owner = stagerOwner(session.owner),
                relativePath = session.relativePath,
                formats = session.format.workspaceExtensions,
                maxBytes = session.format.maxSourceBytes,
                isCurrent = { isCurrent(session) },
            )
            session.staged.add(main)
            C04CadFileProbe.verify(session.format, main.file)?.let {
                throw SessionFailure(C04CadFailure.INVALID, it, retryable = false)
            }
            val resources = ArrayList<Pair<WorkspaceOfficeSnapshotStager.Snapshot, C04CadResourceDescriptor>>()
            val missing = ArrayList<String>()
            if (session.format.family == C04CadFamily.MESH_3D) {
                discoverResources(session, main, resources, missing)
            }
            if (!isCurrent(session)) throw SessionFailure(C04CadFailure.OWNER, "owner")
            val core = client.begin(
                owner = session.owner,
                relativePath = session.relativePath,
                format = session.format,
                sourceBytes = main.bytes,
                resources = resources.map { it.second },
            )
            session.coreSessionID = core.sessionID
            session.missing = missing.toList()
            val mainResource = served(main, UUID.randomUUID().toString())
            val resourceMap = LinkedHashMap<String, C04CadServedResource>()
            resourceMap[mainResource.second] = mainResource.first
            val sideResources = ArrayList<Pair<C04CadServedResource, String>>()
            for ((snapshot, descriptor) in resources) {
                val token = core.tokenByPath[descriptor.relativePath]
                    ?: throw SessionFailure(C04CadFailure.TRANSPORT, "resourceGrant")
                val served = served(snapshot, token)
                resourceMap[served.second] = served.first
                sideResources.add(served)
            }
            val names = sideResources.map { it.first.name.lowercase(Locale.ROOT) } +
                mainResource.first.name.lowercase(Locale.ROOT)
            if (names.size != names.toSet().size) {
                throw SessionFailure(C04CadFailure.RESOURCE, "duplicateResourceName")
            }
            val manifest = buildManifest(
                core = core,
                main = mainResource.first,
                mainToken = mainResource.second,
                sideResources = sideResources,
                missing = missing,
                format = session.format,
                dark = session.dark,
            )
            val assets = C04CadAssetSession(
                sessionToken = core.sessionID,
                format = session.format,
                manifest = manifest.toString().toByteArray(Charsets.UTF_8),
                main = mainResource.first,
                resources = resourceMap,
            )
            synchronized(lock) {
                if (!isCurrentLocked(session)) throw SessionFailure(C04CadFailure.OWNER, "owner")
                session.assets = assets
                registry.register(assets)
                mutableState.value = C04CadViewerState.Rendering(
                    session.token, fileName(session.relativePath), session.format,
                    missing.toList(),
                )
            }
            withContext(Dispatchers.Main.immediate) {
                val view = surface
                if (view != null && isCurrent(session) && view === surface &&
                    session.surfaceLoadedFor !== view
                ) {
                    loadSurface(session, view)
                }
            }
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            if (!session.closed && isCurrent(session)) {
                val mapped = mapFailure(error)
                publishFailure(
                    session.owner, session.relativePath, session.format,
                    mapped.failure, mapped.detail, mapped.retryable, session.token,
                )
            }
            cleanupSession(session)
        }
    }

    /**
     * C04C native `.floecad` directory package. Every member is staged through
     * the same native egress, the actual manifest/document hashes are proved,
     * and only a bounded derived GLB is handed to the existing C04A viewport.
     * The original package is never rewritten.
     */
    private suspend fun runFloecadSession(session: Session) {
        val previewRoot = File(context.applicationContext.filesDir, "CadViewer/previews")
        val directory = File(previewRoot, UUID.randomUUID().toString())
        session.previewDirectory = directory
        val source = C04FloecadWorkspaceSource(
            stager = stager,
            owner = stagerOwner(session.owner),
            isCurrent = { isCurrent(session) },
            onSnapshot = { snapshot -> session.staged.add(snapshot) },
        )
        val preview = withContext(ioDispatcher) {
            C04FloecadPackageReader(source, directory, imageDecoder).read(session.relativePath) {
                isCurrent(session)
            }
        }
        if (!isCurrent(session)) throw SessionFailure(C04CadFailure.OWNER, "owner", retryable = false)
        // Only visible B-Rep-only bodies are served, and only to the local
        // viewer. These resources are NOT listed in `resources` (the pinned
        // viewer would try to import them as a mesh); the adapter fetches
        // them itself and tessellates through the pinned offline OCCT worker.
        val brepByPath = LinkedHashMap<String, C04FloecadResource>()
        for (placement in preview.brepPlacements) {
            val resource = preview.resources.firstOrNull { it.path == placement.blobPath }
                ?: throw SessionFailure(C04CadFailure.INVALID, "brepResource", retryable = false)
            brepByPath[resource.path] = resource
        }
        val descriptors = brepByPath.values.map { resource ->
            C04CadResourceDescriptor(
                relativePath = "${session.relativePath}/${resource.path}",
                byteCount = resource.bytes,
                sha256 = resource.sha256,
                mediaType = "application/octet-stream",
            )
        }
        val core = client.begin(
            owner = session.owner,
            relativePath = session.relativePath,
            format = session.format,
            sourceBytes = preview.derivedBytes,
            resources = descriptors,
        )
        session.coreSessionID = core.sessionID
        session.missing = preview.missing
        session.packageFacts = preview
        val token = UUID.randomUUID().toString()
        val main = C04CadServedResource(
            name = "preview.glb",
            relativePath = "${session.relativePath}/derived-preview.glb",
            file = preview.derivedFile,
            byteCount = preview.derivedBytes,
            sha256 = preview.derivedSha256,
            mediaType = "model/gltf-binary",
        )
        val servedExtra = LinkedHashMap<String, C04CadServedResource>()
        val brepBodies = buildJsonArray {
            var index = 0
            for ((path, resource) in brepByPath) {
                val placements = preview.brepPlacements.filter { it.blobPath == path }
                if (placements.isEmpty()) continue
                val grantPath = "${session.relativePath}/$path"
                val grantToken = core.tokenByPath[grantPath]
                    ?: throw SessionFailure(C04CadFailure.TRANSPORT, "brepGrant")
                val served = C04CadServedResource(
                    name = "brep-${index}.brep",
                    relativePath = grantPath,
                    file = resource.file,
                    byteCount = resource.bytes,
                    sha256 = resource.sha256,
                    mediaType = "application/octet-stream",
                )
                servedExtra[grantToken] = served
                add(buildJsonObject {
                    put("name", placements.first().name.take(C04FloecadLimits.MAX_NAME_CHARS))
                    put("token", grantToken)
                    put("relativePath", path)
                    put("sha256", resource.sha256)
                    put("byteCount", resource.bytes)
                    put("matrices", buildJsonArray {
                        placements.forEach { placement ->
                            add(buildJsonArray {
                                placement.matrix.forEach { add(JsonPrimitive(it)) }
                            })
                        }
                    })
                })
                index += 1
            }
        }
        val manifest = buildManifest(
            core = core,
            main = main,
            mainToken = token,
            sideResources = emptyList(),
            missing = preview.missing,
            format = session.format,
            dark = session.dark,
            packagePreview = preview,
            brepBodies = brepBodies,
        )
        val resourceMap = LinkedHashMap<String, C04CadServedResource>()
        resourceMap[token] = main
        resourceMap.putAll(servedExtra)
        val assets = C04CadAssetSession(
            sessionToken = core.sessionID,
            format = session.format,
            manifest = manifest.toString().toByteArray(Charsets.UTF_8),
            main = main,
            resources = resourceMap,
        )
        synchronized(lock) {
            if (!isCurrentLocked(session)) throw SessionFailure(C04CadFailure.OWNER, "owner")
            session.assets = assets
            registry.register(assets)
            mutableState.value = C04CadViewerState.Rendering(
                session.token, fileName(session.relativePath), session.format,
                preview.missing.toList(),
            )
        }
        withContext(Dispatchers.Main.immediate) {
            val view = surface
            if (view != null && isCurrent(session) && view === surface &&
                session.surfaceLoadedFor !== view
            ) {
                loadSurface(session, view)
            }
        }
    }

    private suspend fun discoverResources(
        session: Session,
        main: WorkspaceOfficeSnapshotStager.Snapshot,
        resources: MutableList<Pair<WorkspaceOfficeSnapshotStager.Snapshot, C04CadResourceDescriptor>>,
        missing: MutableList<String>,
    ) {
        if (main.bytes > C04CadLimits.MAX_PREFLIGHT_BYTES) {
            missing.add("sidecars")
            return
        }
        val bytes = readBounded(main.file, C04CadLimits.MAX_PREFLIGHT_BYTES)
            ?: throw SessionFailure(C04CadFailure.SOURCE, "mainRead")
        val discovery = C04CadResourceResolver.discover(
            session.format, session.relativePath, bytes)
        if (discovery.invalidMainBytes) {
            throw SessionFailure(C04CadFailure.INVALID, "mainBytes", retryable = false)
        }
        if (discovery.unsupportedExtensions.isNotEmpty()) {
            throw SessionFailure(
                C04CadFailure.UNSUPPORTED,
                discovery.unsupportedExtensions.joinToString(",").take(120),
                retryable = false,
            )
        }
        discovery.issues.forEach { missing.add(safeDetail(it.code)) }
        val directory = C04CadResourceResolver.mainDirectory(session.relativePath)
        val pending = ArrayDeque(
            discovery.references.map { PendingReference(it, directory) })
        val stagedPaths = HashSet<String>()
        var totalResourceBytes = 0L
        while (pending.isNotEmpty() && stagedPaths.size < C04CadLimits.MAX_RESOURCES) {
            if (!isCurrent(session)) throw SessionFailure(C04CadFailure.OWNER, "owner")
            val pendingReference = pending.removeFirst()
            val reference = pendingReference.reference
            val resolution = C04CadResourceResolver.resolve(
                reference.raw, pendingReference.baseDirectory)
            if (resolution.isFailure) {
                missing.add(safeDetail((resolution.exceptionOrNull() as? C04CadResolveFailure)?.code ?: "reference"))
                continue
            }
            val resolved = resolution.getOrThrow()
            val extension = C04CadResourceResolver.extensionOf(resolved)
            if (extension !in session.format.resourceExtensions) {
                missing.add(safeDetail(resolved.substringAfterLast('/')))
                continue
            }
            if (!stagedPaths.add(resolved)) continue
            val side = try {
                stager.stage(
                    owner = stagerOwner(session.owner),
                    relativePath = resolved,
                    formats = setOf(extension),
                    maxBytes = minOf(C04CadLimits.MAX_RESOURCE_BYTES, session.format.maxSourceBytes),
                    isCurrent = { isCurrent(session) },
                )
            } catch (error: WorkspaceOfficeSnapshotStager.Failure) {
                if (error.code == "ownerChanged") {
                    throw SessionFailure(C04CadFailure.OWNER, "owner", retryable = false)
                }
                missing.add(safeDetail(resolved.substringAfterLast('/')))
                continue
            }
            session.staged.add(side)
            totalResourceBytes += side.bytes
            if (totalResourceBytes > C04CadLimits.MAX_TOTAL_RESOURCE_BYTES) {
                missing.add("resourceLimit")
                break
            }
            resources.add(side to C04CadResourceDescriptor(
                relativePath = side.logicalPath,
                byteCount = side.bytes,
                sha256 = side.sha256,
                mediaType = c04MimeType(side.logicalPath),
            ))
            if (extension == "mtl" && side.bytes <= C04CadLimits.MAX_MTL_BYTES) {
                val mtlBytes = readBounded(side.file, C04CadLimits.MAX_MTL_BYTES)
                if (mtlBytes != null) {
                    val mtl = C04CadResourceResolver.discoverMtl(mtlBytes)
                    val mtlDirectory = C04CadResourceResolver.mainDirectory(side.logicalPath)
                    mtl.issues.forEach { missing.add(safeDetail(it.code)) }
                    pending.addAll(mtl.references.map { PendingReference(it, mtlDirectory) })
                }
            }
        }
        if (pending.isNotEmpty()) missing.add("resourceLimit")
    }

    // ------------------------------------------------------------------
    // Renderer events
    // ------------------------------------------------------------------

    internal fun onJsEvent(raw: String) {
        if (raw.length.toLong() > C04CadLimits.MAX_CAPTURE_EVENT_BYTES) return
        val objectValue = try {
            json.parseToJsonElement(raw) as? JsonObject
        } catch (_: Throwable) {
            null
        } ?: return
        val sessionToken = objectValue.string("session") ?: return
        val type = objectValue.string("type") ?: return
        val session = active ?: return
        if (session.closed || session.coreSessionID != sessionToken) return
        when (type) {
            "ready" -> {
                val event = objectValue["facts"] as? JsonObject ?: return
                scope.launch { handleReady(session, event) }
            }
            "error" -> {
                val code = objectValue.string("code") ?: "render"
                val detail = safeDetail(objectValue.string("message") ?: code)
                scope.launch { handleRenderFailure(session, code, detail) }
            }
            "capture" -> {
                val requestId = objectValue.string("requestId") ?: return
                val dataUrl = objectValue.string("dataUrl") ?: return
                val width = objectValue.int("width") ?: return
                val height = objectValue.int("height") ?: return
                val frame = objectValue.int("frameSequence") ?: session.facts?.frameSequence ?: 1
                pendingCaptures.remove(requestId)?.complete(
                    C04CadCapturePayload(dataUrl, width, height, frame))
            }
            "captureError" -> {
                val requestId = objectValue.string("requestId") ?: return
                pendingCaptures.remove(requestId)?.completeExceptionally(
                    C04CadCaptureFailure("capture"))
            }
            "notice" -> Unit
            else -> Unit
        }
    }

    private suspend fun handleReady(session: Session, factsObject: JsonObject) {
        try {
            if (!isCurrent(session)) return
            val reportedFormat = factsObject.string("format")
            val nativePreview = session.format == C04CadFormat.FLOECAD &&
                reportedFormat == "glb" && session.packageFacts != null
            if (reportedFormat != session.format.extension && !nativePreview) {
                throw SessionFailure(C04CadFailure.INVALID, "format", retryable = false)
            }
            var facts = parseFacts(session.format, factsObject)
            if (session.format == C04CadFormat.FLOECAD) {
                val preview = session.packageFacts
                    ?: throw SessionFailure(C04CadFailure.INVALID, "package", retryable = false)
                // The adapter rewrites the generic glb/m facts to the native
                // package identity. When the bridge ran, it also converted
                // the ACTUAL rendered bounds from GLB metres back to source
                // millimetres and added the on-device B-Rep counts. If the
                // bridge is unavailable the validated package identity and
                // package-space bounds remain authoritative.
                val bridgeRan = reportedFormat == "floecad"
                facts = if (bridgeRan) {
                    facts.copy(
                        sourceUnits = "mm",
                        displayUnits = preview.displayUnits,
                        missingResourceCount = maxOf(
                            facts.missingResourceCount, preview.missing.size,
                        ).coerceAtMost(512),
                        limitations = facts.limitations.take(512),
                    )
                } else {
                    facts.copy(
                        sourceUnits = "mm",
                        displayUnits = preview.displayUnits,
                        bounds = preview.boundsOrNull() ?: facts.bounds,
                        meshCount = preview.meshCount,
                        triangleCount = preview.triangleCount,
                        vertexCount = preview.vertexCount,
                        missingResourceCount = maxOf(
                            facts.missingResourceCount, preview.missing.size,
                        ).coerceAtMost(512),
                        limitations = (preview.limitations + " " + facts.limitations).take(512),
                    )
                }
            }
            session.facts = facts
            session.renderTimeout?.cancel()
            session.renderTimeout = null
            val coreSession = session.coreSessionID
                ?: throw SessionFailure(C04CadFailure.OWNER, "session")
            client.readiness(coreSession, facts)
            synchronized(lock) {
                if (!isCurrentLocked(session)) return
                mutableState.value = C04CadViewerState.Ready(
                    token = session.token,
                    fileName = fileName(session.relativePath),
                    format = session.format,
                    facts = facts,
                    missingResources = session.missing,
                )
            }
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            handleRenderFailure(session, "readiness", (error as? C04CadHostFailure)?.code ?: "readiness")
        }
    }

    private suspend fun handleRenderFailure(session: Session, code: String, detail: String) {
        if (!isCurrent(session)) return
        val diagnostic = if (code == "emptyViewport" || detail == "emptyViewport") {
            withContext(Dispatchers.Main.immediate) {
                val view = session.boundSurface
                val nativeBounds = "${view?.width ?: 0}x${view?.height ?: 0}"
                val attached = view?.isAttachedToWindow == true
                val result = CompletableDeferred<String>()
                // Only numeric geometry from our fixed local document. No
                // file contents, DOM text, resource URLs or user identifiers.
                if (view != null) runCatching {
                    view.evaluateJavascript("""(() => {
                        const e = document.getElementById('view');
                        const r = e?.getBoundingClientRect();
                        const s = e ? getComputedStyle(e) : null;
                        const number = v => Number.isFinite(Number.parseFloat(v))
                            ? Math.round(Number.parseFloat(v)) : -1;
                        return [innerWidth, innerHeight,
                            document.documentElement.clientWidth, document.documentElement.clientHeight,
                            document.body.clientWidth, document.body.clientHeight,
                            number(r?.width), number(r?.height), document.styleSheets.length,
                            s?.position === 'absolute' ? 1 : s?.position === 'fixed' ? 2 : 0,
                            number(s?.top), number(s?.bottom), number(s?.height), e?.children.length ?? -1
                        ].join(',');
                    })()""") { raw -> result.complete(raw?.removeSurrounding("\"") ?: "unavailable") }
                }.onFailure { result.complete("unavailable") }
                else result.complete("unavailable")
                val geometry = withTimeoutOrNull(750L) { result.await() }
                    ?.takeIf { it.matches(Regex("[-0-9,]{1,90}")) } ?: "unavailable"
                safeDetail("$detail;n=$nativeBounds;a=$attached;w=$geometry")
            }
        } else detail
        if (!isCurrent(session)) return
        val packageOnlyBrep = session.format == C04CadFormat.FLOECAD &&
            (session.packageFacts?.brepOnlyCount ?: 0) > 0 &&
            (session.packageFacts?.meshCount ?: 0) == 0 &&
            detail == "noGeometry"
        val failure = when {
            packageOnlyBrep -> C04CadFailure.UNSUPPORTED
            code == "unsupportedVersion" || code == "coreUnavailable" ->
                C04CadFailure.CORE_UPDATE
            code.contains("Compression", ignoreCase = true) ||
                code == "unsupportedCompression" -> C04CadFailure.UNSUPPORTED
            code.contains("Digest", ignoreCase = true) -> C04CadFailure.INVALID
            else -> C04CadFailure.RENDER
        }
        publishFailure(
            session.owner, session.relativePath, session.format,
            failure, if (packageOnlyBrep) "brepOnly" else diagnostic,
            retryable = failure != C04CadFailure.CORE_UPDATE &&
                failure != C04CadFailure.UNSUPPORTED,
            requestToken = session.token,
        )
        mainHandler.post { destroySurfaceFor(session) }
        retire(session)
    }

    private fun parseFacts(format: C04CadFormat, objectValue: JsonObject): C04CadSceneFacts {
        if (objectValue.boolean("rendered") != true) {
            throw SessionFailure(C04CadFailure.INVALID, "rendered", retryable = false)
        }
        val sourceUnits = objectValue.string("sourceUnits") ?: "unknown"
        val displayUnits = objectValue.string("displayUnits") ?: "unknown"
        if (sourceUnits !in UNITS) {
            throw SessionFailure(C04CadFailure.INVALID, "units", retryable = false)
        }
        if (displayUnits !in UNITS) {
            throw SessionFailure(C04CadFailure.INVALID, "units", retryable = false)
        }
        val bounds = objectValue["bounds"] as? JsonObject
            ?: throw SessionFailure(C04CadFailure.INVALID, "bounds", retryable = false)
        val minimum = bounds.vector("min")
        val maximum = bounds.vector("max")
        val center = bounds.vector("center")
        val radius = bounds.double("radius")
        if (minimum != null && maximum != null) {
            if (minimum.size != 3 || maximum.size != 3 ||
                minimum.indices.any { minimum[it] > maximum[it] }
            ) throw SessionFailure(C04CadFailure.INVALID, "bounds", retryable = false)
        } else if (minimum != null || maximum != null) {
            throw SessionFailure(C04CadFailure.INVALID, "bounds", retryable = false)
        }
        if (center == null && minimum == null) {
            throw SessionFailure(C04CadFailure.INVALID, "bounds", retryable = false)
        }
        val frame = objectValue.int("frameSequence")
            ?: throw SessionFailure(C04CadFailure.INVALID, "frame", retryable = false)
        if (frame < 1) throw SessionFailure(C04CadFailure.INVALID, "frame", retryable = false)
        val meshCount = objectValue.int("meshCount") ?: 0
        val triangleCount = objectValue.int("triangleCount") ?: 0
        val vertexCount = objectValue.int("vertexCount") ?: 0
        val missing = objectValue.int("missingResourceCount") ?: 0
        val limitations = objectValue.string("limitations") ?: ""
        if (meshCount < 0 || triangleCount < 0 || vertexCount < 0 || missing < 0) {
            throw SessionFailure(C04CadFailure.INVALID, "counts", retryable = false)
        }
        return C04CadSceneFacts(
            format = format,
            sourceUnits = sourceUnits,
            displayUnits = displayUnits,
            bounds = C04CadBounds(
                minimum = minimum,
                maximum = maximum,
                center = center,
                radius = radius,
            ),
            entityCount = objectValue.int("entityCount"),
            meshCount = meshCount,
            triangleCount = triangleCount,
            vertexCount = vertexCount,
            missingResourceCount = missing,
            frameSequence = frame,
            limitations = limitations.take(512),
        )
    }

    // ------------------------------------------------------------------
    // WebView surface
    // ------------------------------------------------------------------

    private fun configure(view: WebView, dark: Boolean) {
        view.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = false
            databaseEnabled = false
            allowFileAccess = false
            allowContentAccess = false
            allowFileAccessFromFileURLs = false
            allowUniversalAccessFromFileURLs = false
            javaScriptCanOpenWindowsAutomatically = false
            setSupportMultipleWindows(false)
            cacheMode = android.webkit.WebSettings.LOAD_NO_CACHE
            mediaPlaybackRequiresUserGesture = true
            builtInZoomControls = false
            displayZoomControls = false
            loadWithOverviewMode = false
            useWideViewPort = false
            textZoom = 100
            mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_NEVER_ALLOW
        }
        view.setBackgroundColor(if (dark) 0xFF181E28.toInt() else 0xFFF5F6F8.toInt())
        view.overScrollMode = WebView.OVER_SCROLL_NEVER
        view.isVerticalScrollBarEnabled = false
        view.isHorizontalScrollBarEnabled = false
        view.isLongClickable = false
        view.setOnLongClickListener { true }
        view.addJavascriptInterface(C04CadJsBridge(this), "C04Bridge")
        view.webChromeClient = object : WebChromeClient() {
            override fun onPermissionRequest(request: android.webkit.PermissionRequest?) {
                request?.deny()
            }

            override fun onJsAlert(
                view: WebView?, url: String?, message: String?, result: android.webkit.JsResult?,
            ): Boolean {
                result?.cancel()
                return true
            }

            override fun onJsConfirm(
                view: WebView?, url: String?, message: String?, result: android.webkit.JsResult?,
            ): Boolean {
                result?.cancel()
                return true
            }

            override fun onJsPrompt(
                view: WebView?, url: String?, message: String?, defaultValue: String?,
                result: android.webkit.JsPromptResult?,
            ): Boolean {
                result?.cancel()
                return true
            }
        }
        view.webViewClient = object : WebViewClient() {
            override fun shouldInterceptRequest(
                view: WebView?, request: WebResourceRequest?,
            ): WebResourceResponse? = assetServer.serve(request)

            override fun shouldOverrideUrlLoading(
                view: WebView?, request: WebResourceRequest?,
            ): Boolean = true

            override fun onPageStarted(view: WebView?, url: String?, favicon: android.graphics.Bitmap?) {
                super.onPageStarted(view, url, favicon)
                if (url != null && !url.startsWith(C04CadWebAssetServer.ORIGIN)) {
                    view?.stopLoading()
                }
            }

            override fun onReceivedError(
                view: WebView?, request: WebResourceRequest?, error: WebResourceError?,
            ) {
                super.onReceivedError(view, request, error)
                if (request?.isForMainFrame == true) {
                    onSurfaceFailure("pageError")
                }
            }

            override fun onReceivedHttpError(
                view: WebView?, request: WebResourceRequest?,
                errorResponse: WebResourceResponse?,
            ) {
                super.onReceivedHttpError(view, request, errorResponse)
                if (request?.isForMainFrame == true) {
                    onSurfaceFailure("http${errorResponse?.statusCode ?: 0}")
                }
            }

            override fun onRenderProcessGone(
                view: WebView?, detail: RenderProcessGoneDetail?,
            ): Boolean {
                onSurfaceFailure("rendererGone")
                mainHandler.post {
                    synchronized(lock) {
                        if (surface === view) {
                            surface = null
                            view?.let { destroySurfaceLocked(it) }
                        }
                    }
                }
                return true
            }
        }
    }

    private fun loadSurface(session: Session, view: WebView) {
        val token = session.coreSessionID ?: return
        view.setBackgroundColor(
            if (session.dark) 0xFF181E28.toInt() else 0xFFF5F6F8.toInt())
        session.boundSurface = view
        session.surfaceLoadedFor = view
        synchronized(lock) {
            val current = mutableState.value
            if (current is C04CadViewerState.Ready && current.token == session.token) {
                mutableState.value = C04CadViewerState.Rendering(
                    session.token, fileName(session.relativePath), session.format,
                    session.missing,
                )
            }
        }
        val theme = if (session.dark) "dark" else "light"
        val language = if (Locale.getDefault().language.startsWith("zh")) "zh" else "en"
        session.renderTimeout?.cancel()
        session.renderTimeout = scope.launch {
            kotlinx.coroutines.delay(45_000L)
            if (isCurrent(session) && mutableState.value is C04CadViewerState.Rendering) {
                handleRenderFailure(session, "timeout", "renderTimeout")
            }
        }
        val packageQuery = if (session.format == C04CadFormat.FLOECAD) "&package=1" else ""
        view.loadUrl(
            "${C04CadWebAssetServer.ORIGIN}${C04CadWebAssetServer.VIEWER_PATH}" +
                "?session=$token&theme=$theme&language=$language$packageQuery",
        )
    }

    private fun destroySurfaceFor(session: Session?) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post { destroySurfaceFor(session) }
            return
        }
        synchronized(lock) {
            val view = if (session == null) surface else session.boundSurface
            if (view == null) return
            if (surface === view) surface = null
            if (session != null) {
                if (session.boundSurface === view) session.boundSurface = null
                if (session.surfaceLoadedFor === view) session.surfaceLoadedFor = null
            }
            destroySurfaceLocked(view)
        }
    }

    private fun destroySurfaceLocked(view: WebView) {
        runCatching { view.removeJavascriptInterface("C04Bridge") }
        runCatching { view.stopLoading() }
        runCatching { view.webChromeClient = WebChromeClient() }
        runCatching { view.webViewClient = WebViewClient() }
        runCatching { (view.parent as? ViewGroup)?.removeView(view) }
        runCatching { view.destroy() }
    }

    private fun onSurfaceFailure(code: String) {
        val session = active ?: return
        if (!isCurrent(session)) return
        scope.launch { handleRenderFailure(session, code, code) }
    }

    // ------------------------------------------------------------------
    // Lifecycle / cleanup
    // ------------------------------------------------------------------

    fun onRootStopped() {
        if (currentNativeEpoch() != null) return
        val session = synchronized(lock) {
            val current = active
            active = null
            current?.let(::markClosedLocked)
        }
        mutableState.value = C04CadViewerState.Idle
        registry.clear()
        pendingCaptures.values.forEach {
            it.completeExceptionally(C04CadCaptureFailure("cancelled"))
        }
        pendingCaptures.clear()
        mainHandler.post { destroySurfaceFor(session) }
        scope.launch(ioDispatcher) {
            session?.let { cleanupSession(it) }
            runCatching { client.cancelAll() }
        }
    }

    fun onOwnedStoreReady() {
        val stop = stoppingForEpoch ?: return
        if (currentNativeEpoch() != stop) stoppingForEpoch = null
    }

    suspend fun prepareForRootStop(timeoutMillis: Long = 8_000L): Boolean =
        // RootStop itself must finish even if its caller is being cancelled.
        // The inner withTimeoutOrNull installs its own TimeoutCoroutine; joins
        // therefore remain deadline-bounded (unlike a NonCancellable wrapper
        // *inside* the timeout, which would suppress the deadline).
        withContext(NonCancellable) {
            val session = synchronized(lock) {
                stoppingForEpoch = currentNativeEpoch()
                val current = active
                active = null
                current?.let(::markClosedLocked)
            }
            mutableState.value = C04CadViewerState.Idle
            registry.clear()
            pendingCaptures.values.forEach {
                it.completeExceptionally(C04CadCaptureFailure("cancelled"))
            }
            pendingCaptures.clear()
            withContext(Dispatchers.Main.immediate) { destroySurfaceFor(session) }
            val pending = synchronized(lock) {
                jobs.filter { it !in cleanupOperations }
            }
            pending.forEach { it.cancel() }
            // The join MUST be inside the timeout's cancellable context. A
            // NonCancellable wrapper here would suppress the deadline and make
            // an owned hung job look like a successful stop.
            val joined = try {
                withTimeoutOrNull(timeoutMillis) {
                    pending.forEach { it.join() }
                    true
                } ?: false
            } catch (_: CancellationException) {
                false
            }
            if (!joined) {
                if (session != null) {
                    // Keep a real drain job: it waits for every owned job,
                    // then performs the deferred cleanup. It remains tracked
                    // for a later RootStop/retry if this call times out.
                    trackCleanupJob(scope.launch(ioDispatcher) {
                        pending.forEach { runCatching { it.join() } }
                        awaitOwnedOperations()
                        cleanupSession(session)
                        runCatching { client.cancelAll() }
                    })
                }
                return@withContext false
            }
            session?.let {
                trackCleanupJob(scope.launch(ioDispatcher) {
                    awaitOwnedOperations()
                    cleanupSession(it)
                    runCatching { client.cancelAll() }
                })
            }
            val waits = synchronized(lock) { cleanupOperations.toList() }
            if (waits.isEmpty()) return@withContext true
            try {
                withTimeoutOrNull(timeoutMillis) {
                    waits.forEach { it.join() }
                    true
                } ?: false
            } catch (_: CancellationException) {
                false
            }
        }

    private fun retire(session: Session) {
        cancelOwnedOperations()
        mainHandler.post { destroySurfaceFor(session) }
        trackCleanupJob(scope.launch(ioDispatcher) {
            session.job?.cancelAndJoin()
            // Never delete staged snapshots while an Application-owned
            // capture/export still holds them or their WebView surface.
            awaitOwnedOperations()
            cleanupSession(session)
        })
    }

    private fun cleanupSession(session: Session) {
        previewComponents.releaseCad("cad-view-${session.token}")
        registry.remove(session.coreSessionID ?: "")
        val core = session.coreSessionID
        if (core != null) runCatching { client.end(core) }
        for (snapshot in session.staged) {
            runCatching { snapshot.file.delete() }
            runCatching { snapshot.file.parentFile?.delete() }
        }
        session.staged.clear()
        session.previewDirectory?.let { directory ->
            runCatching { directory.listFiles()?.forEach { it.delete() } }
            runCatching { directory.delete() }
        }
        session.previewDirectory = null
        session.packageFacts = null
        session.assets = null
        session.coreSessionID = null
    }

    private fun markClosedLocked(session: Session): Session {
        session.closed = true
        session.renderTimeout?.cancel()
        session.renderTimeout = null
        return session
    }

    private fun isCurrent(session: Session): Boolean = synchronized(lock) {
        isCurrentLocked(session)
    }

    private fun isCurrentLocked(session: Session): Boolean {
        if (session.closed || active !== session) return false
        if (!ownerCurrent(session.owner)) return false
        val stop = stoppingForEpoch
        if (stop != null && currentNativeEpoch() == stop) return false
        return true
    }

    private fun ownerCurrent(owner: Owner): Boolean =
        owner.nativeEpoch == currentNativeEpoch() &&
            owner.hostGeneration == currentHostGeneration() &&
            !isTemporaryTask(owner.taskID)

    private fun stagerOwner(owner: Owner) = WorkspaceOfficeSnapshotStager.Owner(
        taskID = owner.taskID,
        workspaceID = owner.workspaceID,
        nativeEpoch = owner.nativeEpoch,
        hostGeneration = owner.hostGeneration,
    )

    private fun served(
        snapshot: WorkspaceOfficeSnapshotStager.Snapshot,
        token: String,
    ): Pair<C04CadServedResource, String> {
        val resource = C04CadServedResource(
            name = snapshot.logicalPath.substringAfterLast('/'),
            relativePath = snapshot.logicalPath,
            file = snapshot.file,
            byteCount = snapshot.bytes,
            sha256 = snapshot.sha256,
            mediaType = c04MimeType(snapshot.logicalPath),
        )
        return resource to token
    }

    private fun buildManifest(
        core: C04CadCoreSession,
        main: C04CadServedResource,
        mainToken: String,
        sideResources: List<Pair<C04CadServedResource, String>>,
        missing: List<String>,
        format: C04CadFormat,
        dark: Boolean,
        packagePreview: C04FloecadPreview? = null,
        brepBodies: JsonArray = JsonArray(emptyList()),
    ): JsonObject = buildJsonObject {
        put("session", core.sessionID)
        put("format", if (packagePreview != null) "glb" else format.extension)
        put("sourceFormat", format.extension)
        put("family", format.wireName)
        put("reader", core.reader)
        if (packagePreview != null) {
            put("package", packagePreview.toManifestJson(brepBodies))
        }
        put("main", resourceJson(main, mainToken))
        put("resources", buildJsonArray {
            sideResources.forEach { (resource, token) -> add(resourceJson(resource, token)) }
        })
        put("missing", buildJsonArray { missing.take(12).forEach { add(JsonPrimitive(it)) } })
        put("options", buildJsonObject {
            put("theme", if (dark) "dark" else "light")
            put("language", if (Locale.getDefault().language.startsWith("zh")) "zh" else "en")
        })
        put("limits", buildJsonObject {
            put("maxCaptureEdge", C04CadLimits.MAX_CAPTURE_EDGE)
            put("maxCaptureBytes", C04CadLimits.MAX_CAPTURE_BYTES)
        })
    }

    private fun resourceJson(resource: C04CadServedResource, token: String): JsonObject =
        buildJsonObject {
            put("token", token)
            put("name", resource.name)
            put("relativePath", resource.relativePath)
            put("byteCount", resource.byteCount)
            put("sha256", resource.sha256)
            put("mediaType", resource.mediaType)
        }

    private fun publishFailure(
        owner: Owner,
        relativePath: String,
        format: C04CadFormat?,
        failure: C04CadFailure,
        detail: String?,
        retryable: Boolean,
        requestToken: Long,
    ) {
        synchronized(lock) {
            val current = active
            if (current != null && current.token == requestToken) {
                markClosedLocked(current)
                active = null
            }
            mutableState.value = C04CadViewerState.Failed(
                token = requestToken,
                fileName = fileName(relativePath),
                format = format,
                failure = failure,
                detail = detail?.take(240),
                retryable = retryable,
                owner = owner,
                path = relativePath,
            )
        }
    }

    private fun mapFailure(error: Throwable): SessionFailure = when (error) {
        is SessionFailure -> error
        is WorkspaceOfficeSnapshotStager.Failure -> when (error.code) {
            "ownerChanged" -> SessionFailure(C04CadFailure.OWNER, "owner", retryable = false)
            "contentTooLarge" -> SessionFailure(C04CadFailure.TOO_LARGE, "size", retryable = false)
            "invalidOfficePath" -> SessionFailure(C04CadFailure.INVALID, "path", retryable = false)
            else -> SessionFailure(C04CadFailure.SOURCE, error.code.take(120))
        }
        is C04FloecadFailure -> when (error.code) {
            "ownerChanged" -> SessionFailure(C04CadFailure.OWNER, "owner", retryable = false)
            "previewTooLarge" -> SessionFailure(C04CadFailure.TOO_LARGE, error.detail, retryable = false)
            "resourceMissing" -> SessionFailure(C04CadFailure.RESOURCE, error.detail)
            "unsupportedPackage" -> SessionFailure(C04CadFailure.UNSUPPORTED, error.detail, retryable = false)
            "brepOnly" -> SessionFailure(C04CadFailure.UNSUPPORTED, "brepOnly", retryable = false)
            else -> SessionFailure(C04CadFailure.INVALID, error.detail, retryable = false)
        }
        is C04CadHostFailure -> when (error.code) {
            "unsupportedVersion", "coreUnavailable" ->
                SessionFailure(C04CadFailure.CORE_UPDATE, error.code, retryable = false)
            "sourceTooLarge" -> SessionFailure(C04CadFailure.TOO_LARGE, "size", retryable = false)
            "invalidPath", "formatMismatch", "unknownFormat", "invalidDigest" ->
                SessionFailure(C04CadFailure.INVALID, error.code, retryable = false)
            "resourceOutsideScope", "resourceLimit", "resourceTooLarge",
            "resourceDuplicate", "resourceExtension", "invalidMediaType" ->
                SessionFailure(C04CadFailure.RESOURCE, error.code)
            else -> SessionFailure(C04CadFailure.TRANSPORT, error.code.take(120))
        }
        else -> SessionFailure(C04CadFailure.RENDER, error.message?.take(120))
    }

    private fun decodeDataUrl(dataUrl: String): ByteArray {
        val prefix = "data:image/png;base64,"
        if (!dataUrl.startsWith(prefix, ignoreCase = true)) {
            throw C04CadCaptureFailure("dataUrl")
        }
        val encoded = dataUrl.substring(prefix.length)
        if (encoded.length.toLong() > C04CadLimits.MAX_CAPTURE_EVENT_BYTES) {
            throw C04CadCaptureFailure("captureSize")
        }
        return try {
            Base64.decode(encoded, Base64.NO_WRAP)
        } catch (_: IllegalArgumentException) {
            throw C04CadCaptureFailure("base64")
        }.also {
            if (it.size.toLong() > C04CadLimits.MAX_CAPTURE_BYTES) {
                throw C04CadCaptureFailure("captureSize")
            }
        }
    }

    private fun readBounded(file: File, maximum: Long): ByteArray? {
        if (!file.isFile || file.length() > maximum) return null
        return try {
            FileInputStream(file).use { input ->
                val output = java.io.ByteArrayOutputStream(minOf(file.length(), maximum).toInt())
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val read = input.read(buffer)
                    if (read <= 0) break
                    output.write(buffer, 0, read)
                    if (output.size().toLong() > maximum) return null
                }
                output.toByteArray()
            }
        } catch (_: Throwable) {
            null
        }
    }

    /** Runs capture/export on the Application-owned scope, not the caller's
     * Compose coroutine. `await` cancellation therefore does not cancel the
     * owned work; RootStop/close can cancel and join it explicitly. */
    private suspend fun <T> owned(block: suspend () -> T): T {
        val deferred = scope.async(ioDispatcher) { block() }
        synchronized(lock) { ownedOperations.add(deferred) }
        deferred.invokeOnCompletion {
            synchronized(lock) { ownedOperations.remove(deferred) }
        }
        trackJob(deferred)
        return deferred.await()
    }

    private fun cancelOwnedOperations() {
        val operations = synchronized(lock) { ownedOperations.toList() }
        operations.forEach { it.cancel() }
    }

    private suspend fun awaitOwnedOperations() {
        while (true) {
            val operations = synchronized(lock) { ownedOperations.toList() }
            operations.forEach { it.join() }
            if (synchronized(lock) { ownedOperations.isEmpty() }) return
        }
    }

    private fun trackJob(job: Job): Job {
        synchronized(lock) { jobs.add(job) }
        job.invokeOnCompletion { synchronized(lock) { jobs.remove(job) } }
        return job
    }

    private fun trackCleanupJob(job: Job): Job {
        synchronized(lock) { cleanupOperations.add(job) }
        job.invokeOnCompletion { synchronized(lock) { cleanupOperations.remove(job) } }
        return trackJob(job)
    }

    private fun fileName(path: String): String = path.substringAfterLast('/')

    private fun isDark(): Boolean =
        (context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
            Configuration.UI_MODE_NIGHT_YES

    private fun safeDetail(value: String): String =
        value.filter { it.code in 32..126 || it.code in 0x4E00..0x9FFF }
            .take(120)
            .ifBlank { "resource" }

    private fun quote(value: String): String = buildString {
        append('\'')
        for (char in value) {
            when (char) {
                '\\' -> append("\\\\")
                '\'' -> append("\\'")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                else -> if (char.code in 32..126) append(char)
            }
        }
        append('\'')
    }

    private fun JsonObject.string(key: String): String? =
        (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

    private fun JsonObject.int(key: String): Int? =
        (this[key] as? JsonPrimitive)?.intOrNull

    private fun JsonObject.boolean(key: String): Boolean? =
        (this[key] as? JsonPrimitive)?.booleanOrNull

    private fun JsonObject.vector(key: String): List<Double>? {
        val array = this[key] as? JsonArray ?: return null
        val values = array.map { (it as? JsonPrimitive)?.contentOrNull?.toDoubleOrNull() }
        val numbers = ArrayList<Double>(values.size)
        for (value in values) {
            if (value == null || !value.isFinite() || kotlin.math.abs(value) > 1e12) {
                return null
            }
            numbers.add(value)
        }
        return numbers
    }

    private fun JsonObject.double(key: String): Double? =
        (this[key] as? JsonPrimitive)?.contentOrNull?.toDoubleOrNull()

    companion object {
        private val UNITS = setOf("mm", "cm", "m", "in", "ft", "yd", "unknown")
        private val C04_CAD_COMMANDS = setOf(
            "zoomIn", "zoomOut", "fit", "reset",
            "orbitLeft", "orbitRight", "orbitUp", "orbitDown",
            "panLeft", "panRight", "panUp", "panDown",
        )
    }
}

internal class C04CadJsBridge(
    private val controller: C04CadViewerController,
) {
    @JavascriptInterface
    fun postEvent(json: String) {
        controller.onJsEvent(json)
    }
}
