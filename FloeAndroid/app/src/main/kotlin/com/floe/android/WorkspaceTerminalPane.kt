// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeInlineSwitch
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloeSheetPlacement
import com.floe.android.design.FloeText
import com.floe.android.feature.terminal.G04TerminalView
import com.floe.android.host.G04TerminalHostController
import com.floe.android.host.TerminalActionReply
import com.floe.android.host.TerminalLanguageRuntimeState
import com.floe.android.host.TerminalSessionPhase
import com.floe.android.host.TerminalSessionSnapshot
import kotlinx.coroutines.launch

/**
 * The owning-task inspector's embedded terminal pane (G04 D3/D7: the real
 * surface lives in the current task's inspector, the outer task-first shell
 * is unchanged; the pane keeps the inspector width).
 *
 * Honesty contract (mirrors the inspector header rule): without a bound
 * controller or a qualified Linux engine this pane says what is missing and
 * offers nothing fake. With them, it renders the REAL reused terminal
 * emulator over the conversation's native PTY session.
 *
 * Lifecycle contract (Main steer 2026-10-24): reconstruction/dismissal of
 * THIS composable is never a process or session stop signal — only the
 * explicit Close button, task deletion or Root retirement settles sessions.
 * The engine + emulator screen state live in the Application-owned
 * controller, so re-showing the pane re-attaches to the same live session.
 */
@Composable
internal fun WorkspaceTerminalPane(
    controller: G04TerminalHostController?,
    conversationID: String,
    onOpenEnvironment: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val colors = Floe.colors
    val scope = rememberCoroutineScope()
    val clipboard = LocalClipboardManager.current

    var snapshot by remember(conversationID) { mutableStateOf<TerminalSessionSnapshot?>(null) }
    var keyboardVisible by remember { mutableStateOf(true) }
    var textSp by remember { mutableStateOf(13f) }
    var settingsVisible by remember { mutableStateOf(false) }
    // Language services: persisted choices + ACTUAL runtime state only.
    var languageEnabled by remember { mutableStateOf<Map<String, Boolean>>(emptyMap()) }
    var settingsKnown by remember { mutableStateOf(false) }
    var runtimeStates by remember { mutableStateOf<Map<String, TerminalLanguageRuntimeState>>(emptyMap()) }
    var busyLanguage by remember { mutableStateOf<String?>(null) }

    // Pane-scoped observation ONLY (detaching never stops the session).
    DisposableEffect(controller, conversationID) {
        if (controller == null) return@DisposableEffect onDispose { }
        val unregisterSessions = controller.watchSessions(conversationID) { snapshot = it }
        // Live server transitions keep the settings list honest while open;
        // detaching removes ONLY the listener.
        val unregisterLanguage = controller.addLanguageStatusListener { status ->
            if (status.conversationID == conversationID) {
                runtimeStates = runtimeStates + (status.language to
                    TerminalLanguageRuntimeState(status.state, status.code))
            }
        }
        onDispose { unregisterSessions(); unregisterLanguage() }
    }

    // ACTUAL availability is re-read every time the sheet opens (bounded
    // request, no polling): after Linux qualification or a package install
    // the list refreshes instead of staying pinned to one cold read.
    LaunchedEffect(settingsVisible) {
        if (settingsVisible && controller != null) {
            val capabilities = controller.capabilitiesFor(conversationID)
            if (capabilities != null) {
                languageEnabled = capabilities.enabled
                settingsKnown = capabilities.settingsKnown
                runtimeStates = capabilities.serverStates
            }
        }
    }

    // Start-on-first-show (the iOS `startIfNeeded` semantics: an already
    // live session is never restarted just because the panel was re-shown).
    // An EXITED/STOPPED/FAULT session stays exactly as it ended: a visible
    // Reset control drives the explicit restart — no silent relaunch.
    // Gated by the honest availability predicate — never a fake log.
    LaunchedEffect(controller, conversationID) {
        val host = controller ?: return@LaunchedEffect
        if (!host.availability().capabilitiesKnown) host.refreshCapabilities()
        val current = host.currentSnapshot(conversationID)
        val needsStart = current == null || current.phase == TerminalSessionPhase.CLOSED
        if (needsStart && host.availability().let { it.qualified && it.workspaceAttached }) {
            host.attachOrOpen(conversationID, workspaceID = null, columns = 80, rows = 24)
        } else if (!needsStart && current?.phase?.isLive() == true) {
            host.attachOrOpen(conversationID, workspaceID = null, columns = 80, rows = 24)
        }
        snapshot = host.currentSnapshot(conversationID) ?: snapshot
    }

    val engine = remember(controller, conversationID) {
        controller?.engineFor(conversationID)
    }
    val transport = remember(controller, conversationID) {
        controller?.transportFor(conversationID)
    }

    val statusText = when (snapshot?.phase) {
        null -> if (controller == null) stringResource(R.string.inspector_runtime_pending)
        else stringResource(com.floe.android.feature.terminal.R.string.terminal_starting)
        TerminalSessionPhase.STARTING -> stringResource(com.floe.android.feature.terminal.R.string.terminal_starting)
        TerminalSessionPhase.RUNNING -> stringResource(com.floe.android.feature.terminal.R.string.terminal_running)
        TerminalSessionPhase.WAITING_OUTPUT -> stringResource(com.floe.android.feature.terminal.R.string.terminal_waiting)
        TerminalSessionPhase.EXITED -> stringResource(
            com.floe.android.feature.terminal.R.string.terminal_exited,
            snapshot?.exitCode ?: -1)
        TerminalSessionPhase.STOPPED -> stringResource(
            com.floe.android.feature.terminal.R.string.terminal_stopped,
            snapshot?.stopReason.orEmpty())
        TerminalSessionPhase.CLOSED -> stringResource(com.floe.android.feature.terminal.R.string.terminal_closed)
        TerminalSessionPhase.FAULT -> stringResource(
            com.floe.android.feature.terminal.R.string.terminal_fault,
            snapshot?.faultCode.orEmpty())
    }

    Column(modifier.fillMaxSize().background(colors.readingSurface)) {
        // status strip
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(36.dp)
                .padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            FloeText(
                text = statusText,
                style = Floe.typography.metadata,
                color = colors.secondaryLabel,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            val rolledOver = snapshot?.rolledOverBytes ?: 0
            if (rolledOver > 0) {
                FloeText(
                    text = stringResource(
                        com.floe.android.feature.terminal.R.string.terminal_output_lost, rolledOver),
                    style = Floe.typography.metadata,
                    color = colors.destructive,
                    maxLines = 1,
                )
            }
        }
        FloeDivider()

        val qualified = controller?.availability()?.let { it.qualified && it.workspaceAttached } == true
        val hasSession = snapshot != null && snapshot!!.phase != TerminalSessionPhase.CLOSED
        if (engine == null || transport == null || (!qualified && !hasSession)) {
            // Honest unavailability: no engine, or the runtime is not
            // qualified. The guidance text points to the REAL setup surface.
            Box(modifier = Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
                FloeText(
                    text = if (controller == null) stringResource(R.string.inspector_runtime_pending)
                    else stringResource(com.floe.android.feature.terminal.R.string.terminal_engine_unqualified),
                    style = Floe.typography.body,
                    color = colors.secondaryLabel,
                )
            }
        } else {
            Box(modifier = Modifier.fillMaxSize().weight(1f)) {
                G04TerminalView(
                    engine = engine,
                    transport = transport,
                    settings = com.floe.android.feature.terminal.TerminalViewSettings(
                        cellTextSizeSp = textSp,
                        backgroundColor = TerminalBackground,
                        keyboardVisible = keyboardVisible,
                    ),
                    statusLine = statusText,
                    modifier = Modifier.fillMaxSize(),
                )
            }

            // Control row (secondary sheet for settings, per the design).
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 6.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                TerminalControlLabel(stringResource(com.floe.android.feature.terminal.R.string.terminal_interrupt)) {
                    // Truthful unavailability: no controller, no command.
                    scope.launch { controller?.interrupt(conversationID) }
                }
                TerminalControlLabel(stringResource(com.floe.android.feature.terminal.R.string.terminal_paste)) {
                    val text = clipboard.getText()?.text
                    if (!text.isNullOrEmpty()) engine.pasteText(text)
                }
                TerminalControlLabel(stringResource(com.floe.android.feature.terminal.R.string.terminal_copy)) {
                    // Copy the current screen tail when no drag selection is
                    // active (the selection itself copies on long press).
                    val text = engine.visibleText()
                    if (text.isNotEmpty()) clipboard.setText(AnnotatedString(text))
                }
                TerminalControlLabel(stringResource(com.floe.android.feature.terminal.R.string.terminal_settings)) {
                    settingsVisible = true
                }
                val live = snapshot?.phase?.isLive() == true
                if (live) {
                    TerminalControlLabel(stringResource(com.floe.android.feature.terminal.R.string.terminal_close)) {
                        scope.launch { controller?.closeSession(conversationID) }
                    }
                } else if (snapshot != null && qualified) {
                    TerminalControlLabel(stringResource(com.floe.android.feature.terminal.R.string.terminal_reset)) {
                        // Reset only acts through a live controller; an
                        // unavailable one keeps the session untouched.
                        val host = controller ?: return@TerminalControlLabel
                        scope.launch {
                            // Native close/adoption must settle before a new
                            // open; separate launches race the old token.
                            host.closeSession(conversationID)
                            snapshot = host.attachOrOpen(conversationID, null, 80, 24)
                        }
                    }
                }
            }
        }
    }

    // Secondary settings sheet.
    FloePageSheet(
        visible = settingsVisible,
        onDismiss = { settingsVisible = false },
        widthFraction = 0.42f,
        heightFraction = 0.5f,
        placement = FloeSheetPlacement.CENTER,
    ) {
        // Resolved in composition; the semantics modifier block is not composable.
        val terminalSheetDescription = stringResource(R.string.inspector_terminal)
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(16.dp)
                .semantics { contentDescription = terminalSheetDescription },
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            FloeText(stringResource(com.floe.android.feature.terminal.R.string.terminal_settings),
                style = Floe.typography.toolbarTitle, color = colors.label)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                listOf(11f, 13f, 16f).forEach { size ->
                    val selected = textSp == size
                    Box(
                        modifier = Modifier
                            .clip(RoundedCornerShape(9.dp))
                            .background(if (selected) colors.accent else colors.fillTertiary)
                            .clickable { textSp = size }
                            .padding(horizontal = 14.dp, vertical = 8.dp),
                    ) {
                        FloeText("${size.toInt()}",
                            color = if (selected) Color.White else colors.label)
                    }
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                FloeText(stringResource(com.floe.android.feature.terminal.R.string.terminal_keyboard),
                    color = colors.label, modifier = Modifier.weight(1f))
                FloeInlineSwitch(
                    checked = keyboardVisible,
                    onCheckedChange = { keyboardVisible = it },
                    description = stringResource(com.floe.android.feature.terminal.R.string.terminal_keyboard),
                )
            }
            FloeText(stringResource(com.floe.android.feature.terminal.R.string.terminal_not_persistent_hint),
                style = Floe.typography.metadata, color = colors.secondaryLabel)

            FloeDivider()

            // ---- Language services (persisted choice + actual runtime state) ----
            FloeText(stringResource(R.string.workspace_language_settings_title),
                style = Floe.typography.toolbarTitle, color = colors.label)
            FloeText(stringResource(R.string.workspace_language_settings_hint),
                style = Floe.typography.metadata, color = colors.secondaryLabel)
            if (!settingsKnown) {
                FloeText(stringResource(R.string.workspace_language_settings_unavailable),
                    style = Floe.typography.metadata, color = colors.destructive)
            }
            val host = controller
            LanguageCatalog.forEach { entry ->
                val enabled = languageEnabled[entry.id] != false
                val state = runtimeStates[entry.id]
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            FloeText(stringResource(entry.nameRes), color = colors.label)
                            FloeText(
                                text = stringResource(languageStateRes(enabled, state)),
                                style = Floe.typography.metadata,
                                color = colors.secondaryLabel,
                            )
                        }
                        val retryable = enabled && state != null &&
                            state.state in setOf("unavailable", "failed", "stopped")
                        if (retryable && host != null) {
                            TerminalControlLabel(stringResource(R.string.workspace_language_retry)) {
                                scope.launch {
                                    busyLanguage = entry.id
                                    host.ensureLanguageServer(conversationID, null, entry.id)
                                    host.capabilitiesFor(conversationID)?.let {
                                        languageEnabled = it.enabled
                                        settingsKnown = it.settingsKnown
                                        runtimeStates = it.serverStates
                                    }
                                    busyLanguage = null
                                }
                            }
                        }
                        FloeInlineSwitch(
                            checked = enabled,
                            enabled = host != null && busyLanguage != entry.id,
                            onCheckedChange = { value ->
                                val target = host ?: return@FloeInlineSwitch
                                scope.launch {
                                    busyLanguage = entry.id
                                    val reply = target.setLanguageEnabled(entry.id, value)
                                    if (reply is TerminalActionReply.Success) {
                                        val mirror = target.languageSettingsSnapshot()
                                        languageEnabled = mirror.enabled
                                        settingsKnown = mirror.settingsKnown
                                    }
                                    busyLanguage = null
                                }
                            },
                            description = stringResource(entry.nameRes),
                        )
                    }
                    val live = state
                    if (enabled && live != null && live.state == "unavailable" && live.code == "toolMissing") {
                        FloeText(stringResource(R.string.workspace_language_missing_hint),
                            style = Floe.typography.metadata, color = colors.destructive)
                    }
                }
            }
            if (onOpenEnvironment != null) {
                TerminalControlLabel(stringResource(R.string.workspace_language_open_environment)) {
                    onOpenEnvironment?.invoke()
                }
            }
        }
    }
}

/** The closed supported set, in catalog order (mirrors G04LanguageServerCatalog). */
private data class LanguageEntry(val id: String, val nameRes: Int)
private val LanguageCatalog = listOf(
    LanguageEntry("shell", R.string.workspace_language_shell),
    LanguageEntry("python", R.string.workspace_language_python),
    LanguageEntry("javascript", R.string.workspace_language_javascript),
    LanguageEntry("typescript", R.string.workspace_language_typescript),
    LanguageEntry("json", R.string.workspace_language_json),
    LanguageEntry("html", R.string.workspace_language_html),
    LanguageEntry("css", R.string.workspace_language_css),
    LanguageEntry("yaml", R.string.workspace_language_yaml),
)

/** Honest label from the ACTUAL lifecycle answer — never inferred from the
 * catalog: an unchecked language says "Not checked yet", not "Ready". */
private fun languageStateRes(enabled: Boolean, state: TerminalLanguageRuntimeState?): Int {
    if (!enabled) return R.string.workspace_language_state_disabled
    return when (state?.state) {
        null -> R.string.workspace_language_state_unknown
        "ready" -> R.string.workspace_language_state_ready
        "starting" -> R.string.workspace_language_state_starting
        "unavailable" -> if (state.code == "toolMissing")
            R.string.workspace_language_state_missing else R.string.workspace_language_state_failed
        "failed" -> R.string.workspace_language_state_failed
        "stopping", "stopped" -> R.string.workspace_language_state_released
        else -> R.string.workspace_language_state_unknown
    }
}

@Composable
private fun TerminalControlLabel(label: String, onClick: () -> Unit) {
    val colors = Floe.colors
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(9.dp))
            .background(colors.fillTertiary)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 7.dp)
            .semantics { contentDescription = label },
    ) {
        FloeText(label, style = Floe.typography.metadata, color = colors.label)
    }
}

/** Fixed dark terminal plane (ANSI palette owns everything above it). */
private val TerminalBackground = Color(0xFF101014)

private fun TerminalSessionPhase.isLive(): Boolean =
    this == TerminalSessionPhase.STARTING || this == TerminalSessionPhase.RUNNING ||
        this == TerminalSessionPhase.WAITING_OUTPUT
