// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import android.content.Context
import android.os.UserManager
import com.floe.android.bridge.SecretGatewayNative
import com.floe.android.bridge.SwiftCore
import com.floe.android.contracts.CredentialStore
import com.floe.android.credentials.AndroidKeystoreCredentialStore
import com.floe.android.credentials.CredentialStoreException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull

/** Process-wide capability gate for provider/config and MCP acceptance. */
sealed class SecretGatewayCapability {
    data object Loading : SecretGatewayCapability()
    data object Ready : SecretGatewayCapability()
    data class Failed(val reason: String) : SecretGatewayCapability()
}

internal data class DispatcherTimings(
    val pollerJoinMillis: Long = 2_000,
    val drainChildrenMillis: Long = 10_000,
    val readyAckMillis: Long = 5_000,
)

internal interface SecretGatewayNativeApi {
    fun ensureLoaded()
    fun bindSecretDispatcher(epoch: Long): Int
    fun awaitSecretRequest(timeoutMillis: Int): Long
    fun describeSecretRequest(claim: Long): String?
    fun takeSecretPayload(claim: Long): ByteArray?
    fun isSecretRequestLive(claim: Long): Boolean
    fun completeSecretRequest(claim: Long, status: Int, value: ByteArray?): Int
    fun secretMailboxStats(): String
    fun installSecretGateway(): Int
    fun removeSecretGateway(): Int
}

/**
 * Production adapter. Its own initialization does not touch
 * [SecretGatewayNative]; the object class-init (and therefore
 * System.loadLibrary) runs only on the first off-main method call.
 */
private object SystemSecretGatewayNative : SecretGatewayNativeApi {
    override fun ensureLoaded() {
        // Accessing the object triggers its init { System.loadLibrary(...) }.
        SecretGatewayNative.hashCode()
    }
    override fun bindSecretDispatcher(epoch: Long) =
        SecretGatewayNative.bindSecretDispatcher(epoch)
    override fun awaitSecretRequest(timeoutMillis: Int) =
        SecretGatewayNative.awaitSecretRequest(timeoutMillis)
    override fun describeSecretRequest(claim: Long) =
        SecretGatewayNative.describeSecretRequest(claim)
    override fun takeSecretPayload(claim: Long) =
        SecretGatewayNative.takeSecretPayload(claim)
    override fun isSecretRequestLive(claim: Long) =
        SecretGatewayNative.isSecretRequestLive(claim)
    override fun completeSecretRequest(claim: Long, status: Int, value: ByteArray?) =
        SecretGatewayNative.completeSecretRequest(claim, status, value)
    override fun secretMailboxStats() = SecretGatewayNative.secretMailboxStats()
    override fun installSecretGateway() = SecretGatewayNative.installSecretGateway()
    override fun removeSecretGateway() = SecretGatewayNative.removeSecretGateway()
}

// MARK: - Bounded ownership

private const val MAX_OUTSTANDING_OPS = 48
private const val MAX_OUTSTANDING_BYTES = 3L * 1024L * 1024L
private const val MAX_LIVE_GENERATIONS = 3
private const val MAX_SECRET_BYTES = 65_536
private const val POLL_TIMEOUT_MILLIS = 250

internal data class CapacitySnapshot(
    val outstandingOps: Int,
    val outstandingBytes: Long,
    val liveGenerations: Int,
    val quarantinedRefs: Int,
    val quarantinedJobs: Int,
)

internal data class DispatcherSnapshot(
    val capacity: CapacitySnapshot,
    val dispatcherCapacityRejects: Long,
    val abandoned: Long,
    val generationFailures: Long,
    val installBusy: Long,
)

internal class ReservationTicket internal constructor(
    private val capacity: DispatcherCapacity,
    val generationId: Long,
    initialBytes: Long,
) {
    private val released = AtomicBoolean(false)
    @Volatile internal var bytes: Long = initialBytes
    val isReleased: Boolean get() = released.get()

    /** Shrinks an over-reserved write admission to the actual taken length. */
    fun shrinkTo(newBytes: Long): Boolean = capacity.shrink(this, newBytes)

    /** Atomic exact-once release guard. */
    fun release(): Boolean = capacity.release(this)

    internal fun markReleased(): Boolean = released.compareAndSet(false, true)
}

internal class DispatcherCapacity(
    private val maxOps: Int = MAX_OUTSTANDING_OPS,
    private val maxBytes: Long = MAX_OUTSTANDING_BYTES,
) {
    private val lock = Any()
    private var outstandingOps = 0
    private var outstandingBytes = 0L
    private val generationOps = LinkedHashMap<Long, Int>()

    fun reserve(generationId: Long, bytes: Long): ReservationTicket? = synchronized(lock) {
        if (bytes < 0) return@synchronized null
        if (outstandingOps >= maxOps) return@synchronized null
        if (bytes > maxBytes - outstandingBytes) return@synchronized null
        outstandingOps += 1
        outstandingBytes += bytes
        generationOps[generationId] = (generationOps[generationId] ?: 0) + 1
        ReservationTicket(this, generationId, bytes)
    }

    internal fun shrink(ticket: ReservationTicket, newBytes: Long): Boolean = synchronized(lock) {
        if (ticket.isReleased || newBytes < 0 || newBytes > ticket.bytes) return@synchronized false
        outstandingBytes -= (ticket.bytes - newBytes)
        ticket.bytes = newBytes
        true
    }

    internal fun release(ticket: ReservationTicket): Boolean = synchronized(lock) {
        if (!ticket.markReleased()) return@synchronized false
        outstandingOps -= 1
        outstandingBytes -= ticket.bytes
        val current = generationOps[ticket.generationId] ?: 0
        if (current <= 1) {
            generationOps.remove(ticket.generationId)
        } else {
            generationOps[ticket.generationId] = current - 1
        }
        true
    }

    val liveGenerations: Int get() = synchronized(lock) { generationOps.size }

    fun snapshot(quarantinedRefs: Int, quarantinedJobs: Int): CapacitySnapshot =
        synchronized(lock) {
            CapacitySnapshot(outstandingOps, outstandingBytes, generationOps.size,
                quarantinedRefs, quarantinedJobs)
        }
}

/** ref -> set of ACTUAL child jobs. 16 same-ref children are one map entry. */
internal class QuarantineIndex {
    private val lock = Any()
    private val entries = HashMap<String, MutableSet<ChildRecord>>()

    fun add(record: ChildRecord) {
        synchronized(lock) {
            entries.getOrPut(record.reference) { mutableSetOf() }.add(record)
        }
    }

    fun remove(record: ChildRecord) {
        synchronized(lock) {
            val set = entries[record.reference] ?: return@synchronized
            set.remove(record)
            if (set.isEmpty()) entries.remove(record.reference)
        }
    }

    fun isQuarantined(reference: String): Boolean = synchronized(lock) {
        entries[reference]?.isNotEmpty() == true
    }

    fun counts(): Pair<Int, Int> = synchronized(lock) {
        var jobs = 0
        for (set in entries.values) jobs += set.size
        entries.size to jobs
    }
}

internal class ChildRecord(
    val generationId: Long,
    val claim: Long,
    val reference: String,
    val job: Job,
)

/**
 * Test-only pause points for the failure-cleanup/rebind race. Production
 * leaves the hook null; no behavior depends on it.
 */
internal class FailureCleanupHooks {
    val reached = CompletableDeferred<Unit>()
    val release = CompletableDeferred<Unit>()
    val finished = CompletableDeferred<Unit>()
}

// MARK: - Dispatcher

/**
 * One process-lifetime Application-scoped dispatcher. Bootstrap, ready ack,
 * gateway install and credential.status readback run off-main; the poller is
 * a single dedicated thread; child store submissions are reserved, tracked and
 * quarantined by actual Job lifetime, never by time.
 */
class SecretGatewayDispatcher internal constructor(
    private val native: SecretGatewayNativeApi,
    private val storeProvider: suspend () -> CredentialStore,
    private val unlockChecker: () -> Boolean,
    private val statusReader: () -> Boolean,
    private val scope: CoroutineScope,
    private val ioDispatcher: CoroutineDispatcher,
    private val timings: DispatcherTimings = DispatcherTimings(),
    private val diagnostics: (String) -> Unit = {},
    private val capabilityState: MutableStateFlow<SecretGatewayCapability> =
        MutableStateFlow(SecretGatewayCapability.Loading),
) {
    val capability: StateFlow<SecretGatewayCapability> = capabilityState

    private val installMutex = Mutex()
    private val capabilityLock = Any()
    private val capacity = DispatcherCapacity()
    private val quarantine = QuarantineIndex()
    private val trackedChildren = ConcurrentHashMap<Long, ChildRecord>()
    private val epochCounter = AtomicLong(0)
    private val cleanupScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private val dispatcherCapacityRejects = AtomicLong(0)
    private val abandonedCount = AtomicLong(0)
    private val generationFailureCount = AtomicLong(0)
    private val installBusyCount = AtomicLong(0)

    @Volatile private var currentGeneration: Generation? = null
    @Volatile private var installingGeneration: Generation? = null

    /**
     * Pollers whose bounded join timed out. Every entry retains the actual
     * generation/thread ownership, so a later native bind cannot bypass a
     * still-live previous poller. Guarded by [capabilityLock]; threads are
     * never joined while that lock is held.
     */
    private val fencedPollers = LinkedHashSet<Generation>()

    @Volatile private var store: CredentialStore? = null
    @Volatile internal var failureCleanupHooksForTest: FailureCleanupHooks? = null

    /**
     * One bootstrap/install attempt. Failure and readiness belong to this
     * exact identity; a retired attempt can never publish state for a newer
     * attempt. Internal only for the testable install entry point.
     */
    internal class Generation(val id: Long) {
        val stopRequested = AtomicBoolean(false)
        val failed = AtomicBoolean(false)
        val readyAck = CompletableDeferred<Unit>()
        @Volatile var thread: Thread? = null
    }

    private enum class Operation(val wire: String) {
        READ("read"), WRITE("write"), DELETE("delete");
        companion object {
            fun parse(value: String): Operation? = Operation.values().firstOrNull { it.wire == value }
        }
    }

    private data class Descriptor(val operation: Operation, val reference: String)

    private enum class SettleOutcome { ACCEPTED, TERMINAL, UNSETTLEABLE }

    private val descriptorPattern = Regex(
        """^\{"op":"(read|write|delete)","reference":"(ref:v1:[0-9a-f]{64})"\}$""")

    // MARK: Public lifecycle

    /** Called only from FloeApplication.onCreate. Launches off-main work. */
    fun start() {
        scope.launch(ioDispatcher) { bootstrap() }
    }

    // MARK: Bootstrap

    private suspend fun bootstrap() {
        val attempt = try {
            installGeneration(installGateway = true)
        } catch (t: Throwable) {
            // An escaped install failure carries no proven attempt identity, so
            // it may never remove or overwrite whatever registry is current.
            cleanupAfterBootstrapFailure("bootstrap_exception", null)
            return
        }
        if (attempt == null) return
        val registered = try { statusReader() } catch (t: Throwable) { false }
        if (!registered) {
            cleanupAfterBootstrapFailure("readback_failed", attempt)
            return
        }
        synchronized(capabilityLock) {
            // Only this exact attempt may publish Ready, only if its own
            // failure never won the race, and only while no newer install has
            // established installing ownership. A retired attempt cannot
            // publish readiness for another attempt either.
            if (currentGeneration === attempt && installingGeneration == null &&
                !attempt.failed.get()) {
                capabilityState.value = SecretGatewayCapability.Ready
            }
        }
    }

    /**
     * Identity-bound bootstrap cleanup. [attempt] is the exact generation that
     * this bootstrap installed (or null when no ownership can be proven). The
     * method never re-reads the current owner after an await and never removes
     * or clears a generation it does not own.
     */
    private suspend fun cleanupAfterBootstrapFailure(reason: String, attempt: Generation?) {
        if (attempt == null) {
            synchronized(capabilityLock) {
                if (currentGeneration == null && installingGeneration == null) {
                    capabilityState.value = SecretGatewayCapability.Failed(reason)
                }
            }
            return
        }
        attempt.stopRequested.set(true)
        if (!joinPoller(attempt)) {
            // Retain the real non-joined poller and its registry ownership.
            // No remove/clear: the fence in installGeneration blocks a bind
            // until this exact thread is actually joined.
            fencePoller(attempt)
            synchronized(capabilityLock) {
                if (currentGeneration === attempt) {
                    capabilityState.value = SecretGatewayCapability.Failed(reason)
                }
            }
            // Best-effort honest registry readback; no secret content.
            runCatching { statusReader() }
            return
        }
        unfencePoller(attempt)
        val alive = drainChildren(timings.drainChildrenMillis, attempt.id)
        for (record in alive) quarantine.add(record)
        installMutex.withLock {
            val owns = synchronized(capabilityLock) {
                if (currentGeneration === attempt) {
                    currentGeneration = null
                    true
                } else {
                    false
                }
            }
            if (owns) {
                runCatching { native.removeSecretGateway() }
                synchronized(capabilityLock) {
                    capabilityState.value = SecretGatewayCapability.Failed(reason)
                }
            }
        }
        // Best-effort honest registry readback; no secret content.
        runCatching { statusReader() }
    }

    /**
     * Quiesce/drain the previous generation BEFORE native bind, enforce the
     * live-generation cap, bind a strictly newer epoch, start the dedicated
     * poller, await the REAL first await acknowledgment, then (optionally)
     * install the gateway. Serialized by installMutex.
     *
     * Returns the exact attempt that is now installed/ready, or null when this
     * attempt published failure. The caller must use that identity (never a
     * fresh currentGeneration read) for later readback cleanup.
     */
    internal suspend fun installGeneration(installGateway: Boolean): Generation? =
        installMutex.withLock {
            val attempt = Generation(epochCounter.incrementAndGet())
            // Installing ownership exists before the previous attempt is
            // retired, so a late old callback can never publish for this one.
            synchronized(capabilityLock) { installingGeneration = attempt }
            try {
                val previous = synchronized(capabilityLock) { currentGeneration }
                if (previous != null && previous !== attempt) {
                    previous.stopRequested.set(true)
                    if (!joinPoller(previous)) {
                        fencePoller(previous)
                        publishFailed("poller_join_timeout")
                        return@withLock null
                    }
                    unfencePoller(previous)
                    val alive = drainChildren(timings.drainChildrenMillis, previous.id)
                    for (record in alive) quarantine.add(record)
                }
                // A fenced poller is actual live ownership: no bind below may
                // proceed until every one of them is really joined.
                if (!joinFencedPollers()) {
                    publishFailed("poller_join_timeout")
                    return@withLock null
                }
                if (capacity.liveGenerations >= MAX_LIVE_GENERATIONS) {
                    installBusyCount.incrementAndGet()
                    publishFailed("install_busy")
                    return@withLock null
                }
                try {
                    native.ensureLoaded()
                } catch (t: Throwable) {
                    publishFailed("native_unavailable")
                    return@withLock null
                }
                if (store == null) {
                    store = try {
                        storeProvider()
                    } catch (t: Throwable) {
                        publishFailed("store_failed")
                        return@withLock null
                    }
                }
                val bind = try {
                    native.bindSecretDispatcher(attempt.id)
                } catch (t: Throwable) {
                    publishFailed("bind_failed")
                    return@withLock null
                }
                if (bind != 0) {
                    publishFailed("bind_failed")
                    return@withLock null
                }
                synchronized(capabilityLock) { currentGeneration = attempt }
                startPoller(attempt)
                val ack = try {
                    withTimeoutOrNull(timings.readyAckMillis) { attempt.readyAck.await() }
                } catch (t: Throwable) {
                    null
                }
                if (ack == null) {
                    val joined = stopAndDrain(attempt)
                    clearCurrentIfOwned(attempt, joined)
                    publishFailed("ready_timeout")
                    return@withLock null
                }
                if (installGateway) {
                    val installed = try {
                        native.installSecretGateway()
                    } catch (t: Throwable) {
                        -1
                    }
                    if (installed != 0) {
                        runCatching { native.removeSecretGateway() }
                        val joined = stopAndDrain(attempt)
                        clearCurrentIfOwned(attempt, joined)
                        publishFailed("install_failed")
                        return@withLock null
                    }
                }
                attempt
            } finally {
                synchronized(capabilityLock) {
                    if (installingGeneration === attempt) installingGeneration = null
                }
            }
        }

    /**
     * Stops/drains one attempt and reports whether its poller was ACTUALLY
     * joined. A non-joined poller is fenced and retained; no time disposal.
     */
    private suspend fun stopAndDrain(generation: Generation): Boolean {
        generation.stopRequested.set(true)
        val joined = joinPoller(generation)
        if (joined) unfencePoller(generation) else fencePoller(generation)
        val alive = drainChildren(timings.drainChildrenMillis, generation.id)
        for (record in alive) quarantine.add(record)
        return joined
    }

    /** Clears the registry owner only when join succeeded and identity matches. */
    private fun clearCurrentIfOwned(generation: Generation, joined: Boolean) {
        if (!joined) return
        synchronized(capabilityLock) {
            if (currentGeneration === generation) currentGeneration = null
        }
    }

    private fun publishFailed(reason: String) {
        synchronized(capabilityLock) {
            capabilityState.value = SecretGatewayCapability.Failed(reason)
        }
    }

    /**
     * Failure is owned by the exact attempt that produced it. A null identity
     * proves nothing and can never remove a registry. While a replacement is
     * installing, retired callbacks are stale even if the old generation is
     * still the nominal current owner.
     */
    private fun triggerGenerationFailure(reason: String, generation: Generation?) {
        if (generation == null) {
            generationFailureCount.incrementAndGet()
            diagnostics("unowned_generation_failure:$reason")
            return
        }
        val accepted = synchronized(capabilityLock) {
            val owner = installingGeneration ?: currentGeneration
            if (owner !== generation) {
                false
            } else if (!generation.failed.compareAndSet(false, true)) {
                false
            } else {
                capabilityState.value = SecretGatewayCapability.Failed("generation_failure")
                true
            }
        }
        if (!accepted) {
            generationFailureCount.incrementAndGet()
            diagnostics("stale_generation_failure:$reason")
            return
        }
        generationFailureCount.incrementAndGet()
        generation.stopRequested.set(true)
        cleanupScope.launch { cleanupGenerationFailure(generation) }
        diagnostics("generation_failure:$reason")
    }

    /** Publishes Failed only while [target] still owns the lifecycle. */
    private fun publishGenerationFailureIfOwned(target: Generation) {
        synchronized(capabilityLock) {
            val owner = installingGeneration ?: currentGeneration
            if (owner === target) {
                capabilityState.value = SecretGatewayCapability.Failed("generation_failure")
            }
        }
    }

    /**
     * Stop/drain/quarantine the failed generation WITHOUT holding the
     * install lifecycle lock, then publish removal only if this generation is
     * still the current owner. A bounded join timeout retains the real poller
     * and registry ownership (fenced) instead of removing or clearing it; a
     * later install cannot bind until that thread is actually joined. This
     * lets a serialized replacement proceed while an old cleanup is paused and
     * prevents a delayed cleanup from removing the newer gateway.
     */
    private suspend fun cleanupGenerationFailure(target: Generation) {
        target.stopRequested.set(true)
        if (!joinPoller(target)) {
            fencePoller(target)
            publishGenerationFailureIfOwned(target)
            return
        }
        unfencePoller(target)
        val alive = drainChildren(timings.drainChildrenMillis, target.id)
        for (record in alive) quarantine.add(record)
        val hooks = failureCleanupHooksForTest
        if (hooks != null) {
            hooks.reached.complete(Unit)
            withTimeoutOrNull(5_000) { hooks.release.await() }
        }
        try {
            installMutex.withLock {
                val owns = synchronized(capabilityLock) {
                    if (currentGeneration === target) {
                        currentGeneration = null
                        true
                    } else {
                        false
                    }
                }
                if (owns) {
                    runCatching { native.removeSecretGateway() }
                    synchronized(capabilityLock) {
                        capabilityState.value = SecretGatewayCapability.Failed("generation_failure")
                    }
                }
            }
        } finally {
            hooks?.finished?.complete(Unit)
        }
    }

    // MARK: Poller fence

    private fun fencePoller(generation: Generation) {
        synchronized(capabilityLock) { fencedPollers.add(generation) }
    }

    private fun unfencePoller(generation: Generation) {
        synchronized(capabilityLock) { fencedPollers.remove(generation) }
    }

    /**
     * Joins every retained non-joined poller. Returns false if any is still
     * alive after its bounded join; the caller must NOT proceed to a new
     * native bind. Never called while capabilityLock is held.
     */
    private fun joinFencedPollers(): Boolean {
        while (true) {
            val next = synchronized(capabilityLock) { fencedPollers.firstOrNull() }
                ?: return true
            next.stopRequested.set(true)
            if (!joinPoller(next)) return false
            unfencePoller(next)
        }
    }

    // MARK: Poller

    private fun startPoller(generation: Generation) {
        val thread = Thread({ pollLoop(generation) }, "floe-secret-poll")
        thread.isDaemon = true
        generation.thread = thread
        thread.start()
    }

    private fun joinPoller(generation: Generation): Boolean {
        val thread = generation.thread ?: return true
        if (thread === Thread.currentThread()) return false
        return try {
            thread.join(timings.pollerJoinMillis)
            !thread.isAlive
        } catch (error: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
    }

    private fun pollLoop(generation: Generation) {
        while (!generation.stopRequested.get()) {
            val claim = try {
                native.awaitSecretRequest(POLL_TIMEOUT_MILLIS)
            } catch (t: Throwable) {
                generation.readyAck.completeExceptionally(t)
                if (!generation.stopRequested.get()) {
                    triggerGenerationFailure("await_failed", generation)
                }
                return
            }
            if (claim == 0L) {
                generation.readyAck.complete(Unit)
                continue
            }
            if (claim < 0L) {
                generation.readyAck.completeExceptionally(
                    IllegalStateException("await_status_$claim"))
                if (claim == -104L) return
                triggerGenerationFailure("await_failed", generation)
                return
            }
            generation.readyAck.complete(Unit)
            try {
                processClaim(generation, claim)
            } catch (t: Throwable) {
                triggerGenerationFailure("segment_failed", generation)
                return
            }
        }
    }

    // MARK: Serialized claim segment

    /**
     * ONE non-suspending segment on the poller thread: describe -> reserve ->
     * quarantine -> unlock precheck -> take -> liveness -> UNDISPATCHED store
     * launch. The reservation ticket is released on every pre-submit branch;
     * only the real child ownership transfer hands release to the child.
     */
    private fun processClaim(generation: Generation, claim: Long) {
        if (generation.stopRequested.get()) {
            settleClaim(claim, -14, null, generation)
            return
        }
        val descriptor = try {
            native.describeSecretRequest(claim)
        } catch (t: Throwable) {
            null
        }
        if (descriptor == null) {
            settleClaim(claim, -14, null, generation)
            return
        }
        val parsed = parseDescriptor(descriptor)
        if (parsed == null) {
            settleClaim(claim, -14, null, generation)
            return
        }
        val reserveBytes = when (parsed.operation) {
            Operation.WRITE, Operation.READ -> MAX_SECRET_BYTES.toLong()
            Operation.DELETE -> 0L
        }
        val ticket = capacity.reserve(generation.id, reserveBytes)
        if (ticket == null) {
            dispatcherCapacityRejects.incrementAndGet()
            settleClaim(claim, -16, null, generation)
            return
        }
        var transferred = false
        var payload: ByteArray? = null
        try {
            if (quarantine.isQuarantined(parsed.reference)) {
                settleClaim(claim, -15, null, generation)
                return
            }
            if (!runCatching { unlockChecker() }.getOrDefault(false)) {
                settleClaim(claim, -9, null, generation)
                return
            }
            if (parsed.operation == Operation.WRITE) {
                payload = try {
                    native.takeSecretPayload(claim)
                } catch (t: Throwable) {
                    null
                }
                if (payload == null) {
                    settleClaim(claim, -14, null, generation)
                    return
                }
                ticket.shrinkTo(payload.size.toLong())
            }
            val live = try {
                native.isSecretRequestLive(claim)
            } catch (t: Throwable) {
                false
            }
            if (!live) {
                settleClaim(claim, -13, null, generation)
                return
            }
            if (generation.stopRequested.get()) {
                settleClaim(claim, -14, null, generation)
                return
            }
            val childJob = try {
                scope.launch(ioDispatcher, CoroutineStart.UNDISPATCHED) {
                    runChild(generation, claim, parsed, payload, ticket)
                }
            } catch (t: Throwable) {
                settleClaim(claim, -14, null, generation)
                return
            }
            transferred = true
            trackChild(claim, generation.id, parsed.reference, childJob, ticket)
        } finally {
            if (!transferred) {
                payload?.fill(0)
                ticket.release()
            }
        }
    }

    private suspend fun runChild(generation: Generation, claim: Long, parsed: Descriptor,
                                 payload: ByteArray?, ticket: ReservationTicket) {
        var result: ByteArray? = null
        try {
            val activeStore = store ?: throw IllegalStateException("store_unavailable")
            val status = when (parsed.operation) {
                Operation.READ -> {
                    val value = activeStore.read(parsed.reference)
                    result = value
                    if (value == null) 2 else 1
                }
                Operation.WRITE -> {
                    activeStore.write(parsed.reference, payload ?: ByteArray(0))
                    3
                }
                Operation.DELETE -> {
                    activeStore.delete(parsed.reference)
                    4
                }
            }
            settleClaim(claim, status, result, generation)
        } catch (error: CredentialStoreException) {
            settleClaim(claim, credentialStatus(error), null, generation)
        } catch (error: CancellationException) {
            settleClaim(claim, -11, null, generation)
            throw error
        } catch (t: Throwable) {
            diagnostics("internal_error:${t::class.simpleName ?: "Throwable"}")
            settleClaim(claim, -12, null, generation)
        } finally {
            payload?.fill(0)
            result?.fill(0)
            ticket.release()
        }
    }

    private fun trackChild(claim: Long, generationId: Long, reference: String,
                           job: Job, ticket: ReservationTicket) {
        val record = ChildRecord(generationId, claim, reference, job)
        trackedChildren[claim] = record
        job.invokeOnCompletion {
            trackedChildren.remove(claim, record)
            quarantine.remove(record)
            ticket.release()
        }
    }

    /**
     * Exactly one completion attempt; -105 triggers EXACTLY ONE allocation-free
     * fallback complete(-14, null). A throwing complete (or an invalid/failed
     * fallback) is an unsettleable generation failure: stop/quiesce + off-main
     * remove/drain, while capacity stays held by the real child until its end.
     */
    private fun settleClaim(claim: Long, status: Int, value: ByteArray?,
                            generation: Generation?): SettleOutcome {
        val first = try {
            native.completeSecretRequest(claim, status, value)
        } catch (t: Throwable) {
            triggerGenerationFailure("complete_threw", generation)
            return SettleOutcome.UNSETTLEABLE
        }
        return when (first) {
            0, -103 -> {
                if (status == -14) abandonedCount.incrementAndGet()
                SettleOutcome.ACCEPTED
            }
            -105 -> {
                val fallback = try {
                    native.completeSecretRequest(claim, -14, null)
                } catch (t: Throwable) {
                    triggerGenerationFailure("fallback_threw", generation)
                    return SettleOutcome.UNSETTLEABLE
                }
                when (fallback) {
                    0, -103 -> {
                        abandonedCount.incrementAndGet()
                        SettleOutcome.ACCEPTED
                    }
                    -105 -> {
                        triggerGenerationFailure("fallback_invalid", generation)
                        SettleOutcome.UNSETTLEABLE
                    }
                    else -> SettleOutcome.TERMINAL
                }
            }
            else -> SettleOutcome.TERMINAL
        }
    }

    private fun credentialStatus(error: CredentialStoreException): Int = when (error) {
        is CredentialStoreException.InvalidReference -> -1
        is CredentialStoreException.InvalidValue -> -2
        is CredentialStoreException.CorruptRecord -> -3
        is CredentialStoreException.AuthenticationFailed -> -4
        is CredentialStoreException.KeyUnavailable -> -5
        is CredentialStoreException.KeyStoreFailure -> -6
        is CredentialStoreException.StorageFailure -> -7
        is CredentialStoreException.DeleteFailed -> -8
        is CredentialStoreException.InvalidNamespace -> -12
    }

    private fun parseDescriptor(value: String): Descriptor? {
        val match = descriptorPattern.matchEntire(value) ?: return null
        val operation = Operation.parse(match.groupValues[1]) ?: return null
        val reference = match.groupValues[2]
        if (reference.toByteArray(Charsets.UTF_8).size != 71) return null
        return Descriptor(operation, reference)
    }

    private suspend fun drainChildren(timeoutMillis: Long,
                                      generationId: Long? = null): List<ChildRecord> {
        val deadline = System.nanoTime() + timeoutMillis * 1_000_000L
        while (true) {
            // isCompleted, NOT isActive: a cancelled child blocked in the
            // frozen store's non-cancellable suspendCoroutine is still an
            // actual outstanding I/O and must stay quarantined/accounted.
            val alive = trackedChildren.values.filter {
                (generationId == null || it.generationId == generationId) &&
                    !it.job.isCompleted
            }
            if (alive.isEmpty() || System.nanoTime() >= deadline) return alive
            delay(5)
        }
    }

    // MARK: Diagnostics / test lifecycle

    internal fun trackedJobForTest(claim: Long): Job? = trackedChildren[claim]?.job

    internal fun snapshot(): DispatcherSnapshot {
        val (refs, jobs) = quarantine.counts()
        return DispatcherSnapshot(
            capacity = capacity.snapshot(refs, jobs),
            dispatcherCapacityRejects = dispatcherCapacityRejects.get(),
            abandoned = abandonedCount.get(),
            generationFailures = generationFailureCount.get(),
            installBusy = installBusyCount.get(),
        )
    }

    internal suspend fun shutdownForTest() {
        installMutex.withLock {
            val generation = synchronized(capabilityLock) { currentGeneration }
            generation?.stopRequested?.set(true)
            var joined = true
            if (generation != null) {
                joined = joinPoller(generation)
                if (joined) unfencePoller(generation) else fencePoller(generation)
            }
            if (joined) {
                val fenced = synchronized(capabilityLock) { fencedPollers.toList() }
                for (other in fenced) {
                    other.stopRequested.set(true)
                    if (joinPoller(other)) {
                        unfencePoller(other)
                    } else {
                        joined = false
                    }
                }
            }
            if (generation != null && joined) {
                val alive = drainChildren(timings.drainChildrenMillis, generation.id)
                for (record in alive) quarantine.add(record)
            }
            if (joined) {
                runCatching { native.removeSecretGateway() }
                synchronized(capabilityLock) {
                    if (generation != null && currentGeneration === generation) {
                        currentGeneration = null
                    }
                    capabilityState.value = SecretGatewayCapability.Failed("test_shutdown")
                }
            } else {
                // Retain non-joined poller/registry ownership; test teardown
                // must release and join its own fixture threads.
                synchronized(capabilityLock) {
                    capabilityState.value = SecretGatewayCapability.Failed("test_shutdown")
                }
            }
        }
    }

    internal suspend fun bootstrapForTest() {
        bootstrap()
    }

    companion object {
        private const val STORE_NAMESPACE = "keychainAccount"

        fun create(
            context: Context,
            capabilityState: MutableStateFlow<SecretGatewayCapability> =
                MutableStateFlow(SecretGatewayCapability.Loading),
        ): SecretGatewayDispatcher {
            val appContext = context.applicationContext ?: context
            return SecretGatewayDispatcher(
                native = SystemSecretGatewayNative,
                storeProvider = {
                    AndroidKeystoreCredentialStore.create(appContext, STORE_NAMESPACE)
                },
                unlockChecker = {
                    val manager = appContext.getSystemService(Context.USER_SERVICE) as? UserManager
                    manager?.isUserUnlocked ?: false
                },
                statusReader = {
                    val response = SwiftCore.exchange(
                        """{"version":2,"operation":"credential.status","requestID":"secret-bootstrap"}""")
                    Regex("\"registered\"\\s*:\\s*true").containsMatchIn(response)
                },
                scope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
                ioDispatcher = Dispatchers.Default,
                diagnostics = { code ->
                    android.util.Log.e("FloeSecretGateway", code)
                },
                capabilityState = capabilityState,
            )
        }
    }
}
