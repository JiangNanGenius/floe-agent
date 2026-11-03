// SPDX-License-Identifier: MPL-2.0
//
// C02 client for the reserved trusted-host `floe.results/20` channel. Every
// request is built from the task/call identity the UI already owns; no path,
// secret or model text is sent. The Swift domain resolves ownership and
// returns only whole UTF-8 byte windows with the real nextOffset.
package com.floe.android.host.toolresults

import com.floe.android.bridge.SwiftCore
import com.floe.android.feature.toolresults.ToolResultDetailException
import com.floe.android.feature.toolresults.ToolResultDetailSource
import com.floe.android.feature.toolresults.ToolResultIndexRowUi
import com.floe.android.feature.toolresults.ToolResultIndexUi
import com.floe.android.feature.toolresults.ToolResultPageUi
import com.floe.android.feature.toolresults.ToolResultSearchHitUi
import com.floe.android.feature.toolresults.ToolResultSearchUi
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put

internal const val C02_RESULTS_VERSION = 20
internal const val C02_RESULTS_SCHEMA = "floe.results/20"
internal const val C02_RESULTS_DEFAULT_PAGE_BYTES = 12_000
internal const val C02_RESULTS_MAXIMUM_PAGE_BYTES = 32_000

internal fun interface ToolResultTransport {
    fun exchange(request: String): String
}

internal object SwiftToolResultTransport : ToolResultTransport {
    override fun exchange(request: String): String = SwiftCore.exchange(request)
}

internal class ToolResultClient(
    private val transport: ToolResultTransport = SwiftToolResultTransport,
) : ToolResultDetailSource {
    private val json = Json { ignoreUnknownKeys = true; isLenient = false }

    override suspend fun load(
        taskId: String,
        runId: String?,
        callId: String?,
        ref: String?,
        offset: Int,
        maxBytes: Int,
        expectedSHA256: String?,
        temporary: Boolean,
    ): ToolResultPageUi = page(
        taskId = taskId,
        runId = runId,
        callId = callId,
        ref = ref,
        offset = offset,
        maxBytes = maxBytes,
        expectedSHA256 = expectedSHA256,
        temporary = temporary,
    )

    fun page(
        taskId: String,
        runId: String? = null,
        callId: String?,
        ref: String?,
        offset: Int,
        maxBytes: Int = C02_RESULTS_DEFAULT_PAGE_BYTES,
        expectedSHA256: String? = null,
        temporary: Boolean = false,
    ): ToolResultPageUi {
        if (temporary) {
            throw ToolResultDetailException(
                "temporaryTaskRefused",
                "Temporary chats are RAM-only and cannot read persistent tool results.",
            )
        }
        requireUuid(taskId, "taskID")
        if (ref == null && callId.isNullOrBlank()) {
            throw ToolResultDetailException("invalidRequest:refOrCallID", "No tool result was selected.")
        }
        if (ref != null && !isGeneratedRef(ref)) {
            throw ToolResultDetailException("invalidRequest:invalidRef", "The result reference is invalid.")
        }
        if (callId != null &&
            (callId.length > 200 || callId.any { it.code < 0x20 || it.code == 0x7f })
        ) {
            throw ToolResultDetailException("invalidRequest:callID", "The tool-call identity is invalid.")
        }
        if (offset < 0) {
            throw ToolResultDetailException("invalidRequest:negativeOffset", "The page offset is invalid.")
        }
        if (maxBytes !in 1..C02_RESULTS_MAXIMUM_PAGE_BYTES) {
            throw ToolResultDetailException("invalidRequest:pageSize", "The page size is invalid.")
        }
        if (expectedSHA256 != null && !isDigest(expectedSHA256)) {
            throw ToolResultDetailException("invalidRequest:digest", "The expected digest is invalid.")
        }
        val response = exchange("c02.results.page") {
            put("taskID", taskId)
            runId?.let { put("runID", it) }
            ref?.let { put("ref", it) }
            callId?.takeIf { it.isNotBlank() }?.let { put("callID", it) }
            put("offset", offset)
            put("length", maxBytes)
            expectedSHA256?.let { put("expectedSHA256", it) }
            if (runId != null && ref == null) put("exactRun", true)
        }
        return parsePage(response, offset, maxBytes)
    }

    fun index(taskId: String, runId: String? = null, limit: Int = 20): ToolResultIndexUi {
        requireUuid(taskId, "taskID")
        val response = exchange("c02.results.index") {
            put("taskID", taskId)
            runId?.let { put("runID", it) }
            put("limit", limit)
        }
        val rows = response.requireArray("rows").map { element ->
            val row = element as? JsonObject
                ?: throw malformed("The result index contains an invalid row.")
            ToolResultIndexRowUi(
                ref = row.string("ref")
                    ?: throw malformed("The result index row has no reference."),
                runId = row.string("runID")
                    ?: throw malformed("The result index row has no run identity."),
                callId = row.string("callID")
                    ?: throw malformed("The result index row has no call identity."),
                toolName = row.string("toolName")
                    ?: throw malformed("The result index row has no tool name."),
                totalBytes = row.int("totalBytes")
                    ?: throw malformed("The result index row has no size."),
                executionReportedTruncation = row.bool("executionReportedTruncation") ?: false,
                retentionTruncated = row.bool("retentionTruncated") ?: false,
                capturedAt = row.string("capturedAt") ?: "",
                durability = row.string("durability") ?: "unknown",
                sha256 = row.string("sha256")
                    ?: throw malformed("The result index row has no digest."),
                originalDigest = row.string("originalDigest"),
            )
        }
        return ToolResultIndexUi(rows = rows, evicted = response.int("evicted") ?: 0)
    }

    fun search(taskId: String, query: String, limit: Int = 10): ToolResultSearchUi {
        requireUuid(taskId, "taskID")
        if (query.isBlank() || query.toByteArray(Charsets.UTF_8).size > 360) {
            throw ToolResultDetailException("invalidRequest:invalidQuery", "The search text is invalid.")
        }
        val response = exchange("c02.results.search") {
            put("taskID", taskId)
            put("query", query)
            put("limit", limit)
        }
        val hits = response.requireArray("hits").map { element ->
            val hit = element as? JsonObject
                ?: throw malformed("The result search contains an invalid hit.")
            ToolResultSearchHitUi(
                ref = hit.string("ref")
                    ?: throw malformed("The result hit has no reference."),
                runId = hit.string("runID")
                    ?: throw malformed("The result hit has no run identity."),
                callId = hit.string("callID")
                    ?: throw malformed("The result hit has no call identity."),
                toolName = hit.string("toolName")
                    ?: throw malformed("The result hit has no tool name."),
                totalBytes = hit.int("totalBytes")
                    ?: throw malformed("The result hit has no size."),
                matchOffset = hit.int("matchOffset")
                    ?: throw malformed("The result hit has no match offset."),
                excerpt = hit.string("excerpt") ?: "",
                hasAdditionalMatches = hit.bool("hasAdditionalMatches") ?: false,
                sha256 = hit.string("sha256")
                    ?: throw malformed("The result hit has no digest."),
            )
        }
        return ToolResultSearchUi(
            hits = hits,
            searchedCaptures = response.int("searchedCaptures") ?: 0,
            searchedBytes = response.int("searchedBytes") ?: 0,
            truncated = response.bool("truncated") ?: false,
        )
    }

    private fun parsePage(
        response: JsonObject,
        requestedOffset: Int,
        requestedMaxBytes: Int,
    ): ToolResultPageUi {
        val ref = response.string("ref")
            ?: throw malformed("The result reply has no reference.")
        val runId = response.string("runID")
            ?: throw malformed("The result reply has no run identity.")
        val callId = response.string("callID")
            ?: throw malformed("The result reply has no call identity.")
        val toolName = response.string("toolName")
            ?: throw malformed("The result reply has no tool name.")
        val status = response.string("status") ?: ""
        val offset = response.int("offset")
            ?: throw malformed("The result reply has no offset.")
        val endOffset = response.int("endOffset")
            ?: throw malformed("The result reply has no end offset.")
        val totalBytes = response.int("totalBytes")
            ?: throw malformed("The result reply has no total size.")
        val text = response.string("text")
            ?: throw malformed("The result reply has no text.")
        val sha = response.string("sha256")
            ?: throw malformed("The result reply has no digest.")
        if (!isDigest(sha)) throw malformed("The result digest is invalid.")
        val next = response.int("nextOffset")
        val bytes = text.toByteArray(Charsets.UTF_8)
        if (offset != requestedOffset && requestedOffset >= 0) {
            // The UI always continues from the previous actual nextOffset.
            // A different start means the host/UI cursor drifted.
            throw ToolResultDetailException(
                "cursorMismatch",
                "The reply started at $offset but the requested offset was $requestedOffset.",
            )
        }
        if (endOffset < offset || endOffset - offset != bytes.size) {
            throw malformed("The result byte window is inconsistent.")
        }
        if (requestedMaxBytes <= 0 || bytes.size > requestedMaxBytes) {
            throw malformed("The result page exceeded the requested size.")
        }
        if (totalBytes < endOffset) {
            throw malformed("The result size is smaller than the delivered window.")
        }
        if (next != null && next != endOffset) {
            throw malformed("nextOffset does not equal endOffset.")
        }
        if (next != null && next <= offset) {
            throw malformed("The result cursor did not advance.")
        }
        if (next != null && endOffset >= totalBytes) {
            throw malformed("A completed result advertised another page.")
        }
        if (next == null && endOffset < totalBytes) {
            throw malformed("The result page ended before the retained output.")
        }
        return ToolResultPageUi(
            ref = ref,
            runId = runId,
            callId = callId,
            toolName = toolName,
            status = status,
            offset = offset,
            endOffset = endOffset,
            nextOffset = next,
            totalBytes = totalBytes,
            text = text,
            sha256 = sha,
            originalDigest = response.string("originalDigest"),
            executionReportedTruncation = response.bool("executionReportedTruncation") ?: false,
            retentionTruncated = response.bool("retentionTruncated") ?: false,
            durability = response.string("durability") ?: "unknown",
            restoredFromDisk = response.bool("restoredFromDisk") ?: false,
            evictedCopies = response.int("evictedCopies") ?: 0,
        )
    }

    private fun exchange(
        operation: String,
        payload: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit,
    ): JsonObject {
        val request = buildJsonObject {
            put("version", C02_RESULTS_VERSION)
            put("schema", C02_RESULTS_SCHEMA)
            put("operation", operation)
            put("requestID", UUID.randomUUID().toString())
            this.payload()
        }
        val raw = transport.exchange(request.toString())
        val response = runCatching { json.parseToJsonElement(raw).jsonObject }
            .getOrElse { throw malformed("The result reply was unreadable.") }
        if (response.bool("ok") != true) {
            val code = response.string("code") ?: "toolResultFailure"
            val message = response.string("message") ?: "The result read failed."
            throw ToolResultDetailException(
                code = code,
                message = message,
                retryable = response.bool("retryable") ?: false,
            )
        }
        return response
    }

    private fun requireUuid(value: String, field: String) {
        if (runCatching { UUID.fromString(value) }.isFailure) {
            throw ToolResultDetailException("invalidRequest:$field", "The task identity is invalid.")
        }
    }

    private fun isGeneratedRef(value: String): Boolean {
        if (value.length != 27 || !value.startsWith("tr_")) return false
        return value.drop(3).all { it in '0'..'9' || it in 'a'..'f' }
    }

    private fun isDigest(value: String): Boolean {
        if (value.length != 64) return false
        return value.all { it in '0'..'9' || it in 'a'..'f' }
    }

    private fun malformed(message: String) = ToolResultDetailException(
        code = "malformedResponse",
        message = message,
        retryable = false,
    )
}

/** App host binding for the feature UI. The reader is the trusted bridge; the
 * feature module never opens a file or a tool executor itself. */
internal class ToolResultHostController(
    private val client: ToolResultClient = ToolResultClient(),
) : ToolResultDetailSource {
    override suspend fun load(
        taskId: String,
        runId: String?,
        callId: String?,
        ref: String?,
        offset: Int,
        maxBytes: Int,
        expectedSHA256: String?,
        temporary: Boolean,
    ): ToolResultPageUi = withContext(Dispatchers.IO) {
        client.load(
            taskId = taskId,
            runId = runId,
            callId = callId,
            ref = ref,
            offset = offset,
            maxBytes = maxBytes,
            expectedSHA256 = expectedSHA256,
            temporary = temporary,
        )
    }
}

private fun JsonObject.string(key: String): String? =
    (this[key] as? JsonPrimitive)?.contentOrNull

private fun JsonObject.int(key: String): Int? =
    (this[key] as? JsonPrimitive)?.intOrNull

private fun JsonObject.bool(key: String): Boolean? =
    (this[key] as? JsonPrimitive)?.booleanOrNull

private fun JsonObject.requireArray(key: String): JsonArray =
    this[key] as? JsonArray ?: throw ToolResultDetailException(
        "malformedResponse",
        "The result reply has no '$key' array.",
    )
