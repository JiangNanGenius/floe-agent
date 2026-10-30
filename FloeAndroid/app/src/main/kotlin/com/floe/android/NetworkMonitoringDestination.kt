// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.floe.android.feature.network.R as FeatureNetworkR
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.floe.android.core.networkmonitor.NetworkMonitorConfig
import com.floe.android.core.networkmonitor.NetworkMonitorEndReason
import com.floe.android.core.networkmonitor.NetworkMonitorLimits
import com.floe.android.core.networkmonitor.NetworkMonitorOwner
import com.floe.android.core.networkmonitor.NetworkMonitorPhase
import com.floe.android.core.networkmonitor.NetworkMonitorProbe
import com.floe.android.core.networkmonitor.NetworkMonitorReportFiles
import com.floe.android.core.networkmonitor.NetworkMonitorSessionState
import com.floe.android.design.Floe
import com.floe.android.design.FloeCapsuleButton
import com.floe.android.design.FloeCheckboxRow
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloeText
import com.floe.android.host.RuntimeHost
import com.floe.android.host.networkmonitor.NetworkMonitorHost
import com.floe.android.host.networkmonitor.NetworkMonitorHostStartFailure
import com.floe.android.host.networkmonitor.NetworkMonitorHostStartResult
import com.floe.android.host.networkmonitor.NetworkMonitorReportWriteFailure
import com.floe.android.host.networkmonitor.NetworkMonitorReportWriteResult
import com.floe.android.safgateway.PickKind
import com.floe.android.safgateway.PickRequestSpec
import com.floe.android.safgateway.SafGrantFlagBits
import com.floe.android.safgateway.SafPickerIntents
import java.io.File
import java.util.Locale
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/*
 * G07.2 monitoring/report surface.
 *
 * The monitoring session itself is owned by the Application-scoped
 * NetworkMonitorHost (foreground dataSync Service). This composable only
 * observes its StateFlow, so rotation, navigation and background never start,
 * duplicate or stop a session. Start is an explicit user action admitted by
 * the host's real Activity-foreground callback; the permission callback never
 * replays a start. Stop carries the exact session ID and the typed engine
 * outcome remains the single authority. Reports are created by the core
 * renderer/store into an app-private atomic JSON+Markdown pair; export copies
 * only the exact user-chosen SAF document and never deletes that pair.
 */
@Composable
internal fun NetworkMonitoringDestination(
    host: RuntimeHost,
    modifier: Modifier = Modifier,
) {
    val monitor: NetworkMonitorHost = remember(host) { host.networkMonitorHost }
    val state by monitor.state.collectAsState()
    val context = LocalContext.current
    val activity = context as? Activity
    val lifecycleOwner = context as? ComponentActivity
    val scope = rememberCoroutineScope()

    var permissionRevision by remember { mutableIntStateOf(0) }
    var requestedBefore by rememberSaveable { mutableStateOf(false) }
    var form by rememberSaveable(stateSaver = MonitorFormSaver) { mutableStateOf(MonitorFormValues()) }
    var problems by remember { mutableStateOf(emptyList<MonitorConfigProblem>()) }
    var startNotice by remember { mutableStateOf<StartNotice?>(null) }
    var startingSessionId by rememberSaveable { mutableStateOf<String?>(null) }
    var stopRequestedFor by remember { mutableStateOf<String?>(null) }
    var stopIssue by remember { mutableStateOf<MonitorStopIssue?>(null) }
    var detailed by rememberSaveable { mutableStateOf(false) }
    var reportCreating by remember { mutableStateOf(false) }
    var reportFailure by remember { mutableStateOf<NetworkMonitorReportWriteFailure?>(null) }
    var report by rememberSaveable(stateSaver = MonitorReportUiSaver) {
        mutableStateOf<MonitorReportUi?>(null)
    }
    var pendingExport by remember { mutableStateOf<PendingExport?>(null) }
    var exportState by remember { mutableStateOf<ExportState>(ExportState.Idle) }
    var exportJob by remember { mutableStateOf<Job?>(null) }

    // Real platform state, re-read on resume and after the explicit permission
    // result. The host revalidates notification access too and stops an owned
    // session if it was revoked.
    val permissionGranted = Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(
        context,
        Manifest.permission.POST_NOTIFICATIONS,
    ) == PackageManager.PERMISSION_GRANTED
    val notificationsEnabled = NotificationManagerCompat.from(context).areNotificationsEnabled()
    val canAskAgain = if (Build.VERSION.SDK_INT >= 33) {
        activity?.shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS) ?: true
    } else {
        true
    }
    val notificationGate = remember(
        permissionRevision, permissionGranted, notificationsEnabled, canAskAgain, requestedBefore,
    ) {
        monitorNotificationGate(
            apiLevel = Build.VERSION.SDK_INT,
            permissionGranted = permissionGranted,
            notificationsEnabled = notificationsEnabled,
            canAskAgain = canAskAgain,
            requestedBefore = requestedBefore,
        )
    }

    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { _ ->
        // Grant only. A completed permission dialog never starts monitoring;
        // the user must explicitly tap Start after returning.
        requestedBefore = true
        permissionRevision += 1
        monitor.onNotificationPermissionChanged()
    }
    // This observer is NOT a foreground authority (the host's start
    // admission uses FloeApplication.isActivityInForeground). It only
    // re-reads notification access after the dialog/settings return so a
    // revocation is shown and the host can stop its owned session.
    DisposableEffect(lifecycleOwner, monitor) {
        if (lifecycleOwner == null) return@DisposableEffect onDispose { }
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                permissionRevision += 1
                monitor.onNotificationPermissionChanged()
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    LaunchedEffect(state.sessionId, state.phase, state.isActive) {
        if (startingSessionId != null &&
            (state.sessionId == startingSessionId || state.isActive || state.isTerminal)
        ) {
            startingSessionId = null
        }
        if (state.isActive) startNotice = null
        if (!state.isActive) stopRequestedFor = null
        if (!state.isActive && state.phase != NetworkMonitorPhase.STOPPING) stopIssue = null
    }

    var clockNanos by remember { mutableLongStateOf(System.nanoTime()) }
    LaunchedEffect(state.sessionId, state.isActive) {
        while (state.isActive) {
            delay(1_000L)
            clockNanos = System.nanoTime()
        }
    }
    val elapsed = monitorElapsedSeconds(state, clockNanos)

    val openNotificationSettings: () -> Unit = {
        val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
        runCatching { context.startActivity(intent) }.onFailure {
            runCatching {
                context.startActivity(
                    Intent(
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.parse("package:${context.packageName}"),
                    ),
                )
            }
        }
    }

    val start: () -> Unit = {
        if (notificationGate != MonitorNotificationGate.ALLOWED ||
            state.isActive || startingSessionId != null || reportCreating
        ) {
            Unit
        } else {
            val parsed = MonitorConfigPolicy.parse(form)
            problems = parsed.problems
            startNotice = null
            val config = parsed.config
            if (config == null) {
                Unit
            } else {
                when (val result = monitor.startFromVisibleUserAction(
                    config,
                    NetworkMonitorOwner(host.networkMonitorOwnerId),
                )) {
                    is NetworkMonitorHostStartResult.Accepted -> {
                        startingSessionId = result.sessionId
                        // Keep any previous report visible until the new
                        // session actually owns the host state; visibleReport
                        // filters by the current session ID.
                        reportFailure = null
                        reportCreating = false
                        exportState = ExportState.Idle
                        pendingExport = null
                    }
                    is NetworkMonitorHostStartResult.AlreadyActive -> {
                        startingSessionId = result.sessionId
                        startNotice = StartNotice.AlreadyActive
                    }
                    is NetworkMonitorHostStartResult.Rejected -> {
                        startingSessionId = null
                        startNotice = StartNotice.Failed(result.reason)
                    }
                }
            }
        }
    }

    val stop: () -> Unit = stop@{
        val sessionId = state.sessionId ?: return@stop
        if (!state.isActive || stopRequestedFor == sessionId) return@stop
        stopRequestedFor = sessionId
        stopIssue = null
        if (!monitor.requestStop(sessionId)) {
            stopRequestedFor = null
            stopIssue = if (monitor.state.value.sessionId == sessionId) {
                MonitorStopIssue.ALREADY_ENDED
            } else {
                null
            }
            return@stop
        }
        host.scope.launch(Dispatchers.Main.immediate) {
            val joined = monitor.stopAndJoin(sessionId, MONITOR_STOP_JOIN_MILLIS)
            // Late completion never revives or edits a newer session.
            if (!joined && monitor.state.value.sessionId == sessionId) {
                stopIssue = MonitorStopIssue.SLOW
            }
        }
    }

    val createReport: () -> Unit = create@{
        val sessionId = state.sessionId ?: return@create
        if (reportCreating) return@create
        val reportDetailed = detailed
        reportCreating = true
        reportFailure = null
        exportState = ExportState.Idle
        scope.launch {
            try {
                when (val result = monitor.writeReport(sessionId, reportDetailed)) {
                    is NetworkMonitorReportWriteResult.Written -> {
                        report = MonitorReportUi(
                            sessionId = sessionId,
                            reportId = result.files.reportId,
                            detailed = reportDetailed,
                            files = result.files,
                        )
                    }
                    is NetworkMonitorReportWriteResult.Rejected -> reportFailure = result.reason
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                reportFailure = NetworkMonitorReportWriteFailure.WRITE_FAILED
            } finally {
                reportCreating = false
            }
        }
    }

    val onExportPicked: (MonitorExportFormat, String?, Int) -> Unit = { format, uriString, returnedFlags ->
        val pending = pendingExport
        if (pending == null || pending.format != format) {
            // A callback restored for a surface/report request this composition
            // no longer owns is dropped. The private report is untouched.
            if (uriString == null) exportState = ExportState.Cancelled
        } else {
            pendingExport = null
            val uri = uriString?.let { runCatching { Uri.parse(it) }.getOrNull() }
            if (uri == null) {
                exportState = ExportState.Cancelled
            } else if (uri.scheme != "content" ||
                returnedFlags and SafGrantFlagBits.GRANT_WRITE == 0
            ) {
                // The explicit system result must have granted write access to
                // this exact document; no broad or inferred grant is used.
                exportState = ExportState.Failed
            } else {
                exportState = ExportState.Exporting
                val file = pending.report.fileFor(format)
                val job = host.scope.launch(Dispatchers.Main.immediate) {
                    val outcome = try {
                        withContext(Dispatchers.IO) {
                            writeMonitorExport(context, uri, file, format)
                        }
                    } catch (cancelled: CancellationException) {
                        ExportOutcome.Incomplete
                    } catch (_: Throwable) {
                        ExportOutcome.Failed
                    }
                    // A late export completion never writes its state into a
                    // different session/report shown by this surface.
                    if (report?.reportId == pending.report.reportId) {
                        exportState = when (outcome) {
                            is ExportOutcome.Exported -> ExportState.Exported(outcome.bytes)
                            ExportOutcome.Cancelled -> ExportState.Cancelled
                            ExportOutcome.Incomplete -> ExportState.Incomplete
                            ExportOutcome.Failed -> ExportState.Failed
                        }
                    }
                }
                exportJob = job
            }
        }
    }
    val jsonExportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        val ok = result.resultCode == Activity.RESULT_OK
        onExportPicked(
            MonitorExportFormat.JSON,
            if (ok) SafPickerIntents.resultUriString(result.data) else null,
            if (ok) SafPickerIntents.resultFlags(result.data) else 0,
        )
    }
    val markdownExportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        val ok = result.resultCode == Activity.RESULT_OK
        onExportPicked(
            MonitorExportFormat.MARKDOWN,
            if (ok) SafPickerIntents.resultUriString(result.data) else null,
            if (ok) SafPickerIntents.resultFlags(result.data) else 0,
        )
    }

    val beginExport: (MonitorExportFormat) -> Unit = begin@ { format ->
        val currentReport = report ?: return@begin
        if (pendingExport != null || exportJob?.isActive == true) return@begin
        val pending = PendingExport(
            id = UUID.randomUUID().toString(),
            report = currentReport,
            format = format,
        )
        pendingExport = pending
        exportState = ExportState.Idle
        // Reuse the App's approved system CREATE_DOCUMENT intent helper. The
        // returned URI's ACTUAL write grant is checked before any bytes are
        // copied; no tree, broad-files or persisted grant is requested.
        val spec = PickRequestSpec(
            requestKey = "network-monitor-export-${pending.id}",
            kind = PickKind.CREATE_DOCUMENT,
            mimeTypes = listOf(format.mimeType),
            suggestedName = pending.suggestedName,
            initialDirectory = null,
        )
        val launched = runCatching {
            val intent = SafPickerIntents.from(spec)
            when (format) {
                MonitorExportFormat.JSON -> jsonExportLauncher.launch(intent)
                MonitorExportFormat.MARKDOWN -> markdownExportLauncher.launch(intent)
            }
        }.isSuccess
        if (!launched) {
            pendingExport = null
            exportState = ExportState.Failed
        }
    }

    val reportable = state.sessionId != null &&
        (state.observationCount > 0L || state.phase == NetworkMonitorPhase.COMPLETED)
    // The host/core already published the pair atomically; the export job
    // validates the exact file on its IO thread before any destination write.
    val visibleReport = report?.takeIf { it.sessionId == state.sessionId }

    LazyColumn(
        modifier.fillMaxHeight(),
        contentPadding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                FloeText(stringResource(FeatureNetworkR.string.network_monitor_title), style = Floe.typography.section)
                FloeText(
                    stringResource(FeatureNetworkR.string.network_phone_source),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                FloeText(stringResource(FeatureNetworkR.string.network_monitor_intro), style = Floe.typography.body)
                FloeText(
                    stringResource(FeatureNetworkR.string.network_monitor_scope),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
        }
        if (notificationGate != MonitorNotificationGate.ALLOWED) {
            item {
                NotificationPermissionCard(
                    gate = notificationGate,
                    onRequest = {
                        if (Build.VERSION.SDK_INT >= 33) {
                            permissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                        } else {
                            openNotificationSettings()
                        }
                    },
                    onSettings = openNotificationSettings,
                )
            }
        }
        if (!state.isActive) {
            item {
                MonitorConfigSection(
                    form = form,
                    onFormChange = {
                        form = it
                        problems = emptyList()
                    },
                    problems = problems,
                    startNotice = startNotice,
                    canStart = notificationGate == MonitorNotificationGate.ALLOWED &&
                        startingSessionId == null && !reportCreating,
                    starting = startingSessionId != null,
                    onStart = start,
                    onOpenNotificationSettings = openNotificationSettings,
                )
            }
        }
        if (state.sessionId != null) {
            item {
                MonitorSessionSection(
                    state = state,
                    elapsedSeconds = elapsed,
                    stopping = state.phase == NetworkMonitorPhase.STOPPING ||
                        stopRequestedFor == state.sessionId,
                    stopIssue = stopIssue,
                    onStop = stop,
                    onOpenNotificationSettings = openNotificationSettings,
                )
            }
        }
        if (reportable) {
            item {
                MonitorReportSection(
                    state = state,
                    detailed = detailed,
                    onDetailedChange = { detailed = it },
                    creating = reportCreating,
                    failure = reportFailure,
                    report = visibleReport,
                    exportState = exportState,
                    exporting = exportJob?.isActive == true,
                    onCreate = createReport,
                    onExportJson = { beginExport(MonitorExportFormat.JSON) },
                    onExportMarkdown = { beginExport(MonitorExportFormat.MARKDOWN) },
                    onCancelExport = {
                        exportJob?.cancel()
                        exportJob = null
                    },
                )
            }
        }
    }
}

@Composable
private fun NotificationPermissionCard(
    gate: MonitorNotificationGate,
    onRequest: () -> Unit,
    onSettings: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        FloeDivider()
        FloeText(stringResource(FeatureNetworkR.string.network_monitor_notifications_title), style = Floe.typography.section)
        FloeText(
            stringResource(
                if (gate == MonitorNotificationGate.REQUEST_PERMISSION) {
                    FeatureNetworkR.string.network_monitor_notifications_required
                } else {
                    FeatureNetworkR.string.network_monitor_notifications_off
                },
            ),
            style = Floe.typography.body,
        )
        FloeCapsuleButton(
            label = stringResource(
                if (gate == MonitorNotificationGate.REQUEST_PERMISSION) {
                    FeatureNetworkR.string.network_monitor_notifications_allow
                } else {
                    FeatureNetworkR.string.network_monitor_notifications_settings
                },
            ),
            onClick = if (gate == MonitorNotificationGate.REQUEST_PERMISSION) onRequest else onSettings,
            prominent = true,
        )
    }
}

@Composable
private fun MonitorConfigSection(
    form: MonitorFormValues,
    onFormChange: (MonitorFormValues) -> Unit,
    problems: List<MonitorConfigProblem>,
    startNotice: StartNotice?,
    canStart: Boolean,
    starting: Boolean,
    onStart: () -> Unit,
    onOpenNotificationSettings: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        FloeDivider()
        FloeText(stringResource(FeatureNetworkR.string.network_monitor_config), style = Floe.typography.section)
        FloePlainFormField(
            label = stringResource(FeatureNetworkR.string.network_monitor_duration),
            value = form.durationMinutes,
            onValueChange = { onFormChange(form.copy(durationMinutes = it.take(3))) },
            isError = MonitorConfigProblem.DURATION in problems,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
        )
        FloePlainFormField(
            label = stringResource(FeatureNetworkR.string.network_monitor_interval),
            value = form.intervalSeconds,
            onValueChange = { onFormChange(form.copy(intervalSeconds = it.take(4))) },
            isError = MonitorConfigProblem.INTERVAL in problems,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
        )
        FloeText(stringResource(FeatureNetworkR.string.network_monitor_checks), style = Floe.typography.bodyEmphasized)
        FloeCheckboxRow(
            label = stringResource(FeatureNetworkR.string.network_monitor_probe_status),
            checked = form.statusEnabled,
            onCheckedChange = { onFormChange(form.copy(statusEnabled = it)) },
        )
        FloeCheckboxRow(
            label = stringResource(FeatureNetworkR.string.network_monitor_probe_ping),
            checked = form.pingEnabled,
            onCheckedChange = { onFormChange(form.copy(pingEnabled = it)) },
        )
        if (form.pingEnabled) {
            FloePlainFormField(
                label = stringResource(FeatureNetworkR.string.network_monitor_host),
                value = form.pingHost,
                onValueChange = { onFormChange(form.copy(pingHost = it.take(253))) },
                isError = MonitorConfigProblem.HOST in problems,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
            )
        }
        FloeCheckboxRow(
            label = stringResource(FeatureNetworkR.string.network_monitor_probe_tcp),
            checked = form.tcpEnabled,
            onCheckedChange = { onFormChange(form.copy(tcpEnabled = it)) },
        )
        if (form.tcpEnabled) {
            FloePlainFormField(
                label = stringResource(FeatureNetworkR.string.network_monitor_host),
                value = form.tcpHost,
                onValueChange = { onFormChange(form.copy(tcpHost = it.take(253))) },
                isError = MonitorConfigProblem.HOST in problems,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
            )
            FloePlainFormField(
                label = stringResource(FeatureNetworkR.string.network_monitor_port),
                value = form.tcpPort,
                onValueChange = { onFormChange(form.copy(tcpPort = it.take(5))) },
                isError = MonitorConfigProblem.PORT in problems,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            )
        }
        FloeText(
            stringResource(FeatureNetworkR.string.network_monitor_limits),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
        problems.forEach { problem -> MonitorProblemText(problem) }
        startNotice?.let { notice -> StartNoticeText(notice, onOpenNotificationSettings) }
        FloeCapsuleButton(
            label = stringResource(
                if (starting) FeatureNetworkR.string.network_monitor_starting else FeatureNetworkR.string.network_monitor_start,
            ),
            onClick = onStart,
            enabled = canStart,
            prominent = true,
        )
    }
}

@Composable
private fun MonitorSessionSection(
    state: NetworkMonitorSessionState,
    elapsedSeconds: Long,
    stopping: Boolean,
    stopIssue: MonitorStopIssue?,
    onStop: () -> Unit,
    onOpenNotificationSettings: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        FloeDivider()
        FloeText(monitorPhaseTitle(state.phase), style = Floe.typography.section)
        FloeText(
            stringResource(FeatureNetworkR.string.network_monitor_session_time, formatMonitorElapsed(elapsedSeconds)),
            style = Floe.typography.body,
        )
        val dropped = state.droppedObservationCount.coerceIn(0L, state.observationCount)
        val retained = (state.observationCount - dropped).coerceAtLeast(0L)
        FloeText(
            stringResource(
                FeatureNetworkR.string.network_monitor_count,
                state.observationCount.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
                retained.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
            ),
            style = Floe.typography.body,
        )
        FloeText(
            stringResource(FeatureNetworkR.string.network_monitor_buffer, NetworkMonitorLimits.MAX_OBSERVATIONS),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
        if (state.isActive) {
            FloeText(
                stringResource(FeatureNetworkR.string.network_monitor_background_note),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
        }
        if (state.isTerminal) {
            state.endReason?.let { reason ->
                FloeText(
                    stringResource(FeatureNetworkR.string.network_monitor_end_reason, monitorEndReasonText(reason)),
                    style = Floe.typography.body,
                )
                if (reason == NetworkMonitorEndReason.NOTIFICATION_PERMISSION_REVOKED) {
                    FloeCapsuleButton(
                        label = stringResource(FeatureNetworkR.string.network_monitor_notifications_settings),
                        onClick = onOpenNotificationSettings,
                    )
                }
            }
        }
        val last = state.lastObservation
        if (last == null) {
            FloeText(
                stringResource(FeatureNetworkR.string.network_monitor_no_checks),
                style = Floe.typography.body,
                color = Floe.colors.secondaryLabel,
            )
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                FloeText(stringResource(FeatureNetworkR.string.network_monitor_last_check), style = Floe.typography.bodyEmphasized)
                FloeText(
                    stringResource(
                        FeatureNetworkR.string.network_monitor_check_line,
                        monitorMethodText(last.method),
                        monitorStatusText(last.status),
                    ),
                    style = Floe.typography.body,
                )
                FloeText(
                    stringResource(
                        FeatureNetworkR.string.network_monitor_check_duration,
                        ((last.finishedAtElapsedNanos - last.startedAtElapsedNanos) / 1_000_000L)
                            .coerceAtLeast(0L),
                    ),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                last.actualNetwork.booleans["available"]?.let { available ->
                    FloeText(
                        stringResource(
                            if (available) FeatureNetworkR.string.network_monitor_network_available
                            else FeatureNetworkR.string.network_monitor_network_unavailable,
                        ),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                }
                if (last.missingPermissions.isNotEmpty()) {
                    FloeText(
                        stringResource(FeatureNetworkR.string.network_monitor_missing_permission),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                }
            }
        }
        if (state.isActive) {
            FloeCapsuleButton(
                label = stringResource(
                    if (stopping) FeatureNetworkR.string.network_monitor_stopping else FeatureNetworkR.string.network_monitor_stop,
                ),
                onClick = onStop,
                enabled = !stopping,
            )
        }
        stopIssue?.let { issue ->
            FloeText(
                stringResource(
                    when (issue) {
                        MonitorStopIssue.ALREADY_ENDED -> FeatureNetworkR.string.network_monitor_stop_ended
                        MonitorStopIssue.SLOW -> FeatureNetworkR.string.network_monitor_stop_slow
                    },
                ),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
        }
    }
}

@Composable
private fun MonitorReportSection(
    state: NetworkMonitorSessionState,
    detailed: Boolean,
    onDetailedChange: (Boolean) -> Unit,
    creating: Boolean,
    failure: NetworkMonitorReportWriteFailure?,
    report: MonitorReportUi?,
    exportState: ExportState,
    exporting: Boolean,
    onCreate: () -> Unit,
    onExportJson: () -> Unit,
    onExportMarkdown: () -> Unit,
    onCancelExport: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        FloeDivider()
        FloeText(stringResource(FeatureNetworkR.string.network_monitor_report), style = Floe.typography.section)
        FloeText(stringResource(FeatureNetworkR.string.network_monitor_report_hint), style = Floe.typography.body)
        if (state.isActive) {
            FloeText(
                stringResource(FeatureNetworkR.string.network_monitor_report_current_note),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
        }
        FloeCheckboxRow(
            label = stringResource(FeatureNetworkR.string.network_monitor_report_detailed),
            checked = detailed,
            onCheckedChange = onDetailedChange,
        )
        FloeText(
            stringResource(
                if (detailed) FeatureNetworkR.string.network_monitor_report_detailed_note
                else FeatureNetworkR.string.network_monitor_report_redacted_note,
            ),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
        FloeCapsuleButton(
            label = stringResource(
                if (creating) FeatureNetworkR.string.network_monitor_report_creating
                else FeatureNetworkR.string.network_monitor_report_create,
            ),
            onClick = onCreate,
            enabled = !creating,
            prominent = true,
        )
        failure?.let { reason ->
            FloeText(
                stringResource(
                    when (reason) {
                        NetworkMonitorReportWriteFailure.SESSION_NOT_FOUND -> FeatureNetworkR.string.network_monitor_report_failed_session
                        NetworkMonitorReportWriteFailure.REPORT_TOO_LARGE -> FeatureNetworkR.string.network_monitor_report_failed_large
                        NetworkMonitorReportWriteFailure.WRITE_FAILED -> FeatureNetworkR.string.network_monitor_report_failed_write
                    },
                ),
                style = Floe.typography.metadata,
                color = Floe.colors.destructive,
            )
        }
        report?.let { ready ->
            FloeDivider()
            FloeText(
                stringResource(
                    FeatureNetworkR.string.network_monitor_report_ready,
                    stringResource(
                        if (ready.detailed) FeatureNetworkR.string.network_monitor_report_mode_detailed
                        else FeatureNetworkR.string.network_monitor_report_mode_redacted,
                    ),
                ),
                style = Floe.typography.bodyEmphasized,
            )
            FloeText(
                stringResource(FeatureNetworkR.string.network_monitor_report_storage),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                FloeCapsuleButton(
                    label = stringResource(FeatureNetworkR.string.network_monitor_export_json),
                    onClick = onExportJson,
                    enabled = !exporting,
                    modifier = Modifier.weight(1f),
                )
                FloeCapsuleButton(
                    label = stringResource(FeatureNetworkR.string.network_monitor_export_markdown),
                    onClick = onExportMarkdown,
                    enabled = !exporting,
                    modifier = Modifier.weight(1f),
                )
            }
            if (exporting) {
                FloeCapsuleButton(
                    label = stringResource(FeatureNetworkR.string.network_monitor_export_cancel),
                    onClick = onCancelExport,
                )
            }
            ExportStateText(exportState)
        }
    }
}

@Composable
private fun ExportStateText(state: ExportState) {
    when (state) {
        ExportState.Idle -> Unit
        ExportState.Exporting -> FloeText(
            stringResource(FeatureNetworkR.string.network_monitor_exporting),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
        is ExportState.Exported -> FloeText(
            stringResource(FeatureNetworkR.string.network_monitor_exported, state.bytes),
            style = Floe.typography.body,
        )
        ExportState.Cancelled -> FloeText(
            stringResource(FeatureNetworkR.string.network_monitor_export_cancelled),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
        ExportState.Incomplete -> FloeText(
            stringResource(FeatureNetworkR.string.network_monitor_export_incomplete),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
        ExportState.Failed -> FloeText(
            stringResource(FeatureNetworkR.string.network_monitor_export_failed),
            style = Floe.typography.metadata,
            color = Floe.colors.destructive,
        )
    }
}

@Composable
private fun MonitorProblemText(problem: MonitorConfigProblem) {
    FloeText(
        stringResource(
            when (problem) {
                MonitorConfigProblem.DURATION -> FeatureNetworkR.string.network_monitor_error_duration
                MonitorConfigProblem.INTERVAL -> FeatureNetworkR.string.network_monitor_error_interval
                MonitorConfigProblem.NO_PROBE -> FeatureNetworkR.string.network_monitor_error_probe
                MonitorConfigProblem.HOST -> FeatureNetworkR.string.network_monitor_error_host
                MonitorConfigProblem.PORT -> FeatureNetworkR.string.network_monitor_error_port
            },
        ),
        style = Floe.typography.metadata,
        color = Floe.colors.destructive,
    )
}

@Composable
private fun StartNoticeText(notice: StartNotice, onOpenNotificationSettings: () -> Unit) {
    val message = when (notice) {
        StartNotice.AlreadyActive -> stringResource(FeatureNetworkR.string.network_monitor_already_active)
        is StartNotice.Failed -> stringResource(
            when (notice.reason) {
                NetworkMonitorHostStartFailure.APP_NOT_FOREGROUND -> FeatureNetworkR.string.network_monitor_start_foreground
                NetworkMonitorHostStartFailure.NOTIFICATIONS_DISABLED -> FeatureNetworkR.string.network_monitor_start_notifications
                NetworkMonitorHostStartFailure.START_RESTRICTED -> FeatureNetworkR.string.network_monitor_start_restricted
                NetworkMonitorHostStartFailure.START_FAILED -> FeatureNetworkR.string.network_monitor_start_failed
            },
        )
    }
    FloeText(
        message,
        style = Floe.typography.metadata,
        color = if (notice is StartNotice.Failed) Floe.colors.destructive else Floe.colors.secondaryLabel,
    )
    if (notice is StartNotice.Failed &&
        notice.reason == NetworkMonitorHostStartFailure.NOTIFICATIONS_DISABLED
    ) {
        FloeCapsuleButton(
            label = stringResource(FeatureNetworkR.string.network_monitor_notifications_settings),
            onClick = onOpenNotificationSettings,
        )
    }
}

@Composable
private fun monitorPhaseTitle(phase: NetworkMonitorPhase): String = stringResource(
    when (phase) {
        NetworkMonitorPhase.IDLE -> FeatureNetworkR.string.network_waiting
        NetworkMonitorPhase.RUNNING -> FeatureNetworkR.string.network_monitor_phase_running
        NetworkMonitorPhase.STOPPING -> FeatureNetworkR.string.network_monitor_phase_stopping
        NetworkMonitorPhase.COMPLETED -> FeatureNetworkR.string.network_monitor_phase_completed
        NetworkMonitorPhase.FAILED -> FeatureNetworkR.string.network_monitor_phase_failed
    },
)

@Composable
private fun monitorEndReasonText(reason: NetworkMonitorEndReason): String = stringResource(
    when (reason) {
        NetworkMonitorEndReason.USER_STOP -> FeatureNetworkR.string.network_monitor_reason_user_stop
        NetworkMonitorEndReason.FOREGROUND_START_FAILED -> FeatureNetworkR.string.network_monitor_reason_start_failed
        NetworkMonitorEndReason.DURATION_REACHED -> FeatureNetworkR.string.network_monitor_reason_duration
        NetworkMonitorEndReason.DATA_CAP_REACHED -> FeatureNetworkR.string.network_monitor_reason_data_cap
        NetworkMonitorEndReason.NETWORK_CHANGED -> FeatureNetworkR.string.network_monitor_reason_network_changed
        NetworkMonitorEndReason.NETWORK_IDENTITY_UNAVAILABLE -> FeatureNetworkR.string.network_monitor_reason_network_identity
        NetworkMonitorEndReason.TIME_BUDGET_EXHAUSTED -> FeatureNetworkR.string.network_monitor_reason_time_budget
        NetworkMonitorEndReason.TASK_REMOVED -> FeatureNetworkR.string.network_monitor_reason_task_removed
        NetworkMonitorEndReason.NOTIFICATION_PERMISSION_REVOKED -> FeatureNetworkR.string.network_monitor_reason_notification
        NetworkMonitorEndReason.SERVICE_DESTROYED -> FeatureNetworkR.string.network_monitor_reason_service_stopped
        NetworkMonitorEndReason.EXECUTOR_FAILURE -> FeatureNetworkR.string.network_monitor_reason_probe_failed
    },
)

@Composable
private fun monitorMethodText(method: String): String = stringResource(
    when (method) {
        "network.status" -> FeatureNetworkR.string.network_monitor_probe_status
        "network.ping" -> FeatureNetworkR.string.network_monitor_probe_ping
        "network.tcpProbe" -> FeatureNetworkR.string.network_monitor_probe_tcp
        else -> FeatureNetworkR.string.network_monitor_method_other
    },
)

@Composable
private fun monitorStatusText(status: String): String = stringResource(
    when (status) {
        "ok" -> FeatureNetworkR.string.network_status_ok
        "partial" -> FeatureNetworkR.string.network_status_partial
        "permissionRequired" -> FeatureNetworkR.string.network_status_permissionRequired
        "unsupported" -> FeatureNetworkR.string.network_status_unsupported
        "cancelled" -> FeatureNetworkR.string.network_status_cancelled
        "timeout" -> FeatureNetworkR.string.network_status_timeout
        "error" -> FeatureNetworkR.string.network_status_error
        else -> FeatureNetworkR.string.network_status_unavailable
    },
)

/* ------------------------------ pure policy ------------------------------ */

internal enum class MonitorConfigProblem { DURATION, INTERVAL, NO_PROBE, HOST, PORT }

internal data class MonitorFormValues(
    val durationMinutes: String = "10",
    val intervalSeconds: String = "30",
    val statusEnabled: Boolean = true,
    val pingEnabled: Boolean = false,
    val pingHost: String = "",
    val tcpEnabled: Boolean = false,
    val tcpHost: String = "",
    val tcpPort: String = "443",
)

internal data class MonitorConfigParse(
    val config: NetworkMonitorConfig? = null,
    val problems: List<MonitorConfigProblem> = emptyList(),
)

/**
 * Mirrors the core bounds without doing any I/O. The only network work is the
 * service-owned session created after an explicit Start.
 */
internal object MonitorConfigPolicy {
    const val MIN_DURATION_MINUTES = 1
    const val MAX_DURATION_MINUTES = 60
    const val MIN_INTERVAL_SECONDS = 5
    const val MAX_INTERVAL_SECONDS = 300

    fun parse(values: MonitorFormValues): MonitorConfigParse {
        val problems = LinkedHashSet<MonitorConfigProblem>()
        val durationMinutes = values.durationMinutes.trim().toIntOrNull()
        if (durationMinutes == null || durationMinutes !in MIN_DURATION_MINUTES..MAX_DURATION_MINUTES) {
            problems += MonitorConfigProblem.DURATION
        }
        val intervalSeconds = values.intervalSeconds.trim().toIntOrNull()
        if (intervalSeconds == null || intervalSeconds !in MIN_INTERVAL_SECONDS..MAX_INTERVAL_SECONDS) {
            problems += MonitorConfigProblem.INTERVAL
        }
        val probes = mutableListOf<NetworkMonitorProbe>()
        if (values.statusEnabled) probes += NetworkMonitorProbe.status()
        if (values.pingEnabled) {
            val host = normalizeMonitorHost(values.pingHost)
            if (host == null) problems += MonitorConfigProblem.HOST
            else probes += NetworkMonitorProbe.ping(host)
        }
        if (values.tcpEnabled) {
            val host = normalizeMonitorHost(values.tcpHost)
            if (host == null) problems += MonitorConfigProblem.HOST
            val port = values.tcpPort.trim().toIntOrNull()
            if (port == null || port !in 1..65_535) problems += MonitorConfigProblem.PORT
            if (host != null && port != null && port in 1..65_535) {
                probes += NetworkMonitorProbe.tcp(host, port)
            }
        }
        if (!values.statusEnabled && !values.pingEnabled && !values.tcpEnabled) {
            problems += MonitorConfigProblem.NO_PROBE
        }
        if (problems.isNotEmpty() || durationMinutes == null || intervalSeconds == null) {
            return MonitorConfigParse(problems = problems.toList())
        }
        val config = NetworkMonitorConfig(
            durationMillis = durationMinutes * 60_000L,
            intervalMillis = intervalSeconds * 1_000L,
            probes = probes,
        )
        return MonitorConfigParse(config = config)
    }

    fun normalizeMonitorHost(raw: String): String? {
        val host = raw.trim()
        if (host.isEmpty() || host.length > 253) return null
        if (host.any { it.isWhitespace() || it == '/' || it == '@' || it == '?' || it == '#' }) return null
        return host
    }
}

internal enum class MonitorNotificationGate { ALLOWED, REQUEST_PERMISSION, OPEN_SETTINGS }

/**
 * Platform-only admission mirror. No permission is requested or granted here;
 * the caller must use the explicit system dialog/settings action.
 */
internal fun monitorNotificationGate(
    apiLevel: Int,
    permissionGranted: Boolean,
    notificationsEnabled: Boolean,
    canAskAgain: Boolean,
    requestedBefore: Boolean,
): MonitorNotificationGate {
    if (apiLevel < 33) {
        return if (notificationsEnabled) MonitorNotificationGate.ALLOWED
        else MonitorNotificationGate.OPEN_SETTINGS
    }
    if (!permissionGranted) {
        return if (requestedBefore && !canAskAgain) {
            MonitorNotificationGate.OPEN_SETTINGS
        } else {
            MonitorNotificationGate.REQUEST_PERMISSION
        }
    }
    return if (notificationsEnabled) MonitorNotificationGate.ALLOWED
    else MonitorNotificationGate.OPEN_SETTINGS
}

internal enum class MonitorExportFormat(
    val reportFileName: String,
    val mimeType: String,
    val extension: String,
    val maxBytes: Long,
) {
    JSON(
        reportFileName = "report.json",
        mimeType = "application/json",
        extension = "json",
        maxBytes = NetworkMonitorLimits.MAX_REPORT_JSON_BYTES.toLong(),
    ),
    MARKDOWN(
        reportFileName = "report.md",
        mimeType = "text/markdown",
        extension = "md",
        maxBytes = NetworkMonitorLimits.MAX_REPORT_MARKDOWN_BYTES.toLong(),
    ),
}

internal enum class MonitorExportValidation { VALID, MISSING, NOT_A_FILE, WRONG_NAME, EMPTY, TOO_LARGE }

internal fun validateMonitorExport(file: File?, format: MonitorExportFormat): MonitorExportValidation {
    if (file == null) return MonitorExportValidation.MISSING
    if (!file.exists()) return MonitorExportValidation.MISSING
    if (!file.isFile) return MonitorExportValidation.NOT_A_FILE
    val canonical = runCatching { file.canonicalFile }.getOrNull() ?: return MonitorExportValidation.MISSING
    if (canonical.name != format.reportFileName) return MonitorExportValidation.WRONG_NAME
    val length = canonical.length()
    if (length <= 0L) return MonitorExportValidation.EMPTY
    if (length > format.maxBytes) return MonitorExportValidation.TOO_LARGE
    return MonitorExportValidation.VALID
}

internal fun formatMonitorElapsed(totalSeconds: Long): String {
    val seconds = totalSeconds.coerceAtLeast(0L)
    val hours = seconds / 3600L
    val minutes = (seconds % 3600L) / 60L
    val remainder = seconds % 60L
    return if (hours > 0L) {
        String.format(Locale.US, "%d:%02d:%02d", hours, minutes, remainder)
    } else {
        String.format(Locale.US, "%d:%02d", minutes, remainder)
    }
}

internal fun monitorElapsedSeconds(state: NetworkMonitorSessionState, nowElapsedNanos: Long): Long =
    monitorElapsedSeconds(
        startedAtElapsedNanos = state.startedAtElapsedNanos,
        isActive = state.isActive,
        lastObservationFinishedAtElapsedNanos = state.lastObservation?.finishedAtElapsedNanos,
        nowElapsedNanos = nowElapsedNanos,
    )

/**
 * Active sessions use the monotonic current time; a terminal session shows
 * the time of its last completed check (the only end timestamp the host state
 * exposes). No end time is invented when the session never measured.
 */
internal fun monitorElapsedSeconds(
    startedAtElapsedNanos: Long,
    isActive: Boolean,
    lastObservationFinishedAtElapsedNanos: Long?,
    nowElapsedNanos: Long,
): Long {
    if (startedAtElapsedNanos <= 0L) return 0L
    return if (isActive) {
        ((nowElapsedNanos - startedAtElapsedNanos) / 1_000_000_000L).coerceAtLeast(0L)
    } else {
        lastObservationFinishedAtElapsedNanos?.let { finished ->
            ((finished - startedAtElapsedNanos) / 1_000_000_000L).coerceAtLeast(0L)
        } ?: 0L
    }
}

private enum class MonitorStopIssue { ALREADY_ENDED, SLOW }

private sealed interface StartNotice {
    data object AlreadyActive : StartNotice
    data class Failed(val reason: NetworkMonitorHostStartFailure) : StartNotice
}

private data class MonitorReportUi(
    val sessionId: String,
    val reportId: String,
    val detailed: Boolean,
    val files: NetworkMonitorReportFiles,
) {
    fun fileFor(format: MonitorExportFormat): File = when (format) {
        MonitorExportFormat.JSON -> files.jsonFile
        MonitorExportFormat.MARKDOWN -> files.markdownFile
    }
}

private data class PendingExport(
    val id: String,
    val report: MonitorReportUi,
    val format: MonitorExportFormat,
) {
    val suggestedName: String get() = "floe-network-monitor-${report.reportId.take(8)}.${format.extension}"
}

private sealed interface ExportState {
    data object Idle : ExportState
    data object Exporting : ExportState
    data class Exported(val bytes: Long) : ExportState
    data object Cancelled : ExportState
    data object Incomplete : ExportState
    data object Failed : ExportState
}

private sealed interface ExportOutcome {
    data class Exported(val bytes: Long) : ExportOutcome
    data object Cancelled : ExportOutcome
    data object Incomplete : ExportOutcome
    data object Failed : ExportOutcome
}

/**
 * Copies exactly the selected report file to the exact SAF document the user
 * chose. The private report pair is never modified. Success is returned only
 * after both streams close and every byte was written.
 */
private suspend fun writeMonitorExport(
    context: Context,
    uri: Uri,
    file: File,
    format: MonitorExportFormat,
): ExportOutcome {
    if (uri.scheme != "content") return ExportOutcome.Failed
    if (validateMonitorExport(file, format) != MonitorExportValidation.VALID) {
        return ExportOutcome.Failed
    }
    val total = file.length()
    var written = 0L
    try {
        // The URI grant belongs to the app; use the application resolver so a
        // completed write never depends on a destroyed Activity instance.
        val resolver = (context.applicationContext ?: context).contentResolver
        val output = resolver.openOutputStream(uri, "wt")
            ?: return ExportOutcome.Failed
        output.use { destination ->
            file.inputStream().use { source ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val count = source.read(buffer)
                    if (count < 0) break
                    destination.write(buffer, 0, count)
                    written += count
                }
            }
            destination.flush()
        }
    } catch (_: CancellationException) {
        return if (written > 0L) ExportOutcome.Incomplete else ExportOutcome.Cancelled
    } catch (_: Throwable) {
        return ExportOutcome.Failed
    }
    return if (written == total) ExportOutcome.Exported(written) else ExportOutcome.Failed
}

private val MonitorFormSaver = listSaver<MonitorFormValues, Any>(
    save = { form ->
        listOf(
            form.durationMinutes,
            form.intervalSeconds,
            form.statusEnabled,
            form.pingEnabled,
            form.pingHost,
            form.tcpEnabled,
            form.tcpHost,
            form.tcpPort,
        )
    },
    restore = { values ->
        if (values.size < 8) {
            MonitorFormValues()
        } else {
            MonitorFormValues(
                durationMinutes = values[0] as? String ?: "10",
                intervalSeconds = values[1] as? String ?: "30",
                statusEnabled = values[2] as? Boolean ?: true,
                pingEnabled = values[3] as? Boolean ?: false,
                pingHost = values[4] as? String ?: "",
                tcpEnabled = values[5] as? Boolean ?: false,
                tcpHost = values[6] as? String ?: "",
                tcpPort = values[7] as? String ?: "443",
            )
        }
    },
)

private val MonitorReportUiSaver = listSaver<MonitorReportUi?, Any>(
    save = { report ->
        report?.let {
            listOf(
                it.sessionId,
                it.reportId,
                it.detailed,
                it.files.directory.path,
                it.files.jsonFile.path,
                it.files.markdownFile.path,
                it.files.manifestFile.path,
            )
        } ?: emptyList()
    },
    restore = { values ->
        val sessionId = values.getOrNull(0) as? String
        val reportId = values.getOrNull(1) as? String
        val directory = (values.getOrNull(3) as? String)?.let(::File)
        val json = (values.getOrNull(4) as? String)?.let(::File)
        val markdown = (values.getOrNull(5) as? String)?.let(::File)
        val manifest = (values.getOrNull(6) as? String)?.let(::File)
        if (sessionId == null || reportId == null || directory == null || json == null ||
            markdown == null || manifest == null
        ) {
            null
        } else {
            MonitorReportUi(
                sessionId = sessionId,
                reportId = reportId,
                detailed = values.getOrNull(2) as? Boolean ?: false,
                files = NetworkMonitorReportFiles(
                    reportId = reportId,
                    directory = directory,
                    jsonFile = json,
                    markdownFile = markdown,
                    manifestFile = manifest,
                ),
            )
        }
    },
)

private const val MONITOR_STOP_JOIN_MILLIS = 5_000L
