// SPDX-License-Identifier: MPL-2.0
//
// C02 Application-owned durable task-continuity controller.
//
// It owns ONLY the trusted-host client correlation and immutable projections.
// The Swift coordinator owns the pause marker, storage probe, canonical wait
// identity and the explicit-resume CAS. This controller never resumes on its
// own, never answers a question/approval, and never treats a late reply as
// authority for a newer task/root generation.
package com.floe.android.host.taskcontinuity

import com.floe.android.feature.taskcontinuity.TaskContinuityPauseStateUi
import com.floe.android.feature.taskcontinuity.TaskContinuityPresentation
import com.floe.android.feature.taskcontinuity.TaskContinuityUiState
import com.floe.android.host.RuntimeHost
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

internal interface TaskContinuityHostEnv {
    fun nativeRootEpoch(): Long?
    fun generation(): Long
    fun isTemporary(taskID: String): Boolean
    val ioDispatcher: CoroutineDispatcher
}

private class RuntimeTaskContinuityHostEnv(
    private val host: RuntimeHost,
) : TaskContinuityHostEnv {
    override fun nativeRootEpoch(): Long? = host.nativeRootEpoch()
    override fun generation(): Long = host.commandClient.generation()
    override fun isTemporary(taskID: String): Boolean =
        host.conversations.entryFor(taskID)?.isTemporary == true
    override val ioDispatcher: CoroutineDispatcher = host.ioDispatcher
}

class TaskContinuityHostController internal constructor(
    private val env: TaskContinuityHostEnv,
    private val api: TaskContinuityApi = TaskContinuityClient(),
) {
    internal constructor(
        host: RuntimeHost,
        api: TaskContinuityApi = TaskContinuityClient(),
    ) : this(RuntimeTaskContinuityHostEnv(host), api)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val mutable = MutableStateFlow(TaskContinuityUiState())
    val state: StateFlow<TaskContinuityUiState> = mutable.asStateFlow()
    private var job: Job? = null
    private var fence = 0L

    /** Load the pause marker and canonical waits for one durable task. */
    fun load(taskID: String, runID: String? = null) {
        if (taskID.isBlank()) {
            mutable.value = TaskContinuityUiState(
                loaded = true, errorCode = "invalidTask")
            return
        }
        if (env.isTemporary(taskID)) {
            mutable.value = TaskContinuityUiState()
            return
        }
        val epoch = env.nativeRootEpoch() ?: run {
            mutable.value = mutable.value.copy(
                loading = false,
                loaded = true,
                taskID = taskID,
                runID = runID,
                errorCode = "runtime_unavailable",
                errorMessage = null,
            )
            return
        }
        val generation = env.generation()
        val token = nextFence()
        mutable.value = mutable.value.copy(
            loading = true,
            busy = false,
            taskID = taskID,
            runID = runID,
            errorCode = null,
            errorMessage = null,
            notice = null,
        )
        job?.cancel()
        job = scope.launch(env.ioDispatcher) {
            val result = runCatching { api.snapshot(taskID, runID) }
            if (!current(token, epoch, generation, taskID)) return@launch
            result.onSuccess { reply ->
                apply(reply, taskID = taskID, runID = runID, notice = null)
            }.onFailure { failure ->
                mutable.value = mutable.value.copy(
                    loading = false,
                    busy = false,
                    loaded = true,
                    errorCode = failure.codeOrNull() ?: "continuityUnavailable",
                    errorMessage = failure.message,
                )
            }
        }
    }

    fun refresh() {
        val taskID = mutable.value.taskID ?: return
        load(taskID, mutable.value.runID)
    }

    /**
     * Bounded reaction to a REAL run persistence refusal surfaced by the
     * existing conversation host. The native probe decides whether storage
     * is actually unavailable; a healthy store creates no marker. This is
     * the only automatic pause trigger and it never resumes or retries.
     */
    fun noteRunStorageFailure(taskID: String, runID: String) {
        if (taskID.isBlank() || runID.isBlank()) return
        if (env.isTemporary(taskID)) return
        if (mutable.value.busy || mutable.value.loading) return
        val epoch = env.nativeRootEpoch() ?: return
        val generation = env.generation()
        val token = nextFence()
        mutable.value = mutable.value.copy(
            loading = false,
            busy = true,
            taskID = taskID,
            runID = runID,
            errorCode = null,
            errorMessage = null,
            notice = null,
        )
        job?.cancel()
        job = scope.launch(env.ioDispatcher) {
            val result = runCatching { api.checkStorage(taskID, runID) }
            if (!current(token, epoch, generation, taskID)) return@launch
            result.onSuccess { reply ->
                val notice = if (reply.pauseRecorded == true) "storagePaused" else null
                apply(reply, taskID = taskID, runID = runID, notice = notice)
            }.onFailure { failure ->
                mutable.value = mutable.value.copy(
                    busy = false,
                    errorCode = failure.codeOrNull() ?: "continuityUnavailable",
                    errorMessage = failure.message,
                )
            }
        }
    }

    /** A bounded probe triggered by an explicit user refresh or a real App
     *  storage error observer. It never runs on a timer and never resumes. */
    fun checkStorage() {
        val taskID = mutable.value.taskID ?: return
        val runID = mutable.value.runID ?: return
        if (env.isTemporary(taskID)) return
        val epoch = env.nativeRootEpoch() ?: return
        val generation = env.generation()
        val token = nextFence()
        mutable.value = mutable.value.copy(
            busy = true, errorCode = null, errorMessage = null, notice = null)
        job?.cancel()
        job = scope.launch(env.ioDispatcher) {
            val result = runCatching { api.checkStorage(taskID, runID) }
            if (!current(token, epoch, generation, taskID)) return@launch
            result.onSuccess { reply ->
                val notice = if (reply.pauseRecorded == true) "storagePaused" else null
                apply(reply, taskID = taskID, runID = runID, notice = notice)
            }.onFailure { failure ->
                mutable.value = mutable.value.copy(
                    busy = false,
                    errorCode = failure.codeOrNull() ?: "continuityUnavailable",
                    errorMessage = failure.message,
                )
            }
        }
    }

    /** The ONE explicit Resume action from the continuity sheet. */
    fun resume() {
        val current = mutable.value
        if (!TaskContinuityPresentation.canResume(current)) return
        val pause = current.pause ?: return
        val taskID = current.taskID ?: return
        val runID = current.runID ?: return
        if (env.isTemporary(taskID)) return
        val epoch = env.nativeRootEpoch() ?: return
        val generation = env.generation()
        val token = nextFence()
        mutable.value = current.copy(
            busy = true, errorCode = null, errorMessage = null, notice = null)
        job?.cancel()
        job = scope.launch(env.ioDispatcher) {
            val result = runCatching {
                api.resume(
                    taskID = taskID,
                    runID = runID,
                    markerID = pause.markerID,
                    expectedRootEpoch = epoch,
                    expectedTargetRevision = pause.targetRevision,
                )
            }
            if (!current(token, epoch, generation, taskID)) return@launch
            result.onSuccess { reply ->
                val marker = reply.marker
                val updatedPause = marker ?: pause.copy(
                    state = TaskContinuityPauseStateUi.RESUMED)
                mutable.value = mutable.value.copy(
                    busy = false,
                    pause = updatedPause,
                    notice = if (reply.requiresReconciliation) {
                        "resumedWithReconciliation"
                    } else {
                        "resumed"
                    },
                )
            }.onFailure { failure ->
                mutable.value = mutable.value.copy(
                    busy = false,
                    errorCode = failure.codeOrNull() ?: "resumeRejected",
                    errorMessage = failure.message,
                )
            }
        }
    }

    fun dismissError() {
        mutable.value = mutable.value.copy(errorCode = null, errorMessage = null)
    }

    fun dismissNotice() {
        mutable.value = mutable.value.copy(notice = null)
    }

    /** Root retirement / real navigation: a late reply can never apply. */
    fun release() {
        fence += 1
        job?.cancel()
        job = null
        mutable.value = TaskContinuityUiState()
    }

    private fun apply(
        reply: TaskContinuitySnapshotWire,
        taskID: String,
        runID: String?,
        notice: String?,
    ) {
        mutable.value = reply.state.copy(
            loading = false,
            busy = false,
            loaded = true,
            taskID = reply.state.taskID ?: taskID,
            runID = reply.state.runID ?: runID,
            errorCode = null,
            errorMessage = null,
            notice = notice,
        )
    }

    private fun nextFence(): Long {
        fence += 1
        return fence
    }

    private fun current(
        token: Long,
        epoch: Long,
        generation: Long,
        taskID: String,
    ): Boolean =
        token == fence &&
            env.nativeRootEpoch() == epoch &&
            env.generation() == generation &&
            env.isTemporary(taskID) != true
}

internal fun Throwable.codeOrNull(): String? =
    (this as? TaskContinuityFailure)?.code
