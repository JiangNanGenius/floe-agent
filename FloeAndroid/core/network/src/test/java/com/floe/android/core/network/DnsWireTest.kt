// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import java.io.ByteArrayOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class DnsWireTest {
    @Test
    fun encodesOneQuestionWithExactTypeAndId() {
        val query = DnsWire.encodeQuery("example.com", DnsWire.TYPE_A, 0x1234)
        assertEquals(0x12, query[0].toInt() and 0xFF)
        assertEquals(0x34, query[1].toInt() and 0xFF)
        assertEquals(0x01, query[2].toInt() and 0xFF)
        assertEquals(0, query[3].toInt() and 0xFF)
        assertEquals(0, query[4].toInt() and 0xFF)
        assertEquals(1, query[5].toInt() and 0xFF)
        assertEquals(7, query[12].toInt() and 0xFF)
        assertEquals('e'.code, query[13].toInt() and 0xFF)
        assertEquals(0, query[24].toInt() and 0xFF)
        assertEquals(0, query[25].toInt() and 0xFF)
        assertEquals(1, query[26].toInt() and 0xFF)
        assertEquals(0, query[27].toInt() and 0xFF)
        assertEquals(1, query[28].toInt() and 0xFF)

        val aaaa = DnsWire.encodeQuery("example.com", DnsWire.TYPE_AAAA, 7)
        assertEquals(28, aaaa[26].toInt() and 0xFF)
    }

    @Test
    fun rejectsAddressLiteralsForDnsNames() {
        try {
            DnsWire.encodeQuery("::1", DnsWire.TYPE_A, 1)
            fail("an address literal is not a DNS name")
        } catch (_: DnsParseException) {
            // expected
        }
    }

    @Test
    fun parsesAAnswerWithTtlAndCompression() {
        val response = response(
            answers = listOf(rr(DnsWire.TYPE_A, 300, byteArrayOf(93, 184.toByte(), 216.toByte(), 34))),
        )
        val parsed = DnsWire.parseResponse(response, 0x1234)
        assertEquals(0, parsed.rcode)
        assertEquals(1, parsed.answerCount)
        assertEquals(1, parsed.records.size)
        assertEquals("example.com", parsed.records[0].name)
        assertEquals("A", parsed.records[0].typeName)
        assertEquals(300L, parsed.records[0].ttlSeconds)
        assertEquals("93.184.216.34", parsed.records[0].address)
    }

    @Test
    fun parsesCnameAndAaaaAnswers() {
        val cnameData = ByteArrayOutputStream().apply {
            write(3)
            write("www".toByteArray(Charsets.US_ASCII))
            write(0xC0)
            write(0x0C)
        }.toByteArray()
        val aaaa = byteArrayOf(
            0x20, 0x01, 0x0D, 0xB8.toByte(), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
        )
        val cnameResponse = response(
            answers = listOf(rr(DnsWire.TYPE_CNAME, 60, cnameData)),
        )
        val cname = DnsWire.parseResponse(cnameResponse, 0x1234)
        assertEquals("www.example.com", cname.records[0].value)

        val aaaaResponse = response(
            answers = listOf(rr(DnsWire.TYPE_AAAA, 120, aaaa)),
            questionType = DnsWire.TYPE_AAAA,
        )
        val parsed = DnsWire.parseResponse(aaaaResponse, 0x1234)
        assertEquals("AAAA", parsed.records[0].typeName)
        assertEquals("2001:db8:0:0:0:0:0:1", parsed.records[0].address)
    }

    @Test
    fun preservesUnsignedLargeTtl() {
        val response = response(
            answers = listOf(rr(DnsWire.TYPE_A, 4_294_967_295L, byteArrayOf(1, 2, 3, 4))),
        )
        val parsed = DnsWire.parseResponse(response, 0x1234)
        assertEquals(4_294_967_295L, parsed.records[0].ttlSeconds)
    }

    @Test
    fun reportsNxdomainAndTruncation() {
        val nxdomain = DnsWire.parseResponse(response(flags = 0x8183), 0x1234)
        assertEquals(3, nxdomain.rcode)
        assertEquals("NXDOMAIN", DnsWire.rcodeName(nxdomain.rcode))

        val truncated = DnsWire.parseResponse(response(flags = 0x8380), 0x1234)
        assertTrue(truncated.truncated)
    }

    @Test
    fun rejectsWrongIdAndShortOrMalformedPackets() {
        try {
            DnsWire.parseResponse(response(), 0x9999)
            fail("mismatched id must be rejected")
        } catch (_: DnsParseException) {
            // expected
        }
        try {
            DnsWire.parseResponse(byteArrayOf(0, 1, 0), 0x1234)
            fail("short packet must be rejected")
        } catch (_: DnsParseException) {
            // expected
        }

        val out = ByteArrayOutputStream()
        writeShort(out, 0x1234)
        writeShort(out, 0x8180)
        writeShort(out, 1)
        writeShort(out, 1)
        writeShort(out, 0)
        writeShort(out, 0)
        writeName(out, "example.com")
        writeShort(out, DnsWire.TYPE_A)
        writeShort(out, 1)
        val answerOffset = out.size()
        out.write(0xC0)
        out.write(answerOffset)
        out.write(0)
        out.write(1)
        out.write(0)
        out.write(1)
        out.write(0)
        out.write(0)
        out.write(0)
        out.write(0)
        out.write(0)
        out.write(4)
        out.write(1)
        out.write(1)
        out.write(1)
        out.write(1)
        try {
            DnsWire.parseResponse(out.toByteArray(), 0x1234)
            fail("compression loop must be rejected")
        } catch (_: DnsParseException) {
            // expected
        }
    }

    @Test
    fun capsLargeAnswerSetsHonestly() {
        val answers = (0 until 65).map { index ->
            rr(DnsWire.TYPE_A, 60, byteArrayOf(10, 0, 0, index.toByte()))
        }
        val parsed = DnsWire.parseResponse(response(answers = answers), 0x1234)
        assertEquals(NetworkLimits.MAX_DNS_RECORDS, parsed.records.size)
        assertTrue(parsed.truncated)
    }

    private fun response(
        id: Int = 0x1234,
        flags: Int = 0x8180,
        answers: List<ByteArray> = emptyList(),
        qname: String = "example.com",
        questionType: Int = DnsWire.TYPE_A,
    ): ByteArray {
        val out = ByteArrayOutputStream()
        writeShort(out, id)
        writeShort(out, flags)
        writeShort(out, 1)
        writeShort(out, answers.size)
        writeShort(out, 0)
        writeShort(out, 0)
        writeName(out, qname)
        writeShort(out, questionType)
        writeShort(out, 1)
        answers.forEach { out.write(it) }
        return out.toByteArray()
    }

    private fun rr(type: Int, ttl: Long, data: ByteArray): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(0xC0)
        out.write(0x0C)
        writeShort(out, type)
        writeShort(out, 1)
        out.write(((ttl shr 24) and 0xFF).toInt())
        out.write(((ttl shr 16) and 0xFF).toInt())
        out.write(((ttl shr 8) and 0xFF).toInt())
        out.write((ttl and 0xFF).toInt())
        writeShort(out, data.size)
        out.write(data)
        return out.toByteArray()
    }

    private fun writeName(out: ByteArrayOutputStream, name: String) {
        name.split('.').forEach { label ->
            val bytes = label.toByteArray(Charsets.US_ASCII)
            out.write(bytes.size)
            out.write(bytes)
        }
        out.write(0)
    }

    private fun writeShort(out: ByteArrayOutputStream, value: Int) {
        out.write((value shr 8) and 0xFF)
        out.write(value and 0xFF)
    }
}
