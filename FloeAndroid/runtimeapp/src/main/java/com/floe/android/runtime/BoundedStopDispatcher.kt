// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.RejectedExecutionHandler
import java.util.concurrent.ThreadFactory
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/**
 * Bounded, strictly serialized stop lane for the runtime kernel.
 *
 * The ORIGINAL single-slot `stopExecutor` claimed at most one queued stop
 * out of the fence state machine and silently DROPPED any second distinct
 * target while the first was pending (the claim returned false and no task
 * was submitted). Once the engine admits two interactive sessions with their
 * own foreground permits, dropping a distinct target stop is a real lifecycle
 * loss: closing A and closing B at nearly the same time must stop exactly A
 * and exactly B, never whichever request happened to arrive first.
 *
 * This lane keeps the original serialization (ONE worker) and adds the
 * bounded no-loss property:
 *  * a fixed [capacity] queue: no unbounded growth under repeated stops;
 *  * a full queue makes the submitting thread WAIT for the worker to take one
 *    task (the standard blocking-rejection handoff) instead of rejecting or
 *    running the task concurrently; the handoff therefore preserves both the
 *    bound and the distinct-target order;
 *  * an interrupt during that handoff is remembered and the same bounded
 *    handoff is retried; the interrupt status is restored only AFTER the task
 *    is accepted, so a stop is never executed on the caller while the single
 *    worker is still running another stop;
 *  * shutdown is an honest pre-accept rejection (there is no public shutdown
 *    path); [dispatch] surfaces it instead of running the task inline. The
 *    kernel keeps the fence/ownership when that impossible boundary is hit;
 *  * no timer, no epoch and no fabricated progress: the lane only executes
 *    the lifecycle action its caller supplied.
 *
 * The worker is a daemon that exits after the configured idle keep-alive; the
 * next accepted stop starts a fresh worker. This replaces only the queue
 * container, never the kernel fence or the operations' real stop proof.
 */
internal class BoundedStopDispatcher(
    capacity: Int = DEFAULT_CAPACITY,
    private val threadName: String = "floe-linux-stop",
) {
    init { require(capacity >= 1) { "stop queue capacity must be positive" } }

    private val executor = ThreadPoolExecutor(
        1, 1, 30, TimeUnit.SECONDS,
        ArrayBlockingQueue<Runnable>(capacity),
        ThreadFactory { work -> Thread(work, threadName).apply { isDaemon = true } },
        RejectedExecutionHandler { task, pool ->
            if (pool.isShutdown) throw RejectedExecutionException("stop lane is shut down")
            handoff(task, pool)
        },
    ).apply { allowCoreThreadTimeOut(true) }

    /**
     * Bounded, lossless handoff used only when the queue is full. An
     * interrupt is remembered and the handoff retried; the interrupt flag is
     * restored AFTER acceptance. The task is never executed here, so the
     * single worker remains the only executor.
     */
    private fun handoff(task: Runnable, pool: ThreadPoolExecutor) {
        var interrupted = false
        while (true) {
            try {
                pool.queue.put(task)
                if (interrupted) Thread.currentThread().interrupt()
                return
            } catch (_: InterruptedException) {
                interrupted = true
            }
        }
    }

    /**
     * Submit one exact stop action. Never runs it on the caller: a shutdown
     * rejection is surfaced as an honest pre-accept failure so the kernel can
     * keep the real ownership/fence instead of executing a second stop in
     * parallel with the lane's worker.
     */
    fun dispatch(task: Runnable) {
        try {
            executor.execute(task)
        } catch (_: RejectedExecutionException) {
            throw IllegalStateException("Stop lane unavailable")
        }
    }

    companion object {
        /** 2 interactive + 1 execution + install + preflight + deferred
         *  owners + bound headroom. Distinct accepted stops are never
         *  coalesced, so this is a real memory/work bound. */
        internal const val DEFAULT_CAPACITY = 8
    }
}
