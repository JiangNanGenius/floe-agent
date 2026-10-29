// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui.state

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.floe.android.feature.notes.NotesService
import com.floe.android.feature.notes.ui.api.NotesAssistantAvailability
import com.floe.android.feature.notes.ui.api.NotesAssistantContext
import com.floe.android.feature.notes.ui.api.NotesAssistantConversationRequest
import com.floe.android.feature.notes.ui.api.NotesAssistantEvent
import com.floe.android.feature.notes.ui.api.NotesAssistantPort
import com.floe.android.feature.notes.ui.api.NotesAssistantProposal
import com.floe.android.feature.notes.ui.api.NotesAssistantRestartRequest
import com.floe.android.feature.notes.ui.api.NotesAssistantRunOutcome
import com.floe.android.feature.notes.ui.api.NotesAssistantSendRequest
import com.floe.android.feature.notes.ui.api.NotesAssistantStatus
import com.floe.android.feature.notes.ui.api.NotesAssistantTranscriptEntry
import com.floe.android.feature.notes.ui.api.NotesAssistantTranscriptPage
import com.floe.android.feature.notes.ui.api.NotesAssistantTranscriptRole
import com.floe.android.feature.notes.ui.api.NotesInkToolKind
import com.floe.android.feature.notes.ui.presentation.NotesFailure
import com.floe.android.feature.notes.ui.presentation.toNotesFailure
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

internal data class NotesAssistantMessage(
    val id: String,
    val fromUser: Boolean,
    val text: String,
    val streaming: Boolean = false,
    val stopped: Boolean = false,
    val failed: Boolean = false,
    /** Structured proposal-decision transcript row; rendered as a notice. */
    val systemEvent: Boolean = false,
    /** True only when a DURABLE run row says the run was interrupted. */
    val interrupted: Boolean = false,
)

internal enum class NotesAssistantNotice { ANSWER_SAVED, ANSWER_INSERTED, NOTHING_TO_SAVE }

/**
 * Document-owned assistant conversation. It never reads chat history, never
 * shares selection/undo with the editor and never grants itself access: the
 * Notes-local grant is created through [NotesService.bindAssistant] for this
 * exact document before the first turn.
 *
 * Durability: on open the controller restores the DURABLE transcript page from
 * the host (which projects the native `purpose = notes` messages and the real
 * run outcome). A view reconstruction therefore shows the real conversation
 * instead of an empty panel. Older pages load on demand; nothing is invented.
 */
@Stable
internal class NotesAssistantController(
    private val session: NotesDocumentSession,
    private val service: NotesService,
    private val port: NotesAssistantPort,
    private val scope: CoroutineScope,
) {
    var isOpen by mutableStateOf(false)
    var status by mutableStateOf<NotesAssistantStatus?>(null)
        private set
    var loading by mutableStateOf(false)
        private set
    var conversationID by mutableStateOf<String?>(null)
        private set
    var messages by mutableStateOf<List<NotesAssistantMessage>>(emptyList())
        private set
    var streaming by mutableStateOf(false)
        private set
    var failure by mutableStateOf<NotesFailure?>(null)
        private set
    var input by mutableStateOf("")
    var notice by mutableStateOf<NotesAssistantNotice?>(null)
        private set
    var inkTool: NotesInkToolKind = NotesInkToolKind.PEN

    /** Pending proposals for THIS document/conversation (editor accept path). */
    var proposals by mutableStateOf<List<NotesAssistantProposal>>(emptyList())
        private set
    var proposalBusy by mutableStateOf(false)
        private set
    var hasOlder by mutableStateOf(false)
        private set

    private var olderCursor: String? = null
    private var turn: Long = 0L
    private var sendJob: Job? = null
    private var transcriptJob: Job? = null
    private var disposed = false
    private var cancelRequested = false

    fun open() {
        isOpen = true
        if (conversationID == null) refreshStatusAndOpen()
    }

    fun close() {
        isOpen = false
    }

    fun dismissNotice() {
        notice = null
    }

    fun dismissFailure() {
        failure = null
    }

    private fun refreshStatusAndOpen() {
        if (loading || disposed) return
        loading = true
        failure = null
        scope.launch {
            try {
                val current = port.status()
                status = current
                if (current.availability != NotesAssistantAvailability.READY) return@launch
                val conversation = port.createConversation(
                    NotesAssistantConversationRequest(
                        documentID = session.documentID,
                        documentTitle = session.document?.title ?: "",
                        canEdit = true,
                    ),
                )
                // Explicit, document-scoped grant. Tool/context text can never
                // widen it; revoking or deleting a chat cannot delete notes.
                service.bindAssistant(conversation.id, session.documentID, canEdit = true)
                service.setAssistantFocus(conversation.id, session.documentID, session.activePageID)
                conversationID = conversation.id
                messages = emptyList()
                olderCursor = null
                hasOlder = false
                restoreTranscript()
                refreshProposals()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                failure = error.toNotesFailure()
            } finally {
                loading = false
            }
        }
    }

    // ---------------------------------------------------------------- durable

    /** Rebuilds the visible conversation from durable rows (never invented). */
    private fun restoreTranscript() {
        val id = conversationID ?: return
        transcriptJob?.cancel()
        transcriptJob = scope.launch {
            try {
                val page = port.transcript(id, before = null)
                if (id != conversationID) return@launch
                messages = page.entries.mapNotNull { it.toMessage() }
                olderCursor = page.earlierCursor
                hasOlder = page.hasEarlier
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                // A transcript read failure must not hide the live turn; the
                // panel shows the failure and keeps send available.
                if (messages.isEmpty()) failure = error.toNotesFailure()
            }
        }
    }

    fun loadOlder() {
        val id = conversationID ?: return
        val cursor = olderCursor ?: return
        if (loadingOlder) return
        loadingOlder = true
        scope.launch {
            try {
                val page = port.transcript(id, before = cursor)
                if (id != conversationID) return@launch
                val restored = page.entries.mapNotNull { it.toMessage() }
                val known = messages.map { it.id }.toSet()
                messages = restored.filter { it.id !in known } + messages
                olderCursor = page.earlierCursor
                hasOlder = page.hasEarlier
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                // Leave the cursor so the user can retry.
            } finally {
                loadingOlder = false
            }
        }
    }

    var loadingOlder by mutableStateOf(false)
        private set

    private fun NotesAssistantTranscriptEntry.toMessage(): NotesAssistantMessage? {
        val text = text
        return when (role) {
            NotesAssistantTranscriptRole.USER -> NotesAssistantMessage(
                id = id, fromUser = true, text = text)
            NotesAssistantTranscriptRole.ASSISTANT -> NotesAssistantMessage(
                id = id,
                fromUser = false,
                text = text,
                stopped = outcome == NotesAssistantRunOutcome.CANCELLED,
                failed = outcome == NotesAssistantRunOutcome.FAILED ||
                    outcome == NotesAssistantRunOutcome.INTERRUPTED,
                interrupted = outcome == NotesAssistantRunOutcome.INTERRUPTED,
            )
            NotesAssistantTranscriptRole.SYSTEM -> NotesAssistantMessage(
                id = id,
                fromUser = false,
                text = text,
                systemEvent = true,
            )
        }
    }

    // --------------------------------------------------------------- proposals

    fun refreshProposals() {
        val id = conversationID ?: return
        scope.launch {
            runCatching { port.proposals(id, session.documentID) }
                .onSuccess { if (id == conversationID) proposals = it }
                .onFailure { /* keep the previous list; a refusal is not "none" */ }
        }
    }

    fun acceptProposal(proposalID: String) {
        val id = conversationID ?: return
        if (proposalBusy) return
        proposalBusy = true
        scope.launch {
            try {
                val decision = port.acceptProposal(id, session.documentID, proposalID)
                if (decision.decision == "applied") {
                    // The native apply advanced the document revision: reload
                    // ONLY this exact source note from the real store, then
                    // refresh the proposal list. No other note is touched.
                    runCatching { session.load(focusPageID = session.activePageID) }
                }
                refreshProposals()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                failure = error.toNotesFailure()
            } finally {
                proposalBusy = false
            }
        }
    }

    fun rejectProposal(proposalID: String) {
        val id = conversationID ?: return
        if (proposalBusy) return
        proposalBusy = true
        scope.launch {
            try {
                port.rejectProposal(id, session.documentID, proposalID)
                refreshProposals()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                failure = error.toNotesFailure()
            } finally {
                proposalBusy = false
            }
        }
    }

    // ------------------------------------------------------------------- turn

    fun onPageChanged(pageID: String?) {
        val id = conversationID ?: return
        scope.launch {
            runCatching { service.setAssistantFocus(id, session.documentID, pageID) }
        }
    }

    fun onDocumentReplaced() {
        // Context is rebuilt from the current session on every send; no state
        // from a previously bound revision is reused.
    }

    fun updateInput(value: String) {
        input = value
    }

    fun send() {
        val id = conversationID ?: return
        val text = input.trim()
        if (text.isEmpty() || streaming) return
        val document = session.document ?: return
        if (cancelRequested) return
        input = ""
        failure = null
        notice = null
        val userMessage = NotesAssistantMessage(
            id = UUID.randomUUID().toString(),
            fromUser = true,
            text = text,
        )
        val replyID = UUID.randomUUID().toString()
        messages = messages + userMessage + NotesAssistantMessage(
            id = replyID,
            fromUser = false,
            text = "",
            streaming = true,
        )
        streaming = true
        turn++
        val token = turn
        var completed = false
        var settledSuccessfully = false
        val context = NotesAssistantContext(
            documentID = session.documentID,
            revision = document.revision,
            pageID = session.currentPage?.id,
            pageNumber = session.currentPageIndex?.plus(1),
            nodeID = session.selectedMindMapNodeID,
            selectedElementIDs = session.selectedElementIDs.toList(),
            selectedText = session.assistantContextText(),
            attachmentResourceIDs = session.assistantAttachmentIDs(),
        )
        sendJob = scope.launch {
            var dispatched = false
            try {
                // The assistant must receive the stored version of what the
                // user selected, including newly drawn ink and pending text.
                for (pageID in session.pendingInk.keys.toList()) {
                    if (!session.commitInk(pageID)) {
                        throw com.floe.android.feature.notes.NotesException(
                            session.inkSaveFailure?.code ?: "conflict",
                            "assistantInkNotSaved", retryable = true,
                        )
                    }
                }
                when (val saved = session.flush()) {
                    is NotesFlushResult.Failed -> throw com.floe.android.feature.notes.NotesException(
                        saved.failure.code, "assistantFlushFailed", retryable = true,
                    )
                    is NotesFlushResult.Conflict -> throw com.floe.android.feature.notes.NotesException(
                        "conflict", "assistantFlushConflict", retryable = true,
                    )
                    NotesFlushResult.Fenced -> throw com.floe.android.feature.notes.NotesException(
                        "staleGeneration", "assistantFlushFenced", retryable = true,
                    )
                    NotesFlushResult.Saved, NotesFlushResult.NoPending -> Unit
                }
                if (session.pendingEditCount > 0 || session.pendingInk.isNotEmpty()) {
                    throw com.floe.android.feature.notes.NotesException(
                        "busy", "assistantEditsPending", retryable = true,
                    )
                }
                val savedDocument = session.document
                    ?: throw com.floe.android.feature.notes.NotesException("notFound", "document")
                if (token != turn || disposed) return@launch
                dispatched = true
                port.send(
                    NotesAssistantSendRequest(
                        conversationID = id,
                        documentID = session.documentID,
                        revision = savedDocument.revision,
                        text = text,
                        context = context.copy(revision = savedDocument.revision),
                    ),
                ) { event ->
                    if (token == turn && !disposed) {
                        when (event) {
                            is NotesAssistantEvent.Delta -> appendDelta(replyID, event.text)
                            is NotesAssistantEvent.Snapshot -> replaceReplyText(replyID, event.text)
                            is NotesAssistantEvent.Finished -> {
                                completed = true
                                settledSuccessfully = true
                                finishReply(replyID, event.finalText)
                            }
                            is NotesAssistantEvent.Failed -> {
                                completed = true
                                failure = event.failure.toNotesFailure()
                                markReplyFailed(replyID)
                            }
                            NotesAssistantEvent.Cancelled -> {
                                completed = true
                                markReplyStopped(replyID)
                            }
                        }
                    }
                }
                if (token == turn && !completed) {
                    // A host that ends without a terminal event still finishes
                    // exactly once with the text already streamed.
                    finishReply(replyID, messages.firstOrNull { it.id == replyID }?.text.orEmpty())
                }
            } catch (cancelled: CancellationException) {
                // The VIEW coroutine was cancelled (route rebuild). The HOST
                // owns the run, so this is not a cancelled turn; the durable
                // transcript and the host's active turn restore it.
                if (token == turn) {
                    messages = messages.filterNot { it.id == replyID }
                }
                throw cancelled
            } catch (error: Throwable) {
                if (token == turn) {
                    failure = error.toNotesFailure()
                    if (!dispatched && input.isEmpty()) input = text
                    markReplyFailed(replyID)
                }
            } finally {
                if (token == turn) {
                    streaming = false
                    cancelRequested = false
                }
                if (settledSuccessfully && token == turn && !disposed) {
                    // The durable assistant message is committed BEFORE the
                    // native terminal, so this re-read replaces the streamed
                    // bubble with the canonical persisted row exactly once.
                    // A failed/cancelled turn keeps its honest partial text.
                    restoreTranscript()
                }
                refreshProposals()
            }
        }
    }

    private fun appendDelta(replyID: String, delta: String) {
        messages = messages.map { message ->
            if (message.id == replyID) message.copy(text = message.text + delta) else message
        }
    }

    /** Authoritative replacement for the current owned turn (never append). */
    private fun replaceReplyText(replyID: String, text: String) {
        messages = messages.map { message ->
            if (message.id == replyID) message.copy(text = text) else message
        }
    }

    private fun finishReply(replyID: String, finalText: String) {
        messages = messages.map { message ->
            if (message.id == replyID) {
                message.copy(
                    text = finalText.ifBlank { message.text },
                    streaming = false,
                )
            } else message
        }
        streaming = false
    }

    private fun markReplyFailed(replyID: String) {
        messages = messages.map { message ->
            if (message.id == replyID) message.copy(streaming = false, failed = true) else message
        }
        streaming = false
    }

    private fun markReplyStopped(replyID: String) {
        messages = messages.map { message ->
            if (message.id == replyID) message.copy(streaming = false, stopped = true) else message
        }
        streaming = false
    }

    /**
     * Requests cancellation. The visible `Cancelled` state arrives ONLY from the
     * real terminal (host `NotesAssistantEvent.Cancelled`), never from this
     * acknowledgement; the input stays disabled until that terminal lands.
     */
    fun cancel() {
        if (!streaming || cancelRequested) return
        cancelRequested = true
        val id = conversationID ?: return
        scope.launch { runCatching { port.cancel(id) } }
    }

    fun restart() {
        val id = conversationID ?: return
        if (streaming) return
        loading = true
        failure = null
        scope.launch {
            try {
                val document = session.document
                val next = port.restartConversation(
                    NotesAssistantRestartRequest(
                        conversationID = id,
                        documentID = session.documentID,
                        documentTitle = document?.title ?: "",
                    ),
                )
                // The old grant is revoked by the native bind transaction; the
                // new durable thread owns the document from here.
                service.bindAssistant(next.id, session.documentID, canEdit = true)
                service.setAssistantFocus(next.id, session.documentID, session.activePageID)
                conversationID = next.id
                messages = emptyList()
                proposals = emptyList()
                olderCursor = null
                hasOlder = false
                restoreTranscript()
                refreshProposals()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                // Refused restart (run not drained) keeps the OLD conversation
                // and its durable history; nothing is recreated locally.
                failure = error.toNotesFailure()
            } finally {
                loading = false
            }
        }
    }

    fun saveAsNewNote(title: String) {
        val text = lastAssistantText() ?: run {
            notice = NotesAssistantNotice.NOTHING_TO_SAVE
            return
        }
        scope.launch {
            val id = session.saveAssistantAnswerAsNote(text, title)
            notice = if (id != null) NotesAssistantNotice.ANSWER_SAVED else NotesAssistantNotice.NOTHING_TO_SAVE
        }
    }

    fun insertOnPage() {
        val text = lastAssistantText() ?: run {
            notice = NotesAssistantNotice.NOTHING_TO_SAVE
            return
        }
        if (session.insertAssistantText(text)) {
            notice = NotesAssistantNotice.ANSWER_INSERTED
        } else {
            notice = NotesAssistantNotice.NOTHING_TO_SAVE
        }
    }

    fun addSubtopic() {
        val text = lastAssistantText() ?: run {
            notice = NotesAssistantNotice.NOTHING_TO_SAVE
            return
        }
        if (session.document?.kind == com.floe.android.feature.notes.NoteDocumentKind.MIND_MAP &&
            session.insertAssistantText(text)
        ) {
            notice = NotesAssistantNotice.ANSWER_INSERTED
        } else {
            notice = NotesAssistantNotice.NOTHING_TO_SAVE
        }
    }

    fun lastAssistantText(): String? =
        messages.lastOrNull { !it.fromUser && !it.systemEvent && it.text.isNotBlank() }?.text

    fun openSettingsRequired(): Boolean =
        status?.availability == NotesAssistantAvailability.NOT_CONFIGURED

    fun supported(): Boolean =
        status?.availability == NotesAssistantAvailability.READY

    fun dispose() {
        disposed = true
        sendJob?.cancel()
        transcriptJob?.cancel()
        // Detach only: the durable thread and any owned run stay intact; the
        // native bind is NOT revoked here (the next open reuses this exact
        // conversation and its transcript).
        conversationID = null
    }
}
