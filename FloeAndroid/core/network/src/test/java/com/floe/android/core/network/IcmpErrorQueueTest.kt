// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import org.junit.Assert.*
import org.junit.Test
import java.io.IOException

class IcmpErrorQueueTest {
    private val target = byteArrayOf(1, 1, 1, 1)
    private fun frame(type: Int = 11, code: Int = 0) = ByteArray(20).apply {
        this[0] = 1; this[1] = 1; this[2] = type.toByte(); this[3] = code.toByte()
        byteArrayOf(192.toByte(), 0, 2, 1).copyInto(this, 8)
        target.copyInto(this, 12)
        this[16] = 0x12; this[17] = 0x34; this[18] = 0; this[19] = 7
    }
    @Test fun minimumQuoteNeedsNoEchoPayloadToken() {
        val hop = IcmpErrorQueue.parse(frame(), target, 0x1234, 7)!!
        assertEquals("192.0.2.1", hop.address)
        assertEquals(11, hop.type)
    }
    @Test fun actualDestinationIdentifierAndSequenceMustAllMatch() {
        assertNull(IcmpErrorQueue.parse(frame(), byteArrayOf(1,1,1,2), 0x1234, 7))
        assertNull(IcmpErrorQueue.parse(frame(), target, 0x1235, 7))
        assertNull(IcmpErrorQueue.parse(frame(), target, 0x1234, 8))
        assertNull(IcmpErrorQueue.parse(frame(), target, 0, 7))
    }
    @Test fun acceptsOnlyHopTimeExceededAndBoundedUnreachable() {
        assertNotNull(IcmpErrorQueue.parse(frame(3, 13), target, 0x1234, 7))
        assertNull(IcmpErrorQueue.parse(frame(11, 1), target, 0x1234, 7))
        assertNull(IcmpErrorQueue.parse(frame(3, 255), target, 0x1234, 7))
        assertNull(IcmpErrorQueue.parse(frame(0, 0), target, 0x1234, 7))
    }
    @Test fun rejectsMalformedWireAndUnattributedRouter() {
        assertNull(IcmpErrorQueue.parse(frame().copyOf(19), target, 0x1234, 7))
        assertNull(IcmpErrorQueue.parse(frame().apply { this[0] = 2 }, target, 0x1234, 7))
        assertNull(IcmpErrorQueue.parse(frame().apply { fill(0, 8, 12) }, target, 0x1234, 7))
        assertNull(IcmpErrorQueue.parse(frame().apply { this[8] = 224.toByte() }, target, 0x1234, 7))
    }
    @Test(expected = IOException::class) fun receiveFailureIsNotAFilteredHop() {
        IcmpErrorQueue.parse(frame().apply { this[1] = 2 }, target, 0x1234, 7)
    }
}
