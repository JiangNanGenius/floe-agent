// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import com.floe.android.phonecontrol.PhoneControlOwner
import java.util.UUID

/** A denial fence, never a grant. Only explicit current-user continuation
 * may remove it; saved automatic-control consent cannot do so. */
internal class PhoneAutomationPause(initial: Snapshot? = null) {
    data class Snapshot(val owner: PhoneControlOwner, val atMillis: Long, val id: UUID) {
        fun encode(): String = "1|${owner.taskID}|${owner.runID}|$atMillis|$id"
        companion object {
            fun decode(value: String?): Snapshot? = runCatching {
                val fields = value?.split('|') ?: return null
                if (fields.size != 5 || fields[0] != "1") return null
                fun uuid(text: String): UUID = UUID.fromString(text).also { require(it.toString() == text) }
                val at = fields[3].toLong().also { require(it > 0) }
                Snapshot(PhoneControlOwner(uuid(fields[1]), uuid(fields[2])), at, uuid(fields[4]))
            }.getOrNull()
        }
    }
    @Volatile var snapshot: Snapshot? = initial
        private set

    @Synchronized fun pause(owner: PhoneControlOwner, now: Long): Snapshot =
        Snapshot(owner, maxOf(1, now), UUID.randomUUID()).also { snapshot = it }

    fun isPaused(owner: PhoneControlOwner): Boolean = snapshot?.owner == owner

    @Synchronized fun resume(owner: PhoneControlOwner, expectedID: UUID, persistClear: () -> Boolean = { true }): Boolean {
        val current = snapshot ?: return false
        if (current.owner != owner || current.id != expectedID) return false
        if (!persistClear()) return false
        snapshot = null
        return true
    }

    /** Timestamp comes only from the native human-answer receipt, never
     * tool arguments. An answer predating the pause cannot remove it. */
    @Synchronized fun resumeAfterHumanAnswer(owner: PhoneControlOwner, expectedID: UUID?, answeredAt: Long,
        persistClear: () -> Boolean = { true }): Boolean {
        val current = snapshot ?: return false
        if (current.owner != owner || current.id != expectedID || answeredAt <= current.atMillis) return false
        if (!persistClear()) return false
        snapshot = null
        return true
    }
}
