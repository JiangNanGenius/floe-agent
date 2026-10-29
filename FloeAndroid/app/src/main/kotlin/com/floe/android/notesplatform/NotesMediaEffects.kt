// SPDX-License-Identifier: MPL-2.0
package com.floe.android.notesplatform

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.pdf.PdfDocument
import android.view.MotionEvent
import android.view.View
import com.floe.android.core.notesmedia.api.NotesMedia
import com.floe.android.core.notesmedia.export.ImageFormat
import com.floe.android.core.notesmedia.export.NotesExportEngine
import com.floe.android.core.notesmedia.export.NotesExportPagePlan
import com.floe.android.core.notesmedia.export.NotesExportQuality
import com.floe.android.core.notesmedia.export.NotesExportPlanner
import com.floe.android.core.notesmedia.export.NotesExportRefusal
import com.floe.android.core.notesmedia.export.NotesOverlay
import com.floe.android.core.notesmedia.export.NotesPdfExportFidelity
import com.floe.android.core.notesmedia.export.NotesPrintBridge
import com.floe.android.core.notesmedia.export.NotesPrintFinish
import com.floe.android.core.notesmedia.export.NotesPrintStart
import com.floe.android.core.notesmedia.ink.InkBrushSpec
import com.floe.android.core.notesmedia.ink.InkCanvasView
import com.floe.android.core.notesmedia.ink.InkDocument
import com.floe.android.core.notesmedia.ink.InkDecodeResult
import com.floe.android.core.notesmedia.ink.InkDocumentCodec
import com.floe.android.core.notesmedia.ink.InkEncodeResult
import com.floe.android.core.notesmedia.ink.InkBox
import com.floe.android.core.notesmedia.media.InkFormat
import com.floe.android.core.notesmedia.ink.InkInputConfig
import com.floe.android.core.notesmedia.ink.InkPageGeometry
import com.floe.android.core.notesmedia.ink.InkSnapshot
import com.floe.android.core.notesmedia.media.NotesMediaType
import com.floe.android.core.notesmedia.pdf.PdfDocumentSession
import com.floe.android.core.notesmedia.pdf.PdfDocumentSessions
import com.floe.android.core.notesmedia.pdf.PdfMediaFailure
import com.floe.android.core.notesmedia.pdf.PdfOpenResult
import com.floe.android.core.notesmedia.pdf.PdfPassword
import com.floe.android.core.notesmedia.pdf.PdfPageBox
import com.floe.android.core.notesmedia.pdf.PdfPageId
import com.floe.android.core.notesmedia.pdf.PdfPageRenderResult
import com.floe.android.core.notesmedia.pdf.PdfRenderPlanner
import com.floe.android.core.notesmedia.pdf.PdfSessionOptions
import com.floe.android.core.notesmedia.pdf.PdfTextSearchOutcome
import com.floe.android.core.notesmedia.source.MediaSnapshotVerifier
import com.floe.android.core.notesmedia.source.SnapshotResult
import com.floe.android.core.notesmedia.source.VerifiedMediaSnapshot
import com.floe.android.core.notesmedia.pdf.OfficePdfRenderGateway
import com.floe.android.feature.notes.NoteElementKind
import com.floe.android.feature.notes.NotePaper
import com.floe.android.feature.notes.NoteRect
import com.floe.android.feature.notes.ui.api.NotesCoverImageRequest
import com.floe.android.feature.notes.ui.api.NotesExportPage
import com.floe.android.feature.notes.ui.api.NotesExportElement
import com.floe.android.feature.notes.ui.api.NotesExportedStream
import com.floe.android.feature.notes.ui.api.NotesImageInfo
import com.floe.android.feature.notes.ui.api.NotesImageProbeRequest
import com.floe.android.feature.notes.ui.api.NotesInkCreateRequest
import com.floe.android.feature.notes.ui.api.NotesInkSurface
import com.floe.android.feature.notes.ui.api.NotesInkToolKind
import com.floe.android.feature.notes.ui.api.NotesInkToolSpec
import com.floe.android.feature.notes.ui.api.NotesMediaCapabilities
import com.floe.android.feature.notes.ui.api.NotesMediaPort
import com.floe.android.feature.notes.ui.api.NotesNormalizedRect
import com.floe.android.feature.notes.ui.api.NotesPageImageExportRequest
import com.floe.android.feature.notes.ui.api.NotesPdfExportRequest
import com.floe.android.feature.notes.ui.api.NotesPdfHandle
import com.floe.android.feature.notes.ui.api.NotesPdfOpenOutcome
import com.floe.android.feature.notes.ui.api.NotesPdfOpenRequest
import com.floe.android.feature.notes.ui.api.NotesPdfPageSize
import com.floe.android.feature.notes.ui.api.NotesPdfSearchHit
import com.floe.android.feature.notes.ui.api.NotesPdfSearchOutcome
import com.floe.android.feature.notes.ui.api.NotesPortFailure
import com.floe.android.feature.notes.ui.api.NotesPreparedImage
import com.floe.android.feature.notes.ui.api.NotesPrintOutcome
import com.floe.android.feature.notes.ui.api.NotesPrintRequest
import com.floe.android.feature.notes.ui.api.NotesResourceReader
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.coroutineContext
import kotlin.math.roundToInt
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Real Notes media effects over `core:notesmedia`.
 *
 * Everything user-visible here is backed by an existing renderer, codec or
 * exporter:
 *  - PDFs are streamed from `NotesService.readResource` into an App-private
 *    verified snapshot (length + SHA-256 re-proved), then opened through the
 *    shared isolated Office renderer session;
 *  - image/ink resources are staged the same way; ink uses the stable
 *    `FLOEINK1` codec and the `androidx.ink` 1.0 authoring View;
 *  - export composes a flattened source page raster (PDF page / image / paper)
 *    and lets `NotesExportEngine` write the verified PDF/PNG copy. Fidelity is
 *    RASTERIZED_COPY, never "lossless";
 *  - print hands the verified bytes to the existing `OfficePdfPrintFlow`.
 *
 * Ownership: every staged directory/file is owned by this adapter and removed
 * after the returned stream/handle closes. Bitmaps are released through the
 * session's ownership rules; no bitmap is recycled while the cache owns it.
 */
/**
 * Optional UI-owned password prompt seam for a protected PDF. The provider is
 * called off the UI thread after the renderer reports PASSWORD_PROTECTED; it
 * must return a fresh char array (or null for cancel). The adapter copies it
 * into a RAM-only [PdfPassword], zeroes the caller's array immediately and
 * never logs/persists it.
 */
fun interface NotesPdfPasswordProvider {
    suspend fun requestPassword(fileName: String): CharArray?
}

internal class NotesMediaEffects(
    private val context: Context,
    private val scope: CoroutineScope,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val stagingRoot: File,
    private val passwordProvider: NotesPdfPasswordProvider? = null,
) : NotesMediaPort, AutoCloseable {

    private val workRoot = File(stagingRoot, "media")
    private val closed = AtomicBoolean(false)

    /** One shared renderer binding; released by the host owner. */
    private val gateway: OfficePdfRenderGateway by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        NotesMedia.renderGateway(context)
    }

    private val printSessions = java.util.Collections.synchronizedSet(HashSet<PdfDocumentSession>())

    override fun capabilities(): NotesMediaCapabilities {
        val caps = NotesMedia.capabilities()
        return NotesMediaCapabilities(
            pdfRendering = caps.pdfRendering,
            pdfThumbnails = caps.pdfThumbnails,
            pdfTextSearch = caps.pdfNativeTextSearch,
            pdfPasswordUnlock = caps.pdfPasswordUnlock,
            inkAuthoring = caps.inkAuthoringView,
            inkEditablePersistence = caps.inkEditablePersistence,
            imageExport = caps.imageExport,
            pdfExport = caps.pdfAnnotationExport,
            systemPrint = caps.systemPrint,
        )
    }

    /* ------------------------------ images -------------------------------- */

    override suspend fun probeImage(request: NotesImageProbeRequest): NotesImageInfo? {
        if (request.byteCount <= 0L || request.byteCount > NotesPlatformFiles.MAX_STAGED_IMAGE_BYTES) {
            return null
        }
        return withContext(ioDispatcher) {
            val work = NotesPlatformFiles.newWorkDirectory(workRoot, "probe")
            try {
                val staged = NotesPlatformFiles.copyFromReader(
                    destination = File(work, "probe.bin"),
                    maxBytes = NotesPlatformFiles.MAX_STAGED_IMAGE_BYTES,
                    read = request.read,
                )
                if (staged.byteCount != request.byteCount) return@withContext null
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeFile(staged.file.absolutePath, bounds)
                if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return@withContext null
                NotesImageInfo(
                    width = bounds.outWidth,
                    height = bounds.outHeight,
                    mediaType = NotesPlatformNames.mimeFor(request.fileName, request.mediaType),
                )
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                null
            } finally {
                NotesPlatformFiles.deleteQuietly(work)
            }
        }
    }

    override suspend fun prepareCoverImage(request: NotesCoverImageRequest): NotesPreparedImage {
        return withContext(ioDispatcher) {
            val work = NotesPlatformFiles.newWorkDirectory(workRoot, "cover")
            try {
                val staged = NotesPlatformFiles.copyFromReader(
                    destination = File(work, "source.bin"),
                    maxBytes = NotesPlatformFiles.MAX_STAGED_IMAGE_BYTES,
                    read = request.read,
                )
                val maxEdge = request.maxEdgePx.coerceIn(64, 4096)
                val decoded = decodeImage(staged.file, maxEdge)
                    ?: throw NotesPlatformErrors.failed("imageDecode")
                val hasAlpha = decoded.hasAlpha()
                val format = if (hasAlpha) Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG
                val quality = if (format == Bitmap.CompressFormat.PNG) 100 else 90
                val output = File(work, "cover." + if (hasAlpha) "png" else "jpg")
                FileOutputStream(output).use { out ->
                    if (!decoded.compress(format, quality, out)) throw NotesPlatformErrors.failed("imageEncode")
                    out.flush()
                    runCatching { out.fd.sync() }
                }
                val bytes = output.readBounded(NotesPlatformFiles.MAX_STAGED_IMAGE_BYTES)
                val verify = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size, verify)
                if (verify.outWidth <= 0 || verify.outHeight <= 0) {
                    throw NotesPlatformErrors.failed("imageReadback")
                }
                val mediaType = if (hasAlpha) "image/png" else "image/jpeg"
                val extension = if (hasAlpha) "png" else "jpg"
                NotesPreparedImage(
                    bytes = bytes,
                    mediaType = mediaType,
                    fileName = NotesPlatformNames.safeFileName(request.fileName, "cover", extension),
                    width = verify.outWidth,
                    height = verify.outHeight,
                )
            } finally {
                NotesPlatformFiles.deleteQuietly(work)
            }
        }
    }

    /* -------------------------------- PDF --------------------------------- */

    override suspend fun openPdf(request: NotesPdfOpenRequest): NotesPdfOpenOutcome {
        if (request.resourceID.isBlank() || request.byteCount <= 0L) {
            return NotesPdfOpenOutcome.Failed(NotesPortFailure(NotesPortFailure.NOT_FOUND, "resource"))
        }
        if (request.byteCount > VerifiedMediaSnapshot.MAX_SOURCE_BYTES) {
            return NotesPdfOpenOutcome.Unavailable(NotesPortFailure(NotesPortFailure.UNSUPPORTED, "sourceTooLarge"))
        }
        if (!isSha256(request.sha256)) {
            return NotesPdfOpenOutcome.Failed(NotesPortFailure(NotesPortFailure.FAILED, "invalidDigest"))
        }
        return try {
            val work = withContext(ioDispatcher) {
                NotesPlatformFiles.newWorkDirectory(workRoot, "pdf")
            }
            try {
                val snapshot = withContext(ioDispatcher) {
                    val staged = NotesPlatformFiles.copyFromReader(
                        destination = File(work, NotesPlatformNames.safeFileName(request.fileName, "document", "pdf")),
                        maxBytes = VerifiedMediaSnapshot.MAX_SOURCE_BYTES,
                        read = { offset, maxBytes -> request.read.read(request.resourceID, offset, maxBytes) },
                    )
                    if (staged.byteCount != request.byteCount || staged.sha256 != request.sha256) {
                        throw NotesPlatformErrors.failed("sourceChanged")
                    }
                    when (val verified = MediaSnapshotVerifier.verify(
                        staged.file,
                        NotesMediaType.PDF,
                        NotesPlatformNames.safeFileName(request.fileName, "document", "pdf"),
                    )) {
                        is SnapshotResult.Refused -> throw NotesPlatformErrors.failed("sourceRefused:" + verified.reason.name)
                        is SnapshotResult.Verified -> {
                            if (verified.snapshot.sha256 != request.sha256 ||
                                verified.snapshot.byteCount != request.byteCount
                            ) {
                                throw NotesPlatformErrors.failed("sourceChanged")
                            }
                            verified.snapshot
                        }
                    }
                }
                when (val opened = openWithOptionalPassword(snapshot, request.fileName)) {
                    is PdfOpenResult.Opened -> {
                        NotesPdfOpenOutcome.Opened(
                            PdfHandle(
                                session = opened.session,
                                documentID = request.documentID,
                                resourceID = request.resourceID,
                                work = work,
                                ioDispatcher = ioDispatcher,
                            ),
                        )
                    }
                    is PdfOpenResult.Failed -> {
                        NotesPlatformFiles.deleteQuietly(work)
                        mapOpenFailure(opened)
                    }
                }
            } catch (cancelled: CancellationException) {
                NotesPlatformFiles.deleteQuietly(work)
                throw cancelled
            } catch (error: Throwable) {
                NotesPlatformFiles.deleteQuietly(work)
                NotesPdfOpenOutcome.Failed(NotesPlatformErrors.notes(error, "pdfOpenFailed").failure)
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        }
    }

    override suspend fun exportPdf(request: NotesPdfExportRequest): NotesExportedStream {
        if (request.pages.isEmpty()) throw NotesPlatformErrors.failed("noPages")
        if (request.pages.size > NotesExportPlanner.MAX_PAGES_PER_EXPORT) {
            throw NotesPlatformErrors.unsupported("tooManyPages")
        }
        return withContext(ioDispatcher) {
            val work = NotesPlatformFiles.newWorkDirectory(workRoot, "exportpdf")
            var overlays: DecodedOverlays? = null
            var baseSession: PdfDocumentSession? = null
            try {
                val base = buildComposedPdf(request.pages, request, work)
                val baseSnapshot = verifySnapshot(
                    base.file,
                    NotesPlatformNames.safeFileName(request.fileName, "export", "pdf"),
                )
                val session = openSnapshot(baseSnapshot).also { baseSession = it }
                val decoded = buildOverlays(request.pages, request.read, work).also { overlays = it }
                val ids = request.pages.indices.map { PdfPageId(it) }
                val plan = when (val planned = NotesExportPlanner.plan(
                    baseSnapshot.sha256,
                    session.geometry,
                    ids,
                    decoded.overlays,
                    NotesExportQuality.HIGH,
                )) {
                    is com.floe.android.core.notesmedia.export.NotesExportPlanResult.Ready -> planned.plan
                    is com.floe.android.core.notesmedia.export.NotesExportPlanResult.Refused ->
                        throw NotesPlatformErrors.unsupported("exportRefused:" + planned.refusal.name)
                }
                val destination = File(work, NotesPlatformNames.safeFileName(request.fileName, "export", "pdf"))
                when (val exported = NotesExportEngine(session).exportPdf(plan, destination)) {
                    is com.floe.android.core.notesmedia.export.PdfExportResult.Ok -> Unit
                    is com.floe.android.core.notesmedia.export.PdfExportResult.Failed ->
                        throw NotesPlatformErrors.failed("exportFailed:" + exported.failure.name)
                }
                if (!NotesPlatformFiles.isPlainFile(destination, NotesPlatformFiles.MAX_STAGED_EXPORT_BYTES)) {
                    throw NotesPlatformErrors.failed("exportMissing")
                }
                val stream = fileStream(
                    file = destination,
                    fileName = NotesPlatformNames.safeFileName(request.fileName, "export", "pdf"),
                    mediaType = "application/pdf",
                    work = work,
                    ioDispatcher = ioDispatcher,
                )
                stream
            } catch (error: Throwable) {
                NotesPlatformFiles.deleteQuietly(work)
                throw NotesPlatformErrors.notes(error, "pdfExportFailed")
            } finally {
                overlays?.recycle()
                runCatching { baseSession?.close() }
            }
        }
    }

    override suspend fun exportPageImage(request: NotesPageImageExportRequest): NotesExportedStream {
        return withContext(ioDispatcher) {
            val work = NotesPlatformFiles.newWorkDirectory(workRoot, "exportpage")
            var overlays: DecodedOverlays? = null
            var baseSession: PdfDocumentSession? = null
            try {
                val pages = listOf(request.page)
                val base = buildComposedPdf(
                    pages,
                    NotesPdfExportRequest(
                        documentID = request.documentID,
                        title = request.fileName,
                        pages = pages,
                        pdfResourceID = request.page.pdfResourceID,
                        pdfSha256 = null,
                        pdfByteCount = null,
                        fileName = request.fileName,
                        read = request.read,
                    ),
                    work,
                )
                val baseSnapshot = verifySnapshot(
                    base.file,
                    NotesPlatformNames.safeFileName(request.fileName, "page", "pdf"),
                )
                val session = openSnapshot(baseSnapshot).also { baseSession = it }
                val decoded = buildOverlays(pages, request.read, work).also { overlays = it }
                val plan = when (val planned = NotesExportPlanner.plan(
                    baseSnapshot.sha256,
                    session.geometry,
                    listOf(PdfPageId(0)),
                    decoded.overlays,
                    NotesExportQuality.HIGH,
                )) {
                    is com.floe.android.core.notesmedia.export.NotesExportPlanResult.Ready -> planned.plan
                    is com.floe.android.core.notesmedia.export.NotesExportPlanResult.Refused ->
                        throw NotesPlatformErrors.unsupported("exportRefused:" + planned.refusal.name)
                }
                val destination = File(work, NotesPlatformNames.safeFileName(request.fileName, "page", "png"))
                val exported = NotesExportEngine(session).exportImage(
                    pagePlan = plan.pages.first(),
                    destination = destination,
                    format = ImageFormat.PNG,
                    maxEdgePx = request.targetWidthPx.coerceIn(64, 4096),
                    overwrite = false,
                )
                if (!exported.ok) {
                    throw NotesPlatformErrors.failed("imageExportFailed:" + exported.failure?.name)
                }
                if (!NotesPlatformFiles.isPlainFile(destination, NotesPlatformFiles.MAX_STAGED_EXPORT_BYTES)) {
                    throw NotesPlatformErrors.failed("exportMissing")
                }
                fileStream(
                    file = destination,
                    fileName = NotesPlatformNames.safeFileName(request.fileName, "page", "png"),
                    mediaType = "image/png",
                    work = work,
                    ioDispatcher = ioDispatcher,
                )
            } catch (error: Throwable) {
                NotesPlatformFiles.deleteQuietly(work)
                throw NotesPlatformErrors.notes(error, "pageExportFailed")
            } finally {
                overlays?.recycle()
                runCatching { baseSession?.close() }
            }
        }
    }

    override suspend fun print(request: NotesPrintRequest): NotesPrintOutcome {
        val work = withContext(ioDispatcher) {
            NotesPlatformFiles.newWorkDirectory(workRoot, "print")
        }
        var session: PdfDocumentSession? = null
        try {
            val snap = withContext(ioDispatcher) {
                val staged = NotesPlatformFiles.copyFromReader(
                    destination = File(work, NotesPlatformNames.safeFileName(request.stream.fileName, "print", "pdf")),
                    maxBytes = NotesPlatformFiles.MAX_STAGED_EXPORT_BYTES,
                    read = request.stream.read,
                )
                if (staged.byteCount != request.stream.totalBytes) {
                    throw NotesPlatformErrors.failed("printLengthMismatch")
                }
                verifySnapshot(
                    staged.file,
                    NotesPlatformNames.safeFileName(request.stream.fileName, "print", "pdf"),
                )
            }
            val opened = NotesMedia.openPdf(context, snap, PdfSessionOptions(gateway = sharedGateway()))
            val openedSession = (opened as? PdfOpenResult.Opened)?.session
                ?: run {
                    NotesPlatformFiles.deleteQuietly(work)
                    val failure = (opened as? PdfOpenResult.Failed)?.failure
                    return mapPrintStartFailure(failure)
                }
            session = openedSession
            printSessions += openedSession
            val started = CompletableDeferred<NotesPrintStart>()
            val finished = CompletableDeferred<NotesPrintFinish>()
            NotesPrintBridge.print(
                context = context,
                session = openedSession,
                documentLabel = request.jobName.take(120).ifBlank { "Notes" },
                onResult = { started.complete(it) },
                onFinished = { finished.complete(it) },
            )
            val start = withTimeoutOrNull(30_000L) { started.await() }
                ?: NotesPrintStart.ACTIVITY_RETIRED
            if (start != NotesPrintStart.DIALOG_OPENED) {
                printSessions -= openedSession
                runCatching { openedSession.close() }
                NotesPlatformFiles.deleteQuietly(work)
                return mapPrintStartFailure(start)
            }
            scope.launch(ioDispatcher) {
                withTimeoutOrNull(10L * 60 * 1000) { finished.await() }
                printSessions -= openedSession
                runCatching { openedSession.close() }
                NotesPlatformFiles.deleteQuietly(work)
            }
            session = null
            return NotesPrintOutcome.Launched
        } catch (cancelled: CancellationException) {
            NotesPlatformFiles.deleteQuietly(work)
            throw cancelled
        } catch (error: Throwable) {
            session?.let { printSessions -= it }
            runCatching { session?.close() }
            NotesPlatformFiles.deleteQuietly(work)
            val failure = NotesPlatformErrors.notes(error, "printFailed").failure
            return NotesPrintOutcome.Failed(failure)
        }
    }

    /* --------------------------------- ink -------------------------------- */

    override fun createInk(request: NotesInkCreateRequest): NotesInkSurface {
        if (request.pageWidthPt <= 0f || request.pageHeightPt <= 0f ||
            request.pageWidthPt > 100_000f || request.pageHeightPt > 100_000f
        ) {
            throw NotesPlatformErrors.failed("invalidPageGeometry")
        }
        val documentID = request.documentID.takeIf {
            it.matches(Regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"))
        } ?: request.pageID
        val view = NotesMedia.instrumentedInkCanvas(context)
        // PageSurface already composes the page background (paper, imported
        // image or rendered PDF) beneath this authoring view. Painting the
        // ink layer's default opaque paper colour would cover that background
        // and make every PDF/image page look blank.
        view.setPaperColor(Color.TRANSPARENT)
        val document = NotesMedia.createInkDocument(
            documentId = documentID,
            pageKey = request.pageID,
            widthPt = request.pageWidthPt,
            heightPt = request.pageHeightPt,
        )
        return NotesInkSurfaceImpl(
            inkView = view,
            document = document,
            initialTool = request.tool,
            onDrawingChanged = request.onDrawingChanged,
        ).also { it.start() }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        val sessions = synchronized(printSessions) { printSessions.toList() }
        sessions.forEach { runCatching { it.close() } }
        printSessions.clear()
        runCatching { if (gatewayInitialized()) gateway.release() }
        NotesPlatformFiles.sweepOlderThan(workRoot, NotesPlatformFiles.CACHE_MAX_AGE_MILLIS)
    }

    private fun gatewayInitialized(): Boolean = try {
        // Accessing the lazy would initialize it; only release an already
        // created gateway. Kotlin's lazy has no public isInitialized, so track
        // it through the property's backing field via a separate flag.
        gatewayCreated
    } catch (_: Throwable) {
        false
    }

    @Volatile
    private var gatewayCreated = false

    private fun sharedGateway(): OfficePdfRenderGateway {
        gatewayCreated = true
        return gateway
    }

    /* ---------------------------- export helpers -------------------------- */

    /**
     * Opens a verified PDF, consuming the media layer's real API-35/PreV
     * password transaction only when a UI password provider is installed.
     * Without a provider the typed PasswordRequired outcome is preserved.
     */
    private suspend fun openWithOptionalPassword(
        snapshot: VerifiedMediaSnapshot,
        fileName: String,
    ): PdfOpenResult {
        val first = NotesMedia.openPdf(context, snapshot, PdfSessionOptions(gateway = sharedGateway()))
        if (first !is PdfOpenResult.Failed || first.failure != PdfMediaFailure.PASSWORD_PROTECTED) {
            return first
        }
        val provider = passwordProvider ?: return first
        if (!NotesMedia.passwordUnlockAvailable()) return first
        val raw = try {
            provider.requestPassword(NotesPlatformNames.safeFileName(fileName, "document", "pdf"))
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            null
        } ?: return first
        val holder = try {
            PdfPassword.of(raw)
        } finally {
            raw.fill('\u0000')
        } ?: return first
        return NotesMedia.openPdf(
            context,
            snapshot,
            PdfSessionOptions(gateway = sharedGateway(), password = holder),
        )
    }

    private suspend fun openSnapshot(
        snapshot: VerifiedMediaSnapshot,
    ): PdfDocumentSession {
        return when (val opened = openWithOptionalPassword(snapshot, snapshot.displayName)) {
            is PdfOpenResult.Opened -> opened.session
            is PdfOpenResult.Failed -> throw NotesPlatformErrors.failed("pdfOpen:" + opened.failure.name)
        }
    }

    private suspend fun verifySnapshot(file: File, displayName: String): VerifiedMediaSnapshot {
        return when (val verified = MediaSnapshotVerifier.verify(file, NotesMediaType.PDF, displayName)) {
            is SnapshotResult.Refused -> throw NotesPlatformErrors.failed("sourceRefused:" + verified.reason.name)
            is SnapshotResult.Verified -> verified.snapshot
        }
    }

    private suspend fun buildComposedPdf(
        pages: List<NotesExportPage>,
        request: NotesPdfExportRequest,
        work: File,
    ): StagedByteFile {
        val document = PdfDocument()
        val resourceFiles = HashMap<String, StagedByteFile>()
        val opened = HashMap<String, PdfDocumentSession>()
        try {
            pages.forEachIndexed { index, page ->
                val width = page.widthPt.roundToInt().coerceIn(1, 20_000)
                val height = page.heightPt.roundToInt().coerceIn(1, 20_000)
                val info = PdfDocument.PageInfo.Builder(width, height, index + 1).create()
                val canvasPage = document.startPage(info)
                try {
                    val canvas = canvasPage.canvas
                    canvas.drawColor(Color.WHITE)
                    val pdfResource = page.backgroundResourceID?.takeIf { page.pdfPageIndex != null }
                    if (pdfResource != null) {
                        val pdfIndex = page.pdfPageIndex ?: 0
                        var session = opened[pdfResource]
                        if (session == null) {
                            val staged = resourceFiles.getOrPut(pdfResource) {
                                stageResource(
                                    read = request.read,
                                    resourceID = pdfResource,
                                    work = work,
                                    fileName = "background-$pdfResource.pdf",
                                    maxBytes = VerifiedMediaSnapshot.MAX_SOURCE_BYTES,
                                    expectedSha = request.pdfSha256.takeIf { pdfResource == request.pdfResourceID },
                                    expectedBytes = request.pdfByteCount.takeIf { pdfResource == request.pdfResourceID },
                                )
                            }
                            val snap = verifySnapshot(staged.file, "background.pdf")
                            session = openSnapshot(snap)
                            opened[pdfResource] = session
                        }
                        val activeSession = session
                        val pageId = PdfPageId(pdfIndex)
                        val box = activeSession.pageBox(pageId)
                            ?: throw NotesPlatformErrors.failed("pdfPageUnavailable")
                        val zoom = PdfRenderPlanner.zoomPercentForWidth(box, (width * 2).coerceAtLeast(1))
                        val render = activeSession.renderForExport(pageId, zoom)
                        if (render !is PdfPageRenderResult.Ready) {
                            throw NotesPlatformErrors.failed("pdfPageRender")
                        }
                        try {
                            canvas.drawBitmap(
                                render.bitmap,
                                null,
                                RectF(0f, 0f, width.toFloat(), height.toFloat()),
                                Paint(Paint.FILTER_BITMAP_FLAG),
                            )
                        } finally {
                            activeSession.releaseBitmap(render)
                        }
                    } else {
                        val imageResource = page.backgroundResourceID
                        val bitmap = if (imageResource != null) {
                            val staged = resourceFiles.getOrPut(imageResource) {
                                stageResource(
                                    read = request.read,
                                    resourceID = imageResource,
                                    work = work,
                                    fileName = "background-$imageResource.bin",
                                    maxBytes = NotesPlatformFiles.MAX_STAGED_IMAGE_BYTES,
                                )
                            }
                            decodeImage(staged.file, maxOf(width, height) * 2)
                                ?: throw NotesPlatformErrors.failed("imageDecode")
                        } else {
                            null
                        }
                        if (bitmap != null) {
                            try {
                                canvas.drawBitmap(bitmap, null, RectF(0f, 0f, width.toFloat(), height.toFloat()),
                                    Paint(Paint.FILTER_BITMAP_FLAG))
                            } finally {
                                if (!bitmap.isRecycled) bitmap.recycle()
                            }
                        } else {
                            drawPaper(canvas, page.paper, width.toFloat(), height.toFloat())
                        }
                    }
                } finally {
                    document.finishPage(canvasPage)
                }
            }
            val destination = File(work, "base.pdf")
            FileOutputStream(destination).use { out ->
                document.writeTo(out)
                out.flush()
                runCatching { out.fd.sync() }
            }
            val sha = NotesPlatformFiles.sha256(destination)
            return StagedByteFile(destination, destination.length(), sha)
        } finally {
            opened.values.forEach { runCatching { it.close() } }
            runCatching { document.close() }
        }
    }

    private inner class DecodedOverlays(
        val overlays: List<NotesOverlay>,
        private val bitmaps: List<Bitmap>,
    ) {
        fun recycle() {
            bitmaps.forEach { if (!it.isRecycled) runCatching { it.recycle() } }
        }
    }

    private suspend fun buildOverlays(
        pages: List<NotesExportPage>,
        read: NotesResourceReader,
        work: File,
    ): DecodedOverlays {
        val overlays = ArrayList<NotesOverlay>()
        val bitmaps = ArrayList<Bitmap>()
        var imageBudget = 96L * 1024 * 1024
        val stagedResources = HashMap<String, StagedByteFile>()
        try {
            pages.forEachIndexed { index, page ->
                val pageId = PdfPageId(index)
                val pageW = page.widthPt
                val pageH = page.heightPt
                page.elements.forEach { element ->
                    val bounds = clampBounds(element.frame, pageW, pageH)
                    when (element.kind) {
                        NoteElementKind.TEXT -> {
                            if (element.text.isBlank()) return@forEach
                            if (element.text.length > NotesOverlay.Text.MAX_TEXT_CHARS) {
                                throw NotesPlatformErrors.unsupported("textTooLargeForExport")
                            }
                            overlays += NotesOverlay.Text(
                                page = pageId,
                                bounds = bounds,
                                text = element.text,
                                fontSizePt = element.fontSize.toFloat().coerceIn(1f, 400f),
                                colorArgb = parseColor(element.color),
                            )
                        }
                        NoteElementKind.IMAGE -> {
                            val resourceID = element.imageResourceID
                                ?: throw NotesPlatformErrors.failed("missingImageResource")
                            val staged = stagedResources.getOrPut(resourceID) {
                                stageResource(
                                    read = read,
                                    resourceID = resourceID,
                                    work = work,
                                    fileName = "image-$resourceID.bin",
                                    maxBytes = NotesPlatformFiles.MAX_STAGED_IMAGE_BYTES,
                                )
                            }
                            val bitmap = decodeImage(
                                staged.file,
                                maxOf(bounds.width.toInt(), bounds.height.toInt()).coerceIn(64, 2048) * 2,
                            ) ?: throw NotesPlatformErrors.failed("imageDecode")
                            imageBudget -= bitmap.allocationByteCount.toLong()
                            if (imageBudget < 0L) {
                                runCatching { bitmap.recycle() }
                                throw NotesPlatformErrors.unsupported("exportImageBudget")
                            }
                            bitmaps += bitmap
                            overlays += NotesOverlay.Image(pageId, bounds, bitmap, opacity = 1f)
                        }
                        NoteElementKind.RECTANGLE,
                        NoteElementKind.ELLIPSE,
                        NoteElementKind.LINE,
                        NoteElementKind.ARROW,
                        -> {
                            overlays += NotesOverlay.Shape(
                                page = pageId,
                                bounds = bounds,
                                kind = when (element.kind) {
                                    NoteElementKind.RECTANGLE ->
                                        com.floe.android.core.notesmedia.export.NotesShapeKind.RECT
                                    NoteElementKind.ELLIPSE ->
                                        com.floe.android.core.notesmedia.export.NotesShapeKind.ELLIPSE
                                    NoteElementKind.LINE ->
                                        com.floe.android.core.notesmedia.export.NotesShapeKind.LINE
                                    else -> com.floe.android.core.notesmedia.export.NotesShapeKind.ARROW
                                },
                                strokeWidthPt = 2f,
                                colorArgb = parseColor(element.color),
                            )
                        }
                    }
                }
                val drawingID = page.drawingResourceID
                if (drawingID != null) {
                    val staged = stagedResources.getOrPut(drawingID) {
                        stageResource(
                            read = read,
                            resourceID = drawingID,
                            work = work,
                            fileName = "ink-$drawingID.ink",
                            maxBytes = InkFormat.MAX_DOCUMENT_BYTES,
                        )
                    }
                    val bytes = staged.file.readBounded(InkFormat.MAX_DOCUMENT_BYTES)
                    if (!looksLikeFloeInk(bytes)) {
                        throw NotesPlatformErrors.unsupported("foreignInkExport")
                    }
                    val snapshot = when (val decoded = InkDocumentCodec.decode(bytes)) {
                        is InkDecodeResult.Ok -> decoded.snapshot
                        is InkDecodeResult.Invalid ->
                            throw NotesPlatformErrors.failed("inkDecode:" + decoded.refusal.name)
                    }
                    overlays += NotesOverlay.InkMark(
                        page = pageId,
                        bounds = InkBox(0f, 0f, pageW, pageH),
                        snapshot = snapshot,
                    )
                }
                if (page.elements.size > NotesExportPlanner.MAX_OVERLAYS_PER_PAGE) {
                    throw NotesPlatformErrors.unsupported("tooManyOverlays")
                }
            }
            return DecodedOverlays(overlays, bitmaps)
        } catch (error: Throwable) {
            bitmaps.forEach { if (!it.isRecycled) runCatching { it.recycle() } }
            throw error
        }
    }

    private suspend fun stageResource(
        read: NotesResourceReader,
        resourceID: String,
        work: File,
        fileName: String,
        maxBytes: Long,
        expectedSha: String? = null,
        expectedBytes: Long? = null,
    ): StagedByteFile {
        val safe = NotesPlatformNames.safeFileName(fileName, "resource")
        val destination = File(work, safe)
        val staged = NotesPlatformFiles.copyFromReader(
            destination = destination,
            maxBytes = maxBytes,
            read = { offset, maxBytesRead -> read.read(resourceID, offset, maxBytesRead) },
        )
        if (expectedBytes != null && staged.byteCount != expectedBytes) {
            throw NotesPlatformErrors.failed("sourceChanged")
        }
        if (expectedSha != null && staged.sha256 != expectedSha) {
            throw NotesPlatformErrors.failed("sourceChanged")
        }
        return staged
    }

    private fun fileStream(
        file: File,
        fileName: String,
        mediaType: String,
        work: File,
        ioDispatcher: CoroutineDispatcher,
    ): NotesExportedStream {
        val reader = StagedFileReader(file, file.length(), onClose = {
            NotesPlatformFiles.deleteQuietly(work)
        }, ioDispatcher = ioDispatcher)
        return NotesExportedStream(
            fileName = fileName,
            mediaType = mediaType,
            totalBytes = file.length(),
            read = { offset, maxBytes -> reader.read(offset, maxBytes) },
            close = { reader.close() },
        )
    }

    private fun decodeImage(file: File, maxEdgePx: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.absolutePath, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        val target = maxEdgePx.coerceIn(64, 4096)
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= target) sample *= 2
        val options = BitmapFactory.Options().apply {
            inSampleSize = sample
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        val decoded = BitmapFactory.decodeFile(file.absolutePath, options) ?: return null
        val longEdge = maxOf(decoded.width, decoded.height)
        if (longEdge <= target) return decoded
        val scale = target.toFloat() / longEdge
        val scaled = try {
            Bitmap.createScaledBitmap(
                decoded,
                (decoded.width * scale).roundToInt().coerceAtLeast(1),
                (decoded.height * scale).roundToInt().coerceAtLeast(1),
                true,
            )
        } catch (_: OutOfMemoryError) {
            null
        } ?: return decoded
        if (scaled !== decoded) runCatching { decoded.recycle() }
        return scaled
    }

    private fun drawPaper(canvas: Canvas, paper: NotePaper, width: Float, height: Float) {
        canvas.drawColor(Color.WHITE)
        if (paper == NotePaper.PLAIN) return
        val paint = Paint().apply {
            color = 0x1F000000
            strokeWidth = 0.8f
            isAntiAlias = false
        }
        if (paper == NotePaper.RULED) {
            var y = 32f
            while (y < height - 16f) {
                canvas.drawLine(24f, y, width - 24f, y, paint)
                y += 28f
            }
        } else if (paper == NotePaper.GRID) {
            var x = 24f
            while (x < width - 16f) {
                canvas.drawLine(x, 24f, x, height - 24f, paint)
                x += 28f
            }
            var y = 24f
            while (y < height - 16f) {
                canvas.drawLine(24f, y, width - 24f, y, paint)
                y += 28f
            }
        }
    }

    private fun clampBounds(rect: NoteRect, width: Float, height: Float): InkBox {
        val left = rect.x.toFloat().coerceIn(0f, width)
        val top = rect.y.toFloat().coerceIn(0f, height)
        val right = (rect.x + rect.width).toFloat().coerceIn(left, width)
        val bottom = (rect.y + rect.height).toFloat().coerceIn(top, height)
        if (right <= left || bottom <= top) return InkBox(0f, 0f, 1f, 1f)
        return InkBox(left, top, right, bottom)
    }

    private fun parseColor(hex: String?): Int =
        runCatching { Color.parseColor(hex?.trim().orEmpty()) }.getOrDefault(Color.BLACK)

    private fun isSha256(value: String?): Boolean =
        value != null && value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' }

    private fun looksLikeFloeInk(bytes: ByteArray): Boolean =
        bytes.size >= 8 && String(bytes, 0, 8, Charsets.US_ASCII) == InkFormat.MAGIC

    private fun mapOpenFailure(failed: PdfOpenResult.Failed): NotesPdfOpenOutcome = when (failed.failure) {
        PdfMediaFailure.PASSWORD_PROTECTED ->
            if (NotesMedia.passwordUnlockAvailable()) {
                NotesPdfOpenOutcome.PasswordRequired
            } else {
                NotesPdfOpenOutcome.Unavailable(
                    NotesPortFailure(NotesPortFailure.UNSUPPORTED, "passwordUnsupported"),
                )
            }
        PdfMediaFailure.PASSWORD_REJECTED -> NotesPdfOpenOutcome.PasswordRequired
        PdfMediaFailure.PASSWORD_UNSUPPORTED ->
            NotesPdfOpenOutcome.Unavailable(NotesPortFailure(NotesPortFailure.UNSUPPORTED, "passwordUnsupported"))
        PdfMediaFailure.INVALID_PDF ->
            NotesPdfOpenOutcome.Failed(NotesPortFailure(NotesPortFailure.FAILED, "invalidPdf"))
        PdfMediaFailure.BUSY ->
            NotesPdfOpenOutcome.Unavailable(NotesPortFailure(NotesPortFailure.BUSY, "rendererBusy"))
        PdfMediaFailure.SOURCE_CHANGED ->
            NotesPdfOpenOutcome.Failed(NotesPortFailure(NotesPortFailure.FAILED, "sourceChanged"))
        PdfMediaFailure.CANCELLED ->
            NotesPdfOpenOutcome.Failed(NotesPortFailure(NotesPortFailure.CANCELLED, "cancelled"))
        else ->
            NotesPdfOpenOutcome.Unavailable(
                NotesPortFailure(NotesPortFailure.UNAVAILABLE, failed.failure.name.lowercase(Locale.ROOT)),
            )
    }

    private fun mapPrintStartFailure(start: NotesPrintStart): NotesPrintOutcome = when (start) {
        NotesPrintStart.DIALOG_OPENED -> NotesPrintOutcome.Launched
        NotesPrintStart.NO_PRINT_SERVICE ->
            NotesPrintOutcome.Unavailable(NotesPortFailure(NotesPortFailure.NOT_CONFIGURED, "noPrintService"))
        NotesPrintStart.SOURCE_UNAVAILABLE ->
            NotesPrintOutcome.Failed(NotesPortFailure(NotesPortFailure.FAILED, "sourceUnavailable"))
        NotesPrintStart.ACTIVITY_RETIRED ->
            NotesPrintOutcome.Failed(NotesPortFailure(NotesPortFailure.FAILED, "activityRetired"))
        NotesPrintStart.SESSION_CLOSED ->
            NotesPrintOutcome.Failed(NotesPortFailure(NotesPortFailure.FAILED, "sessionClosed"))
    }

    private fun mapPrintStartFailure(failure: PdfMediaFailure?): NotesPrintOutcome = when (failure) {
        PdfMediaFailure.INVALID_PDF ->
            NotesPrintOutcome.Failed(NotesPortFailure(NotesPortFailure.FAILED, "invalidPdf"))
        PdfMediaFailure.PASSWORD_PROTECTED, PdfMediaFailure.PASSWORD_REJECTED ->
            NotesPrintOutcome.Failed(NotesPortFailure(NotesPortFailure.UNSUPPORTED, "passwordProtected"))
        null -> NotesPrintOutcome.Failed(NotesPortFailure(NotesPortFailure.FAILED, "printOpenFailed"))
        else -> NotesPrintOutcome.Unavailable(
            NotesPortFailure(NotesPortFailure.UNAVAILABLE, failure.name.lowercase(Locale.ROOT)),
        )
    }

    private class PdfHandle(
        private val session: PdfDocumentSession,
        override val documentID: String,
        override val resourceID: String,
        private val work: File,
        private val ioDispatcher: CoroutineDispatcher,
    ) : NotesPdfHandle {
        private val closed = AtomicBoolean(false)

        override val pageCount: Int get() = session.pageCount

        override fun pageSize(pageIndex: Int): NotesPdfPageSize? {
            if (closed.get() || pageIndex !in 0 until session.pageCount) return null
            val box = session.pageBox(PdfPageId(pageIndex)) ?: return null
            return NotesPdfPageSize(box.displayedWidthPt, box.displayedHeightPt)
        }

        override suspend fun renderPage(pageIndex: Int, targetWidthPx: Int): ByteArray {
            if (closed.get()) throw NotesPlatformErrors.failed("sessionClosed")
            if (pageIndex !in 0 until session.pageCount) throw NotesPlatformErrors.failed("pageOutOfRange")
            val page = PdfPageId(pageIndex)
            val box = session.pageBox(page) ?: throw NotesPlatformErrors.failed("pageUnavailable")
            val zoom = PdfRenderPlanner.zoomPercentForWidth(box, targetWidthPx.coerceIn(32, 8192))
            val result = session.renderPage(page, zoom)
            if (result !is PdfPageRenderResult.Ready) {
                throw NotesPlatformErrors.failed("render:" + (result as? PdfPageRenderResult.Failed)?.failure?.name)
            }
            try {
                return withContext(ioDispatcher) {
                    val output = java.io.ByteArrayOutputStream()
                    if (!result.bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) {
                        throw NotesPlatformErrors.failed("pngEncode")
                    }
                    output.toByteArray()
                }
            } finally {
                session.releaseBitmap(result)
            }
        }

        override suspend fun search(
            query: String,
            limit: Int,
            matchCase: Boolean,
        ): NotesPdfSearchOutcome {
            if (closed.get()) return NotesPdfSearchOutcome.Unavailable("sessionClosed")
            if (matchCase) return NotesPdfSearchOutcome.Unavailable("caseSensitiveSearchUnsupported")
            return try {
                when (val outcome = session.searchTextAwait(query, limit.coerceIn(1, 200))) {
                    is PdfTextSearchOutcome.Matches -> {
                        val hits = outcome.matches.mapNotNull { match ->
                            val page = match.page.pageIndex
                            if (page !in 0 until session.pageCount) return@mapNotNull null
                            val box = session.pageBox(match.page)
                            val rects = if (box != null) {
                                match.rects.mapNotNull { rect ->
                                    val left = (rect.left / box.displayedWidthPt).coerceIn(0f, 1f)
                                    val top = (rect.top / box.displayedHeightPt).coerceIn(0f, 1f)
                                    val right = (rect.right / box.displayedWidthPt).coerceIn(0f, 1f)
                                    val bottom = (rect.bottom / box.displayedHeightPt).coerceIn(0f, 1f)
                                    if (right > left && bottom > top) {
                                        NotesNormalizedRect(left, top, right, bottom)
                                    } else null
                                }
                            } else emptyList()
                            NotesPdfSearchHit(page, match.snippet, rects)
                        }
                        NotesPdfSearchOutcome.Matches(hits, outcome.truncated)
                    }
                    is PdfTextSearchOutcome.NoMatches -> {
                        if (outcome.truncated) {
                            NotesPdfSearchOutcome.Unavailable("searchTruncated")
                        } else {
                            NotesPdfSearchOutcome.NoMatches
                        }
                    }
                    is PdfTextSearchOutcome.NeedsOcr ->
                        NotesPdfSearchOutcome.NeedsOcr(emptyList())
                    is PdfTextSearchOutcome.Unavailable ->
                        NotesPdfSearchOutcome.Unavailable(outcome.reason.name)
                    is PdfTextSearchOutcome.StaleSource -> NotesPdfSearchOutcome.StaleSource
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                NotesPdfSearchOutcome.Unavailable("searchFailed")
            }
        }

        override suspend fun close() {
            if (!closed.compareAndSet(false, true)) return
            withContext(ioDispatcher) {
                runCatching { session.close() }
                NotesPlatformFiles.deleteQuietly(work)
            }
        }
    }
}

/**
 * One stable View-based ink surface. Stroke state, selection and undo stay in
 * the media layer; the UI only hosts the View and receives complete FLOEINK1
 * bytes after a committed change. Partial/cancelled strokes are never encoded
 * because the codec snapshots only committed strokes.
 */
internal class NotesInkSurfaceImpl(
    private val inkView: InkCanvasView,
    private var document: InkDocument,
    initialTool: NotesInkToolSpec,
    private val onDrawingChanged: (ByteArray) -> Unit,
) : NotesInkSurface {

    private var closed = false
    private var loading = false
    private var readOnly = false
    private var interactionEnabled = false
    private var lastEmitted: ByteArray? = null
    private var lastLoaded: ByteArray? = null
    private var tool: NotesInkToolSpec = initialTool
    private var selectionListener: ((Int) -> Unit)? = null
    private var canUndoFlag = false
    private var canRedoFlag = false
    private var selectionCountValue = 0

    fun start() {
        inkView.listener = object : InkCanvasView.Listener {
            override fun onDocumentChanged(snapshot: InkSnapshot, canUndo: Boolean, canRedo: Boolean) {
                canUndoFlag = canUndo
                canRedoFlag = canRedo
                if (loading || readOnly || closed) return
                val bytes = encode(snapshot) ?: return
                if (lastEmitted?.contentEquals(bytes) == true) return
                lastEmitted = bytes
                onDrawingChanged(bytes.copyOf())
            }

            override fun onSelectionChanged(selected: Set<Long>) {
                selectionCountValue = selected.size
                selectionListener?.invoke(selectionCountValue)
            }
        }
        inkView.setOnTouchListener { _, _ -> !interactionEnabled || readOnly }
        applyTool(tool)
        load(document, bytes = null)
    }

    /** Optional listener used by a UI that wants live selection counts. */
    override fun setOnSelectionChanged(listener: ((Int) -> Unit)?) {
        selectionListener = listener
        listener?.invoke(selectionCountValue)
    }

    override val view: View get() = inkView
    override val isReadOnly: Boolean get() = readOnly

    override fun setDrawing(drawing: ByteArray?) {
        if (closed) return
        if (drawing == null || drawing.isEmpty()) {
            val previous = lastLoaded
            if (previous == null || previous.isNotEmpty()) {
                load(emptyDocument(), bytes = null)
                lastLoaded = ByteArray(0)
            }
            return
        }
        if (lastEmitted?.contentEquals(drawing) == true) return
        if (lastLoaded?.contentEquals(drawing) == true) return
        if (!looksLikeFloeInk(drawing)) {
            // Apple PencilKit / unknown future ink: preserve the resource,
            // refuse to decode or overwrite it, and stop accepting strokes.
            readOnly = true
            inkView.setOnTouchListener { _, _ -> true }
            lastLoaded = drawing.copyOf()
            return
        }
        when (val decoded = InkDocumentCodec.decode(drawing)) {
            is InkDecodeResult.Ok -> {
                load(InkDocument.fromSnapshot(decoded.snapshot), bytes = drawing)
            }
            is InkDecodeResult.Invalid -> {
                readOnly = true
                inkView.setOnTouchListener { _, _ -> true }
                lastLoaded = drawing.copyOf()
            }
        }
    }

    override fun currentDrawing(): ByteArray? {
        if (closed) return null
        return encode(document.snapshot())
    }

    override fun setTool(tool: NotesInkToolSpec) {
        this.tool = tool
        if (!closed) applyTool(tool)
    }

    override fun setInteractionEnabled(enabled: Boolean) {
        interactionEnabled = enabled
        if (!closed) inkView.setOnTouchListener { _, _ -> !interactionEnabled || readOnly }
    }

    override fun undo(): Boolean {
        if (closed || readOnly) return false
        return inkView.undo()
    }

    override fun redo(): Boolean {
        if (closed || readOnly) return false
        return inkView.redo()
    }

    override val canUndo: Boolean get() = canUndoFlag

    override val canRedo: Boolean get() = canRedoFlag

    override fun deleteSelection(): Boolean {
        if (closed || readOnly) return false
        return inkView.deleteSelection()
    }

    override fun selectionCount(): Int = selectionCountValue

    override suspend fun captureSelectionPng(maxWidthPx: Int): ByteArray? = null

    override fun dispose() {
        if (closed) return
        closed = true
        inkView.listener = null
        inkView.setOnTouchListener(null)
        runCatching { inkView.cancelInProgress() }
        runCatching { inkView.loadDocument(null) }
    }

    private fun load(next: InkDocument, bytes: ByteArray?) {
        document = next
        loading = true
        try {
            inkView.loadDocument(next)
        } finally {
            loading = false
        }
        canUndoFlag = next.canUndo
        canRedoFlag = next.canRedo
        if (bytes != null) {
            lastLoaded = bytes.copyOf()
            lastEmitted = bytes.copyOf()
        }
    }

    private fun emptyDocument(): InkDocument = InkDocument(document.documentId, document.geometry)

    private fun encode(snapshot: InkSnapshot): ByteArray? = when (val encoded = InkDocumentCodec.encode(snapshot)) {
        is InkEncodeResult.Ok -> encoded.bytes
        is InkEncodeResult.Refused -> null
    }

    private fun applyTool(tool: NotesInkToolSpec) {
        if (readOnly) {
            inkView.setOnTouchListener { _, _ -> true }
            return
        }
        inkView.setInputConfig(
            InkInputConfig(
                fingerWriting = !tool.penOnly && tool.fingerDrawing,
                penOnly = tool.penOnly,
                mouseDraws = true,
                twoFingerTransform = true,
            ),
        )
        when (tool.kind) {
            NotesInkToolKind.ERASER -> {
                inkView.setEraserMode(true)
                inkView.setSelectionMode(false)
            }
            NotesInkToolKind.LASSO -> {
                inkView.setEraserMode(false)
                inkView.setSelectionMode(true)
            }
            NotesInkToolKind.PEN -> {
                inkView.setEraserMode(false)
                inkView.setSelectionMode(false)
                inkView.setBrush(
                    InkBrushSpec.pen(
                        notesColor(tool.colorHex),
                        tool.width.coerceIn(InkBrushSpec.MIN_WIDTH_PT, 32f),
                    ),
                )
            }
            NotesInkToolKind.MARKER -> {
                inkView.setEraserMode(false)
                inkView.setSelectionMode(false)
                inkView.setBrush(
                    InkBrushSpec.highlighter(
                        notesColor(tool.colorHex),
                        tool.width.coerceIn(1f, InkBrushSpec.MAX_WIDTH_PT),
                    ),
                )
            }
        }
    }
}

private fun notesColor(hex: String?): Int =
    runCatching { Color.parseColor(hex?.trim().orEmpty()) }.getOrDefault(Color.BLACK)

private fun looksLikeFloeInk(bytes: ByteArray): Boolean =
    bytes.size >= 8 && String(bytes, 0, 8, Charsets.US_ASCII) == InkFormat.MAGIC
