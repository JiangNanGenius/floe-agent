// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import java.util.LinkedHashMap

/** One window identity read from an authorized explicit observation snapshot. */
internal data class PhoneControlWindowIdentity(
    val windowId: Int,
    val packageName: String,
)

/**
 * Bounded, generation-scoped window-id -> package attribution used only to
 * classify accessibility window events.
 *
 * The framework does not always stamp a window event with its package
 * (`TYPE_WINDOWS_CHANGED` in particular can carry only a window id). A window
 * that was positively identified earlier - by a package-carrying framework
 * event or by the explicit observation snapshot - can therefore be recognised
 * as an unrelated transient/own overlay window later. The retained identity is
 * never used to authorize an action or to bypass the observed-window checks:
 * [windowEventInvalidates] still invalidates the observed window, the observed
 * package, an active-window change and every fully unknown event, and action
 * dispatch still revalidates the live target.
 *
 * Lifecycle is deliberately narrow:
 * - identities are scoped to one (fence, page) generation and are dropped when
 *   either changes, so a new run or a re-captured page cannot inherit them;
 * - `WINDOWS_CHANGE_REMOVED` forgets the id, so a later reuse starts unknown
 *   and fails closed;
 * - a package-carrying event replaces any earlier identity for that id;
 * - an ADDED event without a package only reuses a recently confirmed
 *   identity (the state-change/ADDED pair for one window). An older identity
 *   is forgotten, so a reused numeric id is not silently attributed to the
 *   previous owner;
 * - capacity is bounded (LRU), so unattributed churn cannot accumulate state.
 *
 * This class is Android-free and synchronized; callers map framework event
 * constants to the boolean inputs and pass elapsed-realtime milliseconds.
 */
internal class PhoneControlWindowAttribution(
    private val capacity: Int = DEFAULT_CAPACITY,
) {
    private class Entry(
        val packageName: String,
        var lastConfirmedElapsedRealtimeMillis: Long,
    )

    private val identities = LinkedHashMap<Int, Entry>(capacity, 0.75f, true)
    private var fenceGeneration: Long? = null
    private var pageGeneration: Long? = null

    /** Seeds identities from one authorized explicit observation snapshot. */
    @Synchronized
    fun seed(
        fenceGeneration: Long,
        pageGeneration: Long,
        elapsedRealtimeMillis: Long,
        windows: List<PhoneControlWindowIdentity>,
    ) {
        ensureEpochLocked(fenceGeneration, pageGeneration)
        for (window in windows) {
            if (window.windowId < 0) continue
            val packageName = window.packageName.takeIf { it.isNotEmpty() } ?: continue
            rememberSnapshot(window.windowId, packageName, elapsedRealtimeMillis)
        }
    }

    /**
     * Attributes one framework window event and reports whether it must
     * invalidate the currently issued observation.
     *
     * [observedWindowId] is null when no observation can be invalidated; the
     * event's attribution is still recorded and false is returned.
     */
    @Synchronized
    fun onWindowEvent(
        fenceGeneration: Long,
        pageGeneration: Long,
        elapsedRealtimeMillis: Long,
        observedWindowId: Int?,
        observedPackageName: String?,
        eventWindowId: Int,
        eventPackageName: String?,
        isWindowStateChanged: Boolean,
        activeWindowChanged: Boolean,
        windowAdded: Boolean,
        windowRemoved: Boolean,
    ): Boolean {
        ensureEpochLocked(fenceGeneration, pageGeneration)
        val attributed = eventPackageName?.takeIf { it.isNotEmpty() }
        val trusted = attributed ?: trustedPackageLocked(
            windowId = eventWindowId,
            windowAdded = windowAdded,
            now = elapsedRealtimeMillis,
        )
        val invalidates = if (observedWindowId != null) {
            windowEventInvalidates(
                observedWindowId = observedWindowId,
                observedPackageName = observedPackageName,
                eventWindowId = eventWindowId,
                eventPackageName = trusted,
                isWindowStateChanged = isWindowStateChanged,
                activeWindowChanged = activeWindowChanged,
            )
        } else {
            false
        }
        if (eventWindowId >= 0) {
            if (windowRemoved) {
                // A removed id must never retain an identity; a reused id
                // starts unknown and therefore fails closed.
                identities.remove(eventWindowId)
            } else if (attributed != null) {
                rememberEvent(eventWindowId, attributed, elapsedRealtimeMillis)
            }
        }
        return invalidates
    }

    /** Trusted package for [windowId], or null when the id is unknown. */
    @Synchronized
    fun trustedPackage(windowId: Int): String? =
        if (windowId < 0) null else identities[windowId]?.packageName

    /** Drops every identity, e.g. when the owning observation is invalidated. */
    @Synchronized
    fun clear() {
        identities.clear()
        fenceGeneration = null
        pageGeneration = null
    }

    private fun ensureEpochLocked(fenceGeneration: Long, pageGeneration: Long) {
        if (this.fenceGeneration == fenceGeneration &&
            this.pageGeneration == pageGeneration
        ) {
            return
        }
        identities.clear()
        this.fenceGeneration = fenceGeneration
        this.pageGeneration = pageGeneration
    }

    private fun trustedPackageLocked(windowId: Int, windowAdded: Boolean, now: Long): String? {
        if (windowId < 0) return null
        val entry = identities[windowId] ?: return null
        if (windowAdded) {
            val age = now - entry.lastConfirmedElapsedRealtimeMillis
            val recent = age >= 0 && age <= ADDED_REUSE_GUARD_MS
            if (!recent) {
                // An ADDED event starts a new window lifecycle. Only an
                // identity confirmed within that add burst may be reused;
                // anything older is a reused id and stays unknown.
                identities.remove(windowId)
                return null
            }
        }
        return entry.packageName
    }

    private fun rememberSnapshot(windowId: Int, packageName: String, now: Long) {
        val existing = identities.remove(windowId)
        if (existing != null && existing.packageName == packageName) {
            existing.lastConfirmedElapsedRealtimeMillis = now
            identities[windowId] = existing
        } else {
            putEntry(windowId, Entry(packageName, now))
        }
    }

    private fun rememberEvent(windowId: Int, packageName: String, now: Long) {
        putEntry(windowId, Entry(packageName, now))
    }

    private fun putEntry(windowId: Int, entry: Entry) {
        identities.remove(windowId)
        identities[windowId] = entry
        while (identities.size > capacity) {
            val eldest = identities.entries.iterator()
            if (!eldest.hasNext()) return
            eldest.next()
            eldest.remove()
        }
    }

    private companion object {
        const val DEFAULT_CAPACITY = 32

        /** A state-event/ADDED pair belongs to one add burst; reuse is later. */
        const val ADDED_REUSE_GUARD_MS = 10_000L
    }
}
