// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.networkmonitor

import com.floe.android.core.networkmonitor.NetworkMonitorConfig
import com.floe.android.core.networkmonitor.NetworkMonitorOwner

/**
 * Pure process-local launch ledger for the one App-owned monitoring session.
 *
 * It closes the three real windows between the visible Start gesture and a
 * measurement:
 *
 *  * PENDING: reserved before `startForegroundService`; the Service has not
 *    consumed the opaque launch token yet.
 *  * CLAIMED: the Service consumed the token but `engine.start` has not
 *    linearized yet (foreground/notification work happens in this window).
 *  * ACTIVE: `engine.start` returned and the exact session is running.
 *
 * [NetworkMonitorHost] serializes every call with its own lock and holds that
 * same lock across the CLAIMED -> engine.start transition, so retirement and
 * cancellation cannot observe a half-created launch. The ledger itself does
 * no I/O, creates no thread and stores no Android object; interleavings can be
 * compiled and executed deterministically by JVM tests.
 *
 * A launch, not a session StateFlow, is the authority here: the engine state
 * is published asynchronously by the Service collector and therefore cannot
 * prove that no pending/claimed token may still attach later.
 */
internal class NetworkMonitorLaunchLedger {

    internal enum class Phase { PENDING, CLAIMED, ACTIVE }

    internal data class Launch(
        val launchId: String,
        val sessionId: String,
        val config: NetworkMonitorConfig,
        val owner: NetworkMonitorOwner,
        val generation: Long,
    )

    internal data class Entry(val launch: Launch, val phase: Phase)

    internal sealed interface ReserveResult {
        data class Reserved(val launch: Launch) : ReserveResult
        data class Existing(val launch: Launch, val phase: Phase) : ReserveResult
        data class Active(val sessionId: String) : ReserveResult
    }

    internal sealed interface CancelResult {
        data object None : CancelResult
        data class Cancelled(val launch: Launch) : CancelResult
        data class Active(val launch: Launch) : CancelResult
    }

    internal data class Retirement(
        val cancelled: List<Launch>,
        val activeSessionId: String?,
    )

    private var nextGeneration = 0L
    private var entry: Entry? = null

    /** Current launch, if any. Callers hold the host lock. */
    fun current(): Entry? = entry

    fun isPendingOrClaimed(): Boolean =
        entry?.phase.let { it == Phase.PENDING || it == Phase.CLAIMED }

    /**
     * Reserve the one launch slot. A second visible Start reuses the existing
     * pending/claimed launch instead of minting a second token; an active
     * session is reported as such. IDs are supplied by the host so the token
     * remains opaque to the Intent.
     */
    fun reserve(
        launchId: String,
        sessionId: String,
        config: NetworkMonitorConfig,
        owner: NetworkMonitorOwner,
    ): ReserveResult {
        entry?.let { existing ->
            return when (existing.phase) {
                Phase.ACTIVE -> ReserveResult.Active(existing.launch.sessionId)
                else -> ReserveResult.Existing(existing.launch, existing.phase)
            }
        }
        val launch = Launch(
            launchId = launchId,
            sessionId = sessionId,
            config = config,
            owner = owner,
            generation = ++nextGeneration,
        )
        entry = Entry(launch, Phase.PENDING)
        return ReserveResult.Reserved(launch)
    }

    /** Consume a still-pending opaque token exactly once. */
    fun claim(launchId: String): Launch? {
        val current = entry ?: return null
        if (current.phase != Phase.PENDING || current.launch.launchId != launchId) return null
        entry = current.copy(phase = Phase.CLAIMED)
        return current.launch
    }

    /**
     * Atomic admission for `engine.start`: the launch must still be the same
     * claimed generation and must not have been cancelled or retired.
     */
    fun authorizeEngineStart(launch: Launch): Boolean {
        val current = entry ?: return false
        return current.phase == Phase.CLAIMED &&
            current.launch.launchId == launch.launchId &&
            current.launch.generation == launch.generation &&
            current.launch.sessionId == launch.sessionId
    }

    /** Record the synchronous `engine.start` result as the active session. */
    fun activate(launch: Launch, actualSessionId: String = launch.sessionId): Boolean {
        val current = entry ?: return false
        if (current.phase != Phase.CLAIMED) return false
        if (current.launch.launchId != launch.launchId ||
            current.launch.generation != launch.generation
        ) {
            return false
        }
        entry = Entry(current.launch.copy(sessionId = actualSessionId), Phase.ACTIVE)
        return true
    }

    /**
     * Exact-session cancellation. Pending and claimed launches are removed
     * immediately (the opaque token can never attach again); an active launch
     * stays in the ledger so the caller can join it. A foreign session ID is
     * never touched.
     */
    fun cancelExact(sessionId: String): CancelResult {
        val current = entry ?: return CancelResult.None
        if (current.launch.sessionId != sessionId) return CancelResult.None
        return when (current.phase) {
            Phase.ACTIVE -> CancelResult.Active(current.launch)
            Phase.PENDING, Phase.CLAIMED -> {
                entry = null
                CancelResult.Cancelled(current.launch)
            }
        }
    }

    /** Notification revocation only fences a launch that never reached ACTIVE. */
    fun cancelUnstarted(): Launch? {
        val current = entry ?: return null
        if (current.phase == Phase.ACTIVE) return null
        entry = null
        return current.launch
    }

    /**
     * Service destruction/start failure before `engine.start`: only the exact
     * claimed generation is released; an already-active session is untouched.
     */
    fun abandon(launch: Launch): Boolean {
        val current = entry ?: return false
        if (current.phase == Phase.ACTIVE) return false
        if (current.launch.launchId != launch.launchId ||
            current.launch.generation != launch.generation
        ) {
            return false
        }
        entry = null
        return true
    }

    /** The engine reached terminal; the next explicit Start may reserve again. */
    fun completeActive(sessionId: String): Boolean {
        val current = entry ?: return false
        if (current.phase != Phase.ACTIVE || current.launch.sessionId != sessionId) return false
        entry = null
        return true
    }

    /**
     * Root retirement: invalidate every not-yet-active launch and report the
     * exact active session (if any) the caller must join before the native
     * root retires. The active entry remains until completion so a repeated
     * retirement cannot lose the join target.
     */
    fun retire(): Retirement {
        val current = entry
        return when {
            current == null -> Retirement(emptyList(), null)
            current.phase == Phase.ACTIVE -> Retirement(emptyList(), current.launch.sessionId)
            else -> {
                entry = null
                Retirement(listOf(current.launch), null)
            }
        }
    }

    fun activeSessionId(): String? =
        entry?.takeIf { it.phase == Phase.ACTIVE }?.launch?.sessionId
}

/**
 * Pure admission gate for native-root retirement.
 *
 * The Application arms it BEFORE the drain begins (even when the lazy
 * monitoring host was never constructed). It then refuses every launch until
 * a different, live `nativeRootEpoch` is observed; that observation clears
 * the gate so an explicit Start can legitimately run against the new root
 * generation. It is not a second root/launch tracker: it stores only the
 * epoch being retired and delegates the real lifecycle to the ledger.
 */
internal class NetworkMonitorLaunchAdmission {
    private var armed = false
    private var everArmed = false
    private var retiredEpoch: Long? = null

    /**
     * Arm for the current generation. Repeated retirement during the same
     * drain must not widen the gate: a null readback while already armed
     * keeps the last known epoch, otherwise the old generation could be
     * admitted again before the JNI root epoch transitions.
     */
    @Synchronized
    fun arm(currentNativeEpoch: Long?) {
        everArmed = true
        if (!armed) {
            armed = true
            retiredEpoch = currentNativeEpoch
            return
        }
        if (currentNativeEpoch != null) retiredEpoch = currentNativeEpoch
    }

    @Synchronized
    fun isAdmitted(currentNativeEpoch: Long?): Boolean {
        if (!armed) return true
        if (currentNativeEpoch == null || currentNativeEpoch <= 0L) return false
        if (currentNativeEpoch == retiredEpoch) return false
        armed = false
        retiredEpoch = null
        return true
    }

    @Synchronized
    fun isArmed(): Boolean = armed

    /** True once any drain armed this gate; distinguishes a new admission from a never-armed root. */
    @Synchronized
    fun wasEverArmed(): Boolean = everArmed
}
