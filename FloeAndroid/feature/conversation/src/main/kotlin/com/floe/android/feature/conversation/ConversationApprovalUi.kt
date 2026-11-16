// SPDX-License-Identifier: MPL-2.0
//
// Inline approval presentation (⇄ FloeApp/Chat/ApprovalCardView.swift).
// Renders inline in the thread — never a full-screen modal. Every field on
// the card is a HOST projection of the real effect: the tool name, the
// normalized scope target, the deterministic risk labels and the policy
// reason. Approve/Deny dispatch ONLY the exact run+call identity through the
// holder (APR-CALL-BOUND); imported documents, web responses and tool output
// can never produce or widen a grant (APR-UNTRUSTED-NO-GRANT) — the only way
// a decision leaves this card is a human tap on these two controls.
// The catastrophic-gate `.stopped` presentation is destructive red and is
// NEVER weakened by the chosen tier (the runtime's second-auth release is
// the host's authority, not this UI's).

package com.floe.android.feature.conversation

import androidx.compose.foundation.background
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import java.util.UUID
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeBadgePill
import com.floe.android.design.FloeBadgeTone
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloeSegmented
import com.floe.android.design.FloeText
import com.floe.android.design.IconGlyph

@Composable
fun ConversationApprovalRow(
    card: ApprovalCardUi,
    holder: ConversationFlowHolder,
    modifier: Modifier = Modifier,
    onResolve: ((ApprovalCardUi, Boolean) -> Unit)? = null,
    /** Test/inspector seam for the explicit owned-slot handoff, mirroring
     * [onResolve]. Production keeps the holder's canonical path. */
    onEndTerminalAndRun: ((ApprovalCardUi, TerminalHandoffConsentUi) -> Unit)? = null,
) {
    val shellStop = if (card.toolName == "exec.shell") holder.shellStopPending(card) else null
    if (shellStop != null) {
        val colors = Floe.colors
        Column(modifier = modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp)) {
            FloeText(stringResource(if (shellStop) R.string.approval_shell_stop_pending
                else R.string.approval_shell_stop_unconfirmed),
                style = Floe.typography.metadata,
                color = if (shellStop) colors.pending else colors.destructive)
            if (!shellStop) {
                FloeText(stringResource(R.string.approval_recheck),
                    modifier = Modifier.clickable { holder.recheckApproval(card) }.padding(vertical = 8.dp),
                    style = Floe.typography.bodyEmphasized, color = colors.accent)
            }
        }
        return
    }
    val deviceStop = if (card.toolName == "device.act") holder.deviceApprovalStopFor(card) else null
    if (deviceStop != null) {
        // Takeover has removed this approval from the actionable UI. Keep a
        // small truthful status without showing the obsolete target/buttons.
        val colors = Floe.colors
        Column(modifier = modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp)) {
            FloeText(
                stringResource(when (deviceStop.phase) {
                    DeviceApprovalStopPhaseUi.FAILED -> R.string.approval_device_stop_failed
                    DeviceApprovalStopPhaseUi.STOPPED -> R.string.state_stopped
                    DeviceApprovalStopPhaseUi.STOPPING -> R.string.approval_device_stopping
                }),
                style = Floe.typography.metadata,
                color = if (deviceStop.phase == DeviceApprovalStopPhaseUi.FAILED) colors.destructive else colors.pending,
            )
            if (deviceStop.phase == DeviceApprovalStopPhaseUi.FAILED) {
                FloeText(stringResource(R.string.action_stop),
                    modifier = Modifier.clickable { holder.stopForApproval(card) }.padding(vertical = 8.dp),
                    style = Floe.typography.bodyEmphasized, color = colors.destructive)
            }
        }
        return
    }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var resumed by remember(lifecycle) { mutableStateOf(lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) }
    var visible by remember(card.key, card.requestGeneration, card.descriptorIdentity) { mutableStateOf(false) }
    var lease by remember(card.key, card.requestGeneration, card.descriptorIdentity) { mutableStateOf<String?>(null) }
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, _ -> resumed = lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    val privateRefresh = holder.privateApprovalRefresh.value[card.key] ?: 0
    DisposableEffect(holder, card, resumed, visible, privateRefresh) {
        val active = if (resumed && visible) UUID.randomUUID().toString() else null
        lease = active
        if (active != null) holder.showPrivateApproval(card, active)
        onDispose {
            if (active != null) holder.hidePrivateApproval(active)
            if (lease == active) lease = null
        }
    }
    val presentedCard = lease?.let { holder.visibleApprovalCard(card, it) } ?: card
    val colors = Floe.colors
    // Owned Linux engine slot conflict (Main ruling 2026-10-28): the runtime
    // escalated THIS exact call because its trusted G04 probe found this
    // conversation's own live interactive terminal really holding the
    // dedicated execution slot. The typed reason token is an opaque identifier
    // and is NEVER rendered as prose — the presentedCard shows its own short localized
    // copy.
    //
    // A live TTY alone is NOT a conflict: under the approved separated pool
    // (TWO interactive tabs + ONE Agent/run execution slot) it never blocks an
    // Agent command. The App therefore asks the host for the live capture only
    // when the trusted token is present, and requires that exact capture for
    // the destructive control. No token ⇒ an ordinary presentedCard, unchanged.
    val reasonIsSlotConflict = ApprovalGrantMapping.terminalHandoffConflict(presentedCard.reason)
    val handoff = ApprovalGrantMapping.terminalHandoffProjection(
        reason = presentedCard.reason,
        toolName = presentedCard.toolName,
        liveConsent = if (reasonIsSlotConflict && presentedCard.conversationId == holder.conversationId) {
            holder.liveTerminalHandoffConsent()
        } else {
            null
        },
    )
    val slotConflict = handoff.showsConflictNote
    val handoffRefusal = holder.terminalHandoffRefusal.value
        ?.takeIf { it.approvalKey == presentedCard.key }
    val dispatchState = holder.approvalDispatchStates.value[presentedCard.key]
    val decisionInFlight = dispatchState != null && dispatchState != ApprovalDispatchState.RETRY_READY
    val fileAction = presentedCard.workspaceAction
    val shellAction = presentedCard.localShellAction
    var shellExpanded by remember(card.key, lease) { mutableStateOf(false) }
    val scheduleAction = presentedCard.scheduleCreateAction
    val browserTabAction = presentedCard.browserTabAction
    val browserInteraction = presentedCard.browserInteractionAction
    val browserVisual = presentedCard.browserVisualAction
    var visualSeen by remember(card.key, lease, browserVisual) { mutableStateOf(false) }
    val unidentifiedBrowserTarget = browserTabAction != null && browserTabAction.operation != "create" &&
        browserTabAction.isWellFormed() && !browserTabAction.isReviewable()
    val detailsVisible = if (browserVisual != null) {
        presentedCard.toolName == "browser.clickPoint" && browserVisual.isWellFormed() && visualSeen
    } else if (browserInteraction != null) {
        presentedCard.toolName == "browser.${browserInteraction.operation}" && browserInteraction.isWellFormed()
    } else if (browserTabAction != null) {
        presentedCard.toolName == "browser.tab" && browserTabAction.isReviewable()
    } else if (scheduleAction != null) {
        presentedCard.toolName == "task.schedule"
    } else if (shellAction != null) {
        presentedCard.toolName == "exec.shell"
    } else if (fileAction != null) {
        presentedCard.workspaceVerified && presentedCard.workspaceId == fileAction.workspaceId &&
            presentedCard.toolName == "workspace.${fileAction.operation}"
    } else when (presentedCard.actionKind) {
        "back", "home" -> true
        "launch" -> !presentedCard.actionPackage.isNullOrBlank()
        else -> false
    }
    val shellDetailsReady = shellAction?.shellPrivateBytes == null ||
        (lease != null && shellAction.env != null && holder.privateShellReviewed(lease!!))
    val canAllow = presentedCard.identityVerified && presentedCard.scopeVerified &&
        detailsVisible && shellDetailsReady && !decisionInFlight
    val canDeny = presentedCard.identityVerified && !decisionInFlight
    val gateStopped = ApprovalGrantMapping.isGateStopped(presentedCard.reason) && !reasonIsSlotConflict
    val headerTitle = stringResource(R.string.approval_required)
    val actionLabel = stringResource(R.string.approval_action)
    val evidenceLabel = stringResource(R.string.approval_evidence)
    val chooseScopeLabel = stringResource(R.string.approval_scope_choose)
    val denyLabel = stringResource(R.string.action_deny)
    val approveLabel = stringResource(R.string.action_approve)
    val skillNote = stringResource(R.string.approval_skill_create_note)
    val slotConflictNote = stringResource(R.string.approval_terminal_conflict_note)
    val endTerminalAndRunLabel = stringResource(R.string.approval_terminal_end_and_run)
    val handoffRefusalNote = stringResource(R.string.approval_terminal_handoff_refused)
    val handoffRefusalDetailsLabel = stringResource(R.string.approval_terminal_handoff_details)
    val tierLabels = listOf(
        stringResource(R.string.approval_scope_once),
    )
    val headerTint = if (gateStopped) colors.destructive else colors.pending
    // One stable resolution lambda: the presentedCard NEVER fabricates a decision
    // without a human tap on these two controls.
    val backendResolve: (ApprovalCardUi, Boolean) -> Unit =
        { c, allow ->
            if (c.workspaceAction != null || c.localShellAction != null || c.scheduleCreateAction != null || c.browserTabAction != null || c.browserInteractionAction != null || c.browserVisualAction != null) holder.resolveApproval(c, allow, presentationLease = lease)
            else if (onResolve != null) onResolve(c, allow) else holder.resolveApproval(c, allow)
        }
    // The current native decision contract is call-bound. Never promise
    // task/project/host grants that the producer cannot forward.
    val resolve: (ApprovalCardUi, Boolean) -> Unit = { c, allow ->
        if (allow) holder.setApprovalScope(c.key, ApprovalScopeChoiceUi.ONCE, expected = card)
        backendResolve(c, allow)
    }
    // The explicit handoff is a THIRD human control, not a variant of Allow:
    // it is the only path that may end a manual terminal, and the host still
    // re-fences the captured identity, proves the real engine release and only
    // then dispatches this already-proposed call once through the ordinary
    // route. Nothing here stops anything itself.
    val backendEndTerminalAndRun: (ApprovalCardUi, TerminalHandoffConsentUi) -> Unit =
        onEndTerminalAndRun ?: { c, consent ->
            holder.resolveApproval(c, allow = true, terminalHandoff = consent, presentationLease = lease)
        }
    val endTerminalAndRun: (ApprovalCardUi) -> Unit = { c ->
        // Consent belongs to the terminal captured when this control was
        // presented. Never replace it with another live session at tap time.
        val consent = handoff.consent
        if (consent == null || consent.sessionToken.isEmpty() ||
            consent != holder.liveTerminalHandoffConsent()) {
            // The terminal settled between the presentedCard being projected and this
            // tap. Nothing is stopped, approved or dispatched; the presentedCard says
            // so plainly and the ordinary Allow/Deny stays available.
            holder.noteTerminalCaptureRefusal(card, "staleCapture")
        } else {
            holder.setApprovalScope(c.key, ApprovalScopeChoiceUi.ONCE, expected = card)
            backendEndTerminalAndRun(c, consent)
        }
    }
    val borderTint = headerTint.copy(alpha = 0.6f)
    val shape = RoundedCornerShape(FloeLayout.BubbleCorner)

    Column(
        modifier = modifier
            .onGloballyPositioned { coordinates ->
                val bounds = coordinates.boundsInWindow()
                visible = coordinates.isAttached && bounds.width > 0f && bounds.height > 0f
            }
            .fillMaxWidth()
            .clip(shape)
            .border(1.dp, borderTint, shape)
            .background(colors.groupedSurface)
            .padding(12.dp)
            .semantics { contentDescription = headerTitle },
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            IconGlyph(
                if (gateStopped) FloeIcons.ShieldAlert else FloeIcons.ShieldAlert,
                headerTint,
                20.dp,
            )
            FloeText(headerTitle, style = Floe.typography.section, color = colors.label)
            Spacer(Modifier.weight(1f))
            FloeText(presentedCard.requestedAtLabel, style = Floe.typography.metadata, color = colors.secondaryLabel)
        }

        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FloeText(actionLabel, style = Floe.typography.metadata, color = colors.secondaryLabel)
                FloeText(presentedCard.toolName, style = Floe.typography.evidence, color = colors.label)
            }
            if (presentedCard.scopeVerified) {
                FloeText(if (browserVisual != null) stringResource(R.string.approval_browser_visual_click)
                else if (browserInteraction != null) stringResource(when (browserInteraction.operation) {
                    "click" -> R.string.approval_browser_click
                    "type" -> R.string.approval_browser_type
                    else -> R.string.approval_browser_scroll
                })
                else if (browserTabAction != null) stringResource(when (browserTabAction.operation) {
                    "activate" -> R.string.approval_browser_tab_activate
                    "close" -> R.string.approval_browser_tab_close
                    else -> R.string.approval_browser_tab_create
                })
                else if (scheduleAction != null) stringResource(R.string.approval_schedule_create)
                else if (shellAction != null) stringResource(R.string.approval_shell_action)
                else if (fileAction != null) when (fileAction.operation) {
                    "createFile" -> stringResource(R.string.approval_workspace_create)
                    "writeFile" -> stringResource(R.string.approval_workspace_write)
                    "applyPatch" -> stringResource(R.string.approval_workspace_patch)
                    "appendFile" -> stringResource(R.string.approval_workspace_append)
                    "replaceText" -> stringResource(R.string.approval_workspace_replace)
                    "createDirectory" -> stringResource(R.string.approval_workspace_create_directory)
                    "moveFile" -> stringResource(R.string.approval_workspace_move)
                    "copyFile" -> stringResource(R.string.approval_workspace_copy)
                    "deleteFile" -> stringResource(R.string.approval_workspace_delete)
                    else -> ""
                } else when (presentedCard.actionKind) {
                    "back" -> stringResource(R.string.approval_device_back)
                    "home" -> stringResource(R.string.approval_device_home)
                    "launch" -> stringResource(R.string.approval_device_launch)
                    else -> ""
                }, style = Floe.typography.bodyEmphasized, color = colors.label)
                if (browserVisual != null) {
                    browserVisual.title?.let { title ->
                        FloeText(title, style = Floe.typography.evidence, color = colors.label)
                    }
                    FloeText(browserVisual.url, style = Floe.typography.evidence, color = colors.label)
                    FloeText(stringResource(R.string.approval_browser_visual_coordinates,
                        browserVisual.pointX.toString(), browserVisual.pointY.toString()),
                        style = Floe.typography.metadata, color = colors.label)
                    FloeText(stringResource(if (browserVisual.fallbackReason == "noStructuredTarget")
                        R.string.approval_browser_visual_no_target else R.string.approval_browser_visual_insufficient),
                        style = Floe.typography.metadata, color = colors.secondaryLabel)
                    FloeText(stringResource(R.string.approval_browser_visual_hint),
                        style = Floe.typography.metadata, color = colors.secondaryLabel)
                    Box(Modifier.fillMaxWidth().height(220.dp).onGloballyPositioned { coordinates ->
                        val bounds = coordinates.boundsInWindow()
                        val whollyVisible = coordinates.isAttached && coordinates.size.width > 0 &&
                            coordinates.size.height > 0 && bounds.width >= coordinates.size.width * 0.95f &&
                            bounds.height >= coordinates.size.height * 0.95f
                        if (whollyVisible && !visualSeen && lease != null && resumed) {
                            holder.setPrivateBrowserVisualVisible(card, lease!!, true)
                            visualSeen = true
                        }
                    }) {
                        Image(bitmap = browserVisual.screenshot.asImageBitmap(),
                            contentDescription = stringResource(R.string.approval_browser_visual_hint),
                            contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize())
                        Canvas(Modifier.fillMaxSize()) {
                            val point = browserVisualFitPoint(
                                browserVisual.originalWidth, browserVisual.originalHeight,
                                browserVisual.screenshot.width, browserVisual.screenshot.height,
                                browserVisual.pointX, browserVisual.pointY, size.width, size.height)
                            val center = Offset(point.first, point.second)
                            drawCircle(Color.White, radius = 13.dp.toPx(), center = center, style = Stroke(4.dp.toPx()))
                            drawCircle(Color.Red, radius = 11.dp.toPx(), center = center, style = Stroke(2.dp.toPx()))
                            drawLine(Color.Red, Offset(center.x - 16.dp.toPx(), center.y),
                                Offset(center.x + 16.dp.toPx(), center.y), 2.dp.toPx())
                            drawLine(Color.Red, Offset(center.x, center.y - 16.dp.toPx()),
                                Offset(center.x, center.y + 16.dp.toPx()), 2.dp.toPx())
                        }
                    }
                }
                if (browserInteraction != null) {
                    browserInteraction.title?.let { title ->
                        FloeText(stringResource(R.string.approval_browser_tab_title),
                            style = Floe.typography.metadata, color = colors.secondaryLabel)
                        SelectionContainer { FloeText(title, style = Floe.typography.evidence, color = colors.label) }
                    }
                    FloeText(stringResource(R.string.approval_browser_tab_url),
                        style = Floe.typography.metadata, color = colors.secondaryLabel)
                    SelectionContainer { FloeText(browserInteraction.url, modifier = Modifier.fillMaxWidth(),
                        style = Floe.typography.evidence, color = colors.label) }
                    if (browserInteraction.ref != null) {
                        FloeText(stringResource(R.string.approval_browser_target),
                            style = Floe.typography.metadata, color = colors.secondaryLabel)
                        SelectionContainer {
                            FloeText(listOfNotNull(browserInteraction.label, browserInteraction.role, browserInteraction.ref)
                                .joinToString(" · "), modifier = Modifier.fillMaxWidth(),
                                style = Floe.typography.evidence, color = colors.label)
                        }
                    }
                    browserInteraction.textBytes?.let { count ->
                        FloeText(stringResource(R.string.approval_browser_text_bytes, count),
                            style = Floe.typography.body, color = colors.label)
                        FloeText(stringResource(if (browserInteraction.submit == true)
                            R.string.approval_browser_submit_yes else R.string.approval_browser_submit_no),
                            style = Floe.typography.body, color = colors.label)
                    }
                    if (browserInteraction.deltaX != null && browserInteraction.deltaY != null) {
                        FloeText(stringResource(R.string.approval_browser_scroll_distance,
                            browserInteraction.deltaX.toString(), browserInteraction.deltaY.toString()),
                            style = Floe.typography.body, color = colors.label)
                    }
                }
                if (browserTabAction != null && browserTabAction.operation != "create") {
                    if (browserTabAction.tabIndex != null && browserTabAction.tabCount != null) {
                        FloeText(stringResource(R.string.approval_browser_tab_position,
                            browserTabAction.tabIndex, browserTabAction.tabCount),
                            style = Floe.typography.body, color = colors.label)
                    }
                    browserTabAction.title?.takeUnless { it.isBlank() }?.let { title ->
                        FloeText(stringResource(R.string.approval_browser_tab_title),
                            style = Floe.typography.metadata, color = colors.secondaryLabel)
                        SelectionContainer {
                            FloeText(title, modifier = Modifier.fillMaxWidth(),
                                style = Floe.typography.evidence, color = colors.label)
                        }
                    }
                    browserTabAction.url?.takeUnless { it.isBlank() }?.let { url ->
                        FloeText(stringResource(R.string.approval_browser_tab_url),
                            style = Floe.typography.metadata, color = colors.secondaryLabel)
                        SelectionContainer {
                            FloeText(url, modifier = Modifier.fillMaxWidth(),
                                style = Floe.typography.evidence, color = colors.label)
                        }
                    }
                }
                if (scheduleAction != null) {
                    ScheduleApprovalDetails(scheduleAction)
                }
                if (fileAction != null) {
                    FloeText(stringResource(R.string.approval_workspace_id),
                        style = Floe.typography.metadata, color = colors.secondaryLabel)
                    SelectionContainer {
                        FloeText(fileAction.workspaceId, modifier = Modifier.fillMaxWidth(),
                            style = Floe.typography.evidence, color = colors.label)
                    }
                    FloeText(stringResource(R.string.approval_workspace_target),
                        style = Floe.typography.metadata, color = colors.secondaryLabel)
                    SelectionContainer {
                        FloeText(fileAction.targetPath, modifier = Modifier.fillMaxWidth(),
                            style = Floe.typography.evidence, color = colors.label)
                    }
                    if (fileAction.operation in setOf("createFile", "writeFile", "moveFile", "copyFile", "createDirectory")) {
                        FloeText(stringResource(when (fileAction.overwrite) {
                            "allowed" -> R.string.approval_overwrite_allowed
                            "forbidden" -> R.string.approval_overwrite_forbidden
                            else -> R.string.approval_overwrite_conditional
                        }), style = Floe.typography.metadata, color = colors.secondaryLabel)
                    }
                    FloeText(stringResource(when (fileAction.precondition) {
                        "sha256" -> R.string.approval_precondition_sha
                        "mtime" -> R.string.approval_precondition_mtime
                        "sha256AndMtime" -> R.string.approval_precondition_both
                        "patchContext" -> R.string.approval_precondition_patch
                        "fileExists" -> R.string.approval_precondition_exists
                        "fileExistsAndSha256" -> R.string.approval_precondition_exists_sha
                        "occurrences" -> R.string.approval_precondition_occurrences
                        "occurrencesAndSha256" -> R.string.approval_precondition_occurrences_sha
                        "sourceExists" -> R.string.approval_precondition_source_exists
                        "exists" -> R.string.approval_precondition_exists
                        else -> R.string.approval_precondition_none
                    }), style = Floe.typography.metadata, color = colors.secondaryLabel)
                    fileAction.expectedOccurrences?.let {
                        FloeText(stringResource(R.string.approval_expected_occurrences, it.toString()),
                            style = Floe.typography.metadata, color = colors.secondaryLabel)
                    }
                    fileAction.recursive?.let {
                        FloeText(stringResource(if (it) R.string.approval_recursive_on else R.string.approval_recursive_off),
                            style = Floe.typography.metadata, color = colors.destructive)
                    }
                    if (fileAction.operation in setOf("createDirectory", "moveFile", "copyFile")) {
                        FloeText(stringResource(if (fileAction.operation == "createDirectory") R.string.approval_directory_parents
                            else R.string.approval_copy_move_directories),
                            style = Floe.typography.metadata, color = colors.secondaryLabel)
                    }
                    if (fileAction.source != "none") FloeText(stringResource(when (fileAction.source) {
                        "workspaceFile" -> R.string.approval_source_file
                        "patch" -> R.string.approval_source_patch
                        else -> R.string.approval_source_inline
                    }), style = Floe.typography.metadata, color = colors.secondaryLabel)
                    fileAction.sourcePath?.let { sourcePath ->
                        SelectionContainer {
                            FloeText(sourcePath, modifier = Modifier.fillMaxWidth(),
                                style = Floe.typography.evidence, color = colors.label)
                        }
                        FloeText(stringResource(if (fileAction.sourcePrecondition == "sha256") R.string.approval_source_sha
                            else R.string.approval_source_exists),
                            style = Floe.typography.metadata, color = colors.secondaryLabel)
                    }
                }
                if (shellAction != null) {
                    FloeText(stringResource(R.string.approval_shell_target),
                        style = Floe.typography.metadata, color = colors.secondaryLabel)
                    FloeText(stringResource(R.string.approval_shell_local_linux),
                        style = Floe.typography.bodyEmphasized, color = colors.label)
                    SelectionContainer {
                        FloeText(shellAction.environmentId, modifier = Modifier.fillMaxWidth(),
                            style = Floe.typography.evidence, color = colors.label)
                    }
                    FloeText(stringResource(R.string.approval_workspace_id),
                        style = Floe.typography.metadata, color = colors.secondaryLabel)
                    SelectionContainer {
                        FloeText(shellAction.workspaceId, modifier = Modifier.fillMaxWidth(),
                            style = Floe.typography.evidence, color = colors.label)
                    }
                    FloeText(stringResource(R.string.approval_shell_cwd),
                        style = Floe.typography.metadata, color = colors.secondaryLabel)
                    SelectionContainer {
                        FloeText(shellAction.cwd, modifier = Modifier.fillMaxWidth(),
                            style = Floe.typography.evidence, color = colors.label)
                    }
                    FloeText(stringResource(R.string.approval_shell_command),
                        style = Floe.typography.metadata, color = colors.secondaryLabel)
                    SelectionContainer {
                        FloeText(shellAction.command, modifier = Modifier.horizontalScroll(rememberScrollState()),
                            style = Floe.typography.evidence, color = colors.label)
                    }
                    FloeText(stringResource(R.string.approval_shell_timeout, shellAction.timeoutSeconds.toString()),
                        style = Floe.typography.metadata, color = colors.secondaryLabel)
                    FloeText(stringResource(R.string.approval_shell_output, shellAction.maxOutputBytes),
                        style = Floe.typography.metadata, color = colors.secondaryLabel)
                    FloeText(stringResource(if (shellAction.environmentTransaction) R.string.approval_shell_transaction_on
                        else R.string.approval_shell_transaction_off),
                        style = Floe.typography.metadata, color = colors.secondaryLabel)
                    if (shellAction.shellPrivateBytes != null && lease != null) {
                        val currentLease = lease!!
                        FloeText(stringResource(if (shellExpanded) R.string.approval_shell_hide_private
                            else R.string.approval_shell_show_private),
                            modifier = Modifier.clickable {
                                shellExpanded = !shellExpanded
                                if (shellExpanded && shellAction.env == null)
                                    holder.loadPrivateShellDetails(card, currentLease)
                            }.padding(vertical = 8.dp),
                            style = Floe.typography.bodyEmphasized, color = colors.accent)
                        if (shellExpanded) {
                            if (holder.privateShellLoading(currentLease)) {
                                FloeText(stringResource(R.string.approval_shell_private_loading),
                                    style = Floe.typography.metadata, color = colors.secondaryLabel)
                            } else if (holder.privateShellLoadFailed(currentLease)) {
                                FloeText(stringResource(R.string.approval_shell_private_failed),
                                    modifier = Modifier.clickable { holder.loadPrivateShellDetails(card, currentLease) },
                                    style = Floe.typography.metadata, color = colors.destructive)
                            } else if (shellAction.env != null) {
                                val absent = stringResource(R.string.approval_shell_stdin_absent)
                                val noEnv = stringResource(R.string.approval_shell_env_empty)
                                val sections = remember(shellAction.stdin, shellAction.env, absent, noEnv) {
                                    val values = mutableListOf<Triple<String, String, Boolean>>()
                                    values += Triple("stdin", shellAction.stdin ?: absent, shellAction.stdin != null)
                                    if (shellAction.env.isEmpty()) values += Triple("env", noEnv, false)
                                    else shellAction.env.toSortedMap().forEach { (key, value) ->
                                        values += Triple(key, value, true)
                                    }
                                    values.flatMap { (name, value, quoted) ->
                                        val chunks = if (quoted) chunkPrivateShellText(value) else listOf(value)
                                        chunks.mapIndexed { index, chunk ->
                                            val content = (if (quoted && index == 0) "\"" else "") + chunk +
                                                (if (quoted && index == chunks.lastIndex) "\"" else "")
                                            (if (chunks.size == 1) name else "$name (${index + 1}/${chunks.size})") to content
                                        }
                                    }
                                }
                                FloeText(stringResource(R.string.approval_shell_private_escape_note),
                                    style = Floe.typography.metadata, color = colors.secondaryLabel)
                                LazyColumn(modifier = Modifier.fillMaxWidth().heightIn(min = 96.dp, max = 240.dp)) {
                                    items(sections.size) { index ->
                                        val (label, value) = sections[index]
                                        FloeText(label, style = Floe.typography.metadata, color = colors.secondaryLabel)
                                        SelectionContainer {
                                            FloeText(value, modifier = Modifier.fillMaxWidth(),
                                                style = Floe.typography.evidence, color = colors.label)
                                        }
                                    }
                                }
                                FloeText(stringResource(if (holder.privateShellReviewed(currentLease))
                                    R.string.approval_shell_private_confirmed else R.string.approval_shell_private_confirm),
                                    modifier = Modifier.clickable {
                                        holder.confirmPrivateShellDetails(card, currentLease)
                                    }.padding(vertical = 8.dp),
                                    style = Floe.typography.bodyEmphasized, color = colors.accent)
                            }
                        }
                    }
                }
                presentedCard.actionPackage?.let { packageName ->
                    FloeText(stringResource(R.string.approval_device_package),
                        style = Floe.typography.metadata, color = colors.secondaryLabel)
                    SelectionContainer {
                        FloeText(packageName, modifier = Modifier.fillMaxWidth(),
                            style = Floe.typography.evidence, color = colors.label)
                    }
                }
                FloeText(stringResource(if (scheduleAction != null) R.string.approval_schedule_note
                    else if (shellAction != null) R.string.approval_shell_scope_note
                    else if (fileAction == null) R.string.approval_requested_scope_note
                    else R.string.approval_workspace_scope_note),
                    style = Floe.typography.metadata, color = colors.secondaryLabel)
            }
            if (presentedCard.reason.isNotEmpty() && !reasonIsSlotConflict) {
                FloeText(
                    if (presentedCard.reason == "No approval model is configured for this sensitive action") {
                        stringResource(R.string.approval_model_missing)
                    } else presentedCard.reason,
                    style = Floe.typography.metadata,
                    color = if (gateStopped) colors.destructive else colors.secondaryLabel,
                )
            }
            if (slotConflict) {
                // One short actionable sentence: what is blocking and what the
                // user can do. No session token, generation, exit code or
                // protocol detail belongs on this surface.
                FloeText(
                    slotConflictNote,
                    style = Floe.typography.metadata,
                    color = colors.pending,
                )
            }
            if (ApprovalGrantMapping.isSkillCreation(presentedCard.toolName)) {
                FloeText(skillNote, style = Floe.typography.metadata, color = colors.pending)
            }
        }

        if (presentedCard.riskLabels.isNotEmpty()) {
            val riskGroupLabel = stringResource(R.string.approval_risks)
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState())
                    .semantics { contentDescription = riskGroupLabel },
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                presentedCard.riskLabels.sorted().forEach { raw ->
                    val localized = riskLabelText(raw)
                    FloeBadgePill(text = localized, tone = FloeBadgeTone.PENDING)
                }
            }
        }

        // A handoff refusal carries a diagnostic code, so the fold must exist
        // even for a presentedCard that would otherwise have no evidence section:
        // message on the surface, opaque code in the opened details only.
        if (ApprovalGrantMapping.requiresEvidence(presentedCard.isSideEffecting, presentedCard.riskLabels) ||
            handoffRefusal != null
        ) {
            val expanded = presentedCard.key in holder.expandedApprovalEvidence.value
            Column {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = FloeLayout.MinimumTarget)
                        .clickable { holder.toggleApprovalEvidence(presentedCard.key, expected = card) },
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    IconGlyph(FloeIcons.ChevronUpDown, colors.accent, 14.dp)
                    FloeText(evidenceLabel, style = Floe.typography.metadata, color = colors.accent)
                    Spacer(Modifier.weight(1f))
                    IconGlyph(
                        if (expanded) FloeIcons.ChevronUp else FloeIcons.ChevronDown,
                        colors.secondaryLabel,
                        14.dp,
                    )
                }
                if (expanded) {
                    Spacer(Modifier.height(6.dp))
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(8.dp))
                            .background(colors.readingSurface)
                            .padding(8.dp),
                    ) {
                        presentedCard.evidenceLines.forEach { line ->
                            FloeText(line, style = Floe.typography.evidence, color = colors.secondaryLabel)
                        }
                        if (handoffRefusal != null) {
                            FloeText(
                                "$handoffRefusalDetailsLabel ${handoffRefusal.code}",
                                style = Floe.typography.evidence,
                                color = colors.secondaryLabel,
                            )
                        }
                    }
                }
            }
        }

        if (presentedCard.scopeVerified) Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            FloeText(chooseScopeLabel, style = Floe.typography.metadata, color = colors.secondaryLabel)
            FloeSegmented(
                options = tierLabels,
                selectedIndex = 0,
                onSelect = { _ ->
                    holder.setApprovalScope(card.key, ApprovalScopeChoiceUi.ONCE, expected = card)
                },
            )
        }

        if (handoff.allowsEndAndRun) {
            // The wording states the effect plainly: this ENDS the task's
            // terminal and then runs the proposed command. It is never an
            // unconditional auto-stop and never implied by a policy or tier.
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = FloeLayout.MinimumTarget)
                    .clip(RoundedCornerShape(FloeLayout.CircleToolbarCorner))
                    .background(colors.pending)
                    .clickable(enabled = canAllow) { endTerminalAndRun(presentedCard) }
                    .semantics { contentDescription = endTerminalAndRunLabel }
                    .padding(horizontal = 14.dp, vertical = 8.dp),
                contentAlignment = Alignment.Center,
            ) {
                FloeText(
                    endTerminalAndRunLabel,
                    style = Floe.typography.bodyEmphasized,
                    color = colors.readingSurface,
                )
            }
        }
        if (handoffRefusal != null) {
            // Honest refusal: nothing was approved, nothing ran, and the presentedCard
            // stays actionable. The opaque code lives in the details line.
            FloeText(
                handoffRefusalNote,
                style = Floe.typography.metadata,
                color = colors.destructive,
            )
        }

        when (dispatchState) {
            ApprovalDispatchState.PROCESSING, ApprovalDispatchState.CHECKING -> FloeText(
                stringResource(R.string.approval_processing), style = Floe.typography.metadata, color = colors.secondaryLabel)
            ApprovalDispatchState.NEEDS_CHECK -> FloeText(
                stringResource(R.string.approval_result_unknown), style = Floe.typography.metadata, color = colors.destructive)
            ApprovalDispatchState.STOP_REQUIRED -> FloeText(
                stringResource(R.string.approval_changed_stop), style = Floe.typography.metadata, color = colors.destructive)
            ApprovalDispatchState.RETRY_READY -> FloeText(
                stringResource(R.string.approval_retry_ready), style = Floe.typography.metadata, color = colors.destructive)
            null -> Unit
        }
        if (!presentedCard.identityVerified || !presentedCard.scopeVerified || !detailsVisible) {
            FloeText(stringResource(when {
                !presentedCard.identityVerified -> R.string.approval_identity_unavailable
                unidentifiedBrowserTarget -> R.string.approval_browser_tab_unidentified
                else -> R.string.approval_details_unavailable
            }), style = Floe.typography.metadata, color = colors.secondaryLabel)
        }
        if (dispatchState == ApprovalDispatchState.NEEDS_CHECK ||
            (!decisionInFlight && (!presentedCard.identityVerified || !presentedCard.scopeVerified || !detailsVisible))) {
            FloeText(stringResource(R.string.approval_recheck),
                modifier = Modifier.clickable { holder.recheckApproval(card) }.padding(vertical = 8.dp),
                style = Floe.typography.bodyEmphasized, color = colors.accent)
        }
        if (!presentedCard.identityVerified || dispatchState == ApprovalDispatchState.NEEDS_CHECK ||
            dispatchState == ApprovalDispatchState.STOP_REQUIRED) {
            FloeText(stringResource(R.string.action_stop),
                modifier = Modifier.clickable { holder.stopForApproval(card) }.padding(vertical = 8.dp),
                style = Floe.typography.bodyEmphasized, color = colors.destructive)
        }

        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(
                modifier = Modifier
                    .weight(1f)
                    .heightIn(min = FloeLayout.MinimumTarget)
                    .clip(RoundedCornerShape(FloeLayout.CircleToolbarCorner))
                    .border(0.5.dp, colors.chromeHairline, RoundedCornerShape(FloeLayout.CircleToolbarCorner))
                    .clickable(enabled = canDeny) { resolve(presentedCard, false) }
                    .semantics { contentDescription = denyLabel }
                    .padding(horizontal = 14.dp, vertical = 8.dp),
                contentAlignment = Alignment.Center,
            ) {
                FloeText(denyLabel, style = Floe.typography.bodyEmphasized,
                    color = if (canDeny) colors.label else colors.secondaryLabel.copy(alpha = 0.45f))
            }
            val allowTint = if (!canAllow) colors.secondaryLabel.copy(alpha = 0.25f)
                else if (presentedCard.isSideEffecting) colors.destructive else colors.accent
            Box(
                modifier = Modifier
                    .weight(1f)
                    .heightIn(min = FloeLayout.MinimumTarget)
                    .clip(RoundedCornerShape(FloeLayout.CircleToolbarCorner))
                    .background(allowTint)
                    .clickable(enabled = canAllow) { resolve(presentedCard, true) }
                    .semantics { contentDescription = approveLabel }
                    .padding(horizontal = 14.dp, vertical = 8.dp),
                contentAlignment = Alignment.Center,
            ) {
                FloeText(approveLabel, style = Floe.typography.bodyEmphasized, color = colors.readingSurface)
            }
        }
        if (gateStopped) {
            FloeDivider()
            // Honest statement of the host rule: the tier only narrows what
            // an ALLOW may remember; the catastrophic stop still needs the
            // runtime's second local authentication before anything runs.
            FloeText(
                stringResource(R.string.approval_gate_stopped_note),
                style = Floe.typography.metadata,
                color = colors.destructive,
            )
        }
    }
}

@Composable
private fun ScheduleApprovalDetails(details: ScheduleCreateApprovalUi) {
    val cadence = stringResource(when (details.cadence) {
        "once" -> R.string.approval_schedule_once
        "daily" -> R.string.approval_schedule_daily
        "weekly" -> R.string.approval_schedule_weekly
        "interval" -> R.string.approval_schedule_interval
        "afterSuccess" -> R.string.approval_schedule_after_success
        "charging" -> R.string.approval_schedule_charging
        else -> R.string.approval_schedule_network
    })
    val approval = stringResource(when (details.approvalMode) {
        "ask" -> R.string.approval_schedule_policy_ask
        "automatic" -> R.string.approval_schedule_policy_automatic
        else -> R.string.approval_schedule_policy_full
    })
    val recovery = stringResource(if (details.recoveryPolicy == "safePoint") R.string.approval_schedule_recovery_safe else R.string.approval_schedule_recovery_retry)
    val notifications = stringResource(when (details.notificationPolicy) {
        "off" -> R.string.approval_schedule_notify_off
        "terminal" -> R.string.approval_schedule_notify_terminal
        "critical" -> R.string.approval_schedule_notify_critical
        else -> R.string.approval_schedule_notify_stages
    })
    ScheduleField(stringResource(R.string.approval_schedule_title), details.title)
    ScheduleField(stringResource(R.string.approval_schedule_prompt), details.prompt)
    ScheduleField(stringResource(R.string.approval_schedule_repeat), cadence)
    ScheduleField(stringResource(R.string.approval_schedule_anchor), details.scheduledAt)
    ScheduleField(stringResource(R.string.approval_schedule_timezone), details.timezone)
    val localTime = remember(details.scheduledAt, details.timezone) {
        runCatching { java.time.Instant.parse(details.scheduledAt).atZone(java.time.ZoneId.of(details.timezone)).toOffsetDateTime().toString() }.getOrNull()
    }
    if (localTime != null) ScheduleField(stringResource(R.string.approval_schedule_local_time), localTime)
    details.weekday?.let { day ->
        val dayName = stringResource(when (day) {
            1 -> R.string.approval_schedule_sunday
            2 -> R.string.approval_schedule_monday
            3 -> R.string.approval_schedule_tuesday
            4 -> R.string.approval_schedule_wednesday
            5 -> R.string.approval_schedule_thursday
            6 -> R.string.approval_schedule_friday
            else -> R.string.approval_schedule_saturday
        })
        ScheduleField(stringResource(R.string.approval_schedule_weekday), dayName)
    }
    details.intervalSeconds?.let {
        ScheduleField(stringResource(R.string.approval_schedule_interval_label), stringResource(R.string.approval_schedule_seconds, it.toString()))
    }
    details.upstreamRunId?.let { ScheduleField(stringResource(R.string.approval_schedule_upstream), it) }
    ScheduleField(stringResource(R.string.approval_schedule_model), details.modelId)
    ScheduleField(stringResource(R.string.approval_schedule_workspace), details.workspaceId ?: stringResource(R.string.approval_schedule_new_workspace))
    ScheduleField(stringResource(R.string.approval_schedule_environment), details.environmentId ?: stringResource(R.string.approval_schedule_default_environment))
    ScheduleField(stringResource(R.string.approval_schedule_approval), approval)
    ScheduleField(stringResource(R.string.approval_schedule_recovery), recovery)
    ScheduleField(stringResource(R.string.approval_schedule_notifications), notifications)
}

@Composable
private fun ScheduleField(label: String, value: String) {
    FloeText(label, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
    SelectionContainer {
        FloeText(value, modifier = Modifier.fillMaxWidth(), style = Floe.typography.evidence, color = Floe.colors.label)
    }
}

@Composable
private fun riskLabelText(raw: String): String {
    val key = ApprovalGrantMapping.riskLabelKey(raw)
    return when (key) {
        "risk_reads_files" -> stringResource(R.string.risk_reads_files)
        "risk_writes_files" -> stringResource(R.string.risk_writes_files)
        "risk_deletes_files" -> stringResource(R.string.risk_deletes_files)
        "risk_executes_local_code" -> stringResource(R.string.risk_executes_local_code)
        "risk_executes_remote_command" -> stringResource(R.string.risk_executes_remote_command)
        "risk_modifies_remote_system" -> stringResource(R.string.risk_modifies_remote_system)
        "risk_network_access" -> stringResource(R.string.risk_network_access)
        "risk_sends_data_to_provider" -> stringResource(R.string.risk_sends_data_to_provider)
        "risk_controls_gui" -> stringResource(R.string.risk_controls_gui)
        "risk_accesses_credentials" -> stringResource(R.string.risk_accesses_credentials)
        // Unknown catalog labels render their raw value (still non-secret),
        // exactly like the Swift fallback.
        else -> raw
    }
}
