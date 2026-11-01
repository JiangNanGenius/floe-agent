// SPDX-License-Identifier: MPL-2.0
//
// Bounded ordered PTY input lane for one SSH PTY. Ordinary typing, IME
// commits and paste all enter here on the UI thread; the App-owned writer
// coroutine drains them in order to `c05.pty.write`. Overflow is a typed
// refusal reported to the pane, never an unbounded queue or silent drop.

package com.floe.android.host.remote

import kotlinx.coroutines.channels.Channel

internal class C05RemoteInputLane(
    private val sink: suspend (ByteArray) -> Unit,
    private val onIssue: (String) -> Unit,
    private val capacityPackets: Int = 128,
    private val capacityBytes: Int = 256 * 1024,
    private val coalesceBytes: Int = 2_048,
) {
    private val lock = Any()
    private val queue = ArrayDeque<ByteArray>()
    private var queuedBytes = 0
    private var closed = false
    private val signal = Channel<Unit>(Channel.CONFLATED)

    /** Returns a stable issue code when the bytes were refused, else null. */
    fun offer(data: ByteArray): String? {
        if (data.isEmpty()) return null
        synchronized(lock) {
            if (closed) return "hostClosed"
            if (data.size > capacityBytes) return "inputTooLarge"
            if (queue.isNotEmpty() &&
                queue.last().size + data.size <= coalesceBytes &&
                queuedBytes + data.size <= capacityBytes
            ) {
                val merged = queue.removeLast() + data
                queue.addLast(merged)
                queuedBytes += data.size
            } else {
                if (queue.size >= capacityPackets || queuedBytes + data.size > capacityBytes) {
                    return "inputFull"
                }
                queue.addLast(data.copyOf())
                queuedBytes += data.size
            }
        }
        signal.trySend(Unit)
        return null
    }

    suspend fun run() {
        while (true) {
            val item = take() ?: return
            try {
                sink(item)
            } catch (_: Throwable) {
                onIssue("transport")
                close()
                return
            }
        }
    }

    fun close() {
        synchronized(lock) {
            if (closed) return
            closed = true
            queue.clear()
            queuedBytes = 0
        }
        signal.close()
    }

    private suspend fun take(): ByteArray? {
        while (true) {
            synchronized(lock) {
                if (closed) return null
                if (queue.isNotEmpty()) {
                    val item = queue.removeFirst()
                    queuedBytes -= item.size
                    return item
                }
            }
            val resumed = try {
                signal.receive()
                true
            } catch (_: Throwable) {
                false
            }
            if (!resumed) return null
        }
    }
}
