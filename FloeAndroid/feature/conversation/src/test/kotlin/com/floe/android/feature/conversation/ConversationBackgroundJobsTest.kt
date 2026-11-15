// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.conversation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationBackgroundJobsTest {

    private fun job(
        jobId: String = "job-1",
        runId: String = "run-1",
        targetKind: String = "shell",
        state: String = "running",
        terminal: Boolean = false,
        cancellationRequested: Boolean = false,
        resultAvailable: Boolean = false,
        completedUnits: Int? = null,
        totalUnits: Int? = null,
        dependencyKind: String? = "job",
        dependencyState: String? = "pending",
    ) = BackgroundJobUi(
        jobId = jobId,
        runId = runId,
        targetKind = targetKind,
        stateName = state,
        terminal = terminal,
        cancellationRequested = cancellationRequested,
        resultAvailable = resultAvailable,
        completedUnits = completedUnits,
        totalUnits = totalUnits,
        dependencyKind = dependencyKind,
        dependencyState = dependencyState,
    )

    @Test
    fun durableStateVocabularyNeverTurnsARequestIntoATerminal() {
        val running = job()
        assertEquals("job_state_running", FloeBackgroundJobPresentation.stateKey(running))
        assertEquals(FloeStateColorRole.ACCENT,
            FloeBackgroundJobPresentation.stateColorRole(running))

        val cancelling = job(cancellationRequested = true)
        assertEquals("job_state_cancelling",
            FloeBackgroundJobPresentation.stateKey(cancelling))
        assertTrue(cancelling.canCancel)

        val completed = job(state = "completed", terminal = true,
            cancellationRequested = false, resultAvailable = true)
        assertEquals("job_state_completed",
            FloeBackgroundJobPresentation.stateKey(completed))
        assertEquals(FloeStateColorRole.SUCCESS,
            FloeBackgroundJobPresentation.stateColorRole(completed))
        assertFalse(completed.canCancel)

        val interrupted = job(state = "interrupted", terminal = true)
        assertEquals("job_state_interrupted",
            FloeBackgroundJobPresentation.stateKey(interrupted))
        assertEquals(FloeStateColorRole.DESTRUCTIVE,
            FloeBackgroundJobPresentation.stateColorRole(interrupted))
    }

    @Test
    fun cancelIsOfferedOnlyForARealNonterminalRequest() {
        assertTrue(FloeBackgroundJobPresentation.cancelEnabled(job(), emptySet()))
        assertFalse(FloeBackgroundJobPresentation.cancelEnabled(
            job(cancellationRequested = true), emptySet()))
        assertFalse(FloeBackgroundJobPresentation.cancelEnabled(
            job(), setOf("job-1")))
        assertFalse(FloeBackgroundJobPresentation.cancelEnabled(
            job(state = "completed", terminal = true), emptySet()))
    }

    @Test
    fun progressUsesOnlyRealProcessorUnits() {
        assertEquals("3/10", FloeBackgroundJobPresentation.progressLabel(
            job(completedUnits = 3, totalUnits = 10)))
        assertEquals(null, FloeBackgroundJobPresentation.progressLabel(
            job(completedUnits = null, totalUnits = null)))
        assertEquals("3", FloeBackgroundJobPresentation.progressLabel(
            job(completedUnits = 3, totalUnits = 0)))
        assertEquals("job_stage_running",
            FloeBackgroundJobPresentation.progressStageKey(
                BackgroundJobUi(jobId = "j", runId = "r", targetKind = "shell",
                    stateName = "running", terminal = false,
                    cancellationRequested = false, resultAvailable = false,
                    progressStage = "running")))
    }

    @Test
    fun closedTargetLabelsHaveNoRawToolNames() {
        assertEquals("job_target_shell",
            FloeBackgroundJobPresentation.targetTitleKey("shell"))
        assertEquals("job_target_service",
            FloeBackgroundJobPresentation.targetTitleKey("service"))
        assertEquals("job_target_other",
            FloeBackgroundJobPresentation.targetTitleKey("exec.shell"))
    }

    @Test
    fun dependencyLabelsComeOnlyFromTheDurableState() {
        assertEquals("jobs_dependency_pending",
            FloeBackgroundJobPresentation.dependencyKey(job()))
        assertEquals("jobs_dependency_resolved",
            FloeBackgroundJobPresentation.dependencyKey(
                job(dependencyKind = "job", dependencyState = "resolved")))
        // A service can be ready while it keeps running; this label must
        // not imply the service process finished.
        assertEquals("jobs_dependency_service_ready",
            FloeBackgroundJobPresentation.dependencyKey(
                job(dependencyKind = "service", dependencyState = "resolved")))
        assertEquals(null, FloeBackgroundJobPresentation.dependencyKey(
            job(dependencyKind = null, dependencyState = null)))
    }

    @Test
    fun waitingCheckpointIsNotTerminalForTheStopAffordance() {
        assertTrue(FloeRunStateLocalizer.isTerminal("checkpointed"))
        assertFalse(FloeRunStateLocalizer.isTerminal(
            "checkpointed", awaitingBackgroundJobs = true))
        assertTrue(FloeRunStateLocalizer.isAwaitingBackgroundJobs(
            "checkpointed", "awaiting.finite.job:abc"))
        assertTrue(FloeRunStateLocalizer.isAwaitingBackgroundJobs(
            "checkpointed", "awaiting.finite.job"))
        assertFalse(FloeRunStateLocalizer.isAwaitingBackgroundJobs(
            "checkpointed", "runtime.agent_runtime.the_task_was_stopped_by_you"))
        assertFalse(FloeRunStateLocalizer.isAwaitingBackgroundJobs(
            "completed", "awaiting.finite.job"))
    }

    @Test
    fun requiredDependenciesSettleOnlyWhenNoEdgeIsPending() {
        assertFalse(FloeRunStateLocalizer.requiredDependenciesSettled(
            listOf(job(dependencyState = "pending")), "run-1", loaded = true))
        // A proven-ready managed service resolves its edge while the service
        // keeps running: that is settled.
        assertTrue(FloeRunStateLocalizer.requiredDependenciesSettled(
            listOf(job(dependencyKind = "service", dependencyState = "resolved")),
            "run-1", loaded = true))
        assertTrue(FloeRunStateLocalizer.requiredDependenciesSettled(
            listOf(job(dependencyState = "failed", terminal = true),
                   job(jobId = "job-2", dependencyState = "cancelled", terminal = true)),
            "run-1", loaded = true))
        // An unrelated run's pending job never blocks this run, and a run with
        // no visible rows may still be continued explicitly.
        assertTrue(FloeRunStateLocalizer.requiredDependenciesSettled(
            listOf(job(runId = "another-run", dependencyState = "pending")),
            "run-1", loaded = true))
        assertTrue(FloeRunStateLocalizer.requiredDependenciesSettled(
            emptyList(), "run-1", loaded = true))
        // An unloaded/wrong-run/optional-running projection is never settled.
        assertFalse(FloeRunStateLocalizer.requiredDependenciesSettled(
            emptyList(), "run-1", loaded = false))
        assertFalse(FloeRunStateLocalizer.requiredDependenciesSettled(
            listOf(job(dependencyKind = null, dependencyState = null)),
            "run-1", loaded = true))
        assertFalse(FloeRunStateLocalizer.requiredDependenciesSettled(
            listOf(job()), null, loaded = true))
    }

    @Test
    fun waitingRunKeepsTheRealStopReachable() {
        val host = RecordingHost()
        val holder = ConversationFlowHolder(host, "waiting")
        holder.applyHostSnapshot(threadState(
            holder.session, selectedRunId = "run-1",
            isRunning = false, waitingForJobs = true))
        assertEquals(ConversationFlowResult.Accepted, holder.cancel())
        assertEquals(listOf<Any?>(holder.session, "run-1"), host.lastArgs("cancelRun"))
    }

    @Test
    fun continueIsRefusedUntilRequiredEdgesSettle() {
        val host = RecordingHost()
        val holder = ConversationFlowHolder(host, "waiting")
        holder.applyHostSnapshot(threadState(
            holder.session, selectedRunId = "run-1", waitingForJobs = true))
        assertEquals(ConversationFlowResult.Rejected(ConversationRejectedReason.RUN_NOT_CONTINUABLE),
            holder.retry())
        assertEquals(0, host.count("retryRun"))

        holder.applyHostSnapshot(threadState(
            holder.session, selectedRunId = "run-1", waitingForJobs = true,
            dependenciesSettled = true))
        assertEquals(ConversationFlowResult.Accepted, holder.retry())
        assertEquals(1, host.count("retryRun"))
    }

    @Test
    fun openBackgroundJobsDispatchesOneBoundedRead() {
        val host = RecordingHost()
        val holder = ConversationFlowHolder(host, "jobs")
        holder.applyHostSnapshot(threadState(holder.session))
        assertEquals(ConversationFlowResult.Accepted, holder.openBackgroundJobs())
        assertTrue(holder.backgroundJobsVisible)
        assertEquals(1, host.count("refreshBackgroundJobs"))
    }

    @Test
    fun perJobCancelUsesTheExactIdentityAndLatchesTheTap() {
        val host = RecordingHost()
        val holder = ConversationFlowHolder(host, "jobs")
        holder.applyHostSnapshot(threadState(holder.session,
            backgroundJobs = listOf(job(jobId = "job-9", runId = "run-7"))))
        assertEquals(ConversationFlowResult.Accepted,
            holder.cancelBackgroundJob(job(jobId = "job-9", runId = "run-7")))
        assertEquals(listOf<Any?>(holder.session, "job-9", "run-7"),
            host.lastArgs("cancelBackgroundJob"))
        assertEquals(setOf("job-9"), holder.cancellingBackgroundJobIds)
        assertEquals(ConversationFlowResult.Rejected(ConversationRejectedReason.OPERATION_IN_FLIGHT),
            holder.cancelBackgroundJob(job(jobId = "job-9", runId = "run-7")))
        assertEquals(1, host.count("cancelBackgroundJob"))
        holder.applyBackgroundJobActionSettled("job-9")
        assertTrue(holder.cancellingBackgroundJobIds.isEmpty())
    }

    @Test
    fun terminalJobHasNoCancelAffordance() {
        val host = RecordingHost()
        val holder = ConversationFlowHolder(host, "jobs")
        holder.applyHostSnapshot(threadState(holder.session))
        assertEquals(ConversationFlowResult.Rejected(ConversationRejectedReason.RUN_NOT_CONTINUABLE),
            holder.cancelBackgroundJob(job(state = "completed", terminal = true,
                dependencyState = "resolved")))
        assertEquals(0, host.count("cancelBackgroundJob"))
    }

    @Test
    fun failedDispatchClearsTheTapLatch() {
        val host = RecordingHost()
        host.backgroundJobCancelAccepted = false
        val holder = ConversationFlowHolder(host, "jobs")
        holder.applyHostSnapshot(threadState(holder.session))
        assertEquals(ConversationFlowResult.Rejected(ConversationRejectedReason.HOST_UNAVAILABLE),
            holder.cancelBackgroundJob(job()))
        assertTrue(holder.cancellingBackgroundJobIds.isEmpty())
    }
}
