// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officereview

import com.floe.android.core.officeengine.revisionreview.OfficeConflictReviewAction
import com.floe.android.core.officeengine.revisionreview.OfficeConflictReviewAnswer
import com.floe.android.core.officeengine.revisionreview.OfficeConflictResolutionResult
import com.floe.android.core.officeengine.revisionreview.OfficeConflictReviewState

/** Where the open-time original came from (identity, never authority). */
internal enum class OfficeConflictRoute { PROVIDER, WORKSPACE, RUN_OUTPUT, NONE }

/** Result of staging the live original through its existing read authority. */
internal sealed class OfficeOriginalCapture {
    data class Captured(
        val file: java.io.File,
        val sha256: String,
        val bytes: Long,
    ) : OfficeOriginalCapture()

    /** Bounded provider/workspace failure code; never a path or URI. */
    data class Failed(val code: String) : OfficeOriginalCapture()
}

/** One immutable version retained for review; never a mutable working file. */
internal data class OfficeConflictVersion(
    val sha256: String,
    val bytes: Long,
    val revision: String?,
    val file: java.io.File,
)

/** Exact facts captured when the viewer was opened for this operation. */
internal data class OfficeConflictReviewIdentity(
    val sessionToken: String,
    val generation: Long,
    val route: OfficeConflictRoute,
    val baseSha256: String,
    val baseRevision: String?,
    val originalUri: String?,
    val ownerTaskId: String?,
    val workspaceId: String?,
    val nativeEpoch: Long?,
    val hostGeneration: Long?,
    val sourceLogicalPath: String?,
    val workingCopy: java.io.File,
    val extension: String,
)

/**
 * Pure conflict-review decisions. All file/provider IO lives in the App
 * coordinator; this object only decides what the observations mean and which
 * deliberate resolutions are admissible.
 */
internal object OfficeConflictReviewPolicy {
    fun hasOriginal(route: OfficeConflictRoute): Boolean =
        route == OfficeConflictRoute.PROVIDER || route == OfficeConflictRoute.WORKSPACE

    /**
     * A revision is compared only when both sides actually reported one. A
     * provider route has no workspace CAS token, so its immutable SHA is the
     * identity. A digest difference is always a real conflict.
     */
    fun reviewState(
        baseSha256: String,
        baseRevision: String?,
        currentSha256: String?,
        currentRevision: String?,
        currentAvailable: Boolean,
    ): OfficeConflictReviewState = when {
        !currentAvailable || currentSha256 == null -> OfficeConflictReviewState.UNAVAILABLE
        currentSha256 == baseSha256 &&
            (baseRevision == null || currentRevision == null || baseRevision == currentRevision) ->
            OfficeConflictReviewState.UNCHANGED
        else -> OfficeConflictReviewState.CHANGED
    }

    fun answer(
        state: OfficeConflictReviewState,
        recordId: String?,
        baseSha256: String?,
        baseRevision: String?,
        mine: OfficeConflictVersion?,
        current: OfficeConflictVersion?,
        reason: String?,
    ): OfficeConflictReviewAnswer {
        val changed = state == OfficeConflictReviewState.CHANGED
        return OfficeConflictReviewAnswer(
            state = state,
            recordId = if (changed) recordId else null,
            baseSha256 = baseSha256,
            baseRevision = safeToken(baseRevision),
            mineSha256 = mine?.sha256,
            mineBytes = mine?.bytes ?: 0L,
            currentSha256 = current?.sha256,
            currentBytes = current?.bytes ?: 0L,
            currentRevision = safeToken(current?.revision),
            canKeepCurrent = changed,
            canPreserveMineAsCopy = changed,
            // The manual viewer owns no original CAS authority. The field is
            // present so a future authorized lane can answer truthfully; it
            // is never flipped to true by UI state alone.
            canRetryOriginalCas = false,
            reason = reason,
        )
    }

    private fun safeToken(raw: String?): String? =
        raw?.takeIf { it.length <= 160 && it.none { c -> c == '|' || c == '\n' || c == '\r' } }

    fun unavailable(reason: String): OfficeConflictReviewAnswer = OfficeConflictReviewAnswer(
        state = OfficeConflictReviewState.UNAVAILABLE,
        recordId = null,
        baseSha256 = null,
        baseRevision = null,
        mineSha256 = null,
        mineBytes = 0L,
        currentSha256 = null,
        currentBytes = 0L,
        currentRevision = null,
        canKeepCurrent = false,
        canPreserveMineAsCopy = false,
        canRetryOriginalCas = false,
        reason = reason,
    )

    fun notApplicable(reason: String): OfficeConflictReviewAnswer = OfficeConflictReviewAnswer(
        state = OfficeConflictReviewState.NOT_APPLICABLE,
        recordId = null,
        baseSha256 = null,
        baseRevision = null,
        mineSha256 = null,
        mineBytes = 0L,
        currentSha256 = null,
        currentBytes = 0L,
        currentRevision = null,
        canKeepCurrent = false,
        canPreserveMineAsCopy = false,
        canRetryOriginalCas = false,
        reason = reason,
    )

    /**
     * Resolution admission. The caller must have re-read the live original
     * FIRST and pass [currentStillMatches]. No mutation is permitted on a
     * stale review, and RETRY is refused unless a real original CAS authority
     * is present (the manual viewer has none).
     */
    fun resolve(
        state: OfficeConflictReviewState,
        action: OfficeConflictReviewAction,
        currentStillMatches: Boolean,
        originalCasAuthority: Boolean,
    ): OfficeConflictResolutionResult = when {
        state != OfficeConflictReviewState.CHANGED ->
            OfficeConflictResolutionResult(false, "noConflict", null)
        !currentStillMatches ->
            OfficeConflictResolutionResult(
                false,
                "reviewStale",
                "The original changed again after it was reviewed; everything is retained and nothing was written.",
            )
        action == OfficeConflictReviewAction.KEEP_CURRENT ->
            OfficeConflictResolutionResult(
                true,
                "keptCurrent",
                "The current original was kept; the working version remains retained.",
            )
        action == OfficeConflictReviewAction.PRESERVE_MINE_AS_COPY ->
            OfficeConflictResolutionResult(
                true,
                "preserveMineAsCopy",
                "The original stays untouched. Save the working version through the existing verified Save Copy flow.",
            )
        action == OfficeConflictReviewAction.RETRY_ORIGINAL_CAS &&
            !originalCasAuthority ->
            OfficeConflictResolutionResult(
                false,
                "originalCasUnavailable",
                "This viewer cannot overwrite an original: it owns no original compare-and-swap authority.",
            )
        action == OfficeConflictReviewAction.RETRY_ORIGINAL_CAS ->
            OfficeConflictResolutionResult(
                false,
                "originalCasNotImplemented",
                "A retry was not attempted; this lane has no implementation that can prove an original CAS write.",
            )
        else -> OfficeConflictResolutionResult(false, "unsupportedAction", null)
    }
}
