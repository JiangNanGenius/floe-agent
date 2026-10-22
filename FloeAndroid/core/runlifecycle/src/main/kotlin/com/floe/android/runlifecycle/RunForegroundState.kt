// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runlifecycle

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * The single process-wide view of Core foreground ownership. Purely
 * TRANSIENT: the registry entries live only while the real awaited work is
 * in flight; `foregroundConfirmed` mirrors ONLY the actual
 * Service.startForeground success of the CURRENT live
 * [RunForegroundService] instance and is cleared on that instance's real
 * failure/end/destroy path. A permit answer requires BOTH, so nothing is
 * ever reported as protected when the service is not really running.
 *
 * The service installs a listener for owned-set changes; the controller
 * never calls stopService concurrently with an acquire (that race could
 * strand a fresh startForegroundService delivery), so stopping is
 * service-self-driven and serialized by the system.
 *
 * Round-4 discipline (Main review): a REPLACED service instance whose
 * callbacks or destroy arrive late must NEVER clear a newer live
 * instance's foreground truth, applied stamp, listener or denial slot —
 * and the CURRENT instance's real destroy must still end protection
 * truthfully. Every service-origin mutation of the shared truth
 * (confirm, end, denial arming, idle stop, destroy) therefore carries
 * the actual current service identity and is fenced atomically under
 * the SAME `lifecycleDecisionLock` that already serializes acquisition
 * and the stop decision. Ownership is the locked identity
 * `serviceOwner === caller`, never a remembered boolean a late callback
 * could misread; bind transfers it atomically, retire ends it atomically.
 */
internal object RunForegroundState {

    private val lifecycleDecisionLock = Any()
    private val registry = OwnedOperationRegistry<RunForegroundPermitBinder>()

    private val foregroundFlow = MutableStateFlow(false)
    val foreground: StateFlow<Boolean> = foregroundFlow.asStateFlow()

    /** Last typed refusal observed while an acquirer was waiting. The
     *  acquirer drains it; a never-started wait falls back to Unavailable
     *  on timeout, never a silent success. */
    @Volatile
    private var lastDenial: RunForegroundFailure? = null

    /** Captured stamp of the notification currently applied by the live
     *  service instance, so redelivery can skip an unchanged render.
     *  Raised ONLY by the current owner's `confirmForeground` and reset
     *  by every guarded end/retire, all under the decision lock. */
    @Volatile
    var appliedStamp: Long = -1L
        private set

    /** The CURRENT live foreground service instance — the ONLY identity
     *  allowed to mutate the shared truth. Read/mutated exclusively
     *  under `lifecycleDecisionLock` (bind transfers it atomically;
     *  retire or fenced calls observe it). */
    private var serviceOwner: Any? = null

    /** Volatile mirror so the owned-set notify (Binder thread) can read
     *  the live listener without taking the decision lock; every
     *  mutation happens under that lock with the owner transfer. */
    @Volatile
    private var listener: (() -> Unit)? = null

    val currentStamp: Long get() = registry.currentStamp

    fun hasHeldWork(): Boolean = !registry.isEmpty()

    fun heldKinds(): Set<OperationKind> = registry.heldKinds()

    fun heldOperationIDs(): Set<String> = registry.heldOperationIDs()

    fun armNextAcquisition() {
        lastDenial = null
    }

    /** Service-origin denial arming, fenced to the ACTUAL current
     *  instance: a replaced instance's late denial (its promotion path
     *  failed after it stopped being the live service) can neither arm
     *  the shared denial slot nor confuse a waiting acquirer. Returns
     *  false when the caller no longer owns the foreground. */
    fun reportServiceDenial(owner: Any, failure: RunForegroundFailure): Boolean =
        synchronized(lifecycleDecisionLock) {
            if (serviceOwner !== owner) return@synchronized false
            lastDenial = failure
            true
        }

    fun takeDenial(): RunForegroundFailure? {
        val value = lastDenial
        lastDenial = null
        return value
    }

    /** Fully-typed registration boundary for the controller: either the
     *  exact live (or newly created) entry, or an honest kind conflict. */
    sealed class RegistrationOutcome {
        class Registered(
            val entry: OwnedOperationRegistry.Entry<RunForegroundPermitBinder>,
            val created: Boolean,
        ) : RegistrationOutcome()
        class Conflicting(val existingKind: OperationKind) : RegistrationOutcome()
    }

    fun acquire(
        operationID: String,
        kind: OperationKind,
        stopHandler: RunStopHandler?,
        runtimePackageName: String,
        coreContext: Context,
    ): RegistrationOutcome = synchronized(lifecycleDecisionLock) {
        val factory: (String, Long) -> RunForegroundPermitBinder = { id, generation ->
            RunForegroundPermitBinder(coreContext, id, generation, runtimePackageName)
        }
        var pair = registry.acquire(operationID, kind, stopHandler, factory)
        if (pair == null && registry.kindOf(operationID) == null) {
            // The conflicting registration settled between the two
            // reads: one bounded retry against the now-free id. If the
            // retry conflicts again, a genuine different-kind owner is
            // live and that is reported honestly.
            pair = registry.acquire(operationID, kind, stopHandler, factory)
        }
        if (pair == null) {
            val existingKind = registry.kindOf(operationID)
                ?: kind // vanished again; report without inventing another id's state.
            return@synchronized RegistrationOutcome.Conflicting(existingKind)
        }
        // Only an actual SET change notifies; a same-kind attach keeps the
        // owned set (and the stop fence stamp) identical.
        if (pair.second) notifyOwnedSetChanged()
        return@synchronized RegistrationOutcome.Registered(pair.first, created = pair.second)
    }

    /** Exact-generation, last-lease release; idempotent at the lease level
     *  and safe from any thread. Never mutates a newer same-id
     *  registration or a still-attached first operation. */
    fun release(operationID: String, ownerGeneration: Long): Boolean {
        val setChanged = registry.release(operationID, ownerGeneration)
        if (setChanged) notifyOwnedSetChanged()
        return setChanged
    }

    /** Observation helper used by the controller for honest attach
     *  bookkeeping (never on the permit path). */
    fun leaseCount(operationID: String, ownerGeneration: Long): Int =
        registry.leaseCount(operationID, ownerGeneration)

    /** Called on the Binder thread ONLY through the permit. Memory-only. */
    fun permitActive(operationID: String, ownerGeneration: Long): Boolean =
        registry.isActive(operationID, ownerGeneration, foregroundFlow.value)

    /** True only while [owner] IS the actual current foreground service.
     *  Every late service-origin callback checks this BEFORE it may
     *  touch anything shared (the guarded mutations below re-fence under
     *  the same lock, so no window between check and act exists). */
    fun isCurrentService(owner: Any): Boolean =
        synchronized(lifecycleDecisionLock) { serviceOwner === owner }

    /** Service success path, fenced to the ACTUAL current instance:
     *  only the live service's own REAL startForeground success sets
     *  the shared truth, and it applies the rendered notification stamp
     *  in the SAME atomic step, so waiters observe confirmed+stamp
     *  together. A replaced instance whose promotion returned late can
     *  neither claim the global truth nor stamp it for the newer
     *  service. Returns false when the caller is no longer current. */
    fun confirmForeground(owner: Any, notificationStamp: Long): Boolean =
        synchronized(lifecycleDecisionLock) {
            if (serviceOwner !== owner) return@synchronized false
            foregroundFlow.value = true
            appliedStamp = notificationStamp
            true
        }

    /** End/failure service paths clear the truth flag ONLY while they
     *  still own it; the newer live instance's protection stays. */
    fun endForeground(owner: Any): Boolean = synchronized(lifecycleDecisionLock) {
        if (serviceOwner !== owner) return@synchronized false
        endForegroundLocked()
        true
    }

    /** The CURRENT instance's real destroy, in ONE atomic fenced step:
     *  listener, ownership, applied stamp and foreground truth retire
     *  together — protection ends truthfully for permits (they answer 0
     *  while foreground is not real). A REPLACED instance destroyed late
     *  leaves the newer live instance's truth, stamp and listener
     *  completely untouched. */
    fun retireService(owner: Any): Boolean = synchronized(lifecycleDecisionLock) {
        if (serviceOwner !== owner) return@synchronized false
        serviceOwner = null
        listener = null
        endForegroundLocked()
        true
    }

    private fun endForegroundLocked() {
        foregroundFlow.value = false
        appliedStamp = -1L
    }

    /** Atomic with acquisition AND current ownership: a new claim either
     *  keeps the current service or observes ended protection and starts
     *  a fresh delivery. Only the CURRENT instance's callback may stop
     *  the service; a stale instance's late idle callback neither runs
     *  its stopSelf lambda nor clears anything. */
    fun stopWhenIdle(owner: Any, stopService: () -> Unit): Boolean =
        synchronized(lifecycleDecisionLock) {
            if (serviceOwner !== owner) return@synchronized false
            if (!registry.isEmpty()) return@synchronized false
            endForegroundLocked()
            stopService()
            true
        }

    /** Install the live instance's owned-set callback AND transfer the
     *  foreground ownership to it atomically: from this moment only
     *  [owner]'s guarded calls can mutate the shared truth, and any
     *  predecessor's late callbacks fence against it. */
    fun bindServiceListener(owner: Any, onChange: () -> Unit) {
        synchronized(lifecycleDecisionLock) {
            serviceOwner = owner
            listener = onChange
        }
    }

    fun notifyOwnedSetChanged() {
        listener?.invoke()
    }

    /** Test isolation only: return the object to the pristine state a
     *  fresh process starts with (no owner, no listener, no truth, no
     *  denial, empty registry). Never used by production paths. */
    fun resetForTesting() {
        synchronized(lifecycleDecisionLock) {
            serviceOwner = null
            listener = null
            lastDenial = null
            endForegroundLocked()
            registry.resetForTesting()
        }
    }

    /** Stop-button entry point (receiver thread). Returns false when the
     *  press is stale; when true, the CURRENT live owners' stop handlers
     *  were routed to their REAL cancellation paths. Ownership is NOT
     *  terminal here: leases close only when the awaited work settles. */
    fun routeStopRequest(intentStamp: Long): Boolean = registry.routeStop(intentStamp)
}
