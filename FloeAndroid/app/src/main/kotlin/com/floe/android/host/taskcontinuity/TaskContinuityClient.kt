// SPDX-License-Identifier: MPL-2.0
//
// C02 client for the reserved trusted-host `floe.continuity/21` channel.
// Every request is built from trusted task/run/marker identities and an
// explicit user intent; no question/approval text, model output, path or
// secret is ever sent on this channel.
package com.floe.android.host.taskcontinuity

import java.util.UUID
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put

internal interface TaskContinuityApi {
    fun snapshot(taskID: String, runID: String?): TaskContinuitySnapshotWire
    fun checkStorage(taskID: String, runID: String): TaskContinuitySnapshotWire
    fun pause(
        taskID: String,
        runID: String,
        reason: String? = null,
    ): TaskContinuityPauseWire
    fun resume(
        taskID: String,
        runID: String,
        markerID: String,
        expectedRootEpoch: Long,
        expectedTargetRevision: Long?,
    ): TaskContinuityResumeWire
}

internal data class TaskContinuityPauseWire(
    val pause: com.floe.android.feature.taskcontinuity.TaskContinuityPauseUi,
    val runCheckpointed: Boolean,
    val storage: com.floe.android.feature.taskcontinuity.TaskContinuityStorageUi,
)

internal class TaskContinuityClient(
    private val transport: TaskContinuityTransport = SwiftTaskContinuityTransport,
) : TaskContinuityApi {

    override fun snapshot(taskID: String, runID: String?): TaskContinuitySnapshotWire {
        val response = exchange("continuity.snapshot") {
            put("taskID", taskID)
            if (runID != null) put("runID", runID)
        }
        return TaskContinuityJson.parseSnapshot(response)
    }

    override fun checkStorage(taskID: String, runID: String): TaskContinuitySnapshotWire {
        val response = exchange("continuity.storage.check") {
            put("taskID", taskID)
            put("runID", runID)
        }
        return TaskContinuityJson.parseSnapshot(response)
    }

    override fun pause(
        taskID: String,
        runID: String,
        reason: String?,
    ): TaskContinuityPauseWire {
        val response = exchange("continuity.pause") {
            put("taskID", taskID)
            put("runID", runID)
            if (reason != null) put("reason", reason)
        }
        val pause = response.objectValue("pause")?.let(TaskContinuityJson::parsePause)
            ?: throw TaskContinuityFailure(
                "malformedResponse", "The pause reply was unreadable.")
        val storage = response.objectValue("storage")
            ?.let(TaskContinuityJson::parseStorage)
            ?: throw TaskContinuityFailure(
                "malformedResponse", "The pause reply was unreadable.")
        return TaskContinuityPauseWire(
            pause = pause,
            runCheckpointed = response.bool("runCheckpointed") ?: false,
            storage = storage,
        )
    }

    override fun resume(
        taskID: String,
        runID: String,
        markerID: String,
        expectedRootEpoch: Long,
        expectedTargetRevision: Long?,
    ): TaskContinuityResumeWire {
        val response = exchange("continuity.resume") {
            put("taskID", taskID)
            put("runID", runID)
            put("markerID", markerID)
            put("expectedRootEpoch", expectedRootEpoch)
            if (expectedTargetRevision != null) {
                put("expectedTargetRevision", expectedTargetRevision)
            }
            // The ONLY source of this flag is the explicit Resume tap in
            // the task-continuity sheet. It is never inferred from a route,
            // notification or model decision.
            put("explicitUserAction", true)
        }
        return TaskContinuityJson.parseResume(response)
    }

    private fun exchange(
        operation: String,
        payload: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit,
    ): JsonObject {
        val request = buildJsonObject {
            put("version", C02_CONTINUITY_VERSION)
            put("schema", C02_CONTINUITY_SCHEMA)
            put("operation", operation)
            put("requestID", UUID.randomUUID().toString())
            this.payload()
        }
        val raw = transport.exchange(request.toString())
        val response = runCatching {
            TaskContinuityJson.json.parseToJsonElement(raw).jsonObject
        }.getOrElse {
            throw TaskContinuityFailure(
                "malformedResponse", "The continuity reply was unreadable.")
        }
        throwIfNotOk(response)
        return response
    }
}
