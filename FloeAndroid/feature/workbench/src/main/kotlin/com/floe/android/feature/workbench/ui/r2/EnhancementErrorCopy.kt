// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui.r2

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import com.floe.android.feature.workbench.ui.R

/**
 * Concise, actionable EN/zh copy for the bounded enhancement failure and
 * unavailability codes. Ordinary screens never show a raw
 * `linuxUnavailable` / `backendProfileUnavailable` token; unknown codes fall
 * back to the safe bounded detail the native contract already guarantees.
 */
internal object EnhancementErrorCopy {

    /** Copy for a capability unavailability reason (may be null). */
    @Composable
    fun unavailableReason(reason: String?): String? {
        if (reason == null) return null
        return when (reason) {
            "backendNotConfigured" -> stringResource(
                R.string.media_enhancement_reason_backend_not_configured)
            "backendProfileUnavailable" -> stringResource(
                R.string.media_enhancement_reason_backend_profile_unavailable)
            "linuxUnavailable" -> stringResource(
                R.string.media_enhancement_reason_linux_unavailable)
            "taskBindingRequired" -> stringResource(
                R.string.media_enhancement_reason_task_binding)
            else -> stringResource(
                R.string.media_enhancement_reason_generic, reason)
        }
    }

    /** Copy for a terminal job failure (code + safe detail fallback). */
    @Composable
    fun failure(code: String?, detail: String?): String {
        if (code != null) {
            val mapped = when (code) {
                "backendUnavailable" -> stringResource(
                    R.string.media_enhancement_failure_backend_unavailable)
                "backendNotConfigured" -> stringResource(
                    R.string.media_enhancement_reason_backend_not_configured)
                "backendProfileUnavailable" -> stringResource(
                    R.string.media_enhancement_reason_backend_profile_unavailable)
                "linuxUnavailable" -> stringResource(
                    R.string.media_enhancement_reason_linux_unavailable)
                "taskBindingRequired" -> stringResource(
                    R.string.media_enhancement_reason_task_binding)
                "outcomeUnknown" -> stringResource(
                    R.string.media_enhancement_outcome_unknown)
                "cancelled" -> stringResource(R.string.media_enhancement_failure_cancelled)
                "sourceUnreadable" -> stringResource(
                    R.string.media_enhancement_failure_source_unreadable)
                "sourceTooLarge" -> stringResource(
                    R.string.media_enhancement_failure_source_too_large)
                "outputTooLarge" -> stringResource(
                    R.string.media_enhancement_failure_output_too_large)
                "durationTooLong" -> stringResource(
                    R.string.media_enhancement_failure_duration_too_long)
                "frameBoundExceeded" -> stringResource(
                    R.string.media_enhancement_failure_frame_bound)
                "targetFPSInvalid" -> stringResource(
                    R.string.media_enhancement_failure_target_fps)
                "scaleInvalid" -> stringResource(
                    R.string.media_enhancement_failure_scale)
                "unsupportedCombination" -> detail?.takeIf { it.isNotBlank() }
                    ?: stringResource(R.string.media_enhancement_failure_unsupported)
                "outputExists" -> stringResource(
                    R.string.media_enhancement_failure_output_exists)
                "verificationFailed" -> stringResource(
                    R.string.media_enhancement_failure_verification)
                "superResolutionFailed" -> stringResource(
                    R.string.media_enhancement_failure_super_resolution)
                else -> null
            }
            if (mapped != null) return mapped
        }
        return detail?.takeIf { it.isNotBlank() }
            ?: stringResource(R.string.media_enhancement_failure_generic)
    }
}
