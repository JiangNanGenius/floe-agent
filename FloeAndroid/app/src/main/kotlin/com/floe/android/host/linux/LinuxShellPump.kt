// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import android.content.Context
import com.floe.android.runtimeipc.RuntimeExecutionTrace
import com.floe.android.runtimeipc.RuntimeExecutionTrace.Stage
import com.floe.android.bridge.LinuxShellNative
import com.floe.android.runlifecycle.ForegroundLease
import com.floe.android.runlifecycle.OperationKind
import com.floe.android.runlifecycle.RunForegroundController
import com.floe.android.runlifecycle.RunStopHandler
import com.floe.android.runtimeipc.RuntimeConnection
import com.floe.android.runtimeipc.RuntimePeerProof
import com.floe.android.workspacebridge.CoreWorkspaceGrant
import com.floe.android.workspacebridge.WorkspaceOwnershipProbe
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/** App-owned transient transport. Original Swift services remain job/run authority. */
class LinuxShellPump(context: Context, private val scope: CoroutineScope) {
    private class AdmissionRefused : IllegalStateException("Runtime refused admission")
    private val context = context.applicationContext
    private val foreground = RunForegroundController.forApplication(context)
    private val epoch = AtomicLong()
    private val starts = Mutex()
    private val admissionClosed = AtomicBoolean()
    private data class TerminalReceipt(val epoch: Long, val runID: String, val toolCallID: String?, val sessionID: String?, val proof: String)
    private val terminals = LinkedHashMap<String, TerminalReceipt>()
    private val slots = Semaphore(4)
    private var reader: Job? = null
    private val work = ConcurrentHashMap<String, OwnedSession>()
    private class OwnedJobForeground(val epoch: Long) {
        val ended = AtomicBoolean()
        @Volatile var lease: ForegroundLease? = null
    }
    private val jobForeground = ConcurrentHashMap<String, OwnedJobForeground>()
    /** R3 first-use NON-EXECUTING workspace preflights (one per real run). */
    private val preflights = ConcurrentHashMap<String, OwnedPreflight>()
    /** App-owned live readiness controller. Set by Application BEFORE
     *  [start]; a null controller means no preflight can ever qualify
     *  (fail closed), never a boolean bypass. */
    @Volatile var readiness: LinuxRuntimeReadinessController? = null
    val boundNativeEpoch: Long get() = epoch.get()

    fun requestSessionStop(sessionID: String) {
        val owner = work.values.firstOrNull { it.sessionID == sessionID } ?: return
        scope.launch(Dispatchers.IO) { owner.requestStop() }
    }

    private inner class OwnedSession(val controlID: String, val nativeEpoch: Long, val runID: String, val toolCallID: String?) {
        lateinit var lease: ForegroundLease
        var client: RuntimeConnection? = null
        var workspaceGrant: CoreWorkspaceGrant? = null
        val connectionLock = Mutex()
        val settlementLock = Mutex()
        private var settledProof: String? = null
        val stop = AtomicBoolean()
        private val tracedStopTargets = ConcurrentHashMap.newKeySet<Stage>()
        @Volatile var sessionID: String? = null

        suspend fun exchange(operation: String, payload: JSONObject = JSONObject(), requestID: String = UUID.randomUUID().toString()): JSONObject {
            val connection = connectionLock.withLock {
                client ?: RuntimeConnection(context, lease.runtimePermit, workspaceGrant).also {
                    try { it.connect().get(15, TimeUnit.SECONDS); client = it }
                    catch (failure: Exception) { it.close(); throw failure }
                }
            }
            try { return result(connection.exchange(operation, payload, requestID)) }
            catch (failure: Exception) {
                connectionLock.withLock { if (client === connection) { client = null; connection.close() } }
                throw failure
            }
        }

        suspend fun requestStop() {
            val stopStage = if (sessionID == null) Stage.PUMP_STOP_REQUEST else Stage.PUMP_STOP_SESSION
            if (tracedStopTargets.add(stopStage)) RuntimeExecutionTrace.mark(stopStage)
            stop.set(true)
            val target = sessionID?.let { JSONObject().put("sessionID", it) }
                ?: JSONObject().put("requestID", controlID)
            try { exchange("shell.cancel", target) } catch (_: Exception) { /* receipt/watch retains ownership */ }
        }

        suspend fun finish(proof: JSONObject) = settlementLock.withLock {
            settledProof?.let { return@withLock JSONObject(it) }
            // Drain Core file callbacks before publishing any terminal proof,
            // completing the native waiter, or releasing original Root work.
            val grant = workspaceGrant
            grant?.close()
            // Only an ACTUAL Core-owned export reply can prove saved files.
            // Runtime result strings never qualify this boundary.
            val saved = grant?.exportReceipt()?.let { bytes -> runCatching { objectBytes(bytes) }.getOrNull() }
            proof.remove("workspaceStatus"); proof.remove("workspaceRecoveryRef")
            val recovery = saved?.optJSONObject("recovery")
            val sameSession = grant != null && recovery?.optString("sessionKey") == grant.sessionKey
            val status = saved?.optString("result")?.takeIf {
                sameSession && saved?.optBoolean("ok") == true && it in setOf("synced", "conflict", "aborted")
            } ?: "unknown"
            proof.put("workspaceStatus", status)
            if (status != "synced" && grant != null) proof.put("workspaceRecoveryRef", grant.sessionKey)
            // Additive OPTIONAL recovery projection: the runtime's own import
            // facts (kept ONLY when the exact session/run identity matches)
            // merged with the ACTUAL Core-side EXPORT_FINISH reply when this
            // grant captured one. Missing/unbound → the field stays absent;
            // nothing is zeroed or fabricated.
            val pageRecovery = proof.optJSONObject("workspaceRecovery")
            proof.remove("workspaceRecovery")
            val merged = runCatching {
                mergeWorkspaceRecovery(
                    pageRecovery?.let { kotlinx.serialization.json.Json.parseToJsonElement(it.toString())
                        as? kotlinx.serialization.json.JsonObject },
                    saved?.let { kotlinx.serialization.json.Json.parseToJsonElement(it.toString())
                        as? kotlinx.serialization.json.JsonObject },
                    grant?.sessionKey,
                    runID,
                )
            }.getOrNull()?.toString()
            if (merged != null) proof.put("workspaceRecovery", JSONObject(merged))
            workspaceGrant = null
            proof.put("epoch", nativeEpoch)
            synchronized(terminals) {
                terminals[controlID] = TerminalReceipt(nativeEpoch, runID, toolCallID, sessionID, proof.toString())
                while (terminals.size > 128) terminals.remove(terminals.keys.first())
            }
            connectionLock.withLock { client?.close(); client = null }
            lease.close()
            work.remove(controlID, this)
            settledProof = proof.toString()
            JSONObject(proof.toString())
        }

    }

    /** Caller passes the ACTUAL accepted native epoch, off Main. No guessed generation. */
    suspend fun start(acceptedEpoch: Long) = starts.withLock {
        if (epoch.get() == acceptedEpoch) return@withLock
        check(acceptedEpoch > 0 && epoch.get() == 0L && work.isEmpty())
        check(LinuxShellNative.bindEpoch(acceptedEpoch) == 0)
        epoch.set(acceptedEpoch)
        admissionClosed.set(false)
        reader = scope.launch(Dispatchers.IO) {
            while (isActive && epoch.get() == acceptedEpoch) {
                slots.acquire()
                val claim = LinuxShellNative.next(1_000)
                if (claim <= 0) { slots.release(); if (claim < 0) break; continue }
                scope.launch(Dispatchers.IO) {
                    try { handle(claim, acceptedEpoch) } finally { slots.release() }
                }
            }
        }
    }

    /** Fence NEW execution, retain the proof/poll channel for owned cleanup. */
    suspend fun stop(expectedEpoch: Long) = starts.withLock {
        if (expectedEpoch <= 0 || epoch.get() != expectedEpoch) return@withLock
        admissionClosed.set(true)
        LinuxShellNative.suspendAdmission(expectedEpoch)
        work.values.forEach { owned -> scope.launch(Dispatchers.IO) { owned.requestStop() } }
        // Target-scoped: cancels ONLY this host's own preflight requests.
        // Unrelated shell/job work on the runtime side is never touched.
        preflights.values.forEach { owned -> scope.launch(Dispatchers.IO) { owned.requestCancel() } }
    }

    suspend fun stopAndDrain(expectedEpoch: Long, budgetMillis: Long = 15_000): Boolean {
        stop(expectedEpoch)
        val drained = withTimeoutOrNull(budgetMillis) {
            while (work.isNotEmpty() || preflights.isNotEmpty()) delay(100)
            // Job/shell processors must consume real release proofs before
            // their mailbox is fenced and the original root can close.
            com.floe.android.bridge.JobsNative.drain(10_000) == 1 && LinuxShellNative.drain(10_000) == 1
        } ?: false
        if (!drained) return false
        // Best-effort owned stale payload pruning; unknown/active entries
        // are retained by the original Core run proof, never assumed done.
        runCatching { com.floe.android.bridge.LinuxWorkspaceNative.sweep(
            System.currentTimeMillis() / 1000, 24L * 60 * 60) }
        starts.withLock {
            if (expectedEpoch > 0 && epoch.compareAndSet(expectedEpoch, 0)) {
                LinuxShellNative.fenceEpoch(expectedEpoch)
                reader?.cancelAndJoin(); reader = null
            }
        }
        return true
    }

    private suspend fun handle(claim: Long, acceptedEpoch: Long) {
        try {
            check(epoch.get() == acceptedEpoch && LinuxShellNative.isLive(claim) == 1)
            val descriptor = objectBytes(checkNotNull(LinuxShellNative.describe(claim)))
            val payload = objectBytes(checkNotNull(LinuxShellNative.payload(claim)))
            val operation = descriptor.getString("operation")
            if (operation == "host.jobOwnership") {
                complete(claim, 0, jobOwnership(claim, payload, acceptedEpoch)); return
            }
            if (operation == "host.shellSettlement") {
                complete(claim, 0, settlement(payload, acceptedEpoch)); return
            }
            if (operation == "host.workspacePreflight") {
                // R3 first-use NON-EXECUTING preflight (Main amendment
                // r3-first-use-blocking-makeService-hook-v1). Handled BEFORE
                // the shell admission gates: it never starts a shell and no
                // command can cross this session.
                preflight(claim, payload, acceptedEpoch); return
            }
            if (operation == "shell.start") {
                check(!admissionClosed.get())
                startSession(claim, payload, acceptedEpoch); return
            }
            require(operation in setOf("shell.poll", "shell.input", "shell.resize", "shell.cancel"))
            val sessionID = payload.getString("sessionID")
            val owner = work.values.firstOrNull { it.sessionID == sessionID }
            if (owner == null && operation == "shell.poll") {
                val terminal = synchronized(terminals) { terminals.values.firstOrNull { it.epoch == acceptedEpoch && it.sessionID == sessionID } }
                checkNotNull(terminal)
                val client = RuntimeConnection(context)
                try {
                    client.connect().get(15, TimeUnit.SECONDS)
                    val response = result(client.exchange(operation, payload))
                    require(response.getString("sessionID") == sessionID)
                    copyWorkspaceProof(response, JSONObject(terminal.proof))
                    complete(claim, 0, response)
                } finally { client.close() }
                return
            }
            if (owner == null && operation == "shell.input" &&
                payload.keys().asSequence().toSet() == setOf("sessionID", "inputBase64") &&
                isEofInputPage(payload.getString("inputBase64"))
            ) {
                // G03-R3 fast-exit stdin contract: the trusted one-shot
                // backend ALWAYS commands exactly one trailing EMPTY
                // shell.input EOF page after the start reply, including nil
                // stdin. A fast command can settle and retire the session
                // BEFORE that page is claimed (candidate 06's ~2s lifecycle).
                // The write-end close then already belongs to the REAL
                // terminal lifecycle, so the honest answer is the SAME
                // REJECTED EOF the running engine reports — bound to the
                // recorded actual terminal — never a fabricated accepted
                // delivery, and NEVER any data written to a finished
                // session. A NON-empty input page here stays refused exactly
                // as before (checkNotNull(owner) below).
                val terminal = synchronized(terminals) { terminals.values.lastOrNull { it.epoch == acceptedEpoch && it.sessionID == sessionID } }
                checkNotNull(terminal)
                val proof = JSONObject(terminal.proof)
                val ack = JSONObject().put("sessionID", sessionID).put("acceptedBytes", 0)
                    .put("stdinEof", "rejected").put("reason", "sessionReleased")
                for (key in listOf("leaseReleased", "cancelled", "stopReason", "exitCode", "termSig", "waitErrno")) {
                    if (proof.has(key)) ack.put(key, proof.get(key))
                }
                complete(claim, 0, ack)
                return
            }
            checkNotNull(owner)
            val response = if (operation == "shell.cancel") {
                owner.requestStop(); JSONObject().put("state", "stop_requested")
            } else {
                val first = owner.exchange(operation, payload)
                // Poll is an immediate memory snapshot; input/resize are
                // queued controls. Route by the operation, never by a
                // process state that overlaps the receipt vocabulary.
                if (requiresControlReceipt(operation)) awaitReceipt(owner, first) else first
            }
            if (operation == "shell.poll" && response.optBoolean("leaseReleased")) {
                val proof = owner.finish(terminalProof(response))
                copyWorkspaceProof(response, proof)
            }
            complete(claim, 0, response)
        } catch (_: Exception) { complete(claim, 1, JSONObject().put("code", "runtime_unavailable")) }
    }

    private suspend fun startSession(claim: Long, payload: JSONObject, acceptedEpoch: Long) {
        val runID = UUID.fromString(payload.getString("runID")).toString()
        val host = payload.remove("host") as? JSONObject
        val callID = host?.optString("toolCallID")?.takeIf { it.isNotEmpty() }
        require(callID == null || callID.length <= 256)
        val owned = OwnedSession(UUID.randomUUID().toString(), acceptedEpoch, runID, callID)
        var possiblyAdmitted = false
        var handedToWatcher = false
        try {
            // Ownership is registered BEFORE any IPC may start a process.
            RuntimeExecutionTrace.mark(Stage.PUMP_REGISTER)
            owned.lease = foreground.acquireOperation(owned.controlID, OperationKind.LOCAL_EXECUTION,
                RunStopHandler { scope.launch(Dispatchers.IO) { owned.requestStop() } })
            work[owned.controlID] = owned
            RuntimeExecutionTrace.mark(Stage.PUMP_OWNED)
            if (admissionClosed.get() || owned.stop.get() || LinuxShellNative.shouldStop(claim) != 0) error("Caller stopped before admission")
            RuntimeExecutionTrace.mark(Stage.PUMP_GRANT)
            val grant = CoreWorkspaceGrant.create(context, acceptedEpoch, payload.getString("runID"),
                trustedCallID = callID?.takeIf { it.startsWith("jobs.") },
                isOwned = WorkspaceOwnershipProbe {
                    // Cleanup/writeback remains owned during a stop request.
                    // Current real FGS protection separately gates process execution.
                    epoch.get() == acceptedEpoch && work[owned.controlID] === owned && !owned.lease.isClosed
                }, authority = CoreWorkspaceNativeAuthority()) ?: error("Owned workspace unavailable")
            owned.workspaceGrant = grant
            check(grant.projectID == payload.getString("projectID"))
            RuntimeExecutionTrace.mark(Stage.PUMP_GRANT_READY)
            // A transport failure may follow accepted dispatch. Never replay it.
            possiblyAdmitted = true
            RuntimeExecutionTrace.mark(Stage.PUMP_DISPATCH)
            val response = owned.exchange("shell.start", payload, owned.controlID)
            RuntimeExecutionTrace.mark(Stage.PUMP_REQUEST_ACCEPTED)
            val started = awaitReceipt(owned, response) {
                if (LinuxShellNative.shouldStop(claim) != 0) owned.requestStop()
            }
            RuntimeExecutionTrace.mark(Stage.PUMP_RECEIPT_RETURNED)
            owned.sessionID = started.getString("sessionID")
            RuntimeExecutionTrace.mark(Stage.PUMP_SESSION_READY)
            if (owned.stop.get() || LinuxShellNative.shouldStop(claim) != 0) {
                owned.requestStop()
                handedToWatcher = true
                scope.launch(Dispatchers.IO) { watch(owned, failedStartClaim = claim) }
                return // keep the claimed receipt until real release
            }
            complete(claim, 0, started)
            handedToWatcher = true
            scope.launch(Dispatchers.IO) { watch(owned) }
        } catch (failure: Exception) {
            RuntimeExecutionTrace.mark(if (failure is AdmissionRefused) Stage.PUMP_ADMISSION_REFUSED else Stage.PUMP_START_EXCEPTION)
            if (failure is AdmissionRefused) possiblyAdmitted = false
            if (!possiblyAdmitted) {
                if (work.containsKey(owned.controlID)) owned.finish(JSONObject().put("state", "quiescent"))
                complete(claim, 1, JSONObject().put("code", "runtime_not_started"))
            }
        } finally {
            if (!handedToWatcher && work.containsKey(owned.controlID)) {
                if (possiblyAdmitted) {
                    owned.stop.set(true)
                    scope.launch(Dispatchers.IO) { watch(owned, failedStartClaim = claim) }
                } else owned.finish(JSONObject().put("state", "quiescent"))
            }
        }
    }

    private suspend fun watch(owned: OwnedSession, failedStartClaim: Long? = null) {
        // This service-owned reconciliation outlives views and native waiters.
        withContext(NonCancellable) {
            RuntimeExecutionTrace.mark(Stage.PUMP_WATCH_ENTER)
            val emittedStages = mutableSetOf<Stage>()
            while (true) {
                try {
                    if (owned.stop.get()) owned.requestStop()
                    if (owned.sessionID == null) {
                        val receipt = owned.exchange("request.status", JSONObject().put("requestID", owned.controlID))
                        val stage = when (receipt.optString("state")) {
                            "completed" -> Stage.PUMP_WATCH_COMPLETED
                            "failed" -> Stage.PUMP_WATCH_FAILED
                            "queued", "running" -> Stage.PUMP_WATCH_WAITING
                            else -> Stage.PUMP_WATCH_UNKNOWN
                        }
                        if (emittedStages.add(stage)) RuntimeExecutionTrace.mark(stage)
                        if (receipt.optString("state") == "completed") {
                            owned.sessionID = receipt.getJSONObject("result").getString("sessionID")
                        }
                    }
                    val session = owned.sessionID
                    if (session != null) {
                        val page = owned.exchange("shell.poll", JSONObject().put("sessionID", session)
                            .put("cursor", 0).put("maxBytes", 1))
                        if (page.getBoolean("leaseReleased")) {
                            owned.finish(terminalProof(page))
                            RuntimeExecutionTrace.mark(Stage.PUMP_FINISHED)
                            failedStartClaim?.let { complete(it, 1, JSONObject().put("code", "runtime_start_stopped")) }
                            return@withContext
                        }
                    }
                    // A new component process has no old receipt. Initializing
                    // its metadata performs runtime-UID quiescence recovery;
                    // status alone (before recovery) is never proof.
                    awaitReceipt(owned, owned.exchange("install.status"))
                    if (!owned.exchange("status").getBoolean("active")) {
                        owned.finish(JSONObject().put("state", "quiescent"))
                        RuntimeExecutionTrace.mark(Stage.PUMP_FINISHED)
                        failedStartClaim?.let { complete(it, 1, JSONObject().put("code", "runtime_start_interrupted")) }
                        return@withContext
                    }
                } catch (_: Exception) {
                    if (emittedStages.add(Stage.PUMP_WATCH_EXCEPTION)) RuntimeExecutionTrace.mark(Stage.PUMP_WATCH_EXCEPTION)
                    /* unresolved means retain, never replay */
                }
                delay(1_000)
            }
        }
    }

    // MARK: - R3 first-use NON-EXECUTING workspace preflight
    // (Main amendment r3-first-use-blocking-makeService-hook-v1; the frozen
    // Core sequence 1-9 with the real grant/lease/index evidence.)

    private class PreflightUncertain(val reason: String) : IllegalStateException(reason)

    private inner class OwnedPreflight(
        val controlID: String, val nativeEpoch: Long, val runID: String,
        val conversationID: String, val environmentID: String?,
    ) {
        lateinit var lease: ForegroundLease
        var client: RuntimeConnection? = null
        var workspaceGrant: CoreWorkspaceGrant? = null
        val connectionLock = Mutex()
        val stop = AtomicBoolean()
        /** True once a request may have crossed the wire. Uncertain claims
         *  are retired ONLY by an authenticated same-request terminal or a
         *  proven peer-generation retirement — never by a time budget. */
        val dispatchedRemote = AtomicBoolean()
        private val grantClosed = AtomicBoolean()
        val reconcileStarted = AtomicBoolean()
        /** The runtime PROCESS generation this claim was actually dispatched
         *  to (measured anchored identity). Reconciliation compares against
         *  it; it never trusts an unmeasured string. */
        @Volatile var dispatchedPeerToken: String? = null

        suspend fun exchange(operation: String, payload: JSONObject, requestID: String = controlID): JSONObject {
            val connection = connectionLock.withLock {
                client ?: RuntimeConnection(context, lease.runtimePermit, workspaceGrant).also {
                    try { it.connect().get(15, TimeUnit.SECONDS); client = it }
                    catch (failure: Exception) { it.close(); throw failure }
                }
            }
            try { return result(connection.exchange(operation, payload, requestID)) }
            catch (failure: Exception) {
                connectionLock.withLock { if (client === connection) { client = null; connection.close() } }
                throw failure
            }
        }

        /** Target-scoped cancel for THIS preflight request only (the original
         *  control UUID travels as the wire request id). It never stops an
         *  unrelated shell/job workload A. A cancel REQUEST is never treated
         *  as settlement: the owned reconciliation still has to observe the
         *  same request's real terminal (or proven retirement) before any
         *  ownership release. */
        suspend fun requestCancel() {
            stop.set(true)
            try { exchange("workspace.preflight.cancel", JSONObject().put("requestID", controlID)) }
            catch (_: Exception) { /* receipt/watch retains ownership */ }
        }

        /** Close proof channels in Main's order: authenticated connection,
         *  then the drained Core-side grant close, then the foreground lease.
         *  Only a FAILED drained GRANT close RETAINS ownership (returns false;
         *  the grant and map entry stay exactly as claimed) so a swallowed
         *  close can never be followed by an ingest. Callers retry through
         *  the owned reconciliation. Idempotent: already-closed channels are
         *  not re-run.
         *
         *  ACTUAL ForegroundLease contract (Main API review, core/runlifecycle
         *  ForegroundLease.kt): close() returns whether THIS close removed the
         *  registration from the refcounted owned set (last lease) — NOT a
         *  per-holder success flag; false is also normal for an already-closed
         *  lease, another holder or a newer same-id registration, and the
         *  service stops itself when the set empties. A stale object can never
         *  touch a newer registration (the registry generation check owns
         *  that). So this lease's discharge is proven by its own idempotent
         *  CAS `isClosed`, NEVER by the refcount boolean: close this lease
         *  exactly once and never retain the claimed map entry on a false
         *  return that already discharged our contribution. */
        suspend fun settle(): Boolean {
            connectionLock.withLock { client?.close(); client = null }
            val grant = workspaceGrant
            if (grant != null && !grantClosed.get()) {
                if (!runCatching { grant.close() }.isSuccess) return false
                grantClosed.set(true)
                workspaceGrant = null
            }
            if (::lease.isInitialized && !lease.isClosed) lease.close()
            preflights.remove(controlID, this)
            return true
        }
    }

    /**
     * Owned, cancellable reconciliation for a CLAIMED preflight round trip
     * whose settlement is still uncertain (unknown receipt, transport loss,
     * caller cancellation). Reuses the pump's existing OwnedSession `watch`
     * ownership pattern: a service-owned job that outlives the caller and
     * the mailbox claim, makes bounded individual polls, and releases
     * ownership ONLY on an authenticated SAME-request terminal or a PROVEN
     * peer/process retirement. It never ingests, activates, re-qualifies
     * (the claim was already answered honestly unavailable/cancelled or is
     * lost), and never fabricates a terminal from a budget. A failed channel
     * close is retried on the next bounded poll; until then the ORIGINAL
     * grant + foreground lease + mailbox claim stay retained.
     */
    private fun reconcilePreflightOwnership(owned: OwnedPreflight) {
        if (!owned.reconcileStarted.compareAndSet(false, true)) return
        scope.launch(Dispatchers.IO) {
            while (preflights[owned.controlID] === owned) {
                if (!owned.dispatchedRemote.get()) {
                    // Nothing crossed the wire: only the LOCAL channel close
                    // remains; a failed close keeps the entry claimed.
                    owned.settle()
                } else {
                    var state: String? = null
                    var identity: String? = null
                    try {
                        state = owned.exchange("request.status", JSONObject().put("requestID", owned.controlID)).optString("state")
                        if (state == "unknown" && owned.dispatchedPeerToken != null) {
                            // Kernel receipts are in-memory per process: a
                            // SUCCESSFUL exchange answering "unknown" for a
                            // token we stamped is itself a new-generation
                            // signal. Compare the measured identity — only a
                            // DIFFERENT generation proves the original peer/
                            // process retired (and its successor ran the
                            // ORIGINAL recover()/census at service init).
                            identity = runCatching {
                                LinuxRuntimeReadinessController.processIdentity(
                                    owned.exchange("status", JSONObject()))
                            }.getOrNull()
                        }
                    } catch (_: Exception) {
                        // Transport loss alone proves nothing; only a
                        // DIFFERENT measured generation on a fresh
                        // authenticated connection proves the original peer
                        // is retired (and its successor ran the ORIGINAL
                        // recover()/census at init).
                        runCatching {
                            identity = LinuxRuntimeReadinessController.processIdentity(
                                owned.exchange("status", JSONObject()))
                        }
                    }
                    if (isPreflightTerminalReceipt(state) || isPeerRetirementProven(owned.dispatchedPeerToken, identity)) {
                        if (isPeerRetirementProven(owned.dispatchedPeerToken, identity))
                            runCatching { readiness?.invalidateForEpoch(owned.nativeEpoch, "preflight_peer_retired") }
                        owned.settle() // false: channels retained; retried next bounded poll
                    } else if (owned.stop.get()) {
                        runCatching { owned.requestCancel() } // ONLY the matching control cancel
                    }
                }
                delay(1_000)
            }
        }
    }

    private suspend fun preflight(claim: Long, request: JSONObject, acceptedEpoch: Long) {
        val runID = request.optString("runID")
        val conversationID = request.optString("conversationID")
        val environmentID = request.optString("environmentID").takeIf { it.isNotEmpty() }
        val allowedKeys = setOf("runID", "conversationID", "rootEpoch") +
            if (environmentID != null) setOf("environmentID") else emptySet()
        fun reply(status: String, reason: String?): JSONObject =
            JSONObject().put("status", status).put("rootEpoch", acceptedEpoch)
                .put("runID", runID).put("conversationID", conversationID)
                .also {
                    if (status != "ready") {
                        it.put("reason", (reason ?: status).take(32))
                        // G03-R3 bounded diagnostic (Main steers 2026-10-23):
                        // the typed stage token rides the EXISTING refusal
                        // vocabulary into the readiness controller so the
                        // real device failure is observable without logs.
                        // The token is tagged with THIS pump's captured
                        // accepted epoch: a late callback from an old Root
                        // can never surface under a newer generation.
                        // Recording qualifies nothing.
                        readiness?.recordPreflightStage(acceptedEpoch, reason ?: status)
                    }
                }
        val controller = readiness
        // Exact canonical identities, closed request shape, epoch match.
        // Anything else is a typed unavailable — a malformed request can
        // never be retried into qualification. The refusal echoes ONLY the
        // pump's own accepted epoch (untrusted request strings are never
        // reflected back).
        if (acceptedEpoch <= 0 || controller == null ||
            request.keys().asSequence().toSet() != allowedKeys ||
            request.optLong("rootEpoch") != acceptedEpoch ||
            !isCanonicalUUID(runID) || !isCanonicalUUID(conversationID) ||
            (environmentID != null && !ENVIRONMENT_ID.matches(environmentID))
        ) {
            readiness?.recordPreflightStage(acceptedEpoch, "request_invalid")
            complete(claim, 0, JSONObject().put("status", "unavailable")
                .put("rootEpoch", acceptedEpoch).put("reason", "request_invalid")); return
        }
        if (admissionClosed.get() || LinuxShellNative.shouldStop(claim) != 0) {
            complete(claim, 0, reply("cancelled", "run_or_epoch_stopped")); return
        }
        if (controller.boundEpoch != acceptedEpoch || !controller.prerequisitesLive(acceptedEpoch)) {
            // Fast typed skip for an unconfigured/unproven peer: the Core
            // hook continues with ordinary non-Linux tools; no failed user
            // call and no bootstrap attempt.
            complete(claim, 0, reply("unavailable", "prerequisites_unverified")); return
        }
        val owned = OwnedPreflight(UUID.randomUUID().toString(), acceptedEpoch, runID, conversationID, environmentID)
        var registered = false
        var dispatched = false
        try {
            // Foreground/work ownership is registered BEFORE any IPC or file IO.
            owned.lease = foreground.acquireOperation(owned.controlID, OperationKind.LOCAL_EXECUTION,
                RunStopHandler { scope.launch(Dispatchers.IO) { owned.requestCancel() } })
            preflights[owned.controlID] = owned
            registered = true
            if (admissionClosed.get() || owned.stop.get() || LinuxShellNative.shouldStop(claim) != 0)
                error("caller_stopped")
            // The ORIGINAL grant ABI mints from the accepted Root + the
            // ORIGINAL run/conversation/workspace ownership rows. A run that
            // is not actually active/owned yields NO grant (null) — a typed
            // unavailable, never a synthetic session.
            // Closed-token refusal discriminator (G03-R3 grant refusal
            // observation): create() reports EXACTLY ONE fixed closed token
            // naming the actual null branch (or the flat native reply
            // code) through the run-owned observer; it rides the EXISTING
            // bounded stage recording below, replacing the single collapsed
            // "workspace_unresolved" observation with the precise branch
            // evidence. The historical token stays the fallback when null
            // came back without a report. Recording qualifies nothing; the
            // admission, ownership, cancellation and drain semantics of
            // this lane are unchanged.
            var grantRefusal: String? = null
            val grant = CoreWorkspaceGrant.create(context, acceptedEpoch, runID, trustedCallID = null,
                isOwned = WorkspaceOwnershipProbe {
                    epoch.get() == acceptedEpoch && preflights[owned.controlID] === owned && !owned.lease.isClosed
                }, authority = CoreWorkspaceNativeAuthority(),
                refusalObserver = { token -> grantRefusal = token })
                ?: error(grantRefusal ?: "workspace_unresolved")
            owned.workspaceGrant = grant
            // Stamp the claim with the ACTUAL anchored generation it is being
            // dispatched to; reconciliation later proves retirement ONLY by
            // a different measured generation, never by an elapsed budget.
            owned.dispatchedPeerToken = controller.anchoredProcessToken(acceptedEpoch)
            val payload = JSONObject().put("projectID", grant.projectID).put("runID", runID)
                .put("conversationID", conversationID)
                .also { if (environmentID != null) it.put("environmentID", environmentID) }
            // Explicit pre-queue refusals (busy) are retryable with the SAME
            // control UUID; a transport loss is uncertain, and the kernel's
            // per-request dedupe makes a same-ID re-send a receipt read, not
            // a blind side-effect replay. No different-ID replay ever occurs.
            var first: JSONObject? = null
            var attempt = 0
            while (first == null && attempt < 6) {
                attempt += 1
                if (owned.stop.get() || LinuxShellNative.shouldStop(claim) != 0)
                    error("caller_stopped")
                try {
                    first = owned.exchange("workspace.preflight", payload)
                    dispatched = true; owned.dispatchedRemote.set(true)
                } catch (failure: AdmissionRefused) {
                    if (attempt >= 6) error("runtime_busy") else delay(1_000)
                } catch (failure: Exception) {
                    dispatched = true; owned.dispatchedRemote.set(true)
                    if (attempt >= 6) throw failure else delay(500)
                }
            }
            val outcome = awaitPreflightReceipt(owned, checkNotNull(first)) {
                if (LinuxShellNative.shouldStop(claim) != 0) owned.requestCancel()
            }
            settlePreflight(claim, owned, controller, outcome, acceptedEpoch, runID, conversationID)
        } catch (failure: PreflightUncertain) {
            // Timeout, cancellation, transport loss and an unknown receipt
            // are NOT actual retirement of the claimed remote IO. Answer THIS
            // claim honestly ONCE (a late terminal releases ownership only
            // and never re-qualifies), then retain the ORIGINAL grant +
            // foreground + mailbox claim and hand the entry to its own
            // cancellable reconciliation until the SAME request settles on
            // the peer or peer/process retirement is actually proven.
            val code = boundedToken(failure.reason)
            if (LinuxShellNative.isLive(claim) == 1 && LinuxShellNative.shouldStop(claim) == 0)
                complete(claim, 0, reply(if (code in CANCEL_CODES) "cancelled" else "unavailable", code))
            if (code !in CANCEL_CODES && registered) controller.invalidateForEpoch(acceptedEpoch, "preflight_$code".take(48))
            reconcilePreflightOwnership(owned)
        } catch (failure: Exception) {
            // Uncertain or aborted round trip: KEEP ownership (grant, lease,
            // receipt) until the original request actually settles on the
            // peer; then settle channels and report honestly.
            val cancelled = failure is kotlinx.coroutines.CancellationException
            if (dispatched) {
                // Claimed remote IO may still run: never drop it on budget,
                // transport loss or caller cancellation.
                val code = if (cancelled) "caller_stopped" else boundedCode(failure)
                if (LinuxShellNative.isLive(claim) == 1 && LinuxShellNative.shouldStop(claim) == 0)
                    complete(claim, 0, reply(
                        if (cancelled || code in CANCEL_CODES) "cancelled" else "unavailable", code))
                // An explicit never-accepted busy refusal does NOT invalidate
                // facts (nothing broke); everything else fences the
                // generation until a fresh full re-ingest.
                if (code != "runtime_busy" && code !in CANCEL_CODES && registered)
                    controller.invalidateForEpoch(acceptedEpoch, "preflight_$code".take(48))
                reconcilePreflightOwnership(owned)
            } else {
                // Nothing crossed the wire: only local channel closure can
                // remain, and a FAILED close still retains ownership.
                if (!owned.settle()) reconcilePreflightOwnership(owned)
                val code = boundedCode(failure)
                if (code != "runtime_busy" && code !in CANCEL_CODES && registered)
                    controller.invalidateForEpoch(acceptedEpoch, "preflight_$code".take(48))
                complete(claim, 0, reply(if (code in CANCEL_CODES) "cancelled" else "unavailable", code))
            }
            if (cancelled) throw failure
        }
    }

    /** Verify → ingest → activate → typed complete. Called ONLY with an
     *  authenticated SAME-request terminal receipt (never a fabricated
     *  unknown/budget outcome). Each branch either closes the owned channels
     *  for real (a failed drained close RETAINS them for the owned
     *  reconciliation) or hands them to reconciliation; only REAL evidence
     *  from the grant's captured Core-side EXPORT_FINISH receipt plus the
     *  runtime's original lease proof can produce a "ready" reply. A lost or
     *  already-answered claim NEVER re-qualifies (late success is settled for
     *  ownership release only and discarded for readiness). */
    private suspend fun settlePreflight(
        claim: Long, owned: OwnedPreflight,
        controller: LinuxRuntimeReadinessController, outcome: JSONObject,
        acceptedEpoch: Long, runID: String, conversationID: String,
    ) {
        fun reply(status: String, reason: String?): JSONObject =
            JSONObject().put("status", status).put("rootEpoch", acceptedEpoch)
                .put("runID", runID).put("conversationID", conversationID)
                .also {
                    if (status != "ready") {
                        it.put("reason", (reason ?: status).take(32))
                        // Same bounded diagnostic recording as the dispatch
                        // lane's reply builder (closed tokens only, tagged
                        // with this claim's captured accepted epoch).
                        controller.recordPreflightStage(acceptedEpoch, reason ?: status)
                    }
                }
        if (owned.stop.get() || LinuxShellNative.shouldStop(claim) != 0) {
            // The cancel was already proven settled (this call carries the
            // real same-request outcome); a failed channel close still keeps
            // the entry claimed for the owned reconciliation to retry.
            if (!owned.settle()) reconcilePreflightOwnership(owned)
            complete(claim, 0, reply("cancelled", "preflight_cancelled")); return
        }
        if (outcome.optString("status") != "ready") {
            val reason = boundedToken(outcome.optString("reason", "preflight_aborted"))
            if (!owned.settle()) reconcilePreflightOwnership(owned)
            // A target-scoped CANCELLATION of this own preflight is not a
            // generation failure: ordinary facts stay live and unrelated
            // conversations keep their qualification.
            if (reason !in CANCEL_CODES) controller.invalidateForEpoch(acceptedEpoch, "preflight_$reason".take(48))
            complete(claim, 0, reply(if (reason in CANCEL_CODES) "cancelled" else "unavailable", reason))
            return
        }
        val leaseProofDigest = outcome.optString("leaseProofDigest")
        val sessionToken = LinuxRuntimeReadinessController.processIdentity(outcome)
        val peerProof = runCatching { owned.client?.currentPeerProof() }.getOrNull()
        // The ONLY accepted file-sync evidence: the actual Core-owned
        // terminal EXPORT_FINISH reply captured by THIS grant (result
        // "synced", terminal marker, this session key, current epoch).
        val receiptBytes = owned.workspaceGrant?.exportReceipt()
        val sessionKey = owned.workspaceGrant?.sessionKey
        // Drained grant close precedes ingest (session_close ordering). A
        // FAILED close RETAINS ownership: never swallow it and still ingest
        // this round trip; the owned reconciliation retries the close while
        // the caller stays honestly unqualified.
        if (!owned.settle()) {
            controller.invalidateForEpoch(acceptedEpoch, "preflight_close_retained")
            reconcilePreflightOwnership(owned)
            complete(claim, 0, reply("unavailable", "close_retained")); return
        }
        val indexDigest = mappingIndexDigest(receiptBytes, sessionKey)
        if (indexDigest == null) {
            controller.invalidateForEpoch(acceptedEpoch, "preflight_mapping")
            complete(claim, 0, reply("unavailable", "mapping_unsynced")); return
        }
        if (peerProof == null || sessionToken == null ||
            !RuntimePeerProof.isHex64(leaseProofDigest)
        ) {
            controller.invalidateForEpoch(acceptedEpoch, "preflight_evidence")
            complete(claim, 0, reply("unavailable", "evidence_incomplete")); return
        }
        val ingressed = controller.ingestMappingAndLease(acceptedEpoch, indexDigest, leaseProofDigest,
            sessionToken, peerProof.peerUid, peerProof.certificateDigest, peerProof.packageVersion)
        if (ingressed.state == LinuxRuntimeReadinessController.Activation.REFUSED) {
            controller.invalidateForEpoch(acceptedEpoch, "preflight_${ingressed.code}".take(48))
            complete(claim, 0, reply("unavailable", boundedToken(ingressed.code))); return
        }
        val activated = controller.activateAndVerify(acceptedEpoch)
        if (activated.state != LinuxRuntimeReadinessController.Activation.READY) {
            controller.invalidateForEpoch(acceptedEpoch, "preflight_${activated.code}".take(48))
            complete(claim, 0, reply("unavailable", boundedToken(activated.code))); return
        }
        // All seven live facts + activation were re-read from Core's own
        // status authority above; the reply echoes ONLY the measured digests.
        complete(claim, 0, reply("ready", null)
            .put("workspaceIndexDigest", indexDigest)
            .put("leaseProofDigest", leaseProofDigest)
            .put("shellRegistered", true))
    }

    /**
     * A `completed` or `failed` receipt for THIS control UUID is an actual
     * authenticated same-request terminal and settles normally. An `unknown`
     * receipt (no kernel record) and a caller stop are NOT settlements: they
     * raise [PreflightUncertain], which keeps the ORIGINAL grant + foreground
     * + claim owned and hands them to [reconcilePreflightOwnership]. A cancel
     * REQUEST is never settlement — only the same request's later real
     * terminal (or proven retirement) releases it.
     */
    private suspend fun awaitPreflightReceipt(owned: OwnedPreflight, first: JSONObject,
                                             onWaiting: suspend () -> Unit): JSONObject {
        when (first.optString("state")) {
            "completed" -> return first.getJSONObject("result")
            "failed" -> return JSONObject().put("status", "aborted")
                .put("reason", boundedToken(first.optString("code", "preflight_failed")))
            "unknown" -> throw PreflightUncertain("dispatch_unknown")
            "queued", "running" -> Unit
            else -> return first
        }
        val id = first.getString("requestID")
        while (true) {
            if (owned.stop.get()) throw PreflightUncertain("preflight_cancelled")
            val value = owned.exchange("request.status", JSONObject().put("requestID", id))
            when (value.getString("state")) {
                "completed" -> return value.getJSONObject("result")
                "failed" -> return JSONObject().put("status", "aborted")
                    .put("reason", boundedToken(value.optString("code", "preflight_failed")))
                "unknown" -> throw PreflightUncertain("dispatch_unknown")
            }
            onWaiting(); delay(250)
        }
    }

    /** Parse the grant's captured native EXPORT_FINISH reply (companion so
     *  the decision is unit-testable with boundary fixtures). Honest ONLY
     *  for result=="synced", the same sessionKey, a terminal recovery block
     *  and a well-formed index digest. Anything else is no proof. */
    internal fun mappingIndexDigest(receiptBytes: ByteArray?, sessionKey: String?): String? {
        if (receiptBytes == null || sessionKey == null) return null
        val reply = runCatching {
            JSONObject(Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(receiptBytes)).toString())
        }.getOrNull() ?: return null
        if (reply.optBoolean("ok") != true || reply.optString("result") != "synced") return null
        val recovery = reply.optJSONObject("recovery") ?: return null
        if (recovery.optString("sessionKey") != sessionKey) return null
        val digest = recovery.optString("indexDigest")
        return digest.takeIf { RuntimePeerProof.isHex64(it) }
    }

    companion object {
        internal val ENVIRONMENT_ID = Regex("^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$")

        internal fun requiresControlReceipt(operation: String): Boolean {
            require(operation in setOf("shell.poll", "shell.input", "shell.resize"))
            return operation != "shell.poll"
        }

        /** The canonical one-shot pipe EOF command page: EMPTY base64 stdin.
         * Only this shape may receive the terminal-bound rejected EOF ack
         * after a fast session retires; any other input page to an unknown
         * owner stays refused exactly as before. */
        internal fun isEofInputPage(inputBase64: String): Boolean = inputBase64.isEmpty()

        /** Own-request cancellations: settle + typed "cancelled"; they do NOT
         *  invalidate the generation's other facts or unrelated work. */
        internal val CANCEL_CODES = setOf("cancelled", "preflight_cancelled", "caller_stopped")

        /**
         * The ACTUAL canonical Core identity grammar: Swift `UUID.uuidString`
         * and the CoreWorkspaceGrant exact echoes are UPPER-CASE 8-4-4-4-12
         * hex. The previous `UUID.fromString(text).toString() == text` Java
         * idiom accepted ONLY lowercase and rejected every real Core run
         * containing A-F (a digit-only fixture passes both grammars and
         * therefore misses the bug; meaningful fixtures use hex letters).
         * Java-generated lowercase runtime CONTROL request IDs are a separate
         * grammar that RuntimeWire itself validates — untouched here. Core
         * run/conversation bytes are echoed back exactly as received.
         */
        internal fun isCanonicalUUID(text: String): Boolean = try {
            java.util.UUID.fromString(text).toString().uppercase() == text
        } catch (_: IllegalArgumentException) { false }

        /** Only the SAME request's real kernel terminal settles a claimed
         *  preflight. `unknown`, `queued`, `running`, missing replies and
         *  elapsed budgets are explicitly NOT retirement. */
        internal fun isPreflightTerminalReceipt(state: String?): Boolean =
            state == "completed" || state == "failed"

        /** Peer/process retirement is PROVEN only by a DIFFERENT measured
         *  runtime process generation than the one the request was actually
         *  dispatched to (the new generation performed its own ORIGINAL
         *  recover()/census sweep at init). A missing or equal identity
         *  proves nothing and must retain the claim. */
        internal fun isPeerRetirementProven(dispatchedToken: String?, currentIdentity: String?): Boolean =
            dispatchedToken != null && currentIdentity != null && currentIdentity != dispatchedToken

        // ---- OPTIONAL per-execution recovery projection (merge authority) ----
        // Bounds are diagnostic ceilings ONLY; they never widen the real
        // workspace budgets and never truncate a status/identity skeleton.
        private const val RECOVERY_MAX_JSON_BYTES = 8_192
        private const val RECOVERY_MAX_PATH_BYTES = 256
        private val RECOVERY_INDEX_DIGEST = Regex("^[0-9a-f]{64}$")
        private val RECOVERY_TOKEN = Regex("^[!-~]{1,48}$")

        /**
         * Merge the runtime page's recovery projection with THIS grant's
         * ACTUAL Core-side EXPORT_FINISH reply. Strict identity binding:
         * the page must echo the exact grant sessionKey and this run's
         * runID — a foreign or unbound projection is DROPPED, never
         * attached to another run/conversation. When no matching Core
         * terminal reply exists, the runtime's own typed view is retained
         * as-is. Missing metadata stays missing; nothing is zeroed or
         * cleared. A merged envelope over the diagnostic budget falls back
         * to the (already bounded) runtime view.
         */
        internal fun mergeWorkspaceRecovery(page: JsonObject?, coreReply: JsonObject?,
                                            sessionKey: String?, runID: String): JsonObject? {
            if (page == null || sessionKey == null) return null
            if (page.stringValue("sessionKey") != sessionKey) return null
            // The page echoes the CORE canonical (UPPER-case) run UUID while
            // this pump stores Java-normalised lower-case; compare the SAME
            // UUID identity exactly, never a case-sensitive string accident.
            val pageRun = page.stringValue("runID") ?: return null
            try { if (UUID.fromString(pageRun) != UUID.fromString(runID)) return null }
            catch (_: IllegalArgumentException) { return null }
            val merged = LinkedHashMap<String, JsonElement>(page.toMap())
            coreExportSection(coreReply, sessionKey)?.let { authoritative ->
                merged["export"] = authoritative
            }
            val candidate = JsonObject(merged)
            return if (candidate.toString().toByteArray(Charsets.UTF_8).size <= RECOVERY_MAX_JSON_BYTES)
                candidate else page
        }

        /** The Core-side authority section: built ONLY from a terminal
         *  EXPORT_FINISH reply whose recovery block names THIS session.
         *  Relative paths, kinds, bounded counters and hex digests only. */
        private fun coreExportSection(reply: JsonObject?, sessionKey: String): JsonObject? {
            if (reply == null) return null
            if (reply["ok"] ?.let { (it as? JsonPrimitive)?.contentOrNull?.toBooleanStrictOrNull() } != true) return null
            val result = reply.stringValue("result") ?: return null
            if (result !in setOf("synced", "conflict", "aborted")) return null
            val recovery = reply["recovery"] as? JsonObject ?: return null
            if (recovery.stringValue("sessionKey") != sessionKey) return null
            val out = LinkedHashMap<String, JsonElement>()
            out["source"] = JsonPrimitive("core-export-finish")
            out["result"] = JsonPrimitive(result)
            (reply["applied"] as? JsonObject)?.let { applied ->
                val counters = LinkedHashMap<String, JsonElement>()
                for (key in listOf("created", "replaced", "directories", "deleted", "links")) {
                    applied.longValue(key)?.takeIf { it >= 0 }?.let { counters[key] = JsonPrimitive(it) }
                }
                if (counters.isNotEmpty()) out["applied"] = JsonObject(counters)
            }
            (reply["counts"] as? JsonObject)?.let { counts ->
                counts.longValue("failed")?.takeIf { it >= 0 }?.let { out["failed"] = JsonPrimitive(it) }
                counts.longValue("stagedRefusals")?.takeIf { it >= 0 }?.let { out["stagedRefusals"] = JsonPrimitive(it) }
            }
            (reply["preview"] as? JsonObject)?.let { preview ->
                val conflicts = preview["conflicts"] as? JsonArray
                val shown = conflicts?.mapNotNull { element ->
                    val item = element as? JsonObject ?: return@mapNotNull null
                    val path = item.stringValue("path")?.takeIf {
                        it.toByteArray(Charsets.UTF_8).size <= RECOVERY_MAX_PATH_BYTES
                    } ?: return@mapNotNull null
                    val kind = item.stringValue("kind")?.takeIf { RECOVERY_TOKEN.matches(it) } ?: return@mapNotNull null
                    val artifact = item["artifact"]?.let { (it as? JsonPrimitive)?.contentOrNull?.toBooleanStrictOrNull() } == true
                    JsonObject(linkedMapOf<String, JsonElement>("path" to JsonPrimitive(path),
                                                               "kind" to JsonPrimitive(kind),
                                                               "artifact" to JsonPrimitive(artifact)))
                }?.take(16)
                if (!shown.isNullOrEmpty()) {
                    out["conflicts"] = JsonArray(shown)
                    if ((conflicts?.size ?: 0) > 16 ||
                        preview["truncated"]?.let { (it as? JsonPrimitive)?.contentOrNull?.toBooleanStrictOrNull() } == true
                    ) out["conflictsTruncated"] = JsonPrimitive(true)
                }
            }
            reply.stringValue("planDigest")?.takeIf { RECOVERY_INDEX_DIGEST.matches(it) }
                ?.let { out["planDigest"] = JsonPrimitive(it) }
            recovery.stringValue("indexDigest")?.takeIf { RECOVERY_INDEX_DIGEST.matches(it) }
                ?.let { out["indexDigest"] = JsonPrimitive(it) }
            return JsonObject(out)
        }

        private fun JsonObject.stringValue(key: String): String? =
            (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

        private fun JsonObject.longValue(key: String): Long? =
            (this[key] as? JsonPrimitive)?.takeIf { !it.isString }?.contentOrNull?.toLongOrNull()

        internal fun boundedCode(failure: Exception): String =
            failure.message?.takeIf { it.isNotEmpty() && it.length <= 32 &&
                it.all { c -> c.code in 0x21..0x7e } } ?: "preflight_failed"

        internal fun boundedToken(text: String): String =
            text.takeIf { it.isNotEmpty() && it.length <= 32 && it.all { c -> c.code in 0x21..0x7e } }
                ?: "preflight_failed"
    }

    private suspend fun jobOwnership(claim: Long, query: JSONObject, acceptedEpoch: Long): JSONObject {
        require(query.getLong("epoch") == acceptedEpoch)
        val jobID = UUID.fromString(query.getString("jobID")).toString()
        val accepted = when (query.getString("action")) {
            "release" -> {
                val held = jobForeground[jobID]
                if (held != null && held.epoch == acceptedEpoch) {
                    held.ended.set(true)
                    held.lease?.close()
                    jobForeground.remove(jobID, held)
                }
                true // idempotent actual terminal, never a stop request
            }
            "acquire" -> {
                check(!admissionClosed.get() && LinuxShellNative.shouldStop(claim) == 0)
                val held = OwnedJobForeground(acceptedEpoch)
                val existing = jobForeground.putIfAbsent(jobID, held)
                if (existing != null) existing.epoch == acceptedEpoch && existing.lease?.isActiveNow() == true
                else try {
                    val lease = foreground.acquireOperation(jobID, OperationKind.DURABLE_JOB, RunStopHandler {
                        scope.launch(Dispatchers.IO) { com.floe.android.bridge.JobsNative.cancelJob(acceptedEpoch, jobID) }
                    })
                    held.lease = lease
                    if (held.ended.get() || admissionClosed.get() || LinuxShellNative.shouldStop(claim) != 0) {
                        lease.close(); jobForeground.remove(jobID, held); false
                    } else true
                } catch (_: Exception) {
                    held.lease?.close(); jobForeground.remove(jobID, held); false
                }
            }
            else -> error("Invalid job ownership action")
        }
        return JSONObject().put("accepted", accepted).put("epoch", acceptedEpoch)
    }

    private fun copyWorkspaceProof(target: JSONObject, proof: JSONObject) {
        target.remove("workspaceStatus"); target.remove("workspaceRecoveryRef")
        target.remove("workspaceRecovery")
        target.put("workspaceStatus", proof.optString("workspaceStatus", "unknown"))
        if (proof.has("workspaceRecoveryRef")) target.put("workspaceRecoveryRef", proof.getString("workspaceRecoveryRef"))
        // The OPTIONAL merged recovery projection rides the same terminal
        // proof channel (never a second registry); absence is preserved.
        proof.optJSONObject("workspaceRecovery")?.let { target.put("workspaceRecovery", it) }
    }

    private fun terminalProof(page: JSONObject): JSONObject = JSONObject().put("state", "released").also { proof ->
        for (key in listOf("sessionID", "cancelled", "stopReason", "exitCode", "termSig", "waitErrno",
                           "workspaceStatus", "workspaceRecoveryRef", "workspaceRecovery")) {
            if (page.has(key)) proof.put(key, page.get(key))
        }
    }

    private fun matches(runID: String, callID: String?, sessionID: String?, query: JSONObject): Boolean {
        if (UUID.fromString(query.getString("runID")).toString() != runID) return false
        val hintedSession = query.optString("sessionID").takeIf { it.isNotEmpty() }
        if (hintedSession != null && hintedSession != sessionID) return false
        val requestedJob = query.optString("jobID").takeIf { it.isNotEmpty() }
        if (requestedJob != null) {
            if (callID == null || !callID.startsWith("jobs.")) return false
            return try { UUID.fromString(callID.removePrefix("jobs.")) == UUID.fromString(requestedJob) }
            catch (_: IllegalArgumentException) { false }
        }
        val requestedCall = query.optString("toolCallID").takeIf { it.isNotEmpty() } ?: return false
        return callID == requestedCall
    }

    private suspend fun settlement(query: JSONObject, acceptedEpoch: Long): JSONObject {
        require(query.getLong("epoch") == acceptedEpoch)
        val active = work.values.firstOrNull {
            it.nativeEpoch == acceptedEpoch && matches(it.runID, it.toolCallID, it.sessionID, query)
        }
        if (active != null) {
            if (query.optBoolean("cancellationRequested")) active.requestStop()
            return JSONObject().put("epoch", acceptedEpoch).put("state", "unconfirmed")
        }
        val terminal = synchronized(terminals) { terminals.values.lastOrNull {
            it.epoch == acceptedEpoch && matches(it.runID, it.toolCallID, it.sessionID, query)
        } }
        if (terminal != null) return JSONObject(terminal.proof)
        // No matching recorded proof is not proof of quiescence. A claimed
        // start can still be awaiting foreground admission. Keep it pending.
        return JSONObject().put("epoch", acceptedEpoch).put("state", "unconfirmed")
    }

    private suspend fun awaitReceipt(owned: OwnedSession, first: JSONObject, onWaiting: suspend () -> Unit = {}): JSONObject {
        when (first.optString("state")) {
            "completed" -> return first.getJSONObject("result")
            "failed", "unknown" -> error("Runtime operation failed")
            "queued", "running" -> Unit
            else -> return first // progress may contain a historical requestID
        }
        val id = first.getString("requestID")
        while (true) {
            val value = owned.exchange("request.status", JSONObject().put("requestID", id))
            when (value.getString("state")) {
                "completed" -> return value.getJSONObject("result")
                "failed", "unknown" -> error("Runtime operation did not settle successfully")
            }
            onWaiting(); delay(100)
        }
    }

    private fun complete(claim: Long, status: Int, value: JSONObject) {
        LinuxShellNative.complete(claim, status, value.toString().toByteArray(Charsets.UTF_8))
    }
    private fun objectBytes(bytes: ByteArray): JSONObject {
        require(bytes.size <= 65_536)
        return JSONObject(Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(bytes)).toString())
    }
    private fun result(envelope: JSONObject): JSONObject {
        if (!envelope.getBoolean("ok")) throw AdmissionRefused()
        return envelope.getJSONObject("result")
    }
}
