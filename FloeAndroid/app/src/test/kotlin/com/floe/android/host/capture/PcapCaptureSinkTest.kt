// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.capture

import com.floe.android.core.networkcapture.CaptureEndReason
import com.floe.android.core.networkcapture.PcapCaptureSink
import java.io.OutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PcapCaptureSinkTest {

    private class BlockingOutput : OutputStream() {
        val firstPayloadWritten = CountDownLatch(1)
        private val release = CountDownLatch(1)

        override fun write(b: Int) = Unit

        override fun write(b: ByteArray, off: Int, len: Int) {
            // A single small packet can remain inside the sink's 64 KiB
            // BufferedOutputStream, so only a real payload-sized write is a
            // reliable "the writer is blocked here" signal.
            if (len >= 1_000) {
                firstPayloadWritten.countDown()
                await()
            }
        }

        private fun await() {
            try {
                release.await(5, TimeUnit.SECONDS)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }

        fun release() {
            release.countDown()
        }
    }

    @Test
    fun queueDropsWhenBothPacketAndByteBudgetsAreFull() {
        val output = BlockingOutput()
        val sink = PcapCaptureSink(
            output = output,
            maxBytes = 10_000_000,
            maxPackets = 100,
            queuePackets = 1,
            queueBytes = 200_000,
        )
        sink.start()
        // Two bulk packets are needed to force the 64 KiB BufferedOutputStream
        // to hand a payload-sized write to the underlying (blocking) owner.
        assertTrue(sink.offer(ByteArray(60_000) { 0x45 }, 0, 60_000))
        assertTrue(sink.offer(ByteArray(60_000) { 0x45 }, 0, 60_000))
        assertTrue(output.firstPayloadWritten.await(5, TimeUnit.SECONDS))
        // The writer is blocked on the second payload, so the queue can hold
        // exactly one more packet and must reject the fourth copy.
        assertTrue(sink.offer(ByteArray(60_000) { 0x45 }, 0, 60_000))
        assertFalse(sink.offer(ByteArray(60_000) { 0x45 }, 0, 60_000))
        val stats = sink.stats()
        assertEquals(3L, stats.capturedPackets)
        assertEquals(1L, stats.droppedPackets)
        output.release()
        // Let the already-admitted third packet drain before closing; otherwise
        // close's poison-marker admission would evict it and count another drop
        // (a documented close policy, not the queue rule under test).
        val deadline = System.nanoTime() + 5_000_000_000L
        while (sink.stats().writtenPackets < 3L && System.nanoTime() < deadline) {
            Thread.sleep(10L)
        }
        assertEquals(3L, sink.stats().writtenPackets)
        val summary = sink.closeAndDrain(5_000)
        assertTrue(summary.drained)
        assertEquals(3L, summary.writtenPackets)
        assertEquals(1L, summary.droppedPackets)
    }

    @Test
    fun writerLimitIsReportedAndLaterOffersAreDropped() {
        val sink = PcapCaptureSink(
            output = OutputStream.nullOutputStream(),
            maxBytes = 24 + 16 + 10,
            maxPackets = 100,
            queuePackets = 8,
            queueBytes = 1_024,
        )
        sink.start()
        assertTrue(sink.offer(ByteArray(20) { 0x45 }, 0, 20))
        // Let the writer observe the size limit.
        val deadline = System.nanoTime() + 5_000_000_000L
        while (sink.limitReason() == null && System.nanoTime() < deadline) {
            Thread.sleep(10)
        }
        assertEquals(CaptureEndReason.SIZE_LIMIT, sink.limitReason())
        assertFalse(sink.offer(ByteArray(20) { 0x45 }, 0, 20))
        val summary = sink.closeAndDrain(5_000)
        assertEquals(CaptureEndReason.SIZE_LIMIT, summary.limitReason)
        assertEquals(1L, summary.capturedPackets)
    }

    @Test
    fun emptyCloseIsDrainedWithoutAWriterStart() {
        val sink = PcapCaptureSink(
            output = OutputStream.nullOutputStream(),
            maxBytes = 1_024,
        )
        val summary = sink.closeAndDrain(1_000)
        assertTrue(summary.drained)
        assertEquals(0L, summary.writtenPackets)
    }
}
