// SPDX-License-Identifier: MPL-2.0
//
// C02 continuity controller tests. Deterministic fake environment/client only:
// no native Root, database, network, provider, device or App UI.
package com.floe.android.host.taskcontinuity

import com.floe.android.feature.taskcontinuity.TaskContinuityDurabilityUi
import com.floe.android.feature.taskcontinuity.TaskContinuityPauseReasonUi
import com.floe.android.feature.taskcontinuity.TaskContinuityPauseStateUi
import com.floe.android.feature.taskcontinuity.TaskContinuityPauseUi
import com.floe.android.feature.taskcontinuity.TaskContinuityStorageConditionUi
import com.floe.android.feature.taskcontinuity.TaskContinuityStorageUi
import com.floe.android.feature.taskcontinuity.TaskContinuityUiState
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TaskContinuityHostControllerTest {

    private class FakeEnv(
        var epoch: Long? = 7,
        var generation: Long = 1,
        var temporary: Boolean = false,
    ) : TaskContinuityHostEnv {
        override fun nativeRootEpoch(): Long? = epoch
        override fun generation(): Long = generation
        override fun isTemporary(taskID: String): Boolean = temporary
        override val ioDispatcher = Dispatchers.Unconfined
    }

    private class FakeApi(
        var snapshot: TaskContinuitySnapshotWire,
        var resumeReply: TaskContinuityResumeWire? = null,
        var resumeFailure: Throwable? = null,
        var checkReply: TaskContinuitySnapshotWire? = null,
        var onSnapshot: (() -> Unit)? = null,
    ) : TaskContinuityApi {
        var snapshotCalls = 0
        var resumeCalls = 0
        var checkCalls = 0
        override fun snapshot(taskID: String, runID: String?): TaskContinuitySnapshotWire {
            snapshotCalls += 1
            onSnapshot?.invoke()
            return snapshot
        }

        override fun checkStorage(taskID: String, runID: String): TaskContinuitySnapshotWire {
            checkCalls += 1
            return checkReply ?: snapshot
        }

        override fun pause(
            taskID: String,
            runID: String,
            reason: String?,
        ): TaskContinuityPauseWire {
            throw TaskContinuityFailure("notUsed", "not used")
        }

        override fun resume(
            taskID: String,
            runID: String,
            markerID: String,
            expectedRootEpoch: Long,
            expectedTargetRevision: Long?,
        ): TaskContinuityResumeWire {
            resumeCalls += 1
            resumeFailure?.let { throw it }
            return resumeReply ?: TaskContinuityResumeWire(
                accepted = true, resumed = true,
                requiresReconciliation = false, marker = null)
        }
    }

    private fun pause(
        state: TaskContinuityPauseStateUi = TaskContinuityPauseStateUi.AWAITING_STORAGE_RECOVERY,
    ) = TaskContinuityPauseUi(
        markerID = "m-1",
        taskID = TASK,
        runID = RUN,
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

    private fun state(pause: TaskContinuityPauseUi? = pause()) = TaskContinuityUiState(
        loaded = true,
        taskID = TASK,
        runID = RUN,
        rootEpoch = 7,
        storage = TaskContinuityStorageUi(
            condition = TaskContinuityStorageConditionUi.READY,
            isReady = true,
        ),
        pause = pause,
    )

    private fun wire(state: TaskContinuityUiState, pauseRecorded: Boolean? = null) =
        TaskContinuitySnapshotWire(state = state, pauseRecorded = pauseRecorded)

    @Test
    fun loadAppliesSnapshotAndTemporaryIsRefused() {
        val env = FakeEnv()
        val api = FakeApi(wire(state()))
        val controller = TaskContinuityHostController(env, api)
        controller.load(TASK, RUN)
        assertTrue(controller.state.value.loaded)
        assertEquals("m-1", controller.state.value.pause?.markerID)
        assertEquals(1, api.snapshotCalls)

        env.temporary = true
        controller.load(TASK, RUN)
        assertNull(controller.state.value.pause)
        assertNull(controller.state.value.taskID)
        assertEquals(1, api.snapshotCalls)
    }

    @Test
    fun lateSnapshotAfterRootChangeIsDropped() {
        val env = FakeEnv()
        val api = FakeApi(
            wire(state()),
            onSnapshot = { env.epoch = 8 },
        )
        val controller = TaskContinuityHostController(env, api)
        controller.load(TASK, RUN)
        // The reply belongs to the retired epoch: nothing was applied.
        assertNull(controller.state.value.pause)
        assertFalse(controller.state.value.loaded)
        assertEquals(TASK, controller.state.value.taskID)
    }

    @Test
    fun doubleResumeDispatchesExactlyOnce() {
        val env = FakeEnv()
        val api = FakeApi(wire(state()))
        val controller = TaskContinuityHostController(env, api)
        controller.load(TASK, RUN)
        controller.resume()
        assertEquals(1, api.resumeCalls)
        assertEquals(TaskContinuityPauseStateUi.RESUMED, controller.state.value.pause?.state)
        controller.resume()
        assertEquals(1, api.resumeCalls)
    }

    @Test
    fun refusedResumeKeepsMarkerAndShowsTypedError() {
        val env = FakeEnv()
        val api = FakeApi(
            wire(state()),
            resumeFailure = TaskContinuityFailure(
                "storageStillUnavailable:volumeFull",
                "Storage is still unavailable.",
                retryable = true,
            ),
        )
        val controller = TaskContinuityHostController(env, api)
        controller.load(TASK, RUN)
        controller.resume()
        assertEquals(1, api.resumeCalls)
        assertEquals(
            "storageStillUnavailable:volumeFull",
            controller.state.value.errorCode,
        )
        assertEquals(
            TaskContinuityPauseStateUi.AWAITING_STORAGE_RECOVERY,
            controller.state.value.pause?.state,
        )
        assertNotNull(controller.state.value.pause)
    }

    @Test
    fun storageCheckSurfacesRecordedPause() {
        val env = FakeEnv()
        val api = FakeApi(
            wire(state()),
            checkReply = wire(state(), pauseRecorded = true),
        )
        val controller = TaskContinuityHostController(env, api)
        controller.load(TASK, RUN)
        controller.checkStorage()
        assertEquals(1, api.checkCalls)
        assertEquals("storagePaused", controller.state.value.notice)
        assertEquals("m-1", controller.state.value.pause?.markerID)
    }

    @Test
    fun runPersistenceRefusalUsesTheBoundedProbeAndNeverResumes() {
        val env = FakeEnv()
        val api = FakeApi(
            wire(TaskContinuityUiState()),
            checkReply = wire(state(), pauseRecorded = true),
        )
        val controller = TaskContinuityHostController(env, api)
        controller.noteRunStorageFailure(TASK, RUN)
        assertEquals(1, api.checkCalls)
        assertEquals(0, api.resumeCalls)
        assertEquals("storagePaused", controller.state.value.notice)
        assertEquals("m-1", controller.state.value.pause?.markerID)
    }

    @Test
    fun epochUnavailableNeverCallsTheBridge() {
        val env = FakeEnv(epoch = null)
        val api = FakeApi(wire(state()))
        val controller = TaskContinuityHostController(env, api)
        controller.load(TASK, RUN)
        assertEquals(0, api.snapshotCalls)
        assertEquals("runtime_unavailable", controller.state.value.errorCode)
    }

    private companion object {
        const val TASK = "11111111-1111-1111-1111-111111111111"
        const val RUN = "22222222-2222-2222-2222-222222222222"
    }
}
