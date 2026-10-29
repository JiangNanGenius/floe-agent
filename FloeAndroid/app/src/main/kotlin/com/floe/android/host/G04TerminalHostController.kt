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
import kotlinx.coroutines.channels.Channel
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

/** The EXACT identity of one live interactive terminal this host owns, as
 * captured for an explicit model handoff. Opaque by design: [sessionToken]
 * and [nativeEpoch] are fences, never user copy and never a grant. A handoff
 * may only ever touch THIS capture — a session that replaced it is a
 * different terminal and is never stopped. */
data class TerminalHandoffCapture(
    val conversationID: String,
    val sessionToken: String,
    val nativeEpoch: Long,
)

/** Outcome of one explicitly-consented terminal→model handoff. [Released] is
 * the ONLY success and means the captured terminal was closed AND the single
 * runtime-UID engine slot was REALLY proven free (lease release, not an
 * accepted stop request and not elapsed time). Every [Refused] code means
 * nothing was dispatched and the caller must not approve the command. */
sealed interface TerminalHandoffResult {
    data object Released : TerminalHandoffResult
    /** Typed refusal; [code] is a diagnostic identity for the opened details
     * view, never prose for the ordinary surface. */
    data class Refused(val code: String) : TerminalHandoffResult
}

data class TerminalCompletionItem(
    val label: String,
    val insertText: String,
    val kind: Int,
    val detail: String,
    val documentation: String,
)

/** The LATEST typed PTY input refusal for one conversation. A host-side
 * fact reported through the pane's status strip (message) and its opened
 * details (code) — never a fabricated native phase or fault. [count] is
 * the number of consecutive same-code refusals since the last clear (a
 * successful fresh open or close). */
data class TerminalInputIssue(
    val conversationID: String,
    val code: String,
    val count: Int,
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
    private val outputDispatcher: kotlinx.coroutines.CoroutineDispatcher = Dispatchers.Main,
    /** PTY-input lane drain dispatcher (IO in production; injectable so
     * the focused host tests can pump one serialized drain deterministically). */
    private val inputDispatcher: kotlinx.coroutines.CoroutineDispatcher = Dispatchers.IO,
    /** Test seam for the lane's actual submit step (see [enqueuePtyInput]);
     * production keeps the real mailbox admission. */
    private val inputSinkOverride:
        (suspend (conversationID: String, sessionToken: String, bytes: ByteArray) -> Unit)? = null,
    /** REAL engine-slot release proof for the explicit terminal→model
      * handoff. Production uses the EXISTING trusted-host drain read
      * (`LinuxShellNative.drain` → `floe_linux_shell_drain` →
      * `reconcileLedger()` + `isDrained()`): true only when no backend lease
      * awaits its release proof, the single engine gate is free, no mailbox
      * ticket is live and no ledger worker remains. It fences nothing, stops
      * nothing, suspends no admission and closes no mailbox — it is the same
      * proof `LinuxShellPump.stopAndDrain` already consumes, minus that
      * method's own stop/fence steps, which are deliberately NOT performed
      * here. Injectable so the focused host tests prove the handoff waits for
      * a REAL release instead of an accepted stop or elapsed time. */
    private val engineSlotReleaseProof: suspend (timeoutMillis: Int) -> Boolean = { timeout ->
        withContext(Dispatchers.IO) {
            runCatching { com.floe.android.bridge.LinuxShellNative.drain(timeout) == 1 }
                .getOrDefault(false)
        }
    },
    /** Test seam for the handoff's actual native close admission (the same
      * convention as [inputSinkOverride]): production keeps the real
      * `terminalClose` mailbox submit, so the focused host tests can prove the
      * close→settle→REAL-release→approve ordering without a JNI library. */
    private val closeSinkOverride:
        (suspend (conversationID: String, sessionToken: String) -> TerminalActionReply)? = null,
    /** Native mailbox submission seam for deterministic reply/status ordering
     * tests. Production always uses TerminalNative; admission and reply-future
     * ownership still run through the real submit path. */
    private val nativeSubmitOverride: ((ByteArray, ByteArray?) -> Long)? = null,
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
    /** Registered run-open intents keyed by the EXACT requestID `runDraft`
     * submitted: the service-owned binding route for an accepted Run's
     * sessionToken (device evidence 2026-10-25: native answers the reply —
     * then the first output — before any host binding existed, because
     * only `attachOrOpen` assigned tokens, so accepted Run output had no
     * reverse-binding owner and every page was dropped). An intent is
     * consumed by its matching actionReply and cleared by the submitting
     * call's timeout/cancel/fence; a late reply from a retired world never
     * binds. */
    private val pendingRunOpens = ConcurrentHashMap<String, PendingRunOpen>()

    /** One owned run-open intent: the conversation, the Root generation
     * that admitted the submit, and the EXACT conversation binding captured
     * at registration. The binding is claimed with a per-conversation CAS
     * against that captured predecessor, so an accepted Run can replace its
     * own stale predecessor while any newer open/reset/stop that moved the
     * binding fences this reply — never the cached snapshot mirror. Binding
     * is honored only while that exact generation is still the live one —
     * no epoch-0 or unbound fallback. */
    internal data class PendingRunOpen(
        val conversationID: String,
        val epoch: Long,
        val previousToken: String?,
    )

    /** requestID -> the interactive `attachOrOpen` that submitted it. The
     * accepted UI terminal's token is bound by the actionReply itself, BEFORE
     * native's first output / running status events (which follow the reply
     * in mailbox order) and before the deferred open coroutine resumes. The
     * same ordering gap the Run lane closed on 2026-10-25 otherwise drops
     * the first output page and leaves the pane key's snapshot at its
     * STARTING seed while the terminal is actually live. An intent is
     * consumed by its exact actionReply and cleared by the submitting call's
     * refusal/timeout/fence; a late reply never binds. */
    private val pendingInteractiveOpens = ConcurrentHashMap<String, PendingInteractiveOpen>()

    /** One interactive-open intent: the conversation key, the admitted Root
     * generation and the binding captured before dispatch (the CAS
     * predecessor). */
    private data class PendingInteractiveOpen(
        val conversationID: String,
        val epoch: Long,
        val previousToken: String?,
    )

    private val outputListeners = ConcurrentHashMap<String, MutableSet<(ByteArray) -> Unit>>() // token -> listeners
    private val engines = ConcurrentHashMap<String, G04TerminalEngine>()
    private val snapshots = ConcurrentHashMap<String, TerminalSessionSnapshot>()

    @Volatile private var availability = TerminalHostAvailability(
        bound = false, qualified = false, workspaceAttached = false, capabilitiesKnown = false)
    @Volatile private var onTerminalStatus: ((TerminalSessionSnapshot) -> Unit)? = null
    private val sessionWatchers = ConcurrentHashMap<String, MutableSet<(TerminalSessionSnapshot) -> Unit>>()
    /** Latest typed input refusal per conversation + its pane watchers
     * (the same watcher idiom as [sessionWatchers]). */
    private val inputIssues = ConcurrentHashMap<String, TerminalInputIssue>()
    private val inputIssueWatchers = ConcurrentHashMap<String, MutableSet<(TerminalInputIssue?) -> Unit>>()
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

    /** Pane-scoped observation of the conversation's LATEST typed input
     * refusal (null once cleared by a fresh open/close). Same watcher idiom
     * as [watchSessions]: registration is the only view-scoped resource;
     * detaching never touches the session. */
    fun watchInputIssues(conversationID: String, watcher: (TerminalInputIssue?) -> Unit): () -> Unit {
        val set = inputIssueWatchers.getOrPut(conversationID) { java.util.concurrent.CopyOnWriteArraySet() }
        set.add(watcher)
        inputIssues[conversationID]?.let { watcher(it) }
        return { set.remove(watcher); if (set.isEmpty()) inputIssueWatchers.remove(conversationID) }
    }

    /** Records one typed refusal: latest-code + consecutive-count truth for
     * the pane, watcher fan-out, and the bounded WARN log. A host-side fact
     * — never invents a native phase or fault. */
    private fun reportInputIssue(conversationID: String, code: String) {
        val issue = inputIssues.compute(conversationID) { _, old ->
            if (old != null && old.code == code) old.copy(count = old.count + 1)
            else TerminalInputIssue(conversationID, code, 1)
        } ?: return
        inputIssueWatchers[conversationID]?.forEach { it(issue) }
        inputIssueReporter("pty input refused conversation=$conversationID code=$code")
    }

    /** Clears the surfaced refusal when the session truth moves on (a
     * fresh open bound a new token, or an accepted close ended it): the old
     * generation's input facts no longer describe the live session. */
    internal fun clearInputIssue(conversationID: String) {
        inputIssues.remove(conversationID)
        inputIssueWatchers[conversationID]?.forEach { it(null) }
    }

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
        if (boundEpoch != expectedEpoch && boundEpoch != 0L) return@withLock false
        // Stopped ownership is proven INDEPENDENTLY of the reader's
        // boundEpoch: the reader's finally zeroes boundEpoch BEFORE any
        // lane join, so boundEpoch==0 alone must never answer true while
        // owned lane workers are still retained. A true answer always
        // means the reader AND every owned input worker have provably
        // finished for this controller.
        stopped.set(true)
        if (boundEpoch == expectedEpoch && expectedEpoch != 0L) {
            val joined = withTimeoutOrNull(waitMillis) { reader?.join(); true } ?: false
            if (!joined) return@withLock false
            reader = null
        }
        if (!ensureLanesJoined(waitMillis)) return@withLock false
        fencePending()
        true
    }

    /** Stops AND joins every owned input lane worker. Idempotent: a retry
     * after a timed-out join re-joins the RETAINED workers instead of
     * abandoning them, closed channels keep refusing later offers
     * truthfully, and the registry entries are removed ONLY after their
     * worker provably finished — under the same lock [enqueuePtyInput]
     * uses for creation, so no worker can be created after the stop
     * snapshot. The lock is never held across suspension. */
    private suspend fun ensureLanesJoined(waitMillis: Long): Boolean {
        val lanes = synchronized(inputLanesLock) { inputLanes.values.toList() }
        if (lanes.isEmpty()) return true
        val done = withTimeoutOrNull(waitMillis) {
            lanes.forEach { it.terminate() }
            true
        } ?: false
        if (done) {
            synchronized(inputLanesLock) {
                lanes.forEach { inputLanes.remove(it.conversationID, it) }
            }
        }
        return done
    }

    private fun fencePending() {
        val pendingReplies = replies.values.toList()
        replies.clear()
        pendingReplies.forEach { it.complete(TerminalActionReply.Refused("hostFenced", null)) }
        val pendingCompletions = completions.values.toList()
        completions.clear()
        pendingCompletions.forEach { it.complete(null) }
        // Run-open and interactive-open intents never survive a fence: an
        // actionReply arriving after this point can no longer claim an owned
        // binding (the same honest local-waiter refusal the replies get).
        pendingRunOpens.clear()
        pendingInteractiveOpens.clear()
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
                    enqueuePtyInput(conversationID, bytes)
                }
                override fun log(level: String, message: String) {
                    android.util.Log.println(logPriority(level), "FloeTerminal", message.take(2048))
                }
            })
        }

    /* ---------------- PTY input: one bounded ORDERED lane per conversation ---------------- */

    /** One admitted input page. The bytes are an IMMUTABLE COPY taken at
     * offer time (callers may reuse their arrays) and [admittedEpoch] pins
     * the Root generation that admitted it — queued input from an old
     * world can never enter a new one. */
    private data class PtyInputItem(
        val sessionToken: String,
        val bytes: ByteArray,
        val admittedEpoch: Long,
    )

    /** conversationID -> its serialized input lane (the same service-owned,
     * per-conversation lifetime as [engines]; lanes are stopped and joined
     * with the generation in [stopAndJoin]). */
    private val inputLanes = ConcurrentHashMap<String, TerminalInputLane>()

    /** Bounded WARN log seam for input refusals. The USER-VISIBLE truth is
     * recorded unconditionally by [reportInputIssue] (latest typed refusal
     * + watcher fan-out); this reporter is the diagnostic log line only.
     * Internal so the focused JVM tests can observe refusals without an
     * Android log. */
    internal var inputIssueReporter: (String) -> Unit = { message ->
        android.util.Log.println(android.util.Log.WARN, "FloeTerminal", message.take(2048))
    }

    /** Ensures the conversation's service-owned engine exists at an owned
     * binding boundary (a Run accepted before any pane mounted must not
     * drop its bytes). Production keeps the real bounded [engineFor]
     * registry — controller-owned, independent of view lifetime, reuse
     * preserves the existing transcript/reset policy. Internal var so the
     * focused JVM tests can observe the boundary without constructing the
     * vendored emulator (the same seam idiom as [inputIssueReporter]). */
    internal var engineEnsurer: (String) -> Unit = { conversationID ->
        engineFor(conversationID)
    }

    /** The lane's actual production drain: ONE ordered terminalInput
     * action through the ORIGINAL submit/ack path (the reviewed
     * [submit] helper: registered requestID future, bounded wait, real
     * reply) — mailbox admission order IS PTY input order and the session
     * authority stays in Swift Core. A non-Success answer is reported
     * truthfully through [inputIssueReporter] with the actual refusal
     * code (hostUnbound/saturated/timedOut/…), never as a silent success. */
    private val inputSink: suspend (String, String, ByteArray) -> Unit =
        inputSinkOverride ?: { conversationID, sessionToken, bytes ->
            val reply = submit(buildJsonObject {
                put("action", "terminalInput")
                put("sessionToken", sessionToken)
                put("data", Base64.getEncoder().encodeToString(bytes))
                put("requestID", UUID.randomUUID().toString())
            }, timeoutMillis = 6_000)
            if (reply !is TerminalActionReply.Success) {
                reportInputIssue(conversationID, inputRefusalCode(reply))
            }
        }

    private fun inputRefusalCode(reply: TerminalActionReply): String = when (reply) {
        TerminalActionReply.TimedOut -> "timedOut"
        is TerminalActionReply.Refused -> reply.code
        else -> "refused"
    }

    /** Bounded serialized PTY input lane. One `scope.launch(Dispatchers.IO)`
     * PER keystroke could reorder at JNI admission (two IO workers racing
     * into `submitAction`) and flood the mailbox's in-flight window with
     * unbounded parallel submits — the contract is REAL ORDERED PTY input.
     * Every keystroke therefore enqueues into ONE bounded, byte-stream
     * lane (both a packet cap AND a byte budget — item count alone is not
     * boundedness) and drains one frame at a time in EXACT arrival order
     * on a single owned worker whose [Job] handle the controller keeps, so
     * a Root stop closes the lane and JOINS the worker before declaring
     * the generation stopped. Each drain re-checks, IMMEDIATELY before the
     * native submit: the item's admitted epoch still equals the bound
     * epoch AND the runtime's live epoch, the host is not stopping, and
     * the exact token is still bound to the conversation. Every refusal is
     * truthful (reported, never silently dropped); cancellation flows with
     * the app-owned [scope].
     *
     * Coalescing (linux-product80, 2026-10-28): PTY stdin is ONE ordered
     * byte stream per conversation, but the old lane queued one packet per
     * key EVENT, so a rapid burst (device-retained: ~350-byte adb-input /
     * hardware-keyboard typing with a momentarily stalled drain) honestly
     * refused `inputLaneOverflow` while the byte budget was nearly empty —
     * real user input lost in the visible warning. Consecutive small
     * frames admitted for the SAME token and epoch now merge at the TAIL
     * into one frame bounded by [MaxCoalescedInputFrameBytes], still under
     * both the packet cap and the byte budget. Nothing is reordered,
     * replayed or duplicated: a merged frame is admitted once, drains
     * once, keeps the admission-time epoch/token copies, and a refused
     * write still reports its real code. Boundedness is unchanged — the
     * queue is still an ArrayDeque behind one monitor with a conflated
     * wake token, and every reservation is taken atomically before the
     * item becomes visible. */
    private inner class TerminalInputLane(val conversationID: String) {
        private val queue = ArrayDeque<PtyInputItem>()
        private val wake = Channel<Unit>(capacity = 1)
        private var closed = false
        private var queuedCount = 0
        private var queuedBytes = 0L

        private val consumer: Job = scope.launch(inputDispatcher) {
            // Conflated wake: one buffered token guarantees at least one
            // following drain pass; each pass drains EVERY frame present,
            // so an offer racing the pass either joins that drain or
            // leaves its own token behind. Buffered elements are received
            // before close() surfaces (same end-of-stream behaviour the
            // old `for (item in channel)` relied on).
            while (wake.receiveCatching().isSuccess) {
                while (true) {
                    val item = synchronized(this@TerminalInputLane) {
                        if (queue.isEmpty()) null
                        else {
                            val head = queue.removeFirst()
                            queuedCount -= 1
                            queuedBytes -= head.bytes.size
                            head
                        }
                    } ?: break
                    // Exact fences immediately before the native submit.
                    val refusal = when {
                        item.admittedEpoch != boundEpoch -> "inputGenerationStale"
                        currentNativeEpoch() != item.admittedEpoch -> "inputGenerationStale"
                        stopped.get() -> "hostUnbound"
                        sessionTokens[conversationID] != item.sessionToken -> "inputTokenRetired"
                        else -> null
                    }
                    if (refusal != null) {
                        reportInputIssue(conversationID, refusal)
                        continue
                    }
                    inputSink(conversationID, item.sessionToken, item.bytes)
                }
            }
        }

        /** Admits one item; returns null when queued, otherwise a truthful
         * refusal code. Reservations (packet count AND byte budget) and
         * the tail coalescing are taken under ONE lane monitor before the
         * item becomes visible, so the lane can never exceed either bound
         * and the drain can never observe a half-merged frame. */
        fun offer(token: String, bytes: ByteArray, admittedEpoch: Long): String? {
            val incoming = bytes.copyOf()
            val refusal = synchronized(this) {
                when {
                    closed -> "inputLaneStopped"
                    else -> {
                        val tail = queue.lastOrNull()
                        val canMerge = tail != null &&
                            tail.sessionToken == token &&
                            tail.admittedEpoch == admittedEpoch &&
                            tail.bytes.size + incoming.size <= MaxCoalescedInputFrameBytes &&
                            queuedBytes + incoming.size <= InputLaneByteBudget
                        when {
                            canMerge -> {
                                queue.removeLast()
                                queue.addLast(PtyInputItem(token, tail.bytes + incoming,
                                    admittedEpoch))
                                queuedBytes += incoming.size
                                null
                            }
                            queuedCount >= InputLaneCapacity -> "inputLaneOverflow"
                            queuedBytes + incoming.size > InputLaneByteBudget -> "inputLaneByteBudget"
                            else -> {
                                queuedCount += 1
                                queuedBytes += incoming.size
                                queue.addLast(PtyInputItem(token, incoming, admittedEpoch))
                                null
                            }
                        }
                    }
                }
            }
            if (refusal != null) return refusal
            // Best-effort wake only: a buffered token already guarantees a
            // future drain pass that sees this frame.
            wake.trySend(Unit)
            return null
        }

        /** Stops this owned worker: refuse later offers, give the drain a
         * final pass over the admitted frames (each still fence-checked),
         * then JOIN. Used by [stopAndJoin]; bounded there — on timeout
         * the lane RETAINS its closed lane state and live worker
         * (ownership is never fabricated away). */
        suspend fun terminate() {
            synchronized(this) { closed = true }
            wake.trySend(Unit)
            wake.close()
            consumer.join()
        }
    }

    /** Guards lane creation against the stop path: [ensureLanesJoined]
     * snapshots/removes under this lock and [enqueuePtyInput] re-checks
     * [stopped] under it, so a worker can never be created after the stop
     * snapshot — a truthful stop always means no lane worker outlives the
     * generation. */
    private val inputLanesLock = Any()

    /** Single entry point for EVERY byte the UI wants to send to the PTY
     * (hardware keys, IME commits, emulator keyboard responses): admit
     * with the CURRENT token and the CURRENT live generation on the
     * caller thread, then let the conversation's serialized lane drain it
     * in order under its own fences. Every refusal is typed, recorded for
     * the pane and logged — never silent. */
    private fun enqueuePtyInput(conversationID: String, bytes: ByteArray) {
        if (bytes.isEmpty()) return
        val admittedEpoch = boundEpoch
        if (admittedEpoch == 0L || currentNativeEpoch() != admittedEpoch || stopped.get()) {
            reportInputIssue(conversationID, "hostUnbound")
            return
        }
        val token = sessionTokens[conversationID]
        if (token == null) {
            reportInputIssue(conversationID, "sessionUnknown")
            return
        }
        // Atomic creation, coordinated with stopAndJoin: the stopped
        // re-check runs under the SAME lock the stop uses to snapshot and
        // remove lanes, so no worker is created after a stop began.
        val lane = synchronized(inputLanesLock) {
            if (stopped.get()) null
            else inputLanes.computeIfAbsent(conversationID) { TerminalInputLane(it) }
        }
        if (lane == null) {
            reportInputIssue(conversationID, "hostUnbound")
            return
        }
        lane.offer(token, bytes, admittedEpoch)?.let { refusal ->
            reportInputIssue(conversationID, refusal)
        }
    }

    private fun logPriority(level: String): Int = when (level) {
        "error" -> android.util.Log.ERROR; "warn" -> android.util.Log.WARN
        "info" -> android.util.Log.INFO; else -> android.util.Log.DEBUG
    }

    /** Transport handed to the view: ordered writes + true native resize. */
    fun transportFor(conversationID: String): TerminalTransport = object : TerminalTransport {
        override fun write(bytes: ByteArray) {
            enqueuePtyInput(conversationID, bytes)
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
                             columns: Int, rows: Int,
                             onRefusal: (TerminalActionReply) -> Unit = {}): TerminalSessionSnapshot? {
        val token = sessionTokens[conversationID]
        if (token != null && snapshots[conversationID]?.phase?.isLive() == true) {
            val requestID = UUID.randomUUID().toString()
            submit(buildJsonObject {
                put("action", "terminalAttach"); put("sessionToken", token); put("requestID", requestID)
            }, timeoutMillis = 10_000)
            return snapshots[conversationID]
        }
        val openingEpoch = boundEpoch
        val previousToken = token
        val requestID = UUID.randomUUID().toString()
        // Register the intent BEFORE dispatch: the reply handler binds the
        // accepted token synchronously, so native's following output/status
        // events are never processed against a missing pane binding.
        pendingInteractiveOpens[requestID] =
            PendingInteractiveOpen(conversationID, openingEpoch, previousToken)
        val reply = try {
            submit(buildJsonObject {
                put("action", "terminalOpen")
                put("conversationID", conversationID)
                workspaceID?.let { put("workspaceID", it) }
                put("columns", columns); put("rows", rows); put("requestID", requestID)
            }, timeoutMillis = 165_000)
        } finally {
            // Consumed by the exact accepted reply; a refusal/timeout/fence
            // must leave no late-binding intent behind.
            pendingInteractiveOpens.remove(requestID)
        }
        if (boundEpoch != openingEpoch || (openingEpoch != 0L && stopped.get())) return null
        if (reply is TerminalActionReply.Success) {
            val newToken = reply.fields["sessionToken"]?.jsonPrimitive?.contentOrNull
            if (newToken != null) {
                val current = sessionTokens[conversationID]
                if (current == null || current == previousToken) {
                    sessionTokens[conversationID] = newToken
                }
                if (sessionTokens[conversationID] != newToken) {
                    // A newer open/reset/stop moved this conversation's
                    // binding while this reply was in flight: the reply
                    // handler already fenced it. Never overwrite the newer
                    // session's authoritative projection with this stale one.
                    return snapshots[conversationID]
                }
                // A fresh session bound: the previous generation's typed
                // input refusals no longer describe the live truth.
                clearInputIssue(conversationID)
                // Seed the view state; the native terminalStatus event for
                // this session arrives immediately and replaces it with the
                // authoritative phase (never a silent fake "running").
                // A stale snapshot of the PREVIOUS token must not survive a
                // fresh open: replace it, but never downgrade the NEW
                // token's already-arrived authoritative status — including
                // the case where that status was published under the native
                // `UUID.uuidString` spelling before this coroutine resumed.
                val existing = snapshots[conversationID]
                if (existing == null || existing.sessionToken != newToken) {
                    if (snapshots.values.any { it.sessionToken == newToken }) {
                        adoptSnapshotForToken(conversationID, newToken)
                    } else {
                        snapshots[conversationID] = TerminalSessionSnapshot(
                            conversationID, newToken, TerminalSessionPhase.STARTING, "interactive", "",
                            null, null, null, 0)
                    }
                }
                // Completing the open reply schedules this coroutine separately
                // from the mailbox reader. RUNNING status may already have been
                // published while the captured handle was still absent. Re-publish
                // the matching current snapshot after binding so observers can
                // re-evaluate BOTH facts; never fabricate a RUNNING phase.
                snapshots[conversationID]?.takeIf { it.sessionToken == newToken }?.let { snapshot ->
                    sessionWatchers[conversationID]?.forEach { it(snapshot) }
                }
            } else {
                onRefusal(TerminalActionReply.Refused("invalidReply", null))
            }
        } else {
            onRefusal(reply)
            // Nothing is live for this opening. Returning the previous
            // (settled) snapshot here kept callers convinced a start was
            // in flight forever: the pane then showed a blank live-style
            // pane with no guidance and no retry. Honest answer: null.
            val current = snapshots[conversationID]
            if (current == null || !current.phase.isLive()) return null
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
            // The session truth moved on: stop surfacing its input refusals.
            clearInputIssue(conversationID)
        }
        return reply
    }

    /* -------- explicit interactive-terminal → model handoff (Main ruling
       2026-10-28) --------

       The single runtime-UID Linux engine slot is PRESERVED: nothing here
       raises a cap, starts a duplicate worker, kills a process, retries
       hidden or fabricates a release. A manual terminal is human-owned work,
       so only an EXPLICIT user decision on the existing approval surface may
       end it, and the already-proposed command is dispatched by the ordinary
       approval route AFTER the real release below — never replayed from a
       failed run. */

    /** The conversation's LIVE interactive terminal exactly as this host owns
     * it right now, or null. Every clause is a real read: an admitted live
     * Root generation, an authoritative LIVE status, this host's own captured
     * handle, and both describing the SAME session. A `.run` (language/run
     * draft) session, a settled phase, a retired token, another
     * conversation's session or an unbound host therefore answer null — so no
     * approval card can ever offer to end work this host does not own. */
    fun liveInteractiveTerminal(conversationID: String): TerminalHandoffCapture? {
        val epoch = boundEpoch
        if (epoch == 0L || stopped.get()) return null
        if (currentNativeEpoch() != epoch) return null
        val snapshot = snapshots[conversationID] ?: return null
        if (!snapshot.phase.isLive()) return null
        if (snapshot.purpose != TERMINAL_PURPOSE_INTERACTIVE) return null
        val token = sessionTokens[conversationID] ?: return null
        // The captured handle and the authoritative status must describe the
        // SAME session: a stale snapshot of a retired token is not a live
        // terminal, and a replacement token is a different terminal.
        if (token.isEmpty() || token != snapshot.sessionToken) return null
        return TerminalHandoffCapture(
            conversationID = conversationID,
            sessionToken = token,
            nativeEpoch = epoch,
        )
    }

    /** Ends EXACTLY [capture] and proves the engine slot is really free, so
     * the caller may then approve/dispatch the already-proposed command once.
     *
     * Fences, in order, each one refusing without touching anything:
     *  * generation — the captured Root epoch must still be the live bound
     *    one, re-checked AFTER every suspension (a generation that moved on
     *    mid-handoff never publishes a release);
     *  * identity — this host's handle for the conversation must still BE the
     *    captured token, so a session that replaced it is never stopped, and
     *    a different conversation is unreachable by construction (the map is
     *    keyed per conversation and the close is submitted with the captured
     *    token only);
     *  * cancellation — a cancelled/navigated-away caller gets a typed
     *    refusal, never a partial stop presented as success.
     *
     * Success requires BOTH the projected settlement AND the real release
     * proof: `terminalClose` answers before native settlement, and an
     * accepted engine stop request is not a released lease. A foreign
     * workload that still holds the slot answers [TerminalHandoffResult.Refused]
     * with `engineSlotStillHeld` and is NEVER closed here.
     *
     * The G04 domain's own close path already retires the captured
     * operation/workspace mapping and ends its receipt, and the model run
     * mints its own grant at dispatch, so no additional mapping refresh is
     * performed or needed here.
     */
    suspend fun endCapturedTerminalForHandoff(
        capture: TerminalHandoffCapture,
        settledWaitMillis: Long = 20_000,
        releaseProofTimeoutMillis: Int = 15_000,
    ): TerminalHandoffResult {
        if (capture.nativeEpoch == 0L || capture.sessionToken.isEmpty()) {
            return TerminalHandoffResult.Refused("staleCapture")
        }
        fun generationLive(): Boolean =
            boundEpoch == capture.nativeEpoch &&
                !stopped.get() &&
                currentNativeEpoch() == capture.nativeEpoch
        if (!generationLive()) return TerminalHandoffResult.Refused("staleGeneration")
        if (isHandoffCancelled()) return TerminalHandoffResult.Refused("cancelled")
        // Identity fence BEFORE any effect: only the exact captured session is
        // a candidate. `null` (already retired) and a replacement token both
        // refuse — the replacement is a different terminal and stays running.
        if (sessionTokens[capture.conversationID] != capture.sessionToken) {
            return TerminalHandoffResult.Refused("staleCapture")
        }
        val closed = closeSessionExact(capture.conversationID, capture.sessionToken)
        when (closed) {
            is TerminalActionReply.Success -> Unit
            TerminalActionReply.TimedOut ->
                return TerminalHandoffResult.Refused("closeTimedOut")
            is TerminalActionReply.Refused ->
                return TerminalHandoffResult.Refused(closed.code.ifEmpty { "closeRefused" })
        }
        if (!generationLive()) return TerminalHandoffResult.Refused("staleGeneration")
        if (isHandoffCancelled()) return TerminalHandoffResult.Refused("cancelled")
        // Projected settlement (the same real-CLOSED observation the pane's
        // explicit Reset already awaits): necessary, but NOT the release
        // proof — an accepted close answers before the engine settles.
        if (!awaitSessionSettled(capture.conversationID, settledWaitMillis)) {
            return TerminalHandoffResult.Refused("closeNotSettled")
        }
        if (!generationLive()) return TerminalHandoffResult.Refused("staleGeneration")
        if (isHandoffCancelled()) return TerminalHandoffResult.Refused("cancelled")
        // The REAL settled/released/export roundtrip: the existing trusted
        // host drain answers true only when no backend lease awaits its
        // release proof, the single engine gate is free, no mailbox ticket is
        // live and no ledger worker remains. Elapsed time is never a release.
        if (!engineSlotReleaseProof(releaseProofTimeoutMillis)) {
            return TerminalHandoffResult.Refused("engineSlotStillHeld")
        }
        if (!generationLive()) return TerminalHandoffResult.Refused("staleGeneration")
        if (isHandoffCancelled()) return TerminalHandoffResult.Refused("cancelled")
        return TerminalHandoffResult.Released
    }

    /** Closes EXACTLY [expectedToken]: the request carries the captured token
     * (never a re-read one), and the handle is removed with a per-conversation
     * CAS against that same value, so a replacement session bound meanwhile is
     * never unbound and a timeout/refusal retains the handle for the ORIGINAL
     * reconciliation path. */
    private suspend fun closeSessionExact(
        conversationID: String,
        expectedToken: String,
    ): TerminalActionReply {
        val override = closeSinkOverride
        val reply = if (override != null) {
            override(conversationID, expectedToken)
        } else {
            submit(buildJsonObject {
                put("action", "terminalClose")
                put("sessionToken", expectedToken)
                put("requestID", UUID.randomUUID().toString())
            }, timeoutMillis = 20_000)
        }
        if (reply is TerminalActionReply.Success) {
            sessionTokens.remove(conversationID, expectedToken)
            // The session truth moved on: stop surfacing its input refusals.
            clearInputIssue(conversationID)
        }
        return reply
    }

    /** Non-throwing cancellation read for the handoff: a cancelled caller gets
     * a typed refusal instead of an exception that could be mistaken for a
     * completed stop. */
    private suspend fun isHandoffCancelled(): Boolean =
        !kotlin.coroutines.coroutineContext.isActive

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

    /** Routes one raw PTY output page to its actual display owners.
     *
     * The SERVICE-OWNED engine of the conversation bound to this token is
     * fed, so the emulator screen survives pane reconstruction and — the
     * blank-output failure this repairs — a `terminalOutput` event is
     * never acked with no consumer at all. Registered listeners are
     * OBSERVERS (the engine feed is not duplicated per observer). All
     * deliveries run on [outputDispatcher] (Main in production): the
     * reused emulator is single-threaded, and pages keep mailbox order on
     * one serialized dispatcher.
     *
     * Ownership fences (review items 2): a page must have an admitted LIVE
     * Root generation (bound epoch > 0 matching `currentNativeEpoch()`) and
     * an exact conversation-token reverse-binding at admission — an epoch-0
     * "unbound" page is dropped, never delivered through a test-shaped hole.
     * The SAME predicate is re-validated at apply time on the serialized
     * dispatcher (where the pane's open/close mutations also run) BEFORE
     * the engine and AGAINST EACH OBSERVER (bytes queued before a
     * reset/stop can never touch a replacement session, and an observer
     * removed by a preceding observer is skipped). The engine feed runs
     * FIRST: it is the authoritative owner and one throwing or
     * unregistering observer can no longer starve it (cancellation still
     * propagates as structured cancellation). No double-feed: observers are
     * observers. */
    internal fun deliverTerminalOutput(sessionToken: String, payload: ByteArray) {
        if (payload.isEmpty()) return
        val admittedEpoch = boundEpoch
        if (admittedEpoch == 0L || currentNativeEpoch() != admittedEpoch) return
        val conversationID = sessionTokens.entries.firstOrNull { it.value == sessionToken }?.key
            ?: return
        scope.launch(outputDispatcher) {
            if (!deliveryOwnershipLive(admittedEpoch, conversationID, sessionToken)) return@launch
            engines[conversationID]?.feed(payload)
            val listeners = outputListeners[sessionToken]?.toList() ?: return@launch
            for (listener in listeners) {
                if (!deliveryOwnershipLive(admittedEpoch, conversationID, sessionToken)) {
                    return@launch
                }
                // Still-registered only: a preceding observer may have
                // disposed this one synchronously.
                if (outputListeners[sessionToken]?.contains(listener) != true) continue
                try {
                    listener(payload)
                } catch (cancel: kotlinx.coroutines.CancellationException) {
                    throw cancel
                } catch (_: Throwable) {
                    // Observer delivery is view-scoped best effort; the
                    // authoritative engine feed already ran above.
                }
            }
        }
    }

    /** The exact live-ownership predicate a terminalOutput delivery must
     * satisfy at admission AND at every apply step: same bound Root
     * generation still confirmed by the runtime authority, host not
     * stopping, and the page's token STILL bound to its conversation. */
    private fun deliveryOwnershipLive(
        admittedEpoch: Long,
        conversationID: String,
        sessionToken: String,
    ): Boolean = boundEpoch == admittedEpoch && currentNativeEpoch() == admittedEpoch &&
        !stopped.get() && sessionTokens[conversationID] == sessionToken

    /** Binds a native-committed Run sessionToken from an accepted,
     * REGISTERED run-open reply onto its owning conversation. This is the
     * ONLY route a Run token enters [sessionTokens] — no inference from
     * unbound output, no unbound/epoch-0 fallback: the admitting Root
     * generation must still be the live one (the same predicate shape as
     * [deliveryOwnershipLive]).
     *
     * Ownership is a per-conversation CAS against the binding captured at
     * registration (never the cached snapshot mirror, which can lag native
     * slot release behind an awaited finish/status): while the binding has
     * NOT moved, the accepted Run is authoritative and replaces its own
     * stale predecessor; a binding that DID move (a newer open/reset/stop,
     * or a newer accepted Run) fences this late reply — an old Run can
     * never steal a newer binding, and an accepted current Run's valid
     * binding is never discarded. On claim it mirrors `attachOrOpen`'s
     * fresh-open duties: the service-owned engine is ensured at this owned
     * boundary (independent of any view lifetime, so a Run before the pane
     * was ever mounted cannot drop its bytes), the previous generation's
     * typed-input refusals are cleared, and the projection is seeded for
     * the new token exactly once — never downgrading an already-arrived
     * authoritative status for it. */
    private fun bindRunOpenReply(intent: PendingRunOpen, sessionToken: String?) {
        if (sessionToken.isNullOrEmpty()) return
        if (intent.epoch == 0L || stopped.get() || boundEpoch != intent.epoch ||
            currentNativeEpoch() != intent.epoch) {
            return
        }
        var claimed = false
        sessionTokens.compute(intent.conversationID) { _, current ->
            if (current != intent.previousToken) {
                // The conversation's binding moved on after this Run was
                // submitted: this reply is stale — fence it, keep the newer
                // binding untouched.
                current
            } else {
                claimed = true
                sessionToken
            }
        }
        if (!claimed) return
        // The service-owned transcript buffer must exist at the binding
        // boundary itself: deliverTerminalOutput feeds engines[conversation],
        // and a Run accepted before any pane mounted would otherwise drop
        // every page even with a perfect binding. Production path is the
        // real bounded [engineFor] registry (reuse keeps transcript/reset
        // policy exactly as the pane-driven creation).
        engineEnsurer(intent.conversationID)
        // A fresh session bound: the previous generation's typed input
        // refusals no longer describe the live truth.
        clearInputIssue(intent.conversationID)
        val existing = snapshots[intent.conversationID]
        if (existing == null || existing.sessionToken != sessionToken) {
            snapshots[intent.conversationID] = TerminalSessionSnapshot(
                intent.conversationID, sessionToken, TerminalSessionPhase.STARTING, "run", "",
                null, null, null, 0)
        }
    }

    /** Binds an accepted UI (interactive) `attachOrOpen` token at the
     * actionReply event itself, before the waiter resumes and before native's
     * following `terminalOutput` / `terminalStatus` events are consumed. This
     * is the same ordering contract [bindRunOpenReply] already enforces for
     * Run sessions: the token enters [sessionTokens] only for the exact
     * admitted Root generation and only while this conversation's binding has
     * not moved (per-conversation CAS against the predecessor captured at
     * registration). A late/refused/fenced reply never binds.
     *
     * It seeds NO phase: the authoritative `terminalStatus` event stays the
     * only source of RUNNING/WAITING/EXITED. It only makes the pane key's
     * token visible so output ownership and the status projection can use the
     * SAME key the pane/engine already use. */
    private fun bindInteractiveOpenReply(intent: PendingInteractiveOpen, sessionToken: String?) {
        if (sessionToken.isNullOrEmpty()) return
        if (intent.epoch == 0L || stopped.get() || boundEpoch != intent.epoch ||
            currentNativeEpoch() != intent.epoch) {
            return
        }
        var claimed = false
        sessionTokens.compute(intent.conversationID) { _, current ->
            if (current != intent.previousToken && current != sessionToken) {
                // A newer open/reset/stop moved this conversation's binding
                // while this reply was in flight: fence the stale reply.
                current
            } else {
                claimed = true
                sessionToken
            }
        }
        if (!claimed) return
        // The service-owned engine must exist at the binding boundary: the
        // first output page follows the reply in mailbox order and must reach
        // the real conversation engine even before any pane re-composition.
        engineEnsurer(intent.conversationID)
        clearInputIssue(intent.conversationID)
        // An authoritative status that arrived before this reply was handled
        // (out-of-order event, never reordered here) belongs to the same
        // token; project it onto the bound key instead of leaving a STARTING
        // seed to overwrite it later.
        adoptSnapshotForToken(intent.conversationID, sessionToken)
    }

    /** Projects one authoritative native snapshot onto the conversation key
     * THIS host actually bound, using the exact session token as the ONLY
     * identity. Native events carry `UUID.uuidString` (canonical uppercase);
     * the App route/holder may retain another spelling of the same UUID, and
     * the first status can arrive before the deferred open coroutine seeds the
     * pane key. The session token is already the ownership key both sides use
     * for output delivery, so this re-keys the SAME phase/fault/exit metadata
     * — it never infers RUNNING from output and never adopts a different
     * session. A snapshot already under the bound key is left untouched when
     * it is the same token (the caller only invokes this while seeding). */
    private fun adoptSnapshotForToken(conversationID: String, sessionToken: String) {
        // Never downgrade an already-authoritative snapshot this pane key
        // holds for the same token (a status projection may already be newer
        // than the event-key copy this adoption was asked to mirror). A bare
        // STARTING seed is not authoritative and may be replaced.
        val byKey = snapshots[conversationID]
        if (byKey != null && byKey.sessionToken == sessionToken &&
            byKey.phase != TerminalSessionPhase.STARTING) return
        val candidates = snapshots.values.filter { it.sessionToken == sessionToken }
        val authoritative = candidates.firstOrNull { it.phase != TerminalSessionPhase.STARTING }
            ?: candidates.firstOrNull()
            ?: return
        val projected = authoritative.copy(conversationID = conversationID)
        snapshots[conversationID] = projected
        sessionWatchers[conversationID]?.forEach { it(projected) }
    }

    /** True once the conversation's projected session is actually settled:
     * no snapshot at all, or a phase that is not live (CLOSED/EXITED/
     * STOPPED/FAULT). `terminalClose` answers before native settlement, so
     * a reopen must observe this instead of racing the retiring operation
     * lease. Bounded: on timeout it reports the LAST observed truth and
     * never fabricates a settlement. */
    suspend fun awaitSessionSettled(conversationID: String, timeoutMillis: Long): Boolean {
        var waited = 0L
        while (waited < timeoutMillis) {
            val snap = snapshots[conversationID]
            if (snap == null || !snap.phase.isLive()) return true
            delay(50)
            waited += 50
        }
        val last = snapshots[conversationID]
        return last == null || !last.phase.isLive()
    }

    /** Registers an output listener for one session token; delivered FIFO
     * on the serialized output dispatcher (Main) ONLY while the observer
     * is still registered and the token still owns live delivery (see
     * [deliverTerminalOutput]). Returns the unregister hook (pane-owned,
     * disposed with the view — the ONLY view-scoped resource). Observers
     * only: the service-owned engine is fed by [deliverTerminalOutput],
     * so no listener may also feed it (double-render). */
    fun addOutputListener(sessionToken: String, listener: (ByteArray) -> Unit): () -> Unit {
        val listeners = outputListeners.getOrPut(sessionToken) {
            java.util.concurrent.CopyOnWriteArraySet()
        }
        listeners.add(listener)
        return { listeners.remove(listener) }
    }

    /* ---------------- run + LSP (Main mounts these into the IDE extras) ---------------- */

    suspend fun runDraft(conversationID: String, workspaceID: String?,
                         relativePath: String, language: String): TerminalActionReply {
        val requestID = UUID.randomUUID().toString()
        // Register the owned run-open intent BEFORE submit: native emits the
        // accepted Run's actionReply (carrying its sessionToken) BEFORE the
        // first output/status, and the reply handler can bind that token only
        // against this registered request/conversation/Root-epoch ownership.
        // Only a live generation may register — an epoch-0 or stopping host
        // creates no intent, so no unbound/epoch-0 fallback route exists.
        val admittedEpoch = boundEpoch
        val registered = admittedEpoch != 0L && !stopped.get() &&
            currentNativeEpoch() == admittedEpoch
        if (registered) {
            // Capture the EXACT current binding: the accepted reply may only
            // claim the conversation with a CAS against this predecessor, so
            // any newer open/reset/stop that moves the binding fences this
            // Run's late reply instead of letting it steal the conversation.
            pendingRunOpens[requestID] = PendingRunOpen(
                conversationID, admittedEpoch, sessionTokens[conversationID])
        }
        try {
            return submit(buildJsonObject {
                put("action", "runDraft")
                put("conversationID", conversationID)
                workspaceID?.let { put("workspaceID", it) }
                put("relativePath", relativePath); put("language", language)
                put("requestID", requestID)
            }, timeoutMillis = 30_000)
        } finally {
            // Timeout/cancel/refusal clears the intent: a late native reply
            // for a request this host no longer waits on must never bind an
            // unobserved session retroactively.
            if (registered) pendingRunOpens.remove(requestID)
        }
    }

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
                deliverTerminalOutput(token, payload)
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
                        // Native names this event with `UUID.uuidString`
                        // (canonical uppercase). The App route/holder key is
                        // the identity that owns [sessionTokens] and the
                        // pane/engine, and it may retain the original
                        // spelling of the SAME UUID. The session token is the
                        // ownership key both sides already use for output, so
                        // project this SAME authoritative snapshot (phase,
                        // fault, exit — never inferred from output) onto the
                        // bound key and notify its watchers. Exact token +
                        // live generation only; a different/absent binding is
                        // left alone.
                        val boundKeys = buildSet {
                            sessionTokens.entries.forEach {
                                if (it.value == snapshot.sessionToken) add(it.key)
                            }
                            snapshots.entries.forEach {
                                if (it.value.sessionToken == snapshot.sessionToken) add(it.key)
                            }
                        }
                        if (boundEpoch != 0L && currentNativeEpoch() == boundEpoch) {
                            for (key in boundKeys) {
                                if (key == snapshot.conversationID) continue
                                val projected = snapshot.copy(conversationID = key)
                                snapshots[key] = projected
                                sessionWatchers[key]?.forEach { it(projected) }
                            }
                        }
                        if (snapshot.phase == TerminalSessionPhase.CLOSED) {
                            // Retirement is ORDERED after accepted output: the
                            // reader admits terminalOutput pages onto the same
                            // serialized output dispatcher in mailbox order, so
                            // enqueuing the removal behind them lets an
                            // immediate-exit Run's final bytes reach their real
                            // owner instead of being stripped by a synchronous
                            // removal that raced the queued applies (device
                            // evidence 2026-10-25). The apply carries its OWN
                            // fences: the captured Root generation must still be
                            // the live bound one (an old-Root queued control can
                            // never remove a new-Root binding, even if a token
                            // string were reused), and the removal is an exact
                            // per-conversation CAS against the very binding this
                            // status describes — a replacement token or another
                            // conversation is never erased. The CLOSED snapshot
                            // itself is still applied synchronously above, so
                            // every phase reader stays truthful immediately, and
                            // pages admitted AFTER this removal still fail
                            // deliveryOwnershipLive.
                            val retirementEpoch = boundEpoch
                            scope.launch(outputDispatcher) {
                                if (retirementEpoch == 0L || stopped.get() ||
                                    boundEpoch != retirementEpoch ||
                                    currentNativeEpoch() != retirementEpoch) {
                                    return@launch
                                }
                                // Retire every key that actually maps this
                                // session by the exact token CAS (the App's
                                // original key included), so a replacement
                                // session is never erased.
                                sessionTokens.entries
                                    .filter { it.value == snapshot.sessionToken }
                                    .forEach { (key, _) ->
                                        sessionTokens.remove(key, snapshot.sessionToken)
                                    }
                            }
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
                // Service-owned run binding: an accepted Run's sessionToken
                // binds ONLY while this reply's waiter is still the
                // registered request owner — the `replies.remove(requestID)`
                // above is that atomic ownership transfer, so a non-null
                // [future] proves runDraft's timeout/cancel cleanup has NOT
                // released the request yet. A reply that outlives its waiter
                // consumes the intent without binding: a late native session
                // is never retroactively claimed as host-owned. Binding runs
                // SYNCHRONOUSLY here — before the waiter resumes and before
                // native's subsequent terminalOutput/terminalStatus events
                // reach this reader loop. A refused reply never binds
                // (never fabricated). The interactive `attachOrOpen` lane
                // uses the same rule: its accepted token is bound here,
                // before the deferred open coroutine resumes, so native's
                // first output/status events already see the pane binding.
                pendingInteractiveOpens.remove(requestID)?.let { intent ->
                    if (ok && future != null) {
                        bindInteractiveOpenReply(intent,
                            descriptor["sessionToken"]?.jsonPrimitive?.contentOrNull)
                    }
                }
                pendingRunOpens.remove(requestID)?.let { intent ->
                    if (ok && future != null) {
                        bindRunOpenReply(intent, descriptor["sessionToken"]?.jsonPrimitive?.contentOrNull)
                    }
                }
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
            val token = withContext(Dispatchers.IO) {
                nativeSubmitOverride?.invoke(descriptor, payload)
                    ?: TerminalNative.submitAction(descriptor, payload)
            }
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

/** Bounded PTY input lane: at most this many queued packets AND at most
 * this many queued payload bytes per conversation (an item COUNT alone is
 * not boundedness — each ByteArray is arbitrary). Beyond either limit the
 * lane refuses truthfully through inputIssueReporter instead of growing
 * unbounded or dropping silently. 256 KiB covers the worst realistic
 * burst (fast typing, long IME commits and pastes); the native mailbox
 * still applies its own payload limits (-106/-107) as the authority. */
private const val InputLaneCapacity = 128
private const val InputLaneByteBudget = 262_144L

/** The G04 domain's own purpose tag for a HUMAN-owned interactive terminal
 * (`G04TerminalSessionPurpose.purposeTag`). A language/run-draft session is
 * tagged "run" and is never a handoff candidate: only a manual terminal may
 * be offered for an explicit end-and-run decision. */
private const val TERMINAL_PURPOSE_INTERACTIVE = "interactive"

/** Coalescing cap for one queued PTY input frame (bytes). Consecutive
 * small admission frames from the same conversation/epoch/token merge at
 * the lane tail up to this size; larger frames still enter as separate
 * items and never merge. 2 KiB is far below the native mailbox payload
 * limits (the native -106/-107 bounds stay the authority) and keeps the
 * packet/byte refusals truthfully reachable once tails are full. */
private const val MaxCoalescedInputFrameBytes = 2_048

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
