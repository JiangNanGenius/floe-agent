// SPDX-License-Identifier: MPL-2.0
package com.floe.android.notesplatform

import com.floe.android.feature.notes.NotesException
import com.floe.android.feature.notes.NotesIndexCacheStatus
import com.floe.android.feature.notes.NotesOfficeTextRequest
import com.floe.android.feature.notes.NotesOfficeTextState
import com.floe.android.feature.notes.NotesProtocol
import com.floe.android.feature.notes.NotesService
import com.floe.android.feature.notes.ui.api.NotesOfficeIndexOutcome
import com.floe.android.feature.notes.ui.api.NotesOfficeIndexingPort
import com.floe.android.feature.notes.ui.api.NotesPortFailure
import com.floe.android.host.officeai.verification.BoundedZipReader
import com.floe.android.host.officeai.verification.CellIntentEvaluator
import com.floe.android.host.officeai.verification.DomUtil
import com.floe.android.host.officeai.verification.PartReadResult
import com.floe.android.host.officeai.verification.PptxText
import com.floe.android.host.officeai.verification.TrustedXml
import com.floe.android.host.officeai.verification.VerificationCodes
import com.floe.android.host.officeai.verification.WordText
import com.floe.android.host.officeai.verification.WorksheetCell
import com.floe.android.host.officeai.verification.XlsxParts
import com.floe.android.host.officeai.verification.XmlParseResult
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.Locale
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import org.w3c.dom.Element

/**
 * Bounded, read-only Office (OOXML) plain-text extraction for the Notes search
 * index.
 *
 * This is an INDEXER, not a second Office engine: it opens the exact immutable
 * resource with the existing verification package reader
 * ([BoundedZipReader] — central-directory parse, encryption refusal, entry and
 * inflation caps), parses only the text parts it needs with the existing
 * [TrustedXml] hardening (no DTD/entity, strict UTF-8), and reuses the actual
 * part normalizers ([WordText], [PptxText], [XlsxParts]/[CellIntentEvaluator])
 * that the Office AI verifier already proved against real saved files.
 *
 * Nothing is rendered, executed or rewritten; the source file is only read.
 * A legacy binary package (.doc/.xls/.ppt), an encrypted package or a package
 * that fails a bound is refused with a typed code instead of a fake empty
 * success.
 */
internal enum class NotesOfficeIndexFormat { DOCX, XLSX, PPTX }

internal sealed interface NotesOfficeExtraction {
    data class Text(val text: String, val truncated: Boolean) : NotesOfficeExtraction

    /** [unsupported] = the package is real but this indexer cannot read it. */
    data class Refused(val code: String, val unsupported: Boolean) : NotesOfficeExtraction
}

internal object NotesOfficeIndex {
    /** Hard ceiling on the immutable resource this indexer will copy/read. */
    const val MAX_RESOURCE_BYTES: Long = 96L * 1024 * 1024

    /** Bounded below the native cache's own 2,000,000-character truncation. */
    const val MAX_INDEX_CHARS: Int = 1_500_000

    private const val MAX_HEADER_FOOTER_PARTS = 32
    private const val MAX_SHEETS = 64
    private const val MAX_CELLS_PER_SHEET = 50_000
    private const val MAX_SLIDES = 512
    private const val TRUNCATION_MARKER = "\u2026"

    /** Extension/MIME admission using the existing OOXML kind table. */
    fun formatFor(fileName: String?, mediaType: String?): NotesOfficeIndexFormat? {
        val extension = NotesPlatformNames.extensionOf(fileName.orEmpty())
        val kind = NotesOoxmlKind.forExtension(extension)
            ?: NotesOoxmlTemplates.kindForMime(mediaType)
            ?: return null
        return when (kind) {
            NotesOoxmlKind.DOCX -> NotesOfficeIndexFormat.DOCX
            NotesOoxmlKind.XLSX -> NotesOfficeIndexFormat.XLSX
            NotesOoxmlKind.PPTX -> NotesOfficeIndexFormat.PPTX
        }
    }

    /** True when the extension is a legacy binary Office package. */
    fun isLegacyBinary(fileName: String?): Boolean =
        NotesPlatformNames.extensionOf(fileName.orEmpty()) in
            setOf("doc", "dot", "xls", "xlt", "ppt", "pot")

    /**
     * Extract index text from [file]. Every path is bounded and read-only; a
     * refusal explains itself with a stable code.
     */
    fun extract(file: File, format: NotesOfficeIndexFormat): NotesOfficeExtraction {
        val open = BoundedZipReader.open(file)
        val zip = when (open) {
            is com.floe.android.host.officeai.verification.ZipOpenResult.Refused ->
                return NotesOfficeExtraction.Refused(open.code, open.code == VerificationCodes.ZIP_ENCRYPTED)
            is com.floe.android.host.officeai.verification.ZipOpenResult.Ready -> open.zip
        }
        return try {
            when (format) {
                NotesOfficeIndexFormat.DOCX -> docx(zip)
                NotesOfficeIndexFormat.XLSX -> xlsx(zip)
                NotesOfficeIndexFormat.PPTX -> pptx(zip)
            }
        } catch (error: RuntimeException) {
            NotesOfficeExtraction.Refused(VerificationCodes.ZIP_MALFORMED, unsupported = false)
        } finally {
            zip.close()
        }
    }

    /* --------------------------------- DOCX --------------------------------- */

    private fun docx(zip: BoundedZipReader): NotesOfficeExtraction {
        val bodyBytes = when (val read = zip.readPart(WordText.DOCUMENT_PART)) {
            is PartReadResult.Bytes -> read.data
            is PartReadResult.Missing -> return NotesOfficeExtraction.Refused(
                VerificationCodes.PART_MISSING, unsupported = true,
            )
            is PartReadResult.Refused -> return NotesOfficeExtraction.Refused(read.code, false)
        }
        val body = when (val parsed = TrustedXml.parse(bodyBytes)) {
            is XmlParseResult.Parsed -> parsed.document
            is XmlParseResult.Refused ->
                return NotesOfficeExtraction.Refused(parsed.code, unsupported = false)
        }
        val out = BoundedIndexText()
        out.append(WordText.normalizedBodyText(body))
        // Header/footer/footnote/endnote parts are separate package parts; for
        // an INDEX they are real document text too. Each part is parsed with
        // the same hardened reader and bounded count.
        val extraParts = buildList {
            add("word/footnotes.xml")
            add("word/endnotes.xml")
            for (index in 1..MAX_HEADER_FOOTER_PARTS / 2) {
                add("word/header$index.xml")
                add("word/footer$index.xml")
            }
        }
        for (part in extraParts) {
            if (!zip.hasPart(part)) continue
            val bytes = when (val read = zip.readPart(part)) {
                is PartReadResult.Bytes -> read.data
                else -> continue
            }
            val document = when (val parsed = TrustedXml.parse(bytes)) {
                is XmlParseResult.Parsed -> parsed.document
                is XmlParseResult.Refused -> continue
            }
            out.append(WordText.normalizedBodyText(document))
        }
        return out.result()
    }

    /* --------------------------------- XLSX --------------------------------- */

    private fun xlsx(zip: BoundedZipReader): NotesOfficeExtraction {
        val plan = when (val planned = XlsxParts.plan(zip)) {
            is XlsxParts.WorkbookPlan.Ready -> planned
            is XlsxParts.WorkbookPlan.Refused ->
                return NotesOfficeExtraction.Refused(planned.code, unsupported = true)
        }
        val names = sheetNames(zip)
        val sharedStrings = when (val loaded = plan.sharedStringsPart?.let {
            XlsxParts.sharedStrings(zip, it)
        }) {
            is XlsxParts.SharedStringsResult.Ready -> loaded.strings
            is XlsxParts.SharedStringsResult.Refused -> return NotesOfficeExtraction.Refused(
                loaded.code, unsupported = false,
            )
            else -> null
        }
        val out = BoundedIndexText()
        var unresolved = 0
        plan.sheets.take(MAX_SHEETS).forEachIndexed { index, target ->
            val partName = target.partName ?: run {
                out.append("[${target.refusalCode ?: VerificationCodes.RELATION_UNRESOLVED}]")
                return@forEachIndexed
            }
            val bytes = when (val read = zip.readPart(partName)) {
                is PartReadResult.Bytes -> read.data
                else -> {
                    out.append("[${VerificationCodes.PART_MISSING}]")
                    return@forEachIndexed
                }
            }
            val sheet = when (val parsed = TrustedXml.parse(bytes)) {
                is XmlParseResult.Parsed -> parsed.document
                is XmlParseResult.Refused -> {
                    out.append("[${parsed.code}]")
                    return@forEachIndexed
                }
            }
            val name = names.getOrNull(index) ?: "Sheet ${index + 1}"
            out.append("## $name")
            var cells = 0
            val nodeList = DomUtil.elements(sheet, XlsxParts.S_NS, "c")
            for (element in nodeList) {
                if (cells >= MAX_CELLS_PER_SHEET || out.done) break
                cells += 1
                val address = element.getAttribute("r").trim().uppercase(Locale.ROOT)
                if (address.isEmpty()) continue
                val cell = toCell(element, address)
                val value = try {
                    CellIntentEvaluator.comparableFor(cell, sharedStrings)
                } catch (error: RuntimeException) {
                    null
                }
                if (value == null) {
                    unresolved += 1
                    continue
                }
                val formula = cell.formulaSource
                val line = when {
                    formula != null && value.isNotEmpty() -> "$address = $formula \u2192 $value"
                    formula != null -> "$address = $formula"
                    else -> "$address\t$value"
                }
                out.append(line)
            }
        }
        if (unresolved > 0) out.append("[${VerificationCodes.SHARED_STRING_INVALID}:$unresolved]")
        if (plan.sheets.size > MAX_SHEETS) out.markTruncated()
        return out.result()
    }

    private fun sheetNames(zip: BoundedZipReader): List<String> {
        val bytes = when (val read = zip.readPart(XlsxParts.WORKBOOK_PART)) {
            is PartReadResult.Bytes -> read.data
            else -> return emptyList()
        }
        val workbook = when (val parsed = TrustedXml.parse(bytes)) {
            is XmlParseResult.Parsed -> parsed.document
            is XmlParseResult.Refused -> return emptyList()
        }
        val names = ArrayList<String>()
        for (sheets in DomUtil.elements(workbook, XlsxParts.S_NS, "sheets")) {
            for (sheet in DomUtil.childElements(sheets, XlsxParts.S_NS, "sheet")) {
                names.add(sheet.getAttribute("name"))
            }
        }
        return names
    }

    /** Same persisted-cell projection as the verifier ([WorksheetCell]). */
    private fun toCell(element: Element, address: String): WorksheetCell {
        val type = element.getAttribute("t")
        val formula = DomUtil.firstElement(element, XlsxParts.S_NS, "f")
        val cached = DomUtil.firstElement(element, XlsxParts.S_NS, "v")
        val inline = DomUtil.firstElement(element, XlsxParts.S_NS, "is")
        val inlineText = if (inline == null) {
            null
        } else {
            val builder = StringBuilder()
            for (text in DomUtil.elementsWithin(inline, XlsxParts.S_NS, "t")) {
                builder.append(text.getTextContent() ?: "")
            }
            builder.toString()
        }
        val formulaText = formula?.getTextContent()
        return WorksheetCell(
            address = address,
            typeAttr = if (type.isEmpty()) null else type,
            hasFormula = formula != null,
            formulaSource = if (formulaText.isNullOrEmpty()) null else formulaText,
            formulaKind = formula?.getAttribute("t")?.takeIf { it.isNotEmpty() },
            formulaSi = formula?.getAttribute("si")?.takeIf { it.isNotEmpty() },
            cachedValue = cached?.getTextContent(),
            inlineText = inlineText,
        )
    }

    /* --------------------------------- PPTX --------------------------------- */

    private fun pptx(zip: BoundedZipReader): NotesOfficeExtraction {
        val ordered = when (val order = PptxText.resolveSlideOrder(zip)) {
            is PptxText.SlideOrderResult.Ordered -> order.slidePartNames
            is PptxText.SlideOrderResult.Refused ->
                return NotesOfficeExtraction.Refused(order.code, unsupported = true)
        }
        val out = BoundedIndexText()
        ordered.take(MAX_SLIDES).forEachIndexed { index, part ->
            val bytes = when (val read = zip.readPart(part)) {
                is PartReadResult.Bytes -> read.data
                else -> {
                    out.append("[${VerificationCodes.PART_MISSING}]")
                    return@forEachIndexed
                }
            }
            val slide = when (val parsed = TrustedXml.parse(bytes)) {
                is XmlParseResult.Parsed -> parsed.document
                is XmlParseResult.Refused -> {
                    out.append("[${parsed.code}]")
                    return@forEachIndexed
                }
            }
            out.append("## Slide ${index + 1}")
            out.append(PptxText.normalizedSlideText(slide))
        }
        if (ordered.size > MAX_SLIDES) out.markTruncated()
        return out.result()
    }

    /* -------------------------------- helpers ------------------------------- */

    private class BoundedIndexText {
        private val builder = StringBuilder()
        private var truncated = false

        val done: Boolean get() = builder.length >= MAX_INDEX_CHARS

        fun append(value: String) {
            if (value.isBlank() || done) return
            if (builder.isNotEmpty()) builder.append('\n')
            val remaining = MAX_INDEX_CHARS - builder.length
            if (remaining <= 1) {
                truncated = true
                return
            }
            if (value.length <= remaining) {
                builder.append(value)
            } else {
                var end = remaining - 1
                if (end > 0 && Character.isHighSurrogate(value[end - 1]) &&
                    end < value.length && Character.isLowSurrogate(value[end])
                ) {
                    end -= 1
                }
                builder.append(value, 0, end.coerceAtLeast(0))
                builder.append(TRUNCATION_MARKER)
                truncated = true
            }
        }

        fun markTruncated() {
            truncated = true
        }

        fun result(): NotesOfficeExtraction {
            val text = builder.toString()
            if (text.isBlank()) {
                return NotesOfficeExtraction.Text("", truncated)
            }
            return NotesOfficeExtraction.Text(text, truncated)
        }
    }
}

/**
 * Real Office → Notes index route.
 *
 * Reads the EXACT immutable resource through the native Notes service in
 * bounded chunks into an App-private work file (never a user path), extracts
 * text with [NotesOfficeIndex], then writes only through
 * `document.cacheOfficeText`, whose transaction revalidates the document, the
 * current `officeResourceID` and the revision. The work file is deleted in
 * every path; the original resource is never mutated.
 */
internal class NotesOfficeIndexer(
    private val service: NotesService,
    private val workRoot: File,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) : NotesOfficeIndexingPort {

    override fun supports(fileName: String?, mediaType: String?): Boolean =
        NotesOfficeIndex.formatFor(fileName, mediaType) != null

    override suspend fun index(
        documentID: String,
        sourceResourceID: String,
        expectedRevision: Int,
    ): NotesOfficeIndexOutcome = withContext(ioDispatcher) {
        val metadata = try {
            service.resourceMetadata(sourceResourceID)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            return@withContext NotesOfficeIndexOutcome.Failed(
                documentID = documentID,
                sourceResourceID = sourceResourceID,
                failure = NotesPortFailure(NotesPortFailure.UNAVAILABLE, "resourceUnavailable"),
                retryable = true,
            )
        }
        // A terminal cache for this exact source+revision (indexed text or a
        // stored refusal) answers without reading the bytes again. A note edit
        // bumps the revision, so one bounded re-attempt stays possible.
        cachedOutcome(documentID, sourceResourceID, expectedRevision)?.let { return@withContext it }
        if (metadata.byteCount <= 0L || metadata.byteCount > NotesOfficeIndex.MAX_RESOURCE_BYTES) {
            return@withContext recordRefusal(
                documentID, sourceResourceID, expectedRevision,
                reason = "resourceTooLarge", retryable = false,
            )
        }
        val format = NotesOfficeIndex.formatFor(metadata.fileName, metadata.mediaType)
        if (format == null) {
            val reason = if (NotesOfficeIndex.isLegacyBinary(metadata.fileName)) {
                "legacyBinaryFormat"
            } else {
                "unsupportedFormat"
            }
            return@withContext recordRefusal(
                documentID, sourceResourceID, expectedRevision, reason, retryable = false,
            )
        }
        val directory = try {
            NotesPlatformFiles.ensureDirectory(File(workRoot, "index"))
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            return@withContext NotesOfficeIndexOutcome.Failed(
                documentID, sourceResourceID,
                NotesPortFailure(NotesPortFailure.UNAVAILABLE, "storageUnavailable"),
                retryable = true,
            )
        }
        val work = File(directory, "source-" + UUID.randomUUID())
        try {
            copyResource(sourceResourceID, metadata.byteCount, work)
            val extraction = NotesOfficeIndex.extract(work, format)
            when (extraction) {
                is NotesOfficeExtraction.Refused -> {
                    val retryable = !extraction.unsupported &&
                        extraction.code !in setOf(
                            VerificationCodes.XML_UNTRUSTED,
                            VerificationCodes.XML_MALFORMED,
                            VerificationCodes.XML_ENCODING_INVALID,
                            VerificationCodes.XML_ENCODING_UNSUPPORTED,
                            VerificationCodes.ZIP_MALFORMED,
                            VerificationCodes.ZIP_UNSAFE_ENTRY,
                            VerificationCodes.ZIP_UNBOUNDED,
                            VerificationCodes.ZIP_TOO_MANY_ENTRIES,
                            VerificationCodes.ZIP_PART_TOO_LARGE,
                        )
                    if (retryable) {
                        NotesOfficeIndexOutcome.Failed(
                            documentID, sourceResourceID,
                            NotesPortFailure(NotesPortFailure.FAILED, extraction.code),
                            retryable = true,
                        )
                    } else {
                        recordRefusal(
                            documentID, sourceResourceID, expectedRevision,
                            reason = extraction.code, retryable = false,
                        )
                    }
                }
                is NotesOfficeExtraction.Text -> {
                    if (extraction.text.isBlank()) {
                        recordRefusal(
                            documentID, sourceResourceID, expectedRevision,
                            reason = "noExtractableText", retryable = false,
                        )
                    } else {
                        writeCache(
                            documentID = documentID,
                            sourceResourceID = sourceResourceID,
                            expectedRevision = expectedRevision,
                            text = extraction.text,
                            truncated = extraction.truncated,
                        )
                    }
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            NotesOfficeIndexOutcome.Failed(
                documentID, sourceResourceID,
                NotesPortFailure(NotesPortFailure.FAILED, error.message?.take(120) ?: "indexFailed"),
                retryable = true,
            )
        } finally {
            runCatching { NotesPlatformFiles.deleteQuietly(work) }
        }
    }

    private suspend fun cachedOutcome(
        documentID: String,
        sourceResourceID: String,
        expectedRevision: Int,
    ): NotesOfficeIndexOutcome? {
        val state = try {
            service.officeTextState(documentID)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            return null
        }
        if (state.sourceResourceID != sourceResourceID ||
            state.cachedResourceID != sourceResourceID ||
            state.revision != expectedRevision
        ) {
            return null
        }
        if (state.current && state.error == null) {
            return NotesOfficeIndexOutcome.UpToDate(
                documentID = documentID,
                sourceResourceID = sourceResourceID,
                revision = state.revision,
                textLength = state.textLength ?: 0,
            )
        }
        return when (val error = state.error) {
            null -> null
            "noExtractableText" -> NotesOfficeIndexOutcome.NoText(
                documentID, sourceResourceID, state.revision, error,
            )
            "unsupportedFormat", "legacyBinaryFormat" -> NotesOfficeIndexOutcome.Unsupported(
                documentID, sourceResourceID, error,
            )
            else -> NotesOfficeIndexOutcome.Failed(
                documentID, sourceResourceID,
                NotesPortFailure(NotesPortFailure.FAILED, error),
                retryable = false,
            )
        }
    }

    private suspend fun copyResource(resourceID: String, byteCount: Long, destination: File) {
        var offset = 0L
        var total = 0L
        FileOutputStream(destination).use { output ->
            while (total < byteCount) {
                currentCoroutineContext().ensureActive()
                val request = minOf(
                    NotesProtocol.MAX_READ_BYTES.toLong(),
                    byteCount - total,
                ).toInt().coerceAtLeast(1)
                val chunk = service.readResource(resourceID, offset, request)
                if (chunk.data.isEmpty()) throw IOException("shortRead")
                total += chunk.data.size
                if (total > byteCount) throw IOException("resourceChanged")
                output.write(chunk.data)
                if (chunk.eof) break
                if (chunk.nextOffset <= offset) throw IOException("shortRead")
                offset = chunk.nextOffset
            }
            output.flush()
            output.fd.sync()
        }
        if (total != byteCount) throw IOException("resourceChanged")
    }

    private suspend fun recordRefusal(
        documentID: String,
        sourceResourceID: String,
        expectedRevision: Int,
        reason: String,
        retryable: Boolean,
    ): NotesOfficeIndexOutcome {
        val receipt = try {
            service.cacheOfficeText(
                NotesOfficeTextRequest(
                    documentID = documentID,
                    sourceResourceID = sourceResourceID,
                    text = null,
                    error = reason,
                    expectedRevision = expectedRevision,
                ),
            )
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            val detail = (error as? NotesException)?.reason ?: error.message?.take(120)
            return NotesOfficeIndexOutcome.Failed(
                documentID, sourceResourceID,
                NotesPortFailure(NotesPortFailure.FAILED, detail ?: reason),
                retryable = retryable,
            )
        }
        return when (receipt.status) {
            NotesIndexCacheStatus.STALE -> NotesOfficeIndexOutcome.Stale(
                documentID, sourceResourceID, receipt.reason ?: "stale",
            )
            NotesIndexCacheStatus.FAILED -> NotesOfficeIndexOutcome.Failed(
                documentID, sourceResourceID,
                NotesPortFailure(NotesPortFailure.FAILED, receipt.reason ?: reason),
                retryable = retryable && receipt.retryable,
            )
            else -> when (reason) {
                // Real package this indexer cannot read: no retry can help.
                "unsupportedFormat", "legacyBinaryFormat" -> NotesOfficeIndexOutcome.Unsupported(
                    documentID, sourceResourceID, reason,
                )
                // Parsed and genuinely holds no text (image-only deck, etc.).
                "noExtractableText" -> NotesOfficeIndexOutcome.NoText(
                    documentID = documentID,
                    sourceResourceID = sourceResourceID,
                    revision = receipt.documentRevision,
                    reason = reason,
                )
                // Malformed/untrusted/oversized bytes: a typed, non-retryable
                // failure — never a fake empty success.
                else -> NotesOfficeIndexOutcome.Failed(
                    documentID, sourceResourceID,
                    NotesPortFailure(NotesPortFailure.FAILED, reason),
                    retryable = false,
                )
            }
        }
    }

    private suspend fun writeCache(
        documentID: String,
        sourceResourceID: String,
        expectedRevision: Int,
        text: String,
        truncated: Boolean,
    ): NotesOfficeIndexOutcome {
        var receipt = try {
            service.cacheOfficeText(
                NotesOfficeTextRequest(
                    documentID = documentID,
                    sourceResourceID = sourceResourceID,
                    text = text,
                    expectedRevision = expectedRevision,
                ),
            )
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            val message = (error as? NotesException)?.reason ?: error.message?.take(120)
            return NotesOfficeIndexOutcome.Failed(
                documentID, sourceResourceID,
                NotesPortFailure(NotesPortFailure.FAILED, message ?: "cacheWriteFailed"),
                retryable = true,
            )
        }
        if (receipt.status == NotesIndexCacheStatus.STALE) {
            // The note moved revision while extraction ran. Retry ONCE against
            // the native state's own revision, but only while the document
            // still references this exact source; otherwise the source really
            // changed and the result must stay stale.
            val state = cachedSource(documentID, sourceResourceID)
            if (state != null) {
                receipt = try {
                    service.cacheOfficeText(
                        NotesOfficeTextRequest(
                            documentID = documentID,
                            sourceResourceID = sourceResourceID,
                            text = text,
                            expectedRevision = state.revision,
                        ),
                    )
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    receipt
                }
            }
        }
        return when (receipt.status) {
            NotesIndexCacheStatus.APPLIED, NotesIndexCacheStatus.UNCHANGED ->
                if (receipt.indexed) {
                    NotesOfficeIndexOutcome.Indexed(
                        documentID = documentID,
                        sourceResourceID = sourceResourceID,
                        revision = receipt.documentRevision,
                        textLength = receipt.textLength ?: text.length,
                        truncated = truncated,
                    )
                } else {
                    NotesOfficeIndexOutcome.NoText(
                        documentID, sourceResourceID, receipt.documentRevision,
                        receipt.error ?: "noExtractableText",
                    )
                }
            NotesIndexCacheStatus.STALE -> NotesOfficeIndexOutcome.Stale(
                documentID, sourceResourceID, receipt.reason ?: "stale",
            )
            NotesIndexCacheStatus.FAILED -> NotesOfficeIndexOutcome.Failed(
                documentID, sourceResourceID,
                NotesPortFailure(NotesPortFailure.FAILED, receipt.reason ?: "cacheWriteFailed"),
                retryable = receipt.retryable,
            )
        }
    }

    private suspend fun cachedSource(documentID: String, sourceResourceID: String): NotesOfficeTextState? =
        try {
            service.officeTextState(documentID).takeIf {
                it.sourceResourceID == sourceResourceID
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            null
        }
}
