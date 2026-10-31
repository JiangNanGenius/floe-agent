// SPDX-License-Identifier: MPL-2.0
package com.floe.android.schedule

import android.app.DatePickerDialog
import android.app.TimePickerDialog
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.R
import com.floe.android.design.CupertinoMenuEntry
import com.floe.android.design.Floe
import com.floe.android.design.FloeCapsuleButton
import com.floe.android.design.FloeChipMenu
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeConfirmDialog
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeInfoDialog
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloeSegmented
import com.floe.android.design.FloeSheetPlacement
import com.floe.android.design.FloeStatusLine
import com.floe.android.design.FloeText
import com.floe.android.design.FloeToolbar
import com.floe.android.design.FloeUnavailableView
import com.floe.android.host.RuntimeHost
import java.util.Calendar
import java.util.TimeZone
import kotlinx.coroutines.launch

// ---------------------------------------------------------------- destination

/**
 * Standalone Scheduled Tasks destination. Main embeds this in the Task Center
 * (and may reuse [ScheduledTasksSummaryCard] on Home):
 *
 * ```
 * if (showSchedules) {
 *     TaskScheduleDestination(host, compact, true, onBack = { showSchedules = false })
 * } else { FloeConversationHistoryDestination(...) }
 * ```
 *
 * The composable owns no durable state; every action enters the native
 * scheduling service through the App host command channel.
 */
@Composable
fun TaskScheduleDestination(
    host: RuntimeHost?,
    compact: Boolean,
    showSidebarToggle: Boolean,
    onBack: () -> Unit,
    environmentProvider: TaskScheduleEnvironmentProvider? = null,
    runChoices: List<TaskScheduleRunChoice> = emptyList(),
) {
    if (host == null) {
        FloeUnavailableView(
            icon = FloeIcons.Clock,
            title = stringResource(R.string.schedule_title),
            description = stringResource(R.string.schedule_runtime_unavailable),
        )
        return
    }
    val context = LocalContext.current
    // ONE Application-owned authority provider is installed before any host
    // binds; the UI reuses that exact instance instead of a placeholder.
    val appliedEnvironmentProvider = environmentProvider ?: TaskSchedulePlatform.authority
    val controller = remember(host, appliedEnvironmentProvider) {
        TaskScheduleHostController(host, appliedEnvironmentProvider)
    }
    DisposableEffect(controller) { onDispose { controller.close() } }
    val state by controller.state.collectAsState()
    val scope = rememberCoroutineScope()
    var editing by remember { mutableStateOf<TaskScheduleDetail?>(null) }
    var creating by remember { mutableStateOf(false) }
    var historyFor by remember { mutableStateOf<TaskScheduleSummary?>(null) }
    var deleteTarget by remember { mutableStateOf<TaskScheduleSummary?>(null) }
    var actionError by remember { mutableStateOf<String?>(null) }
    var queuedNotice by remember { mutableStateOf<String?>(null) }
    var exactAllowed by remember {
        mutableStateOf(TaskSchedulePlatform.exactAlarmAllowed(context))
    }
    // Compact/phone Back returns to the Task Center list instead of leaving
    // the app; the persistent-sidebar (tablet) surface keeps platform Back.
    androidx.activity.compose.BackHandler(enabled = compact) { onBack() }

    val lifecycleOwner = context as? androidx.activity.ComponentActivity
    DisposableEffect(lifecycleOwner, controller) {
        if (lifecycleOwner == null) return@DisposableEffect onDispose { }
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                exactAllowed = TaskSchedulePlatform.exactAlarmAllowed(context)
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(controller) {
        exactAllowed = TaskSchedulePlatform.exactAlarmAllowed(context)
        controller.refreshNow()
    }

    fun openDetail(summary: TaskScheduleSummary) {
        scope.launch {
            when (val result = controller.detail(summary.id)) {
                is TaskScheduleResult.Ok -> editing = result.value
                is TaskScheduleResult.Failure -> actionError = result.code
            }
        }
    }

    fun toggle(summary: TaskScheduleSummary) {
        scope.launch {
            val result = controller.setEnabled(summary, !summary.enabled)
            if (result is TaskScheduleResult.Failure) actionError = result.code
        }
    }

    fun runNow(summary: TaskScheduleSummary) {
        scope.launch {
            when (val result = controller.runNow(summary)) {
                is TaskScheduleResult.Ok -> {
                    if (result.value.queued) queuedNotice = summary.title
                }
                is TaskScheduleResult.Failure -> actionError = result.code
            }
        }
    }

    Column(Modifier.fillMaxSize()) {
        FloeToolbar(
            title = stringResource(R.string.schedule_title),
            navigation = {
                FloeCircleButton(
                    icon = FloeIcons.ChevronBack,
                    contentDescription = stringResource(R.string.schedule_back),
                    onClick = onBack,
                    hairline = false,
                    background = Color.Transparent,
                )
            },
            actions = {
                FloeCircleButton(
                    icon = FloeIcons.Plus,
                    contentDescription = stringResource(R.string.schedule_add),
                    onClick = { creating = true },
                    hairline = false,
                    background = Color.Transparent,
                )
            },
        )
        val needsPermission = !exactAllowed && state.schedules.any {
            it.enabled && it.nextFireAtMillis != null &&
                it.cadence != TaskScheduleCadence.AFTER_SUCCESS &&
                !TaskSchedulePlatform.flexibleChosen(context, it.id)
        }
        if (needsPermission) {
            SchedulePermissionBanner(
                onAllowExact = { TaskSchedulePlatform.openExactAlarmSettings(context) },
            )
        }
        when {
            state.loading && state.schedules.isEmpty() -> CenteredCaption(
                stringResource(R.string.schedule_loading),
            )
            state.errorCode != null && state.schedules.isEmpty() ->
                CenteredCaption(scheduleErrorMessage(state.errorCode))
            state.schedules.isEmpty() -> CenteredCaption(
                stringResource(R.string.schedule_empty_body),
                title = stringResource(R.string.schedule_empty_title),
            )
            else -> {
                val upcoming = state.schedules.filter { it.enabled }
                val paused = state.schedules.filter { !it.enabled }
                LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(
                        start = if (compact) 16.dp else 28.dp,
                        end = if (compact) 16.dp else 28.dp,
                        top = 8.dp,
                        bottom = 32.dp,
                    ),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    if (upcoming.isNotEmpty()) {
                        item {
                            FloeText(
                                stringResource(R.string.schedule_section_upcoming),
                                style = Floe.typography.groupHeader,
                                color = Floe.colors.secondaryLabel,
                                modifier = Modifier.padding(top = 6.dp, bottom = 2.dp),
                            )
                        }
                        items(upcoming, key = { it.id }) { summary ->
                            ScheduledTaskRow(
                                summary = summary,
                                exactAlarmAllowed = exactAllowed,
                                flexibleChosen =
                                    TaskSchedulePlatform.flexibleChosen(context, summary.id),
                                transportNotice =
                                    TaskSchedulePlatform.transportNotice(context, summary.id),
                                onOpen = { openDetail(summary) },
                                onToggle = { toggle(summary) },
                                onRunNow = { runNow(summary) },
                                onHistory = { historyFor = summary },
                                onDelete = { deleteTarget = summary },
                                onUseFlexible = {
                                    TaskSchedulePlatform.setFlexibleChosen(context, summary.id, true)
                                    exactAllowed =
                                        TaskSchedulePlatform.exactAlarmAllowed(context)
                                },
                                onUseExact = {
                                    TaskSchedulePlatform.setFlexibleChosen(context, summary.id, false)
                                    exactAllowed =
                                        TaskSchedulePlatform.exactAlarmAllowed(context)
                                },
                            )
                        }
                    }
                    if (paused.isNotEmpty()) {
                        item {
                            FloeText(
                                stringResource(R.string.schedule_section_paused),
                                style = Floe.typography.groupHeader,
                                color = Floe.colors.secondaryLabel,
                                modifier = Modifier.padding(top = 16.dp, bottom = 2.dp),
                            )
                        }
                        items(paused, key = { it.id }) { summary ->
                            ScheduledTaskRow(
                                summary = summary,
                                exactAlarmAllowed = exactAllowed,
                                flexibleChosen =
                                    TaskSchedulePlatform.flexibleChosen(context, summary.id),
                                transportNotice =
                                    TaskSchedulePlatform.transportNotice(context, summary.id),
                                onOpen = { openDetail(summary) },
                                onToggle = { toggle(summary) },
                                onRunNow = { runNow(summary) },
                                onHistory = { historyFor = summary },
                                onDelete = { deleteTarget = summary },
                                onUseFlexible = {
                                    TaskSchedulePlatform.setFlexibleChosen(context, summary.id, true)
                                },
                                onUseExact = {
                                    TaskSchedulePlatform.setFlexibleChosen(context, summary.id, false)
                                },
                            )
                        }
                    }
                    if (state.truncated) {
                        item {
                            FloeText(
                                stringResource(R.string.schedule_list_truncated),
                                style = Floe.typography.metadata,
                                color = Floe.colors.secondaryLabel,
                                modifier = Modifier.padding(top = 8.dp),
                            )
                        }
                    }
                }
            }
        }
    }

    if (creating || editing != null) {
        TaskScheduleEditorSheet(
            options = state.options,
            environmentSelectionAvailable = state.environmentSelectionAvailable,
            runChoices = runChoices,
            initial = editing,
            compact = compact,
            onDismiss = { creating = false; editing = null },
            onSave = { draft ->
                val result = controller.save(draft)
                if (result is TaskScheduleResult.Ok) {
                    creating = false
                    editing = null
                    null
                } else {
                    (result as TaskScheduleResult.Failure).code
                }
            },
        )
    }

    historyFor?.let { summary ->
        TaskScheduleHistorySheet(
            controller = controller,
            summary = summary,
            compact = compact,
            onDismiss = { historyFor = null },
        )
    }

    deleteTarget?.let { summary ->
        FloeConfirmDialog(
            title = stringResource(R.string.schedule_delete_title),
            message = stringResource(R.string.schedule_delete_body, summary.title),
            confirmLabel = stringResource(R.string.schedule_delete_action),
            dismissLabel = stringResource(R.string.schedule_cancel),
            onConfirm = {
                deleteTarget = null
                // Explicit destructive tap only; the native revision CAS
                // still re-checks the exact row before deleting.
                scope.launch {
                    val result = controller.delete(summary)
                    if (result is TaskScheduleResult.Failure) {
                        actionError = result.code
                    }
                }
            },
            onDismiss = { deleteTarget = null },
        )
    }

    actionError?.let { code ->
        FloeInfoDialog(
            title = stringResource(R.string.schedule_error_title),
            message = scheduleErrorMessage(code),
            confirmLabel = stringResource(R.string.schedule_ok),
            onDismiss = { actionError = null },
        )
    }

    queuedNotice?.let { title ->
        FloeInfoDialog(
            title = stringResource(R.string.schedule_queued_title),
            message = stringResource(R.string.schedule_queued_body, title),
            confirmLabel = stringResource(R.string.schedule_ok),
            onDismiss = { queuedNotice = null },
        )
    }
}

@Composable
private fun SchedulePermissionBanner(onAllowExact: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 6.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(Floe.colors.fillTertiary)
            .padding(14.dp),
    ) {
        FloeText(
            stringResource(R.string.schedule_permission_title),
            style = Floe.typography.bodyEmphasized,
            color = Floe.colors.label,
        )
        Spacer(Modifier.height(4.dp))
        FloeText(
            stringResource(R.string.schedule_permission_body),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
        Spacer(Modifier.height(8.dp))
        TextButton(onClick = onAllowExact) {
            FloeText(
                stringResource(R.string.schedule_action_allow_exact),
                style = Floe.typography.bodyEmphasized,
                color = Floe.colors.accent,
            )
        }
    }
}

// ---------------------------------------------------------------------- row

@Composable
private fun ScheduledTaskRow(
    summary: TaskScheduleSummary,
    exactAlarmAllowed: Boolean,
    flexibleChosen: Boolean,
    transportNotice: String?,
    onOpen: () -> Unit,
    onToggle: () -> Unit,
    onRunNow: () -> Unit,
    onHistory: () -> Unit,
    onDelete: () -> Unit,
    onUseFlexible: () -> Unit,
    onUseExact: () -> Unit,
) {
    val status = TaskSchedulePresentation.status(
        summary, exactAlarmAllowed, flexibleChosen, transportNotice)
    var menu by remember { mutableStateOf(false) }
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(Floe.colors.sectionCardSurface)
            .clickable(role = Role.Button, onClick = onOpen)
            .padding(14.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                FloeText(
                    summary.title,
                    style = Floe.typography.bodyEmphasized,
                    color = Floe.colors.label,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.height(2.dp))
                FloeText(
                    stringResource(cadenceLabel(summary)),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
            Spacer(Modifier.width(8.dp))
            FloeStatusLine(
                icon = statusIcon(status),
                text = stringResource(statusLabel(status)),
                color = statusColor(status),
            )
            Box {
                FloeCircleButton(
                    icon = FloeIcons.Ellipsis,
                    contentDescription = stringResource(R.string.schedule_more),
                    onClick = { menu = true },
                    visualSize = 34.dp,
                    iconSize = 18.dp,
                    hairline = false,
                    background = Color.Transparent,
                )
                FloeChipMenu(expanded = menu, onDismiss = { menu = false }) {
                    CupertinoMenuEntry(
                        title = stringResource(R.string.schedule_action_run_now),
                        onClick = { menu = false; onRunNow() },
                    )
                    CupertinoMenuEntry(
                        title = stringResource(R.string.schedule_action_history),
                        onClick = { menu = false; onHistory() },
                    )
                    CupertinoMenuEntry(
                        title = stringResource(
                            if (summary.enabled) R.string.schedule_action_pause
                            else R.string.schedule_action_resume),
                        onClick = { menu = false; onToggle() },
                    )
                    if (status == TaskSchedulePresentationStatus.WAITING_PERMISSION) {
                        CupertinoMenuEntry(
                            title = stringResource(R.string.schedule_action_use_flexible),
                            onClick = { menu = false; onUseFlexible() },
                        )
                    }
                    if (flexibleChosen) {
                        CupertinoMenuEntry(
                            title = stringResource(R.string.schedule_action_use_exact),
                            onClick = { menu = false; onUseExact() },
                        )
                    }
                    CupertinoMenuEntry(
                        title = stringResource(R.string.schedule_delete_action),
                        onClick = { menu = false; onDelete() },
                    )
                }
            }
        }
        Spacer(Modifier.height(6.dp))
        FloeText(
            nextLine(summary),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
        if (summary.modelName != null || summary.workspaceName != null ||
            summary.environmentName != null) {
            Spacer(Modifier.height(3.dp))
            FloeText(
                listOfNotNull(
                    summary.modelName,
                    summary.workspaceName,
                    summary.environmentName,
                ).joinToString(" · "),
                style = Floe.typography.metadata,
                color = Floe.colors.tertiaryLabel,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (status == TaskSchedulePresentationStatus.NEEDS_ATTENTION) {
            Spacer(Modifier.height(4.dp))
            FloeText(
                summary.lastOccurrence?.errorText
                    ?: stringResource(R.string.schedule_needs_attention),
                style = Floe.typography.metadata,
                color = Floe.colors.destructive,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun CenteredCaption(text: String, title: String? = null) {
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        if (title != null) {
            FloeText(title, style = Floe.typography.section, color = Floe.colors.label)
            Spacer(Modifier.height(6.dp))
        }
        FloeText(text, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
    }
}

// ------------------------------------------------------------------- editor

@Composable
private fun TaskScheduleEditorSheet(
    options: TaskScheduleOptions,
    environmentSelectionAvailable: Boolean,
    runChoices: List<TaskScheduleRunChoice>,
    initial: TaskScheduleDetail?,
    compact: Boolean,
    onDismiss: () -> Unit,
    onSave: suspend (TaskScheduleDraft) -> String?,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val base = initial?.summary
    var title by remember { mutableStateOf(base?.title.orEmpty()) }
    var prompt by remember { mutableStateOf(initial?.prompt.orEmpty()) }
    var cadence by remember {
        mutableStateOf(base?.cadence ?: TaskScheduleCadence.ONCE)
    }
    var scheduledAt by remember {
        mutableStateOf(base?.scheduledAtMillis ?: (System.currentTimeMillis() + 3_600_000))
    }
    var weekday by remember {
        mutableStateOf(base?.weekday ?: Calendar.getInstance().get(Calendar.DAY_OF_WEEK))
    }
    var intervalMinutes by remember {
        mutableStateOf(((base?.intervalSeconds ?: 3_600) / 60).coerceAtLeast(1).toString())
    }
    var workspaceID by remember { mutableStateOf(base?.workspaceID) }
    var modelID by remember {
        mutableStateOf(base?.modelID ?: options.defaultModelID ?: options.models.firstOrNull()?.id)
    }
    var environmentID by remember { mutableStateOf(base?.environmentID) }
    var approvalMode by remember { mutableStateOf(base?.policy?.approvalMode ?: "ask") }
    var upstreamRunID by remember { mutableStateOf(base?.upstreamRunID) }
    var saving by remember { mutableStateOf(false) }
    var errorCode by remember { mutableStateOf<String?>(null) }

    val cadenceLabels = listOf(
        stringResource(R.string.schedule_cadence_once),
        stringResource(R.string.schedule_cadence_daily),
        stringResource(R.string.schedule_cadence_weekly),
        stringResource(R.string.schedule_cadence_interval),
        stringResource(R.string.schedule_cadence_after_success),
    )
    val cadences = TaskScheduleCadence.entries
    val timezone = base?.anchorTimezone ?: TimeZone.getDefault().id
    // REAL after-success candidates come from the native schedule.options
    // projection (same durable run store). A caller-supplied list is a visual
    // suggestion only: the native service re-validates the chosen run id.
    val visibleRunChoices = remember(options.runChoices, runChoices, workspaceID) {
        availableRunChoices(options.runChoices, runChoices, workspaceID)
    }

    suspend fun submit() {
        if (saving) return
        errorCode = when {
            prompt.trim().isEmpty() -> "promptInvalid"
            cadence == TaskScheduleCadence.AFTER_SUCCESS && upstreamRunID == null ->
                "upstreamRunRequired"
            cadence == TaskScheduleCadence.INTERVAL &&
                (intervalMinutes.toIntOrNull() ?: 0) < 1 -> "intervalInvalid"
            modelID == null -> "modelUnavailable"
            else -> null
        }
        if (errorCode != null) return
        saving = true
        val draft = TaskScheduleDraft(
            scheduleID = base?.id,
            expectedRevision = base?.revision,
            title = title.trim(),
            prompt = prompt.trim(),
            cadence = cadence,
            scheduledAtMillis = scheduledAt,
            weekday = if (cadence == TaskScheduleCadence.WEEKLY) weekday else null,
            intervalMinutes = if (cadence == TaskScheduleCadence.INTERVAL)
                intervalMinutes.toIntOrNull() ?: 0 else null,
            anchorTimezone = timezone,
            upstreamRunID = if (cadence == TaskScheduleCadence.AFTER_SUCCESS)
                upstreamRunID else null,
            workspaceID = workspaceID,
            modelID = modelID,
            environmentID = if (workspaceID != null) environmentID else null,
            policy = TaskSchedulePolicyBinding(
                approvalMode = approvalMode,
                recoveryPolicy = base?.let { it.policy.recoveryPolicy } ?: "safePoint",
                notificationPolicy = base?.let { it.policy.notificationPolicy } ?: "stages",
            ),
        )
        errorCode = onSave(draft)
        saving = false
    }

    fun pickDateTime() {
        val calendar = Calendar.getInstance().apply { timeInMillis = scheduledAt }
        DatePickerDialog(
            context,
            { _, year, month, day ->
                calendar.set(year, month, day)
                TimePickerDialog(
                    context,
                    { _, hour, minute ->
                        calendar.set(Calendar.HOUR_OF_DAY, hour)
                        calendar.set(Calendar.MINUTE, minute)
                        calendar.set(Calendar.SECOND, 0)
                        scheduledAt = calendar.timeInMillis
                    },
                    calendar.get(Calendar.HOUR_OF_DAY),
                    calendar.get(Calendar.MINUTE),
                    true,
                ).show()
            },
            calendar.get(Calendar.YEAR),
            calendar.get(Calendar.MONTH),
            calendar.get(Calendar.DAY_OF_MONTH),
        ).show()
    }

    FloePageSheet(
        visible = true,
        onDismiss = onDismiss,
        widthFraction = if (compact) 1f else 0.72f,
        heightFraction = if (compact) 1f else 0.92f,
        placement = if (compact) FloeSheetPlacement.BOTTOM else FloeSheetPlacement.CENTER,
    ) {
        Column(Modifier.fillMaxSize()) {
            FloeToolbar(
                title = stringResource(
                    if (initial == null) R.string.schedule_editor_create
                    else R.string.schedule_editor_edit),
                navigation = {
                    TextButton(onClick = onDismiss) {
                        FloeText(
                            stringResource(R.string.schedule_cancel),
                            style = Floe.typography.body,
                            color = Floe.colors.accent,
                        )
                    }
                },
                actions = {
                    TextButton(
                        onClick = { scope.launch { submit() } },
                        enabled = !saving,
                    ) {
                        FloeText(
                            if (saving) stringResource(R.string.schedule_saving)
                            else stringResource(R.string.schedule_save),
                            style = Floe.typography.bodyEmphasized,
                            color = if (saving) Floe.colors.tertiaryLabel
                            else Floe.colors.accent,
                        )
                    }
                },
            )
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 20.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                FloePlainFormField(
                    label = stringResource(R.string.schedule_field_title),
                    value = title,
                    onValueChange = { title = it.takeUtf8Bytes(160) },
                )
                FloePlainFormField(
                    label = stringResource(R.string.schedule_field_prompt),
                    value = prompt,
                    onValueChange = { prompt = it.takeUtf8Bytes(16_384) },
                    singleLine = false,
                    minLines = 4,
                    maxLines = 8,
                )
                FloeText(
                    stringResource(R.string.schedule_field_cadence),
                    style = Floe.typography.groupHeader,
                    color = Floe.colors.secondaryLabel,
                )
                FloeSegmented(
                    options = cadenceLabels,
                    selectedIndex = cadences.indexOf(cadence).coerceAtLeast(0),
                    onSelect = { index ->
                        cadence = cadences[index]
                        if (cadence == TaskScheduleCadence.ONCE &&
                            scheduledAt <= System.currentTimeMillis()) {
                            scheduledAt = System.currentTimeMillis() + 3_600_000
                        }
                    },
                )
                if (cadence == TaskScheduleCadence.WEEKLY) {
                    ChoiceRow(
                        label = stringResource(R.string.schedule_field_weekday),
                        value = weekdayLabel(weekday),
                        options = (1..7).map { it.toString() to weekdayLabel(it) },
                        onSelect = { weekday = it.toInt() },
                    )
                }
                if (cadence == TaskScheduleCadence.INTERVAL) {
                    FloePlainFormField(
                        label = stringResource(R.string.schedule_field_interval_minutes),
                        value = intervalMinutes,
                        onValueChange = { raw ->
                            intervalMinutes = raw.filter(Char::isDigit).take(6)
                        },
                    )
                }
                if (cadence == TaskScheduleCadence.AFTER_SUCCESS) {
                    if (visibleRunChoices.isEmpty()) {
                        FloeText(
                            stringResource(R.string.schedule_upstream_unavailable),
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                        )
                    } else {
                        ChoiceRow(
                            label = stringResource(R.string.schedule_field_upstream_run),
                            value = visibleRunChoices
                                .firstOrNull { it.runID == upstreamRunID }
                                ?.let { runChoiceLabel(it) }
                                ?: stringResource(R.string.schedule_choose),
                            options = visibleRunChoices.map {
                                it.runID to runChoiceLabel(it)
                            },
                            onSelect = { upstreamRunID = it },
                        )
                    }
                }
                if (cadence != TaskScheduleCadence.AFTER_SUCCESS) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        FloeText(
                            stringResource(R.string.schedule_field_time),
                            style = Floe.typography.body,
                            color = Floe.colors.label,
                            modifier = Modifier.weight(1f),
                        )
                        TextButton(onClick = ::pickDateTime) {
                            FloeText(
                                TaskScheduleWire.isoLocal(
                                    scheduledAt,
                                    timezone.let { runCatching { TimeZone.getTimeZone(it) }
                                        .getOrDefault(TimeZone.getDefault()) }.toZoneId(),
                                ),
                                style = Floe.typography.body,
                                color = Floe.colors.accent,
                            )
                        }
                    }
                }
                ChoiceRow(
                    label = stringResource(R.string.schedule_field_workspace),
                    value = workspaceID?.let { id ->
                        options.workspaces.firstOrNull { it.id == id }?.name
                    } ?: stringResource(R.string.schedule_workspace_new),
                    options = listOf("" to stringResource(R.string.schedule_workspace_new)) +
                        options.workspaces.map { it.id to it.name },
                    onSelect = { key ->
                        workspaceID = key.takeIf { it.isNotEmpty() }
                        if (workspaceID == null) environmentID = null
                    },
                )
                FloeText(
                    stringResource(R.string.schedule_workspace_caption),
                    style = Floe.typography.metadata,
                    color = Floe.colors.tertiaryLabel,
                )
                ChoiceRow(
                    label = stringResource(R.string.schedule_field_model),
                    value = options.models.firstOrNull { it.id == modelID }?.displayName
                        ?: stringResource(R.string.schedule_choose),
                    options = options.models.map { it.id to it.displayName },
                    onSelect = { modelID = it },
                )
                if (workspaceID == null || !environmentSelectionAvailable) {
                    FloeText(
                        stringResource(
                            if (workspaceID == null) R.string.schedule_environment_new_workspace
                            else R.string.schedule_environment_unavailable),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                } else {
                    ChoiceRow(
                        label = stringResource(R.string.schedule_field_environment),
                        value = environmentID?.let { id ->
                            options.environments.firstOrNull { it.id == id }?.name
                        } ?: stringResource(R.string.schedule_environment_auto),
                        options = listOf("" to stringResource(R.string.schedule_environment_auto)) +
                            options.environments.map { it.id to it.name },
                        onSelect = { environmentID = it.takeIf { key -> key.isNotEmpty() } },
                    )
                }
                ChoiceRow(
                    label = stringResource(R.string.schedule_field_approval),
                    value = approvalLabel(approvalMode),
                    options = listOf(
                        "ask" to stringResource(R.string.schedule_approval_ask),
                        "automatic" to stringResource(R.string.schedule_approval_automatic),
                        "fullAccess" to stringResource(R.string.schedule_approval_full),
                    ),
                    onSelect = { approvalMode = it },
                )
                FloeText(
                    stringResource(R.string.schedule_permission_note),
                    style = Floe.typography.metadata,
                    color = Floe.colors.tertiaryLabel,
                )
                if (options.truncated) {
                    FloeText(
                        stringResource(R.string.schedule_options_truncated),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                }
                errorCode?.let { code ->
                    FloeText(
                        scheduleErrorMessage(code),
                        style = Floe.typography.metadata,
                        color = Floe.colors.destructive,
                    )
                }
                Spacer(Modifier.height(8.dp))
                FloeCapsuleButton(
                    label = if (saving) stringResource(R.string.schedule_saving)
                    else stringResource(R.string.schedule_save),
                    onClick = { scope.launch { submit() } },
                    enabled = !saving,
                    prominent = true,
                )
            }
        }
    }
}

@Composable
private fun ChoiceRow(
    label: String,
    value: String,
    options: List<Pair<String, String>>,
    onSelect: (String) -> Unit,
    enabled: Boolean = true,
) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = FloeLayout.MinimumTarget)
                .clip(RoundedCornerShape(10.dp))
                .clickable(enabled = enabled, role = Role.Button) { expanded = true }
                .padding(horizontal = 4.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            FloeText(
                label,
                style = Floe.typography.body,
                color = if (enabled) Floe.colors.label else Floe.colors.tertiaryLabel,
                modifier = Modifier.weight(1f),
            )
            FloeText(
                value,
                style = Floe.typography.body,
                color = if (enabled) Floe.colors.secondaryLabel else Floe.colors.tertiaryLabel,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.width(6.dp))
            androidx.compose.foundation.Image(
                imageVector = FloeIcons.ChevronForward,
                contentDescription = null,
                modifier = Modifier.size(14.dp),
                colorFilter = androidx.compose.ui.graphics.ColorFilter.tint(
                    Floe.colors.tertiaryLabel),
            )
        }
        FloeChipMenu(expanded = expanded, onDismiss = { expanded = false }) {
            options.forEach { (key, optionLabel) ->
                CupertinoMenuEntry(
                    title = optionLabel,
                    selected = key == options.firstOrNull {
                        value == it.second
                    }?.first,
                    onClick = {
                        expanded = false
                        onSelect(key)
                    },
                )
            }
        }
    }
}

// ------------------------------------------------------------------ history

@Composable
private fun TaskScheduleHistorySheet(
    controller: TaskScheduleHostController,
    summary: TaskScheduleSummary,
    compact: Boolean,
    onDismiss: () -> Unit,
) {
    var items by remember { mutableStateOf<List<TaskScheduleOccurrence>>(emptyList()) }
    var truncated by remember { mutableStateOf(false) }
    var loading by remember { mutableStateOf(true) }
    var errorCode by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(summary.id) {
        when (val result = controller.history(summary.id, 50)) {
            is TaskScheduleResult.Ok -> {
                items = result.value.occurrences
                truncated = result.value.truncated
            }
            is TaskScheduleResult.Failure -> errorCode = result.code
        }
        loading = false
    }
    FloePageSheet(
        visible = true,
        onDismiss = onDismiss,
        widthFraction = if (compact) 1f else 0.6f,
        heightFraction = if (compact) 0.9f else 0.85f,
        placement = if (compact) FloeSheetPlacement.BOTTOM else FloeSheetPlacement.CENTER,
    ) {
        Column(Modifier.fillMaxSize()) {
            FloeToolbar(
                title = stringResource(R.string.schedule_history_title, summary.title),
                navigation = {
                    TextButton(onClick = onDismiss) {
                        FloeText(
                            stringResource(R.string.schedule_ok),
                            style = Floe.typography.body,
                            color = Floe.colors.accent,
                        )
                    }
                },
            )
            when {
                loading -> CenteredCaption(stringResource(R.string.schedule_loading))
                errorCode != null -> CenteredCaption(scheduleErrorMessage(errorCode))
                items.isEmpty() -> CenteredCaption(
                    stringResource(R.string.schedule_history_empty))
                else -> LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    if (truncated) {
                        item {
                            FloeText(
                                stringResource(R.string.schedule_history_truncated),
                                style = Floe.typography.metadata,
                                color = Floe.colors.secondaryLabel,
                            )
                        }
                    }
                    items(items, key = { it.id }) { occurrence ->
                        Column(
                            Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(12.dp))
                                .background(Floe.colors.sectionCardSurface)
                                .padding(12.dp),
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                FloeText(
                                    occurrence.scheduledForMillis?.let {
                                        TaskScheduleWire.isoLocal(it)
                                    } ?: "",
                                    style = Floe.typography.body,
                                    color = Floe.colors.label,
                                    modifier = Modifier.weight(1f),
                                )
                                FloeText(
                                    stringResource(occurrenceStateLabel(occurrence.state)),
                                    style = Floe.typography.metadata,
                                    color = occurrenceStateColor(occurrence.state),
                                )
                            }
                            val detail = occurrence.errorText ?: occurrence.summary
                            if (detail != null) {
                                Spacer(Modifier.height(3.dp))
                                FloeText(
                                    detail,
                                    style = Floe.typography.metadata,
                                    color = Floe.colors.secondaryLabel,
                                    maxLines = 3,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

// -------------------------------------------------------------------- card

/**
 * Compact Home summary card. Main may place it above the composer/history:
 * it shows the next enabled schedule and opens [onOpen].
 */
@Composable
fun ScheduledTasksSummaryCard(
    host: RuntimeHost?,
    onOpen: () -> Unit,
    modifier: Modifier = Modifier,
    environmentProvider: TaskScheduleEnvironmentProvider? = null,
    /** Home hides the card while nothing is scheduled (the Task Center keeps
     * a permanent entry). */
    showWhenEmpty: Boolean = true,
) {
    if (host == null) return
    val appliedProvider = environmentProvider ?: TaskSchedulePlatform.authority
    val controller = remember(host, appliedProvider) {
        TaskScheduleHostController(host, appliedProvider)
    }
    DisposableEffect(controller) { onDispose { controller.close() } }
    val state by controller.state.collectAsState()
    LaunchedEffect(controller) { controller.refreshNow() }
    if (!showWhenEmpty && state.schedules.isEmpty()) return
    val next = state.schedules
        .filter { it.enabled }
        .minByOrNull { it.nextFireAtMillis ?: Long.MAX_VALUE }
    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(Floe.colors.sectionCardSurface)
            .clickable(role = Role.Button, onClick = onOpen)
            .padding(14.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            FloeText(
                stringResource(R.string.schedule_card_title),
                style = Floe.typography.bodyEmphasized,
                color = Floe.colors.label,
                modifier = Modifier.weight(1f),
            )
            FloeText(
                stringResource(R.string.schedule_card_open),
                style = Floe.typography.metadata,
                color = Floe.colors.accent,
            )
        }
        Spacer(Modifier.height(4.dp))
        FloeText(
            if (next == null) stringResource(R.string.schedule_card_empty)
            else nextLine(next),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

// ----------------------------------------------------------------- helpers

@Composable
private fun nextLine(summary: TaskScheduleSummary): String {
    if (!summary.enabled) return stringResource(R.string.schedule_no_next)
    if (summary.cadence == TaskScheduleCadence.AFTER_SUCCESS) {
        return stringResource(R.string.schedule_after_success_line)
    }
    val millis = summary.nextFireAtMillis ?: return stringResource(R.string.schedule_no_next)
    return stringResource(
        R.string.schedule_next_line,
        TaskScheduleWire.isoLocal(
            millis,
            runCatching { TimeZone.getTimeZone(summary.anchorTimezone ?: TimeZone.getDefault().id) }
                .getOrDefault(TimeZone.getDefault()).toZoneId(),
        ),
    )
}

@Composable
private fun scheduleErrorMessage(code: String?): String = when (code) {
    "notFound" -> stringResource(R.string.schedule_error_not_found)
    "revisionMismatch" -> stringResource(R.string.schedule_error_revision)
    "promptInvalid", "titleInvalid", "invalidPayload" ->
        stringResource(R.string.schedule_error_prompt)
    "modelUnavailable" -> stringResource(R.string.schedule_error_model)
    "workspaceUnavailable", "workspaceNotProject" ->
        stringResource(R.string.schedule_error_workspace)
    "environmentUnavailable", "environmentNotProject", "environmentSnapshotMissing" ->
        stringResource(R.string.schedule_error_environment)
    "componentUnavailable", "componentVersionStale", "componentIdentityMismatch",
    "rootfsUnverified", "engineProtocolUnsupported", "engineIdentityUnreported",
    "peerUnverified", "metadataMalformed" ->
        stringResource(R.string.schedule_error_environment_authority)
    "upstreamRunRequired", "upstreamRunUnavailable" ->
        stringResource(R.string.schedule_error_upstream)
    "payloadTooLarge" -> stringResource(R.string.schedule_error_payload_too_large)
    "exactAlarmPermission" -> stringResource(R.string.schedule_error_exact)
    "notifications_blocked" -> stringResource(R.string.schedule_error_notifications)
    "timeout", "runtime_unavailable", "runtimeUnavailable", "superseded" ->
        stringResource(R.string.schedule_error_runtime)
    "storeUnavailable", "rearm_failed" -> stringResource(R.string.schedule_error_store)
    "launchRefused" -> stringResource(R.string.schedule_error_launch)
    else -> stringResource(R.string.schedule_error_generic)
}

@Composable
private fun cadenceLabel(summary: TaskScheduleSummary): Int = when (summary.cadence) {
    TaskScheduleCadence.ONCE -> R.string.schedule_cadence_once
    TaskScheduleCadence.DAILY -> R.string.schedule_cadence_daily
    TaskScheduleCadence.WEEKLY -> R.string.schedule_cadence_weekly
    TaskScheduleCadence.INTERVAL -> R.string.schedule_cadence_interval
    TaskScheduleCadence.AFTER_SUCCESS -> R.string.schedule_cadence_after_success
}

private fun statusLabel(status: TaskSchedulePresentationStatus): Int = when (status) {
    TaskSchedulePresentationStatus.ACTIVE -> R.string.schedule_status_active
    TaskSchedulePresentationStatus.FLEXIBLE -> R.string.schedule_status_flexible
    TaskSchedulePresentationStatus.WAITING_PERMISSION -> R.string.schedule_status_waiting
    TaskSchedulePresentationStatus.PAUSED -> R.string.schedule_status_paused
    TaskSchedulePresentationStatus.EVENT_DRIVEN -> R.string.schedule_status_event
    TaskSchedulePresentationStatus.NEEDS_ATTENTION -> R.string.schedule_status_attention
}

private fun statusIcon(status: TaskSchedulePresentationStatus) = when (status) {
    TaskSchedulePresentationStatus.ACTIVE -> FloeIcons.Clock
    TaskSchedulePresentationStatus.FLEXIBLE -> FloeIcons.Clock
    TaskSchedulePresentationStatus.WAITING_PERMISSION -> FloeIcons.Clock
    TaskSchedulePresentationStatus.PAUSED -> FloeIcons.StopSquare
    TaskSchedulePresentationStatus.EVENT_DRIVEN -> FloeIcons.PlayRuns
    TaskSchedulePresentationStatus.NEEDS_ATTENTION -> FloeIcons.StopSquare
}

@Composable
private fun statusColor(status: TaskSchedulePresentationStatus): Color = when (status) {
    TaskSchedulePresentationStatus.ACTIVE -> Floe.colors.success
    TaskSchedulePresentationStatus.FLEXIBLE -> Floe.colors.pending
    TaskSchedulePresentationStatus.WAITING_PERMISSION -> Floe.colors.pending
    TaskSchedulePresentationStatus.PAUSED -> Floe.colors.tertiaryLabel
    TaskSchedulePresentationStatus.EVENT_DRIVEN -> Floe.colors.accent
    TaskSchedulePresentationStatus.NEEDS_ATTENTION -> Floe.colors.destructive
}

private fun occurrenceStateLabel(state: String): Int = when (state) {
    "pending" -> R.string.schedule_state_pending
    "claimed" -> R.string.schedule_state_pending
    "running" -> R.string.schedule_state_running
    "completed" -> R.string.schedule_state_completed
    "failed" -> R.string.schedule_state_failed
    "cancelled" -> R.string.schedule_state_cancelled
    "skipped" -> R.string.schedule_state_skipped
    "interrupted" -> R.string.schedule_state_interrupted
    else -> R.string.schedule_state_pending
}

@Composable
private fun occurrenceStateColor(state: String): Color = when (state) {
    "completed" -> Floe.colors.success
    "failed", "interrupted" -> Floe.colors.destructive
    "running" -> Floe.colors.accent
    else -> Floe.colors.secondaryLabel
}

private fun String.takeUtf8Bytes(maxBytes: Int): String {
    if (utf8BytesLength() <= maxBytes) return this
    var result = StringBuilder()
    var used = 0
    for (character in this) {
        val bytes = character.toString().toByteArray(Charsets.UTF_8).size
        if (used + bytes > maxBytes) break
        result.append(character)
        used += bytes
    }
    return result.toString()
}

private fun String.utf8BytesLength(): Int = toByteArray(Charsets.UTF_8).size

@Composable
private fun approvalLabel(mode: String): String = when (mode) {
    "automatic" -> stringResource(R.string.schedule_approval_automatic)
    "fullAccess" -> stringResource(R.string.schedule_approval_full)
    else -> stringResource(R.string.schedule_approval_ask)
}

/** Human label for one REAL run choice: the owning conversation's title plus
 * the durable start time (never a raw run UUID in ordinary copy). */
@Composable
private fun runChoiceLabel(choice: TaskScheduleRunChoice): String {
    val title = choice.label.ifBlank { stringResource(R.string.schedule_run_untitled) }
    val started = choice.startedAtMillis?.let { TaskScheduleWire.isoLocal(it) }
    return if (started == null) title else "$title · $started"
}

@Composable
private fun weekdayLabel(day: Int): String {
    val names = listOf(
        R.string.schedule_weekday_sun,
        R.string.schedule_weekday_mon,
        R.string.schedule_weekday_tue,
        R.string.schedule_weekday_wed,
        R.string.schedule_weekday_thu,
        R.string.schedule_weekday_fri,
        R.string.schedule_weekday_sat,
    )
    return stringResource(names[(day - 1).coerceIn(0, 6)])
}
