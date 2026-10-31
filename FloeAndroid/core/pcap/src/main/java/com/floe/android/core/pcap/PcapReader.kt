// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.pcap

import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.nio.charset.StandardCharsets
import java.util.ArrayDeque
import java.util.EnumMap
import java.util.TreeMap

/**
 * Streaming, allocation-bounded PCAP/PCAPNG reader and flow aggregator.
 *
 * The parser never retains raw packets: it decodes one record at a time into
 * a reusable bounded buffer and folds the actual bytes into counters, a
 * bounded flow table, a coarsening timeline and bounded plaintext DNS/HTTP
 * extraction. TLS, TCP reassembly, VPN/root capture and payload export are
 * explicitly out of scope.
 */
class PcapAnalyzer {

    fun analyze(source: PcapSource, options: PcapAnalysisOptions): PcapSummary {
        val started = System.nanoTime()
        if (source.sizeBytes > PcapLimits.MAX_SOURCE_BYTES) {
            return failed(options, source.sizeBytes, "sourceTooLarge")
        }
        val state = ParseState(options, started)
        state.sourceBytes = source.sizeBytes
        try {
            val stream = source.openStream()
            val counting = CountingInputStream(stream)
            try {
                val magic = ByteArray(4)
                val headerBytes = readFully(counting, magic, 0, 4)
                when {
                    headerBytes == 0 -> state.failure = "emptySource"
                    headerBytes < 4 -> {
                        state.sourceTruncated = true
                        state.failure = "invalidHeader"
                    }
                    else -> when (val kind = detectFormat(magic)) {
                        FormatKind.PCAP_LE_MICRO, FormatKind.PCAP_BE_MICRO,
                        FormatKind.PCAP_LE_NANO, FormatKind.PCAP_BE_NANO ->
                            readPcap(counting, magic, kind, state)
                        FormatKind.PCAPNG -> readPcapNg(counting, magic, state)
                        FormatKind.UNKNOWN -> state.failure = "unknownFormat"
                    }
                }
                state.parsedBytes = counting.count
            } finally {
                runCatching { stream.close() }
            }
        } catch (_: IOException) {
            state.failure = "readFailure"
        }
        state.parseMillis = (System.nanoTime() - started) / 1_000_000L
        return state.buildSummary()
    }

    // ------------------------------------------------------------------
    // PCAP
    // ------------------------------------------------------------------

    private fun readPcap(
        stream: CountingInputStream,
        first: ByteArray,
        kind: FormatKind,
        state: ParseState,
    ) {
        state.format = PcapCaptureFormat.PCAP
        val header = ByteArray(24)
        first.copyInto(header, 0, 0, 4)
        val rest = readFully(stream, header, 4, 20)
        if (rest < 20) {
            state.sourceTruncated = true
            state.failure = "invalidHeader"
            return
        }
        val little = kind == FormatKind.PCAP_LE_MICRO || kind == FormatKind.PCAP_LE_NANO
        val nano = kind == FormatKind.PCAP_LE_NANO || kind == FormatKind.PCAP_BE_NANO
        val major = u16(header, 4, little)
        val linkType = (u32(header, 20, little).toInt()) and 0xFFFF
        if (major != 2) {
            state.failure = "invalidHeader"
            return
        }
        state.interfaces += PcapInterface(
            index = 0,
            linkType = linkType,
            snaplen = 0xFFFFFFFFL,
            timestampResolution = if (nano) "1e-9" else "1e-6",
        )
        val record = ByteArray(16)
        while (true) {
            if (state.shouldStop()) return
            val read = readFully(stream, record, 0, 16)
            if (read == 0) return
            if (read < 16) {
                state.sourceTruncated = true
                state.stoppedReason = "truncatedRecord"
                return
            }
            val tsSeconds = u32(record, 0, little)
            val fraction = u32(record, 4, little)
            val included = u32(record, 8, little)
            val original = u32(record, 12, little)
            if (fraction >= if (nano) 1_000_000_000L else 1_000_000L) {
                state.malformedPackets++
            }
            val timestamp = epochMillis(
                tsSeconds, fraction,
                if (nano) 1_000_000_000.0 else 1_000_000.0,
            )
            val wireLength = if (original > 0) original else included
            if (included > MAX_PCAP_RECORD_BYTES) {
                state.malformedPackets++
                val skipped = skipFully(stream, included)
                if (skipped < included) {
                    state.sourceTruncated = true
                    state.stoppedReason = "truncatedRecord"
                    state.recordPacket(wireLength, timestamp, null, truncated = false)
                    return
                }
                state.recordPacket(wireLength, timestamp, null, truncated = false)
                continue
            }
            val toRead = minOf(included, PcapLimits.MAX_PACKET_CAPTURE_BYTES.toLong()).toInt()
            val packet = ByteArray(toRead)
            val got = readFully(stream, packet, 0, toRead)
            val remaining = included - got
            if (remaining > 0 && skipFully(stream, remaining) < remaining) {
                state.sourceTruncated = true
                state.stoppedReason = "truncatedRecord"
                state.recordPacket(wireLength, timestamp, null, truncated = true)
                return
            }
            if (got < toRead) {
                state.sourceTruncated = true
                state.stoppedReason = "truncatedRecord"
                state.recordPacket(wireLength, timestamp, null, truncated = true)
                return
            }
            val truncated = included < original || included > PcapLimits.MAX_PACKET_CAPTURE_BYTES
            val parsed = parseLinkPacket(linkType, packet, got, state)
            state.recordPacket(wireLength, timestamp, parsed, truncated)
        }
    }

    // ------------------------------------------------------------------
    // PCAPNG
    // ------------------------------------------------------------------

    private fun readPcapNg(
        stream: CountingInputStream,
        first: ByteArray,
        state: ParseState,
    ) {
        state.format = PcapCaptureFormat.PCAPNG
        var section: NgSection? = null
        var pending = first
        var pendingLength = 4
        while (true) {
            if (state.shouldStop()) return
            val header = ByteArray(8)
            var copied = minOf(pendingLength, 8)
            pending.copyInto(header, 0, 0, copied)
            if (copied < 8) {
                copied += readFully(stream, header, copied, 8 - copied)
            }
            if (copied == 0) return
            if (copied < 8) {
                state.sourceTruncated = true
                state.stoppedReason = "truncatedBlock"
                return
            }
            pending = ByteArray(0)
            pendingLength = 0
            // The section header block type is byte-order independent.
            if (u32(header, 0, false) == NG_SHB) {
                val bom = ByteArray(4)
                if (readFully(stream, bom, 0, 4) < 4) {
                    state.sourceTruncated = true
                    state.stoppedReason = "truncatedBlock"
                    return
                }
                val little = when (u32(bom, 0, false)) {
                    0x4D3C2B1AL -> true
                    0x1A2B3C4DL -> false
                    else -> {
                        state.failure = "invalidHeader"
                        return
                    }
                }
                val total = u32(header, 4, little)
                if (!validBlockLength(total) || total < 28) {
                    state.failure = "invalidHeader"
                    return
                }
                val body = ByteArray(total.toInt() - 12)
                if (body.isNotEmpty() && readFully(stream, body, 0, body.size) < body.size) {
                    state.sourceTruncated = true
                    state.stoppedReason = "truncatedBlock"
                    return
                }
                if (u32(body, body.size - 4, little) != total) {
                    state.malformedPackets++
                    state.stoppedReason = "invalidBlock"
                    return
                }
                section = NgSection(little, ArrayList())
                continue
            }
            val active = section
            if (active == null) {
                state.failure = "invalidHeader"
                return
            }
            val type = u32(header, 0, active.littleEndian)
            val total = u32(header, 4, active.littleEndian)
            if (!validBlockLength(total)) {
                state.malformedPackets++
                state.stoppedReason = "invalidBlock"
                return
            }
            if (total > PcapLimits.MAX_BLOCK_BYTES) {
                val skipped = skipFully(stream, total - 8)
                if (skipped < total - 8) {
                    state.sourceTruncated = true
                    state.stoppedReason = "truncatedBlock"
                    return
                }
                state.unsupportedBlocks++
                continue
            }
            val body = ByteArray(total.toInt() - 8)
            if (body.isNotEmpty() && readFully(stream, body, 0, body.size) < body.size) {
                state.sourceTruncated = true
                state.stoppedReason = "truncatedBlock"
                return
            }
            if (u32(body, body.size - 4, active.littleEndian) != total) {
                state.malformedPackets++
                state.stoppedReason = "invalidBlock"
                return
            }
            val blockBody = if (body.size >= 4) body.copyOfRange(0, body.size - 4) else ByteArray(0)
            when (type) {
                NG_IDB -> parseNgInterface(blockBody, active, state)
                NG_EPB -> parseNgEnhancedPacket(blockBody, active, state)
                NG_SPB -> parseNgSimplePacket(blockBody, active, state)
                NG_PB -> parseNgObsoletePacket(blockBody, active, state)
                else -> state.unsupportedBlocks++
            }
        }
    }

    private fun parseNgInterface(body: ByteArray, section: NgSection, state: ParseState) {
        if (body.size < 8) {
            state.malformedPackets++
            return
        }
        val linkType = u16(body, 0, section.littleEndian)
        val snaplen = u32(body, 4, section.littleEndian)
        var unitsPerSecond = 1_000_000.0
        var resolutionLabel = "1e-6"
        var name: String? = null
        var offset = 8
        while (offset + 4 <= body.size) {
            val code = u16(body, offset, section.littleEndian)
            val length = u16(body, offset + 2, section.littleEndian)
            offset += 4
            if (offset + length > body.size) break
            when (code) {
                0 -> break
                9 -> if (length == 1) {
                    val value = body[offset].toInt() and 0xFF
                    if (value and 0x80 != 0) {
                        unitsPerSecond = Math.pow(2.0, (value and 0x7F).toDouble())
                        resolutionLabel = "2^-" + (value and 0x7F)
                    } else {
                        unitsPerSecond = Math.pow(10.0, value.toDouble())
                        resolutionLabel = "1e" + value
                    }
                }
                2 -> name = String(body, offset, length, StandardCharsets.UTF_8)
                    .filter { it.code >= 0x20 && it.code != 0x7f }.take(64)
            }
            offset += (length + 3) and 3.inv()
        }
        if (section.interfaces.size >= PcapLimits.MAX_INTERFACES) {
            state.limitations += "Additional capture interfaces were ignored at the 64-interface limit."
            return
        }
        val index = section.interfaces.size
        section.interfaces += NgInterface(linkType, unitsPerSecond)
        state.interfaces += PcapInterface(
            index = index,
            linkType = linkType,
            snaplen = snaplen,
            timestampResolution = resolutionLabel,
            name = name,
        )
    }

    private fun parseNgEnhancedPacket(body: ByteArray, section: NgSection, state: ParseState) {
        if (body.size < 20) {
            state.malformedPackets++
            return
        }
        val interfaceID = u32(body, 0, section.littleEndian).toInt()
        val iface = section.interfaces.getOrNull(interfaceID)
        if (iface == null) {
            state.malformedPackets++
            return
        }
        val tsHigh = u32(body, 4, section.littleEndian)
        val tsLow = u32(body, 8, section.littleEndian)
        val captured = u32(body, 12, section.littleEndian)
        val original = u32(body, 16, section.littleEndian)
        if (captured > (body.size - 20).toLong()) {
            state.malformedPackets++
            return
        }
        val copied = minOf(captured, PcapLimits.MAX_PACKET_CAPTURE_BYTES.toLong()).toInt()
        val packet = body.copyOfRange(20, 20 + copied)
        val parsed = parseLinkPacket(iface.linkType, packet, copied, state)
        state.recordPacket(
            if (original > 0) original else captured,
            ngTimestamp(tsHigh, tsLow, iface),
            parsed,
            truncated = captured < original || captured > PcapLimits.MAX_PACKET_CAPTURE_BYTES,
        )
    }

    private fun parseNgSimplePacket(body: ByteArray, section: NgSection, state: ParseState) {
        if (body.size < 4) {
            state.malformedPackets++
            return
        }
        val iface = section.interfaces.firstOrNull() ?: run {
            state.malformedPackets++
            return
        }
        val original = u32(body, 0, section.littleEndian)
        val copied = minOf(
            (body.size - 4).toLong(),
            PcapLimits.MAX_PACKET_CAPTURE_BYTES.toLong(),
        ).toInt()
        val packet = body.copyOfRange(4, 4 + copied)
        val parsed = parseLinkPacket(iface.linkType, packet, copied, state)
        // Simple packet blocks carry no timestamp at all; 0 is honest, not a
        // fabricated wall-clock time.
        state.recordPacket(
            if (original > 0) original else copied.toLong(),
            0L,
            parsed,
            truncated = original > copied.toLong(),
        )
    }

    private fun parseNgObsoletePacket(body: ByteArray, section: NgSection, state: ParseState) {
        if (body.size < 20) {
            state.malformedPackets++
            return
        }
        val interfaceID = u16(body, 0, section.littleEndian)
        val iface = section.interfaces.getOrNull(interfaceID) ?: run {
            state.malformedPackets++
            return
        }
        val tsHigh = u32(body, 4, section.littleEndian)
        val tsLow = u32(body, 8, section.littleEndian)
        val captured = u32(body, 12, section.littleEndian)
        val original = u32(body, 16, section.littleEndian)
        if (captured > (body.size - 20).toLong()) {
            state.malformedPackets++
            return
        }
        val copied = minOf(captured, PcapLimits.MAX_PACKET_CAPTURE_BYTES.toLong()).toInt()
        val packet = body.copyOfRange(20, 20 + copied)
        val parsed = parseLinkPacket(iface.linkType, packet, copied, state)
        state.recordPacket(
            if (original > 0) original else captured,
            ngTimestamp(tsHigh, tsLow, iface),
            parsed,
            truncated = captured < original,
        )
    }

    // ------------------------------------------------------------------
    // Link/IP/transport decoding
    // ------------------------------------------------------------------

    private fun parseLinkPacket(
        linkType: Int,
        data: ByteArray,
        length: Int,
        state: ParseState,
    ): ParsedPacket? = when (linkType) {
        LINKTYPE_ETHERNET -> parseEthernet(data, length, state)
        LINKTYPE_RAW -> parseRawIp(data, 0, length, state)
        LINKTYPE_LINUX_SLL -> if (length < 16) {
            state.malformedPackets++; null
        } else {
            parseEtherType(u16(data, 14, false), data, 16, length, state)
        }
        LINKTYPE_LINUX_SLL2 -> if (length < 20) {
            state.malformedPackets++; null
        } else {
            parseEtherType(u16(data, 0, false), data, 20, length, state)
        }
        LINKTYPE_NULL -> parseNullLoop(data, length, state, little = true)
        LINKTYPE_LOOP -> parseNullLoop(data, length, state, little = false)
        else -> {
            state.unsupportedPackets++
            null
        }
    }

    private fun parseNullLoop(data: ByteArray, length: Int, state: ParseState, little: Boolean): ParsedPacket? {
        if (length < 4) {
            state.malformedPackets++
            return null
        }
        return when (u32(data, 0, little)) {
            2L -> parseRawIp(data, 4, length, state)
            10L, 24L, 28L, 30L -> parseRawIp(data, 4, length, state)
            else -> {
                state.nonIpPackets++
                null
            }
        }
    }

    private fun parseEthernet(data: ByteArray, length: Int, state: ParseState): ParsedPacket? {
        if (length < 14) {
            state.malformedPackets++
            return null
        }
        var offset = 12
        var etherType = u16(data, offset, false)
        var tags = 0
        while (etherType == 0x8100 || etherType == 0x88A8 || etherType == 0x9100) {
            if (tags >= 2 || length < offset + 6) {
                state.malformedPackets++
                return null
            }
            offset += 4
            etherType = u16(data, offset, false)
            tags++
        }
        return parseEtherType(etherType, data, offset + 2, length, state)
    }

    private fun parseEtherType(
        etherType: Int,
        data: ByteArray,
        offset: Int,
        length: Int,
        state: ParseState,
    ): ParsedPacket? = when (etherType) {
        0x0800 -> parseIpv4(data, offset, length, state)
        0x86DD -> parseIpv6(data, offset, length, state)
        else -> {
            state.nonIpPackets++
            null
        }
    }

    private fun parseRawIp(data: ByteArray, offset: Int, length: Int, state: ParseState): ParsedPacket? {
        if (offset >= length) {
            state.malformedPackets++
            return null
        }
        return when ((data[offset].toInt() ushr 4) and 0xF) {
            4 -> parseIpv4(data, offset, length, state)
            6 -> parseIpv6(data, offset, length, state)
            else -> {
                state.nonIpPackets++
                null
            }
        }
    }

    private fun parseIpv4(data: ByteArray, offset: Int, length: Int, state: ParseState): ParsedPacket? {
        if (length - offset < 20) {
            state.malformedPackets++
            return null
        }
        val headerLength = (data[offset].toInt() and 0xF) * 4
        if (headerLength < 20 || offset + headerLength > length) {
            state.malformedPackets++
            return null
        }
        val totalLength = u16(data, offset + 2, false)
        val effectiveEnd = if (totalLength in headerLength..(length - offset)) {
            offset + totalLength
        } else {
            length
        }
        val protocol = data[offset + 9].toInt() and 0xFF
        val fragment = u16(data, offset + 6, false)
        val fragmentOffset = fragment and 0x1FFF
        val src = address(data, offset + 12, 4)
        val dst = address(data, offset + 16, 4)
        state.ipVersions[PcapIpVersion.IPV4] = (state.ipVersions[PcapIpVersion.IPV4] ?: 0L) + 1
        if (fragmentOffset != 0) {
            state.fragmentedPackets++
            return ParsedPacket(src, dst, protocolOf(protocol), PcapIpVersion.IPV4,
                null, null, null, null)
        }
        return parseTransport(data, offset + headerLength, effectiveEnd, protocol, src, dst, state)
    }

    private fun parseIpv6(data: ByteArray, offset: Int, length: Int, state: ParseState): ParsedPacket? {
        if (length - offset < 40) {
            state.malformedPackets++
            return null
        }
        val payloadLength = u16(data, offset + 4, false)
        val declaredEnd = offset + 40 + payloadLength
        val effectiveEnd = if (payloadLength > 0 && declaredEnd <= length) declaredEnd else length
        val src = address(data, offset + 8, 16)
        val dst = address(data, offset + 24, 16)
        var nextHeader = data[offset + 6].toInt() and 0xFF
        var cursor = offset + 40
        var extensions = 0
        var fragmentOffset = 0
        while (nextHeader in setOf(0, 43, 44, 51, 60) && extensions < 4) {
            if (cursor + 2 > effectiveEnd) {
                state.malformedPackets++
                return null
            }
            val extensionLength = if (nextHeader == 44) {
                8
            } else {
                (data[cursor + 1].toInt() and 0xFF) * 8 + 8
            }
            if (extensionLength <= 0 || cursor + extensionLength > effectiveEnd) {
                state.malformedPackets++
                return null
            }
            if (nextHeader == 44) {
                val rawOffset = ((data[cursor + 2].toInt() and 0xFF) shl 8) or
                    (data[cursor + 3].toInt() and 0xFF)
                fragmentOffset = (rawOffset ushr 3) and 0x1FFF
            }
            nextHeader = data[cursor].toInt() and 0xFF
            cursor += extensionLength
            extensions++
        }
        state.ipVersions[PcapIpVersion.IPV6] = (state.ipVersions[PcapIpVersion.IPV6] ?: 0L) + 1
        if (fragmentOffset != 0) {
            state.fragmentedPackets++
            return ParsedPacket(src, dst, protocolOf(nextHeader), PcapIpVersion.IPV6,
                null, null, null, null)
        }
        return parseTransport(data, cursor, effectiveEnd, nextHeader, src, dst, state)
    }

    private fun parseTransport(
        data: ByteArray,
        offset: Int,
        end: Int,
        protocol: Int,
        src: String,
        dst: String,
        state: ParseState,
    ): ParsedPacket? {
        if (end < offset) {
            state.malformedPackets++
            return null
        }
        val version = if (src.contains(':')) PcapIpVersion.IPV6 else PcapIpVersion.IPV4
        return when (protocol) {
            6 -> {
                if (end - offset < 20) {
                    state.malformedPackets++
                    return null
                }
                val srcPort = u16(data, offset, false)
                val dstPort = u16(data, offset + 2, false)
                val dataOffset = ((data[offset + 12].toInt() ushr 4) and 0xF) * 4
                if (dataOffset < 20 || offset + dataOffset > end) {
                    state.malformedPackets++
                    return null
                }
                ParsedPacket(
                    src, dst, PcapProtocol.TCP, version, srcPort, dstPort,
                    tcpFlags(data[offset + 13].toInt() and 0xFF),
                    if (offset + dataOffset < end) data.copyOfRange(offset + dataOffset, end) else null,
                )
            }
            17 -> {
                if (end - offset < 8) {
                    state.malformedPackets++
                    return null
                }
                val srcPort = u16(data, offset, false)
                val dstPort = u16(data, offset + 2, false)
                val udpLength = u16(data, offset + 4, false)
                val payloadEnd = if (udpLength in 8..(end - offset)) offset + udpLength else end
                ParsedPacket(
                    src, dst, PcapProtocol.UDP, version, srcPort, dstPort, null,
                    if (offset + 8 < payloadEnd) data.copyOfRange(offset + 8, payloadEnd) else null,
                )
            }
            1, 58 -> {
                if (end - offset < 4) {
                    state.malformedPackets++
                    return null
                }
                ParsedPacket(
                    src, dst,
                    if (protocol == 1) PcapProtocol.ICMP else PcapProtocol.ICMPV6,
                    version, null, null, null, null,
                )
            }
            else -> ParsedPacket(src, dst, PcapProtocol.OTHER, version, null, null, null, null)
        }
    }

    private fun address(data: ByteArray, offset: Int, size: Int): String = runCatching {
        java.net.InetAddress.getByAddress(data.copyOfRange(offset, offset + size)).hostAddress
    }.getOrElse { "unknown" }

    private fun ngTimestamp(high: Long, low: Long, iface: NgInterface): Long {
        val units = ((high and 0xFFFFFFFFL) shl 32) or (low and 0xFFFFFFFFL)
        if (iface.unitsPerSecond <= 0.0) return 0L
        val millis = units.toDouble() * 1000.0 / iface.unitsPerSecond
        return if (!millis.isFinite() || millis < 0.0) 0L
        else if (millis > Long.MAX_VALUE.toDouble()) Long.MAX_VALUE else millis.toLong()
    }

    private fun failed(options: PcapAnalysisOptions, sourceBytes: Long, code: String): PcapSummary =
        ParseState(options, System.nanoTime()).apply {
            this.sourceBytes = sourceBytes
            failure = code
        }.buildSummary()

    private fun detectFormat(magic: ByteArray): FormatKind {
        val b0 = magic[0].toInt() and 0xFF
        val b1 = magic[1].toInt() and 0xFF
        val b2 = magic[2].toInt() and 0xFF
        val b3 = magic[3].toInt() and 0xFF
        return when {
            b0 == 0xD4 && b1 == 0xC3 && b2 == 0xB2 && b3 == 0xA1 -> FormatKind.PCAP_LE_MICRO
            b0 == 0xA1 && b1 == 0xB2 && b2 == 0xC3 && b3 == 0xD4 -> FormatKind.PCAP_BE_MICRO
            b0 == 0x4D && b1 == 0x3C && b2 == 0xB2 && b3 == 0xA1 -> FormatKind.PCAP_LE_NANO
            b0 == 0xA1 && b1 == 0xB2 && b2 == 0x3C && b3 == 0x4D -> FormatKind.PCAP_BE_NANO
            b0 == 0x0A && b1 == 0x0D && b2 == 0x0D && b3 == 0x0A -> FormatKind.PCAPNG
            else -> FormatKind.UNKNOWN
        }
    }

    private companion object {
        const val LINKTYPE_NULL = 0
        const val LINKTYPE_ETHERNET = 1
        const val LINKTYPE_RAW = 101
        const val LINKTYPE_LOOP = 108
        const val LINKTYPE_LINUX_SLL = 113
        const val LINKTYPE_LINUX_SLL2 = 276
        const val NG_SHB = 0x0A0D0D0AL
        const val NG_IDB = 0x00000001L
        const val NG_PB = 0x00000002L
        const val NG_SPB = 0x00000003L
        const val NG_EPB = 0x00000006L
    }

    private enum class FormatKind {
        PCAP_LE_MICRO, PCAP_BE_MICRO, PCAP_LE_NANO, PCAP_BE_NANO, PCAPNG, UNKNOWN,
    }

    private data class NgSection(val littleEndian: Boolean, val interfaces: MutableList<NgInterface>)

    private data class NgInterface(val linkType: Int, val unitsPerSecond: Double)

    private class ParsedPacket(
        val sourceAddress: String,
        val destinationAddress: String,
        val protocol: PcapProtocol,
        val ipVersion: PcapIpVersion,
        val sourcePort: Int?,
        val destinationPort: Int?,
        val tcpFlags: String?,
        val payload: ByteArray?,
    ) {
        // App-private summaries retain the literal endpoint for local filters
        // and diagnostics; export/tool projections apply redaction later.
        fun endpointSource(): PcapEndpoint {
            val token = PcapIdentifiers.token(sourceAddress)
            return PcapEndpoint(sourceAddress.take(PcapLimits.MAX_ADDRESS_CHARS - 1), token,
                sourcePort?.takeIf { it in 1..65_535 })
        }

        fun endpointDestination(): PcapEndpoint {
            val token = PcapIdentifiers.token(destinationAddress)
            return PcapEndpoint(destinationAddress.take(PcapLimits.MAX_ADDRESS_CHARS - 1), token,
                destinationPort?.takeIf { it in 1..65_535 })
        }
    }

    private data class FlowKey(
        val protocol: PcapProtocol,
        val ipVersion: PcapIpVersion,
        val sourceToken: String,
        val sourcePort: Int?,
        val destinationToken: String,
        val destinationPort: Int?,
    )

    private class FlowAgg(
        val protocol: PcapProtocol,
        val ipVersion: PcapIpVersion,
        val source: PcapEndpoint,
        val destination: PcapEndpoint,
        var packets: Long,
        var bytes: Long,
        var first: Long,
        var last: Long,
        var flags: String?,
    )

    private class TimelineAccumulator(private val maxBuckets: Int) {
        private val buckets = TreeMap<Long, LongArray>()
        private var bucketMillis = 1_000L

        fun add(timestamp: Long, wireLength: Long) {
            val safeTimestamp = if (timestamp > 0) timestamp else 0L
            val key = safeTimestamp - (safeTimestamp % bucketMillis)
            val value = buckets[key] ?: LongArray(2).also { buckets[key] = it }
            value[0] += 1
            value[1] += wireLength
            while (buckets.size > maxBuckets * 2) merge()
        }

        fun result(): List<PcapTimelineBucket> {
            while (buckets.size > maxBuckets) merge()
            return buckets.entries.map { (key, value) ->
                PcapTimelineBucket(key, bucketMillis, value[0], value[1])
            }
        }

        private fun merge() {
            val merged = TreeMap<Long, LongArray>()
            for ((key, value) in buckets) {
                val target = key - (key % (bucketMillis * 2))
                val current = merged[target] ?: LongArray(2)
                current[0] += value[0]
                current[1] += value[1]
                merged[target] = current
            }
            buckets.clear()
            buckets.putAll(merged)
            bucketMillis *= 2
        }
    }

    private class ParseState(val options: PcapAnalysisOptions, val startedNanos: Long) {
        var sourceBytes: Long = 0L
        var parsedBytes: Long = 0L
        var parseMillis: Long = 0L
        var format: PcapCaptureFormat = PcapCaptureFormat.UNKNOWN
        var packetCount: Long = 0L
        var capturedPacketCount: Long = 0L
        var totalByteCount: Long = 0L
        var truncatedPacketCount: Long = 0L
        var malformedPackets: Long = 0L
        var unsupportedPackets: Long = 0L
        var nonIpPackets: Long = 0L
        var unsupportedBlocks: Long = 0L
        var fragmentedPackets: Long = 0L
        var flowTableOverflow: Long = 0L
        var sourceTruncated: Boolean = false
        var cancelled: Boolean = false
        var lastEpochMillis: Long? = null
        var firstEpochMillis: Long? = null
        var stoppedReason: String? = null
        var failure: String? = null
        val protocols = EnumMap<PcapProtocol, LongArray>(PcapProtocol::class.java)
        val ipVersions = EnumMap<PcapIpVersion, Long>(PcapIpVersion::class.java)
        val interfaces = ArrayList<PcapInterface>()
        val flows = LinkedHashMap<FlowKey, FlowAgg>()
        val timeline = TimelineAccumulator(options.maxTimelineBuckets)
        val dns = ArrayDeque<PcapDnsRecord>()
        val http = ArrayDeque<PcapHttpRecord>()
        var dnsDropped: Long = 0L
        var httpDropped: Long = 0L
        val limitations = ArrayList<String>()

        fun shouldStop(): Boolean {
            if (options.cancellation.isCancelled()) {
                cancelled = true
                stoppedReason = "cancelled"
                return true
            }
            if (packetCount >= options.maxPackets) {
                stoppedReason = "packetLimit"
                return true
            }
            if ((packetCount and 0x3FL) == 0L) {
                val elapsed = (System.nanoTime() - startedNanos) / 1_000_000L
                if (elapsed >= options.timeBudgetMillis) {
                    stoppedReason = "timeBudget"
                    return true
                }
            }
            return false
        }

        fun recordPacket(
            wireLength: Long,
            timestamp: Long,
            parsed: ParsedPacket?,
            truncated: Boolean,
        ) {
            packetCount++
            capturedPacketCount++
            val boundedWire = wireLength.coerceIn(0L, PcapLimits.MAX_SOURCE_BYTES)
            totalByteCount += boundedWire
            if (timestamp > 0) {
                if (firstEpochMillis == null || timestamp < firstEpochMillis!!) firstEpochMillis = timestamp
                if (lastEpochMillis == null || timestamp > lastEpochMillis!!) lastEpochMillis = timestamp
            }
            if (truncated) truncatedPacketCount++
            timeline.add(timestamp, boundedWire)
            if (parsed == null) return
            val stats = protocols.getOrPut(parsed.protocol) { LongArray(2) }
            stats[0] += 1
            stats[1] += boundedWire
            val sourceToken = PcapIdentifiers.token(parsed.sourceAddress)
            val destinationToken = PcapIdentifiers.token(parsed.destinationAddress)
            val sourcePort = parsed.sourcePort?.takeIf { it in 1..65_535 }
            val destinationPort = parsed.destinationPort?.takeIf { it in 1..65_535 }
            val key = FlowKey(
                parsed.protocol, parsed.ipVersion, sourceToken, sourcePort,
                destinationToken, destinationPort,
            )
            val existing = flows[key]
            if (existing == null) {
                if (flows.size >= options.maxFlowKeys) {
                    flowTableOverflow++
                } else {
                    flows[key] = FlowAgg(
                        parsed.protocol, parsed.ipVersion,
                        parsed.endpointSource(),
                        parsed.endpointDestination(),
                        1, boundedWire, timestamp, timestamp, parsed.tcpFlags,
                    )
                }
            } else {
                existing.packets++
                existing.bytes += boundedWire
                if (timestamp > 0) {
                    if (existing.first == 0L || timestamp < existing.first) existing.first = timestamp
                    if (timestamp > existing.last) existing.last = timestamp
                }
                existing.flags = parsed.tcpFlags ?: existing.flags
            }
            if (parsed.protocol == PcapProtocol.TCP) {
                if (53 in listOfNotNull(sourcePort, destinationPort)) {
                    extractDns(parsed, timestamp, overTcp = true)
                } else if (listOfNotNull(sourcePort, destinationPort).any { it in HTTP_PORTS }) {
                    extractHttp(parsed, timestamp)
                }
            } else if (parsed.protocol == PcapProtocol.UDP &&
                listOfNotNull(sourcePort, destinationPort).contains(53)
            ) {
                extractDns(parsed, timestamp, overTcp = false)
            }
        }

        private fun extractDns(packet: ParsedPacket, timestamp: Long, overTcp: Boolean) {
            val payload = packet.payload ?: return
            val offset = if (overTcp) 2 else 0
            if (payload.size < 12 + offset) return
            val flags = u16(payload, offset + 2, false)
            val response = flags and 0x8000 != 0
            val qdCount = u16(payload, offset + 4, false)
            if (qdCount < 1) return
            val decoded = readDnsName(payload, offset + 12, payload.size) ?: return
            val (name, afterName) = decoded
            if (afterName + 4 > payload.size) return
            val qType = u16(payload, afterName, false)
            addDns(
                PcapDnsRecord(
                    timestampEpochMillis = timestamp,
                    direction = if (response) "response" else "query",
                    name = name.lowercase(java.util.Locale.ROOT).take(320),
                    nameToken = PcapIdentifiers.token(name),
                    recordType = dnsTypeName(qType),
                    responseCode = if (response) flags and 0xF else null,
                    source = packet.endpointSource(),
                    destination = packet.endpointDestination(),
                    overTcp = overTcp,
                    truncated = flags and 0x0200 != 0 || payload.size >= 65_535,
                ),
            )
        }

        private fun addDns(record: PcapDnsRecord) {
            if (options.maxDnsRecords <= 0) {
                dnsDropped++
                return
            }
            if (dns.size >= options.maxDnsRecords) {
                dns.removeFirst()
                dnsDropped++
            }
            dns.addLast(record)
        }

        private fun extractHttp(packet: ParsedPacket, timestamp: Long) {
            val payload = packet.payload ?: return
            if (payload.isEmpty()) return
            val prefixLength = minOf(payload.size, 4096)
            val text = String(payload, 0, prefixLength, StandardCharsets.ISO_8859_1)
            val firstLine = text.lineSequence().firstOrNull()?.take(512) ?: return
            val request = HTTP_METHODS.any { firstLine.startsWith("$it ") }
            val response = firstLine.startsWith("HTTP/1.") || firstLine.startsWith("HTTP/2")
            if (!request && !response) return
            val methodOrStatus = firstLine.substringBefore(' ').take(64)
            if (methodOrStatus.isBlank()) return
            var host: String? = null
            if (request) {
                for (line in text.lineSequence().drop(1).take(32)) {
                    if (line.isEmpty()) break
                    if (line.startsWith("Host:", ignoreCase = true)) {
                        host = line.substringAfter(':').trim().take(320)
                        break
                    }
                }
            }
            addHttp(
                PcapHttpRecord(
                    timestampEpochMillis = timestamp,
                    direction = if (request) "request" else "response",
                    methodOrStatus = methodOrStatus,
                    host = host?.let(::sanitizeHttpHost),
                    path = if (request) {
                        firstLine.split(' ').getOrNull(1)?.let(::sanitizeHttpPath)
                    } else {
                        null
                    },
                    source = packet.endpointSource(),
                    destination = packet.endpointDestination(),
                    payloadBytes = payload.size,
                    truncated = payload.size >= prefixLength,
                ),
            )
        }

        private fun addHttp(record: PcapHttpRecord) {
            if (options.maxHttpRecords <= 0) {
                httpDropped++
                return
            }
            if (http.size >= options.maxHttpRecords) {
                http.removeFirst()
                httpDropped++
            }
            http.addLast(record)
        }

        fun buildSummary(): PcapSummary {
            val selected = flows.values.sortedWith(
                compareByDescending<FlowAgg> { it.bytes }.thenByDescending { it.packets },
            ).take(options.maxRetainedFlows)
            val protocolStats = PcapProtocol.entries.mapNotNull { protocol ->
                protocols[protocol]?.let { stats -> PcapProtocolStats(protocol, stats[0], stats[1]) }
            }
            val messages = ArrayList<String>()
            messages += "Offline analysis cannot decrypt TLS, reassemble segmented TCP streams, " +
                "or recover payloads beyond the bounded plaintext DNS/HTTP fields."
            failure?.let { code ->
                messages += when (code) {
                    "sourceTooLarge" -> "The capture exceeds the 128 MiB offline limit."
                    "emptySource" -> "The selected capture is empty."
                    "unknownFormat" -> "The file is not a PCAP or PCAPNG capture."
                    "invalidHeader" -> "The capture header is invalid or truncated."
                    "readFailure" -> "The capture could not be read."
                    else -> "The capture could not be analysed."
                }
            }
            if (cancelled) messages += "Analysis was cancelled; only the parsed prefix is represented."
            when (stoppedReason) {
                "timeBudget" ->
                    messages += "The 30 s analysis budget was reached; only the parsed prefix is represented."
                "packetLimit" ->
                    messages += "The two-million-packet limit was reached; only the parsed prefix is represented."
                "truncatedRecord", "truncatedBlock" ->
                    messages += "The capture ended in the middle of a record; partial data is shown."
                "invalidBlock" -> messages += "A malformed PCAPNG block ended analysis."
            }
            if (malformedPackets > 0) messages += "$malformedPackets malformed packet records were skipped."
            if (truncatedPacketCount > 0) {
                messages += "$truncatedPacketCount packets were captured shorter than their original length."
            }
            if (unsupportedPackets > 0) {
                messages += "$unsupportedPackets packets use an unsupported link type and were counted but not decoded."
            }
            if (unsupportedBlocks > 0) messages += "$unsupportedBlocks unsupported PCAPNG blocks were skipped."
            if (fragmentedPackets > 0) {
                messages += "$fragmentedPackets non-initial IP fragments were counted without transport ports."
            }
            if (flowTableOverflow > 0) {
                messages += "$flowTableOverflow additional flow keys were not aggregated (65,536-key limit)."
            }
            if (dnsDropped > 0) messages += "$dnsDropped earlier DNS records were evicted by the 200-record ring."
            if (httpDropped > 0) messages += "$httpDropped earlier HTTP records were evicted by the 200-record ring."
            if (packetCount == 0L && failure == null) messages += "No packets were found in the selected capture."
            messages += if (options.detailed) {
                "This analysis is App-private and detailed exports may include sanitized network identifiers; credentials and URL secrets remain removed."
            } else {
                "This analysis is App-private; exports and Agent tools redact network identifiers unless detailed export was chosen at import."
            }
            val status = when {
                failure != null && packetCount == 0L -> PcapAnalysisStatus.FAILED
                cancelled || stoppedReason != null || sourceTruncated ||
                    malformedPackets > 0 || unsupportedPackets > 0 ||
                    flowTableOverflow > 0 || dnsDropped > 0 || httpDropped > 0 ->
                    PcapAnalysisStatus.PARTIAL
                else -> PcapAnalysisStatus.OK
            }
            return PcapSummary(
                analysisID = options.analysisID,
                createdAtEpochMillis = options.createdAtEpochMillis,
                status = status,
                format = format,
                sourceLabel = PcapIdentifiers.displayName(options.sourceLabel),
                sourceBytes = sourceBytes,
                parsedBytes = parsedBytes,
                totalByteCount = totalByteCount,
                sourceTruncated = sourceTruncated,
                detailed = options.detailed,
                startEpochMillis = firstEpochMillis,
                endEpochMillis = lastEpochMillis,
                parseMillis = parseMillis,
                budgetMillis = options.timeBudgetMillis,
                packetCount = packetCount,
                capturedPacketCount = capturedPacketCount,
                truncatedPacketCount = truncatedPacketCount,
                malformedPacketCount = malformedPackets,
                unsupportedPacketCount = unsupportedPackets,
                nonIpPacketCount = nonIpPackets,
                flowTableOverflow = flowTableOverflow,
                totalFlowCount = flows.size.toLong(),
                protocols = protocolStats,
                ipVersions = ipVersions.toMap(),
                interfaces = interfaces.toList(),
                flows = selected.map { flow ->
                    val first = if (flow.first > 0) flow.first else (firstEpochMillis ?: 0L)
                    val last = if (flow.last > 0) flow.last else (lastEpochMillis ?: first)
                    PcapFlow(
                        flow.protocol, flow.ipVersion, flow.source, flow.destination,
                        flow.packets, flow.bytes, first, last, flow.flags,
                    )
                },
                timeline = timeline.result().take(options.maxTimelineBuckets),
                dns = dns.toList(),
                http = http.toList(),
                stoppedReason = stoppedReason,
                cancelled = cancelled,
                limitations = messages.distinct().take(PcapLimits.MAX_LIMITATIONS),
            )
        }
    }
}

// ---------------------------------------------------------------------------
// Bounded helpers
// ---------------------------------------------------------------------------

private const val MAX_PCAP_RECORD_BYTES = 1024L * 1024L
private val HTTP_PORTS = setOf(80, 8000, 8080, 8888)
private val HTTP_METHODS = setOf(
    "GET", "POST", "PUT", "HEAD", "DELETE", "OPTIONS", "PATCH", "CONNECT", "TRACE",
)

private fun sanitizeHttpHost(value: String): String =
    value.substringAfterLast('@').trim().lowercase(java.util.Locale.ROOT)
        .filter { it.code >= 0x20 && it.code != 0x7f }.take(320)

private fun sanitizeHttpPath(value: String): String =
    value.substringBefore('?').substringBefore('#').take(512)

internal fun readFully(stream: InputStream, buffer: ByteArray, offset: Int, length: Int): Int {
    var total = 0
    while (total < length) {
        val read = try {
            stream.read(buffer, offset + total, length - total)
        } catch (_: EOFException) {
            -1
        }
        if (read <= 0) break
        total += read
    }
    return total
}

internal fun skipFully(stream: InputStream, length: Long): Long {
    if (length <= 0) return 0
    val scratch = ByteArray(64 * 1024)
    var remaining = length
    while (remaining > 0) {
        val read = stream.read(scratch, 0, minOf(remaining, scratch.size.toLong()).toInt())
        if (read < 0) break
        remaining -= read
    }
    return length - remaining
}

internal fun validBlockLength(length: Long): Boolean =
    length >= 12 && length % 4 == 0L && length <= PcapLimits.MAX_BLOCK_BYTES

internal fun u16(data: ByteArray, offset: Int, little: Boolean): Int {
    if (offset < 0 || offset + 2 > data.size) return 0
    val b0 = data[offset].toInt() and 0xFF
    val b1 = data[offset + 1].toInt() and 0xFF
    return if (little) b0 or (b1 shl 8) else (b0 shl 8) or b1
}

internal fun u32(data: ByteArray, offset: Int, little: Boolean): Long {
    if (offset < 0 || offset + 4 > data.size) return 0L
    var value = 0L
    if (little) {
        for (index in 3 downTo 0) value = (value shl 8) or (data[offset + index].toLong() and 0xFF)
    } else {
        for (index in 0 until 4) value = (value shl 8) or (data[offset + index].toLong() and 0xFF)
    }
    return value
}

private fun epochMillis(seconds: Long, fraction: Long, unitsPerSecond: Double): Long {
    if (seconds < 0 || fraction < 0) return 0L
    val total = seconds * 1000L + (fraction * 1000.0 / unitsPerSecond).toLong()
    return if (total < 0) 0L else total
}

private fun protocolOf(ipProtocol: Int): PcapProtocol = when (ipProtocol) {
    6 -> PcapProtocol.TCP
    17 -> PcapProtocol.UDP
    1 -> PcapProtocol.ICMP
    58 -> PcapProtocol.ICMPV6
    else -> PcapProtocol.OTHER
}

private fun tcpFlags(value: Int): String = buildString {
    if (value and 0x02 != 0) append('S')
    if (value and 0x10 != 0) append('A')
    if (value and 0x01 != 0) append('F')
    if (value and 0x04 != 0) append('R')
    if (value and 0x08 != 0) append('P')
    if (value and 0x20 != 0) append('U')
    if (value and 0x40 != 0) append('E')
    if (value and 0x80 != 0) append('C')
}.ifBlank { "-" }

private fun readDnsName(data: ByteArray, start: Int, end: Int): Pair<String, Int>? {
    val labels = ArrayList<String>(8)
    var cursor = start
    var after = -1
    var jumps = 0
    var total = 0
    while (cursor < end && jumps <= 16) {
        val length = data[cursor].toInt() and 0xFF
        if (length == 0) {
            if (after < 0) after = cursor + 1
            break
        }
        if (length and 0xC0 == 0xC0) {
            if (cursor + 1 >= end) return null
            val pointer = ((length and 0x3F) shl 8) or (data[cursor + 1].toInt() and 0xFF)
            if (after < 0) after = cursor + 2
            if (pointer >= cursor || pointer < 12) return null
            cursor = pointer
            jumps++
            continue
        }
        if (length > 63 || cursor + 1 + length > end) return null
        val label = String(data, cursor + 1, length, StandardCharsets.US_ASCII)
        if (label.any { it.code < 0x21 || it.code > 0x7e }) return null
        labels += label
        total += length + 1
        if (total > 255 || labels.size > 32) return null
        cursor += length + 1
    }
    if (labels.isEmpty()) return null
    return labels.joinToString(".") to (after.coerceAtLeast(cursor + 1))
}

private fun dnsTypeName(type: Int): String = when (type) {
    1 -> "A"; 2 -> "NS"; 5 -> "CNAME"; 6 -> "SOA"; 12 -> "PTR"; 15 -> "MX";
    16 -> "TXT"; 28 -> "AAAA"; 33 -> "SRV"; 41 -> "OPT"; 43 -> "DS";
    46 -> "RRSIG"; 47 -> "NSEC"; 64 -> "SVCB"; 65 -> "HTTPS"; 255 -> "ANY";
    else -> "TYPE$type"
}

private class CountingInputStream(private val delegate: InputStream) : InputStream() {
    var count: Long = 0L
        private set

    override fun read(): Int {
        val value = delegate.read()
        if (value >= 0) count++
        return value
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        val value = delegate.read(buffer, offset, length)
        if (value > 0) count += value
        return value
    }

    override fun skip(amount: Long): Long {
        var remaining = amount
        val scratch = ByteArray(64 * 1024)
        while (remaining > 0) {
            val read = delegate.read(scratch, 0, minOf(remaining, scratch.size.toLong()).toInt())
            if (read < 0) break
            count += read
            remaining -= read
        }
        return amount - remaining
    }

    override fun available(): Int = 0

    override fun close() = delegate.close()
}
