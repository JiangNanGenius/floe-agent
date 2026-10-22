// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.supervision

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** Bounded retention and truthful paging gaps. */
class BoundedOutputRingTest {

    private fun bytes(vararg values: Int) = ByteArray(values.size) { values[it].toByte() }

    @Test
    fun appendsWithinCapacityAreFullyRetained() {
        val ring = BoundedOutputRing(1024)
        ring.append(bytes(1, 2, 3, 4, 5))

        assertEquals(5L, ring.totalProducedBytes)
        assertEquals(0L, ring.totalDroppedBytes)
        val page = ring.read(0, 64)
        assertTrue(page.bytes.contentEquals(bytes(1, 2, 3, 4, 5)))
        assertEquals(5L, page.nextCursor)
        assertEquals(0L, page.gapBytes)
        assertTrue(!page.truncatedMore)
    }

    @Test
    fun overflowDropsTheOldestBytesAndReportsTheGap() {
        val ring = BoundedOutputRing(1024)
        val produced = ByteArray(1500) { (it % 251).toByte() }
        ring.append(produced)

        assertEquals(1500L, ring.totalProducedBytes)
        assertEquals(1024, ring.retainedBytes)
        assertEquals(476L, ring.totalDroppedBytes)
        assertEquals(476L, ring.firstRetainedCursor)

        // A consumer that still believes it is at offset 0 learns exactly what it missed.
        val page = ring.read(0, BoundedOutputRing.MAX_PAGE_BYTES)
        assertEquals(476L, page.gapBytes)
        assertEquals(1024, page.bytes.size)
        assertEquals(1500L, page.nextCursor)
        assertTrue(page.bytes.contentEquals(produced.copyOfRange(476, 1500)))
    }

    @Test
    fun singleChunkLargerThanTheWindowKeepsTheNewestTail() {
        val ring = BoundedOutputRing(1024)
        val produced = ByteArray(4096) { it.toByte() }
        val accepted = ring.append(produced)

        assertEquals(1024, accepted)
        assertEquals(3072L, ring.totalDroppedBytes)
        val page = ring.read(ring.firstRetainedCursor, 2048)
        assertTrue(page.bytes.contentEquals(produced.copyOfRange(3072, 4096)))
    }

    @Test
    fun pagingCursorWalksTheRetainedTailInBoundedPages() {
        val ring = BoundedOutputRing(1024)
        ring.append(ByteArray(2000) { (it % 97).toByte() })

        var cursor = ring.firstRetainedCursor
        val collected = mutableListOf<Byte>()
        var pages = 0
        while (true) {
            val page = ring.read(cursor, 300)
            pages++
            collected += page.bytes.toList()
            cursor = page.nextCursor
            if (!page.truncatedMore) break
        }
        assertEquals(1024, collected.size)
        assertEquals(4, pages) // 300+300+300+124
        assertEquals(
            (0 until 1024).map { (((2000 - 1024) + it) % 97).toByte() },
            collected,
        )
    }

    @Test
    fun cursorAheadOfTheStreamAndOversizedPagesAreRefused() {
        val ring = BoundedOutputRing(1024)
        ring.append(bytes(1, 2, 3))

        assertThrows(IllegalArgumentException::class.java) { ring.read(4, 16) }
        assertThrows(IllegalArgumentException::class.java) { ring.read(-1, 16) }
        assertThrows(IllegalArgumentException::class.java) { ring.read(0, BoundedOutputRing.MAX_PAGE_BYTES + 1) }
        assertThrows(IllegalArgumentException::class.java) { BoundedOutputRing(16) }
    }

    @Test
    fun offsetAndLengthRangeIsValidated() {
        val ring = BoundedOutputRing(1024)
        assertThrows(IllegalArgumentException::class.java) { ring.append(bytes(1, 2), offset = 1, length = 5) }
    }
}
