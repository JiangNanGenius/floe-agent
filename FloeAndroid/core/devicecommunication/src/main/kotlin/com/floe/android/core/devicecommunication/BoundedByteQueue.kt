// SPDX-License-Identifier: MPL-2.0
//
// One bounded byte queue shared by the TCP/Telnet reader, BLE notifications
// and USB serial reads. Overflow drops the OLDEST bytes and records the exact
// dropped count; the queue never grows past `capacity` even when a peer sends
// a burst larger than the whole allowance.

package com.floe.android.core.devicecommunication

import java.util.ArrayDeque

class BoundedByteQueue(val capacity: Int) {
    init {
        require(capacity > 0) { "capacity must be positive" }
    }

    private val chunks = ArrayDeque<ByteArray>()
    private var size = 0
    private var total = 0L
    private var dropped = 0L

    data class Stats(
        val bufferedBytes: Int,
        val totalBytes: Long,
        val droppedBytes: Long,
    )

    @Synchronized
    fun append(data: ByteArray): Int {
        if (data.isEmpty()) return 0
        total += data.size.toLong()
        if (data.size >= capacity) {
            val keep = data.copyOfRange(data.size - capacity, data.size)
            val removed = size + (data.size - capacity)
            dropped += removed.toLong()
            chunks.clear()
            chunks.addLast(keep)
            size = keep.size
            return removed
        }
        chunks.addLast(data.copyOf())
        size += data.size
        var removed = 0
        while (size > capacity && chunks.isNotEmpty()) {
            val head = chunks.first()
            val overflow = size - capacity
            if (head.size <= overflow) {
                chunks.removeFirst()
                size -= head.size
                removed += head.size
            } else {
                chunks.removeFirst()
                val retained = head.copyOfRange(overflow, head.size)
                chunks.addFirst(retained)
                size -= overflow
                removed += overflow
            }
        }
        dropped += removed.toLong()
        return removed
    }

    @Synchronized
    fun drain(maxBytes: Int): ByteArray {
        if (maxBytes <= 0 || size == 0) return ByteArray(0)
        val wanted = minOf(maxBytes, size)
        val output = ByteArray(wanted)
        var offset = 0
        while (offset < wanted && chunks.isNotEmpty()) {
            val head = chunks.first()
            val take = minOf(head.size, wanted - offset)
            System.arraycopy(head, 0, output, offset, take)
            offset += take
            if (take == head.size) {
                chunks.removeFirst()
                size -= take
            } else {
                chunks.removeFirst()
                chunks.addFirst(head.copyOfRange(take, head.size))
                size -= take
            }
        }
        return if (offset == output.size) output else output.copyOf(offset)
    }

    @Synchronized
    fun clear(): Int {
        val removed = size
        chunks.clear()
        size = 0
        return removed
    }

    @Synchronized
    fun stats(): Stats = Stats(size, total, dropped)

    @get:Synchronized
    val bufferedBytes: Int
        get() = size
}
