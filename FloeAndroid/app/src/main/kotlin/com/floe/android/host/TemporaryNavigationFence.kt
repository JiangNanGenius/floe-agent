// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.feature.conversation.TemporaryEndTargetUi
import com.floe.android.feature.conversation.TemporarySessionRef
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

/**
 * Temporary-session navigation fence — the App-host side of TMP-NAV-2.
 *
 * iOS semantics: an actual route transition or New Task synchronously
 * tombstones the temporary origin BEFORE any await; rotation, recreation,
 * background and lock do not. The host must not wait for the whole
 * cancellation drain before moving the route: it transitions after the REAL
 * identity/root/epoch/incarnation-validated fence admission is observed, and
 * the async drain (owned-run cancellation, RAM close, store settle)
 * continues afterwards.
 *
 * Admission is ONLY the exact trusted typed acknowledgement emitted by the
 * native `temp.end` producer after the immediate native incarnation fence has
 * linearized:
 *
 * ```
 * "value": {
 *   "navigationFence": {
 *     "admitted": true,
 *     "conversationID": "<exact hosted id>",
 *     "incarnationID": "<exact incarnation>",
 *     "requestCorrelationID": "<exact temp.end correlation>",
 *     "epoch": <exact bound session epoch>
 *   }
 * }
 * ```
 *
 * The whole tuple must equal THIS pending request's conversation,
 * incarnation, correlation and epoch. Queue admission, prepared/progress
 * frames, a generic terminal/error/refusal, a transport failure or a timeout
 * are NOT admission. `alreadyAbsent`/`alreadyRetired` may only ride the SAME
 * exact admitted acknowledgement (they certify that this exact incarnation
 * cannot mutate); a bare reason or a generic `admitted=false` is refused.
 *
 * The acknowledgement is read from `HostEffectFrame.value` only. A similar
 * member inside `page`, `detail` or a diagnostic string is never trusted.
 * Until the native producer actually emits this acknowledgement the state
 * remains Pending and `awaitAdmission` returns false (fail closed). No
 * capability presence, command label or queue receipt is promoted to truth.
 */
class TemporaryNavigationFence internal constructor(
    private val host: RuntimeHost,
    /**
     * The exact currently-active temporary identity. Production reads the
     * conversation owner; tests inject a controlled provider for stale/late
     * callback ordering without fabricating UI state.
     */
    private val activeRefProvider: () -> TemporarySessionRef? = {
        host.conversations.activeTemporarySession()
    },
    /**
     * Called exactly once when an exact acknowledgement admits this ref, so
     * the conversation owner can retire the fenced identity before the route
     * moves. Never called for a generic terminal/refusal.
     */
    private val onAdmitted: (TemporarySessionRef) -> Unit = { ref ->
        host.conversations.onTemporaryFenceAdmitted(ref)
    },
) {
    /** One exact typed native acknowledgement (secret-free, bounded ids). */
    data class Acknowledgement(
        val conversationID: String,
        val incarnationID: String,
        val requestCorrelationID: String,
        val epoch: Long,
        val reason: String? = null,
    ) {
        /** The wire epoch is the ACTUAL trusted native root generation —
         *  never the UI holder/session counter (MAIN_TEMP_ACK_NATIVE_EPOCH_
         *  DECISION 20261019). The UI counter stays a local disposal token. */
        fun matches(ref: TemporarySessionRef, correlationID: String): Boolean =
            conversationID == ref.conversationId &&
                incarnationID == ref.incarnationId &&
                requestCorrelationID == correlationID &&
                epoch == ref.nativeRootEpoch
    }

    sealed interface State {
        data object Idle : State

        /** Fence requested for this exact tuple; waiting for the typed ack. */
        data class Pending(
            val ref: TemporarySessionRef,
            val requestCorrelationID: String,
            val epoch: Long,
        ) : State

        /** Exact acknowledgement observed; the route may transition. */
        data class Admitted(
            val ref: TemporarySessionRef,
            val acknowledgement: Acknowledgement,
        ) : State

        /** The operation ended before a valid acknowledgement (not admission). */
        data class Ended(
            val ref: TemporarySessionRef,
            val reason: String,
        ) : State

        /** Submission/pump failed before a valid acknowledgement (not admission). */
        data class Refused(
            val ref: TemporarySessionRef,
            val code: String,
        ) : State
    }

    private class FenceRequest(
        val ref: TemporarySessionRef,
        val requestCorrelationID: String,
        val request: HostCommandRequest,
        var notifyOutcome: Boolean,
    ) {
        var pump: EffectPumpHandle? = null
        var outcomeNotified: Boolean = false
    }

    private val stateFlow = MutableStateFlow<State>(State.Idle)
    val state: StateFlow<State> = stateFlow

    private val lock = Any()
    private var active: FenceRequest? = null

    /**
     * Begin ending [ref] because of a genuine route change. The route MUST
     * NOT transition until [awaitAdmission] returns true.
     *
     * A stale ref (not the currently active temporary session) is refused
     * without touching a newer fence. Repeating the same still-pending ref is
     * idempotent; a different ref supersedes the previous request and makes
     * every late callback of that older request inert.
     */
    fun beginEnd(ref: TemporarySessionRef, notifyOutcome: Boolean = false): Boolean {
        if (ref.conversationId.isBlank() || ref.incarnationId.isBlank() ||
            ref.sessionEpoch < 0
        ) {
            refuseStale(ref, "invalidSessionRef")
            return false
        }
        // The native root epoch is the ONLY wire authority for the fence
        // acknowledgement. An unbound ref (-1: no trusted readback yet) can
        // never begin — missing readback fails closed (never 0, never the UI
        // counter echoed as authority).
        if (ref.nativeRootEpoch < 0L) {
            refuseStale(ref, "nativeRootEpochUnbound")
            return false
        }
        val nativeActive = activeRefProvider()
        if (nativeActive == null || nativeActive != ref) {
            // A late/foreign begin must never mutate the current fence.
            refuseStale(ref, "staleSession")
            return false
        }

        val correlationID = host.commandClient.correlationID("tend")
        val epoch = ref.sessionEpoch
        val request = HostCommandRequest(
            command = "temp.end",
            scope = HostScope.ConversationLifecycle(ref.conversationId),
            stateful = true,
            correlationID = correlationID,
            revision = HostRevision("session.${ref.conversationId}", ref.incarnationId),
        )
        val fence = FenceRequest(
            ref = ref,
            requestCorrelationID = correlationID,
            request = request,
            notifyOutcome = notifyOutcome,
        )

        var previousPump: EffectPumpHandle? = null
        var notifyAdmission: FenceRequest? = null
        val shouldSubmit = synchronized(lock) {
            when (val current = stateFlow.value) {
                is State.Pending -> {
                    if (current.ref == ref && current.epoch == epoch) {
                        // Same navigation request: one command, one drain.
                        active?.let { existing ->
                            if (notifyOutcome && existing.ref == ref) {
                                existing.notifyOutcome = true
                            }
                        }
                        false
                    } else {
                        previousPump = active?.pump
                        active = fence
                        stateFlow.value = State.Pending(ref, correlationID, epoch)
                        true
                    }
                }
                is State.Admitted -> {
                    if (current.ref == ref) {
                        // The exact incarnation is already fenced; a second
                        // route attempt only needs the existing admission.
                        active?.let { existing ->
                            if (notifyOutcome && existing.ref == ref) {
                                existing.notifyOutcome = true
                                notifyAdmission = existing
                            }
                        }
                        false
                    } else {
                        previousPump = active?.pump
                        active = fence
                        stateFlow.value = State.Pending(ref, correlationID, epoch)
                        true
                    }
                }
                else -> {
                    previousPump = active?.pump
                    active = fence
                    stateFlow.value = State.Pending(ref, correlationID, epoch)
                    true
                }
            }
        }
        previousPump?.close()
        notifyAdmission?.let { notifyExplicitAdmission(it) }
        if (!shouldSubmit) return true

        host.scope.launch(host.ioDispatcher) {
            when (val submitted = host.commandClient.submit(request)) {
                is HostSubmitResult.Accepted -> {
                    val handle = host.commandClient.openEffectStream(
                        operationReceiptID = submitted.operationReceiptID,
                        configurationScope = "system",
                        onFrame = { frame -> consumeFrame(fence, frame) },
                        onTerminal = { terminal ->
                            host.commandClient.closeCorrelation(correlationID)
                            val stillCurrent = synchronized(lock) {
                                if (active !== fence) {
                                    false
                                } else {
                                    if (stateFlow.value is State.Pending) {
                                        stateFlow.value = State.Ended(
                                            ref, terminal.endedReason())
                                    }
                                    true
                                }
                            }
                            if (stillCurrent) {
                                notifyUnavailableIfNeeded(fence)
                            }
                        },
                        onFailure = { failure ->
                            host.commandClient.closeCorrelation(correlationID)
                            val stillCurrent = synchronized(lock) {
                                if (active !== fence) {
                                    false
                                } else {
                                    if (stateFlow.value is State.Pending) {
                                        stateFlow.value = State.Refused(ref, failure.code())
                                    }
                                    true
                                }
                            }
                            if (stillCurrent) {
                                notifyUnavailableIfNeeded(fence)
                            }
                        },
                    )
                    val closeImmediately = synchronized(lock) {
                        if (active === fence) {
                            fence.pump = handle
                            false
                        } else {
                            true
                        }
                    }
                    if (closeImmediately) handle.close()
                }
                is HostSubmitResult.Rejected -> settleBeforeAdmission(
                    fence,
                    State.Refused(ref, submitted.reason),
                )
                HostSubmitResult.Superseded -> settleBeforeAdmission(
                    fence,
                    State.Refused(ref, "superseded"),
                )
            }
        }
        return true
    }

    /**
     * Suspend until the EXACT acknowledgement for [ref] admits the route
     * transition. A foreign/later admission, terminal, refusal, reset or
     * timeout is never evidence for this ref.
     */
    suspend fun awaitAdmission(ref: TemporarySessionRef, timeoutMillis: Long = 2_000): Boolean {
        val deadline = System.nanoTime() + timeoutMillis * 1_000_000L
        while (true) {
            when (val current = stateFlow.value) {
                is State.Admitted -> {
                    if (current.ref == ref &&
                        current.acknowledgement.matches(ref, current.acknowledgement.requestCorrelationID)
                    ) {
                        return true
                    }
                    // Not this session's acknowledgement. Keep waiting only
                    // if a real request for this ref might still settle.
                }
                is State.Pending -> Unit
                is State.Ended, is State.Refused, State.Idle -> return false
            }
            if (System.nanoTime() >= deadline) {
                // Honest timeout: keep ownership, do not fabricate admission.
                // The shell keeps the user on the origin surface; the drain
                // continues in the background.
                return false
            }
            delay(16)
        }
    }

    /** The conversation host observes the end outcome for its holder echo. */
    var endOutcomeListener: ((TemporarySessionRef, TemporaryEndTargetUi) -> Unit)? = null

    internal fun reset() {
        val pump = synchronized(lock) {
            val currentPump = active?.pump
            active = null
            stateFlow.value = State.Idle
            currentPump
        }
        pump?.close()
    }

    // ------------------------------------------------------------- internals

    private fun consumeFrame(fence: FenceRequest, frame: HostEffectFrame) {
        // ONLY the typed value carrier can certify the native fence. Generic
        // page payloads, detail maps, prepared/progress frames and terminal
        // flags never reach this decoder.
        val acknowledgement = decodeAcknowledgement(frame.value) ?: return
        if (!acknowledgement.matches(fence.ref, fence.requestCorrelationID)) return
        // Ownership re-check AT admission (post-await discipline): the wire
        // acknowledgement carries only the native root epoch + identities, so
        // a SUPERSEDED UI holder whose only difference is its sessionEpoch
        // would otherwise ride a byte-valid acknowledgement. The CURRENT
        // holder (exact ref equality, including the UI sessionEpoch) must
        // still be this fence's ref, or the ack is refused.
        if (activeRefProvider() != fence.ref) {
            refuseStale(fence.ref, "staleSession")
            return
        }
        var admittedNow = false
        synchronized(lock) {
            if (active !== fence) return@synchronized
            val current = stateFlow.value
            if (current !is State.Pending) return@synchronized
            if (current.ref != fence.ref) return@synchronized
            if (current.requestCorrelationID != fence.requestCorrelationID) return@synchronized
            if (current.epoch != fence.ref.sessionEpoch) return@synchronized
            stateFlow.value = State.Admitted(fence.ref, acknowledgement)
            admittedNow = true
        }
        if (admittedNow) {
            try {
                onAdmitted(fence.ref)
            } catch (t: Throwable) {
                // The admission is already linearized; a UI listener failure
                // must not revoke or crash the fence.
            }
            notifyExplicitAdmission(fence)
        }
    }

    private fun refuseStale(ref: TemporarySessionRef, code: String) {
        synchronized(lock) {
            when (stateFlow.value) {
                // An already pending/linearized fence is never revoked by a
                // late or foreign begin call.
                is State.Pending, is State.Admitted -> Unit
                State.Idle, is State.Ended, is State.Refused ->
                    stateFlow.value = State.Refused(ref, code)
            }
        }
    }

    private fun settleBeforeAdmission(
        fence: FenceRequest,
        next: State,
    ) {
        val stillCurrent = synchronized(lock) {
            if (active !== fence) {
                false
            } else {
                if (stateFlow.value is State.Pending) {
                    stateFlow.value = next
                }
                true
            }
        }
        host.commandClient.closeCorrelation(fence.requestCorrelationID)
        if (stillCurrent) {
            notifyUnavailableIfNeeded(fence)
        }
    }

    private fun decodeAcknowledgement(value: JsonElement?): Acknowledgement? {
        val root = value as? JsonObject ?: return null
        val node = root["navigationFence"] as? JsonObject ?: return null
        val keys = node.keys
        if (keys.any { it !in ACK_FIELDS }) return null
        if (node.boolStrict("admitted") != true) return null
        val conversationID = node.stringStrict("conversationID") ?: return null
        val incarnationID = node.stringStrict("incarnationID") ?: return null
        val requestCorrelationID = node.stringStrict("requestCorrelationID") ?: return null
        val epoch = node.longStrict("epoch") ?: return null
        if (epoch < 0) return null
        val reason = node.stringStrict("reason")
        if (reason != null && reason !in ACK_REASONS) return null
        return Acknowledgement(
            conversationID = conversationID,
            incarnationID = incarnationID,
            requestCorrelationID = requestCorrelationID,
            epoch = epoch,
            reason = reason,
        )
    }

    private fun HostEffectTerminal.endedReason(): String = when (this) {
        is HostEffectTerminal.Completed -> "terminalBeforeAdmission"
        is HostEffectTerminal.Rejected -> code
        is HostEffectTerminal.Failed -> code
        is HostEffectTerminal.Cancelled -> "cancelled"
        is HostEffectTerminal.Closed -> "closed"
        is HostEffectTerminal.Replaced -> "replaced"
    }

    private fun HostPumpFailure.code(): String = when (this) {
        is HostPumpFailure.Recoverable -> code
        HostPumpFailure.Superseded -> "superseded"
    }

    /**
     * Explicit End (the holder's End button) gets exactly one short echo on
     * admission. A route-driven fence passes notifyOutcome=false because the
     * shell already committed its selected target; a late drain terminal must
     * never override it.
     */
    private fun notifyExplicitAdmission(fence: FenceRequest) {
        var notify = false
        synchronized(lock) {
            if (active === fence && fence.notifyOutcome && !fence.outcomeNotified) {
                fence.outcomeNotified = true
                notify = true
            }
        }
        if (notify) {
            try {
                endOutcomeListener?.invoke(fence.ref, TemporaryEndTargetUi.OpenNewTask)
            } catch (t: Throwable) {
                // UI echo failure is not a fence/route failure.
            }
        }
    }

    private fun notifyUnavailableIfNeeded(fence: FenceRequest) {
        var notify = false
        synchronized(lock) {
            if (active === fence && fence.notifyOutcome && !fence.outcomeNotified) {
                fence.outcomeNotified = true
                notify = true
            }
        }
        if (notify) {
            try {
                endOutcomeListener?.invoke(fence.ref, TemporaryEndTargetUi.Unavailable)
            } catch (t: Throwable) {
                // UI echo failure is not a fence/route failure.
            }
        }
    }

    private companion object {
        val ACK_FIELDS = setOf(
            "admitted", "conversationID", "incarnationID",
            "requestCorrelationID", "epoch", "reason",
        )
        val ACK_REASONS = setOf("fenced", "alreadyAbsent", "alreadyRetired")
    }
}
