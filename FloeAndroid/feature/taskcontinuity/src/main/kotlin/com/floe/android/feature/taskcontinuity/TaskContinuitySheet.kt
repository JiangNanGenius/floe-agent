// SPDX-License-Identifier: MPL-2.0
//
// C02 durable task continuity sheet.
//
// One surface for the recoverable storage pause and the canonical
// question/approval wait identity. It never answers a question or approval
// itself: a live question opens the ORIGINAL question sheet, a live approval
// points back to its timeline card, and a durable wait without a live owner
// offers the ORIGINAL Continue (run.retry) path. Resume of a storage pause is
// routed to the native explicit-resume CAS.
package com.floe.android.feature.taskcontinuity

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloePrimaryAction
import com.floe.android.design.FloeText

/**
 * Compact task-header entry. It appears only for a real pause/marker or a
 * wait that has no live owner, so an ordinary task never gains noise.
 */
@Composable
public fun TaskContinuityBanner(
    state: TaskContinuityUiState,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    if (!TaskContinuityPresentation.shouldShowBanner(state)) return
    val label = if (state.pause?.isResumed == false) {
        stringResource(R.string.taskcontinuity_banner)
    } else {
        stringResource(R.string.taskcontinuity_banner_waiting)
    }
    FloeCapsuleAction(label = label, onClick = onClick, modifier = modifier)
}

@Composable
public fun TaskContinuitySheet(
    visible: Boolean,
    state: TaskContinuityUiState,
    compact: Boolean,
    onDismiss: () -> Unit,
    onResumePause: () -> Unit,
    onResumeTask: (String) -> Unit,
    onReviewQuestion: (String) -> Unit,
    onRefresh: () -> Unit,
) {
    FloePageSheet(
        visible = visible,
        onDismiss = onDismiss,
        widthFraction = if (compact) 1f else 0.72f,
        heightFraction = if (compact) 1f else 0.9f,
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 18.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FloeText(
                    stringResource(R.string.taskcontinuity_title),
                    style = Floe.typography.title,
                    modifier = Modifier.weight(1f),
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.taskcontinuity_dismiss),
                    onClick = onDismiss,
                )
            }

            if (state.loading) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    FloeActivityIndicator()
                    Spacer(Modifier.width(10.dp))
                    FloeText(stringResource(R.string.taskcontinuity_checking))
                }
            }

            state.errorCode?.let { code ->
                FloeText(
                    if (code == "notInstalled" || code == "unsupportedOperation") {
                        stringResource(R.string.taskcontinuity_error_unavailable)
                    } else {
                        stringResource(R.string.taskcontinuity_error_generic)
                    },
                    style = Floe.typography.metadata,
                    color = Floe.colors.pending,
                )
            }

            Row(verticalAlignment = Alignment.CenterVertically) {
                FloeText(
                    stringResource(R.string.taskcontinuity_storage_title),
                    style = Floe.typography.section,
                    modifier = Modifier.weight(1f),
                )
                FloeText(
                    stringResource(state.storage.conditionLabelRes),
                    style = Floe.typography.metadata,
                    color = if (state.storage.isReady) Floe.colors.secondaryLabel
                    else Floe.colors.pending,
                )
            }

            state.pause?.let { pause ->
                FloeDivider()
                FloeText(
                    stringResource(R.string.taskcontinuity_paused_title),
                    style = Floe.typography.section,
                    color = Floe.colors.pending,
                )
                pause.reason?.let { reason ->
                    FloeText(
                        stringResource(reason.messageRes),
                        style = Floe.typography.body,
                        color = Floe.colors.label,
                    )
                }
                FloeText(
                    stringResource(
                        if (pause.runCheckpointed) R.string.taskcontinuity_checkpointed
                        else R.string.taskcontinuity_not_checkpointed
                    ),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                if (pause.durability == TaskContinuityDurabilityUi.MEMORY_ONLY) {
                    FloeText(
                        stringResource(R.string.taskcontinuity_memory_only),
                        style = Floe.typography.metadata,
                        color = Floe.colors.pending,
                    )
                }
                if (state.unknownOutcomeCount > 0) {
                    FloeText(
                        stringResource(
                            R.string.taskcontinuity_unknown_outcomes,
                            state.unknownOutcomeCount,
                        ),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                }
                if (pause.isActionable) {
                    FloeText(
                        stringResource(R.string.taskcontinuity_resume_hint),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                    FloePrimaryAction(
                        label = stringResource(
                            if (state.busy) R.string.taskcontinuity_resuming
                            else if (pause.state == TaskContinuityPauseStateUi.RESUME_FAILED)
                                R.string.taskcontinuity_resume_again
                            else R.string.taskcontinuity_resume
                        ),
                        onClick = onResumePause,
                        enabled = TaskContinuityPresentation.canResume(state),
                        modifier = Modifier.fillMaxWidth(),
                    )
                } else if (pause.isInProgress) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        FloeActivityIndicator()
                        Spacer(Modifier.width(10.dp))
                        FloeText(
                            stringResource(R.string.taskcontinuity_resuming),
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                        )
                    }
                } else if (pause.isResumed) {
                    FloeText(
                        stringResource(R.string.taskcontinuity_resumed),
                        style = Floe.typography.metadata,
                        color = Floe.colors.accent,
                    )
                }
            }

            if (state.waits.isNotEmpty() || state.waitsTruncated || state.waitsUnavailable) {
                FloeDivider()
                FloeText(
                    stringResource(R.string.taskcontinuity_waiting_title),
                    style = Floe.typography.section,
                )
            }
            state.waits.forEach { wait ->
                WaitRow(
                    wait = wait,
                    busy = state.busy,
                    pauseBlocksWait = state.pause?.isResumed == false,
                    onResumeTask = onResumeTask,
                    onReviewQuestion = onReviewQuestion,
                )
            }
            if (state.waitsTruncated) {
                FloeText(
                    stringResource(R.string.taskcontinuity_wait_truncated),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
            if (state.waitsUnavailable) {
                FloeText(
                    stringResource(R.string.taskcontinuity_wait_unavailable),
                    style = Floe.typography.metadata,
                    color = Floe.colors.pending,
                )
            }

            state.notice?.let { notice ->
                val noticeText = when (notice) {
                    "resumed" -> stringResource(R.string.taskcontinuity_notice_resumed)
                    "resumedWithReconciliation" ->
                        stringResource(R.string.taskcontinuity_notice_resumed_reconcile)
                    "storagePaused" ->
                        stringResource(R.string.taskcontinuity_notice_storage_paused)
                    else -> null
                }
                if (noticeText != null) {
                    FloeDivider()
                    FloeText(
                        noticeText,
                        style = Floe.typography.metadata,
                        color = Floe.colors.accent,
                    )
                }
            }

            FloeCapsuleAction(
                label = stringResource(R.string.taskcontinuity_refresh),
                onClick = onRefresh,
                enabled = !state.loading && !state.busy,
            )
        }
    }
}

@Composable
private fun WaitRow(
    wait: TaskContinuityWaitUi,
    busy: Boolean,
    pauseBlocksWait: Boolean,
    onResumeTask: (String) -> Unit,
    onReviewQuestion: (String) -> Unit,
) {
    val kindLabel = stringResource(
        if (wait.isQuestion) R.string.taskcontinuity_wait_question
        else R.string.taskcontinuity_wait_approval
    )
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            FloeText(
                kindLabel,
                style = Floe.typography.metadata,
                color = if (wait.requiresResume) Floe.colors.pending
                else Floe.colors.secondaryLabel,
                modifier = Modifier.weight(1f),
            )
            wait.deadlineLabel?.let { deadline ->
                FloeText(
                    stringResource(R.string.taskcontinuity_wait_deadline, deadline),
                    style = Floe.typography.metadata,
                    color = Floe.colors.pending,
                )
            }
        }
        FloeText(
            TaskContinuityPresentation.waitPreview(wait),
            style = Floe.typography.body,
            color = Floe.colors.label,
        )
        when (TaskContinuityPresentation.waitAction(wait)) {
            TaskContinuityWaitAction.RESUME_TASK -> {
                if (pauseBlocksWait) {
                    // There is ONE resume action: the pause button above.
                    // A second run.retry would be refused by the native
                    // pause gate and would only confuse the user.
                    FloeText(
                        stringResource(R.string.taskcontinuity_wait_resume_paused),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                } else {
                    FloeCapsuleAction(
                        label = stringResource(R.string.taskcontinuity_wait_resume),
                        onClick = { onResumeTask(wait.runID) },
                        enabled = !busy,
                    )
                }
            }
            TaskContinuityWaitAction.REVIEW_QUESTION -> FloeCapsuleAction(
                label = stringResource(R.string.taskcontinuity_wait_review),
                onClick = { onReviewQuestion(wait.requestID) },
                enabled = !busy,
            )
            TaskContinuityWaitAction.REVIEW_APPROVAL -> FloeText(
                stringResource(R.string.taskcontinuity_wait_review),
                style = Floe.typography.metadata,
                color = Floe.colors.accent,
            )
            TaskContinuityWaitAction.READ_ONLY -> FloeText(
                stringResource(R.string.taskcontinuity_wait_readonly),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
        }
        FloeDivider()
    }
}
