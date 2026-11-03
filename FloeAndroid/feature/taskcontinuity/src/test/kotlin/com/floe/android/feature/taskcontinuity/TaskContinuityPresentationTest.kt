// SPDX-License-Identifier: MPL-2.0
//
// C02 continuity presentation logic tests. Pure JVM, no Android runtime,
// no network, no App host and no native call.
package com.floe.android.feature.taskcontinuity

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TaskContinuityPresentationTest {

    private fun pause(
        state: TaskContinuityPauseStateUi = TaskContinuityPauseStateUi.AWAITING_STORAGE_RECOVERY,
        markerID: String = "m-1",
    ) = TaskContinuityPauseUi(
        markerID = markerID,
        taskID = "task-1",
        runID = "run-1",
        rootEpoch = 7,
        reason = TaskContinuityPauseReasonUi.VOLUME_FULL,
        state = state,
        durability = TaskContinuityDurabilityUi.TASK_DATABASE,
        detectedAtLabel = "2026-11-02T00:00:00.000Z",
        updatedAtLabel = "2026-11-02T00:00:00.000Z",
        resumeAttempt = 0,
        runCheckpointed = true,
        unknownOutcomeCount = 0,
        explicitResumeOnly = true,
        targetRevision = 3,
        environmentID = "env-a",
        detailCode = null,
    )

    private fun wait(
        kind: TaskContinuityWaitKindUi = TaskContinuityWaitKindUi.QUESTION,
        answerable: Boolean = false,
        taskID: String = "task-1",
        runID: String = "run-1",
        rootEpoch: Long = 7,
        prompt: String = "Which file should I use?",
    ) = TaskContinuityWaitUi(
        waitID = "tw_1",
        kind = kind,
        rootEpoch = rootEpoch,
        taskID = taskID,
        runID = runID,
        toolCallID = "call-1",
        requestID = "uq_1",
        itemID = "uq_1.q1",
        revision = 2,
        prompt = prompt,
        promptTruncated = false,
        waitPolicy = "required",
        answerableNow = answerable,
        requiresResume = !answerable,
        deadlineLabel = null,
        requestDigest = "a".repeat(64),
        answerNonce = "nonce",
        approvalVersion = null,
        runState = "executingTool",
    )

    @Test
    fun resumeRequiresActionableMarkerAndReadyStorage() {
        val ready = TaskContinuityUiState(
            loaded = true,
            taskID = "task-1",
            runID = "run-1",
            storage = TaskContinuityStorageUi(
                condition = TaskContinuityStorageConditionUi.READY,
                isReady = true,
            ),
            pause = pause(),
        )
        assertTrue(TaskContinuityPresentation.canResume(ready))
        assertFalse(
            TaskContinuityPresentation.canResume(
                ready.copy(storage = TaskContinuityStorageUi(
                    condition = TaskContinuityStorageConditionUi.VOLUME_FULL,
                    isReady = false,
                )),
            ),
        )
        assertFalse(
            TaskContinuityPresentation.canResume(
                ready.copy(pause = pause(TaskContinuityPauseStateUi.RESUME_IN_PROGRESS)),
            ),
        )
        assertFalse(
            TaskContinuityPresentation.canResume(
                ready.copy(pause = pause(TaskContinuityPauseStateUi.RESUMED)),
            ),
        )
        assertFalse(TaskContinuityPresentation.canResume(ready.copy(busy = true)))
    }

    @Test
    fun bannerAppearsForPauseOrResumeRequiredWaitOnly() {
        val ordinary = TaskContinuityUiState(
            loaded = true, taskID = "task-1", runID = "run-1")
        assertFalse(TaskContinuityPresentation.shouldShowBanner(ordinary))
        assertTrue(
            TaskContinuityPresentation.shouldShowBanner(
                ordinary.copy(pause = pause()),
            ),
        )
        assertFalse(
            TaskContinuityPresentation.shouldShowBanner(
                ordinary.copy(pause = pause(TaskContinuityPauseStateUi.RESUMED)),
            ),
        )
        assertTrue(
            TaskContinuityPresentation.shouldShowBanner(
                ordinary.copy(waits = listOf(wait())),
            ),
        )
        assertFalse(
            TaskContinuityPresentation.shouldShowBanner(
                ordinary.copy(waits = listOf(wait(answerable = true))),
            ),
        )
    }

    @Test
    fun waitActionRoutesToOriginalSurfaces() {
        assertEquals(
            TaskContinuityWaitAction.RESUME_TASK,
            TaskContinuityPresentation.waitAction(wait()),
        )
        assertEquals(
            TaskContinuityWaitAction.REVIEW_QUESTION,
            TaskContinuityPresentation.waitAction(wait(answerable = true)),
        )
        assertEquals(
            TaskContinuityWaitAction.REVIEW_APPROVAL,
            TaskContinuityPresentation.waitAction(
                wait(kind = TaskContinuityWaitKindUi.APPROVAL, answerable = true),
            ),
        )
    }

    @Test
    fun crossTaskOrRootWaitIsRejected() {
        val value = wait()
        assertTrue(
            TaskContinuityPresentation.accepts(value, "task-1", "run-1", 7),
        )
        assertFalse(
            TaskContinuityPresentation.accepts(value, "task-2", "run-1", 7),
        )
        assertFalse(
            TaskContinuityPresentation.accepts(value, "task-1", "run-2", 7),
        )
        assertFalse(
            TaskContinuityPresentation.accepts(value, "task-1", "run-1", 8),
        )
    }

    @Test
    fun previewIsBoundedAndStable() {
        val long = wait(prompt = "x".repeat(200))
        val preview = TaskContinuityPresentation.waitPreview(long, maxCharacters = 20)
        assertEquals(20, preview.length)
        assertTrue(preview.endsWith("\u2026"))
        assertEquals(
            "Which file should I use?",
            TaskContinuityPresentation.waitPreview(wait()),
        )
    }
}
