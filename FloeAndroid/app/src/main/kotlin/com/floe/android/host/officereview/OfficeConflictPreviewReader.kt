// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officereview

import com.floe.android.core.officeengine.OfficeRequestPolicy
import com.floe.android.host.officeai.verification.BoundedZipReader
import com.floe.android.host.officeai.verification.PartReadResult
import com.floe.android.host.officeai.verification.PptxText
import com.floe.android.host.officeai.verification.TrustedXml
import com.floe.android.host.officeai.verification.WordText
import com.floe.android.host.officeai.verification.WorksheetCell
import com.floe.android.host.officeai.verification.WorksheetCells
import com.floe.android.host.officeai.verification.WorksheetScan
import com.floe.android.host.officeai.verification.XlsxParts
import com.floe.android.host.officeai.verification.XmlParseResult
import com.floe.android.host.officeai.verification.ZipOpenResult
import java.io.File
import java.nio.file.Files
import java.util.Locale

/** One bounded text projection of an exact retained snapshot. */
internal sealed class OfficeConflictPreviewRead {
    data class Ready(
        val text: String,
        val truncated: Boolean,
    ) : OfficeConflictPreviewRead()

    /** Bounded code only: never a path, exception or document text. */
    data class Refused(val code: String) : OfficeConflictPreviewRead()
}

/**
 * Read-only projection of one already-retained conflict snapshot.
 *
 * This is deliberately NOT a second document renderer: the Office engine
 * owns one native document per process and the live editor must stay
 * mounted, so the review uses the bounded text already reachable through the
 * existing OOXML verification readers. The projection:
 *  - re-verifies the exact file (regular, non-symlink, length, SHA-256 and
 *    the same package magic the engine uses) before reading a part;
 *  - parses only the resolved main parts with the existing bounded ZIP and
 *    hardened XML readers;
 *  - caps the output and never writes, extracts or executes anything.
 *
 * The caller writes the resulting text to an App-owned preview file; this
 * object itself never creates a file.
 */
internal object OfficeConflictPreviewReader {
    const val MAX_PACKAGE_BYTES: Long = 64L * 1024L * 1024L

    private const val MAX_SHEETS = 8
    private const val MAX_SLIDES = 30
    private const val MAX_CELLS = 4_000
    private const val MAX_CELLS_PER_SHEET = 300
    private const val MAX_CELL_CHARS = 400

    fun read(
        version: OfficeConflictVersion,
        format: String,
        maxChars: Int = 12_000,
    ): OfficeConflictPreviewRead {
        val cap = maxChars.coerceIn(512, 12_000)
        if (version.bytes !in 1L..MAX_PACKAGE_BYTES) {
            return OfficeConflictPreviewRead.Refused("previewTooLarge")
        }
        val file = version.file
        if (!file.isFile || Files.isSymbolicLink(file.toPath())) {
            return OfficeConflictPreviewRead.Refused("snapshotChanged")
        }
        // Same whole-file admission the engine applies to a saved package
        // (magic + exact length + SHA-256); the snapshot bytes are immutable
        // and are only opened read-only below.
        val verified = runCatching { OfficeRequestPolicy.verifyStagedOutput(file, format) }
            .getOrNull() ?: return OfficeConflictPreviewRead.Refused("snapshotChanged")
        if (!verified.verified ||
            verified.bytes != version.bytes ||
            verified.sha256?.equals(version.sha256, ignoreCase = true) != true
        ) {
            return OfficeConflictPreviewRead.Refused("snapshotChanged")
        }
        return when (format.lowercase(Locale.ROOT)) {
            "docx" -> readDocx(file, cap)
            "xlsx" -> readXlsx(file, cap)
            "pptx" -> readPptx(file, cap)
            else -> OfficeConflictPreviewRead.Refused("previewUnsupported")
        }
    }

    private fun readDocx(file: File, cap: Int): OfficeConflictPreviewRead {
        val zip = openZip(file) ?: return OfficeConflictPreviewRead.Refused("previewUnreadable")
        return try {
            val bytes = when (val part = zip.readPart(WordText.DOCUMENT_PART)) {
                is PartReadResult.Bytes -> part.data
                is PartReadResult.Missing -> return OfficeConflictPreviewRead.Refused("previewUnsupported")
                is PartReadResult.Refused -> return OfficeConflictPreviewRead.Refused("previewUnreadable")
            }
            val document = when (val parsed = TrustedXml.parse(bytes)) {
                is XmlParseResult.Parsed -> parsed.document
                is XmlParseResult.Refused -> return OfficeConflictPreviewRead.Refused("previewUnreadable")
            }
            bounded(WordText.normalizedBodyText(document), cap)
        } catch (_: Throwable) {
            OfficeConflictPreviewRead.Refused("previewUnreadable")
        } finally {
            zip.close()
        }
    }

    private fun readXlsx(file: File, cap: Int): OfficeConflictPreviewRead {
        val zip = openZip(file) ?: return OfficeConflictPreviewRead.Refused("previewUnreadable")
        return try {
            val plan = when (val planned = XlsxParts.plan(zip)) {
                is XlsxParts.WorkbookPlan.Ready -> planned
                is XlsxParts.WorkbookPlan.Refused -> return OfficeConflictPreviewRead.Refused("previewUnreadable")
            }
            val shared = when (val strings = plan.sharedStringsPart?.let { XlsxParts.sharedStrings(zip, it) }) {
                is XlsxParts.SharedStringsResult.Ready -> strings.strings
                is XlsxParts.SharedStringsResult.Missing -> null
                is XlsxParts.SharedStringsResult.Refused -> return OfficeConflictPreviewRead.Refused("previewUnreadable")
                null -> null
            }
            val builder = StringBuilder()
            var structurallyTruncated = plan.sheets.size > MAX_SHEETS
            for (sheet in plan.sheets.take(MAX_SHEETS)) {
                if (builder.length >= cap) { structurallyTruncated = true; break }
                val partName = sheet.partName
                if (partName == null) { structurallyTruncated = true; continue }
                val bytes = when (val part = zip.readPart(partName)) {
                    is PartReadResult.Bytes -> part.data
                    else -> { structurallyTruncated = true; continue }
                }
                val document = when (val parsed = TrustedXml.parse(bytes)) {
                    is XmlParseResult.Parsed -> parsed.document
                    is XmlParseResult.Refused -> { structurallyTruncated = true; continue }
                }
                val scan = when (val scanned = WorksheetCells.scan(document, MAX_CELLS)) {
                    is WorksheetScan.Ready -> scanned
                    else -> { structurallyTruncated = true; continue }
                }
                builder.append("— ")
                builder.append(sheet.name?.take(80)?.takeIf { it.isNotBlank() } ?: "Sheet")
                builder.append(" —\n")
                var cells = 0
                for ((address, cell) in scan.byAddress) {
                    if (cells >= MAX_CELLS_PER_SHEET || builder.length >= cap) {
                        structurallyTruncated = true
                        break
                    }
                    val value = cellText(cell, shared) ?: continue
                    if (value.length > MAX_CELL_CHARS) structurallyTruncated = true
                    builder.append(address).append(": ")
                    builder.append(value.take(MAX_CELL_CHARS)).append('\n')
                    cells += 1
                }
            }
            finalizePreview(bounded(builder.toString(), cap), structurallyTruncated)
        } catch (_: Throwable) {
            OfficeConflictPreviewRead.Refused("previewUnreadable")
        } finally {
            zip.close()
        }
    }

    private fun readPptx(file: File, cap: Int): OfficeConflictPreviewRead {
        val zip = openZip(file) ?: return OfficeConflictPreviewRead.Refused("previewUnreadable")
        return try {
            val order = when (val resolved = PptxText.resolveSlideOrder(zip)) {
                is PptxText.SlideOrderResult.Ordered -> resolved.slidePartNames
                is PptxText.SlideOrderResult.Refused -> return OfficeConflictPreviewRead.Refused("previewUnreadable")
            }
            val builder = StringBuilder()
            var structurallyTruncated = order.size > MAX_SLIDES
            for ((index, partName) in order.take(MAX_SLIDES).withIndex()) {
                if (builder.length >= cap) { structurallyTruncated = true; break }
                val bytes = when (val part = zip.readPart(partName)) {
                    is PartReadResult.Bytes -> part.data
                    else -> { structurallyTruncated = true; continue }
                }
                val document = when (val parsed = TrustedXml.parse(bytes)) {
                    is XmlParseResult.Parsed -> parsed.document
                    is XmlParseResult.Refused -> { structurallyTruncated = true; continue }
                }
                val original = PptxText.normalizedSlideText(document).trim()
                if (original.length > cap) structurallyTruncated = true
                val text = original.take(cap)
                if (text.isEmpty()) continue
                builder.append("— Slide ").append(index + 1).append(" —\n")
                builder.append(text).append('\n')
            }
            finalizePreview(bounded(builder.toString(), cap), structurallyTruncated)
        } catch (_: Throwable) {
            OfficeConflictPreviewRead.Refused("previewUnreadable")
        } finally {
            zip.close()
        }
    }

    private fun openZip(file: File): BoundedZipReader? =
        (BoundedZipReader.open(file) as? ZipOpenResult.Ready)?.zip

    /** Exact display value of a persisted cell, never an invented formula result. */
    private fun cellText(cell: WorksheetCell, shared: List<String>?): String? {
        val value = when {
            cell.inlineText != null -> cell.inlineText
            // A shared-string cell is resolvable ONLY through the actual
            // sharedStrings part; its numeric index is not content.
            cell.typeAttr == "s" -> cell.cachedValue
                ?.toIntOrNull()
                ?.let { shared?.getOrNull(it) }
            cell.typeAttr == "b" -> when (cell.cachedValue) {
                "1" -> "TRUE"
                "0" -> "FALSE"
                else -> cell.cachedValue
            }
            else -> cell.cachedValue
        }
        return when {
            cell.formulaSource != null && value != null -> "=${cell.formulaSource} → $value"
            cell.formulaSource != null -> "=${cell.formulaSource}"
            else -> value
        }?.takeIf { it.isNotBlank() }
    }

    private fun finalizePreview(
        read: OfficeConflictPreviewRead,
        structurallyTruncated: Boolean,
    ): OfficeConflictPreviewRead = when {
        read is OfficeConflictPreviewRead.Refused &&
            read.code == "previewEmpty" && structurallyTruncated ->
            OfficeConflictPreviewRead.Refused("previewTooLarge")
        structurallyTruncated && read is OfficeConflictPreviewRead.Ready && !read.truncated ->
            read.copy(truncated = true)
        else -> read
    }

    private fun bounded(raw: String, cap: Int): OfficeConflictPreviewRead {
        val normalized = raw
            .replace("\u0000", "")
            .replace("\r\n", "\n")
            .replace('\r', '\n')
            .trim()
        if (normalized.isEmpty()) {
            return OfficeConflictPreviewRead.Refused("previewEmpty")
        }
        if (normalized.length <= cap) {
            return OfficeConflictPreviewRead.Ready(normalized, false)
        }
        var end = cap
        if (end > 0 && Character.isHighSurrogate(normalized[end - 1])) end -= 1
        return OfficeConflictPreviewRead.Ready(normalized.substring(0, end), true)
    }
}
