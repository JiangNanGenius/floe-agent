// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Focused JVM tests for the language binding's exact UTF-16 position math
 * (job-bdebb54ff6ff4403). AUTHORED SOURCE ONLY — not executed by the
 * authoring job. LSP positions count UTF-16 code units and every line
 * terminator style (\n, \r\n, lone \r) is ONE break; the native client
 * applies the same rule (G04LspPosition) against the EXACT synced bytes.
 * Capacity reality (verified against G04WorkspaceDocumentSession): the
 * native session admits 32 documents / 16 MiB total / 4 MiB per document —
 * the binding's queues are sized to that truth (the old "at most eight"
 * note was a wrong assumption and must not come back).
 */
class G04IdeLanguageBindingTest {
    private fun pos(text: String, caret: Int) = G04IdeLanguageBinding.position(text, caret)
    private fun off(text: String, line: Int, column: Int) = G04IdeLanguageBinding.offset(text, line, column)

    @Test
    fun lineFeedPositionsAreExact() {
        val text = "abc\ndefg\n"
        assertEquals(0 to 0, pos(text, 0))
        assertEquals(0 to 3, pos(text, 3))
        assertEquals(1 to 0, pos(text, 4))
        assertEquals(1 to 4, pos(text, 8))
        assertEquals(2 to 0, pos(text, 9))
    }

    @Test
    fun crlfIsOneBreakLoneCrIsOneBreak() {
        val crlf = "ab\r\ncd"
        assertEquals(1 to 0, pos(crlf, 4))
        val lfOnly = "ab\ncd"
        assertEquals(1 to 0, pos(lfOnly, 3))
        val loneCR = "a\rb\r"
        assertEquals(1 to 0, pos(loneCR, 2))
        assertEquals(2 to 0, pos(loneCR, 4))
    }

    @Test
    fun surrogatePairsCountAsTwoUtf16Units() {
        val text = "a😀b" // a, surrogate pair, b → UTF-16 length 4
        assertEquals(0 to 1, pos(text, 1))
        assertEquals(0 to 3, pos(text, 3))
        assertEquals(0 to 4, pos(text, 4))
    }

    @Test
    fun caretBeyondTextLengthIsCoercedByCallerAndMathStaysBounded() {
        val text = "short"
        // position() clamps the walk to text length; huge offsets clamp.
        assertEquals(0 to 5, pos(text, 999))
    }

    @Test
    fun offsetRoundTripsAcrossEveryTerminatorStyle() {
        val text = "one\r\ntwo\rthree\nfour"
        for (caret in 0..text.length) {
            val (line, column) = pos(text, caret)
            val recovered = off(text, line, column)
            assertEquals("caret $caret must round-trip via (line $line, column $column)", caret, recovered)
        }
    }

    @Test
    fun offsetRefusesOutsideTheActualDocument() {
        val text = "one\ntwo"
        assertNull(off(text, -1, 0))
        assertNull(off(text, 0, -1))
        assertNull(off(text, 9, 0))
        assertNull("column beyond the line's real length must refuse", off(text, 1, 4))
        assertEquals(2, off(text, 0, 2))
        assertEquals(4, off(text, 1, 0))
        assertEquals(7, off(text, 1, 3))
    }
}
