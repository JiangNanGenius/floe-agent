// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.notesocr

import com.floe.android.feature.notes.NoteDocument
import com.floe.android.feature.notes.NotesException
import com.floe.android.feature.notes.NotesPageOCRState
import com.floe.android.feature.notes.NotesProtocol
import com.floe.android.feature.notes.NotesService
import com.floe.android.feature.notes.ui.api.NotesExportElement
import com.floe.android.feature.notes.ui.api.NotesExportPage
import com.floe.android.feature.notes.ui.api.NotesExportedStream
import com.floe.android.feature.notes.ui.api.NotesIndexingAvailability
import com.floe.android.feature.notes.ui.api.NotesIndexingPort
import com.floe.android.feature.notes.ui.api.NotesIndexingRequest
import com.floe.android.feature.notes.ui.api.NotesIndexingResult
import com.floe.android.feature.notes.ui.api.NotesIndexingStatus
import com.floe.android.feature.notes.ui.api.NotesMediaPort
import com.floe.android.feature.notes.ui.api.NotesPageImageExportRequest
import com.floe.android.feature.notes.ui.api.NotesPortFailureException
import com.floe.android.feature.notes.ui.api.NotesResourceReader
import com.floe.android.feature.notes.ui.presentation.resolveElementText
import com.floe.android.host.notes.bool
import com.floe.android.host.notes.int
import com.floe.android.host.notes.long
import com.floe.android.host.notes.obj
import com.floe.android.host.notes.string
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.Base64
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

public data class NotesOcrStopReport(
    public val epoch: Long,
    public val cancelRequestedCount: Int,
    public val pendingCount: Int,
    public val canRetire: Boolean,
    public val retainedStageCount: Int,
)

public data class NotesOcrDrainReport(
    public val epoch: Long,
    public val drained: Boolean,
    public val pendingCount: Int,
    public val retainedStageCount: Int,
)

/** Narrow read/import seam over the REAL [NotesService]. */
internal interface NotesOcrNotesSource {
    suspend fun pageOCRState(documentID: String, pageID: String): NotesPageOCRState
    suspend fun document(documentID: String): NoteDocument
    suspend fun readResource(resourceID: String, offset: Long, maxBytes: Int): ByteArray
}

internal class NotesServiceOcrSource(
    private val service: NotesService,
) : NotesOcrNotesSource {
    override suspend fun pageOCRState(
        documentID: String,
        pageID: String,
    ): NotesPageOCRState = service.pageOCRState(documentID, pageID)

    override suspend fun document(documentID: String): NoteDocument =
        service.document(documentID)

    override suspend fun readResource(
        resourceID: String,
        offset: Long,
        maxBytes: Int,
    ): ByteArray = service.readResource(resourceID, offset, maxBytes).data
}

/** Narrow export seam over the REAL app-owned [NotesMediaPort]. */
internal fun interface NotesOcrPageRenderer {
    suspend fun exportPageImage(request: NotesPageImageExportRequest): NotesExportedStream
}

internal class NotesMediaOcrRenderer(
    private val media: NotesMediaPort,
) : NotesOcrPageRenderer {
    override suspend fun exportPageImage(
        request: NotesPageImageExportRequest,
    ): NotesExportedStream = media.exportPageImage(request)
}

/**
 * App-owned cloud page OCR. The STORED native page is the render authority:
 * UI-only text/element snapshots are never sent to the model. The recognized
 * text is returned only after the native source-key cache receipt is
 * `applied` or `unchanged`; a stale source is a typed failure, never a false
 * success.
 */
public class NotesOcrHost internal constructor(
    private val source: NotesOcrNotesSource,
    private val renderer: NotesOcrPageRenderer,
    private val bridge: NotesOcrBridge,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) : NotesIndexingPort {
    override suspend fun status(): NotesIndexingStatus = withContext(ioDispatcher) {
        readStatus()
    }

    override suspend fun recognize(
        request: NotesIndexingRequest,
    ): NotesIndexingResult = withContext(ioDispatcher) {
        val requestedDocumentID = request.documentID
        val requestedPageID = request.pageID
        if (requestedDocumentID.isBlank() || requestedPageID.isBlank()) {
            throw NotesException("invalidPayload", "ocrPageIdentity")
        }
        val state = source.pageOCRState(requestedDocumentID, requestedPageID)
        val cachedText = state.ocrText
        if (state.current && cachedText != null) {
            // Existing cached text is reused only when the NATIVE state marks
            // this exact source current; no provider request is made.
            return@withContext NotesIndexingResult(cachedText, null)
        }
        val status = readStatus()
        if (status.availability != NotesIndexingAvailability.READY) {
            throw NotesException(
                code = if (status.availability == NotesIndexingAvailability.UNSUPPORTED) {
                    "unsupported"
                } else {
                    "notConfigured"
                },
                reason = status.message ?: "ocrUnavailable",
                retryable = false,
            )
        }

        val document = source.document(requestedDocumentID)
        if (document.id != requestedDocumentID) {
            throw NotesException("invalidResponse", "documentChanged")
        }
        val pageIndex = document.pages.indexOfFirst { it.id == requestedPageID }
        if (pageIndex < 0) throw NotesException("notFound", "page")
        val page = document.pages[pageIndex]
        val pageNumber = (pageIndex + 1).takeIf { it in 1..10_000 }
            ?: request.pageNumber

        // The real saved page is rendered with the existing media exporter;
        // unsaved UI element text is deliberately NOT used as OCR content.
        val spec = NotesExportPage(
            pageID = page.id,
            widthPt = page.width.toFloat(),
            heightPt = page.height.toFloat(),
            paper = page.paper,
            pdfPageIndex = page.pdfPageIndex,
            pdfResourceID = page.backgroundResourceID.takeIf { page.pdfPageIndex != null },
            drawingResourceID = page.drawingResourceID,
            backgroundResourceID = page.backgroundResourceID,
            elements = page.elements.map { element ->
                NotesExportElement(
                    kind = element.kind,
                    frame = element.frame,
                    text = resolveElementText(document, element),
                    color = element.color,
                    fontSize = element.fontSize,
                    isMarkdown = element.isMarkdown,
                    imageResourceID = element.resourceID,
                )
            },
        )
        val stream = try {
            renderer.exportPageImage(
                NotesPageImageExportRequest(
                    documentID = document.id,
                    page = spec,
                    fileName = "notes-page.png",
                    targetWidthPx = 2048,
                    read = NotesResourceReader { resourceID, offset, maxBytes ->
                        source.readResource(resourceID, offset, maxBytes)
                    },
                ),
            )
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            throw error.asOcrFailure("ocrRenderFailed")
        }

        var stageID: String? = null
        try {
            val image = readBounded(stream)
            val dimensions = pngDimensions(image)
                ?: throw NotesException("invalidPayload", "ocrImageFormat")
            val digest = sha256Hex(image)
            val begun = bridge.perform(
                NotesOcrActions.STAGE_BEGIN,
                buildJsonObject {
                    put("documentID", document.id)
                    put("pageID", page.id)
                    put("sourceKey", state.visualIndexKey)
                    put("revision", document.revision)
                    put("pageNumber", pageNumber)
                    put("widthPt", page.width)
                    put("heightPt", page.height)
                    put("byteCount", image.size)
                    put("sha256", digest)
                    put("pixelWidth", dimensions.first)
                    put("pixelHeight", dimensions.second)
                },
            )
            val id = begun.requiredString("stageID")
            stageID = id
            val chunkBytes = begun.int("chunkBytes") ?: NotesProtocol.CHUNK_BYTES
            if (chunkBytes <= 0 || chunkBytes > NotesProtocol.CHUNK_BYTES) {
                throw NotesException("invalidResponse", "stageChunkBytes")
            }
            val declared = begun.long("totalBytes")
            if (declared != image.size.toLong()) {
                throw NotesException("invalidResponse", "stageTotalBytes")
            }
            var offset = 0
            while (offset < image.size) {
                val end = minOf(image.size, offset + chunkBytes)
                val chunk = image.copyOfRange(offset, end)
                val appended = bridge.perform(
                    NotesOcrActions.STAGE_APPEND,
                    buildJsonObject {
                        put("stageID", id)
                        put("offset", offset)
                        put("dataBase64", Base64.getEncoder().encodeToString(chunk))
                    },
                )
                if (appended.long("receivedBytes") != end.toLong()) {
                    throw NotesException("invalidResponse", "stageAppend")
                }
                offset = end
            }
            val reply = bridge.perform(
                NotesOcrActions.RECOGNIZE,
                buildJsonObject { put("stageID", id) },
            )
            val result = reply.obj("result")
                ?: throw NotesException("invalidResponse", "ocrResult")
            val cache = result.obj("cache")
            val cacheStatus = cache?.string("status")
            if (cacheStatus != "applied" && cacheStatus != "unchanged") {
                throw NotesException(
                    code = "ocrStale",
                    reason = cache?.string("reason") ?: "cacheNotApplied",
                    retryable = false,
                )
            }
            val text = result.string("text")
                ?: throw NotesException("invalidResponse", "ocrText")
            NotesIndexingResult(text, result.string("providerLabel"))
        } catch (cancelled: CancellationException) {
            stageID?.let { id ->
                withContext(NonCancellable) {
                    runCatching {
                        bridge.perform(
                            NotesOcrActions.STAGE_ABORT,
                            buildJsonObject { put("stageID", id) },
                        )
                    }
                }
            }
            throw cancelled
        } catch (error: Throwable) {
            stageID?.let { id ->
                runCatching {
                    bridge.perform(
                        NotesOcrActions.STAGE_ABORT,
                        buildJsonObject { put("stageID", id) },
                    )
                }
            }
            throw error
        } finally {
            runCatching { stream.close() }
        }
    }

    /**
     * Fences new OCR, cancels the actual provider request and waits for the
     * DOMAIN's real terminal. `canRetire == true` only at zero pending work.
     * A timeout returns `canRetire == false`; the caller must keep the root
     * open and retry (never treat the timeout as drain proof).
     */
    public suspend fun prepareForRootStop(
        epoch: Long,
        deadlineMillis: Int = 10_000,
    ): NotesOcrStopReport = withContext(ioDispatcher) {
        if (epoch <= 0L) {
            // No accepted root exists: no OCR work can be owned by this epoch.
            return@withContext NotesOcrStopReport(epoch, 0, 0, true, 0)
        }
        try {
            val response = bridge.perform(
                NotesOcrActions.PREPARE_ROOT_STOP,
                buildJsonObject { put("deadlineMillis", deadlineMillis) },
                epochOverride = epoch,
            )
            NotesOcrStopReport(
                epoch = epoch,
                cancelRequestedCount = response.int("cancelRequestedCount") ?: 0,
                pendingCount = response.int("pendingCount") ?: 0,
                canRetire = response.bool("canRetire") == true,
                retainedStageCount = response.int("retainedStageCount") ?: 0,
            )
        } catch (error: NotesException) {
            if (error.code == "notesNotBound" || error.code == "staleGeneration") {
                NotesOcrStopReport(epoch, 0, 0, true, 0)
            } else {
                NotesOcrStopReport(epoch, 0, 1, false, 0)
            }
        }
    }

    public suspend fun abortRootStop(epoch: Long) {
        if (epoch <= 0L) return
        withContext(ioDispatcher) {
            runCatching {
                bridge.perform(
                    NotesOcrActions.ABORT_ROOT_STOP,
                    buildJsonObject { put("epoch", epoch) },
                    epochOverride = epoch,
                )
            }
        }
    }

    public suspend fun resumeAfterRootChange(epoch: Long) {
        if (epoch <= 0L) return
        withContext(ioDispatcher) {
            bridge.perform(
                NotesOcrActions.RESUME_AFTER_ROOT_CHANGE,
                buildJsonObject { put("epoch", epoch) },
                epochOverride = epoch,
            )
        }
    }

    public suspend fun drain(epoch: Long): NotesOcrDrainReport = withContext(ioDispatcher) {
        if (epoch <= 0L) {
            return@withContext NotesOcrDrainReport(epoch, drained = true, pendingCount = 0, retainedStageCount = 0)
        }
        try {
            val response = bridge.perform(
                NotesOcrActions.DRAIN,
                buildJsonObject { put("epoch", epoch) },
                epochOverride = epoch,
            )
            NotesOcrDrainReport(
                epoch = epoch,
                drained = response.bool("drained") == true,
                pendingCount = response.int("pendingCount") ?: 0,
                retainedStageCount = response.int("retainedStageCount") ?: 0,
            )
        } catch (error: NotesException) {
            if (error.code == "notesNotBound" || error.code == "staleGeneration") {
                NotesOcrDrainReport(epoch, drained = true, pendingCount = 0, retainedStageCount = 0)
            } else {
                NotesOcrDrainReport(epoch, drained = false, pendingCount = 1, retainedStageCount = 0)
            }
        }
    }

    public suspend fun cancelActive() {
        withContext(ioDispatcher) {
            runCatching { bridge.perform(NotesOcrActions.CANCEL, null) }
        }
    }

    /** Final owner teardown only; call after a successful root drain. */
    public suspend fun close() {
        bridge.reset()
    }

    private suspend fun readStatus(): NotesIndexingStatus {
        val response = try {
            bridge.perform(NotesOcrActions.STATUS, null)
        } catch (error: NotesException) {
            return NotesIndexingStatus(
                availability = if (error.code == "ocrUnsupported" ||
                    error.code == "ocrTransportUnavailable"
                ) {
                    NotesIndexingAvailability.UNSUPPORTED
                } else {
                    NotesIndexingAvailability.NOT_CONFIGURED
                },
                providerLabel = null,
                message = error.reason ?: error.code,
            )
        }
        val availability = when (response.string("availability")) {
            "ready" -> NotesIndexingAvailability.READY
            "unsupported" -> NotesIndexingAvailability.UNSUPPORTED
            else -> NotesIndexingAvailability.NOT_CONFIGURED
        }
        return NotesIndexingStatus(
            availability = availability,
            providerLabel = response.string("providerLabel"),
            message = response.string("reason"),
        )
    }

    private suspend fun readBounded(stream: NotesExportedStream): ByteArray {
        val total = stream.totalBytes
        if (total <= 0L || total > MAX_IMAGE_BYTES) {
            throw NotesException("requestTooLarge", "ocrImage")
        }
        val output = ByteArrayOutputStream(total.coerceAtMost(MAX_IMAGE_BYTES).toInt())
        var offset = 0L
        while (offset < total) {
            val want = minOf(READ_CHUNK_BYTES, total - offset).toInt()
            val chunk = stream.read(offset, want)
            if (chunk.isEmpty()) break
            output.write(chunk)
            offset += chunk.size.toLong()
            if (offset > MAX_IMAGE_BYTES) {
                throw NotesException("requestTooLarge", "ocrImage")
            }
        }
        if (offset != total) {
            throw NotesException("invalidResponse", "ocrRenderIncomplete")
        }
        return output.toByteArray()
    }

    private fun pngDimensions(bytes: ByteArray): Pair<Int, Int>? {
        if (bytes.size < 33) return null
        val signature = byteArrayOf(
            0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        )
        for (index in signature.indices) {
            if (bytes[index] != signature[index]) return null
        }
        if (readBigEndian(bytes, 8) != 13) return null
        if (String(bytes, 12, 4, Charsets.US_ASCII) != "IHDR") return null
        val width = readBigEndian(bytes, 16)
        val height = readBigEndian(bytes, 20)
        if (width <= 0 || height <= 0) return null
        if (width > MAX_DIMENSION || height > MAX_DIMENSION) return null
        if (width.toLong() * height.toLong() > MAX_PIXEL_COUNT) return null
        return width to height
    }

    private fun readBigEndian(bytes: ByteArray, offset: Int): Int =
        ((bytes[offset].toInt() and 0xFF) shl 24) or
            ((bytes[offset + 1].toInt() and 0xFF) shl 16) or
            ((bytes[offset + 2].toInt() and 0xFF) shl 8) or
            (bytes[offset + 3].toInt() and 0xFF)

    private fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it) }

    private fun Throwable.asOcrFailure(fallback: String): NotesException = when (this) {
        is NotesException -> this
        is NotesPortFailureException -> NotesException(
            code = failure.code,
            reason = failure.detail,
            retryable = false,
        )
        else -> NotesException(fallback, message, retryable = false)
    }

    private companion object {
        const val MAX_IMAGE_BYTES = 8L * 1024L * 1024L
        const val READ_CHUNK_BYTES = 64L * 1024L
        const val MAX_DIMENSION = 16_384
        const val MAX_PIXEL_COUNT = 16_777_216L
    }
}

/**
 * Production factory. Main passes the SAME app-owned Notes service and
 * platform media host plus the existing `SwiftNotesTransport`; no path,
 * provider key or model is accepted here.
 */
public fun createNotesOcrHost(
    service: NotesService,
    media: NotesMediaPort,
    transport: NotesOcrTransport,
    epochProvider: () -> Long?,
    ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
): NotesOcrHost = NotesOcrHost(
    source = NotesServiceOcrSource(service),
    renderer = NotesMediaOcrRenderer(media),
    bridge = NotesOcrBridge(transport, epochProvider, ioDispatcher),
    ioDispatcher = ioDispatcher,
)
