// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import android.content.Context
import com.floe.android.bridge.TerminalNative
import com.floe.android.feature.terminal.G04TerminalEngine
import com.floe.android.feature.terminal.TerminalEngineHost
import com.floe.android.feature.terminal.TerminalTransport
import java.util.Base64
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.isActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/* ---------------- public values ---------------- */

data class TerminalHostAvailability(
    val bound: Boolean,
    val qualified: Boolean,
    val workspaceAttached: Boolean,
    val capabilitiesKnown: Boolean,
)

enum class TerminalSessionPhase { CLOSED, STARTING, RUNNING, WAITING_OUTPUT, EXITED, STOPPED, FAULT }

data class TerminalSessionSnapshot(
    val conversationID: String,
    val sessionToken: String,
    val phase: TerminalSessionPhase,
    val purpose: String,
    val runID: String,
    val exitCode: Int?,
    val stopReason: String?,
    val faultCode: String?,
    val rolledOverBytes: Int,
)

sealed class TerminalActionReply {
    data class Success(val fields: JsonObject) : TerminalActionReply()
    data class Refused(val code: String, val reason: String?) : TerminalActionReply()
    data object TimedOut : TerminalActionReply()
}

data class TerminalCompletionItem(
    val label: String,
    val insertText: String,
    val kind: Int,
    val detail: String,
    val documentation: String,
)

data class TerminalCompletionSnapshot(
    val requestID: String,
    val documentID: String,
    val revision: String,
    val items: List<TerminalCompletionItem>,
    val incomplete: Boolean,
    val truncated: Boolean,
)

data class TerminalDiagnosticItem(
    val startLine: Int, val startCharacter: Int,
    val endLine: Int, val endCharacter: Int,
    /** 1 error, 2 warning, 3 info, 4 hint (LSP severities, unchanged). */
    val severity: Int,
    val message: String,
    val source: String,
)

data class TerminalDiagnosticsSnapshot(
    val conversationID: String,
    val workspaceID: String,
    val documentID: String,
    val relativePath: String,
    /** EXACT native revision fence; stale projections must discard. */
    val revision: String,
    val lspVersion: Int,
    val items: List<TerminalDiagnosticItem>,
    val truncated: Boolean,
)

data class TerminalLanguageStatus(
    val conversationID: String,
    val language: String,
    /** idle|starting|ready|stopping|stopped|unavailable|failed */
    val state: String,
    val code: String?,
)

/** ACTUAL per-language runtime state of one live native server session.
 * Never inferred from catalog presence. */
data class TerminalLanguageRuntimeState(val state: String, val code: String?)

/** The durable settings + real availability snapshot the native center
 * answers on every capabilities read: persisted user choices (settingsKnown
 * says whether the durable read actually succeeded), and the live server
 * states for the queried conversation. */
data class TerminalLanguageCapabilities(
    val qualified: Boolean,
    val workspaceAttached: Boolean,
    val settingsKnown: Boolean,
    val settingsRevision: Long,
    val enabled: Map<String, Boolean>,
    val serverStates: Map<String, TerminalLanguageRuntimeState>,
)

/* ---------------- the controller ---------------- */

/**
 * Application-owned transport + presentation bridge for the embedded
 * terminal and LSP domain (job-dda32d23d55e4460). One Root generation owns
 * one serialized claim loop over the trusted `TerminalNative` mailbox
 * (same reviewed shape as LinuxShellPump/WorkspaceSourcePump).
 *
 * Ownership discipline (honest, no parallel systems):
 *  * The Swift domain (`G04TerminalStore` / `G04LanguageServerCenter`) over
 *    the ORIGINAL services stays the session, engine, workspace, revision
 *    and settlement authority. This class routes bounded actions and raw
 *    output; it holds no document state and decides nothing durable.
 *  * Engines/renders are kept per conversation HERE (service-owned), so a
 *    pane being reconstructed, dismissed or route-navigated NEVER stops a
 *    process or a session: only explicit close, task deletion or Root
 *    retirement settles sessions (native-side), and listeners are the only
 *    view-scoped resources the pane owns.
 *  * No MainActor-style UI thread ever blocks on a native call: the claim
 *    loop runs on IO; output is delivered FIFO onto Main; request/reply
 *    waits are suspend timeouts (a host-side timeout only requests
 *    `$/cancelRequest`/reconciliation and never fabricates completion).
 */
internal class G04TerminalHostController(
    private val scope: CoroutineScope,
    private val currentNativeEpoch: () -> Long?,
) {
    private val json = Json { ignoreUnknownKeys = true }
    private val starts = Mutex()
    private val stopped = AtomicBoolean(true)

    @Volatile private var boundEpoch: Long = 0L
    private var reader: Job? = null

    /** requestID -> reply future for submit()/actionReply routing. */
    private val replies = ConcurrentHashMap<String, CompletableDeferred<TerminalActionReply>>()
    /** requestID -> completion future for lspCompletion results. */
    private val completions = ConcurrentHashMap<String, CompletableDeferred<TerminalCompletionSnapshot?>>()

    private val sessionTokens = ConcurrentHashMap<String, String>()          // conversationID -> token
    private val outputListeners = ConcurrentHashMap<String, MutableSet<(ByteArray) -> Unit>>() // token -> listeners
    private val engines = ConcurrentHashMap<String, G04TerminalEngine>()
    private val snapshots = ConcurrentHashMap<String, TerminalSessionSnapshot>()

    @Volatile private var availability = TerminalHostAvailability(
        bound = false, qualified = false, workspaceAttached = false, capabilitiesKnown = false)
    @Volatile private var onTerminalStatus: ((TerminalSessionSnapshot) -> Unit)? = null
    private val sessionWatchers = ConcurrentHashMap<String, MutableSet<(TerminalSessionSnapshot) -> Unit>>()
    @Volatile private var onDiagnostics: ((TerminalDiagnosticsSnapshot) -> Unit)? = null
    private val diagnosticListeners = java.util.concurrent.CopyOnWriteArraySet<(TerminalDiagnosticsSnapshot) -> Unit>()
    @Volatile private var onLanguageStatus: ((TerminalLanguageStatus) -> Unit)? = null
    /** Multi-subscriber language status (same reviewed pattern as Main's
     * diagnostics fix): a settings sheet and any future consumer co-own. */
    private val languageStatusListeners = java.util.concurrent.CopyOnWriteArraySet<(TerminalLanguageStatus) -> Unit>()
    /** Mirrors ONLY answers the native center actually committed; an
     * unknown durable state is `settingsKnown == false`, never a guess. */
    @Volatile private var languageCapabilities = TerminalLanguageCapabilities(
        qualified = false, workspaceAttached = false, settingsKnown = false,
        settingsRevision = -1L, enabled = emptyMap(), serverStates = emptyMap())

    /** Pane-scoped observation of one conversation's authoritative session
     * snapshot. The watcher set/unset is the ONLY view-scoped registration;
     * detaching never touches the native session. */
    fun watchSessions(conversationID: String, watcher: (TerminalSessionSnapshot) -> Unit): () -> Unit {
        val set = sessionWatchers.getOrPut(conversationID) { java.util.concurrent.CopyOnWriteArraySet() }
        set.add(watcher)
        snapshots[conversationID]?.let { watcher(it) }
        return { set.remove(watcher); if (set.isEmpty()) sessionWatchers.remove(conversationID) }
    }

    fun currentSnapshot(conversationID: String): TerminalSessionSnapshot? = snapshots[conversationID]

    fun setDiagnosticsListener(listener: ((TerminalDiagnosticsSnapshot) -> Unit)?) { onDiagnostics = listener }
    fun addDiagnosticsListener(listener: (TerminalDiagnosticsSnapshot) -> Unit): () -> Unit {
        diagnosticListeners.add(listener)
        return { diagnosticListeners.remove(listener) }
    }

    fun setLanguageStatusListener(listener: ((TerminalLanguageStatus) -> Unit)?) { onLanguageStatus = listener }
    fun setTerminalStatusListener(listener: ((TerminalSessionSnapshot) -> Unit)?) { onTerminalStatus = listener }

    /** Pane-scoped language status subscription; detaching removes ONLY
     * the listener (never a session or server side effect). */
    fun addLanguageStatusListener(listener: (TerminalLanguageStatus) -> Unit): () -> Unit {
        languageStatusListeners.add(listener)
        return { languageStatusListeners.remove(listener) }
    }

    /** The projected durable choices + last conversation server states. */
    fun languageSettingsSnapshot(): TerminalLanguageCapabilities = languageCapabilities

    /** Known-disabled is the ONLY false answer; unknown settings never
     * block capability (honest pass-through, native re-validates). */
    fun isLanguageEnabled(language: String): Boolean = languageCapabilities.enabled[language] != false

    val boundNativeEpoch: Long get() = boundEpoch
    fun availability(): TerminalHostAvailability = availability

    /* ---------------- lifecycle ---------------- */

    fun start(epoch: Long): Boolean {
        if (epoch <= 0 || currentNativeEpoch() != epoch) return false
        val previous = synchronized(this) { reader?.takeIf { it.isActive && boundEpoch == epoch } }
        if (previous != null) return true
        val bound = try { TerminalNative.bindEpoch(epoch) == 0 } catch (_: LinkageError) { false }
        if (!bound) return false
        boundEpoch = epoch
        stopped.set(false)
        reader = scope.launch(Dispatchers.IO) {
            try {
                while (isActive && !stopped.get() && currentNativeEpoch() == epoch) {
                    val event = TerminalNative.next(200)
                    if (event < 0) { delay(20); continue }
                    if (event == 0L) continue
                    try {
                        if (TerminalNative.describe(event)?.let { handleEvent(event, it) } != true) {
                            // malformed descriptor: still ack (bounded loss is
                            // counted natively; nothing re-delivers).
                        }
                    } finally {
                        try { TerminalNative.ack(event) } catch (_: LinkageError) { }
                    }
                }
            } finally {
                withContext(NonCancellable + Dispatchers.IO) {
                    stopped.set(true)
                    fencePending()
                    try { TerminalNative.close(epoch) } catch (_: LinkageError) { }
                    boundEpoch = 0
                }
            }
        }
        scope.launch(Dispatchers.IO) { refreshCapabilities() }
        return true
    }

    /** False means the old generation remains owned/pending; never replaced
     * or declared stopped merely because a wait expired. */
    suspend fun stopAndJoin(expectedEpoch: Long, waitMillis: Long): Boolean = starts.withLock {
        if (boundEpoch != expectedEpoch) return@withLock boundEpoch == 0L
        stopped.set(true)
        val joined = withTimeoutOrNull(waitMillis) { reader?.join(); true } ?: false
        if (!joined) return@withLock false
        reader = null
        fencePending()
        true
    }

    private fun fencePending() {
        val pendingReplies = replies.values.toList()
        replies.clear()
        pendingReplies.forEach { it.complete(TerminalActionReply.Refused("hostFenced", null)) }
        val pendingCompletions = completions.values.toList()
        completions.clear()
        pendingCompletions.forEach { it.complete(null) }
        availability = availability.copy(bound = false, capabilitiesKnown = false)
    }

    /* ---------------- capabilities ---------------- */

    suspend fun refreshCapabilities() {
        if (boundEpoch == 0L) {
            availability = TerminalHostAvailability(false, false, false, false)
            languageCapabilities = languageCapabilities.copy(settingsKnown = false, serverStates = emptyMap())
            return
        }
        capabilitiesFor(conversationID = null)
    }

    /** One bounded capabilities read. With a conversation it ALSO returns
     * the ACTUAL live server states for that conversation, so the settings
     * surface refreshes after Linux qualification/installation instead of
     * staying pinned to one cold read. A failed/timed-out read changes only
     * `capabilitiesKnown`, never the last committed durable mirror. */
    suspend fun capabilitiesFor(conversationID: String?): TerminalLanguageCapabilities? {
        if (boundEpoch == 0L) {
            availability = TerminalHostAvailability(false, false, false, false)
            return null
        }
        val reply = submit(buildJsonObject {
            put("action", "capabilities")
            conversationID?.let { put("conversationID", it) }
            put("requestID", UUID.randomUUID().toString())
        }, timeoutMillis = 5_000)
        if (reply !is TerminalActionReply.Success) {
            availability = TerminalHostAvailability(bound = true, qualified = false,
                workspaceAttached = false, capabilitiesKnown = false)
            return null
        }
        availability = TerminalHostAvailability(
            bound = true,
            qualified = reply.fields["qualified"] flag true,
            workspaceAttached = reply.fields["attached"] flag true,
            capabilitiesKnown = true,
        )
        val parsed = parseLanguageCapabilities(reply.fields)
        languageCapabilities = if (conversationID != null) parsed else languageCapabilities.copy(
            qualified = parsed.qualified, workspaceAttached = parsed.workspaceAttached,
            settingsKnown = parsed.settingsKnown, settingsRevision = parsed.settingsRevision,
            enabled = parsed.enabled)
        return languageCapabilities
    }

    internal fun parseLanguageCapabilities(fields: JsonObject): TerminalLanguageCapabilities {
        val enabled = (fields["languageEnabled"] as? JsonObject)
            ?.mapNotNull { (key, value) ->
                (value as? JsonPrimitive)?.booleanOrNull?.let { key to it }
            }?.toMap() ?: emptyMap()
        val states = (fields["serverStates"] as? JsonArray)
            ?.mapNotNull { element ->
                val row = element as? JsonObject ?: return@mapNotNull null
                val language = row["language"]?.jsonPrimitive?.contentOrNull ?: return@mapNotNull null
                val state = row["state"]?.jsonPrimitive?.contentOrNull ?: return@mapNotNull null
                language to TerminalLanguageRuntimeState(
                    state, row["code"]?.jsonPrimitive?.contentOrNull?.takeIf { it.isNotEmpty() })
            }?.toMap() ?: emptyMap()
        return TerminalLanguageCapabilities(
            qualified = fields["qualified"] flag false,
            workspaceAttached = fields["attached"] flag false,
            settingsKnown = fields["settingsKnown"] flag false,
            settingsRevision = fields["settingsRevision"]?.jsonPrimitive?.longOrNull ?: -1L,
            enabled = enabled,
            serverStates = states,
        )
    }

    /* ---------------- terminal actions ---------------- */

    /** Engine registry: one reused emulator per conversation, surviving
     * every pane reconstruction (the session may or may not be open; the
     * emulator keeps the screen state). */
    fun engineFor(conversationID: String, columns: Int = 80, rows: Int = 24): G04TerminalEngine =
        engines.getOrPut(conversationID) {
            G04TerminalEngine(columns, rows, host = object : TerminalEngineHost {
                override fun writeToPty(bytes: ByteArray) {
                    val token = sessionTokens[conversationID] ?: return
                    scope.launch(Dispatchers.IO) {
                        submit(buildJsonObject {
                            put("action", "terminalInput")
                            put("sessionToken", token)
                            put("data", Base64.getEncoder().encodeToString(bytes))
                            put("requestID", UUID.randomUUID().toString())
                        }, timeoutMillis = 6_000)
                    }
                }
                override fun log(level: String, message: String) {
                    android.util.Log.println(logPriority(level), "FloeTerminal", message.take(2048))
                }
            })
        }

    private fun logPriority(level: String): Int = when (level) {
        "error" -> android.util.Log.ERROR; "warn" -> android.util.Log.WARN
        "info" -> android.util.Log.INFO; else -> android.util.Log.DEBUG
    }

    /** Transport handed to the view: writes + true native resize. */
    fun transportFor(conversationID: String): TerminalTransport = object : TerminalTransport {
        override fun write(bytes: ByteArray) {
            val token = sessionTokens[conversationID] ?: return
            scope.launch(Dispatchers.IO) {
                submit(buildJsonObject {
                    put("action", "terminalInput")
                    put("sessionToken", token)
                    put("data", Base64.getEncoder().encodeToString(bytes))
                    put("requestID", UUID.randomUUID().toString())
                }, timeoutMillis = 6_000)
            }
        }

        override fun resize(columns: Int, rows: Int) {
            val token = sessionTokens[conversationID] ?: return
            scope.launch(Dispatchers.IO) {
                submit(buildJsonObject {
                    put("action", "terminalResize")
                    put("sessionToken", token)
                    put("columns", columns); put("rows", rows)
                    put("requestID", UUID.randomUUID().toString())
                }, timeoutMillis = 6_000)
            }
        }
    }

    /** Attaches the conversation's view to its service-owned session: an
     * existing live session is NEVER restarted here (startIfNeeded
     * semantics from the original iOS owner). */
    suspend fun attachOrOpen(conversationID: String, workspaceID: String?,
                             columns: Int, rows: Int): TerminalSessionSnapshot? {
        val token = sessionTokens[conversationID]
        if (token != null && snapshots[conversationID]?.phase?.isLive() == true) {
            val requestID = UUID.randomUUID().toString()
            submit(buildJsonObject {
                put("action", "terminalAttach"); put("sessionToken", token); put("requestID", requestID)
            }, timeoutMillis = 10_000)
            return snapshots[conversationID]
        }
        val requestID = UUID.randomUUID().toString()
        val reply = submit(buildJsonObject {
            put("action", "terminalOpen")
            put("conversationID", conversationID)
            workspaceID?.let { put("workspaceID", it) }
            put("columns", columns); put("rows", rows); put("requestID", requestID)
        }, timeoutMillis = 165_000)
        if (reply is TerminalActionReply.Success) {
            val newToken = reply.fields["sessionToken"]?.jsonPrimitive?.contentOrNull
            if (newToken != null) {
                sessionTokens[conversationID] = newToken
                // Seed the view state; the native terminalStatus event for
                // this session arrives immediately and replaces it with the
                // authoritative phase (never a silent fake "running").
                snapshots.putIfAbsent(conversationID, TerminalSessionSnapshot(
                    conversationID, newToken, TerminalSessionPhase.STARTING, "interactive", "",
                    null, null, null, 0))
            }
        }
        return snapshots[conversationID]
    }

    suspend fun closeSession(conversationID: String): TerminalActionReply {
        val token = sessionTokens[conversationID] ?: return TerminalActionReply.Refused("sessionUnknown", null)
        val reply = submit(buildJsonObject {
            put("action", "terminalClose")
            put("sessionToken", token)
            put("requestID", UUID.randomUUID().toString())
        }, timeoutMillis = 20_000)
        // A timeout/refusal does not prove native session release. Retain
        // the captured handle for reconciliation; never remove a replacement.
        if (reply is TerminalActionReply.Success) {
            sessionTokens.remove(conversationID, token)
        }
        return reply
    }

    suspend fun interrupt(conversationID: String): TerminalActionReply {
        val token = sessionTokens[conversationID] ?: return TerminalActionReply.Refused("sessionUnknown", null)
        return submit(buildJsonObject {
            put("action", "terminalInterrupt")
            put("sessionToken", token)
            put("requestID", UUID.randomUUID().toString())
        }, timeoutMillis = 6_000)
    }

    /** Sends raw bytes as ordered PTY input (IME commits from the view go
     * through the transport; this path is for explicit control bytes). */
    suspend fun sendRaw(conversationID: String, bytes: ByteArray): TerminalActionReply {
        val token = sessionTokens[conversationID] ?: return TerminalActionReply.Refused("sessionUnknown", null)
        return submit(buildJsonObject {
            put("action", "terminalInput")
            put("sessionToken", token)
            put("data", Base64.getEncoder().encodeToString(bytes))
            put("requestID", UUID.randomUUID().toString())
        }, timeoutMillis = 6_000)
    }

    /** Registers an output listener for one session token; delivered FIFO
     * on the Main dispatcher. Returns the unregister hook (pane-owned,
     * disposed with the view — the ONLY view-scoped resource). */
    fun addOutputListener(sessionToken: String, listener: (ByteArray) -> Unit): () -> Unit {
        val listeners = outputListeners.getOrPut(sessionToken) {
            java.util.concurrent.CopyOnWriteArraySet()
        }
        listeners.add(listener)
        return { listeners.remove(listener) }
    }

    /* ---------------- run + LSP (Main mounts these into the IDE extras) ---------------- */

    suspend fun runDraft(conversationID: String, workspaceID: String?,
                         relativePath: String, language: String): TerminalActionReply =
        submit(buildJsonObject {
            put("action", "runDraft")
            put("conversationID", conversationID)
            workspaceID?.let { put("workspaceID", it) }
            put("relativePath", relativePath); put("language", language)
            put("requestID", UUID.randomUUID().toString())
        }, timeoutMillis = 30_000)

    suspend fun ensureLanguageServer(conversationID: String, workspaceID: String?,
                                     language: String): TerminalActionReply =
        submit(buildJsonObject {
            put("action", "lspEnsure")
            put("conversationID", conversationID)
            workspaceID?.let { put("workspaceID", it) }
            put("language", language)
            put("requestID", UUID.randomUUID().toString())
        }, timeoutMillis = 120_000)

    /** Durable toggle. The local projection mirrors the durable state ONLY
     * from a native Success that carries `persisted:true`; refusals,
     * timeouts and failed writes leave the projection at the last
     * persisted truth (the switch must not show a choice Core did not
     * commit). Disabling settles that language's live servers natively;
     * enabling never auto-starts (an explicit ensure proves availability). */
    suspend fun setLanguageEnabled(language: String, enabled: Boolean): TerminalActionReply {
        val reply = submit(buildJsonObject {
            put("action", "lspSetLanguageEnabled")
            put("language", language); put("enabled", enabled)
            put("requestID", UUID.randomUUID().toString())
        }, timeoutMillis = 8_000)
        if (reply is TerminalActionReply.Success &&
            reply.fields["persisted"] flag false &&
            reply.fields["language"]?.jsonPrimitive?.contentOrNull == language) {
            languageCapabilities = languageCapabilities.copy(
                settingsKnown = true,
                settingsRevision = reply.fields["revision"]?.jsonPrimitive?.longOrNull
                    ?: languageCapabilities.settingsRevision,
                enabled = languageCapabilities.enabled + (language to enabled))
        }
        return reply
    }

    suspend fun lspOpenDocument(conversationID: String, workspaceID: String?, language: String,
                                documentID: String, revision: String, text: String): TerminalActionReply =
        submitText("lspOpenDocument", conversationID, workspaceID, language, documentID, revision, text,
            extra = null)

    suspend fun lspChangeDocument(conversationID: String, workspaceID: String?, language: String,
                                  documentID: String, revision: String, text: String): TerminalActionReply =
        submitText("lspChangeDocument", conversationID, workspaceID, language, documentID, revision, text,
            extra = null)

    suspend fun lspCloseDocument(conversationID: String, workspaceID: String?, language: String,
                                 documentID: String): TerminalActionReply =
        submit(buildJsonObject {
            put("action", "lspCloseDocument")
            put("conversationID", conversationID); put("language", language)
            workspaceID?.let { put("workspaceID", it) }
            put("documentID", documentID)
            put("requestID", UUID.randomUUID().toString())
        }, timeoutMillis = 15_000)

    private suspend fun submitText(action: String, conversationID: String, workspaceID: String?,
                                   language: String, documentID: String, revision: String, text: String,
                                   extra: JsonObject?): TerminalActionReply {
        val bytes = text.toByteArray(Charsets.UTF_8)
        val digest = sha256Hex(bytes)
        return submit(buildJsonObject {
            put("action", action)
            put("conversationID", conversationID); put("language", language)
            workspaceID?.let { put("workspaceID", it) }
            put("documentID", documentID); put("revision", revision)
            put("textByteCount", bytes.size); put("textSHA256", digest)
            extra?.let { (it as? JsonObject)?.forEach { (key, value) -> put(key, value) } }
            put("requestID", UUID.randomUUID().toString())
        }, payload = bytes, timeoutMillis = 60_000)
    }

    /** Completion with the EXACT documentID+revision fence; a host-side
     * timeout requests native `$/cancelRequest` (a request, never a claim
     * the server stopped) and answers honestly. */
    suspend fun completion(conversationID: String, workspaceID: String?, language: String,
                           documentID: String, revision: String,
                           line: Int, character: Int): TerminalCompletionSnapshot? {
        val requestID = UUID.randomUUID().toString()
        val future = CompletableDeferred<TerminalCompletionSnapshot?>()
        completions[requestID] = future
        val descriptor = buildJsonObject {
            put("action", "lspCompletion")
            put("conversationID", conversationID); put("language", language)
            workspaceID?.let { put("workspaceID", it) }
            put("documentID", documentID); put("revision", revision)
            put("line", line); put("character", character)
            put("requestID", requestID)
        }.toString().toByteArray(Charsets.UTF_8)
        // Raw submit: a completion is answered by the fenced lspCompletion
        // EVENT (success) or an actionReply refusal; the replies map is NOT
        // the success path, so the timeout below is the only host budget.
        val admittedEpoch = boundEpoch
        var admitted = false
        var completed = false
        try {
            val token = withContext(Dispatchers.IO) {
                TerminalNative.submitAction(descriptor, null).also { admitted = it > 0 }
            }
            if (token <= 0) return null
            val answer = withTimeoutOrNull(G04LanguageServerCompletionBudgetMillis) { future.await() }
            completed = answer != null
            return answer
        } finally {
            completions.remove(requestID, future)
            if (admitted && !completed && boundEpoch == admittedEpoch && !stopped.get()) {
                // Cancellation removes only this waiter and requests native
                // cancellation; real session/IO ownership remains in Core.
                withContext(NonCancellable) {
                    submit(buildJsonObject {
                        put("action", "lspCancel"); put("conversationID", conversationID)
                        put("language", language); put("cancelTarget", requestID)
                        put("requestID", UUID.randomUUID().toString())
                    }, timeoutMillis = 6_000)
                }
            }
        }
    }

    suspend fun shutdownLanguage(conversationID: String, workspaceID: String?,
                                 language: String): TerminalActionReply =
        submit(buildJsonObject {
            put("action", "lspShutdown")
            put("conversationID", conversationID); put("language", language)
            workspaceID?.let { put("workspaceID", it) }
            put("requestID", UUID.randomUUID().toString())
        }, timeoutMillis = 15_000)

    /* ---------------- event handling ---------------- */

    /** internal for focused host tests (same semantics as the claim loop). */
    internal fun handleEvent(event: Long, descriptorBytes: ByteArray): Boolean {
        val descriptor = runCatching { json.parseToJsonElement(String(descriptorBytes)).jsonObject }
            .getOrNull() ?: return false
        when (descriptor["type"]?.jsonPrimitive?.contentOrNull) {
            "hostEventOverflow" -> {
                // Lost control delivery is an explicit refusal of local
                // waiters. Native IO/session receipts remain actually owned.
                fencePending()
                return true
            }
            "terminalOutput" -> {
                val token = descriptor["sessionToken"]?.jsonPrimitive?.contentOrNull ?: return true
                val payload = TerminalNative.payload(event) ?: return true
                val listeners = outputListeners[token]?.toList() ?: return true
                scope.launch(Dispatchers.Main) { listeners.forEach { it(payload) } }
                return true
            }
            "terminalStatus" -> {
                val snapshot = TerminalSessionSnapshot(
                    conversationID = descriptor["conversationID"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                    sessionToken = descriptor["sessionToken"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                    phase = descriptor["phase"]?.jsonPrimitive?.contentOrNull?.toPhase()
                        ?: TerminalSessionPhase.CLOSED,
                    purpose = descriptor["purpose"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                    runID = descriptor["runID"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                    exitCode = descriptor["exitCode"]?.jsonPrimitive?.intOrNull,
                    stopReason = descriptor["stopReason"]?.jsonPrimitive?.contentOrNull,
                    faultCode = descriptor["faultCode"]?.jsonPrimitive?.contentOrNull,
                    rolledOverBytes = descriptor["rolledOverBytes"]?.jsonPrimitive?.intOrNull ?: 0,
                )
                if (snapshot.sessionToken.isNotEmpty()) {
                    if (snapshot.conversationID.isNotEmpty()) {
                        snapshots[snapshot.conversationID] = snapshot
                        if (snapshot.phase == TerminalSessionPhase.CLOSED) {
                            sessionTokens.entries.removeAll { it.value == snapshot.sessionToken }
                        }
                    }
                    onTerminalStatus?.invoke(snapshot)
                    snapshot.conversationID.takeIf { it.isNotEmpty() }?.let { key ->
                        sessionWatchers[key]?.forEach { it(snapshot) }
                    }
                }
                return true
            }
            "actionReply" -> {
                val requestID = descriptor["requestID"]?.jsonPrimitive?.contentOrNull ?: return true
                val future = replies.remove(requestID)
                val ok = descriptor["ok"] flag false
                // A refusal for a fenced completion also releases the
                // completion waiter (one release; success path removes it).
                if (!ok) completions.remove(requestID)?.complete(null)
                if (future != null) {
                    if (ok) future.complete(TerminalActionReply.Success(descriptor))
                    else future.complete(TerminalActionReply.Refused(
                        descriptor["code"]?.jsonPrimitive?.contentOrNull ?: "failed",
                        descriptor["reason"]?.jsonPrimitive?.contentOrNull))
                }
                return true
            }
            "lspCompletion" -> {
                val requestID = descriptor["requestID"]?.jsonPrimitive?.contentOrNull ?: return true
                val items = descriptor.itemsJson().map { item ->
                    TerminalCompletionItem(
                        label = item.str("label"), insertText = item.str("insertText"),
                        kind = item.num("kind").toInt(), detail = item.str("detail"),
                        documentation = item.str("documentation"))
                } ?: emptyList()
                completions.remove(requestID)?.complete(TerminalCompletionSnapshot(
                    requestID = requestID,
                    documentID = descriptor["documentID"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                    revision = descriptor["revision"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                    items = items,
                    incomplete = descriptor["incomplete"] flag false,
                    truncated = descriptor["truncated"] flag false,
                ))
                return true
            }
            "lspDiagnostics" -> {
                val items = descriptor.itemsJson().map { item ->
                    TerminalDiagnosticItem(
                        startLine = item.num("startLine").toInt(),
                        startCharacter = item.num("startCharacter").toInt(),
                        endLine = item.num("endLine").toInt(),
                        endCharacter = item.num("endCharacter").toInt(),
                        severity = item.num("severity").toInt(),
                        message = item.str("message"), source = item.str("source")
                    )
                }
                val diagnosticEvent = TerminalDiagnosticsSnapshot(
                    conversationID = descriptor.str("conversationID"),
                    workspaceID = descriptor.str("workspaceID"),
                    documentID = descriptor.str("documentID"),
                    relativePath = descriptor.str("relativePath"),
                    revision = descriptor.str("revision"),
                    lspVersion = descriptor.num("lspVersion").toInt(),
                    items = items,
                    truncated = descriptor["truncated"] flag false,
                )
                onDiagnostics?.invoke(diagnosticEvent)
                diagnosticListeners.forEach { it(diagnosticEvent) }
                return true
            }
            "lspStatus" -> {
                val statusEvent = TerminalLanguageStatus(
                    conversationID = descriptor.str("conversationID"),
                    language = descriptor.str("language"),
                    state = descriptor.str("state"),
                    code = descriptor["code"]?.jsonPrimitive?.contentOrNull,
                )
                onLanguageStatus?.invoke(statusEvent)
                languageStatusListeners.forEach { it(statusEvent) }
                return true
            }
            "lspApplyEditApplied", "lspApplyEditPartial", "lspFramingFault",
            "lspServerMessage", "lspWriteOverflow", "hostBound" -> {
                val listener = onLanguageStatus
                if (listener != null && descriptor["type"] != null) {
                    listener(TerminalLanguageStatus(
                        conversationID = descriptor.str("conversationID"),
                        language = descriptor.str("language"),
                        state = descriptor["type"]!!.jsonPrimitive.content,
                        code = descriptor["code"]?.jsonPrimitive?.contentOrNull
                            ?: descriptor["reason"]?.jsonPrimitive?.contentOrNull,
                    ))
                }
                return true
            }
            else -> return true // unknown event types are counted, never claimed
        }
    }

    /* ---------------- submit helper ---------------- */

    private suspend fun submit(action: JsonObject, payload: ByteArray? = null,
                               timeoutMillis: Long): TerminalActionReply {
        if (boundEpoch == 0L || stopped.get()) return TerminalActionReply.Refused("hostUnbound", null)
        val requestID = action["requestID"]?.jsonPrimitive?.contentOrNull ?: return TerminalActionReply.Refused("invalidRequest", null)
        val future = CompletableDeferred<TerminalActionReply>()
        replies[requestID] = future
        val descriptor = action.toString().toByteArray(Charsets.UTF_8)
        try {
            val token = withContext(Dispatchers.IO) { TerminalNative.submitAction(descriptor, payload) }
            if (token <= 0) return TerminalActionReply.Refused(codeForSubmit(token), null)
            return withTimeoutOrNull(timeoutMillis) { future.await() } ?: TerminalActionReply.TimedOut
        } finally {
            // Local cancellation/timeout never leaves a future retained;
            // the native operation still keeps its original actual receipt.
            replies.remove(requestID, future)
        }
    }

    private fun codeForSubmit(token: Long): String = when (token) {
        -101L -> "hostClosed"; -105L -> "invalidDescriptor"; -106L -> "payloadTooLarge"
        -107L -> "payloadTooLarge"; -108L -> "saturated"; else -> "submitFailed"
    }
}

/** Host-side outer budget for a fenced completion answer (native applies
 * its own shorter 10 s request deadline plus $/cancelRequest). */
private const val G04LanguageServerCompletionBudgetMillis = 15_000L

/* ---------------- tiny JSON helpers (bounded, never invented) ---------------- */

private infix fun kotlinx.serialization.json.JsonElement?.flag(default: Boolean): Boolean {
    val primitive = this as? JsonPrimitive ?: return default
    return primitive.booleanOrNull ?: default
}

private fun JsonObject.itemsJson(): List<JsonObject> =
    (this["items"] as? kotlinx.serialization.json.JsonArray)?.mapNotNull { it as? JsonObject }
    ?: emptyList()

private fun JsonObject.str(key: String): String =
    this[key]?.jsonPrimitive?.contentOrNull.orEmpty()

private fun JsonObject.num(key: String): Long =
    this[key]?.jsonPrimitive?.longOrNull ?: 0L

private fun String.toPhase(): TerminalSessionPhase? = when (this) {
    "closed" -> TerminalSessionPhase.CLOSED
    "starting" -> TerminalSessionPhase.STARTING
    "running" -> TerminalSessionPhase.RUNNING
    "waitingOutput" -> TerminalSessionPhase.WAITING_OUTPUT
    "exited" -> TerminalSessionPhase.EXITED
    "stopped" -> TerminalSessionPhase.STOPPED
    "fault" -> TerminalSessionPhase.FAULT
    else -> null
}

private fun TerminalSessionPhase.isLive(): Boolean =
    this == TerminalSessionPhase.RUNNING || this == TerminalSessionPhase.WAITING_OUTPUT ||
        this == TerminalSessionPhase.STARTING

private fun sha256Hex(bytes: ByteArray): String =
    java.security.MessageDigest.getInstance("SHA-256").digest(bytes)
        .joinToString("") { "%02x".format(it) }
