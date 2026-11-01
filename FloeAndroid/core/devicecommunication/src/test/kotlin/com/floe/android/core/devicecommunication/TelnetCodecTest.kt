// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.devicecommunication

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TelnetCodecTest {
    @Test
    fun `escaped IAC is restored once`() {
        val codec = TelnetCodec()
        val result = codec.feed(byteArrayOf(1, 255.toByte(), 255.toByte(), 2))
        assertArrayEquals(byteArrayOf(1, 255.toByte(), 2), result.application)
        assertEquals(1, codec.escapedFrames)
    }

    @Test
    fun `option negotiation split across reads does not leak IAC`() {
        val codec = TelnetCodec()
        val first = codec.feed(byteArrayOf(255.toByte(), 251.toByte()))
        assertTrue(first.application.isEmpty())
        assertTrue(first.replies.isEmpty())
        val second = codec.feed(byteArrayOf(1, 90))
        assertArrayEquals(byteArrayOf(1, 90), second.application)
        assertArrayEquals(byteArrayOf(255.toByte(), 254.toByte(), 1), second.replies)
    }

    @Test
    fun `DO is refused with WONT and WONT has no reply`() {
        val codec = TelnetCodec()
        val doResult = codec.feed(byteArrayOf(255.toByte(), 253.toByte(), 3))
        assertArrayEquals(byteArrayOf(255.toByte(), 252.toByte(), 3), doResult.replies)
        val wontResult = codec.feed(byteArrayOf(255.toByte(), 252.toByte(), 5))
        assertTrue(wontResult.replies.isEmpty())
    }

    @Test
    fun `subnegotiation is skipped and following text is preserved`() {
        val codec = TelnetCodec()
        val result = codec.feed(
            byteArrayOf(
                255.toByte(), 250.toByte(), 1, 2, 3,
                255.toByte(), 240.toByte(), 65, 66,
            ),
        )
        assertArrayEquals(byteArrayOf(65, 66), result.application)
        assertEquals(1, codec.skippedSubnegotiations)
    }

    @Test
    fun `overlong subnegotiation is dropped without unbounded growth`() {
        val codec = TelnetCodec()
        val prefix = byteArrayOf(255.toByte(), 250.toByte())
        val body = ByteArray(DeviceLimits.MAXIMUM_TELNET_SUBNEGOTIATION_BYTES + 8) { 7 }
        val suffix = byteArrayOf(255.toByte(), 240.toByte(), 88)
        val result = codec.feed(prefix + body + suffix)
        assertArrayEquals(byteArrayOf(88), result.application)
        assertTrue(result.truncatedSubnegotiation)
        assertEquals(0, codec.pendingSubnegotiations)
    }

    @Test
    fun `binary bytes are preserved exactly`() {
        val codec = TelnetCodec()
        val payload = ByteArray(255) { it.toByte() }
        val result = codec.feed(payload + 255.toByte())
        assertArrayEquals(payload, result.application)
        assertFalse(result.truncatedSubnegotiation)
    }
}
