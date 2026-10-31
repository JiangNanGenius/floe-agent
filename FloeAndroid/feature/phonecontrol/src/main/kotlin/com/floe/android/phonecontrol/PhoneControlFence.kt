// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol


enum class PhoneControlBlocker {
    STOPPED,
    TAKEN_OVER,
    USER_TOUCH,
    LOCKED,
    SERVICE_REVOKED,
    SERVICE_DISCONNECTED,
}

/**
 * Process-local fence for the one active phone-control run.
 *
 * - A fence generation bumps on every claim/release/block/clear, so any
 *   in-flight observation or action ticket is invalidated by stop, takeover,
 *   user touch, lock, revocation or task death.
 * - A page generation bumps when the foreground window/window set changes,
 *   invalidating node references even while the run stays authorized.
 * - `arm` is the explicit user/host re-arm after STOPPED/TAKEN_OVER/USER_TOUCH;
 *   it does not clear LOCKED or a missing service.
 *
 * This class is Android-free and synchronized; policy/identity checks remain
 * in the host grant callback and [PhoneControlPolicy].
 */
internal class PhoneControlFence {
    data class Ticket(
        val owner: PhoneControlOwner,
        val fenceGeneration: Long,
        val pageGeneration: Long,
    )

    data class State(
        val blocker: PhoneControlBlocker?,
        val owner: PhoneControlOwner?,
        val fenceGeneration: Long,
        val pageGeneration: Long,
    )

    sealed interface Claim {
        data object Ok : Claim
        data class Blocked(val blocker: PhoneControlBlocker) : Claim
        data object ForeignRun : Claim
    }

    sealed interface Verdict {
        data object Open : Verdict
        data class Blocked(val blocker: PhoneControlBlocker) : Verdict
        data object ForeignRun : Verdict
        data object StaleFence : Verdict
        data object StalePage : Verdict
    }

    private var blocker: PhoneControlBlocker? = null
    private var owner: PhoneControlOwner? = null
    private var fenceGeneration: Long = 0
    private var pageGeneration: Long = 0

    @Synchronized
    fun state(): State = State(blocker, owner, fenceGeneration, pageGeneration)

    /** Normal claim: blocked/fenced runs stay blocked; never clears a user stop. */
    @Synchronized
    fun claim(candidate: PhoneControlOwner): Claim {
        blocker?.let { return Claim.Blocked(it) }
        val current = owner
        if (current != null && current != candidate) return Claim.ForeignRun
        if (current == null) {
            owner = candidate
            fenceGeneration += 1
        }
        return Claim.Ok
    }

    /** Explicit host/user re-arm after stop/takeover/user touch. */
    @Synchronized
    fun arm(candidate: PhoneControlOwner): Claim {
        val currentBlocker = blocker
        if (currentBlocker == PhoneControlBlocker.LOCKED ||
            currentBlocker == PhoneControlBlocker.SERVICE_REVOKED ||
            currentBlocker == PhoneControlBlocker.SERVICE_DISCONNECTED
        ) {
            return Claim.Blocked(currentBlocker)
        }
        val current = owner
        if (current != null && current != candidate) return Claim.ForeignRun
        blocker = null
        owner = candidate
        fenceGeneration += 1
        return Claim.Ok
    }

    @Synchronized
    fun release(candidate: PhoneControlOwner): Boolean {
        if (owner != candidate) return false
        owner = null
        fenceGeneration += 1
        return true
    }

    @Synchronized
    fun block(reason: PhoneControlBlocker): State {
        val existing = blocker
        // A user stop/takeover/touch is terminal for this process lifetime
        // until an explicit arm; a later screen-off or service event must not
        // downgrade it into a block that clears automatically on unlock.
        if (existing != null && isTerminal(existing) && !isTerminal(reason)) {
            return state()
        }
        blocker = reason
        owner = null
        fenceGeneration += 1
        return state()
    }

    private fun isTerminal(candidate: PhoneControlBlocker): Boolean =
        candidate == PhoneControlBlocker.STOPPED ||
            candidate == PhoneControlBlocker.TAKEN_OVER ||
            candidate == PhoneControlBlocker.USER_TOUCH

    @Synchronized
    fun clear(reason: PhoneControlBlocker): Boolean {
        if (blocker != reason) return false
        blocker = null
        fenceGeneration += 1
        return true
    }

    @Synchronized
    fun onPageChanged(): Long {
        pageGeneration += 1
        return pageGeneration
    }

    @Synchronized
    fun ticket(candidate: PhoneControlOwner): Ticket? {
        if (blocker != null || owner != candidate) return null
        return Ticket(candidate, fenceGeneration, pageGeneration)
    }

    @Synchronized
    fun validate(ticket: Ticket): Verdict {
        blocker?.let { return Verdict.Blocked(it) }
        if (owner != ticket.owner) return Verdict.ForeignRun
        if (fenceGeneration != ticket.fenceGeneration) return Verdict.StaleFence
        if (pageGeneration != ticket.pageGeneration) return Verdict.StalePage
        return Verdict.Open
    }
}
