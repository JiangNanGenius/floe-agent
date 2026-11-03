// SPDX-License-Identifier: MPL-2.0
//
// C02 tool-result paging presentation values. These mirror the closed
// `floe.results/20` page exactly: byte offsets, the real nextOffset, the
// retained digest and explicit capture/persistence states. No path, secret or
// raw log is represented here.
package com.floe.android.feature.toolresults

data class ToolResultPageUi(
    val ref: String,
    val runId: String,
    val callId: String,
    val toolName: String,
    val status: String,
    val offset: Int,
    val endOffset: Int,
    val nextOffset: Int?,
    val totalBytes: Int,
    val text: String,
    val sha256: String,
    val originalDigest: String?,
    val executionReportedTruncation: Boolean,
    val retentionTruncated: Boolean,
    val durability: String,
    val restoredFromDisk: Boolean,
    val evictedCopies: Int,
) {
    /** True when this page is the last retained window. */
    val isLastPage: Boolean get() = nextOffset == null

    /** Honest combined capture state; never claims upstream bytes exist. */
    val captureState: String
        get() = when {
            executionReportedTruncation && retentionTruncated ->
                "executionOutputTruncated+retentionTruncated"
            executionReportedTruncation -> "executionOutputTruncated"
            retentionTruncated -> "retentionTruncated"
            else -> "complete"
        }
}

data class ToolResultIndexRowUi(
    val ref: String,
    val runId: String,
    val callId: String,
    val toolName: String,
    val totalBytes: Int,
    val executionReportedTruncation: Boolean,
    val retentionTruncated: Boolean,
    val capturedAt: String,
    val durability: String,
    val sha256: String,
    val originalDigest: String?,
)

data class ToolResultIndexUi(
    val rows: List<ToolResultIndexRowUi>,
    val evicted: Int,
)

data class ToolResultSearchHitUi(
    val ref: String,
    val runId: String,
    val callId: String,
    val toolName: String,
    val totalBytes: Int,
    val matchOffset: Int,
    val excerpt: String,
    val hasAdditionalMatches: Boolean,
    val sha256: String,
)

data class ToolResultSearchUi(
    val hits: List<ToolResultSearchHitUi>,
    val searchedCaptures: Int,
    val searchedBytes: Int,
    val truncated: Boolean,
)

/** Typed failure raised by a host/UI transport. Codes mirror the native wire
 * (`missing`, `changed`, `temporaryTaskRefused`, …); the UI maps them to an
 * honest state instead of inventing output. */
class ToolResultDetailException(
    val code: String,
    override val message: String,
    val retryable: Boolean = false,
) : Exception(message)

/** Host-provided reader. The App host implements it over the trusted bridge;
 * feature UI never opens a file, database or tool executor itself. */
interface ToolResultDetailSource {
    suspend fun load(
        taskId: String,
        runId: String?,
        callId: String?,
        ref: String?,
        offset: Int,
        maxBytes: Int,
        expectedSHA256: String?,
        temporary: Boolean,
    ): ToolResultPageUi
}
