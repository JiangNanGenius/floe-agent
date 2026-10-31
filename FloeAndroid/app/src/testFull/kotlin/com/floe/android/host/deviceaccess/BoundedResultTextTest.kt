// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The platform result contract is a closed bounded shape: 2048-character
 * summary, <=192-byte evidence lines, no control characters and no split
 * surrogate pairs. These are transport invariants, not cosmetic truncation.
 */
class BoundedResultTextTest {

    @Test
    fun summaryIsClippedToTheTransportCeilingWithoutControlCharacters() {
        val raw = "a\u0000b\u0001c\n" + "x".repeat(5_000)
        val summary = BoundedResultText.summary(raw)
        assertTrue(summary.length <= 2_048)
        assertFalse(summary.any { it.code < 0x20 && it != '\n' && it != '\t' })
        assertTrue(summary.endsWith("…"))
    }

    @Test
    fun evidenceIsAtMost192Utf8Bytes() {
        val line = BoundedResultText.evidence("中".repeat(200))
        assertTrue(line.toByteArray(Charsets.UTF_8).size <= 192)
        assertTrue(line.endsWith("…"))
    }

    @Test
    fun clippingDoesNotSplitSurrogatePairs() {
        val emoji = "😀"
        val value = emoji.repeat(20)
        val clipped = BoundedResultText.clip(value, 15)
        assertTrue(clipped.length <= 15)
        assertEquals(0, clipped.count { Character.isSurrogate(it) } % 2)
    }

    @Test
    fun detailAndTokenStayBoundedAndTokenShaped() {
        val detail = BoundedResultText.detail("x".repeat(500))
        assertTrue(detail.length <= 200)
        assertEquals("root_failed-2", BoundedResultText.token("root_failed-2 $ `"))
        assertEquals("failed", BoundedResultText.token("$$$"))
    }

    @Test
    fun emptySummaryStillProducesAValidResult() {
        assertEquals("Completed.", BoundedResultText.summary(""))
        assertEquals("Completed.", BoundedResultText.summary(" \n\t "))
    }
}
