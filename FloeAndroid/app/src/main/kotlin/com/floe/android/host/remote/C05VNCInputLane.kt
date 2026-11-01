// SPDX-License-Identifier: MPL-2.0
//
// Bounded ordered VNC input lane. Pointer moves coalesce to the latest
// position; button/key/text events keep their order. The lane is owned by the
// App controller, never by the Compose view, and is closed on session change
// so queued input can never replay into a newer session/epoch.

package com.floe.android.host.remote

import kotlinx.coroutines.channels.Channel

internal class C05VNCInputLane(
    private val sink: suspend (List<C05VncInput>) -> Unit,
    private val onIssue: (String) -> Unit,
    private val capacityPackets: Int = 128,
    private val batchLimit: Int = 24,
) {
    private val lock = Any()
    private val queue = ArrayDeque<C05VncInput>()
    private var closed = false
    private val signal = Channel<Unit>(Channel.CONFLATED)

    fun offer(event: C05VncInput): String? {
        synchronized(lock) {
            if (closed) return "hostClosed"
            if (event is C05VncInput.PointerMove &&
                queue.isNotEmpty() &&
                queue.last() is C05VncInput.PointerMove
            ) {
                queue.removeLast()
                queue.addLast(event)
                signal.trySend(Unit)
                return null
            }
            if (queue.size >= capacityPackets) return "inputFull"
            queue.addLast(event)
        }
        signal.trySend(Unit)
        return null
    }

    suspend fun run() {
        while (true) {
            val batch = takeBatch() ?: return
            try {
                sink(batch)
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
        }
        signal.close()
    }

    private fun takeBatch(): List<C05VncInput>? {
        while (true) {
            synchronized(lock) {
                if (closed) return null
                if (queue.isNotEmpty()) {
                    val batch = ArrayList<C05VncInput>(minOf(batchLimit, queue.size))
                    while (batch.size < batchLimit && queue.isNotEmpty()) {
                        batch.add(queue.removeFirst())
                    }
                    return batch
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
