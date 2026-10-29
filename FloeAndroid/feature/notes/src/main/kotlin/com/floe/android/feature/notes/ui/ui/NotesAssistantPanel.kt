// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeAssistantMessage
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloeText
import com.floe.android.design.FloeUnavailableView
import com.floe.android.design.FloeUserBubble
import com.floe.android.design.IconGlyph
import com.floe.android.feature.notes.ui.NotesIcons
import com.floe.android.feature.notes.ui.R
import com.floe.android.feature.notes.ui.api.NotesAssistantAvailability
import com.floe.android.feature.notes.ui.api.NotesAssistantProposal
import com.floe.android.feature.notes.ui.api.NotesSettingsTarget
import com.floe.android.feature.notes.ui.state.NotesAssistantNotice
import com.floe.android.feature.notes.ui.state.NotesDocumentSession
import com.floe.android.feature.notes.ui.state.NotesWorkspaceController

@Composable
internal fun NotesAssistantPanel(
    controller: NotesWorkspaceController,
    session: NotesDocumentSession,
    modifier: Modifier = Modifier,
    onClose: () -> Unit,
    onOpenSettings: ((NotesSettingsTarget) -> Unit)?,
) {
    val assistant = session.assistant
    val document = session.document ?: return
    val listState = rememberLazyListState()
    var saveOpen by remember { mutableStateOf(false) }

    LaunchedEffect(assistant.messages.size, assistant.messages.lastOrNull()?.text?.length) {
        if (assistant.messages.isNotEmpty()) {
            listState.scrollToItem(assistant.messages.lastIndex)
        }
    }

    Column(modifier.background(Floe.colors.readingSurface)) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(Floe.colors.chromeSurface)
                .padding(start = 14.dp, end = 6.dp, top = 6.dp, bottom = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Column(Modifier.weight(1f)) {
                FloeText(stringResource(R.string.notes_assistant), style = Floe.typography.section)
                FloeText(
                    document.title,
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            NotesIconAction(
                FloeIcons.Refresh,
                stringResource(R.string.notes_assistant_restart),
                { assistant.restart() },
                enabled = assistant.conversationID != null && !assistant.streaming,
                visualSize = 32.dp,
            )
            NotesIconAction(
                FloeIcons.Xmark,
                stringResource(R.string.notes_assistant_close),
                onClose,
                visualSize = 32.dp,
            )
        }
        FloeDivider()
        // The scope hint belongs with the page/selection pills at the top,
        // not after the composer. In the compact assistant sheet the bottom
        // hint was the last child and measured [0,0] (clipped by the sheet);
        // moving it into this fixed header keeps it visible without touching
        // the conversation, streaming or Back contracts.
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                val page = session.currentPageIndex
                NotesPill(
                    if (page != null) {
                        stringResource(R.string.notes_assistant_context_page, page + 1)
                    } else {
                        stringResource(R.string.notes_assistant_context_document)
                    },
                    Floe.colors.accent,
                )
                if (session.selectedElementIDs.isNotEmpty()) {
                    NotesPill(
                        stringResource(
                            R.string.notes_assistant_context_selection,
                            session.selectedElementIDs.size,
                        ),
                        Floe.colors.secondaryLabel,
                    )
                }
                Spacer(Modifier.weight(1f))
                FloeText(
                    stringResource(R.string.notes_assistant_scope),
                    style = Floe.typography.metadata,
                    color = Floe.colors.tertiaryLabel,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            FloeText(
                stringResource(R.string.notes_assistant_selection_hint),
                style = Floe.typography.metadata,
                color = Floe.colors.tertiaryLabel,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
        FloeDivider()

        val status = assistant.status
        when {
            assistant.loading && status == null -> Box(
                Modifier.weight(1f).fillMaxWidth(),
                contentAlignment = Alignment.Center,
            ) { FloeActivityIndicator() }

            status?.availability == NotesAssistantAvailability.NOT_CONFIGURED -> {
                val settingsAction: (@Composable () -> Unit)? = onOpenSettings?.let { openSettings ->
                    {
                        FloeCapsuleAction(
                            stringResource(R.string.notes_assistant_open_settings),
                            onClick = { openSettings(NotesSettingsTarget.MODELS) },
                        )
                    }
                }
                FloeUnavailableView(
                    icon = FloeIcons.Wand,
                    title = stringResource(R.string.notes_assistant_not_configured_title),
                    description = stringResource(R.string.notes_assistant_not_configured_body),
                    action = settingsAction,
                    modifier = Modifier.weight(1f),
                )
            }

            status?.availability == NotesAssistantAvailability.UNSUPPORTED || status == null -> {
                FloeUnavailableView(
                    icon = FloeIcons.InfoCircle,
                    title = stringResource(R.string.notes_assistant_unavailable_title),
                    description = stringResource(R.string.notes_assistant_unavailable_body),
                    modifier = Modifier.weight(1f),
                )
            }

            else -> {
                LazyColumn(
                    state = listState,
                    modifier = Modifier.weight(1f).fillMaxWidth(),
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(12.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    if (assistant.messages.isEmpty() && assistant.proposals.isEmpty()) {
                        item {
                            FloeText(
                                stringResource(R.string.notes_assistant_empty),
                                style = Floe.typography.metadata,
                                color = Floe.colors.secondaryLabel,
                                modifier = Modifier.padding(vertical = 20.dp),
                            )
                        }
                    }
                    // Durable pending proposal for THIS document: the editor's
                    // real accept control (single-use grant + apply) or reject
                    // (durable decision). Never a model-authored edit script.
                    items(assistant.proposals, key = { "proposal-${it.proposalID}" }) { proposal ->
                        NotesProposalCard(
                            proposal = proposal,
                            busy = assistant.proposalBusy,
                            onAccept = { assistant.acceptProposal(proposal.proposalID) },
                            onReject = { assistant.rejectProposal(proposal.proposalID) },
                        )
                    }
                    items(assistant.messages, key = { it.id }) { message ->
                        if (message.fromUser) {
                            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
                                FloeUserBubble(message.text)
                            }
                        } else {
                            Column(Modifier.fillMaxWidth()) {
                                if (message.text.isNotBlank()) {
                                    FloeAssistantMessage(
                                        message.text,
                                        metadata = when {
                                            message.failed -> stringResource(R.string.notes_assistant_error)
                                            message.stopped -> stringResource(R.string.notes_assistant_cancelled)
                                            message.streaming -> stringResource(R.string.notes_assistant_streaming)
                                            message.systemEvent -> stringResource(R.string.notes_assistant)
                                            else -> null
                                        },
                                    )
                                } else if (message.streaming) {
                                    Row(
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                                        modifier = Modifier.padding(vertical = 8.dp),
                                    ) {
                                        FloeActivityIndicator()
                                        FloeText(
                                            stringResource(R.string.notes_assistant_streaming),
                                            style = Floe.typography.metadata,
                                            color = Floe.colors.secondaryLabel,
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
                assistant.failure?.let { failure ->
                    NotesErrorBanner(
                        failure = failure,
                        onRetry = {
                            assistant.dismissFailure()
                            assistant.send()
                        },
                        onDismiss = assistant::dismissFailure,
                    )
                }
                assistant.notice?.let { notice ->
                    val text = when (notice) {
                        NotesAssistantNotice.ANSWER_SAVED -> stringResource(R.string.notes_assistant_answer_saved)
                        NotesAssistantNotice.ANSWER_INSERTED -> stringResource(R.string.notes_assistant_answer_saved)
                        NotesAssistantNotice.NOTHING_TO_SAVE -> stringResource(R.string.notes_assistant_empty)
                    }
                    NotesBanner(
                        icon = FloeIcons.CheckCircle,
                        text = text,
                        tone = Floe.colors.success,
                        onDismiss = assistant::dismissNotice,
                        dismissLabel = stringResource(R.string.notes_dismiss),
                    )
                }
                if (assistant.lastAssistantText() != null) {
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 4.dp),
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        FloeCapsuleAction(
                            stringResource(R.string.notes_assistant_save_to_notes),
                            onClick = { saveOpen = true },
                            modifier = Modifier.weight(1f),
                        )
                        if (document.kind == com.floe.android.feature.notes.NoteDocumentKind.NOTEBOOK) {
                            FloeCapsuleAction(
                                stringResource(R.string.notes_assistant_insert_page),
                                onClick = { assistant.insertOnPage() },
                                modifier = Modifier.weight(1f),
                            )
                        }
                    }
                }
                FloeDivider()
                Row(
                    modifier = Modifier.fillMaxWidth().imePadding().padding(8.dp),
                    verticalAlignment = Alignment.Bottom,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Box(Modifier.weight(1f)) {
                        FloePlainFormField(
                            label = stringResource(R.string.notes_assistant_placeholder),
                            value = assistant.input,
                            onValueChange = assistant::updateInput,
                            enabled = !assistant.streaming,
                            singleLine = false,
                            minLines = 1,
                            maxLines = 4,
                            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Default),
                        )
                    }
                    if (assistant.streaming) {
                        FloeCircleButton(
                            icon = FloeIcons.StopSquare,
                            contentDescription = stringResource(R.string.notes_assistant_stop),
                            onClick = assistant::cancel,
                            visualSize = 38.dp,
                        )
                    } else {
                        FloeCircleButton(
                            icon = FloeIcons.ArrowUp,
                            contentDescription = stringResource(R.string.notes_assistant_send),
                            onClick = assistant::send,
                            enabled = assistant.input.isNotBlank() && assistant.conversationID != null,
                            visualSize = 38.dp,
                        )
                    }
                }
            }
        }
    }

    if (saveOpen) {
        NotesAssistantSaveSheet(
            session = session,
            visible = true,
            onDismiss = { saveOpen = false },
        )
    }
}

/**
 * One durable pending proposal. The summary is the NATIVE deterministic diff
 * description; the accept control mints the single-use grant inside the host and
 * the reject control records the durable rejection — neither exposes an edit
 * script or a raw grant to the UI/model.
 *
 * The labels are the dedicated bilingual proposal strings and the base
 * revision is the exact durable revision the diff was computed from, so the
 * user can tell a stale proposal from a current one before applying it.
 */
@Composable
private fun NotesProposalCard(
    proposal: NotesAssistantProposal,
    busy: Boolean,
    onAccept: () -> Unit,
    onReject: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(Floe.colors.chromeSurface, FloeCardShape)
            .padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        FloeText(
            stringResource(R.string.notes_assistant_proposal_title),
            style = Floe.typography.metadata,
            color = Floe.colors.accent,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        FloeText(
            proposal.title,
            style = Floe.typography.metadata,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        if (proposal.summary.isNotBlank()) {
            FloeText(
                proposal.summary,
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                maxLines = 12,
                overflow = TextOverflow.Ellipsis,
            )
        }
        FloeText(
            stringResource(
                R.string.notes_assistant_proposal_based_on,
                proposal.baseRevision,
            ),
            style = Floe.typography.metadata,
            color = Floe.colors.tertiaryLabel,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            FloeCapsuleAction(
                stringResource(R.string.notes_assistant_proposal_accept),
                onClick = onAccept,
                enabled = !busy && proposal.canAccept,
            )
            FloeCapsuleAction(
                stringResource(R.string.notes_assistant_proposal_reject),
                onClick = onReject,
                enabled = !busy && proposal.canReject,
            )
        }
    }
}

private val FloeCardShape = RoundedCornerShape(12.dp)
