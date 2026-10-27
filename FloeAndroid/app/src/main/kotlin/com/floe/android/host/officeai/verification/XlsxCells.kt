// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officeai.verification

import org.w3c.dom.Document
import org.w3c.dom.Element

/** The ACTUAL persisted state of one <c> element, read namespace-aware from
 * the resolved worksheet part.
 */
internal data class WorksheetCell(
    val address: String,
    /** t attribute; null when absent (OOXML numeric default). */
    val typeAttr: String?,
    val hasFormula: Boolean,
    /** <f> element text source, null when the element carries no text. */
    val formulaSource: String?,
    /** <f t="..."> kind: normal(null)/shared/array/dataTable. */
    val formulaKind: String?,
    /** <f si="..."> for shared formulas. */
    val formulaSi: String?,
    /** <v> text, null when absent. */
    val cachedValue: String?,
    /** <is> concatenated <t> text, null when absent. */
    val inlineText: String?,
)

internal object WorksheetCells {
    val ADDRESS_PATTERN = Regex("^[A-Z]+[0-9]+$")

    fun normalizedAddress(raw: String): String? {
        val trimmed = raw.trim().uppercase()
        return if (ADDRESS_PATTERN.matches(trimmed)) trimmed else null
    }

    fun findCell(document: Document, address: String): WorksheetCell? {
        for (element in DomUtil.elements(document, XlsxParts.S_NS, "c")) {
            val ref = element.getAttribute("r")
            if (ref.trim().uppercase() == address) return toCell(element, ref.trim().uppercase())
        }
        return null
    }

    /** The <c> whose shared-formula master text defines [si], excluding the
     * requested address. A shared formula defined in ANOTHER cell carries the
     * base-address relative form, so its per-target source is unresolvable
     * honestly here.
     */
    fun sharedFormulaMaster(
        document: Document,
        si: String,
        excludeAddress: String,
    ): WorksheetCell? {
        for (element in DomUtil.elements(document, XlsxParts.S_NS, "c")) {
            val ref = element.getAttribute("r").trim().uppercase()
            if (ref == excludeAddress) continue
            val cell = toCell(element, ref)
            if (cell.hasFormula && cell.formulaKind == "shared" &&
                cell.formulaSi == si && !cell.formulaSource.isNullOrEmpty()
            ) {
                return cell
            }
        }
        return null
    }

    private fun toCell(element: Element, address: String): WorksheetCell {
        val t = element.getAttribute("t")
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
            typeAttr = if (t.isEmpty()) null else t,
            hasFormula = formula != null,
            formulaSource = if (formulaText.isNullOrEmpty()) null else formulaText,
            formulaKind = formula?.getAttribute("t")?.takeIf { it.isNotEmpty() },
            formulaSi = formula?.getAttribute("si")?.takeIf { it.isNotEmpty() },
            cachedValue = cached?.getTextContent(),
            inlineText = inlineText,
        )
    }
}

internal sealed class IntentEvaluation {
    data class Assessed(
        val contentMatches: Boolean,
        val typeMatchesIntent: Boolean,
        val persistedPreview: String?,
        val notes: List<String>,
        /** Normalized value used for honest before/after cell delta. */
        val comparableValue: String?,
    ) : IntentEvaluation()

    data class Refused(val code: String) : IntentEvaluation()
}

/** Evaluates the ACTUAL saved cell against the declared intent per Main v2:
 * literal is an EXACT string (00123 and a leading = stay strings), number is
 * canonical finite numeric equivalence, formula compares the SAVED <f>
 * source after conservative normalization. A cached display value or the
 * mere presence of <f> never passes.
 */
internal object CellIntentEvaluator {
    private val NUMBER_GRAMMAR =
        Regex("^[+-]?(\\d+(\\.\\d*)?|\\.\\d+)([eE][+-]?\\d+)?$")

    fun assess(
        kind: String,
        expected: String,
        cell: WorksheetCell,
        sharedStrings: List<String>?,
        sheetDocument: Document,
    ): IntentEvaluation {
        return when (kind) {
            "literal" -> assessLiteral(expected, cell, sharedStrings)
            "number" -> assessNumber(expected, cell)
            "formula" -> assessFormula(expected, cell, sheetDocument)
            else -> IntentEvaluation.Refused(VerificationCodes.UNKNOWN_CONTENT_KIND)
        }
    }

    /** Decodes the value used for baseline-vs-saved delta for any cell. */
    fun comparableFor(
        cell: WorksheetCell?,
        sharedStrings: List<String>?,
    ): String? {
        if (cell == null) return ""
        return when (cell.typeAttr) {
            null, "n" -> cell.cachedValue ?: ""
            "s" -> {
                val index = cell.cachedValue?.trim()?.toIntOrNull()
                if (index == null || sharedStrings == null ||
                    index < 0 || index >= sharedStrings.size
                ) {
                    null
                } else {
                    sharedStrings[index]
                }
            }
            "str", "e" -> cell.cachedValue ?: ""
            "b" -> when (cell.cachedValue?.trim()) {
                "1" -> "TRUE"
                "0" -> "FALSE"
                else -> cell.cachedValue ?: ""
            }
            "inlineStr" -> cell.inlineText ?: ""
            else -> cell.cachedValue ?: cell.inlineText ?: ""
        }
    }

    private fun assessLiteral(
        expected: String,
        cell: WorksheetCell,
        sharedStrings: List<String>?,
    ): IntentEvaluation {
        val stringType = cell.typeAttr == "s" || cell.typeAttr == "str" ||
            cell.typeAttr == "inlineStr"
        val typeOk = !cell.hasFormula && stringType
        val notes = ArrayList<String>()
        if (cell.hasFormula) {
            // An <f> with a cached str/number is NOT a literal.
            return IntentEvaluation.Assessed(
                contentMatches = false,
                typeMatchesIntent = false,
                persistedPreview = preview(cell.cachedValue),
                notes = listOf("savedCellIsFormulaNotLiteral"),
                comparableValue = cell.cachedValue,
            )
        }
        val decoded: String? = when (cell.typeAttr) {
            "s" -> {
                if (sharedStrings == null) {
                    return IntentEvaluation.Refused(VerificationCodes.SHARED_STRINGS_MISSING)
                }
                val index = cell.cachedValue?.trim()?.toIntOrNull()
                if (index == null || index < 0 || index >= sharedStrings.size) {
                    return IntentEvaluation.Refused(VerificationCodes.SHARED_STRING_INVALID)
                }
                sharedStrings[index]
            }
            "str" -> cell.cachedValue
            "inlineStr" -> cell.inlineText
            else -> null
        }
        if (!stringType || decoded == null) {
            notes.add("cellNotStringType")
            return IntentEvaluation.Assessed(
                contentMatches = false,
                typeMatchesIntent = false,
                persistedPreview = preview(displayFallback(cell)),
                notes = notes,
                comparableValue = displayFallback(cell),
            )
        }
        if (decoded.length > VerificationLimits.PREVIEW_MAX_CHARS) {
            notes.add(VerificationNotes.PREVIEW_TRUNCATED)
        }
        return IntentEvaluation.Assessed(
            contentMatches = decoded == expected,
            typeMatchesIntent = true,
            persistedPreview = preview(decoded),
            notes = notes,
            comparableValue = decoded,
        )
    }

    private fun assessNumber(expected: String, cell: WorksheetCell): IntentEvaluation {
        if (!NUMBER_GRAMMAR.matches(expected.trim())) {
            return IntentEvaluation.Refused(VerificationCodes.NUMBER_INTENT_INVALID)
        }
        val expectedValue = try {
            expected.trim().toBigDecimal()
        } catch (error: NumberFormatException) {
            return IntentEvaluation.Refused(VerificationCodes.NUMBER_INTENT_INVALID)
        }
        if (!expectedValue.toDouble().isFinite()) {
            return IntentEvaluation.Refused(VerificationCodes.NUMBER_INTENT_INVALID)
        }
        val typeOk = !cell.hasFormula && (cell.typeAttr == null || cell.typeAttr == "n")
        val stored = cell.cachedValue?.trim()
        if (!typeOk || stored == null || !NUMBER_GRAMMAR.matches(stored)) {
            val notes = if (!typeOk) {
                listOf("cellNotNumericType")
            } else {
                listOf(VerificationNotes.STORED_NOT_NUMERIC)
            }
            return IntentEvaluation.Assessed(
                contentMatches = false,
                typeMatchesIntent = false,
                persistedPreview = preview(stored),
                notes = notes,
                comparableValue = stored,
            )
        }
        val storedValue = try {
            stored.toBigDecimal()
        } catch (error: NumberFormatException) {
            return IntentEvaluation.Assessed(
                contentMatches = false,
                typeMatchesIntent = typeOk,
                persistedPreview = preview(stored),
                notes = listOf(VerificationNotes.STORED_NOT_NUMERIC),
                comparableValue = stored,
            )
        }
        // Exact decimal equivalence: refusing to accept any precision drift.
        val matches = expectedValue.compareTo(storedValue) == 0
        val notes = if (!matches && expectedValue.toDouble() == storedValue.toDouble()) {
            listOf("precisionLossRefused")
        } else {
            emptyList()
        }
        return IntentEvaluation.Assessed(
            contentMatches = matches,
            typeMatchesIntent = typeOk,
            persistedPreview = preview(stored),
            notes = notes,
            comparableValue = stored,
        )
    }

    private fun assessFormula(
        expected: String,
        cell: WorksheetCell,
        sheetDocument: Document,
    ): IntentEvaluation {
        val trimmed = expected.trim()
        if (!trimmed.startsWith("=")) {
            return IntentEvaluation.Refused(VerificationCodes.FORMULA_INTENT_MISSING_EQUALS)
        }
        if (!cell.hasFormula) {
            return IntentEvaluation.Assessed(
                contentMatches = false,
                typeMatchesIntent = false,
                persistedPreview = preview(cell.cachedValue),
                notes = listOf("savedCellHasNoFormula"),
                comparableValue = null,
            )
        }
        when (cell.formulaKind) {
            "shared" -> {
                if (cell.formulaSource != null) {
                    // The target cell itself carries the ACTUAL source text.
                    return compareFormula(expected, cell)
                }
                val si = cell.formulaSi
                if (si == null) {
                    return IntentEvaluation.Refused(VerificationCodes.UNSUPPORTED_FORMULA)
                }
                val master = WorksheetCells.sharedFormulaMaster(sheetDocument, si, cell.address)
                if (master == null) {
                    return IntentEvaluation.Refused(VerificationCodes.UNSUPPORTED_FORMULA)
                }
                // Master text belongs to another base address; translating the
                // relative references is impossible without a real engine.
                return IntentEvaluation.Refused(VerificationCodes.UNSUPPORTED_FORMULA)
            }
            "array", "dataTable" -> {
                if (cell.formulaSource == null) {
                    return IntentEvaluation.Refused(VerificationCodes.UNSUPPORTED_FORMULA)
                }
                return compareFormula(expected, cell)
            }
            else -> return compareFormula(expected, cell)
        }
    }

    private fun compareFormula(
        expected: String,
        cell: WorksheetCell,
    ): IntentEvaluation {
        val source = cell.formulaSource
        if (source == null) {
            return IntentEvaluation.Assessed(
                contentMatches = false,
                typeMatchesIntent = true,
                persistedPreview = preview(cell.cachedValue),
                notes = listOf("formulaSourceUnreadable"),
                comparableValue = null,
            )
        }
        val normalizedExpected = FormulaNormalizer.normalize(expected)
        val normalizedSource = FormulaNormalizer.normalize(source)
        val matches = normalizedExpected == normalizedSource
        val notes = ArrayList<String>()
        if (cell.formulaKind == "array" && matches) {
            notes.add("arrayFormulaSourceMatched")
        }
        if (!matches &&
            FormulaNormalizer.differsOnlyByInteriorWhitespace(normalizedExpected, normalizedSource)
        ) {
            // Honest refusal kept; only the cause is explained.
            notes.add("formulaDiffersOnlyByWhitespace")
        }
        return IntentEvaluation.Assessed(
            contentMatches = matches,
            typeMatchesIntent = true,
            // A valid formula's cached t absent/n/str/b/e is not a mismatch.
            persistedPreview = preview(cell.cachedValue ?: ("=" + source)),
            notes = notes,
            comparableValue = "=" + FormulaNormalizer.normalize(source),
        )
    }

    private fun displayFallback(cell: WorksheetCell): String? =
        cell.cachedValue ?: cell.inlineText

    private fun preview(value: String?): String? {
        if (value == null) return null
        return if (value.length > VerificationLimits.PREVIEW_MAX_CHARS) {
            value.substring(0, VerificationLimits.PREVIEW_MAX_CHARS)
        } else {
            value
        }
    }

}

/** MINIMAL conservative formula normalization: at most one leading '=' plus
 * proven BOUNDARY whitespace only. Interior content is compared exactly:
 *  - spaces inside single-quoted sheet/workbook identifiers (='Sales Q1'!A1)
 *    are significant;
 *  - a space between references (=A1 B1) is the intersection operator;
 *  - implementing full spreadsheet-formula grammar equivalence is out of
 *    scope, so different saved interior forms are honestly NOT treated as
 *    equal. A false refusal with a diagnostic note is preferred over claiming
 *    two different formula sources are the same.
 */
internal object FormulaNormalizer {
    fun normalize(raw: String): String {
        var text = raw.trim()
        if (text.startsWith("=")) {
            text = text.substring(1)
            text = text.trim()
        }
        return text.trimEnd()
    }

    /** DIAGNOSTIC ONLY (never decides a match): true when the two sources
     * contain no quote characters at all and differ purely by interior
     * whitespace, so the verifier can explain an honest refusal without
     * weakening the equality proof. Quoted identifiers are excluded because
     * a space inside 'Sales Q1' or "a b" is meaningful content, and a space
     * between references can be the intersection operator, so those refusals
     * stay silent-but-strict rather than being labeled cosmetic.
     */
    fun differsOnlyByInteriorWhitespace(a: String, b: String): Boolean {
        if (a.contains('\'') || b.contains('\'')) return false
        if (a.contains('"') || b.contains('"')) return false
        return a.replace(Regex("[\\s\\p{Z}]+"), "") ==
            b.replace(Regex("[\\s\\p{Z}]+"), "")
    }
}
