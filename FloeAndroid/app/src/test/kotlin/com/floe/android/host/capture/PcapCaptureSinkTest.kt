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
        var afterFirst = false

        override fun write(b: Int) {
            if (afterFirst) await()
        }

        override fun write(b: ByteArray, off: Int, len: Int) {
            if (afterFirst && len == 20) {
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
            afterFirst = true
            release.countDown()
        }
    }

    @Test
    fun queueDropsWhenBothPacketAndByteBudgetsAreFull() {
        val output = BlockingOutput()
        val sink = PcapCaptureSink(
            output = output,
            maxBytes = 1_000_000,
            maxPackets = 100,
            queuePackets = 1,
            queueBytes = 64,
        )
        sink.start()
        assertTrue(sink.offer(ByteArray(20) { 0x45 }, 0, 20))
        assertTrue(output.firstPayloadWritten.await(5, TimeUnit.SECONDS))
        // The writer is blocked on the first payload, so the queue can now
        // hold exactly one more packet and must reject the third copy.
        assertTrue(sink.offer(ByteArray(20) { 0x45 }, 0, 20))
        assertFalse(sink.offer(ByteArray(20) { 0x45 }, 0, 20))
        val stats = sink.stats()
        assertEquals(2L, stats.capturedPackets)
        assertEquals(1L, stats.droppedPackets)
        output.release()
        val summary = sink.closeAndDrain(5_000)
        assertTrue(summary.drained)
        assertEquals(2L, summary.writtenPackets)
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
