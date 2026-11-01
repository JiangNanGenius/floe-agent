// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.capture

import com.floe.android.core.networkcapture.CaptureArtifactStore
import com.floe.android.core.networkcapture.CaptureMode
import com.floe.android.core.networkcapture.CaptureOwner
import com.floe.android.core.networkcapture.CapturePhase
import com.floe.android.core.networkcapture.CaptureSinkSummary
import com.floe.android.core.networkcapture.CaptureState
import com.floe.android.core.networkcapture.PcapCaptureSink
import java.io.File
import java.io.IOException
import java.io.OutputStream
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * The writer owns the output until it actually joins. A timeout must not be
 * converted into a closed/renamed artifact, and a later retry must join the
 * exact same thread without creating another capture.
 */
class CaptureLateWriterDrainTest {
    private val root: File = Files.createTempDirectory("floe-late-writer").toFile()
    private val owner = CaptureOwner(ownerId = "late-writer", nativeEpoch = 1)

    @After
    fun cleanup() {
        root.deleteRecursively()
    }

    private class BlockingOutput : OutputStream() {
        val firstPayload = CountDownLatch(1)
        private val releaseLatch = CountDownLatch(1)
        var closed = false

        init {
            // Bound the test process: a writer that is never explicitly
            // released cannot keep the JVM alive.
            Thread {
                try {
                    Thread.sleep(10_000L)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                }
                releaseWriter()
            }.also { it.isDaemon = true; it.start() }
        }

        override fun write(b: Int) {
            // Header/flush bytes are buffered by the sink; only a real bulk
            // payload write blocks this test writer.
        }

        override fun write(b: ByteArray, off: Int, len: Int) {
            if (len >= 1_000) {
                firstPayload.countDown()
                await()
            }
        }

        private fun await() {
            // A stop deadline may interrupt the writer; the output owner is
            // still blocked until the test explicitly releases it.
            while (releaseLatch.count > 0) {
                try {
                    releaseLatch.await(5, TimeUnit.SECONDS)
                } catch (_: InterruptedException) {
                    Thread.interrupted()
                }
            }
        }

        fun releaseWriter() {
            releaseLatch.countDown()
        }

        override fun close() {
            closed = true
        }
    }

    @Test
    fun timedOutSinkStaysOwnedAndRetryJoinsTheSameWriter() {
        val output = BlockingOutput()
        val sink = PcapCaptureSink(
            output = output,
            maxBytes = 1_000_000,
            maxPackets = 100,
            queuePackets = 4,
            queueBytes = 1_000_000,
        )
        sink.start()
        // The sink's 64 KiB BufferedOutputStream can retain one full MTU
        // packet, so two bulk packets are required to make the underlying
        // output owner actually block (the state this test proves).
        assertTrue(sink.offer(ByteArray(60_000) { 0x45 }, 0, 60_000))
        assertTrue(sink.offer(ByteArray(60_000) { 0x45 }, 0, 60_000))
        assertTrue(output.firstPayload.await(5, TimeUnit.SECONDS))
        val first = sink.closeAndDrain(100)
        assertFalse(first.drained)
        assertTrue(sink.isWriterAlive())
        assertFalse(output.closed)
        output.releaseWriter()
        val second = sink.closeAndDrain(5_000)
        assertTrue(second.drained)
        assertFalse(sink.isWriterAlive())
        assertEquals(first.capturedPackets, second.capturedPackets)
        assertEquals(2L, second.writtenPackets)
    }

    @Test
    fun storeRefusesToFinalizeWhileWriterStillOwnsOutput() {
        val store = CaptureArtifactStore(root)
        val session = UUID.randomUUID().toString()
        val artifact = store.begin(
            sessionId = session,
            owner = owner,
            mode = CaptureMode.VPN,
            detailed = false,
            maxBytes = 1_000_000,
            maxPackets = 100,
            maxDurationMillis = 60_000,
        )
        artifact.sink.start()
        assertTrue(artifact.sink.isWriterAlive())
        // The store must refuse before touching bytes while the writer still
        // owns the output. This is the exact guard; no timing-dependent
        // "close finished during the wait" window is used.
        val summary = CaptureSinkSummary(
            writtenPackets = 0L,
            writtenBytes = 0L,
            capturedPackets = 0L,
            capturedBytes = 0L,
            droppedPackets = 0L,
            droppedBytes = 0L,
            truncatedPackets = 0L,
            unsupportedPackets = 0L,
            ipv6BypassedPackets = 0L,
            limitReason = null,
            drained = false,
            failure = null,
        )
        try {
            store.finalize(
                artifact = artifact,
                sink = summary,
                state = CaptureState(
                    sessionId = session,
                    owner = owner,
                    mode = CaptureMode.VPN,
                    phase = CapturePhase.FINALIZING,
                ),
                startedAtMillis = 1L,
                endedAtMillis = 2L,
                limitations = emptyList(),
            )
            fail("finalize must fail while the writer owns the output")
        } catch (_: IOException) {
            // expected
        }
        assertTrue(artifact.sink.isWriterAlive())
        assertTrue(artifact.stagingFile.isFile)
        assertFalse(File(root, "capture-$session.pcap").exists())
        // The same artifact is retained; no replacement capture was created.
        assertEquals(
            1,
            File(root, "staging").listFiles()?.count { it.name.endsWith(".part") } ?: 0,
        )
        // Let the idle writer exit before the shared temp directory is removed.
        assertTrue(artifact.sink.closeAndDrain(5_000).drained)
    }
}
