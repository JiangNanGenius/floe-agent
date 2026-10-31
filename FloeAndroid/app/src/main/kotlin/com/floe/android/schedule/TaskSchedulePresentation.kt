// SPDX-License-Identifier: MPL-2.0
package com.floe.android.schedule

/**
 * How the platform can actually wake this schedule. Kept as a closed enum so
 * the UI copy and the dispatch transport agree on one meaning.
 */
enum class TaskSchedulePresentationStatus {
    /** Exact wall-clock alarm armed; runs at the specified time. */
    ACTIVE,

    /** The user explicitly chose flexible WorkManager; may run late. */
    FLEXIBLE,

    /** Enabled, but exact-alarm permission is missing and no flexible choice
     * was made. Nothing is armed; the user must choose. */
    WAITING_PERMISSION,

    PAUSED,

    /** `.afterSuccess`: armed by a real upstream successful run, not a clock. */
    EVENT_DRIVEN,

    /** The last occurrence failed/interrupted, a binding is missing, or the
     * platform transport could not start the task. Actionable. */
    NEEDS_ATTENTION,
}

object TaskSchedulePresentation {
    fun status(
        summary: TaskScheduleSummary,
        exactAlarmAllowed: Boolean,
        flexibleChosen: Boolean,
        transportNotice: String?,
    ): TaskSchedulePresentationStatus {
        if (!summary.enabled) return TaskSchedulePresentationStatus.PAUSED
        if (summary.needsAttention || transportNotice != null) {
            return TaskSchedulePresentationStatus.NEEDS_ATTENTION
        }
        if (summary.cadence == TaskScheduleCadence.AFTER_SUCCESS) {
            return TaskSchedulePresentationStatus.EVENT_DRIVEN
        }
        if (!exactAlarmAllowed && !flexibleChosen) {
            return TaskSchedulePresentationStatus.WAITING_PERMISSION
        }
        if (flexibleChosen) return TaskSchedulePresentationStatus.FLEXIBLE
        return TaskSchedulePresentationStatus.ACTIVE
    }
}

/**
 * The after-success picker list: the native run-store projection is the base,
 * a UI holder's visual suggestions may be merged in, and the list is narrowed
 * to the selected project when one is frozen. This is PRESENTATION only; the
 * native service re-validates every chosen run and remains the authority.
 * Pure so the composition policy is pinned by a JVM test.
 */
internal fun availableRunChoices(
    nativeChoices: List<TaskScheduleRunChoice>,
    visualChoices: List<TaskScheduleRunChoice>,
    workspaceID: String?,
): List<TaskScheduleRunChoice> = (nativeChoices + visualChoices)
    .distinctBy { it.runID }
    .filter { choice ->
        workspaceID == null || choice.workspaceID == null ||
            choice.workspaceID == workspaceID
    }


/**
 * What the dispatch worker must do with its provisional foreground lease
 * after a real terminal, a timeout or a cancelled caller.
 *
 *  * ADMIT — a real run exists and the authoritative lease must be attached
 *    BEFORE the provisional is released (coverage stays continuous).
 *  * RELEASE — the attempt provably did not produce a run (or the run already
 *    settled); the provisional lease must be closed.
 *  * RECONCILE — the receipt is genuinely unknown. NEVER release blindly:
 *    resolve through the durable occurrence ledger first.
 */
internal enum class TaskScheduleAdmissionDecision { ADMIT, RELEASE, RECONCILE }

internal object TaskScheduleAdmissionPolicy {
    /** `null` means the terminal never arrived (bounded wait elapsed). */
    fun decision(result: TaskScheduleResult<TaskScheduleDispatch>?): TaskScheduleAdmissionDecision =
        when (result) {
            null -> TaskScheduleAdmissionDecision.RECONCILE
            is TaskScheduleResult.Ok ->
                if (result.value.launched) TaskScheduleAdmissionDecision.ADMIT
                else TaskScheduleAdmissionDecision.RELEASE
            is TaskScheduleResult.Failure -> when (result.code) {
                // Transport/observation uncertainty: the command may have
                // been admitted even though the caller did not observe it.
                "timeout", "cancelled", "superseded", "malformed" ->
                    TaskScheduleAdmissionDecision.RECONCILE
                // A definite native refusal before any launch, or a proven
                // pre-submit runtime-unavailable. Safe to release.
                else -> TaskScheduleAdmissionDecision.RELEASE
            }
        }

    /**
     * Durable-ledger resolution. `null` means the read itself failed (still
     * unknown, keep the lease); a real row is authoritative.
     */
    fun decisionForOccurrence(
        occurrence: TaskScheduleOccurrence?,
    ): TaskScheduleAdmissionDecision {
        if (occurrence == null) return TaskScheduleAdmissionDecision.RECONCILE
        val hasRun = occurrence.runID != null && occurrence.conversationID != null
        return when (occurrence.state) {
            // A live occurrence bound to a real run: adopt it.
            "running" -> if (hasRun) TaskScheduleAdmissionDecision.ADMIT
                else TaskScheduleAdmissionDecision.RECONCILE
            // Claimed but the launch has not bound a run yet: still unknown.
            "claimed" -> if (hasRun) TaskScheduleAdmissionDecision.ADMIT
                else TaskScheduleAdmissionDecision.RECONCILE
            // Any terminal row with a run already settled: no live work to
            // protect. Without a run the attempt did not launch.
            else -> TaskScheduleAdmissionDecision.RELEASE
        }
    }
}

/**
 * Thread-safe admission bookkeeping for ONE dispatch worker attempt.
 *
 * The provisional foreground lease is released ONLY through a decision this
 * object can justify: a pre-submit cancellation/Stop (nothing was queued), a
 * definite non-launch terminal, or a real admission transfer. A submitted
 * envelope whose receipt/terminal is unknown is NEVER treated as a definite
 * non-admission. The host callback and the WorkManager coroutine touch this
 * object from different threads.
 */
internal class TaskScheduleAdmissionGuard {
    private val acceptedAtomic = java.util.concurrent.atomic.AtomicBoolean(false)
    private val stoppedAtomic = java.util.concurrent.atomic.AtomicBoolean(false)
    private val stopCancellationClaimed =
        java.util.concurrent.atomic.AtomicBoolean(false)
    private val terminal = TaskScheduleTerminalSink<TaskScheduleDispatch>()

    /** Completes with the REAL terminal exactly once (also when the worker
     *  coroutine was already cancelled and only the host pump observed it). */
    val settled: kotlinx.coroutines.CompletableDeferred<
        TaskScheduleResult<TaskScheduleDispatch>>
        get() = terminal.settled

    fun onAccepted() {
        acceptedAtomic.set(true)
    }

    fun onStopRequested() {
        stoppedAtomic.set(true)
    }

    fun stopRequested(): Boolean = stoppedAtomic.get()

    /**
     * Claim the ONE canonical cancel for an actually admitted run. A Stop can
     * arrive while the receipt is unknown and the same attempt can then be
     * resolved from both the live worker path and the late-terminal path;
     * only the winner reaches `run.cancel` (exactly once), the other is a
     * no-op. Returns false when no Stop is pending or a cancel was claimed.
     */
    fun claimStopCancellation(): Boolean {
        if (!stoppedAtomic.get()) return false
        return stopCancellationClaimed.compareAndSet(false, true)
    }

    fun wasSubmitted(): Boolean = acceptedAtomic.get()

    fun recordSettled(result: TaskScheduleResult<TaskScheduleDispatch>) {
        terminal.deliver(result)
    }

    /** Cancellation of the calling coroutine: pre-submit is a definite
     *  release; after queue acceptance it is an unknown receipt. */
    fun cancellationDecision(): TaskScheduleAdmissionDecision =
        if (acceptedAtomic.get()) TaskScheduleAdmissionDecision.RECONCILE
        else TaskScheduleAdmissionDecision.RELEASE

    /** Policy for an observed terminal, downgraded to RELEASE only when the
     *  host queue provably never accepted the envelope. */
    fun effectiveDecision(
        result: TaskScheduleResult<TaskScheduleDispatch>,
    ): TaskScheduleAdmissionDecision {
        val decision = TaskScheduleAdmissionPolicy.decision(result)
        return if (!acceptedAtomic.get() &&
            decision == TaskScheduleAdmissionDecision.RECONCILE) {
            TaskScheduleAdmissionDecision.RELEASE
        } else {
            decision
        }
    }
}

/** What the late-terminal resolver actually did. Testable evidence, not a
 *  second authority: every side effect still goes through the callbacks. */
internal enum class TaskScheduleLateAdmissionOutcome {
    /** The accepted Root generation changed before/at resolution; no old run
     *  or provisional lease may be re-acquired into the new generation. */
    FENCED,
    ADMITTED,
    ADMITTED_AND_CANCELLED,
    ADOPTION_FAILED,
    RELEASED,
    UNKNOWN_RETAINED,
}

/**
 * Resolves ONE submitted-but-unobserved dispatch from its REAL host terminal.
 *
 * The caller timeout/cancellation only closed the observation window; it is
 * not a terminal. This resolver is owned by the Application coordinator
 * scope, is fenced by the EXACT accepted Root epoch captured at dispatch, and
 * carries the real attempt [TaskScheduleAdmissionGuard] so a Stop that
 * arrived while the receipt was unknown still reaches the canonical
 * `run.cancel` path exactly once after the late ADMIT is adopted.
 */
internal class TaskScheduleLateAdmissionResolver(
    private val guard: TaskScheduleAdmissionGuard,
    private val dispatchedEpoch: Long,
    private val liveEpoch: () -> Long?,
    private val admit: suspend (conversationID: String, runID: String) -> Boolean,
    private val release: () -> Unit,
    private val cancelAdmittedRun: (conversationID: String, runID: String) -> Unit,
    private val notice: (String?) -> Unit,
) {
    private fun fenced(): Boolean = liveEpoch() != dispatchedEpoch

    /** Waits for the host's real terminal; never times out and never treats
     *  an observation gap as a terminal. */
    suspend fun awaitAndResolve(): TaskScheduleLateAdmissionOutcome =
        resolve(guard.settled.await())

    suspend fun resolve(
        terminal: TaskScheduleResult<TaskScheduleDispatch>,
    ): TaskScheduleLateAdmissionOutcome {
        if (fenced()) return TaskScheduleLateAdmissionOutcome.FENCED
        return when (TaskScheduleAdmissionPolicy.decision(terminal)) {
            TaskScheduleAdmissionDecision.ADMIT -> {
                val dispatch = (terminal as? TaskScheduleResult.Ok<TaskScheduleDispatch>)?.value
                val conversationID = dispatch?.conversationID
                val runID = dispatch?.runID
                if (conversationID == null || runID == null) {
                    // A "launched" terminal without both real identities is
                    // unknown, not a rejection: retain coverage honestly.
                    notice("foreground_unavailable")
                    TaskScheduleLateAdmissionOutcome.UNKNOWN_RETAINED
                } else if (!admit(conversationID, runID)) {
                    // The authoritative lease could not be attached; keep
                    // provisional coverage and report honestly.
                    notice("foreground_unavailable")
                    TaskScheduleLateAdmissionOutcome.ADOPTION_FAILED
                } else if (fenced()) {
                    // The generation retired during adoption. Do not cancel
                    // or re-acquire the old run into the new generation; the
                    // Root retirement owns the provisional lease.
                    TaskScheduleLateAdmissionOutcome.FENCED
                } else {
                    notice(null)
                    if (guard.claimStopCancellation()) {
                        cancelAdmittedRun(conversationID, runID)
                        TaskScheduleLateAdmissionOutcome.ADMITTED_AND_CANCELLED
                    } else {
                        TaskScheduleLateAdmissionOutcome.ADMITTED
                    }
                }
            }
            TaskScheduleAdmissionDecision.RELEASE -> {
                // A real host terminal proved no launch. Safe to release.
                release()
                TaskScheduleLateAdmissionOutcome.RELEASED
            }
            TaskScheduleAdmissionDecision.RECONCILE -> {
                // Unknown/malformed terminal: never release on a guess.
                notice("foreground_unavailable")
                TaskScheduleLateAdmissionOutcome.UNKNOWN_RETAINED
            }
        }
    }
}
