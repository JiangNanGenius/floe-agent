// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officeai

import com.floe.android.host.officeai.verification.FormulaOutcomes
import com.floe.android.host.officeai.verification.OoxmlTestFixtures
import com.floe.android.host.officeai.verification.OoxmlTestFixtures.XlsxCell
import com.floe.android.host.officeai.verification.OoxmlTestFixtures.XlsxSheet
import com.floe.android.host.officeai.verification.VerificationCodes
import com.floe.android.host.officeai.verification.VerificationNotes
import java.io.File
import java.io.FileOutputStream
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** C08 OFC-CELL-FORMULA-RECALC regression source against the ACTUAL verifier
 * over REAL saved OOXML ZIP fixtures. Every case proves the SAVED computed
 * result against the SAME package's persisted dependency values: a matching
 * `<f>` source is never enough on its own, and an unsupported shape is never
 * promoted to a verified result.
 */
class FormulaResultVerificationTest {

    private val tempFiles = ArrayList<File>()

    @After
    fun deleteTempArtifacts() {
        for (file in tempFiles) {
            runCatching { file.delete() }
        }
        tempFiles.clear()
    }

    // -----------------------------------------------------------------
    // helpers
    // -----------------------------------------------------------------

    private fun artifact(bytes: ByteArray): File {
        val file = File.createTempFile("floe-formula-c08-", ".bin")
        tempFiles.add(file)
        FileOutputStream(file).use { it.write(bytes) }
        return file
    }

    private fun inspect(
        bytes: ByteArray,
        expected: String,
        address: String,
        partIndex: Int = 0,
        kind: String = "formula",
    ): OfficeAiVerificationResult {
        val file = artifact(bytes)
        return OfficeAiOoxmlVerifier.inspect(
            OfficeAiVerificationInput(
                file = file,
                sha256 = OoxmlTestFixtures.sha256(bytes),
                bytes = bytes.size.toLong(),
                format = "xlsx",
                command = "setCellContent",
                expectedText = expected,
                contentKind = kind,
                cellAddress = address,
                partIndex = partIndex,
                baseline = null,
                nativeTargetEffectVerified = false,
                trustedCompletedJobProof = false,
            ),
        )
    }

    private fun factsOf(result: OfficeAiVerificationResult): OfficeAiVerificationFacts =
        when (result) {
            is OfficeAiVerificationResult.Verified -> result.facts
            is OfficeAiVerificationResult.Refused ->
                throw AssertionError("expected Verified, got Refused(${result.code})")
        }

    private fun refusedCode(result: OfficeAiVerificationResult): String =
        when (result) {
            is OfficeAiVerificationResult.Refused -> result.code
            is OfficeAiVerificationResult.Verified ->
                throw AssertionError("expected Refused, got Verified(${result.facts})")
        }

    private fun single(vararg cells: XlsxCell, strings: List<String>? = null): ByteArray =
        OoxmlTestFixtures.xlsxBytes(
            listOf(XlsxSheet("rId1", "sheet1.xml", cells.toList())),
            strings,
        )

    /** Asserts the source matched AND the persisted result was verified. */
    private fun assertVerified(facts: OfficeAiVerificationFacts, outcome: String) {
        assertTrue("the saved formula source must match", facts.expectedContentMatches)
        assertTrue(
            "the saved computed result must be independently verified",
            facts.cellFormulaResultVerified == true,
        )
        assertEquals(outcome, facts.cellFormulaResultOutcome)
    }

    /** Asserts an explicit, honest "source saved but result not proven". */
    private fun assertUnverified(facts: OfficeAiVerificationFacts) {
        assertTrue("the saved formula source itself is still compared", facts.expectedContentMatches)
        assertFalse("an unsupported shape is never a verified result",
            facts.cellFormulaResultVerified == true)
        assertEquals(FormulaOutcomes.UNSUPPORTED, facts.cellFormulaResultOutcome)
        assertTrue("the limitation token must be explicit",
            facts.limitations.contains(VerificationNotes.FORMULA_RESULT_UNVERIFIED))
    }

    // -----------------------------------------------------------------
    // correct / stale / missing cache
    // -----------------------------------------------------------------

    @Test
    fun sumCacheAgreeingWithPersistedDependenciesIsVerified() {
        val bytes = single(
            XlsxCell("A1", v = "1"),
            XlsxCell("A2", v = "2"),
            XlsxCell("A3", v = "3"),
            XlsxCell("B1", f = "SUM(A1:A3)", v = "6"),
        )
        val facts = factsOf(inspect(bytes, "=SUM(A1:A3)", "B1"))
        assertVerified(facts, FormulaOutcomes.VERIFIED)
        assertEquals("xl/worksheets/sheet1.xml", facts.partName)
        assertEquals(true, facts.cellHasFormula)
        assertEquals(true, facts.cellTypeMatchesIntent)
    }

    @Test
    fun sumCacheContradictingPersistedDependenciesIsRefused() {
        val bytes = single(
            XlsxCell("A1", v = "1"),
            XlsxCell("A2", v = "2"),
            XlsxCell("A3", v = "3"),
            XlsxCell("B1", f = "SUM(A1:A3)", v = "5"),
        )
        assertEquals(
            VerificationCodes.FORMULA_RESULT_STALE_CACHE,
            refusedCode(inspect(bytes, "=SUM(A1:A3)", "B1")),
        )
    }

    @Test
    fun changedPersistedDependencyInvalidatesTheDependentCache() {
        // B1's cache is stale (2 + 1 must be 3, not 90). C1's own cache (4) is
        // consistent with the RECOMPUTED B1, but a stale intermediate cache
        // must not certify the dependent cell either.
        val bytes = single(
            XlsxCell("A1", v = "2"),
            XlsxCell("B1", f = "A1+1", v = "90"),
            XlsxCell("C1", f = "B1+1", v = "4"),
        )
        assertEquals(
            VerificationCodes.FORMULA_DEPENDENCY_STALE_CACHE,
            refusedCode(inspect(bytes, "=B1+1", "C1")),
        )
    }

    @Test
    fun formulaCellWithoutPersistedCacheIsRefused() {
        val bytes = single(
            XlsxCell("A1", v = "1"),
            XlsxCell("A2", v = "2"),
            XlsxCell("A3", v = "3"),
            XlsxCell("B1", f = "SUM(A1:A3)"),
        )
        assertEquals(
            VerificationCodes.FORMULA_RESULT_MISSING_CACHE,
            refusedCode(inspect(bytes, "=SUM(A1:A3)", "B1")),
        )
    }

    @Test
    fun missingCacheIsRefusedEvenForAnUnsupportedShape() {
        // Donor parity: the recalculation was supposed to write a cache. The
        // missing-cache defect is decided before shape support.
        val bytes = single(
            XlsxCell("A1", v = "1"),
            XlsxCell("B1", f = "VLOOKUP(A1,A1:B2,2,FALSE)"),
        )
        assertEquals(
            VerificationCodes.FORMULA_RESULT_MISSING_CACHE,
            refusedCode(inspect(bytes, "=VLOOKUP(A1,A1:B2,2,FALSE)", "B1")),
        )
    }

    @Test
    fun numericResultCachedAsTextIsStale() {
        val bytes = single(
            XlsxCell("A1", v = "2"),
            XlsxCell("B1", t = "str", f = "A1*2", v = "4"),
        )
        assertEquals(
            VerificationCodes.FORMULA_RESULT_STALE_CACHE,
            refusedCode(inspect(bytes, "=A1*2", "B1")),
        )
    }

    @Test
    fun cacheIndexedAsSharedStringIsNotAFormulaNumber() {
        val bytes = single(
            XlsxCell("A1", v = "2"),
            XlsxCell("B1", t = "s", f = "A1*2", v = "0"),
            strings = listOf("4"),
        )
        assertEquals(
            VerificationCodes.FORMULA_RESULT_TYPE_MISMATCH,
            refusedCode(inspect(bytes, "=A1*2", "B1")),
        )
    }

    // -----------------------------------------------------------------
    // error / boolean / blank result handling
    // -----------------------------------------------------------------

    @Test
    fun errorResultVerifiesThePersistedErrorCode() {
        val bytes = single(
            XlsxCell("A1", v = "1"),
            XlsxCell("B1", t = "e", f = "A1/0", v = "#DIV/0!"),
        )
        val facts = factsOf(inspect(bytes, "=A1/0", "B1"))
        assertVerified(facts, FormulaOutcomes.ERROR_CACHED)
    }

    @Test
    fun numberPersistedWhereTheFormulaIsAnErrorIsStale() {
        val bytes = single(
            XlsxCell("A1", v = "1"),
            XlsxCell("B1", f = "A1/0", v = "0"),
        )
        assertEquals(
            VerificationCodes.FORMULA_RESULT_STALE_CACHE,
            refusedCode(inspect(bytes, "=A1/0", "B1")),
        )
    }

    @Test
    fun booleanComparisonResultVerifiesOnlyWithBooleanCache() {
        val verified = single(
            XlsxCell("A1", v = "2"),
            XlsxCell("B1", t = "b", f = "A1>=2", v = "1"),
        )
        assertVerified(factsOf(inspect(verified, "=A1>=2", "B1")), FormulaOutcomes.VERIFIED)

        val wrong = single(
            XlsxCell("A1", v = "2"),
            XlsxCell("B1", t = "b", f = "A1>=2", v = "0"),
        )
        assertEquals(
            VerificationCodes.FORMULA_RESULT_STALE_CACHE,
            refusedCode(inspect(wrong, "=A1>=2", "B1")),
        )
    }

    @Test
    fun blankResultAndItsTwoCacheShapesAreDistinguished() {
        // =A1 with A1 genuinely absent evaluates blank; an empty <v></v> is
        // the only honest blank cache.
        val blank = single(XlsxCell("B1", f = "A1", v = ""))
        assertVerified(factsOf(inspect(blank, "=A1", "B1")), FormulaOutcomes.BLANK_RESULT)

        // Excel persists a numeric 0 for a reference to an empty cell, which
        // contradicts the donor's blank evaluation: never accepted silently.
        val numericZero = single(XlsxCell("B1", f = "A1", v = "0"))
        assertEquals(
            VerificationCodes.FORMULA_RESULT_STALE_CACHE,
            refusedCode(inspect(numericZero, "=A1", "B1")),
        )
    }

    // -----------------------------------------------------------------
    // supported function / type semantics
    // -----------------------------------------------------------------

    @Test
    fun ifShortCircuitsAndRoundRoundsHalfAwayFromZero() {
        val bytes = single(
            XlsxCell("A1", v = "2"),
            XlsxCell("B1", f = "IF(A1>0,ROUND(-2.55,1),1/0)", v = "-2.6"),
            // The unselected branch contains a division by zero: Excel (and
            // this checker) must never evaluate it.
            XlsxCell("C1", f = "IF(A1<0,1/0,7)", v = "7"),
        )
        assertVerified(
            factsOf(inspect(bytes, "=IF(A1>0,ROUND(-2.55,1),1/0)", "B1")),
            FormulaOutcomes.VERIFIED,
        )
        assertVerified(
            factsOf(inspect(bytes, "=IF(A1<0,1/0,7)", "C1")),
            FormulaOutcomes.VERIFIED,
        )
    }

    @Test
    fun aggregatesIgnoreReferenceTextBooleansAndCountOnlyNumbers() {
        val bytes = single(
            XlsxCell("A1", t = "b", v = "1"),
            XlsxCell("A2", v = "2"),
            XlsxCell("A3", v = "4"),
            XlsxCell("B1", f = "AVERAGE(A1:A3)", v = "3"),
            XlsxCell("C1", f = "MIN(A1:A3)", v = "2"),
            XlsxCell("D1", f = "MAX(A1:A3)", v = "4"),
            XlsxCell("E1", f = "COUNT(A1:A3)", v = "2"),
            XlsxCell("F1", f = "SUM(TRUE,A1)", v = "1"),
        )
        assertVerified(factsOf(inspect(bytes, "=AVERAGE(A1:A3)", "B1")), FormulaOutcomes.VERIFIED)
        assertVerified(factsOf(inspect(bytes, "=MIN(A1:A3)", "C1")), FormulaOutcomes.VERIFIED)
        assertVerified(factsOf(inspect(bytes, "=MAX(A1:A3)", "D1")), FormulaOutcomes.VERIFIED)
        assertVerified(factsOf(inspect(bytes, "=COUNT(A1:A3)", "E1")), FormulaOutcomes.VERIFIED)
        // A literal TRUE is one; the reference to a boolean cell is ignored.
        assertVerified(factsOf(inspect(bytes, "=SUM(TRUE,A1)", "F1")), FormulaOutcomes.VERIFIED)
    }

    @Test
    fun averageOfNoNumbersPersistsTheDivisionError() {
        val bytes = single(XlsxCell("B1", t = "e", f = "AVERAGE(Z1:Z2)", v = "#DIV/0!"))
        assertVerified(
            factsOf(inspect(bytes, "=AVERAGE(Z1:Z2)", "B1")),
            FormulaOutcomes.ERROR_CACHED,
        )
    }

    @Test
    fun crossSheetQuotedNameAndEscapedQuoteResolve() {
        val bytes = OoxmlTestFixtures.xlsxBytes(
            listOf(
                XlsxSheet(
                    "rId1", "sheet1.xml",
                    listOf(
                        XlsxCell("A1", v = "8"),
                        XlsxCell("B1", f = "IF(A1>0,A1+1,0)", v = "9"),
                    ),
                    name = "Data's",
                ),
                XlsxSheet(
                    "rId2", "sheet2.xml",
                    listOf(XlsxCell("B1", f = "'Data''s'!B1+1", v = "10")),
                    name = "Report",
                ),
            ),
        )
        val facts = factsOf(inspect(bytes, "='Data''s'!B1+1", "B1", partIndex = 1))
        assertVerified(facts, FormulaOutcomes.VERIFIED)
        assertEquals("xl/worksheets/sheet2.xml", facts.partName)
    }

    @Test
    fun absoluteReferencesResolveToTheSamePersistedCells() {
        val bytes = single(
            XlsxCell("A1", v = "2"),
            XlsxCell("A2", v = "3"),
            XlsxCell("B1", f = "\$A\$1+\$A\$2", v = "5"),
        )
        assertVerified(
            factsOf(inspect(bytes, "=\$A\$1+\$A\$2", "B1")),
            FormulaOutcomes.VERIFIED,
        )
    }

    // -----------------------------------------------------------------
    // explicit unverified / refused shapes
    // -----------------------------------------------------------------

    @Test
    fun unsupportedFunctionIsExplicitlyUnverifiedNotVerified() {
        val bytes = single(
            XlsxCell("A1", v = "1"),
            XlsxCell("B1", f = "VLOOKUP(A1,A1:B2,2,FALSE)", v = "7"),
        )
        val facts = factsOf(inspect(bytes, "=VLOOKUP(A1,A1:B2,2,FALSE)", "B1"))
        assertUnverified(facts)
        assertTrue(
            "the bounded limitation names the unsupported function",
            facts.cellFormulaResultDetail?.contains("VLOOKUP") == true,
        )
    }

    @Test
    fun circularDependencyRemainsExplicitlyUnverified() {
        val bytes = single(
            XlsxCell("A1", f = "C1+1", v = "2"),
            XlsxCell("B1", f = "A1+1", v = "2"),
            XlsxCell("C1", f = "B1-1", v = "1"),
        )
        assertUnverified(factsOf(inspect(bytes, "=C1+1", "A1")))
    }

    @Test
    fun selfReferenceIsExplicitlyUnverified() {
        val bytes = single(XlsxCell("A1", f = "A1+1", v = "1"))
        assertUnverified(factsOf(inspect(bytes, "=A1+1", "A1")))
    }

    @Test
    fun sharedFormulaDependencyWithoutOwnTextStaysUnverified() {
        val bytes = single(
            XlsxCell("B1", f = "", fAttrs = " t=\"shared\" si=\"0\"", v = "2"),
            XlsxCell("A1", f = "B1+1", v = "3"),
        )
        assertUnverified(factsOf(inspect(bytes, "=B1+1", "A1")))
    }

    @Test
    fun rangeBeyondTheBoundedLengthStaysUnverified() {
        val cells = ArrayList<XlsxCell>(1_501)
        for (row in 1..1_500) cells.add(XlsxCell("A$row", v = "1"))
        cells.add(XlsxCell("B1", f = "SUM(A1:A1500)", v = "1499"))
        val bytes = single(*cells.toTypedArray())
        assertUnverified(factsOf(inspect(bytes, "=SUM(A1:A1500)", "B1")))
    }

    @Test
    fun textDependencyInArithmeticStaysUnverifiedInsteadOfGuessing() {
        val bytes = single(
            XlsxCell("A1", t = "s", v = "0"),
            XlsxCell("B1", f = "A1*2", v = "0"),
            strings = listOf("abc"),
        )
        assertUnverified(factsOf(inspect(bytes, "=A1*2", "B1")))
    }

    @Test
    fun formulaDependencyWithoutCacheIsRefused() {
        val bytes = single(
            XlsxCell("A1", v = "1"),
            XlsxCell("B1", f = "A1+1"),
            XlsxCell("C1", f = "B1+1", v = "3"),
        )
        assertEquals(
            VerificationCodes.FORMULA_DEPENDENCY_MISSING_CACHE,
            refusedCode(inspect(bytes, "=B1+1", "C1")),
        )
    }

    // -----------------------------------------------------------------
    // source proof remains separate
    // -----------------------------------------------------------------

    @Test
    fun sourceMismatchNeverClaimsAnyResultProof() {
        val bytes = single(
            XlsxCell("A1", v = "1"),
            XlsxCell("A2", v = "2"),
            XlsxCell("A3", v = "3"),
            XlsxCell("B1", f = "SUM(A2:A3)", v = "5"),
        )
        val facts = factsOf(inspect(bytes, "=SUM(A1:A3)", "B1"))
        assertFalse("the saved formula source is not the intent", facts.expectedContentMatches)
        assertNull("no result claim is made for a different formula", facts.cellFormulaResultVerified)
        assertNull(facts.cellFormulaResultOutcome)
    }

    @Test
    fun literalAndNumberIntentsCarryNoFormulaResultFact() {
        val literal = single(
            XlsxCell("A1", t = "inlineStr", inline = "hello"),
        )
        val literalFacts = factsOf(inspect(literal, "hello", "A1", kind = "literal"))
        assertTrue(literalFacts.expectedContentMatches)
        assertNull(literalFacts.cellFormulaResultVerified)
        assertNull(literalFacts.cellFormulaResultOutcome)

        val number = single(XlsxCell("A1", v = "42"))
        val numberFacts = factsOf(inspect(number, "42", "A1", kind = "number"))
        assertTrue(numberFacts.expectedContentMatches)
        assertNull(numberFacts.cellFormulaResultVerified)
    }
}
