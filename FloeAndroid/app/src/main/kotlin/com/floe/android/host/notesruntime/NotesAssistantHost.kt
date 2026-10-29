// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.notesruntime

import com.floe.android.feature.notes.ui.api.NotesAssistantAvailability
import com.floe.android.feature.notes.ui.api.NotesAssistantConversation
import com.floe.android.feature.notes.ui.api.NotesAssistantConversationRequest
import com.floe.android.feature.notes.ui.api.NotesAssistantEvent
import com.floe.android.feature.notes.ui.api.NotesAssistantPort
import com.floe.android.feature.notes.ui.api.NotesAssistantProposal
import com.floe.android.feature.notes.ui.api.NotesAssistantProposalDecision
import com.floe.android.feature.notes.ui.api.NotesAssistantRestartRequest
import com.floe.android.feature.notes.ui.api.NotesAssistantRootLifecycle
import com.floe.android.feature.notes.ui.api.NotesAssistantRunOutcome
import com.floe.android.feature.notes.ui.api.NotesAssistantSendRequest
import com.floe.android.feature.notes.ui.api.NotesAssistantStatus
import com.floe.android.feature.notes.ui.api.NotesAssistantStopReport
import com.floe.android.feature.notes.ui.api.NotesAssistantTranscriptEntry
import com.floe.android.feature.notes.ui.api.NotesAssistantTranscriptPage
import com.floe.android.feature.notes.ui.api.NotesAssistantTranscriptRole
import com.floe.android.feature.notes.ui.api.NotesAssistantTurnSnapshot
import com.floe.android.feature.notes.ui.api.NotesPortFailure
import com.floe.android.feature.notes.ui.api.NotesPortFailureException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull

/**
 * Application-owned Notes assistant host (G06).
 *
 * It is the ONLY App-side adapter behind [NotesAssistantPort]: it turns the
 * Notes UI's typed calls into the EXISTING closed `floe.notes/4` actions
 * (`assistant.*` for the run lifecycle, `proposal.*` for the editor's real
 * accept/reject) and consumes the EXISTING run-event stream for streaming text.
 *
 * It never constructs a provider client, an agent loop, a conversation
 * controller, a Notes store or a second transcript: the durable conversation
 * and messages live in the native `purpose = notes` rows, and the run belongs
 * to the accepted `FacadeRunDomain`.
 *
 * Lifetime:
 * * one instance per App process, created off the main thread;
 * * [send] owns its run subscription in the PROCESS scope, so a view/route
 *   reconstruction never cancels a run. [close] only detaches;
 * * [prepareForRootStop] fences admission and reports the NATIVE drain; an ACK,
 *   a stream end or a timeout is never reported as drained;
 * * a new accepted root calls [resumeAfterRootChange] to rebuild projections
 *   from durable state — old runs are never revived and nothing auto-retries.
 */
class NotesAssistantHost(
    private val commands: NotesAssistantCommandPort,
    private val runs: NotesAssistantRunStreamFactory,
    private val scope: CoroutineScope,
    /** True only when the App's real root epoch is accepted. */
    private val epochProvider: () -> Long,
) : NotesAssistantPort, NotesAssistantRootLifecycle, AutoCloseable {

    private val json = Json { ignoreUnknownKeys = true; isLenient = false }
    private val turns = MutableStateFlow<Map<String, NotesAssistantTurnSnapshot>>(emptyMap())
    private val activeJobs = ConcurrentHashMap<String, Job>()
    /** Reservations held from the launch command until the owned turn settles. */
    private val inFlightConversations: MutableSet<String> = ConcurrentHashMap.newKeySet()
    private val correlation = AtomicLong(0)
    private val fenced = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)

    /** ONE turn per conversation: a second send while live is a typed refusal. */
    override fun activeTurn(conversationID: String): NotesAssistantTurnSnapshot? =
        turns.value[conversationID]

    // ---------------------------------------------------------------- status

    override suspend fun status(): NotesAssistantStatus {
        if (closed.get()) return NotesAssistantStatus(NotesAssistantAvailability.UNSUPPORTED)
        if (epochProvider() <= 0L) {
            return NotesAssistantStatus(
                NotesAssistantAvailability.NOT_CONFIGURED,
                message = "runtimeUnavailable",
            )
        }
        val reply = exchange("assistant.status", JsonObject(emptyMap()))
        val availability = when (reply.string("availability")) {
            "ready" -> NotesAssistantAvailability.READY
            "notConfigured" -> NotesAssistantAvailability.NOT_CONFIGURED
            "unavailable" -> NotesAssistantAvailability.UNSUPPORTED
            else -> NotesAssistantAvailability.UNSUPPORTED
        }
        return NotesAssistantStatus(
            availability = availability,
            modelLabel = reply.string("modelLabel"),
            message = reply.string("reason"),
        )
    }

    // ------------------------------------------------------------------ open

    override suspend fun createConversation(
        request: NotesAssistantConversationRequest,
    ): NotesAssistantConversation {
        requireAdmission()
        val reply = exchange("assistant.open", JsonObject(mapOf(
            "documentID" to JsonPrimitive(request.documentID),
            "title" to JsonPrimitive(request.documentTitle),
        )))
        val id = reply.string("conversationID")
            ?: throw failure(NotesPortFailure.NOT_CONFIGURED, "conversationMissing")
        return NotesAssistantConversation(id)
    }

    // ------------------------------------------------------------------ send

    override suspend fun send(
        request: NotesAssistantSendRequest,
        onEvent: (NotesAssistantEvent) -> Unit,
    ) {
        requireAdmission()
        // One assistant turn per conversation. The reservation is taken
        // BEFORE the launch so two racing sends cannot both pass the check.
        if (!inFlightConversations.add(request.conversationID)) {
            throw failure(NotesPortFailure.BUSY, "turnActive")
        }
        // Re-read the durable thread BEFORE the launch: this is the ONLY
        // current conversation revision the native start CAS expects, and it
        // revalidates that this exact conversation still owns the document.
        val reopened = try {
            exchange("assistant.open", JsonObject(mapOf(
                "documentID" to JsonPrimitive(request.documentID),
                "title" to JsonPrimitive(""),
            )))
        } catch (error: Throwable) {
            inFlightConversations.remove(request.conversationID)
            throw error
        }
        val boundConversation = reopened.string("conversationID")
        if (boundConversation != null && boundConversation != request.conversationID) {
            inFlightConversations.remove(request.conversationID)
            throw failure(NotesPortFailure.NOT_FOUND, "conversationChanged")
        }
        val payload = linkedMapOf<String, JsonElement>(
            "conversationID" to JsonPrimitive(request.conversationID),
            "documentID" to JsonPrimitive(request.documentID),
            "goal" to JsonPrimitive(request.text),
            // The document revision the editor's context came from. The
            // native coordinator validates the focus against the stored
            // document at exactly this revision.
            "documentRevision" to JsonPrimitive(request.revision),
            "pageID" to (request.context.pageID?.let { JsonPrimitive(it) }
                ?: kotlinx.serialization.json.JsonNull),
        )
        // The native start CAS is the CONVERSATION row revision, not the
        // document revision. A missing revision stays absent (the native
        // launch still proves the current revision internally).
        reopened.string("revision")?.let { payload["revision"] = JsonPrimitive(it) }
        request.context.pageNumber?.let { payload["pageNumber"] = JsonPrimitive(it) }
        request.context.nodeID?.let { payload["nodeID"] = JsonPrimitive(it) }
        if (request.context.selectedElementIDs.isNotEmpty()) {
            payload["selectedElementIDs"] = JsonArray(
                request.context.selectedElementIDs.take(MAX_SELECTED_ELEMENTS)
                    .map { JsonPrimitive(it) })
        }
        request.context.selectedText
            ?.let { boundedUtf8(it, MAX_SELECTED_TEXT_BYTES) }
            ?.takeIf { it.isNotEmpty() }
            ?.let { payload["selectedText"] = JsonPrimitive(it) }
        if (request.context.attachmentResourceIDs.isNotEmpty()) {
            payload["attachmentResourceIDs"] = JsonArray(
                request.context.attachmentResourceIDs.take(MAX_ATTACHMENTS)
                    .map { JsonPrimitive(it) })
        }
        val start = try {
            exchange("assistant.start", JsonObject(payload))
        } catch (error: Throwable) {
            inFlightConversations.remove(request.conversationID)
            throw error
        }
        val runID = start.string("runID") ?: run {
            inFlightConversations.remove(request.conversationID)
            throw failure(NotesPortFailure.FAILED, "runIdentityMissing")
        }
        val settled = CompletableDeferred<Unit>()
        val turn = NotesTurnProjection(
            conversationID = request.conversationID,
            runID = runID,
            onEvent = onEvent,
            publishProjection = ::publish,
        )
        publish(turn.projection(streaming = true))
        val job = scope.launch {
            var detach: (() -> Unit)? = null
            try {
                detach = runs.open(
                    taskID = request.conversationID,
                    runID = runID,
                    onFrame = turn::onFrame,
                    onFailure = turn::onFailure,
                )
                // The concrete factory resolves the canonical run stream; a
                // dead pump or Superseded completes this exactly once, so the
                // UI never waits forever. A local detach is not a terminal.
                runs.awaitTerminal(runID)
                turn.finish()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                turn.onFailure("streamUnavailable")
                turn.finish()
            } finally {
                detach?.invoke()
                activeJobs.remove(request.conversationID)
                inFlightConversations.remove(request.conversationID)
                // Notes-specific decision drain: deliver ready proposal
                // decisions and (when idle) launch the queued follow-up through
                // the SAME closed Notes profile. Refusals stay durable.
                runCatching { drainDecisions(request.conversationID) }
                settled.complete(Unit)
            }
        }
        activeJobs[request.conversationID] = job
        // A cancelled VIEW coroutine must not cancel the owned run job.
        try {
            settled.await()
        } catch (cancelled: CancellationException) {
            throw cancelled
        }
    }

    override suspend fun cancel(conversationID: String) {
        // Request only: the UI reaches CANCELLED from the real terminal, never
        // from this acknowledgement.
        exchange("assistant.cancel", JsonObject(mapOf(
            "conversationID" to JsonPrimitive(conversationID),
        )))
    }

    override suspend fun close(conversationID: String) {
        // Detach only. The run, its owned stream, the durable mapping and the
        // transcript stay untouched; [activeTurn]/transcript are how a rebuilt
        // view re-attaches. Never a stop, never a revoke.
    }

    // ------------------------------------------------------------ transcript

    override suspend fun transcript(
        conversationID: String,
        before: String?,
        limit: Int,
    ): NotesAssistantTranscriptPage {
        if (closed.get()) throw failure(NotesPortFailure.UNAVAILABLE, "hostClosed")
        val payload = linkedMapOf<String, kotlinx.serialization.json.JsonElement>(
            "conversationID" to JsonPrimitive(conversationID),
            "limit" to JsonPrimitive(limit.coerceIn(1, 200)),
        )
        before?.let { payload["olderCursor"] = JsonPrimitive(it) }
        val reply = exchange("assistant.transcript", JsonObject(payload))
        val entries = (reply["entries"] as? JsonArray).orEmpty().mapNotNull { element ->
            val entry = element as? JsonObject ?: return@mapNotNull null
            val role = when (entry.string("role")) {
                "user" -> NotesAssistantTranscriptRole.USER
                "assistant" -> NotesAssistantTranscriptRole.ASSISTANT
                "system" -> NotesAssistantTranscriptRole.SYSTEM
                else -> return@mapNotNull null
            }
            NotesAssistantTranscriptEntry(
                id = entry.string("id") ?: return@mapNotNull null,
                role = role,
                text = entry.string("text").orEmpty(),
                runID = entry.string("runID"),
                outcome = NotesAssistantRunOutcome.fromWire(entry.string("outcome")),
            )
        }
        return NotesAssistantTranscriptPage(
            entries = entries,
            earlierCursor = reply.string("olderCursor"),
            hasEarlier = reply.bool("hasOlder") ?: false,
        )
    }

    // -------------------------------------------------------------- proposals

    override suspend fun proposals(
        conversationID: String,
        documentID: String,
    ): List<NotesAssistantProposal> {
        if (closed.get()) throw failure(NotesPortFailure.UNAVAILABLE, "hostClosed")
        val reply = exchange("proposal.list", JsonObject(mapOf(
            "documentID" to JsonPrimitive(documentID),
            "conversationID" to JsonPrimitive(conversationID),
            "limit" to JsonPrimitive(200),
        )))
        return (reply["proposals"] as? JsonArray).orEmpty().mapNotNull { element ->
            val row = element as? JsonObject ?: return@mapNotNull null
            val id = row.string("id") ?: return@mapNotNull null
            val target = row.string("documentID") ?: documentID
            if (target != documentID) return@mapNotNull null
            NotesAssistantProposal(
                proposalID = id,
                documentID = target,
                baseRevision = row.long("baseRevision")?.toInt() ?: 0,
                title = row.string("title").orEmpty(),
                summary = row.string("summary").orEmpty(),
                editCount = row.long("editCount")?.toInt() ?: 0,
                status = row.string("status") ?: "pending",
            )
        }
    }

    override suspend fun acceptProposal(
        conversationID: String,
        documentID: String,
        proposalID: String,
    ): NotesAssistantProposalDecision {
        // Exactly the editor's two-step authority: mint the single-use grant,
        // then consume it. The grant never leaves this host.
        val grant = exchange("proposal.issueGrant", JsonObject(mapOf(
            "proposalID" to JsonPrimitive(proposalID),
            "documentID" to JsonPrimitive(documentID),
        )))
        val grantID = grant.objectValue("grant")?.string("grantID")
            ?: throw failure(NotesPortFailure.FAILED, "grantMissing")
        val applied = exchange("proposal.apply", JsonObject(mapOf(
            "proposalID" to JsonPrimitive(proposalID),
            "documentID" to JsonPrimitive(documentID),
            "grantID" to JsonPrimitive(grantID),
            "conversationID" to JsonPrimitive(conversationID),
        )))
        val result = applied.objectValue("result")
        return NotesAssistantProposalDecision(
            proposalID = proposalID,
            decision = "applied",
            appliedRevision = result?.long("appliedRevision")?.toInt(),
        )
    }

    override suspend fun rejectProposal(
        conversationID: String,
        documentID: String,
        proposalID: String,
    ): NotesAssistantProposalDecision {
        exchange("proposal.resolve", JsonObject(mapOf(
            "proposalID" to JsonPrimitive(proposalID),
            "documentID" to JsonPrimitive(documentID),
            "decision" to JsonPrimitive("rejected"),
            "conversationID" to JsonPrimitive(conversationID),
        )))
        return NotesAssistantProposalDecision(proposalID, decision = "rejected")
    }

    override suspend fun restartConversation(
        request: NotesAssistantRestartRequest,
    ): NotesAssistantConversation {
        requireAdmission()
        val reply = exchange("assistant.restart", JsonObject(mapOf(
            "documentID" to JsonPrimitive(request.documentID),
            "conversationID" to JsonPrimitive(request.conversationID),
            "title" to JsonPrimitive(request.documentTitle),
        )))
        if (reply.bool("restarted") != true) {
            throw failure(NotesPortFailure.BUSY,
                reply.string("reason") ?: "restartRefused")
        }
        val id = reply.string("conversationID")
            ?: throw failure(NotesPortFailure.FAILED, "conversationMissing")
        return NotesAssistantConversation(id)
    }

    // -------------------------------------------------------------- lifecycle

    override suspend fun prepareForRootStop(epoch: Long): NotesAssistantStopReport {
        fenced.set(true)
        val reply = runCatching {
            exchange("assistant.prepareRootStop", JsonObject(mapOf(
                "epoch" to JsonPrimitive(epoch),
            )))
        }.getOrElse {
            // A native refusal is NOT a drain: keep the fence and refuse
            // retirement.
            return NotesAssistantStopReport(epoch, 0, 1, canRetire = false)
        }
        val pending = (reply["pendingRunIDs"] as? JsonArray)?.size ?: 0
        val requested = (reply["requestedRunIDs"] as? JsonArray)?.size ?: 0
        val canRetire = reply.bool("canRetire") == true &&
            reply.bool("fenced") == true && pending == 0
        return NotesAssistantStopReport(
            epoch = epoch,
            cancelRequestedCount = requested,
            pendingCount = pending,
            canRetire = canRetire,
        )
    }

    override suspend fun abortRootStop(epoch: Long) {
        // Same-epoch re-arm only; a refused native abort keeps the fence.
        val reply = runCatching {
            exchange("assistant.abortRootStop", JsonObject(mapOf(
                "epoch" to JsonPrimitive(epoch),
            )))
        }.getOrNull()
        if (reply?.bool("fenced") == false) fenced.set(false)
    }

    override suspend fun resumeAfterRootChange(epoch: Long) {
        fenced.set(false)
        activeJobs.keys.forEach { conversationID ->
            val current = turns.value[conversationID] ?: return@forEach
            if (!current.streaming) turns.value = turns.value - conversationID
        }
        // Rebuild from durable state: nothing is revived, and the next UI read
        // calls transcript()/status() against the NEW accepted epoch.
        runCatching { status() }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        activeJobs.values.forEach { it.cancel() }
        activeJobs.clear()
        inFlightConversations.clear()
        turns.value = emptyMap()
    }

    // --------------------------------------------------------------- helpers

    private suspend fun drainDecisions(conversationID: String) {
        runCatching {
            exchange("assistant.drainDecisions", JsonObject(mapOf(
                "conversationID" to JsonPrimitive(conversationID),
                "limit" to JsonPrimitive(32),
                "launchQueued" to JsonPrimitive(true),
            )))
        }
    }

    private fun requireAdmission() {
        if (closed.get()) throw failure(NotesPortFailure.UNAVAILABLE, "hostClosed")
        if (fenced.get()) throw failure(NotesPortFailure.BUSY, "rootStopping")
    }

    private suspend fun exchange(action: String, payload: JsonObject): JsonObject {
        val reply = try {
            commands.command(action, payload)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: NotesPortFailureException) {
            throw error
        } catch (error: Throwable) {
            throw failure(NotesPortFailure.FAILED, "commandUnavailable")
        }
        if (reply.bool("ok") == true) return reply
        val code = reply.string("error") ?: "failed"
        val reason = reply.string("reason")
        throw failure(mapFailureCode(code), reason ?: code)
    }

    private fun mapFailureCode(code: String): String = when (code) {
        "notConfigured" -> NotesPortFailure.NOT_CONFIGURED
        "notAuthorized", "bindingRefused" -> NotesPortFailure.PERMISSION_DENIED
        "busy", "staleRevision" -> NotesPortFailure.BUSY
        "cancelled" -> NotesPortFailure.CANCELLED
        "documentMissing", "conversationMissing", "runMissing" -> NotesPortFailure.NOT_FOUND
        "runtimeUnavailable", "unsupported", "authority" -> NotesPortFailure.UNAVAILABLE
        "invalidPayload" -> NotesPortFailure.UNSUPPORTED
        else -> NotesPortFailure.FAILED
    }

    private fun publish(turn: NotesAssistantTurnSnapshot) {
        turns.value = turns.value + (turn.conversationID to turn)
    }

    private fun failure(code: String, detail: String?) =
        NotesPortFailureException(NotesPortFailure(code, detail))

    companion object {
        /** Bounds mirrored by the native focus validator. */
        private const val MAX_SELECTED_ELEMENTS = 32
        private const val MAX_ATTACHMENTS = 16
        private const val MAX_SELECTED_TEXT_BYTES = 12_000

        /** UTF-8 byte-bounded prefix; never splits a scalar. */
        private fun boundedUtf8(value: String, maxBytes: Int): String {
            val bytes = value.toByteArray(Charsets.UTF_8)
            if (bytes.size <= maxBytes) return value
            var end = maxBytes.coerceAtLeast(0)
            while (end > 0 && end < bytes.size && (bytes[end].toInt() and 0xC0) == 0x80) {
                end -= 1
            }
            return String(bytes, 0, end, Charsets.UTF_8)
        }
    }
}

/**
 * ONE Notes assistant turn projection.
 *
 * The durable `assistantText` segments are the journal tail; the canonical
 * `run.snapshot` page carries the ORIGINAL in-progress answer text of the same
 * step. The snapshot REPLACES the already-durable prefix of that step instead
 * of being appended, so the same characters can never render twice. A snapshot
 * whose `durableWatermark` is older than an already-delivered durable frame is
 * ignored for text (the journal is fresher); it still conveys the real
 * terminal. Nothing here invents text, a terminal or a cancellation.
 */
private class NotesTurnProjection(
    private val conversationID: String,
    private val runID: String,
    private val onEvent: (NotesAssistantEvent) -> Unit,
    private val publishProjection: (NotesAssistantTurnSnapshot) -> Unit,
) {
    private val durable = StringBuilder()
    private val segments = ArrayDeque<String>()
    private var segmentChars = 0
    private var overlay: String? = null
    private var displayed = ""
    private var maxDurableSequence = 0L
    private var terminal = false
    private var finished = false
    private var cancelled = false
    private var failureDetail: String? = null

    fun projection(streaming: Boolean): NotesAssistantTurnSnapshot =
        NotesAssistantTurnSnapshot(
            conversationID = conversationID,
            runID = runID,
            text = displayed,
            streaming = streaming && !terminal,
            cancelled = cancelled,
            failed = failureDetail != null,
        )

    fun onFrame(frame: JsonObject) {
        if (finished) return
        val kind = frame.string("kind") ?: return
        val sequence = frame.long("sequence") ?: 0L
        if (sequence > maxDurableSequence) maxDurableSequence = sequence
        when (kind) {
            "assistantText" -> {
                val text = frame.objectValue("payload")?.string("text")
                if (!text.isNullOrEmpty()) {
                    durable.append(text)
                    recordSegment(text)
                }
            }
            HostNotesAssistantRunStreamFactory.FRAME_SNAPSHOT ->
                applySnapshot(frame.objectValue("payload"))
            "terminal" -> {
                terminal = true
                val payload = frame.objectValue("payload")
                val stop = payload?.string("stopReason") ?: payload?.string("terminal")
                when (stop) {
                    "cancelled", "canceled" -> cancelled = true
                    "failed" -> failureDetail = failureDetail ?: "runFailed"
                    else -> failureDetail = null
                }
            }
            "status" -> {
                val state = frame.objectValue("payload")?.string("state")
                if (state != null && state in TERMINAL_STATES) {
                    terminal = true
                    when (state) {
                        "cancelled", "canceled" -> cancelled = true
                        "failed", "checkpointed", "interrupted" ->
                            failureDetail = failureDetail ?: "runFailed"
                        "completed", "idle" -> failureDetail = null
                    }
                }
            }
            "error" -> {
                // An error frame is not itself terminal: a recoverable
                // provider error may be retried into a real completion.
                failureDetail = failureDetail
                    ?: frame.objectValue("payload")?.string("message")
            }
            else -> Unit
        }
        recompute()
        publish(projection(streaming = true))
    }

    fun onFailure(code: String) {
        if (finished || terminal) return
        // A dead pump / Superseded / epoch change is an observed settlement,
        // never a fabricated native cancellation.
        failureDetail = failureDetail ?: code
        publish(projection(streaming = true))
    }

    fun finish() {
        if (finished) return
        finished = true
        recompute()
        val text = displayed
        val failed = failureDetail
        when {
            cancelled -> {
                publish(projection(streaming = false))
                onEvent(NotesAssistantEvent.Cancelled)
            }
            failed != null -> {
                publish(projection(streaming = false))
                onEvent(NotesAssistantEvent.Failed(
                    NotesPortFailure(NotesPortFailure.FAILED, failed)))
            }
            else -> {
                publish(projection(streaming = false))
                onEvent(NotesAssistantEvent.Finished(text))
            }
        }
    }

    private fun applySnapshot(page: JsonObject?) {
        if (page == null) return
        val pageRun = page.string("runID") ?: return
        if (!sameRun(pageRun)) return
        val state = page.string("durableState")
        val isTerminal = page.bool("isTerminal") == true ||
            (state != null && state in TERMINAL_STATES)
        val watermark = page.long("durableWatermark") ?: 0L
        val liveOwner = page.bool("liveOwner") == true
        val text = page.string("answerText")
        // A read that started before newer durable segments is not allowed to
        // replace their fresher tail. Terminal pages stay authoritative.
        val stale = !isTerminal && watermark > 0L && watermark < maxDurableSequence
        if (text != null && liveOwner && !stale) overlay = text
        if (isTerminal) {
            terminal = true
            when (state) {
                "cancelled", "canceled" -> cancelled = true
                "failed", "checkpointed", "interrupted" ->
                    failureDetail = failureDetail ?: "runFailed"
                "completed", "idle" -> failureDetail = null
            }
        }
    }

    private fun recordSegment(text: String) {
        segments.addLast(text)
        segmentChars += text.length
        while (segments.size > MAX_SEGMENTS || segmentChars > MAX_SEGMENT_CHARS) {
            val dropped = segments.removeFirstOrNull() ?: break
            segmentChars -= dropped.length
        }
    }

    private fun compose(): String {
        val durableText = durable.toString()
        val live = overlay
        if (live.isNullOrEmpty()) return durableText
        if (durableText.isEmpty()) return live
        if (durableText == live) return durableText
        if (durableText.endsWith(live)) return durableText
        if (durableText.startsWith(live)) return durableText
        if (live.startsWith(durableText)) return live
        // The snapshot text starts at the current step while the durable tail
        // already contains earlier steps and/or this step's flushed prefix.
        // Remove the exact retained suffix that the snapshot repeats.
        var overlap = 0
        val candidate = StringBuilder()
        var index = segments.size - 1
        while (index >= 0) {
            candidate.insert(0, segments[index])
            if (candidate.length >= live.length) {
                if (candidate.startsWith(live)) return durableText
                break
            }
            if (live.startsWith(candidate)) overlap = candidate.length
            index -= 1
        }
        return if (overlap > 0) durableText.dropLast(overlap) + live else durableText + live
    }

    private fun recompute() {
        val next = compose()
        if (next == displayed) return
        if (next.startsWith(displayed)) {
            val delta = next.substring(displayed.length)
            if (delta.isNotEmpty()) onEvent(NotesAssistantEvent.Delta(delta))
        } else {
            // Replacement, never an append: the snapshot is the authoritative
            // current turn text (rollback/rebase/superseded tails).
            onEvent(NotesAssistantEvent.Snapshot(next))
        }
        displayed = next
    }

    private fun publish(value: NotesAssistantTurnSnapshot) {
        // The host owns the single per-process turn map; the projection never
        // creates a second state container.
        publishProjection(value)
    }

    private fun sameRun(other: String): Boolean {
        val a = runCatching { java.util.UUID.fromString(other) }.getOrNull() ?: return false
        val b = runCatching { java.util.UUID.fromString(runID) }.getOrNull() ?: return false
        return a == b
    }

    companion object {
        private const val MAX_SEGMENTS = 256
        private const val MAX_SEGMENT_CHARS = 512_000
        private val TERMINAL_STATES = setOf(
            "completed", "failed", "checkpointed", "idle", "cancelled", "canceled",
        )
    }
}

/**
 * The existing closed `floe.notes/4` channel, as a narrow port. Main wires it to
 * `NotesHostService`/`NotesService`; the assistant host owns NO wire codec of
 * its own beyond JSON object shaping.
 */
public fun interface NotesAssistantCommandPort {
    public suspend fun command(action: String, payload: JsonObject): JsonObject
}

/**
 * The EXISTING run-event stream (`RuntimeHostCommandClient.openRunEventStream`),
 * reduced to what a Notes turn needs. `open` returns a detach function; it must
 * NOT cancel the run when the returned function is invoked.
 */
public interface NotesAssistantRunStreamFactory {
    public fun open(
        taskID: String,
        runID: String,
        onFrame: (JsonObject) -> Unit,
        onFailure: (String) -> Unit,
    ): () -> Unit

    /**
     * Suspends until this run's stream has been observed to END. It MUST also
     * complete after [open] reported [onFailure] (a dead pump is a settled
     * turn, not an indefinite wait); it must never return merely because a
     * local subscriber detached.
     */
    public suspend fun awaitTerminal(runID: String)
}

// ---------------------------------------------------------------- JSON helpers

private fun JsonObject.string(key: String): String? =
    (this[key] as? JsonPrimitive)?.contentOrNull

private fun JsonObject.bool(key: String): Boolean? =
    (this[key] as? JsonPrimitive)?.booleanOrNull

private fun JsonObject.long(key: String): Long? =
    (this[key] as? JsonPrimitive)?.longOrNull

private fun JsonObject.objectValue(key: String): JsonObject? =
    this[key] as? JsonObject
