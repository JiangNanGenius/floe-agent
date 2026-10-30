// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class IcmpPacketTest {
    @Test
    fun buildsAValidEchoRequest() {
        val packet = IcmpPacket.buildEchoRequest(7, 123_456_789L, 0x11223344)
        assertEquals(IcmpPacket.PACKET_BYTES, packet.size)
        assertEquals(IcmpPacket.TYPE_ECHO_REQUEST, packet[0].toInt() and 0xFF)
        assertEquals(7, packet[7].toInt() and 0xFF)
        assertTrue(IcmpPacket.verifyChecksum(packet))
    }

    @Test
    fun parsesMatchingReplyWithRttTimestampAndToken() {
        val request = IcmpPacket.buildEchoRequest(9, 987_654_321L, 0x0A0B0C0D)
        val reply = request.copyOf().apply {
            this[0] = IcmpPacket.TYPE_ECHO_REPLY.toByte()
            this[2] = 0
            this[3] = 0
            val checksum = IcmpPacket.checksum(this)
            this[2] = ((checksum shr 8) and 0xFF).toByte()
            this[3] = (checksum and 0xFF).toByte()
        }
        val parsed = IcmpPacket.parseEchoReply(reply, 9, 0x0A0B0C0D)
        assertNotNull(parsed)
        assertEquals(9, parsed!!.sequence)
        assertEquals(987_654_321L, parsed.timestampNanos)
    }

    @Test
    fun rejectsWrongSequenceWrongTokenAndCorruptChecksum() {
        val request = IcmpPacket.buildEchoRequest(3, 100L, 0x01020304)
        val reply = request.copyOf().apply {
            this[0] = IcmpPacket.TYPE_ECHO_REPLY.toByte()
            this[2] = 0
            this[3] = 0
            val checksum = IcmpPacket.checksum(this)
            this[2] = ((checksum shr 8) and 0xFF).toByte()
            this[3] = (checksum and 0xFF).toByte()
        }
        assertNull(IcmpPacket.parseEchoReply(reply, 4, 0x01020304))
        assertNull(IcmpPacket.parseEchoReply(reply, 3, 0x05060708))
        val corrupt = reply.copyOf().apply { this[2] = (this[2] + 1).toByte() }
        assertNull(IcmpPacket.parseEchoReply(corrupt, 3, 0x01020304))
        assertNull(IcmpPacket.parseEchoReply(reply.copyOf(8), 3, 0x01020304))
    }

    @Test
    fun checksumRejectsChangesAndAcceptsOddLength() {
        val bytes = byteArrayOf(0, 1, 2, 3, 4)
        val sum = IcmpPacket.checksum(bytes)
        assertTrue(sum in 0..0xFFFF)
        val packet = ByteArray(8)
        packet[0] = 8
        packet[4] = 1
        packet[5] = 2
        val checksum = IcmpPacket.checksum(packet)
        packet[2] = ((checksum shr 8) and 0xFF).toByte()
        packet[3] = (checksum and 0xFF).toByte()
        assertTrue(IcmpPacket.verifyChecksum(packet))
    }

    @Test
    fun rejectsOutOfRangeSequence() {
        try {
            IcmpPacket.buildEchoRequest(65_536, 1L, 2)
            fail("sequence must be a u16")
        } catch (_: IllegalArgumentException) {
            // expected
        }
    }
}
