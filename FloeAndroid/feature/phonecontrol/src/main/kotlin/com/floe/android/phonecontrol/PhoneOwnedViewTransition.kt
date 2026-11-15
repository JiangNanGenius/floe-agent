// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

/**
 * Closed source of the last accepted human-presence signal. Diagnostic only:
 * the value never authorizes anything and carries no screen content.
 */
enum class PhoneUserInteractionSource {
    /** No human interaction has been observed by this session. */
    NONE,

    /** The trusted own-App Activity touch/key hook. */
    OWN_APP_TOUCH,

    /** A raw platform touch-interaction event in any window. */
    PLATFORM_RAW_TOUCH,

    /** An external app's semantic click/scroll event (never Floe's own). */
    PLATFORM_SEMANTIC,
}

/**
 * One immutable snapshot of the last accepted human signal. Publishing all
 * fields together prevents a reader from pairing a new source with a stale
 * timestamp (or vice versa) while the service main thread updates it.
 * Diagnostic only: never authority, never screen content.
 */
data class PhoneInteractionStamp(
    val elapsedRealtimeMillis: Long,
    val wallMillis: Long,
    val source: PhoneUserInteractionSource,
    /** Exact external package for [PhoneUserInteractionSource.PLATFORM_SEMANTIC]. */
    val semanticPackage: String?,
)

/**
 * Bounded attribution of the external app's own transition/loading semantics
 * to the Agent's ONE authorized launch or document VIEW.
 *
 * Why this exists: an authorized `startActivity` makes the target app emit
 * ordinary accessibility semantic events (`TYPE_VIEW_SCROLLED` /
 * `TYPE_VIEW_CLICKED`) while it inflates, decodes and scrolls its own UI.
 * Those events are not human input, but the conservative platform path in
 * [PhoneControlSession.onExternalSemanticInteraction] would otherwise mark
 * them as a fresh user touch, fence the run with USER_TOUCH and later make the
 * host ask a screen-presence question the user never caused.
 *
 * The attribution is deliberately narrow and non-transferable:
 *  - it exists only after an ACTUAL successful dispatch by this session;
 *  - it names the exact owner, epoch, generation, target package and component;
 *  - it never applies to Floe's own package, a foreign package, another task
 *    or a newer grant generation;
 *  - it is time bounded and never extended by later events;
 *  - it never turns into presence: it only suppresses the *false* human stamp
 *    for that app's loading semantics;
 *  - any raw touch, own-App touch, stop, takeover, lock, release, explicit
 *    re-arm or principal/generation change clears it immediately.
 *
 * A genuine human tap still produces a raw touch-interaction start, which is
 * never absorbed here. Timestamp correlation cannot distinguish a human
 * semantic-only input inside this short window; that limitation is accepted
 * and must stay explicit rather than claiming per-event provenance the
 * platform record does not carry.
 *
 * Android-free and time-injected so the exact boundary is JVM-testable.
 */
internal class PhoneOwnedViewTransition(
    private val horizonMillis: Long = DEFAULT_HORIZON_MILLIS,
    private val startSkewMillis: Long = DEFAULT_START_SKEW_MILLIS,
) {
    data class Record(
        val owner: PhoneControlOwner,
        val epoch: Long,
        val generation: Long,
        val targetPackage: String,
        val targetComponent: String?,
        val fromUptimeMillis: Long,
        val untilUptimeMillis: Long,
    ) {
        fun contains(eventUptimeMillis: Long): Boolean =
            eventUptimeMillis >= fromUptimeMillis && eventUptimeMillis <= untilUptimeMillis
    }

    private var record: Record? = null

    /** Current record for closed diagnostics/tests; never an authorization. */
    val armed: Record? get() = record

    /**
     * Arms ONE owned transition. A blank target package, a non-positive
     * horizon or a non-positive owner epoch never arms anything.
     */
    fun arm(
        owner: PhoneControlOwner,
        epoch: Long,
        generation: Long,
        targetPackage: String,
        targetComponent: String?,
        uptimeMillis: Long,
    ): Record? {
        val packageName = targetPackage.trim()
        if (packageName.isEmpty() || epoch <= 0L || generation <= 0L || horizonMillis <= 0L) {
            record = null
            return null
        }
        val armed = Record(
            owner = owner,
            epoch = epoch,
            generation = generation,
            targetPackage = packageName,
            targetComponent = targetComponent?.trim()?.takeIf { it.isNotEmpty() },
            fromUptimeMillis = uptimeMillis - startSkewMillis,
            untilUptimeMillis = uptimeMillis + horizonMillis,
        )
        record = armed
        return armed
    }

    /** Clears the record and returns what was cleared (for a closed log token). */
    fun clear(): Record? {
        val previous = record
        record = null
        return previous
    }

    /**
     * True only for a semantic event from the EXACT package this session last
     * launched, while the same live fence owner/epoch/generation still holds,
     * inside the bounded window, and with no active fence blocker.
     *
     * Any failure path simply returns false; the caller keeps the existing
     * conservative human-takeover behavior. Expiry clears the record so a
     * later event cannot revive it.
     */
    fun absorbs(
        packageName: String?,
        eventUptimeMillis: Long?,
        fenceOwner: PhoneControlOwner?,
        fenceBlocked: Boolean,
        nowUptimeMillis: Long,
        currentEpoch: Long,
        currentGeneration: Long,
    ): Boolean {
        val current = record ?: return false
        if (fenceBlocked) {
            record = null
            return false
        }
        if (fenceOwner == null || fenceOwner != current.owner) return false
        if (currentEpoch != current.epoch || currentGeneration != current.generation) return false
        if (nowUptimeMillis > current.untilUptimeMillis) {
            record = null
            return false
        }
        if (packageName.isNullOrEmpty() || packageName != current.targetPackage) return false
        val stamp = eventUptimeMillis ?: nowUptimeMillis
        return current.contains(stamp)
    }

    private companion object {
        // Attribute only the short launch transition. The separate human
        // lookback does not extend this window.
        const val DEFAULT_HORIZON_MILLIS = 5_000L

        // An event derived from the launch can be stamped a few milliseconds
        // before this record is written; the small skew keeps it owned. It
        // never extends the horizon.
        const val DEFAULT_START_SKEW_MILLIS = 250L
    }
}
