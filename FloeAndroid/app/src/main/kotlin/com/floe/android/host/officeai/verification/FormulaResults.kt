// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officeai.verification

import java.util.Locale
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.pow
import kotlin.math.truncate
import org.w3c.dom.Document

/** Wire tokens for the persisted computed-result proof. Only the first three
 * mean "the saved cache agrees with the workbook's own persisted values". */
internal object FormulaOutcomes {
    const val VERIFIED = "verified"
    const val ERROR_CACHED = "errorCached"
    const val BLANK_RESULT = "blankResult"
    /** Recognized formula source, but the shape/dependency context is outside
     * the bounded evaluator: explicitly NOT verified. */
    const val UNSUPPORTED = "unsupported"
}

/** Outcome of checking ONE saved formula cell's persisted result. */
internal sealed class FormulaCheck {
    data class Verified(val outcome: String) : FormulaCheck()

    /** The source is saved correctly but no exact result proof exists. */
    data class Unverified(val reason: String) : FormulaCheck()

    /** The persisted state contradicts the formula / its dependencies. */
    data class Failed(val code: String) : FormulaCheck()
}

/** The bounded evaluator's value domain. [Fault] is a persisted-workbook
 * contradiction discovered in the dependency chain (never an Excel error). */
internal sealed class FormulaComputation {
    data class Number(val value: Double) : FormulaComputation()
    data class Text(val value: String) : FormulaComputation()
    data class Bool(val value: Boolean) : FormulaComputation()
    data class Error(val code: String) : FormulaComputation()
    object Blank : FormulaComputation()
    data class Fault(val code: String) : FormulaComputation()
    data class Unsupported(val reason: String) : FormulaComputation()
}

private val FORMULA_NUMBER_GRAMMAR =
    Regex("^[+-]?(\\d+(\\.\\d*)?|\\.\\d+)([eE][+-]?\\d+)?$")

/** Strict finite decimal text: rejects NaN/Infinity/hex forms the platform
 * `toDouble` would otherwise accept. */
private fun strictNumber(raw: String): Double? {
    val trimmed = raw.trim()
    if (!FORMULA_NUMBER_GRAMMAR.matches(trimmed)) return null
    val value = trimmed.toDoubleOrNull() ?: return null
    return if (value.isFinite()) value else null
}

private fun booleanToken(raw: String): Boolean? = when (raw.trim().lowercase(Locale.ROOT)) {
    "1", "true" -> true
    "0", "false" -> false
    else -> null
}

/** Relative 1e-9 tolerance, exactly the fixed donor's `numbersMatch`:
 * serialization noise is tolerated, a genuinely different result is not. */
private fun numbersMatch(expected: Double, cached: Double): Boolean {
    if (!cached.isFinite()) return false
    if (expected == cached) return true
    val scale = max(max(abs(expected), abs(cached)), 1.0)
    return abs(expected - cached) <= scale * 1e-9
}

/**
 * Persisted XLSX formula-RESULT verification (C08 OFC-CELL-FORMULA-RECALC).
 *
 * The exact saved `<f>` SOURCE comparison stays in [CellIntentEvaluator]; this
 * object adds a SEPARATE proof: recompute the saved formula from the values
 * persisted in the SAME saved workbook and require the cell's own persisted
 * `<v>` cache/type to agree.
 *
 * Honesty rules:
 *  - a missing cache is always a refusal, even for an unsupported shape (the
 *    recalculation was supposed to write one; a source match cannot replace it);
 *  - a cache that contradicts recomputation is a refusal (stale or malformed);
 *  - a recognized shape whose dependency context is outside the bounded
 *    contract is `Unverified`, never counted as verified and never silently
 *    treated as success;
 *  - dependencies are recomputed from their own persisted inputs (a stale
 *    intermediate cache cannot certify the dependent cell), and a dependency
 *    with no cache or a contradicting cache is a refusal;
 *  - only SUM/MIN/MAX/COUNT/AVERAGE, IF, ROUND, numeric comparisons/arithmetic,
 *    A1 references/ranges and constant text/boolean values are evaluated —
 *    the exact subset of the fixed iOS donor
 *    `FloeAgent/Sources/FloeDocuments/OfficeFormulaVerification.swift`
 *    (a59b4d4). Everything else (other functions, `&`, `%`, `^`, 3-D/external
 *    references, shared/array formulas without their own text, data tables,
 *    huge ranges, deep nesting, cycles) is explicitly unsupported. This is
 *    NOT full Excel compatibility and never claims to be.
 *
 * The evaluation is read-only and bounded: the caller's already-parsed target
 * worksheet is reused; every other worksheet part is read through the existing
 * [BoundedZipReader] and [TrustedXml] guards with additional cell/byte/sheet
 * caps in [FormulaLimits]. Nothing is extracted, written or executed.
 */
internal object FormulaResults {

    fun inspect(
        zip: BoundedZipReader,
        plan: XlsxParts.WorkbookPlan.Ready,
        targetSheetIndex: Int,
        targetSheetDocument: Document,
        targetCell: WorksheetCell,
        sharedStrings: List<String>?,
    ): FormulaCheck {
        val source = targetCell.formulaSource
            ?: return FormulaCheck.Unverified("formula source is unreadable")
        // The cache defect is decided FIRST: a recalculated formula must carry
        // its result even when the shape would not be evaluated (donor parity).
        if (targetCell.cachedValue == null) {
            return FormulaCheck.Failed(VerificationCodes.FORMULA_RESULT_MISSING_CACHE)
        }
        if (targetCell.formulaKind == "dataTable") {
            // A data-table result depends on its input-cell matrix; the
            // bounded scalar evaluator cannot reproduce it honestly.
            return FormulaCheck.Unverified("data-table formula is not evaluated")
        }
        val formula = FormulaNormalizer.normalize(source)
        if (formula.isEmpty()) return FormulaCheck.Unverified("formula is empty")
        if (formula.toByteArray(Charsets.UTF_8).size > FormulaLimits.MAX_FORMULA_BYTES) {
            return FormulaCheck.Unverified("formula exceeds the bounded length")
        }
        val targetSheet = plan.sheets.getOrNull(targetSheetIndex)
            ?: return FormulaCheck.Unverified("target sheet is unresolved")
        val partName = targetSheet.partName
            ?: return FormulaCheck.Unverified("target sheet is not a worksheet")
        val workbook = WorkbookCellIndex(
            zip = zip,
            plan = plan,
            sharedStrings = sharedStrings,
            targetIndex = targetSheetIndex,
            targetDocument = targetSheetDocument,
        )
        val context = EvaluationContext(workbook, partName, targetSheet.name)
        val computation = context.evaluateTarget(targetCell.address, formula)
        return when (computation) {
            is FormulaComputation.Fault -> FormulaCheck.Failed(computation.code)
            is FormulaComputation.Unsupported ->
                FormulaCheck.Unverified(boundedReason(computation.reason))
            else -> when (val verdict = cacheVerdict(computation, targetCell)) {
                CacheVerdict.MATCH -> FormulaCheck.Verified(outcomeFor(computation))
                CacheVerdict.TYPE_MISMATCH ->
                    FormulaCheck.Failed(VerificationCodes.FORMULA_RESULT_TYPE_MISMATCH)
                CacheVerdict.STALE ->
                    FormulaCheck.Failed(VerificationCodes.FORMULA_RESULT_STALE_CACHE)
            }
        }
    }

    private fun outcomeFor(value: FormulaComputation): String = when (value) {
        is FormulaComputation.Error -> FormulaOutcomes.ERROR_CACHED
        FormulaComputation.Blank -> FormulaOutcomes.BLANK_RESULT
        else -> FormulaOutcomes.VERIFIED
    }

    private enum class CacheVerdict { MATCH, STALE, TYPE_MISMATCH }

    /** Compares recomputation against ONE persisted cell cache/type. A type
     * that cannot legally carry a formula result at all is distinguished from
     * a legal-but-contradictory value; both fail closed. */
    private fun cacheVerdict(expected: FormulaComputation, cell: WorksheetCell): CacheVerdict {
        val type = cell.typeAttr
        val raw = cell.cachedValue ?: return CacheVerdict.STALE
        return when (expected) {
            is FormulaComputation.Number -> {
                if (type != null && type != "n") return incompatible(type)
                val cached = strictNumber(raw) ?: return CacheVerdict.STALE
                if (numbersMatch(expected.value, cached)) CacheVerdict.MATCH else CacheVerdict.STALE
            }
            is FormulaComputation.Text -> {
                if (type != "str") return incompatible(type)
                if (raw == expected.value) CacheVerdict.MATCH else CacheVerdict.STALE
            }
            is FormulaComputation.Bool -> {
                if (type != "b") return incompatible(type)
                val cached = booleanToken(raw) ?: return CacheVerdict.STALE
                if (cached == expected.value) CacheVerdict.MATCH else CacheVerdict.STALE
            }
            is FormulaComputation.Error -> {
                if (type != "e") return incompatible(type)
                if (raw == expected.code) CacheVerdict.MATCH else CacheVerdict.STALE
            }
            FormulaComputation.Blank -> when {
                raw.isNotEmpty() -> CacheVerdict.STALE
                type == null || type == "n" || type == "str" -> CacheVerdict.MATCH
                else -> CacheVerdict.TYPE_MISMATCH
            }
            else -> CacheVerdict.STALE
        }
    }

    /** Legal formula-result type attributes are n/absent, str, b and e; any
     * other persisted type (shared string index, inline string, date) cannot
     * carry this formula's result. */
    private fun incompatible(type: String?): CacheVerdict = when (type) {
        null, "n", "str", "b", "e" -> CacheVerdict.STALE
        else -> CacheVerdict.TYPE_MISMATCH
    }

    private fun boundedReason(raw: String): String {
        val builder = StringBuilder(minOf(raw.length, FormulaLimits.MAX_REASON_CHARS))
        for (ch in raw) {
            if (builder.length >= FormulaLimits.MAX_REASON_CHARS) break
            builder.append(if (ch < ' ' || ch == '\u007F') ' ' else ch)
        }
        return builder.toString().trim()
    }
}

private object FormulaLimits {
    const val MAX_FORMULA_BYTES = 8_192
    const val MAX_PARSE_DEPTH = 64
    const val MAX_NODE_DEPTH = 64
    const val MAX_FORMULA_DEPTH = 64
    const val MAX_DEPENDENCIES = 4_096
    const val MAX_RANGE_CELLS = 1_024
    const val MAX_FUNCTION_ARGS = 32
    const val MAX_CONTEXT_SHEETS = 32
    const val MAX_CELLS_PER_SHEET = 65_536
    const val MAX_DEPENDENCY_PART_BYTES = 4L * 1024L * 1024L
    const val MAX_CONTEXT_BYTES = 16L * 1024L * 1024L
    const val MAX_REASON_CHARS = 140
}

// ---------------------------------------------------------------------
// Bounded workbook dependency context
// ---------------------------------------------------------------------

private sealed class SheetLookup {
    data class Ready(
        val key: String,
        val name: String?,
        val byAddress: Map<String, WorksheetCell>,
        val duplicateAddresses: Set<String>,
    ) : SheetLookup()

    data class Unavailable(val reason: String) : SheetLookup()
}

/** Lazily indexes ONLY the worksheets a formula actually references, through
 * the caller's already-open bounded ZIP. The target worksheet DOM is reused
 * from the main verification path and is never re-read. */
private class WorkbookCellIndex(
    private val zip: BoundedZipReader,
    private val plan: XlsxParts.WorkbookPlan.Ready,
    val sharedStrings: List<String>?,
    private val targetIndex: Int,
    private val targetDocument: Document,
) {
    private val loaded = HashMap<String, SheetLookup>()
    private val indexByName = HashMap<String, Int>()
    private val ambiguousNames = HashSet<String>()
    private var parsedDependencySheets = 0
    private var parsedDependencyBytes = 0L
    private val targetKey: String = plan.sheets[targetIndex].partName.orEmpty()

    init {
        plan.sheets.forEachIndexed { index, sheet ->
            val name = sheet.name ?: return@forEachIndexed
            val key = name.uppercase(Locale.ROOT)
            if (indexByName.put(key, index) != null) ambiguousNames.add(key)
        }
    }

    fun lookupByKey(key: String, name: String?): SheetLookup {
        loaded[key]?.let { return it }
        val lookup = if (key == targetKey) {
            scanSheet(key, name, targetDocument)
        } else {
            loadDependency(key)
        }
        loaded[key] = lookup
        return lookup
    }

    fun lookupByName(rawName: String): SheetLookup {
        val key = rawName.uppercase(Locale.ROOT)
        if (ambiguousNames.contains(key)) {
            return SheetLookup.Unavailable("dependency sheet name is ambiguous")
        }
        val index = indexByName[key]
            ?: return SheetLookup.Unavailable("dependency sheet is unavailable")
        val target = plan.sheets[index]
        val part = target.partName
            ?: return SheetLookup.Unavailable("dependency sheet is not a worksheet")
        return lookupByKey(part, target.name)
    }

    private fun loadDependency(key: String): SheetLookup {
        val target = plan.sheets.firstOrNull { it.partName == key }
            ?: return SheetLookup.Unavailable("dependency sheet is unavailable")
        if (parsedDependencySheets >= FormulaLimits.MAX_CONTEXT_SHEETS) {
            return SheetLookup.Unavailable("dependency sheet budget exceeded")
        }
        val bytes = when (val read = zip.readPart(key)) {
            is PartReadResult.Bytes -> read.data
            is PartReadResult.Missing ->
                return SheetLookup.Unavailable("dependency sheet is unavailable")
            is PartReadResult.Refused ->
                return SheetLookup.Unavailable("dependency sheet is unreadable")
        }
        if (bytes.size.toLong() > FormulaLimits.MAX_DEPENDENCY_PART_BYTES) {
            return SheetLookup.Unavailable("dependency sheet part exceeds the bounded read")
        }
        if (parsedDependencyBytes + bytes.size > FormulaLimits.MAX_CONTEXT_BYTES) {
            return SheetLookup.Unavailable("dependency context bytes exceed the bound")
        }
        parsedDependencyBytes += bytes.size
        parsedDependencySheets += 1
        val document = when (val parsed = TrustedXml.parse(bytes)) {
            is XmlParseResult.Parsed -> parsed.document
            is XmlParseResult.Refused ->
                return SheetLookup.Unavailable("dependency sheet is unreadable")
        }
        return scanSheet(key, target.name, document)
    }

    private fun scanSheet(key: String, name: String?, document: Document): SheetLookup =
        when (val scan = WorksheetCells.scan(document, FormulaLimits.MAX_CELLS_PER_SHEET)) {
            is WorksheetScan.Ready -> SheetLookup.Ready(
                key = key,
                name = name,
                byAddress = scan.byAddress,
                duplicateAddresses = scan.duplicateAddresses,
            )
            WorksheetScan.TooManyCells ->
                SheetLookup.Unavailable("dependency context is truncated")
            WorksheetScan.Unaddressable ->
                SheetLookup.Unavailable("dependency sheet carries cells without identity")
        }
}

// ---------------------------------------------------------------------
// Evaluation
// ---------------------------------------------------------------------

private class EvaluationContext(
    private val workbook: WorkbookCellIndex,
    rootKey: String,
    rootName: String?,
) {
    private var dependencies = 0
    private var nodeDepth = 0
    private var formulaDepth = 0
    private val visiting = HashSet<String>()
    private var currentKey = rootKey
    private var currentName = rootName

    fun evaluateTarget(address: String, formula: String): FormulaComputation {
        // The target is part of the dependency graph: a self/indirectly
        // circular reference must be reported, never evaluated to a guess.
        visiting.add(identityKey(currentKey, address))
        return evaluateFormula(formula)
    }

    private fun evaluateFormula(formula: String): FormulaComputation {
        if (formulaDepth >= FormulaLimits.MAX_FORMULA_DEPTH) {
            return FormulaComputation.Unsupported("formula nesting exceeds the bound")
        }
        formulaDepth += 1
        try {
            val parser = FormulaParser(formula)
            val node = parser.parse()
                ?: return FormulaComputation.Unsupported("unrecognized formula shape")
            val value = resolve(node)
            if (value is FormulaComputation.Number && !value.value.isFinite()) {
                return FormulaComputation.Unsupported("non-finite arithmetic result")
            }
            return value
        } finally {
            formulaDepth -= 1
        }
    }

    private fun identityKey(key: String, address: String): String = "$key!$address"

    private fun resolve(node: FormulaNode): FormulaComputation {
        if (nodeDepth >= FormulaLimits.MAX_NODE_DEPTH) {
            return FormulaComputation.Unsupported("formula nesting exceeds the bound")
        }
        nodeDepth += 1
        try {
            return when (node) {
                is FormulaNode.NodeNumber -> FormulaComputation.Number(node.value)
                is FormulaNode.NodeText -> FormulaComputation.Text(node.text)
                is FormulaNode.NodeBool -> FormulaComputation.Bool(node.value)
                is FormulaNode.NodeRef -> resolveReference(node.sheet, node.cell)
                is FormulaNode.NodeRange ->
                    FormulaComputation.Unsupported("a range cannot be used as a scalar value")
                is FormulaNode.NodeCall -> resolveFunction(node.name, node.arguments)
                is FormulaNode.NodeBinary -> resolveBinary(node.op, node.left, node.right)
                is FormulaNode.NodeNegate -> when (val value = resolve(node.value)) {
                    is FormulaComputation.Number -> FormulaComputation.Number(-value.value)
                    is FormulaComputation.Error -> value
                    is FormulaComputation.Fault -> value
                    is FormulaComputation.Unsupported -> value
                    else -> FormulaComputation.Unsupported("unary minus on a non-number")
                }
            }
        } finally {
            nodeDepth -= 1
        }
    }

    private fun resolveReference(sheetName: String?, address: String): FormulaComputation {
        dependencies += 1
        if (dependencies > FormulaLimits.MAX_DEPENDENCIES) {
            return FormulaComputation.Unsupported("dependency budget exceeded")
        }
        val lookup = if (sheetName == null) {
            workbook.lookupByKey(currentKey, currentName)
        } else {
            workbook.lookupByName(sheetName)
        }
        val ready = when (lookup) {
            is SheetLookup.Unavailable -> return FormulaComputation.Unsupported(lookup.reason)
            is SheetLookup.Ready -> lookup
        }
        if (ready.duplicateAddresses.contains(address)) {
            return FormulaComputation.Unsupported("duplicate cell identity: $address")
        }
        val cell = ready.byAddress[address] ?: return FormulaComputation.Blank
        if (!cell.hasFormula) return decodePersisted(cell)
        if (cell.formulaKind == "dataTable") {
            return FormulaComputation.Unsupported("data-table formula dependency is not evaluated")
        }
        val source = cell.formulaSource
            ?: return FormulaComputation.Unsupported("shared formula dependency has no own source")
        if (cell.cachedValue == null) {
            return FormulaComputation.Fault(VerificationCodes.FORMULA_DEPENDENCY_MISSING_CACHE)
        }
        val identity = identityKey(ready.key, address)
        if (!visiting.add(identity)) {
            return FormulaComputation.Unsupported("circular formula dependency")
        }
        val previousKey = currentKey
        val previousName = currentName
        currentKey = ready.key
        currentName = ready.name
        val value = try {
            evaluateFormula(FormulaNormalizer.normalize(source))
        } finally {
            currentKey = previousKey
            currentName = previousName
            visiting.remove(identity)
        }
        return when (value) {
            is FormulaComputation.Fault, is FormulaComputation.Unsupported -> value
            else -> {
                // Recompute alone is not enough: the dependency's OWN persisted
                // cache must agree, otherwise a stale intermediate value is
                // being hidden inside an apparently correct dependent cache.
                if (cacheVerdictFor(value, cell) != DependencyCache.MATCH) {
                    FormulaComputation.Fault(VerificationCodes.FORMULA_DEPENDENCY_STALE_CACHE)
                } else {
                    value
                }
            }
        }
    }

    private enum class DependencyCache { MATCH, MISMATCH }

    private fun cacheVerdictFor(
        expected: FormulaComputation,
        cell: WorksheetCell,
    ): DependencyCache = when (expected) {
        is FormulaComputation.Number -> {
            val type = cell.typeAttr
            val cached = cell.cachedValue?.let { strictNumber(it) }
            if ((type == null || type == "n") && cached != null &&
                numbersMatch(expected.value, cached)
            ) {
                DependencyCache.MATCH
            } else {
                DependencyCache.MISMATCH
            }
        }
        is FormulaComputation.Text -> {
            if (cell.typeAttr == "str" && cell.cachedValue == expected.value) {
                DependencyCache.MATCH
            } else {
                DependencyCache.MISMATCH
            }
        }
        is FormulaComputation.Bool -> {
            val cached = cell.cachedValue?.let { booleanToken(it) }
            if (cell.typeAttr == "b" && cached == expected.value) {
                DependencyCache.MATCH
            } else {
                DependencyCache.MISMATCH
            }
        }
        is FormulaComputation.Error -> {
            if (cell.typeAttr == "e" && cell.cachedValue == expected.code) {
                DependencyCache.MATCH
            } else {
                DependencyCache.MISMATCH
            }
        }
        FormulaComputation.Blank -> {
            if (cell.cachedValue.isNullOrEmpty()) DependencyCache.MATCH else DependencyCache.MISMATCH
        }
        else -> DependencyCache.MISMATCH
    }

    private fun decodePersisted(cell: WorksheetCell): FormulaComputation {
        val raw = cell.cachedValue
        return when (val type = cell.typeAttr) {
            null, "n" -> {
                if (raw == null || raw.trim().isEmpty()) {
                    FormulaComputation.Blank
                } else {
                    strictNumber(raw)?.let { FormulaComputation.Number(it) }
                        ?: FormulaComputation.Unsupported("dependency cell is not numeric")
                }
            }
            "s" -> {
                val strings = workbook.sharedStrings
                    ?: return FormulaComputation.Unsupported(
                        "dependency shared strings are unavailable",
                    )
                val index = raw?.trim()?.toIntOrNull()
                if (index == null || index < 0 || index >= strings.size) {
                    FormulaComputation.Unsupported("dependency shared string index is invalid")
                } else {
                    FormulaComputation.Text(strings[index])
                }
            }
            "str" -> FormulaComputation.Text(raw ?: "")
            "inlineStr" -> cell.inlineText?.let { FormulaComputation.Text(it) }
                ?: FormulaComputation.Blank
            "b" -> booleanToken(raw ?: "")?.let { FormulaComputation.Bool(it) }
                ?: FormulaComputation.Unsupported("dependency boolean is invalid")
            "e" -> if (raw.isNullOrEmpty()) {
                FormulaComputation.Unsupported("dependency error code is missing")
            } else {
                FormulaComputation.Error(raw)
            }
            else -> FormulaComputation.Unsupported(
                "dependency type ${type.take(16)} is not evaluated",
            )
        }
    }

    private fun resolveFunction(name: String, arguments: List<FormulaNode>): FormulaComputation {
        if (arguments.size > FormulaLimits.MAX_FUNCTION_ARGS) {
            return FormulaComputation.Unsupported("too many function arguments")
        }
        return when (name.uppercase(Locale.ROOT)) {
            "IF" -> resolveIf(arguments)
            "ROUND" -> resolveRound(arguments)
            "SUM", "MIN", "MAX", "COUNT", "AVERAGE" -> resolveAggregate(name, arguments)
            else -> FormulaComputation.Unsupported(
                "function ${name.take(32)} is not evaluated by the bounded checker",
            )
        }
    }

    private fun resolveIf(arguments: List<FormulaNode>): FormulaComputation {
        if (arguments.size !in 2..3) {
            return FormulaComputation.Unsupported("IF needs 2 or 3 arguments")
        }
        val condition = resolve(arguments[0])
        blocker(condition)?.let { return it }
        val value = numeric(condition)
            ?: return FormulaComputation.Unsupported("IF condition is not numeric or boolean")
        // Excel evaluates ONLY the selected branch; the other branch may even
        // contain an expression this checker cannot evaluate.
        if (value != 0.0) return resolve(arguments[1])
        if (arguments.size == 3) return resolve(arguments[2])
        return FormulaComputation.Bool(false)
    }

    private fun resolveRound(arguments: List<FormulaNode>): FormulaComputation {
        if (arguments.size != 2) {
            return FormulaComputation.Unsupported("ROUND needs 2 arguments")
        }
        val raw = resolve(arguments[0])
        blocker(raw)?.let { return it }
        val digits = resolve(arguments[1])
        blocker(digits)?.let { return it }
        val number = numeric(raw)
            ?: return FormulaComputation.Unsupported("ROUND value is not numeric")
        val placesValue = numeric(digits)
            ?: return FormulaComputation.Unsupported("ROUND precision is not numeric")
        if (!number.isFinite() || !placesValue.isFinite()) {
            return FormulaComputation.Unsupported("ROUND argument is not finite")
        }
        if (placesValue < -15.0 || placesValue > 15.0) {
            return FormulaComputation.Unsupported("ROUND precision is outside the supported range")
        }
        val places = truncate(placesValue).toInt()
        val factor = 10.0.pow(places)
        if (!factor.isFinite() || factor == 0.0) {
            return FormulaComputation.Unsupported("ROUND scale is outside the supported range")
        }
        val scaled = number * factor
        if (!scaled.isFinite()) return FormulaComputation.Unsupported("ROUND overflow")
        // Donor parity: round half AWAY FROM ZERO (Kotlin's round() is half up
        // toward positive infinity and would differ for negative halves).
        val rounded = if (scaled >= 0) floor(scaled + 0.5) else ceil(scaled - 0.5)
        val result = rounded / factor
        return if (result.isFinite()) {
            FormulaComputation.Number(result)
        } else {
            FormulaComputation.Unsupported("ROUND overflow")
        }
    }

    private fun resolveAggregate(
        name: String,
        arguments: List<FormulaNode>,
    ): FormulaComputation {
        val upper = name.uppercase(Locale.ROOT)
        val countOnly = upper == "COUNT"
        val numbers = ArrayList<Double>()
        for (argument in arguments) {
            when (val collected = collectNumbers(argument, countOnly)) {
                is NumberCollection.Values -> numbers.addAll(collected.values)
                is NumberCollection.Blocked -> return collected.computation
            }
        }
        return when (upper) {
            "SUM" -> FormulaComputation.Number(numbers.sum())
            "MIN" -> FormulaComputation.Number(numbers.minOrNull() ?: 0.0)
            "MAX" -> FormulaComputation.Number(numbers.maxOrNull() ?: 0.0)
            "AVERAGE" -> if (numbers.isEmpty()) {
                FormulaComputation.Error(DIVISION_BY_ZERO)
            } else {
                FormulaComputation.Number(numbers.sum() / numbers.size)
            }
            else -> FormulaComputation.Number(numbers.size.toDouble())
        }
    }

    private sealed class NumberCollection {
        data class Values(val values: List<Double>) : NumberCollection()
        data class Blocked(val computation: FormulaComputation) : NumberCollection()
    }

    /** Aggregate coercion, donor parity: a REFERENCE to text/boolean/blank is
     * ignored, a LITERAL numeric text is coerced, a literal non-numeric text
     * is #VALUE!, an error in a reference aborts everything except COUNT, and
     * a recomputed dependency must still agree with its own persisted cache. */
    private fun collectNumbers(node: FormulaNode, countOnly: Boolean): NumberCollection {
        return when (node) {
            is FormulaNode.NodeRange -> {
                val sheet = node.sheet
                val cells = expandRange(node.start, node.end)
                    ?: return blocked(
                        FormulaComputation.Unsupported(
                            "range ${node.start}:${node.end} is not bounded",
                        ),
                    )
                dependencies += cells.size
                if (dependencies > FormulaLimits.MAX_DEPENDENCIES) {
                    return blocked(FormulaComputation.Unsupported("dependency budget exceeded"))
                }
                val values = ArrayList<Double>()
                for (cell in cells) {
                    when (val resolved = resolveReference(sheet, cell)) {
                        is FormulaComputation.Number -> values.add(resolved.value)
                        FormulaComputation.Blank,
                        is FormulaComputation.Text,
                        is FormulaComputation.Bool -> Unit
                        is FormulaComputation.Error -> {
                            if (!countOnly) return blocked(resolved)
                        }
                        else -> return blocked(resolved)
                    }
                }
                NumberCollection.Values(values)
            }
            is FormulaNode.NodeRef -> when (val resolved = resolveReference(node.sheet, node.cell)) {
                is FormulaComputation.Number -> NumberCollection.Values(listOf(resolved.value))
                FormulaComputation.Blank,
                is FormulaComputation.Text,
                is FormulaComputation.Bool -> NumberCollection.Values(emptyList())
                is FormulaComputation.Error ->
                    if (countOnly) NumberCollection.Values(emptyList()) else blocked(resolved)
                else -> blocked(resolved)
            }
            is FormulaNode.NodeNumber -> NumberCollection.Values(listOf(node.value))
            is FormulaNode.NodeText -> {
                val number = strictNumber(node.text)
                if (number != null) {
                    NumberCollection.Values(listOf(number))
                } else if (countOnly) {
                    NumberCollection.Values(emptyList())
                } else {
                    blocked(FormulaComputation.Error(VALUE_ERROR))
                }
            }
            else -> when (val resolved = resolve(node)) {
                is FormulaComputation.Number -> NumberCollection.Values(listOf(resolved.value))
                is FormulaComputation.Error -> blocked(resolved)
                is FormulaComputation.Bool ->
                    NumberCollection.Values(listOf(if (resolved.value) 1.0 else 0.0))
                is FormulaComputation.Text ->
                    blocked(
                        FormulaComputation.Unsupported("text produced by a scalar expression"),
                    )
                FormulaComputation.Blank -> NumberCollection.Values(emptyList())
                else -> blocked(resolved)
            }
        }
    }

    private fun blocked(value: FormulaComputation): NumberCollection =
        NumberCollection.Blocked(value)

    private fun resolveBinary(
        op: Operator,
        leftNode: FormulaNode,
        rightNode: FormulaNode,
    ): FormulaComputation {
        val left = resolve(leftNode)
        val right = resolve(rightNode)
        blocker(left)?.let { return it }
        blocker(right)?.let { return it }
        val leftNumber = numeric(left)
        val rightNumber = numeric(right)
        if (leftNumber == null || rightNumber == null) {
            return FormulaComputation.Unsupported("non-numeric operand")
        }
        return when (op) {
            Operator.EQ -> FormulaComputation.Bool(leftNumber == rightNumber)
            Operator.NE -> FormulaComputation.Bool(leftNumber != rightNumber)
            Operator.LT -> FormulaComputation.Bool(leftNumber < rightNumber)
            Operator.LE -> FormulaComputation.Bool(leftNumber <= rightNumber)
            Operator.GT -> FormulaComputation.Bool(leftNumber > rightNumber)
            Operator.GE -> FormulaComputation.Bool(leftNumber >= rightNumber)
            Operator.ADD -> FormulaComputation.Number(leftNumber + rightNumber)
            Operator.SUB -> FormulaComputation.Number(leftNumber - rightNumber)
            Operator.MUL -> FormulaComputation.Number(leftNumber * rightNumber)
            Operator.DIV -> {
                if (rightNumber == 0.0) {
                    FormulaComputation.Error(DIVISION_BY_ZERO)
                } else {
                    FormulaComputation.Number(leftNumber / rightNumber)
                }
            }
        }
    }

    /** Faults and unsupported shapes block evaluation; Excel errors also block
     * the surrounding arithmetic/condition (they are real result values only
     * at the top level). */
    private fun blocker(value: FormulaComputation): FormulaComputation? = when (value) {
        is FormulaComputation.Fault,
        is FormulaComputation.Unsupported,
        is FormulaComputation.Error -> value
        else -> null
    }

    private fun numeric(value: FormulaComputation): Double? = when (value) {
        is FormulaComputation.Number -> value.value
        is FormulaComputation.Bool -> if (value.value) 1.0 else 0.0
        FormulaComputation.Blank -> 0.0
        else -> null
    }

    private fun expandRange(start: String, end: String): List<String>? {
        val startCell = A1Ref.parse(start) ?: return null
        val endCell = A1Ref.parse(end) ?: return null
        val columnCount = abs(startCell.column - endCell.column) + 1
        val rowCount = abs(startCell.row - endCell.row) + 1
        if (columnCount > FormulaLimits.MAX_RANGE_CELLS) return null
        if (rowCount > FormulaLimits.MAX_RANGE_CELLS / columnCount) return null
        if (columnCount * rowCount > FormulaLimits.MAX_RANGE_CELLS) return null
        val columnStep = if (startCell.column <= endCell.column) 1 else -1
        val rowStep = if (startCell.row <= endCell.row) 1 else -1
        val cells = ArrayList<String>(columnCount * rowCount)
        var column = startCell.column
        while (true) {
            var row = startCell.row
            while (true) {
                cells.add(A1Ref.letters(column) + row)
                if (row == endCell.row) break
                row += rowStep
            }
            if (column == endCell.column) break
            column += columnStep
        }
        return cells
    }

    private companion object {
        const val DIVISION_BY_ZERO = "#DIV/0!"
        const val VALUE_ERROR = "#VALUE!"
    }
}

private enum class Operator { ADD, SUB, MUL, DIV, EQ, NE, LT, LE, GT, GE }

// ---------------------------------------------------------------------
// Bounded recursive-descent parser (donor subset)
// ---------------------------------------------------------------------

private sealed class FormulaNode {
    data class NodeNumber(val value: Double) : FormulaNode()
    data class NodeText(val text: String) : FormulaNode()
    data class NodeBool(val value: Boolean) : FormulaNode()
    data class NodeRef(val sheet: String?, val cell: String) : FormulaNode()
    data class NodeRange(val sheet: String?, val start: String, val end: String) : FormulaNode()
    data class NodeCall(val name: String, val arguments: List<FormulaNode>) : FormulaNode()
    data class NodeBinary(
        val op: Operator,
        val left: FormulaNode,
        val right: FormulaNode,
    ) : FormulaNode()
    data class NodeNegate(val value: FormulaNode) : FormulaNode()
}

/** Small bounded parser for the donor's exact grammar subset. Unknown
 * constructs fail to PARSE (reported unsupported) instead of being guessed. */
private class FormulaParser(private val text: String) {
    private var index = 0
    private var depth = 0

    fun parse(): FormulaNode? {
        skipWhitespace()
        val node = parseComparison() ?: return null
        skipWhitespace()
        return if (index >= text.length) node else null
    }

    private fun parseComparison(): FormulaNode? {
        val left = parseSum() ?: return null
        skipWhitespace()
        val op = when {
            consumeToken("<=") -> Operator.LE
            consumeToken(">=") -> Operator.GE
            consumeToken("<>") -> Operator.NE
            consume('=') -> Operator.EQ
            consume('<') -> Operator.LT
            consume('>') -> Operator.GT
            else -> return left
        }
        val right = parseSum() ?: return null
        return FormulaNode.NodeBinary(op, left, right)
    }

    private fun parseSum(): FormulaNode? {
        var left = parseTerm() ?: return null
        while (true) {
            skipWhitespace()
            when {
                consume('+') -> {
                    val right = parseTerm() ?: return null
                    left = FormulaNode.NodeBinary(Operator.ADD, left, right)
                }
                consume('-') -> {
                    val right = parseTerm() ?: return null
                    left = FormulaNode.NodeBinary(Operator.SUB, left, right)
                }
                else -> return left
            }
        }
    }

    private fun parseTerm(): FormulaNode? {
        var left = parseFactor() ?: return null
        while (true) {
            skipWhitespace()
            when {
                consume('*') -> {
                    val right = parseFactor() ?: return null
                    left = FormulaNode.NodeBinary(Operator.MUL, left, right)
                }
                consume('/') -> {
                    val right = parseFactor() ?: return null
                    left = FormulaNode.NodeBinary(Operator.DIV, left, right)
                }
                else -> return left
            }
        }
    }

    private fun parseFactor(): FormulaNode? {
        if (depth >= FormulaLimits.MAX_PARSE_DEPTH) return null
        depth += 1
        try {
            skipWhitespace()
            if (consume('-')) {
                val value = parseFactor() ?: return null
                return FormulaNode.NodeNegate(value)
            }
            if (consume('(')) {
                val value = parseComparison() ?: return null
                if (!consume(')')) return null
                return value
            }
            if (peek('"')) return parseText()
            if (peekNameStart()) return parseIdentifier()
            return null
        } finally {
            depth -= 1
        }
    }

    private fun parseText(): FormulaNode? {
        if (!consume('"')) return null
        val out = StringBuilder()
        while (index < text.length) {
            val ch = text[index]
            index += 1
            if (ch == '"') {
                if (index < text.length && text[index] == '"') {
                    out.append('"')
                    index += 1
                    continue
                }
                return FormulaNode.NodeText(out.toString())
            }
            out.append(ch)
        }
        return null
    }

    private fun parseIdentifier(): FormulaNode? {
        var name = ""
        if (peek('\'')) {
            index += 1
            var closed = false
            while (index < text.length) {
                val ch = text[index]
                index += 1
                if (ch == '\'') {
                    if (index < text.length && text[index] == '\'') {
                        name += '\''
                        index += 1
                    } else {
                        closed = true
                        break
                    }
                } else {
                    name += ch
                }
            }
            if (!closed) return null
            if (!consume('!')) return null
            return parseCellOrRange(name)
        }
        val start = index
        while (index < text.length && isNameChar(text[index])) {
            name += text[index]
            index += 1
        }
        if (index == start || name.isEmpty()) return null
        if (peek('(')) return parseCall(name)
        if (consume('!')) return parseCellOrRange(name)
        val upper = name.uppercase(Locale.ROOT)
        if (upper == "TRUE") return FormulaNode.NodeBool(true)
        if (upper == "FALSE") return FormulaNode.NodeBool(false)
        strictNumber(name)?.let { return FormulaNode.NodeNumber(it) }
        val cleaned = stripAbsolute(name) ?: return null
        if (A1Ref.parse(cleaned) == null) return null
        if (consume(':')) {
            val end = parseReferenceToken()?.let(::stripAbsolute) ?: return null
            if (A1Ref.parse(end) == null) return null
            return FormulaNode.NodeRange(null, cleaned, end)
        }
        return FormulaNode.NodeRef(null, cleaned)
    }

    private fun parseCall(name: String): FormulaNode? {
        if (!consume('(')) return null
        val arguments = ArrayList<FormulaNode>()
        skipWhitespace()
        if (consume(')')) return FormulaNode.NodeCall(name, arguments)
        while (true) {
            val argument = parseComparison() ?: return null
            arguments.add(argument)
            if (arguments.size > FormulaLimits.MAX_FUNCTION_ARGS) return null
            skipWhitespace()
            if (consume(',')) continue
            if (consume(';')) continue
            if (consume(')')) return FormulaNode.NodeCall(name, arguments)
            return null
        }
    }

    private fun parseCellOrRange(sheet: String): FormulaNode? {
        val start = parseReferenceToken()?.let(::stripAbsolute) ?: return null
        if (A1Ref.parse(start) == null) return null
        if (consume(':')) {
            val end = parseReferenceToken()?.let(::stripAbsolute) ?: return null
            if (A1Ref.parse(end) == null) return null
            return FormulaNode.NodeRange(sheet, start, end)
        }
        return FormulaNode.NodeRef(sheet, start)
    }

    private fun parseReferenceToken(): String? {
        skipWhitespace()
        val start = index
        while (index < text.length) {
            val ch = text[index]
            if (ch.isLetterOrDigit() || ch == '$') index += 1 else break
        }
        return if (index > start) text.substring(start, index) else null
    }

    /** Strict A1-with-optional-$ token: a misplaced `$` (e.g. `A$B1`) is
     * refused instead of being silently rewritten into a different cell. */
    private fun stripAbsolute(raw: String): String? {
        if (!raw.contains('$')) return raw.uppercase(Locale.ROOT)
        if (!ABSOLUTE_CELL.matches(raw)) return null
        return raw.replace("$", "").uppercase(Locale.ROOT)
    }

    private companion object {
        val ABSOLUTE_CELL = Regex("^\\$?[A-Za-z]{1,3}\\$?[0-9]{1,7}$")
    }

    private fun isNameChar(ch: Char): Boolean =
        ch.isLetterOrDigit() || ch == '_' || ch == '.' || ch == '$'

    private fun peekNameStart(): Boolean {
        if (index >= text.length) return false
        val ch = text[index]
        return ch.isLetterOrDigit() || ch == '_' || ch == '\'' || ch == '$'
    }

    private fun peek(ch: Char): Boolean = index < text.length && text[index] == ch

    private fun skipWhitespace() {
        while (index < text.length && text[index].isWhitespace()) index += 1
    }

    private fun consume(ch: Char): Boolean {
        skipWhitespace()
        if (index >= text.length || text[index] != ch) return false
        index += 1
        return true
    }

    private fun consumeToken(token: String): Boolean {
        skipWhitespace()
        if (index + token.length > text.length) return false
        for (offset in token.indices) {
            if (text[index + offset] != token[offset]) return false
        }
        index += token.length
        return true
    }
}

/** Bounded A1 identity: 1..3 A-Z letters and a positive row within the XLSX
 * grid limit. Absolute markers are stripped BEFORE construction. */
private class A1Ref(val column: Int, val row: Int) {
    companion object {
        fun parse(raw: String): A1Ref? {
            if (raw.isEmpty()) return null
            var letters = ""
            var digits = ""
            for (ch in raw) {
                if (digits.isEmpty() && ch in 'A'..'Z') {
                    letters += ch
                } else if (ch in '0'..'9' && letters.isNotEmpty()) {
                    digits += ch
                } else {
                    return null
                }
            }
            if (letters.isEmpty() || letters.length > 3) return null
            if (digits.isEmpty() || digits.length > 7) return null
            val row = digits.toIntOrNull() ?: return null
            if (row < 1 || row > 1_048_576) return null
            var column = 0
            for (ch in letters) column = column * 26 + (ch - 'A' + 1)
            if (column < 1 || column > 16_384) return null
            return A1Ref(column, row)
        }

        fun letters(column: Int): String {
            var value = column
            val out = StringBuilder()
            while (value > 0) {
                value -= 1
                out.insert(0, ('A' + value % 26))
                value /= 26
            }
            return out.toString()
        }
    }
}
