// SPDX-License-Identifier: MPL-2.0
//
// Bounded ordered RDP input lane. Pointer moves coalesce to the latest
// position; button/key/text events keep their order. The lane is owned by the
// App controller, never by the Compose view, and is closed on session change
// so queued input can never replay into a newer session/epoch.

package com.floe.android.host.rdp

import kotlinx.coroutines.channels.Channel

internal class C05RDPInputLane(
    private val sink: suspend (List<C05RdpInput>) -> Unit,
    private val onIssue: (String) -> Unit,
    private val capacityPackets: Int = 128,
    private val batchLimit: Int = 24,
) {
    private val lock = Any()
    private val queue = ArrayDeque<C05RdpInput>()
    private var closed = false
    private val signal = Channel<Unit>(Channel.CONFLATED)

    fun offer(event: C05RdpInput): String? {
        synchronized(lock) {
            if (closed) return "hostClosed"
            if (event is C05RdpInput.PointerMove &&
                queue.isNotEmpty() &&
                queue.last() is C05RdpInput.PointerMove
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

    private suspend fun takeBatch(): List<C05RdpInput>? {
        while (true) {
            synchronized(lock) {
                if (closed) return null
                if (queue.isNotEmpty()) {
                    val batch = ArrayList<C05RdpInput>(minOf(batchLimit, queue.size))
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
