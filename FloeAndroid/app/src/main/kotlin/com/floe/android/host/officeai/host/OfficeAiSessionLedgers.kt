// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officeai

import com.floe.android.core.officeengine.OfficeSaveReceipt
import com.floe.android.core.officeengine.precision.OfficePrecisionState
import java.io.File
import java.util.ArrayDeque
import java.util.LinkedHashMap
import kotlinx.coroutines.CompletableDeferred

/**
 * RAM-only per-epoch session ledgers for the Office AI host lane (host20).
 *
 * These records exist so the host can answer the Amendment/2 proof facts from
 * ACTUAL owned observations — never from model payloads and never from a
 * fresh silent re-capture:
 *  - [SessionBinds] remembers the exact realm (task/workspace/epoch) each
 *    session token resolved to, so a command/save/verify can rejoin the live
 *    owned operation BEFORE dispatch (a stale/foreign/manual retarget refuses
 *    before any effect);
 *  - [CaptureStore] records each engine-minted capture (generation, target
 *    handle, captured logical part index, prior selection/part facts) AND the
 *    immutable pre-edit baseline retained from the ACTUAL current flushed
 *    working copy at capture time (digest bound to the capture attestation,
 *    never the initial immutable source snapshot hash);
 *  - [EffectLedger] correlates the owned native effect (same session,
 *    generation, captured handle, exact opId) with its REAL terminal state —
 *    the only source of `targetEffectVerified`; a content opId already
 *    dispatched can NEVER be re-dispatched by a retry;
 *  - [SaveWaiters] is the OWNED receipt observer's exact-key waiter table
 *    (opId + sessionToken + native generation). A late or foreign receipt
 *    completes nothing.
 *
 * Everything here is bounded; a full store evicts the OLDEST entry only, and
 * eviction is honest data loss for the optional baseline (the verifier then
 * reports the semantic delta as unprovable, never a guess).
 */

internal data class OfficeAiSessionBind(
    val sessionToken: String,
    val nativeGeneration: Long,
    val ownerTaskID: String,
    val workspaceID: String?,
    val nativeEpoch: Long,
    val viewerIncarnation: Long,
    val sourceLogicalPath: String?,
    val stagedWorkingCopyPath: String?,
    val stagedWorkingCopySha256: String?,
    val format: String,
    val boundAtElapsedMs: Long,
)

internal class SessionBinds {
    companion object {
        const val MAX_BINDS = 8
    }

    private val lock = Any()
    private val binds = LinkedHashMap<String, OfficeAiSessionBind>()

    fun bind(record: OfficeAiSessionBind) = synchronized(lock) {
        binds.remove(record.sessionToken)
        binds[record.sessionToken] = record
        while (binds.size > MAX_BINDS) binds.remove(binds.keys.first())
    }

    fun get(sessionToken: String): OfficeAiSessionBind? = synchronized(lock) { binds[sessionToken] }

    fun forget(sessionToken: String) = synchronized(lock) { binds.remove(sessionToken) }

    fun clear() = synchronized(lock) { binds.clear() }

    /** True only while the record still names this exact epoch. */
    fun belongsToEpoch(epoch: Long): Boolean = synchronized(lock) {
        binds.values.any { it.nativeEpoch == epoch }
    }
}

internal data class OfficeAiCaptureRecord(
    val sessionToken: String,
    val generation: Long,
    val ownerTaskID: String,
    val workspaceID: String?,
    val targetHandle: String,
    val docType: String?,
    val partsCount: Int?,
    val selectedPart: String?,
    /** ACTUAL captured logical 0-based part index (resolved from the engine's
     * own selectedpart decimal part id), null when unparseable — NEVER a
     * sheet1/slide1 default. */
    val partIndex: Int?,
    val documentModified: Boolean?,
    val workingCopySha256AtCapture: String?,
    val workingCopyBytesAtCapture: Long,
    /** The retained immutable pre-edit baseline (bytes copied from the
     * working copy file at capture; null when retention was impossible —
     * the semantic delta then stays honestly unprovable). */
    val baselineFile: File?,
    val baselineSha256: String?,
    val baselineBytes: Long,
    val capturedAtElapsedMs: Long,
    val expiresAtElapsedMs: Long,
) {
    /** Prior selection text for the verifier rides the SelectionLedger (the
     * engine selection answer is a separate query); this record binds the
     * capture identity itself. */
    fun usable(clockNow: Long): Boolean =
        clockNow < expiresAtElapsedMs && baselineFile?.isFile == true
}

internal class CaptureStore(private val clock: () -> Long) {
    companion object {
        const val MAX_PER_SESSION = 4
        const val MAX_TOTAL = 24

        /** Grace after the engine handle expiry before the baseline file may
         * be pruned (a verify in flight still reads the retained bytes). */
        const val EXPIRY_GRACE_MS = 60_000L
    }

    private val lock = Any()
    private val records = LinkedHashMap<String, ArrayDeque<OfficeAiCaptureRecord>>()

    private fun key(sessionToken: String, handle: String) = "$sessionToken|$handle"

    fun put(record: OfficeAiCaptureRecord) = synchronized(lock) {
        val queue = records.getOrPut(record.sessionToken) { ArrayDeque() }
        queue.addLast(record)
        while (queue.size > MAX_PER_SESSION) dropOldest(queue.removeFirst())
        var total = records.values.sumOf { it.size }
        while (total > MAX_TOTAL) {
            val oldestSession = records.entries.firstOrNull { it.value.isNotEmpty() } ?: break
            dropOldest(oldestSession.value.removeFirst())
            total--
            if (oldestSession.value.isEmpty()) records.remove(oldestSession.key)
        }
    }

    fun get(sessionToken: String, targetHandle: String): OfficeAiCaptureRecord? =
        synchronized(lock) {
            records[sessionToken]?.firstOrNull { it.targetHandle == targetHandle }
        }

    /** Newest live capture for the exact session (used to bind a content
     * effect when the command carries the handle the store has seen). */
    fun latestForSession(sessionToken: String, generation: Long): OfficeAiCaptureRecord? =
        synchronized(lock) {
            records[sessionToken]?.lastOrNull { it.generation == generation }
        }

    fun forgetSession(sessionToken: String) = synchronized(lock) {
        records.remove(sessionToken)?.forEach { dropOldest(it) }
    }

    private fun dropOldest(record: OfficeAiCaptureRecord?) {
        // Baseline retention is recoverable-by-re-capture only after the
        // capture expiry; within the grace the file stays put even if the
        // RAM record is evicted (the verify path re-reads actual bytes).
        if (record == null) return
        val now = clock()
        if (record.baselineFile != null && now - record.expiresAtElapsedMs > EXPIRY_GRACE_MS) {
            runCatching { record.baselineFile.delete() }
        }
    }

    fun clear() = synchronized(lock) {
        records.values.flatten().forEach { record ->
            runCatching { record.baselineFile?.delete() }
        }
        records.clear()
    }

    fun count(): Int = synchronized(lock) { records.values.sumOf { it.size } }
}

internal data class OfficeAiEffectRecord(
    val sessionToken: String,
    val generation: Long,
    val ownerTaskID: String,
    val targetHandle: String,
    val opId: String,
    val action: String,
    /** The raw expected text digest (the codec apostrophe is never part of
     * the wanted value; correlation is by identity, never by content). */
    val expectedSha256: String,
    val terminalState: OfficePrecisionState?,
    val workingCopySha256AfterEffect: String?,
    val dispatchedAtElapsedMs: Long,
) {
    val provesNativeEffect: Boolean
        get() = terminalState == OfficePrecisionState.MUTATION_VERIFIED
}

internal class EffectLedger(private val clock: () -> Long) {
    companion object {
        const val MAX_SESSION = 16
        const val MAX_TOTAL = 96
    }

    private val lock = Any()
    private val records = LinkedHashMap<String, ArrayDeque<OfficeAiEffectRecord>>()

    /** Dispatched-before-decision gate: a content opId already dispatched in
     * THIS session can never be re-dispatched by a retry. */
    fun alreadyDispatched(sessionToken: String, opId: String): Boolean = synchronized(lock) {
        records[sessionToken]?.any { it.opId == opId } == true
    }

    fun recordDispatched(record: OfficeAiEffectRecord) = synchronized(lock) {
        val queue = records.getOrPut(record.sessionToken) { ArrayDeque() }
        queue.addLast(record)
        while (queue.size > MAX_SESSION) queue.removeFirst()
        var total = records.values.sumOf { it.size }
        while (total > MAX_TOTAL) {
            val oldest = records.entries.firstOrNull { it.value.isNotEmpty() } ?: break
            oldest.value.removeFirst()
            total--
            if (oldest.value.isEmpty()) records.remove(oldest.key)
        }
    }

    fun settleOpId(sessionToken: String, opId: String, terminal: OfficePrecisionState,
                   workingCopySha256: String?) = synchronized(lock) {
        val queue = records[sessionToken] ?: return@synchronized
        var updated = false
        val next = queue.map { record ->
            if (record.opId == opId) {
                updated = true
                record.copy(terminalState = terminal, workingCopySha256AfterEffect = workingCopySha256)
            } else record
        }
        if (updated) {
            queue.clear()
            queue.addAll(next)
        }
    }

    /** The ONLY source of `targetEffectVerified`: the same captured target,
     * the exact owned effect opId, the same session/generation AND the real
     * engine MUTATION_VERIFIED terminal. nativeCompleted/ack alone is never
     * proof. */
    fun provesMutationVerified(sessionToken: String, generation: Long, targetHandle: String,
                               effectOpId: String): Boolean = synchronized(lock) {
        records[sessionToken]?.any {
            it.opId == effectOpId && it.generation == generation &&
                it.targetHandle == targetHandle.lowercase() && it.provesNativeEffect
        } == true
    }

    fun forgetSession(sessionToken: String) = synchronized(lock) { records.remove(sessionToken) }

    fun clear() = synchronized(lock) { records.clear() }
}

/** The latest observed selection answer for one session (typed
 * QUERY_TEXT_SELECTION facts preserved for the verifier's prior-selection
 * baseline; content itself never leaves the host except through the bounded
 * verify input). */
internal data class OfficeAiSelectionFact(
    val sessionToken: String,
    val generation: Long,
    val selectionText: String,
    val selectionByteCount: Int,
    val observedAtElapsedMs: Long,
)

internal class SelectionLedger {
    companion object { const val MAX = 8 }

    private val lock = Any()
    private val latest = LinkedHashMap<String, OfficeAiSelectionFact>()

    fun observe(fact: OfficeAiSelectionFact) = synchronized(lock) {
        latest[fact.sessionToken] = fact
        while (latest.size > MAX) latest.remove(latest.keys.first())
    }

    fun forSession(sessionToken: String, generation: Long): OfficeAiSelectionFact? =
        synchronized(lock) {
            latest[sessionToken]?.takeIf { it.generation == generation }
        }

    fun forgetSession(sessionToken: String) = synchronized(lock) { latest.remove(sessionToken) }

    fun clear() = synchronized(lock) { latest.clear() }
}

/**
 * The typed outcome of one AI save submit through the SAME existing
 * transaction-20 binding (Main host20 final review — the precision adapter's
 * dispatch-proof distinction applied to the save surface):
 *  - [NotBound] proves the command binder was NOT available and no
 *    submitSave transaction was attempted: nothing reached the engine and a
 *    fresh ticket may retry;
 *  - [AttemptedWithoutReply] means the submitSave transaction WAS issued and
 *    its reply was lost (or the client frame failed after issue): the op may
 *    already hold the engine. It must be resolved through the
 *    ALREADY-registered exact-key receipt waiter (real terminal receipt) or
 *    answered UNKNOWN/retained — NEVER re-sent and never labeled definitely
 *    un-dispatched;
 *  - [Code] carries the real unchanged [com.floe.android.core.officeengine.OfficeEngineCommandsPolicy]
 *    reply code.
 */
internal sealed interface OfficeAiSaveSubmit {
    object NotBound : OfficeAiSaveSubmit
    object AttemptedWithoutReply : OfficeAiSaveSubmit
    data class Code(val value: Int) : OfficeAiSaveSubmit
}

/** Bounded exact-op keys dispatched through the Office AI save lane. A
 * tracked (sessionToken, opId) must NEVER receive a manual SAF picker
 * prepare from the Save-Copy host: the AI chain consumes its own typed
 * receipts (Main host20). Ops are unique per dispatch, so entries simply
 * age out of the bounded table. */
internal class OfficeAiOperationGuard {
    companion object { const val MAX_TRACKED = 128 }

    private val lock = Any()
    private val keys = LinkedHashMap<String, Boolean>()

    private fun key(sessionToken: String, opId: String): String = "$sessionToken|$opId"

    fun track(sessionToken: String, opId: String) = synchronized(lock) {
        keys[key(sessionToken, opId)] = true
        while (keys.size > MAX_TRACKED) keys.remove(keys.keys.first())
    }

    fun contains(sessionToken: String, opId: String): Boolean =
        synchronized(lock) { keys.containsKey(key(sessionToken, opId)) }

    fun clear() = synchronized(lock) { keys.clear() }
}

/** The owned save receipt waiter table. The handoff-level receipt observer
 * feeds it FIRST for every shape-valid receipt; waiters are keyed by the
 * EXACT opId + sessionToken + native generation, so a foreign or late
 * receipt completes nothing. */
internal class SaveWaiters {
    data class Key(val sessionToken: String, val generation: Long, val opId: String)

    private val lock = Any()

    private class Waiter {
        val deferred = CompletableDeferred<OfficeSaveReceipt>()
        var terminalSeen = false
    }

    private val waiters = HashMap<Key, Waiter>()

    /** Register BEFORE dispatch. A duplicate key never double-waits. */
    fun register(key: Key): CompletableDeferred<OfficeSaveReceipt>? = synchronized(lock) {
        if (waiters.containsKey(key)) return@synchronized null
        Waiter().also { waiters[key] = it }.deferred
    }

    fun remove(key: Key) { synchronized(lock) { waiters.remove(key) } }

    /** Called from the observer (Binder thread). Returns true when exactly
     * one live waiter consumed this terminal receipt. SUBMITTED is not a
     * terminal state and never completes a waiter. */
    fun observe(receipt: OfficeSaveReceipt): Boolean {
        val key = Key(receipt.sessionToken, receipt.generation, receipt.opId)
        val waiter = synchronized(lock) {
            waiters[key] ?: return false
        }
        val terminal = when (receipt.state) {
            com.floe.android.core.officeengine.OfficeSaveState.SUBMITTED -> false
            else -> true
        }
        if (!terminal) return false
        var consumed = false
        synchronized(lock) {
            if (!waiter.terminalSeen) {
                waiter.terminalSeen = true
                consumed = true
                waiters.remove(key)
            }
        }
        if (consumed) waiter.deferred.complete(receipt)
        return consumed
    }

    fun clear() = synchronized(lock) {
        waiters.keys.toList().forEach { waiters.remove(it) }
    }
}
