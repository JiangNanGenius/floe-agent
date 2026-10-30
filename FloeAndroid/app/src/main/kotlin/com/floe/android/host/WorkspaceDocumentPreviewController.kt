// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import com.floe.android.core.notesmedia.pdf.PdfPassword
import com.floe.android.core.notesmedia.pdf.PdfPasswordCapability
import com.floe.android.core.notesmedia.pdf.PdfPasswordSupport
import com.floe.android.core.officeengine.pdf.OfficePdfRenderFence
import com.floe.android.core.officeengine.pdf.OfficePdfRenderHost
import com.floe.android.core.officeengine.pdf.OfficePdfRendererContract
import com.floe.android.core.officeengine.pdf.OfficePdfVerifiedSource
import com.floe.android.core.officeengine.pdf.PdfDocResult
import com.floe.android.core.officeengine.pdf.PdfFailure
import com.floe.android.core.officeengine.pdf.PdfPageResult
import com.floe.android.notesplatform.NotesPdfPasswordPromptBroker
import java.io.File
import java.io.FileInputStream
import java.util.Locale
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/** The two real document families that can be presented full-window from a
 * verified workspace snapshot in this batch. Everything else keeps its
 * honest typed cover. */
internal enum class WorkspacePreviewKind { PDF, IMAGE }

/**
 * Immutable presentation contract for the ONE live workspace document
 * preview. The controller publishes it; the Compose surface only renders it.
 * No state contains a workspace host path, a renderer ticket or a model
 * identity. [Failed] carries the captured owner/path internally so an
 * explicit retry can restart the SAME request; ordinary UI ignores them.
 */
internal sealed interface WorkspacePreviewState {
    data object Idle : WorkspacePreviewState

    data class Opening(
        val token: Long,
        val fileName: String,
        val kind: WorkspacePreviewKind,
    ) : WorkspacePreviewState

    data class Pdf(
        val token: Long,
        val fileName: String,
        val pageCount: Int,
        val pageIndex: Int,
        val zoomPercent: Int,
        val pages: Map<Int, Page>,
    ) : WorkspacePreviewState

    data class Image(
        val token: Long,
        val fileName: String,
        val bitmap: Bitmap,
        val widthPx: Int,
        val heightPx: Int,
        val zoomPercent: Int,
    ) : WorkspacePreviewState

    data class PasswordRequired(
        val token: Long,
        val fileName: String,
    ) : WorkspacePreviewState

    data class Failed(
        val token: Long,
        val fileName: String,
        val kind: WorkspacePreviewKind,
        val failure: Failure,
        val retryable: Boolean,
        internal val owner: Owner,
        internal val path: String,
    ) : WorkspacePreviewState

    sealed interface Page {
        data object Loading : Page
        data class Ready(val bitmap: Bitmap, val widthPx: Int, val heightPx: Int) : Page
        data class Failed(val retryable: Boolean) : Page
    }

    enum class Failure {
        /** The captured task/workspace/epoch/generation retired. */
        OWNER,
        /** The verified workspace egress or its storage failed. */
        SOURCE,
        TOO_LARGE,
        /** Declared PDF/image bytes did not prove out, or the renderer refused. */
        INVALID,
        UNSUPPORTED,
        PASSWORD_REQUIRED,
        PASSWORD_REJECTED,
        PASSWORD_UNSUPPORTED,
        /** Isolated renderer transport/binding fault; retryable. */
        TRANSPORT,
        /** One page render failed; retryable. */
        RENDER,
    }
}

internal data class Owner(
    val taskID: String,
    val workspaceID: String,
    val nativeEpoch: Long,
    val hostGeneration: Long,
) {
    init {
        require(UUID.fromString(taskID).toString().equals(taskID, true))
        require(UUID.fromString(workspaceID).toString().equals(workspaceID, true))
        require(nativeEpoch > 0 && hostGeneration >= 0)
    }
}

/**
 * Pure, JVM-testable preview policy: extension purpose, PDF magic, bounded
 * raster sampling and the page/zoom limits. No Android type is touched here;
 * the controller only performs the actions these answers authorize.
 */
internal object WorkspaceDocumentPreviewPolicy {
    val PDF_FORMAT_EXTENSIONS: Set<String> = setOf("pdf")

    /**
     * Only formats a real BitmapFactory decoder is allowed to attempt. HEIF
     * stays in the attempt set because API 28+ BitmapFactory often decodes
     * it; a device without the decoder fails honestly through the typed
     * unsupported state instead of the app claiming support.
     */
    val IMAGE_FORMAT_EXTENSIONS: Set<String> = setOf(
        "png", "jpg", "jpeg", "webp", "gif", "bmp", "heic", "heif",
    )

    /** Routed to IMAGE by the shared classifier but explicitly NOT claimed:
     * SVG/TIFF have no decoder in this App and stay on the typed cover. */
    val UNSUPPORTED_IMAGE_EXTENSIONS: Set<String> = setOf("svg", "tiff", "tif")

    /** One image snapshot cap: below the generic 256 MiB egress cap because
     * preview decoding is a bounded screen operation, not a document copy. */
    const val MAX_IMAGE_BYTES: Long = 64L shl 20

    /** Longest decoded edge. */
    const val MAX_IMAGE_EDGE_PX: Int = 4096

    /** Total decoded pixels (≈48 MB as ARGB_8888). */
    const val MAX_IMAGE_PIXELS: Long = 12_000_000L

    const val MIN_IMAGE_EDGE_PX: Int = 64

    /** Sampling never exceeds this; absurd claims fail the decode instead. */
    const val MAX_IMAGE_SAMPLE: Int = 4096

    const val MAX_PASSWORD_ATTEMPTS: Int = 3

    private const val PDF_MAGIC_SIZE = 5

    /** The bounded on-screen zoom table (all inside the renderer's 25..400). */
    val ZOOM_PERCENTS: List<Int> = listOf(50, 75, 100, 150, 200, 300)
    const val DEFAULT_ZOOM_INDEX: Int = 2

    fun kindForPath(relativePath: String): WorkspacePreviewKind? =
        when (extensionOf(relativePath)) {
            in PDF_FORMAT_EXTENSIONS -> WorkspacePreviewKind.PDF
            in IMAGE_FORMAT_EXTENSIONS -> WorkspacePreviewKind.IMAGE
            else -> null
        }

    fun isUnsupportedImage(relativePath: String): Boolean =
        extensionOf(relativePath) in UNSUPPORTED_IMAGE_EXTENSIONS

    fun formatsFor(kind: WorkspacePreviewKind): Set<String> = when (kind) {
        WorkspacePreviewKind.PDF -> PDF_FORMAT_EXTENSIONS
        WorkspacePreviewKind.IMAGE -> IMAGE_FORMAT_EXTENSIONS
    }

    fun maxBytesFor(kind: WorkspacePreviewKind): Long = when (kind) {
        WorkspacePreviewKind.PDF -> WorkspaceOfficeSnapshotStager.MAX_BYTES
        WorkspacePreviewKind.IMAGE -> MAX_IMAGE_BYTES
    }

    /** Reads the real first bytes of the OWNED immutable snapshot. */
    fun hasPdfMagic(file: File): Boolean {
        if (!file.isFile || file.length() < PDF_MAGIC_SIZE) return false
        val header = ByteArray(PDF_MAGIC_SIZE)
        val read = runCatching {
            FileInputStream(file).use { input ->
                var offset = 0
                while (offset < header.size) {
                    val count = input.read(header, offset, header.size - offset)
                    if (count <= 0) return@use offset
                    offset += count
                }
                offset
            }
        }.getOrDefault(0)
        return read == header.size && isPdfMagic(header)
    }

    fun isPdfMagic(header: ByteArray): Boolean =
        header.size >= PDF_MAGIC_SIZE &&
            header[0] == '%'.code.toByte() &&
            header[1] == 'P'.code.toByte() &&
            header[2] == 'D'.code.toByte() &&
            header[3] == 'F'.code.toByte() &&
            header[4] == '-'.code.toByte()

    /**
     * Power-of-two sampling that keeps BOTH the longest edge and total
     * pixels inside the fixed bounds. A non-positive claim returns 1; the
     * decoder then fails honestly instead of allocating from a forged size.
     */
    fun imageSampleSize(
        width: Int,
        height: Int,
        maxEdgePx: Int = MAX_IMAGE_EDGE_PX,
        maxPixels: Long = MAX_IMAGE_PIXELS,
    ): Int {
        if (width <= 0 || height <= 0) return 1
        val edge = maxEdgePx.coerceAtLeast(MIN_IMAGE_EDGE_PX)
        val pixels = maxPixels.coerceAtLeast(1L)
        var sample = 1
        while (sample < MAX_IMAGE_SAMPLE) {
            val w = (width / sample).toLong()
            val h = (height / sample).toLong()
            if (w >= 1L && h >= 1L && maxOf(w, h) <= edge.toLong() && w * h <= pixels) {
                return sample
            }
            sample *= 2
        }
        return sample
    }

    fun validPdfPageCount(count: Int): Boolean = count in 1..OfficePdfRendererContract.MAX_PAGE_INDEX

    fun validPdfPage(pageIndex: Int, pageCount: Int): Boolean = pageIndex in 0 until pageCount

    fun clampZoomIndex(index: Int): Int = index.coerceIn(0, ZOOM_PERCENTS.lastIndex)

    fun zoomPercent(index: Int): Int = ZOOM_PERCENTS[clampZoomIndex(index)]

    fun zoomIndexFor(percent: Int): Int =
        ZOOM_PERCENTS.indexOf(percent).takeIf { it >= 0 } ?: DEFAULT_ZOOM_INDEX

    fun nextZoomIndex(index: Int, delta: Int): Int =
        (index + delta).coerceIn(0, ZOOM_PERCENTS.lastIndex)

    /** Maps the stager's typed refusals to the ordinary UI decision. */
    fun failureFor(error: Throwable): WorkspacePreviewState.Failure = when {
        error is WorkspaceOfficeSnapshotStager.Failure && error.code == "ownerChanged" ->
            WorkspacePreviewState.Failure.OWNER
        error is WorkspaceOfficeSnapshotStager.Failure && error.code == "contentTooLarge" ->
            WorkspacePreviewState.Failure.TOO_LARGE
        else -> WorkspacePreviewState.Failure.SOURCE
    }

    fun retryable(failure: WorkspacePreviewState.Failure): Boolean = when (failure) {
        WorkspacePreviewState.Failure.TRANSPORT,
        WorkspacePreviewState.Failure.RENDER,
        WorkspacePreviewState.Failure.PASSWORD_REQUIRED,
        -> true
        else -> false
    }

    private fun extensionOf(relativePath: String): String =
        relativePath.substringAfterLast('/').substringAfterLast('.', "").lowercase(Locale.ROOT)
}

/**
 * Application-owned read-only preview of ONE workspace PDF or raster image.
 *
 * Chain (all EXISTING verified components, no Native/Gradle change):
 *  1. the UI passes only the already-owned task/workspace/path identity;
 *     [WorkspaceOfficeSnapshotStager] streams the file through the existing
 *     native `export` egress into a random immutable App-owned snapshot
 *     (exact length + whole-stream SHA + clean EOF; purpose and cap are
 *     closed caller inputs);
 *  2. PDF: the real `%PDF-` header is proved on the snapshot copy, then the
 *     SAME isolated [OfficePdfRenderHost] used by Office/Notes parses it
 *     through an FD-only renderer and reports the REAL page count; protected
 *     PDFs reuse [PdfPasswordSupport] + the owner-gated RAM-only
 *     [NotesPdfPasswordPromptBroker] instead of a new prompt/vault;
 *  3. image: only a real BitmapFactory-decodable raster is accepted, with a
 *     fixed input cap and bounds-first power-of-two sampling (never a raw
 *     bitmap of the claimed dimensions);
 *  4. the snapshot is deleted only after the renderer has reported real
 *     quiescence; a late bitmap/page callback is dropped and recycled, never
 *     painted for another request.
 *
 * One controller lives in the Application-owned [RuntimeHost]; rotation
 * reuses the live session (`open` with the same request token is a no-op),
 * while task/root/generation change, explicit close and root-stop retire it.
 */
internal class WorkspaceDocumentPreviewController internal constructor(
    private val root: File,
    private val scope: CoroutineScope,
    private val ioDispatcher: CoroutineDispatcher,
    private val currentNativeEpoch: () -> Long?,
    private val currentHostGeneration: () -> Long,
    private val isTemporaryTask: (String) -> Boolean,
    admitsPasswordPrompt: () -> Boolean,
    private val pdfPortFactory: () -> WorkspacePreviewPdfPort,
    private val stager: WorkspaceOfficeSnapshotStager = WorkspaceOfficeSnapshotStager(root),
) {
    /** Production wiring: the Application data dir plus the REAL isolated
     * renderer host; tests inject the root, stager channel and PDF port. */
    internal constructor(
        context: Context,
        scope: CoroutineScope,
        ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
        currentNativeEpoch: () -> Long?,
        currentHostGeneration: () -> Long,
        isTemporaryTask: (String) -> Boolean,
        admitsPasswordPrompt: () -> Boolean,
    ) : this(
        root = File(context.applicationContext.applicationInfo.dataDir, "files/WorkspaceDocumentPreview"),
        scope = scope,
        ioDispatcher = ioDispatcher,
        currentNativeEpoch = currentNativeEpoch,
        currentHostGeneration = currentHostGeneration,
        isTemporaryTask = isTemporaryTask,
        admitsPasswordPrompt = admitsPasswordPrompt,
        pdfPortFactory = { ServicePdfSession(OfficePdfRenderHost(context.applicationContext)) },
    )

    private val lock = Any()

    /** The owner-gated RAM-only prompt; the UI reuses the existing dialog. */
    internal val passwordPrompts = NotesPdfPasswordPromptBroker(admitsPasswordPrompt)

    private val mutableState = MutableStateFlow<WorkspacePreviewState>(WorkspacePreviewState.Idle)
    val state: StateFlow<WorkspacePreviewState> = mutableState

    private val addressFence = OfficePdfRenderFence()
    private var active: Session? = null
    private var pendingCleanups = 0
    /** Every controller-owned staging/prompt job, including jobs of a session
     * that was replaced, failed or closed. A root drain joins these before it
     * retires anything so no late stage/decode/prompt can outlive the root. */
    private val pendingJobs = LinkedHashSet<Job>()
    /** Releases whose renderer quiescence was never proved. Their snapshot and
     * password stay retained, and the drain can never claim clean. */
    private val blockedRetirements = ArrayList<Retired>()
    private val cleanupSignal = MutableStateFlow(0)
    /** Set while a root-stop drain owns this controller; a late open from a
     * queued UI callback must not start a new read after the drain check.
     * Cleared only by a REAL new accepted store generation. */
    @Volatile private var stoppingForEpoch: Long? = null

    private class Session(
        val token: Long,
        val owner: Owner,
        val relativePath: String,
        val kind: WorkspacePreviewKind,
        val renderFence: OfficePdfRenderFence = OfficePdfRenderFence(),
    ) {
        var generation: Long = 0L
        var job: Job? = null
        var promptJob: Job? = null
        var snapshot: WorkspaceOfficeSnapshotStager.Snapshot? = null
        var source: OfficePdfVerifiedSource? = null
        var pdf: WorkspacePreviewPdfPort? = null
        var image: Bitmap? = null
        var password: PdfPassword? = null
        var passwordAttempts: Int = 0
        var closed: Boolean = false
        var failed: Boolean = false
    }

    private class Retired(
        val snapshot: File?,
        val pdf: WorkspacePreviewPdfPort?,
        val password: PdfPassword?,
    )

    private val fileNameOf: (String) -> String = { it.substringAfterLast('/') }

    // ------------------------------------------------------------------
    // Public UI contract
    // ------------------------------------------------------------------

    /**
     * Idempotent open for one explicit full-window request. The SAME request
     * token + owner + path + kind never stages or renders twice (rotation);
     * a different token/identity replaces the previous session. Returns true
     * when this request is the live one.
     */
    fun open(owner: Owner, relativePath: String, kind: WorkspacePreviewKind, token: Long): Boolean =
        begin(owner, relativePath, kind, token, force = false)

    private fun begin(
        owner: Owner,
        relativePath: String,
        kind: WorkspacePreviewKind,
        token: Long,
        force: Boolean,
    ): Boolean {
        var previous: Retired? = null
        synchronized(lock) {
            val stopEpoch = stoppingForEpoch
            if (stopEpoch != null && (currentNativeEpoch() ?: 0L) == stopEpoch) {
                mutableState.value = WorkspacePreviewState.Failed(
                    token = token,
                    fileName = fileNameOf(relativePath),
                    kind = kind,
                    failure = WorkspacePreviewState.Failure.OWNER,
                    retryable = false,
                    owner = owner,
                    path = relativePath,
                )
                return false
            }
            val existing = active
            if (!force && existing != null && existing.token == token &&
                existing.owner == owner && existing.relativePath == relativePath &&
                existing.kind == kind
            ) {
                return true
            }
            previous = existing?.let(::markRetiredLocked)
            val session = Session(token, owner, relativePath, kind)
            session.generation = addressFence.bump()
            session.renderFence.bump()
            active = session
            mutableState.value = WorkspacePreviewState.Opening(token, fileNameOf(relativePath), kind)
            session.job = trackJob(scope.launch(ioDispatcher) { stageAndProve(session) })
        }
        previous?.let(::releaseRetired)
        return true
    }

    /** Explicit user close/back: drop the UI state at once, then release. */
    fun close(token: Long) {
        val retired: Retired?
        synchronized(lock) {
            val session = active ?: return
            if (session.token != token) return
            retired = markRetiredLocked(session)
            mutableState.value = WorkspacePreviewState.Idle
        }
        passwordPrompts.cancelPending()
        retired?.let(::releaseRetired)
    }

    fun selectPage(token: Long, pageIndex: Int) {
        val session: Session
        synchronized(lock) {
            session = active ?: return
            if (session.closed || session.failed || session.token != token) return
            val current = mutableState.value as? WorkspacePreviewState.Pdf ?: return
            if (current.token != token || !WorkspaceDocumentPreviewPolicy.validPdfPage(pageIndex, current.pageCount)) return
            if (pageIndex == current.pageIndex) return
            session.renderFence.bump()
            mutableState.value = current.copy(pageIndex = pageIndex, pages = emptyMap())
        }
        requestCurrentPage(session)
    }

    fun setZoom(token: Long, zoomPercent: Int) {
        val session: Session
        synchronized(lock) {
            session = active ?: return
            if (session.closed || session.failed || session.token != token) return
            val current = when (val value = mutableState.value) {
                is WorkspacePreviewState.Pdf -> {
                    if (value.token != token) return
                    value.copy(zoomPercent = WorkspaceDocumentPreviewPolicy.zoomPercent(
                        WorkspaceDocumentPreviewPolicy.zoomIndexFor(zoomPercent)), pages = emptyMap())
                }
                is WorkspacePreviewState.Image -> {
                    if (value.token != token) return
                    value.copy(zoomPercent = WorkspaceDocumentPreviewPolicy.zoomPercent(
                        WorkspaceDocumentPreviewPolicy.zoomIndexFor(zoomPercent)))
                }
                else -> return
            }
            if (current == mutableState.value) return
            if (current is WorkspacePreviewState.Pdf) session.renderFence.bump()
            mutableState.value = current
        }
        if (mutableState.value is WorkspacePreviewState.Pdf) requestCurrentPage(session)
    }

    fun retryPage(token: Long) {
        val session: Session
        synchronized(lock) {
            session = active ?: return
            if (session.closed || session.failed || session.token != token) return
            if ((mutableState.value as? WorkspacePreviewState.Pdf)?.token != token) return
        }
        requestCurrentPage(session)
    }

    /** Explicit retry of a retryable document-level failure. */
    fun retry(token: Long) {
        var owner: Owner? = null
        var path: String? = null
        var kind: WorkspacePreviewKind? = null
        synchronized(lock) {
            val failed = mutableState.value as? WorkspacePreviewState.Failed ?: return
            if (failed.token != token || !failed.retryable) return
            owner = failed.owner
            path = failed.path
            kind = failed.kind
        }
        begin(owner ?: return, path ?: return, kind ?: return, token, force = true)
    }

    /** A real new accepted root generation re-admits explicit opens after a
     * completed stop/rebind cycle. Called by the Application-owned host only. */
    internal fun onOwnedStoreReady() {
        stoppingForEpoch = null
    }

    /** True only when this request is the currently published preview. */
    fun isPresenting(token: Long): Boolean = mutableState.value.tokenOrNull() == token

    /**
     * Root-stop drain: cancels a still-staging read, retires the live
     * renderer, and waits for the real snapshot-deletion quiescence. Returns
     * false when that proof could not be obtained in [timeoutMs]; the old
     * generation then stays honestly pending and no directory is invented as
     * cleaned.
     */
    suspend fun prepareForRootStop(timeoutMs: Long): Boolean {
        stoppingForEpoch = currentNativeEpoch() ?: 0L
        passwordPrompts.cancelPending()
        var retired: Retired? = null
        val jobs: List<Job>
        synchronized(lock) {
            val session = active
            if (session != null) {
                retired = markRetiredLocked(session)
            }
            // Every still-running staging/decode/prompt (including those of a
            // session that was already replaced or failed) must return before
            // its native ticket and snapshot work are treated as gone.
            jobs = pendingJobs.toList()
            mutableState.value = if (session != null) {
                // The root is going away: publish the truthful strong-owner
                // failure so the open dialog returns to the file list rather
                // than leaving a spinner over a retired generation.
                WorkspacePreviewState.Failed(
                    token = session.token,
                    fileName = fileNameOf(session.relativePath),
                    kind = session.kind,
                    failure = WorkspacePreviewState.Failure.OWNER,
                    retryable = false,
                    owner = session.owner,
                    path = session.relativePath,
                )
            } else {
                WorkspacePreviewState.Idle
            }
        }
        val joined = if (jobs.isEmpty()) {
            true
        } else {
            withTimeoutOrNull(timeoutMs) {
                jobs.forEach { it.cancelAndJoin() }
                true
            } != null
        }
        // Fail closed: an unjoined stage/prompt still owns work at the native
        // root. Retain the retired renderer/source instead of losing its only
        // reference, and keep every later drain false.
        if (!joined) {
            retired?.let { blocked ->
                synchronized(lock) { blockedRetirements += blocked }
            }
            return false
        }
        retired?.let(::releaseRetired)
        // A renderer release fault keeps its snapshot retained forever; the
        // root drain must never report a clean stop it could not prove.
        if (drainBlocked()) return false
        return withTimeoutOrNull(timeoutMs) {
            cleanupSignal.first { it == 0 }
            true
        } ?: false
    }

    // ------------------------------------------------------------------
    // Staging / type proof
    // ------------------------------------------------------------------

    private suspend fun stageAndProve(session: Session) {
        try {
            val snapshot = stager.stage(
                owner = stagerOwner(session.owner),
                relativePath = session.relativePath,
                formats = WorkspaceDocumentPreviewPolicy.formatsFor(session.kind),
                maxBytes = WorkspaceDocumentPreviewPolicy.maxBytesFor(session.kind),
                isCurrent = { sessionAlive(session) },
            )
            if (!adopt(session, snapshot)) {
                purge(snapshot.file)
                return
            }
            when (session.kind) {
                WorkspacePreviewKind.PDF -> provePdf(session, snapshot)
                WorkspacePreviewKind.IMAGE -> decodeImage(session, snapshot)
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            fail(session, WorkspaceDocumentPreviewPolicy.failureFor(error))
        }
    }

    private fun provePdf(session: Session, snapshot: WorkspaceOfficeSnapshotStager.Snapshot) {
        if (!WorkspaceDocumentPreviewPolicy.hasPdfMagic(snapshot.file)) {
            fail(session, WorkspacePreviewState.Failure.INVALID)
            return
        }
        val source = object : OfficePdfVerifiedSource {
            override val readableFile: File = snapshot.file
            override val expectedSha256: String = snapshot.sha256
            override val expectedBytes: Long = snapshot.bytes
        }
        val pdf = pdfPortFactory()
        val current = synchronized(lock) {
            if (!sessionUsableLocked(session)) {
                false
            } else {
                session.source = source
                session.pdf = pdf
                true
            }
        }
        if (!current) {
            pdf.release(null)
            return
        }
        try {
            pdf.documentInfo(source, null) { result -> onDocumentInfo(session, result) }
        } catch (_: Throwable) {
            fail(session, WorkspacePreviewState.Failure.TRANSPORT)
        }
    }

    private fun decodeImage(session: Session, snapshot: WorkspaceOfficeSnapshotStager.Snapshot) {
        if (snapshot.bytes > WorkspaceDocumentPreviewPolicy.MAX_IMAGE_BYTES) {
            fail(session, WorkspacePreviewState.Failure.TOO_LARGE)
            return
        }
        val decoded = decodeBounded(snapshot.file)
        if (decoded == null) {
            fail(session, WorkspacePreviewState.Failure.UNSUPPORTED)
            return
        }
        synchronized(lock) {
            if (!sessionUsableLocked(session)) {
                recycle(decoded.bitmap)
                return
            }
            session.image = decoded.bitmap
            mutableState.value = WorkspacePreviewState.Image(
                token = session.token,
                fileName = fileNameOf(session.relativePath),
                bitmap = decoded.bitmap,
                widthPx = decoded.widthPx,
                heightPx = decoded.heightPx,
                zoomPercent = WorkspaceDocumentPreviewPolicy.zoomPercent(
                    WorkspaceDocumentPreviewPolicy.DEFAULT_ZOOM_INDEX),
            )
        }
    }

    private class Decoded(val bitmap: Bitmap, val widthPx: Int, val heightPx: Int)

    /**
     * Bounds first, then one sampled BitmapFactory decode. This never trusts
     * the extension or the claimed size: the decoder must really return a
     * bitmap, and its post-decode dimensions are re-checked against the same
     * caps. A decoder that rejects the bytes (unsupported HEIF profile,
     * corrupt data, absurd dimensions) returns null, never an empty claim.
     */
    private fun decodeBounded(file: File): Decoded? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        runCatching { BitmapFactory.decodeFile(file.absolutePath, bounds) }
        val width = bounds.outWidth
        val height = bounds.outHeight
        if (width <= 0 || height <= 0) return null
        val sample = WorkspaceDocumentPreviewPolicy.imageSampleSize(width, height)
        val options = BitmapFactory.Options().apply {
            inSampleSize = sample
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        val bitmap = runCatching { BitmapFactory.decodeFile(file.absolutePath, options) }
            .getOrNull() ?: return null
        if (bitmap.isRecycled || bitmap.width <= 0 || bitmap.height <= 0 ||
            maxOf(bitmap.width, bitmap.height) > WorkspaceDocumentPreviewPolicy.MAX_IMAGE_EDGE_PX ||
            bitmap.width.toLong() * bitmap.height.toLong() >
            WorkspaceDocumentPreviewPolicy.MAX_IMAGE_PIXELS
        ) {
            recycle(bitmap)
            return null
        }
        return Decoded(bitmap, bitmap.width, bitmap.height)
    }

    // ------------------------------------------------------------------
    // PDF document/page flow
    // ------------------------------------------------------------------

    private fun onDocumentInfo(session: Session, result: PdfDocResult) {
        if (!sessionUsable(session)) return
        when (result) {
            is PdfDocResult.Ready -> {
                if (!WorkspaceDocumentPreviewPolicy.validPdfPageCount(result.pageCount)) {
                    fail(session, WorkspacePreviewState.Failure.INVALID)
                    return
                }
                synchronized(lock) {
                    if (!sessionUsableLocked(session)) return
                    mutableState.value = WorkspacePreviewState.Pdf(
                        token = session.token,
                        fileName = fileNameOf(session.relativePath),
                        pageCount = result.pageCount,
                        pageIndex = 0,
                        zoomPercent = WorkspaceDocumentPreviewPolicy.zoomPercent(
                            WorkspaceDocumentPreviewPolicy.DEFAULT_ZOOM_INDEX),
                        pages = emptyMap(),
                    )
                }
                requestCurrentPage(session)
            }
            is PdfDocResult.Failed -> when (result.failure) {
                PdfFailure.PasswordProtected -> requestPassword(session)
                PdfFailure.InvalidPdf -> fail(session, WorkspacePreviewState.Failure.INVALID)
                PdfFailure.Busy -> fail(session, WorkspacePreviewState.Failure.RENDER)
                PdfFailure.Transport -> fail(session, WorkspacePreviewState.Failure.TRANSPORT)
            }
        }
    }

    private fun requestPassword(session: Session) {
        val capability = PdfPasswordSupport.capability()
        if (capability !is PdfPasswordCapability.NativeSupported) {
            fail(session, WorkspacePreviewState.Failure.PASSWORD_UNSUPPORTED)
            return
        }
        if (session.passwordAttempts >= WorkspaceDocumentPreviewPolicy.MAX_PASSWORD_ATTEMPTS) {
            fail(session, WorkspacePreviewState.Failure.PASSWORD_REJECTED)
            return
        }
        synchronized(lock) {
            if (!sessionUsableLocked(session)) return
            mutableState.value = WorkspacePreviewState.PasswordRequired(
                session.token, fileNameOf(session.relativePath))
        }
        val promptJob = trackJob(scope.launch {
            val characters = try {
                passwordPrompts.requestPassword(fileNameOf(session.relativePath))
            } catch (_: Throwable) {
                null
            }
            if (characters == null) {
                fail(session, WorkspacePreviewState.Failure.PASSWORD_REQUIRED)
                return@launch
            }
            if (!sessionUsable(session)) {
                characters.fill('\u0000')
                return@launch
            }
            val password = PdfPassword.of(characters)
            characters.fill('\u0000')
            if (password == null) {
                fail(session, WorkspacePreviewState.Failure.PASSWORD_REJECTED)
                return@launch
            }
            val previous = synchronized(lock) {
                if (!sessionUsableLocked(session)) {
                    password.close()
                    return@launch
                }
                session.passwordAttempts += 1
                val replaced = session.password
                session.password = password
                mutableState.value = WorkspacePreviewState.Opening(
                    session.token, fileNameOf(session.relativePath), WorkspacePreviewKind.PDF)
                replaced
            }
            previous?.close()
            val source = session.source
            val pdf = synchronized(lock) { session.pdf }
            if (source == null || pdf == null) {
                fail(session, WorkspacePreviewState.Failure.SOURCE)
                return@launch
            }
            val buffer = try {
                password.use { it }
            } catch (_: IllegalStateException) {
                fail(session, WorkspacePreviewState.Failure.OWNER)
                return@launch
            }
            try {
                pdf.documentInfo(source, buffer) { result -> onDocumentInfo(session, result) }
            } catch (_: Throwable) {
                fail(session, WorkspacePreviewState.Failure.TRANSPORT)
            }
        })
        synchronized(lock) {
            if (session.closed) promptJob.cancel() else session.promptJob = promptJob
        }
    }

    private fun requestCurrentPage(session: Session) {
        val index: Int
        val zoom: Int
        val generation: Long
        synchronized(lock) {
            if (!sessionUsableLocked(session)) return
            val current = mutableState.value as? WorkspacePreviewState.Pdf ?: return
            if (current.token != session.token ||
                !WorkspaceDocumentPreviewPolicy.validPdfPage(current.pageIndex, current.pageCount)
            ) {
                return
            }
            index = current.pageIndex
            zoom = current.zoomPercent
            generation = session.renderFence.bump()
            mutableState.value = current.copy(
                pages = mapOf(index to WorkspacePreviewState.Page.Loading))
        }
        val source = session.source
        val pdf = synchronized(lock) { session.pdf }
        if (source == null || pdf == null) {
            fail(session, WorkspacePreviewState.Failure.SOURCE)
            return
        }
        val buffer = try {
            session.password?.use { it }
        } catch (_: IllegalStateException) {
            fail(session, WorkspacePreviewState.Failure.OWNER)
            return
        }
        try {
            pdf.renderPage(source, index, zoom, buffer) { result ->
                onPageRendered(session, index, generation, result)
            }
        } catch (_: Throwable) {
            onPageRendered(session, index, generation, PdfPageResult.Failed(PdfFailure.Transport))
        }
    }

    private fun onPageRendered(
        session: Session,
        pageIndex: Int,
        generation: Long,
        result: PdfPageResult,
    ) {
        val drop = !sessionUsable(session) || !session.renderFence.isCurrent(generation)
        if (drop) {
            if (result is PdfPageResult.Rendered) recycle(result.bitmap)
            return
        }
        synchronized(lock) {
            if (!sessionUsableLocked(session) || !session.renderFence.isCurrent(generation)) {
                if (result is PdfPageResult.Rendered) recycle(result.bitmap)
                return
            }
            val current = mutableState.value as? WorkspacePreviewState.Pdf ?: return
            if (current.token != session.token || current.pageIndex != pageIndex) {
                if (result is PdfPageResult.Rendered) recycle(result.bitmap)
                return
            }
            val page = when (result) {
                is PdfPageResult.Rendered -> WorkspacePreviewState.Page.Ready(
                    result.bitmap, result.widthPx, result.heightPx)
                is PdfPageResult.Failed -> WorkspacePreviewState.Page.Failed(
                    retryable = result.failure != PdfFailure.InvalidPdf &&
                        result.failure != PdfFailure.PasswordProtected)
            }
            mutableState.value = current.copy(pages = mapOf(pageIndex to page))
        }
    }

    // ------------------------------------------------------------------
    // Lifecycle / cleanup
    // ------------------------------------------------------------------

    private fun stagerOwner(owner: Owner) = WorkspaceOfficeSnapshotStager.Owner(
        owner.taskID, owner.workspaceID, owner.nativeEpoch, owner.hostGeneration)

    private fun ownerCurrent(owner: Owner): Boolean =
        currentNativeEpoch() == owner.nativeEpoch &&
            currentHostGeneration() == owner.hostGeneration &&
            !isTemporaryTask(owner.taskID)

    private fun sessionUsableLocked(session: Session): Boolean =
        active === session && !session.closed && !session.failed &&
            addressFence.isCurrent(session.generation)

    private fun sessionUsable(session: Session): Boolean =
        !Thread.currentThread().isInterrupted && synchronized(lock) { sessionUsableLocked(session) } &&
            ownerCurrent(session.owner)

    private fun sessionAlive(session: Session): Boolean = sessionUsable(session)

    private fun adopt(session: Session, snapshot: WorkspaceOfficeSnapshotStager.Snapshot): Boolean =
        synchronized(lock) {
            if (!sessionUsableLocked(session)) {
                false
            } else {
                session.snapshot = snapshot
                true
            }
        }

    private fun fail(session: Session, failure: WorkspacePreviewState.Failure) {
        val retired: Retired?
        synchronized(lock) {
            if (active !== session || session.closed || session.failed) return
            session.failed = true
            addressFence.bump()
            session.promptJob?.cancel()
            retired = takeResourcesLocked(session)
            mutableState.value = WorkspacePreviewState.Failed(
                token = session.token,
                fileName = fileNameOf(session.relativePath),
                kind = session.kind,
                failure = failure,
                retryable = WorkspaceDocumentPreviewPolicy.retryable(failure),
                owner = session.owner,
                path = session.relativePath,
            )
        }
        retired?.let(::releaseRetired)
    }

    private fun takeResourcesLocked(session: Session): Retired {
        val retired = Retired(
            snapshot = session.snapshot?.file,
            pdf = session.pdf,
            password = session.password,
        )
        session.snapshot = null
        session.pdf = null
        session.image = null
        session.password = null
        session.source = null
        return retired
    }

    /** Marks a session retired exactly once; the caller releases outside the
     * lock. A replacement open therefore cannot race another release. */
    private fun markRetiredLocked(session: Session): Retired {
        session.closed = true
        addressFence.bump()
        if (active === session) active = null
        session.job?.cancel()
        session.promptJob?.cancel()
        return takeResourcesLocked(session)
    }

    /** Registers one controller-owned job so every root drain can join it even
     * after its session was replaced/failed/closed (a stage may still hold its
     * native ticket until the job actually returns). */
    private fun trackJob(job: Job): Job {
        synchronized(lock) { pendingJobs += job }
        job.invokeOnCompletion {
            synchronized(lock) { pendingJobs.remove(job) }
        }
        return job
    }

    private fun drainBlocked(): Boolean = synchronized(lock) { blockedRetirements.isNotEmpty() }

    private fun releaseRetired(retired: Retired) {
        val pdf = retired.pdf
        // A bitmap the UI may still be drawing is only DROPPED (never
        // recycled here) so the last frame can never draw recycled pixels;
        // an undeliverable decode is recycled at its own race site.
        if (pdf == null && retired.snapshot == null && retired.password == null) {
            return
        }
        if (pdf != null) {
            beginCleanup()
            val faulted = AtomicBoolean(false)
            try {
                pdf.release {
                    // A synchronous/async release fault means quiescence was
                    // never proved: do NOT delete the snapshot it may still
                    // hold, and never settle the drain counter.
                    if (faulted.get()) return@release
                    try {
                        cleanupNow(retired.snapshot, retired.password)
                    } finally {
                        endCleanup()
                    }
                }
            } catch (_: Throwable) {
                faulted.set(true)
                // Fail closed: retain the source/lease/password and keep the
                // drain permanently unproven for this process.
                synchronized(lock) { blockedRetirements += retired }
            }
        } else {
            beginCleanup()
            scope.launch(ioDispatcher + NonCancellable) {
                try {
                    cleanupNow(retired.snapshot, retired.password)
                } finally {
                    endCleanup()
                }
            }
        }
    }

    private fun beginCleanup() {
        synchronized(lock) {
            pendingCleanups += 1
            cleanupSignal.value = pendingCleanups
        }
    }

    private fun endCleanup() {
        synchronized(lock) {
            pendingCleanups = (pendingCleanups - 1).coerceAtLeast(0)
            cleanupSignal.value = pendingCleanups
        }
    }

    private fun cleanupNow(snapshot: File?, password: PdfPassword?) {
        runCatching { password?.close() }
        snapshot?.let(::purge)
    }

    /** Deletes ONLY the random directory this stager created under its own
     * root: canonical parent equality plus a UUID leaf. No host path and no
     * sibling snapshot is ever touched. */
    private fun purge(file: File) {
        val directory = file.parentFile ?: return
        val rootCanonical = runCatching { root.canonicalFile }.getOrNull() ?: return
        val directoryCanonical = runCatching { directory.canonicalFile }.getOrNull() ?: return
        if (directoryCanonical.parentFile != rootCanonical) return
        if (runCatching { UUID.fromString(directory.name) }.isFailure) return
        directory.listFiles()?.forEach { entry -> runCatching { entry.delete() } }
        runCatching { directory.delete() }
    }

    private fun recycle(bitmap: Bitmap) {
        if (!bitmap.isRecycled) runCatching { bitmap.recycle() }
    }

    private fun WorkspacePreviewState.tokenOrNull(): Long? = when (this) {
        is WorkspacePreviewState.Opening -> token
        is WorkspacePreviewState.Pdf -> token
        is WorkspacePreviewState.Image -> token
        is WorkspacePreviewState.PasswordRequired -> token
        is WorkspacePreviewState.Failed -> token
        WorkspacePreviewState.Idle -> null
    }
}

/** Narrow adapter over the REAL isolated renderer host so tests/UI never
 * need a second PDF engine and the session can be released with the
 * renderer's own quiescent join. Injectable so the release/drain lifecycle is
 * provable with a fake port on the JVM. */
internal interface WorkspacePreviewPdfPort {
    fun documentInfo(
        source: OfficePdfVerifiedSource,
        password: CharArray?,
        onResult: (PdfDocResult) -> Unit,
    )

    fun renderPage(
        source: OfficePdfVerifiedSource,
        pageIndex: Int,
        zoomPercent: Int,
        password: CharArray?,
        onResult: (PdfPageResult) -> Unit,
    )

    fun release(onQuiescent: (() -> Unit)?)
}

private class ServicePdfSession(private val host: OfficePdfRenderHost) : WorkspacePreviewPdfPort {
    override fun documentInfo(
        source: OfficePdfVerifiedSource,
        password: CharArray?,
        onResult: (PdfDocResult) -> Unit,
    ) = host.documentInfo(source, password, onResult)

    override fun renderPage(
        source: OfficePdfVerifiedSource,
        pageIndex: Int,
        zoomPercent: Int,
        password: CharArray?,
        onResult: (PdfPageResult) -> Unit,
    ) = host.renderPage(source, pageIndex, zoomPercent, password, onResult)

    override fun release(onQuiescent: (() -> Unit)?) = host.release(onQuiescent)
}
