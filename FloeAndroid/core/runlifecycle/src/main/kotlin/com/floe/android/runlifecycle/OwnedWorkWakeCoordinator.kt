// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runlifecycle

import android.content.Context
import android.os.PowerManager

/**
 * Real-work-bound CPU wake ownership (G03-R3 facilities, hardened by
 * Main's round-3 review).
 *
 * A confirmed foreground service raises PROCESS importance, but importance
 * alone is not CPU-wake ownership: with the screen off the CPU can suspend
 * and an owned run/install/job/Linux session stalls silently while the
 * notification still looks healthy. This coordinator holds exactly ONE
 * PARTIAL_WAKE_LOCK — the one ACTUAL process-owned wake object — for the
 * same lifetime as the REAL owned-operation set:
 *  * acquire only after the actual [RunForegroundService] has confirmed a
 *    real startForeground success AND the owned set is non-empty;
 *  * the wake object is CANONICAL FOR THE PROCESS, chosen once from the
 *    first handle handed in (a service creates it against the APPLICATION
 *    context). A recreated service instance passing a different handle
 *    NEVER re-points the coordinator: with per-instance handles the old
 *    held WakeLock stranded a real kernel wakelock while the new handle
 *    reported unheld and a SECOND lock stacked on top;
 *  * release ONLY when the owned set goes empty — which happens when the
 *    actual work settled (leases close on real completion), never on a
 *    stop-button press, a cancellation echo, view lifetime, a timeout or
 *    Binder death;
 *  * the flag dropping transiently between service instances does NOT
 *    release: work is still real, and a newer instance ADOPTS the existing
 *    same-process wake instead of stacking another;
 *  * a live [SettleWatch] keeps the settle check alive even after the LAST
 *    service instance is destroyed while work is still owned: the wake is
 *    released when the owned set REALLY settles, whenever and by whomever
 *    that settle happens (the per-instance listener dies with the
 *    instance; the coordinator's process watch does not);
 *  * no timed acquire, no reference-counted stacking (a leaked double
 *    acquire would outlive the work), no fullscreen flags, no
 *    battery-exemption request, no PiP and no scheduling expansion.
 *
 * The decision is a pure function so the whole safety property is JVM
 * testable; [PowerManagerWakeHandle] is a thin production adapter and
 * [RunForegroundService] is the only production handle provider.
 */
internal enum class WakeAction { ACQUIRE, KEEP, RELEASE, IDLE }

internal interface CpuWakeHandle {
    fun acquireWake()
    fun releaseWake()
    fun isWakeHeld(): Boolean
}

/** Production adapter onto the real PowerManager wake object. Must be
 *  created with the APPLICATION context when it can become the process
 *  canonical handle (a service instance must never leak its own Context
 *  into a wake that outlives it). */
internal class PowerManagerWakeHandle(context: Context) : CpuWakeHandle {
    private val wakeLock: PowerManager.WakeLock =
        context.getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_TAG)
            .apply { setReferenceCounted(false) }

    override fun acquireWake() {
        if (!wakeLock.isHeld) wakeLock.acquire()
    }

    override fun releaseWake() {
        if (wakeLock.isHeld) wakeLock.release()
    }

    override fun isWakeHeld(): Boolean = wakeLock.isHeld

    companion object {
        private const val WAKE_TAG = "FloeAndroid::core-owned-work"
    }
}

/** Process-lifetime settle notification. The production implementation
 *  lives in [RunForegroundService]'s companion (a main-looper handler
 *  that outlives every service instance); JVM tests install a fake.
 *  [scheduleSettledCheck] requests a bounded recheck of the owned set
 *  while the wake is held; [cancelSettledCheck] stops the chain when the
 *  wake is no longer held. */
internal interface SettleWatch {
    fun scheduleSettledCheck()
    fun cancelSettledCheck()
}

internal object OwnedWorkWakeCoordinator {

    private val decisionLock = Any()

    /** Token for the process-scoped settle recheck (not a service
     *  instance — instances may be gone when it fires). */
    private val processWatchToken = Any()

    /** The ONE actual wake object, chosen at most once per process from
     *  the first handle handed in. Later, DIFFERENT handles from recreated
     *  service instances are observation inputs only — never adopted, so
     *  the held wake can neither strand on a dying instance nor stack a
     *  second kernel wakelock. */
    private var processHandle: CpuWakeHandle? = null

    /** Holder identity for the current wake owner (a live service
     *  instance). Cleared only with the wake itself. */
    @Volatile
    private var holderToken: Any? = null

    @Volatile
    private var settleWatch: SettleWatch? = null

    /** Installed by the production service; null in pure JVM tests unless
     *  a fake is provided. Re-installing the same instance is idempotent. */
    fun installSettleWatch(watch: SettleWatch?) {
        synchronized(decisionLock) { settleWatch = watch }
    }

    /** Pure safety property under test:
     *  * empty owned set ⇒ the wake must not stay held (release or idle),
     *    whatever the foreground flag says (settled work ends ownership);
     *  * non-empty owned set + not held ⇒ ACQUIRE only when foreground is
     *    a CONFIRMED real service (no wake without visible protection);
     *  * non-empty + already held ⇒ KEEP even if the flag dropped — real
     *    work continues across a service-instance handoff. */
    fun decide(held: Boolean, foregroundConfirmed: Boolean, ownedEmpty: Boolean): WakeAction = when {
        ownedEmpty -> if (held) WakeAction.RELEASE else WakeAction.IDLE
        held -> WakeAction.KEEP
        foregroundConfirmed -> WakeAction.ACQUIRE
        else -> WakeAction.IDLE
    }

    /** Applies one decision against the PROCESS wake object. Returns the
     *  action taken (test/observation only; callers never act on it). */
    fun sync(token: Any, handle: CpuWakeHandle, foregroundConfirmed: Boolean, ownedEmpty: Boolean):
        WakeAction = synchronized(decisionLock) {
        val canonical = processHandle ?: handle.also { processHandle = it }
        applyLocked(token, canonical, foregroundConfirmed, ownedEmpty)
    }

    /** The settle-watch recheck path: applies the same decision from the
     *  PROCESS watcher (no live service instance required) using the
     *  canonical handle and the current real flags. */
    fun syncFromProcessWatch(foregroundConfirmed: Boolean, ownedEmpty: Boolean): WakeAction =
        synchronized(decisionLock) {
            val canonical = processHandle ?: return@synchronized WakeAction.IDLE
            applyLocked(processWatchToken, canonical, foregroundConfirmed, ownedEmpty)
        }

    /** The real wake state of the process canonical object, or null while
     *  no handle has ever been installed. */
    fun wakeHandleForProcess(): CpuWakeHandle? = synchronized(decisionLock) { processHandle }

    private fun applyLocked(token: Any, canonical: CpuWakeHandle,
                            foregroundConfirmed: Boolean, ownedEmpty: Boolean): WakeAction {
        val action = decide(canonical.isWakeHeld(), foregroundConfirmed, ownedEmpty)
        when (action) {
            WakeAction.ACQUIRE -> {
                canonical.acquireWake()
                holderToken = token
                // The wake is real now: its end must not depend on any
                // service instance staying alive.
                settleWatch?.scheduleSettledCheck()
            }
            WakeAction.KEEP -> {
                // Adopt a wake whose previous owner instance is gone
                // (same process, same real work): never a second lock.
                if (holderToken == null) holderToken = token
                settleWatch?.scheduleSettledCheck()
            }
            WakeAction.RELEASE -> {
                canonical.releaseWake()
                holderToken = null
                settleWatch?.cancelSettledCheck()
            }
            WakeAction.IDLE -> {
                // Nothing is held: no holder exists, nothing to recheck.
                holderToken = null
                settleWatch?.cancelSettledCheck()
            }
        }
        return action
    }

    /** Honest live observation for reporting: REAL wake state of the
     *  process canonical handle, never a remembered boolean and never
     *  re-pointed by a recreated service. */
    fun isCpuWakeHeld(): Boolean = wakeHandleForProcess()?.isWakeHeld() == true

    fun resetForTesting() {
        synchronized(decisionLock) {
            holderToken = null
            processHandle = null
            settleWatch = null
        }
    }
}
