// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officeai

import com.floe.android.host.officeai.verification.OoxmlTestFixtures
import com.floe.android.host.officeai.verification.OoxmlTestFixtures.PptSlide
import com.floe.android.host.officeai.verification.OoxmlTestFixtures.RawEntry
import com.floe.android.host.officeai.verification.OoxmlTestFixtures.XlsxCell
import com.floe.android.host.officeai.verification.OoxmlTestFixtures.XlsxSheet
import com.floe.android.host.officeai.verification.VerificationCodes
import com.floe.android.host.officeai.verification.VerificationNotes
import java.io.File
import java.io.FileOutputStream
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Focused regression source against the ACTUAL OfficeAiOoxmlVerifier object
 * over REAL OOXML ZIP fixtures (no mirrored parser in this file). The core
 * honesty under test everywhere: preexisting text, a changed package hash or
 * an ack NEVER proves a mutation; every proof fact must come from actual
 * bounded inspection of the saved bytes with ordered-relationship targeting.
 */
class OfficeAiOoxmlVerifierTest {

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
        val file = File.createTempFile("floe-ooxml21-", ".bin")
        tempFiles.add(file)
        FileOutputStream(file).use { it.write(bytes) }
        return file
    }

    private fun sha(bytes: ByteArray) = OoxmlTestFixtures.sha256(bytes)

    private fun input(
        bytes: ByteArray,
        format: String,
        command: String,
        expected: String,
        contentKind: String? = null,
        cellAddress: String? = null,
        partIndex: Int? = null,
        baseline: OfficeAiVerificationBaseline? = null,
        nativeTargetEffectVerified: Boolean = false,
        trustedCompletedJobProof: Boolean = false,
        fileOverride: File? = null,
        shaOverride: String? = null,
        sizeOverride: Long? = null,
    ): OfficeAiVerificationInput = OfficeAiVerificationInput(
        file = fileOverride ?: artifact(bytes),
        sha256 = shaOverride ?: sha(bytes),
        bytes = sizeOverride ?: bytes.size.toLong(),
        format = format,
        command = command,
        expectedText = expected,
        contentKind = contentKind,
        cellAddress = cellAddress,
        partIndex = partIndex,
        baseline = baseline,
        nativeTargetEffectVerified = nativeTargetEffectVerified,
        trustedCompletedJobProof = trustedCompletedJobProof,
    )

    private fun baselineOf(
        bytes: ByteArray,
        partIndex: Int? = null,
        prior: String? = null,
        shaOverride: String? = null,
    ): OfficeAiVerificationBaseline = OfficeAiVerificationBaseline(
        file = artifact(bytes),
        sha256 = shaOverride ?: sha(bytes),
        bytes = bytes.size.toLong(),
        partIndex = partIndex,
        priorSelectionText = prior,
    )

    private fun docx(paragraphs: List<String>): ByteArray =
        OoxmlTestFixtures.docxBytes(
            OoxmlTestFixtures.wordDocumentXml(
                paragraphs.joinToString("") { OoxmlTestFixtures.wordPara(it) },
            ),
        )

    private fun xlsx(
        sheets: List<XlsxSheet>,
        strings: List<String>? = null,
    ): ByteArray = OoxmlTestFixtures.xlsxBytes(sheets, strings)

    private fun verifiedOf(result: OfficeAiVerificationResult): OfficeAiVerificationFacts =
        when (result) {
            is OfficeAiVerificationResult.Verified -> result.facts
            is OfficeAiVerificationResult.Refused ->
                throw AssertionError("expected Verified, got Refused(${result.code})")
        }

    private fun refusedOf(result: OfficeAiVerificationResult): String =
        when (result) {
            is OfficeAiVerificationResult.Refused -> result.code
            is OfficeAiVerificationResult.Verified ->
                throw AssertionError("expected Refused, got Verified(${result.facts})")
        }

    private fun inspect(i: OfficeAiVerificationInput) = OfficeAiOoxmlVerifier.inspect(i)

    // -----------------------------------------------------------------
    // Word applyText honesty
    // -----------------------------------------------------------------

    @Test
    fun preexistingWantedElsewhereUnchangedBodyAndFalseFlagsProveNothing() {
        val bytes = docx(listOf("alpha bravo charlie"))
        val facts = verifiedOf(
            inspect(
                input(
                    bytes, "docx", "applyText", "charlie",
                    baseline = baselineOf(bytes, prior = "alpha"),
                ),
            ),
        )
        assertTrue(facts.expectedContentMatches)
        assertEquals(SemanticScope.TEXT_PRESENT_ONLY, facts.replacementScope)
        assertFalse("unchanged body must not prove a delta", facts.semanticDeltaVerified)
        assertFalse(facts.targetEffectVerified)
        assertFalse(facts.proofReused)
        assertFalse(facts.changedFromOriginal == true)
        assertEquals(false, facts.changedFromOriginal)
        assertTrue(facts.limitations.contains(VerificationNotes.DELTA_NOT_SINGLE_EDIT))
    }

    @Test
    fun nativeHostFactNeedsActualContentMatchAndNeverInventsDelta() {
        val saved = docx(listOf("fresh sentence here"))
        val matched = verifiedOf(
            inspect(input(saved, "docx", "applyText", "fresh sentence here", nativeTargetEffectVerified = true)),
        )
        assertTrue(matched.expectedContentMatches)
        assertTrue("private host fact + real postcondition proves target effect", matched.targetEffectVerified)
        assertFalse("no baseline => no invented semantic delta", matched.semanticDeltaVerified)
        assertNull(matched.changedFromOriginal)
        assertEquals("word/document.xml", matched.partName)
        val absent = verifiedOf(
            inspect(input(saved, "docx", "applyText", "other text", nativeTargetEffectVerified = true)),
        )
        assertFalse("native fact alone without content match is refused by facts", absent.targetEffectVerified)
    }

    @Test
    fun selectionReplacementFromTrustedBaseline() {
        val base = docx(listOf("Hello world foo"))
        val saved = docx(listOf("Hello there foo"))
        val facts = verifiedOf(
            inspect(
                input(
                    saved, "docx", "applyText", "there",
                    baseline = baselineOf(base, prior = "world"),
                    nativeTargetEffectVerified = false,
                ),
            ),
        )
        assertTrue(facts.expectedContentMatches)
        assertTrue(facts.semanticDeltaVerified)
        assertEquals(SemanticScope.SELECTION_REPLACED, facts.replacementScope)
        assertEquals(true, facts.changedFromOriginal)
    }

    @Test
    fun cursorInsertionFromTrustedBaseline() {
        val base = docx(listOf("Start End"))
        val saved = docx(listOf("Start NEW End"))
        val facts = verifiedOf(
            inspect(
                input(saved, "docx", "applyText", " NEW", baseline = baselineOf(base, prior = "")),
            ),
        )
        assertTrue(facts.semanticDeltaVerified)
        assertEquals(SemanticScope.INSERTED_AT_CURSOR, facts.replacementScope)
    }

    @Test
    fun wholeBodyReplacementFromTrustedBaseline() {
        val base = docx(listOf("Old full text"))
        val saved = docx(listOf("New full text"))
        val facts = verifiedOf(
            inspect(
                input(
                    saved, "docx", "applyText", "New full text",
                    baseline = baselineOf(base, prior = "Old full text"),
                ),
            ),
        )
        assertTrue(facts.semanticDeltaVerified)
        assertEquals(SemanticScope.WHOLE_BODY_REPLACED, facts.replacementScope)
    }

    @Test
    fun c12UnicodeRunsParagraphsAndDecimalListProveExactClipboardWholeBodyDelta() {
        val title = "手记 § Baseline 🧪"
        val second = "Floe G01 synthetic paragraph with bold and italic runs."
        val rtl = "مرحبا שלום mixed RTL"
        val split = "synthetic paragraph with bold and italic runs."
        val secondRuns = "<w:p><w:r><w:t xml:space=\"preserve\">Floe G01 </w:t></w:r>" +
            "<w:r><w:t xml:space=\"preserve\">" + OoxmlTestFixtures.esc(split) +
            "</w:t></w:r></w:p>"
        fun numbered(text: String) = "<w:p><w:pPr><w:numPr><w:ilvl w:val=\"0\"/>" +
            "<w:numId w:val=\"1\"/></w:numPr></w:pPr>" + OoxmlTestFixtures.wordPara(text).removePrefix("<w:p>")
        val body = OoxmlTestFixtures.wordPara(title) + secondRuns + OoxmlTestFixtures.wordPara(rtl) +
            numbered("alpha list one") + numbered("beta list two") + numbered("γ § 3 list three") +
            OoxmlTestFixtures.wordPara("")
        val numbering = "<w:numbering xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">" +
            "<w:abstractNum w:abstractNumId=\"0\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/>" +
            "<w:numFmt w:val=\"decimal\"/><w:lvlText w:val=\"%1.\"/></w:lvl></w:abstractNum>" +
            "<w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num></w:numbering>"
        val base = OoxmlTestFixtures.docxBytes(
            OoxmlTestFixtures.wordDocumentXml(body),
            extras = mapOf("word/numbering.xml" to numbering.toByteArray(StandardCharsets.UTF_8)),
        )
        val marker = "Floe LOCAL QA marker applied via scripted fixture (no cloud model)."
        val saved = docx(listOf(marker))
        val prior = listOf(
            title, second, rtl,
            "    1. alpha list one", "    2. beta list two", "    3. γ § 3 list three",
        ).joinToString("\n")
        assertEquals("the real C12 select-all readback shape is 178 UTF-8 bytes",
            178, prior.toByteArray(StandardCharsets.UTF_8).size)
        val proven = verifiedOf(
            inspect(input(saved, "docx", "applyText", marker, baseline = baselineOf(base, prior = prior))),
        )
        assertTrue(proven.expectedContentMatches)
        assertTrue("exact Writer clipboard text + saved OOXML proves the whole-body delta",
            proven.semanticDeltaVerified)
        assertEquals(SemanticScope.WHOLE_BODY_REPLACED, proven.replacementScope)
        assertFalse("NATIVE_COMPLETED alone is not target-effect proof", proven.targetEffectVerified)

        val wrongLabel = verifiedOf(
            inspect(
                input(
                    saved, "docx", "applyText", marker,
                    baseline = baselineOf(base, prior = prior.replace("    2. beta", "    9. beta")),
                ),
            ),
        )
        assertFalse("a wrong list label or stale selection never promotes", wrongLabel.semanticDeltaVerified)
        assertTrue(wrongLabel.limitations.contains(VerificationNotes.PRIOR_NOT_IN_BASELINE))
        val missing = verifiedOf(
            inspect(input(saved, "docx", "applyText", marker, baseline = baselineOf(base, prior = null))),
        )
        assertFalse(missing.semanticDeltaVerified)
        assertTrue(missing.limitations.contains(VerificationNotes.PRIOR_SELECTION_MISSING))
        val unsupportedNumbering = OoxmlTestFixtures.docxBytes(
            OoxmlTestFixtures.wordDocumentXml(body),
            extras = mapOf(
                "word/numbering.xml" to numbering.replace("decimal", "bullet")
                    .toByteArray(StandardCharsets.UTF_8),
            ),
        )
        val unsupported = verifiedOf(
            inspect(
                input(
                    saved, "docx", "applyText", marker,
                    baseline = baselineOf(unsupportedNumbering, prior = prior),
                ),
            ),
        )
        assertFalse("unknown native list rendering must not be guessed", unsupported.semanticDeltaVerified)
    }

    @Test
    fun wrongBaselineDigestStaysUnprovenWithHonestNote() {
        val base = docx(listOf("Hello world foo"))
        val saved = docx(listOf("Hello there foo"))
        val facts = verifiedOf(
            inspect(
                input(
                    saved, "docx", "applyText", "there",
                    baseline = baselineOf(base, prior = "world", shaOverride = sha(docx(listOf("other")))),
                ),
            ),
        )
        assertFalse(facts.semanticDeltaVerified)
        assertNull(facts.changedFromOriginal)
        assertTrue(
            facts.limitations.any { it.startsWith(VerificationNotes.BASELINE_UNVERIFIED) },
        )
        assertTrue(facts.expectedContentMatches)
    }

    @Test
    fun missingPriorSelectionCannotProveDelta() {
        val base = docx(listOf("Hello world foo"))
        val saved = docx(listOf("Hello there foo"))
        val facts = verifiedOf(
            inspect(
                input(saved, "docx", "applyText", "there", baseline = baselineOf(base, prior = null)),
            ),
        )
        assertFalse(facts.semanticDeltaVerified)
        assertTrue(facts.limitations.contains(VerificationNotes.PRIOR_SELECTION_MISSING))
    }

    @Test
    fun meaningfulWhitespaceIsPreservedNotTrimmed() {
        val bytes = OoxmlTestFixtures.docxBytes(
            OoxmlTestFixtures.wordDocumentXml(
                "<w:p><w:r><w:t xml:space=\"preserve\">keep  two   gaps </w:t></w:r></w:p>",
            ),
        )
        val facts = verifiedOf(inspect(input(bytes, "docx", "applyText", "keep  two   gaps")))
        assertTrue(facts.expectedContentMatches)
    }

    @Test
    fun tabAndBreakNormalizeToControlledText() {
        val bytes = OoxmlTestFixtures.docxBytes(
            OoxmlTestFixtures.wordDocumentXml(
                "<w:p><w:r><w:t>a</w:t><w:tab/><w:t>b</w:t><w:br/><w:t>c</w:t></w:r></w:p>",
            ),
        )
        val facts = verifiedOf(inspect(input(bytes, "docx", "applyText", "a\tb\nc")))
        assertTrue(facts.expectedContentMatches)
    }

    @Test
    fun headerOnlyScopeIsNotComparedAndNeverProves() {
        val bytes = OoxmlTestFixtures.docxBytesWithHeader("header secret", OoxmlTestFixtures.wordPara("body only"))
        val facts = verifiedOf(
            inspect(
                input(bytes, "docx", "applyText", "header secret", nativeTargetEffectVerified = true),
            ),
        )
        assertFalse(facts.expectedContentMatches)
        assertFalse(facts.targetEffectVerified)
        assertNull(facts.replacementScope)
        assertTrue(facts.limitations.contains(VerificationNotes.WORD_HEADERS_NOT_INSPECTED))
    }

    @Test
    fun occurrenceCountAndEmptyExpectedGuards() {
        val bytes = docx(listOf("xy xy xy"))
        val facts = verifiedOf(inspect(input(bytes, "docx", "applyText", "xy")))
        assertEquals(3, facts.occurrenceCount)
        assertEquals(
            VerificationCodes.EXPECTED_EMPTY,
            refusedOf(inspect(input(bytes, "docx", "applyText", ""))),
        )
        val big = "x".repeat(200 * 1024)
        assertEquals(
            VerificationCodes.EXPECTED_TOO_LARGE,
            refusedOf(inspect(input(bytes, "docx", "applyText", big))),
        )
    }

    // -----------------------------------------------------------------
    // PPTX ordered slide targeting
    // -----------------------------------------------------------------

    @Test
    fun reorderedSlidesResolveThroughPresentationAndRelsNotFileNames() {
        val bytes = OoxmlTestFixtures.pptxBytes(
            listOf(
                PptSlide("rId2", "slide2.xml", listOf("Second logical slide")),
                PptSlide("rId1", "slide1.xml", listOf("Naive file name trap")),
            ),
        )
        val facts = verifiedOf(
            inspect(input(bytes, "pptx", "applyText", "Second logical slide", partIndex = 0)),
        )
        assertTrue(facts.expectedContentMatches)
        assertEquals("ppt/slides/slide2.xml", facts.partName)
        val wrongIndex = verifiedOf(
            inspect(input(bytes, "pptx", "applyText", "Naive file name trap", partIndex = 1)),
        )
        assertTrue(wrongIndex.expectedContentMatches)
        assertEquals("ppt/slides/slide1.xml", wrongIndex.partName)
    }

    @Test
    fun pptxIndexWithoutDefaultRefusesHonestly() {
        val bytes = OoxmlTestFixtures.pptxBytes(listOf(PptSlide("rId1", "slide1.xml", listOf("only"))))
        assertEquals(
            VerificationCodes.MISSING_PART_INDEX,
            refusedOf(inspect(input(bytes, "pptx", "applyText", "only"))),
        )
        assertEquals(
            VerificationCodes.TARGET_INDEX_OUT_OF_RANGE,
            refusedOf(inspect(input(bytes, "pptx", "applyText", "only", partIndex = 5))),
        )
    }

    @Test
    fun pptxExternalSlideRelationshipRefused() {
        val bytes = OoxmlTestFixtures.pptxBytes(
            listOf(PptSlide("rId1", "slide1.xml", listOf("x"))),
            externalSlideRel = "rId1",
        )
        assertEquals(
            VerificationCodes.RELATION_UNRESOLVED,
            refusedOf(inspect(input(bytes, "pptx", "applyText", "x", partIndex = 0))),
        )
    }

    @Test
    fun pptxSelectionDeltaResolvesReorderedBaselinePart() {
        val base = OoxmlTestFixtures.pptxBytes(
            listOf(
                PptSlide("rId2", "slide2.xml", listOf("one two three")),
                PptSlide("rId1", "slide1.xml", listOf("other slide")),
            ),
        )
        val saved = OoxmlTestFixtures.pptxBytes(
            listOf(
                PptSlide("rId2", "slide2.xml", listOf("one TWO three")),
                PptSlide("rId1", "slide1.xml", listOf("other slide")),
            ),
        )
        val facts = verifiedOf(
            inspect(
                input(
                    saved, "pptx", "applyText", "TWO",
                    partIndex = 0,
                    baseline = baselineOf(base, partIndex = 0, prior = "two"),
                ),
            ),
        )
        assertTrue(facts.semanticDeltaVerified)
        assertEquals(SemanticScope.SELECTION_REPLACED, facts.replacementScope)
        assertEquals("ppt/slides/slide2.xml", facts.partName)
    }

    @Test
    fun pptxSelectedSlideRealEmptySelectionProvesInsertionAtCapturedPart() {
        val base = OoxmlTestFixtures.pptxBytes(
            listOf(
                PptSlide("rId2", "slide2.xml", listOf("other slide")),
                PptSlide("rId1", "slide1.xml", listOf("old title", "old body")),
            ),
        )
        // selectSlide + apply can start with NO selected shape: the native
        // prior is empty, so existing title/body remain and a new text shape
        // is inserted. Inventing "old title\nold body" as prior would instead
        // describe a different whole-slide replacement operation.
        val saved = OoxmlTestFixtures.pptxBytes(
            listOf(
                PptSlide("rId2", "slide2.xml", listOf("other slide")),
                PptSlide("rId1", "slide1.xml", listOf("old title", "old body", "selected-slide marker")),
            ),
        )
        val facts = verifiedOf(
            inspect(
                input(
                    saved, "pptx", "applyText", "selected-slide marker", partIndex = 1,
                    baseline = baselineOf(base, partIndex = 1, prior = ""),
                ),
            ),
        )
        assertTrue(facts.expectedContentMatches)
        assertTrue(facts.semanticDeltaVerified)
        assertEquals(SemanticScope.INSERTED_AT_CURSOR, facts.replacementScope)
        assertEquals("ppt/slides/slide1.xml", facts.partName)
        assertFalse("selected-slide completion alone is not target-effect proof", facts.targetEffectVerified)
    }

    // -----------------------------------------------------------------
    // XLSX exact cell intent
    // -----------------------------------------------------------------

    private fun cellCase(
        cell: XlsxCell,
        expected: String,
        kind: String,
        strings: List<String>? = null,
        address: String = "A1",
        partIndex: Int = 0,
    ): OfficeAiVerificationFacts = verifiedOf(
        inspect(
            input(
                xlsx(listOf(XlsxSheet("rId1", "sheet1.xml", listOf(cell))), strings),
                "xlsx", "setCellContent", expected,
                contentKind = kind,
                cellAddress = address,
                partIndex = partIndex,
            ),
        ),
    )

    @Test
    fun literal00123StoredAsStringMatchesExactly() {
        val facts = cellCase(XlsxCell("A1", t = "s", v = "0"), "00123", "literal", strings = listOf("00123"))
        assertTrue(facts.expectedContentMatches)
        assertTrue(facts.cellTypeMatchesIntent == true)
        assertEquals("s", facts.cellTypeAttribute)
        assertEquals("00123", facts.cellPersistedValue)
        assertEquals(false, facts.cellHasFormula)
        assertEquals(1, facts.occurrenceCount)
    }

    @Test
    fun literal00123StoredAsNumberIsNotStringIntent() {
        val facts = cellCase(XlsxCell("A1", v = "00123"), "00123", "literal")
        assertFalse(facts.expectedContentMatches)
        assertFalse(facts.cellTypeMatchesIntent == true)
        assertEquals("", facts.cellTypeAttribute)
        assertEquals("00123", facts.cellPersistedValue)
    }

    @Test
    fun literalWithLeadingEqualsStaysRawString() {
        val facts = cellCase(
            XlsxCell("A1", t = "s", v = "0"),
            "=SUM(A1:B2)",
            "literal",
            strings = listOf("=SUM(A1:B2)"),
        )
        assertTrue(facts.expectedContentMatches)
        assertEquals(false, facts.cellHasFormula)
    }

    @Test
    fun explicitNumberNeedsActualNumericTypeAndEquivalence() {
        assertTrue(cellCase(XlsxCell("A1", v = "42"), "42", "number").expectedContentMatches)
        val asString = cellCase(XlsxCell("A1", t = "s", v = "0"), "42", "number", strings = listOf("42"))
        assertFalse(asString.expectedContentMatches)
        assertFalse(asString.cellTypeMatchesIntent == true)
    }

    @Test
    fun numberPrecisionDriftIsHonestlyRefused() {
        val facts = cellCase(XlsxCell("A1", v = "0.10000000000000001"), "0.1", "number")
        assertFalse(facts.expectedContentMatches)
        assertTrue(facts.limitations.contains("precisionLossRefused"))
    }

    @Test
    fun oldWrongFormulaSourceCannotPass() {
        val facts = cellCase(XlsxCell("A1", f = "SUM(A1:A9)"), "=SUM(A1:A2)", "formula")
        assertFalse(facts.expectedContentMatches)
        assertTrue(facts.cellTypeMatchesIntent == true)
        assertEquals(true, facts.cellHasFormula)
    }

    @Test
    fun formulaMatchesActualSavedSourceWithBoundaryOnlyNormalization() {
        val facts = cellCase(XlsxCell("A1", f = "SUM(A1:A2)"), "= SUM(A1:A2)  ", "formula")
        assertTrue(facts.expectedContentMatches)
    }

    @Test
    fun quotedSheetNameAndIntersectionSpacesStaySignificant() {
        val quoted = cellCase(XlsxCell("A1", f = "SUM('Sales Q1'!A1)"), "=SUM('SalesQ1'!A1)", "formula")
        assertFalse("quoted sheet identifier spaces are meaningful", quoted.expectedContentMatches)
        assertFalse(quoted.limitations.contains("formulaDiffersOnlyByWhitespace"))
        val intersection = cellCase(XlsxCell("A1", f = "A1 B1"), "=A1B1", "formula")
        assertFalse("reference intersection space is meaningful", intersection.expectedContentMatches)
    }

    @Test
    fun whitespaceOnlyFormulaDiffRefusesWithDiagnosticNote() {
        val facts = cellCase(XlsxCell("A1", f = "SUM( A1 , B1 )"), "=SUM(A1,B1)", "formula")
        assertFalse(facts.expectedContentMatches)
        assertTrue(facts.limitations.contains("formulaDiffersOnlyByWhitespace"))
    }

    @Test
    fun validFormulaCachedTypesAreAllAllowed() {
        for (t in listOf(null, "n", "str", "b", "e")) {
            val facts = cellCase(XlsxCell("A1", t = t, f = "SUM(A1:A2)", v = "7"), "=SUM(A1:A2)", "formula")
            assertTrue("cached t=$t must not break formula proof", facts.expectedContentMatches)
            assertTrue(facts.cellTypeMatchesIntent == true)
        }
    }

    @Test
    fun formulaIntentWithoutLeadingEqualsRefuses() {
        val bytes = xlsx(listOf(XlsxSheet("rId1", "sheet1.xml", listOf(XlsxCell("A1", f = "SUM(A1:A2)")))))
        assertEquals(
            VerificationCodes.FORMULA_INTENT_MISSING_EQUALS,
            refusedOf(inspect(input(bytes, "xlsx", "setCellContent", "SUM(A1:A2)", "formula", "A1", 0))),
        )
    }

    @Test
    fun sharedFormulaWithoutOwnSourceIsUnsupportedNotAnyFPass() {
        val bytes = xlsx(
            listOf(
                XlsxSheet(
                    "rId1", "sheet1.xml",
                    listOf(
                        XlsxCell("B1", f = "SUM(A1:A2)", fAttrs = " t=\"shared\" si=\"0\""),
                        XlsxCell("B2", f = "", fAttrs = " t=\"shared\" si=\"0\"", v = "3"),
                    ),
                ),
            ),
        )
        assertEquals(
            VerificationCodes.UNSUPPORTED_FORMULA,
            refusedOf(inspect(input(bytes, "xlsx", "setCellContent", "=SUM(A1:A2)", "formula", "B2", 0))),
        )
    }

    @Test
    fun sharedFormulaOwnTextAndArrayWithTextResolveToActualSource() {
        val shared = cellCase(
            XlsxCell("A1", f = "SUM(A1:A2)", fAttrs = " t=\"shared\" si=\"1\""),
            "=SUM(A1:A2)", "formula",
        )
        assertTrue(shared.expectedContentMatches)
        val array = cellCase(
            XlsxCell("A1", f = "SUM(A1:A2)", fAttrs = " t=\"array\" ref=\"A1\""),
            "=SUM(A1:A2)", "formula",
        )
        assertTrue(array.expectedContentMatches)
        assertTrue(array.limitations.contains("arrayFormulaSourceMatched"))
    }

    @Test
    fun inlineStringLiteralAndSharedStringDecodeBothMatch() {
        assertTrue(cellCase(XlsxCell("A1", t = "inlineStr", inline = "abc"), "abc", "literal").expectedContentMatches)
        assertTrue(cellCase(XlsxCell("A1", t = "s", v = "0"), "abc", "literal", strings = listOf("abc")).expectedContentMatches)
    }

    @Test
    fun invalidSharedStringIndexRefuses() {
        val bytes = xlsx(
            listOf(XlsxSheet("rId1", "sheet1.xml", listOf(XlsxCell("A1", t = "s", v = "9")))),
            listOf("only"),
        )
        assertEquals(
            VerificationCodes.SHARED_STRING_INVALID,
            refusedOf(inspect(input(bytes, "xlsx", "setCellContent", "x", "literal", "A1", 0))),
        )
    }

    @Test
    fun missingCellAndIndexDefaultsRefuse() {
        val bytes = xlsx(listOf(XlsxSheet("rId1", "sheet1.xml", listOf(XlsxCell("A1", v = "1")))))
        assertEquals(
            VerificationCodes.TARGET_CELL_MISSING,
            refusedOf(inspect(input(bytes, "xlsx", "setCellContent", "1", "number", "Z26", 0))),
        )
        assertEquals(
            VerificationCodes.MISSING_PART_INDEX,
            refusedOf(inspect(input(bytes, "xlsx", "setCellContent", "1", "number", "A1", null))),
        )
        assertEquals(
            VerificationCodes.MISSING_CELL_ADDRESS,
            refusedOf(inspect(input(bytes, "xlsx", "setCellContent", "1", "number", null, 0))),
        )
        assertEquals(
            VerificationCodes.CELL_ADDRESS_INVALID,
            refusedOf(inspect(input(bytes, "xlsx", "setCellContent", "1", "number", "Sheet1!A1", 0))),
        )
    }

    @Test
    fun worksheetsResolveThroughOrderedWorkbookRelsNotFileOrdinals() {
        val bytes = xlsx(
            listOf(
                XlsxSheet("rId2", "sheet2.xml", listOf(XlsxCell("A1", t = "s", v = "0"))),
                XlsxSheet("rId1", "sheet1.xml", emptyList()),
            ),
            listOf("wanted"),
        )
        val facts = verifiedOf(
            inspect(input(bytes, "xlsx", "setCellContent", "wanted", "literal", "A1", 0)),
        )
        assertTrue(facts.expectedContentMatches)
        assertEquals("xl/worksheets/sheet2.xml", facts.partName)
        assertEquals(
            VerificationCodes.TARGET_INDEX_OUT_OF_RANGE,
            refusedOf(inspect(input(bytes, "xlsx", "setCellContent", "wanted", "literal", "A1", 5))),
        )
    }

    @Test
    fun cellDeltaFromTrustedBaselineProvesReplacement() {
        val base = xlsx(
            listOf(XlsxSheet("rId1", "sheet1.xml", listOf(XlsxCell("A1", t = "s", v = "0")))),
            listOf("old"),
        )
        val saved = xlsx(
            listOf(XlsxSheet("rId1", "sheet1.xml", listOf(XlsxCell("A1", t = "s", v = "0")))),
            listOf("new"),
        )
        val facts = verifiedOf(
            inspect(
                input(
                    saved, "xlsx", "setCellContent", "new", "literal", "A1", 0,
                    baseline = baselineOf(base, partIndex = 0, prior = "old"),
                ),
            ),
        )
        assertTrue(facts.semanticDeltaVerified)
        assertEquals(SemanticScope.CELL_REPLACED, facts.replacementScope)
        assertEquals(true, facts.changedFromOriginal)
    }

    @Test
    fun formulaDeltaUsesObservedPriorDisplayAndActualSavedFormulaSource() {
        val base = xlsx(
            listOf(XlsxSheet("rId1", "sheet1.xml", listOf(XlsxCell("A1", v = "7")))),
        )
        val saved = xlsx(
            listOf(
                XlsxSheet(
                    "rId1", "sheet1.xml",
                    listOf(XlsxCell("A1", f = "SUM(B1:B2)", v = "14")),
                ),
            ),
        )
        val facts = verifiedOf(
            inspect(
                input(
                    saved, "xlsx", "setCellContent", "=SUM(B1:B2)", "formula", "A1", 0,
                    baseline = baselineOf(base, partIndex = 0, prior = "7"),
                ),
            ),
        )
        assertTrue(facts.expectedContentMatches)
        assertTrue(facts.cellTypeMatchesIntent == true)
        assertTrue("the prior display value plus saved formula source proves this cell delta",
            facts.semanticDeltaVerified)
        assertEquals(SemanticScope.CELL_REPLACED, facts.replacementScope)
        assertFalse("FORMULA_NOT_COMPARABLE must rely on saved proof, not native effect promotion",
            facts.targetEffectVerified)
    }

    @Test
    fun cellInsertionIntoAbsentBaselineCellProves() {
        val base = xlsx(listOf(XlsxSheet("rId1", "sheet1.xml", emptyList())))
        val saved = xlsx(listOf(XlsxSheet("rId1", "sheet1.xml", listOf(XlsxCell("B2", t = "inlineStr", inline = "x")))))
        val facts = verifiedOf(
            inspect(
                input(
                    saved, "xlsx", "setCellContent", "x", "literal", "B2", 0,
                    baseline = baselineOf(base, partIndex = 0, prior = ""),
                ),
            ),
        )
        assertTrue(facts.semanticDeltaVerified)
        assertEquals(SemanticScope.CELL_INSERTED, facts.replacementScope)
    }

    @Test
    fun cellDeltaRejectsWrongPriorAndUnknownBaselineTarget() {
        val base = xlsx(
            listOf(XlsxSheet("rId1", "sheet1.xml", listOf(XlsxCell("A1", t = "s", v = "0")))),
            listOf("old"),
        )
        val saved = xlsx(
            listOf(XlsxSheet("rId1", "sheet1.xml", listOf(XlsxCell("A1", t = "s", v = "0")))),
            listOf("new"),
        )
        val wrongPrior = verifiedOf(
            inspect(
                input(
                    saved, "xlsx", "setCellContent", "new", "literal", "A1", 0,
                    baseline = baselineOf(base, partIndex = 0, prior = "wrong"),
                ),
            ),
        )
        assertFalse(wrongPrior.semanticDeltaVerified)
        assertTrue(wrongPrior.limitations.contains(VerificationNotes.PRIOR_NOT_IN_BASELINE))
        val unknownTarget = verifiedOf(
            inspect(
                input(
                    saved, "xlsx", "setCellContent", "new", "literal", "A1", 0,
                    baseline = baselineOf(base, partIndex = null, prior = "old"),
                ),
            ),
        )
        assertFalse(unknownTarget.semanticDeltaVerified)
        assertTrue(unknownTarget.limitations.contains(VerificationNotes.BASELINE_TARGET_UNKNOWN))
    }

    @Test
    fun proofFlagsOnlyHelpWhenContentActuallyMatches() {
        val with = xlsx(
            listOf(XlsxSheet("rId1", "sheet1.xml", listOf(XlsxCell("A1", t = "s", v = "0")))),
            listOf("wanted"),
        )
        val reused = verifiedOf(
            inspect(
                input(
                    with, "xlsx", "setCellContent", "wanted", "literal", "A1", 0,
                    trustedCompletedJobProof = true, nativeTargetEffectVerified = true,
                ),
            ),
        )
        assertTrue(reused.proofReused)
        assertTrue(reused.targetEffectVerified)
        val absent = verifiedOf(
            inspect(
                input(
                    with, "xlsx", "setCellContent", "absent value", "literal", "A1", 0,
                    trustedCompletedJobProof = true, nativeTargetEffectVerified = true,
                ),
            ),
        )
        assertFalse("flags without content match never pass", absent.proofReused)
        assertFalse(absent.targetEffectVerified)
    }

    // -----------------------------------------------------------------
    // Artifact / package security bounds
    // -----------------------------------------------------------------

    @Test
    fun digestSizeAndFormatPairingsFailClosed() {
        val bytes = docx(listOf("body"))
        assertEquals(VerificationCodes.ARTIFACT_DIGEST_INVALID, refusedOf(inspect(input(bytes, "docx", "applyText", "body", shaOverride = "zz"))))
        assertEquals(VerificationCodes.ARTIFACT_DIGEST_MISMATCH, refusedOf(inspect(input(bytes, "docx", "applyText", "body", shaOverride = sha(docx(listOf("other")))))))
        assertEquals(VerificationCodes.ARTIFACT_SIZE_MISMATCH, refusedOf(inspect(input(bytes, "docx", "applyText", "body", sizeOverride = bytes.size.toLong() + 1))))
        assertEquals(VerificationCodes.ARTIFACT_SIZE_INVALID, refusedOf(inspect(input(bytes, "docx", "applyText", "body", sizeOverride = 0))))
        assertEquals(VerificationCodes.ARTIFACT_TOO_LARGE, refusedOf(inspect(input(bytes, "docx", "applyText", "body", sizeOverride = 300L * 1024L * 1024L))))
        assertEquals(VerificationCodes.UNKNOWN_FORMAT, refusedOf(inspect(input(bytes, "pdf", "applyText", "body"))))
        assertEquals(VerificationCodes.UNKNOWN_COMMAND, refusedOf(inspect(input(bytes, "docx", "recalc", "body"))))
        assertEquals(VerificationCodes.COMMAND_FORMAT_MISMATCH, refusedOf(inspect(input(bytes, "xlsx", "applyText", "body", null, "A1", 0))))
        assertEquals(
            VerificationCodes.UNKNOWN_CONTENT_KIND,
            refusedOf(
                inspect(
                    input(
                        xlsx(listOf(XlsxSheet("rId1", "sheet1.xml", listOf(XlsxCell("A1", v = "1"))))),
                        "xlsx", "setCellContent", "1", null, "A1", 0,
                    ),
                ),
            ),
        )
    }

    @Test
    fun symlinkedArtifactIsRefused() {
        val bytes = docx(listOf("body"))
        val real = artifact(bytes)
        val link = File(real.parentFile, real.name + "-link")
        val created = try {
            Files.createSymbolicLink(link.toPath(), real.toPath())
            true
        } catch (error: Exception) {
            false // platform without symlink support: nothing to prove here
        }
        if (!created) return
        tempFiles.add(link)
        assertEquals(
            VerificationCodes.ARTIFACT_MISSING,
            refusedOf(inspect(input(bytes, "docx", "applyText", "body", fileOverride = link))),
        )
    }

    @Test
    fun nonZipAndRawZipAbuseAreBoundedTypedRefusals() {
        val garbage = "not a zip archive at all".toByteArray(StandardCharsets.UTF_8)
        assertEquals(VerificationCodes.ZIP_MALFORMED, refusedOf(inspect(input(garbage, "docx", "applyText", "x"))))
        val wordBytes = OoxmlTestFixtures.wordDocumentXml(OoxmlTestFixtures.wordPara("hello"))
            .toByteArray(StandardCharsets.UTF_8)
        val encrypted = OoxmlTestFixtures.rawZip(
            listOf(RawEntry("word/document.xml", wordBytes, method = 0, flags = 0x1)),
        )
        assertEquals(VerificationCodes.ZIP_ENCRYPTED, refusedOf(inspect(input(encrypted, "docx", "applyText", "hello"))))
        val bomb = OoxmlTestFixtures.rawZip(
            listOf(
                RawEntry(
                    "word/document.xml",
                    wordBytes,
                    method = 0,
                    declaredUsize = 600L * 1024L * 1024L,
                    declaredCsize = wordBytes.size.toLong(),
                ),
            ),
        )
        assertEquals(VerificationCodes.ZIP_UNBOUNDED, refusedOf(inspect(input(bomb, "docx", "applyText", "hello"))))
        val escape = OoxmlTestFixtures.rawZip(listOf(RawEntry("../evil.xml", wordBytes)))
        assertEquals(VerificationCodes.ZIP_UNSAFE_ENTRY, refusedOf(inspect(input(escape, "docx", "applyText", "hello"))))
        val brokenLocal = OoxmlTestFixtures.rawZip(
            listOf(
                RawEntry(
                    "word/document.xml",
                    wordBytes,
                    localSignatureOverride = byteArrayOf('X'.code.toByte(), 'X'.code.toByte(), 3, 4),
                ),
            ),
        )
        assertEquals(VerificationCodes.ZIP_MALFORMED, refusedOf(inspect(input(brokenLocal, "docx", "applyText", "hello"))))
    }

    @Test
    fun xxeAndUtf16PackagesRefuseEndToEndThroughActualVerifier() {
        val xxe = OoxmlTestFixtures.docxBytes(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" +
                "<!DOCTYPE w:document [<!ENTITY x SYSTEM \"file:///etc/passwd\">]>" +
                "<w:document xmlns:w=\"" + OoxmlTestFixtures.W_NS + "\"><w:body><w:p/></w:body></w:document>" +
                "&x;",
        )
        assertEquals(VerificationCodes.XML_UNTRUSTED, refusedOf(inspect(input(xxe, "docx", "applyText", "x"))))
        val utf16 = OoxmlTestFixtures.docxBytesRaw(
            wordDoctypeUtf16Le(),
        )
        assertEquals(
            VerificationCodes.XML_ENCODING_UNSUPPORTED,
            refusedOf(inspect(input(utf16, "docx", "applyText", "x"))),
        )
    }

    private fun wordDoctypeUtf16Le(): ByteArray {
        val xml = "<?xml version=\"1.0\" encoding=\"UTF-16\"?>" +
            "<!DOCTYPE w:document [<!ENTITY x SYSTEM \"file:///etc/passwd\">]>" +
            "<w:document xmlns:w=\"" + OoxmlTestFixtures.W_NS + "\"><w:body>" +
            "<w:p><w:r><w:t>&x;</w:t></w:r></w:p></w:body></w:document>"
        return byteArrayOf(0xFF.toByte(), 0xFE.toByte()) + xml.toByteArray(StandardCharsets.UTF_16LE)
    }

    private object SemanticScope {
        const val TEXT_PRESENT_ONLY = "textPresentOnly"
        const val SELECTION_REPLACED = "selectionReplaced"
        const val INSERTED_AT_CURSOR = "insertedAtCursor"
        const val WHOLE_BODY_REPLACED = "wholeBodyReplaced"
        const val CELL_REPLACED = "cellReplaced"
        const val CELL_INSERTED = "cellInserted"
    }
}
