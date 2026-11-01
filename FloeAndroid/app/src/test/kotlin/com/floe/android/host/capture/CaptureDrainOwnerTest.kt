// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.capture

import com.floe.android.core.networkcapture.CaptureDrainRegistry
import com.floe.android.core.networkcapture.CaptureMode
import com.floe.android.core.networkcapture.CaptureSinkSummary
import com.floe.android.core.networkcapture.PcapCaptureSink
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A Service scope is destroyed at an arbitrary point. The process owner must
 * keep the SAME drain alive, retry the SAME writer and finalize exactly once;
 * a bounded wait may report false meanwhile, but must never cancel the job or
 * invent a settled ledger.
 */
class CaptureDrainOwnerTest {
    private val ownerScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val owner = CaptureDrainOwner(ownerScope, retryDelayMillis = 20L)

    @After
    fun tearDown() {
        ownerScope.cancel()
    }

    private class FakeTask(
        override val sessionId: String = UUID.randomUUID().toString(),
        override val ownerToken: Any = Any(),
        override val mode: CaptureMode = CaptureMode.VPN,
        private val settleAfterAttempts: Int,
        private val onAttempt: (Int) -> Unit = {},
    ) : CaptureDrainOwner.Task<String>() {
        val attempts = AtomicInteger()
        val finalized = AtomicInteger()

        @Volatile
        var finalizedValue: String? = null

        override suspend fun attempt(): CaptureDrainOwner.Attempt<String> {
            val count = attempts.incrementAndGet()
            onAttempt(count)
            return if (count >= settleAfterAttempts) {
                CaptureDrainOwner.Attempt(true, "settled-$count")
            } else {
                CaptureDrainOwner.Attempt(false, failure = "notYet")
            }
        }

        override fun finalize(value: String) {
            finalized.incrementAndGet()
            finalizedValue = value
        }
    }

    @Test
    fun destroyedServiceScopeCannotLoseTheRetainedDrain() {
        // Long enough that the first bounded wait really times out.
        val task = FakeTask(settleAfterAttempts = 40)
        assertEquals(CaptureDrainOwner.Retention.STARTED, owner.retain(task))
        assertFalse(runBlocking { owner.awaitSettled(task.sessionId, 100L) })
        assertTrue(owner.isRetained(task.sessionId))

        // The Service is destroyed. Transferring the same resource set again
        // must not start a second loop, and must not cancel the first.
        assertEquals(CaptureDrainOwner.Retention.ALREADY_RETAINED, owner.retain(task))

        assertTrue(runBlocking { owner.awaitSettled(task.sessionId, 10_000L) })
        assertEquals(1, task.finalized.get())
        assertEquals("settled-40", task.finalizedValue)
        assertFalse(owner.isRetained(task.sessionId))
        assertTrue(task.attempts.get() >= 40)
        assertNull(owner.finalizeFailure(task.sessionId))
    }

    @Test
    fun aDifferentOwnerForTheSameSessionIsRefusedInsteadOfDoubleFinalize() {
        val session = UUID.randomUUID().toString()
        val first = FakeTask(sessionId = session, settleAfterAttempts = 20)
        val second = FakeTask(sessionId = session, settleAfterAttempts = 1)
        assertEquals(CaptureDrainOwner.Retention.STARTED, owner.retain(first))
        assertEquals(CaptureDrainOwner.Retention.CONFLICT, owner.retain(second))
        assertTrue(runBlocking { owner.awaitSettled(session, 10_000L) })
        assertEquals(1, first.finalized.get())
        assertEquals(0, second.finalized.get())
        assertEquals(0, second.attempts.get())
    }

    @Test
    fun lateWriterIsJoinedByTheSameSinkAndFinalizedOnce() {
        val output = BlockingOutput()
        val sink = PcapCaptureSink(
            output = output,
            maxBytes = 1_000_000L,
            maxPackets = 100L,
            queuePackets = 4,
            queueBytes = 1_000_000L,
        )
        sink.start()
        // Two bulk packets are required to force the 64 KiB BufferedOutputStream
        // to hand a payload-sized write to the underlying output; a single
        // 65 535-byte packet can stay entirely in that buffer.
        assertTrue(sink.offer(ByteArray(60_000) { 0x45 }, 0, 60_000))
        assertTrue(sink.offer(ByteArray(60_000) { 0x45 }, 0, 60_000))
        assertTrue(output.firstPayload.await(5, TimeUnit.SECONDS))

        val task = object : CaptureDrainOwner.Task<CaptureSinkSummary>() {
            override val sessionId: String = UUID.randomUUID().toString()
            override val mode: CaptureMode = CaptureMode.VPN
            override val ownerToken: Any = sink
            val finalized = AtomicInteger()

            override suspend fun attempt(): CaptureDrainOwner.Attempt<CaptureSinkSummary> {
                val summary = sink.closeAndDrain(100L)
                return if (summary.drained && !sink.isWriterAlive()) {
                    CaptureDrainOwner.Attempt(true, summary)
                } else {
                    CaptureDrainOwner.Attempt(false, failure = "writerStillOwnsOutput")
                }
            }

            override fun finalize(value: CaptureSinkSummary) {
                finalized.incrementAndGet()
                assertTrue(value.drained)
                assertFalse(sink.isWriterAlive())
            }
        }
        assertEquals(CaptureDrainOwner.Retention.STARTED, owner.retain(task))
        assertFalse(runBlocking { owner.awaitSettled(task.sessionId, 300L) })
        // The timeout is a real result: the writer still owns its output.
        assertFalse(output.closed)
        assertTrue(sink.isWriterAlive())
        assertEquals(0, task.finalized.get())

        output.releaseWriter()
        assertTrue(runBlocking { owner.awaitSettled(task.sessionId, 10_000L) })
        assertEquals(1, task.finalized.get())
        assertFalse(sink.isWriterAlive())
    }

    @Test
    fun ownerSettlesTheOriginalRootLedgerBeforeRetirement() {
        val registry = CaptureDrainRegistry(now = { 11L })
        val session = UUID.randomUUID().toString()
        registry.register(session, CaptureMode.ROOT)
        val attempts = AtomicInteger()
        val task = object : CaptureDrainOwner.Task<String>() {
            override val sessionId: String = session
            override val mode: CaptureMode = CaptureMode.ROOT
            override val ownerToken: Any = Any()

            override suspend fun attempt(): CaptureDrainOwner.Attempt<String> {
                val count = attempts.incrementAndGet()
                if (count < 3) {
                    registry.update(session) {
                        it.copy(
                            stopRequested = true,
                            rootStartJobJoined = count >= 2,
                        )
                    }
                    return CaptureDrainOwner.Attempt(false, failure = "drainPending")
                }
                registry.update(session) {
                    it.copy(
                        stopRequested = true,
                        rootStartJobJoined = true,
                        rootProcessExited = true,
                        rootFileOwnerClosed = true,
                        rootDrainProven = true,
                    )
                }
                assertTrue(registry.isSettled(session))
                return CaptureDrainOwner.Attempt(true, "done")
            }

            override fun finalize(value: String) {
                assertTrue(registry.completeAfterFinalize(session))
            }
        }
        assertEquals(CaptureDrainOwner.Retention.STARTED, owner.retain(task))
        // The first attempt cannot satisfy every root owner, so RootStop's
        // exact ledger gate must stay false while async work is outstanding.
        assertFalse(registry.isSettled(session))
        assertTrue(runBlocking { owner.awaitSettled(session, 10_000L) })
        assertNull(registry.snapshot(session))
        assertTrue(registry.isSettled(session))
        assertEquals(3, attempts.get())
    }

    private class BlockingOutput : OutputStream() {
        val firstPayload = CountDownLatch(1)
        private val releaseLatch = CountDownLatch(1)

        @Volatile
        var closed = false
            private set

        init {
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
            // Header/flush bytes are buffered by the sink.
        }

        override fun write(b: ByteArray, off: Int, len: Int) {
            if (len >= 1_000) {
                firstPayload.countDown()
                await()
            }
        }

        private fun await() {
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
}
