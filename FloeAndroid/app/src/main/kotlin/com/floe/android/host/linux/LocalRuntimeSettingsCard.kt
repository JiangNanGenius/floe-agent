@file:OptIn(io.github.robinpcrd.cupertino.ExperimentalCupertinoApi::class)
package com.floe.android.host.linux

import androidx.compose.foundation.background
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
import android.text.format.Formatter
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.FloeApplication
import com.floe.android.R
import com.floe.android.design.*
import com.floe.android.terminalWorkspaceMappingPending
import io.github.robinpcrd.cupertino.section.SectionItem
import kotlinx.coroutines.launch

/** Uses the same second-level modal and Floe components as other settings. */
@Composable
fun LocalRuntimeSettingsCard() {
    val context = LocalContext.current
    val app = context.applicationContext as FloeApplication
    val clipboard = LocalClipboardManager.current
    val host = app.linuxSetup
    var visible by rememberSaveable { mutableStateOf(false) }
    val state by host.state.collectAsState()
    val notificationPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) host.prepare() else host.openNotificationSettings()
    }
    Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
        FloeSettingsSectionCard(title = stringResource(R.string.linux_environment_title)) {
            SectionItem(title = {
                Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable {
                    visible = true; host.engage()
                }, verticalAlignment = Alignment.CenterVertically) {
                    FloeText(stringResource(R.string.linux_environment_title), style = Floe.typography.body,
                        color = Floe.colors.label, modifier = Modifier.weight(1f))
                    FloeText(if (state.phase == LocalRuntimeSetupHost.Phase.INSTALLING ||
                            state.phase == LocalRuntimeSetupHost.Phase.COMPONENT_INSTALLING)
                            state.progress?.percent?.let { stringResource(R.string.linux_progress_percent, it) }
                                ?: stringResource(R.string.linux_progress_active)
                        else stringResource(R.string.linux_environment_open), style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel)
                }
            })
        }
    }
    if (visible) {
        val wide = LocalConfiguration.current.screenWidthDp >= 700
        FloePageSheet(visible = true, onDismiss = { visible = false },
            widthFraction = if (wide) 0.56f else 1f,
            heightFraction = if (wide) 0.66f else 0.74f,
            placement = if (wide) FloeSheetPlacement.CENTER else FloeSheetPlacement.BOTTOM,
            topInset = if (wide) 0.dp else FloeLayout.SettingsSheetTopInset) {
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    FloeText(stringResource(R.string.linux_environment_title), style = Floe.typography.title,
                        color = Floe.colors.label, modifier = Modifier.weight(1f))
                    FloeCapsuleAction(label = stringResource(R.string.done), onClick = { visible = false })
                }
                FloeText(stringResource(R.string.linux_environment_description), style = Floe.typography.body,
                    color = Floe.colors.secondaryLabel)
                if (state.progress == null || state.phase == LocalRuntimeSetupHost.Phase.FAILED ||
                    state.phase == LocalRuntimeSetupHost.Phase.STOPPING) FloeText(stringResource(when (state.phase) {
                    LocalRuntimeSetupHost.Phase.UNKNOWN -> R.string.linux_environment_loading
                    LocalRuntimeSetupHost.Phase.COMPONENT_REQUIRED -> R.string.linux_environment_component
                    LocalRuntimeSetupHost.Phase.COMPONENT_INSTALLING -> R.string.linux_component_waiting_system
                    LocalRuntimeSetupHost.Phase.SETUP_REQUIRED -> R.string.linux_environment_setup
                    LocalRuntimeSetupHost.Phase.INSTALL_REQUIRED -> R.string.linux_environment_install_needed
                    LocalRuntimeSetupHost.Phase.INSTALLING -> R.string.linux_environment_installing
                    LocalRuntimeSetupHost.Phase.INSTALLED -> R.string.linux_environment_installed
                    LocalRuntimeSetupHost.Phase.STOPPING -> R.string.linux_environment_stopping
                    LocalRuntimeSetupHost.Phase.FAILED -> R.string.linux_environment_failed
                }), style = Floe.typography.body, color = Floe.colors.label)
                state.failure?.let { failure ->
                    FloeText(stringResource(when (failure.category) {
                        "storage" -> R.string.linux_failure_storage
                        "dns" -> R.string.linux_failure_dns
                        "timeout" -> R.string.linux_failure_timeout
                        "tls" -> R.string.linux_failure_tls
                        "network" -> R.string.linux_failure_network
                        "server" -> R.string.linux_failure_server
                        "archive" -> R.string.linux_failure_archive
                        "permission" -> R.string.linux_failure_permission
                        "cancelled" -> R.string.linux_failure_cancelled
                        "compatibility" -> R.string.linux_failure_compatibility
                        "busy" -> R.string.linux_failure_busy
                        "runtime" -> R.string.linux_failure_runtime
                        "component" -> when (failure.code) {
                            "COMPONENT_ASSET_UNAVAILABLE", "COMPONENT_ARCHIVE_UNREADABLE",
                            "COMPONENT_SIZE_EXCEEDED" -> R.string.linux_failure_component_archive
                            "COMPONENT_DIGEST_MISMATCH" -> R.string.linux_failure_component_verify
                            "COMPONENT_CERTIFICATE_UNAVAILABLE" -> R.string.linux_failure_component_certificate
                            "COMPONENT_IDENTITY_MISMATCH" -> R.string.linux_failure_component_signature
                            "COMPONENT_PACKAGE_MISMATCH", "COMPONENT_VERSION_MISMATCH" -> R.string.linux_failure_component_version
                            "COMPONENT_COPY_FAILED" -> R.string.linux_failure_component_copy
                            "COMPONENT_SESSION_FAILED", "COMPONENT_INSTALL_FAILED" -> R.string.linux_failure_component_install
                            else -> R.string.linux_failure_component
                        }
                        else -> R.string.linux_failure_unknown
                    }), style = Floe.typography.body, color = Floe.colors.label)
                    var details by remember(failure) { mutableStateOf(false) }
                    FloeCapsuleAction(label = stringResource(R.string.linux_failure_details), onClick = { details = !details })
                    if (details) {
                        FloeText(host.diagnosticDetails(), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                        FloeCapsuleAction(label = stringResource(R.string.linux_failure_copy),
                            onClick = { clipboard.setText(AnnotatedString(host.diagnosticDetails())) })
                    }
                }
                if (state.phase == LocalRuntimeSetupHost.Phase.INSTALLING ||
                    state.phase == LocalRuntimeSetupHost.Phase.COMPONENT_INSTALLING)
                    state.progress?.let { LinuxSetupProgressPanel(it) }
                val busy = state.phase == LocalRuntimeSetupHost.Phase.INSTALLING || state.phase == LocalRuntimeSetupHost.Phase.STOPPING ||
                    state.phase == LocalRuntimeSetupHost.Phase.COMPONENT_INSTALLING
                if (state.pendingIntent != null) {
                    FloeCapsuleAction(label = stringResource(if (state.componentSessionID != null)
                        R.string.linux_component_view_installer else R.string.linux_environment_continue), onClick = {
                        host.consumeIntent()?.let { intent ->
                            try { context.startActivity(intent) }
                            catch (_: android.content.ActivityNotFoundException) { host.refresh() }
                            catch (_: SecurityException) { host.refresh() }
                        }
                    })
                } else if (!busy && state.phase != LocalRuntimeSetupHost.Phase.INSTALLED) {
                    FloeCapsuleAction(label = stringResource(R.string.linux_environment_prepare), onClick = {
                        if (android.os.Build.VERSION.SDK_INT >= 33 &&
                            context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                            notificationPermission.launch(android.Manifest.permission.POST_NOTIFICATIONS)
                        } else host.prepare()
                    })
                }
                if (state.phase == LocalRuntimeSetupHost.Phase.COMPONENT_INSTALLING && state.componentSessionID != null) {
                    FloeCapsuleAction(label = stringResource(R.string.cancel), onClick = { host.cancelComponentInstall() })
                }
                if (state.phase == LocalRuntimeSetupHost.Phase.INSTALLING) {
                    FloeCapsuleAction(label = stringResource(R.string.cancel), onClick = { host.cancelInstall() })
                }
                if (state.phase == LocalRuntimeSetupHost.Phase.INSTALLED) {
                    if (state.localNetworkPermissionNeeded && state.pendingIntent == null) {
                        FloeCapsuleAction(label = stringResource(R.string.linux_environment_local_network),
                            onClick = { host.requestLocalNetworkAccess() })
                    }
                    // Truthful task-execution state: ONE bounded observation
                    // of the ORIGINAL readiness authority per open (no idle
                    // polling), plus one more after the system permission
                    // activity returns. A not-ready answer also reads the SAME
                    // closed stage authority Diagnostics opens, so the copy
                    // names the ONE real next step instead of a dead end: when
                    // every prerequisite is live and only this task's receipt-
                    // backed workspace facts are still missing, the terminal's
                    // own run-less first-use preparation produces them. Any
                    // other not-ready stage now ALSO names its honest cause
                    // class and offers the SAME authorized user-initiated
                    // recheck the Diagnostics surface uses — a bounded fresh
                    // re-measure that never reinstalls, redownloads or resets
                    // the installed environment.
                    var taskState by remember { mutableStateOf(LocalRuntimeTaskState.UNVERIFIED) }
                    var readinessToken by remember { mutableStateOf<String?>(null) }
                    var rechecking by remember { mutableStateOf(false) }
                    val scope = rememberCoroutineScope()
                    LaunchedEffect(state.phase, state.localNetworkPermissionNeeded, state.pendingIntent != null) {
                        val ready = app.linuxTaskExecutionReady()
                        readinessToken = if (ready) null else app.linuxTaskExecutionDiagnostic()
                        taskState = localRuntimeTaskState(ready, readinessToken)
                    }
                    FloeText(stringResource(when (taskState) {
                        LocalRuntimeTaskState.READY -> R.string.linux_environment_tools_ready
                        LocalRuntimeTaskState.PREPARING_WORKSPACE ->
                            R.string.linux_environment_tools_prepare_terminal
                        LocalRuntimeTaskState.UNVERIFIED -> R.string.linux_environment_tools_pending
                    }), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                    if (taskState == LocalRuntimeTaskState.UNVERIFIED) {
                        // Concise bilingual recovery copy for the observed
                        // not-ready stage; the closed codes stay behind the
                        // explicit details expander below.
                        FloeText(stringResource(when (localRuntimeRecovery(readinessToken)) {
                            LocalRuntimeRecovery.PROBE -> R.string.linux_environment_tools_probe_unavailable
                            LocalRuntimeRecovery.LINK -> R.string.linux_environment_tools_link_pending
                            LocalRuntimeRecovery.COMPONENT ->
                                R.string.linux_environment_tools_component_mismatch
                            LocalRuntimeRecovery.ATTEMPT_FAILED ->
                                R.string.linux_environment_tools_attempt_failed
                            // Defensive only: the UNVERIFIED branch never
                            // classifies as NONE (ready / mapping-pending are
                            // the other two task states).
                            LocalRuntimeRecovery.NONE -> R.string.linux_environment_tools_link_pending
                        }), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                        var readinessDetails by remember { mutableStateOf(false) }
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp),
                            verticalAlignment = Alignment.CenterVertically) {
                            FloeCapsuleAction(label = stringResource(
                                if (rechecking) R.string.checking else R.string.linux_environment_recheck),
                                enabled = !rechecking, onClick = {
                                    // ONE bounded user-initiated fresh re-ingress
                                    // through the SAME authorized primitive the
                                    // Diagnostics surface uses, then ONE fresh
                                    // observation. Cancellation propagates and
                                    // never publishes a stale readiness answer.
                                    scope.launch {
                                        try {
                                            rechecking = true
                                            app.retryLinuxTaskExecutionIngress()
                                            val ready = app.linuxTaskExecutionReady()
                                            readinessToken =
                                                if (ready) null else app.linuxTaskExecutionDiagnostic()
                                            taskState = localRuntimeTaskState(ready, readinessToken)
                                        } finally {
                                            rechecking = false
                                        }
                                    }
                                })
                            FloeCapsuleAction(label = stringResource(R.string.linux_failure_details),
                                onClick = { readinessDetails = !readinessDetails })
                        }
                        if (readinessDetails) {
                            val detailText = buildString {
                                append(host.diagnosticDetails())
                                readinessToken?.let { appendLine("Readiness: $it") }
                            }
                            FloeText(detailText, style = Floe.typography.metadata,
                                color = Floe.colors.secondaryLabel)
                            FloeCapsuleAction(label = stringResource(R.string.linux_failure_copy),
                                onClick = { clipboard.setText(AnnotatedString(detailText)) })
                        }
                    }
                }
            }
        }
    }
}

/** Compact measured progress, kept in the application-owned setup host across sheet dismissal. */
@Composable
private fun LinuxSetupProgressPanel(value: LinuxSetupProgress) {
    val context = LocalContext.current
    fun size(bytes: Long) = Formatter.formatShortFileSize(context, bytes.coerceAtLeast(0))
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            FloeText(stringResource(when (value.stage) {
                LinuxSetupStage.COMPONENT_FILE -> R.string.linux_progress_component_file
                LinuxSetupStage.COMPONENT_INSTALL -> R.string.linux_component_waiting_system
                LinuxSetupStage.PREFLIGHT -> R.string.linux_progress_preflight
                LinuxSetupStage.DOWNLOAD -> R.string.linux_progress_download
                LinuxSetupStage.VERIFY -> R.string.linux_progress_verify
                LinuxSetupStage.EXTRACT -> R.string.linux_progress_extract
                LinuxSetupStage.PUBLISH -> R.string.linux_progress_publish
                LinuxSetupStage.CONFIGURE -> R.string.linux_progress_configure
            }), style = Floe.typography.metadata, color = Floe.colors.label, modifier = Modifier.weight(1f))
            value.percent?.let { FloeText(stringResource(R.string.linux_progress_percent, it),
                style = Floe.typography.metadata, color = Floe.colors.secondaryLabel) }
        }
        value.percent?.let { percent ->
            Box(Modifier.fillMaxWidth().height(4.dp).clip(RoundedCornerShape(2.dp))
                .background(Floe.colors.secondaryLabel.copy(alpha = .15f))) {
                Box(Modifier.fillMaxHeight().fillMaxWidth(percent / 100f).background(Floe.colors.accent))
            }
        }
        if (value.transfer) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                FloeText(if (value.total > 0) stringResource(R.string.linux_progress_bytes,
                    size(value.bytes), size(value.total)) else size(value.bytes),
                    style = Floe.typography.metadata, color = Floe.colors.secondaryLabel,
                    modifier = Modifier.weight(1f))
                value.bytesPerSecond?.let { FloeText(stringResource(R.string.linux_progress_rate, size(it)),
                    style = Floe.typography.metadata, color = Floe.colors.secondaryLabel) }
            }
        } else if (value.stage == LinuxSetupStage.EXTRACT) {
            FloeText(stringResource(R.string.linux_progress_extracted, value.entries, size(value.extractedBytes)),
                style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
        }
    }
}

/**
 * COPY-ONLY projection of the ORIGINAL local-task readiness authority for the
 * Settings card. It qualifies nothing, gates nothing and writes nothing: the
 * boolean still comes from `linuxTaskExecutionReady()` (the seven-fact live
 * ingress), and [diagnostic] is the SAME closed stage token the Diagnostics
 * surface reads (`ready` | `lane:unbound` | `status:unreadable` |
 * `<cause>|refusal:<closed>|stage:<closed>`).
 *
 * [PREPARING_WORKSPACE] is returned ONLY for the exact stage shape the
 * terminal's own first-use classifier already accepts: every prerequisite is
 * live, only this task's receipt-backed `workspaceMappingSynced` /
 * `leaseAuthorityQualified` facts are missing, and no attempt failed for this
 * generation (both attempt tokens empty). Everything else — a missing
 * prerequisite, an unbound lane, an unreadable status, a failed attempt,
 * unknown text — stays [UNVERIFIED] and keeps the existing setup-neutral copy,
 * so this function can never turn an unproven lane into an actionable promise.
 */
internal enum class LocalRuntimeTaskState { READY, PREPARING_WORKSPACE, UNVERIFIED }

internal fun localRuntimeTaskState(ready: Boolean, diagnostic: String?): LocalRuntimeTaskState =
    when {
        ready -> LocalRuntimeTaskState.READY
        terminalWorkspaceMappingPending(diagnostic) -> LocalRuntimeTaskState.PREPARING_WORKSPACE
        else -> LocalRuntimeTaskState.UNVERIFIED
    }

/**
 * COPY-ONLY recovery-class projection of the SAME closed readiness stage
 * token the card reads (`linuxTaskExecutionDiagnostic` vocabulary). It
 * qualifies nothing, gates nothing and writes nothing: it maps the honest
 * closed token onto the ONE real next-step class so the installed card can
 * tell apart a generic capability-probe failure, a missing prerequisite
 * link, a runtime-component mismatch and an actual failed readiness
 * attempt — without ever inventing a cause or widening any gate. Pure,
 * total, never throws.
 */
internal enum class LocalRuntimeRecovery {
    /** Ready, or the exact run-less first-use shape where opening a terminal
     *  produces the two workspace facts: the existing state copy already
     *  names the real next step, so no recovery guidance is added. */
    NONE,

    /** The capability probe itself could not run or be read (lane unbound,
     *  status unreadable or unknown): a recheck re-measures it. */
    PROBE,

    /** A prerequisite link between the installed rootfs and the live runtime
     *  is missing (peer anchor, live epoch, suspension or an unaccepted
     *  fact record): the recheck re-runs the SAME verified install-
     *  completion ingress the transition uses. */
    LINK,

    /** The installed runtime component does not match this Floe build:
     *  updating Floe and the component together is the real fix. */
    COMPONENT,

    /** The five prerequisites are live but a real readiness attempt recorded
     *  a refusal/stage this generation: opening a terminal in a task (or a
     *  recheck) is the honest recovery. */
    ATTEMPT_FAILED,
}

/** Component-mismatch refusal tokens (the RuntimeComponentMatch closed set). */
private val COMPONENT_REFUSALS = setOf(
    "componentUnavailable", "componentVersionStale", "componentIdentityMismatch",
)

internal fun localRuntimeRecovery(diagnostic: String?): LocalRuntimeRecovery {
    if (diagnostic.isNullOrEmpty()) return LocalRuntimeRecovery.PROBE
    if (diagnostic == "ready") return LocalRuntimeRecovery.NONE
    // Run-less first-use shapes stay on the existing "open a terminal" copy.
    if (terminalWorkspaceMappingPending(diagnostic)) return LocalRuntimeRecovery.NONE
    // Closed grammar: <cause>|refusal:<closed>|stage:<closed>. Extract the
    // refusal/stage segments defensively; a token without the grammar is
    // classified by its cause alone.
    val refusal = diagnostic.substringAfter("refusal:", "").substringBefore('|', "")
    val stage = diagnostic.substringAfterLast("stage:", "")
    // The component codes may ride EITHER closed segment: the readiness
    // ingress surfaces them in `refusal:` (epoch-tagged controller record),
    // while a preflight/grant-lane recording puts the same closed vocabulary
    // into `stage:`. Checking only `refusal:` left a recorded component
    // mismatch misclassified as a generic attempt failure with futile
    // "open a terminal / recheck" guidance.
    if (refusal in COMPONENT_REFUSALS || stage in COMPONENT_REFUSALS)
        return LocalRuntimeRecovery.COMPONENT
    val cause = diagnostic.substringBefore('|', diagnostic)
    if (cause == "lane:unbound" || cause == "status:unreadable") return LocalRuntimeRecovery.PROBE
    if (refusal.isNotEmpty() || stage.isNotEmpty()) return LocalRuntimeRecovery.ATTEMPT_FAILED
    return LocalRuntimeRecovery.LINK
}
