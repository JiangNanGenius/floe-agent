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
 * Service.startForeground success of the live [RunForegroundService]
 * instance and is cleared on every failure/end/destroy path. A permit
 * answer requires BOTH, so nothing is ever reported as protected when the
 * service is not really running.
 *
 * The service installs a listener for owned-set changes; the controller
 * never calls stopService concurrently with an acquire (that race could
 * strand a fresh startForegroundService delivery), so stopping is
 * service-self-driven and serialized by the system.
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
     *  service instance, so redelivery can skip an unchanged render. */
    @Volatile
    var appliedStamp: Long = -1L

    @Volatile
    private var listener: (() -> Unit)? = null
    @Volatile
    private var listenerOwner: Any? = null

    val currentStamp: Long get() = registry.currentStamp

    fun hasHeldWork(): Boolean = !registry.isEmpty()

    fun heldKinds(): Set<OperationKind> = registry.heldKinds()

    fun heldOperationIDs(): Set<String> = registry.heldOperationIDs()

    fun armNextAcquisition() {
        lastDenial = null
    }

    fun reportDenial(failure: RunForegroundFailure) {
        lastDenial = failure
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

    /** Service success path: set BEFORE waiters are allowed to observe
     *  true, so every confirmed permit has a real running FGS behind it. */
    fun markForegroundConfirmed() {
        foregroundFlow.value = true
    }

    /** Every end/failure/destroy service path clears the truth flag first;
     *  permits then answer 0 without any further bookkeeping. */
    fun markForegroundEnded() {
        foregroundFlow.value = false
        appliedStamp = -1L
    }

    /** Atomic with acquisition: a new claim either keeps the current
     * service or observes ended protection and starts a fresh delivery. */
    fun stopWhenIdle(stopService: () -> Unit): Boolean = synchronized(lifecycleDecisionLock) {
        if (!registry.isEmpty()) return@synchronized false
        markForegroundEnded()
        stopService()
        true
    }

    fun bindServiceListener(owner: Any, onChange: () -> Unit) {
        listenerOwner = owner
        listener = onChange
    }

    fun unbindServiceListener(owner: Any) {
        // Identity fence: a retiring service instance must not clear the
        // listener a newer instance already installed.
        if (listenerOwner === owner) {
            listener = null
            listenerOwner = null
        }
    }

    fun notifyOwnedSetChanged() {
        listener?.invoke()
    }

    /** Stop-button entry point (receiver thread). Returns false when the
     *  press is stale; when true, the CURRENT live owners' stop handlers
     *  were routed to their REAL cancellation paths. Ownership is NOT
     *  terminal here: leases close only when the awaited work settles. */
    fun routeStopRequest(intentStamp: Long): Boolean = registry.routeStop(intentStamp)
}
