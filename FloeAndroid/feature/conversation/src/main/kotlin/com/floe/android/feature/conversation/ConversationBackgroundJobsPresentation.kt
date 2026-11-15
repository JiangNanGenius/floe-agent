// SPDX-License-Identifier: MPL-2.0
//
// Pure presentation rules for THIS task's finite background jobs. No I/O, no
// payload parsing, no permission decision and no terminal inference: the
// durable host projection is the only state source.
package com.floe.android.feature.conversation

/**
 * Closed target labels and durable state vocabulary for the background-job
 * surface (⇄ BackgroundJobTools `jobs.status` state names, never invented).
 */
object FloeBackgroundJobPresentation {

    /** String-resource KEY for the closed target class. */
    fun targetTitleKey(targetKind: String): String = when (targetKind) {
        "shell" -> "job_target_shell"
        "web" -> "job_target_web"
        "officeEdit" -> "job_target_office"
        "service" -> "job_target_service"
        else -> "job_target_other"
    }

    /**
     * Durable state label. A cancellation request is NOT a terminal state:
     * a running job that was asked to stop stays "Cancelling" until its
     * processor acknowledges and the durable row really ends.
     */
    fun stateKey(job: BackgroundJobUi): String = when {
        job.stateName == "queued" -> "job_state_queued"
        job.stateName == "running" && job.cancellationRequested -> "job_state_cancelling"
        job.stateName == "running" -> "job_state_running"
        job.stateName == "completed" -> "job_state_completed"
        job.stateName == "failed" -> "job_state_failed"
        job.stateName == "cancelled" -> "job_state_cancelled"
        job.stateName == "interrupted" -> "job_state_interrupted"
        else -> "job_state_unknown"
    }

    fun stateColorRole(job: BackgroundJobUi): FloeStateColorRole = when {
        job.terminal && job.stateName == "completed" -> FloeStateColorRole.SUCCESS
        job.terminal && job.stateName == "failed" -> FloeStateColorRole.DESTRUCTIVE
        job.terminal && job.stateName == "interrupted" -> FloeStateColorRole.DESTRUCTIVE
        job.cancellationRequested -> FloeStateColorRole.PENDING
        job.terminal -> FloeStateColorRole.UNKNOWN
        else -> FloeStateColorRole.ACCENT
    }

    /** Real processor units only; a phase without units shows no fake percent. */
    fun progressLabel(job: BackgroundJobUi): String? {
        val completed = job.completedUnits
        val total = job.totalUnits
        return when {
            completed != null && total != null && total > 0 -> "$completed/$total"
            completed != null && completed > 0 -> completed.toString()
            else -> null
        }
    }

    /** Closed stage label key, or null when the processor reported no stage. */
    fun progressStageKey(job: BackgroundJobUi): String? = when (job.progressStage) {
        "preparing" -> "job_stage_preparing"
        "running" -> "job_stage_running"
        "finalizing" -> "job_stage_finalizing"
        "verifying" -> "job_stage_verifying"
        "cancelling" -> "job_stage_cancelling"
        else -> null
    }

    /** Required-dependency line key, or null for an optional job. */
    fun dependencyKey(job: BackgroundJobUi): String? {
        if (job.dependencyKind == null) return null
        return when (job.dependencyState) {
            "pending" -> "jobs_dependency_pending"
            "resolved" -> if (job.dependencyKind == "service") {
                "jobs_dependency_service_ready"
            } else {
                "jobs_dependency_resolved"
            }
            "failed" -> "jobs_dependency_failed"
            "cancelled" -> "jobs_dependency_cancelled"
            "interrupted" -> "jobs_dependency_interrupted"
            else -> "jobs_dependency_pending"
        }
    }

    /** True when a compact waiting bar should be visible for this thread. */
    fun showsWaitingBar(state: ThreadUiState): Boolean =
        state.selectedRunWaitingForJobs

    /**
     * A cancel is offered only while the row is nonterminal, no cancellation
     * was requested yet, and this tap is not already in flight.
     */
    fun cancelEnabled(job: BackgroundJobUi, cancelling: Set<String>): Boolean =
        job.canCancel && !job.cancellationRequested && job.jobId !in cancelling
}
