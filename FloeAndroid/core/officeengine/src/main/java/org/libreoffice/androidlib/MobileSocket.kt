/* -*- Mode: C++; tab-width: 4; indent-tabs-mode: nil; c-basic-offset: 4 -*- */
/*
 * This Source Code Form is derived from the Collabora Online / LibreOffice
 * android lib (upstream MobileSocket.java) and is subject to the terms of the
 * Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed
 * with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Floe G05-R1 changes vs upstream:
 *  - The send queue is BOUNDED (message count + bytes + bounded offer wait)
 *    instead of an unbounded LinkedBlockingQueue that could stall forever.
 *  - Response streams are bounded too: at most [MAX_INFLIGHT_STREAMS] open
 *    deliveries and [MAX_INFLIGHT_BYTES] drained-but-undelivered bytes; the
 *    slot/byte reservation is released on every path, and drained messages
 *    are accounted until actually written or failed.
 *  - A delivery failure on a LIVE session is surfaced once through
 *    [SocketHost.transportFailed] (never requeued with burned serials, which
 *    would silently stall the page's serial-contiguous processor); a failure
 *    after normal close/unload settles quietly because the session is gone.
 *  - Framing stays byte-identical: the pinned 26.04 mobile dist
 *    (dist/global.js ProxySocket) parses it and assigns serials per send.
 */
package org.libreoffice.androidlib

import android.util.Log
import android.webkit.WebResourceResponse
import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.PipedInputStream
import java.io.PipedOutputStream
import java.nio.ByteBuffer
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.Semaphore

/**
 * Sends native-side messages to the in-page fake websocket through the
 * intercepted `cool:` request channel (ProxySocket protocol).
 *
 * Upstream return-path comment applies unchanged: responses go through the
 * intercepted request stream; JS -> native returns still call
 * [LOActivity.postMobileMessage], because Android cannot read the body of an
 * intercepted request.
 */
class MobileSocket(private val host: SocketHost) {

    interface SocketHost {
        /** Schedule `window.socket.doSend()` on the UI thread. Never blocks. */
        fun triggerSend()

        /**
         * The bounded transport failed (closed session, offer wait exceeded,
         * executor rejection or a delivery error while live). The owning
         * session must surface this honestly: messages are never silently
         * dropped and readiness is never implied.
         */
        fun transportFailed(reason: String)

        fun isClosed(): Boolean
    }

    companion object {
        private const val LOG_TAG = "MobileSocket"
        const val MAX_QUEUED_MESSAGES = 1024
        const val MAX_QUEUED_BYTES: Long = 64L shl 20 // 64 MiB waiting to be sent
        const val MAX_INFLIGHT_STREAMS = 4 // matches the page ProxySocket msgInflight cap
        const val MAX_INFLIGHT_BYTES: Long = 96L shl 20 // 96 MiB drained-but-undelivered
        const val OFFER_WAIT_MS = 5_000L

        /**
         * Byte-identical ProxySocket framing of upstream MobileSocket.java:
         * 'T'|'B' + "0x<hex serial>\n" + "0x<hex size>\n" + message + "\n".
         * Binary ('B') iff the message itself contains a newline byte.
         */
        @JvmStatic
        fun frame(serial: Int, message: ByteArray): ByteArray {
            val serialString = Integer.toString(serial, 16).toByteArray()
            val sizeString = Integer.toString(message.size, 16).toByteArray()
            var binary = false
            for (b in message) {
                if (b == '\n'.code.toByte()) {
                    binary = true
                    break
                }
            }
            val header = ByteBuffer.allocate(
                1 + 2 + serialString.size + 1 + 2 + sizeString.size + 1,
            )
            header.put(if (binary) 'B'.code.toByte() else 'T'.code.toByte())
            header.put('0'.code.toByte())
            header.put('x'.code.toByte())
            header.put(serialString)
            header.put('\n'.code.toByte())
            header.put('0'.code.toByte())
            header.put('x'.code.toByte())
            header.put(sizeString)
            header.put('\n'.code.toByte())
            return header.array() + message + '\n'.code.toByte()
        }
    }

    private val lock = Object()
    private val queue = ArrayDeque<ByteArray>()

    @Volatile
    private var serial = 0
    private var queuedBytes = 0L
    private var inflightBytes = 0L
    private var closed = false
    private var failureReported = false
    private val streamSlots = Semaphore(MAX_INFLIGHT_STREAMS, true)
    private val flushExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    private fun reportFailureOnce(reason: String) {
        synchronized(lock) {
            if (failureReported) return
            failureReported = true
        }
        Log.e(LOG_TAG, "MobileSocket transport failed: $reason")
        host.transportFailed(reason)
    }

    /**
     * Enqueue a message for the JS side and arm one `doSend()` poll.
     * Blocks up to [OFFER_WAIT_MS] under backpressure (queue full or the
     * combined queue+inflight byte budget exhausted). Returns false, and
     * reports the failure once, when the session is closed or the bounded
     * transport cannot accept the message: the owning session must then leave
     * any readiness claim. Never throws across the JNI callback boundary.
     */
    fun queueSend(message: ByteArray): Boolean {
        if (closed) {
            reportFailureOnce("closed")
            return false
        }
        val deadline = System.currentTimeMillis() + OFFER_WAIT_MS
        synchronized(lock) {
            while (
                queue.size >= MAX_QUEUED_MESSAGES ||
                queuedBytes + message.size > MAX_QUEUED_BYTES ||
                queuedBytes + inflightBytes + message.size > (MAX_QUEUED_BYTES + MAX_INFLIGHT_BYTES)
            ) {
                if (closed) {
                    reportFailureOnce("closed")
                    return false
                }
                val wait = deadline - System.currentTimeMillis()
                if (wait <= 0L) {
                    reportFailureOnce("bounded-queue-timeout")
                    return false
                }
                try {
                    lock.wait(wait)
                } catch (e: InterruptedException) {
                    Thread.currentThread().interrupt()
                    reportFailureOnce("interrupted")
                    return false
                }
            }
            if (closed) {
                reportFailureOnce("closed")
                return false
            }
            queue.addLast(message)
            queuedBytes += message.size
        }
        host.triggerSend()
        return true
    }

    /**
     * Reserve up to one response batch under the inflight byte budget.
     * Returns the drained messages (already accounted as inflight bytes) or
     * an empty list when nothing may be drained right now.
     */
    private fun reserveBatch(): List<ByteArray> {
        synchronized(lock) {
            if (closed || queue.isEmpty() || inflightBytes >= MAX_INFLIGHT_BYTES) {
                return emptyList()
            }
            val budget = MAX_INFLIGHT_BYTES - inflightBytes
            val batch = ArrayList<ByteArray>()
            var bytes = 0L
            while (queue.isNotEmpty()) {
                val next = queue.first()
                if (bytes + next.size > budget) break
                queue.removeFirst()
                queuedBytes -= next.size
                batch.add(next)
                bytes += next.size
                if (bytes >= budget) break
            }
            inflightBytes += bytes
            lock.notifyAll()
            return batch
        }
    }

    private fun releaseBatch(bytes: Long) {
        synchronized(lock) {
            inflightBytes -= bytes
            if (inflightBytes < 0) inflightBytes = 0
            lock.notifyAll()
        }
    }

    fun open(): WebResourceResponse {
        serial = 0
        val name = "mobile".toByteArray()
        return COWebViewClient.response(
            200,
            "OK",
            ByteArrayInputStream(name),
            name.size.toLong(),
        )
    }

    /**
     * One intercepted `write` response. Concurrency and bytes are bounded by
     * [streamSlots] plus the inflight byte reservation; when no slot/budget is
     * free the page gets an honest empty response and stays armed for the next
     * trigger (nothing is lost). Serials advance only at frame/send time,
     * exactly like upstream, so the page's serial-contiguous parser never sees
     * a burned gap.
     */
    fun write(): WebResourceResponse {
        if (closed) {
            return COWebViewClient.response(503, "Service Unavailable")
        }
        if (!streamSlots.tryAcquire()) {
            return emptyResponse()
        }
        val batch = reserveBatch()
        if (batch.isEmpty()) {
            streamSlots.release()
            return emptyResponse()
        }
        val batchBytes = batch.sumOf { it.size.toLong() }
        val data: PipedInputStream
        val output = PipedOutputStream()
        try {
            data = PipedInputStream(output)
        } catch (e: IOException) {
            releaseBatch(batchBytes)
            streamSlots.release()
            reportFailureOnce("pipe-io:${e.message}")
            return COWebViewClient.response(503, "Service Unavailable")
        }
        try {
            flushExecutor.execute {
                var failure: Throwable? = null
                try {
                    for (message in batch) {
                        // frame() carries header + message + terminator,
                        // matching upstream's three writes byte-for-byte.
                        // PipedOutputStream.write blocks until the reader
                        // consumed the bytes: success here means delivered.
                        output.write(frame(++serial, message))
                    }
                } catch (e: Throwable) {
                    failure = e
                } finally {
                    // Undelivered bytes of a failed batch are NOT requeued:
                    // the failed reader is gone, and their serials were
                    // already handed to the page-side parser positionally.
                    // Re-framing them would burn serials and stall the
                    // contiguous processor. Instead the failure is surfaced.
                    releaseBatch(batchBytes)
                    try {
                        output.close()
                    } catch (ignored: IOException) {
                    }
                    streamSlots.release()
                    if (failure != null) {
                        val live = !host.isClosed()
                        if (live) {
                            reportFailureOnce("delivery-io:${failure.message}")
                        } else {
                            Log.d(LOG_TAG, "response stream ended after session close: ${failure.message}")
                        }
                    }
                }
            }
        } catch (e: RejectedExecutionException) {
            // Executor already shut down (close raced this request): the
            // drained batch cannot be delivered. Settle quietly if closing,
            // fail honestly if the session is somehow still live.
            releaseBatch(batchBytes)
            try {
                data.close()
            } catch (ignored: IOException) {
            }
            streamSlots.release()
            if (!host.isClosed()) {
                reportFailureOnce("executor-shutdown")
            }
            return COWebViewClient.response(503, "Service Unavailable")
        }
        return COWebViewClient.response(200, "OK", data)
    }

    private fun emptyResponse(): WebResourceResponse {
        val empty = ByteArrayInputStream(ByteArray(0))
        return COWebViewClient.response(200, "OK", empty, 0L)
    }

    /** Close the transport for the current session exactly once. */
    fun close() {
        val drained: Int
        synchronized(lock) {
            if (closed) return
            closed = true
            drained = queue.size
            queue.clear()
            queuedBytes = 0
            lock.notifyAll()
        }
        flushExecutor.shutdownNow()
        if (drained > 0) {
            Log.i(LOG_TAG, "closed with $drained undelivered message(s); session is ending")
        }
    }

    val isClosed: Boolean
        get() = synchronized(lock) { closed }

    /** Diagnostics for honest session reporting (no behavioural coupling). */
    fun snapshot(): Pair<Int, Long> = synchronized(lock) {
        Pair(queue.size, queuedBytes)
    }
}
