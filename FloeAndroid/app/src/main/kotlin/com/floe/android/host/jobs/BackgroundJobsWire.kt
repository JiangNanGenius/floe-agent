// SPDX-License-Identifier: MPL-2.0
//
// Trusted App transport for THIS task's finite background jobs
// (`floe.taskjobs/30`, BridgeV30) over the EXISTING `floe_bridge_exchange`
// C ABI. Closed actions only:
//
//   jobs.list   {conversationID, runID?}
//   jobs.cancel {conversationID, runID, jobID}
//
// The native owner answers with bounded durable projections. This codec never
// synthesizes a state, never turns a cancellation request into a terminal and
// rejects any reply whose identity/state vocabulary is outside the closed set.
package com.floe.android.host.jobs

import com.floe.android.feature.conversation.BackgroundJobUi
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import java.util.UUID

internal object BackgroundJobsWire {
    const val VERSION = 30
    const val SCHEMA = "floe.taskjobs/30"
    const val ACTION_LIST = "jobs.list"
    const val ACTION_CANCEL = "jobs.cancel"
    const val MAX_JOBS = 50
    const val MAX_REQUEST_BYTES = 65_536

    private val json = Json { isLenient = false; ignoreUnknownKeys = true }

    internal data class Snapshot(
        val jobs: List<BackgroundJobUi>,
        val truncated: Boolean,
        /** Typed native error code, or null on success. */
        val error: String?,
    )

    fun listRequest(requestID: String, epoch: Long, conversationID: String): String {
        require(epoch > 0) { "epoch must be positive" }
        return buildJsonObject {
            put("version", VERSION)
            put("operation", "command")
            put("requestID", requestID)
            put("epoch", epoch)
            put("action", ACTION_LIST)
            put("payload", buildJsonObject { put("conversationID", conversationID) })
        }.toString()
    }

    fun cancelRequest(
        requestID: String,
        epoch: Long,
        conversationID: String,
        runID: String,
        jobID: String,
    ): String {
        require(epoch > 0) { "epoch must be positive" }
        return buildJsonObject {
            put("version", VERSION)
            put("operation", "command")
            put("requestID", requestID)
            put("epoch", epoch)
            put("action", ACTION_CANCEL)
            put(
                "payload",
                buildJsonObject {
                    put("conversationID", conversationID)
                    put("runID", runID)
                    put("jobID", jobID)
                },
            )
        }.toString()
    }

    /** Strict, bounded decode. A malformed reply is a typed failure. */
    fun parse(raw: String): Snapshot = try {
        parseResponse(raw)
    } catch (_: Exception) {
        Snapshot(emptyList(), false, "invalidResponse")
    }

    private fun parseResponse(raw: String): Snapshot {
        val root = try {
            json.parseToJsonElement(raw).jsonObject
        } catch (_: Exception) {
            return Snapshot(emptyList(), false, "invalidResponse")
        }
        if (root["ok"]?.jsonPrimitive?.booleanOrNull != true) {
            return Snapshot(emptyList(), false, boundedCode(root["error"]?.jsonPrimitive?.contentOrNull))
        }
        if (root["schema"]?.jsonPrimitive?.contentOrNull != SCHEMA) {
            return Snapshot(emptyList(), false, "invalidResponse")
        }
        val array = try {
            root["jobs"]?.jsonArray
        } catch (_: Exception) {
            null
        } ?: return Snapshot(emptyList(), false, "invalidResponse")
        if (array.size > MAX_JOBS) return Snapshot(emptyList(), false, "invalidResponse")
        val jobs = try {
            array.mapNotNull { element ->
                val value = element as? JsonObject ?: return@mapNotNull null
                val jobID = canonicalIdentity(value["jobID"]?.jsonPrimitive?.contentOrNull)
                    ?: return@mapNotNull null
                val runID = canonicalIdentity(value["runID"]?.jsonPrimitive?.contentOrNull)
                    ?: return@mapNotNull null
                val state = value["state"]?.jsonPrimitive?.contentOrNull
                    ?: return@mapNotNull null
                if (state !in JOB_STATES) return@mapNotNull null
                val target = value["target"]?.jsonPrimitive?.contentOrNull
                    ?.takeIf { it in TARGET_KINDS } ?: "other"
                val terminal = value["terminal"]?.jsonPrimitive?.booleanOrNull
                    ?: return@mapNotNull null
                if (terminal != (state in TERMINAL_STATES)) return@mapNotNull null
                val cancellationRequested =
                    value["cancellationRequested"]?.jsonPrimitive?.booleanOrNull ?: false
                val resultAvailable =
                    value["resultAvailable"]?.jsonPrimitive?.booleanOrNull ?: false
                val progress = value["progress"] as? JsonObject
                val dependency = value["dependency"] as? JsonObject
                val dependencyKind = boundedString(
                    dependency?.get("kind")?.jsonPrimitive?.contentOrNull, 16)
                val dependencyState = boundedString(
                    dependency?.get("state")?.jsonPrimitive?.contentOrNull, 16)
                BackgroundJobUi(
                    jobId = jobID,
                    runId = runID,
                    targetKind = target,
                    stateName = state,
                    terminal = terminal,
                    cancellationRequested = cancellationRequested,
                    resultAvailable = resultAvailable,
                    outputBytes = value["outputBytes"]?.jsonPrimitive?.longOrNull
                        ?.takeIf { it >= 0 },
                    progressStage = boundedString(
                        progress?.get("stage")?.jsonPrimitive?.contentOrNull, 24),
                    completedUnits = progress?.get("completedUnits")?.jsonPrimitive?.intOrNull
                        ?.takeIf { it >= 0 },
                    totalUnits = progress?.get("totalUnits")?.jsonPrimitive?.intOrNull
                        ?.takeIf { it > 0 },
                    dependencyKind = dependencyKind?.takeIf { it == "job" || it == "service" },
                    dependencyState = dependencyState?.takeIf { it in DEPENDENCY_STATES },
                )
            }
        } catch (_: Exception) {
            return Snapshot(emptyList(), false, "invalidResponse")
        }
        if (jobs.size != array.size) return Snapshot(emptyList(), false, "invalidResponse")
        return Snapshot(
            jobs = jobs,
            truncated = root["truncated"]?.jsonPrimitive?.booleanOrNull ?: false,
            error = null,
        )
    }

    private fun canonicalIdentity(value: String?): String? {
        val text = boundedString(value, 64) ?: return null
        val canonical = runCatching { UUID.fromString(text).toString() }.getOrNull()
            ?: return null
        return text.takeIf { it.equals(canonical, ignoreCase = true) }
    }

    private fun boundedString(value: String?, limit: Int): String? {
        val trimmed = value?.trim() ?: return null
        if (trimmed.isEmpty() || trimmed.length > limit) return null
        return trimmed
    }

    private fun boundedCode(code: String?): String {
        val trimmed = code?.trim() ?: return "jobsUnavailable"
        if (trimmed.isEmpty() || trimmed.length > 64) return "jobsUnavailable"
        return if (trimmed.all { it.isLetterOrDigit() || it == '.' || it == '_' || it == '-' }) {
            trimmed
        } else {
            "jobsUnavailable"
        }
    }

    private val TARGET_KINDS = setOf("shell", "web", "officeEdit", "service", "other")
    private val JOB_STATES = setOf(
        "queued", "running", "completed", "failed", "cancelled", "interrupted",
    )
    private val TERMINAL_STATES = setOf("completed", "failed", "cancelled", "interrupted")
    private val DEPENDENCY_STATES = setOf(
        "pending", "resolved", "failed", "cancelled", "interrupted",
    )
}
