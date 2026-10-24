// SPDX-License-Identifier: MPL-2.0
package com.floe.android.safgateway

import java.util.concurrent.CancellationException
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicBoolean

/** Service-owned IO. Cancel is a request; a timeout/closed admission does not
 * prove a provider stopped. Tokens and resource cleanup remain owned until
 * the real block settles. close never releases persisted OS grants.
 */
class SafGatewayService(
    private val backend: SafPlatformBackend,
    ioExecutor: Executor? = null,
    limits: SafLimits = SafLimits.DEFAULT,
    releaseBroker: SafReleaseBroker? = null,
) : AutoCloseable {
    private val ownsExecutor = ioExecutor == null
    private val executor: Executor = ioExecutor ?: Executors.newSingleThreadExecutor { r ->
        Thread(r, "floe-saf-gateway-io").apply { isDaemon = true }
    }
    private val ownedExecutor = if (ownsExecutor) executor as ExecutorService else null
    private val lifecycleLock = Any()
    private val settlement = java.lang.Object()
    private val closed = AtomicBoolean()
    private val cleanupStarted = AtomicBoolean()
    private val cleanupFinished = AtomicBoolean()
    private val activeTokens = CopyOnWriteArrayList<SafCancelToken>()

    val grants = SafGrantGateway(backend, releaseBroker)
    val operations = SafProviderOperations(backend, grants, limits)
    val workingCopy = SafWorkingCopyService(backend, operations, limits)
    /** Closed admission is distinct from actual IO/resource drain. */
    val isClosed: Boolean get() = closed.get()
    val pendingOperationCount: Int get() = activeTokens.size
    val isDrained: Boolean get() = activeTokens.isEmpty() && (!closed.get() || cleanupFinished.get())

    fun <T> submit(block: (SafCancelToken) -> SafOutcome<T>): SafOperation<T> = synchronized(lifecycleLock) {
        check(!closed.get()) { "SafGatewayService is closed" }
        val token = SafCancelToken()
        activeTokens += token
        try {
            val task = SafPendingTask(executor, token, block) {
                activeTokens.remove(token)
                finishCleanupIfIdle()
                synchronized(settlement) { settlement.notifyAll() }
            }
            SafOperation(token, task)
        } catch (error: RuntimeException) {
            activeTokens.remove(token)
            synchronized(settlement) { settlement.notifyAll() }
            throw error
        }
    }

    override fun close() {
        val tokens = synchronized(lifecycleLock) {
            if (!closed.compareAndSet(false, true)) return
            activeTokens.toList()
        }
        tokens.forEach { it.cancel() }
        // Queued blocks must still run their cancellation checks/finalizers;
        // shutdownNow would discard them and fabricate settlement.
        ownedExecutor?.shutdown()
        finishCleanupIfIdle()
        ownedExecutor?.let { runCatching { it.awaitTermination(2, TimeUnit.SECONDS) } }
    }

    /** IO-context join. A false timeout preserves pending work and its owner;
     * zero waits for actual settlement, including close-time cursor cleanup. */
    fun awaitIdle(timeoutMillis: Long = 0): Boolean {
        require(timeoutMillis >= 0)
        val started = System.nanoTime()
        val budget = TimeUnit.MILLISECONDS.toNanos(timeoutMillis)
        synchronized(settlement) {
            while (!isDrained) {
                if (timeoutMillis == 0L) settlement.wait()
                else {
                    val remaining = budget - (System.nanoTime() - started)
                    if (remaining <= 0) return false
                    settlement.wait(remaining / 1_000_000, (remaining % 1_000_000).toInt())
                }
            }
        }
        return true
    }

    private fun finishCleanupIfIdle() {
        if (!closed.get() || activeTokens.isNotEmpty() || !cleanupStarted.compareAndSet(false, true)) return
        try {
            runCatching { backend.releaseAllCursors() }
            runCatching { grants.shutdown() }
        } finally {
            cleanupFinished.set(true)
            synchronized(settlement) { settlement.notifyAll() }
        }
    }
}

/** Completion is signalled only after actual IO and its owned finalizers.
 * Unlike Future.cancel, cancel never counts down the settlement latch. */
internal class SafPendingTask<T>(
    executor: Executor,
    token: SafCancelToken,
    block: (SafCancelToken) -> SafOutcome<T>,
    onSettled: () -> Unit,
) {
    private val settled = CountDownLatch(1)
    @Volatile private var value: SafOutcome<T>? = null
    val isDone: Boolean get() = settled.count == 0L
    init {
        executor.execute {
            try {
                value = if (token.isCancelled) SafOutcome.failure(SafFailure.Cancelled) else block(token)
            } catch (_: SafCancelledException) {
                value = SafOutcome.failure(SafFailure.Cancelled)
            } catch (_: CancellationException) {
                value = SafOutcome.failure(SafFailure.Cancelled)
            } catch (fault: SafBackendFaultException) {
                value = SafOutcome.failure(fault.fault.toSafFailure(), fault.message)
            } catch (error: Exception) {
                value = SafOutcome.failure(SafFailure.Failed(error.message ?: error.javaClass.simpleName))
            } finally {
                try { onSettled() } finally { settled.countDown() }
            }
        }
    }
    fun await(timeoutMillis: Long): SafOutcome<T> {
        if (timeoutMillis == 0L) settled.await()
        else if (!settled.await(timeoutMillis, TimeUnit.MILLISECONDS)) throw TimeoutException()
        return value ?: SafOutcome.failure(SafFailure.Failed("worker settled without an outcome"))
    }
}

class SafOperation<T> internal constructor(
    val token: SafCancelToken,
    private val task: SafPendingTask<T>,
) {
    val isDone: Boolean get() = task.isDone
    fun await(timeoutMillis: Long = 0): SafOutcome<T> {
        require(timeoutMillis >= 0)
        return try { task.await(timeoutMillis) }
        catch (_: TimeoutException) {
            cancel()
            SafOutcome.failure(SafFailure.Failed("operation timed out; cancellation requested, IO may still be pending"))
        } catch (_: InterruptedException) {
            cancel(); Thread.currentThread().interrupt()
            SafOutcome.failure(SafFailure.Cancelled, "wait interrupted; IO may still be pending")
        }
    }
    /** Requests real CancellationSignal cancellation without claiming done. */
    fun cancel(): Boolean {
        if (task.isDone || token.isCancelled) return false
        token.cancel()
        return true
    }
}
