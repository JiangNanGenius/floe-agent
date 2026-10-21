// SPDX-License-Identifier: MPL-2.0
//
// Thread status sections (⇄ ThreadDetailView: checklistStatus, intelligenceStatus,
// importantFilesStrip, compaction status, errorBanner, continuationBar,
// ThreadUsageFooter, ContextUsageRing/Details, decisionSummary/child rows are
// covered in ConversationTimelineRows.kt).
//
// Subagent/goal boundaries (SUB-DELEGATE / SUB-CHILD-ISOLATION presentation):
// the thread SHOWS delegated children resolved per run+call and the parent
// cancel/steer controls stay scoped to the parent run — one child's card
// never implies this UI can touch siblings; sibling isolation and budgets
// are host-enforced durable behavior, and the exact next qualification
// commands are recorded in the lane handoff.

package com.floe.android.feature.conversation

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloeText
import com.floe.android.design.IconGlyph

/* -------------------------------- checklist -------------------------------- */

/** ⇄ checklistStatus: foldable step list; folded header shows the current
 * step plus the monospaced progress count. */
@Composable
fun ThreadChecklistSection(holder: ConversationFlowHolder, modifier: Modifier = Modifier) {
    val checklist = holder.snapshot.value?.checklist ?: return
    Column(modifier = modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 8.dp)) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = FloeLayout.MinimumTarget)
                .clickable(onClick = holder::toggleChecklist),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Column(modifier = Modifier.weight(1f)) {
                FloeText(checklist.title, style = Floe.typography.body, color = Floe.colors.label, maxLines = 1, overflow = TextOverflow.Ellipsis)
                checklist.currentStepTitle?.let { step ->
                    FloeText(
                        stringResource(R.string.checklist_current_step, step),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            FloeText(checklist.progressSummary, style = Floe.typography.evidence, color = Floe.colors.secondaryLabel)
            IconGlyph(
                if (holder.checklistExpanded) FloeIcons.ChevronUp else FloeIcons.ChevronDown,
                Floe.colors.tertiaryLabel,
                14.dp,
            )
        }
        if (holder.checklistExpanded) {
            Spacer(Modifier.height(10.dp))
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 240.dp)
                    .verticalScrollCompat(),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                checklist.steps.forEach { step ->
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.Top,
                    ) {
                        IconGlyph(
                            when (step.status) {
                                ChecklistStepStatusUi.PENDING -> FloeIcons.Chip
                                ChecklistStepStatusUi.IN_PROGRESS -> FloeIcons.Refresh
                                ChecklistStepStatusUi.COMPLETED -> FloeIcons.Checkmark
                                ChecklistStepStatusUi.BLOCKED -> FloeIcons.Clock
                                ChecklistStepStatusUi.CANCELLED -> FloeIcons.Xmark
                            },
                            if (step.status == ChecklistStepStatusUi.COMPLETED) Floe.colors.success else Floe.colors.secondaryLabel,
                            15.dp,
                        )
                        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                            FloeText(step.title, style = Floe.typography.body, color = Floe.colors.label)
                            if (step.evidence.isNotEmpty()) {
                                FloeText(
                                    step.evidence.joinToString(" · "),
                                    style = Floe.typography.metadata,
                                    color = Floe.colors.secondaryLabel,
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun Modifier.verticalScrollCompat(): Modifier =
    this.then(
        androidx.compose.foundation.rememberScrollState().let {
            Modifier.verticalScroll(it)
        },
    )

/* ------------------------------ plan & goal strip ----------------------------- */

/** ⇄ intelligenceStatus: the plan card (recommendation + accept actions only
 * when ready+decision-complete) and the active goal card (progress bar;
 * confirm-completion offered only while verifying). */
@Composable
fun ThreadIntelligenceSection(holder: ConversationFlowHolder, modifier: Modifier = Modifier) {
    val state = holder.snapshot.value ?: return
    val plan = state.plan
    val goal = state.goal
    // TRIMMING is not ABSENCE: a page under native pressure may carry no
    // summary member while the availability members still prove a durable
    // row EXISTS. Those rows render as honestly incomplete with the
    // bounded detail read as the recovery path — never as "no plan/goal".
    val planTrimmed = plan == null && state.planAvailabilityRaw == "trimmed"
    val goalTrimmed = goal == null && state.goalAvailabilityRaw == "trimmed"
    if (plan == null && goal == null && !planTrimmed && !goalTrimmed) return
    Column(
        modifier = modifier
            .fillMaxWidth()
            .background(Floe.colors.groupedSurface)
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (plan != null) {
            Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                IconGlyph(FloeIcons.PlanList, Floe.colors.label, 16.dp)
                FloeText(stringResource(R.string.plan_title), style = Floe.typography.section, color = Floe.colors.label, modifier = Modifier.weight(1f))
                FloeText(plan.statusRaw, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
            }
            FloeText(plan.title, style = Floe.typography.body, color = Floe.colors.label, maxLines = 2, overflow = TextOverflow.Ellipsis)
            plan.executionRecommendation?.let { recommendation ->
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                    IconGlyph(
                        if (recommendation == PlanRecommendationUi.GOAL) FloeIcons.Target else FloeIcons.PlayRuns,
                        Floe.colors.secondaryLabel,
                        14.dp,
                    )
                    FloeText(
                        stringResource(
                            if (recommendation == PlanRecommendationUi.GOAL) R.string.plan_suggest_goal
                            else R.string.plan_suggest_normal
                        ),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                }
                plan.recommendationReason?.takeIf { it.isNotEmpty() }?.let { reason ->
                    FloeText(reason, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel, maxLines = 3, overflow = TextOverflow.Ellipsis)
                }
            }
            if (plan.statusRaw == "ready" && plan.isDecisionComplete) {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    PlanAction(
                        label = stringResource(R.string.plan_execute_normal),
                        prominent = true,
                        enabled = !holder.isAcceptingPlan && !state.isRunning,
                        onClick = { holder.acceptPlan(PlanRecommendationUi.NORMAL) },
                    )
                    PlanAction(
                        label = stringResource(R.string.plan_convert_goal),
                        prominent = false,
                        enabled = !holder.isAcceptingPlan && !state.isRunning,
                        onClick = { holder.acceptPlan(PlanRecommendationUi.GOAL) },
                    )
                }
            }
        }
        if (goal != null) {
            FloeDivider()
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                IconGlyph(FloeIcons.Target, Floe.colors.label, 16.dp)
                FloeText(stringResource(R.string.goal_title), style = Floe.typography.section, color = Floe.colors.label, modifier = Modifier.weight(1f))
                FloeText(goal.statusRaw, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
            }
            FloeText(goal.objective, style = Floe.typography.body, color = Floe.colors.label, maxLines = 2, overflow = TextOverflow.Ellipsis)
            val fraction = if (goal.stepsTotal <= 0) 0f else goal.stepsCompleted.toFloat() / goal.stepsTotal
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(4.dp)
                    .clip(CircleShape)
                    .background(Floe.colors.fillTertiary),
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth(fraction.coerceIn(0f, 1f))
                        .height(4.dp)
                        .clip(CircleShape)
                        .background(Floe.colors.accent),
                ) {}
            }
            if (goal.statusRaw == "verifying") {
                PlanAction(
                    label = stringResource(R.string.goal_confirm_complete),
                    prominent = true,
                    enabled = true,
                    onClick = { holder.confirmGoalCompletion() },
                )
            }
            // REAL post-run review/continuation activity (run.snapshot
            // `goalReview`): while review work is ACTIVE the surface keeps an
            // explicit human Stop routed through the existing run.cancel at
            // the exact review-owning run; while STOPPING it shows an honest
            // settling line and no fake settled/alreadyRequested claim. The
            // stopping→none flip (native registry) is the only settlement
            // proof, so this never needs a local timer.
            val activeReviewRun = state.goalReviewByRun.entries
                .firstOrNull { it.value == "active" }?.key
            val stoppingReviewRun = state.goalReviewByRun.entries
                .firstOrNull { it.value == "stopping" }?.key
            if (activeReviewRun != null) {
                PlanAction(
                    label = stringResource(R.string.goal_stop_review),
                    prominent = false,
                    enabled = true,
                    onClick = { holder.requestGoalReviewStop(activeReviewRun) },
                )
            } else if (stoppingReviewRun != null) {
                FloeText(
                    stringResource(R.string.goal_review_stopping),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
        }
        if (goalTrimmed || planTrimmed) {
            FloeDivider()
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                FloeText(
                    stringResource(R.string.intelligence_trimmed_note),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                    modifier = Modifier.weight(1f),
                )
                PlanAction(
                    label = stringResource(R.string.intelligence_read_full),
                    prominent = false,
                    enabled = true,
                    onClick = { holder.requestInspector(InspectorRouteUi.PROGRESS) },
                )
            }
        }
    }
}

@Composable
private fun PlanAction(label: String, prominent: Boolean, enabled: Boolean, onClick: () -> Unit) {
    val colors = Floe.colors
    val shape = RoundedCornerShape(9.dp)
    Box(
        modifier = Modifier
            .heightIn(min = FloeLayout.MinimumTarget)
            .clip(shape)
            .then(
                if (prominent) Modifier.background(if (enabled) colors.accent else colors.accent.copy(alpha = 0.45f))
                else Modifier.border(0.5.dp, colors.chromeHairline, shape)
            )
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 8.dp)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        FloeText(
            label,
            style = Floe.typography.bodyEmphasized,
            color = if (prominent) colors.readingSurface else colors.label,
        )
    }
}

/* ------------------------------ important files ------------------------------ */

/** ⇄ importantFilesStrip: horizontal chips of the projected working set;
 * taps route through the host attachment/file preview (no path trust here). */
@Composable
fun ImportantFilesStrip(
    files: List<ImportantFileUi>,
    onOpenFile: (ImportantFileUi) -> Unit,
    onOpenAll: () -> Unit,
    modifier: Modifier = Modifier,
) {
    if (files.isEmpty()) return
    val allLabel = stringResource(R.string.key_files_all)
    Column(modifier = modifier.fillMaxWidth().padding(vertical = 8.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            IconGlyph(FloeIcons.Pencil, Floe.colors.label, 14.dp)
            FloeText(stringResource(R.string.key_files_title), style = Floe.typography.bodyEmphasized, color = Floe.colors.label, modifier = Modifier.weight(1f))
            Box(
                modifier = Modifier
                    .heightIn(min = FloeLayout.MinimumTarget)
                    .clickable(onClick = onOpenAll)
                    .semantics { contentDescription = allLabel },
                contentAlignment = Alignment.Center,
            ) { FloeText(allLabel, style = Floe.typography.metadata, color = Floe.colors.accent) }
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .horizontalScroll(rememberScrollState())
                .padding(horizontal = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            files.forEach { file ->
                val chipLabel = "${file.action} · ${file.path.substringAfterLast('/')}"
                Box(
                    modifier = Modifier
                        .heightIn(min = FloeLayout.MinimumTarget)
                        .clip(RoundedCornerShape(9.dp))
                        .background(Floe.colors.groupedSurface)
                        .clickable { onOpenFile(file) }
                        .padding(horizontal = 10.dp, vertical = 6.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    FloeText(chipLabel, style = Floe.typography.metadata, color = Floe.colors.label, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
}

/* ------------------------------ usage & context ----------------------------- */

/** ⇄ ThreadUsageFooter: token accounting line; unreported metrics say
 * "not reported", never 0. */
@Composable
fun ThreadUsageFooter(usage: UsageUi, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(Floe.colors.groupedSurface)
            .padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
            FloeText("↑ ${TokenUnitFormatter.format(usage.inputTokens)}", style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
            FloeText("↓ ${TokenUnitFormatter.format(usage.outputTokens)}", style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
            FloeText(stringResource(R.string.usage_total, TokenUnitFormatter.format(usage.totalTokens)), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
            if (usage.isEstimatedLive) {
                FloeText(stringResource(R.string.usage_live_estimate), style = Floe.typography.metadata, color = Floe.colors.tertiaryLabel)
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            FloeText(
                stringResource(R.string.usage_context_reuse, reported(usage.cacheReadTokens)),
                style = Floe.typography.evidence,
                color = Floe.colors.tertiaryLabel,
            )
            FloeText(
                stringResource(R.string.usage_reasoning, reported(usage.reasoningTokens)),
                style = Floe.typography.evidence,
                color = Floe.colors.tertiaryLabel,
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            FloeText(
                stringResource(R.string.usage_cache_rate, usage.cacheHitRate?.let { "%.1f%%".format(it * 100) } ?: NOT_REPORTED),
                style = Floe.typography.evidence,
                color = Floe.colors.tertiaryLabel,
            )
            FloeText(
                stringResource(R.string.usage_speed, usage.tokensPerSecond?.let { "%.1f".format(it) } ?: NOT_REPORTED),
                style = Floe.typography.evidence,
                color = Floe.colors.tertiaryLabel,
            )
            FloeText(
                stringResource(R.string.usage_first_response, usage.timeToFirstTokenMs?.let { "%.2fs".format(it / 1000.0) } ?: NOT_REPORTED),
                style = Floe.typography.evidence,
                color = Floe.colors.tertiaryLabel,
            )
        }
    }
}

private const val NOT_REPORTED = "—"

@Composable
private fun reported(value: Int?): String = value?.let { TokenUnitFormatter.format(it) } ?: NOT_REPORTED

/** ⇄ ContextUsageRing: 20dp trim ring; pending amber past 85%. */
@Composable
fun ContextUsageRing(fraction: Double, modifier: Modifier = Modifier) {
    val colors = Floe.colors
    val sweep = fraction.coerceIn(0.0, 1.0)
    Box(modifier = modifier.size(20.dp), contentAlignment = Alignment.Center) {
        androidx.compose.foundation.Canvas(modifier = Modifier.size(20.dp)) {
            val strokeWidth = 3.dp.toPx()
            drawCircle(
                color = colors.secondaryLabel.copy(alpha = 0.22f),
                style = androidx.compose.ui.graphics.drawscope.Stroke(width = strokeWidth),
            )
            if (sweep > 0.0) {
                drawArc(
                    color = if (sweep > 0.85) colors.pending else colors.accent,
                    startAngle = -90f,
                    sweepAngle = (360.0 * sweep).toFloat(),
                    useCenter = false,
                    style = androidx.compose.ui.graphics.drawscope.Stroke(
                        width = strokeWidth,
                        cap = androidx.compose.ui.graphics.StrokeCap.Round,
                    ),
                )
            }
        }
    }
}

/** ⇄ ContextUsageDetails popover content. */
@Composable
fun ContextUsageDetails(usage: UsageUi, modifier: Modifier = Modifier) {
    val contextWindowLabel = stringResource(R.string.usage_context_window)
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(16.dp)
            .semantics { contentDescription = contextWindowLabel },
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
            IconGlyph(FloeIcons.Chip, Floe.colors.label, 15.dp)
            FloeText(contextWindowLabel, style = Floe.typography.section, color = Floe.colors.label)
        }
        FloeText(
            "${if (usage.contextTokens > 0) TokenUnitFormatter.format(usage.contextTokens) else "—"} / ${TokenUnitFormatter.format(usage.contextWindowTokens)}",
            style = Floe.typography.title,
            color = Floe.colors.label,
        )
        if (usage.contextTokens > 0) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(4.dp)
                    .clip(CircleShape)
                    .background(Floe.colors.fillTertiary),
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth(usage.contextFraction.toFloat().coerceIn(0f, 1f))
                        .height(4.dp)
                        .clip(CircleShape)
                        .background(if (usage.contextFraction > 0.85) Floe.colors.pending else Floe.colors.accent),
                ) {}
            }
            FloeText(
                stringResource(
                    R.string.usage_this_turn,
                    TokenUnitFormatter.format(usage.inputTokens),
                    TokenUnitFormatter.format(usage.outputTokens),
                ),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
        } else {
            FloeText(stringResource(R.string.usage_pending), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
        }
    }
}

/* --------------------------- bars & banners (VM-owned) --------------------------- */

/** ⇄ continuationBar: parked-run recovery affordance; Continue launches the
 * host's durable resume (never a fabricated run here). */
@Composable
fun ThreadContinuationBar(holder: ConversationFlowHolder, modifier: Modifier = Modifier) {
    val state = holder.snapshot.value ?: return
    if (!state.canContinue) return
    val continueLabel = stringResource(R.string.action_continue)
    Row(
        modifier = modifier
            .fillMaxWidth()
            .background(Floe.colors.pending.copy(alpha = 0.08f))
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        IconGlyph(
            if (state.runs.firstOrNull { it.id == state.selectedRunId }?.stateName == "failed") FloeIcons.XOctagon else FloeIcons.Clock,
            Floe.colors.pending,
            16.dp,
        )
        Column(modifier = Modifier.weight(1f)) {
            FloeText(
                state.continuationTitle ?: stringResource(R.string.continuation_default),
                style = Floe.typography.metadata,
                color = Floe.colors.label,
            )
            state.continuationDetail?.let { detail ->
                FloeText(detail, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
            }
        }
        Box(
            modifier = Modifier
                .heightIn(min = FloeLayout.MinimumTarget)
                .clip(RoundedCornerShape(9.dp))
                .background(Floe.colors.accent)
                .clickable(onClick = holder::retry)
                .padding(horizontal = 14.dp, vertical = 8.dp)
                .semantics { contentDescription = continueLabel },
            contentAlignment = Alignment.Center,
        ) {
            FloeText(continueLabel, style = Floe.typography.bodyEmphasized, color = Floe.colors.readingSurface)
        }
    }
}

/** ⇄ errorBanner: honest failure surface with dismiss. */
@Composable
fun ThreadErrorBanner(holder: ConversationFlowHolder, modifier: Modifier = Modifier) {
    val message = holder.actionError ?: return
    InlineBanner(
        icon = FloeIcons.XOctagon,
        text = message,
        tint = Floe.colors.destructive,
        onDismiss = holder::dismissActionError,
        modifier = modifier,
    )
}

/** ⇄ compaction status row. */
@Composable
fun ThreadCompactionStatus(holder: ConversationFlowHolder, modifier: Modifier = Modifier) {
    val state = holder.snapshot.value ?: return
    val status = state.compactionStatus ?: return
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (holder.isCompacting) FloeActivityIndicator()
        FloeText(status, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
    }
}

/* --------------------------- conversation missing row --------------------------- */

/** ⇄ composer==conversation-missing branch: honest unavailable surface. */
@Composable
fun ConversationMissingPlaceholder(modifier: Modifier = Modifier) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .background(Floe.colors.pending.copy(alpha = 0.08f))
            .padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        IconGlyph(FloeIcons.Bubble, Floe.colors.pending, 16.dp)
        FloeText(stringResource(R.string.chat_select_or_new), style = Floe.typography.metadata, color = Floe.colors.label)
    }
}
