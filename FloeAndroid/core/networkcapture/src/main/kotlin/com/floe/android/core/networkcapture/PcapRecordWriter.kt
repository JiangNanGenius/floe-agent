// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.networkcapture

import java.io.IOException
import java.io.OutputStream

enum class PcapLinkType(val value: Int) {
    /** Raw IPv4/IPv6 packet, exactly what a TUN fd returns. */
    RAW(101),
}

data class PcapWriteSummary(
    val linkType: PcapLinkType,
    val packets: Long,
    val bytes: Long,
    val truncatedPackets: Long,
    val limitReason: CaptureEndReason?,
    val closed: Boolean,
)

sealed interface PcapWriteOutcome {
    data class Written(val capturedBytes: Int, val truncated: Boolean) : PcapWriteOutcome
    data class LimitReached(val reason: CaptureEndReason) : PcapWriteOutcome
}

/**
 * Little-endian classic PCAP writer (LINKTYPE_RAW), bounded by total file
 * bytes and packet count. A record is written atomically or not at all; the
 * file therefore remains a valid (possibly short) capture at every point.
 *
 * The writer does not close the caller's stream. The artifact store owns
 * fsync/rename, and the bounded sink owns the background writer.
 */
class PcapRecordWriter(
    private val output: OutputStream,
    private val maxBytes: Long = CaptureLimits.MAX_BYTES,
    private val maxPackets: Long = CaptureLimits.MAX_PACKETS,
    private val snapLength: Int = CaptureLimits.SNAPLEN,
    private val nowEpochMicros: () -> Long = { System.currentTimeMillis() * 1_000L },
) {
    init {
        require(maxBytes > GLOBAL_HEADER_BYTES) { "maxBytes must leave room for records" }
        require(maxPackets > 0) { "maxPackets" }
        require(snapLength in 1..CaptureLimits.MAX_PACKET_BYTES) { "snapLength" }
        writeGlobalHeader()
    }

    private var totalBytes: Long = GLOBAL_HEADER_BYTES.toLong()
    private var packetCount: Long = 0
    private var truncatedPackets: Long = 0
    private var limitReason: CaptureEndReason? = null
    private var closed = false

    @Synchronized
    fun write(packet: ByteArray, offset: Int, length: Int): PcapWriteOutcome {
        check(!closed) { "writer is closed" }
        require(offset >= 0 && length >= 0 && offset + length <= packet.size) { "packet bounds" }
        limitReason?.let { return PcapWriteOutcome.LimitReached(it) }
        if (length == 0) {
            return PcapWriteOutcome.Written(0, false)
        }
        if (packetCount >= maxPackets) {
            limitReason = CaptureEndReason.PACKET_LIMIT
            return PcapWriteOutcome.LimitReached(CaptureEndReason.PACKET_LIMIT)
        }
        val included = minOf(length, snapLength)
        val truncated = included < length
        val recordBytes = RECORD_HEADER_BYTES + included
        if (totalBytes + recordBytes > maxBytes) {
            limitReason = CaptureEndReason.SIZE_LIMIT
            return PcapWriteOutcome.LimitReached(CaptureEndReason.SIZE_LIMIT)
        }
        val micros = nowEpochMicros().coerceAtLeast(0L)
        val seconds = micros / 1_000_000L
        val usec = (micros % 1_000_000L).toInt()
        writeIntLe(seconds.toInt())
        writeIntLe(usec)
        writeIntLe(included)
        writeIntLe(length)
        output.write(packet, offset, included)
        totalBytes += recordBytes
        packetCount += 1
        if (truncated) truncatedPackets += 1
        return PcapWriteOutcome.Written(included, truncated)
    }

    @Synchronized
    fun flush() {
        if (!closed) output.flush()
    }

    @Synchronized
    fun finish(): PcapWriteSummary {
        if (!closed) closed = true
        return snapshot()
    }

    /** Current state without closing the stream; used while a writer is late. */
    @Synchronized
    fun snapshot(): PcapWriteSummary = PcapWriteSummary(
        linkType = PcapLinkType.RAW,
        packets = packetCount,
        bytes = totalBytes,
        truncatedPackets = truncatedPackets,
        limitReason = limitReason,
        closed = closed,
    )

    private fun writeGlobalHeader() {
        writeIntLe(MAGIC_LE)
        writeShortLe(2)
        writeShortLe(4)
        writeIntLe(0)
        writeIntLe(0)
        writeIntLe(snapLength)
        writeIntLe(PcapLinkType.RAW.value)
        output.flush()
    }

    private fun writeIntLe(value: Int) {
        output.write(value and 0xFF)
        output.write((value ushr 8) and 0xFF)
        output.write((value ushr 16) and 0xFF)
        output.write((value ushr 24) and 0xFF)
    }

    private fun writeShortLe(value: Int) {
        output.write(value and 0xFF)
        output.write((value ushr 8) and 0xFF)
    }

    companion object {
        const val GLOBAL_HEADER_BYTES: Int = 24
        const val RECORD_HEADER_BYTES: Int = 16
        const val MAGIC_LE: Int = 0xA1B2C3D4.toInt()

        fun writeGlobalHeaderTo(output: OutputStream, snapLength: Int = CaptureLimits.SNAPLEN) {
            fun i(value: Int) {
                output.write(value and 0xFF)
                output.write((value ushr 8) and 0xFF)
                output.write((value ushr 16) and 0xFF)
                output.write((value ushr 24) and 0xFF)
            }
            fun s(value: Int) {
                output.write(value and 0xFF)
                output.write((value ushr 8) and 0xFF)
            }
            i(MAGIC_LE)
            s(2)
            s(4)
            i(0)
            i(0)
            i(snapLength)
            i(PcapLinkType.RAW.value)
        }
    }
}

/**
 * Streaming validator/counter for a root-produced PCAP byte stream. It never
 * retains payloads; it validates the global header and record framing, counts
 * complete records and records the first malformed byte offset. Partial
 * headers across chunk boundaries are handled without buffering the capture.
 */
class PcapRecordCounter {
    private val header = ByteArray(PcapRecordWriter.RECORD_HEADER_BYTES)
    private var headerFill = 0
    private var globalFill = 0
    private var remaining = 0L
    private var packetPending = false
    private var malformed = false
    private var consumed = 0L

    var packets: Long = 0
        private set
    var bytes: Long = 0
        private set
    var malformedOffset: Long = -1
        private set
    val isMalformed: Boolean get() = malformed

    fun consume(chunk: ByteArray, offset: Int, length: Int) {
        if (malformed || length <= 0) return
        require(offset >= 0 && length >= 0 && offset + length <= chunk.size) { "chunk bounds" }
        var cursor = offset
        val end = offset + length
        while (cursor < end) {
            if (globalFill < PcapRecordWriter.GLOBAL_HEADER_BYTES) {
                val take = minOf(PcapRecordWriter.GLOBAL_HEADER_BYTES - globalFill, end - cursor)
                globalFill += take
                cursor += take
                consumed += take
                continue
            }
            if (remaining > 0) {
                val take = minOf(remaining, (end - cursor).toLong()).toInt()
                remaining -= take
                cursor += take
                consumed += take
                if (remaining == 0L && packetPending) {
                    packetPending = false
                    packets += 1
                }
                continue
            }
            val take = minOf(PcapRecordWriter.RECORD_HEADER_BYTES - headerFill, end - cursor)
            chunk.copyInto(header, headerFill, cursor, cursor + take)
            headerFill += take
            cursor += take
            consumed += take
            if (headerFill < PcapRecordWriter.RECORD_HEADER_BYTES) continue
            val included = readIntLe(header, 8)
            val original = readIntLe(header, 12)
            headerFill = 0
            if (included < 0 || included > CaptureLimits.MAX_PACKET_BYTES ||
                original < 0 || original > CaptureLimits.MAX_PACKET_BYTES
            ) {
                malformed = true
                malformedOffset = consumed - PcapRecordWriter.RECORD_HEADER_BYTES
                return
            }
            bytes += included.toLong()
            if (included == 0) {
                packets += 1
            } else {
                remaining = included.toLong()
                packetPending = true
            }
        }
    }

    fun finish(): PcapRecordCount = PcapRecordCount(
        packets = packets,
        bytes = bytes,
        malformed = malformed || headerFill != 0 || remaining != 0L ||
            packetPending || globalFill < PcapRecordWriter.GLOBAL_HEADER_BYTES,
    )

    private fun readIntLe(source: ByteArray, at: Int): Int =
        (source[at].toInt() and 0xFF) or
            ((source[at + 1].toInt() and 0xFF) shl 8) or
            ((source[at + 2].toInt() and 0xFF) shl 16) or
            ((source[at + 3].toInt() and 0xFF) shl 24)
}

data class PcapRecordCount(
    val packets: Long,
    val bytes: Long,
    val malformed: Boolean,
)

/** Optional validation for a finished artifact; never repairs malformed bytes. */
object PcapFormatCheck {
    fun isValidGlobalHeader(bytes: ByteArray): Boolean {
        if (bytes.size < PcapRecordWriter.GLOBAL_HEADER_BYTES) return false
        val magic = (bytes[0].toInt() and 0xFF) or
            ((bytes[1].toInt() and 0xFF) shl 8) or
            ((bytes[2].toInt() and 0xFF) shl 16) or
            ((bytes[3].toInt() and 0xFF) shl 24)
        if (magic != PcapRecordWriter.MAGIC_LE) return false
        val major = (bytes[4].toInt() and 0xFF) or ((bytes[5].toInt() and 0xFF) shl 8)
        val link = (bytes[20].toInt() and 0xFF) or
            ((bytes[21].toInt() and 0xFF) shl 8) or
            ((bytes[22].toInt() and 0xFF) shl 16) or
            ((bytes[23].toInt() and 0xFF) shl 24)
        return major == 2 && link == PcapLinkType.RAW.value
    }
}

@Throws(IOException::class)
internal fun OutputStream.writeAll(bytes: ByteArray) {
    write(bytes, 0, bytes.size)
}
