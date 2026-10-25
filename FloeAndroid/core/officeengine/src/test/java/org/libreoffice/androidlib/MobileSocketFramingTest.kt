package org.libreoffice.androidlib

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Wire-fidelity tests for the ProxySocket framing that the pinned 26.04
 * mobile dist (dist/global.js parseIncomingArray) consumes:
 * 'T'|'B' + "0x<hex serial>\n" + "0x<hex size>\n" + message + "\n".
 * Framing must stay byte-identical to upstream MobileSocket.java.
 */
class MobileSocketFramingTest {

    @Test
    fun textMessageFramesExactlyLikeUpstream() {
        val message = "status: shape: (1x1)".toByteArray()
        val header = ("T" + "0x" + Integer.toString(255, 16) + "\n" +
            "0x" + Integer.toString(message.size, 16) + "\n").toByteArray(Charsets.US_ASCII)
        val frame = MobileSocket.frame(255, message)
        assertEquals(header.size + message.size + 1, frame.size)
        assertEquals('T'.code.toByte(), frame[0])
        // Header bytes precede the exact payload and single terminator newline.
        assertTrue(frame.copyOfRange(0, header.size).contentEquals(header))
        assertTrue(frame.copyOfRange(header.size, header.size + message.size).contentEquals(message))
        assertEquals('\n'.code.toByte(), frame.last())
    }

    @Test
    fun binaryMessageIsMarkedWithB() {
        val message = "line1\nline2".toByteArray()
        val frame = MobileSocket.frame(1, message)
        assertEquals('B'.code.toByte(), frame[0])
        assertEquals('0'.code.toByte(), frame[1])
        assertEquals('x'.code.toByte(), frame[2])
        assertEquals('1'.code.toByte(), frame[3])
        assertEquals('\n'.code.toByte(), frame[4])
    }

    @Test
    fun emptyPayloadStillFrames() {
        val frame = MobileSocket.frame(16, ByteArray(0))
        // Upstream writes header, then the (empty) message, then terminator:
        // "T0x10\n0x0\n" + "" + "\n".
        assertEquals("T0x10\n0x0\n\n".toByteArray(Charsets.US_ASCII).toList(), frame.toList())
    }

    @Test
    fun sizeHexUsesMessageLengthNotFrameLength() {
        val message = ByteArray(300) // 0x12c; the full frame is 0x12c+12 bytes.
        val frame = MobileSocket.frame(1, message)
        val head = String(frame.copyOfRange(0, 11), Charsets.ISO_8859_1)
        assertEquals("T0x1\n0x12c\n", head)
        assertEquals(11 + message.size + 1, frame.size)
    }

    @Test
    fun newlineOnlyMessageIsBinary() {
        val frame = MobileSocket.frame(2, "\n".toByteArray())
        assertEquals('B'.code.toByte(), frame[0])
    }

    @Test
    fun serialFormatsHex() {
        val frame = MobileSocket.frame(2748, "x".toByteArray())
        assertTrue(String(frame, Charsets.ISO_8859_1).startsWith("T0xabc\n"))
    }
}
