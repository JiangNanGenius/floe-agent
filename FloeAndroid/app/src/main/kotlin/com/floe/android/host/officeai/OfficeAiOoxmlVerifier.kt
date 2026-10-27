// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officeai

import com.floe.android.host.officeai.verification.ArtifactGuard
import com.floe.android.host.officeai.verification.BoundedZipReader
import com.floe.android.host.officeai.verification.CellIntentEvaluator
import com.floe.android.host.officeai.verification.IntentEvaluation
import com.floe.android.host.officeai.verification.PartReadResult
import com.floe.android.host.officeai.verification.PptxText
import com.floe.android.host.officeai.verification.SemanticDelta
import com.floe.android.host.officeai.verification.TextDeltaProof
import com.floe.android.host.officeai.verification.TrustedXml
import com.floe.android.host.officeai.verification.VerificationCodes
import com.floe.android.host.officeai.verification.VerificationLimits
import com.floe.android.host.officeai.verification.VerificationNotes
import com.floe.android.host.officeai.verification.WorksheetCells
import com.floe.android.host.officeai.verification.WordText
import com.floe.android.host.officeai.verification.XlsxParts
import com.floe.android.host.officeai.verification.XmlParseResult
import com.floe.android.host.officeai.verification.ZipOpenResult
import java.util.Locale
import org.w3c.dom.Document

/** Pure Kotlin/JVM saved-content verifier implementing the Main-fixed
 * OfficeAiSavedPackageVerifier contract over the ACTUAL immutable App-owned
 * export file.
 *
 * Honesty rules (Main v2 semantic amendment):
 *  - expectedContentMatches is computed ONLY from the actually inspected part
 *    (word/document.xml, the rels-resolved slide part, or the exact <c> in
 *    the ordered-workbook-resolved worksheet).
 *  - targetEffectVerified = input.nativeTargetEffectVerified (the private
 *    host fact from the real P-A MUTATION_VERIFIED correlation at the same
 *    captured target) AND the actual saved postcondition. The verifier never
 *    invents native effect proof.
 *  - semanticDeltaVerified = the ACTUAL trusted pre-edit baseline (own size
 *    and streamed digest proven here) resolves the same target part, and the
 *    saved part equals exactly the ONE requested replacement/insertion. A
 *    changed package hash or global "contains" alone can never prove this.
 *  - proofReused = input.trustedCompletedJobProof (derived by the trusted
 *    host/Core from the exact owned COMPLETED v2 producer + artifact digest)
 *    AND the actual saved content match.
 *  - A package that fails to open, parse, resolve or exceeds a bound answers
 *    a typed Refused code. Verification is strictly read-only: no extraction,
 *    no zip rewrite, and input/baseline bytes stay untouched on every path.
 *  - Verified means inspection completed, even when every proof fact is
 *    false; the Core gate refuses unproven results.
 */
internal object OfficeAiOoxmlVerifier : OfficeAiSavedPackageVerifier {

    override fun inspect(input: OfficeAiVerificationInput): OfficeAiVerificationResult =
        try {
            inspectInternal(input)
        } catch (error: Exception) {
            OfficeAiVerificationResult.Refused(VerificationCodes.INSPECTOR_ERROR)
        }

    private fun inspectInternal(input: OfficeAiVerificationInput): OfficeAiVerificationResult {
        val format = input.format.trim().lowercase(Locale.ROOT)
        if (format != "docx" && format != "xlsx" && format != "pptx") {
            return OfficeAiVerificationResult.Refused(VerificationCodes.UNKNOWN_FORMAT)
        }
        val command = input.command.trim()
        if (command != "applyText" && command != "setCellContent") {
            return OfficeAiVerificationResult.Refused(VerificationCodes.UNKNOWN_COMMAND)
        }
        if ((format == "xlsx") != (command == "setCellContent")) {
            return OfficeAiVerificationResult.Refused(VerificationCodes.COMMAND_FORMAT_MISMATCH)
        }
        if (command == "setCellContent") {
            val kind = input.contentKind
            if (kind != "literal" && kind != "number" && kind != "formula") {
                return OfficeAiVerificationResult.Refused(VerificationCodes.UNKNOWN_CONTENT_KIND)
            }
        }
        val expectedBytes = input.expectedText.toByteArray(Charsets.UTF_8).size.toLong()
        if (expectedBytes > VerificationLimits.MAX_EXPECTED_BYTES) {
            return OfficeAiVerificationResult.Refused(VerificationCodes.EXPECTED_TOO_LARGE)
        }
        ArtifactGuard.check(input.file, input.sha256, input.bytes)?.let { code ->
            return OfficeAiVerificationResult.Refused(code)
        }
        return when (command) {
            "applyText" -> inspectTextEdition(format, input)
            else -> inspectCellEdition(input)
        }
    }

    // -----------------------------------------------------------------
    // Shared bounded part reading
    // -----------------------------------------------------------------

    private sealed class TextRead {
        data class Ok(val text: String) : TextRead()
        data class Refused(val code: String) : TextRead()
        data class BaselineNote(val note: String) : TextRead()
    }

    private fun readNormalizedText(
        zip: BoundedZipReader,
        partName: String,
        format: String,
        baselineNotePrefix: String?,
    ): TextRead {
        val bytes = when (val read = zip.readPart(partName)) {
            is PartReadResult.Bytes -> read.data
            is PartReadResult.Missing -> {
                return if (baselineNotePrefix != null) {
                    TextRead.BaselineNote(baselineNotePrefix)
                } else {
                    TextRead.Refused(VerificationCodes.PART_MISSING)
                }
            }
            is PartReadResult.Refused -> {
                return if (baselineNotePrefix != null) {
                    TextRead.BaselineNote("$baselineNotePrefix:${read.code}")
                } else {
                    TextRead.Refused(read.code)
                }
            }
        }
        val document = when (val parsed = TrustedXml.parse(bytes)) {
            is XmlParseResult.Parsed -> parsed.document
            is XmlParseResult.Refused -> {
                return if (baselineNotePrefix != null) {
                    TextRead.BaselineNote("$baselineNotePrefix:${parsed.code}")
                } else {
                    TextRead.Refused(parsed.code)
                }
            }
        }
        return TextRead.Ok(
            if (format == "docx") {
                WordText.normalizedBodyText(document)
            } else {
                PptxText.normalizedSlideText(document)
            },
        )
    }

    // -----------------------------------------------------------------
    // Word / PPT applyText
    // -----------------------------------------------------------------

    private fun inspectTextEdition(
        format: String,
        input: OfficeAiVerificationInput,
    ): OfficeAiVerificationResult {
        if (input.expectedText.isEmpty()) {
            return OfficeAiVerificationResult.Refused(VerificationCodes.EXPECTED_EMPTY)
        }
        return when (val open = BoundedZipReader.open(input.file)) {
            is ZipOpenResult.Refused -> OfficeAiVerificationResult.Refused(open.code)
            is ZipOpenResult.Ready -> try {
                textEdition(format, open.zip, input)
            } finally {
                open.zip.close()
            }
        }
    }

    private fun textEdition(
        format: String,
        zip: BoundedZipReader,
        input: OfficeAiVerificationInput,
    ): OfficeAiVerificationResult {
        val limitations = ArrayList<String>()
        val logicalIndex = input.partIndex
        val partName: String
        if (format == "docx") {
            partName = WordText.DOCUMENT_PART
        } else {
            if (logicalIndex == null) {
                return OfficeAiVerificationResult.Refused(VerificationCodes.MISSING_PART_INDEX)
            }
            when (val order = PptxText.resolveSlideOrder(zip)) {
                is PptxText.SlideOrderResult.Refused -> {
                    return OfficeAiVerificationResult.Refused(order.code)
                }
                is PptxText.SlideOrderResult.Ordered -> {
                    if (logicalIndex < 0 || logicalIndex >= order.slidePartNames.size) {
                        return OfficeAiVerificationResult.Refused(
                            VerificationCodes.TARGET_INDEX_OUT_OF_RANGE,
                        )
                    }
                    partName = order.slidePartNames[logicalIndex]
                }
            }
        }
        val savedText = when (val read = readNormalizedText(zip, partName, format, null)) {
            is TextRead.Ok -> read.text
            is TextRead.Refused -> return OfficeAiVerificationResult.Refused(read.code)
            is TextRead.BaselineNote -> return OfficeAiVerificationResult.Refused(
                read.note.substringAfter(":"),
            )
        }
        val contentMatches = savedText.contains(input.expectedText)
        val occurrences = countOccurrences(savedText, input.expectedText)
        if (occurrences.second) limitations.add(VerificationNotes.OCCURRENCES_CAPPED)
        if (!contentMatches && format == "docx") {
            limitations.add(VerificationNotes.WORD_HEADERS_NOT_INSPECTED)
        }

        var changedFromOriginal: Boolean? = null
        var baselineText: String? = null
        val baseline = input.baseline
        if (baseline != null) {
            val guard = ArtifactGuard.check(baseline.file, baseline.sha256, baseline.bytes)
            if (guard != null) {
                limitations.add("${VerificationNotes.BASELINE_UNVERIFIED}:$guard")
            } else {
                changedFromOriginal = baseline.sha256.lowercase(Locale.ROOT) !=
                    input.sha256.lowercase(Locale.ROOT)
                when (val open = BoundedZipReader.open(baseline.file)) {
                    is ZipOpenResult.Refused -> {
                        limitations.add("${VerificationNotes.BASELINE_UNREADABLE}:${open.code}")
                    }
                    is ZipOpenResult.Ready -> {
                        try {
                            val baselinePart = when (format) {
                                "docx" -> WordText.DOCUMENT_PART
                                else -> baselineSlidePart(
                                    open.zip,
                                    logicalIndex,
                                    baseline.partIndex,
                                    limitations,
                                )
                            }
                            if (baselinePart != null) {
                                baselineText = when (
                                    val read = readNormalizedText(
                                        open.zip,
                                        baselinePart,
                                        format,
                                        VerificationNotes.BASELINE_PART_MISSING,
                                    )
                                ) {
                                    is TextRead.Ok -> read.text
                                    is TextRead.BaselineNote -> {
                                        limitations.add(read.note)
                                        null
                                    }
                                    is TextRead.Refused -> {
                                        limitations.add(
                                            "${VerificationNotes.BASELINE_PART_MISSING}:${read.code}",
                                        )
                                        null
                                    }
                                }
                            }
                        } finally {
                            open.zip.close()
                        }
                    }
                }
            }
        }

        val delta = if (baseline == null) {
            TextDeltaProof.Unproven(VerificationNotes.NO_BASELINE)
        } else {
            SemanticDelta.proveTextDelta(
                baselineText = baselineText,
                savedText = savedText,
                priorSelectionText = baseline.priorSelectionText,
                expectedText = input.expectedText,
            )
        }
        val semanticDelta = delta is TextDeltaProof.Proven
        if (delta is TextDeltaProof.Unproven) limitations.add(delta.note)
        val scope = when {
            delta is TextDeltaProof.Proven -> delta.scope
            contentMatches -> SemanticDelta.SCOPE_TEXT_PRESENT_ONLY
            else -> null
        }
        return OfficeAiVerificationResult.Verified(
            facts(
                partName = partName,
                expectedContentMatches = contentMatches,
                expectedTextFound = contentMatches,
                occurrenceCount = occurrences.first,
                replacementScope = scope,
                cellTypeAttribute = null,
                cellHasFormula = null,
                cellPersistedValue = null,
                cellTypeMatchesIntent = null,
                semanticDeltaVerified = semanticDelta,
                targetEffectVerified = input.nativeTargetEffectVerified && contentMatches,
                proofReused = input.trustedCompletedJobProof && contentMatches,
                changedFromOriginal = changedFromOriginal,
                limitations = limitations,
            ),
        )
    }

    private fun baselineSlidePart(
        zip: BoundedZipReader,
        logicalIndex: Int?,
        baselinePartIndex: Int?,
        limitations: ArrayList<String>,
    ): String? {
        if (baselinePartIndex == null) {
            limitations.add(VerificationNotes.BASELINE_TARGET_UNKNOWN)
            return null
        }
        if (logicalIndex == null || baselinePartIndex != logicalIndex) {
            limitations.add(VerificationNotes.BASELINE_TARGET_MISMATCH)
            return null
        }
        return when (val order = PptxText.resolveSlideOrder(zip)) {
            is PptxText.SlideOrderResult.Refused -> {
                limitations.add("${VerificationNotes.BASELINE_UNREADABLE}:${order.code}")
                null
            }
            is PptxText.SlideOrderResult.Ordered -> {
                if (logicalIndex < 0 || logicalIndex >= order.slidePartNames.size) {
                    limitations.add(VerificationNotes.BASELINE_PART_MISSING)
                    null
                } else {
                    order.slidePartNames[logicalIndex]
                }
            }
        }
    }

    // -----------------------------------------------------------------
    // XLSX setCellContent
    // -----------------------------------------------------------------

    private fun inspectCellEdition(
        input: OfficeAiVerificationInput,
    ): OfficeAiVerificationResult {
        val logicalIndex = input.partIndex
            ?: return OfficeAiVerificationResult.Refused(VerificationCodes.MISSING_PART_INDEX)
        val cellAddressRaw = input.cellAddress
            ?: return OfficeAiVerificationResult.Refused(VerificationCodes.MISSING_CELL_ADDRESS)
        val address = WorksheetCells.normalizedAddress(cellAddressRaw)
            ?: return OfficeAiVerificationResult.Refused(VerificationCodes.CELL_ADDRESS_INVALID)
        val kind = input.contentKind
            ?: return OfficeAiVerificationResult.Refused(VerificationCodes.UNKNOWN_CONTENT_KIND)
        return when (val open = BoundedZipReader.open(input.file)) {
            is ZipOpenResult.Refused -> OfficeAiVerificationResult.Refused(open.code)
            is ZipOpenResult.Ready -> try {
                cellEdition(logicalIndex, address, kind, open.zip, input)
            } finally {
                open.zip.close()
            }
        }
    }

    private fun cellEdition(
        logicalIndex: Int,
        address: String,
        kind: String,
        zip: BoundedZipReader,
        input: OfficeAiVerificationInput,
    ): OfficeAiVerificationResult {
        val limitations = ArrayList<String>()
        val plan = when (val planned = XlsxParts.plan(zip)) {
            is XlsxParts.WorkbookPlan.Refused -> {
                return OfficeAiVerificationResult.Refused(planned.code)
            }
            is XlsxParts.WorkbookPlan.Ready -> planned
        }
        if (logicalIndex < 0 || logicalIndex >= plan.sheets.size) {
            return OfficeAiVerificationResult.Refused(VerificationCodes.TARGET_INDEX_OUT_OF_RANGE)
        }
        val target = plan.sheets[logicalIndex]
        val partName = target.partName
            ?: return OfficeAiVerificationResult.Refused(
                target.refusalCode ?: VerificationCodes.RELATION_UNRESOLVED,
            )
        val sheetDocument = readXmlPart(zip, partName)
            ?: return OfficeAiVerificationResult.Refused(VerificationCodes.PART_MISSING)
        val cell = WorksheetCells.findCell(sheetDocument, address)
            ?: return OfficeAiVerificationResult.Refused(VerificationCodes.TARGET_CELL_MISSING)
        val sharedStrings = loadSharedStrings(zip, plan.sharedStringsPart)
        if (sharedStrings is LoadedStrings.Failed) {
            return OfficeAiVerificationResult.Refused(sharedStrings.code)
        }
        val strings = (sharedStrings as? LoadedStrings.Ready)?.strings
        val assessment = when (
            val evaluated = CellIntentEvaluator.assess(
                kind = kind,
                expected = input.expectedText,
                cell = cell,
                sharedStrings = strings,
                sheetDocument = sheetDocument,
            )
        ) {
            is IntentEvaluation.Refused -> {
                return OfficeAiVerificationResult.Refused(evaluated.code)
            }
            is IntentEvaluation.Assessed -> evaluated
        }
        limitations.addAll(assessment.notes)
        var changedFromOriginal: Boolean? = null
        var baselineDisplay: String? = null
        var baselineCellMissing = false
        var baselineUsable = false
        val baseline = input.baseline
        if (baseline != null) {
            val guard = ArtifactGuard.check(baseline.file, baseline.sha256, baseline.bytes)
            if (guard != null) {
                limitations.add("${VerificationNotes.BASELINE_UNVERIFIED}:$guard")
            } else {
                changedFromOriginal = baseline.sha256.lowercase(Locale.ROOT) !=
                    input.sha256.lowercase(Locale.ROOT)
                val resolution = resolveBaselineCell(
                    baseline,
                    logicalIndex,
                    address,
                    limitations,
                )
                baselineDisplay = resolution.display
                baselineCellMissing = resolution.missing
                baselineUsable = resolution.usable
            }
        }
        val delta = when {
            baseline == null -> TextDeltaProof.Unproven(VerificationNotes.NO_BASELINE)
            // The baseline exists but is not comparable at this target:
            // never treat its unreadable display as an empty prior cell.
            !baselineUsable -> TextDeltaProof.Unproven(VerificationNotes.DELTA_NOT_SINGLE_EDIT)
            else -> SemanticDelta.proveCellDelta(
                baselineDisplay = baselineDisplay,
                savedDisplay = assessment.comparableValue,
                priorSelectionText = baseline.priorSelectionText,
                contentMatches = assessment.contentMatches,
                baselineCellWasMissing = baselineCellMissing,
            )
        }
        val semanticDelta = delta is TextDeltaProof.Proven
        if (delta is TextDeltaProof.Unproven) limitations.add(delta.note)
        return OfficeAiVerificationResult.Verified(
            facts(
                partName = partName,
                expectedContentMatches = assessment.contentMatches,
                expectedTextFound = assessment.contentMatches,
                occurrenceCount = if (assessment.contentMatches) 1 else 0,
                replacementScope = when (delta) {
                    is TextDeltaProof.Proven -> delta.scope
                    else -> null
                },
                cellTypeAttribute = cell.typeAttr ?: "",
                cellHasFormula = cell.hasFormula,
                cellPersistedValue = assessment.persistedPreview,
                cellTypeMatchesIntent = assessment.typeMatchesIntent,
                semanticDeltaVerified = semanticDelta,
                targetEffectVerified = input.nativeTargetEffectVerified && assessment.contentMatches,
                proofReused = input.trustedCompletedJobProof && assessment.contentMatches,
                changedFromOriginal = changedFromOriginal,
                limitations = limitations,
            ),
        )
    }

    private fun readXmlPart(zip: BoundedZipReader, partName: String): Document? {
        val bytes = when (val read = zip.readPart(partName)) {
            is PartReadResult.Bytes -> read.data
            else -> return null
        }
        return when (val parsed = TrustedXml.parse(bytes)) {
            is XmlParseResult.Parsed -> parsed.document
            is XmlParseResult.Refused -> null
        }
    }

    private data class BaselineCellProbe(
        val display: String?,
        val missing: Boolean,
        val usable: Boolean,
    )

    private fun resolveBaselineCell(
        baseline: OfficeAiVerificationBaseline,
        logicalIndex: Int,
        address: String,
        limitations: ArrayList<String>,
    ): BaselineCellProbe {
        if (baseline.partIndex == null) {
            limitations.add(VerificationNotes.BASELINE_TARGET_UNKNOWN)
            return BaselineCellProbe(null, false, false)
        }
        if (baseline.partIndex != logicalIndex) {
            limitations.add(VerificationNotes.BASELINE_TARGET_MISMATCH)
            return BaselineCellProbe(null, false, false)
        }
        when (val open = BoundedZipReader.open(baseline.file)) {
            is ZipOpenResult.Refused -> {
                limitations.add("${VerificationNotes.BASELINE_UNREADABLE}:${open.code}")
                return BaselineCellProbe(null, false, false)
            }
            is ZipOpenResult.Ready -> {
                try {
                    val plan = when (val planned = XlsxParts.plan(open.zip)) {
                        is XlsxParts.WorkbookPlan.Refused -> {
                            limitations.add("${VerificationNotes.BASELINE_UNREADABLE}:${planned.code}")
                            return BaselineCellProbe(null, false, false)
                        }
                        is XlsxParts.WorkbookPlan.Ready -> planned
                    }
                    if (logicalIndex < 0 || logicalIndex >= plan.sheets.size) {
                        limitations.add(VerificationNotes.BASELINE_PART_MISSING)
                        return BaselineCellProbe(null, false, false)
                    }
                    val target = plan.sheets[logicalIndex]
                    val partName = target.partName ?: run {
                        limitations.add(
                            VerificationNotes.BASELINE_TARGET_MISMATCH +
                                ":" + target.refusalCode.orEmpty(),
                        )
                        return BaselineCellProbe(null, false, false)
                    }
                    val sheetDocument = readXmlPart(open.zip, partName)
                        ?: run {
                            limitations.add(VerificationNotes.BASELINE_PART_MISSING)
                            return BaselineCellProbe(null, false, false)
                        }
                    val cell = WorksheetCells.findCell(sheetDocument, address)
                        ?: return BaselineCellProbe(null, true, true)
                    val sharedStrings = loadSharedStrings(open.zip, plan.sharedStringsPart)
                    if (sharedStrings is LoadedStrings.Failed) {
                        limitations.add(
                            "${VerificationNotes.BASELINE_UNREADABLE}:${sharedStrings.code}",
                        )
                        return BaselineCellProbe(null, false, false)
                    }
                    val strings = (sharedStrings as? LoadedStrings.Ready)?.strings
                    val display = CellIntentEvaluator.comparableFor(cell, strings)
                    if (display == null) {
                        limitations.add(
                            "${VerificationNotes.BASELINE_UNREADABLE}:" +
                                VerificationCodes.SHARED_STRING_INVALID,
                        )
                        return BaselineCellProbe(null, false, false)
                    }
                    return BaselineCellProbe(display, false, true)
                } finally {
                    open.zip.close()
                }
            }
        }
    }

    private sealed class LoadedStrings {
        data class Ready(val strings: List<String>) : LoadedStrings()
        data class Failed(val code: String) : LoadedStrings()
        object Absent : LoadedStrings()
    }

    private fun loadSharedStrings(
        zip: BoundedZipReader,
        partName: String?,
    ): LoadedStrings {
        if (partName == null) return LoadedStrings.Absent
        return when (val result = XlsxParts.sharedStrings(zip, partName)) {
            is XlsxParts.SharedStringsResult.Ready -> LoadedStrings.Ready(result.strings)
            XlsxParts.SharedStringsResult.Missing -> LoadedStrings.Absent
            is XlsxParts.SharedStringsResult.Refused -> LoadedStrings.Failed(result.code)
        }
    }

    private fun countOccurrences(text: String, needle: String): Pair<Int, Boolean> {
        if (needle.isEmpty()) return 0 to false
        var count = 0
        var capped = false
        var at = text.indexOf(needle)
        while (at >= 0) {
            if (count >= VerificationLimits.MAX_OCCURRENCE_REPORT) {
                capped = true
                break
            }
            count += 1
            at = text.indexOf(needle, at + needle.length)
        }
        return count to capped
    }

    private fun facts(
        partName: String,
        expectedContentMatches: Boolean,
        expectedTextFound: Boolean?,
        occurrenceCount: Int?,
        replacementScope: String?,
        cellTypeAttribute: String?,
        cellHasFormula: Boolean?,
        cellPersistedValue: String?,
        cellTypeMatchesIntent: Boolean?,
        semanticDeltaVerified: Boolean,
        targetEffectVerified: Boolean,
        proofReused: Boolean,
        changedFromOriginal: Boolean?,
        limitations: List<String>,
    ): OfficeAiVerificationFacts = OfficeAiVerificationFacts(
        partName = partName,
        expectedContentMatches = expectedContentMatches,
        expectedTextFound = expectedTextFound,
        occurrenceCount = occurrenceCount,
        replacementScope = replacementScope,
        cellTypeAttribute = cellTypeAttribute,
        cellHasFormula = cellHasFormula,
        cellPersistedValue = cellPersistedValue,
        cellTypeMatchesIntent = cellTypeMatchesIntent,
        semanticDeltaVerified = semanticDeltaVerified,
        targetEffectVerified = targetEffectVerified,
        proofReused = proofReused,
        changedFromOriginal = changedFromOriginal,
        limitations = limitations.distinct().take(VerificationLimits.LIMITATIONS_CAP),
    )
}
