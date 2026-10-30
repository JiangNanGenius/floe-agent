// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import java.io.ByteArrayOutputStream
import java.net.InetAddress

internal class DnsParseException(message: String) : Exception(message)

/**
 * Pure RFC 1035 wire codec for the phone DNS diagnostic. It builds one
 * question and parses bounded A/AAAA/CNAME answers (including compression) so
 * the platform resolver's bytes can be reported truthfully. No resolver and no
 * Android type lives here.
 */
internal object DnsWire {
    const val TYPE_A = 1
    const val TYPE_NS = 2
    const val TYPE_CNAME = 5
    const val TYPE_PTR = 12
    const val TYPE_TXT = 16
    const val TYPE_AAAA = 28
    const val TYPE_HTTPS = 65
    const val CLASS_IN = 1

    const val HEADER_BYTES = 12
    const val MAX_QUERY_BYTES = 512
    const val MAX_NAME_BYTES = 255
    const val MAX_POINTER_JUMPS = 64

    data class DnsRecord(
        val name: String,
        val type: Int,
        val typeName: String,
        val ttlSeconds: Long?,
        val value: String,
        val address: String?,
    )

    data class DnsResponse(
        val rcode: Int,
        val truncated: Boolean,
        val questionCount: Int,
        val answerCount: Int,
        val records: List<DnsRecord>,
    )

    fun encodeQuery(host: String, type: Int, id: Int): ByteArray {
        require(id in 0..65_535) { "DNS id out of range" }
        require(type == TYPE_A || type == TYPE_AAAA) { "unsupported DNS query type" }
        val name = NetworkTargetPolicy.normalizeHost(host)
        if (name.isEmpty() || name.contains(':')) {
            throw DnsParseException("DNS query requires a host name, not an address literal")
        }
        val labels = name.split('.')
        if (labels.size > 127) throw DnsParseException("DNS name has too many labels")
        val out = ByteArrayOutputStream(64)
        writeShort(out, id)
        writeShort(out, 0x0100) // recursion desired
        writeShort(out, 1) // QDCOUNT
        writeShort(out, 0) // ANCOUNT
        writeShort(out, 0) // NSCOUNT
        writeShort(out, 0) // ARCOUNT
        var encodedNameBytes = 0
        labels.forEach { label ->
            val bytes = label.toByteArray(Charsets.US_ASCII)
            if (bytes.isEmpty() || bytes.size > 63) throw DnsParseException("DNS label length is invalid")
            if (bytes.any { (it.toInt() and 0xFF) > 0x7F }) throw DnsParseException("DNS name must be ASCII")
            encodedNameBytes += 1 + bytes.size
            if (encodedNameBytes > MAX_NAME_BYTES) throw DnsParseException("DNS name is too long")
            out.write(bytes.size)
            out.write(bytes)
        }
        out.write(0)
        writeShort(out, type)
        writeShort(out, CLASS_IN)
        val query = out.toByteArray()
        if (query.size > MAX_QUERY_BYTES) throw DnsParseException("DNS query is too large")
        return query
    }

    fun parseResponse(packet: ByteArray, expectedId: Int): DnsResponse {
        if (packet.size < HEADER_BYTES) throw DnsParseException("DNS response is shorter than its header")
        if (packet.size > NetworkLimits.MAX_DNS_RESPONSE_BYTES) {
            throw DnsParseException("DNS response exceeds the 4096-byte diagnostic bound")
        }
        val id = u16(packet, 0)
        if (id != expectedId) throw DnsParseException("DNS response id does not match the query")
        val flags = u16(packet, 2)
        val questionCount = u16(packet, 4)
        val answerCount = u16(packet, 6)
        val tc = flags and 0x0200 != 0
        val rcode = flags and 0x000F
        var cursor = HEADER_BYTES
        repeat(questionCount) {
            val question = readName(packet, cursor)
            cursor = question.next
            if (cursor + 4 > packet.size) throw DnsParseException("DNS question is truncated")
            cursor += 4
        }
        val records = ArrayList<DnsRecord>()
        var parsedAnswers = 0
        while (parsedAnswers < answerCount && records.size < NetworkLimits.MAX_DNS_RECORDS) {
            val answerName = readName(packet, cursor)
            cursor = answerName.next
            if (cursor + 10 > packet.size) throw DnsParseException("DNS answer header is truncated")
            val type = u16(packet, cursor)
            val klass = u16(packet, cursor + 2)
            val ttl = u32(packet, cursor + 4)
            val rdLength = u16(packet, cursor + 8)
            cursor += 10
            if (cursor + rdLength > packet.size) throw DnsParseException("DNS answer data is truncated")
            if (klass == CLASS_IN) {
                val address = when (type) {
                    TYPE_A -> if (rdLength == 4) ipv4(packet, cursor) else null
                    TYPE_AAAA -> if (rdLength == 16) ipv6(packet, cursor) else null
                    else -> null
                }
                val value = when (type) {
                    TYPE_A, TYPE_AAAA -> address.orEmpty()
                    TYPE_CNAME, TYPE_NS, TYPE_PTR -> readName(packet, cursor).name
                    else -> ""
                }
                records += DnsRecord(
                    name = answerName.name,
                    type = type,
                    typeName = typeName(type),
                    ttlSeconds = ttl,
                    value = value,
                    address = address,
                )
            }
            cursor += rdLength
            parsedAnswers++
        }
        return DnsResponse(
            rcode = rcode,
            truncated = tc || answerCount > parsedAnswers,
            questionCount = questionCount,
            answerCount = answerCount,
            records = records,
        )
    }

    fun rcodeName(rcode: Int): String = when (rcode) {
        0 -> "NOERROR"
        1 -> "FORMERR"
        2 -> "SERVFAIL"
        3 -> "NXDOMAIN"
        4 -> "NOTIMP"
        5 -> "REFUSED"
        else -> "RCODE_$rcode"
    }

    fun typeName(type: Int): String = when (type) {
        TYPE_A -> "A"
        TYPE_NS -> "NS"
        TYPE_CNAME -> "CNAME"
        TYPE_PTR -> "PTR"
        TYPE_TXT -> "TXT"
        TYPE_AAAA -> "AAAA"
        TYPE_HTTPS -> "HTTPS"
        else -> "TYPE_$type"
    }

    private data class ParsedName(val name: String, val next: Int)

    private fun readName(packet: ByteArray, start: Int): ParsedName {
        var cursor = start
        var next = -1
        var jumps = 0
        var bytesUsed = 0
        val labels = ArrayList<String>()
        while (true) {
            if (cursor >= packet.size) throw DnsParseException("DNS name is truncated")
            val length = packet[cursor].toInt() and 0xFF
            if (length == 0) {
                cursor++
                if (next < 0) next = cursor
                break
            }
            if (length and 0xC0 == 0xC0) {
                if (cursor + 1 >= packet.size) throw DnsParseException("DNS compression pointer is truncated")
                val pointer = ((length and 0x3F) shl 8) or (packet[cursor + 1].toInt() and 0xFF)
                if (next < 0) next = cursor + 2
                if (pointer >= packet.size) throw DnsParseException("DNS compression pointer is outside the packet")
                jumps++
                if (jumps > MAX_POINTER_JUMPS) throw DnsParseException("DNS compression pointer loop")
                cursor = pointer
                continue
            }
            if (length and 0xC0 != 0) throw DnsParseException("DNS label uses a reserved length form")
            if (length > 63 || cursor + 1 + length > packet.size) {
                throw DnsParseException("DNS label is truncated")
            }
            var text = ""
            for (index in 0 until length) {
                val value = packet[cursor + 1 + index].toInt() and 0xFF
                if (value > 0x7F) throw DnsParseException("DNS label is not ASCII")
                text += value.toChar()
            }
            bytesUsed += length + 1
            if (bytesUsed > MAX_NAME_BYTES) throw DnsParseException("DNS name is too long")
            labels += text
            cursor += 1 + length
        }
        if (labels.isEmpty()) throw DnsParseException("DNS name is empty")
        return ParsedName(labels.joinToString("."), next)
    }

    private fun ipv4(packet: ByteArray, offset: Int): String =
        "${packet[offset].toInt() and 0xFF}.${packet[offset + 1].toInt() and 0xFF}." +
            "${packet[offset + 2].toInt() and 0xFF}.${packet[offset + 3].toInt() and 0xFF}"

    private fun ipv6(packet: ByteArray, offset: Int): String = try {
        InetAddress.getByAddress(packet.copyOfRange(offset, offset + 16)).hostAddress.orEmpty()
    } catch (_: Exception) {
        ""
    }

    private fun u16(packet: ByteArray, offset: Int): Int =
        ((packet[offset].toInt() and 0xFF) shl 8) or (packet[offset + 1].toInt() and 0xFF)

    private fun u32(packet: ByteArray, offset: Int): Long =
        ((packet[offset].toLong() and 0xFF) shl 24) or
            ((packet[offset + 1].toLong() and 0xFF) shl 16) or
            ((packet[offset + 2].toLong() and 0xFF) shl 8) or
            (packet[offset + 3].toLong() and 0xFF)

    private fun writeShort(out: ByteArrayOutputStream, value: Int) {
        out.write((value shr 8) and 0xFF)
        out.write(value and 0xFF)
    }
}
