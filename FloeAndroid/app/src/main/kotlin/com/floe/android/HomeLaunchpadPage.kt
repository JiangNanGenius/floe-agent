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
import com.floe.android.design.FloeDraftStore
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeInfoDialog
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloeText
import com.floe.android.design.FloeToolbar
import com.floe.android.design.ComposerAvailability
import com.floe.android.host.RuntimeHost

private enum class HomeDialog {
    NONE, TEMP_CHAT, VOICE, ATTACH, REASONING, PROJECT, TARGET, PERMISSIONS, SEND_FAILED,
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
    var field by remember { mutableStateOf(TextFieldValue(FloeFoundation.draftStore.draft(FloeDraftStore.HOME_DRAFT))) }
    // The RAM draft store is updated synchronously with every edit so a
    // navigation/rotation cancellation can never race ahead of the last
    // text change; selection/composition stay in the live TextFieldValue.
    var dialog by remember { mutableStateOf(HomeDialog.NONE) }
    var agentModeKey by remember { mutableStateOf("agent") }
    var modeMenuOpen by remember { mutableStateOf(false) }

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
        FloeComposer(
            value = field,
            onValueChange = { next ->
                field = next
                FloeFoundation.draftStore.update(FloeDraftStore.HOME_DRAFT, next.text)
            },
            maxLines = if (compact) FloeLayout.ComposerMaxLinesCompact else FloeLayout.ComposerMaxLinesRegular,
            availability = availability.copy(attachmentsProcessing = sending),
            placeholder = stringResource(R.string.composer_placeholder),
            attachDescription = stringResource(R.string.composer_attach),
            voiceDescription = stringResource(R.string.voice_input),
            sendDescription = stringResource(R.string.send),
            onAttach = { dialog = HomeDialog.ATTACH },
            onVoice = { dialog = HomeDialog.VOICE },
            onSend = {
                if (runtimeHost != null && !sending) {
                    val text = field.text
                    FloeFoundation.draftStore.update(FloeDraftStore.HOME_DRAFT, "")
                    field = TextFieldValue("")
                    runtimeHost.home.send(
                        text = text,
                        mode = agentModeKey,
                        temporary = false,
                    ) { reason ->
                        // Restore the draft on an honest failure; the error is
                        // surfaced on the launchpad instead of losing text.
                        field = TextFieldValue(text)
                        FloeFoundation.draftStore.update(FloeDraftStore.HOME_DRAFT, text)
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
                FloeComposerChip(
                    icon = FloeIcons.Gauge,
                    text = stringResource(R.string.reasoning_auto),
                    onClick = { dialog = HomeDialog.REASONING },
                )
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
                FloeComposerChip(
                    icon = FloeIcons.ShieldCheck,
                    text = stringResource(R.string.approval_ask),
                    onClick = { dialog = HomeDialog.PERMISSIONS },
                )
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
