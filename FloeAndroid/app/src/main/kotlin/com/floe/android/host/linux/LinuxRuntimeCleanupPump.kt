// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import android.content.Context
import android.os.Process
import com.floe.android.bridge.LinuxRuntimeCleanupNative
import com.floe.android.runtimeipc.RuntimeConnection
import com.floe.android.runtimeipc.RuntimePeerProof
import com.floe.android.runtimeipc.RuntimeWire
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.util.UUID
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * G03-R3 (job-7e9db10b801940c2): the APP-owned transport pump for the typed
 * Core -> runtime-UID workspace-copy cleanup lane.
 *
 * Shape mirrors the existing `LinuxShellPump` transport discipline (mailbox
 * claim -> signed distinct-UID RuntimeWire dispatch -> typed result -> Core
 * `complete` with the receipt), with the cleanup-specific rules from the
 * Main-reviewed host contract (`RUNTIME_CLEANUP_HOST_CONTRACT.json` v1):
 *  * bound at the SAME actual accepted native Root epoch as the shell pump
 *    (`start` receives `RuntimeHost.nativeRootEpoch()`), off Main, owned by
 *    the Application service scope — never by a view lifetime;
 *  * the channel stays serviceable while shell/model admission is fenced
 *    (this pump is independent of `LinuxShellNative` admission fencing; the
 *    runtime kernel exempts ONLY the typed cleanup op from the foreground
 *    permit requirement);
 *  * pending / unknown / partial / refused are RETAINED — never a false
 *    "cleared" from a requested callback, a result string or a body echo;
 *  * a cleared receipt is stamped ONLY from the actual authenticated peer
 *    identity measured over the CURRENT verified connection generation
 *    (`RuntimeConnection.currentPeerProof()`) AND a scoped execution result
 *    whose scope echo matches the claimed request exactly; a changed or
 *    unobservable peer yields an honest refusal/retention, never cleared;
 *  * shutdown/rebind late callbacks cannot settle a wrong claim: every
 *    `complete` re-checks the pump generation AND the lane's live claim;
 *    no receipt is delivered for a stale bind or a dead claim;
 *  * the RuntimeWire control id is a fresh UUID per dispatch attempt and
 *    the ORIGINAL wire id is preserved through an uncertain-but-accepted
 *    dispatch (the kernel's transient receipt is polled by that id); only
 *    after the kernel reports the control `unknown` may a NEW wire id be
 *    minted for one continuation attempt over the SAME Core scope (the
 *    runtime wipe is idempotent), so a retained partial is never cached
 *    forever and never blindly replayed against different work;
 *  * bounded exponential backoff keeps retained obligations from becoming a
 *    hot retry loop; the durable V36 retry + Core settlement trigger remain
 *    the only lifecycle authority (no Kotlin persistent DB here).
 */
class LinuxRuntimeCleanupPump internal constructor(
    private val queue: RuntimeCleanupQueue,
    private val channels: RuntimeCleanupChannelFactory,
    private val scope: CoroutineScope,
    private val settleBudgetMillis: Long = 180_000,
    private val drainBudgetMillis: Long = 15_000,
    private val backoffBaseMillis: Long = 2_000,
    private val maxBackoffMillis: Long = 60_000,
) {
    /** Production composition: the real JNI cleanup lane + real Binder. */
    constructor(context: Context, scope: CoroutineScope) : this(
        JniRuntimeCleanupQueue,
        RuntimeCleanupChannelFactory { LiveRuntimeCleanupChannel(context) },
        scope,
    )

    private val epoch = AtomicLong()
    private val starts = Mutex()
    private val claimGate = Mutex()
    private val pauseClaims = AtomicBoolean()
    private val pumpClosed = AtomicBoolean()
    private var reader: Job? = null

    /** Honest host-side counters (diagnostics only; never settlement). */
    val settledCleared = AtomicLong()
    val retainedTotal = AtomicLong()

    @Volatile
    var lastRetentionReason: String? = null
        private set

    val boundNativeEpoch: Long get() = epoch.get()

    /** Bind at the SAME actual accepted native Root epoch as LinuxShellPump.
     *  No guessed generation; the lane itself refuses zero/equal epochs. */
    suspend fun start(acceptedEpoch: Long) = starts.withLock {
        check(acceptedEpoch > 0) { "Cleanup pump requires the ACTUAL accepted epoch (never 0)" }
        if (epoch.get() == acceptedEpoch) return@withLock
        check(epoch.get() == 0L && !pumpClosed.get()) { "Cleanup pump epoch already bound" }
        check(queue.bind(acceptedEpoch) == 0) { "Cleanup lane refused the accepted epoch" }
        epoch.set(acceptedEpoch)
        reader = scope.launch(Dispatchers.IO) { pumpLoop(acceptedEpoch) }
    }

    private suspend fun pumpLoop(acceptedEpoch: Long) {
        var consecutiveRetained = 0
        while (currentCoroutineContext().isActive && epoch.get() == acceptedEpoch && !pumpClosed.get()) {
            if (pauseClaims.get()) { delay(200); continue }
            val claim = claimGate.withLock { queue.next(1_000) }
            if (claim < 0) break // lane unbound/fenced: nothing to poll against
            if (claim == 0L) continue // idle: the bounded next() wait IS the poll
            val settled = settleOne(claim, acceptedEpoch)
            if (settled) {
                consecutiveRetained = 0
            } else {
                consecutiveRetained += 1
                retainedTotal.incrementAndGet()
                val shift = minOf(consecutiveRetained - 1, 5)
                delay(minOf(maxBackoffMillis, backoffBaseMillis shl shift))
            }
        }
    }

    /**
     * Drain owned obligations BEFORE root retirement (composed AFTER
     * `LinuxShellPump.stopAndDrain`, so the Core owned-work/CoreIO drain
     * precedes runtime wipe attempts). True only when the lane is observably
     * quiescent (stats `queued==0 && claimed==0`); otherwise the cleanup
     * channel STAYS open, the drain stays retryable and the obligations
     * remain retained (never a silent "everything is done").
     */
    suspend fun drainAndStop(expectedEpoch: Long, budgetMillis: Long = drainBudgetMillis): Boolean = starts.withLock {
        if (expectedEpoch <= 0 || epoch.get() != expectedEpoch) return@withLock false
        pauseClaims.set(true)
        val deadline = System.nanoTime() + budgetMillis * 1_000_000L
        var quiescent = false
        while (System.nanoTime() < deadline && !pumpClosed.get()) {
            val claim = claimGate.withLock { queue.next(150) }
            if (claim < 0) break
            if (claim > 0) {
                // Never let one settlement overrun the shutdown budget:
                // the remaining window bounds dispatch + status polling and
                // the obligation RETAINS honestly if it is not enough.
                val remainingMillis = ((deadline - System.nanoTime()) / 1_000_000L)
                    .coerceIn(250L, settleBudgetMillis)
                settleOne(claim, expectedEpoch, remainingMillis)
            }
            val stats = decodeObject(queue.stats())
            val queued = stats?.longField("queued") ?: -1L
            val claimed = stats?.longField("claimed") ?: -1L
            if (claim == 0L && queued == 0L && claimed == 0L) { quiescent = true; break }
        }
        if (quiescent) {
            pumpClosed.set(true)
            reader?.cancel()
            reader = null
            epoch.set(0)
            lastRetentionReason = null
        }
        // On exhaustion the reader RESUMES claiming (retention, not closure):
        // root retirement never silently closes the cleanup channel.
        pauseClaims.set(false)
        quiescent
    }

    // MARK: - one claim settlement

    /**
     * Returns true ONLY when the lane ACKED a real cleared settlement for
     * THIS claim. Every other path (refusal delivered, uncertain without a
     * receipt, stale claim) returns false and RETAINS the obligation.
     */
    internal suspend fun settleOne(
        claim: Long,
        acceptedEpoch: Long,
        budgetMillis: Long = settleBudgetMillis,
    ): Boolean = withContext(Dispatchers.IO) {
        try {
            if (epoch.get() != acceptedEpoch) return@withContext false
            if (!queue.isLive(claim)) return@withContext false // never a receipt on a dead claim
            val described = decodeObject(queue.describe(claim)) ?: return@withContext false
            if (described.boolField("ok") != true) return@withContext false
            val requestID = described.stringField("requestID")?.takeIf { HEX32.matches(it) } ?: return@withContext false
            if (described.stringField("operation") != RuntimeWire.CLEANUP) return@withContext false
            val targetEpoch = described.longField("targetEpoch")?.takeIf { it > 0 } ?: return@withContext false
            // A different bound generation owns the lane -> never settle here.
            if (described.longField("boundEpoch") != acceptedEpoch) return@withContext false
            val payloadBytes = queue.payload(claim)?.takeIf { it.size in 1..4_096 } ?: return@withContext false
            val payload = decodeObject(payloadBytes) ?: return@withContext false
            if (!scopePayloadMatches(payload, targetEpoch)) return@withContext false
            val conversation = payload.stringField("conversationID") ?: return@withContext false
            val project = payload.stringField("projectID") ?: return@withContext false
            val fields = ScopeFields(requestID, conversation, project, targetEpoch)
            val control = JsonObject(payload.toMap() + ("requestID" to JsonPrimitive(requestID)))
            val channel = channels.create()
            try {
                val opened = runCatching { channel.open() }.isSuccess
                val preProof = if (opened) channel.peerProof() else null
                val ownUid = runCatching { channel.ownUid() }.getOrDefault(-1)
                if (preProof == null || !preProof.wellFormed(ownUid)) {
                    return@withContext deliverRefused(claim, acceptedEpoch, fields, "peerUnauthenticated")
                }
                var wireID = UUID.randomUUID().toString()
                var dispatch = attemptDispatch(channel, control, wireID, acceptedEpoch, budgetMillis / 2)
                if (dispatch is DispatchResult.NotAdmitted) {
                    // The kernel never held this control: one continuation
                    // attempt with a NEW wire id over the SAME scope is safe
                    // (the wipe handler is idempotent). The original wire id
                    // was preserved through the uncertain accepted dispatch.
                    wireID = UUID.randomUUID().toString()
                    dispatch = attemptDispatch(channel, control, wireID, acceptedEpoch, budgetMillis / 2)
                }
                when (dispatch) {
                    is DispatchResult.Completed -> {
                        val result = dispatch.result
                        when {
                            resultLooksCleared(result, fields) -> {
                                val executorUid = result.longField("executorUid") ?: 0L
                                val pathsRemoved = result.longField("pathsRemoved") ?: -1L
                                val bytesFreed = result.longField("bytesFreed") ?: -1L
                                val digest = result.stringField("executorProofDigest") ?: ""
                                // Verified UNCHANGED peer and CURRENT
                                // generation binder identity; the receipt
                                // carries ONLY the host-measured peer values.
                                val postProof = channel.peerProof()
                                if (postProof != preProof || postProof == null ||
                                    postProof.peerUid.toLong() != executorUid ||
                                    !postProof.wellFormed(ownUid)
                                ) {
                                    deliverRefused(claim, acceptedEpoch, fields, "peerChanged")
                                } else {
                                    deliverCleared(claim, acceptedEpoch, fields, postProof,
                                        pathsRemoved, bytesFreed, digest)
                                }
                            }
                            result.stringField("outcome") == "refused" ->
                                deliverRefused(claim, acceptedEpoch, fields,
                                    "runtime:" + token(result.stringField("reason") ?: "refused"))
                            else -> deliverRefused(claim, acceptedEpoch, fields, "resultUnverified")
                        }
                    }
                    is DispatchResult.RuntimeRefused ->
                        deliverRefused(claim, acceptedEpoch, fields, "runtime:" + token(dispatch.reason))
                    is DispatchResult.Uncertain ->
                        deliverRefused(claim, acceptedEpoch, fields, "uncertain:" + token(dispatch.reason))
                    is DispatchResult.NotAdmitted ->
                        deliverRefused(claim, acceptedEpoch, fields, "runtimeUnavailable")
                }
            } finally {
                runCatching { channel.close() }
            }
        } catch (_: Exception) {
            false // unsettled = RETAINED; the lane re-queues on the next bind
        }
    }

    /** Dispatch + bounded status polling; NEVER blindly replays an accepted
     *  control: an exchange failure falls through to request.status with the
     *  ORIGINAL wire id. */
    private suspend fun attemptDispatch(
        channel: RuntimeCleanupChannel,
        control: JsonObject,
        wireID: String,
        acceptedEpoch: Long,
        budgetMillis: Long,
    ): DispatchResult {
        val deadline = System.nanoTime() + budgetMillis * 1_000_000L
        // The transport reply is JSON TEXT; the decoder consumes the same
        // bounded UTF-8 bytes the bridge lane already uses for receipts
        // (decodeObject caps 1..64 KiB and fails closed to null, so an
        // unreadable/oversized body stays uncertain and falls through to
        // status polling — never a fake ack; channel/queue semantics and
        // Native.complete are UNCHANGED).
        val exchanged = runCatching {
            decodeObject(channel.exchange(RuntimeWire.CLEANUP, control, wireID)
                .toByteArray(Charsets.UTF_8))
        }.getOrNull()
        if (exchanged != null) {
            if (exchanged.stringField("id") != wireID) return DispatchResult.Uncertain("envelopeIdMismatch")
            if (exchanged.boolField("ok") != true) {
                return DispatchResult.RuntimeRefused(exchanged.stringField("code") ?: "refused")
            }
            val submitted = exchanged.objField("result")
            val submittedState = submitted?.stringField("state")
            if (submittedState == "completed") {
                return DispatchResult.Completed(submitted?.objField("result") ?: JsonObject(emptyMap()))
            }
            if (submittedState == "failed") {
                return DispatchResult.RuntimeRefused(submitted?.stringField("code") ?: "operation_failed")
            }
            // queued/running (or unexpected shape): poll the real receipt
        }
        // Uncertain accepted dispatch OR async admission: poll by the
        // ORIGINAL control id until real request.status/exit proof.
        while (System.nanoTime() < deadline && epoch.get() == acceptedEpoch && !pumpClosed.get()) {
            val reply = runCatching {
                decodeObject(channel.exchange("request.status",
                    JsonObject(mapOf("requestID" to JsonPrimitive(wireID))), UUID.randomUUID().toString())
                    .toByteArray(Charsets.UTF_8))
            }.getOrNull()
            if (reply != null && reply.stringField("id") != null && reply.boolField("ok") == true) {
                val receipt = reply.objField("result")
                val state = receipt?.stringField("state")
                if (state == "completed") {
                    return DispatchResult.Completed(receipt?.objField("result") ?: JsonObject(emptyMap()))
                }
                if (state == "failed") {
                    return DispatchResult.RuntimeRefused(receipt?.stringField("code") ?: "operation_failed")
                }
                if (state == "unknown") {
                    return DispatchResult.NotAdmitted
                }
            }
            delay(100)
        }
        return DispatchResult.Uncertain(if (epoch.get() != acceptedEpoch) "generationChanged" else "statusDeadline")
    }

    private fun deliverCleared(claim: Long, acceptedEpoch: Long, fields: ScopeFields, proof: RuntimePeerProof,
                               pathsRemoved: Long, bytesFreed: Long, executorProofDigest: String): Boolean {
        // Stale bind / dead claim: NEVER deliver a receipt (late callbacks
        // cannot settle a wrong claim).
        if (epoch.get() != acceptedEpoch || !queue.isLive(claim)) {
            lastRetentionReason = "staleBeforeSettle"
            return false
        }
        val receipt = JsonObject(linkedMapOf<String, JsonElement>(
            "requestID" to JsonPrimitive(fields.requestID),
            "conversationID" to JsonPrimitive(fields.conversationID),
            "projectID" to JsonPrimitive(fields.projectID),
            "targetEpoch" to JsonPrimitive(fields.targetEpoch),
            "outcome" to JsonPrimitive("cleared"),
            "runtimeUID" to JsonPrimitive(proof.peerUid),
            "certificateDigest" to JsonPrimitive(proof.certificateDigest),
            "packageVersion" to JsonPrimitive(proof.packageVersion),
            "binderIdentity" to JsonPrimitive(proof.binderIdentity),
            "executorProofDigest" to JsonPrimitive(executorProofDigest),
            "pathsRemoved" to JsonPrimitive(pathsRemoved),
            "bytesFreed" to JsonPrimitive(bytesFreed),
        ))
        val reply = runCatching { queue.complete(claim, receipt.toString().toByteArray(Charsets.UTF_8)) }.getOrNull()
        val ack = decodeObject(reply)
        val settled = ack?.boolField("ok") == true && ack.stringField("state") == "cleared"
        if (settled) settledCleared.incrementAndGet()
        else lastRetentionReason = "ack:" + (ack?.stringField("code") ?: ack?.stringField("state") ?: "unreadable")
        return settled
    }

    /** A refused receipt RETAINS the obligation (lane re-queues it); it
     *  always returns false (never a cleared). */
    private fun deliverRefused(claim: Long, acceptedEpoch: Long, fields: ScopeFields, reasonRaw: String): Boolean {
        val reason = token(reasonRaw)
        lastRetentionReason = reason
        // Same stale gate as cleared: no receipt at all for a dead claim
        // (the lane re-queues claimed records on the next bind).
        if (epoch.get() != acceptedEpoch || !queue.isLive(claim)) return false
        val receipt = JsonObject(linkedMapOf<String, JsonElement>(
            "requestID" to JsonPrimitive(fields.requestID),
            "conversationID" to JsonPrimitive(fields.conversationID),
            "projectID" to JsonPrimitive(fields.projectID),
            "targetEpoch" to JsonPrimitive(fields.targetEpoch),
            "outcome" to JsonPrimitive("refused"),
            "reason" to JsonPrimitive(reason),
        ))
        runCatching { queue.complete(claim, receipt.toString().toByteArray(Charsets.UTF_8)) }
        return false
    }

    // MARK: - strict validation helpers

    private data class ScopeFields(val requestID: String, val conversationID: String,
                                   val projectID: String, val targetEpoch: Long)

    private sealed interface DispatchResult {
        data class Completed(val result: JsonObject) : DispatchResult
        data class RuntimeRefused(val reason: String) : DispatchResult
        data class Uncertain(val reason: String) : DispatchResult
        data object NotAdmitted : DispatchResult
    }

    /** The EXACT Core cleanup-payload grammar (frozen contract v1). */
    private fun scopePayloadMatches(payload: JsonObject, targetEpoch: Long): Boolean {
        if (payload.keys != PAYLOAD_KEYS) return false
        if (payload.stringField("operation") != RuntimeWire.CLEANUP) return false
        if (payload.stringField("deletionSet") != DELETION_SET) return false
        val conversation = payload.stringField("conversationID")?.takeIf { UUID_TOKEN.matches(it) } ?: return false
        val project = payload.stringField("projectID")?.takeIf { UUID_TOKEN.matches(it) } ?: return false
        if (payload.stringField("workspaceRelativePath") != "PrivateTasks/$conversation") return false
        if (payload.longField("targetEpoch") != targetEpoch) return false
        val provenTotal = payload.longField("provenTotal")?.takeIf { it >= 0 } ?: return false
        if (payload.boolField("evidenceTruncated") == null) return false
        val keys = payload["evidenceSessionKeys"] as? kotlinx.serialization.json.JsonArray ?: return false
        if (keys.size > MAX_EVIDENCE_KEYS || keys.size > provenTotal) return false
        for (element in keys) {
            val key = (element as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return false
            if (!HEX32.matches(key)) return false
        }
        return true
    }

    /** All-or-nothing: every field must independently prove the cleared. */
    private fun resultLooksCleared(result: JsonObject, fields: ScopeFields): Boolean =
        result.stringField("operation") == RuntimeWire.CLEANUP &&
            result.stringField("outcome") == "cleared" &&
            result.stringField("requestID") == fields.requestID &&
            result.stringField("conversationID") == fields.conversationID &&
            result.stringField("projectID") == fields.projectID &&
            result.longField("targetEpoch") == fields.targetEpoch &&
            (result.longField("executorUid") ?: -1L) >= 0 &&
            (result.longField("pathsRemoved") ?: -1L) >= 0 &&
            (result.longField("bytesFreed") ?: -1L) >= 0 &&
            HEX64.matches(result.stringField("executorProofDigest") ?: "")

    private fun token(raw: String): String {
        // joinToString("") keeps this sanitizer the intended String pipeline:
        // map alone yields List<Char>, which mis-types the later take (the
        // frozen bridge has NO `take` call and none is invented here).
        // Semantics unchanged: printable-ASCII map, spaces dropped,
        // "retain" fallback, hard 64-char bound on every token (receipt
        // reason + host retention reason).
        val cleaned = raw.map { if (it.code in 0x21..0x7e) it else '-' }.joinToString("")
            .filter { it != ' ' }
            .ifEmpty { "retain" }
        return cleaned.take(64)
    }

    companion object {
        private val HEX32 = Regex("^[0-9a-f]{32}$")
        private val HEX64 = Regex("^[0-9a-f]{64}$")
        private val UUID_TOKEN = Regex("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")
        private const val DELETION_SET = "targetProjectScope"
        private const val MAX_EVIDENCE_KEYS = 16
        private val PAYLOAD_KEYS = setOf(
            "operation", "deletionSet", "conversationID", "projectID", "targetEpoch",
            "workspaceRelativePath", "provenTotal", "evidenceSessionKeys", "evidenceTruncated",
        )

        internal fun decodeObject(bytes: ByteArray?): JsonObject? = runCatching {
            bytes ?: return null
            require(bytes.size in 1..65_536)
            Json.parseToJsonElement(String(bytes, Charsets.UTF_8)) as? JsonObject
        }.getOrNull()
    }
}

// MARK: - strict kotlinx field readers (no coercion, no defaults)

private fun JsonObject.stringField(key: String): String? =
    (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

private fun JsonObject.longField(key: String): Long? =
    (this[key] as? JsonPrimitive)?.takeIf { !it.isString }?.content?.toLongOrNull()

private fun JsonObject.boolField(key: String): Boolean? =
    (this[key] as? JsonPrimitive)?.takeIf { !it.isString }?.let {
        when (it.content) { "true" -> true; "false" -> false; else -> null }
    }

private fun JsonObject.objField(key: String): JsonObject? = this[key] as? JsonObject

// MARK: - lane + channel surfaces (JNI in production, fakes in qualification)

/** Exact mirror of `LinuxRuntimeCleanupNative` (trusted-host JNI only). */
internal interface RuntimeCleanupQueue {
    fun bind(epoch: Long): Int
    fun next(timeoutMillis: Int): Long
    fun describe(claim: Long): ByteArray?
    fun payload(claim: Long): ByteArray?
    fun isLive(claim: Long): Boolean
    fun complete(claim: Long, receipt: ByteArray): ByteArray?
    fun status(requestID: String): ByteArray?
    fun stats(): ByteArray?
}

internal object JniRuntimeCleanupQueue : RuntimeCleanupQueue {
    override fun bind(epoch: Long): Int = LinuxRuntimeCleanupNative.bind(epoch)
    override fun next(timeoutMillis: Int): Long = LinuxRuntimeCleanupNative.next(timeoutMillis)
    override fun describe(claim: Long): ByteArray? = LinuxRuntimeCleanupNative.describe(claim)
    override fun payload(claim: Long): ByteArray? = LinuxRuntimeCleanupNative.payload(claim)
    override fun isLive(claim: Long): Boolean = LinuxRuntimeCleanupNative.isLive(claim)
    override fun complete(claim: Long, receipt: ByteArray): ByteArray? = LinuxRuntimeCleanupNative.complete(claim, receipt)
    override fun status(requestID: String): ByteArray? = LinuxRuntimeCleanupNative.status(requestID)
    override fun stats(): ByteArray? = LinuxRuntimeCleanupNative.stats()
}

/** One signed, distinct-UID runtime control channel for a claim attempt. */
internal interface RuntimeCleanupChannel {
    fun open()
    fun exchange(operation: String, control: JsonObject, requestID: String): String
    fun peerProof(): RuntimePeerProof?
    fun ownUid(): Int
    fun close()
}

internal fun interface RuntimeCleanupChannelFactory {
    fun create(): RuntimeCleanupChannel
}

private class LiveRuntimeCleanupChannel(context: Context) : RuntimeCleanupChannel {
    private val connection = RuntimeConnection(context.applicationContext)
    override fun open() { connection.connect().get(15, TimeUnit.SECONDS) }
    override fun exchange(operation: String, control: JsonObject, requestID: String): String =
        connection.exchange(operation, org.json.JSONObject(control.toString()), requestID).toString()
    override fun peerProof(): RuntimePeerProof? = connection.currentPeerProof()
    override fun ownUid(): Int = Process.myUid()
    override fun close() { connection.close() }
}
