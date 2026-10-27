// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.precision

import java.security.SecureRandom

/**
 * Pure, JVM-testable correlation ledger for ONE native session's precision
 * operations. Modeled on the proven save stale-ack quarantine discipline
 * (OfficeSaveCoordinator) and extended for the fact that native query/
 * command frames carry NO operation id:
 *
 *  - ONE operation in flight per native session (queries included): the kit
 *    replies cannot be attributed across concurrent same-kind operations,
 *    so they are serialized, never guessed. A bounded FIFO queue absorbs
 *    bursts; overflow is REFUSED (never dropped silently).
 *  - Arm-then-dispatch: an operation step is armed BEFORE its wire command
 *    is posted, so a fast local answer can never be missed. Only frames
 *    observed WHILE armed (and not awaiting a post-barrier re-arm) can
 *    settle the step.
 *
 * Stale-frame fencing and its PROOF classes (Main early review 2026-10-27):
 *  - After a mandatory-step timeout the missed frame kind is QUARANTINED.
 *    Re-arming a quarantined kind through the ordered `.uno:ReadOnly`
 *    barrier is allowed ONLY for kinds whose producer reply is emitted
 *    synchronously inside the command's own kit input handler — pinned
 *    proof: the single KitPoll thread calls `session->handleMessage`
 *    synchronously (kit/Kit.cpp:2626 at revision 2333344…) and
 *    ChildSession::_handleInput (:208) answers these commands inline via
 *    sendTextFrame before returning: getCommandValues (:1396/:1413/:1418),
 *    getTextSelection (:1882/:1901/:1912), paste (:2154-2157), getStatus,
 *    getPresentationInfo (:4565). A barrier reply (itself such a
 *    synchronous answer) therefore proves every EARLIER same-class frame
 *    was already emitted and delivered (one FIFO channel).
 *  - Callback-emitted kinds (`setpart:` SET_PART, `textselection:`
 *    TEXT_SELECTION effect frames — ChildSession loKitCallback cases
 *    :5075-5085/:4998-5000) fire from core callbacks whose emission
 *    thread/ordering is NOT byte-proven from the pinned wsd/kit sources
 *    alone. Their quarantine is PERMANENT for this mount incarnation:
 *    once such an answer went missing, later operations of that kind are
 *    REFUSED (STALE_ANSWER_QUARANTINE) until a NEW native incarnation
 *    (a new Session constructs a new ledger) — the same honest-degradation
 *    philosophy as the save surface's permanent flush quarantine.
 *  - A TIMED-OUT barrier reply is itself uncorrelated (no request ids): a
 *    later same-command barrier could consume that stale reply and clear
 *    quarantine without proof the missed frames drained. The ledger
 *    therefore POISONS barrier re-arming for the rest of the incarnation
 *    ([barrierPoisoned]); every operation that would need a barrier is
 *    refused until a new native incarnation. No in-incarnation
 *    reconciliation is claimed.
 *  - Between a consumed barrier reply and the engine's real re-dispatch,
 *    the run sits in `awaitingDispatch`: EVERY frame is discarded (counted)
 *    — a genuinely-earlier same-kind completion arriving around the
 *    barrier can never complete the fresh operation.
 *  - A late/duplicate/forged frame can never complete a NEW operation:
 *    unmatched frames are counted only; a timed-out mandatory step stays
 *    UNKNOWN with its effects uncertain and ALL data retained (the ledger
 *    is RAM-only, never deletes files and NEVER auto-undoes native
 *    in-flight effects), and quarantine blocks same-kind reuse.
 *
 * Completion honesty (Main early API review 2026-10-27): a position
 * readback proves ONLY position. A content mutation terminates
 * MUTATION_VERIFIED only when the SOFT real producer content readback
 * matched exactly. Explicit comparable conflict terminates UNKNOWN with the
 * effect uncertain; absent/unavailable readback terminates NATIVE_COMPLETED
 * (tool success then requires later owned flush/export byte verification).
 * Neither path auto-retries or auto-undoes the native attempt.
 *
 * APPLY_TEXT's post-paste `gettextselection` answer is scoped to the CURRENT
 * view selection, not to the document body or necessarily to the inserted
 * range. Its exact match is positive corroboration, but an empty, stale or
 * otherwise different selection is NOT comparable body-content conflict;
 * the owned saved-OOXML check remains the decisive negative/positive gate.
 * SET_CELL_CONTENT is different: after its cursor readback confirms the
 * exact cell, the selected-cell display text is target-scoped and a literal
 * mismatch remains an explicit comparable conflict (UNKNOWN, never replay).
 *
 * Target handles are engine-minted random ids bound to (generation, flushed
 * working-copy digest, manual-input epoch, precision-edit epoch): a manual
 * page edit while a model thinks invalidates the capture even though
 * `.uno:ModifiedStatus` merely stays true, a flush changes the digest, a
 * remount changes the generation, and any completed AI content mutation
 * advances the edit epoch. Handles are single-use for content mutations.
 *
 * All content answers are returned ONLY through typed terminal results to
 * the authorized fenced owner; this ledger stores them bounded, and its
 * diagnostic-facing surfaces expose counts/hashes/kinds only — never raw
 * document text, formulas, tokens or paths.
 */
class OfficePrecisionLedger(
    private val maxPending: Int = MAX_PENDING,
    private val maxCompleted: Int = MAX_COMPLETED,
    private val maxHandles: Int = MAX_HANDLES,
    private val handleTtlMs: Long = HANDLE_TTL_MS,
    private val clock: () -> Long = { android.os.SystemClock.elapsedRealtime() },
) {

    companion object {
        const val MAX_PENDING = 8
        const val MAX_COMPLETED = 16
        const val MAX_HANDLES = 16
        const val HANDLE_TTL_MS = 30 * 60 * 1000L

        /** Unrelated-frame bookkeeping cap (identity-safe counters only). */
        const val MAX_UNMATCHED_RECORDS = 64

        private val HEX = "0123456789abcdef".toCharArray()
    }

    // ------------------------------------------------------------------
    // Observed frame input (built by the engine from CoolMessageTriage +
    // bounded payload extraction; payload is null unless an armed step can
    // consume it, keeping the relay hot path lean).
    // ------------------------------------------------------------------

    enum class FrameKind {
        STATUS,
        COMMAND_VALUE,
        TEXT_SELECTION_CONTENT,
        COMPLEX_SELECTION,
        PASTE_RESULT,
        PART_SET,
        TEXT_SELECTION,
        GRAPHIC_SELECTION,
        CELL_CURSOR,
        CELL_ADDRESS,
        CELL_FORMULA,
        PRESENTATION_INFO,
        STATE_CHANGED,
        UNO_COMMAND_RESULT,
        ERROR,
    }

    data class ObservedFrame(
        val kind: FrameKind,
        /** Exact wire prefix token ("status" vs "statusupdate" vs "partstatus"). */
        val prefix: String = "",
        /** Bounded payload text — only extracted while a step can consume it. */
        val payload: String? = null,
        val payloadBytes: Int = 0,
        val oversize: Boolean = false,
        /** COMMAND_VALUE scalars. */
        val commandName: String? = null,
        val commandValues: String? = null,
        /** PASTE_RESULT scalar. */
        val pasteVerdict: String? = null,
        /** PART_SET scalar. */
        val partEcho: String? = null,
        /** ERROR scalars. */
        val errorCmd: String? = null,
        val errorKind: String? = null,
    )

    // ------------------------------------------------------------------
    // Outputs
    // ------------------------------------------------------------------

    sealed class SubmitOutcome {
        data class Accepted(val opId: String) : SubmitOutcome()
        data class Rejected(val failure: OfficePrecisionFailure, val detail: String?) : SubmitOutcome()
    }

    /** Result of arming one step (engine reacts immediately, on the control lane). */
    sealed class ArmDecision {
        /** Post the step's own wire command now. */
        object DispatchNow : ArmDecision()

        /** Post the ordered barrier first; its reply re-emits DispatchStep. */
        object BarrierFirst : ArmDecision()

        /** The step can never be safely correlated in this incarnation. */
        data class Reject(val failure: OfficePrecisionFailure, val detail: String) : ArmDecision()
    }

    /** One event the engine must react to (dispatch/terminal). */
    sealed class LedgerEvent {
        /** Frame matched nothing armed; counted only. */
        object Ignored : LedgerEvent()

        /**
         * The armed step must now be dispatched by the engine: either the
         * step's own wire command or (when [barrierFirst] is true) the
         * ordered barrier whose reply re-emits this event with
         * barrierFirst=false after which the engine MUST re-arm.
         */
        data class DispatchStep(val opId: String, val stepIndex: Int, val barrierFirst: Boolean) : LedgerEvent()

        /** The operation reached a terminal state (result stored for read). */
        data class Terminal(val result: OfficePrecisionResult) : LedgerEvent()

        /**
         * An `error:` frame was consumed as this operation's producer
         * refusal; the generic mount-failure path must NOT run for it.
         */
        data class ConsumedError(val result: OfficePrecisionResult) : LedgerEvent()
    }

    // ------------------------------------------------------------------
    // Internal state
    // ------------------------------------------------------------------

    internal class OpRun(
        val request: OfficePrecisionRequest,
        val plan: List<OfficePrecisionPlan.Step>,
        val submittedAt: Long,
    ) {
        /** -1 while queued; >= 0 = armed step index. */
        var stepIndex: Int = -1

        /** True while waiting for the ordered barrier reply before [stepIndex]. */
        var barrierPhase: Boolean = false

        /**
         * True between a consumed barrier reply and the engine's re-arm:
         * every frame is discarded (a genuinely-earlier same-kind
         * completion around the barrier can never settle the fresh op).
         */
        var awaitingDispatch: Boolean = false
        val attestations = ArrayList<String>()
        var lastTerminal: OfficePrecisionResult? = null

        /** Working-copy (flushed-file) digest captured by the engine at arm time. */
        var contextSha: String? = null

        /** Producer completion evidence observed for a content mutation. */
        var nativeCompleted: Boolean = false

        /**
         * True once ANY effect-bearing wire step of a non-query operation
         * was actually posted (Main final target-safety review 2026-10-27):
         * from that moment the document/selection/part context may differ
         * from every earlier capture — INCLUDING when the op later ends
         * FAILED or UNKNOWN (maybe-effect). Terminating such an op advances
         * the precision effect epoch, so captures taken before it can never
         * apply to another sheet/slide/selection.
         */
        var effectDispatched: Boolean = false

        /** The owned native editable command already preceded this run's first plan wire. */
        var ownedEditViewAsserted: Boolean = false

        /** Head command tokens of wires actually posted for this run (error correlation). */
        val dispatchedCommands = LinkedHashSet<String>()

        /** Soft content-readback outcome (CONTENT actions only). */
        var contentReadback: OfficePrecisionContentReadback =
            OfficePrecisionContentReadback.NOT_ATTEMPTED

        /** Exact capture consumed by the engine for a CONTENT run. */
        var contentTarget: OfficePrecisionTarget? = null

        /** Fresh part observed by this run's pre-effect status pull. */
        var preEffectPartId: String? = null

        /** Fresh selection acquired by THIS run before paste; never sampled
         * from the host's ambient query/select-all cache. */
        var preEffectEvidence: OfficePrecisionPreEffectEvidence? = null
    }

    private val lock = Any()
    private val queue = ArrayDeque<OpRun>()
    private var armed: OpRun? = null
    private val completed = LinkedHashMap<String, OfficePrecisionResult>()
    private val knownOpIds = LinkedHashSet<String>()

    /**
     * Quarantined expectation keys whose producer reply ordering IS pinned-
     * provable (synchronous handler answers): a successful ordered barrier
     * may re-arm these.
     */
    private val quarantinedProven = HashSet<String>()

    /**
     * Quarantined expectation keys emitted from core callbacks (no pinned
     * ordering proof vs. the barrier): PERMANENT for this incarnation.
     */
    private val quarantinedUnproven = HashSet<String>()

    /**
     * True once a barrier reply went missing: later same-command barrier
     * replies are uncorrelated (the stale one could be consumed), so NO
     * barrier may clear quarantine again in this incarnation.
     */
    private var barrierPoisoned = false

    /** See [notePageQueryForwarded]. */
    private var pageQueryForwarded = false

    /** Manual page-input epoch: advanced by real forwarded retarget frames. */
    private var inputEpoch = 0L

    /** Completed-precision-mutation epoch: advanced per completed CONTENT op. */
    private var editEpoch = 0L

    /** Bounded identity-safe counters for unmatched native frames. */
    private val unmatchedCounts = LinkedHashMap<String, Long>()

    private data class TargetRecord(
        val target: OfficePrecisionTarget,
        val inputEpoch: Long,
        val editEpoch: Long,
        var consumed: Boolean = false,
    )

    private val handles = LinkedHashMap<String, TargetRecord>()
    private val random = SecureRandom()

    // ------------------------------------------------------------------
    // Submission
    // ------------------------------------------------------------------

    fun submit(request: OfficePrecisionRequest): SubmitOutcome {
        synchronized(lock) {
            if (knownOpIds.contains(request.opId)) {
                return SubmitOutcome.Rejected(
                    OfficePrecisionFailure.INVALID_REQUEST,
                    "duplicate-op-id",
                )
            }
            if (queue.size >= maxPending) {
                return SubmitOutcome.Rejected(OfficePrecisionFailure.QUEUE_FULL, "pending-queue-full")
            }
            val plan = OfficePrecisionPlan.forRequest(request)
                ?: return SubmitOutcome.Rejected(OfficePrecisionFailure.INVALID_REQUEST, "untranslatable-action")
            // Early honest refusal for incarnations that can no longer be
            // barrier-fenced (arm-time re-checks remain authoritative).
            refusalForPlanLocked(plan)?.let { (failure, detail) ->
                return SubmitOutcome.Rejected(failure, detail)
            }
            knownOpIds.add(request.opId)
            while (knownOpIds.size > maxCompleted * 4) {
                val oldest = knownOpIds.iterator().next()
                knownOpIds.remove(oldest)
            }
            queue.addLast(OpRun(request, plan, clock()))
            return SubmitOutcome.Accepted(request.opId)
        }
    }

    private fun refusalForPlanLocked(
        plan: List<OfficePrecisionPlan.Step>,
    ): Pair<OfficePrecisionFailure, String>? {
        for (step in plan) {
            val expect = step.expect ?: continue
            if (quarantinedUnproven.contains(expect.key)) {
                return OfficePrecisionFailure.STALE_ANSWER_QUARANTINE to
                    ("callback-answer-kind-quarantined:" + expect.key)
            }
            if (barrierPoisoned &&
                (quarantinedProven.contains(expect.key) || pageQueryForwarded)
            ) {
                return OfficePrecisionFailure.STALE_ANSWER_QUARANTINE to "barrier-uncorrelated"
            }
        }
        return null
    }

    /** Claims the next queued run (engine calls on the serialized control lane). */
    internal fun claimNext(): OpRun? = synchronized(lock) {
        if (armed != null) return@synchronized null
        val run = queue.removeFirstOrNull() ?: return@synchronized null
        armed = run
        run
    }

    fun hasArmedWork(): Boolean = synchronized(lock) { armed != null }

    fun armedOpId(): String? = synchronized(lock) { armed?.request?.opId }

    fun pendingCount(): Int = synchronized(lock) { queue.size }

    /**
     * The expectation key the armed step is currently waiting for (null when
     * nothing is armed or the run awaits a post-barrier re-dispatch). The
     * engine uses it to gate bounded payload extraction, keeping the relay
     * hot path free of content copies nobody can consume.
     */
    fun armedExpectationKey(): String? = synchronized(lock) {
        val run = armed ?: return@synchronized null
        if (run.awaitingDispatch) return@synchronized null
        if (run.barrierPhase) return@synchronized OfficePrecisionPlan.Expectation.BarrierReply.key
        run.plan.getOrNull(run.stepIndex)?.expect?.key
    }

    /**
     * Arms one step of the run (call IMMEDIATELY before dispatch —
     * arm-then-dispatch). The returned decision tells the engine whether to
     * post the step's own wire command, post the ordered barrier first, or
     * refuse the operation because this incarnation can no longer correlate
     * the expected answer safely.
     */
    internal fun armStep(run: OpRun, stepIndex: Int): ArmDecision = synchronized(lock) {
        if (armed !== run) return@synchronized ArmDecision.Reject(
            OfficePrecisionFailure.INTERNAL,
            "arm-without-claim",
        )
        val step = run.plan.getOrNull(stepIndex) ?: return@synchronized ArmDecision.Reject(
            OfficePrecisionFailure.INTERNAL,
            "arm-bad-step",
        )
        run.stepIndex = stepIndex
        run.awaitingDispatch = false
        val expect = step.expect
        if (expect == null) {
            run.barrierPhase = false
            return@synchronized ArmDecision.DispatchNow
        }
        val needsBarrier = quarantinedProven.contains(expect.key) ||
            quarantinedUnproven.contains(expect.key) ||
            pageQueryForwarded
        if (!needsBarrier) {
            run.barrierPhase = false
            return@synchronized ArmDecision.DispatchNow
        }
        if (quarantinedUnproven.contains(expect.key)) {
            // Callback-emitted answer kind went missing before: no barrier
            // may re-arm it (ordering not pinned-provable). Permanent for
            // this incarnation; a NEW mount starts a fresh ledger.
            return@synchronized terminalRejectLocked(
                run,
                OfficePrecisionFailure.STALE_ANSWER_QUARANTINE,
                "callback-answer-kind-quarantined:" + expect.key,
            )
        }
        if (barrierPoisoned) {
            // A previous barrier reply went missing; a fresh barrier's reply
            // cannot be told from the stale one — refuse instead of risking
            // a false clear.
            return@synchronized terminalRejectLocked(
                run,
                OfficePrecisionFailure.STALE_ANSWER_QUARANTINE,
                "barrier-uncorrelated",
            )
        }
        run.barrierPhase = true
        ArmDecision.BarrierFirst
    }

    private fun terminalRejectLocked(
        run: OpRun,
        failure: OfficePrecisionFailure,
        detail: String,
    ): ArmDecision.Reject {
        terminateLocked(
            run,
            OfficePrecisionState.REJECTED,
            failure,
            detail,
            attestation = "refused-before-dispatch",
            answer = null,
        )
        return ArmDecision.Reject(failure, detail)
    }

    /** Completes a fire-and-forget step after its wire send succeeded. */
    internal fun markDispatched(run: OpRun, stepIndex: Int): LedgerEvent? = synchronized(lock) {
        if (armed !== run || run.stepIndex != stepIndex) return@synchronized null
        val step = run.plan[stepIndex]
        if (step.expect != null) return@synchronized null
        run.attestations.add(step.name + ":sent")
        advanceOrTerminalLocked(run)
    }

    /**
     * Conservatively records the dispatch attempt IMMEDIATELY BEFORE the
     * native call. A synchronous page-off/error callback can therefore never
     * classify a possibly-landed wire as a no-effect refusal. The command set
     * is idempotent; the post-send call below retains the original bookkeeping.
     */
    internal fun noteWireDispatchStarted(run: OpRun, stepIndex: Int) {
        synchronized(lock) {
            if (armed !== run) return
            val step = run.plan.getOrNull(stepIndex) ?: return
            run.dispatchedCommands.add(step.wire.substringBefore(' '))
            if (run.request.action.effect != OfficePrecisionEffect.QUERY) {
                run.effectDispatched = true
            }
        }
    }

    /** Post-send bookkeeping; safe and idempotent after [noteWireDispatchStarted]. */
    internal fun noteWireDispatched(run: OpRun, stepIndex: Int) =
        noteWireDispatchStarted(run, stepIndex)

    /** The wire dispatch itself threw: nothing reached the kit (honest FAILED). */
    internal fun abortDispatch(run: OpRun, detail: String): OfficePrecisionResult? = synchronized(lock) {
        if (armed !== run) return@synchronized null
        terminateLocked(
            run,
            OfficePrecisionState.FAILED,
            OfficePrecisionFailure.TRANSPORT,
            detail,
            attestation = "dispatch-failed",
            answer = null,
        )
    }

    // ------------------------------------------------------------------
    // Frame correlation
    // ------------------------------------------------------------------

    fun onFrame(frame: ObservedFrame): LedgerEvent = synchronized(lock) {
        val run = armed
        if (run == null) {
            countUnmatchedLocked(frame)
            return@synchronized LedgerEvent.Ignored
        }
        if (run.awaitingDispatch) {
            // Between the consumed barrier reply and the engine's real
            // re-dispatch NOTHING can be a reply to our (not yet posted)
            // command: discard provably-earlier traffic.
            countUnmatchedLocked(frame)
            return@synchronized LedgerEvent.Ignored
        }
        if (run.barrierPhase) {
            // Only the barrier reply is consumed; EVERY other frame is
            // provably-earlier traffic and is discarded (never settles).
            if (isBarrierReply(frame) && !barrierPoisoned) {
                clearBarrierLocked(run)
                return@synchronized LedgerEvent.DispatchStep(run.request.opId, run.stepIndex, false)
            }
            countUnmatchedLocked(frame)
            return@synchronized LedgerEvent.Ignored
        }
        val stepIndex = run.stepIndex
        if (stepIndex < 0) {
            countUnmatchedLocked(frame)
            return@synchronized LedgerEvent.Ignored
        }
        val step = run.plan[stepIndex]
        val expect = step.expect
        if (expect == null) {
            countUnmatchedLocked(frame)
            return@synchronized LedgerEvent.Ignored
        }
        // An error frame naming ANY command this run actually dispatched is
        // the producer's own refusal for THIS operation (consumed; never a
        // mount failure). The lease fences page traffic and error replies
        // are synchronous handler answers, so the attribution is sound —
        // e.g. `error: cmd=setclientpart kind=invalid` arriving while the
        // follow-up status readback is armed.
        if (frame.kind == FrameKind.ERROR) {
            val errorCmd = frame.errorCmd
            if (errorCmd != null && run.dispatchedCommands.contains(errorCmd)) {
                if (step.soft && run.nativeCompleted) {
                    // A soft-stage refusal cannot undo the completed
                    // mutation: downgrade verification, terminate honestly.
                    run.contentReadback = OfficePrecisionContentReadback.UNAVAILABLE
                    run.attestations.add(step.name + ":producer-error")
                    val result = terminateLocked(
                        run,
                        terminalStateFor(run),
                        terminalFailureFor(run),
                        terminalDetailFor(run),
                        attestation = run.attestations.joinToString("+"),
                        answer = null,
                    )
                    return@synchronized LedgerEvent.Terminal(result!!)
                }
                val result = terminateLocked(
                    run,
                    OfficePrecisionState.FAILED,
                    OfficePrecisionFailure.PRODUCER_REJECTED,
                    "error cmd=${frame.errorCmd} kind=${frame.errorKind}",
                    attestation = "producer-error-frame",
                    answer = null,
                )
                return@synchronized LedgerEvent.ConsumedError(result!!)
            }
            countUnmatchedLocked(frame)
            return@synchronized LedgerEvent.Ignored
        }
        if (frame.kind == FrameKind.COMPLEX_SELECTION &&
            expect == OfficePrecisionPlan.Expectation.TextSelectionContent
        ) {
            if (step.check == OfficePrecisionPlan.StepCheck.NonEmptySelectionContent) {
                // `complexselection:` means the producer measured >= 1 MiB of
                // selected content: definitive non-emptiness PROOF for the
                // selection readback (byte count carried, content never is).
                run.attestations.add(step.name + ":complexselection-nonempty")
                val result = terminateLocked(
                    run,
                    terminalStateFor(run),
                    terminalFailureFor(run),
                    terminalDetailFor(run),
                    attestation = run.attestations.joinToString("+"),
                    answer = OfficePrecisionAnswer.TextSelected(frame.payloadBytes),
                )
                return@synchronized LedgerEvent.Terminal(result!!)
            }
            if (step.soft && run.nativeCompleted) {
                run.contentReadback = OfficePrecisionContentReadback.UNAVAILABLE
                run.attestations.add(step.name + ":complexselection")
                val result = terminateLocked(
                    run,
                    terminalStateFor(run),
                    terminalFailureFor(run),
                    terminalDetailFor(run),
                    attestation = run.attestations.joinToString("+"),
                    answer = null,
                )
                return@synchronized LedgerEvent.Terminal(result!!)
            }
            // The producer itself declares the selection too large/complex
            // for the typed answer (>= 1 MiB): honest unavailability.
            val result = terminateLocked(
                run,
                OfficePrecisionState.FAILED,
                OfficePrecisionFailure.COMPLEX_SELECTION_UNAVAILABLE,
                "complexselection",
                attestation = "producer-complexselection",
                answer = null,
            )
            return@synchronized LedgerEvent.Terminal(result!!)
        }
        if (!matches(expect, frame)) {
            countUnmatchedLocked(frame)
            return@synchronized LedgerEvent.Ignored
        }
        // Oversize answers are refused with their real byte count — EXCEPT
        // for the non-empty selection proof, which needs only the count.
        if (
            (frame.oversize || frame.payloadBytes > OfficePrecisionProtocol.MAX_ANSWER_BYTES) &&
            step.check != OfficePrecisionPlan.StepCheck.NonEmptySelectionContent
        ) {
            if (step.soft && run.nativeCompleted) {
                run.contentReadback = OfficePrecisionContentReadback.UNAVAILABLE
                run.attestations.add(step.name + ":oversize")
                val result = terminateLocked(
                    run,
                    terminalStateFor(run),
                    terminalFailureFor(run),
                    terminalDetailFor(run),
                    attestation = run.attestations.joinToString("+"),
                    answer = null,
                )
                return@synchronized LedgerEvent.Terminal(result!!)
            }
            val result = terminateLocked(
                run,
                OfficePrecisionState.FAILED,
                OfficePrecisionFailure.ANSWER_TOO_LARGE,
                "answer-bytes=${frame.payloadBytes}",
                attestation = "oversize-answer-refused",
                answer = null,
            )
            return@synchronized LedgerEvent.Terminal(result!!)
        }
        when (val outcome = checkStep(run, step.check, expect, frame)) {
            is StepOutcome.Fail -> {
                if (step.soft && run.nativeCompleted) {
                    // Explicit conflict becomes UNKNOWN; unavailable evidence
                    // only limits verification. Neither auto-replays the op.
                    run.contentReadback = outcome.softDowngrade
                    run.attestations.add(step.name + ":" + outcome.attestationToken)
                    val result = terminateLocked(
                        run,
                        terminalStateFor(run),
                        terminalFailureFor(run),
                        terminalDetailFor(run),
                        attestation = run.attestations.joinToString("+"),
                        answer = null,
                    )
                    return@synchronized LedgerEvent.Terminal(result!!)
                }
                val result = terminateLocked(
                    run,
                    OfficePrecisionState.FAILED,
                    outcome.failure,
                    outcome.detail,
                    attestation = step.name + "-readback-disagreed",
                    answer = null,
                )
                return@synchronized LedgerEvent.Terminal(result!!)
            }
            is StepOutcome.Answer -> {
                run.attestations.add(step.name + ":" + outcome.attestationToken)
                outcome.readback?.let { run.contentReadback = it }
                if (stepIndex == run.plan.lastIndex) {
                    val result = terminateLocked(
                        run,
                        terminalStateFor(run),
                        terminalFailureFor(run),
                        terminalDetailFor(run),
                        attestation = run.attestations.joinToString("+"),
                        answer = outcome.answer(),
                    )
                    return@synchronized LedgerEvent.Terminal(result!!)
                }
                return@synchronized advanceOrTerminalLocked(run)
            }
        }
    }

    private sealed class StepOutcome {
        data class Answer(
            val attestationToken: String,
            val readback: OfficePrecisionContentReadback? = null,
            val makeAnswer: () -> OfficePrecisionAnswer?,
        ) : StepOutcome() {
            fun answer(): OfficePrecisionAnswer? = makeAnswer()
        }

        data class Fail(
            val failure: OfficePrecisionFailure,
            val detail: String?,
            val attestationToken: String = "failed",
            val softDowngrade: OfficePrecisionContentReadback =
                OfficePrecisionContentReadback.MISMATCHED,
        ) : StepOutcome()
    }

    /** Applies the step's pure check to the matched frame. */
    private fun checkStep(
        run: OpRun,
        check: OfficePrecisionPlan.StepCheck,
        expect: OfficePrecisionPlan.Expectation,
        frame: ObservedFrame,
    ): StepOutcome = when (check) {
        OfficePrecisionPlan.StepCheck.Accept -> when (expect) {
            OfficePrecisionPlan.Expectation.StatusAnswer -> {
                val info = frame.payload?.let { OfficePrecisionProtocol.parseDocumentStatus(it) }
                if (info == null) {
                    StepOutcome.Fail(OfficePrecisionFailure.PRODUCER_REJECTED, "status-answer-unparseable")
                } else {
                    // Bind the producer's OWN observed context into the minted
                    // handle record NOW (still under `lock`), so the target
                    // advertised to the owner and the target a later content
                    // mutation validates/consumes are ONE immutable value.
                    // A handle whose stored selectedPart stayed null could
                    // never satisfy the mandatory pre-effect part gate, so
                    // every APPLY_TEXT/SET_CELL_CONTENT would be refused
                    // before its own paste wire.
                    val captured = pendingCaptureTarget?.let { bindCapturedContextLocked(it, info) }
                    StepOutcome.Answer("status-answer") {
                        if (captured != null) {
                            OfficePrecisionAnswer.TargetCaptured(captured)
                        } else {
                            OfficePrecisionAnswer.DocumentContext(
                                docType = info.docType,
                                partsCount = info.partsCount,
                                selectedPart = info.selectedPart,
                                widthTwip = info.widthTwip,
                                heightTwip = info.heightTwip,
                                viewId = info.viewId,
                                readOnly = info.readOnly,
                                documentModified = lastModifiedStatus,
                            )
                        }
                    }
                }
            }
            is OfficePrecisionPlan.Expectation.CommandValues -> {
                if (frame.commandName == OfficePrecisionProtocol.CELL_CURSOR_COMMAND_NAME) {
                    val cursor = OfficePrecisionProtocol.parseCellCursorPayload(frame.commandValues)
                    val empty = cursor == null
                    StepOutcome.Answer(if (empty) "cursor-empty" else "cursor-observed") {
                        OfficePrecisionAnswer.CellCursor(
                            column = cursor?.column,
                            row = cursor?.row,
                            xTwip = cursor?.xTwip,
                            yTwip = cursor?.yTwip,
                            widthTwip = cursor?.widthTwip,
                            heightTwip = cursor?.heightTwip,
                            empty = empty,
                        )
                    }
                } else {
                    StepOutcome.Answer("commandvalues-answer") { null }
                }
            }
            OfficePrecisionPlan.Expectation.TextSelectionContent -> {
                val parsed = frame.payload?.let { OfficePrecisionProtocol.parseTextSelectionContent(it) }
                if (parsed == null) {
                    StepOutcome.Fail(OfficePrecisionFailure.PRODUCER_REJECTED, "selection-answer-unparseable")
                } else if (
                    parsed.oversize ||
                    !OfficePrecisionProtocol.contentFitsReplyBudget(parsed.text)
                ) {
                    // Refused BEFORE storing/advertising: honest typed count,
                    // never a truncated .take() and never an unmarshalable
                    // binder reply.
                    StepOutcome.Fail(
                        OfficePrecisionFailure.ANSWER_TOO_LARGE,
                        "selection-content-bytes=${parsed.byteCount}",
                    )
                } else {
                    StepOutcome.Answer("selection-bytes=" + parsed.byteCount) {
                        OfficePrecisionAnswer.TextSelection(parsed.text, parsed.byteCount, parsed.multiFormatJson)
                    }
                }
            }
            OfficePrecisionPlan.Expectation.PresentationInfoAnswer -> {
                val bytes = frame.payloadBytes
                StepOutcome.Answer("presentationinfo-bytes=$bytes") {
                    OfficePrecisionAnswer.PresentationInfo(bytes, countSlides(frame.payload))
                }
            }
            else -> StepOutcome.Answer("answer-observed") { null }
        }
        OfficePrecisionPlan.StepCheck.PasteSuccess ->
            if (frame.pasteVerdict == "success") {
                // The producer's OWN completion frame — native completion
                // evidence, NOT yet a content claim (soft readback follows).
                run.nativeCompleted = true
                StepOutcome.Answer("pasteresult-success") { null }
            } else {
                StepOutcome.Fail(
                    OfficePrecisionFailure.PRODUCER_REJECTED,
                    "pasteresult=" + (frame.pasteVerdict ?: "absent"),
                )
            }
        is OfficePrecisionPlan.StepCheck.CursorAt -> {
            val cursor = OfficePrecisionProtocol.parseCellCursorPayload(frame.commandValues)
            if (cursor != null && cursor.column == check.column && cursor.row == check.row) {
                StepOutcome.Answer("cursor-at-target") { null }
            } else if (cursor == null) {
                StepOutcome.Fail(OfficePrecisionFailure.TARGET_UNVERIFIED, "cursor-readback-empty")
            } else {
                StepOutcome.Fail(
                    OfficePrecisionFailure.TARGET_UNVERIFIED,
                    "cursor-readback-mismatch col=${cursor.column} row=${cursor.row}",
                )
            }
        }
        is OfficePrecisionPlan.StepCheck.StatusSelectedPartMatches -> {
            val info = frame.payload?.let { OfficePrecisionProtocol.parseDocumentStatus(it) }
            when {
                info == null -> StepOutcome.Fail(
                    OfficePrecisionFailure.PRODUCER_REJECTED,
                    "status-readback-unparseable",
                )
                info.selectedPart == check.partId ->
                    StepOutcome.Answer("part-readback-matched") {
                        OfficePrecisionAnswer.SlideSelected(check.partId)
                    }
                else -> StepOutcome.Fail(
                    OfficePrecisionFailure.TARGET_UNVERIFIED,
                    "part-readback-mismatch",
                )
            }
        }
        OfficePrecisionPlan.StepCheck.PreEffectTargetStatus -> {
            val info = frame.payload?.let { OfficePrecisionProtocol.parseDocumentStatus(it) }
            val target = run.contentTarget
            val expectedPart = target?.selectedPart
            when {
                info == null -> StepOutcome.Fail(
                    OfficePrecisionFailure.PRODUCER_REJECTED,
                    "pre-effect-status-unparseable",
                )
                target == null -> StepOutcome.Fail(
                    OfficePrecisionFailure.INTERNAL,
                    "pre-effect-target-absent",
                )
                expectedPart.isNullOrEmpty() || info.selectedPart != expectedPart ->
                    StepOutcome.Fail(
                        OfficePrecisionFailure.TARGET_UNVERIFIED,
                        "pre-effect-part-mismatch",
                    )
                else -> {
                    run.preEffectPartId = info.selectedPart
                    run.preEffectEvidence = null
                    StepOutcome.Answer("pre-effect-part-matched") { null }
                }
            }
        }
        is OfficePrecisionPlan.StepCheck.PreEffectSelectionContent -> {
            val parsed = frame.payload?.let { OfficePrecisionProtocol.parseTextSelectionContent(it) }
            val target = run.contentTarget
            val expectedPart = target?.selectedPart
            val causalPart = run.preEffectPartId?.takeIf { it == expectedPart }
            when {
                parsed == null || parsed.oversize -> StepOutcome.Fail(
                    OfficePrecisionFailure.PRODUCER_REJECTED,
                    "pre-effect-selection-unparseable",
                )
                !OfficePrecisionProtocol.contentFitsReplyBudget(parsed.text) -> StepOutcome.Fail(
                    OfficePrecisionFailure.ANSWER_TOO_LARGE,
                    "pre-effect-selection-content-bytes=${parsed.byteCount}",
                )
                target == null -> StepOutcome.Fail(
                    OfficePrecisionFailure.INTERNAL,
                    "pre-effect-target-absent",
                )
                causalPart == null -> StepOutcome.Fail(
                    OfficePrecisionFailure.TARGET_UNVERIFIED,
                    "pre-effect-part-not-proven",
                )
                parsed.multiFormatJson -> StepOutcome.Fail(
                    OfficePrecisionFailure.COMPLEX_SELECTION_UNAVAILABLE,
                    "pre-effect-multiformat-refused",
                )
                check.singleCellPlainText && parsed.text.any { it == '\t' || it == '\n' || it == '\r' } ->
                    StepOutcome.Fail(
                        OfficePrecisionFailure.COMPLEX_SELECTION_UNAVAILABLE,
                        "pre-effect-single-cell-plaintext-required",
                    )
                !run.request.targetHandle.equals(target.handleId, ignoreCase = true) ->
                    StepOutcome.Fail(
                        OfficePrecisionFailure.TARGET_UNVERIFIED,
                        "pre-effect-target-handle-mismatch",
                    )
                target.generation != run.request.generation -> StepOutcome.Fail(
                    OfficePrecisionFailure.APPLY_CONFLICT,
                    "pre-effect-generation-drift",
                )
                target.inputEpoch != inputEpoch -> StepOutcome.Fail(
                    OfficePrecisionFailure.APPLY_CONFLICT,
                    "pre-effect-manual-input-drift",
                )
                target.editEpoch != editEpoch -> StepOutcome.Fail(
                    OfficePrecisionFailure.APPLY_CONFLICT,
                    "pre-effect-edit-epoch-drift",
                )
                else -> {
                    // parsed.text is preserved byte-for-byte as Kotlin text:
                    // no trimming, terminator removal, TSV unquoting or cached
                    // numeric display substitution. Empty is a REAL insertion
                    // baseline only because this synchronous answer supplied it.
                    val evidence = OfficePrecisionPreEffectEvidence(
                        opId = run.request.opId,
                        sessionToken = run.request.sessionToken,
                        generation = run.request.generation,
                        targetHandle = target.handleId,
                        partId = causalPart,
                        inputEpoch = inputEpoch,
                        editEpoch = editEpoch,
                        selectionText = parsed.text,
                        selectionByteCount = parsed.byteCount,
                    )
                    run.preEffectEvidence = evidence
                    StepOutcome.Answer("pre-effect-selection-bytes=" + parsed.byteCount) { null }
                }
            }
        }
        OfficePrecisionPlan.StepCheck.NonEmptySelectionContent -> {
            val parsed = frame.payload?.let { OfficePrecisionProtocol.parseTextSelectionContent(it) }
            val byteCount = parsed?.byteCount ?: frame.payloadBytes
            when {
                // Preserve the ordinary answer's exact text for the public
                // preparatory read. A later content op independently acquires
                // its own causal prior. Complex/oversize/unparseable content
                // proves only non-emptiness by count; nothing is truncated.
                byteCount > 0 ->
                    StepOutcome.Answer("selection-readback-bytes=$byteCount") {
                        if (parsed != null && !parsed.oversize) {
                            OfficePrecisionAnswer.TextSelection(
                                parsed.text, parsed.byteCount, parsed.multiFormatJson,
                            )
                        } else {
                            OfficePrecisionAnswer.TextSelected(byteCount)
                        }
                    }
                parsed != null && parsed.text.isEmpty() && !parsed.oversize ->
                    StepOutcome.Fail(
                        OfficePrecisionFailure.TARGET_UNVERIFIED,
                        "selection-readback-empty",
                    )
                else -> StepOutcome.Fail(
                    OfficePrecisionFailure.PRODUCER_REJECTED,
                    "selection-readback-unparseable",
                )
            }
        }
        OfficePrecisionPlan.StepCheck.AppliedTextReadback -> {
            val parsed = frame.payload?.let { OfficePrecisionProtocol.parseTextSelectionContent(it) }
            val expected = run.request.text
            when {
                parsed == null || parsed.oversize ||
                    !OfficePrecisionProtocol.contentFitsReplyBudget(parsed.text) -> StepOutcome.Fail(
                    OfficePrecisionFailure.INTERNAL,
                    "readback-unparseable-or-oversize",
                    attestationToken = "readback-unavailable",
                    softDowngrade = OfficePrecisionContentReadback.UNAVAILABLE,
                )
                parsed.multiFormatJson -> StepOutcome.Fail(
                    OfficePrecisionFailure.INTERNAL,
                    "readback-multiformat",
                    attestationToken = "readback-multiformat",
                    softDowngrade = OfficePrecisionContentReadback.UNAVAILABLE,
                )
                expected != null && parsed.text == expected -> StepOutcome.Answer(
                    "readback-matched",
                    readback = OfficePrecisionContentReadback.MATCHED,
                ) { null }
                run.request.action == OfficePrecisionAction.APPLY_TEXT -> StepOutcome.Fail(
                    OfficePrecisionFailure.INTERNAL,
                    "readback-selection-not-body bytes=${parsed.byteCount}",
                    attestationToken = "readback-selection-not-comparable",
                    softDowngrade = OfficePrecisionContentReadback.UNAVAILABLE,
                )
                else -> StepOutcome.Fail(
                    OfficePrecisionFailure.INTERNAL,
                    "readback-mismatch bytes=${parsed.byteCount}",
                    attestationToken = "readback-mismatch",
                    softDowngrade = OfficePrecisionContentReadback.MISMATCHED,
                )
            }
        }
    }

    /** Set by the engine while a CAPTURE_TARGET op is armed (handle pre-mint). */
    @Volatile
    internal var pendingCaptureTarget: OfficePrecisionTarget? = null

    /** Corroborating observed `.uno:ModifiedStatus` (never completion by itself). */
    @Volatile
    internal var lastModifiedStatus: Boolean? = null

    private fun countSlides(payload: String?): Int? {
        if (payload == null) return null
        // The pinned presentationinfo JSON carries one slide object per
        // slide; count conservatively via its stable per-slide marker.
        // Absence stays null (never invented).
        val matches = Regex("\"slideNumber\"\\s*:").findAll(payload).count()
        return matches.takeIf { it > 0 }
    }

    /**
     * Terminal state for a settled run: queries terminate on their real
     * answer; NAVIGATION is MUTATION_VERIFIED only through the pinned-
     * ordering-proven `status:` selectedpart readback (full postcondition);
     * SELECTION terminates NATIVE_COMPLETED — the non-empty selection
     * readback is a PARTIAL postcondition and a delayed callback frame is
     * never accepted as proof; CONTENT mutations are MUTATION_VERIFIED only
     * with an exact content readback match, UNKNOWN on an explicit comparable
     * conflict, and NATIVE_COMPLETED when evidence is merely unavailable.
     */
    private fun terminalStateFor(run: OpRun): OfficePrecisionState =
        when (run.request.action.effect) {
            OfficePrecisionEffect.QUERY -> OfficePrecisionState.QUERY_OBSERVED
            OfficePrecisionEffect.CONTENT -> when (run.contentReadback) {
                OfficePrecisionContentReadback.MATCHED -> OfficePrecisionState.MUTATION_VERIFIED
                // A real, comparable answer that contradicts the requested
                // text is positive conflicting evidence after a paste ACK.
                // It is NOT native completion and NOT a harmless formatting
                // downgrade: the actual effect is uncertain and retained.
                OfficePrecisionContentReadback.MISMATCHED -> OfficePrecisionState.UNKNOWN
                else -> OfficePrecisionState.NATIVE_COMPLETED
            }
            OfficePrecisionEffect.SELECTION -> OfficePrecisionState.NATIVE_COMPLETED
            OfficePrecisionEffect.NAVIGATION -> OfficePrecisionState.MUTATION_VERIFIED
        }

    private fun terminalFailureFor(run: OpRun): OfficePrecisionFailure? =
        if (run.request.action.effect == OfficePrecisionEffect.CONTENT &&
            run.contentReadback == OfficePrecisionContentReadback.MISMATCHED
        ) {
            OfficePrecisionFailure.TARGET_UNVERIFIED
        } else {
            null
        }

    private fun terminalDetailFor(run: OpRun): String? =
        if (run.request.action.effect == OfficePrecisionEffect.CONTENT &&
            run.contentReadback == OfficePrecisionContentReadback.MISMATCHED
        ) {
            "content-readback-conflict-effect-uncertain"
        } else {
            null
        }

    private fun matches(expect: OfficePrecisionPlan.Expectation, frame: ObservedFrame): Boolean =
        when (expect) {
            OfficePrecisionPlan.Expectation.StatusAnswer ->
                frame.kind == FrameKind.STATUS && frame.prefix == "status"
            is OfficePrecisionPlan.Expectation.CommandValues ->
                frame.kind == FrameKind.COMMAND_VALUE && frame.commandName == expect.commandName
            OfficePrecisionPlan.Expectation.TextSelectionContent ->
                frame.kind == FrameKind.TEXT_SELECTION_CONTENT
            OfficePrecisionPlan.Expectation.PresentationInfoAnswer ->
                frame.kind == FrameKind.PRESENTATION_INFO
            OfficePrecisionPlan.Expectation.PasteResult ->
                frame.kind == FrameKind.PASTE_RESULT
            OfficePrecisionPlan.Expectation.BarrierReply -> isBarrierReply(frame)
        }

    private fun isBarrierReply(frame: ObservedFrame): Boolean =
        frame.kind == FrameKind.COMMAND_VALUE &&
            frame.commandName == OfficePrecisionProtocol.BARRIER_COMMAND_NAME

    private fun clearBarrierLocked(run: OpRun) {
        run.barrierPhase = false
        // A barrier reply proves every EARLIER same-class (synchronous
        // handler answer) frame already drained — pinned citations in the
        // class KDoc. Callback-emitted quarantine and a poisoned barrier
        // are NEVER cleared here.
        quarantinedProven.clear()
        pageQueryForwarded = false
        // Post-barrier window: frames are discarded until the engine
        // re-arms and really posts the step (see awaitingDispatch).
        run.awaitingDispatch = true
    }

    private fun countUnmatchedLocked(frame: ObservedFrame) {
        val key = frame.kind.name
        unmatchedCounts[key] = (unmatchedCounts[key] ?: 0L) + 1
        while (unmatchedCounts.size > MAX_UNMATCHED_RECORDS) {
            val oldest = unmatchedCounts.keys.iterator().next()
            unmatchedCounts.remove(oldest)
        }
    }

    /** Identity-safe unmatched-frame counters for diagnostics (no content). */
    fun unmatchedSnapshot(): List<Pair<String, Long>> = synchronized(lock) {
        unmatchedCounts.map { (k, v) -> k to v }
    }

    private fun advanceOrTerminalLocked(run: OpRun): LedgerEvent {
        val nextIndex = run.stepIndex + 1
        if (nextIndex >= run.plan.size) {
            val result = terminateLocked(
                run,
                terminalStateFor(run),
                terminalFailureFor(run),
                terminalDetailFor(run),
                attestation = run.attestations.joinToString("+"),
                answer = null,
            )
            return LedgerEvent.Terminal(result!!)
        }
        return LedgerEvent.DispatchStep(run.request.opId, nextIndex, false)
    }

    // ------------------------------------------------------------------
    // Page mode drift / timeouts / mount end (never auto-undo; data retained)
    // ------------------------------------------------------------------

    /**
     * The page really entered Viewing during an owned non-query run. No new
     * plan wire may follow. Before any effect this is a typed refusal; after
     * an effect-bearing send the result is UNKNOWN because the earlier paste/
     * selection/navigation may already have landed. No retry or undo is made.
     */
    fun onPageViewing(opId: String): OfficePrecisionResult? = synchronized(lock) {
        val run = armed ?: return@synchronized null
        if (run.request.opId != opId || run.request.action.effect == OfficePrecisionEffect.QUERY) {
            return@synchronized null
        }
        val maybeEffect = run.effectDispatched
        terminateLocked(
            run,
            if (maybeEffect) OfficePrecisionState.UNKNOWN else OfficePrecisionState.REJECTED,
            if (maybeEffect) OfficePrecisionFailure.TARGET_UNVERIFIED else OfficePrecisionFailure.NOT_EDITABLE,
            if (maybeEffect) "page-viewing-after-effect-dispatch" else "page-viewing-before-dispatch",
            attestation = (run.attestations + "page-edit-mode-lost").joinToString("+"),
            answer = null,
        )
    }

    fun onStepTimeout(opId: String, stepIndex: Int): OfficePrecisionResult? = synchronized(lock) {
        val run = armed ?: return@synchronized null
        if (run.request.opId != opId || run.stepIndex != stepIndex) return@synchronized null
        val step = run.plan[stepIndex]
        val wasBarrierPhase = run.barrierPhase
        if (wasBarrierPhase) {
            // The barrier reply itself went missing: a later same-command
            // reply is uncorrelated (it could be THIS stale one), so barrier
            // re-arming is poisoned for the rest of this incarnation.
            barrierPoisoned = true
        }
        // The missed answer may still arrive late: quarantine its kind
        // (proven kinds may later re-arm through a successful barrier;
        // callback-emitted kinds never re-arm in this incarnation).
        step.expect?.let { expect ->
            if (expect.barrierProven) quarantinedProven.add(expect.key)
            else quarantinedUnproven.add(expect.key)
        }
        if (step.soft && run.nativeCompleted) {
            // The mutation itself already carries producer completion
            // evidence; only the optional verification went missing.
            run.contentReadback = OfficePrecisionContentReadback.UNAVAILABLE
            run.attestations.add(step.name + ":no-answer")
            return@synchronized terminateLocked(
                run,
                terminalStateFor(run),
                terminalFailureFor(run),
                terminalDetailFor(run),
                attestation = run.attestations.joinToString("+"),
                answer = null,
            )
        }
        terminateLocked(
            run,
            OfficePrecisionState.UNKNOWN,
            OfficePrecisionFailure.TIMEOUT,
            "step=" + step.name + (if (wasBarrierPhase) " barrier-phase" else ""),
            attestation = "no-proof-within-bounded-window",
            answer = null,
        )
    }

    fun onMountTerminal(): List<OfficePrecisionResult> = synchronized(lock) {
        val results = ArrayList<OfficePrecisionResult>()
        armed?.let { run ->
            terminateLocked(
                run,
                OfficePrecisionState.UNKNOWN,
                OfficePrecisionFailure.TIMEOUT,
                "mount-ended-without-answer",
                attestation = "no-proof-mount-ended",
                answer = null,
            )?.let { results.add(it) }
        }
        while (queue.isNotEmpty()) {
            // PEEK, never pre-remove: terminateLocked's exactly-once guard
            // decides "already terminal" by (armed !== run && !queue.contains
            // (run)), and its LIVE path removes the run itself. A pre-removed
            // run would hit the guard, return its (null) lastTerminal and be
            // silently DROPPED from this mount drain — a queued op would
            // vanish without its honest SESSION_ENDING result.
            val run = queue.first()
            terminateLocked(
                run,
                OfficePrecisionState.REJECTED,
                OfficePrecisionFailure.SESSION_ENDING,
                "mount-ended-before-dispatch",
                attestation = "never-dispatched",
                answer = null,
            )?.let { results.add(it) }
            if (queue.firstOrNull() === run) queue.remove(run) // defensive: never spin
        }
        results
    }

    // ------------------------------------------------------------------
    // Manual-input / mutation epochs (target invalidation signals)
    // ------------------------------------------------------------------

    /** Called for every forwarded page retarget/write-class frame. */
    fun notePageInput() {
        synchronized(lock) { inputEpoch++ }
    }

    /**
     * Called for forwarded page commands whose REPLIES collide with
     * precision answer kinds (gettextselection/commandvalues/
     * getpresentationinfo/status*): a late reply must not complete a fresh
     * operation, so the next answer-expecting step is barrier-fenced.
     */
    fun notePageQueryForwarded() {
        synchronized(lock) { pageQueryForwarded = true }
    }

    fun inputEpoch(): Long = synchronized(lock) { inputEpoch }

    fun editEpoch(): Long = synchronized(lock) { editEpoch }

    fun quarantineActive(): Boolean = synchronized(lock) {
        quarantinedProven.isNotEmpty() || quarantinedUnproven.isNotEmpty()
    }

    /** True when barrier re-arming is poisoned for this incarnation. */
    fun barrierPoisoned(): Boolean = synchronized(lock) { barrierPoisoned }

    // ------------------------------------------------------------------
    // Target handles (engine-minted, single-use, dual-revision CAS)
    // ------------------------------------------------------------------

    /**
     * Mints the handle BEFORE the capture's own `status:` answer exists, so
     * the three producer-observed context fields (docType/partsCount/
     * selectedPart) start null and are bound by
     * [bindCapturedContextLocked] when that answer settles. The handle is
     * only complete — and only usable for a content mutation's mandatory
     * pre-effect part gate — after that binding.
     */
    fun issueTarget(
        generation: Long,
        workingCopySha256: String?,
        workingCopyBytes: Long,
        documentModified: Boolean?,
        sourceId: String?,
        sourceRevision: String?,
        sourceLogicalPath: String?,
        workspaceId: String?,
        ownerTaskId: String?,
    ): OfficePrecisionTarget = synchronized(lock) {
        val now = clock()
        val id = newHandleId()
        val target = OfficePrecisionTarget(
            handleId = id,
            generation = generation,
            sourceId = sourceId,
            sourceRevision = sourceRevision,
            sourceLogicalPath = sourceLogicalPath,
            workspaceId = workspaceId,
            ownerTaskId = ownerTaskId,
            workingCopySha256 = workingCopySha256,
            workingCopyBytes = workingCopyBytes,
            inputEpoch = inputEpoch,
            editEpoch = editEpoch,
            documentModified = documentModified,
            docType = null,
            partsCount = null,
            selectedPart = null,
            capturedAtElapsedMs = now,
            expiresAtElapsedMs = now + handleTtlMs,
        )
        handles[id] = TargetRecord(target, inputEpoch, editEpoch)
        while (handles.size > maxHandles) {
            val oldest = handles.keys.iterator().next()
            handles.remove(oldest)
        }
        target
    }

    /**
     * Binds the producer's OWN `status:` facts (docType/partsCount/
     * selectedPart) into the ALREADY-MINTED handle record and returns the
     * completed immutable target. Caller holds [lock] (invoked from
     * [checkStep] inside [onFrame]).
     *
     * This is the single source of the capture's logical part: the value
     * returned here is BOTH what [OfficePrecisionAnswer.TargetCaptured]
     * advertises to the fenced owner and what [validateTarget] later hands to
     * a content run as `contentTarget`. Keeping only the advertised copy
     * (the pre-repair behaviour) left the stored record's `selectedPart`
     * null, so [OfficePrecisionPlan.StepCheck.PreEffectTargetStatus] could
     * never match and every APPLY_TEXT/SET_CELL_CONTENT was refused
     * TARGET_UNVERIFIED before its own paste wire — in all three families.
     *
     * Nothing here is caller-supplied or model-supplied: the facts come from
     * the native producer's own synchronous answer to this capture's `status`
     * pull. An evicted or already-consumed record is never resurrected; the
     * completed target is still returned so the owner's answer stays
     * truthful about what was measured.
     */
    private fun bindCapturedContextLocked(
        captured: OfficePrecisionTarget,
        info: OfficePrecisionProtocol.DocumentStatusInfo,
    ): OfficePrecisionTarget {
        val bound = captured.copy(
            docType = info.docType,
            partsCount = info.partsCount,
            selectedPart = info.selectedPart,
        )
        val record = handles[captured.handleId] ?: return bound
        if (record.consumed) return bound
        handles[captured.handleId] = record.copy(target = bound)
        pendingCaptureTarget = bound
        return bound
    }

    sealed class TargetCheck {
        data class Ok(val target: OfficePrecisionTarget) : TargetCheck()
        data class Refused(val failure: OfficePrecisionFailure, val detail: String) : TargetCheck()
    }

    /**
     * Validates (and for content mutations CONSUMES) one captured target
     * against the CURRENT real state. Any divergence is an honest apply
     * conflict — no effect is attempted and the stale handle is dropped.
     */
    fun validateTarget(
        handleId: String?,
        generation: Long,
        currentWorkingCopySha256: String?,
        consume: Boolean,
    ): TargetCheck = synchronized(lock) {
        if (handleId.isNullOrEmpty()) {
            return@synchronized TargetCheck.Refused(OfficePrecisionFailure.TARGET_UNKNOWN, "handle-absent")
        }
        val record = handles[handleId]
            ?: return@synchronized TargetCheck.Refused(
                OfficePrecisionFailure.TARGET_UNKNOWN,
                "handle-not-issued-or-evicted",
            )
        val now = clock()
        if (record.consumed) {
            handles.remove(handleId)
            return@synchronized TargetCheck.Refused(OfficePrecisionFailure.TARGET_UNKNOWN, "handle-consumed")
        }
        if (now >= record.target.expiresAtElapsedMs) {
            handles.remove(handleId)
            return@synchronized TargetCheck.Refused(OfficePrecisionFailure.TARGET_UNKNOWN, "handle-expired")
        }
        if (record.target.generation != generation) {
            handles.remove(handleId)
            return@synchronized TargetCheck.Refused(OfficePrecisionFailure.APPLY_CONFLICT, "generation-advanced")
        }
        if (record.target.workingCopySha256 != currentWorkingCopySha256) {
            handles.remove(handleId)
            return@synchronized TargetCheck.Refused(OfficePrecisionFailure.APPLY_CONFLICT, "working-copy-changed")
        }
        if (record.inputEpoch != inputEpoch) {
            handles.remove(handleId)
            return@synchronized TargetCheck.Refused(OfficePrecisionFailure.APPLY_CONFLICT, "manual-input-since-capture")
        }
        if (record.editEpoch != editEpoch) {
            handles.remove(handleId)
            return@synchronized TargetCheck.Refused(
                OfficePrecisionFailure.APPLY_CONFLICT,
                "precision-effect-since-capture",
            )
        }
        if (consume) {
            record.consumed = true
            handles.remove(handleId)
        }
        TargetCheck.Ok(record.target)
    }

    /** Re-check the ALREADY-CONSUMED capture immediately before paste. The
     * handle registry cannot be queried again (single-use was consumed at arm),
     * so this compares the run-owned immutable target with current native
     * digest/generation/manual/edit epochs without consuming anything twice. */
    internal fun revalidateContentTargetBeforePaste(
        run: OpRun,
        generation: Long,
        currentWorkingCopySha256: String?,
    ): TargetCheck = synchronized(lock) {
        val target = run.contentTarget
            ?: return@synchronized TargetCheck.Refused(
                OfficePrecisionFailure.INTERNAL,
                "pre-paste-target-absent",
            )
        when {
            target.generation != generation || target.generation != run.request.generation ->
                TargetCheck.Refused(OfficePrecisionFailure.APPLY_CONFLICT, "pre-paste-generation-advanced")
            target.workingCopySha256 != currentWorkingCopySha256 ->
                TargetCheck.Refused(OfficePrecisionFailure.APPLY_CONFLICT, "pre-paste-working-copy-changed")
            target.inputEpoch != inputEpoch ->
                TargetCheck.Refused(OfficePrecisionFailure.APPLY_CONFLICT, "pre-paste-manual-input-since-capture")
            target.editEpoch != editEpoch ->
                TargetCheck.Refused(OfficePrecisionFailure.APPLY_CONFLICT, "pre-paste-precision-effect-since-capture")
            run.preEffectEvidence == null ->
                TargetCheck.Refused(OfficePrecisionFailure.TARGET_UNVERIFIED, "pre-paste-evidence-missing")
            else -> TargetCheck.Ok(target)
        }
    }

    private fun newHandleId(): String {
        val bytes = ByteArray(16)
        random.nextBytes(bytes)
        val sb = StringBuilder(32)
        for (b in bytes) {
            sb.append(HEX[(b.toInt() shr 4) and 0x0f])
            sb.append(HEX[b.toInt() and 0x0f])
        }
        return sb.toString()
    }

    // ------------------------------------------------------------------
    // Terminal bookkeeping / result read
    // ------------------------------------------------------------------

    private fun terminateLocked(
        run: OpRun,
        state: OfficePrecisionState,
        failure: OfficePrecisionFailure?,
        detail: String?,
        attestation: String,
        answer: OfficePrecisionAnswer?,
    ): OfficePrecisionResult? {
        if (armed !== run && !queue.contains(run)) {
            // Already terminal (exactly-once guard).
            return run.lastTerminal
        }
        if (armed === run) armed = null
        queue.remove(run)
        val now = clock()
        if (run.effectDispatched) {
            // An effect-bearing wire was REALLY posted (Main final target-
            // safety review 2026-10-27): the in-memory document/selection/
            // part context may have moved — including on FAILED or UNKNOWN
            // (maybe-effect) outcomes and even though the flushed file
            // digest did not change. EVERY capture taken before this is now
            // stale and can never apply to another sheet/slide/selection;
            // a fresh capture (taken after) stays usable.
            editEpoch++
        }
        val contentMutationCompleted =
            run.request.action.effect == OfficePrecisionEffect.CONTENT &&
                (state == OfficePrecisionState.MUTATION_VERIFIED ||
                    state == OfficePrecisionState.NATIVE_COMPLETED)
        val readbackForAnswer = when {
            run.request.action == OfficePrecisionAction.SET_CELL_CONTENT &&
                run.request.contentKind == OfficePrecisionContentKind.FORMULA &&
                contentMutationCompleted ->
                OfficePrecisionContentReadback.FORMULA_NOT_COMPARABLE
            else -> run.contentReadback
        }
        val finalAnswer = answer ?: if (contentMutationCompleted) {
            OfficePrecisionAnswer.MutationApplied(
                steps = run.attestations.toList(),
                pastedBytes = run.request.text?.toByteArray(Charsets.UTF_8)?.size ?: 0,
                contentReadback = readbackForAnswer,
                workingCopySha256 = run.contextSha,
                consumedTargetHandle = run.request.targetHandle,
                preEffectEvidence = run.preEffectEvidence,
            )
        } else {
            null
        }
        val honestDetail = detail ?: when {
            state == OfficePrecisionState.NATIVE_COMPLETED &&
                run.request.action.effect == OfficePrecisionEffect.CONTENT ->
                "pending-flush-or-export-verification"
            state == OfficePrecisionState.NATIVE_COMPLETED ->
                "selection-postcondition-partial-readback"
            else -> null
        }
        val result = OfficePrecisionResult(
            opId = run.request.opId,
            sessionToken = run.request.sessionToken,
            generation = run.request.generation,
            action = run.request.action,
            state = state,
            failure = failure,
            detail = honestDetail?.take(240),
            answer = finalAnswer,
            attestation = attestation,
            submittedAtElapsedMs = run.submittedAt,
            completedAtElapsedMs = now,
        )
        run.lastTerminal = result
        pendingCaptureTarget = null
        storeResultLocked(result)
        return result
    }

    private fun storeResultLocked(result: OfficePrecisionResult) {
        completed[result.opId] = result
        while (completed.size > maxCompleted) {
            val oldest = completed.keys.iterator().next()
            completed.remove(oldest)
        }
    }

    /**
     * Terminates one claimed/queued run with an engine-side refusal (fence
     * re-check, target conflict, save-busy) BEFORE any wire effect.
     */
    internal fun rejectRun(
        run: OpRun,
        failure: OfficePrecisionFailure,
        detail: String,
    ): OfficePrecisionResult? = synchronized(lock) {
        if (armed !== run && !queue.contains(run)) return@synchronized run.lastTerminal
        terminateLocked(
            run,
            OfficePrecisionState.REJECTED,
            failure,
            detail,
            attestation = "refused-before-dispatch",
            answer = null,
        )
    }

    /**
     * Stores an engine-minted REJECTED result (refusals that never entered
     * the queue) so the owner can read the exact typed failure back.
     */
    fun recordRejection(result: OfficePrecisionResult) {
        synchronized(lock) {
            knownOpIds.add(result.opId)
            storeResultLocked(result)
        }
    }

    /**
     * Reads (and consumes) the terminal result for one exact fenced op.
     * Returns null while pending/in-flight or when unknown to this session.
     */
    fun takeResult(opId: String): OfficePrecisionResult? = synchronized(lock) {
        completed.remove(opId)
    }

    /** Non-consuming peek (diagnostics / client retry-safety). */
    fun peekResult(opId: String): OfficePrecisionResult? = synchronized(lock) {
        completed[opId]
    }
}
