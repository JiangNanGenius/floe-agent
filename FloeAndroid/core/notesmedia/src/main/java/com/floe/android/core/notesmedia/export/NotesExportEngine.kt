// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.export

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.pdf.PdfDocument
import androidx.ink.rendering.android.canvas.CanvasStrokeRenderer
import com.floe.android.core.notesmedia.ink.InkNativeBridge
import com.floe.android.core.notesmedia.media.Sha256Hex
import com.floe.android.core.notesmedia.pdf.PdfDocumentSession
import com.floe.android.core.notesmedia.pdf.PdfGeometryResult
import com.floe.android.core.notesmedia.pdf.PdfMediaFailure
import com.floe.android.core.notesmedia.pdf.PdfPageBoxReader
import com.floe.android.core.notesmedia.pdf.PdfPageRenderResult
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.security.MessageDigest
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/** Verified facts about a produced file, read back from its actual bytes. */
data class ExportReadback(
    val file: File,
    val byteCount: Long,
    val sha256: String,
    val pageCount: Int,
    val pageWidthsPt: List<Int>,
    val pageHeightsPt: List<Int>,
    /** What kind of PDF this actually is (never inferred as lossless). */
    val fidelity: NotesPdfExportFidelity = NotesPdfExportFidelity.RASTERIZED_COPY,
    /** False for the implemented rasterized route. */
    val sourceTextPreserved: Boolean = false,
    /** False for the implemented rasterized route. */
    val sourceVectorContentPreserved: Boolean = false,
)

enum class NotesExportFailure {
    NO_GEOMETRY,
    PAGE_UNVERIFIED,
    RENDER_FAILED,
    CANCELLED,
    IO_ERROR,
    DESTINATION_EXISTS,
    WRITE_FAILED,
    READBACK_MISMATCH,
    INK_RENDER_FAILED,
    OVERLAY_INVALID,
    IMAGE_HEADER_UNREADABLE,
}

sealed class PdfExportResult {
    data class Ok(val readback: ExportReadback) : PdfExportResult()
    data class Failed(val failure: NotesExportFailure) : PdfExportResult()
}

enum class ImageFormat(val mimeType: String, val extension: String) {
    PNG("image/png", "png"),
    JPEG("image/jpeg", "jpg"),
}

data class ImageExportResult(
    val file: File?,
    val byteCount: Long,
    val sha256: String?,
    val widthPx: Int,
    val heightPx: Int,
    val failure: NotesExportFailure? = null,
) {
    val ok: Boolean get() = failure == null
}

/**
 * Real PDF/image export over the verified source snapshot and caller-owned
 * overlays.
 *
 * Guarantees:
 *  - output page size = the source page's DISPLAYED size in points (page
 *    orientation preserved: a /Rotate 90 page exports at its displayed
 *    landscape size), verified against the rendered bitmap aspect before any
 *    page is written;
 *  - FIDELITY IS EXPLICIT: this is a RASTERIZED copy at the bounded render
 *    size (≈144 DPI target, 2048 px edge cap) with overlays drawn on top. The
 *    source text/vector structure is NOT preserved in the output and the
 *    original file is never modified. [ExportReadback] carries those flags;
 *    callers must not present the result as lossless. A native preserving
 *    route is not enabled (see [NotesExportCapabilities]);
 *  - overlays are drawn in paper coordinates with an explicit clip; ink is
 *    rendered by the same androidx.ink renderer used on screen;
 *  - the PDF/image is written to a staging file in the SAME directory, fsynced,
 *    then READ BACK from its bytes (page count + page boxes for PDF, pixel
 *    dimensions for images) before an atomic rename;
 *  - cancellation or any failure deletes the staging file and never touches an
 *    existing destination; overwrite requires [overwrite] = true explicitly;
 *  - printing is NOT done here (see [NotesPrintBridge]) — the verified source
 *    bytes go to the system print adapter unchanged.
 */
class NotesExportEngine(private val session: PdfDocumentSession) {

    private val inkRenderer: CanvasStrokeRenderer by lazy { CanvasStrokeRenderer.create() }

    suspend fun exportPdf(
        plan: NotesExportPlan,
        destination: File,
        overwrite: Boolean = false,
        isCancelled: () -> Boolean = { false },
    ): PdfExportResult = withContext(Dispatchers.IO) {
        if (plan.sourceSha256 != session.source.sha256) return@withContext PdfExportResult.Failed(NotesExportFailure.NO_GEOMETRY)
        if (destination.exists() && !overwrite) {
            return@withContext PdfExportResult.Failed(NotesExportFailure.DESTINATION_EXISTS)
        }
        val temp = stagingFile(destination)
        val document = PdfDocument()
        try {
            plan.pages.forEachIndexed { index, pagePlan ->
                if (isCancelled()) {
                    return@withContext abort(document, temp, NotesExportFailure.CANCELLED)
                }
                val render = session.renderForExport(pagePlan.page, pagePlan.renderZoomPercent)
                if (render !is PdfPageRenderResult.Ready) {
                    return@withContext abort(document, temp, NotesExportFailure.RENDER_FAILED)
                }
                try {
                    if (!pagePlan.box.matchesRenderedAspect(render.widthPx, render.heightPx)) {
                        return@withContext abort(document, temp, NotesExportFailure.PAGE_UNVERIFIED)
                    }
                    val info = PdfDocument.PageInfo.Builder(
                        pagePlan.outputWidthPt,
                        pagePlan.outputHeightPt,
                        index + 1,
                    ).create()
                    val page = document.startPage(info)
                    try {
                        drawPage(page.canvas, pagePlan, render.bitmap)
                    } finally {
                        document.finishPage(page)
                    }
                } finally {
                    session.releaseBitmap(render)
                }
            }
            val digest = MessageDigest.getInstance("SHA-256")
            FileOutputStream(temp).use { out ->
                document.writeTo(out)
                out.flush()
                runCatching { out.fd.sync() }
            }
            // The digest is computed by reading back the actual staging bytes.
            val bytes = temp.readBytesOrNull() ?: return@withContext abort(document, temp, NotesExportFailure.IO_ERROR)
            digest.update(bytes)
            val sha = Sha256Hex.encode(digest.digest())
            val readback = when (val geometry = PdfPageBoxReader().read(temp, sha)) {
                is PdfGeometryResult.Refused -> return@withContext abort(document, temp, NotesExportFailure.READBACK_MISMATCH)
                is PdfGeometryResult.Ok -> geometry.geometry
            }
            if (readback.pageCount != plan.pages.size) {
                return@withContext abort(document, temp, NotesExportFailure.READBACK_MISMATCH)
            }
            for (i in plan.pages.indices) {
                val expected = plan.pages[i]
                val actual = readback.pages[i]
                if (kotlin.math.abs(actual.displayedWidthPt - expected.outputWidthPt) > 1.5f ||
                    kotlin.math.abs(actual.displayedHeightPt - expected.outputHeightPt) > 1.5f
                ) {
                    return@withContext abort(document, temp, NotesExportFailure.READBACK_MISMATCH)
                }
            }
            if (!commit(temp, destination, overwrite)) {
                return@withContext abort(document, temp, NotesExportFailure.IO_ERROR)
            }
            PdfExportResult.Ok(
                ExportReadback(
                    file = destination,
                    byteCount = bytes.size.toLong(),
                    sha256 = sha,
                    pageCount = readback.pageCount,
                    pageWidthsPt = readback.pages.map { it.displayedWidthPt.toInt() },
                    pageHeightsPt = readback.pages.map { it.displayedHeightPt.toInt() },
                    fidelity = NotesPdfExportFidelity.RASTERIZED_COPY,
                    sourceTextPreserved = false,
                    sourceVectorContentPreserved = false,
                ),
            )
        } catch (_: IOException) {
            abort(document, temp, NotesExportFailure.IO_ERROR)
        } catch (_: SecurityException) {
            abort(document, temp, NotesExportFailure.IO_ERROR)
        } finally {
            runCatching { document.close() }
        }
    }

    suspend fun exportImage(
        pagePlan: NotesExportPagePlan,
        destination: File,
        format: ImageFormat = ImageFormat.PNG,
        maxEdgePx: Int = 2_400,
        backgroundColorArgb: Int? = null,
        overwrite: Boolean = false,
        isCancelled: () -> Boolean = { false },
    ): ImageExportResult = withContext(Dispatchers.IO) {
        if (destination.exists() && !overwrite) {
            return@withContext failedImage(NotesExportFailure.DESTINATION_EXISTS)
        }
        if (isCancelled()) return@withContext failedImage(NotesExportFailure.CANCELLED)
        val targetEdge = maxEdgePx.coerceIn(64, 8_192)
        val zoom = com.floe.android.core.notesmedia.pdf.PdfRenderPlanner.thumbnailZoomPercent(pagePlan.box, targetEdge)
        val render = session.renderForExport(pagePlan.page, zoom)
        if (render !is PdfPageRenderResult.Ready) return@withContext failedImage(NotesExportFailure.RENDER_FAILED)
        val temp = stagingFile(destination)
        var mutable: Bitmap? = null
        try {
            if (!pagePlan.box.matchesRenderedAspect(render.widthPx, render.heightPx)) {
                return@withContext failedImage(NotesExportFailure.PAGE_UNVERIFIED)
            }
            mutable = try {
                render.bitmap.copy(Bitmap.Config.ARGB_8888, true)
            } catch (_: OutOfMemoryError) {
                null
            } ?: return@withContext failedImage(NotesExportFailure.WRITE_FAILED)
            val canvas = Canvas(mutable)
            backgroundColorArgb?.let { canvas.drawColor(it) }
            // Separate axes keep overlays exact even when the renderer's
            // rounding leaves a sub-pixel aspect difference.
            val scaleX = mutable.width / pagePlan.box.displayedWidthPt
            val scaleY = mutable.height / pagePlan.box.displayedHeightPt
            canvas.save()
            canvas.scale(scaleX, scaleY)
            drawOverlays(canvas, pagePlan, inkScaleX = 1f, inkScaleY = 1f)
            canvas.restore()
            val quality = if (format == ImageFormat.JPEG) 95 else 100
            val compressFormat = if (format == ImageFormat.JPEG) Bitmap.CompressFormat.JPEG else Bitmap.CompressFormat.PNG
            val fileOut = FileOutputStream(temp)
            val wrote = try {
                mutable.compress(compressFormat, quality, fileOut).also { fileOut.flush(); runCatching { fileOut.fd.sync() } }
            } finally {
                runCatching { fileOut.close() }
            }
            if (!wrote) return@withContext abortImage(temp, NotesExportFailure.WRITE_FAILED)
            val bytes = temp.readBytesOrNull() ?: return@withContext abortImage(temp, NotesExportFailure.IO_ERROR)
            val header = ImageHeaderReader.read(bytes) ?: return@withContext abortImage(
                temp,
                NotesExportFailure.IMAGE_HEADER_UNREADABLE,
            )
            if (header.first != mutable.width || header.second != mutable.height) {
                return@withContext abortImage(temp, NotesExportFailure.READBACK_MISMATCH)
            }
            if (!commit(temp, destination, overwrite)) {
                return@withContext abortImage(temp, NotesExportFailure.IO_ERROR)
            }
            ImageExportResult(
                file = destination,
                byteCount = bytes.size.toLong(),
                sha256 = Sha256Hex.encode(MessageDigest.getInstance("SHA-256").digest(bytes)),
                widthPx = header.first,
                heightPx = header.second,
            )
        } catch (_: IOException) {
            abortImage(temp, NotesExportFailure.IO_ERROR)
        } catch (_: SecurityException) {
            abortImage(temp, NotesExportFailure.IO_ERROR)
        } finally {
            mutable?.let { if (!it.isRecycled) runCatching { it.recycle() } }
            session.releaseBitmap(render)
        }
    }

    // ------------------------------------------------------------------
    // Drawing
    // ------------------------------------------------------------------

    private fun drawPage(canvas: Canvas, pagePlan: NotesExportPagePlan, bitmap: Bitmap) {
        val paint = Paint(Paint.FILTER_BITMAP_FLAG)
        val src = Rect(0, 0, bitmap.width, bitmap.height)
        val dst = RectF(0f, 0f, pagePlan.outputWidthPt.toFloat(), pagePlan.outputHeightPt.toFloat())
        canvas.drawBitmap(bitmap, src, dst, paint)
        drawOverlays(canvas, pagePlan, inkScaleX = 1f, inkScaleY = 1f)
    }

    private fun drawOverlays(canvas: Canvas, pagePlan: NotesExportPagePlan, inkScaleX: Float, inkScaleY: Float) {
        val clip = RectF(
            0f,
            0f,
            pagePlan.box.displayedWidthPt,
            pagePlan.box.displayedHeightPt,
        )
        val checkpoint = canvas.save()
        canvas.clipRect(clip)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        for (overlay in pagePlan.overlays) {
            when (overlay) {
                is NotesOverlay.Image -> {
                    paint.reset()
                    paint.isAntiAlias = true
                    paint.alpha = (overlay.opacity.coerceIn(0f, 1f) * 255f).toInt()
                    paint.isFilterBitmap = true
                    canvas.drawBitmap(
                        overlay.bitmap,
                        Rect(0, 0, overlay.bitmap.width, overlay.bitmap.height),
                        RectF(overlay.bounds.left, overlay.bounds.top, overlay.bounds.right, overlay.bounds.bottom),
                        paint,
                    )
                }

                is NotesOverlay.Shape -> {
                    paint.reset()
                    paint.isAntiAlias = true
                    paint.style = Paint.Style.STROKE
                    paint.strokeWidth = overlay.strokeWidthPt
                    paint.color = overlay.colorArgb
                    paint.strokeCap = Paint.Cap.ROUND
                    val l = overlay.bounds.left
                    val t = overlay.bounds.top
                    val r = overlay.bounds.right
                    val b = overlay.bounds.bottom
                    when (overlay.kind) {
                        NotesShapeKind.RECT -> canvas.drawRect(l, t, r, b, paint)
                        NotesShapeKind.ELLIPSE -> canvas.drawOval(RectF(l, t, r, b), paint)
                        NotesShapeKind.LINE -> canvas.drawLine(l, t, r, b, paint)
                        NotesShapeKind.ARROW -> drawArrow(canvas, l, t, r, b, paint)
                    }
                }

                is NotesOverlay.Text -> {
                    overlay.backgroundColorArgb?.let { bg ->
                        paint.reset()
                        paint.color = bg
                        canvas.drawRect(overlay.bounds.left, overlay.bounds.top, overlay.bounds.right, overlay.bounds.bottom, paint)
                    }
                    paint.reset()
                    paint.isAntiAlias = true
                    paint.color = overlay.colorArgb
                    paint.textSize = overlay.fontSizePt
                    paint.textAlign = when (overlay.align) {
                        NotesTextAlign.LEFT -> Paint.Align.LEFT
                        NotesTextAlign.CENTER -> Paint.Align.CENTER
                        NotesTextAlign.RIGHT -> Paint.Align.RIGHT
                    }
                    val x = when (overlay.align) {
                        NotesTextAlign.LEFT -> overlay.bounds.left
                        NotesTextAlign.CENTER -> (overlay.bounds.left + overlay.bounds.right) / 2f
                        NotesTextAlign.RIGHT -> overlay.bounds.right
                    }
                    val metrics = paint.fontMetrics
                    val lineHeight = (metrics.descent - metrics.ascent).coerceAtLeast(overlay.fontSizePt)
                    var baseline = overlay.bounds.top - metrics.ascent
                    var drawn = 0
                    for (line in overlay.text.split('\n')) {
                        if (baseline > overlay.bounds.bottom) break
                        canvas.drawText(line, x, baseline, paint)
                        baseline += lineHeight
                        drawn++
                        if (drawn > MAX_TEXT_LINES) break
                    }
                }

                is NotesOverlay.InkMark -> {
                    val snapshot = overlay.snapshot
                    if (snapshot.strokes.isEmpty()) continue
                    val sx = if (snapshot.geometry.widthPt > 0f) {
                        pagePlan.box.displayedWidthPt / snapshot.geometry.widthPt
                    } else {
                        1f
                    }
                    val sy = if (snapshot.geometry.heightPt > 0f) {
                        pagePlan.box.displayedHeightPt / snapshot.geometry.heightPt
                    } else {
                        1f
                    }
                    val inkCheckpoint = canvas.save()
                    canvas.scale(sx * inkScaleX, sy * inkScaleY)
                    for (stroke in snapshot.strokes) {
                        InkNativeBridge.drawOnPaperCanvas(canvas, inkRenderer, stroke)
                    }
                    canvas.restoreToCount(inkCheckpoint)
                }
            }
        }
        canvas.restoreToCount(checkpoint)
    }

    private fun drawArrow(canvas: Canvas, x0: Float, y0: Float, x1: Float, y1: Float, paint: Paint) {
        canvas.drawLine(x0, y0, x1, y1, paint)
        val angle = atan2((y1 - y0).toDouble(), (x1 - x0).toDouble())
        val head = (6.0 + paint.strokeWidth * 3.0)
        val path = Path()
        path.moveTo(x1, y1)
        path.lineTo(
            (x1 - head * cos(angle - Math.PI / 7)).toFloat(),
            (y1 - head * sin(angle - Math.PI / 7)).toFloat(),
        )
        path.lineTo(
            (x1 - head * cos(angle + Math.PI / 7)).toFloat(),
            (y1 - head * sin(angle + Math.PI / 7)).toFloat(),
        )
        path.close()
        val fill = Paint(paint)
        fill.style = Paint.Style.FILL
        canvas.drawPath(path, fill)
    }

    // ------------------------------------------------------------------
    // Staging / commit
    // ------------------------------------------------------------------

    private fun stagingFile(destination: File): File {
        val parent = destination.absoluteFile.parentFile ?: File(".")
        if (!parent.isDirectory) parent.mkdirs()
        return File(parent, ".staging-${destination.name}-${System.nanoTime()}")
    }

    private fun abort(document: PdfDocument, temp: File, failure: NotesExportFailure): PdfExportResult {
        runCatching { document.close() }
        runCatching { temp.delete() }
        return PdfExportResult.Failed(failure)
    }

    private fun abortImage(temp: File, failure: NotesExportFailure): ImageExportResult {
        runCatching { temp.delete() }
        return failedImage(failure)
    }

    private fun failedImage(failure: NotesExportFailure): ImageExportResult =
        ImageExportResult(file = null, byteCount = 0L, sha256 = null, widthPx = 0, heightPx = 0, failure = failure)

    /**
     * Atomic commit: rename into place only after the staging bytes were read
     * back and verified. When overwriting, the old file is moved aside first
     * and deleted only after the new file is in place, so a failure leaves
     * either the old file or the new file, never neither.
     */
    private fun commit(temp: File, destination: File, overwrite: Boolean): Boolean {
        if (!temp.isFile) return false
        if (destination.exists()) {
            if (!overwrite) return false
            val trash = File(destination.parentFile, ".trash-${destination.name}-${System.nanoTime()}")
            if (!destination.renameTo(trash)) return false
            if (!temp.renameTo(destination)) {
                trash.renameTo(destination)
                return false
            }
            trash.deleteRecursively()
            return true
        }
        if (!temp.renameTo(destination)) return false
        return destination.isFile
    }

    private fun File.readBytesOrNull(): ByteArray? = try {
        readBytes()
    } catch (_: IOException) {
        null
    }

    private companion object {
        const val MAX_TEXT_LINES = 500
    }
}

/** Pure image header reader (PNG IHDR / JPEG SOF) used for real pixel readback. */
object ImageHeaderReader {

    fun read(bytes: ByteArray): Pair<Int, Int>? {
        if (bytes.size >= 24 &&
            bytes[0] == 0x89.toByte() && bytes[1] == 0x50.toByte() &&
            bytes[2] == 0x4E.toByte() && bytes[3] == 0x47.toByte()
        ) {
            val width = readInt(bytes, 16)
            val height = readInt(bytes, 20)
            return if (width > 0 && height > 0) width to height else null
        }
        if (bytes.size >= 4 && bytes[0] == 0xFF.toByte() && bytes[1] == 0xD8.toByte()) {
            return readJpeg(bytes)
        }
        return null
    }

    private fun readJpeg(bytes: ByteArray): Pair<Int, Int>? {
        var i = 2
        while (i + 9 < bytes.size) {
            if (bytes[i].toInt() and 0xff != 0xFF) {
                i++
                continue
            }
            val marker = bytes[i + 1].toInt() and 0xff
            if (marker == 0xD8 || marker == 0xD9 || marker in 0xD0..0xD7) {
                i += 2
                continue
            }
            if (i + 3 >= bytes.size) return null
            val length = ((bytes[i + 2].toInt() and 0xff) shl 8) or (bytes[i + 3].toInt() and 0xff)
            if (length < 2) return null
            val isSof = marker in 0xC0..0xC3 || marker in 0xC5..0xC7 || marker in 0xC9..0xCB || marker in 0xCD..0xCF
            if (isSof) {
                if (i + 9 >= bytes.size) return null
                val height = ((bytes[i + 5].toInt() and 0xff) shl 8) or (bytes[i + 6].toInt() and 0xff)
                val width = ((bytes[i + 7].toInt() and 0xff) shl 8) or (bytes[i + 8].toInt() and 0xff)
                return if (width > 0 && height > 0) width to height else null
            }
            i += 2 + length
        }
        return null
    }

    private fun readInt(bytes: ByteArray, offset: Int): Int =
        ((bytes[offset].toInt() and 0xff) shl 24) or
            ((bytes[offset + 1].toInt() and 0xff) shl 16) or
            ((bytes[offset + 2].toInt() and 0xff) shl 8) or
            (bytes[offset + 3].toInt() and 0xff)

    /** Distance helper used by arrow heads (kept for symmetry with the drawing code). */
    internal fun length(dx: Float, dy: Float): Float = sqrt(dx * dx + dy * dy)
}

/** Convenience: default overlay colour constant independent of theme. */
object NotesOverlayColors {
    val DEFAULT_INK = Color.BLACK
}
