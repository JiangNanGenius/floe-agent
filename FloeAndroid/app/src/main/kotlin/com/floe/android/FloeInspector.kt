// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import androidx.compose.ui.platform.LocalContext
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloeText
import com.floe.android.design.FloeUnavailableView
import com.floe.android.design.InspectorContent
import com.floe.android.design.InspectorRoute
import com.floe.android.feature.conversation.ApprovalModeUi
import com.floe.android.feature.conversation.ChecklistDetailUi
import com.floe.android.feature.conversation.ChecklistStepStatusUi
import com.floe.android.feature.conversation.GoalDetailUi
import com.floe.android.feature.conversation.PlanDetailUi
import com.floe.android.feature.conversation.PlanGoalDetailStateUi
import com.floe.android.host.ConversationHostController
import com.floe.android.host.RuntimeHost

/**
 * On-demand inspector pane (iOS third column lives inside the stable detail
 * row; recreated per route identity, mirroring the `.id(route.id)` contract).
 * PROGRESS / CHILD_AGENTS / PERMISSIONS render the REAL produced wire:
 * durable plan/goal/checklist rows over the bounded `conversation.get.detail`
 * byte-exact read, the authoritative child graph, and the persisted task
 * policy under its proven CAS revision. Everything else stays an honest
 * unavailable until its real source is bound; no synthetic samples, no
 * timers, no local status invention.
 */
@Composable
fun FloeInspectorPane(
    route: InspectorRoute,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
    runtimeHost: RuntimeHost? = null,
) {
    BackHandler(onBack = onDismiss)
    val colors = Floe.colors
    var environmentVisible by remember(route.conversationId) { mutableStateOf(false) }
    Column(modifier.fillMaxSize().background(colors.readingSurface)) {
        Box(
            Modifier
                .fillMaxWidth()
                .height(FloeLayout.ToolbarHeight + 4.dp)
                .padding(horizontal = 10.dp),
        ) {
            FloeText(
                inspectorTitle(route.content),
                style = Floe.typography.toolbarTitle,
                color = colors.label,
                modifier = Modifier.align(Alignment.CenterStart),
            )
            FloeCircleButton(
                icon = FloeIcons.Xmark,
                contentDescription = stringResource(R.string.close),
                onClick = onDismiss,
                visualSize = 34.dp,
                iconSize = 15.dp,
                modifier = Modifier.align(Alignment.CenterEnd),
            )
        }
        com.floe.android.design.FloePageSheet(
            visible = environmentVisible, onDismiss = { environmentVisible = false },
        ) {
            Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(16.dp)) {
                com.floe.android.host.linux.LocalRuntimeSettingsCard()
            }
        }
        FloeDivider()
        val conversations = runtimeHost?.conversations
        when (route.content) {
            InspectorContent.PROGRESS -> TaskProgressPane(conversations, route.conversationId)
            InspectorContent.CHILD_AGENTS -> ChildAgentsPane(conversations, route.conversationId)
            InspectorContent.PERMISSIONS -> TaskPermissionsPane(conversations, route.conversationId)
            InspectorContent.WORKSPACE_FILES -> WorkspaceFilesPane(runtimeHost, route.conversationId, onDismiss)
            InspectorContent.CHANGES -> WorkspaceGitPane(runtimeHost, route.conversationId)
            InspectorContent.BROWSER -> {
                val taskID = route.conversationId
                if (runtimeHost != null && taskID != null)
                    WorkspaceBrowserPanelEmbedded(taskID, runtimeHost, onDismiss)
                else FloeUnavailableView(FloeIcons.Terminal, inspectorTitle(route.content), stringResource(R.string.root_detail_absent))
            }
            InspectorContent.TERMINAL -> route.conversationId?.let { WorkspaceTerminalPane(runtimeHost?.workspaceTerminal, it, onOpenEnvironment = { environmentVisible = true }) }
                ?: FloeUnavailableView(FloeIcons.Terminal, inspectorTitle(route.content), stringResource(R.string.root_detail_absent))
            else -> FloeUnavailableView(
                icon = FloeIcons.Terminal,
                title = inspectorTitle(route.content),
                description = stringResource(R.string.inspector_runtime_pending),
            )
        }
    }
}

@Composable
private fun inspectorTitle(content: InspectorContent): String = when (content) {
    InspectorContent.PROGRESS -> stringResource(R.string.inspector_progress)
    InspectorContent.WORKSPACE_FILES -> stringResource(R.string.inspector_files)
    InspectorContent.CHANGES -> stringResource(R.string.inspector_changes)
    InspectorContent.BROWSER -> stringResource(R.string.inspector_browser)
    InspectorContent.TERMINAL -> stringResource(R.string.inspector_terminal)
    InspectorContent.CHILD_AGENTS -> stringResource(R.string.inspector_agents)
    InspectorContent.PERMISSIONS -> stringResource(R.string.inspector_permissions)
}

/* ------------------------------- progress pane ------------------------------- */

/**
 * The task's REAL durable rows. Reads are EXPLICIT/ownership-scoped: they
 * start when the pane opens on a visible ordinary conversation and re-run
 * when the selected run actually SETTLES (a real durable-state transition
 * through the authoritative projection) — never a timer, never a background
 * resurrection. Absence, failure (+retry) and loading stay distinct; a
 * trimmed summary is honestly labelled and points at this same read.
 */
@Composable
private fun TaskProgressPane(conversations: ConversationHostController?, conversationId: String?) {
    val colors = Floe.colors
    val entry = conversationId?.let { conversations?.entryFor(it) }
    val holder = entry?.holder
    val state = holder?.snapshot?.value
    val isTemporary = entry?.isTemporary == true
    val isRunning = state?.isRunning == true
    val selectedRunId = state?.selectedRunId
    if (conversations == null || conversationId == null || holder == null) {
        FloeUnavailableView(
            icon = FloeIcons.Checklist,
            title = stringResource(R.string.inspector_progress),
            description = stringResource(R.string.root_detail_absent),
        )
        return
    }
    LaunchedEffect(conversationId, selectedRunId, isRunning) {
        if (isTemporary) return@LaunchedEffect
        conversations.requestPlanGoalDetail(holder.session, "goal")
        conversations.requestPlanGoalDetail(holder.session, "plan")
        if (!isRunning) conversations.requestPlanGoalDetail(holder.session, "checklist")
    }
    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        // REAL post-run review/continuation activity (the ONLY settlement
        // proof is the goalReview flipping to none through the snapshot).
        val activeReview = state?.goalReviewByRun?.entries?.firstOrNull { it.value == "active" }?.key
        val stoppingReview = state?.goalReviewByRun?.entries?.firstOrNull { it.value == "stopping" }?.key
        if (activeReview != null) {
            InspectorRowButton(
                label = stringResource(R.string.root_review_stop),
                onClick = { holder.requestGoalReviewStop(activeReview) },
            )
        } else if (stoppingReview != null) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                FloeActivityIndicator(modifier = Modifier.size(14.dp))
                FloeText(
                    stringResource(R.string.root_review_stopping),
                    style = Floe.typography.metadata,
                    color = colors.secondaryLabel,
                )
            }
        }
        if (isTemporary) {
            FloeText(
                stringResource(R.string.root_perm_temp),
                style = Floe.typography.metadata,
                color = colors.secondaryLabel,
            )
            return@Column
        }
        PlanArea(conversations, conversationId, holder, state)
        GoalArea(conversations, conversationId, holder, state)
        ChecklistArea(conversations, conversationId, holder)
        val children = state?.childRuns.orEmpty()
        if (children.isNotEmpty()) {
            InspectorRowButton(
                label = stringResource(R.string.root_children_summary, children.size),
                onClick = { holder.requestChildAgentsList() },
            )
        }
    }
}

@Composable
private fun PlanArea(
    conversations: ConversationHostController,
    conversationId: String,
    holder: com.floe.android.feature.conversation.ConversationFlowHolder,
    state: com.floe.android.feature.conversation.ThreadUiState?,
) {
    val colors = Floe.colors
    val plan = state?.plan
    if (plan == null && state?.planAvailabilityRaw != "trimmed") return
    FloeDivider()
    FloeText(
        plan?.title ?: stringResource(com.floe.android.feature.conversation.R.string.plan_title),
        style = Floe.typography.section,
        color = colors.label,
    )
    plan?.let {
        FloeText(
            it.statusRaw + (if (it.isDecisionComplete) " · ✓" else ""),
            style = Floe.typography.metadata,
            color = colors.secondaryLabel,
        )
    }
    val detail = remember(conversationId, "plan") {
        conversations.planGoalDetailState(conversationId, "plan")
    }.collectAsState().value
    DetailStateArea(
        detail = detail,
        summaryTrimmed = plan == null,
        onRead = { conversations.requestPlanGoalDetail(holder.session, "plan") },
        content = { row -> (row as? PlanDetailUi)?.let { PlanDetailContent(it) } },
    )
}

@Composable
private fun GoalArea(
    conversations: ConversationHostController,
    conversationId: String,
    holder: com.floe.android.feature.conversation.ConversationFlowHolder,
    state: com.floe.android.feature.conversation.ThreadUiState?,
) {
    val colors = Floe.colors
    val goal = state?.goal
    if (goal == null && state?.goalAvailabilityRaw != "trimmed") return
    FloeDivider()
    FloeText(
        goal?.objective ?: stringResource(com.floe.android.feature.conversation.R.string.goal_title),
        style = Floe.typography.section,
        color = colors.label,
    )
    goal?.let {
        FloeText(
            it.statusRaw,
            style = Floe.typography.metadata,
            color = colors.secondaryLabel,
        )
    }
    val detail = remember(conversationId, "goal") {
        conversations.planGoalDetailState(conversationId, "goal")
    }.collectAsState().value
    DetailStateArea(
        detail = detail,
        summaryTrimmed = goal == null,
        onRead = { conversations.requestPlanGoalDetail(holder.session, "goal") },
        content = { row -> (row as? GoalDetailUi)?.let { GoalDetailContent(it) } },
    )
}

@Composable
private fun ChecklistArea(
    conversations: ConversationHostController,
    conversationId: String,
    holder: com.floe.android.feature.conversation.ConversationFlowHolder,
) {
    val colors = Floe.colors
    FloeDivider()
    FloeText(
        stringResource(R.string.root_checklist_title),
        style = Floe.typography.section,
        color = colors.label,
    )
    val detail = remember(conversationId, "checklist") {
        conversations.planGoalDetailState(conversationId, "checklist")
    }.collectAsState().value
    DetailStateArea(
        detail = detail,
        summaryTrimmed = false,
        onRead = { conversations.requestPlanGoalDetail(holder.session, "checklist") },
        content = { row -> (row as? ChecklistDetailUi)?.let { ChecklistDetailContent(it) } },
    )
}

@Composable
private fun DetailStateArea(
    detail: PlanGoalDetailStateUi,
    summaryTrimmed: Boolean,
    onRead: () -> Unit,
    content: @Composable (Any) -> Unit,
) {
    val colors = Floe.colors
    when (detail) {
        PlanGoalDetailStateUi.Idle -> InspectorRowButton(
            label = stringResource(R.string.root_detail_read_full),
            onClick = onRead,
        )
        PlanGoalDetailStateUi.Loading -> Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            FloeActivityIndicator(modifier = Modifier.size(14.dp))
            FloeText(
                stringResource(if (summaryTrimmed) R.string.root_detail_loading else R.string.root_detail_read_full),
                style = Floe.typography.metadata,
                color = colors.secondaryLabel,
            )
        }
        PlanGoalDetailStateUi.Absent -> FloeText(
            stringResource(R.string.root_detail_absent),
            style = Floe.typography.metadata,
            color = colors.secondaryLabel,
        )
        is PlanGoalDetailStateUi.Failed -> Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            // The code stays visible only as the explicit diagnostic tail.
            FloeText(
                stringResource(R.string.root_detail_failed, detail.code),
                style = Floe.typography.metadata,
                color = colors.secondaryLabel,
            )
            InspectorRowButton(
                label = stringResource(R.string.root_detail_retry),
                onClick = onRead,
            )
        }
        is PlanGoalDetailStateUi.GoalReady -> content(detail.row)
        is PlanGoalDetailStateUi.PlanReady -> content(detail.row)
        is PlanGoalDetailStateUi.ChecklistReady -> content(detail.row)
    }
}

@Composable
private fun PlanDetailContent(row: PlanDetailUi) {
    val colors = Floe.colors
    if (row.summary.isNotBlank()) {
        FloeText(row.summary, style = Floe.typography.body, color = colors.label)
    }
    DetailList(stringResource(R.string.root_plan_sections), row.sections.map { it.title to it.body })
    if (row.assumptions.isNotEmpty()) {
        FloeText(
            stringResource(R.string.root_plan_assumptions),
            style = Floe.typography.metadata,
            color = colors.secondaryLabel,
        )
        row.assumptions.forEach { a ->
            FloeText(
                a.text + if (a.isAccepted) " · ${stringResource(R.string.root_plan_accepted)}" else "",
                style = Floe.typography.metadata,
                color = colors.label,
            )
        }
    }
    DetailList(
        stringResource(R.string.root_plan_risks),
        row.risks.map { it.text to (it.mitigation ?: it.severityRaw) },
    )
    DetailList(
        stringResource(R.string.root_plan_criteria),
        row.criteria.map { it.text to it.verification },
    )
    row.digest?.takeIf { it.isNotBlank() }?.let {
        FloeText(
            stringResource(R.string.root_plan_digest, it.take(12)),
            style = Floe.typography.evidence,
            color = colors.secondaryLabel,
        )
    }
}

@Composable
private fun GoalDetailContent(row: GoalDetailUi) {
    val colors = Floe.colors
    if (row.criteria.isNotEmpty()) {
        FloeText(
            stringResource(R.string.root_goal_criteria),
            style = Floe.typography.metadata,
            color = colors.secondaryLabel,
        )
        row.criteria.forEach { criterion ->
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                FloeText(
                    if (criterion.isSatisfied) "✓" else "○",
                    style = Floe.typography.metadata,
                    color = colors.accent,
                )
                Column(Modifier.weight(1f)) {
                    FloeText(criterion.text, style = Floe.typography.metadata, color = colors.label)
                    if (criterion.requiresUserConfirmation) {
                        FloeText(
                            stringResource(R.string.root_goal_needs_confirm),
                            style = Floe.typography.evidence,
                            color = colors.secondaryLabel,
                        )
                    }
                }
            }
        }
    }
    DetailList(
        stringResource(R.string.root_goal_steps),
        row.steps.map { it.title to it.statusRaw },
    )
    if (row.evidence.isNotEmpty()) {
        FloeText(
            stringResource(R.string.root_goal_evidence),
            style = Floe.typography.metadata,
            color = colors.secondaryLabel,
        )
        row.evidence.forEach { ev ->
            FloeText(
                "${ev.kindRaw}: ${ev.summary}",
                style = Floe.typography.evidence,
                color = colors.label,
                maxLines = 2,
            )
        }
    }
    row.blockingConditions?.let { conditions ->
        if (conditions.isNotEmpty()) {
            DetailList(stringResource(R.string.root_goal_blocking), conditions.map { it to "" })
        }
    }
    row.stoppingConditions?.let { conditions ->
        if (conditions.isNotEmpty()) {
            DetailList(stringResource(R.string.root_goal_stopping), conditions.map { it to "" })
        }
    }
    FloeText(
        stringResource(R.string.root_goal_progress, row.cycleCount, row.modelCallCount, row.totalIterationCount),
        style = Floe.typography.evidence,
        color = colors.secondaryLabel,
    )
    FloeText(
        stringResource(
            R.string.root_goal_limits,
            row.maxCycles?.toString() ?: "—",
            row.maxModelCalls?.toString() ?: "—",
        ),
        style = Floe.typography.evidence,
        color = colors.secondaryLabel,
    )
}

@Composable
private fun ChecklistDetailContent(row: ChecklistDetailUi) {
    val colors = Floe.colors
    if (row.title.isNotBlank()) {
        FloeText(row.title, style = Floe.typography.body, color = colors.label)
    }
    val completed = row.steps.count { it.status == ChecklistStepStatusUi.COMPLETED }
    val cancelled = row.steps.count { it.status == ChecklistStepStatusUi.CANCELLED }
    val inProgress = row.steps.count { it.status == ChecklistStepStatusUi.IN_PROGRESS }
    val pending = row.steps.count {
        it.status == ChecklistStepStatusUi.PENDING || it.status == ChecklistStepStatusUi.BLOCKED
    }
    FloeText(
        stringResource(R.string.root_checklist_counts, completed, cancelled, inProgress, pending),
        style = Floe.typography.metadata,
        color = colors.secondaryLabel,
    )
    row.steps.forEach { step ->
        Row(
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            FloeText(
                stepStatusLabel(step.status),
                style = Floe.typography.evidence,
                color = colors.accent,
            )
            Column(Modifier.weight(1f)) {
                FloeText(step.title, style = Floe.typography.metadata, color = colors.label)
                step.evidence.forEach { line ->
                    FloeText(line, style = Floe.typography.evidence, color = colors.secondaryLabel, maxLines = 2)
                }
            }
        }
    }
    // Honest framing: model-authored progress, never Goal proof.
    FloeText(
        stringResource(R.string.root_checklist_note),
        style = Floe.typography.evidence,
        color = colors.secondaryLabel,
    )
}

@Composable
private fun stepStatusLabel(status: ChecklistStepStatusUi): String = stringResource(
    when (status) {
        ChecklistStepStatusUi.PENDING -> R.string.step_pending
        ChecklistStepStatusUi.IN_PROGRESS -> R.string.step_in_progress
        ChecklistStepStatusUi.COMPLETED -> R.string.step_completed
        ChecklistStepStatusUi.BLOCKED -> R.string.step_blocked
        ChecklistStepStatusUi.CANCELLED -> R.string.step_cancelled
    },
)

@Composable
private fun DetailList(title: String, entries: List<Pair<String, String>>) {
    if (entries.isEmpty()) return
    val colors = Floe.colors
    FloeText(title, style = Floe.typography.metadata, color = colors.secondaryLabel)
    entries.forEach { (head, tail) ->
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            FloeText(head, style = Floe.typography.metadata, color = colors.label, modifier = Modifier.weight(1f))
            if (tail.isNotBlank()) {
                FloeText(tail, style = Floe.typography.evidence, color = colors.secondaryLabel, maxLines = 2)
            }
        }
    }
}

/* ------------------------------- child agents ------------------------------- */

/** The authoritative durable child graph (`child.list` rows already applied
 * through the projection) with on-demand transcripts (`child.entries`). */
@Composable
private fun ChildAgentsPane(conversations: ConversationHostController?, conversationId: String?) {
    val colors = Floe.colors
    val entry = conversationId?.let { conversations?.entryFor(it) }
    val holder = entry?.holder
    val state = holder?.snapshot?.value
    val children = state?.childRuns.orEmpty()
    if (holder == null || children.isEmpty()) {
        FloeUnavailableView(
            icon = FloeIcons.Target,
            title = stringResource(R.string.inspector_agents),
            description = stringResource(R.string.root_children_empty),
        )
        return
    }
    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        children.forEach { child ->
            Column(
                Modifier
                    .fillMaxWidth()
                    .heightIn(min = FloeLayout.MinimumTarget)
                    .clip(RoundedCornerShape(FloeLayout.BubbleCorner))
                    .background(colors.groupedSurface)
                    .clickable { holder.openChildRun(child.id) }
                    .padding(10.dp),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                FloeText(child.title, style = Floe.typography.body, color = colors.label, maxLines = 2)
                FloeText(
                    "${child.stateTitle} · ${child.startedAtLabel}",
                    style = Floe.typography.evidence,
                    color = colors.secondaryLabel,
                )
                child.summary?.let {
                    FloeText(it, style = Floe.typography.metadata, color = colors.secondaryLabel, maxLines = 2)
                }
                state?.childDetails?.get(child.id)?.let { detail ->
                    // The loaded durable transcript renders with the SAME
                    // row presentation as the parent timeline.
                    detail.rows.forEach { row ->
                        com.floe.android.feature.conversation.ConversationTimelineRow(
                            row = row,
                            holder = holder,
                        )
                    }
                }
            }
            FloeDivider()
        }
    }
}

/* ------------------------------ permissions pane ----------------------------- */

/** Live task policy: the EXPLICIT human gesture writes through the
 * persisted TaskPolicy row under its PROVEN CAS revision
 * (`run.policy.update`); the actual `appliedToLiveRun` reply is echoed, a
 * frozen active run stays frozen, and an unproven revision refuses rather
 * than sending a fabricated version. */
@Composable
private fun TaskPermissionsPane(conversations: ConversationHostController?, conversationId: String?) {
    val colors = Floe.colors
    val context = LocalContext.current
    val entry = conversationId?.let { conversations?.entryFor(it) }
    val holder = entry?.holder
    val state = holder?.snapshot?.value
    if (conversations == null || holder == null || state == null) {
        FloeUnavailableView(
            icon = FloeIcons.ShieldCheck,
            title = stringResource(R.string.inspector_permissions),
            description = stringResource(R.string.root_detail_absent),
        )
        return
    }
    if (state.isTemporary) {
        FloeText(
            stringResource(R.string.root_perm_temp),
            style = Floe.typography.metadata,
            color = colors.secondaryLabel,
            modifier = Modifier.padding(12.dp),
        )
        return
    }
    var resultLine by remember(conversationId) { mutableStateOf<String?>(null) }
    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        ApprovalModeUi.entries.forEach { mode ->
            Row(
                Modifier
                    .fillMaxWidth()
                    .heightIn(min = FloeLayout.MinimumTarget)
                    .clickable {
                        val started = conversations.updateTaskApprovalMode(holder.session, mode) { accepted, code, appliedToLiveRun ->
                            resultLine = if (accepted) {
                                if (appliedToLiveRun) {
                                    context.getString(R.string.root_perm_update_live)
                                } else {
                                    context.getString(R.string.root_perm_update_next)
                                }
                            } else {
                                context.getString(R.string.root_perm_update_failed, code ?: "unknown")
                            }
                        }
                        if (!started) {
                            resultLine = context.getString(R.string.root_perm_update_failed, "host_unavailable")
                        }
                    }
                    .padding(horizontal = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                FloeText(
                    approvalModeLabel(mode),
                    style = Floe.typography.body,
                    color = colors.label,
                    modifier = Modifier.weight(1f),
                )
                if (state.approvalMode == mode) {
                    FloeText("✓", style = Floe.typography.body, color = colors.accent)
                }
            }
        }
        if (state.taskPolicyRevision == null) {
            FloeText(
                stringResource(R.string.root_perm_no_revision),
                style = Floe.typography.evidence,
                color = colors.secondaryLabel,
            )
        }
        resultLine?.let {
            FloeText(it, style = Floe.typography.metadata, color = colors.secondaryLabel)
        }
        state.taskRecoveryPolicyRaw?.let {
            FloeText(
                stringResource(R.string.root_perm_recovery, it),
                style = Floe.typography.evidence,
                color = colors.secondaryLabel,
            )
        }
        state.taskNotificationPolicyRaw?.let {
            FloeText(
                stringResource(R.string.root_perm_notification, it),
                style = Floe.typography.evidence,
                color = colors.secondaryLabel,
            )
        }
    }
}

@Composable
private fun approvalModeLabel(mode: ApprovalModeUi): String = stringResource(
    when (mode) {
        ApprovalModeUi.ASK -> com.floe.android.feature.conversation.R.string.permissions_ask
        ApprovalModeUi.AUTOMATIC -> com.floe.android.feature.conversation.R.string.permissions_auto_approve
        ApprovalModeUi.FULL_ACCESS -> com.floe.android.feature.conversation.R.string.permissions_full_access
    },
)

@Composable
private fun InspectorRowButton(label: String, onClick: () -> Unit) {
    val colors = Floe.colors
    Box(
        Modifier
            .fillMaxWidth()
            .heightIn(min = FloeLayout.MinimumTarget)
            .clip(RoundedCornerShape(FloeLayout.BubbleCorner))
            .background(colors.groupedSurface)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp),
    ) {
        FloeText(label, style = Floe.typography.body, color = colors.accent)
    }
}
