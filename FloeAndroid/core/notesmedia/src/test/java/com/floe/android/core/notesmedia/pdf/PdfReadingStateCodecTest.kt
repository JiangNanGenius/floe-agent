// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.pdf

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PdfReadingStateCodecTest {

    private val sha = "c".repeat(64)

    private fun state() = PdfReadingState(
        sourceSha256 = sha,
        position = PdfReadingPosition(PdfPageId(4), 1.75f, 0.25f, 0.9f),
        bookmarks = listOf(
            PdfBookmark("bm-1", PdfPageId(2), "Chapter\tone\nwith\\slash", 1_700_000_000_000L, "snippet"),
            PdfBookmark("bm-2", PdfPageId(9), "Ünïcode label", 1_700_000_000_001L),
        ),
        pageRotationQuarterTurns = 3,
    )

    @Test
    fun roundTripPreservesEveryFieldAndEscapesLabels() {
        val encoded = PdfReadingStateCodec.encode(state())
        assertTrue(encoded.contains("\\t"))
        val decoded = PdfReadingStateCodec.decode(encoded, sha)
        assertTrue(decoded is PdfReadingStateResult.Ok)
        val restored = (decoded as PdfReadingStateResult.Ok).state
        assertEquals(state(), restored)
    }

    @Test
    fun staleSourceIsRejected() {
        val encoded = PdfReadingStateCodec.encode(state())
        val decoded = PdfReadingStateCodec.decode(encoded, "d".repeat(64))
        assertTrue(decoded is PdfReadingStateResult.Invalid)
        assertEquals(PdfReadingStateError.STALE_SOURCE, (decoded as PdfReadingStateResult.Invalid).error)
    }

    @Test
    fun malformedAndUnknownVersionAreRejected() {
        assertTrue(
            PdfReadingStateCodec.decode("not a state", sha) is PdfReadingStateResult.Invalid,
        )
        val encoded = PdfReadingStateCodec.encode(state()).replace("version=1", "version=9")
        val decoded = PdfReadingStateCodec.decode(encoded, sha)
        assertEquals(
            PdfReadingStateError.UNSUPPORTED_VERSION,
            (decoded as PdfReadingStateResult.Invalid).error,
        )
    }

    @Test
    fun outOfRangePositionIsRejected() {
        val broken = PdfReadingStateCodec.encode(state()).replace("position=4|1.75|0.25|0.9", "position=4|99|0.25|0.9")
        val decoded = PdfReadingStateCodec.decode(broken, sha)
        assertEquals(
            PdfReadingStateError.OUT_OF_BOUNDS,
            (decoded as PdfReadingStateResult.Invalid).error,
        )
    }

    @Test
    fun noPositionAndNoBookmarksStillRoundTrips() {
        val empty = PdfReadingState(sha, null, emptyList(), 0)
        val decoded = PdfReadingStateCodec.decode(PdfReadingStateCodec.encode(empty), sha)
        assertEquals(empty, (decoded as PdfReadingStateResult.Ok).state)
    }
}
