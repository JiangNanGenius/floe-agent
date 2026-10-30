// SPDX-License-Identifier: MPL-2.0
//
// Timeline row renderers for the unified thread (⇄ ThreadDetailView.timelineRow
// + MessageBubble + ThreadEventView + StepGroupView + ToolCallCardView +
// ErrorEventView + TerminalEventRow + MissingFinalMessageRow +
// ModelResponseWaitingView). Feature-specific components built from the
// frozen Floe design-system primitives and semantic tokens only — the module
// adds no new visual language, no Material defaults and no alternate palette.
// Geometry mirrors the iPad source: user bubble r12 accent@14 h12/v8, tool
// card hairline sectioned surface, terminal quiet line. Parity of
// translucency/blur/layering and icon geometry stays an explicit OPEN G14
// item; the LAYOUT/composition here follows the current source now.

package com.floe.android.feature.conversation

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloeText
import com.floe.android.design.IconGlyph
import androidx.compose.ui.graphics.vector.ImageVector
import kotlinx.coroutines.delay

/* ------------------------------ presentation glue ----------------------------- */

@Composable
internal fun floeStatusColor(role: FloeStateColorRole): Color = when (role) {
    FloeStateColorRole.ACCENT -> Floe.colors.accent
    FloeStateColorRole.PENDING -> Floe.colors.pending
    FloeStateColorRole.DESTRUCTIVE -> Floe.colors.destructive
    FloeStateColorRole.SUCCESS -> Floe.colors.success
    FloeStateColorRole.UNKNOWN -> Floe.colors.secondaryLabel
}

internal fun floeToolIcon(iconKey: String): ImageVector = when (iconKey) {
    "icon_check_circle" -> FloeIcons.CheckCircle
    "icon_error" -> FloeIcons.XOctagon
    "icon_denied" -> FloeIcons.ShieldAlert
    "icon_expired" -> FloeIcons.Clock
    "icon_cancelled" -> FloeIcons.StopSquare
    "icon_running" -> FloeIcons.Refresh
    "icon_pending" -> FloeIcons.Clock
    else -> FloeIcons.Terminal
}

/** ⇄ RunStateLocalizer.title: keys map to module string resources. */
@Composable
fun runStateTitle(stateName: String): String {
    val key = FloeRunStateLocalizer.titleKey(stateName)
    return stringResource(localizedStateKey(key))
}

private fun localizedStateKey(key: String): Int = when (key) {
    "state_preparing" -> R.string.state_preparing
    "state_streaming" -> R.string.state_streaming
    "state_reconnecting" -> R.string.state_reconnecting
    "state_committing_results" -> R.string.state_committing_results
    "state_reviewing_approval" -> R.string.state_reviewing_approval
    "state_verifying" -> R.string.state_verifying
    "state_executing_tool" -> R.string.state_executing_tool
    "state_waiting_approval" -> R.string.state_waiting_approval
    "state_compacting" -> R.string.state_compacting
    "state_paused" -> R.string.state_paused
    "state_blocked" -> R.string.state_blocked
    "state_budget_limited" -> R.string.state_budget_limited
    "state_truncated" -> R.string.state_truncated
    "state_waiting_user" -> R.string.state_waiting_user
    "state_stopped" -> R.string.state_stopped
    "state_cancelling" -> R.string.state_cancelling
    "state_round_ended" -> R.string.state_round_ended
    "state_recovery_failed" -> R.string.state_recovery_failed
    "state_failed" -> R.string.state_failed
    else -> R.string.state_unknown
}

private fun toolStatusTitleKey(key: String): Int = when (key) {
    "tool_status_succeeded" -> R.string.tool_status_succeeded
    "tool_status_failed" -> R.string.tool_status_failed
    "tool_status_running" -> R.string.tool_status_running
    "tool_status_pending" -> R.string.tool_status_pending
    "tool_status_needs_user" -> R.string.tool_status_needs_user
    "tool_status_denied" -> R.string.tool_status_denied
    "tool_status_expired" -> R.string.tool_status_expired
    "tool_status_cancelled" -> R.string.tool_status_cancelled
    else -> R.string.tool_status_unknown
}

/* ------------------------------- row dispatcher ------------------------------- */

/**
 * Renders one timeline row. [onOpenAttachment] and the holder-scoped actions
 * follow ⇄ ThreadDetailView.timelineRow exactly: messages use the shared chip
 * surface, events resolve through ThreadEventView-equivalents, approvals are
 * live decision cards, and live slots render the streaming tail.
 */
@Composable
fun ConversationTimelineRow(
    row: TimelineRowUi,
    holder: ConversationFlowHolder,
    modifier: Modifier = Modifier,
    searchHighlightQuery: String? = null,
) {
    when (row) {
        is TimelineRowUi.EarlierEvents -> EarlierEventsRow(row, holder, modifier)
        is TimelineRowUi.UserMessage ->
            UserMessageRow(row.message, holder, modifier, searchHighlightQuery)
        is TimelineRowUi.AssistantMessage ->
            AssistantRow(row, holder, modifier, searchHighlightQuery)
        is TimelineRowUi.Event -> EventRow(row.event, holder, modifier)
        is TimelineRowUi.StepGroup -> StepGroupRow(row, holder, modifier)
        is TimelineRowUi.RunOutputGroup -> RunOutputGroupRow(row, holder, modifier)
        is TimelineRowUi.Terminal -> TerminalRow(row.event, modifier)
        is TimelineRowUi.MissingFinal -> MissingFinalRow(modifier)
        TimelineRowUi.LiveReasoning -> {
            val state = holder.snapshot.value ?: return
            val streamingLabel = stringResource(R.string.state_streaming)
            ConversationReasoningBlock(
                text = state.liveReasoningText,
                isStreaming = true,
                expanded = holder.liveReasoningExpanded,
                onToggle = holder::toggleLiveReasoning,
                onCopyText = { holder.copyMessage(state.liveReasoningText) },
                modifier = modifier,
                label = streamingLabel,
            )
        }
        TimelineRowUi.LiveAssistantTail -> {
            val state = holder.snapshot.value ?: return
            // ⇄ AssistantMessageView(isStreaming: true) + MarkdownRendererView
            // streaming contract: only the unfinished tail fragment re-parses
            // (async, off the UI thread, generation-fenced); the completed
            // block sequence stays stably mounted per token tick.
            FloeMarkdownMessage(
                source = state.liveAssistantText,
                holder = holder,
                onLinkOpen = { url -> holder.openMessageLink(url) },
                onCopyText = { text -> holder.copyMessage(text) },
                modifier = modifier,
                isStreaming = true,
            )
        }
        TimelineRowUi.LiveThinking -> LiveThinkingRow(holder, modifier)
        is TimelineRowUi.Approval -> ConversationApprovalRow(card = row.card, holder = holder, modifier = modifier)
    }
}

/* --------------------------------- user rows ---------------------------------- */

/** ⇄ MessageBubble(user) + UserMessageBubble: right-aligned bubble, verbatim
 * text (user input is NOT markdown-rendered), credential cards, chips. */
@Composable
private fun UserMessageRow(
    message: MessageUi,
    holder: ConversationFlowHolder,
    modifier: Modifier,
    searchHighlightQuery: String? = null,
) {
    val colors = Floe.colors
    val userRole = stringResource(R.string.role_user)
    Row(modifier = modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
        Spacer(Modifier.width(40.dp))
        Column(
            modifier = Modifier.weight(1f),
            horizontalAlignment = Alignment.End,
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            if (message.text.isNotEmpty()) {
                Column(
                    modifier = Modifier
                        .clip(RoundedCornerShape(FloeLayout.BubbleCorner))
                        .background(colors.accentFillBubble)
                        .padding(horizontal = 12.dp, vertical = 8.dp)
                        .semantics { contentDescription = userRole },
                    horizontalAlignment = Alignment.End,
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    // ⇄ CredentialMessagePart.parse: credential placeholders
                    // render as secure-cards, never as raw token text.
                    CredentialAwareUserText(message.text, searchHighlightQuery)
                }
            }
            AttachmentChipRow(
                chips = message.attachmentChips,
                alignEnd = true,
                onOpen = { chip ->
                    chip.attachmentId?.let {
                        holder.openMessageAttachment(
                            AttachmentOpenRequest(holder.conversationId, message.id, it)
                        )
                    }
                },
            )
        }
    }
}

/** ⇄ CredentialMessagePart: splits ⟨credential:UUID⟩ markers for card rendering. */
data class CredentialTextSegment(val isCredential: Boolean, val value: String)

object CredentialTextParser {
    private const val OPEN = "\u27e8credential:"
    private const val CLOSE = "\u27e9"

    /** Same token grammar as iOS: ⟨credential:36-hex-dash⟩. Unknown shapes
     * stay plain text (a user can legitimately type the marker characters). */
    fun parse(text: String): List<CredentialTextSegment> {
        val out = mutableListOf<CredentialTextSegment>()
        var cursor = 0
        while (true) {
            val start = text.indexOf(OPEN, cursor)
            if (start < 0) break
            val end = text.indexOf(CLOSE, start + OPEN.length)
            if (end < 0) break
            val token = text.substring(start + OPEN.length, end)
            if (!isCredentialToken(token)) break
            if (start > cursor) out += CredentialTextSegment(false, text.substring(cursor, start))
            out += CredentialTextSegment(true, text.substring(start, end + CLOSE.length))
            cursor = end + CLOSE.length
        }
        if (cursor < text.length) out += CredentialTextSegment(false, text.substring(cursor))
        return out.ifEmpty { listOf(CredentialTextSegment(false, text)) }
    }

    private fun isCredentialToken(raw: String): Boolean =
        raw.length == 36 && raw.all { it.isDigit() || it in 'a'..'f' || it in 'A'..'F' || it == '-' }
}

@Composable
private fun CredentialAwareUserText(
    text: String,
    searchHighlightQuery: String? = null,
) {
    val colors = Floe.colors
    val credentialCardCd = stringResource(R.string.secure_credentials_card)
    CredentialTextParser.parse(text).forEach { segment ->
        if (segment.isCredential) {
            Row(
                modifier = Modifier
                    .clip(RoundedCornerShape(10.dp))
                    .background(colors.groupedSurface)
                    .padding(10.dp)
                    .semantics { contentDescription = credentialCardCd },
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconGlyph(FloeIcons.Key, colors.accent, 18.dp)
                Column {
                    FloeText(stringResource(R.string.secure_credentials), style = Floe.typography.bodyEmphasized)
                    FloeText(
                        stringResource(R.string.secure_credentials_hint),
                        style = Floe.typography.metadata,
                        color = colors.secondaryLabel,
                    )
                }
            }
        } else {
            // ⇄ UserMessageBubble.swift:106-139 — the Text has NO fillMaxWidth:
            // a short message sizes the blue bubble to its content (trailing),
            // long text wraps only against the row's available width (the 40dp
            // leading gutter of the enclosing row is the native
            // Spacer(minLength: 40)). Credential-card rendering unchanged.
            androidx.compose.material3.Text(
                text = highlightedVisibleText(segment.value, searchHighlightQuery),
                style = Floe.typography.body.copy(color = colors.label),
            )
        }
    }
}

/** Highlight the exact visible segment string. Offsets come from the same
 * folded matcher used for the native hit, so the highlighted characters are
 * the ones the user actually reads (not raw Markdown syntax). */
@Composable
private fun highlightedVisibleText(
    text: String,
    querySource: String?,
): androidx.compose.ui.text.AnnotatedString {
    val builder = androidx.compose.ui.text.AnnotatedString.Builder()
    builder.append(text)
    val query = querySource?.takeIf { it.isNotBlank() }?.let(::ThreadSearchQuery)
        ?: return builder.toAnnotatedString()
    val length = text.length
    for (range in ThreadSearchMatcher.ranges(text, query)) {
        val start = range.first.coerceIn(0, length)
        val end = (range.last + 1).coerceIn(start, length)
        if (end > start) {
            builder.addStyle(
                androidx.compose.ui.text.SpanStyle(
                    background = Floe.colors.pending.copy(alpha = 0.35f),
                ),
                start,
                end,
            )
        }
    }
    return builder.toAnnotatedString()
}

/** ⇄ AttachmentChipRow: ONE reusable attachment surface (user trailing,
 * assistant leading); images keep the image glyph. */
@Composable
internal fun AttachmentChipRow(
    chips: List<AttachmentChipUi>,
    alignEnd: Boolean,
    onOpen: ((AttachmentChipUi) -> Unit)?,
    modifier: Modifier = Modifier,
) {
    if (chips.isEmpty()) return
    Column(
        modifier = modifier,
        horizontalAlignment = if (alignEnd) Alignment.End else Alignment.Start,
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        chips.forEach { chip ->
            val description = stringResource(R.string.attachment_open_named, chip.name)
            Box(
                modifier = Modifier
                    .heightIn(min = FloeLayout.MinimumTarget)
                    .clip(RoundedCornerShape(percent = 50))
                    .background(Floe.colors.accent.copy(alpha = 0.10f))
                    .then(if (onOpen != null) Modifier.clickable { onOpen(chip) } else Modifier)
                    .semantics { contentDescription = description }
                    .padding(horizontal = 12.dp, vertical = 8.dp),
            ) {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    IconGlyph(
                        if (chip.isImage) FloeIcons.Photo else FloeIcons.Paperclip,
                        Floe.colors.secondaryLabel,
                        14.dp,
                    )
                    FloeText(
                        chip.name,
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.width(maxOf(0.dp, 220.dp)),
                    )
                }
            }
        }
    }
}

/* ------------------------------ assistant rows ------------------------------ */

/** ⇄ AssistantMessageView: MARKDOWN reading column (the host-projected rich
 * block tree; never a plain-text stand-in claim) + copy/read-aloud actions
 * when settled; attachment chips lead the same shared surface as user rows.
 * Localized descriptions are hoisted in composable scope before any
 * semantics lambda (no stringResource inside non-composable blocks). */
@Composable
private fun AssistantRow(
    row: TimelineRowUi.AssistantMessage,
    holder: ConversationFlowHolder,
    modifier: Modifier,
    searchHighlightQuery: String? = null,
) {
    val copyLabel = stringResource(R.string.action_copy)
    val readAloudLabel = stringResource(R.string.action_read_aloud)
    val saveToNotesLabel = stringResource(R.string.action_save_to_notes)
    val saveToNotesFailed = stringResource(R.string.action_save_to_notes_failed)
    val assistantRole = stringResource(R.string.role_assistant)
    // The host state is the authority: a temporary session never offers a
    // persistent copy, and an unknown projection keeps the affordance hidden
    // until the real state arrives. The host re-checks the same facts.
    val persistentSession = holder.snapshot.value?.isTemporary == false
    var saveNotice by remember(row.rowId) { mutableStateOf<String?>(null) }
    Column(
        modifier = modifier
            .fillMaxWidth()
            .semantics { contentDescription = assistantRole },
    ) {
        FloeMarkdownMessage(
            source = row.text,
            holder = holder,
            onLinkOpen = { url -> holder.openMessageLink(url) },
            onCopyText = { text -> holder.copyMessage(text) },
            isStreaming = false,
            highlightQuery = searchHighlightQuery,
        )
        AttachmentChipRow(
            chips = row.attachmentChips,
            alignEnd = false,
            onOpen = { chip ->
                row.attachedMessageId?.let { messageId ->
                    chip.attachmentId?.let {
                        holder.openMessageAttachment(AttachmentOpenRequest(holder.conversationId, messageId, it))
                    }
                }
            },
        )
        Row(
            modifier = Modifier.padding(horizontal = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // Copy affordance: exact verbatim text via the host clipboard
            // effect. FloeIcons has no doc.on.doc glyph (reported to the icon
            // owner); a text label carries the meaning instead of a
            // semantically wrong icon.
            Box(
                modifier = Modifier
                    .heightIn(min = FloeLayout.MinimumTarget)
                    .clickable { holder.copyMessage(row.text) }
                    .semantics { contentDescription = copyLabel },
                contentAlignment = Alignment.CenterStart,
            ) {
                FloeText(copyLabel, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
            }
            if (holder.snapshot.value?.voiceAvailable == true) {
                Box(
                    modifier = Modifier
                        .heightIn(min = FloeLayout.MinimumTarget)
                        .clickable { holder.speakMessage(row.text) }
                        .semantics { contentDescription = readAloudLabel },
                    contentAlignment = Alignment.CenterStart,
                ) {
                    FloeText(readAloudLabel, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                }
            }
            if (persistentSession && row.text.isNotBlank()) {
                // Explicit user copy into an independent note. A true holder
                // result is ADMISSION only; the real Saving/Saved/Failed state
                // is surfaced by the App from the host transfer controller, so
                // this row never claims the note was saved.
                Box(
                    modifier = Modifier
                        .heightIn(min = FloeLayout.MinimumTarget)
                        .clickable {
                            val result = holder.saveMessageToNotes(row.text)
                            if (result !is ConversationFlowResult.Accepted) {
                                saveNotice = saveToNotesFailed
                            }
                        }
                        .semantics { contentDescription = saveToNotesLabel },
                    contentAlignment = Alignment.CenterStart,
                ) {
                    FloeText(saveToNotesLabel, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                }
            }
        }
        saveNotice?.let { notice ->
            LaunchedEffect(notice) {
                delay(4_000)
                saveNotice = null
            }
            FloeText(
                notice,
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.padding(horizontal = 4.dp),
            )
        }
    }
}

/* --------------------------------- event rows -------------------------------- */

@Composable
private fun EventRow(event: RunEventUi, holder: ConversationFlowHolder, modifier: Modifier = Modifier) {
    when (event.kind) {
        RunEventKindUi.ERROR -> ErrorRow(event, holder, modifier)
        RunEventKindUi.NOTICE -> NoticeRow(event, modifier)
        RunEventKindUi.REASONING -> ConversationReasoningBlock(
            text = event.reasoningExcerpt.orEmpty(),
            isStreaming = false,
            expanded = event.id in holder.expandedToolCards.value,
            onToggle = { holder.toggleToolCard(event.id) },
            onCopyText = { holder.copyMessage(event.reasoningExcerpt.orEmpty()) },
            modifier = modifier,
        )
        RunEventKindUi.STATUS -> StatusRow(event, modifier)
        RunEventKindUi.TOOL_REQUEST, RunEventKindUi.TOOL_RESULT -> ToolRow(event, holder, modifier)
        RunEventKindUi.APPROVAL, RunEventKindUi.AUTO_APPROVED -> Unit // folded into tool cards by StepGroupPairing
        else -> Unit // assistantText/terminal/file/usage/checkpoint handled by their rows
    }
}

/** ⇄ ErrorEventView: terminal presentation, destructive, honest message. */
@Composable
private fun ErrorRow(event: RunEventUi, holder: ConversationFlowHolder, modifier: Modifier) {
    val state = holder.snapshot.value
    val retryable = state?.let { s ->
        s.selectedRunId == event.runId && (s.runs.firstOrNull { it.id == s.selectedRunId }?.stateName in setOf("failed", "interrupted"))
    } == true
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(Floe.colors.destructive.copy(alpha = 0.08f))
            .padding(10.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        IconGlyph(FloeIcons.XOctagon, Floe.colors.destructive, 18.dp)
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            FloeText(
                stringResource(R.string.error_card_title),
                style = Floe.typography.metadata,
                color = Floe.colors.destructive,
            )
            FloeText(event.message.orEmpty(), style = Floe.typography.body, color = Floe.colors.label)
            if (retryable) {
                Box(
                    modifier = Modifier
                        .heightIn(min = FloeLayout.MinimumTarget)
                        .clip(RoundedCornerShape(9.dp))
                        .border(0.5.dp, Floe.colors.destructive.copy(alpha = 0.45f), RoundedCornerShape(9.dp))
                        .clickable { holder.retry() }
                        .padding(horizontal = 14.dp, vertical = 8.dp),
                ) {
                    FloeText(stringResource(R.string.action_retry), style = Floe.typography.bodyEmphasized, color = Floe.colors.destructive)
                }
            }
        }
    }
}

/** Internal invalidation is durable metadata, not an empty user notice.
 * Keep ordinary informational notices, including ones carrying a message. */
internal fun isInternalQueueRefreshNotice(event: RunEventUi): Boolean =
    event.kind == RunEventKindUi.NOTICE && event.statusReason == "queueSettled" &&
        event.message.isNullOrBlank()

/** ⇄ notice events: non-fatal information, never failure-styled. */
@Composable
private fun NoticeRow(event: RunEventUi, modifier: Modifier) {
    if (isInternalQueueRefreshNotice(event)) return
    Row(
        modifier = modifier.fillMaxWidth().padding(vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconGlyph(FloeIcons.InfoCircle, Floe.colors.secondaryLabel, 15.dp)
        FloeText(event.message.orEmpty(), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
    }
}

/** Current-state marker: belongs to the toolbar in modern runs; a standalone
 * status row renders quietly (⇄ stale/terminal status filtering is the host
 * builder's rule — only live-status rows arrive here). */
@Composable
private fun StatusRow(event: RunEventUi, modifier: Modifier) {
    val name = event.stateName ?: return
    Row(
        modifier = modifier.fillMaxWidth().padding(vertical = 2.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        FloeText(runStateTitle(name), style = Floe.typography.metadata, color = floeStatusColor(FloeRunStateLocalizer.colorRole(name)))
    }
}

/** ⇄ ToolCallCardView via StepGroupView pairing: one disclosure owns the
 * exact input, approval outcome, recorded output and duration. A pending
 * approval is a sibling of the disclosure, never content inside its fold. */
@Composable
internal fun ToolRow(
    event: RunEventUi,
    holder: ConversationFlowHolder,
    modifier: Modifier = Modifier,
    resultStatusOverride: String? = null,
    resultSummaryOverride: String? = null,
    approvalSummary: String? = null,
    decisionSummary: String? = null,
    pendingApprovalCard: ApprovalCardUi? = null,
    childRun: ChildRunUi? = null,
    onResolveApproval: ((ApprovalCardUi, Boolean) -> Unit)? = null,
    isLive: Boolean = false,
) {
    val tool = event.tool ?: return
    val status = resultStatusOverride ?: tool.statusRaw
    val presentation = FloeToolStatusPresentation.forStatus(status)
    val summary = resultSummaryOverride ?: tool.resultSummary ?: tool.inputSummary.orEmpty()
    val expanded = holder.toolCardExpanded(event)
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        FloeToolCard(
            toolName = tool.toolName,
            statusIcon = floeToolIcon(presentation.iconKey),
            statusLabel = stringResource(toolStatusTitleKey(presentation.titleKey)),
            statusColor = floeStatusColor(presentation.colorRole),
            summary = summary,
            inputSummary = tool.inputSummary,
            approvalSummary = approvalSummary ?: tool.approvalSummary,
            decisionSummary = decisionSummary,
            durationSeconds = tool.durationSeconds,
            artifacts = tool.artifacts,
            expanded = expanded,
            onToggleExpanded = { holder.toggleToolCard(event.id) },
            modifier = Modifier,
            onOpenArtifactPreview = { artifactId -> holder.openRichArtifactPreview(artifactId) },
        ) {
            // Below-fold extras that the iOS card places inside details.
            if (childRun != null) {
                DelegateCardRow(
                    child = childRun,
                    onView = { holder.openChildRun(childRun.id) },
                )
            }
            if (isLive && status == "running") {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                    FloeActivityIndicator()
                    FloeText(stringResource(R.string.tool_status_running), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                }
            }
        }
        // The decision surface stays outside the card's fold; identity and
        // dispatch are unchanged.
        pendingApprovalCard?.let { card ->
            ConversationApprovalRow(
                card = card,
                holder = holder,
                onResolve = { c, allow -> onResolveApproval?.invoke(c, allow) ?: holder.resolveApproval(c, allow) },
            )
        }
    }
}



/* ------------------------------ delegate cards ------------------------------ */

/** ⇄ the delegate card affordance inside a tool step: "View" opens this
 * child's durable transcript; the list fallback opens the inspector. */
@Composable
private fun DelegateCardRow(child: ChildRunUi, onView: () -> Unit) {
    val colors = Floe.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = FloeLayout.MinimumTarget)
            .padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        IconGlyph(FloeIcons.Puzzle, colors.secondaryLabel, 16.dp)
        Column(modifier = Modifier.weight(1f)) {
            FloeText(child.title, style = Floe.typography.bodyEmphasized, color = colors.label, maxLines = 1, overflow = TextOverflow.Ellipsis)
            FloeText(
                child.stateTitle,
                style = Floe.typography.metadata,
                color = if (child.isTerminal) colors.secondaryLabel else colors.accent,
            )
        }
        Box(
            modifier = Modifier
                .heightIn(min = FloeLayout.MinimumTarget)
                .clickable(onClick = onView),
            contentAlignment = Alignment.Center,
        ) {
            FloeText(stringResource(R.string.action_view), style = Floe.typography.bodyEmphasized, color = colors.accent)
        }
    }
}

/* --------------------------------- live rows --------------------------------- */

/** ⇄ ModelResponseWaitingView: honest "contacting provider / thinking" state
 * driven by provider activity, never a fake partial answer. */
@Composable
private fun LiveThinkingRow(holder: ConversationFlowHolder, modifier: Modifier) {
    val hasActivity = holder.snapshot.value?.hasProviderActivity == true
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        FloeActivityIndicator()
        FloeText(
            stringResource(if (hasActivity) R.string.state_thinking else R.string.state_contacting_provider),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
    }
}

/* -------------------------------- quiet rows -------------------------------- */

@Composable
private fun EarlierEventsRow(row: TimelineRowUi.EarlierEvents, holder: ConversationFlowHolder, modifier: Modifier) {
    // ⇄ disabled(viewModel.loadingEventRunIDs.contains(runID)): the host
    // publishes per-run page latches; a second tap dispatches nothing.
    val loading = holder.snapshot.value?.loadingEventRunIds?.contains(row.runId) == true
    Box(modifier = modifier.fillMaxWidth().padding(vertical = 4.dp), contentAlignment = Alignment.Center) {
        Row(
            modifier = Modifier
                .heightIn(min = FloeLayout.MinimumTarget)
                .clip(RoundedCornerShape(FloeLayout.CircleToolbarCorner))
                .border(0.5.dp, Floe.colors.separator, RoundedCornerShape(FloeLayout.CircleToolbarCorner))
                .clickable(enabled = !loading) { holder.loadEarlierEvents(row) }
                .padding(horizontal = 14.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconGlyph(FloeIcons.Clock, Floe.colors.secondaryLabel, 15.dp)
            FloeText(
                stringResource(R.string.show_earlier_tool_activity),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
        }
    }
}

/** ⇄ TerminalEventRow: a single quiet status line, never a big card. */
@Composable
private fun TerminalRow(event: RunEventUi, modifier: Modifier) {
    val reason = event.stopReason ?: "completed"
    val isClean = reason == "completed" || reason == "endTurn"
    Row(
        modifier = modifier.fillMaxWidth().padding(vertical = 2.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconGlyph(
            if (isClean) FloeIcons.CheckCircle else FloeIcons.StopSquare,
            floeStatusColor(FloeStateColorRole.SUCCESS),
            15.dp,
        )
        FloeText(
            stringResource(terminalTitleKey(reason)),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
        Spacer(Modifier.weight(1f))
        FloeText(event.timeLabel, style = Floe.typography.metadata, color = Floe.colors.tertiaryLabel)
    }
}

private fun terminalTitleKey(reason: String): Int =
    when (FloeRunStateLocalizer.terminalTitleKey(reason)) {
        "state_round_ended" -> R.string.state_round_ended
        "state_stopped" -> R.string.state_stopped
        "state_truncated" -> R.string.state_truncated
        "state_task_unfinished" -> R.string.state_task_unfinished
        else -> R.string.state_unknown
    }

/** ⇄ MissingFinalMessageRow: a completed run without final reply is honest. */
@Composable
private fun MissingFinalRow(modifier: Modifier) {
    Row(
        modifier = modifier.fillMaxWidth().padding(vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconGlyph(FloeIcons.WarningTriangle, Floe.colors.pending, 16.dp)
        FloeText(stringResource(R.string.thread_no_final_reply), style = Floe.typography.body, color = Floe.colors.secondaryLabel)
    }
}

/* ------------------------------- step group row ------------------------------- */

/** ⇄ StepGroupView: collapsed header summarizes the batch; urgent rows stay
 * visible; the disclosure pairs request+result by call id (host-projected). */
@Composable
private fun StepGroupRow(group: TimelineRowUi.StepGroup, holder: ConversationFlowHolder, modifier: Modifier) {
    val state = holder.snapshot.value ?: return
    val results = StepGroupPairing.resultsByCall(group.events)
    val requests = StepGroupPairing.requestCallIds(group.events)
    val approvalSummaries = StepGroupPairing.approvalSummariesByCall(group.events)
    val displayed = StepGroupPairing.displayedEvents(group.events)

    val pendingApprovalKeys = state.pendingApprovals.map { it.key }.toSet()
    val toolCount = displayed.count { it.kind == RunEventKindUi.TOOL_REQUEST || it.kind == RunEventKindUi.TOOL_RESULT }
    val reasoningCount = displayed.count { it.kind == RunEventKindUi.REASONING }
    val failed = displayed.filter { event ->
        when (event.kind) {
            RunEventKindUi.TOOL_REQUEST, RunEventKindUi.TOOL_RESULT -> {
                val status = StepGroupPairing.requestStatus(event, results, false, group.isLatest && state.isRunning)
                    ?: event.tool?.statusRaw
                    ?: ""
                status in setOf("failed", "error", "denied", "expired", "needsUser")
            }
            RunEventKindUi.ERROR -> true
            else -> false
        }
    }
    val active = displayed.filter { it.kind == RunEventKindUi.TOOL_REQUEST && StepGroupPairing.callIdOf(it) !in results && group.isLatest && state.isRunning }
    val pendingCount = displayed.count { event ->
        val call = StepGroupPairing.callIdOf(event)
        call != null && pendingApprovalKeys.contains("${event.runId}/$call")
    }

    val summary = buildString {
        if (toolCount > 0) append(pluralToolCalls(toolCount))
        if (toolCount > 0 && reasoningCount > 0) append(" · ")
        if (reasoningCount > 0) append(pluralThinkingSegments(reasoningCount))
    }
    val stateKey = StepGroupPairing.groupStateKey(failed.size, active.size, pendingCount, group.isLatest && state.isRunning)
    val stateColor = floeStatusColor(StepGroupPairing.groupStateColorRole(failed.size, active.size, pendingCount))
    val expanded = holder.isGroupExpanded(group.groupId)

    Column(modifier = modifier.fillMaxWidth().padding(vertical = 6.dp)) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = FloeLayout.MinimumTarget)
                .clickable { holder.toggleGroup(group.groupId) }
                .padding(vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            IconGlyph(FloeIcons.PlanList, stateColor, 18.dp)
            Column(modifier = Modifier.weight(1f)) {
                FloeText(
                    if (summary.isEmpty()) stringResource(R.string.group_run_records) else summary,
                    style = Floe.typography.bodyEmphasized,
                    color = Floe.colors.label,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                FloeText(stringResource(groupStateStringKey(stateKey)), style = Floe.typography.metadata, color = stateColor)
            }
            FloeText(
                stringResource(if (expanded) R.string.action_hide else R.string.action_expand),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
            IconGlyph(if (expanded) FloeIcons.ChevronUp else FloeIcons.ChevronDown, Floe.colors.secondaryLabel, 14.dp)
        }
        val urgentIds = (active + failed).map { it.id }.toSet()
        val urgentWithDecisions = urgentIds + displayed.filter { decisionSummariesFor(it, state).isNotEmpty() }.map { it.id } +
            displayed.filter { event ->
                val call = StepGroupPairing.callIdOf(event)
                call != null && pendingApprovalKeys.contains("${event.runId}/$call")
            }.map { it.id }
        val visible = if (expanded) displayed else displayed.filter { it.id in urgentWithDecisions }
        if (expanded || urgentWithDecisions.isNotEmpty()) {
            Spacer(Modifier.height(8.dp))
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                visible.forEach { event ->
                    when (event.kind) {
                        RunEventKindUi.TOOL_REQUEST -> {
                            val call = StepGroupPairing.callIdOf(event)
                            val result = call?.let { results[it] }
                            val pendingCard = call?.let { state.pendingApprovals.firstOrNull { a -> a.runId == event.runId && a.approvalId == call } }
                            val decision = call?.let {
                                ThreadRunScopedResolution.decisionSummaries(call, event.runId, state.decisions).joinToString("\n")
                            }?.takeIf { it.isNotEmpty() }
                            val child = call?.let {
                                ThreadRunScopedResolution.child(call, event.runId, state.childRuns)
                            }
                            ToolRow(
                                event = event,
                                holder = holder,
                                resultStatusOverride = result?.tool?.statusRaw,
                                resultSummaryOverride = result?.tool?.resultSummary,
                                approvalSummary = call?.let { approvalSummaries[it] },
                                decisionSummary = decision,
                                pendingApprovalCard = pendingCard,
                                childRun = child,
                                isLive = group.isLatest && state.isRunning,
                            )
                        }
                        RunEventKindUi.TOOL_RESULT -> {
                            // Standalone (unpaired) result keeps its own card
                            // with the RECORDED output (APR-TOOL-RECORD-OUTPUT).
                            if (StepGroupPairing.callIdOf(event)?.let { it in requests } != true) {
                                ToolRow(event = event, holder = holder, isLive = false)
                            }
                        }
                        RunEventKindUi.REASONING -> ConversationReasoningBlock(
                            text = event.reasoningExcerpt.orEmpty(),
                            isStreaming = false,
                            expanded = event.id in holder.expandedToolCards.value,
                            onToggle = { holder.toggleToolCard(event.id) },
                            onCopyText = { holder.copyMessage(event.reasoningExcerpt.orEmpty()) },
                        )
                        RunEventKindUi.ERROR -> EventRow(event, holder)
                        RunEventKindUi.APPROVAL, RunEventKindUi.AUTO_APPROVED -> {
                            val call = event.tool?.callId
                            val summaryText = call?.let { approvalSummaries[it] }
                            if (call == null || call !in requests) {
                                // Detached (no matching tool) approval outcome:
                                // honest quiet line; live cards render above.
                                Row(
                                    modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp),
                                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    IconGlyph(FloeIcons.ShieldCheck, Floe.colors.secondaryLabel, 14.dp)
                                    FloeText(summaryText.orEmpty(), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                                }
                            }
                        }
                        else -> EventRow(event, holder)
                    }
                }
            }
        }
    }
}

private fun decisionSummariesFor(event: RunEventUi, state: ThreadUiState): List<String> {
    val call = StepGroupPairing.callIdOf(event) ?: return emptyList()
    return ThreadRunScopedResolution.decisionSummaries(call, event.runId, state.decisions)
}

@Composable
private fun pluralToolCalls(count: Int): String =
    if (count == 1) stringResource(R.string.group_one_tool_call) else stringResource(R.string.group_tool_calls, count)

@Composable
private fun pluralThinkingSegments(count: Int): String =
    if (count == 1) stringResource(R.string.group_one_thinking_segment) else stringResource(R.string.group_thinking_segments, count)

private fun groupStateStringKey(key: String): Int = when (key) {
    "group_waiting_confirmation" -> R.string.group_waiting_confirmation
    "group_one_needs_review" -> R.string.group_one_needs_review
    "group_items_need_review" -> R.string.group_items_need_review
    "group_one_running" -> R.string.group_one_running
    "group_items_running" -> R.string.group_items_running
    "group_run_records" -> R.string.group_run_records
    else -> R.string.group_view_run_records
}

/* --------------------------- tool card (feature) --------------------------- */

/** ⇄ ToolCallCardView: header fold + evidence sections with monospaced
 * typography, duration, artifacts and the below-fold delegate/live extras.
 * A pending approval is rendered by ToolRow as this card's sibling. */
@Composable
internal fun FloeToolCard(
    toolName: String,
    statusIcon: ImageVector,
    statusLabel: String,
    statusColor: Color,
    summary: String,
    inputSummary: String?,
    approvalSummary: String?,
    decisionSummary: String?,
    durationSeconds: Double?,
    artifacts: List<ToolArtifactUi>,
    expanded: Boolean,
    onToggleExpanded: () -> Unit,
    modifier: Modifier = Modifier,
    onOpenArtifactPreview: ((String) -> Unit)? = null,
    extra: (@Composable () -> Unit)? = null,
) {
    val colors = Floe.colors
    val shape = RoundedCornerShape(FloeLayout.BubbleCorner)
    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(shape)
            .border(0.5.dp, colors.separator.copy(alpha = 0.45f), shape)
            .background(colors.sectionCardSurface)
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = FloeLayout.MinimumTarget)
                .clickable(role = androidx.compose.ui.semantics.Role.Button) { extra?.let { onToggleExpanded() } ?: onToggleExpanded() },
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            IconGlyph(statusIcon, statusColor, 20.dp)
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                FloeText(
                    toolName,
                    style = Floe.typography.bodyEmphasized,
                    color = colors.label,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    FloeText(statusLabel, style = Floe.typography.metadata, color = statusColor)
                    if (durationSeconds != null) {
                        FloeText(
                            formatDuration(durationSeconds),
                            style = Floe.typography.metadata,
                            color = colors.secondaryLabel,
                        )
                    }
                }
            }
            IconGlyph(if (expanded) FloeIcons.ChevronUp else FloeIcons.ChevronDown, colors.secondaryLabel, 14.dp)
        }
        FloeText(
            summary,
            style = Floe.typography.metadata,
            color = colors.secondaryLabel,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        artifacts.forEach { artifact ->
            // ⇄ RichArtifactView: metadata is always shown; an interactive
            // HTML artifact exposes an explicit HOST preview request only
            // when the host verified the recorded digest. This module never
            // embeds a WebView or enables raw untrusted HTML/JS.
            if (artifact.mimeType == "text/html") {
                RichArtifactAffordance(
                    artifact = artifact,
                    canOpenPreview = artifact.hostVerified,
                    onOpenPreview = { onOpenArtifactPreview?.invoke(artifact.id) },
                )
            } else {
                ArtifactRow(artifact)
            }
        }
        if (expanded) {
            FloeDivider()
            inputSummary?.takeIf { it.isNotEmpty() }?.let {
                EvidenceSection(stringResource(R.string.tool_input), it)
            }
            val output = summary.takeIf { it.isNotEmpty() }
            if (output != null && inputSummary != output) {
                EvidenceSection(stringResource(R.string.tool_result), output)
            }
            approvalSummary?.takeIf { it.isNotEmpty() }?.let {
                EvidenceSection(stringResource(R.string.tool_approval), it)
            }
            decisionSummary?.takeIf { it.isNotEmpty() }?.let {
                EvidenceSection(stringResource(R.string.tool_decision), it)
            }
            extra?.invoke()
        }
    }
}

private fun formatDuration(seconds: Double): String =
    if (seconds < 1.0) "${(seconds * 1000).toLong()} ms" else String.format("%.1f s", seconds)

@Composable
private fun EvidenceSection(title: String, text: String) {
    // ⇄ BoundedToolEvidence: a bounded prefix first; "Show more" is explicit
    // (+8192 per tap) and never alters the complete persisted result the
    // model received.
    var limit by remember(text) { mutableStateOf(EVIDENCE_PAGE) }
    Column(modifier = Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        FloeText(title, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
        val clipped = text.length > limit
        FloeText(
            if (clipped) text.substring(0, limit) else text,
            style = Floe.typography.evidence,
            color = Floe.colors.secondaryLabel,
        )
        if (clipped) {
            val showMoreCd = stringResource(R.string.show_more_output)
            Box(
                modifier = Modifier
                    .heightIn(min = FloeLayout.MinimumTarget)
                    .clickable { limit += EVIDENCE_PAGE }
                    .semantics { contentDescription = showMoreCd },
                contentAlignment = Alignment.CenterStart,
            ) {
                FloeText(stringResource(R.string.show_more_output), style = Floe.typography.metadata, color = Floe.colors.accent)
            }
        }
    }
}

private const val EVIDENCE_PAGE = 8_192

/** ⇄ artifact affordance: metadata line with the recorded digest identity;
 * byte loading/preview only happens through a host-verified URI. */
@Composable
private fun ArtifactRow(artifact: ToolArtifactUi) {
    val colors = Floe.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .background(colors.groupedSurface)
            .padding(horizontal = 10.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconGlyph(
            when {
                artifact.mimeType.startsWith("image/") -> FloeIcons.Photo
                artifact.mimeType.startsWith("video/") -> FloeIcons.VideoPlus
                else -> FloeIcons.Terminal
            },
            colors.secondaryLabel,
            16.dp,
        )
        Column(modifier = Modifier.weight(1f)) {
            FloeText(artifact.relativePath.substringAfterLast('/'), style = Floe.typography.metadata, color = colors.label, maxLines = 1, overflow = TextOverflow.Ellipsis)
            FloeText(
                "${TokenUnitFormatter.format(artifact.byteCount.toInt())} · ${artifact.mimeType}",
                style = Floe.typography.evidence,
                color = colors.secondaryLabel,
            )
        }
        if (!artifact.hostVerified) {
            FloeText(
                stringResource(R.string.artifact_unverified),
                style = Floe.typography.metadata,
                color = Floe.colors.pending,
            )
        }
    }
}

/* ------------------------------ image glyph fix ------------------------------ */
// (Kept local: the design-system icon set is frozen for this lane; the
// selection slot import proves 48dp targets are reused where applicable.)
@Suppress("unused")
private val selectionSlotReference: Unit = Unit
