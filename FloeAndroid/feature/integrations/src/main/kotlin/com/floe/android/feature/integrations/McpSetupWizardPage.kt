// SPDX-License-Identifier: MPL-2.0
//
// C02 guided Linux-owned MCP service setup.
//
// The module only collects an explicit user request and renders host
// projections. It never starts a process, saves a connection, writes a
// credential or claims a phase. A missing C01 service lane/template is shown
// as an honest limitation, not as a fake success.
package com.floe.android.feature.integrations

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeChoiceOption
import com.floe.android.design.FloeConfirmDialog
import com.floe.android.design.FloeFormChoiceField
import com.floe.android.design.FloeFormTextField
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeSectionRow
import com.floe.android.design.FloeSettingsSectionCard
import com.floe.android.design.FloeStatusLine
import com.floe.android.design.FloeSwitchRow
import com.floe.android.design.FloeText
import com.floe.android.design.IconGlyph
import io.github.robinpcrd.cupertino.section.SectionScope

@Composable
fun McpSetupWizardPage(
    setup: McpSetupUiState?,
    draft: McpSetupDraftUi,
    busy: Boolean,
    onDraft: (McpSetupDraftUi) -> Unit,
    onSelectProject: (String) -> Unit,
    onStart: () -> Unit,
    onCancel: (String, Long) -> Unit,
    onDiscard: (String, Long) -> Unit,
    onRetryCommit: (String, Long) -> Unit,
    onClearError: () -> Unit,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var discardCandidate by remember { mutableStateOf<McpSetupRecordUi?>(null) }
    var projectMenuOpen by remember { mutableStateOf(false) }
    var environmentMenuOpen by remember { mutableStateOf(false) }
    val options = setup?.options ?: McpSetupOptionsUi()
    val record = setup?.record
    val effectiveBusy = busy || setup?.busy == true || record?.busy == true
    val errorCode = setup?.errorCode
    val errorMessage = setup?.errorMessage
    val port = draft.portText.trim().toIntOrNull()

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(Floe.colors.groupedSurface)
            .testTag("mcp.setup")
            .imePadding()
            .navigationBarsPadding(),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 8.dp, end = 12.dp, top = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Box(Modifier.weight(1f)) {
                IntegrationPushedPaneHeader(
                    title = stringResource(R.string.mcp_setup_title),
                    onBack = onClose,
                )
            }
            if (effectiveBusy) {
                FloeActivityIndicator(description = stringResource(R.string.mcp_setup_progress))
            }
        }

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(bottom = 20.dp),
        ) {
            if (setup == null || options.loading) {
                Box(Modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) {
                    FloeActivityIndicator(description = stringResource(R.string.loading_cd))
                }
                return@Column
            }

            if (record == null) {
                SetupForm(
                    options = options,
                    draft = draft,
                    busy = effectiveBusy,
                    port = port,
                    projectMenuOpen = projectMenuOpen,
                    environmentMenuOpen = environmentMenuOpen,
                    onProjectMenu = { projectMenuOpen = it },
                    onEnvironmentMenu = { environmentMenuOpen = it },
                    onDraft = onDraft,
                    onSelectProject = onSelectProject,
                    onStart = onStart,
                    onClose = onClose,
                )
            } else {
                SetupProgress(record = record)
            }

            if (!errorCode.isNullOrBlank()) {
                IntegrationIssueLine(
                    localizedSetupError(errorCode),
                    modifier = Modifier.testTag("mcp.setup.error"),
                )
                if (record == null) {
                    CardActionLink(
                        label = stringResource(R.string.mcp_setup_retry),
                        tag = "mcp.setup.retry",
                        onClick = onClearError,
                    )
                }
            }

            if (record == null) {
                IntegrationSectionFooter(stringResource(R.string.mcp_setup_intro))
            } else {
                SetupActions(
                    record = record,
                    busy = effectiveBusy,
                    onCancel = { onCancel(record.id, record.revision) },
                    onDiscard = { discardCandidate = record },
                    onRetryCommit = onRetryCommit,
                    onDone = onClose,
                )
            }
        }
    }

    val candidate = discardCandidate
    if (candidate != null) {
        FloeConfirmDialog(
            title = stringResource(R.string.mcp_setup_discard_confirm_title),
            message = stringResource(R.string.mcp_setup_discard_confirm_message),
            confirmLabel = stringResource(R.string.mcp_setup_discard),
            dismissLabel = stringResource(R.string.action_cancel),
            onConfirm = {
                discardCandidate = null
                onDiscard(candidate.id, candidate.revision)
            },
            onDismiss = { discardCandidate = null },
        )
    }
}

@Composable
private fun SetupForm(
    options: McpSetupOptionsUi,
    draft: McpSetupDraftUi,
    busy: Boolean,
    port: Int?,
    projectMenuOpen: Boolean,
    environmentMenuOpen: Boolean,
    onProjectMenu: (Boolean) -> Unit,
    onEnvironmentMenu: (Boolean) -> Unit,
    onDraft: (McpSetupDraftUi) -> Unit,
    onSelectProject: (String) -> Unit,
    onStart: () -> Unit,
    onClose: () -> Unit,
) {
    if (!options.serviceLaneAvailable) {
        IntegrationIssueLine(
            stringResource(R.string.mcp_setup_service_unavailable),
            modifier = Modifier.testTag("mcp.setup.serviceUnavailable"),
        )
    }
    if (!options.templateAvailable) {
        IntegrationIssueLine(stringResource(R.string.mcp_setup_template_unavailable))
    }

    FloeSettingsSectionCard(title = stringResource(R.string.mcp_setup_project)) {
        if (options.projects.isEmpty()) {
            FloeStatusLine(
                icon = FloeIcons.InfoCircle,
                text = stringResource(R.string.mcp_setup_empty_projects),
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
            )
        } else {
            FloeFormChoiceField(
                label = stringResource(R.string.mcp_setup_project),
                options = options.projects.map { FloeChoiceOption(it.id, it.name) },
                selectedKey = draft.projectId,
                expanded = projectMenuOpen,
                onExpandedChange = onProjectMenu,
                onSelect = onSelectProject,
            )
            FloeFormChoiceField(
                label = stringResource(R.string.mcp_setup_environment),
                options = options.environments.map { FloeChoiceOption(it.id, it.label) },
                selectedKey = draft.environmentId,
                expanded = environmentMenuOpen,
                onExpandedChange = onEnvironmentMenu,
                onSelect = { environmentId -> onDraft(draft.copy(environmentId = environmentId)) },
            )
            if (draft.projectId != null && options.environments.isEmpty()) {
                IntegrationMetaLine(stringResource(R.string.mcp_setup_empty_env))
            }
        }
        FloeFormTextField(
            label = stringResource(R.string.mcp_setup_name),
            value = draft.displayName,
            onValueChange = { onDraft(draft.copy(displayName = it)) },
        )
        FloeFormTextField(
            label = stringResource(R.string.mcp_setup_port),
            value = draft.portText,
            onValueChange = { onDraft(draft.copy(portText = it)) },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
        )
        FloeSwitchRow(
            title = stringResource(R.string.mcp_setup_allow_canvas),
            checked = draft.allowInCanvas,
            onCheckedChange = { onDraft(draft.copy(allowInCanvas = it)) },
        )
        val canStart = !busy && options.templateAvailable && options.serviceLaneAvailable &&
            draft.displayName.isNotBlank() && draft.projectId != null &&
            draft.environmentId != null && port != null && port in 1_024..65_535
        IntegrationEditorToolbar(
            confirmLabel = stringResource(
                if (busy) R.string.mcp_setup_creating else R.string.mcp_setup_start),
            cancelLabel = stringResource(R.string.action_cancel),
            inFlight = busy,
            confirmEnabled = canStart,
            onCancel = onClose,
            onConfirm = onStart,
            confirmTag = "mcp.setup.start",
        )
    }
}

@Composable
private fun SetupProgress(record: McpSetupRecordUi) {
    val title = if (record.displayName.isBlank()) {
        stringResource(R.string.mcp_setup_title)
    } else {
        record.displayName
    }
    FloeSettingsSectionCard(title = title) {
        SetupFact(stringResource(R.string.mcp_setup_project), record.projectName)
        SetupFact(stringResource(R.string.mcp_setup_environment), record.environmentLabel)
        SetupFact(stringResource(R.string.mcp_setup_port), record.port.toString())
        SetupFact(stringResource(R.string.mcp_setup_progress), phaseLabel(record.phase))
        if (record.phase == "added") {
            FloeStatusLine(
                icon = FloeIcons.CheckCircle,
                text = stringResource(R.string.mcp_setup_added),
                color = Floe.colors.success,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
            )
        }
        record.serviceEndpoint?.let {
            SetupFact(stringResource(R.string.mcp_setup_endpoint), it)
        }
        record.receipt?.let { receipt ->
            SetupFact(
                stringResource(R.string.mcp_setup_tools),
                receipt.verifiedTools.size.toString(),
            )
        }
    }
    if (record.steps.isNotEmpty()) {
        FloeSettingsSectionCard(title = stringResource(R.string.mcp_setup_steps)) {
            record.steps.forEach { step ->
                FloeSectionRow(
                    leading = {
                        IconGlyph(
                            icon = when (step.state) {
                                "completed" -> FloeIcons.CheckCircle
                                "failed", "cancelled" -> FloeIcons.WarningTriangle
                                else -> FloeIcons.Refresh
                            },
                            tint = when (step.state) {
                                "completed" -> Floe.colors.success
                                "failed", "cancelled" -> Floe.colors.destructive
                                else -> Floe.colors.secondaryLabel
                            },
                            size = 18.dp,
                        )
                    },
                    title = {
                        Column {
                            FloeText(
                                stepLabel(step.name),
                                style = Floe.typography.body,
                                color = Floe.colors.label,
                            )
                            FloeText(
                                stepStateLabel(step.state),
                                style = Floe.typography.metadata,
                                color = if (step.state == "failed") Floe.colors.destructive
                                else Floe.colors.secondaryLabel,
                            )
                        }
                    },
                )
            }
        }
        IntegrationSectionFooter(stringResource(R.string.mcp_setup_intro))
    }
}

@Composable
private fun SectionScope.SetupFact(label: String, value: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        FloeText(
            label,
            style = Floe.typography.body,
            color = Floe.colors.secondaryLabel,
            modifier = Modifier.weight(1f),
        )
        FloeText(
            value,
            style = Floe.typography.body,
            color = Floe.colors.label,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun SetupActions(
    record: McpSetupRecordUi,
    busy: Boolean,
    onCancel: () -> Unit,
    onDiscard: () -> Unit,
    onRetryCommit: (String, Long) -> Unit,
    onDone: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        if (busy || record.busy) {
            CardActionLink(
                label = stringResource(R.string.mcp_setup_cancel),
                tag = "mcp.setup.cancel",
                onClick = onCancel,
            )
        } else if (record.phase == "added") {
            CardActionLink(
                label = stringResource(R.string.mcp_setup_done),
                tag = "mcp.setup.done",
                onClick = onDone,
            )
        } else {
            if (record.phase == "ready") {
                CardActionLink(
                    label = stringResource(R.string.mcp_setup_retry_commit),
                    tag = "mcp.setup.retryCommit",
                    onClick = { onRetryCommit(record.id, record.revision) },
                )
            }
            CardActionLink(
                label = stringResource(R.string.mcp_setup_discard),
                tag = "mcp.setup.discard",
                onClick = onDiscard,
            )
            CardActionLink(
                label = stringResource(R.string.mcp_setup_done),
                tag = "mcp.setup.close",
                onClick = onDone,
            )
        }
    }
}

@Composable
private fun localizedSetupError(code: String): String {
    val resource = when (code) {
        "invalidDraft" -> R.string.mcp_setup_error_invalidDraft
        "projectRequired" -> R.string.mcp_setup_error_projectRequired
        "projectChanged" -> R.string.mcp_setup_error_projectChanged
        "environmentRequired" -> R.string.mcp_setup_error_environmentRequired
        "portInvalid" -> R.string.mcp_setup_error_portInvalid
        "nameRequired" -> R.string.mcp_setup_error_nameRequired
        "detailsTooLong" -> R.string.mcp_setup_error_detailsTooLong
        "templateMissing" -> R.string.mcp_setup_error_templateMissing
        "serviceLaneUnavailable" -> R.string.mcp_setup_error_serviceLaneUnavailable
        "generationUnavailable" -> R.string.mcp_setup_error_generationUnavailable
        "buildStepFailed" -> R.string.mcp_setup_error_buildStepFailed
        "verificationFailed", "serviceNotRunning", "serviceEndpointMismatch" ->
            R.string.mcp_setup_error_verificationFailed
        "smokeTestFailed" -> R.string.mcp_setup_error_smokeTestFailed
        "connectionSaveFailed" -> R.string.mcp_setup_error_connectionSaveFailed
        "staleRecord" -> R.string.mcp_setup_error_staleRecord
        "alreadyAdded" -> R.string.mcp_setup_error_alreadyAdded
        else -> R.string.mcp_setup_error_unavailable
    }
    return stringResource(resource)
}

@Composable
private fun phaseLabel(phase: String): String = stringResource(
    when (phase) {
        "preparing" -> R.string.mcp_setup_phase_preparing
        "prepared" -> R.string.mcp_setup_phase_prepared
        "generating" -> R.string.mcp_setup_phase_generating
        "building" -> R.string.mcp_setup_phase_building
        "readyToStart" -> R.string.mcp_setup_phase_readyToStart
        "starting" -> R.string.mcp_setup_phase_starting
        "verifying" -> R.string.mcp_setup_phase_verifying
        "ready" -> R.string.mcp_setup_phase_ready
        "added" -> R.string.mcp_setup_phase_added
        "stopping" -> R.string.mcp_setup_phase_stopping
        "stopped" -> R.string.mcp_setup_phase_stopped
        "interrupted" -> R.string.mcp_setup_phase_interrupted
        else -> R.string.mcp_setup_phase_failed
    },
)

@Composable
private fun stepLabel(name: String): String = stringResource(
    when (name) {
        "probe" -> R.string.mcp_setup_step_probe
        "install" -> R.string.mcp_setup_step_install
        "compile" -> R.string.mcp_setup_step_compile
        "test" -> R.string.mcp_setup_step_test
        else -> R.string.mcp_setup_steps
    },
)

@Composable
private fun stepStateLabel(state: String): String = stringResource(
    when (state) {
        "pending" -> R.string.mcp_setup_state_pending
        "running" -> R.string.mcp_setup_state_running
        "completed" -> R.string.mcp_setup_state_completed
        "failed" -> R.string.mcp_setup_state_failed
        "cancelled" -> R.string.mcp_setup_state_cancelled
        else -> R.string.mcp_setup_state_pending
    },
)
