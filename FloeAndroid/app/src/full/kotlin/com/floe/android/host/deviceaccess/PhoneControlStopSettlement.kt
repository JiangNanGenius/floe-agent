// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import com.floe.android.phonecontrol.PhoneControlOwner

/**
 * Display/projection state for one exact-owner Stop/Takeover that has not yet
 * been proven settled. It is RAM-only bookkeeping; the authorization fence is
 * [PhoneControlStopFence] and the actual run authority stays native.
 *
 * A stop is only ever displayed as STOPPING while the exact run/session is
 * still live, and as FAILED when the canonical cancellation/read-back could
 * not be proven. Nothing here claims a run terminated, undoes an already
 * issued device action or authorizes a new one.
 */
internal enum class DeviceStopUiPhase { STOPPING, FAILED }

/**
 * Exact-generation stop settlement projection.
 *
 * Every entry is bound to the owner and the stop token issued by
 * [PhoneControlStopFence]. A late callback from an older stop of the SAME
 * owner can never overwrite a newer stop because [mark]/[clear] require the
 * current token. Other owners are entirely independent.
 */
internal class PhoneControlStopSettlements {
    data class Entry(
        val owner: PhoneControlOwner,
        val token: Long,
        val epoch: Long,
        val phase: DeviceStopUiPhase,
        val failureCode: String? = null,
        /** The exact pending approval card (`run/call`) this stop retired,
         * so a later retry/new call of the same run is not blocked. */
        val approvalKey: String? = null,
    )

    private val entries = LinkedHashMap<PhoneControlOwner, Entry>()

    /** Start (or replace with) the current stop generation for one owner. */
    @Synchronized
    fun begin(owner: PhoneControlOwner, token: Long, epoch: Long, approvalKey: String? = null): Entry {
        val entry = Entry(owner, token, epoch, DeviceStopUiPhase.STOPPING, approvalKey = approvalKey)
        entries.remove(owner)
        entries[owner] = entry
        trim()
        return entry
    }

    /** Update only the still-current stop generation. */
    @Synchronized
    fun mark(owner: PhoneControlOwner, token: Long, phase: DeviceStopUiPhase, failureCode: String? = null): Boolean {
        val current = entries[owner] ?: return false
        if (current.token != token) return false
        entries[owner] = current.copy(phase = phase, failureCode = failureCode)
        return true
    }

    @Synchronized
    fun entry(owner: PhoneControlOwner): Entry? = entries[owner]

    @Synchronized
    fun phase(owner: PhoneControlOwner): DeviceStopUiPhase? = entries[owner]?.phase

    /** A newer stop generation is never cleared by an older cleanup. */
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

    private fun trim() {
        while (entries.size > MAX_TRACKED_STOPS) {
            val first = entries.entries.firstOrNull() ?: return
            entries.remove(first.key)
        }
    }

    companion object {
        /** Same hard bound as the authorization fence. */
        const val MAX_TRACKED_STOPS = PhoneControlStopFence.MAX_TRACKED_STOPS
    }
}
