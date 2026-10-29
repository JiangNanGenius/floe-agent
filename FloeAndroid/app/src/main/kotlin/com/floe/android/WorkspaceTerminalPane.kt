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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeCapsuleButton
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeInlineSwitch
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloeSheetPlacement
import com.floe.android.design.FloeText
import com.floe.android.feature.terminal.G04TerminalView
import com.floe.android.host.G04TerminalHostController
import com.floe.android.host.TerminalActionReply
import com.floe.android.host.TerminalInputIssue
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
    // The controller is Application-owned, so its cached availability can
    // hold a known-but-stale unqualified answer from before the lane
    // qualified. The pane keeps OBSERVABLE copies of the live gate and of
    // what it actually dispatched, so a readiness change recomposes here and
    // the status line never claims a start that is not happening.
    var terminalReady by remember(conversationID) { mutableStateOf(false) }
    var startDispatched by remember(conversationID) { mutableStateOf(false) }
    var workspaceMappingPending by remember(conversationID) { mutableStateOf(false) }
    // G05-R3 run-less first entry: true only while THIS pane's explicit open
    // is inside the native non-executing workspace preparation. It is a
    // progress truth ("Preparing this task's workspace…"), never a claim that
    // a session exists — the authoritative phase still comes from the native
    // session projection.
    var preparingWorkspace by remember(conversationID) { mutableStateOf(false) }
    var openFailure by remember(controller, conversationID) { mutableStateOf<TerminalActionReply?>(null) }
    var showFailureDetails by remember(controller, conversationID) { mutableStateOf(false) }
    // Latest typed PTY input refusal (host-side truth, surfaced in the
    // status strip; the diagnostic code lives in the opened details).
    var inputIssue by remember(conversationID) { mutableStateOf<TerminalInputIssue?>(null) }
    var showInputIssueDetails by remember(controller, conversationID) { mutableStateOf(false) }
    val application = LocalContext.current.applicationContext as? FloeApplication

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
        // Typed input refusals are a user-visible truth, not a log-only one.
        val unregisterInputIssues = controller.watchInputIssues(conversationID) { inputIssue = it }
        onDispose { unregisterSessions(); unregisterLanguage(); unregisterInputIssues() }
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
    // G05-R3 run-less first entry: when every prerequisite is live and only
    // THIS task's own workspace facts are missing, the explicit terminal
    // action prepares them natively — no message, no provider and no AI run is
    // a prerequisite, and the pane says plainly what it is doing.
    LaunchedEffect(controller, conversationID) {
        val host = controller ?: return@LaunchedEffect
        openFailure = null
        showFailureDetails = false
        // Read the gate LIVE. `capabilitiesKnown` alone lets an
        // Application-owned known-false snapshot pin the pane forever: on a
        // false cached gate the pane performs ONE bounded capabilities
        // refresh (the same refresh-then-recheck idiom as the IDE language
        // binding) before it decides to start or to explain. A true cached
        // gate is still re-validated natively — the open request consults
        // the SAME live ingress authority and fail-closed refuses on drift.
        if (!host.availability().let { it.qualified && it.workspaceAttached }) {
            host.refreshCapabilities()
        }
        terminalReady = host.availability().let { it.qualified && it.workspaceAttached }
        val current = host.currentSnapshot(conversationID)
        val needsStart = current == null || current.phase == TerminalSessionPhase.CLOSED
        // ONE bounded read of the ORIGINAL stage authority (the closed-token
        // surface Settings uses, off-main). It selects truthful guidance AND
        // says whether this task's workspace can be prepared by the terminal
        // itself. It qualifies and gates nothing.
        workspaceMappingPending = if (needsStart && !terminalReady) {
            terminalWorkspaceMappingPending(
                runCatching { application?.linuxTaskExecutionDiagnostic() }.getOrNull())
        } else {
            false
        }
        val gate = terminalFirstUseGate(ready = terminalReady, needsStart = needsStart,
            liveSession = current?.phase?.isLive() == true,
            mappingPending = workspaceMappingPending)
        when (gate) {
            TerminalFirstUseGate.ATTACH_LIVE ->
                // An existing live session is attached, never restarted.
                host.attachOrOpen(conversationID, workspaceID = null, columns = 80, rows = 24)
            TerminalFirstUseGate.START, TerminalFirstUseGate.PREPARE_FIRST_USE -> {
                val firstUse = gate == TerminalFirstUseGate.PREPARE_FIRST_USE
                preparingWorkspace = firstUse
                startDispatched = true
                val opened = host.attachOrOpen(conversationID, workspaceID = null, columns = 80, rows = 24,
                    onRefusal = { openFailure = it })
                preparingWorkspace = false
                if (opened == null) {
                    // Native refused or timed out: nothing is starting.
                    startDispatched = false
                } else if (firstUse) {
                    // The run-less preparation really produced the facts: read
                    // the ACTUAL availability once more (bounded, no polling)
                    // so Reset/settings and the status line stop reporting the
                    // pre-preparation gate. A refusal never flips this.
                    host.refreshCapabilities()
                    terminalReady = host.availability().let { it.qualified && it.workspaceAttached }
                }
            }
            TerminalFirstUseGate.EXPLAIN -> Unit
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
        null -> when {
            controller == null -> stringResource(R.string.inspector_runtime_pending)
            // The run-less first entry in flight: one short honest sentence,
            // never "Starting terminal…" (nothing is starting yet) and never a
            // fake session.
            preparingWorkspace -> stringResource(
                com.floe.android.feature.terminal.R.string.terminal_workspace_preparing)
            // "Starting…" is only said when a start actually went out for
            // this opening; a gate that dispatched nothing says so plainly.
            startDispatched -> stringResource(com.floe.android.feature.terminal.R.string.terminal_starting)
            else -> stringResource(com.floe.android.feature.terminal.R.string.terminal_not_ready)
        }
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
            // Latest typed input refusal: a short honest message; tapping
            // opens the diagnostic code (same details idiom as openFailure).
            // The native phase/fault projection is never touched by this.
            val issue = inputIssue
            if (issue != null) {
                val issueLabel = stringResource(
                    com.floe.android.feature.terminal.R.string.terminal_input_refused)
                FloeText(
                    text = issueLabel,
                    style = Floe.typography.metadata,
                    color = colors.destructive,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier
                        .clickable { showInputIssueDetails = !showInputIssueDetails }
                        .semantics { contentDescription = issueLabel },
                )
                if (showInputIssueDetails) {
                    val suffix = if (issue.count > 1) " ×${issue.count}" else ""
                    FloeText(
                        text = issue.code.take(96)
                            .filter { it.isLetterOrDigit() || it in "_.-" }
                            .ifEmpty { "refused" } + suffix,
                        style = Floe.typography.metadata,
                        color = colors.secondaryLabel,
                        maxLines = 1,
                    )
                }
            }
        }
        FloeDivider()

        val qualified = terminalReady
        val hasSession = snapshot != null && snapshot!!.phase != TerminalSessionPhase.CLOSED
        if (engine == null || transport == null || (!hasSession && !startDispatched)) {
            // Honest unavailability: no engine, or the runtime is not
            // qualified. The guidance text points to the REAL setup surface;
            // when the ORIGINAL stage authority reports the exact shape of
            // workspace facts awaiting the frozen first-use producer, it
            // names that instead of a completed installation.
            Box(modifier = Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    FloeText(
                        text = when {
                            controller == null -> stringResource(R.string.inspector_runtime_pending)
                            // The run-less first entry in flight: what is
                            // actually happening, in one short sentence.
                            preparingWorkspace -> stringResource(
                                com.floe.android.feature.terminal.R.string.terminal_workspace_preparing)
                            openFailure != null -> stringResource(
                                when {
                                    openFailure.isEngineSlotBusyRefusal ->
                                        R.string.workspace_runtime_slot_busy
                                    // A refused run-less preparation says so,
                                    // instead of blaming a completed install.
                                    workspaceMappingPending ->
                                        com.floe.android.feature.terminal.R.string
                                            .terminal_workspace_prepare_failed
                                    else ->
                                        com.floe.android.feature.terminal.R.string
                                            .terminal_start_failed
                                })
                            workspaceMappingPending -> stringResource(
                                com.floe.android.feature.terminal.R.string.terminal_workspace_mapping_pending)
                            else -> stringResource(
                                com.floe.android.feature.terminal.R.string.terminal_engine_unqualified)
                        },
                        style = Floe.typography.body,
                        color = colors.secondaryLabel,
                    )
                    if (openFailure != null) {
                        FloeCapsuleButton(stringResource(R.string.workspace_source_error_details),
                            onClick = { showFailureDetails = !showFailureDetails })
                        if (showFailureDetails) {
                            // The bounded diagnostic token stays in the opened
                            // details fold: the typed code plus, when native
                            // answered one, the precise first-use reason.
                            val code = when (val failure = openFailure) {
                                is TerminalActionReply.Refused ->
                                    (failure.code + failure.reason?.let { ":$it" }.orEmpty())
                                        .take(96)
                                        .filter { it.isLetterOrDigit() || it in "_.-:" }
                                        .ifEmpty { "refused" }
                                TerminalActionReply.TimedOut -> "timedOut"
                                else -> "unavailable"
                            }
                            FloeText(code, style = Floe.typography.metadata, color = colors.secondaryLabel)
                        }
                    }
                    if (openFailure != null && controller != null && qualified) {
                        // Explicit user retry — the ONLY way a refused
                        // opening starts again (never a silent relaunch).
                        FloeCapsuleButton(
                            stringResource(com.floe.android.feature.terminal.R.string.terminal_reset),
                            onClick = {
                                val host = controller ?: return@FloeCapsuleButton
                                scope.launch {
                                    openFailure = null
                                    startDispatched = true
                                    val opened = host.attachOrOpen(conversationID, null, 80, 24,
                                        onRefusal = { openFailure = it })
                                    snapshot = opened
                                    if (opened == null) startDispatched = false
                                }
                            },
                        )
                    }
                    if (controller != null && !qualified && workspaceMappingPending && !preparingWorkspace) {
                        // G05-R3: the run-less first entry as an EXPLICIT user
                        // control. The pane already attempted it once on show;
                        // this is the honest retry after a refusal or a
                        // timeout — never a silent relaunch and never a hidden
                        // loop. It needs no provider, no model and no message:
                        // native prepares THIS task's workspace under its own
                        // real operation lease and answers truthfully.
                        FloeCapsuleButton(
                            stringResource(
                                com.floe.android.feature.terminal.R.string
                                    .terminal_workspace_prepare_action),
                            onClick = {
                                val host = controller ?: return@FloeCapsuleButton
                                scope.launch {
                                    openFailure = null
                                    preparingWorkspace = true
                                    startDispatched = true
                                    val opened = host.attachOrOpen(conversationID, null, 80, 24,
                                        onRefusal = { openFailure = it })
                                    preparingWorkspace = false
                                    startDispatched = opened != null
                                    if (opened != null) {
                                        host.refreshCapabilities()
                                        terminalReady = host.availability()
                                            .let { it.qualified && it.workspaceAttached }
                                    }
                                    snapshot = host.currentSnapshot(conversationID) ?: snapshot
                                }
                            },
                        )
                    }
                    if (controller != null && qualified) {
                        FloeCapsuleButton(stringResource(com.floe.android.feature.terminal.R.string.terminal_settings),
                            onClick = { settingsVisible = true })
                    }
                }
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
                            // Native close/adoption must settle before a
                            // new open; separate launches race the old
                            // token. An accepted close answers BEFORE the
                            // native settlement completes, so the reopen
                            // waits for the ACTUAL settled/CLOSED
                            // projection instead of minting a second
                            // operation lease against the retiring one
                            // (that refusal left the pane stuck at
                            // "Terminal closed" with no start dispatched).
                            // If the bounded wait expires with the old
                            // native ownership still live, NO replacement
                            // is dispatched: that is an honest refusal the
                            // user can retry explicitly — never a forced
                            // retire, a second lease against a live one,
                            // or a silent relaunch after the timeout.
                            val closed = host.closeSession(conversationID)
                            val settled = if (closed is TerminalActionReply.Success) {
                                host.awaitSessionSettled(conversationID, 20_000)
                            } else {
                                // The close never started (refused/timeout):
                                // attachOrOpen below either attaches to
                                // what is actually live or answers the
                                // honest refusal itself.
                                true
                            }
                            openFailure = null
                            if (!settled) {
                                openFailure = TerminalActionReply.Refused("closeNotSettled", null)
                                snapshot = null
                                startDispatched = false
                            } else {
                                val opened = host.attachOrOpen(conversationID, null, 80, 24,
                                    onRefusal = { openFailure = it })
                                snapshot = opened
                                startDispatched = opened != null
                            }
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
internal fun languageStateRes(enabled: Boolean, state: TerminalLanguageRuntimeState?): Int {
    if (!enabled) return R.string.workspace_language_state_disabled
    return when (state?.state) {
        null -> R.string.workspace_language_state_unknown
        "ready" -> R.string.workspace_language_state_ready
        "starting" -> R.string.workspace_language_state_starting
        "unavailable" -> when (state.code) {
            "toolMissing" -> R.string.workspace_language_state_missing
            // The single-slot busy refusal is its own honest condition: the
            // user must close the live terminal/run, not "fix an error".
            "saturated" -> R.string.workspace_language_state_busy
            else -> R.string.workspace_language_state_failed
        }
        "failed" -> R.string.workspace_language_state_failed
        "stopping", "stopped" -> R.string.workspace_language_state_released
        else -> R.string.workspace_language_state_unknown
    }
}

/** The occupied-slot refusal is a typed, actionable native condition
 * (device-proven 2026-10-25): the pane names what to close instead of a
 * generic start failure. The guard itself is unchanged and stays honest. */
private val TerminalActionReply?.isEngineSlotBusyRefusal: Boolean
    get() = (this as? TerminalActionReply.Refused)
        ?.let { it.code == "saturated" && it.reason == "engineSlotBusy" } == true

/** Exactly the observed mapping-pending stage shape: the lane is bound and
 * every prerequisite is live, but one receipt-backed workspace fact has not
 * been produced yet and no attempt failed this generation (both attempt
 * tokens empty). Anything else — `ready`, a non-empty refusal/stage, a
 * prerequisite or lane shape, unknown text — is false, so the pane keeps
 * the existing setup guidance. Pure, total, never throws. */
internal fun terminalWorkspaceMappingPending(diagnostic: String?): Boolean =
    diagnostic == "missing:workspaceMappingSynced|refusal:|stage:" ||
        diagnostic == "missing:leaseAuthorityQualified|refusal:|stage:"

/** What one pane opening may do (G05-R3). Pure and total, so the authored
 * regression pins the real control-enablement seam instead of a Compose tree:
 * a live session is only ever attached, a qualified lane starts as before, and
 * the run-less first entry is offered ONLY on the exact mapping-pending shape
 * — an unqualified engine, an unbound lane or a failed attempt this generation
 * keeps the honest setup guidance and never dispatches. */
internal enum class TerminalFirstUseGate { START, ATTACH_LIVE, PREPARE_FIRST_USE, EXPLAIN }

internal fun terminalFirstUseGate(
    ready: Boolean,
    needsStart: Boolean,
    liveSession: Boolean,
    mappingPending: Boolean,
): TerminalFirstUseGate = when {
    !needsStart && liveSession -> TerminalFirstUseGate.ATTACH_LIVE
    needsStart && ready -> TerminalFirstUseGate.START
    needsStart && mappingPending -> TerminalFirstUseGate.PREPARE_FIRST_USE
    else -> TerminalFirstUseGate.EXPLAIN
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
