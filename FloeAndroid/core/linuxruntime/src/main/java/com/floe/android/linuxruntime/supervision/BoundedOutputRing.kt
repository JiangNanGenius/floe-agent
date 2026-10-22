// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.supervision

/**
 * One bounded page of retained output.
 *
 * @param bytes the page content (never more than the ring's bound).
 * @param nextCursor cursor to pass to the following read.
 * @param gapBytes bytes that were dropped before this page: the caller must
 *        present this as a truthful truncation, never as continuous output.
 * @param truncatedMore true when retained bytes remain beyond this page.
 * @param totalRetainedBytes ring occupancy when the page was produced.
 * @param totalDroppedBytes cumulative dropped bytes.
 */
data class OutputPage(
    val bytes: ByteArray,
    val nextCursor: Long,
    val gapBytes: Long,
    val truncatedMore: Boolean,
    val totalRetainedBytes: Int,
    val totalDroppedBytes: Long,
) {
    val isEmpty: Boolean get() = bytes.isEmpty()
}

/**
 * Bounded byte ring for PTY output. The service retains at most
 * [capacityBytes] of the most recent output; older bytes are dropped and the
 * drop is *reported*, never hidden. Nothing is written to a file or to logs.
 *
 * Cursors are absolute byte offsets from the start of the stream, so a paging
 * consumer always learns exactly how much it missed.
 *
 * Not thread safe: [com.floe.android.linuxruntime.PtySession] output has a
 * single drain owner by contract, and [SupervisedPtyJob] serialises mutation of
 * this ring under its own state lock.
 */
class BoundedOutputRing(val capacityBytes: Int) {

    init {
        require(capacityBytes in MIN_CAPACITY..MAX_CAPACITY) {
            "capacityBytes must be in $MIN_CAPACITY..$MAX_CAPACITY"
        }
    }

    companion object {
        const val MIN_CAPACITY = 1024
        const val MAX_CAPACITY = 4 * 1024 * 1024

        /** Largest single page a consumer may request. */
        const val MAX_PAGE_BYTES = 1 shl 20
    }

    private val buffer = ByteArray(capacityBytes)
    private var writeIndex = 0
    private var retained = 0

    /** Total bytes ever appended (the stream length). */
    var totalProducedBytes: Long = 0
        private set

    /** Bytes that fell out of the retained window. */
    val totalDroppedBytes: Long get() = totalProducedBytes - retained

    /** Absolute offset of the oldest retained byte (== [totalProducedBytes] when empty). */
    val firstRetainedCursor: Long get() = totalProducedBytes - retained

    val retainedBytes: Int get() = retained

    /** Appends output; returns the number of bytes accepted into the window. */
    fun append(data: ByteArray, offset: Int = 0, length: Int = data.size): Int {
        require(offset >= 0 && length >= 0 && offset + length <= data.size) { "append range invalid" }
        if (length == 0) return 0
        // Keep the newest bytes when a single chunk exceeds the whole window.
        val skip = if (length > capacityBytes) length - capacityBytes else 0
        var index = offset + skip
        var remaining = length - skip
        while (remaining > 0) {
            buffer[writeIndex] = data[index]
            index++
            writeIndex = (writeIndex + 1) % capacityBytes
            if (retained < capacityBytes) retained++
            remaining--
        }
        totalProducedBytes += length
        return length - skip
    }

    /**
     * Reads at most [capacity] retained bytes starting at [cursor].
     *
     * A cursor behind the window is served from the window start with
     * [OutputPage.gapBytes] reporting the loss. A cursor ahead of the stream end
     * is a caller bug and is refused (fail closed, no silent empty success).
     */
    fun read(cursor: Long, capacity: Int): OutputPage {
        require(capacity in 1..MAX_PAGE_BYTES) { "page capacity out of range" }
        require(cursor >= 0) { "cursor must be a non-negative stream offset" }
        val first = firstRetainedCursor
        val end = totalProducedBytes
        require(cursor <= end) { "cursor $cursor is ahead of the stream end $end" }

        val gap = if (cursor < first) first - cursor else 0L
        var from = if (cursor < first) first else cursor
        var available = (end - from).coerceAtMost(capacity.toLong()).toInt()
        // Ring position of `from`: newest byte sits at writeIndex-1.
        val tailOffset = end - from
        var start = (writeIndex - tailOffset).mod(capacityBytes)
        val out = ByteArray(available)
        for (i in 0 until available) {
            out[i] = buffer[start]
            start = (start + 1) % capacityBytes
        }
        from += available
        val more = end - from > 0
        return OutputPage(
            bytes = out,
            nextCursor = from,
            gapBytes = gap,
            truncatedMore = more,
            totalRetainedBytes = retained,
            totalDroppedBytes = totalDroppedBytes,
        )
    }

    /** Discards retained content (called when the workload reaches a terminal state). */
    fun clear() {
        writeIndex = 0
        retained = 0
    }
}
