// SPDX-License-Identifier: MPL-2.0
//
// C02 trusted-host values for `floe.continuity/21`.
//
// Bounded JSON only. The parser accepts the closed native schema and never
// invents a marker, wait, answer or resume receipt. Unknown fields are
// ignored for forward-compatible reads, but every authority-bearing value is
// read from the exact typed member.
package com.floe.android.host.taskcontinuity

import com.floe.android.bridge.SwiftCore
import com.floe.android.feature.taskcontinuity.TaskContinuityDurabilityUi
import com.floe.android.feature.taskcontinuity.TaskContinuityPauseReasonUi
import com.floe.android.feature.taskcontinuity.TaskContinuityPauseStateUi
import com.floe.android.feature.taskcontinuity.TaskContinuityPauseUi
import com.floe.android.feature.taskcontinuity.TaskContinuityStorageConditionUi
import com.floe.android.feature.taskcontinuity.TaskContinuityStorageUi
import com.floe.android.feature.taskcontinuity.TaskContinuityUiState
import com.floe.android.feature.taskcontinuity.TaskContinuityWaitKindUi
import com.floe.android.feature.taskcontinuity.TaskContinuityWaitUi
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull

internal const val C02_CONTINUITY_VERSION = 21
internal const val C02_CONTINUITY_SCHEMA = "floe.continuity/21"

internal fun interface TaskContinuityTransport {
    fun exchange(request: String): String
}

internal object SwiftTaskContinuityTransport : TaskContinuityTransport {
    override fun exchange(request: String): String = SwiftCore.exchange(request)
}

internal class TaskContinuityFailure(
    val code: String,
    override val message: String,
    val retryable: Boolean = false,
) : Exception(message)

internal data class TaskContinuitySnapshotWire(
    val state: TaskContinuityUiState,
    val pauseRecorded: Boolean? = null,
    val runCheckpointed: Boolean? = null,
)

internal data class TaskContinuityResumeWire(
    val accepted: Boolean,
    val resumed: Boolean,
    val requiresReconciliation: Boolean,
    val marker: TaskContinuityPauseUi?,
)

internal object TaskContinuityJson {
    val json = Json { ignoreUnknownKeys = true; isLenient = false }

    fun parseSnapshot(root: JsonObject): TaskContinuitySnapshotWire {
        val taskID = root.string("taskID")
            ?: throw TaskContinuityFailure("malformedResponse", "The continuity reply was unreadable.")
        val storage = root.objectValue("storage")?.let(::parseStorage)
            ?: TaskContinuityStorageUi()
        val pause = root.objectValue("pause")?.let(::parsePause)
        val waits = root.arrayValue("waits").mapNotNull { element ->
            (element as? JsonObject)?.let(::parseWait)
        }
        return TaskContinuitySnapshotWire(
            state = TaskContinuityUiState(
                loading = false,
                busy = false,
                loaded = true,
                taskID = taskID,
                runID = root.string("runID"),
                rootEpoch = root.long("rootEpoch") ?: 0L,
                storage = storage,
                pause = pause,
                waits = waits,
                waitsTruncated = root.bool("waitsTruncated") ?: false,
                waitsUnavailable = root.bool("waitsUnavailable") ?: false,
                unknownOutcomeCount = root.int("unknownOutcomeCount") ?: 0,
            ),
            pauseRecorded = root.bool("pauseRecorded"),
            runCheckpointed = root.bool("runCheckpointed"),
        )
    }

    fun parsePause(root: JsonObject): TaskContinuityPauseUi? {
        val markerID = root.string("markerID") ?: return null
        val taskID = root.string("taskID") ?: return null
        val runID = root.string("runID") ?: return null
        return TaskContinuityPauseUi(
            markerID = markerID,
            taskID = taskID,
            runID = runID,
            rootEpoch = root.long("rootEpoch") ?: 0L,
            reason = TaskContinuityPauseReasonUi.from(root.string("reason")),
            state = TaskContinuityPauseStateUi.from(root.string("state")),
            durability = TaskContinuityDurabilityUi.from(root.string("durability")),
            detectedAtLabel = root.string("detectedAt") ?: "",
            updatedAtLabel = root.string("updatedAt") ?: "",
            resumeAttempt = root.int("resumeAttempt") ?: 0,
            runCheckpointed = root.bool("runCheckpointed") ?: false,
            unknownOutcomeCount = root.int("unknownOutcomeCount") ?: 0,
            explicitResumeOnly = root.bool("explicitResumeOnly") ?: true,
            targetRevision = root.long("targetRevision"),
            environmentID = root.string("environmentID"),
            detailCode = root.string("detailCode"),
        )
    }

    fun parseStorage(root: JsonObject): TaskContinuityStorageUi =
        TaskContinuityStorageUi(
            condition = TaskContinuityStorageConditionUi.from(root.string("condition")),
            isReady = root.bool("isReady") ?: false,
            availableBytes = root.long("availableBytes"),
            detailCode = root.string("detailCode"),
        )

    private fun parseWait(root: JsonObject): TaskContinuityWaitUi? {
        val waitID = root.string("waitID") ?: return null
        val taskID = root.string("taskID") ?: return null
        val runID = root.string("runID") ?: return null
        val itemID = root.string("itemID") ?: return null
        return TaskContinuityWaitUi(
            waitID = waitID,
            kind = TaskContinuityWaitKindUi.from(root.string("kind")),
            rootEpoch = root.long("rootEpoch") ?: 0L,
            taskID = taskID,
            runID = runID,
            toolCallID = root.string("toolCallID") ?: return null,
            requestID = root.string("requestID") ?: return null,
            itemID = itemID,
            revision = root.int("revision") ?: 1,
            prompt = root.string("prompt") ?: "",
            promptTruncated = root.bool("promptTruncated") ?: false,
            waitPolicy = root.string("waitPolicy") ?: "required",
            answerableNow = root.bool("answerableNow") ?: false,
            requiresResume = root.bool("requiresResume") ?: true,
            deadlineLabel = root.string("deadlineAt"),
            requestDigest = root.string("requestDigest"),
            answerNonce = root.string("answerNonce"),
            approvalVersion = root.string("approvalVersion"),
            runState = root.string("runState") ?: "unknown",
        )
    }

    fun parseResume(root: JsonObject): TaskContinuityResumeWire {
        val accepted = root.bool("accepted") ?: false
        if (!accepted) {
            throw TaskContinuityFailure(
                code = root.string("code") ?: "resumeRejected",
                message = root.string("message")
                    ?: "The task could not be resumed.",
                retryable = root.bool("retryable") ?: false,
            )
        }
        return TaskContinuityResumeWire(
            accepted = true,
            resumed = root.bool("resumed") ?: false,
            requiresReconciliation = root.bool("requiresReconciliation") ?: false,
            marker = root.objectValue("marker")?.let(::parsePause),
        )
    }
}

internal fun JsonObject.string(key: String): String? =
    (this[key] as? JsonPrimitive)?.contentOrNull?.takeIf { it != "null" }

internal fun JsonObject.bool(key: String): Boolean? =
    (this[key] as? JsonPrimitive)?.booleanOrNull

internal fun JsonObject.int(key: String): Int? =
    (this[key] as? JsonPrimitive)?.intOrNull

internal fun JsonObject.long(key: String): Long? =
    (this[key] as? JsonPrimitive)?.longOrNull

internal fun JsonObject.objectValue(key: String): JsonObject? =
    when (val value = this[key]) {
        is JsonObject -> value
        else -> null
    }

internal fun JsonObject.arrayValue(key: String): JsonArray =
    this[key] as? JsonArray ?: JsonArray(emptyList())

internal fun taskContinuityFailure(raw: String): TaskContinuityFailure {
    val root = runCatching {
        TaskContinuityJson.json.parseToJsonElement(raw) as? JsonObject
    }.getOrNull()
        ?: return TaskContinuityFailure(
            "malformedResponse", "The continuity reply was unreadable.")
    val ok = root.bool("ok") ?: false
    if (ok) {
        return TaskContinuityFailure(
            "malformedResponse", "The continuity reply was unreadable.")
    }
    return TaskContinuityFailure(
        code = root.string("code") ?: "continuityFailure",
        message = root.string("message") ?: "The continuity request failed.",
        retryable = root.bool("retryable") ?: false,
    )
}

internal fun throwIfNotOk(root: JsonObject) {
    if (root.bool("ok") == false) {
        throw TaskContinuityFailure(
            code = root.string("code") ?: "continuityFailure",
            message = root.string("message") ?: "The continuity request failed.",
            retryable = root.bool("retryable") ?: false,
        )
    }
}

/** `null` is meaningful for optional members; this keeps it out of the
 *  parser's return values without inventing a string. */
internal fun JsonElement?.isNullish(): Boolean = this == null || this is JsonNull
