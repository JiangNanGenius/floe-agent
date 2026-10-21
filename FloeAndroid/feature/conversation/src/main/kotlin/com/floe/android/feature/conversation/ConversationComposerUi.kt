// SPDX-License-Identifier: MPL-2.0
//
// Thread composer section: the design-system FloeComposer surface plus the
// conversation-specific tray/chips (⇄ ThreadComposerView.swift context row,
// attachment chips, queue/steer affordance, permission chip) and the pending
// input queue (⇄ PendingInputQueueView). Geometry stays owned by the shared
// composer wrappers (r22 chrome, 48dp targets, IME/safe insets). When the host
// supplies actual pane geometry (G02 split view), the composer fills that
// pane and the field's one-third height cap uses the pane height; otherwise
// the G01 centred 720dp/screen-height defaults are untouched.
//
// The expand entry (⇄ `isInlineFieldOverflowing`) is derived from the ACTUAL
// inline field width measured by the composer and real Compose text layout at
// the composer typography — never from a min(screenWidth, 720) heuristic when
// pane geometry is available. The full editor itself remains a separate
// dialog and keeps its own bounds.
//
// Honesty rules preserved here:
//  - send gating comes from the shared ComposerSendPolicy plus the projected
//    provider state; while attachments import, send is honestly disabled;
//  - the temporary composer hides attachments/workspace/target/mode/
//    permission chips (ephemeral runs are the ordinary agent turn under the
//    host's read-only ceiling; starting temporary chat stays a New-Task-only
//    entry); staged files are neither rendered nor sent but remain in the
//    draft untouched;
//  - model identity fields stay distinct: the chip shows displayName,
//    selection carries the saved UUID, and the wire id never appears in UI
//    copy; Android is cloud-only, so no local-model groups exist;
//  - capability chips project host usability (enabled+configured+usable);
//    skill/MCP admin pages belong to a later bounded package.

package com.floe.android.feature.conversation

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.floe.android.design.ComposerAvailability
import com.floe.android.design.CupertinoMenuEntry
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeChipMenu
import com.floe.android.design.FloeChipTone
import com.floe.android.design.FloeComposer
import com.floe.android.design.FloeComposerChip
import com.floe.android.design.FloeComposerGeometry
import com.floe.android.design.FloeComposerLayout
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloeText
import com.floe.android.design.IconGlyph

/* --------------------------------- the section -------------------------------- */

@Composable
fun ConversationComposerSection(
    holder: ConversationFlowHolder,
    onSend: () -> Unit,
    onStop: () -> Unit,
    modifier: Modifier = Modifier,
    paneGeometry: ConversationPaneGeometry? = null,
) {
    val state = holder.snapshot.value ?: return
    val attachDescription = stringResource(R.string.composer_attach)
    val voiceDescription = stringResource(R.string.voice_start)
    val sendLabel = sendActionLabel(state, holder)
    val placeholder = stringResource(R.string.composer_placeholder)
    // ⇄ ComposerFieldMetrics.lineCap: compact-width panes get 6 lines,
    // regular/tablet panes get 8. The actual pane decides, so a narrow split
    // column inside a wide window does not keep the tablet line budget. The
    // unmeasured G01 fallback keeps the historical regular budget.
    val inlineMaxLines = paneGeometry?.let {
        FloeComposerGeometry.inlineLineBudgetFor(it.width)
    } ?: FloeLayout.ComposerMaxLinesRegular

    // The measured width survives size/font-scale/theme recomposition but is
    // discarded on a session rebind, a different pane width, or a control-row
    // change (Stop appears/disappears), so the overflow rule never evaluates a
    // new layout against the previous slot width.
    var measuredFieldWidth by remember(
        state.session,
        paneGeometry?.width,
        state.isRunning,
    ) {
        mutableStateOf<Dp?>(null)
    }
    val offerFullEditor: Boolean = if (paneGeometry != null) {
        val fieldWidth = measuredFieldWidth
            ?: FloeComposerGeometry.estimatedInlineFieldWidth(
                paneWidth = paneGeometry.width,
                visibleControlCount = if (state.isRunning) 4 else 3,
            )
        rememberInlineFieldOverflowing(
            text = holder.draft.value.text,
            maxLines = inlineMaxLines,
            fieldWidth = fieldWidth,
            pageHeight = paneGeometry.height,
            style = Floe.typography.composerField,
            fontScale = paneGeometry.fontScale,
        )
    } else {
        // G01/component-preview fallback: unchanged screen-derived
        // approximation. A real host always takes the measured branch above.
        val screenWidthDp = LocalConfiguration.current.screenWidthDp.toFloat()
        FullEditorPolicy.shouldOfferFullEditor(
            text = holder.draft.value.text,
            inlineMaxLines = inlineMaxLines,
            fieldWidthDp = legacyFullEditorFieldWidthDp(screenWidthDp),
        )
    }

    Column(modifier = modifier.fillMaxWidth()) {
        if (state.pendingInputs.isNotEmpty()) {
            PendingInputQueueSection(holder)
        }
        // ⇄ ThreadComposerView banner stack above the input row:
        holder.modelPersistenceFailureName?.let { name ->
            InlineBanner(
                icon = FloeIcons.InfoCircle,
                text = stringResource(R.string.model_persist_failed, name),
                tint = Floe.colors.pending,
                onDismiss = holder::dismissModelPersistenceBanner,
            )
        }
        holder.attachmentError?.let { message ->
            InlineBanner(
                icon = FloeIcons.WarningTriangle,
                text = message,
                tint = Floe.colors.destructive,
                onDismiss = holder::dismissAttachmentError,
            )
        }
        if (state.needsProvider) {
            AddProviderBar()
        }
        if (!state.isTemporary && holder.stagedAttachments.value.isNotEmpty()) {
            StagedAttachmentTray(holder)
        }
        FloeComposer(
            value = holder.draft.value,
            onValueChange = holder::onDraftChange,
            availability = ComposerAvailability(
                providerConfigured = !state.needsProvider,
                attachmentsProcessing = holder.anyAttachmentProcessing(),
                voiceAvailable = state.voiceAvailable,
                temporaryChatAvailable = false, // starting temporary chat is a New-Task-only entry
            ),
            placeholder = placeholder,
            attachDescription = attachDescription,
            voiceDescription = voiceDescription,
            sendDescription = sendLabel,
            onAttach = { holder.requestAttach() },
            onVoice = {
                // Honest affordance only: no Android speech product exists in
                // the current host projection (availability gates the tap).
            },
            onSend = onSend,
            isRunning = state.isRunning,
            onStop = onStop,
            maxLines = inlineMaxLines,
            layout = paneGeometry?.toComposerLayout() ?: FloeComposerLayout.Default,
            onInlineFieldWidthChanged = if (paneGeometry != null) {
                { width: Dp -> measuredFieldWidth = width }
            } else {
                null
            },
            chips = { ConversationContextChips(holder, state, offerFullEditor) },
        )
    }
}

/**
 * Drafts above this size are guaranteed to exceed the eight-line inline cap
 * in any realistic pane. Skipping the text layout keeps a paste of a very
 * large document from re-measuring it on every keystroke; the entry is still
 * offered (the honest answer for such a draft is "yes, it overflows").
 */
private const val MAX_MEASURED_DRAFT_CHARS = 4_000

/**
 * Actual Compose text layout for the inline overflow rule.
 *
 * [fieldWidth] is the slot width measured by [com.floe.android.design.FloeComposer]
 * (or its first-frame estimate), and [pageHeight] gives the same one-third
 * height cap the field itself applies. Running the real `TextMeasurer` with
 * the composer typography and the host-reported [fontScale] means wrapping,
 * CJK metrics, dynamic type and the bounded field height all affect the
 * expand decision instead of a hard-coded characters-per-line count. The
 * measured slot is the field's full budget; any CupertinoTextField internal
 * text inset can only make the real content width slightly smaller, so the
 * trigger can be a few pixels late but never early.
 */
@Composable
private fun rememberInlineFieldOverflowing(
    text: String,
    maxLines: Int,
    fieldWidth: Dp,
    pageHeight: Dp,
    style: TextStyle,
    fontScale: Float,
): Boolean {
    val measurer = rememberTextMeasurer(cacheSize = 4)
    val density = LocalDensity.current
    val fieldWidthPx = with(density) { fieldWidth.roundToPx() }.coerceAtLeast(0)
    val fieldHeightPx = with(density) { FloeComposerGeometry.fieldHeightCapFor(pageHeight).roundToPx() }
    val measurementDensity = Density(density.density, fontScale)
    val measurementKey = InlineFieldMeasurementKey(
        text = text,
        maxLines = maxLines,
        fieldWidthPx = fieldWidthPx,
        fieldHeightPx = fieldHeightPx,
        style = style,
        fontScale = measurementDensity.fontScale,
        density = measurementDensity.density,
    )
    return remember(measurer, measurementKey) {
        when {
            text.isEmpty() || fieldWidthPx == 0 -> false
            text.length > MAX_MEASURED_DRAFT_CHARS -> true
            else -> measurer.measure(
                text = AnnotatedString(text),
                style = style,
                overflow = TextOverflow.Clip,
                softWrap = true,
                maxLines = maxLines,
                constraints = Constraints(
                    maxWidth = fieldWidthPx,
                    maxHeight = fieldHeightPx,
                ),
                density = measurementDensity,
            ).hasVisualOverflow
        }
    }
}

/** Equality key for the measured text layout (Compose `remember` takes max 3 keys). */
private data class InlineFieldMeasurementKey(
    val text: String,
    val maxLines: Int,
    val fieldWidthPx: Int,
    val fieldHeightPx: Int,
    val style: TextStyle,
    val fontScale: Float,
    val density: Float,
)

@Composable
private fun sendActionLabel(state: ThreadUiState, holder: ConversationFlowHolder): String = when {
    state.isRunning && holder.runningInputMode == RunningInputModeUi.QUEUE -> stringResource(R.string.send_queue)
    state.isRunning && holder.runningInputMode == RunningInputModeUi.STEER -> stringResource(R.string.send_steer)
    else -> stringResource(R.string.thread_send)
}

/* ------------------------------- context chips ------------------------------- */

@Composable
private fun RowScope.ConversationContextChips(
    holder: ConversationFlowHolder,
    state: ThreadUiState,
    offerFullEditor: Boolean,
) {
    // ⇄ composer.expand entry: appears only while the draft no longer fits
    // the inline field's line cap (the iOS isInlineFieldOverflowing rule).
    // With measured pane geometry the decision comes from the REAL field
    // width reported by the composer plus actual Compose text layout at the
    // composer typography; the G01 fallback keeps the old approximation.
    // Opening it binds the SAME draft state — no second editor store, no
    // second submit pipeline.
    if (offerFullEditor) {
        val expandDescription = stringResource(R.string.composer_expand)
        FloeComposerChip(
            icon = ExpandEditorGlyph,
            text = expandDescription,
            onClick = holder::openFullEditor,
            description = expandDescription,
        )
    }

    // Model chip (⇄ modelPicker): grouped by cloud provider; selection is a
    // host-persisted effect (a failed durable default lands a banner, never a
    // silent revert). Local models have no Android rows at all.
    var modelMenuExpanded by remember(state.session) { mutableStateOf(false) }
    val selectedName = state.models.firstOrNull { it.modelId == holder.selectedModelId.value }?.displayName
    Box {
        this@ConversationContextChips.FloeComposerChip(
            icon = FloeIcons.Chip,
            text = selectedName ?: stringResource(R.string.composer_no_model),
            onClick = { if (state.models.any { it.isUsable }) modelMenuExpanded = true },
            tone = if (selectedName == null) FloeChipTone.PENDING else FloeChipTone.SECONDARY,
            description = stringResource(R.string.composer_model),
        )
        FloeChipMenu(expanded = modelMenuExpanded, onDismiss = { modelMenuExpanded = false }) {
            state.models.groupBy { it.providerName }.toSortedMap().forEach { (provider, models) ->
                models.filter { it.isUsable }.forEach { model ->
                    CupertinoMenuEntry(
                        title = "$provider · ${model.displayName}",
                        selected = model.modelId == holder.selectedModelId.value,
                        onClick = {
                            modelMenuExpanded = false
                            holder.selectModel(model.modelId)
                        },
                    )
                }
            }
        }
    }

    // Mode chip (hidden while temporary — ephemeral runs are ordinary agent
    // turns under the host's read-only ceiling, never plan/goal/chat-only).
    if (!state.isTemporary) {
        var modeMenuExpanded by remember(state.session) { mutableStateOf(false) }
        Box {
            this@ConversationContextChips.FloeComposerChip(
                icon = modeIcon(holder.agentMode),
                text = stringResource(modeTitleKey(holder.agentMode)),
                onClick = { modeMenuExpanded = true },
                tone = if (holder.agentMode == AgentExecutionModeUi.PLAN || holder.agentMode == AgentExecutionModeUi.GOAL) {
                    FloeChipTone.ACCENT
                } else {
                    FloeChipTone.SECONDARY
                },
                description = stringResource(R.string.composer_mode),
            )
            FloeChipMenu(expanded = modeMenuExpanded, onDismiss = { modeMenuExpanded = false }) {
                AgentExecutionModeUi.entries.forEach { mode ->
                    CupertinoMenuEntry(
                        title = stringResource(modeTitleKey(mode)),
                        selected = mode == holder.agentMode,
                        onClick = {
                            modeMenuExpanded = false
                            holder.selectAgentMode(mode)
                        },
                    )
                }
            }
        }

        // Workspace + target chips report (never change) the locked scope.
        val projectName = state.projects.firstOrNull { it.id == holder.selectedProjectId.value }?.name
            ?: stringResource(R.string.composer_project_none)
        FloeComposerChip(
            icon = FloeIcons.Folder,
            text = projectName,
            onClick = { /* ⇄ projectSelectionLocked: thread scope is immutable */ },
            description = stringResource(R.string.composer_project),
        )
        FloeComposerChip(
            icon = FloeIcons.DeviceLocal,
            text = stringResource(R.string.composer_target_local),
            onClick = { },
            description = stringResource(R.string.composer_target),
        )
    }

    // Queue/Steer chip while running (⇄ runningInputMode menu).
    if (state.isRunning) {
        var sendMenuExpanded by remember(state.session) { mutableStateOf(false) }
        Box {
            this@ConversationContextChips.FloeComposerChip(
                icon = if (holder.runningInputMode == RunningInputModeUi.QUEUE) FloeIcons.PlusCircle else FloeIcons.ChevronForward,
                text = stringResource(
                    if (holder.runningInputMode == RunningInputModeUi.QUEUE) R.string.send_queue else R.string.send_steer
                ),
                onClick = { sendMenuExpanded = true },
                description = stringResource(R.string.send_method_while_running),
            )
            FloeChipMenu(expanded = sendMenuExpanded, onDismiss = { sendMenuExpanded = false }) {
                CupertinoMenuEntry(
                    title = stringResource(R.string.send_queue_hint),
                    selected = holder.runningInputMode == RunningInputModeUi.QUEUE,
                    onClick = {
                        sendMenuExpanded = false
                        holder.setRunningInputMode(RunningInputModeUi.QUEUE)
                    },
                )
                CupertinoMenuEntry(
                    title = stringResource(R.string.send_steer_hint),
                    selected = holder.runningInputMode == RunningInputModeUi.STEER,
                    onClick = {
                        sendMenuExpanded = false
                        holder.setRunningInputMode(RunningInputModeUi.STEER)
                    },
                )
            }
        }
    }

    // Permissions/approval-mode chip (hidden while temporary: an ephemeral
    // chat binds no permission surface and must not show one it never made).
    if (!state.isTemporary) {
        FloeComposerChip(
            icon = FloeIcons.ShieldCheck,
            text = stringResource(approvalModeTitleKey(state.approvalMode)),
            onClick = { holder.openPermissions() },
            description = stringResource(R.string.composer_permissions),
        )
    }

    // Usable-capability chips (chat-surface presentation of
    // enabled+configured+usable truth only; admin pages are later scope).
    state.capabilityChips.forEach { chip ->
        FloeComposerChip(
            icon = FloeIcons.Puzzle,
            text = chip.label,
            onClick = { }, // informational host projection; no effect from here
            tone = when (chip.availability) {
                com.floe.android.contracts.Availability.AVAILABLE -> FloeChipTone.SECONDARY
                com.floe.android.contracts.Availability.NEEDS_CONFIGURATION,
                com.floe.android.contracts.Availability.NEEDS_PERMISSION -> FloeChipTone.PENDING
                else -> FloeChipTone.SECONDARY
            },
            description = chip.label,
        )
    }
}

private fun modeIcon(mode: AgentExecutionModeUi): ImageVector = when (mode) {
    AgentExecutionModeUi.AGENT -> FloeIcons.Wand
    AgentExecutionModeUi.CHAT -> FloeIcons.Bubble
    AgentExecutionModeUi.PLAN -> FloeIcons.PlanList
    AgentExecutionModeUi.GOAL -> FloeIcons.Target
}

private fun modeTitleKey(mode: AgentExecutionModeUi): Int = when (mode) {
    AgentExecutionModeUi.AGENT -> R.string.composer_mode_agent
    AgentExecutionModeUi.CHAT -> R.string.composer_mode_chat
    AgentExecutionModeUi.PLAN -> R.string.composer_mode_plan
    AgentExecutionModeUi.GOAL -> R.string.composer_mode_goal
}

/** Maps the pure queue-status vocabulary to module resources (the logic
 * object returns stable keys, not Android ids). */
private fun queueStatusTitleRes(status: PendingInputStatusUi): Int = when (status) {
    PendingInputStatusUi.QUEUED -> R.string.queue_status_waits_for_run
    PendingInputStatusUi.PROMOTING -> R.string.queue_status_converting
    PendingInputStatusUi.STEER_PENDING -> R.string.queue_status_waiting_insert
    PendingInputStatusUi.CONSUMED -> R.string.queue_status_sent
    PendingInputStatusUi.CANCELLED -> R.string.queue_status_cancelled
}

private fun approvalModeTitleKey(mode: ApprovalModeUi): Int = when (mode) {
    ApprovalModeUi.ASK -> R.string.permissions_ask
    ApprovalModeUi.AUTOMATIC -> R.string.permissions_auto_approve
    ApprovalModeUi.FULL_ACCESS -> R.string.permissions_full_access
}

/* ------------------------------ attachment tray ------------------------------ */

/** ⇄ attachmentChips row with the REAL lifecycle (progress/cancel/retry/
 * remove, actual name/MIME/size/digest projection). */
@Composable
private fun StagedAttachmentTray(holder: ConversationFlowHolder) {
    val staged = holder.stagedAttachments.value
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 12.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        staged.forEach { attachment ->
            StagedAttachmentChip(
                attachment = attachment,
                onRemove = { holder.removeStagedAttachment(attachment.id) },
                onRetry = { holder.retryAttachment(attachment.id) },
                onCancel = { holder.cancelAttachment(attachment.id) },
            )
        }
    }
}

/**
 * Home DRAFT attachment tray: the SAME real lifecycle chip presentation as
 * the thread composer (progress/cancel/retry/remove, actual name/MIME/size
 * projection), driven by the draft-owner's rows (RootWorkspaceController)
 * through explicit callbacks. It never renders a row the staging service
 * did not actually produce, and an empty list renders nothing (no phantom
 * header on Home).
 */
@Composable
fun FloeDraftAttachmentTray(
    rows: List<StagedAttachmentUi>,
    onRemove: (String) -> Unit,
    onRetry: (String) -> Unit,
    onCancel: (String) -> Unit,
) {
    if (rows.isEmpty()) return
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 12.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        rows.forEach { attachment ->
            StagedAttachmentChip(
                attachment = attachment,
                onRemove = { onRemove(attachment.id) },
                onRetry = { onRetry(attachment.id) },
                onCancel = { onCancel(attachment.id) },
            )
        }
    }
}

@Composable
private fun StagedAttachmentChip(
    attachment: StagedAttachmentUi,
    onRemove: () -> Unit,
    onRetry: () -> Unit,
    onCancel: () -> Unit,
) {
    val colors = Floe.colors
    val removeDescription = stringResource(R.string.attachment_remove, attachment.displayName)
    val retryLabel = stringResource(R.string.action_retry)
    val cancelLabel = stringResource(R.string.action_cancel)
    val shape = RoundedCornerShape(percent = 50)
    Row(
        modifier = Modifier
            .heightIn(min = FloeLayout.MinimumTarget)
            .clip(shape)
            .background(colors.groupedSurface)
            .padding(start = 10.dp, end = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        IconGlyph(
            when (attachment.kind) {
                AttachmentKindUi.IMAGE -> FloeIcons.Photo
                AttachmentKindUi.DOCUMENT -> FloeIcons.Paperclip
                AttachmentKindUi.AUDIO -> FloeIcons.Mic
                AttachmentKindUi.OTHER -> FloeIcons.Paperclip
            },
            colors.accent,
            15.dp,
        )
        Column {
            FloeText(
                attachment.displayName,
                style = Floe.typography.metadata,
                color = colors.label,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.widthIn(max = 200.dp),
            )
            when (val lifecycle = attachment.import) {
                AttachmentImportUi.Ready -> FloeText(
                    // Size + MIME are the recorded facts, not a claim.
                    "${TokenUnitFormatter.format(attachment.byteCount.toInt())} · ${attachment.mimeType}",
                    style = Floe.typography.evidence,
                    color = colors.secondaryLabel,
                )
                is AttachmentImportUi.InProgress -> Row(
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    FloeActivityIndicator(modifier = Modifier.size(14.dp))
                    FloeText(
                        lifecycle.fraction?.let { stringResource(R.string.attachment_progress, (it * 100).toInt()) }
                            ?: stringResource(R.string.attachment_importing),
                        style = Floe.typography.evidence,
                        color = colors.secondaryLabel,
                    )
                    Box(
                        modifier = Modifier
                            .heightIn(min = FloeLayout.MinimumTarget)
                            .clickable(onClick = onCancel)
                            .semantics { contentDescription = cancelLabel },
                        contentAlignment = Alignment.Center,
                    ) { FloeText(cancelLabel, style = Floe.typography.metadata, color = colors.secondaryLabel) }
                }
                is AttachmentImportUi.Failed -> Row(
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    FloeText(lifecycle.message, style = Floe.typography.evidence, color = colors.destructive)
                    Box(
                        modifier = Modifier
                            .heightIn(min = FloeLayout.MinimumTarget)
                            .clickable(onClick = onRetry)
                            .semantics { contentDescription = retryLabel },
                        contentAlignment = Alignment.Center,
                    ) { FloeText(retryLabel, style = Floe.typography.metadata, color = colors.accent) }
                }
            }
        }
        Box(
            modifier = Modifier
                .size(FloeLayout.MinimumTarget)
                .clickable(onClick = onRemove)
                .semantics { contentDescription = removeDescription },
            contentAlignment = Alignment.Center,
        ) {
            IconGlyph(FloeIcons.Xmark, colors.secondaryLabel, 15.dp)
        }
    }
}

/* ----------------------------- pending input queue ---------------------------- */

/** ⇄ PendingInputQueueView: queued rows with the per-row edit/move/steer/
 * delete menu; steering is offered only while a run is live and bounds are
 * enforced in the holder logic (out-of-range moves dispatch nothing). */
@Composable
private fun PendingInputQueueSection(holder: ConversationFlowHolder) {
    val state = holder.snapshot.value ?: return
    val queueLabel = stringResource(R.string.queue_title)
    val menuCd = stringResource(R.string.queue_action_cd)
    val editLabel = stringResource(R.string.action_edit)
    val moveUpLabel = stringResource(R.string.queue_move_up)
    val moveDownLabel = stringResource(R.string.queue_move_down)
    val steerLabel = stringResource(R.string.queue_convert_to_steer)
    val deleteLabel = stringResource(R.string.action_delete)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp)
            .padding(top = 8.dp)
            .semantics { contentDescription = queueLabel },
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            IconGlyph(FloeIcons.PlusCircle, Floe.colors.label, 15.dp)
            FloeText(queueLabel, style = Floe.typography.bodyEmphasized, color = Floe.colors.label)
            Spacer(Modifier.weight(1f))
            FloeText("${state.pendingInputs.size}", style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
        }
        val queuedIds = state.pendingInputs.filter { it.status == PendingInputStatusUi.QUEUED }.map { it.id }
        state.pendingInputs.forEach { input ->
            var menuExpanded by remember(input.id) { mutableStateOf(false) }
            val index = queuedIds.indexOf(input.id)
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = FloeLayout.MinimumTarget)
                    .clip(RoundedCornerShape(FloeLayout.BubbleCorner))
                    .background(Floe.colors.groupedSurface)
                    .padding(horizontal = 10.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    FloeText(
                        PendingInputQueueLogic.displayText(input),
                        style = Floe.typography.body,
                        color = Floe.colors.label,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    val statusText = if (input.isBrowserHandoff && input.status == PendingInputStatusUi.QUEUED) {
                        stringResource(R.string.queue_browser_handoff_note)
                    } else {
                        stringResource(queueStatusTitleRes(input.status))
                    }
                    FloeText(
                        statusText,
                        style = Floe.typography.metadata,
                        color = if (input.status == PendingInputStatusUi.QUEUED) Floe.colors.secondaryLabel else Floe.colors.pending,
                    )
                }
                when {
                    input.isBrowserHandoff -> IconGlyph(FloeIcons.Chip, Floe.colors.secondaryLabel, 15.dp)
                    input.status == PendingInputStatusUi.QUEUED || input.status == PendingInputStatusUi.STEER_PENDING -> Box {
                        Box(
                            modifier = Modifier
                                .size(FloeLayout.MinimumTarget)
                                .clickable(enabled = input.status == PendingInputStatusUi.QUEUED) { menuExpanded = true }
                                .semantics { contentDescription = menuCd },
                            contentAlignment = Alignment.Center,
                        ) { IconGlyph(FloeIcons.ChevronUpDown, Floe.colors.secondaryLabel, 16.dp) }
                        FloeChipMenu(expanded = menuExpanded, onDismiss = { menuExpanded = false }) {
                            CupertinoMenuEntry(
                                title = editLabel,
                                selected = false,
                                onClick = { menuExpanded = false; holder.openPendingInputEditor(input.id) },
                            )
                            if (index > 0) {
                                CupertinoMenuEntry(
                                    title = moveUpLabel,
                                    selected = false,
                                    onClick = { menuExpanded = false; holder.movePendingInput(input.id, -1) },
                                )
                            }
                            if (index >= 0 && index < queuedIds.lastIndex) {
                                CupertinoMenuEntry(
                                    title = moveDownLabel,
                                    selected = false,
                                    onClick = { menuExpanded = false; holder.movePendingInput(input.id, 1) },
                                )
                            }
                            if (PendingInputQueueLogic.canPromoteToSteer(state.isRunning, input.status)) {
                                CupertinoMenuEntry(
                                    title = steerLabel,
                                    selected = false,
                                    onClick = { menuExpanded = false; holder.promotePendingInput(input.id) },
                                )
                            }
                            CupertinoMenuEntry(
                                title = deleteLabel,
                                selected = false,
                                onClick = { menuExpanded = false; holder.removePendingInput(input.id) },
                            )
                        }
                    }
                    else -> FloeActivityIndicator()
                }
            }
        }
    }
}

/* --------------------------------- banners ---------------------------------- */

@Composable
internal fun InlineBanner(
    icon: ImageVector,
    text: String,
    tint: Color,
    onDismiss: (() -> Unit)? = null,
    action: (@Composable () -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .background(tint.copy(alpha = 0.08f))
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        IconGlyph(icon, tint, 16.dp)
        FloeText(text, style = Floe.typography.metadata, color = tint)
        Spacer(Modifier.weight(1f))
        action?.invoke()
        if (onDismiss != null) {
            val dismissCd = stringResource(R.string.dismiss_error)
            Box(
                modifier = Modifier
                    .size(FloeLayout.MinimumTarget)
                    .clickable(onClick = onDismiss)
                    .semantics { contentDescription = dismissCd },
                contentAlignment = Alignment.Center,
            ) { IconGlyph(FloeIcons.Xmark, tint, 15.dp) }
        }
    }
}

/** ⇄ addProviderBar: honest actionable hint; the button routes through the
 * host-owned setup presentation, never a fake message list. */
@Composable
private fun AddProviderBar() {
    val openLabel = stringResource(R.string.setup_open)
    val hint = stringResource(R.string.add_provider_hint)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(Floe.colors.pending.copy(alpha = 0.08f))
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        IconGlyph(FloeIcons.Antenna, Floe.colors.pending, 16.dp)
        FloeText(hint, style = Floe.typography.metadata, color = Floe.colors.label)
        Spacer(Modifier.weight(1f))
        val shape = RoundedCornerShape(9.dp)
        Box(
            modifier = Modifier
                .heightIn(min = FloeLayout.MinimumTarget)
                .clip(shape)
                .border(0.5.dp, Floe.colors.chromeHairline, shape)
                .clickable { /* the host settings presentation owns the route */ }
                .padding(horizontal = 12.dp, vertical = 6.dp),
            contentAlignment = Alignment.Center,
        ) { FloeText(openLabel, style = Floe.typography.metadata, color = Floe.colors.accent) }
    }
}
