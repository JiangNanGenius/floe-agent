// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import com.floe.android.phonecontrol.PhoneControlOwner

/**
 * Exact-owner stop fence for the ONE phone-control session.
 *
 * The host previously kept a single process-wide `userStopped` boolean. That
 * made a user Stop/Takeover of task A refuse every later call from an
 * unrelated live task B, even when the durable Automatic device-control
 * consent was on. This fence keeps the same fail-closed stop semantics but
 * binds them to the exact (task, run) owner that was actually stopped:
 *
 *  - A stop never authorizes anything. It only denies the exact owner again.
 *  - Another live task is not denied merely because a different owner was
 *    stopped; it still needs its own real native claim, epoch, arm and run
 *    liveness proof through the existing gates.
 *  - The stopped owner stays denied through late callbacks, same-run retries
 *    and asynchronous cancellation settling. [settled] only records that a
 *    post-stop observation proved the stopped run is no longer live; it lets
 *    the user explicitly Continue/Allow that exact owner again. It never
 *    turns the automatic path back on.
 *  - [clear] is called only after an explicit user arm/grant success for that
 *    owner, or on a real native root stop/process teardown.
 *
 * State is RAM-only and bounded. The oldest entry is evicted only when the
 * hard cap is reached; a settled entry is evicted first.
 */
internal class PhoneControlStopFence {
    data class Entry(
        val owner: PhoneControlOwner,
        /** Native epoch at the time of the stop; informational, never a grant. */
        val epoch: Long,
        /** Monotonic stop generation, used to fence old async cleanup. */
        val token: Long,
        val settled: Boolean,
    )

    private val entries = LinkedHashMap<PhoneControlOwner, Entry>()
    private var nextToken = 0L

    /** Mark the exact owner stopped (or a new stop generation for it). */
    @Synchronized
    fun markStopped(owner: PhoneControlOwner, epoch: Long): Entry {
        nextToken += 1L
        val entry = Entry(owner, epoch, nextToken, settled = false)
        // Re-insert so the retained presentation naturally names the most
        // recently stopped owner without a second ordering field.
        entries.remove(owner)
        entries[owner] = entry
        trim()
        return entry
    }

    @Synchronized
    fun isStopped(owner: PhoneControlOwner): Boolean = entries.containsKey(owner)

    @Synchronized
    fun entry(owner: PhoneControlOwner): Entry? = entries[owner]

    @Synchronized
    fun isSettled(owner: PhoneControlOwner): Boolean =
        entries[owner]?.settled == true

    /** The retained stopped row for presentation; most recent stop wins. */
    @Synchronized
    fun lastStoppedOwner(): PhoneControlOwner? = entries.values.lastOrNull()?.owner

    /**
     * Settle stopped owners whose exact run is no longer live. The predicate
     * is evaluated outside the lock because it reads the real run holder.
     * A newer stop generation for the same owner is never overwritten by an
     * older observation.
     */
    fun settleIfNotLive(ownerLive: (PhoneControlOwner) -> Boolean): Int {
        val pending = synchronized(this) {
            entries.values.filter { !it.settled }
        }
        var changed = 0
        for (entry in pending) {
            if (ownerLive(entry.owner)) continue
            synchronized(this) {
                val current = entries[entry.owner] ?: return@synchronized
                if (current.token == entry.token && !current.settled) {
                    entries[entry.owner] = current.copy(settled = true)
                    changed += 1
                }
            }
        }
        return changed
    }

    /**
     * Explicit re-allow/Continue of one exact owner, or native teardown.
     * When [token] is supplied, only the same stop generation may be cleared;
     * this is what stops an old async cleanup from reviving a newer stop.
     */
    @Synchronized
    fun clear(owner: PhoneControlOwner, token: Long? = null): Boolean {
        val current = entries[owner] ?: return false
        if (token != null && current.token != token) return false
        entries.remove(owner)
        return true
    }

    @Synchronized
    fun clearAll() {
        entries.clear()
    }

    @Synchronized
    fun size(): Int = entries.size

    @Synchronized
    fun owners(): Set<PhoneControlOwner> = entries.keys.toSet()

    private fun trim() {
        while (entries.size > MAX_TRACKED_STOPS) {
            val settled = entries.entries.firstOrNull { it.value.settled }
            if (settled != null) {
                entries.remove(settled.key)
            } else {
                val oldest = entries.entries.firstOrNull() ?: return
                entries.remove(oldest.key)
            }
        }
    }

    companion object {
        /**
         * Bounded RAM state. A real phone has one active owner at a time; the
         * cap only protects against a pathological sequence of stops without
         * an app restart.
         */
        const val MAX_TRACKED_STOPS = 64
    }
}

/**
 * At most one exact-owner stop cleanup owns the global press/busy state at a
 * time. A NEWER owner may claim/replace it; an older cleanup then finishes as
 * a no-op. A duplicate Stop for the same still-current owner+stop generation
 * is rejected so pending cleanup cannot swallow or double-run a new Stop.
 *
 * This is presentation/cleanup bookkeeping only; the authorization fence is
 * [PhoneControlStopFence].
 */
internal class PhoneControlStopClaims {
    data class Claim(
        val owner: PhoneControlOwner,
        val stopToken: Long,
        val takeOver: Boolean,
        val sequence: Long,
    )

    private var active: Claim? = null
    private var nextSequence = 0L

    @Synchronized
    fun current(): Claim? = active

    @Synchronized
    fun isDuplicate(owner: PhoneControlOwner, stopToken: Long): Boolean =
        active?.owner == owner && active?.stopToken == stopToken

    @Synchronized
    fun begin(owner: PhoneControlOwner, stopToken: Long, takeOver: Boolean): Claim {
        nextSequence += 1L
        return Claim(owner, stopToken, takeOver, nextSequence).also { active = it }
    }

    /** True only when [claim] is still the current cleanup. */
    @Synchronized
    fun finish(claim: Claim): Boolean {
        if (active?.sequence != claim.sequence) return false
        active = null
        return true
    }

    @Synchronized
    fun clear() {
        active = null
    }
}

/**
 * The global phone service exposes only stop()/takeover(), never an
 * owner-taking API. This pure decision says whether the stopped owner is still
 * the one actual session, so cleanup cannot fence a different newly armed
 * owner. The caller must evaluate it under the same admission mutex as the
 * arm path and the stop()/takeover() call.
 */
internal object PhoneControlStopServicePolicy {
    fun mayFenceGlobalService(
        stoppedOwner: PhoneControlOwner,
        hostOwner: PhoneControlOwner?,
        serviceOwner: PhoneControlOwner?,
    ): Boolean =
        (hostOwner == null || hostOwner == stoppedOwner) &&
            (serviceOwner == null || serviceOwner == stoppedOwner)
}

/**
 * Per-owner revision counters used to fence one task's asynchronous phone
 * result after its own Stop/Pause, without invalidating a different live
 * task's in-flight call. The previous global counter made a stop of task A
 * interrupt task B's arm/screenshot/Continue path.
 *
 * The counter is opaque and monotonic per owner; it grants nothing.
 */
internal class PhoneControlRevisions {
    private val revisions = LinkedHashMap<PhoneControlOwner, Long>()
    private var next = 0L

    @Synchronized
    fun current(owner: PhoneControlOwner): Long = revisions[owner] ?: 0L

    @Synchronized
    fun bump(owner: PhoneControlOwner): Long {
        next += 1L
        revisions.remove(owner)
        revisions[owner] = next
        trim()
        return next
    }

    @Synchronized
    fun clear(owner: PhoneControlOwner) {
        revisions.remove(owner)
    }

    @Synchronized
    fun clearAll() {
        revisions.clear()
    }

    @Synchronized
    fun size(): Int = revisions.size

    private fun trim() {
        while (revisions.size > MAX_TRACKED_REVISIONS) {
            val oldest = revisions.entries.firstOrNull() ?: return
            revisions.remove(oldest.key)
        }
    }

    companion object {
        const val MAX_TRACKED_REVISIONS = 64
    }
}
