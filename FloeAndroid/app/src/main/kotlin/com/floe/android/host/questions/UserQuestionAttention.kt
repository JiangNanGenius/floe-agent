// SPDX-License-Identifier: MPL-2.0
//
// App-owned durable question attention.
//
// The existing in-app question card and its private notification are driven
// by a live conversation holder plus a short, tool-call-anchored discovery
// window. A question registered after that window (for example a device
// handover/presence question created inside an approved background tool
// call), or one owned by a scheduled/background run with no holder at all,
// can therefore park the run with no visible affordance.
//
// This file adds NO second question store and NO answer path. It consumes the
// EXISTING durable question registration/settlement boundary (the Swift
// coordinator's lifecycle event wakes the same native change sequence the App
// already observes), re-reads the authoritative `question.pending` command,
// and projects the SAME private identifier-only reminder. Every read is
// fenced by the accepted root epoch + command-client generation + the exact
// conversation candidate generation. Settlement/terminal/stop with the
// matching request or run removes the reminder; a transient read failure
// never pretends the question disappeared. Nothing here answers, cancels,
// grants screen control or stores question text/answer content.
package com.floe.android.host.questions

import android.content.Context
import android.content.SharedPreferences
import com.floe.android.bridge.RunForegroundNative
import com.floe.android.feature.conversation.ConversationSessionToken
import com.floe.android.feature.conversation.UserQuestionSnapshotUi
import com.floe.android.host.HostCommandRequest
import com.floe.android.host.HostOperationOutcome
import com.floe.android.host.HostScope
import com.floe.android.host.RuntimeHost
import com.floe.android.runlifecycle.OperationKind
import com.floe.android.runlifecycle.RunForegroundWire
import java.time.Instant
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

/**
 * Minimal identity of one posted reminder. It deliberately has NO question
 * text, option label, answer body, credential or user prompt: only the exact
 * durable identities needed to withdraw/reconcile the correct notice.
 * [rootEpoch] fences a reminder left by an earlier accepted native root.
 */
internal data class UserQuestionAttentionRecord(
    val rootEpoch: Long,
    val conversationId: String,
    val requestId: String,
    val runId: String,
    val questionId: String,
)

/** Stable persistence/validation for the identifier-only reminder. */
internal object UserQuestionAttentionCodec {
    private const val PREFIX = "v1"
    private const val SEPARATOR = "|"

    fun encode(record: UserQuestionAttentionRecord): String? {
        val conversation = canonicalUuid(record.conversationId) ?: return null
        val run = canonicalUuid(record.runId) ?: return null
        if (record.rootEpoch < 0) return null
        if (!validRequestId(record.requestId)) return null
        if (!record.questionId.startsWith(record.requestId + ".") ||
            record.questionId.length > 200
        ) return null
        return listOf(
            PREFIX,
            record.rootEpoch.toString(),
            conversation,
            record.requestId,
            run,
            record.questionId,
        ).joinToString(SEPARATOR)
    }

    fun decode(raw: String): UserQuestionAttentionRecord? {
        if (raw.length > 512) return null
        val parts = raw.split(SEPARATOR)
        if (parts.size != 6 || parts[0] != PREFIX) return null
        val rootEpoch = parts[1].toLongOrNull() ?: return null
        if (rootEpoch < 0) return null
        val conversation = canonicalUuid(parts[2]) ?: return null
        val requestId = parts[3]
        if (!validRequestId(requestId)) return null
        val runId = canonicalUuid(parts[4]) ?: return null
        val questionId = parts[5]
        if (!questionId.startsWith(requestId + ".") || questionId.length > 200) {
            return null
        }
        return UserQuestionAttentionRecord(
            rootEpoch = rootEpoch,
            conversationId = conversation,
            requestId = requestId,
            runId = runId,
            questionId = questionId,
        )
    }

    private fun validRequestId(value: String): Boolean =
        value.length == 35 && value.startsWith("uq_") &&
            value.substring(3).all { it.isDigit() || it in 'a'..'f' }
}

/** Pure action selected from ONE authoritative read. */
internal sealed interface UserQuestionAttentionAction {
    data class Post(val snapshot: UserQuestionSnapshotUi) : UserQuestionAttentionAction
    data class Withdraw(val record: UserQuestionAttentionRecord?) :
        UserQuestionAttentionAction
    data object Keep : UserQuestionAttentionAction
}

/** Pure rules shared by the signal and its focused tests. */
internal object UserQuestionAttentionRules {
    fun actionFor(
        read: UserQuestionPendingRead,
        record: UserQuestionAttentionRecord?,
    ): UserQuestionAttentionAction = when (read) {
        is UserQuestionPendingRead.Snapshot ->
            if (read.snapshot.hasPending && !read.snapshot.isEphemeral) {
                UserQuestionAttentionAction.Post(read.snapshot)
            } else {
                UserQuestionAttentionAction.Withdraw(record)
            }
        UserQuestionPendingRead.Empty ->
            UserQuestionAttentionAction.Withdraw(record)
        // A timeout/rejection is NOT deletion proof: keep the reminder and
        // its record for the next real event.
        is UserQuestionPendingRead.Failure -> UserQuestionAttentionAction.Keep
    }

    fun recordFor(
        snapshot: UserQuestionSnapshotUi,
        rootEpoch: Long,
    ): UserQuestionAttentionRecord? {
        if (rootEpoch < 0 || snapshot.isEphemeral || !snapshot.hasPending) return null
        val conversation = canonicalUuid(snapshot.conversationId) ?: return null
        val question = snapshot.currentQuestion ?: return null
        val run = canonicalUuid(question.runId) ?: return null
        if (snapshot.requestId.isEmpty() ||
            !question.questionId.startsWith(snapshot.requestId + ".")
        ) return null
        return UserQuestionAttentionRecord(
            rootEpoch = rootEpoch,
            conversationId = conversation,
            requestId = snapshot.requestId,
            runId = run,
            questionId = question.questionId,
        )
    }

    /** A read may be applied only while its candidate incarnation is still
     * current. A removed/re-added candidate (navigation, root generation or a
     * terminal fence) gets a new generation and rejects the stale reply. */
    fun isCurrentCandidate(expectedGeneration: Long, currentGeneration: Long?): Boolean =
        currentGeneration == expectedGeneration

    fun canPost(snapshot: UserQuestionSnapshotUi?, notificationsAllowed: Boolean): Boolean =
        notificationsAllowed &&
            snapshot != null &&
            !snapshot.isEphemeral &&
            snapshot.hasPending &&
            snapshot.currentQuestion != null
}

/**
 * In-memory candidate + posted-reminder ledger. Kept free of Android types so
 * the exact fencing and settlement rules can be tested on the JVM.
 */
internal class UserQuestionAttentionLedger(
    private val maximumCandidates: Int = 24,
) {
    private data class Candidate(
        val generation: Long,
        var armedAt: Long,
        var retained: Boolean,
    )

    private val candidates = LinkedHashMap<String, Candidate>()
    private val records = LinkedHashMap<String, UserQuestionAttentionRecord>()
    private var nextGeneration = 0L

    @Synchronized
    fun ensureCandidate(
        conversationId: String,
        now: Long,
        protect: Boolean = false,
    ): Long? {
        val conversation = canonicalUuid(conversationId) ?: return null
        candidates.remove(conversation)?.let { existing ->
            existing.armedAt = now
            if (protect) existing.retained = true
            candidates[conversation] = existing
            return existing.generation
        }
        if (candidates.size >= maximumCandidates) pruneCandidatesLocked()
        val generation = ++nextGeneration
        candidates[conversation] = Candidate(generation, now, protect)
        return generation
    }

    @Synchronized
    fun candidateGeneration(conversationId: String): Long? {
        val conversation = canonicalUuid(conversationId) ?: return null
        return candidates[conversation]?.generation
    }

    @Synchronized
    fun candidateIds(): List<String> = candidates.keys.toList()

    @Synchronized
    fun hasCandidates(): Boolean = candidates.isNotEmpty()

    @Synchronized
    fun dropCandidate(conversationId: String): Boolean {
        val conversation = canonicalUuid(conversationId) ?: return false
        return candidates.remove(conversation) != null
    }

    @Synchronized
    fun record(record: UserQuestionAttentionRecord): Boolean {
        val previous = records[record.conversationId]
        if (previous == record) return false
        records[record.conversationId] = record
        return true
    }

    @Synchronized
    fun recordFor(conversationId: String): UserQuestionAttentionRecord? {
        val conversation = canonicalUuid(conversationId) ?: return null
        return records[conversation]
    }

    @Synchronized
    fun records(): List<UserQuestionAttentionRecord> = records.values.toList()

    @Synchronized
    fun hasRecords(): Boolean = records.isNotEmpty()

    @Synchronized
    fun restore(record: UserQuestionAttentionRecord): Boolean {
        val conversation = canonicalUuid(record.conversationId) ?: return false
        if (records[conversation] != null) return false
        records[conversation] = record
        return true
    }

    @Synchronized
    fun settle(
        conversationId: String,
        requestId: String,
        questionId: String? = null,
    ): UserQuestionAttentionRecord? {
        val conversation = canonicalUuid(conversationId) ?: return null
        val record = records[conversation] ?: return null
        if (record.requestId != requestId) return null
        if (questionId != null && record.questionId != questionId) return null
        records.remove(conversation)
        return record
    }

    @Synchronized
    fun settleForRun(
        conversationId: String,
        runId: String,
    ): UserQuestionAttentionRecord? {
        val conversation = canonicalUuid(conversationId) ?: return null
        val run = canonicalUuid(runId) ?: return null
        val record = records[conversation] ?: return null
        if (record.runId != run) return null
        records.remove(conversation)
        return record
    }

    @Synchronized
    fun remove(record: UserQuestionAttentionRecord): Boolean {
        if (records[record.conversationId] != record) return false
        records.remove(record.conversationId)
        return true
    }

    private fun pruneCandidatesLocked() {
        val victim = candidates.entries.firstOrNull {
            !it.value.retained && it.key !in records
        }?.key
            ?: candidates.entries.firstOrNull { !it.value.retained }?.key
            ?: candidates.keys.firstOrNull()
            ?: return
        candidates.remove(victim)
    }
}

/**
 * Application-scoped durable attention signal. It is owned by the same
 * [ConversationHostController] as the question commands, so it survives
 * holder release and navigation until the App process ends.
 */
internal class UserQuestionAttentionSignal(
    private val host: RuntimeHost,
    private val questions: UserQuestionHostController,
    private val currentSession: (String) -> ConversationSessionToken?,
) {
    private val ledger = UserQuestionAttentionLedger()
    private val started = AtomicBoolean(false)
    private val restoreCompleted = AtomicBoolean(false)
    private val lastReconcileAt = AtomicLong(0L)
    private val lastDiscoveryAt = AtomicLong(0L)
    private val reconcileMutex = Mutex()
    /** Terminal run identities still able to appear in a stale read before
     * the native question cancellation settles. A terminal run can never
     * consume an answer, so a read for it must withdraw, never re-post.
     * Entries are short-lived: a legitimate retry/resumed incarnation must
     * be able to ask again after the cancellation boundary has settled. */
    private val terminalRuns = ConcurrentHashMap<String, Long>()

    @Volatile
    private var prefs: SharedPreferences? = null

    fun start() {
        if (!started.compareAndSet(false, true)) return
        host.scope.launch(host.ioDispatcher) {
            // The RuntimeHost is constructed before its Application context
            // is attached, so a readiness/context wait here is expected and
            // bounded by the process, not by UI visibility.
            while (currentCoroutineContext().isActive && host.appContextOrNull == null) {
                delay(CONTEXT_WAIT_MILLIS)
            }
            if (!currentCoroutineContext().isActive) return@launch
            // Restore the identifier-only reminder ledger immediately so a
            // process restart withdraws a stale OS notice even when no run
            // or native change follows.
            host.appContextOrNull?.let { context ->
                ensurePreferences(context)
                requestReconcile(force = true)
            }
            var observed = 0L
            var lastFallback = 0L
            while (currentCoroutineContext().isActive) {
                val changed = try {
                    RunForegroundNative.waitChange(observed, CHANGE_WAIT_MILLIS)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Throwable) {
                    delay(CHANGE_WAIT_MILLIS.toLong())
                    continue
                }
                val now = System.currentTimeMillis()
                if (changed != observed) {
                    // Includes the wired question `.presented`/`.settled`
                    // lifecycle event and every real run/tool ledger change.
                    observed = changed
                    requestReconcile(force = false)
                } else if (!ledger.hasCandidates() && !ledger.hasRecords() &&
                    now - lastFallback < FALLBACK_RECONCILE_MILLIS
                ) {
                    continue
                } else if (now - lastFallback >= FALLBACK_RECONCILE_MILLIS) {
                    // Bounded fallback for a lost native wake; it never
                    // fabricates a question and never answers/cancels.
                    lastFallback = now
                    requestReconcile(force = false)
                }
            }
        }
    }

    /** Visible holder published the authoritative snapshot. */
    fun present(session: ConversationSessionToken, snapshot: UserQuestionSnapshotUi?) {
        val conversation = canonicalUuid(session.conversationId) ?: return
        if (snapshot != null && canonicalUuid(snapshot.conversationId) != conversation) {
            return
        }
        if (snapshot == null) {
            host.appContextOrNull?.let { ensurePreferences(it) }
            val record = ledger.recordFor(conversation)
            if (record != null) {
                withdrawRecord(record)
            } else {
                // A prior process may have posted the reminder; this holder
                // refresh is authoritative that no pending question remains.
                host.appContextOrNull?.let { UserQuestionNotifications.cancelIfUntracked(it, conversation) }
            }
            return
        }
        if (!snapshot.hasPending || snapshot.isEphemeral) {
            host.appContextOrNull?.let { ensurePreferences(it) }
            // A settled snapshot withdraws only ITS OWN reminder. Another
            // request in the same conversation may still be pending and must
            // keep its notification.
            val record = ledger.recordFor(conversation)
            if (record != null && record.requestId == snapshot.requestId) {
                withdrawRecord(record)
            }
            return
        }
        val context = host.appContextOrNull ?: return
        ensurePreferences(context)
        val rootEpoch = host.nativeRootEpoch() ?: return
        val record = UserQuestionAttentionRules.recordFor(snapshot, rootEpoch) ?: return
        if (isTerminalRun(record.conversationId, record.runId)) {
            ledger.recordFor(record.conversationId)
                ?.takeIf { it.requestId == record.requestId }
                ?.let { withdrawRecord(it) }
            return
        }
        ledger.ensureCandidate(conversation, System.currentTimeMillis(), protect = true)
        if (!UserQuestionNotifications.notificationsAllowed(context)) return
        val posted = UserQuestionNotifications.postQuestion(
            context, session.conversationId, snapshot, session)
        if (!posted) return
        if (ledger.record(record)) persistAll()
    }

    /** Exact receipt/answer/cancel surface settlement. */
    fun settled(
        session: ConversationSessionToken,
        requestId: String,
        questionId: String? = null,
    ) {
        val conversation = canonicalUuid(session.conversationId) ?: return
        ledger.settle(conversation, requestId, questionId)?.let { withdrawRecord(it) }
        requestReconcile(force = true)
    }

    /** Terminal run fence: a terminal run can no longer consume an answer. */
    fun runTerminal(conversationId: String, runId: String) {
        val conversation = canonicalUuid(conversationId) ?: return
        val run = canonicalUuid(runId) ?: return
        rememberTerminalRun(conversation, run)
        ledger.settleForRun(conversation, run)?.let { withdrawRecord(it) }
        requestReconcile(force = true)
    }

    /** Holder release/navigation is NOT settlement: the reminder remains
     * until the authoritative read or a real settlement says otherwise. */
    fun onSurfaceReleased(conversationId: String) {
        val conversation = canonicalUuid(conversationId) ?: return
        ledger.ensureCandidate(conversation, System.currentTimeMillis(), protect = true)
        requestReconcile(force = true)
    }

    /** The conversation itself was deleted: no pending question can survive
     * the durable row's cascade, so withdraw the reminder without waiting for
     * another read. */
    fun onConversationDeleted(conversationId: String) {
        val conversation = canonicalUuid(conversationId) ?: return
        host.appContextOrNull?.let { context ->
            ensurePreferences(context)
            UserQuestionNotifications.cancel(context, conversation)
        }
        ledger.recordFor(conversation)?.let(ledger::remove)
        ledger.dropCandidate(conversation)
        terminalRuns.keys.filter { it.startsWith("$conversation/") }
            .forEach { terminalRuns.remove(it) }
        persistAll()
    }

    /** New question-capable work was observed for this conversation. */
    fun arm(conversationId: String) {
        val conversation = canonicalUuid(conversationId) ?: return
        // New question-capable work in this conversation supersedes an older
        // terminal fence (for example the same run id's retry incarnation).
        terminalRuns.keys.filter { it.startsWith("$conversation/") }
            .forEach { terminalRuns.remove(it) }
        ledger.ensureCandidate(conversation, System.currentTimeMillis(), protect = true)
        requestReconcile(force = false)
    }

    private fun requestReconcile(force: Boolean) {
        if (!force) {
            if (!hasWorkToWatch()) return
            if (System.currentTimeMillis() - lastReconcileAt.get() <
                MIN_RECONCILE_INTERVAL_MILLIS
            ) return
        }
        host.scope.launch(host.ioDispatcher) {
            if (!reconcileMutex.tryLock()) return@launch
            try {
                val now = System.currentTimeMillis()
                val previous = lastReconcileAt.get()
                if (!force && now - previous < MIN_RECONCILE_INTERVAL_MILLIS) {
                    return@launch
                }
                if (!lastReconcileAt.compareAndSet(previous, now)) return@launch
                reconcileOnce()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                // Transport/read failure: keep the existing reminder and its
                // record; the next real event retries the authoritative read.
            } finally {
                reconcileMutex.unlock()
            }
        }
    }

    private fun hasWorkToWatch(): Boolean =
        ledger.hasCandidates() || ledger.hasRecords() || hasLiveAgentRun()

    private fun hasLiveAgentRun(): Boolean {
        if (host.runForeground?.heldOperationKinds()?.contains(OperationKind.AGENT_RUN) == true) return true
        // Foreground-service acquisition can fail while an admitted run is
        // still executing. The native owned-work ledger is separate from the
        // Android service lease; unknown or a different root is not proof.
        val live = runCatching { RunForegroundWire.parse(RunForegroundNative.snapshot()) }.getOrNull()
        return live != null && live.nativeRootEpoch == host.nativeRootEpoch() &&
            live.storeReady && !live.admissionFenced && live.hasLiveRunOwnedWork
    }

    private suspend fun reconcileOnce() {
        val context = host.appContextOrNull ?: return
        ensurePreferences(context)
        val rootEpoch = host.nativeRootEpoch()
        if (rootEpoch == null) {
            // Context can precede native bootstrap. An unknown epoch is not
            // proof that a pending question has settled or its root retired.
            return
        }
        if (!host.readiness.value.conversationDomainAdmitted) return
        val clientGeneration = host.commandClient.generation()
        if (!hasWorkToWatch()) return

        withdrawForeignRootRecords(context, rootEpoch)
        if (hasLiveAgentRun()) {
            discoverRecentConversations(rootEpoch, clientGeneration)
        }
        for (conversationId in ledger.candidateIds()) {
            if (!isCurrent(rootEpoch, clientGeneration)) return
            val candidateGeneration = ledger.candidateGeneration(conversationId) ?: continue
            val read = readPending(conversationId)
            if (!isCurrent(rootEpoch, clientGeneration)) return
            if (!UserQuestionAttentionRules.isCurrentCandidate(
                    candidateGeneration,
                    ledger.candidateGeneration(conversationId),
                )
            ) continue
            when (val action = UserQuestionAttentionRules.actionFor(
                read,
                ledger.recordFor(conversationId),
            )) {
                is UserQuestionAttentionAction.Post ->
                    postFromRead(context, conversationId, action.snapshot, rootEpoch)
                is UserQuestionAttentionAction.Withdraw ->
                    withdrawAuthoritative(context, conversationId)
                UserQuestionAttentionAction.Keep -> Unit
            }
        }
        if (!hasLiveAgentRun() && !ledger.hasRecords()) {
            ledger.candidateIds().forEach { ledger.dropCandidate(it) }
        }
    }

    private fun isCurrent(rootEpoch: Long, clientGeneration: Long): Boolean =
        host.readiness.value.conversationDomainAdmitted &&
            host.nativeRootEpoch() == rootEpoch &&
            host.commandClient.generation() == clientGeneration

    private suspend fun discoverRecentConversations(
        rootEpoch: Long,
        clientGeneration: Long,
    ) {
        val now = System.currentTimeMillis()
        if (ledger.hasCandidates() &&
            now - lastDiscoveryAt.get() < DISCOVERY_INTERVAL_MILLIS
        ) return
        val ids = readRecentConversationIds(rootEpoch, clientGeneration) ?: return
        lastDiscoveryAt.set(now)
        // Insert oldest -> newest so bounded capacity prunes older candidates.
        ids.asReversed().forEach { ledger.ensureCandidate(it, now) }
    }

    private suspend fun readRecentConversationIds(
        rootEpoch: Long,
        clientGeneration: Long,
    ): List<String>? {
        val deferred = CompletableDeferred<List<String>?>()
        host.trackOperation(
            HostCommandRequest(
                command = "conversation.list",
                scope = HostScope.ApplicationConfiguration("conversations"),
                stateful = false,
                correlationID = host.commandClient.correlationID("qwatch-list"),
                payload = JsonObject(
                    mapOf(
                        "includeArchived" to JsonPrimitive(true),
                        "limit" to JsonPrimitive(RECENT_CONVERSATION_LIMIT),
                    ),
                ),
            ),
        ) { outcome ->
            if (!isCurrent(rootEpoch, clientGeneration)) {
                deferred.complete(null)
                return@trackOperation
            }
            val value = (outcome as? HostOperationOutcome.Completed)?.value
            deferred.complete(value?.let { recentConversationIds(it) })
        }
        return withTimeoutOrNull(READ_TIMEOUT_MILLIS) { deferred.await() }
    }

    /**
     * The list page is ordered pinned-first, so a pinned old task can sit
     * ahead of the active background run. Sort this bounded page by its RAW
     * persisted updatedAt and keep only the newest conversations. This first
     * bounded page cannot guarantee discovery of every active conversation.
     */
    private fun recentConversationIds(value: JsonElement): List<String>? {
        val root = value as? JsonObject ?: return null
        val rows = root["rows"] as? JsonArray ?: return emptyList()
        return rows.mapNotNull { element ->
            val row = element as? JsonObject ?: return@mapNotNull null
            val id = canonicalUuid(
                (row["conversationID"] as? JsonPrimitive)?.contentOrNull,
            ) ?: return@mapNotNull null
            val rawUpdated = (row["updatedAt"] as? JsonPrimitive)?.contentOrNull
            val at = runCatching {
                rawUpdated?.let { Instant.parse(it) }
            }.getOrNull()?.toEpochMilli() ?: 0L
            id to at
        }
            .sortedByDescending { it.second }
            .take(RECENT_CANDIDATE_LIMIT)
            .map { it.first }
    }

    private suspend fun readPending(conversationId: String): UserQuestionPendingRead {
        val deferred = CompletableDeferred<UserQuestionPendingRead>()
        if (!questions.readPending(conversationId) { deferred.complete(it) }) {
            return UserQuestionPendingRead.Failure(null)
        }
        return withTimeoutOrNull(READ_TIMEOUT_MILLIS) { deferred.await() }
            ?: UserQuestionPendingRead.Failure("timeout")
    }

    private fun postFromRead(
        context: Context,
        conversationId: String,
        snapshot: UserQuestionSnapshotUi,
        rootEpoch: Long,
    ) {
        if (host.nativeRootEpoch() != rootEpoch ||
            !host.readiness.value.conversationDomainAdmitted
        ) return
        val record = UserQuestionAttentionRules.recordFor(snapshot, rootEpoch) ?: return
        if (record.conversationId != canonicalUuid(conversationId)) return
        if (isTerminalRun(record.conversationId, record.runId)) {
            withdrawAuthoritative(context, conversationId)
            return
        }
        val session = currentSession(conversationId)
        val posted = UserQuestionNotifications.postQuestion(
            context = context,
            conversationId = conversationId,
            snapshot = snapshot,
            replySession = session,
        )
        if (!posted) return
        if (ledger.record(record)) persistAll()
    }

    private fun withdrawAuthoritative(context: Context, conversationId: String) {
        val record = ledger.recordFor(conversationId)
        if (record != null) {
            withdrawRecord(record)
            return
        }
        // The authoritative read says no active question remains. A reminder
        // posted by an earlier process may have lost its local record (for
        // example after data cleanup); the exact conversation identity is
        // still authority to withdraw it.
        UserQuestionNotifications.cancelIfUntracked(context, conversationId)
        if (!hasLiveAgentRun()) ledger.dropCandidate(conversationId)
    }

    private fun withdrawRecord(record: UserQuestionAttentionRecord) {
        val context = host.appContextOrNull
        if (context == null) {
            ledger.remove(record)
            persistAll()
            return
        }
        val tracked = UserQuestionNotifications.postedRequestId(record.conversationId)
        when {
            tracked == null -> {
                // OS notice may survive process death; an authoritative
                // empty/settlement read is the permission to withdraw it.
                UserQuestionNotifications.cancelIfUntracked(context, record.conversationId)
            }
            tracked == record.requestId -> {
                UserQuestionNotifications.cancelIfCurrent(
                    context = context,
                    conversationId = record.conversationId,
                    requestId = record.requestId,
                    questionId = record.questionId,
                )
            }
            else -> Unit // a newer question's reminder owns the notification.
        }
        ledger.remove(record)
        persistAll()
    }

    private fun isTerminalRun(conversationId: String, runId: String): Boolean {
        val key = "$conversationId/$runId"
        val expiresAt = terminalRuns[key] ?: return false
        if (expiresAt <= System.currentTimeMillis()) {
            terminalRuns.remove(key, expiresAt)
            return false
        }
        return true
    }

    private fun rememberTerminalRun(conversationId: String, runId: String) {
        val now = System.currentTimeMillis()
        terminalRuns.keys.filter { key ->
            (terminalRuns[key] ?: Long.MAX_VALUE) <= now
        }.forEach { terminalRuns.remove(it) }
        terminalRuns["$conversationId/$runId"] = now + TERMINAL_FENCE_MILLIS
    }

    private fun withdrawForeignRootRecords(context: Context, rootEpoch: Long) {
        for (record in ledger.records()) {
            if (record.rootEpoch != rootEpoch) withdrawRecord(record)
        }
    }

    private fun ensurePreferences(context: Context) {
        if (prefs == null) {
            synchronized(this) {
                if (prefs == null) {
                    prefs = context.applicationContext.getSharedPreferences(
                        PREFERENCES_NAME, Context.MODE_PRIVATE)
                }
            }
        }
        if (restoreCompleted.compareAndSet(false, true)) {
            restorePersistedRecords()
        }
    }

    private fun restorePersistedRecords() {
        val preferences = prefs ?: return
        val raw = synchronized(this) {
            preferences.getStringSet(KEY_RECORDS, emptySet())?.toList().orEmpty()
        }
        var changed = false
        for (entry in raw) {
            val record = UserQuestionAttentionCodec.decode(entry) ?: continue
            if (ledger.restore(record)) {
                ledger.ensureCandidate(record.conversationId, System.currentTimeMillis(), protect = true)
                changed = true
            }
        }
        if (changed) requestReconcile(force = true)
    }

    private fun persistAll() {
        val preferences = prefs ?: return
        synchronized(this) {
            val entries = ledger.records()
                .mapNotNull(UserQuestionAttentionCodec::encode)
                .toSet()
            preferences.edit().putStringSet(KEY_RECORDS, entries).apply()
        }
    }

    companion object {
        private const val PREFERENCES_NAME = "floe.question.attention.v1"
        private const val KEY_RECORDS = "records"
        private const val CHANGE_WAIT_MILLIS = 1_000
        private const val CONTEXT_WAIT_MILLIS = 250L
        // The coordinator emits `.presented` immediately before its parked
        // continuation becomes visible to `question.pending`; the bounded
        // fallback re-read covers that short window and a lost native wake
        // without treating an early empty read as permanent.
        private const val FALLBACK_RECONCILE_MILLIS = 3_000L
        private const val MIN_RECONCILE_INTERVAL_MILLIS = 2_500L
        private const val DISCOVERY_INTERVAL_MILLIS = 15_000L
        private const val READ_TIMEOUT_MILLIS = 6_000L
        private const val RECENT_CONVERSATION_LIMIT = 50
        private const val RECENT_CANDIDATE_LIMIT = 12
        private const val TERMINAL_FENCE_MILLIS = 30_000L
    }
}

internal fun canonicalUuid(raw: String?): String? {
    if (raw.isNullOrEmpty()) return null
    return runCatching { UUID.fromString(raw).toString() }.getOrNull()
}
