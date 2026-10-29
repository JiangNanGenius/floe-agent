// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.precision

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure JVM regression for the pinned-producer wire translation
 * (OfficePrecisionProtocol). Every expected wire string here is the exact
 * shape the pinned producer parses (revision 2333344185931274f9c49d6c12a4
 * 08cefcef6844: kit/ChildSession.cpp handlers and the pinned mobile
 * frontend's own senders — citations live in OfficePrecisionProtocol's
 * KDoc). These tests pin the translation layer against silent drift.
 */
class OfficePrecisionProtocolTest {

    // ------------------------------------------------------------------
    // Wire builders (byte-exact pinned shapes)
    // ------------------------------------------------------------------

    @Test
    fun queryCommandsMatchPinnedSpellings() {
        assertEquals("status", OfficePrecisionProtocol.CMD_STATUS)
        assertEquals(
            "gettextselection mimetype=text/plain;charset=utf-8",
            OfficePrecisionProtocol.CMD_GET_TEXT_SELECTION,
        )
        assertEquals(
            "commandvalues command=.uno:CellCursor",
            OfficePrecisionProtocol.CMD_CELL_CURSOR_VALUES,
        )
        assertEquals(
            "commandvalues command=.uno:ReadOnly",
            OfficePrecisionProtocol.CMD_BARRIER,
        )
        assertEquals("getpresentationinfo", OfficePrecisionProtocol.CMD_PRESENTATION_INFO)
        assertEquals("uno .uno:SelectAll", OfficePrecisionProtocol.CMD_SELECT_ALL)
    }

    @Test
    fun setClientPartBuildsExactFrameAndRefusesMalformedIds() {
        assertEquals("setclientpart part=0", OfficePrecisionProtocol.setClientPart("0"))
        assertEquals("setclientpart part=12", OfficePrecisionProtocol.setClientPart("12"))
        // The pinned protocol's page-GUID identifier grammar
        // (common/Protocol.hpp isValidPartId @2333344…): a braced page GUID
        // is exactly what the pinned presentation frontend sends back
        // through setclientpart (ImpressTileLayer getPartFromIndex), so the
        // builder must carry it byte-exact.
        assertEquals(
            "setclientpart part={1BE1A269-4A03-4202-ACFE-0204C5E9BE1F}",
            OfficePrecisionProtocol.setClientPart("{1BE1A269-4A03-4202-ACFE-0204C5E9BE1F}"),
        )
        // Lowercase hex is the same pinned grammar (isxdigit both cases).
        assertEquals(
            "setclientpart part={1be1a269-4a03-4202-acfe-0204c5e9be1f}",
            OfficePrecisionProtocol.setClientPart("{1be1a269-4a03-4202-acfe-0204c5e9be1f}"),
        )
        // Fail-closed refusals (never a partial/guessed command).
        assertNull(OfficePrecisionProtocol.setClientPart("a"))
        assertNull(OfficePrecisionProtocol.setClientPart("-1"))
        assertNull(OfficePrecisionProtocol.setClientPart("1 x"))
        assertNull(OfficePrecisionProtocol.setClientPart("1\n"))
        assertNull(OfficePrecisionProtocol.setClientPart(""))
        assertNull(OfficePrecisionProtocol.setClientPart("1234567890")) // > 9 digits
        // Malformed GUID shapes are refused exactly like the pinned grammar:
        // no braces, wrong length, misplaced dash, non-hex digit, trailing
        // whitespace or an embedded newline can never reach the kit.
        assertNull(OfficePrecisionProtocol.setClientPart("1BE1A269-4A03-4202-ACFE-0204C5E9BE1F"))
        assertNull(OfficePrecisionProtocol.setClientPart("{1BE1A269-4A03-4202-ACFE-0204C5E9BE1}"))
        assertNull(OfficePrecisionProtocol.setClientPart("{1BE1A269_4A03-4202-ACFE-0204C5E9BE1F}"))
        assertNull(OfficePrecisionProtocol.setClientPart("{1BE1A269-4A0Z-4202-ACFE-0204C5E9BE1F}"))
        assertNull(OfficePrecisionProtocol.setClientPart("{1BE1A269-4A03-4202-ACFE-0204C5E9BE1F} "))
        assertNull(OfficePrecisionProtocol.setClientPart("{1BE1A269-4A03-4202-ACFE-0204C5E9BE1F}\n"))
    }

    @Test
    fun isValidGuidPartIdMirrorsThePinnedBracedGuidGrammar() {
        assertTrue(OfficePrecisionProtocol.isValidGuidPartId("{1BE1A269-4A03-4202-ACFE-0204C5E9BE1F}"))
        assertTrue(OfficePrecisionProtocol.isValidGuidPartId("{00000000-0000-0000-0000-000000000000}"))
        // The decimal part index is a DIFFERENT identifier form (spreadsheet/
        // text family) and never satisfies the GUID grammar.
        assertFalse(OfficePrecisionProtocol.isValidGuidPartId("1"))
        assertFalse(OfficePrecisionProtocol.isValidGuidPartId(""))
        assertFalse(OfficePrecisionProtocol.isValidGuidPartId(null))
        assertFalse(OfficePrecisionProtocol.isValidGuidPartId("{}"))
        // A witnessed entry that is NOT a braced GUID (empty, decimal, or
        // arbitrary text) is never treated as a page identifier.
        assertFalse(OfficePrecisionProtocol.isValidGuidPartId(""))
        assertFalse(OfficePrecisionProtocol.isValidGuidPartId("1BE1A269-4A03-4202-ACFE-0204C5E9BE1F"))
        assertFalse(OfficePrecisionProtocol.isValidGuidPartId("{1BE1A269-4A03-4202-ACFE-0204C5E9BE1G}"))
    }

    // ------------------------------------------------------------------
    // status: parts-array witness scan (pinned revision 2333344… shape:
    // kit/KitHelper.hpp fetchPartsData concatenates one core getPartInfo
    // object per page; the pinned Impress frontend reads exactly
    // `parts[i].part` — the page GUID — for every real setclientpart).
    // ------------------------------------------------------------------

    @Test
    fun parseStatusPartIdentifiersWitnessesOrderedTopLevelPageGuids() {
        // Pinned presentation status shape (unordered_map JSON; the parts
        // array keeps core getPartInfo's index order 0..partscount-1).
        val payload = "status: {\"type\": \"presentation\", \"partscount\": 3, " +
            "\"selectedpart\": \"{1BE1A269-4A03-4202-ACFE-0204C5E9BAAA}\", " +
            "\"width\": 25400, \"height\": 14288, \"viewid\": 7, " +
            "\"parts\": [{\"part\": \"{1BE1A269-4A03-4202-ACFE-0204C5E9BAAA}\", \"width\": 25400, \"height\": 14288, \"mode\": 0}, " +
            "{\"part\": \"{2BE1A269-4A03-4202-ACFE-0204C5E9ABBB}\", \"name\": \"Slide, Second\", \"mode\": 0}, " +
            "{\"part\": \"{3BE1A269-4A03-4202-ACFE-0204C5E9ACCC}\", \"hidden\": false}]" +
            "}"
        val ids = OfficePrecisionProtocol.parseStatusPartIdentifiers(payload)
        assertEquals(3, ids.size)
        assertEquals("{1BE1A269-4A03-4202-ACFE-0204C5E9BAAA}", ids[0])
        assertEquals("{2BE1A269-4A03-4202-ACFE-0204C5E9ABBB}", ids[1])
        assertEquals("{3BE1A269-4A03-4202-ACFE-0204C5E9ACCC}", ids[2])
        // selectedpart is read separately; the scan never shifts on a comma
        // inside a string value ("Slide, Second" above kept position 1).
    }

    @Test
    fun parseStatusPartIdentifiersIsFailClosedAndNeverShiftsOrGuesses() {
        // Entry with no top-level `part` witness -> null PLACEHOLDER at its
        // own position: a later page's identifier can never slide into the
        // requested index.
        val missing = "{\"parts\": [{\"part\": \"{AAAAAAAA-0000-0000-0000-000000000001}\"}, " +
            "{\"width\": 1}, {\"part\": \"{AAAAAAAA-0000-0000-0000-000000000003}\"}]}"
        val ids = OfficePrecisionProtocol.parseStatusPartIdentifiers(missing)
        assertEquals(3, ids.size)
        assertEquals("{AAAAAAAA-0000-0000-0000-000000000001}", ids[0])
        assertNull(ids[1])
        assertEquals("{AAAAAAAA-0000-0000-0000-000000000003}", ids[2])
        // A nested "part" inside an entry sub-object is NOT the entry's own
        // identifier (top-level witness only).
        val nested = "{\"parts\": [{\"meta\": {\"part\": \"{NESTED-0000-0000-0000-000000000000}\"}}, " +
            "{\"part\": \"{TOP-0000-0000-0000-000000000001}\"}]}"
        val nestedIds = OfficePrecisionProtocol.parseStatusPartIdentifiers(nested)
        assertEquals(2, nestedIds.size)
        assertNull(nestedIds[0])
        assertEquals("{TOP-0000-0000-0000-000000000001}", nestedIds[1])
        // Sibling keys that merely CONTAIN "part" never match as an entry
        // witness, and their arrays are not the parts array.
        val decoys = "{\"selectedpart\": \"{SELECTED-0000-0000-0000-000000000001}\", " +
            "\"partscount\": 2, \"partdimensions\": [1, 2], \"partHasComments\": \"false\", " +
            "\"parts\": [{\"part\": \"{PAGE-0000-0000-0000-00000000000A}\"}," +
            "{\"part\": \"{PAGE-0000-0000-0000-00000000000B}\"}]}"
        val decoyIds = OfficePrecisionProtocol.parseStatusPartIdentifiers(decoys)
        assertEquals(2, decoyIds.size)
        assertEquals("{PAGE-0000-0000-0000-00000000000A}", decoyIds[0])
        assertEquals("{PAGE-0000-0000-0000-00000000000B}", decoyIds[1])
        // No parts array at all (e.g. a spreadsheet/text status) -> empty,
        // so the resolve step refuses instead of inventing identifiers.
        assertEquals(
            emptyList<String?>(),
            OfficePrecisionProtocol.parseStatusPartIdentifiers(
                "{\"type\": \"spreadsheet\", \"partscount\": 2, \"selectedpart\": \"1\"}",
            ),
        )
        // An empty witnessed value is absence, never a guess.
        val empty = "{\"parts\": [{\"part\": \"\"}]}"
        assertNull(OfficePrecisionProtocol.parseStatusPartIdentifiers(empty)[0])
        // A malformed/escaped payload that never closes the array returns
        // only proven entries (fail-closed).
        val cut = "{\"parts\": [{\"part\": \"{A-00000000-0000-0000-0000-000000000000}\"}"
        assertEquals(1, OfficePrecisionProtocol.parseStatusPartIdentifiers(cut).size)
    }

    /** A CLOSED (complete, proven-end) ordered witness — the ordinal proof
     * accepts nothing else for presentation/drawing mapping. */
    private fun witness(vararg ids: String?) =
        OfficePrecisionProtocol.StatusPartWitness(ids.toList(), arrayClosed = true)

    @Test
    fun statusPartOrdinalMapsThePinnedGuidToItsWitnessedOrderedIndex() {
        // The concrete C15 two-slide chain: the producer's own status names
        // each page by its braced GUID and selectedpart = the SECOND page;
        // the SAME answer's complete ordered parts witness proves logical
        // ordinal 1 (never null from a host decimal re-parse, never a
        // filename order).
        val pageA = "{A1A2A3A4-B1B2-C1C2-D1D2-E1E2E3E4E5A0}"
        val pageB = "{A1A2A3A4-B1B2-C1C2-D1D2-E1E2E3E4E5B1}"
        val twoPages = witness(pageA, pageB)
        assertEquals(1, OfficePrecisionProtocol.statusPartOrdinal("presentation", pageB, twoPages, 2))
        assertEquals(0, OfficePrecisionProtocol.statusPartOrdinal("presentation", pageA, twoPages, 2))
        // A hole NEVER shifts a later page: in a COMPLETE array the null
        // placeholder keeps its own position, page C keeps ordinal 2.
        val pageC = "{A1A2A3A4-B1B2-C1C2-D1D2-E1E2E3E4E5C2}"
        assertEquals(2, OfficePrecisionProtocol.statusPartOrdinal("presentation", pageC, witness(pageA, null, pageC), 3))
        // Drawing shares the presentation identifier rule.
        assertEquals(1, OfficePrecisionProtocol.statusPartOrdinal("drawing", pageB, twoPages, 2))
        // Documented decimal families keep their legitimate ordinal behavior,
        // byte-identical to the proven pre-repair host parse — their
        // identifiers need NO parts witness or count at all.
        assertEquals(1, OfficePrecisionProtocol.statusPartOrdinal("spreadsheet", "1", null, null))
        assertEquals(0, OfficePrecisionProtocol.statusPartOrdinal("text", "0", null, null))
    }

    @Test
    fun statusPartOrdinalIsFailClosedAndNeverShiftsGuessesOrExceedsTheAnswerCount() {
        val pageA = "{A1A2A3A4-B1B2-C1C2-D1D2-E1E2E3E4E5A0}"
        val pageB = "{A1A2A3A4-B1B2-C1C2-D1D2-E1E2E3E4E5B1}"
        val pageC = "{A1A2A3A4-B1B2-C1C2-D1D2-E1E2E3E4E5C2}"
        // Absent from the witness: never a slide1/filename guess.
        assertNull(OfficePrecisionProtocol.statusPartOrdinal("presentation", pageB, witness(pageA), 1))
        // Duplicate ambiguity in the complete same-answer witness: refuse
        // instead of taking either position.
        assertNull(OfficePrecisionProtocol.statusPartOrdinal("presentation", pageB, witness(pageB, pageB), 2))
        // SHORT witness: the answer claims partscount 3 but only 2 entries
        // were witnessed — the unseen third entry COULD repeat the selected
        // GUID, so uniqueness is NOT proven merely because that GUID was
        // already seen at a plausible position. The complete ordered list
        // must agree with the native count.
        assertNull(OfficePrecisionProtocol.statusPartOrdinal("presentation", pageB, witness(pageA, pageB), 3))
        // OVER-long witness / out-of-range index contradict the same answer's
        // own count (the original out-of-range requirement preserved).
        assertNull(OfficePrecisionProtocol.statusPartOrdinal("presentation", pageB, witness(pageA, pageB), 1))
        assertNull(OfficePrecisionProtocol.statusPartOrdinal("presentation", pageB, witness(pageA, pageB, pageC), 2))
        // A witness with no count can never prove the mapping.
        assertNull(OfficePrecisionProtocol.statusPartOrdinal("presentation", pageB, witness(pageA, pageB), null))
        // Missing witness (answer carried no parts array): refuse.
        assertNull(OfficePrecisionProtocol.statusPartOrdinal("presentation", pageB, null, 2))
        // Malformed identifiers: a decimal never indexes a presentation page
        // (that was the C15 defect), an unbraced/unpinned GUID string is not
        // the producer grammar, and nothing is hashed into an index.
        assertNull(OfficePrecisionProtocol.statusPartOrdinal("presentation", "1", witness("1", pageB), 2))
        assertNull(
            OfficePrecisionProtocol.statusPartOrdinal(
                "presentation", "A1A2A3A4-B1B2-C1C2-D1D2-E1E2E3E4E5B1",
                witness("A1A2A3A4-B1B2-C1C2-D1D2-E1E2E3E4E5B1"), 1,
            ),
        )
        assertNull(OfficePrecisionProtocol.statusPartOrdinal("presentation", null, witness(pageA), 1))
        // Unknown family: no grammar guess at all.
        assertNull(OfficePrecisionProtocol.statusPartOrdinal("other-42", "0", witness(pageA), 1))
        assertNull(OfficePrecisionProtocol.statusPartOrdinal(null, "0", witness(pageA), 1))
        // Decimal family stays honest about a non-decimal identifier.
        assertNull(OfficePrecisionProtocol.statusPartOrdinal("spreadsheet", pageA, witness(pageA), 1))
        assertNull(OfficePrecisionProtocol.statusPartOrdinal("text", "0123456789", null, null))
    }

    @Test
    fun statusPartOrdinalRejectsStructurallyUnfinishedPartsArray() {
        // The scan already refuses to truncate-guess identifiers, but the
        // ordinal proof goes one step further: a parts array that never
        // closes is NOT qualified as complete just because the partial scan
        // already yielded "enough" identifiers.
        val pageA = "{A1A2A3A4-B1B2-C1C2-D1D2-E1E2E3E4E5A0}"
        val pageB = "{A1A2A3A4-B1B2-C1C2-D1D2-E1E2E3E4E5B1}"
        val truncated = "{\"type\":\"presentation\",\"partscount\":2," +
            "\"selectedpart\":\"$pageB\",\"parts\":[{\"part\":\"$pageA\"},{\"part\":\"$pageB\"}"
        val w = OfficePrecisionProtocol.statusPartWitness(truncated)
        assertFalse(w.arrayClosed)
        // The transport list honestly keeps the proven prefix (the unchanged
        // scanner contract, still used by the resolve step):
        assertEquals(listOf<String?>(pageA, pageB), w.orderedIdentifiers)
        assertEquals(
            listOf<String?>(pageA, pageB),
            OfficePrecisionProtocol.parseStatusPartIdentifiers(truncated),
        )
        // …yet the ordinal proof REFUSES it even though the selected GUID is
        // already at the matching position with a matching count.
        assertNull(OfficePrecisionProtocol.statusPartOrdinal("presentation", pageB, w, 2))
        // Control: the same witness with the array properly CLOSED maps.
        val closed = "{\"type\":\"presentation\",\"partscount\":2," +
            "\"selectedpart\":\"$pageB\",\"parts\":[{\"part\":\"$pageA\"},{\"part\":\"$pageB\"}]}"
        val cw = OfficePrecisionProtocol.statusPartWitness(closed)
        assertTrue(cw.arrayClosed)
        assertEquals(1, OfficePrecisionProtocol.statusPartOrdinal("presentation", pageB, cw, 2))
    }

    @Test
    fun parseDocumentStatusCarriesBracedGuidSelectedPartByteExact() {
        // The pinned documentStatus emits `selectedpart` as a QUOTED string
        // (kit/KitHelper.hpp @2333344: '"' + getPart() + '"'), and for a
        // presentation that string is the page GUID. The existing scanner's
        // value class must not corrupt it — the C15 mismatch compared this
        // field against the decimal request.
        val payload = "status: {\"type\": \"presentation\", \"partscount\": 2, " +
            "\"selectedpart\": \"{1BE1A269-4A03-4202-ACFE-0204C5E9BAAA}\", " +
            "\"width\": 25400, \"height\": 14288, \"viewid\": 7, \"readonly\": false}"
        val info = OfficePrecisionProtocol.parseDocumentStatus(payload)!!
        assertEquals("presentation", info.docType)
        assertEquals(2, info.partsCount)
        assertEquals("{1BE1A269-4A03-4202-ACFE-0204C5E9BAAA}", info.selectedPart)
        assertFalse(info.readOnly!!)
    }

    @Test
    fun goToCellBuildsPinnedUnoJsonAndCanonicalizesAddress() {
        assertEquals(
            "uno .uno:GoToCell {\"ToPoint\":{\"type\":\"string\",\"value\":\"B2\"}}",
            OfficePrecisionProtocol.goToCell("B2"),
        )
        // $ anchors are stripped, letters canonicalized (same target cell).
        assertEquals(
            "uno .uno:GoToCell {\"ToPoint\":{\"type\":\"string\",\"value\":\"B2\"}}",
            OfficePrecisionProtocol.goToCell("\$b\$2"),
        )
        assertNull(OfficePrecisionProtocol.goToCell("B2:C3"))
        assertNull(OfficePrecisionProtocol.goToCell("1B"))
        assertNull(OfficePrecisionProtocol.goToCell(""))
    }

    @Test
    fun pasteUsesPinnedMobileFramingWithBase64Body() {
        // Clipboard.js _pasteTypedBlob (mobile): header + '\n' + btoa(bytes);
        // ChildSession::paste MOBILEAPP branch base64-decodes it.
        assertEquals(
            "paste mimetype=text/plain;charset=utf-8\naGk=",
            OfficePrecisionProtocol.pasteText("hi"),
        )
        // Newlines/quotes/unicode inside the text can never reach the wire
        // framing (they live inside the base64 body).
        val multiline = OfficePrecisionProtocol.pasteText("a\nb\"c\\d")
        assertTrue(multiline!!.startsWith("paste mimetype=text/plain;charset=utf-8\n"))
        assertEquals(1, multiline.count { it == '\n' }) // ONLY the header separator
        // Single-cell content safety is validated by the contract layer;
        // the builder itself refuses NUL and oversize.
        assertNull(OfficePrecisionProtocol.pasteText("a\u0000b"))
        assertNull(OfficePrecisionProtocol.pasteText(""))
    }

    @Test
    fun base64MatchesRfc4648Vectors() {
        // window.btoa-equivalent vectors (standard alphabet, padding).
        assertEquals("", OfficePrecisionProtocol.base64Encode(ByteArray(0)))
        assertEquals("Zg==", OfficePrecisionProtocol.base64Encode("f".toByteArray()))
        assertEquals("Zm8=", OfficePrecisionProtocol.base64Encode("fo".toByteArray()))
        assertEquals("Zm9v", OfficePrecisionProtocol.base64Encode("foo".toByteArray()))
        assertEquals("Zm9vYg==", OfficePrecisionProtocol.base64Encode("foob".toByteArray()))
        assertEquals("Zm9vYmE=", OfficePrecisionProtocol.base64Encode("fooba".toByteArray()))
        assertEquals("Zm9vYmFy", OfficePrecisionProtocol.base64Encode("foobar".toByteArray()))
        // UTF-8 multibyte round-trip shape ("é" = C3 A9).
        assertEquals("w6k=", OfficePrecisionProtocol.base64Encode("é".toByteArray(Charsets.UTF_8)))
    }

    // ------------------------------------------------------------------
    // Parameter validation
    // ------------------------------------------------------------------

    @Test
    fun cellAddressValidationAndConversion() {
        assertTrue(OfficePrecisionProtocol.isValidCellAddress("A1"))
        assertTrue(OfficePrecisionProtocol.isValidCellAddress("\$B\$2"))
        assertTrue(OfficePrecisionProtocol.isValidCellAddress("XFD1048576"))
        assertFalse(OfficePrecisionProtocol.isValidCellAddress("XFE1")) // col > 16384
        assertFalse(OfficePrecisionProtocol.isValidCellAddress("A1048577")) // row > 1048576
        assertFalse(OfficePrecisionProtocol.isValidCellAddress("B0"))
        assertFalse(OfficePrecisionProtocol.isValidCellAddress("AAAA1"))
        assertFalse(OfficePrecisionProtocol.isValidCellAddress("B2:C3"))
        assertFalse(OfficePrecisionProtocol.isValidCellAddress("Sheet1.B2"))
        assertEquals(0, OfficePrecisionProtocol.cellAddressToColumn("A1"))
        assertEquals(1, OfficePrecisionProtocol.cellAddressToColumn("\$b\$2"))
        assertEquals(25, OfficePrecisionProtocol.cellAddressToColumn("Z1"))
        assertEquals(26, OfficePrecisionProtocol.cellAddressToColumn("AA1"))
        assertEquals(16383, OfficePrecisionProtocol.cellAddressToColumn("XFD1"))
        assertEquals(0, OfficePrecisionProtocol.cellAddressToRow("A1"))
        assertEquals(1, OfficePrecisionProtocol.cellAddressToRow("B2"))
        assertEquals(1048575, OfficePrecisionProtocol.cellAddressToRow("A1048576"))
    }

    @Test
    fun pasteTextBoundsAreEnforced() {
        assertTrue(OfficePrecisionProtocol.isValidPasteText("x"))
        assertFalse(OfficePrecisionProtocol.isValidPasteText(null))
        assertFalse(OfficePrecisionProtocol.isValidPasteText(""))
        assertFalse(OfficePrecisionProtocol.isValidPasteText("a\u0000"))
        val oversize = String(CharArray(OfficePrecisionProtocol.MAX_TEXT_BYTES + 1) { 'a' })
        assertFalse(OfficePrecisionProtocol.isValidPasteText(oversize))
    }

    // ------------------------------------------------------------------
    // Answer-frame parsers (pinned payload shapes)
    // ------------------------------------------------------------------

    @Test
    fun parsesPinnedJsonStatusPayload() {
        val frame = "status: {\"type\":\"spreadsheet\",\"partscount\":3,\"selectedpart\":\"1\"," +
            "\"width\":20000,\"height\":10000,\"viewid\":0,\"lastcolumn\":10,\"lastrow\":20}"
        val info = OfficePrecisionProtocol.parseDocumentStatus(frame)!!
        assertEquals("spreadsheet", info.docType)
        assertEquals(3, info.partsCount)
        assertEquals("1", info.selectedPart)
        assertEquals(20000, info.widthTwip)
        assertEquals(10000, info.heightTwip)
        assertEquals(0, info.viewId)
        assertNull(info.readOnly)
        // Fail-closed: no JSON, no witnesses.
        assertNull(OfficePrecisionProtocol.parseDocumentStatus("status: garbage"))
    }

    @Test
    fun parsesCellCursorPayloadExactlyLikePinnedFrontend() {
        // The frontend number-scan: x, y, w, h, col, row (0-based col/row).
        val cursor = OfficePrecisionProtocol.parseCellCursorPayload("0, 380, 1219, 256, 1, 3")!!
        assertEquals(0, cursor.xTwip)
        assertEquals(380, cursor.yTwip)
        assertEquals(1219, cursor.widthTwip)
        assertEquals(256, cursor.heightTwip)
        assertEquals(1, cursor.column)
        assertEquals(3, cursor.row)
        assertNull(OfficePrecisionProtocol.parseCellCursorPayload("EMPTY"))
        assertTrue(OfficePrecisionProtocol.isCellCursorEmpty("EMPTY"))
        assertNull(OfficePrecisionProtocol.parseCellCursorPayload(null))
        assertNull(OfficePrecisionProtocol.parseCellCursorPayload("1, 2, 3")) // < 6 numbers
    }

    @Test
    fun parsesPasteVerdictOnlyForPinnedTokens() {
        assertEquals("success", OfficePrecisionProtocol.parsePasteVerdict("success"))
        assertEquals("fallback", OfficePrecisionProtocol.parsePasteVerdict(" fallback "))
        assertNull(OfficePrecisionProtocol.parsePasteVerdict("maybe"))
        assertNull(OfficePrecisionProtocol.parsePasteVerdict(""))
    }

    @Test
    fun textSelectionContentKeepsBothPinnedFramingsAndNeverTrims() {
        val single = OfficePrecisionProtocol.parseTextSelectionContent("textselectioncontent: hello")!!
        assertFalse(single.multiFormatJson)
        assertEquals("hello", single.text)
        assertEquals(5, single.byteCount)
        assertFalse(single.oversize)

        // Multi-line content survives byte-exact (no trim, no newline split).
        val multiline = OfficePrecisionProtocol.parseTextSelectionContent(
            "textselectioncontent: line1\nline2\n",
        )!!
        assertEquals("line1\nline2\n", multiline.text)

        // Multi-mime JSON framing (header delimiter is '\n').
        val multi = OfficePrecisionProtocol.parseTextSelectionContent(
            "textselectioncontent:\n{\"text/plain\":\"x\"}",
        )!!
        assertTrue(multi.multiFormatJson)
        assertEquals("{\"text/plain\":\"x\"}", multi.text)

        // Oversize is refused with its real byte count, never truncated.
        val big = "textselectioncontent: " + String(
            CharArray(OfficePrecisionProtocol.MAX_ANSWER_BYTES + 1) { 'a' },
        )
        val oversize = OfficePrecisionProtocol.parseTextSelectionContent(big)!!
        assertTrue(oversize.oversize)
        assertEquals("", oversize.text)
        assertEquals(OfficePrecisionProtocol.MAX_ANSWER_BYTES + 1, oversize.byteCount)

        assertNull(OfficePrecisionProtocol.parseTextSelectionContent("other: x"))
    }

    @Test
    fun parsesCommandValuesHeaderScalars() {
        val header = OfficePrecisionProtocol.parseCommandValuesHeader(
            "{\"commandName\":\".uno:CellCursor\",\"commandValues\":\"EMPTY\"}",
        )!!
        assertEquals(".uno:CellCursor", header.commandName)
        assertEquals("EMPTY", header.commandValues)
        // Object-shaped commandValues stay null (fail-closed; the precision
        // surface only consumes the string-shaped CellCursor/ReadOnly answers).
        val obj = OfficePrecisionProtocol.parseCommandValuesHeader(
            "{\"commandName\":\".uno:ViewSettings\",\"commandValues\":{\"a\":1}}",
        )!!
        assertEquals(".uno:ViewSettings", obj.commandName)
        assertNull(obj.commandValues)
        assertNull(OfficePrecisionProtocol.parseCommandValuesHeader("{}"))
    }

    // ------------------------------------------------------------------
    // Binder reply budget (Main marshalling review 2026-10-27):
    // Parcel.writeString serializes UTF-16, so the caps must be proven
    // against the REAL serialized cost, not UTF-8 byte counts alone.
    // ------------------------------------------------------------------

    @Test
    fun utf16ParcelCostIsComputedForAsciiAndNonBmp() {
        // ASCII: 4-byte length + 2 bytes/char + 2-byte NUL, 4-aligned.
        assertEquals(16L, OfficePrecisionProtocol.utf16ParcelBytes("ascii"))
        // Non-BMP: one code point = 2 UTF-16 code units (surrogate pair).
        assertEquals(12L, OfficePrecisionProtocol.utf16ParcelBytes("\uD83D\uDE00"))
        // Null strings still cost their length marker.
        assertEquals(4L, OfficePrecisionProtocol.utf16ParcelBytes(null))
    }

    @Test
    fun utf8AnswerCapGuaranteesTheUtf16ReplyBudget() {
        // Worst-case expansion is ASCII (1 UTF-8 byte -> 1 UTF-16 unit):
        // a payload at the UTF-8 cap must still fit the reply budget.
        val worstAscii = String(CharArray(OfficePrecisionProtocol.MAX_ANSWER_BYTES) { 'a' })
        assertTrue(OfficePrecisionProtocol.contentFitsReplyBudget(worstAscii))
        // One char beyond the derived UTF-16 bound must be refused.
        val tooBig = String(
            CharArray((OfficePrecisionProtocol.MAX_REPLY_PARCEL_BYTES -
                OfficePrecisionProtocol.REPLY_META_RESERVE_BYTES) / 2 + 1) { 'a' },
        )
        assertFalse(OfficePrecisionProtocol.contentFitsReplyBudget(tooBig))
        // Non-BMP content at the same UTF-8 cap is far below the bound
        // (4 UTF-8 bytes -> 2 UTF-16 units per code point).
        val emojiCount = OfficePrecisionProtocol.MAX_ANSWER_BYTES / 4
        val emoji = String(CharArray(emojiCount * 2) { i ->
            if (i % 2 == 0) '\uD83D' else '\uDE00'
        })
        assertEquals(OfficePrecisionProtocol.MAX_ANSWER_BYTES, emoji.toByteArray(Charsets.UTF_8).size)
        assertTrue(OfficePrecisionProtocol.contentFitsReplyBudget(emoji))
    }

    @Test
    fun fullResultEstimateStaysInsideBinderBudgetAtTheCap() {
        val maxText = String(CharArray(OfficePrecisionProtocol.MAX_ANSWER_BYTES) { 'a' })
        val result = OfficePrecisionResult(
            opId = "op-with-a-long-ish-name-0123456789",
            sessionToken = String(CharArray(256) { 't' }),
            generation = Long.MAX_VALUE,
            action = OfficePrecisionAction.QUERY_TEXT_SELECTION,
            state = OfficePrecisionState.QUERY_OBSERVED,
            failure = null,
            detail = String(CharArray(240) { 'd' }),
            answer = OfficePrecisionAnswer.TextSelection(maxText, maxText.length, false),
            attestation = String(CharArray(240) { 'a' }),
            submittedAtElapsedMs = 1L,
            completedAtElapsedMs = 2L,
        )
        val estimate = OfficePrecisionProtocol.estimateResultParcelBytes(result)
        assertTrue(
            "estimate $estimate exceeds budget",
            estimate <= OfficePrecisionProtocol.MAX_REPLY_PARCEL_BYTES,
        )
        assertTrue(OfficePrecisionProtocol.fitsReplyBudget(result))
        // The 768 KiB budget itself keeps >=25% headroom under the ~1 MiB
        // binder transaction buffer.
        assertTrue(OfficePrecisionProtocol.MAX_REPLY_PARCEL_BYTES <= 768 * 1024)
        assertTrue(OfficePrecisionProtocol.MAX_REPLY_PARCEL_BYTES * 4L <= 1024L * 1024L * 3L)
    }

    @Test
    fun semanticExpectedReadbackTextUndoesOnlyTheKnownCalcLiteralInputEscape() {
        // Actual C14 witness pair: outbound wire '00123, native projection
        // 00123 — the comparator expectation decodes exactly one host INPUT
        // codec prefix, request side only, SET_CELL_CONTENT/LITERAL only.
        assertEquals(
            "00123",
            OfficePrecisionProtocol.semanticExpectedReadbackText(
                OfficePrecisionAction.SET_CELL_CONTENT,
                OfficePrecisionContentKind.LITERAL,
                "'00123",
            ),
        )
        // NUMBER branch: same kind, unescaped — exact no-op pass-through.
        assertEquals(
            "123",
            OfficePrecisionProtocol.semanticExpectedReadbackText(
                OfficePrecisionAction.SET_CELL_CONTENT,
                OfficePrecisionContentKind.LITERAL,
                "123",
            ),
        )
        // Double prefix decodes EXACTLY once (user's own apostrophe kept).
        assertEquals(
            "'00123",
            OfficePrecisionProtocol.semanticExpectedReadbackText(
                OfficePrecisionAction.SET_CELL_CONTENT,
                OfficePrecisionContentKind.LITERAL,
                "''00123",
            ),
        )
        // Never decodes down to an empty expectation.
        assertEquals(
            "'",
            OfficePrecisionProtocol.semanticExpectedReadbackText(
                OfficePrecisionAction.SET_CELL_CONTENT,
                OfficePrecisionContentKind.LITERAL,
                "'",
            ),
        )
        // Leading = literal keeps the = after decoding the escape.
        assertEquals(
            "=SUM(A1:A2)",
            OfficePrecisionProtocol.semanticExpectedReadbackText(
                OfficePrecisionAction.SET_CELL_CONTENT,
                OfficePrecisionContentKind.LITERAL,
                "'=SUM(A1:A2)",
            ),
        )
        // FORMULA kind never touches this stage or codec.
        assertEquals(
            "'x",
            OfficePrecisionProtocol.semanticExpectedReadbackText(
                OfficePrecisionAction.SET_CELL_CONTENT,
                OfficePrecisionContentKind.FORMULA,
                "'x",
            ),
        )
        // APPLY_TEXT (Writer) has no codec at this layer — byte-exact keep.
        assertEquals(
            "'kept",
            OfficePrecisionProtocol.semanticExpectedReadbackText(
                OfficePrecisionAction.APPLY_TEXT,
                null,
                "'kept",
            ),
        )
        assertNull(
            OfficePrecisionProtocol.semanticExpectedReadbackText(
                OfficePrecisionAction.SET_CELL_CONTENT,
                OfficePrecisionContentKind.LITERAL,
                null,
            ),
        )
    }
}
