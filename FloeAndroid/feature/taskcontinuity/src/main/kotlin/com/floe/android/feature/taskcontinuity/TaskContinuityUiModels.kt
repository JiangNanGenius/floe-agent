// SPDX-License-Identifier: MPL-2.0
//
// C02 durable task continuity presentation models.
//
// The values here are a READ-ONLY projection of the trusted `floe.continuity/21`
// channel. The UI never invents a pause, a resume, a question answer or an
// approval decision; it only shows the native marker and routes the explicit
// user action back to the App-owned controller.
package com.floe.android.feature.taskcontinuity

enum class TaskContinuityStorageConditionUi {
    READY,
    PERMISSION_REVOKED,
    VOLUME_MISSING,
    VOLUME_READ_ONLY,
    VOLUME_FULL,
    DATABASE_UNAVAILABLE,
    UNKNOWN;

    val isReady: Boolean get() = this == READY

    companion object {
        fun from(raw: String?): TaskContinuityStorageConditionUi = when (raw) {
            "ready" -> READY
            "permissionRevoked" -> PERMISSION_REVOKED
            "volumeMissing" -> VOLUME_MISSING
            "volumeReadOnly" -> VOLUME_READ_ONLY
            "volumeFull" -> VOLUME_FULL
            "databaseUnavailable" -> DATABASE_UNAVAILABLE
            else -> UNKNOWN
        }
    }
}

enum class TaskContinuityPauseReasonUi {
    PERMISSION_REVOKED,
    VOLUME_MISSING,
    VOLUME_READ_ONLY,
    VOLUME_FULL,
    DATABASE_UNAVAILABLE;

    val messageRes: Int
        get() = when (this) {
            PERMISSION_REVOKED -> R.string.taskcontinuity_reason_permission
            VOLUME_MISSING -> R.string.taskcontinuity_reason_missing
            VOLUME_READ_ONLY -> R.string.taskcontinuity_reason_readonly
            VOLUME_FULL -> R.string.taskcontinuity_reason_full
            DATABASE_UNAVAILABLE -> R.string.taskcontinuity_reason_database
        }

    companion object {
        fun from(raw: String?): TaskContinuityPauseReasonUi? = when (raw) {
            "permissionRevoked" -> PERMISSION_REVOKED
            "volumeMissing" -> VOLUME_MISSING
            "volumeReadOnly" -> VOLUME_READ_ONLY
            "volumeFull" -> VOLUME_FULL
            "databaseUnavailable" -> DATABASE_UNAVAILABLE
            else -> null
        }
    }
}

enum class TaskContinuityPauseStateUi {
    AWAITING_STORAGE_RECOVERY,
    RESUME_IN_PROGRESS,
    RESUME_FAILED,
    RESUMED;

    val isActionable: Boolean
        get() = this == AWAITING_STORAGE_RECOVERY || this == RESUME_FAILED

    companion object {
        fun from(raw: String?): TaskContinuityPauseStateUi = when (raw) {
            "resumeInProgress" -> RESUME_IN_PROGRESS
            "resumeFailed" -> RESUME_FAILED
            "resumed" -> RESUMED
            else -> AWAITING_STORAGE_RECOVERY
        }
    }
}

enum class TaskContinuityDurabilityUi {
    TASK_DATABASE,
    RECOVERY_METADATA,
    MEMORY_ONLY;

    companion object {
        fun from(raw: String?): TaskContinuityDurabilityUi = when (raw) {
            "recoveryMetadata" -> RECOVERY_METADATA
            "memoryOnly" -> MEMORY_ONLY
            else -> TASK_DATABASE
        }
    }
}

enum class TaskContinuityWaitKindUi {
    QUESTION,
    APPROVAL;

    companion object {
        fun from(raw: String?): TaskContinuityWaitKindUi =
            if (raw == "approval") APPROVAL else QUESTION
    }
}

data class TaskContinuityStorageUi(
    val condition: TaskContinuityStorageConditionUi = TaskContinuityStorageConditionUi.UNKNOWN,
    val isReady: Boolean = false,
    val availableBytes: Long? = null,
    val detailCode: String? = null,
) {
    val conditionLabelRes: Int
        get() = when (condition) {
            TaskContinuityStorageConditionUi.READY -> R.string.taskcontinuity_storage_ready
            TaskContinuityStorageConditionUi.PERMISSION_REVOKED ->
                R.string.taskcontinuity_storage_permission
            TaskContinuityStorageConditionUi.VOLUME_MISSING ->
                R.string.taskcontinuity_storage_missing
            TaskContinuityStorageConditionUi.VOLUME_READ_ONLY ->
                R.string.taskcontinuity_storage_readonly
            TaskContinuityStorageConditionUi.VOLUME_FULL ->
                R.string.taskcontinuity_storage_full
            TaskContinuityStorageConditionUi.DATABASE_UNAVAILABLE ->
                R.string.taskcontinuity_storage_database
            TaskContinuityStorageConditionUi.UNKNOWN ->
                R.string.taskcontinuity_storage_unknown
        }
}

data class TaskContinuityPauseUi(
    val markerID: String,
    val taskID: String,
    val runID: String,
    val rootEpoch: Long,
    val reason: TaskContinuityPauseReasonUi?,
    val state: TaskContinuityPauseStateUi,
    val durability: TaskContinuityDurabilityUi,
    val detectedAtLabel: String,
    val updatedAtLabel: String,
    val resumeAttempt: Int,
    val runCheckpointed: Boolean,
    val unknownOutcomeCount: Int,
    val explicitResumeOnly: Boolean,
    val targetRevision: Long?,
    val environmentID: String?,
    val detailCode: String?,
) {
    val isActionable: Boolean get() = state.isActionable
    val isInProgress: Boolean get() = state == TaskContinuityPauseStateUi.RESUME_IN_PROGRESS
    val isResumed: Boolean get() = state == TaskContinuityPauseStateUi.RESUMED
}

data class TaskContinuityWaitUi(
    val waitID: String,
    val kind: TaskContinuityWaitKindUi,
    val rootEpoch: Long,
    val taskID: String,
    val runID: String,
    val toolCallID: String,
    val requestID: String,
    val itemID: String,
    val revision: Int,
    val prompt: String,
    val promptTruncated: Boolean,
    val waitPolicy: String,
    val answerableNow: Boolean,
    val requiresResume: Boolean,
    val deadlineLabel: String?,
    val requestDigest: String?,
    val answerNonce: String?,
    val approvalVersion: String?,
    val runState: String,
) {
    val isQuestion: Boolean get() = kind == TaskContinuityWaitKindUi.QUESTION
    val isApproval: Boolean get() = kind == TaskContinuityWaitKindUi.APPROVAL

    /** Stable list/detail identity; never a question/approval answer. */
    val key: String get() = "$kind/$runID/$itemID/$revision"
}

enum class TaskContinuityWaitAction {
    /// The original question sheet can answer this live question.
    REVIEW_QUESTION,
    /// The live approval card in the timeline owns the decision.
    REVIEW_APPROVAL,
    /// No live owner: the task must be resumed first.
    RESUME_TASK,
    /// Already settled or otherwise not actionable; show read-only detail.
    READ_ONLY,
}

data class TaskContinuityUiState(
    val loading: Boolean = false,
    val busy: Boolean = false,
    val loaded: Boolean = false,
    val taskID: String? = null,
    val runID: String? = null,
    val rootEpoch: Long = 0L,
    val storage: TaskContinuityStorageUi = TaskContinuityStorageUi(),
    val pause: TaskContinuityPauseUi? = null,
    val waits: List<TaskContinuityWaitUi> = emptyList(),
    val waitsTruncated: Boolean = false,
    val waitsUnavailable: Boolean = false,
    val unknownOutcomeCount: Int = 0,
    val errorCode: String? = null,
    val errorMessage: String? = null,
    val notice: String? = null,
) {
    val requiresResume: Boolean
        get() = pause?.isActionable == true || waits.any { it.requiresResume }

    val pendingWaitCount: Int
        get() = waits.size
}

object TaskContinuityPresentation {
    /** The explicit Resume action is only offered for the exact actionable
     *  marker, a ready storage probe and no in-flight request. The native
     *  CAS remains the final authority; this is UI gating only. */
    fun canResume(state: TaskContinuityUiState): Boolean =
        !state.loading && !state.busy &&
            state.pause?.isActionable == true &&
            state.storage.isReady

    fun shouldShowBanner(state: TaskContinuityUiState): Boolean =
        (state.pause != null && !state.pause.isResumed) ||
            state.waits.any { it.requiresResume }

    fun waitAction(wait: TaskContinuityWaitUi): TaskContinuityWaitAction = when {
        wait.requiresResume -> TaskContinuityWaitAction.RESUME_TASK
        wait.answerableNow && wait.isQuestion -> TaskContinuityWaitAction.REVIEW_QUESTION
        wait.answerableNow && wait.isApproval -> TaskContinuityWaitAction.REVIEW_APPROVAL
        else -> TaskContinuityWaitAction.READ_ONLY
    }

    /** A duplicate/late wait from a different task/run/root is never shown. */
    fun accepts(
        wait: TaskContinuityWaitUi,
        taskID: String,
        runID: String?,
        rootEpoch: Long,
    ): Boolean = wait.taskID == taskID &&
        (runID == null || wait.runID == runID) &&
        wait.rootEpoch == rootEpoch

    /** Bounded one-line preview; the sheet keeps the complete bounded text. */
    fun waitPreview(wait: TaskContinuityWaitUi, maxCharacters: Int = 160): String {
        if (wait.prompt.length <= maxCharacters) return wait.prompt
        return wait.prompt.take((maxCharacters - 1).coerceAtLeast(1)) + "\u2026"
    }
}
