// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import java.io.Closeable
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * Bounded single-worker executor for platform NsdManager callbacks.
 *
 * NsdManager keeps its ServiceHandler queue and a per-listener executor after
 * discovery is stopped, and can dispatch an already queued acknowledgement
 * after the owning network session has closed. A plain ExecutorService then
 * throws RejectedExecutionException on the platform Handler thread and kills
 * the process. This executor has no terminated state that rejects work:
 * once [close] starts, queued callbacks are cleared and later dispatches are
 * silently ignored. It never throws from [execute].
 *
 * The queue is bounded because NSD callbacks are advisory and must neither
 * block the Binder/Connectivity thread nor grow without limit. A callback
 * dropped while open is counted so LAN discovery can report a partial result
 * instead of a misleading complete inventory; it never mutates another
 * operation or session.
 */
internal class NsdCallbackExecutor(
    queueCapacity: Int = DEFAULT_QUEUE_CAPACITY,
    threadName: String = "floe-nsd",
) : Executor, Closeable {
    private val gate = Any()
    private val closed = AtomicBoolean(false)
    private val droppedCallbacks = AtomicLong(0)
    private val queue = ArrayBlockingQueue<Runnable>(queueCapacity.coerceAtLeast(1))
    private val worker = Thread(::drainLoop, threadName).apply { isDaemon = true }
    private var started = false

    internal val isClosed: Boolean get() = closed.get()

    internal val queuedTaskCount: Int get() = queue.size

    internal val droppedCallbackCount: Long get() = droppedCallbacks.get()

    override fun execute(command: Runnable) {
        synchronized(gate) {
            if (closed.get()) return
            // Never wait on the platform Handler thread; saturated callbacks
            // are dropped instead of blocking Binder/Connectivity delivery.
            if (!queue.offer(command)) {
                droppedCallbacks.incrementAndGet()
                return
            }
            if (!started) {
                started = true
                worker.start()
            }
        }
    }

    private fun drainLoop() {
        while (!closed.get()) {
            val task = try {
                queue.take()
            } catch (_: InterruptedException) {
                if (closed.get()) return
                continue
            }
            // close() also drops a task the worker just dequeued.
            if (closed.get()) return
            try {
                task.run()
            } catch (failure: Throwable) {
                // Match an ordinary uncaught worker failure instead of silently
                // swallowing application errors.
                val handler = Thread.getDefaultUncaughtExceptionHandler()
                if (handler != null) {
                    handler.uncaughtException(Thread.currentThread(), failure)
                } else {
                    throw failure
                }
            }
        }
    }

    override fun close() {
        synchronized(gate) {
            if (!closed.compareAndSet(false, true)) return
            queue.clear()
        }
        worker.interrupt()
        if (Thread.currentThread() !== worker) {
            try {
                worker.join(CLOSE_JOIN_MS)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }
    }

    companion object {
        internal const val DEFAULT_QUEUE_CAPACITY = 64
        private const val CLOSE_JOIN_MS = 1_000L
    }
}
