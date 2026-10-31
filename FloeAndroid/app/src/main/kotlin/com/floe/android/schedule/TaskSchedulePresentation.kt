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
