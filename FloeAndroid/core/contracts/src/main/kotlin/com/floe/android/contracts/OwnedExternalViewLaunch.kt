// SPDX-License-Identifier: MPL-2.0
package com.floe.android.contracts

import java.util.concurrent.atomic.AtomicReference

/**
 * Neutral process-local fact: the trusted host just had the OS accept ONE
 * Agent-owned external document/app launch for an exact task/run/runtime
 * generation and target.
 *
 * The foreground artifact handoff starts the viewer directly from Floe's own
 * Activity (outside the Full-only phone-control session), and the background
 * handoff starts it through the phone-control session. Both are the Agent's
 * own authorized transition: the target app's subsequent programmatic
 * accessibility click/scroll events are the viewer loading itself, not fresh
 * human input. Without this fact the phone-control session treats them as a
 * real user takeover and can create a later screen-presence question the user
 * never caused.
 *
 * Boundaries:
 *  - written ONLY by trusted host code after the exact OS start returned;
 *    never from model JSON, a page, a task transcript or a peer;
 *  - RAM-only, one record, replaced by the next accepted launch and bounded
 *    by [HORIZON_MILLIS]; it never extends on later events;
 *  - carries task/run/native epoch/host generation/target package/component
 *    so the Full session can reject a different task, a stopped generation
 *    or a foreign package; the target package is the only string it reads
 *    from accessibility events (which the platform attributes);
 *  - it is NOT authority: it creates no device grant, approval, presence or
 *    automation permission and never selects a target. A build without phone
 *    control simply never reads it;
 *  - a real raw touch, own-App touch, stop/takeover/lock or a newer launch
 *    ends it. Timestamp correlation cannot prove per-event provenance; that
 *    limitation stays explicit in the session's conservative fallback.
 *
 * Android-free and time-injected: callers pass the monotonic and wall clocks,
 * so the exact boundary is unit-testable on the JVM.
 */
object OwnedExternalViewLaunch {
    /** The one bounded launch record. All fields are bounded host facts. */
    data class Snapshot(
        val taskID: String,
        val runID: String,
        val nativeEpoch: Long,
        val hostGeneration: Long,
        val targetPackage: String,
        val targetComponent: String?,
        val armedAtUptimeMillis: Long,
        val untilUptimeMillis: Long,
        val armedAtElapsedRealtimeMillis: Long,
        val untilElapsedRealtimeMillis: Long,
    )

    /**
     * A short launch-transition window, independent of the human-input
     * lookback. Later semantics retain the conservative input path.
     */
    const val HORIZON_MILLIS = 5_000L

    /** A dispatch can be stamped a few ms before this record is written. */
    const val START_SKEW_MILLIS = 250L

    const val MAX_ID_CHARS = 128
    const val MAX_PACKAGE_CHARS = 255
    const val MAX_COMPONENT_CHARS = 512

    private class Entry(val snapshot: Snapshot, val isCurrentHost: () -> Boolean)
    private val slot = AtomicReference<Entry?>(null)

    /**
     * Records one accepted host launch. Invalid/incomplete identities clear
     * the slot instead of leaving an older launch active. Returns the stored
     * record, or null when rejected.
     */
    fun note(
        taskID: String,
        runID: String,
        nativeEpoch: Long,
        hostGeneration: Long,
        targetPackage: String,
        targetComponent: String?,
        uptimeMillis: Long,
        elapsedRealtimeMillis: Long,
        isCurrentHost: () -> Boolean,
    ): Snapshot? {
        val task = taskID.trim()
        val run = runID.trim()
        val packageName = targetPackage.trim()
        val component = targetComponent?.trim()?.takeIf { it.isNotEmpty() }
        if (task.isEmpty() || task.length > MAX_ID_CHARS ||
            run.isEmpty() || run.length > MAX_ID_CHARS ||
            packageName.isEmpty() || packageName.length > MAX_PACKAGE_CHARS ||
            (component != null && component.length > MAX_COMPONENT_CHARS) ||
            nativeEpoch <= 0L || hostGeneration < 0L ||
            uptimeMillis <= 0L || elapsedRealtimeMillis <= 0L
        ) {
            slot.set(null)
            return null
        }
        val snapshot = Snapshot(
            taskID = task,
            runID = run,
            nativeEpoch = nativeEpoch,
            hostGeneration = hostGeneration,
            targetPackage = packageName,
            targetComponent = component,
            armedAtUptimeMillis = uptimeMillis,
            untilUptimeMillis = uptimeMillis + HORIZON_MILLIS,
            armedAtElapsedRealtimeMillis = elapsedRealtimeMillis,
            untilElapsedRealtimeMillis = elapsedRealtimeMillis + HORIZON_MILLIS,
        )
        slot.set(Entry(snapshot, isCurrentHost))
        return snapshot
    }

    /** The current record, for host diagnostics; null when none/cleared. */
    fun current(): Snapshot? = slot.get()?.snapshot

    /** Revalidate an already matched event without extending its event window.
     * A later launch, host retirement or explicit clear invalidates the fact. */
    fun isStillCurrent(snapshot: Snapshot): Boolean {
        val entry = slot.get() ?: return false
        if (entry.snapshot !== snapshot) return false
        if (!runCatching { entry.isCurrentHost() }.getOrDefault(false)) {
            slot.compareAndSet(entry, null)
            return false
        }
        return slot.get() === entry
    }

    /** Retire only this exact launch; a late callback must not clear a replacement. */
    fun clearIfCurrent(snapshot: Snapshot): Boolean {
        val entry = slot.get() ?: return false
        return entry.snapshot === snapshot && slot.compareAndSet(entry, null)
    }

    /** Clears the record. Returns what was cleared (for a closed log token). */
    fun clear(): Snapshot? = slot.getAndSet(null)?.snapshot

    /** A late stop from another run cannot discard a newer launch. */
    fun clearForOwner(taskID: String, runID: String): Snapshot? {
        while (true) {
            val entry = slot.get() ?: return null
            val snapshot = entry.snapshot
            if (!snapshot.taskID.equals(taskID, ignoreCase = true) ||
                !snapshot.runID.equals(runID, ignoreCase = true)) return null
            if (slot.compareAndSet(entry, null)) return snapshot
        }
    }

    /**
     * Matches a semantic accessibility event against the ONE active host
     * launch. Returns the record only when:
     *  - the record is still inside its monotonic horizon;
     *  - the event names the EXACT launched package;
     *  - its dispatch stamp is inside the bounded window (small start skew);
     *  - the observed runtime epoch and armed task/run match exactly;
     *  - the producing host still proves its captured epoch/generation.
     *
     * This never consumes the record: a viewer may emit several loading
     * events. Expiry clears it so a later event cannot revive it.
     */
    fun matchActive(
        targetPackage: String?,
        eventUptimeMillis: Long?,
        nowUptimeMillis: Long,
        nowElapsedRealtimeMillis: Long,
        expectedNativeEpoch: Long,
        expectedTaskID: String?,
        expectedRunID: String?,
    ): Snapshot? {
        val entry = slot.get() ?: return null
        val snapshot = entry.snapshot
        if (expectedNativeEpoch <= 0L || expectedTaskID.isNullOrBlank() ||
            expectedRunID.isNullOrBlank()) return null
        if (nowElapsedRealtimeMillis > snapshot.untilElapsedRealtimeMillis) {
            slot.compareAndSet(entry, null)
            return null
        }
        if (nowElapsedRealtimeMillis < snapshot.armedAtElapsedRealtimeMillis) return null
        if (snapshot.nativeEpoch != expectedNativeEpoch) return null
        if (targetPackage.isNullOrEmpty() || targetPackage != snapshot.targetPackage) return null
        if (!snapshot.taskID.equals(expectedTaskID, ignoreCase = true)) return null
        if (!snapshot.runID.equals(expectedRunID, ignoreCase = true)) return null
        val stamp = eventUptimeMillis ?: nowUptimeMillis
        if (stamp < snapshot.armedAtUptimeMillis - START_SKEW_MILLIS ||
            stamp > snapshot.untilUptimeMillis
        ) return null
        if (!runCatching { entry.isCurrentHost() }.getOrDefault(false)) {
            slot.compareAndSet(entry, null)
            return null
        }
        return snapshot.takeIf { slot.get() === entry }
    }
}
