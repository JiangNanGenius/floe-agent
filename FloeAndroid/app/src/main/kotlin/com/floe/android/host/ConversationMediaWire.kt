// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/**
 * Trusted App transport for the conversation-owned media refresh lane
 * (`floe.agentmedia/28`, BridgeV28) over the EXISTING `floe_bridge_exchange`
 * C ABI (`SwiftCore.exchange`). This is NOT a BridgeV3 command and NOT a
 * model tool: the single closed action `media.jobs.refresh` asks the native
 * owner to reconcile THIS conversation's durable media jobs (restart bounded
 * poll workers for retained accepted rows; classify lost single-shot rows
 * unknown) and return the re-read durable projections. It never submits,
 * never carries credentials, and grants no file or model authority.
 *
 * Bounds mirror the native channel: request <= 64 KiB, reply <= 48 KiB, at
 * most 50 job projections; anything larger is refused, never truncated. Pure
 * wire codec + one blocking exchange; all ownership decisions stay in the
 * native owner and the host callback.
 */
internal object ConversationMediaWire {
    const val VERSION = 28
    const val SCHEMA = "floe.agentmedia/28"
    const val ACTION_REFRESH = "media.jobs.refresh"
    const val MAX_JOBS = 50

    private val json = Json { isLenient = false; ignoreUnknownKeys = true }

    /** One durable job projection on the refresh wire. */
    internal data class JobSnapshot(
        val jobID: String,
        val state: String,
        val terminated: Boolean,
        val ready: Boolean,
        val mediaKind: String,
        val providerTaskID: String? = null,
        val workspaceRelativePath: String? = null,
        val deliveredByteCount: Long? = null,
        val deliveredSHA256: String? = null,
        val lastError: String? = null,
    )

    /** Refresh outcome: [error] is null on success; [jobs] is bounded. */
    internal data class RefreshResult(
        val jobs: List<JobSnapshot>,
        val error: String?,
    )

    /**
     * Build the exact v28 refresh envelope. [conversationID] must be the
     * canonical UUID string the session token already validated; [epoch] is
     * the accepted native root epoch.
     */
    internal fun refreshRequest(requestID: String, epoch: Long, conversationID: String): String {
        require(epoch > 0) { "epoch must be positive" }
        return buildJsonObject {
            put("version", VERSION)
            put("operation", "command")
            put("requestID", requestID)
            put("epoch", epoch)
            put("action", ACTION_REFRESH)
            put("payload", buildJsonObject { put("conversationID", conversationID) })
        }.toString()
    }

    /**
     * Parse the v28 refresh reply. A malformed reply is a typed error, never
     * a fabricated success; `ok:false` carries the native error code.
     */
    internal fun parseRefreshResponse(raw: String): RefreshResult {
        val root = try {
            json.parseToJsonElement(raw).jsonObject
        } catch (_: Exception) {
            return RefreshResult(emptyList(), "invalidResponse")
        }
        if (root["ok"]?.jsonPrimitive?.booleanOrNull != true) {
            val code = root["error"]?.jsonPrimitive?.contentOrNull
                ?: root["code"]?.jsonPrimitive?.contentOrNull
            return RefreshResult(emptyList(), boundedCode(code) ?: "mediaRefreshFailed")
        }
        val jobs = try {
            root["jobs"]?.jsonArray?.mapNotNull { element ->
                val value = element as? JsonObject ?: return@mapNotNull null
                val jobID = value["jobID"]?.jsonPrimitive?.contentOrNull ?: return@mapNotNull null
                JobSnapshot(
                    jobID = jobID,
                    state = value["state"]?.jsonPrimitive?.contentOrNull ?: "unknown",
                    terminated = value["terminated"]?.jsonPrimitive?.booleanOrNull ?: false,
                    ready = value["ready"]?.jsonPrimitive?.booleanOrNull ?: false,
                    mediaKind = value["mediaKind"]?.jsonPrimitive?.contentOrNull ?: "unknown",
                    providerTaskID = value["providerTaskID"]?.jsonPrimitive?.contentOrNull,
                    workspaceRelativePath = value["workspaceRelativePath"]?.jsonPrimitive?.contentOrNull,
                    deliveredByteCount = value["deliveredByteCount"]?.jsonPrimitive?.longOrNull,
                    deliveredSHA256 = value["deliveredSHA256"]?.jsonPrimitive?.contentOrNull,
                    lastError = value["lastError"]?.jsonPrimitive?.contentOrNull,
                )
            }
        } catch (_: Exception) {
            null
        } ?: return RefreshResult(emptyList(), "invalidResponse")
        return RefreshResult(jobs.take(MAX_JOBS), null)
    }

    private fun boundedCode(code: String?): String? {
        val trimmed = code?.trim()
        if (trimmed.isNullOrEmpty() || trimmed.length > 64) return null
        return if (trimmed.all { it.isLetterOrDigit() || it == '.' || it == '_' || it == '-' }) {
            trimmed
        } else {
            null
        }
    }
}

/**
 * Pure lexical hygiene for a model/user-provided workspace-relative path.
 * This is an early refusal only: the native workspace guard re-validates
 * containment (symlinks included) before any byte is staged. Absolute paths,
 * home aliases, NUL bytes and `..` path segments are refused here so a link
 * can never even enter the staging pipeline. A model relative path never
 * grants authority by itself.
 */
internal object WorkspaceOpenPolicy {
    private const val MAX_PATH_CHARS = 512

    fun relativePathAdmitted(relativePath: String): Boolean {
        if (relativePath.isBlank() || relativePath.length > MAX_PATH_CHARS) return false
        if (relativePath[0] == '/' || relativePath[0] == '\\' ||
            relativePath[0] == '~') return false
        if (relativePath.any { it == '\u0000' }) return false
        return relativePath.split('/', '\\').none { it == ".." }
    }
}
