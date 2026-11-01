// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.capture

import com.floe.android.core.networkcapture.CaptureEndReason
import com.floe.android.core.networkcapture.CaptureLimits
import com.floe.android.core.networkcapture.PcapFormatCheck
import com.floe.android.core.networkcapture.PcapLinkType
import com.floe.android.core.networkcapture.PcapRecordCounter
import com.floe.android.core.networkcapture.PcapRecordWriter
import com.floe.android.core.networkcapture.PcapWriteOutcome
import java.io.ByteArrayOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PcapRecordWriterTest {

    private fun packet(size: Int = 20, fill: Byte = 0x45): ByteArray =
        ByteArray(size) { fill }

    private fun intLe(bytes: ByteArray, offset: Int): Int =
        (bytes[offset].toInt() and 0xFF) or
            ((bytes[offset + 1].toInt() and 0xFF) shl 8) or
            ((bytes[offset + 2].toInt() and 0xFF) shl 16) or
            ((bytes[offset + 3].toInt() and 0xFF) shl 24)

    private fun shortLe(bytes: ByteArray, offset: Int): Int =
        (bytes[offset].toInt() and 0xFF) or
            ((bytes[offset + 1].toInt() and 0xFF) shl 8)

    @Test
    fun writesLittleEndianRawGlobalHeaderAndRecords() {
        val output = ByteArrayOutputStream()
        val writer = PcapRecordWriter(
            output = output,
            maxBytes = 1_000,
            maxPackets = 10,
            nowEpochMicros = { 1_700_000_000_123_456L },
        )
        assertEquals(PcapWriteOutcome.Written(20, false), writer.write(packet(20), 0, 20))
        assertEquals(PcapWriteOutcome.Written(20, false), writer.write(packet(20), 0, 20))
        val summary = writer.finish()
        val bytes = output.toByteArray()
        assertEquals(24 + 2 * (16 + 20), bytes.size)
        assertTrue(PcapFormatCheck.isValidGlobalHeader(bytes))
        assertEquals(0xA1B2C3D4.toInt(), intLe(bytes, 0))
        // PCAP global header: 16-bit major/minor version at offsets 4 and 6.
        assertEquals(2, shortLe(bytes, 4))
        assertEquals(4, shortLe(bytes, 6))
        assertEquals(PcapLinkType.RAW.value, intLe(bytes, 20))
        assertEquals(1_700_000_000, intLe(bytes, 24))
        assertEquals(123_456, intLe(bytes, 28))
        assertEquals(20, intLe(bytes, 32))
        assertEquals(20, intLe(bytes, 36))
        assertEquals(2L, summary.packets)
        assertEquals(24L + 2 * 36, summary.bytes)
    }

    @Test
    fun truncatesToSnapLengthWithoutLosingOriginalLength() {
        val output = ByteArrayOutputStream()
        val writer = PcapRecordWriter(
            output = output,
            maxBytes = 1_000,
            snapLength = 32,
        )
        val outcome = writer.write(packet(40, 0x60), 0, 40)
        assertEquals(PcapWriteOutcome.Written(32, true), outcome)
        val summary = writer.finish()
        assertEquals(32, intLe(output.toByteArray(), 32))
        assertEquals(40, intLe(output.toByteArray(), 36))
        assertEquals(1L, summary.truncatedPackets)
    }

    @Test
    fun refusesRecordThatWouldExceedByteCap() {
        val output = ByteArrayOutputStream()
        val writer = PcapRecordWriter(output = output, maxBytes = 24 + 16 + 10)
        assertEquals(
            PcapWriteOutcome.LimitReached(CaptureEndReason.SIZE_LIMIT),
            writer.write(packet(20), 0, 20),
        )
        val summary = writer.finish()
        assertEquals(0L, summary.packets)
        assertEquals(CaptureEndReason.SIZE_LIMIT, summary.limitReason)
        assertEquals(24, output.size())
    }

    @Test
    fun counterHandlesChunkedHeadersAndPayloads() {
        val output = ByteArrayOutputStream()
        val writer = PcapRecordWriter(output = output, maxBytes = 1_000, maxPackets = 10)
        writer.write(packet(20), 0, 20)
        writer.write(packet(21), 0, 21)
        writer.finish()
        val bytes = output.toByteArray()
        val counter = PcapRecordCounter()
        var offset = 0
        while (offset < bytes.size) {
            val size = minOf(7, bytes.size - offset)
            counter.consume(bytes, offset, size)
            offset += size
        }
        val count = counter.finish()
        assertEquals(2L, count.packets)
        assertEquals(41L, count.bytes)
        assertFalse(count.malformed)
    }

    @Test
    fun maxPacketsIsEnforcedBeforeWriting() {
        val output = ByteArrayOutputStream()
        val writer = PcapRecordWriter(output = output, maxBytes = 1_000, maxPackets = 1)
        writer.write(packet(20), 0, 20)
        assertEquals(
            PcapWriteOutcome.LimitReached(CaptureEndReason.PACKET_LIMIT),
            writer.write(packet(20), 0, 20),
        )
        assertEquals(CaptureLimits.SNAPLEN, 65_535)
    }
}
