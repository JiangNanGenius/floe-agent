// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.networkcapture

import java.io.BufferedOutputStream
import java.io.IOException
import java.io.OutputStream
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

data class CaptureSinkSummary(
    val writtenPackets: Long,
    val writtenBytes: Long,
    val capturedPackets: Long,
    val capturedBytes: Long,
    val droppedPackets: Long,
    val droppedBytes: Long,
    val truncatedPackets: Long,
    val unsupportedPackets: Long,
    val ipv6BypassedPackets: Long,
    val limitReason: CaptureEndReason?,
    val drained: Boolean,
    val failure: CaptureFailure?,
)

/**
 * Bounded packet queue feeding a single PCAP writer thread.
 *
 * The VPN reader must never block on slow storage: [offer] copies at most one
 * MTU packet, admits it only when both the packet and byte budgets allow, and
 * otherwise counts a real drop. The queue is drained before the artifact is
 * finalized; a timeout leaves [CaptureSinkSummary.drained] false and is never
 * reported as success.
 */
class PcapCaptureSink(
    output: OutputStream,
    private val maxBytes: Long = CaptureLimits.MAX_BYTES,
    private val maxPackets: Long = CaptureLimits.MAX_PACKETS,
    private val queuePackets: Int = CaptureLimits.MAX_QUEUE_PACKETS,
    private val queueBytes: Long = CaptureLimits.MAX_QUEUE_BYTES,
    private val maxPacketBytes: Int = CaptureLimits.MAX_PACKET_BYTES,
    private val nowEpochMicros: () -> Long = { System.currentTimeMillis() * 1_000L },
) {
    init {
        require(queuePackets > 0) { "queuePackets" }
        require(queueBytes > 0) { "queueBytes" }
        require(maxPacketBytes in 1..CaptureLimits.MAX_PACKET_BYTES) { "maxPacketBytes" }
    }

    private val stream = BufferedOutputStream(output, 64 * 1024)
    private val writer = PcapRecordWriter(
        output = stream,
        maxBytes = maxBytes,
        maxPackets = maxPackets,
        nowEpochMicros = nowEpochMicros,
    )
    private val queue = ArrayBlockingQueue<ByteArray>(queuePackets)
    private val queuedBytes = AtomicLong(0)
    private val capturedPackets = AtomicLong(0)
    private val capturedBytes = AtomicLong(0)
    private val writtenPackets = AtomicLong(0)
    private val writtenBytes = AtomicLong(0)
    private val droppedPackets = AtomicLong(0)
    private val droppedBytes = AtomicLong(0)
    private val truncatedPackets = AtomicLong(0)
    private val unsupportedPackets = AtomicLong(0)
    private val ipv6BypassedPackets = AtomicLong(0)
    private val closed = AtomicBoolean(false)
    private val started = AtomicBoolean(false)
    private val limitReason = AtomicReference<CaptureEndReason?>(null)
    private val failure = AtomicReference<CaptureFailure?>(null)
    private val drainLock = Any()
    private var closeSummary: CaptureSinkSummary? = null
    @Volatile
    private var thread: Thread? = null

    fun start() {
        if (!started.compareAndSet(false, true)) return
        thread = Thread({ runWriter() }, "floe-pcap-writer").also { it.start() }
    }

    /** Called from the single VPN reader thread; never blocks on disk. */
    fun offer(packet: ByteArray, offset: Int, length: Int): Boolean {
        require(offset >= 0 && length >= 0 && offset + length <= packet.size) { "packet bounds" }
        if (!started.get() || closed.get() || limitReason.get() != null) {
            recordDrop(length)
            return false
        }
        if (length == 0) return true
        if (length > maxPacketBytes) {
            unsupportedPackets.incrementAndGet()
            recordDrop(length)
            return false
        }
        val copy = packet.copyOfRange(offset, offset + length)
        val pending = queuedBytes.addAndGet(length.toLong())
        if (pending > queueBytes || !queue.offer(copy)) {
            queuedBytes.addAndGet(-length.toLong())
            recordDrop(length)
            return false
        }
        capturedPackets.incrementAndGet()
        capturedBytes.addAndGet(length.toLong())
        return true
    }

    fun noteUnsupportedPacket() {
        unsupportedPackets.incrementAndGet()
    }

    fun noteIpv6Bypassed() {
        ipv6BypassedPackets.incrementAndGet()
    }

    fun limitReason(): CaptureEndReason? = limitReason.get()

    fun stats(): CaptureStats = CaptureStats(
        capturedPackets = capturedPackets.get(),
        capturedBytes = capturedBytes.get(),
        writtenPackets = writtenPackets.get(),
        writtenBytes = writtenBytes.get(),
        droppedPackets = droppedPackets.get(),
        droppedBytes = droppedBytes.get(),
        truncatedPackets = truncatedPackets.get(),
        unsupportedPackets = unsupportedPackets.get(),
        ipv6BypassedPackets = ipv6BypassedPackets.get(),
    )

    fun isWriterAlive(): Boolean = thread?.isAlive == true

    /**
     * Close the input side and wait for the writer to settle. The call is
     * repeatable: a timed-out owner stays the same writer thread, and a later
     * call joins it without replaying the capture or closing its output while
     * the writer is alive. A false [CaptureSinkSummary.drained] is a real
     * result, not a success.
     */
    fun closeAndDrain(timeoutMillis: Long): CaptureSinkSummary {
        require(timeoutMillis > 0) { "timeout" }
        synchronized(drainLock) {
            closeSummary?.let { return it }
            if (closed.compareAndSet(false, true)) {
                // Leave room for the poison marker even when the queue is full.
                val poison = ByteArray(0)
                var offered = queue.offer(poison)
                while (!offered) {
                    val evicted = queue.poll()
                    if (evicted != null) {
                        queuedBytes.addAndGet(-evicted.size.toLong())
                        recordDrop(evicted.size)
                    }
                    offered = queue.offer(poison)
                }
            }
            val worker = thread
            if (worker != null) {
                worker.join(timeoutMillis)
                if (worker.isAlive) {
                    worker.interrupt()
                    worker.join(250L)
                }
            }
            val drained = worker?.isAlive != true
            if (!drained) {
                // The writer still owns the output. Do not flush/finish/close
                // it; the next stop attempt joins this same thread.
                //
                // Do NOT call writer.snapshot() here: PcapRecordWriter.write
                // is @Synchronized and may hold its monitor while blocked in
                // the underlying output write. Calling snapshot() would make
                // this "bounded" timeout wait for that stalled write and
                // defeat the caller's stop budget. The sink's own atomics are
                // the non-blocking view of the completed records.
                return CaptureSinkSummary(
                    writtenPackets = writtenPackets.get(),
                    writtenBytes = writtenBytes.get(),
                    capturedPackets = capturedPackets.get(),
                    capturedBytes = capturedBytes.get(),
                    droppedPackets = droppedPackets.get(),
                    droppedBytes = droppedBytes.get(),
                    truncatedPackets = truncatedPackets.get(),
                    unsupportedPackets = unsupportedPackets.get(),
                    ipv6BypassedPackets = ipv6BypassedPackets.get(),
                    limitReason = limitReason.get(),
                    drained = false,
                    failure = failure.get(),
                )
            }
            writer.flush()
            stream.flush()
            val summary = writer.finish()
            val value = CaptureSinkSummary(
                writtenPackets = writtenPackets.get(),
                writtenBytes = writtenBytes.get(),
                capturedPackets = capturedPackets.get(),
                capturedBytes = capturedBytes.get(),
                droppedPackets = droppedPackets.get(),
                droppedBytes = droppedBytes.get(),
                truncatedPackets = summary.truncatedPackets,
                unsupportedPackets = unsupportedPackets.get(),
                ipv6BypassedPackets = ipv6BypassedPackets.get(),
                limitReason = limitReason.get() ?: summary.limitReason,
                drained = true,
                failure = failure.get(),
            )
            closeSummary = value
            return value
        }
    }

    fun flushForTest() {
        check(!isWriterAlive()) { "writer still owns the capture output" }
        writer.flush()
        stream.flush()
    }

    private fun runWriter() {
        try {
            while (true) {
                val packet = queue.take()
                if (packet.isEmpty()) break
                queuedBytes.addAndGet(-packet.size.toLong())
                val outcome = writer.write(packet, 0, packet.size)
                when (outcome) {
                    is PcapWriteOutcome.Written -> {
                        writtenPackets.incrementAndGet()
                        writtenBytes.addAndGet(outcome.capturedBytes.toLong())
                        if (outcome.truncated) truncatedPackets.incrementAndGet()
                    }
                    is PcapWriteOutcome.LimitReached -> {
                        limitReason.compareAndSet(null, outcome.reason)
                        // The writer already refused this packet; count it as
                        // a real drop and keep draining the queue so close is
                        // prompt and byte accounting stays honest.
                        droppedPackets.incrementAndGet()
                        droppedBytes.addAndGet(packet.size.toLong())
                    }
                }
            }
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
        } catch (e: IOException) {
            failure.compareAndSet(
                null,
                CaptureFailure("pcapWriteFailed", e.message?.take(160)),
            )
        } finally {
            // A writer interrupted after close still owns queued packets; they
            // are real drops, not silent losses.
            while (true) {
                val pending = queue.poll() ?: break
                if (pending.isEmpty()) continue
                queuedBytes.addAndGet(-pending.size.toLong())
                recordDrop(pending.size)
            }
            writer.flush()
            stream.flush()
        }
    }

    private fun recordDrop(length: Int) {
        droppedPackets.incrementAndGet()
        droppedBytes.addAndGet(length.toLong())
    }
}
