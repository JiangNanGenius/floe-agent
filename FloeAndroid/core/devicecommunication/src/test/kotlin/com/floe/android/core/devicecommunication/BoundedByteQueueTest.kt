// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.devicecommunication

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class BoundedByteQueueTest {
    @Test
    fun `overflow drops oldest bytes and keeps the bound`() {
        val queue = BoundedByteQueue(8)
        queue.append(byteArrayOf(1, 2, 3, 4, 5, 6))
        val dropped = queue.append(byteArrayOf(7, 8, 9, 10, 11, 12))
        assertEquals(4, dropped)
        assertEquals(8, queue.bufferedBytes)
        assertArrayEquals(
            byteArrayOf(5, 6, 7, 8, 9, 10, 11, 12),
            queue.drain(100),
        )
        val stats = queue.stats()
        assertEquals(12L, stats.totalBytes)
        assertEquals(4L, stats.droppedBytes)
    }

    @Test
    fun `oversized append keeps only the tail`() {
        val queue = BoundedByteQueue(4)
        queue.append(byteArrayOf(1, 2, 3, 4))
        val dropped = queue.append(byteArrayOf(5, 6, 7, 8, 9, 10))
        assertEquals(6, dropped)
        assertArrayEquals(byteArrayOf(7, 8, 9, 10), queue.drain(4))
    }

    @Test
    fun `drain honours max bytes and preserves order`() {
        val queue = BoundedByteQueue(16)
        queue.append(byteArrayOf(1, 2, 3, 4, 5))
        assertArrayEquals(byteArrayOf(1, 2), queue.drain(2))
        assertArrayEquals(byteArrayOf(3, 4, 5), queue.drain(10))
        assertEquals(0, queue.bufferedBytes)
    }

    @Test
    fun `clear requires a bounded capacity`() {
        val queue = BoundedByteQueue(8)
        queue.append(byteArrayOf(1, 2, 3))
        assertEquals(3, queue.clear())
        assertEquals(0, queue.bufferedBytes)
    }
}
