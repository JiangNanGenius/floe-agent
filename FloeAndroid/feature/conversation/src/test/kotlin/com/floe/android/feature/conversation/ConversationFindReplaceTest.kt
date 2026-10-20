// SPDX-License-Identifier: MPL-2.0
//
// Pure-JVM tests for the local literal find/replace engine.
//
// No Compose runtime, Android device, provider, network, credential store or
// file system is involved. Every fixture is a String; the scanner and the
// scroll policy are pure. These tests are AUTHORED but NOT RUN in this
// source-only lane (no Gradle/compiler was used); Main's serial qualification
// owns execution.

package com.floe.android.feature.conversation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationFindReplaceTest {

    /* ------------------------------ empty query ------------------------------ */

    @Test
    fun emptyQueryIsSafeAndNeverMatches() {
        val scanner = FindScanner("alpha", "")
        assertEquals(0, scanner.count())
        assertNull(scanner.next(0))
        assertNull(scanner.previous(10))
        assertNull(scanner.first())
        assertNull(scanner.last())
        assertNull(scanner.matchAt(0))
        assertEquals(FindScan(0, null, -1), scanner.scan(2))
        assertTrue(scanner.matches(100).isEmpty())
        assertEquals(FindReplaceAllOutcome.NoMatch, scanner.replaceAll("x", 0))
        assertEquals(
            FindReplaceOneOutcome.Stale,
            scanner.replaceOne(FindMatch(0, 1), "x"),
        )
    }

    @Test
    fun matchInvariantRejectsEmptyOrNegativeRanges() {
        var threw = false
        try {
            FindMatch(2, 2)
        } catch (_: IllegalArgumentException) {
            threw = true
        }
        assertTrue("a zero-length match is not a literal occurrence", threw)
    }

    /* --------------------------- case + whole word --------------------------- */

    @Test
    fun caseInsensitiveByDefaultAndMatchCaseIsExact() {
        val text = "Alpha alpha ALPHA"
        assertEquals(3, FindScanner(text, "alpha").count())
        assertEquals(3, FindScanner(text, "AlPhA").count())

        val exact = FindScanner(text, "alpha", FindOptions(matchCase = true))
        assertEquals(1, exact.count())
        assertEquals(FindMatch(6, 11), exact.first())

        val upper = FindScanner(text, "ALPHA", FindOptions(matchCase = true))
        assertEquals(1, upper.count())
        assertEquals(FindMatch(12, 17), upper.first())
    }

    @Test
    fun wholeWordUsesUnicodeWordBoundaries() {
        val text = "cat concatenate cat. cat_cat 1cat cat1"
        assertEquals(7, FindScanner(text, "cat").count())

        val whole = FindScanner(text, "cat", FindOptions(wholeWord = true))
        assertEquals(2, whole.count())
        assertEquals(listOf(0, 16), whole.matches(10).map { it.start })

        // Connector punctuation and digits are word characters: a match inside
        // "cat_cat", "1cat" or "cat1" is not a whole word.
        assertEquals(
            0,
            FindScanner("cat_cat", "cat", FindOptions(wholeWord = true)).count(),
        )
        assertEquals(
            0,
            FindScanner("1cat", "cat", FindOptions(wholeWord = true)).count(),
        )
        assertEquals(
            0,
            FindScanner("cat1", "cat", FindOptions(wholeWord = true)).count(),
        )

        // Punctuation-only queries keep ordinary literal semantics in
        // whole-word mode; they are not made impossible to find.
        assertEquals(
            2,
            FindScanner("a(cat) b(cat)", "(cat)", FindOptions(wholeWord = true)).count(),
        )
        assertEquals(
            1,
            FindScanner("(cat)", "cat", FindOptions(wholeWord = true)).count(),
        )
    }

    /* ------------------------ Unicode / line endings ------------------------ */

    @Test
    fun cjkEmojiAndCombiningSequencesMatchByCodePoint() {
        assertEquals(2, FindScanner("中文中文", "中文").count())

        val emoji = FindScanner("😀a😀", "😀")
        assertEquals(2, emoji.count())
        assertEquals(FindMatch(0, 2), emoji.first())
        assertEquals(FindMatch(3, 5), emoji.last())

        val combining = FindScanner("e\u0301x e\u0301", "e\u0301")
        assertEquals(2, combining.count())
        assertEquals(FindMatch(0, 2), combining.first())
        assertEquals(FindMatch(4, 6), combining.last())

        // "e" alone is not a whole word when followed by a combining mark
        // belonging to the same grapheme; the composed sequence is.
        assertEquals(
            0,
            FindScanner("e\u0301", "e", FindOptions(wholeWord = true)).count(),
        )
        assertEquals(
            1,
            FindScanner("e\u0301", "e\u0301", FindOptions(wholeWord = true)).count(),
        )

        // CJK ideographs are word characters: adjacent ideographs form one
        // word for whole-word matching, while a space-separated ideograph is
        // a standalone match.
        assertEquals(
            1,
            FindScanner("猫猫 猫", "猫", FindOptions(wholeWord = true)).count(),
        )
    }

    @Test
    fun crlfIsAnExactLiteral() {
        val scanner = FindScanner("one\r\ntwo\r\n", "\r\n")
        assertEquals(2, scanner.count())
        assertEquals(listOf(FindMatch(3, 5), FindMatch(8, 10)), scanner.matches(10))
        val outcome = scanner.replaceAll("\n", 0) as FindReplaceAllOutcome.Replaced
        assertEquals("one\ntwo\n", outcome.text)
        assertEquals(2, outcome.count)
        assertEquals(0, outcome.caretOffset)
    }

    @Test
    fun overlappingMatchesAreNonOverlappingLeftToRight() {
        val scanner = FindScanner("aaa", "aa")
        assertEquals(1, scanner.count())
        assertEquals(FindMatch(0, 2), scanner.first())
        assertNull(scanner.next(2))
        val outcome = scanner.replaceAll("b", 0) as FindReplaceAllOutcome.Replaced
        assertEquals("ba", outcome.text)
        assertEquals(1, outcome.count)
    }

    /* ------------------------------ navigation ------------------------------ */

    @Test
    fun nextPreviousAndLastUseRealOffsets() {
        val scanner = FindScanner("a a a", "a")
        assertEquals(FindMatch(0, 1), scanner.next(0))
        assertEquals(FindMatch(2, 3), scanner.next(1))
        assertEquals(FindMatch(4, 5), scanner.next(3))
        assertNull(scanner.next(5))
        assertNull(scanner.previous(0))
        assertEquals(FindMatch(0, 1), scanner.previous(1))
        assertEquals(FindMatch(2, 3), scanner.previous(3))
        assertEquals(FindMatch(4, 5), scanner.last())
        assertEquals(FindMatch(2, 3), scanner.matchAt(2))
        assertNull(scanner.matchAt(1))
    }

    @Test
    fun scanPrefersContainingMatchThenNextThenWrapAndEndPrefersLast() {
        val scanner = FindScanner("abc abc", "abc")
        assertEquals(FindScan(2, FindMatch(0, 3), 0), scanner.scan(0))
        assertEquals(FindScan(2, FindMatch(0, 3), 0), scanner.scan(1))
        assertEquals(FindScan(2, FindMatch(4, 7), 1), scanner.scan(3))
        assertEquals(FindScan(2, FindMatch(4, 7), 1), scanner.scan(4))
        assertEquals(FindScan(2, FindMatch(4, 7), 1), scanner.scan(7))
        assertEquals(FindScan(2, FindMatch(4, 7), 1), scanner.scan(100))

        val single = FindScanner("a a a", "a")
        assertEquals(FindScan(3, FindMatch(2, 3), 1), single.scan(1))
        assertEquals(FindScan(3, FindMatch(4, 5), 2), single.scan(5))
    }

    /* ------------------------------- replacement ------------------------------- */

    @Test
    fun replaceOneEditsOnlyTheExactRealMatch() {
        val scanner = FindScanner("alpha beta alpha", "alpha")
        val first = scanner.first()!!
        val outcome = scanner.replaceOne(first, "X") as FindReplaceOneOutcome.Replaced
        assertEquals("X beta alpha", outcome.text)
        assertEquals(1, outcome.caretOffset)

        assertEquals(
            FindReplaceOneOutcome.Stale,
            scanner.replaceOne(FindMatch(1, 6), "X"),
        )
        assertEquals(
            FindReplaceOneOutcome.Stale,
            scanner.replaceOne(FindMatch(0, 4), "X"),
        )
    }

    @Test
    fun replaceAllIsCompleteAndMapsTheCaretThroughTheEdits() {
        val scanner = FindScanner("a a", "a")
        val outcome = scanner.replaceAll("bb", 3) as FindReplaceAllOutcome.Replaced
        assertEquals("bb bb", outcome.text)
        assertEquals(2, outcome.count)
        assertEquals(5, outcome.caretOffset)

        val endOfFirst = scanner.replaceAll("bb", 1) as FindReplaceAllOutcome.Replaced
        assertEquals("bb bb", endOfFirst.text)
        assertEquals(2, endOfFirst.caretOffset)

        val noMatch = FindScanner("bbb", "a").replaceAll("x", 0)
        assertEquals(FindReplaceAllOutcome.NoMatch, noMatch)
    }

    @Test
    fun replacementIsLiteralDollarBackslashAndNRatherThanATemplate() {
        val text = "value \$1 and \\path"
        val scanner = FindScanner(text, "\$1")
        assertEquals(1, scanner.count())
        val replacement = "\$2\\n" // literal $2\n, not a group/escape expansion
        val outcome = scanner.replaceAll(replacement, 0) as FindReplaceAllOutcome.Replaced
        assertEquals("value \$2\\n and \\path", outcome.text)

        // A query beginning with a backslash is still a literal, not \b.
        assertEquals(2, FindScanner("a\\b a\\b", "\\b").count())
    }

    @Test
    fun replaceAllRefusesExcessiveExpansionWithoutReturningTruncatedText() {
        val text = "a".repeat(1_000)
        val replacement = "x".repeat(9_000)
        val outcome = FindScanner(text, "a").replaceAll(replacement, 0)
        assertTrue(
            "an enormous replacement must be refused, never truncated",
            outcome is FindReplaceAllOutcome.RefusedTooLarge,
        )
        assertTrue(
            (outcome as FindReplaceAllOutcome.RefusedTooLarge).attemptedUtf16Length >=
                FindScanner.MAX_REPLACE_ALL_OUTPUT_UTF16,
        )
    }

    /* ------------------------------ highlight ------------------------------ */

    @Test
    fun highlightWindowIsBoundedWhileCountAndReplacementRemainComplete() {
        val text = "a ".repeat(600)
        val scanner = FindScanner(text, "a")
        assertEquals(600, scanner.count())
        assertEquals(FindScanner.MAX_HIGHLIGHT_MATCHES, scanner.matches(FindScanner.MAX_HIGHLIGHT_MATCHES).size)
        assertEquals(600, scanner.matches(10_000).size)

        val outcome = scanner.replaceAll("b", 0) as FindReplaceAllOutcome.Replaced
        assertEquals(600, outcome.count)
        assertFalse(outcome.text.contains('a'))
    }

    /* ------------------------------- scrolling ------------------------------- */

    @Test
    fun scrollPolicyBringsTheMatchIntoViewAndClamps() {
        // Already visible: keep the current offset.
        assertEquals(
            100,
            FindScrollPolicy.targetOffset(
                matchTop = 150f,
                matchBottom = 170f,
                scrollOffset = 100,
                viewportHeight = 200,
                maxScroll = 500,
                marginPx = 20,
            ),
        )
        // Above the visible band: top - margin.
        assertEquals(
            30,
            FindScrollPolicy.targetOffset(50f, 70f, 100, 200, 500, 20),
        )
        // Below the visible band: bottom - viewport + margin.
        assertEquals(
            190,
            FindScrollPolicy.targetOffset(350f, 370f, 100, 200, 500, 20),
        )
        // Clamp to the real scroll range.
        assertEquals(
            500,
            FindScrollPolicy.targetOffset(1000f, 1020f, 100, 200, 500, 20),
        )
        assertEquals(
            0,
            FindScrollPolicy.targetOffset(5f, 25f, 100, 200, 500, 20),
        )
        // No measured viewport yet: never invent a scroll.
        assertEquals(
            100,
            FindScrollPolicy.targetOffset(350f, 370f, 100, 0, 500, 20),
        )
    }

    /* -------------------------------- privacy -------------------------------- */

    @Test
    fun diagnosticStringsRedactDraftQueryAndReplacement() {
        val key = FindSearchKey(
            sessionEpoch = 7L,
            draftGeneration = 3L,
            text = "secret draft",
            query = "secret query",
            matchCase = false,
            wholeWord = true,
        )
        val keyText = key.toString()
        assertFalse(keyText.contains("secret"))
        assertTrue(keyText.contains("textLength=12"))
        assertTrue(keyText.contains("queryLength=12"))

        val state = FindReplaceUiState(
            isOpen = true,
            query = "secret query",
            replacement = "secret replacement",
        )
        val stateText = state.toString()
        assertFalse(stateText.contains("secret"))
        assertTrue(stateText.contains("queryLength=12"))
        assertTrue(stateText.contains("replacementLength=18"))
    }
}
