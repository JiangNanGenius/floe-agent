// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import android.content.Context
import com.floe.android.bridge.LinuxShellNative
import com.floe.android.runlifecycle.ForegroundLease
import com.floe.android.runlifecycle.OperationKind
import com.floe.android.runlifecycle.RunForegroundController
import com.floe.android.runlifecycle.RunStopHandler
import com.floe.android.runtimeipc.RuntimeConnection
import com.floe.android.workspacebridge.CoreWorkspaceGrant
import com.floe.android.workspacebridge.WorkspaceOwnershipProbe
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
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
    }

    suspend fun stopAndDrain(expectedEpoch: Long, budgetMillis: Long = 15_000): Boolean {
        stop(expectedEpoch)
        val drained = withTimeoutOrNull(budgetMillis) {
            while (work.isNotEmpty()) delay(100)
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
            checkNotNull(owner)
            val response = if (operation == "shell.cancel") {
                owner.requestStop(); JSONObject().put("state", "stop_requested")
            } else awaitReceipt(owner, owner.exchange(operation, payload))
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
            owned.lease = foreground.acquireOperation(owned.controlID, OperationKind.LOCAL_EXECUTION,
                RunStopHandler { scope.launch(Dispatchers.IO) { owned.requestStop() } })
            work[owned.controlID] = owned
            if (admissionClosed.get() || owned.stop.get() || LinuxShellNative.shouldStop(claim) != 0) error("Caller stopped before admission")
            val grant = CoreWorkspaceGrant.create(context, acceptedEpoch, payload.getString("runID"),
                trustedCallID = callID?.takeIf { it.startsWith("jobs.") },
                isOwned = WorkspaceOwnershipProbe {
                    // Cleanup/writeback remains owned during a stop request.
                    // Current real FGS protection separately gates process execution.
                    epoch.get() == acceptedEpoch && work[owned.controlID] === owned && !owned.lease.isClosed
                }, authority = CoreWorkspaceNativeAuthority()) ?: error("Owned workspace unavailable")
            owned.workspaceGrant = grant
            check(grant.projectID == payload.getString("projectID"))
            // A transport failure may follow accepted dispatch. Never replay it.
            possiblyAdmitted = true
            val response = owned.exchange("shell.start", payload, owned.controlID)
            val started = awaitReceipt(owned, response) {
                if (LinuxShellNative.shouldStop(claim) != 0) owned.requestStop()
            }
            owned.sessionID = started.getString("sessionID")
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
            while (true) {
                try {
                    if (owned.stop.get()) owned.requestStop()
                    if (owned.sessionID == null) {
                        val receipt = owned.exchange("request.status", JSONObject().put("requestID", owned.controlID))
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
                        failedStartClaim?.let { complete(it, 1, JSONObject().put("code", "runtime_start_interrupted")) }
                        return@withContext
                    }
                } catch (_: Exception) { /* unresolved means retain, never replay */ }
                delay(1_000)
            }
        }
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
        target.put("workspaceStatus", proof.optString("workspaceStatus", "unknown"))
        if (proof.has("workspaceRecoveryRef")) target.put("workspaceRecoveryRef", proof.getString("workspaceRecoveryRef"))
    }

    private fun terminalProof(page: JSONObject): JSONObject = JSONObject().put("state", "released").also { proof ->
        for (key in listOf("sessionID", "cancelled", "stopReason", "exitCode", "termSig", "waitErrno", "workspaceStatus", "workspaceRecoveryRef")) {
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
