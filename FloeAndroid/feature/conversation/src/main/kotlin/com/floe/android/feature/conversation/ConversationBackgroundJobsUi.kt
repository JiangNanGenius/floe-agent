// SPDX-License-Identifier: MPL-2.0
//
// Task-owned finite background jobs: the compact waiting bar, the inspectable
// sheet and the quiet system-notice row. It renders ONLY the durable host
// projection: no payload, command, output text or private path is displayed,
// and a cancellation request is never presented as a settled terminal.
package com.floe.android.feature.conversation

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloeSheetPlacement
import com.floe.android.design.FloeText
import com.floe.android.design.IconGlyph
import com.floe.android.design.FloeIcons

/**
 * Compact strip below the timeline while the selected run waits for required
 * background work (or a pending dependency is visible). It exposes the
 * existing real Stop and the job sheet; no synthetic progress is shown.
 */
@Composable
fun BackgroundJobsWaitingBar(
    holder: ConversationFlowHolder,
    modifier: Modifier = Modifier,
    isWide: Boolean = false,
) {
    val state = holder.snapshot.value ?: return
    if (!FloeBackgroundJobPresentation.showsWaitingBar(state)) return
    val actions: @Composable () -> Unit = {
        if (state.selectedRunDependenciesSettled && !state.isRunning) {
            FloeCapsuleAction(
                label = stringResource(R.string.action_continue),
                onClick = { holder.retry() },
            )
        }
        FloeCapsuleAction(
            label = stringResource(R.string.jobs_view),
            onClick = { holder.openBackgroundJobs() },
        )
        if (state.isRunning || state.selectedRunWaitingForJobs) {
            FloeCapsuleAction(
                label = stringResource(R.string.action_stop),
                tint = Floe.colors.destructive,
                onClick = { holder.cancel() },
            )
        }
    }
    Column(
        modifier = modifier
            .fillMaxWidth()
            .background(Floe.colors.pending.copy(alpha = 0.08f))
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            IconGlyph(FloeIcons.Clock, Floe.colors.pending, 16.dp)
            Column(Modifier.weight(1f)) {
                FloeText(
                    stringResource(R.string.jobs_waiting_title),
                    style = Floe.typography.metadata,
                    color = Floe.colors.label,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                FloeText(
                    stringResource(
                        if (state.selectedRunDependenciesSettled) {
                            R.string.jobs_waiting_settled_detail
                        } else {
                            R.string.jobs_waiting_detail
                        },
                    ),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (isWide) actions()
        }
        if (!isWide) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.End),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                actions()
            }
        }
    }
}

/** The bounded, inspectable list of THIS task's durable finite jobs. */
@Composable
fun BackgroundJobsSheet(holder: ConversationFlowHolder, isWide: Boolean = false) {
    val state = holder.snapshot.value
    FloePageSheet(
        visible = holder.backgroundJobsVisible,
        onDismiss = holder::dismissBackgroundJobs,
        widthFraction = if (isWide) 0.66f else 0.94f,
        heightFraction = 0.74f,
        placement = FloeSheetPlacement.CENTER,
    ) {
        Column(
            Modifier
                .fillMaxSize()
                .background(Floe.colors.chromeSurface),
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 20.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                FloeText(
                    stringResource(R.string.jobs_sheet_title),
                    style = Floe.typography.section,
                    modifier = Modifier.weight(1f),
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.jobs_sheet_refresh),
                    enabled = state?.backgroundJobsLoading != true,
                    onClick = { holder.refreshBackgroundJobs() },
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.action_done),
                    onClick = holder::dismissBackgroundJobs,
                )
            }
            FloeDivider()
            when {
                state == null -> Box(Modifier.fillMaxSize(), Alignment.Center) {
                    FloeActivityIndicator()
                }
                state.backgroundJobsLoading && !state.backgroundJobsLoaded ->
                    Box(Modifier.fillMaxSize(), Alignment.Center) {
                        FloeActivityIndicator(
                            description = stringResource(R.string.jobs_sheet_title))
                    }
                state.backgroundJobsErrorCode != null && !state.backgroundJobsLoaded ->
                    Column(
                        Modifier.fillMaxWidth().padding(20.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        FloeText(
                            stringResource(R.string.jobs_load_failed),
                            style = Floe.typography.body,
                            color = Floe.colors.pending,
                        )
                        FloeCapsuleAction(
                            label = stringResource(R.string.jobs_retry),
                            onClick = { holder.refreshBackgroundJobs() },
                        )
                    }
                state.backgroundJobs.isEmpty() ->
                    Box(Modifier.fillMaxSize(), Alignment.Center) {
                        FloeText(
                            stringResource(
                                if (holder.backgroundJobsUnavailable) {
                                    R.string.jobs_load_failed
                                } else {
                                    R.string.jobs_empty
                                },
                            ),
                            style = Floe.typography.metadata,
                            color = if (holder.backgroundJobsUnavailable) {
                                Floe.colors.pending
                            } else {
                                Floe.colors.secondaryLabel
                            },
                        )
                    }
                else -> LazyColumn(Modifier.fillMaxSize()) {
                    items(state.backgroundJobs, key = { it.jobId }) { job ->
                        BackgroundJobRow(holder, job)
                    }
                }
            }
            if (state?.backgroundJobsTruncated == true) {
                FloeText(
                    stringResource(R.string.jobs_truncated),
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
            if (state?.backgroundJobsActionErrorCode != null) {
                FloeText(
                    stringResource(R.string.jobs_cancel_failed),
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp),
                    style = Floe.typography.metadata,
                    color = Floe.colors.pending,
                )
            }
        }
    }
}

@Composable
private fun BackgroundJobRow(
    holder: ConversationFlowHolder,
    job: BackgroundJobUi,
) {
    val color = floeStatusColor(FloeBackgroundJobPresentation.stateColorRole(job))
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Box(
                Modifier
                    .clip(CircleShape)
                    .background(color.copy(alpha = 0.14f))
                    .padding(6.dp),
            ) {
                IconGlyph(
                    if (job.terminal && job.stateName == "completed") FloeIcons.CheckCircle
                    else if (job.terminal && job.stateName != "completed") FloeIcons.XOctagon
                    else FloeIcons.Clock,
                    color,
                    15.dp,
                )
            }
            Column(Modifier.weight(1f)) {
                FloeText(
                    stringResource(backgroundJobResource(FloeBackgroundJobPresentation.targetTitleKey(job.targetKind))),
                    style = Floe.typography.body,
                )
                Row {
                    FloeText(
                        stringResource(backgroundJobResource(FloeBackgroundJobPresentation.stateKey(job))),
                        style = Floe.typography.metadata,
                        color = color,
                    )
                    val progress = FloeBackgroundJobPresentation.progressLabel(job)
                    val stage = FloeBackgroundJobPresentation.progressStageKey(job)
                    if (stage != null || progress != null) {
                        val extra = listOfNotNull(
                            stage?.let { stringResource(backgroundJobResource(it)) },
                            progress,
                        ).joinToString(" · ")
                        FloeText(
                            " · $extra",
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                        )
                    }
                }
            }
            if (job.canCancel) {
                val cancelling = job.cancellationRequested ||
                    job.jobId in holder.cancellingBackgroundJobIds
                FloeCapsuleAction(
                    label = stringResource(
                        if (cancelling) R.string.jobs_cancelling else R.string.jobs_cancel),
                    enabled = job.jobId !in holder.pendingServiceJobIds &&
                        FloeBackgroundJobPresentation.cancelEnabled(job, holder.cancellingBackgroundJobIds),
                    tint = Floe.colors.destructive,
                    onClick = { holder.cancelBackgroundJob(job) },
                )
            }
        }
        if (job.canOpenServicePreview || job.canRestartService) {
            val action = if (job.canOpenServicePreview) BackgroundServiceAction.OPEN_PREVIEW
                else BackgroundServiceAction.RESTART
            FloeCapsuleAction(
                label = stringResource(if (job.canOpenServicePreview) R.string.jobs_service_open_preview
                    else R.string.jobs_service_restart),
                enabled = job.jobId !in holder.pendingServiceJobIds &&
                    job.jobId !in holder.cancellingBackgroundJobIds,
                onClick = { holder.performBackgroundServiceAction(job, action) },
            )
        }
        FloeBackgroundJobPresentation.dependencyKey(job)?.let { key ->
            FloeText(
                stringResource(backgroundJobResource(key)),
                style = Floe.typography.metadata,
                color = if (job.isPendingDependency) Floe.colors.pending
                        else Floe.colors.secondaryLabel,
            )
        }
        if (job.resultAvailable) {
            FloeText(
                stringResource(R.string.jobs_result_available),
                style = Floe.typography.metadata,
                color = Floe.colors.success,
            )
        } else if (job.terminal) {
            FloeText(
                stringResource(R.string.jobs_result_unavailable),
                style = Floe.typography.metadata,
                color = Floe.colors.tertiaryLabel,
            )
        }
    }
    FloeDivider()
}

/**
 * One quiet system-role lifecycle notice (for example the dependency
 * completion that resumed the task). The model-facing body is intentionally
 * not rendered as speech; the row states what happened and links to the job
 * list.
 */
@Composable
internal fun SystemNoticeRow(
    message: MessageUi,
    holder: ConversationFlowHolder,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        IconGlyph(FloeIcons.Clock, Floe.colors.tertiaryLabel, 14.dp)
        FloeText(
            stringResource(R.string.system_notice_background_work),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        Spacer(Modifier.width(4.dp))
        FloeText(
            stringResource(R.string.system_notice_view_jobs),
            style = Floe.typography.metadata,
            color = Floe.colors.accent,
            modifier = Modifier
                .heightIn(min = FloeLayout.MinimumTarget)
                .padding(vertical = 6.dp)
                .clip(CircleShape)
                .clickable { holder.openBackgroundJobs() }
                .padding(horizontal = 4.dp),
        )
    }
}

/** Closed string-key map for the background-job surface (EN/ZH resources). */
private fun backgroundJobResource(key: String): Int = when (key) {
    "job_target_shell" -> R.string.job_target_shell
    "job_target_web" -> R.string.job_target_web
    "job_target_office" -> R.string.job_target_office
    "job_target_service" -> R.string.job_target_service
    "job_target_other" -> R.string.job_target_other
    "job_state_queued" -> R.string.job_state_queued
    "job_state_running" -> R.string.job_state_running
    "job_state_cancelling" -> R.string.job_state_cancelling
    "job_state_completed" -> R.string.job_state_completed
    "job_state_failed" -> R.string.job_state_failed
    "job_state_cancelled" -> R.string.job_state_cancelled
    "job_state_interrupted" -> R.string.job_state_interrupted
    "job_state_unknown" -> R.string.job_state_unknown
    "job_stage_preparing" -> R.string.job_stage_preparing
    "job_stage_running" -> R.string.job_stage_running
    "job_stage_finalizing" -> R.string.job_stage_finalizing
    "job_stage_verifying" -> R.string.job_stage_verifying
    "job_stage_cancelling" -> R.string.job_stage_cancelling
    "jobs_dependency_pending" -> R.string.jobs_dependency_pending
    "jobs_dependency_resolved" -> R.string.jobs_dependency_resolved
    "jobs_dependency_service_ready" -> R.string.jobs_dependency_service_ready
    "jobs_dependency_failed" -> R.string.jobs_dependency_failed
    "jobs_dependency_cancelled" -> R.string.jobs_dependency_cancelled
    "jobs_dependency_interrupted" -> R.string.jobs_dependency_interrupted
    else -> R.string.job_state_unknown
}
