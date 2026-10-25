// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
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
 * Position contract boundary (verified against the native G04LspPosition
 * line model): LSP line content never contains a terminator and the next
 * line starts AFTER a whole CRLF, so the slot strictly BETWEEN the \r and
 * the \n is not addressable by any (line, column). The helpers canonicalize
 * an interior CRLF caret forward to the next line's start; round-trips are
 * exact for EVERY other UTF-16 offset and for every addressable position.
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
    fun offsetRoundTripsToCanonicalBoundariesAcrossEveryTerminatorStyle() {
        val text = "one\r\ntwo\rthree\nfour"
        for (caret in 0..text.length) {
            val (line, column) = pos(text, caret)
            val recovered = off(text, line, column)
            val interiorOfCrlf = caret > 0 && caret < text.length &&
                text[caret - 1] == '\r' && text[caret] == '\n'
            if (interiorOfCrlf) {
                // The slot between \r and \n is not an LSP-addressable point:
                // no (line, column) names it, and the native G04LspPosition
                // model starts the next line after the WHOLE CRLF. The binding
                // therefore canonicalizes such a caret to the next line's
                // start — assert the explicit canonical boundary, never a skip.
                assertEquals("interior CRLF caret $caret must canonicalize to a line start", 0, column)
                assertEquals("interior CRLF caret $caret must recover to the next line's start", caret + 1, recovered)
                assertEquals("caret $caret must share the address of the caret after the CRLF",
                    pos(text, caret + 1), line to column)
            } else {
                assertEquals("caret $caret must round-trip via (line $line, column $column)", caret, recovered)
            }
        }
    }

    @Test
    fun crlfInteriorCaretSharesTheNextLineStartsAddress() {
        val text = "one\r\ntwo\rthree\nfour"
        // Caret 4 sits INSIDE the first CRLF; caret 3 (before the \r) and
        // caret 5 (after the \n) are its two addressable boundary carets.
        assertEquals(0 to 3, pos(text, 3))
        assertEquals(3, off(text, 0, 3))
        assertEquals(1 to 0, pos(text, 4))
        assertEquals(pos(text, 4), pos(text, 5))
        assertEquals(5, off(text, 1, 0))
        // No column may address the terminator: line 0 really ends at column 3.
        assertNull("terminator interior is not addressable by any column", off(text, 0, 4))
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

    @Test
    fun serverGoneRefusalsAreTheReadyCacheRecoveryTrigger() {
        // The typed refusals naming the SERVER itself must drop the cached
        // "ready" so the next interaction re-runs the explicit ensure.
        assertTrue(G04IdeLanguageBinding.isServerGoneRefusal(
            TerminalActionReply.Refused("serverUnavailable", "stopped")))
        assertTrue(G04IdeLanguageBinding.isServerGoneRefusal(
            TerminalActionReply.Refused("serverGone", null)))
        // Everything else (revision fences, saturation, timeouts) must NOT
        // clear the ready cache: only server death is the trigger.
        assertFalse(G04IdeLanguageBinding.isServerGoneRefusal(
            TerminalActionReply.Refused("staleRevision", null)))
        assertFalse(G04IdeLanguageBinding.isServerGoneRefusal(
            TerminalActionReply.Refused("saturated", null)))
        assertFalse(G04IdeLanguageBinding.isServerGoneRefusal(TerminalActionReply.TimedOut))
        assertFalse(G04IdeLanguageBinding.isServerGoneRefusal(null))
    }
}
