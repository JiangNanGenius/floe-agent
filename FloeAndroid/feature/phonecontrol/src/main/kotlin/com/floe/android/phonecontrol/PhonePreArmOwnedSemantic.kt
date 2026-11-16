// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import com.floe.android.contracts.OwnedExternalViewLaunch

/**
 * Bounded pre-arm attribution for the ONE Agent-owned external launch/viewer.
 *
 * The foreground artifact handoff starts the viewer directly from Floe's own
 * Activity, outside this phone-control session, and only then records the
 * trusted [OwnedExternalViewLaunch] fact. The target app can emit its own
 * loading click/scroll before the first `device.observe` establishes a fence
 * owner. At that instant the session has no principal task/run, so it cannot
 * yet prove that the event belongs to the recorded launch, and must not write
 * the event into [PhoneInteractionStamp] as fresh human presence.
 *
 * This holder captures an event ONLY after [OwnedExternalViewLaunch.matchActive]
 * has validated the still-current host record for the exact target package and
 * bounded event window (including the host's own epoch/generation/run-liveness
 * callback). The record's task/run are stored as the exact identity to require
 * later, not as an already-trusted owner of the session: the first
 * principal-bearing call must present the same task, run and native epoch
 * before the event is discarded as Agent-owned. A different task, run or epoch
 * takes the ordinary human path. This is deliberately narrower than the
 * already-armed [PhoneOwnedViewTransition] path, which can compare the live
 * fence owner immediately.
 *
 * Raw touches never reach this holder: they clear it and take over. Any real
 * external semantic event from a different package/stamp also remains on the
 * ordinary human path. The holder is RAM-only, one record, and never an
 * authorization: it creates no grant, approval, presence or device permission.
 */
internal class PhonePreArmOwnedSemantic {
    data class Candidate(
        val launch: OwnedExternalViewLaunch.Snapshot,
        val packageName: String,
        /** Arrival stamp used exactly like an ordinary semantic interaction. */
        val observedAtElapsedRealtimeMillis: Long,
        /** Original event wall stamp, for the host's approval comparison. */
        val eventWallMillis: Long,
    )

    sealed interface Resolution {
        data class Owned(val candidate: Candidate) : Resolution
        data class Human(val candidate: Candidate) : Resolution
        data object None : Resolution
    }

    private var candidate: Candidate? = null

    /** Current candidate for closed diagnostics/tests; never authority. */
    val current: Candidate? get() = candidate

    /**
     * Defers one external semantic click/scroll only when the process-local
     * host record is still current for the exact package and event window.
     *
     * [OwnedExternalViewLaunch.matchActive] requires an expected task/run. The
     * record's own values are supplied here because they are the identity to
     * capture, not proof that this session owns them; the exact principal check
     * is repeated in [resolve] before any suppression. The call still performs
     * the meaningful checks: exact target package, bounded event stamp,
     * positive runtime epoch, and the host's captured
     * epoch/generation/owner-liveness callback.
     *
     * A later matching event replaces the held timing (the newest input is the
     * one the presence gate must consider); a non-matching event is never
     * deferred. Returns true only when an event is currently held.
     */
    fun capture(
        targetPackage: String?,
        eventUptimeMillis: Long?,
        nowUptimeMillis: Long,
        nowElapsedRealtimeMillis: Long,
        nowWallMillis: Long,
    ): Boolean {
        if (targetPackage.isNullOrEmpty()) return false
        val snapshot = OwnedExternalViewLaunch.current() ?: return false
        // The record's own identity satisfies matchActive's signature only so
        // its host-currency/package/time checks run. It is NOT accepted as
        // this session's owner here; resolve() re-checks the exact principal.
        val matched = OwnedExternalViewLaunch.matchActive(
            targetPackage = targetPackage,
            eventUptimeMillis = eventUptimeMillis,
            nowUptimeMillis = nowUptimeMillis,
            nowElapsedRealtimeMillis = nowElapsedRealtimeMillis,
            expectedNativeEpoch = snapshot.nativeEpoch,
            expectedTaskID = snapshot.taskID,
            expectedRunID = snapshot.runID,
        ) ?: return false
        val stamp = eventUptimeMillis ?: nowUptimeMillis
        val lag = (nowUptimeMillis - stamp).coerceIn(0L, MAX_EVENT_LAG_MILLIS)
        candidate = Candidate(
            launch = matched,
            packageName = targetPackage,
            observedAtElapsedRealtimeMillis = nowElapsedRealtimeMillis,
            eventWallMillis = (nowWallMillis - lag).coerceAtLeast(1L),
        )
        return true
    }

    /**
     * Classifies the held event against the exact principal that just reached
     * the session. Only an equal task/run/native epoch may discard it as the
     * recorded Agent launch; every other identity becomes ordinary human
     * input. Clears the candidate exactly once.
     */
    fun resolve(
        taskID: String?,
        runID: String?,
        nativeEpoch: Long,
    ): Resolution {
        val held = candidate ?: return Resolution.None
        candidate = null
        val owned = !taskID.isNullOrBlank() && !runID.isNullOrBlank() &&
            nativeEpoch > 0L &&
            held.launch.nativeEpoch == nativeEpoch &&
            held.launch.taskID.equals(taskID, ignoreCase = true) &&
            held.launch.runID.equals(runID, ignoreCase = true) &&
            OwnedExternalViewLaunch.isStillCurrent(held.launch)
        return if (owned) Resolution.Owned(held) else Resolution.Human(held)
    }

    /** Clears the held event without classifying it (real input/lifecycle). */
    fun clear(): Candidate? {
        val held = candidate
        candidate = null
        return held
    }

    /** Same 15-second active-user window as the host's PhonePresenceGate. */
    fun isRecent(candidate: Candidate, nowElapsedRealtimeMillis: Long): Boolean =
        nowElapsedRealtimeMillis - candidate.observedAtElapsedRealtimeMillis < 15_000L

    private companion object {
        /**
         * Matches the bounded late-event allowance used by the ordinary
         * semantic path; this never extends the host launch window.
         */
        const val MAX_EVENT_LAG_MILLIS = 60_000L
    }
}
