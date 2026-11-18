// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import java.security.MessageDigest
import java.time.Instant
import java.util.Locale
import java.util.UUID
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull

/**
 * Truthful outcome of one device Stop/Takeover cancellation attempt for the
 * EXACT conversation/run. It is produced only from the canonical run snapshot
 * and `run.cancel` receipt/read-back; a dispatched request is never reported
 * as a cancellation.
 */
internal sealed interface DeviceRunStopReceipt {
    /**
     * The exact run has a confirmed terminal disposition with no live owner.
     * [terminal] describes the durable run, not merely a requested cancel.
     */
    data class Settled(val terminal: Boolean) : DeviceRunStopReceipt

    /** The canonical cancel was requested but read-back still observes the
     * exact run live or its approval pending. Keep showing "stopping". */
    data object StillStopping : DeviceRunStopReceipt

    /** The run domain refused the canonical `run.cancel`. Nothing here was
     * cancelled and the caller must surface a recoverable failure. */
    data class Refused(val code: String) : DeviceRunStopReceipt

    /** The snapshot/read-back could not prove either state (timeout, invalid
     * page, identity mismatch). Never treated as success. */
    data class Unverified(val code: String) : DeviceRunStopReceipt

    /** The native epoch changed between the user gesture and the read; the
     * request is moot and must not mutate the new generation. */
    data object EpochChanged : DeviceRunStopReceipt
}

/**
 * Pure classification of one exact-run snapshot for stop settlement.
 *
 * - the explicit native completed/failed/cancelled disposition with a
 *   matching durable state, no live owner, and no outstanding jobs settles;
 * - an ownerless checkpointed user stop settles device control only when the
 *   native typed settlement is current, complete and bound to this run;
 * - an unowned snapshot's null pendingApproval is unknown, not proof that
 *   approval has been revoked;
 * - live, parked, inconsistent and unknown states remain unproven and need
 *   the canonical cancel/read-back, never a local "done".
 */
internal object DeviceRunStopPolicy {
    fun classify(
        page: ConversationWire.SnapshotPage,
        awaitingBackgroundJobs: Boolean,
    ): DeviceRunStopReceipt {
        if (!validOwnerlessCarrier(page, awaitingBackgroundJobs)) {
            return DeviceRunStopReceipt.StillStopping
        }
        val terminalState = page.durableState in setOf("completed", "failed", "cancelled")
        if (terminalState && page.terminalDispositionRaw == page.durableState) {
            return DeviceRunStopReceipt.Settled(terminal = true)
        }
        if (page.durableState == "checkpointed" && page.terminalDispositionRaw == "suspended" &&
            validCurrentStopProof(page)
        ) return DeviceRunStopReceipt.Settled(terminal = false)
        return DeviceRunStopReceipt.StillStopping
    }

    /** The snapshot belongs to an exact native run and explicitly says there
     * is no live owner. A missing approval field is unknown, not JSON null. */
    private fun validOwnerlessCarrier(
        page: ConversationWire.SnapshotPage,
        awaitingBackgroundJobs: Boolean,
    ): Boolean {
        val run = canonicalUuid(page.runID) ?: return false
        canonicalUuid(page.conversationID) ?: return false
        return page.snapshotSchema == "floe.command-envelope/3" &&
            page.revision.resourceID.equals("run.$run", ignoreCase = true) &&
            page.revision.version == page.durableState &&
            page.isTerminalPresent && page.isTerminal &&
            page.durableTerminalPresent && page.durableTerminal == true &&
            page.liveOwnerPresent && !page.liveOwner && !awaitingBackgroundJobs &&
            page.currentOwnerPhase == "none" && page.currentLiveProducer == false &&
            page.pendingApprovalExplicitlyAbsent && page.pendingApproval == null &&
            page.durableWatermarkPresent && page.durableWatermark >= 0
    }

    /** Native re-verifies the durable row and its current incarnation. Repeat
     * the digest binding here against the outer task/run identity, while
     * requiring fresh, explicit owner state from the snapshot producer. */
    private fun validCurrentStopProof(page: ConversationWire.SnapshotPage): Boolean {
        val obj = page.stopSettlement ?: return false
        fun string(key: String): String? = (obj[key] as? JsonPrimitive)
            ?.takeIf { it.isString }?.contentOrNull
        fun bool(key: String): Boolean? = (obj[key] as? JsonPrimitive)
            ?.takeIf { !it.isString }?.booleanOrNull
        fun long(key: String): Long? = (obj[key] as? JsonPrimitive)
            ?.takeIf { !it.isString }?.longOrNull
        if (string("schema") != "floe.run-stop-settlement/1" ||
            bool("settled") != true || bool("currentIncarnation") != true ||
            string("durableState") != page.durableState ||
            string("currentOwnerPhase") != "none" || bool("currentLiveProducer") != false ||
            bool("ownerAbsent") != true || obj.containsKey("reason")
        ) return false

        val settlementId = canonicalUuid(string("settlementID")) ?: return false
        val runId = canonicalUuid(page.runID) ?: return false
        val conversationId = canonicalUuid(page.conversationID) ?: return false
        val eventId = canonicalUuid(string("incarnationEventID")) ?: return false
        // Parked dependency cancellation does not establish job settlement.
        val path = string("path")?.takeIf { it == "liveCancel" } ?: return false
        val settledAt = string("settledAt")?.takeIf {
            it.isNotEmpty() && it.toByteArray(Charsets.UTF_8).size <= 64 &&
                runCatching { Instant.parse(it) }.isSuccess
        } ?: return false
        val reason = string("reasonKey")
            ?.takeIf { it == "runtime.agent_runtime.the_task_was_stopped_by_you" } ?: return false
        val expectedState = string("expectedState")?.takeIf { it == "checkpointed" } ?: return false
        val incarnation = string("incarnation")?.takeIf(::isLowerHex64) ?: return false
        val incarnationSource = string("incarnationSource")
            ?.takeIf { it == "activation" || it == "launchStatus" } ?: return false
        val incarnationSequence = long("incarnationSequence")
            ?.takeIf { it >= 0 && it <= page.durableWatermark } ?: return false
        val digest = string("settlementDigest")?.takeIf(::isLowerHex64) ?: return false

        val basis = listOf(
            "floe.run.stop-settlement.v1", settlementId, runId, conversationId,
            path, settledAt, reason, expectedState, incarnation, incarnationSource,
            eventId, incarnationSequence.toString(), "1",
        ).joinToString("|")
        val calculated = MessageDigest.getInstance("SHA-256")
            .digest(basis.toByteArray(Charsets.UTF_8))
            .joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }
        return calculated == digest
    }

    private fun canonicalUuid(value: String?): String? {
        if (value == null || value.length != 36) return null
        val uuid = runCatching { UUID.fromString(value) }.getOrNull() ?: return null
        if (!uuid.toString().equals(value, ignoreCase = true)) return null
        return uuid.toString().uppercase(Locale.ROOT)
    }

    private fun isLowerHex64(value: String): Boolean =
        value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' }

    /** Bounded typed code for ordinary read/cancel failures; never raw text. */
    fun safeCode(value: String?): String = value.orEmpty()
        .take(64)
        .takeIf { it.isNotEmpty() && it.all { c -> c in 'a'..'z' || c in 'A'..'Z' ||
            c in '0'..'9' || c == '_' || c == '-' } }
        ?: "unknown"
}
