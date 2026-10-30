// SPDX-License-Identifier: MPL-2.0
//
// Android host binding for durable user questions and current-thread search.
//
// One controller owns every command for a task surface:
//   question.pending / question.answer / question.cancel
//   conversation.messageSearch / conversation.messageWindow
//
// All replies are fenced on the exact visible holder + session epoch + a
// monotonic request generation. A late answer/window/search reply can never
// mutate a rebound, retired or different conversation surface. Notification
// replies use the SAME [answer] path (source=notification) and are revalidated
// by the native request digest + answer nonce + expected revision.
package com.floe.android.host.questions

import com.floe.android.feature.conversation.ConversationSessionToken
import com.floe.android.feature.conversation.MessageRoleUi
import com.floe.android.feature.conversation.ThreadSearchErrorUi
import com.floe.android.feature.conversation.ThreadSearchHitUi
import com.floe.android.feature.conversation.ThreadSearchQuery
import com.floe.android.feature.conversation.ThreadSearchResultUi
import com.floe.android.feature.conversation.UserQuestionAnswerReceiptUi
import com.floe.android.feature.conversation.UserQuestionAnswerRequestUi
import com.floe.android.feature.conversation.UserQuestionOptionUi
import com.floe.android.feature.conversation.UserQuestionPromptUi
import com.floe.android.feature.conversation.UserQuestionSelectionModeUi
import com.floe.android.feature.conversation.UserQuestionSnapshotUi
import com.floe.android.feature.conversation.UserQuestionStatusUi
import com.floe.android.feature.conversation.UserQuestionWaitPolicyUi
import com.floe.android.host.HostCommandRequest
import com.floe.android.host.HostOperationOutcome
import com.floe.android.host.HostScope
import com.floe.android.host.RuntimeHost
import java.text.SimpleDateFormat
import java.time.Instant
import java.util.Date
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

/** Callbacks into the owning conversation surface. The controller never holds
 * a holder; ConversationHostController supplies the exact-entry check. */
internal interface UserQuestionSurface {
    fun publishSnapshot(session: ConversationSessionToken, snapshot: UserQuestionSnapshotUi?)
    fun publishReceipt(session: ConversationSessionToken, receipt: UserQuestionAnswerReceiptUi)
    fun publishFailure(session: ConversationSessionToken, code: String?)
    fun publishSearchResult(
        session: ConversationSessionToken,
        generation: Long,
        result: ThreadSearchResultUi,
    )
    fun publishSearchFailure(session: ConversationSessionToken, generation: Long)
    fun publishSearchFocus(
        session: ConversationSessionToken,
        token: Long,
        messageId: String,
    )
    fun publishSearchRevealFailure(session: ConversationSessionToken, token: Long)
}

internal class UserQuestionHostController(
    private val host: RuntimeHost,
    private val surface: UserQuestionSurface,
    /** Exact visible-holder/session check used before ANY native settlement.
     * Notification replies and late sheet actions pass the same gate. */
    private val isCurrentSession: (ConversationSessionToken) -> Boolean = { true },
) {
    private val generations = ConcurrentHashMap<String, Long>()
    private val lastRefreshAt = ConcurrentHashMap<String, Long>()
    private val searchGenerations = ConcurrentHashMap<String, Long>()
    private val revealGenerations = ConcurrentHashMap<String, Long>()
    private val correlation = AtomicLong()

    fun refresh(
        session: ConversationSessionToken,
        requestId: String? = null,
        force: Boolean = false,
    ): Boolean {
        if (!host.readiness.value.conversationDomainAdmitted) return false
        val now = System.currentTimeMillis()
        if (!force) {
            val previous = lastRefreshAt[session.conversationId] ?: 0L
            if (now - previous < REFRESH_THROTTLE_MILLIS) return false
        }
        lastRefreshAt[session.conversationId] = now
        val generation = (generations[session.conversationId] ?: 0L) + 1L
        generations[session.conversationId] = generation
        val payload = requestId?.let {
            JsonObject(mapOf("requestID" to JsonPrimitive(it)))
        }
        host.trackOperation(
            HostCommandRequest(
                command = "question.pending",
                scope = HostScope.ConversationLifecycle(session.conversationId),
                stateful = false,
                correlationID = "qpend-${correlation.incrementAndGet()}",
                payload = payload,
            ),
        ) { outcome ->
            if (generations[session.conversationId] != generation) return@trackOperation
            if (!current(session)) return@trackOperation
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val snapshots = outcome.value?.let(UserQuestionWire::decodePending)
                    if (snapshots == null) {
                        surface.publishFailure(session, "questionMalformed")
                    } else {
                        surface.publishSnapshot(
                            session,
                            snapshots.firstOrNull { it.hasPending },
                        )
                    }
                }
                is HostOperationOutcome.Rejected ->
                    surface.publishFailure(session, outcome.code)
                is HostOperationOutcome.Failed ->
                    surface.publishFailure(session, outcome.code)
                HostOperationOutcome.Cancelled,
                HostOperationOutcome.Superseded -> Unit
            }
        }
        return true
    }

    fun answer(session: ConversationSessionToken, request: UserQuestionAnswerRequestUi): Boolean {
        if (!host.readiness.value.conversationDomainAdmitted) return false
        if (!isCurrentSession(session)) return false
        val payload = JsonObject(
            mapOf(
                "requestID" to JsonPrimitive(request.requestId),
                "requestDigest" to JsonPrimitive(request.requestDigest),
                "questionID" to JsonPrimitive(request.questionId),
                "runID" to JsonPrimitive(request.runId),
                "expectedRevision" to JsonPrimitive(request.expectedRevision),
                "answerNonce" to JsonPrimitive(request.answerNonce),
                "source" to JsonPrimitive("human"),
                "selectedOptionIDs" to JsonArray(
                    request.selectedOptionIds.map { JsonPrimitive(it) }),
                "freeText" to (request.freeText?.let { JsonPrimitive(it) } ?: kotlinx.serialization.json.JsonNull),
            ),
        )
        host.trackOperation(
            HostCommandRequest(
                command = "question.answer",
                scope = HostScope.ConversationLifecycle(session.conversationId),
                stateful = true,
                correlationID = "qanswer-${correlation.incrementAndGet()}",
                payload = payload,
            ),
        ) { outcome ->
            if (!current(session)) return@trackOperation
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val receipt = outcome.value?.let(UserQuestionWire::decodeReceipt)
                    if (receipt == null) {
                        surface.publishFailure(session, "questionReceiptMalformed")
                        return@trackOperation
                    }
                    surface.publishReceipt(session, receipt)
                    refresh(session, request.requestId, force = true)
                }
                is HostOperationOutcome.Rejected -> {
                    surface.publishFailure(session, outcome.code)
                    refresh(session, request.requestId, force = true)
                }
                is HostOperationOutcome.Failed ->
                    surface.publishFailure(session, outcome.code)
                HostOperationOutcome.Cancelled,
                HostOperationOutcome.Superseded -> Unit
            }
        }
        return true
    }

    fun cancel(session: ConversationSessionToken, requestId: String): Boolean {
        if (!host.readiness.value.conversationDomainAdmitted) return false
        if (!isCurrentSession(session)) return false
        host.trackOperation(
            HostCommandRequest(
                command = "question.cancel",
                scope = HostScope.ConversationLifecycle(session.conversationId),
                stateful = true,
                correlationID = "qcancel-${correlation.incrementAndGet()}",
                payload = JsonObject(mapOf("requestID" to JsonPrimitive(requestId))),
            ),
        ) { outcome ->
            if (!current(session)) return@trackOperation
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val snapshot = outcome.value?.let(UserQuestionWire::decodeSnapshot)
                    surface.publishSnapshot(session, snapshot)
                }
                is HostOperationOutcome.Rejected ->
                    surface.publishFailure(session, outcome.code)
                is HostOperationOutcome.Failed ->
                    surface.publishFailure(session, outcome.code)
                HostOperationOutcome.Cancelled,
                HostOperationOutcome.Superseded -> Unit
            }
        }
        return true
    }

    fun terminalFence(session: ConversationSessionToken, runId: String) {
        if (!current(session)) return
        // The native question snapshot is the only truth: cancel ONLY a
        // request owned by this exact run. A terminal run can no longer
        // consume an answer, so leaving it pending would be dishonest.
        val snapshot = lastSnapshotFor(session.conversationId) ?: return
        if (snapshot.runId != runId) return
        cancel(session, snapshot.requestId)
    }

    private val lastSnapshots = ConcurrentHashMap<String, UserQuestionSnapshotUi>()

    private fun lastSnapshotFor(conversationId: String): UserQuestionSnapshotUi? =
        lastSnapshots[conversationId]

    fun remember(session: ConversationSessionToken, snapshot: UserQuestionSnapshotUi?) {
        if (snapshot == null) lastSnapshots.remove(session.conversationId)
        else lastSnapshots[session.conversationId] = snapshot
    }

    /** Release every RAM-only per-task question/search fact with the holder. */
    fun forget(conversationId: String) {
        lastSnapshots.remove(conversationId)
        generations.remove(conversationId)
        lastRefreshAt.remove(conversationId)
        searchGenerations.remove(conversationId)
        revealGenerations.remove(conversationId)
    }

    private fun current(session: ConversationSessionToken): Boolean {
        return host.readiness.value.conversationDomainAdmitted &&
            isCurrentSession(session)
    }

    /* ------------------------------- search -------------------------------- */

    fun search(session: ConversationSessionToken, query: String, generation: Long): Boolean {
        if (!host.readiness.value.conversationDomainAdmitted) return false
        if (!isCurrentSession(session)) return false
        val parsed = ThreadSearchQuery(query)
        if (parsed.isEmpty) return false
        searchGenerations[session.conversationId] = generation
        host.trackOperation(
            HostCommandRequest(
                command = "conversation.messageSearch",
                scope = HostScope.ConversationLifecycle(session.conversationId),
                stateful = false,
                correlationID = "msearch-${correlation.incrementAndGet()}",
                payload = JsonObject(
                    mapOf(
                        "query" to JsonPrimitive(query),
                        "limit" to JsonPrimitive(200),
                    ),
                ),
            ),
        ) { outcome ->
            if (searchGenerations[session.conversationId] != generation) return@trackOperation
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val result = outcome.value?.let(UserQuestionWire::decodeSearch)
                    if (result == null) {
                        surface.publishSearchFailure(session, generation)
                    } else {
                        surface.publishSearchResult(session, generation, result)
                    }
                }
                is HostOperationOutcome.Rejected,
                is HostOperationOutcome.Failed -> surface.publishSearchFailure(session, generation)
                HostOperationOutcome.Cancelled,
                HostOperationOutcome.Superseded -> Unit
            }
        }
        return true
    }

    fun reveal(
        session: ConversationSessionToken,
        messageId: String,
        token: Long,
        entry: com.floe.android.host.ConversationFlowHolderEntry,
        isCurrent: () -> Boolean,
    ): Boolean {
        if (!host.readiness.value.conversationDomainAdmitted) return false
        if (!isCurrentSession(session)) return false
        revealGenerations[session.conversationId] = token
        host.trackOperation(
            HostCommandRequest(
                command = "conversation.messageWindow",
                scope = HostScope.ConversationLifecycle(session.conversationId),
                stateful = false,
                correlationID = "mwindow-${correlation.incrementAndGet()}",
                payload = JsonObject(
                    mapOf(
                        "messageID" to JsonPrimitive(messageId),
                        "before" to JsonPrimitive(40),
                        "after" to JsonPrimitive(4),
                    ),
                ),
            ),
        ) { outcome ->
            if (revealGenerations[session.conversationId] != token) return@trackOperation
            if (!isCurrent()) return@trackOperation
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val page = outcome.value?.let { value ->
                        com.floe.android.host.ConversationWire.decodeMessagePage(value)
                    }
                    if (page == null) {
                        surface.publishSearchRevealFailure(session, token)
                        return@trackOperation
                    }
                    entry.builder.applyMessageWindow(page)
                    entry.holder.applyHostSnapshot(entry.builder.build())
                    surface.publishSearchFocus(session, token, messageId)
                }
                is HostOperationOutcome.Rejected,
                is HostOperationOutcome.Failed ->
                    surface.publishSearchRevealFailure(session, token)
                HostOperationOutcome.Cancelled,
                HostOperationOutcome.Superseded -> Unit
            }
        }
        return true
    }

    companion object {
        private const val REFRESH_THROTTLE_MILLIS = 750L
    }
}

/** Strict-tolerant decoders for the two additive native carriers. */
internal object UserQuestionWire {
    fun decodePending(value: JsonElement): List<UserQuestionSnapshotUi>? {
        val root = value as? JsonObject ?: return null
        if (root.string("schema") != "floe.question.v1") return null
        val requests = (root["requests"] as? JsonArray) ?: return emptyList()
        return requests.mapNotNull { element ->
            decodeSnapshotElement(element as? JsonObject ?: return@mapNotNull null)
        }
    }

    fun decodeSnapshot(value: JsonElement): UserQuestionSnapshotUi? {
        return decodeSnapshotElement(value as? JsonObject ?: return null)
    }

    private fun decodeSnapshotElement(root: JsonObject): UserQuestionSnapshotUi? {
        val requestId = root.string("requestID") ?: return null
        val requestDigest = root.string("requestDigest") ?: return null
        val conversationId = root.string("conversationID") ?: return null
        val runId = root.string("runID") ?: return null
        val questions = (root["questions"] as? JsonArray)?.mapNotNull { element ->
            decodeQuestion(
                element as? JsonObject ?: return@mapNotNull null,
                requestId = requestId,
                runId = runId,
                requestDigest = requestDigest,
            )
        } ?: emptyList()
        return UserQuestionSnapshotUi(
            requestId = requestId,
            requestDigest = requestDigest,
            conversationId = conversationId,
            runId = runId,
            stateRaw = root.string("state") ?: "settled",
            isEphemeral = root.bool("isEphemeral") ?: false,
            questions = questions,
            currentQuestionId = root.string("currentQuestionID"),
        )
    }

    private fun decodeQuestion(
        root: JsonObject,
        requestId: String,
        runId: String,
        requestDigest: String,
    ): UserQuestionPromptUi? {
        val questionId = root.string("questionID") ?: return null
        if (!questionId.startsWith(requestId + ".")) return null
        val options = (root["options"] as? JsonArray)?.mapNotNull { element ->
            val option = element as? JsonObject ?: return@mapNotNull null
            val id = option.string("id") ?: return@mapNotNull null
            val label = option.string("label") ?: return@mapNotNull null
            UserQuestionOptionUi(id, label, option.string("detail"))
        } ?: emptyList()
        return UserQuestionPromptUi(
            questionId = questionId,
            requestId = requestId,
            runId = runId,
            text = root.string("text") ?: "",
            options = options,
            selectionMode = UserQuestionSelectionModeUi.from(root.string("selectionMode") ?: "single"),
            allowsFreeText = root.bool("allowsFreeText") ?: options.isEmpty(),
            waitPolicy = UserQuestionWaitPolicyUi.from(root.string("waitPolicy") ?: "required"),
            deadlineLabel = root.string("deadlineAt")?.let(::timeLabel),
            status = UserQuestionStatusUi.from(root.string("status") ?: "pending"),
            revision = root.int("revision") ?: 1,
            answerNonce = root.string("answerNonce") ?: return null,
            requestDigest = requestDigest,
            answeredLabels = (root["answer"] as? JsonObject)
                ?.get("selectedOptionIDs")?.jsonArray
                ?.mapNotNull { it.jsonPrimitive.contentOrNull }
                ?: emptyList(),
            answerSourceRaw = root.string("answerSource"),
            answerFreeText = (root["answer"] as? JsonObject)?.string("freeText"),
        )
    }

    fun decodeReceipt(value: JsonElement): UserQuestionAnswerReceiptUi? {
        val root = value as? JsonObject ?: return null
        val requestId = root.string("requestID") ?: return null
        val questionId = root.string("questionID") ?: return null
        return UserQuestionAnswerReceiptUi(
            requestId = requestId,
            questionId = questionId,
            statusRaw = root.string("status") ?: return null,
            revision = root.int("revision") ?: return null,
            accepted = root.bool("accepted") ?: false,
            alreadySettled = root.bool("alreadySettled") ?: false,
            requestStateRaw = root.string("requestState") ?: "",
            selectedLabels = (root["answer"] as? JsonObject)
                ?.get("selectedOptionLabels")?.jsonArray
                ?.mapNotNull { it.jsonPrimitive.contentOrNull }
                ?: emptyList(),
        )
    }

    fun decodeSearch(value: JsonElement): ThreadSearchResultUi? {
        val root = value as? JsonObject ?: return null
        if (root.string("schema") != "floe.threadsearch.v1") return null
        val rows = (root["rows"] as? JsonArray)?.mapNotNull { element ->
            val row = element as? JsonObject ?: return@mapNotNull null
            val messageId = row.string("messageID") ?: return@mapNotNull null
            ThreadSearchHitUi(
                messageId = messageId,
                role = when (row.string("role")) {
                    "assistant" -> MessageRoleUi.ASSISTANT
                    "user" -> MessageRoleUi.USER
                    else -> MessageRoleUi.OTHER
                },
                snippet = row.string("snippet") ?: "",
                createdAtLabel = row.string("createdAt")?.let(::timeLabel) ?: "",
            )
        } ?: emptyList()
        return ThreadSearchResultUi(
            hits = rows,
            includesDurableHistory = rows.isNotEmpty() && root.bool("isTemporary") != true,
            isTemporary = root.bool("isTemporary") ?: false,
        )
    }

    private fun timeLabel(raw: String): String = try {
        val instant = Instant.parse(raw)
        SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date.from(instant))
    } catch (_: Exception) {
        raw.take(5)
    }

    private fun JsonObject.string(key: String): String? =
        (this[key] as? JsonPrimitive)?.contentOrNull

    private fun JsonObject.bool(key: String): Boolean? =
        (this[key] as? JsonPrimitive)?.booleanOrNull

    private fun JsonObject.int(key: String): Int? =
        (this[key] as? JsonPrimitive)?.intOrNull ?: (this[key] as? JsonPrimitive)?.longOrNull?.toInt()
}
