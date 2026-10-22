// SPDX-License-Identifier: MPL-2.0
//
// Pure wire codec for the frozen Floe guest system DNS bridge v1
// (FloeAndroid/core/linuxruntime/native-build/guest-resolver/PROTOCOL.json):
//   request/response frame = "FDN1" magic (4) + u16BE DNS length + DNS
//   message, exactly one transaction per connection, DNS length 12..4096.
// No Android types: this is the shared, JVM-testable contract surface the
// Kotlin handler uses (the guest helper's C twin is owned by the
// native-build/guest-resolver lane).
package com.floe.android.linuxruntime.resolver

import java.io.EOFException
import java.io.InputStream
import java.io.OutputStream
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress

object GuestDnsWire {
    val MAGIC = byteArrayOf(0x46, 0x44, 0x4E, 0x31) // "FDN1"
    const val HEADER_BYTES = 6
    const val DNS_MIN = 12
    const val DNS_MAX = 4096

    sealed class HeaderResult {
        class Ok(val dnsLength: Int) : HeaderResult()
        object BadMagic : HeaderResult()
        class BadSize(val declared: Int) : HeaderResult()
    }

    fun decodeHeader(header: ByteArray): HeaderResult {
        if (header.size < HEADER_BYTES) return HeaderResult.BadMagic
        for (i in 0 until 4) if (header[i] != MAGIC[i]) return HeaderResult.BadMagic
        val declared = ((header[4].toInt() and 0xFF) shl 8) or (header[5].toInt() and 0xFF)
        if (declared < DNS_MIN || declared > DNS_MAX) return HeaderResult.BadSize(declared)
        return HeaderResult.Ok(declared)
    }

    fun encodeFrame(dnsMessage: ByteArray): ByteArray {
        require(dnsMessage.size in DNS_MIN..DNS_MAX) { "dns frame length invalid" }
        val out = ByteArray(HEADER_BYTES + dnsMessage.size)
        MAGIC.copyInto(out, 0)
        out[4] = ((dnsMessage.size shr 8) and 0xFF).toByte()
        out[5] = (dnsMessage.size and 0xFF).toByte()
        dnsMessage.copyInto(out, HEADER_BYTES)
        return out
    }

    /** Bounded stream helpers (never allocate beyond the frame budget). */
    fun readFully(stream: InputStream, buffer: ByteArray, length: Int): Int {
        var done = 0
        while (done < length) {
            val read = stream.read(buffer, done, length - done)
            if (read < 0) throw EOFException("stream ended mid-frame")
            done += read
        }
        return done
    }

    fun writeFrame(stream: OutputStream, dnsMessage: ByteArray) {
        val frame = encodeFrame(dnsMessage)
        stream.write(frame)
        stream.flush()
    }

    data class Question(val name: String, val type: Int, val questionEnd: Int)

    /** Minimal RFC1035 question parse: returns null for anything malformed
     *  (never trusts the payload further). Labels must be ASCII; compression
     *  in the question section is invalid by the same standard. */
    fun parseQuestion(dns: ByteArray): Question? {
        if (dns.size < DNS_MIN) return null
        if (dns[4].toInt() != 0 || dns[5].toInt() != 1) return null // exactly one question
        var cursor = 12
        val labels = ArrayList<String>()
        while (cursor < dns.size) {
            val length = dns[cursor].toInt() and 0xFF
            if (length == 0) { cursor++; break }
            if (length and 0xC0 != 0 || cursor + 1 + length > dns.size) return null
            var text = ""
            for (i in 0 until length) {
                val c = dns[cursor + 1 + i].toInt() and 0xFF
                if (c > 0x7F) return null
                text += c.toChar()
            }
            labels.add(text)
            cursor += 1 + length
        }
        if (cursor + 4 > dns.size || labels.isEmpty()) return null
        val qtype = ((dns[cursor].toInt() and 0xFF) shl 8) or (dns[cursor + 1].toInt() and 0xFF)
        val qclass = ((dns[cursor + 2].toInt() and 0xFF) shl 8) or (dns[cursor + 3].toInt() and 0xFF)
        if (qclass != 1) return null // IN only
        val end = cursor + 4
        return Question(labels.joinToString("."), qtype, end)
    }

    /** Response from system-provided addresses (the API 28 path, and the
     *  rcode passthrough shape). Copies the question bytes verbatim, then
     *  answers with 0xC00C name pointers. Bounded: max 8 records and never
     *  exceeds DNS_MAX (extra records are dropped honestly). */
    fun buildResponseFromAddresses(query: ByteArray, addresses: List<InetAddress>, ttlSeconds: Int,
                                   rcode: Int, recursionAvailable: Boolean): ByteArray {
        val question = parseQuestion(query)
        val qdEnd = question?.questionEnd ?: run {
            return buildRcodeOnly(query, SERVFAIL)
        }
        val wantedType = question.type
        val recordSize = when (wantedType) {
            28 -> 16
            1 -> 4
            else -> return buildRcodeOnly(query, NOTIMP)
        }
        val answers = addresses.asSequence().filter { address ->
            if (wantedType == 1) address is Inet4Address else address is Inet6Address
        }.take(8).toList()
        val totalSize = HEADER_BYTES_BYTES + (qdEnd - 12) + answers.size * (2 + 10 + recordSize)
        if (totalSize > DNS_MAX) {
            val truncatedCount = maxOf(0, (DNS_MAX - HEADER_BYTES_BYTES - (qdEnd - 12)) / (2 + 10 + recordSize))
            return buildResponseFromAddressesInternal(query, qdEnd, answers.take(truncatedCount),
                ttlSeconds, rcode, recursionAvailable, truncated = truncatedCount < answers.size)
        }
        return buildResponseFromAddressesInternal(query, qdEnd, answers, ttlSeconds, rcode,
            recursionAvailable, truncated = false)
    }

    private const val HEADER_BYTES_BYTES = 12

    private fun buildResponseFromAddressesInternal(query: ByteArray, questionEnd: Int,
                                                   answers: List<InetAddress>, ttlSeconds: Int,
                                                   rcode: Int, recursionAvailable: Boolean,
                                                   truncated: Boolean): ByteArray {
        val firstType = if (answers.firstOrNull() is Inet6Address) 28 else 1
        val recordSize = if (firstType == 28) 16 else 4
        val sectionBytes = answers.size * (2 + 10 + recordSize)
        val out = ByteArray(12 + (questionEnd - 12) + sectionBytes)
        query.copyInto(out, 0, 0, questionEnd)
        out[2] = ((0x80 or (query[2].toInt() and 0x7F)) or (if (truncated) 0x02 else 0)).toByte() // QR|TC
        out[3] = ((if (recursionAvailable) 0x80 else 0) or (rcode and 0x0F)).toByte()
        out[6] = ((answers.size shr 8) and 0xFF).toByte(); out[7] = (answers.size and 0xFF).toByte()
        out[8] = 0; out[9] = 0; out[10] = 0; out[11] = 0
        var cursor = questionEnd
        for (address in answers) {
            out[cursor] = 0xC0.toByte(); out[cursor + 1] = 0x0C // pointer to question name
            val type = if (address is Inet6Address) 28 else 1
            out[cursor + 2] = ((type shr 8) and 0xFF).toByte(); out[cursor + 3] = (type and 0xFF).toByte()
            out[cursor + 4] = 0; out[cursor + 5] = 1 // CLASS IN
            out[cursor + 6] = ((ttlSeconds shr 24) and 0xFF).toByte()
            out[cursor + 7] = ((ttlSeconds shr 16) and 0xFF).toByte()
            out[cursor + 8] = ((ttlSeconds shr 8) and 0xFF).toByte()
            out[cursor + 9] = (ttlSeconds and 0xFF).toByte()
            out[cursor + 10] = 0
            out[cursor + 11] = recordSize.toByte()
            address.address.copyInto(out, cursor + 12)
            cursor += 12 + recordSize
        }
        return out
    }

    const val NOERROR = 0
    const val NXDOMAIN = 3
    const val SERVFAIL = 2
    const val REFUSED = 5
    const val NOTIMP = 4

    /** rcode-only honest response: keep the question section, zero counts. */
    fun buildRcodeOnly(query: ByteArray, rcode: Int): ByteArray {
        val size = minOf(query.size, DNS_MAX)
        if (size < 12) return ByteArray(0)
        val out = query.copyOf(size)
        if (size > 12) {
            // Keep only the header + first question when the original had
            // more sections; malformed extras never get echoed back.
            val question = parseQuestion(query)
            if (question != null && question.questionEnd <= size) {
                out[4] = 0; out[5] = 1
                var cursor = question.questionEnd
                while (cursor < size) { out[cursor] = 0; cursor++ }
            }
        }
        out[2] = (out[2].toInt() or 0x80).toByte() // QR=1, keep opcode/RD
        out[3] = (rcode and 0x0F).toByte()
        out[6] = 0; out[7] = 0; out[8] = 0; out[9] = 0; out[10] = 0; out[11] = 0
        return out
    }
}
