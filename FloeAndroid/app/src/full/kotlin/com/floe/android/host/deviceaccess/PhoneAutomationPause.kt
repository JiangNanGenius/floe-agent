// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import com.floe.android.phonecontrol.PhoneControlOwner
import java.util.UUID

/** A denial fence, never a grant. Only explicit current-user continuation
 * may remove it; saved automatic-control consent cannot do so. */
internal class PhoneAutomationPause(initial: Snapshot? = null) {
    data class Snapshot(val owner: PhoneControlOwner, val atMillis: Long, val id: UUID,
        val toolCallIDs: Set<String> = emptySet()) {
        fun encode(): String = "1|${owner.taskID}|${owner.runID}|$atMillis|$id|" + toolCallIDs.sorted().joinToString(",") {
            java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(it.toByteArray(Charsets.UTF_8))
        }
        companion object {
            fun decode(value: String?): Snapshot? = runCatching {
                val encoded = value ?: return null
                val fields = encoded.split('|')
                if (encoded.length > 8192 || fields.size !in 5..6 || fields[0] != "1") return null
                fun uuid(text: String): UUID = UUID.fromString(text).also { require(it.toString() == text) }
                val at = fields[3].toLong().also { require(it > 0) }
                val calls = fields.getOrNull(5)?.takeIf { it.isNotEmpty() }?.split(',')?.map {
                    String(java.util.Base64.getUrlDecoder().decode(it), Charsets.UTF_8).also { call ->
                        require(call.length in 1..128 && call.none { ch -> ch.code < 32 })
                    }
                }?.toSet().orEmpty()
                require(calls.size <= 32)
                Snapshot(PhoneControlOwner(uuid(fields[1]), uuid(fields[2])), at, uuid(fields[4]), calls)
            }.getOrNull()
        }
    }
    @Volatile var snapshot: Snapshot? = initial
        private set

    @Synchronized fun pause(owner: PhoneControlOwner, now: Long): Snapshot =
        Snapshot(owner, maxOf(1, now), UUID.randomUUID()).also { snapshot = it }

    fun isPaused(owner: PhoneControlOwner): Boolean = snapshot?.owner == owner

    /** Only genuine platform tickets are recorded by the host. This binds
     * Continue to the question created by that phone call, not any other
     * model-authored question with a similar local label. */
    @Synchronized fun bindQuestion(owner: PhoneControlOwner, id: UUID, callID: String,
        persist: (Snapshot) -> Boolean): Boolean {
        val current = snapshot ?: return false
        if (current.owner != owner || current.id != id || callID.length !in 1..128 || callID.any { it.code < 32 }) return false
        if (callID in current.toolCallIDs) return true
        if (current.toolCallIDs.size >= 32) return false
        val next = current.copy(toolCallIDs = current.toolCallIDs + callID)
        if (!persist(next)) return false
        snapshot = next
        return true
    }

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
