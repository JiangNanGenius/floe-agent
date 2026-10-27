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
        // Fail-closed refusals (never a partial/guessed command).
        assertNull(OfficePrecisionProtocol.setClientPart("a"))
        assertNull(OfficePrecisionProtocol.setClientPart("-1"))
        assertNull(OfficePrecisionProtocol.setClientPart("1 x"))
        assertNull(OfficePrecisionProtocol.setClientPart("1\n"))
        assertNull(OfficePrecisionProtocol.setClientPart(""))
        assertNull(OfficePrecisionProtocol.setClientPart("1234567890")) // > 9 digits
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
