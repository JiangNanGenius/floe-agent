/* -*- Mode: C++; tab-width: 4; indent-tabs-mode: nil; c-basic-offset: 4 -*- */
/*
 * This Source Code Form is derived from the Collabora Online / LibreOffice
 * android lib (upstream MobileSocket.java) and is subject to the terms of the
 * Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed
 * with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Floe changes vs upstream:
 *  - The send queue is BOUNDED (message count + bytes + bounded offer wait)
 *    instead of an unbounded LinkedBlockingQueue that could stall forever.
 *  - Response bodies are BOUNDED too, and the native side keeps its own bound
 *    on the bytes it has handed to the page but not seen finished
 *    ([OutstandingResponseLedger], limit [MAX_OUTSTANDING_BYTES]); queue plus
 *    outstanding together stay under [MAX_TOTAL_NATIVE_BYTES].
 *  - A transport failure on a live session is surfaced once through
 *    [SocketHost.transportFailed]; nothing is silently dropped and nothing is
 *    requeued with burned serials (which would wedge the page's serial-keyed
 *    processor). After a normal close the session is gone, so it settles
 *    quietly.
 *  - Framing stays byte-identical: the pinned 26.04 mobile dist
 *    (dist/global.js ProxySocket) parses it and assigns serials per send.
 *
 * G05-R2 delivery repair (ACTUAL Alpha13 C02 tablet failure, 2026-10-26;
 * full evidence in the private handoff): delivery is SYNCHRONOUS and
 * NON-BLOCKING. The previous revision answered each `write` with a
 * PipedInputStream fed by ONE shared flush thread behind a 4-permit semaphore
 * held until that thread finished. PipedOutputStream.write blocks on the 1 KiB
 * pipe buffer, so one reader that stopped consuming starved every other
 * reserved response; those XHRs never fired `loadend`, the page's in-flight
 * counter pinned at its hard cap of 4 (dist/global.js `ProxySocket.doSend`),
 * and because the pinned mobile socket deletes `_setPollInterval` and no-ops
 * `close()`, a `doSend()` that early-returns at that cap has no self-recovery.
 * The transport stalled for minutes (blank canvas, permanent "Opening"), then
 * the page's own 30 s no-response watchdog fired `_signalErrorClose()`, which
 * the mobile frontend can never reconnect from.
 *
 * So: each body is framed in memory and served from a stream that cannot
 * block, no response holds a resource another response needs, and there is no
 * stream-count permit to starve. Progress and honesty rules:
 *  - [planBatch] ALWAYS takes at least one queued message, so a head larger
 *    than the per-response bound is delivered alone instead of wedging the
 *    queue forever;
 *  - a bounded batch re-arms exactly one poll, because this host is the mobile
 *    socket's only poll source;
 *  - serials are assigned under the queue lock in drain order, so the page
 *    never sees a gap or a duplicate;
 *  - when the outstanding ledger genuinely cannot fit the next body, `write()`
 *    fails honestly (reported once, 503) — it never answers with a silent
 *    empty body, which would leave the queued tail waiting for a delivery that
 *    is not coming.
 */
package org.libreoffice.androidlib

import android.util.Log
import android.webkit.WebResourceResponse
import java.io.ByteArrayInputStream
import java.util.concurrent.atomic.AtomicBoolean

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
         * The bounded transport failed (closed session, exhausted offer wait,
         * interrupt, or an outstanding-body budget that cannot fit the next
         * response). The owning session must surface this honestly: messages
         * are never silently dropped and readiness is never implied.
         */
        fun transportFailed(reason: String)
    }

    companion object {
        private const val LOG_TAG = "MobileSocket"
        const val MAX_QUEUED_MESSAGES = 1024
        const val MAX_QUEUED_BYTES: Long = 64L shl 20 // 64 MiB waiting to be sent
        const val OFFER_WAIT_MS = 5_000L

        /**
         * Native-owned ceiling on response bodies already handed to the page
         * but not yet finished (EOF/close). Replaces the previous
         * `MAX_INFLIGHT_BYTES` reservation: same bound, but released by the
         * response stream itself instead of by a flush task, so a slow reader
         * can only ever hold its OWN bytes.
         */
        const val MAX_OUTSTANDING_BYTES: Long = 96L shl 20 // 96 MiB handed to the page

        /** Combined native bound: queued bytes + outstanding response bytes. */
        const val MAX_TOTAL_NATIVE_BYTES: Long = MAX_QUEUED_BYTES + MAX_OUTSTANDING_BYTES

        /** Target bound for ONE response body (framed bytes, not payloads). */
        const val MAX_RESPONSE_MESSAGES = 128
        const val MAX_RESPONSE_BYTES: Long = 8L shl 20 // 8 MiB per response body

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
            val header = java.nio.ByteBuffer.allocate(
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

        /**
         * Exact framed length of one message, so a batch can be planned
         * against the REAL body size instead of an approximation.
         */
        @JvmStatic
        fun framedSize(serial: Int, messageSize: Int): Int {
            require(messageSize >= 0) { "messageSize must not be negative" }
            return 1 + 2 + Integer.toString(serial, 16).length + 1 +
                2 + Integer.toString(messageSize, 16).length + 1 +
                messageSize + 1
        }

        /**
         * The exact bytes of one response body: [frame] over [messages] with
         * ascending contiguous serials starting at [startSerial]. Byte-for-byte
         * what upstream produced by writing each framed message into the
         * response stream in order, so dist/global.js `parseIncomingArray` sees
         * an unchanged wire format.
         */
        @JvmStatic
        fun frameBatch(startSerial: Int, messages: List<ByteArray>): ByteArray {
            if (messages.isEmpty()) return ByteArray(0)
            val frames = ArrayList<ByteArray>(messages.size)
            var total = 0
            for (index in messages.indices) {
                val framed = frame(startSerial + index, messages[index])
                frames.add(framed)
                total += framed.size
            }
            val body = ByteArray(total)
            var offset = 0
            for (framed in frames) {
                framed.copyInto(body, offset)
                offset += framed.size
            }
            return body
        }

        /**
         * How many LEADING queued messages fit into one response body of at
         * most [maxBytes] FRAMED bytes, serials starting at [startSerial].
         *
         * Guarantees, in order:
         *  - an empty queue plans 0 (the page then gets an empty 200, exactly
         *    like upstream's drain-nothing-and-close);
         *  - at most [maxMessages] messages and at most [maxBytes] framed
         *    bytes, unless the next message is the head;
         *  - ALWAYS at least 1 for a non-empty queue. The head is taken even
         *    when it alone exceeds [maxBytes]: refusing it would wedge the
         *    queue permanently, the one stall this transport must be unable to
         *    enter. Callers that must not exceed a hard ceiling therefore check
         *    the head against that ceiling BEFORE planning (see [write]).
         */
        @JvmStatic
        fun planBatch(
            startSerial: Int,
            messages: List<ByteArray>,
            maxMessages: Int,
            maxBytes: Long,
        ): Int {
            require(maxMessages >= 1) { "maxMessages must be positive" }
            require(maxBytes >= 1L) { "maxBytes must be positive" }
            var count = 0
            var bytes = 0L
            for (message in messages) {
                if (count >= maxMessages) break
                val framed = framedSize(startSerial + count, message.size).toLong()
                if (count > 0 && bytes + framed > maxBytes) break
                count++
                bytes += framed
            }
            return count
        }
    }

    private val lock = Object()
    private val queue = ArrayDeque<ByteArray>()
    private val outstanding = OutstandingResponseLedger(MAX_OUTSTANDING_BYTES)

    /** Guarded by [lock]: assigned in drain order, never across threads. */
    private var serial = 0
    private var queuedBytes = 0L
    private var closed = false
    private var failureReported = false

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
     * Blocks up to [OFFER_WAIT_MS] under backpressure (queue full, queue byte
     * budget exhausted, or the combined queue+outstanding bound exhausted).
     * Returns false, and reports the failure once, when the session is closed
     * or the bounded transport cannot accept the message: the owning session
     * must then leave any readiness claim. Never throws across the JNI callback
     * boundary.
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
                queuedBytes + outstanding.reserved + message.size > MAX_TOTAL_NATIVE_BYTES
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

    fun open(): WebResourceResponse {
        synchronized(lock) { serial = 0 }
        val name = "mobile".toByteArray()
        return COWebViewClient.response(
            200,
            "OK",
            ByteArrayInputStream(name),
            name.size.toLong(),
        )
    }

    /**
     * One intercepted `write` response: the next bounded batch, framed and
     * served from memory. Never blocks and never reserves a resource another
     * response needs, so the page's in-flight counter always drains again.
     * Serials advance only inside [prepare], in drain order, exactly like
     * upstream. The host is never called while the queue monitor is held.
     */
    fun write(): WebResourceResponse {
        val prepared = prepare()
        return when (prepared) {
            is Prepared.Closed -> COWebViewClient.response(503, "Service Unavailable")
            is Prepared.Empty -> emptyResponse()
            is Prepared.Exhausted -> exhausted(prepared.available)
            is Prepared.Body -> {
                if (prepared.remaining > 0) {
                    // Bounded batch: arm exactly one more poll for the tail.
                    // The pinned mobile socket polls only when asked.
                    host.triggerSend()
                }
                val stream = bodyStream(prepared.bytes, prepared.reservation)
                try {
                    COWebViewClient.response(
                        200,
                        "OK",
                        stream,
                        prepared.bytes.size.toLong(),
                    )
                } catch (t: Throwable) {
                    stream.close()
                    throw t
                }
            }
        }
    }

    /** One prepared `write` outcome; only [Prepared.Body] holds a reservation. */
    private sealed class Prepared {
        /** The session transport is closed: 503, the page settles its socket. */
        class Closed : Prepared()

        /** Nothing queued: upstream's empty-drain 200 (no reservation). */
        class Empty : Prepared()

        /**
         * Data is waiting but the native-owned outstanding ceiling cannot fit
         * it. Reported once through [SocketHost.transportFailed] and answered
         * 503 - never a silent empty 200, which would wedge the queued tail
         * behind a delivery that is not coming.
         */
        class Exhausted(val available: Long) : Prepared()

        class Body(
            val bytes: ByteArray,
            val reservation: OutstandingResponseLedger.Reservation,
            /** Queued messages still waiting after this batch. */
            val remaining: Int,
        ) : Prepared()
    }

    /**
     * Chooses the next `write` outcome under the queue monitor, so serial
     * assignment, queue accounting and the outstanding reservation are one
     * atomic step. Lock order is [lock] -> ledger; [bodyStream] releases in the
     * same order, so a reader finishing a body can never deadlock a writer.
     */
    private fun prepare(): Prepared = synchronized(lock) {
        when {
            closed -> Prepared.Closed()
            queue.isEmpty() -> Prepared.Empty()
            // Data is waiting but the native-owned outstanding ceiling cannot
            // even fit the head frame (a handed-out body never reached
            // EOF/close): honest failure, never a silent empty 200.
            framedSize(serial + 1, queue.first().size).toLong() > outstanding.available() ->
                Prepared.Exhausted(outstanding.available())
            else -> drainBatch()
        }
    }

    /** Runs with [lock] held: drains, frames and reserves the next batch. */
    private fun drainBatch(): Prepared {
        val available = outstanding.available()
        val count = planBatch(
            serial + 1,
            queue,
            MAX_RESPONSE_MESSAGES,
            minOf(MAX_RESPONSE_BYTES, available),
        )
        val batch = ArrayList<ByteArray>(count)
        repeat(count) {
            val message = queue.removeFirst()
            queuedBytes -= message.size
            batch.add(message)
        }
        if (queuedBytes < 0) queuedBytes = 0
        val framed = frameBatch(serial + 1, batch)
        val reservation = outstanding.reserve(framed.size.toLong())
        if (reservation == null) {
            // Unreachable while [lock] is held (a concurrent release can only
            // grow the available budget), but never lose messages: put the
            // batch back at the head, serials untouched, and fail loudly.
            for (index in batch.indices.reversed()) {
                val message = batch[index]
                queue.addFirst(message)
                queuedBytes += message.size
            }
            return Prepared.Exhausted(outstanding.available())
        }
        serial += count
        // A bounded offer wait in queueSend ends as soon as room exists.
        lock.notifyAll()
        return Prepared.Body(framed, reservation, queue.size)
    }

    /** Reports the exhausted outstanding-body budget once, then answers 503. */
    private fun exhausted(available: Long): WebResourceResponse {
        reportFailureOnce("outstanding-response-budget:$available")
        return COWebViewClient.response(503, "Service Unavailable")
    }

    /**
     * Wraps one delivered body so its outstanding-byte reservation returns
     * exactly once, on the first of EOF or close. The release takes the queue
     * monitor BEFORE the ledger - the same order [prepare] uses - and wakes
     * waiting [queueSend] callers, which see the freed combined bound at once.
     */
    private fun bodyStream(
        body: ByteArray,
        reservation: OutstandingResponseLedger.Reservation,
    ): ReservedBodyStream = ReservedBodyStream(body) { fullyConsumed ->
        releaseReservation(reservation)
        if (!fullyConsumed && !isClosed) {
            // Those serials were handed out already. Requeueing with new
            // serials would leave a permanent hole in the page's processor.
            reportFailureOnce("response-closed-before-eof")
        }
    }

    private fun releaseReservation(reservation: OutstandingResponseLedger.Reservation) {
        synchronized(lock) {
            reservation.release()
            lock.notifyAll()
        }
    }

    /**
     * Upstream's empty-drain shape: a 200 with an immediately finished body
     * (upstream closed an empty PipedOutputStream). dist/global.js treats a
     * zero-length 200 as "no data yet" and keeps the socket armed.
     */
    private fun emptyResponse(): WebResourceResponse =
        COWebViewClient.response(200, "OK", ByteArrayInputStream(ByteArray(0)))

    /** Close the transport for the current session exactly once. */
    fun close() {
        val drained: Int
        val stillOutstanding: Long
        synchronized(lock) {
            if (closed) return
            closed = true
            drained = queue.size
            stillOutstanding = outstanding.reserved
            queue.clear()
            queuedBytes = 0
            lock.notifyAll()
        }
        if (drained > 0 || stillOutstanding > 0) {
            Log.i(
                LOG_TAG,
                "closed with $drained undelivered message(s) and $stillOutstanding " +
                    "byte(s) still held by the page; session is ending",
            )
        }
    }

    val isClosed: Boolean
        get() = synchronized(lock) { closed }

    /** Diagnostics for honest session reporting (no behavioural coupling). */
    fun snapshot(): Triple<Int, Long, Long> = synchronized(lock) {
        Triple(queue.size, queuedBytes, outstanding.reserved)
    }

    /**
     * Owns its backing array until fully consumed or closed. Returning the
     * reservation also clears that array; closed bodies cannot be read/reset.
     * The callback runs outside the stream monitor and distinguishes an
     * incomplete close from successful consumption.
     */
    internal class ReservedBodyStream(
        body: ByteArray,
        onReleased: (fullyConsumed: Boolean) -> Unit,
    ) : java.io.InputStream() {
        private val streamLock = Any()
        private var bytes: ByteArray? = body
        private var position = 0
        private var done = false
        private var releaseAction: ((Boolean) -> Unit)? = onReleased

        /** Called only with streamLock held; callers invoke the result outside it. */
        private fun finishLocked(fullyConsumed: Boolean): (() -> Unit)? {
            if (done) return null
            done = true
            bytes = null
            val action = releaseAction
            releaseAction = null
            return action?.let { { it(fullyConsumed) } }
        }

        override fun read(): Int {
            var finish: (() -> Unit)? = null
            val value = synchronized(streamLock) {
                val data = bytes
                if (data == null) {
                    -1
                } else if (position == data.size) {
                    finish = finishLocked(true)
                    -1
                } else {
                    val next = data[position++].toInt() and 0xff
                    if (position == data.size) finish = finishLocked(true)
                    next
                }
            }
            finish?.invoke()
            return value
        }

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (off < 0 || len < 0 || off > b.size || len > b.size - off) {
                throw IndexOutOfBoundsException()
            }
            if (len == 0) return 0
            var finish: (() -> Unit)? = null
            val value = synchronized(streamLock) {
                val data = bytes
                if (data == null) {
                    -1
                } else if (position == data.size) {
                    finish = finishLocked(true)
                    -1
                } else {
                    val count = minOf(len, data.size - position)
                    data.copyInto(b, off, position, position + count)
                    position += count
                    if (position == data.size) finish = finishLocked(true)
                    count
                }
            }
            finish?.invoke()
            return value
        }

        override fun available(): Int = synchronized(streamLock) {
            bytes?.let { it.size - position } ?: 0
        }

        override fun close() {
            val finish = synchronized(streamLock) {
                finishLocked(bytes?.let { position == it.size } ?: true)
            }
            finish?.invoke()
        }

        /** Whether this body already returned its reservation. */
        val isReleased: Boolean
            get() = synchronized(streamLock) { done }
    }
}

/**
 * Native-owned ledger of response bodies handed to the page but not yet
 * finished. The bound is explicit and non-blocking: [reserve] either fits under
 * the limit or returns null, and the caller must then fail honestly rather than
 * answer with a silent empty body. [Reservation.release] is exactly-once, so a
 * body can never be double-credited or forgotten.
 *
 * Self-synchronised, and pure Java: no Android type, so the bound and its
 * release semantics are JVM-testable. Callers in [MobileSocket] always enter
 * with the queue monitor held (order: queue monitor -> ledger), never the
 * reverse.
 */
class OutstandingResponseLedger(private val limitBytes: Long) {

    init {
        require(limitBytes >= 0L) { "limitBytes must not be negative" }
    }

    private val ledgerLock = Any()
    private var reservedBytes = 0L

    /** Bytes that may still be reserved without exceeding the limit. */
    fun available(): Long = synchronized(ledgerLock) { limitBytes - reservedBytes }

    /** Bytes currently held by handed-out, unfinished response bodies. */
    val reserved: Long
        get() = synchronized(ledgerLock) { reservedBytes }

    /** Configured ceiling (the native-owned bound itself). */
    val limit: Long
        get() = limitBytes

    /**
     * Reserves [bytes] under the limit. Null when it does not fit: the caller
     * must fail honestly. A zero-byte reservation always succeeds.
     */
    fun reserve(bytes: Long): Reservation? {
        require(bytes >= 0L) { "bytes must not be negative" }
        return synchronized(ledgerLock) {
            if (bytes > limitBytes - reservedBytes) {
                null
            } else {
                reservedBytes += bytes
                Reservation(bytes)
            }
        }
    }

    /** One exactly-once release handle for [bytes] reserved bytes. */
    inner class Reservation internal constructor(private val bytes: Long) {
        private val released = AtomicBoolean(false)

        /** True only for the call that actually returned the bytes. */
        fun release(): Boolean {
            if (!released.compareAndSet(false, true)) return false
            synchronized(ledgerLock) { reservedBytes -= bytes }
            return true
        }

        val isReleased: Boolean
            get() = released.get()

        val size: Long
            get() = bytes
    }
}
