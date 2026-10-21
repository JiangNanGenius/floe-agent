// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import com.floe.android.design.CupertinoMenuEntry
import com.floe.android.design.Floe
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeChipMenu
import com.floe.android.design.FloeChipTone
import com.floe.android.design.FloeComposer
import com.floe.android.design.FloeComposerChip
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeInfoDialog
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloeText
import com.floe.android.design.FloeToolbar
import com.floe.android.design.ComposerAvailability
import com.floe.android.host.HomeSendToken
import com.floe.android.host.RuntimeHost
import com.floe.android.feature.conversation.ApprovalModeUi
import com.floe.android.feature.conversation.FloeDraftAttachmentTray
import com.floe.android.feature.providers.ReasoningEffortUi

private enum class HomeDialog {
    NONE, TEMP_CHAT, VOICE, ATTACH, ATTACH_REFUSED, REASONING, REASONING_FAILED,
    PROJECT, TARGET, PERMISSIONS, SEND_FAILED,
}

/**
 * New-task launchpad: opaque reading surface, centered brand mark + welcome
 * line, and the bottom composer with the horizontal model/reasoning/project/
 * target/mode/permissions control row. Structure, copy and geometry follow
 * `Home/HomeLaunchpadView.swift` + `Chat/ThreadComposerView.swift`. All
 * backend actions are honestly unavailable in this foundation build: no fake
 * provider state, no simulated success; the field is real and editable.
 */
@Composable
fun HomeLaunchpadPage(
    compact: Boolean,
    showSidebarToggle: Boolean,
    onExpandSidebar: () -> Unit,
    onOpenDrawer: () -> Unit,
    onOpenSettingsSection: (String) -> Unit,
    runtimeHost: RuntimeHost? = null,
) {
    val colors = Floe.colors
    var field by remember {
        mutableStateOf(TextFieldValue(HomeDraftTransfer.draft(FloeFoundation.draftStore)))
    }
    // The RAM draft store is updated synchronously with every edit so a
    // navigation/rotation cancellation can never race ahead of the last
    // text change; selection/composition stay in the live TextFieldValue.
    var dialog by remember { mutableStateOf(HomeDialog.NONE) }
    var agentModeKey by remember { mutableStateOf("agent") }
    var modeMenuOpen by remember { mutableStateOf(false) }
    var permissionMenuOpen by remember { mutableStateOf(false) }
    var reasoningMenuOpen by remember { mutableStateOf(false) }

    // The REAL Home draft ownership surface (RootWorkspaceController): live
    // staged rows, the human draft task-policy selection and the selected
    // model's saved reasoning effort. Without a host these stay honestly
    // absent (legacy dialogs), never fabricated.
    val rootWorkspace = runtimeHost?.conversations?.rootWorkspace
    val draftRows = if (rootWorkspace == null) {
        emptyList()
    } else {
        val rowsState by rootWorkspace.draftAttachments.collectAsState()
        rowsState
    }
    val draftProcessing = draftRows.any { it.isProcessing }
    val draftImportFailed = if (rootWorkspace == null) false else {
        val failed by rootWorkspace.draftImportFailed.collectAsState()
        failed
    }
    val draftApproval = if (rootWorkspace == null) {
        null
    } else {
        val modeState by rootWorkspace.draftApprovalMode.collectAsState()
        modeState
    }
    val savedReasoning = if (rootWorkspace == null) {
        null
    } else {
        val effortState by rootWorkspace.reasoningEffort.collectAsState()
        effortState
    }

    // G02: real availability from the host projections. When the host is
    // absent the surface stays honestly gated exactly like G01.
    if (runtimeHost != null) {
        androidx.compose.runtime.LaunchedEffect(runtimeHost) {
            runtimeHost.home.refresh()
        }
    }
    val availability = if (runtimeHost == null) {
        ComposerAvailability(
            providerConfigured = false,
            voiceAvailable = false,
            temporaryChatAvailable = false,
        )
    } else {
        val availabilityState by runtimeHost.home.availability.collectAsState()
        availabilityState
    }
    val modelChipLabel = if (runtimeHost == null) {
        stringResource(R.string.model_unconfigured_chip)
    } else {
        val label by runtimeHost.home.modelLabel.collectAsState()
        label ?: stringResource(R.string.model_unconfigured_chip)
    }
    val sending = if (runtimeHost == null) {
        false
    } else {
        val sendingState by runtimeHost.home.sending.collectAsState()
        sendingState
    }
    // The service-owned Home identity of THIS surface. It survives rotation/
    // view reconstruction (the host object is process-scoped) and is the
    // origin proof every temporary send carries; it is part of the page's
    // top-level state so the send path can never capture it from an inner
    // conditional scope.
    val homeGeneration = if (runtimeHost == null) {
        0L
    } else {
        val generation by runtimeHost.home.homeGeneration.collectAsState()
        generation
    }
    // Real composer model options from the SAME F1 projection the thread
    // composer uses; the picker offers exactly the usable rows (never a
    // parallel cache or a fabricated "configured" flag).
    val usableModelOptions = if (runtimeHost == null) {
        emptyList()
    } else {
        val options by runtimeHost.home.modelOptions.collectAsState()
        options.filter { it.isUsable }
    }
    val selectedModelId = if (runtimeHost == null) {
        null
    } else {
        val selected by runtimeHost.home.selectedModelId.collectAsState()
        selected
    }
    var modelMenuOpen by remember { mutableStateOf(false) }
    val modeLabel = when (agentModeKey) {
        "chat" -> stringResource(R.string.mode_chat)
        "plan" -> stringResource(R.string.mode_plan)
        "goal" -> stringResource(R.string.mode_goal)
        else -> stringResource(R.string.mode_agent)
    }

    Column(Modifier.fillMaxSize().background(colors.readingSurface)) {
        FloeToolbar(
            title = stringResource(R.string.new_task),
            background = colors.readingSurface,
            navigation = if (showSidebarToggle || compact) {
                {
                    if (showSidebarToggle) {
                        FloeCircleButton(FloeIcons.SidebarToggle, stringResource(R.string.expand_task_list), onExpandSidebar)
                    } else {
                        FloeCircleButton(FloeIcons.SidebarToggle, stringResource(R.string.open_sidebar), onOpenDrawer)
                    }
                }
            } else null,
            actions = {
                // Temporary chat: with the runtime host a real temporary
                // session starts and the shell navigates to it; otherwise the
                // dialog states the lifecycle is absent, truthfully.
                FloeCircleButton(
                    icon = FloeIcons.Bubble,
                    contentDescription = stringResource(R.string.temporary_chat),
                    onClick = {
                        if (runtimeHost != null && availability.temporaryChatAvailable) {
                            val text = field.text
                            runtimeHost.home.send(
                                text = text,
                                mode = agentModeKey,
                                temporary = true,
                                originHomeGeneration = homeGeneration,
                                onAdmitted = { _: HomeSendToken, draftTransferred: Boolean ->
                                    // The REAL temp.start committed and the
                                    // host consumed THIS request's exact
                                    // HOME_DRAFT text under its ownership
                                    // lock. Clear the visible field only
                                    // when the handoff really happened and
                                    // the field still shows that exact text
                                    // (a newer edit always survives).
                                    if (draftTransferred && field.text == text) {
                                        field = TextFieldValue("")
                                    }
                                },
                            ) { dialog = HomeDialog.TEMP_CHAT }
                        } else {
                            dialog = HomeDialog.TEMP_CHAT
                        }
                    },
                    tint = colors.secondaryLabel,
                )
            },
        )
        // Hero: app icon + welcome, centered in the main region (no card).
        Box(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                .verticalScroll(rememberScrollState()),
            contentAlignment = Alignment.Center,
        ) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier.padding(horizontal = 24.dp).widthIn(max = 720.dp),
            ) {
                val heroShape = RoundedCornerShape(FloeLayout.HeroIconCorner)
                Image(
                    painter = painterResource(R.mipmap.ic_launcher),
                    contentDescription = null,
                    modifier = Modifier
                        .size(FloeLayout.HeroIconSize)
                        .shadow(18.dp, heroShape, clip = false, ambientColor = colors.accent.copy(alpha = 0.18f), spotColor = colors.accent.copy(alpha = 0.18f))
                        .clip(heroShape),
                )
                Spacer(Modifier.height(FloeLayout.HeroTextGap))
                FloeText(
                    stringResource(R.string.home_welcome),
                    style = Floe.typography.title,
                    color = colors.label,
                )
            }
        }
        // The draft's REAL staged rows (native-staged lifecycle only): same
        // chip presentation as the thread tray, with genuine remove/retry/
        // cancel routed to the draft owner. Empty renders nothing — Home
        // never grows a phantom attachment header.
        FloeDraftAttachmentTray(
            rows = draftRows,
            onRemove = { id -> rootWorkspace?.removeDraftAttachment(id) },
            onRetry = { id -> rootWorkspace?.retryDraftAttachment(id) },
            onCancel = { id -> rootWorkspace?.removeDraftAttachment(id) },
        )
        if (draftImportFailed) {
            FloeText(
                stringResource(R.string.home_attachment_import_failed),
                style = Floe.typography.metadata,
                color = colors.pending,
            )
        }
        FloeComposer(
            value = field,
            onValueChange = { next ->
                field = next
                HomeDraftTransfer.update(FloeFoundation.draftStore, next.text)
            },
            maxLines = if (compact) FloeLayout.ComposerMaxLinesCompact else FloeLayout.ComposerMaxLinesRegular,
            availability = availability.copy(attachmentsProcessing = sending || draftProcessing),
            placeholder = stringResource(R.string.composer_placeholder),
            attachDescription = stringResource(R.string.composer_attach),
            voiceDescription = stringResource(R.string.voice_input),
            sendDescription = stringResource(R.string.send),
            onAttach = {
                if (rootWorkspace != null) {
                    // ONE explicit user tap: the REAL SAF picker request,
                    // draft-owned staging, no durable conversation header
                    // and no fabricated handles. A refusal is stated
                    // honestly; a temporary session never reaches this.
                    if (!rootWorkspace.requestHomeAttachments()) {
                        dialog = HomeDialog.ATTACH_REFUSED
                    }
                } else {
                    dialog = HomeDialog.ATTACH
                }
            },
            onVoice = { dialog = HomeDialog.VOICE },
            onSend = {
                if (runtimeHost != null && !sending) {
                    val text = field.text
                    HomeDraftTransfer.update(FloeFoundation.draftStore, "")
                    field = TextFieldValue("")
                    runtimeHost.home.send(
                        text = text,
                        mode = agentModeKey,
                        temporary = false,
                    ) { reason ->
                        // Restore the draft on an honest failure; the error is
                        // surfaced on the launchpad instead of losing text.
                        field = TextFieldValue(text)
                        HomeDraftTransfer.update(FloeFoundation.draftStore, text)
                        dialog = HomeDialog.SEND_FAILED
                    }
                }
            },
            chips = {
                // Model chip: with usable models it opens the REAL picker
                // (the same canonical rows the send will use); with none it
                // routes to provider setup — never a dead chip.
                FloeComposerChip(
                    icon = FloeIcons.Chip,
                    text = modelChipLabel,
                    onClick = {
                        if (runtimeHost != null && usableModelOptions.isNotEmpty()) {
                            modelMenuOpen = true
                        } else {
                            onOpenSettingsSection("PROVIDERS")
                        }
                    },
                    tone = if (availability.providerConfigured) {
                        FloeChipTone.SECONDARY
                    } else {
                        FloeChipTone.ACCENT
                    },
                    description = modelChipLabel,
                )
                FloeChipMenu(
                    expanded = modelMenuOpen,
                    onDismiss = { modelMenuOpen = false },
                ) {
                    for (option in usableModelOptions) {
                        CupertinoMenuEntry(
                            title = option.displayName,
                            selected = option.modelId == selectedModelId,
                            onClick = {
                                runtimeHost?.home?.selectModel(option.modelId)
                                modelMenuOpen = false
                            },
                        )
                    }
                }
                // Reasoning chip: the SELECTED configured model's REAL saved
                // effort (never a fabricated "auto"); choosing an effort
                // writes through the ORIGINAL full-snapshot model CAS and
                // every surface re-reads the same projection. With no usable
                // model the chip routes to provider setup instead of a
                // dead no-op, and without a host it states the honest
                // unavailability.
                FloeComposerChip(
                    icon = FloeIcons.Gauge,
                    text = if (rootWorkspace == null) {
                        stringResource(R.string.reasoning_auto)
                    } else {
                        savedReasoning?.let {
                            reasoningEffortLabel(it)
                        } ?: stringResource(R.string.root_reasoning_unset)
                    },
                    onClick = {
                        when {
                            rootWorkspace == null -> dialog = HomeDialog.REASONING
                            usableModelOptions.isEmpty() -> onOpenSettingsSection("PROVIDERS")
                            else -> reasoningMenuOpen = true
                        }
                    },
                )
                FloeChipMenu(expanded = reasoningMenuOpen, onDismiss = { reasoningMenuOpen = false }) {
                    ReasoningEffortUi.entries.forEach { effort ->
                        CupertinoMenuEntry(
                            title = reasoningEffortLabel(effort),
                            selected = savedReasoning == effort,
                            onClick = {
                                reasoningMenuOpen = false
                                val started = rootWorkspace?.updateSelectedModelReasoningEffort(effort) {
                                    succeeded, _ ->
                                    if (!succeeded) dialog = HomeDialog.REASONING_FAILED
                                }
                                if (started != true) dialog = HomeDialog.REASONING_FAILED
                            },
                        )
                    }
                }
                FloeComposerChip(
                    icon = FloeIcons.Folder,
                    text = stringResource(R.string.project_none),
                    onClick = { dialog = HomeDialog.PROJECT },
                )
                FloeComposerChip(
                    icon = FloeIcons.DeviceLocal,
                    text = stringResource(R.string.target_local),
                    onClick = { dialog = HomeDialog.TARGET },
                )
                FloeComposerChip(
                    icon = FloeIcons.Wand,
                    text = modeLabel,
                    onClick = { modeMenuOpen = true },
                )
                FloeChipMenu(expanded = modeMenuOpen, onDismiss = { modeMenuOpen = false }) {
                    listOf(
                        "agent" to stringResource(R.string.mode_agent),
                        "chat" to stringResource(R.string.mode_chat),
                        "plan" to stringResource(R.string.mode_plan),
                        "goal" to stringResource(R.string.mode_goal),
                    ).forEach { (key, label) ->
                        CupertinoMenuEntry(
                            title = label,
                            selected = agentModeKey == key,
                            onClick = { agentModeKey = key; modeMenuOpen = false },
                        )
                    }
                }
                // Home draft task policy: the ORIGINAL Ask / Auto-approve /
                // Full-access surface, seeded from the real global default
                // and carried as the optional run.start approvalMode for the
                // FIRST launch only. An explicit human gesture is the ONLY
                // writer; a temporary session never consumes this value.
                FloeComposerChip(
                    icon = FloeIcons.ShieldCheck,
                    text = draftApproval?.let { draftApprovalLabel(it) }
                        ?: stringResource(R.string.approval_ask),
                    onClick = {
                        if (rootWorkspace != null) {
                            permissionMenuOpen = true
                        } else {
                            dialog = HomeDialog.PERMISSIONS
                        }
                    },
                )
                FloeChipMenu(expanded = permissionMenuOpen, onDismiss = { permissionMenuOpen = false }) {
                    ApprovalModeUi.entries.forEach { mode ->
                        CupertinoMenuEntry(
                            title = draftApprovalLabel(mode),
                            selected = draftApproval == mode,
                            onClick = {
                                rootWorkspace?.selectDraftApprovalMode(mode)
                                permissionMenuOpen = false
                            },
                        )
                    }
                }
            },
        )
    }

    when (dialog) {
        HomeDialog.TEMP_CHAT -> FloeInfoDialog(
            title = stringResource(R.string.temporary_chat),
            message = stringResource(R.string.temp_chat_unavailable),
            confirmLabel = stringResource(R.string.done),
            onDismiss = { dialog = HomeDialog.NONE },
        )
        HomeDialog.VOICE -> FloeInfoDialog(
            title = stringResource(R.string.voice_input),
            message = stringResource(R.string.voice_unavailable),
            confirmLabel = stringResource(R.string.done),
            onDismiss = { dialog = HomeDialog.NONE },
        )
        HomeDialog.ATTACH -> FloeInfoDialog(
            title = stringResource(R.string.composer_attach),
            message = stringResource(R.string.attach_unavailable),
            confirmLabel = stringResource(R.string.done),
            onDismiss = { dialog = HomeDialog.NONE },
        )
        HomeDialog.ATTACH_REFUSED -> FloeInfoDialog(
            title = stringResource(R.string.composer_attach),
            message = stringResource(R.string.root_attach_refused),
            confirmLabel = stringResource(R.string.done),
            onDismiss = { dialog = HomeDialog.NONE },
        )
        HomeDialog.REASONING_FAILED -> FloeInfoDialog(
            title = stringResource(R.string.reasoning_effort),
            message = stringResource(R.string.root_reasoning_failed),
            confirmLabel = stringResource(R.string.done),
            onDismiss = { dialog = HomeDialog.NONE },
        )
        HomeDialog.REASONING -> FloeInfoDialog(
            title = stringResource(R.string.reasoning_effort),
            message = stringResource(R.string.reasoning_unavailable),
            confirmLabel = stringResource(R.string.done),
            onDismiss = { dialog = HomeDialog.NONE },
        )
        HomeDialog.PROJECT -> FloeInfoDialog(
            title = stringResource(R.string.workspaces),
            message = stringResource(R.string.projects_runtime_pending),
            confirmLabel = stringResource(R.string.done),
            onDismiss = { dialog = HomeDialog.NONE },
        )
        HomeDialog.TARGET -> FloeInfoDialog(
            title = stringResource(R.string.target_local),
            message = stringResource(R.string.target_note),
            confirmLabel = stringResource(R.string.done),
            onDismiss = { dialog = HomeDialog.NONE },
        )
        HomeDialog.PERMISSIONS -> FloeInfoDialog(
            title = stringResource(R.string.task_permissions),
            message = stringResource(R.string.permissions_runtime_pending),
            confirmLabel = stringResource(R.string.done),
            onDismiss = { dialog = HomeDialog.NONE },
        )
        HomeDialog.SEND_FAILED -> FloeInfoDialog(
            title = stringResource(R.string.send_failed_title),
            message = stringResource(R.string.send_failed_message),
            confirmLabel = stringResource(R.string.done),
            onDismiss = { dialog = HomeDialog.NONE },
        )
        HomeDialog.NONE -> {}
    }
}

/** The provider editor's OWN vocabulary for the saved reasoning efforts
 * (the same canonical labels the model editor uses; Home never invents a
 * parallel naming). */
@Composable
private fun reasoningEffortLabel(effort: ReasoningEffortUi): String = stringResource(
    when (effort) {
        ReasoningEffortUi.AUTOMATIC -> com.floe.android.feature.providers.R.string.model_reasoning_automatic
        ReasoningEffortUi.LOW -> com.floe.android.feature.providers.R.string.model_reasoning_low
        ReasoningEffortUi.MEDIUM -> com.floe.android.feature.providers.R.string.model_reasoning_medium
        ReasoningEffortUi.HIGH -> com.floe.android.feature.providers.R.string.model_reasoning_high
        ReasoningEffortUi.MAXIMUM -> com.floe.android.feature.providers.R.string.model_reasoning_maximum
    },
)

/** The original task-permission vocabulary shared with the thread
 * composer's permissions chip. */
@Composable
private fun draftApprovalLabel(mode: ApprovalModeUi): String = stringResource(
    when (mode) {
        ApprovalModeUi.ASK -> com.floe.android.feature.conversation.R.string.permissions_ask
        ApprovalModeUi.AUTOMATIC -> com.floe.android.feature.conversation.R.string.permissions_auto_approve
        ApprovalModeUi.FULL_ACCESS -> com.floe.android.feature.conversation.R.string.permissions_full_access
    },
)
