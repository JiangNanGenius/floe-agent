// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.resolver

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress

/**
 * The frozen `floe-guest-dns-v1` frame semantics (header, bounds, refusal)
 * plus the API-28 system-answer builder, proven on the host JVM without
 * any device.
 */
class GuestDnsWireTest {

    private fun query(id: Int, name: String, type: Int): ByteArray {
        val labels = name.split('.').toTypedArray()
        val size = 12 + labels.sumOf { it.length + 1 } + 1 + 4
        val out = ByteArray(size)
        out[0] = ((id shr 8) and 0xFF).toByte(); out[1] = (id and 0xFF).toByte()
        out[2] = 0x01; out[5] = 1
        var cursor = 12
        for (label in labels) {
            out[cursor] = label.length.toByte(); cursor++
            label.toByteArray(Charsets.US_ASCII).copyInto(out, cursor); cursor += label.length
        }
        out[cursor] = 0; cursor++
        out[cursor] = ((type shr 8) and 0xFF).toByte(); out[cursor + 1] = (type and 0xFF).toByte()
        out[cursor + 2] = 0; out[cursor + 3] = 1
        return out
    }

    @Test
    fun frameRoundTrip() {
        val dns = query(0x1234, "a.example.com", 1)
        val frame = GuestDnsWire.encodeFrame(dns)
        assertEquals(GuestDnsWire.MAGIC[0], frame[0])
        assertEquals(dns.size, ((frame[4].toInt() and 0xFF) shl 8) or (frame[5].toInt() and 0xFF))
        when (val decoded = GuestDnsWire.decodeHeader(frame.copyOfRange(0, 6))) {
            is GuestDnsWire.HeaderResult.Ok -> assertEquals(dns.size, decoded.dnsLength)
            else -> error("valid header rejected")
        }
    }

    @Test
    fun boundsAndMagicRefusals() {
        assertTrue(GuestDnsWire.decodeHeader(byteArrayOf('X'.code.toByte(), 'Y'.code.toByte(),
            'Z'.code.toByte(), 'W'.code.toByte(), 0, 12)) is GuestDnsWire.HeaderResult.BadMagic)
        // Declared length 11 (below DNS_MIN)
        assertTrue(GuestDnsWire.decodeHeader(byteArrayOf(0x46, 0x44, 0x4E, 0x31, 0, 11))
            is GuestDnsWire.HeaderResult.BadSize)
        // Declared 4097 (above DNS_MAX via u16 0x1001)
        assertTrue(GuestDnsWire.decodeHeader(byteArrayOf(0x46, 0x44, 0x4E, 0x31, 0x10, 0x01))
            is GuestDnsWire.HeaderResult.BadSize)
        runCatching { GuestDnsWire.encodeFrame(ByteArray(4097)) }
            .onSuccess { error("oversized frame encoded") }
    }

    @Test
    fun questionParseAcceptsOnlySingleInQuestion() {
        val q = query(7, "floe-dns-probe.invalid", 28)
        val parsed = GuestDnsWire.parseQuestion(q)
        assertNotNull(parsed)
        assertEquals("floe-dns-probe.invalid", parsed!!.name)
        assertEquals(28, parsed.type)
        // Two questions: refused
        val evil = q.copyOf(q.size + 4)
        evil[5] = 2
        assertNull(GuestDnsWire.parseQuestion(evil))
    }

    @Test
    fun api28AnswerBuildIsWireCorrect() {
        val q = query(0x4646, "agent.floe.test", 1)
        val addresses = listOf<InetAddress>(
            InetAddress.getByAddress(byteArrayOf(203.toByte(), 0, 113, 42)),
        )
        val response = GuestDnsWire.buildResponseFromAddresses(q, addresses, 60, 0, true)
        val parsedHeaderId = ((response[0].toInt() and 0xFF) shl 8) or (response[1].toInt() and 0xFF)
        assertEquals(0x4646, parsedHeaderId)
        assertEquals(0x81.toByte(), response[2]) // QR (+ RD kept 1)
        assertEquals(0x80.toByte(), response[3]) // RA, rcode 0
        assertEquals(1, ((response[6].toInt() and 0xFF) shl 8) or (response[7].toInt() and 0xFF))
        val questionEnd = GuestDnsWire.parseQuestion(q)!!.questionEnd
        // Answer starts right after question: name pointer 0xC00C, type A
        assertEquals(0xC0.toByte(), response[questionEnd])
        assertEquals(0x0C.toByte(), response[questionEnd + 1])
        assertEquals(0.toByte(), response[questionEnd + 2])
        assertEquals(1.toByte(), response[questionEnd + 3])
        // rdlen 4 and address bytes
        assertEquals(0.toByte(), response[questionEnd + 10])
        assertEquals(4.toByte(), response[questionEnd + 11])
        assertEquals(203.toByte(), response[questionEnd + 12])
        assertEquals(42.toByte(), response[questionEnd + 15])
    }

    @Test
    fun familyMismatchAnswersEmptyAndUnknownTypeNotimp() {
        val q = query(9, "v6.only.test", 28)
        val v4Only = listOf<InetAddress>(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)))
        val empty = GuestDnsWire.buildResponseFromAddresses(q, v4Only, 60, 0, true)
        assertEquals(0, ((empty[6].toInt() and 0xFF) shl 8) or (empty[7].toInt() and 0xFF))
        assertEquals(0, empty[3].toInt() and 0x0F) // NOERROR NODATA, not a lie

        val mx = query(10, "mx.test", 15) // MX not answerable by system address APIs
        val notimp = GuestDnsWire.buildResponseFromAddresses(mx, v4Only, 60, 0, true)
        assertEquals(GuestDnsWire.NOTIMP, notimp[3].toInt() and 0x0F)
    }

    @Test
    fun rcodeOnlyResponsesPreserveIdAndQuestionAndZeroCounts() {
        val q = query(0x2A2B, "offline.test", 1)
        val servfail = GuestDnsWire.buildRcodeOnly(q, GuestDnsWire.SERVFAIL)
        assertEquals(0x2A, servfail[0].toInt() and 0xFF)
        assertEquals(0x2B, servfail[1].toInt() and 0xFF)
        assertEquals(0x80.toByte(), (servfail[2].toInt() and 0x80).toByte()) // QR
        assertEquals(GuestDnsWire.SERVFAIL, servfail[3].toInt() and 0x0F)
        for (offset in 6..11) assertEquals(0, servfail[offset].toInt())
        assertEquals(q.size, servfail.size) // question echoed within budget
    }

    @Test
    fun streamHelpersAreBoundedAndEofHonest() {
        val data = ByteArray(20) { (it % 7).toByte() }
        val out = ByteArrayOutputStream()
        GuestDnsWire.writeFrame(out, data.copyOfRange(0, 12))
        val encoded = out.toByteArray()
        assertEquals(6 + 12, encoded.size)
        val read = ByteArray(6)
        GuestDnsWire.readFully(ByteArrayInputStream(encoded), read, 6)
        assertTrue(GuestDnsWire.decodeHeader(read) is GuestDnsWire.HeaderResult.Ok)
        runCatching { GuestDnsWire.readFully(ByteArrayInputStream(ByteArray(3)), read, 6) }
            .onSuccess { error("EOF not surfaced") }
    }
}
