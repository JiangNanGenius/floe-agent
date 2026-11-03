// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.capture

import com.floe.android.core.networkcapture.CaptureLimits
import com.floe.android.core.networkcapture.CaptureMode
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout

/**
 * Process-lived owner for a capture that outlived its foreground Service.
 *
 * A VpnService/Root Service can be destroyed while its TUN fd, helper process,
 * forwarders or PCAP writer still have an unproven close. This owner keeps the
 * exact resource set (through the task closure), retries the same bounded
 * joins and finalizes the original staging data exactly once when the real
 * resources settle. The instances are created by the App process (see
 * [CaptureServiceRuntime]); cancelling a Service/view scope therefore cannot
 * release this owner, and no detached `GlobalScope` cleanup is used.
 *
 * Actual process death is different: this in-memory owner cannot survive it.
 * The root server is a separate process and its own session watchdog (client
 * lease and duration bound) stops an orphaned helper; the App-side ledger is
 * rebuilt empty on the next process.
 */
class CaptureDrainOwner(
    private val scope: CoroutineScope,
    private val retryDelayMillis: Long = CaptureLimits.DRAIN_RETRY_MILLIS,
) {
    data class Attempt<T>(
        /** True only after the real close/join results all reported true. */
        val settled: Boolean,
        val value: T? = null,
        val failure: String? = null,
    )

    /**
     * One live capture's drain. The same instance is transferred from the
     * Service to this owner; a second instance is never allowed to drive the
     * same session concurrently.
     */
    abstract class Task<T> {
        abstract val sessionId: String
        abstract val mode: CaptureMode

        /** Identity of the exact resource set; a replacement capture conflicts. */
        abstract val ownerToken: Any

        /** One bounded stop/join attempt against the SAME owned resources. */
        abstract suspend fun attempt(): Attempt<T>

        /** Called exactly once, only after [attempt] proved a real settle. */
        abstract fun finalize(value: T)
    }

    enum class Retention {
        STARTED,
        ALREADY_RETAINED,
        CONFLICT,
        INVALID_SESSION,
    }

    private class Entry<T>(
        val task: Task<T>,
        val settled: CompletableDeferred<Unit> = CompletableDeferred(),
    ) {
        lateinit var job: Job

        @Volatile
        var lastFailure: String? = null

        @Volatile
        var finalizeFailure: String? = null
    }

    private val lock = Any()
    private val entries = LinkedHashMap<String, Entry<*>>()

    init {
        require(retryDelayMillis > 0) { "retryDelayMillis" }
    }

    /**
     * Transfer [task] to the process owner. A repeated transfer of the SAME
     * resource set is idempotent; a different owner for the same session is
     * refused instead of starting a second drain or finalizer.
     */
    fun retain(task: Task<*>): Retention {
        if (!runCatching { UUID.fromString(task.sessionId) }.isSuccess) {
            return Retention.INVALID_SESSION
        }
        synchronized(lock) {
            val existing = entries[task.sessionId]
            if (existing != null) {
                return if (existing.task.ownerToken === task.ownerToken) {
                    Retention.ALREADY_RETAINED
                } else {
                    Retention.CONFLICT
                }
            }
            val entry = Entry(task)
            entries[task.sessionId] = entry
            entry.job = scope.launch { runLoop(entry) }
            return Retention.STARTED
        }
    }

    fun isRetained(sessionId: String): Boolean = synchronized(lock) {
        entries.containsKey(sessionId)
    }

    /**
     * Bounded wait for the real settle. A false result never cancels the
     * retained job: the same resources keep draining and a later RootStop can
     * observe the eventual result.
     */
    suspend fun awaitSettled(sessionId: String, timeoutMillis: Long): Boolean {
        require(timeoutMillis > 0) { "timeoutMillis" }
        val settled = synchronized(lock) { entries[sessionId]?.settled } ?: return true
        return try {
            withTimeout(timeoutMillis) { settled.await() }
            true
        } catch (_: TimeoutCancellationException) {
            false
        }
    }

    internal fun retainedSessionIds(): Set<String> = synchronized(lock) {
        entries.keys.toSet()
    }

    internal fun lastFailure(sessionId: String): String? = synchronized(lock) {
        entries[sessionId]?.lastFailure
    }

    internal fun finalizeFailure(sessionId: String): String? = synchronized(lock) {
        entries[sessionId]?.finalizeFailure
    }

    private suspend fun <T> runLoop(entry: Entry<T>) {
        while (true) {
            val attempt = try {
                entry.task.attempt()
            } catch (cancelled: CancellationException) {
                // Process teardown (or an explicit owner-scope cancel) cannot
                // prove the resources settled. Keep the entry fail-closed.
                throw cancelled
            } catch (error: Throwable) {
                Attempt<T>(
                    settled = false,
                    failure = error.javaClass.simpleName.take(64),
                )
            }
            if (attempt.settled) {
                val value = attempt.value
                if (value != null) {
                    try {
                        entry.task.finalize(value)
                    } catch (_: Throwable) {
                        entry.finalizeFailure = "finalize_failed"
                    }
                }
                break
            }
            entry.lastFailure = attempt.failure ?: entry.lastFailure
            delay(retryDelayMillis)
        }
        // Remove only after a proven settle + exactly-once finalize, so a
        // bounded waiter that timed out still observes the same live entry
        // until this point.
        synchronized(lock) { entries.remove(entry.task.sessionId) }
        entry.settled.complete(Unit)
    }
}
