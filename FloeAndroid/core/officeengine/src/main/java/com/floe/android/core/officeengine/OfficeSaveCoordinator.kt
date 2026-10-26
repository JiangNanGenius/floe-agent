// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

/**
 * Pure, JVM-testable state machine for ONE mount's save operations.
 *
 * Correlation rule (honest by construction): the pinned producer's
 * `.uno:Save` completion frame carries no operation id, so at most ONE
 * WORKING_COPY_FLUSH may be in flight per mount; its ack is then
 * unambiguous. A second flush while one is pending is rejected
 * (FLUSH_ALREADY_IN_FLIGHT) instead of guessing which op an ack belongs to.
 * STAGED_EXPORT runs synchronously on the serialized control lane and needs
 * no correlation; it is tracked here only for cancel-before-dispatch and
 * busy visibility.
 *
 * A `.uno:Save` ack that arrives with NO pending flush (e.g. the page's own
 * save button) is recorded as an external fact ([ExternalSaveRecord]) and
 * never completes a host operation. An ack stamped `isAutosave=true` while
 * a host flush is pending is a genuine collision the pinned protocol cannot
 * disambiguate: the pending flush settles UNKNOWN, never "success".
 *
 * Cancellation honesty: the pinned producer has NO save-cancel command.
 * Cancel is honoured only while nothing was dispatched; after dispatch the
 * operation stays pending until a real ack, a save error frame, the bounded
 * timeout ([onTimeout] → UNKNOWN) or mount end ([onMountTerminal] →
 * UNKNOWN). The working copy and every previously confirmed output are
 * retained on every non-success path.
 */
class OfficeSaveCoordinator {

    /** Verdict for the pending flush; byte verification happens outside (service lane). */
    enum class FlushVerdict {
        /** Native acked success==true; caller MUST re-read/digest the working copy before FLUSHED. */
        WRITTEN_ACK,

        /** Native answered "unmodified": nothing was written; honest no-op, not a failure. */
        UNMODIFIED,

        /** Native answered failure (result string carried) or a save error frame arrived. */
        NATIVE_FAILED,

        /** The dispatch itself failed (transport/native call threw): nothing reached the kit. */
        DISPATCH_FAILED,

        /** No proof arrived (timeout / mount end / autosave collision): outcome unknown. */
        NO_PROOF,
    }

    data class FlushOutcome(
        val opId: String,
        val verdict: FlushVerdict,
        val detail: String?,
        val cancelRequested: Boolean,
    )

    /** A `.uno:Save` completion that matches no pending host operation. */
    data class ExternalSaveRecord(
        val verdict: FlushVerdict,
        val detail: String?,
        val isAutosave: Boolean,
    )

    data class PendingFlush(
        val opId: String,
        val saveIfUnmodified: Boolean,
        var dispatched: Boolean = false,
        var cancelRequested: Boolean = false,
    )

    enum class SubmitDecision {
        ACCEPTED,
        REJECTED_BUSY,

        /**
         * A previous flush for this mount timed out without an ack, so a late
         * stale `.uno:Save` callback could still arrive and the pinned
         * protocol carries no operation id to tell it from a new op's ack.
         * New flushes are therefore refused for this mount (honest
         * degradation); STAGED_EXPORT stays available because its proof is
         * the synchronous JNI artifact itself, never an ack correlation.
         */
        REJECTED_STALE_ACK_RISK,
    }

    enum class CancelDecision {
        /** Nothing was dispatched yet; the op is honestly CANCELLED. */
        CANCELLED_BEFORE_DISPATCH,

        /** Already dispatched: no native cancel exists; the op stays pending. */
        STILL_IN_FLIGHT,

        /** No such pending op. */
        UNKNOWN_OP,
    }

    private var pendingFlush: PendingFlush? = null
    private var exportRunning: String? = null
    private var exportCancelRequested = false
    private var staleFlushAckPossible = false

    @Synchronized
    fun pendingFlushOpId(): String? = pendingFlush?.opId

    @Synchronized
    fun runningExportOpId(): String? = exportRunning

    @Synchronized
    fun isFlushDispatched(): Boolean = pendingFlush?.dispatched == true

    @Synchronized
    fun submitFlush(opId: String, saveIfUnmodified: Boolean): SubmitDecision {
        if (pendingFlush != null) return SubmitDecision.REJECTED_BUSY
        if (staleFlushAckPossible) return SubmitDecision.REJECTED_STALE_ACK_RISK
        pendingFlush = PendingFlush(opId, saveIfUnmodified)
        return SubmitDecision.ACCEPTED
    }

    @Synchronized
    fun markFlushDispatched(opId: String): Boolean {
        val pending = pendingFlush ?: return false
        if (pending.opId != opId) return false
        pending.dispatched = true
        return true
    }

    /**
     * The native dispatch itself failed (transport threw): nothing reached
     * the kit, so this is an honest failure, not an unknown.
     */
    @Synchronized
    fun abortDispatch(opId: String, detail: String): FlushOutcome? {
        val pending = pendingFlush ?: return null
        if (pending.opId != opId) return null
        pendingFlush = null
        return FlushOutcome(opId, FlushVerdict.DISPATCH_FAILED, detail, pending.cancelRequested)
    }

    /** Marks one STAGED_EXPORT as running on the control lane (serializes busy checks). */
    @Synchronized
    fun beginExport(opId: String): Boolean {
        if (exportRunning != null) return false
        exportRunning = opId
        exportCancelRequested = false
        return true
    }

    @Synchronized
    fun endExport(opId: String) {
        if (exportRunning == opId) {
            exportRunning = null
            exportCancelRequested = false
        }
    }

    /**
     * True when a cancel arrived for the RUNNING export. A synchronous JNI
     * saveAs/IO section cannot be interrupted honestly; the flag only marks
     * the receipt (cancelRequested) so the App can decide what a completed
     * artifact means for a cancelled intent.
     */
    @Synchronized
    fun isExportCancelRequested(opId: String): Boolean =
        exportRunning == opId && exportCancelRequested

    @Synchronized
    fun requestCancel(opId: String): CancelDecision {
        pendingFlush?.let { pending ->
            if (pending.opId == opId) {
                if (!pending.dispatched) {
                    pendingFlush = null
                    return CancelDecision.CANCELLED_BEFORE_DISPATCH
                }
                pending.cancelRequested = true
                return CancelDecision.STILL_IN_FLIGHT
            }
        }
        if (exportRunning == opId) {
            // Export cannot be interrupted mid-JNI/IO; the flag only marks the
            // receipt. Quiescence is the synchronized control lane itself.
            exportCancelRequested = true
            return CancelDecision.STILL_IN_FLIGHT
        }
        return CancelDecision.UNKNOWN_OP
    }

    /**
     * Consumes one parsed `.uno:Save` completion frame. Returns the pending
     * flush outcome, or an [ExternalSaveRecord] when no host op is pending
     * (second return value), or null when the frame is not a save result.
     */
    @Synchronized
    fun onNativeSaveResult(
        commandName: String,
        success: Boolean?,
        resultValue: String?,
        isAutosave: Boolean,
    ): Pair<FlushOutcome?, ExternalSaveRecord?> {
        if (commandName != OfficeSaveProtocol.SAVE_COMMAND_NAME) return null to null
        val verdict = when (OfficeSaveProtocol.outcome(success, resultValue)) {
            OfficeSaveProtocol.NativeSaveOutcome.WRITTEN -> FlushVerdict.WRITTEN_ACK
            OfficeSaveProtocol.NativeSaveOutcome.UNMODIFIED_SKIPPED -> FlushVerdict.UNMODIFIED
            OfficeSaveProtocol.NativeSaveOutcome.FAILED -> FlushVerdict.NATIVE_FAILED
            null -> FlushVerdict.NO_PROOF // unparseable frame is never evidence
        }
        val pending = pendingFlush
        if (pending == null) {
            return null to ExternalSaveRecord(verdict, resultValue, isAutosave)
        }
        // A concurrent autosave ack cannot be attributed to the host op, and
        // the host op's own ack may still arrive later: quarantine further
        // flush submissions for this mount (see REJECTED_STALE_ACK_RISK).
        if (isAutosave) {
            pendingFlush = null
            staleFlushAckPossible = true
            return FlushOutcome(pending.opId, FlushVerdict.NO_PROOF, "autosave-ack-collision", pending.cancelRequested) to null
        }
        pendingFlush = null
        return FlushOutcome(pending.opId, verdict, resultValue, pending.cancelRequested) to null
    }

    /** Consumes a native `error: cmd=.. kind=..` frame that describes a save failure. */
    @Synchronized
    fun onSaveErrorFrame(cmd: String?, kind: String?): FlushOutcome? {
        if (!OfficeSaveProtocol.isSaveRelatedError(cmd, kind)) return null
        val pending = pendingFlush ?: return null
        pendingFlush = null
        return FlushOutcome(pending.opId, FlushVerdict.NATIVE_FAILED, "error:cmd=$cmd kind=$kind", pending.cancelRequested)
    }

    /** Bounded watchdog fired by the service: honest UNKNOWN, never success. */
    @Synchronized
    fun onTimeout(opId: String): FlushOutcome? {
        val pending = pendingFlush ?: return null
        if (pending.opId != opId) return null
        pendingFlush = null
        // The ack may still arrive after this window; never let it satisfy a
        // later operation (Main contract 2026-10-26).
        staleFlushAckPossible = true
        return FlushOutcome(opId, FlushVerdict.NO_PROOF, "timeout-without-ack", pending.cancelRequested)
    }

    /** Mount end (BYE/close/process loss) with a pending flush: honest UNKNOWN. */
    @Synchronized
    fun onMountTerminal(): FlushOutcome? {
        val pending = pendingFlush ?: return null
        pendingFlush = null
        staleFlushAckPossible = true
        return FlushOutcome(pending.opId, FlushVerdict.NO_PROOF, "mount-ended-without-ack", pending.cancelRequested)
    }

    /** True once a flush ack went missing/collided (flush degraded; export unaffected). */
    @Synchronized
    fun isStaleFlushAckPossible(): Boolean = staleFlushAckPossible
}
