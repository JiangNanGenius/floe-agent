// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.ide

import com.floe.android.feature.ide.internal.IdeTextMath
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** UTF-16 mapping + surrogate-safe minimal projection sync. */
class IdeTextMathTest {

    @Test
    fun deletionUsesPreEditLengthIncludingEofEmojiAndWholeBuffer() {
        for ((text, start, length) in listOf(Triple("abcZ", 3, 1),
            Triple("a🐍", 1, 2), Triple("all", 0, 3), Triple("abXYcd", 2, 2))) {
            val range = IdeTextMath.deletionRange(text.length, start, length)!!
            assertEquals(start, range.startUtf16)
            assertEquals(start + length, range.endUtf16)
            val after = text.removeRange(start, start + length)
            assertEquals(after, text.replaceRange(range.startUtf16, range.endUtf16, ""))
        }
        assertNull(IdeTextMath.deletionRange(3, 2, 2))
        assertNull(IdeTextMath.deletionRange(0, 0, 1))
        assertNull(IdeTextMath.deletionRange(3, -1, 1))
    }

    @Test
    fun lineColumnLfAndCrlf() {
        val text = "ab\r\ncd\nef"
        assertEquals(0 to 0, IdeTextMath.lineColumnAt(text, 0))
        assertEquals(0 to 2, IdeTextMath.lineColumnAt(text, 2))
        assertEquals(1 to 0, IdeTextMath.lineColumnAt(text, 4))
        assertEquals(1 to 1, IdeTextMath.lineColumnAt(text, 5))
        assertEquals(2 to 2, IdeTextMath.lineColumnAt(text, text.length))
    }

    @Test
    fun detectsSurrogateInterior() {
        val emoji = "\uD83D\uDE00" // one codepoint, two UTF-16 units
        assertTrue(IdeTextMath.insideSurrogatePair(emoji, 1))
        assertFalse(IdeTextMath.insideSurrogatePair(emoji, 0))
        assertFalse(IdeTextMath.insideSurrogatePair(emoji, 2))
    }

    @Test
    fun noWriteWhenEqual() {
        assertNull(IdeTextMath.minimalReplacement("abc", "abc"))
        assertNull(IdeTextMath.minimalReplacement("", ""))
    }

    @Test
    fun minimalInsert() {
        val op = IdeTextMath.minimalReplacement("ac", "abc")!!
        assertEquals(1, op.startUtf16)
        assertEquals(1, op.endUtf16)
        assertEquals("b", op.replacement)
    }

    @Test
    fun minimalDelete() {
        val op = IdeTextMath.minimalReplacement("abc", "ac")!!
        assertEquals(1, op.startUtf16)
        assertEquals(2, op.endUtf16)
        assertEquals("", op.replacement)
    }

    @Test
    fun minimalReplacePreservesAffixes() {
        val op = IdeTextMath.minimalReplacement("aXYb", "aZWQb")!!
        assertEquals(1, op.startUtf16)
        assertEquals(3, op.endUtf16)
        assertEquals("ZWQ", op.replacement)
    }

    @Test
    fun pairBoundaryFallsBackToFullReplace() {
        // The shared suffix would start inside the surrogate pair: the sync
        // must choose ONE full write instead of two half-pair writes.
        val current = "\uD83D\uDE00b"
        val desired = "\uD83D\uDE01b"
        val op = IdeTextMath.minimalReplacement(current, desired)!!
        assertEquals(0, op.startUtf16)
        assertEquals(current.length, op.endUtf16)
        assertEquals(desired, op.replacement)
        // Applying it yields the desired text exactly.
        assertEquals(desired, current.substring(0, op.startUtf16) + op.replacement + current.substring(op.endUtf16))
    }

    @Test
    fun applyingOpAlwaysReproducesDesired() {
        val cases = listOf(
            "hello" to "hello world",
            "hello world" to "hello",
            "中文😀text" to "中文😀more text",
            "aaa" to "bbb",
            "" to "x",
            "x" to "",
        )
        for ((current, desired) in cases) {
            val op = IdeTextMath.minimalReplacement(current, desired) ?: continue
            val result = current.substring(0, op.startUtf16) + op.replacement + current.substring(op.endUtf16)
            assertEquals("sync $current -> $desired", desired, result)
        }
    }

    @Test
    fun emptyCurrentInsertsFull() {
        val op = IdeTextMath.minimalReplacement("", "content")!!
        assertEquals(0, op.startUtf16)
        assertEquals(0, op.endUtf16)
        assertEquals("content", op.replacement)
        assertNotNull(op)
    }
}
