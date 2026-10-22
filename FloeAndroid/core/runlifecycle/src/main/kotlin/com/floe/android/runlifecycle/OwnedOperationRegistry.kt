// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runlifecycle

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * TRANSIENT service-ownership ledger: it records which REAL operations the
 * Core foreground service currently protects, for the lifetime of THIS
 * process only. It is deliberately not a run/job/environment database —
 * nothing here survives process death, nothing here re-admits or restores
 * work, and no command or owner authority is ever read from an Intent.
 *
 * Fences (settled contract, hardened by Main's review):
 *  * SET MUTATIONS and the stop decision share ONE `decisionLock`. The
 *    stop press is fenced by comparing the rendered stamp AND capturing an
 *    exact (operationID, ownerGeneration, handler) snapshot atomically
 *    under that lock: an operation acquired AFTER the press can never be
 *    part of it, and handler invocation happens outside the lock against
 *    the captured snapshot only — live map values are never iterated.
 *  * every registration carries a monotonic `ownerGeneration`; a release
 *    or permit answer matches the EXACT generation, so a stale-generation
 *    close is refused and NEVER routes to a replacement entry;
 *  * an operationID is single-flight: a same-id re-acquire with the SAME
 *    kind attaches with an honest refcount (every attached lease must
 *    close before the owned set changes); a same-id re-acquire with a
 *    DIFFERENT kind is REFUSED as an owner conflict and mutates nothing.
 *    No lease close can silently revoke a still-owned operation;
 *  * `isEmpty()` is the honest idle signal used to stop the foreground
 *    service promptly once all actual work has settled.
 *
 * The permit read (`isActive`) stays lock-free (concurrent-map read plus
 * the caller-supplied foreground flag) so the Binder callback can never
 * nest into the decision lock.
 *
 * The token type is generic so the pure decision core is unit-testable on
 * the JVM without android classes; the production registry instantiates it
 * with the per-operation permit Binder.
 */
internal class OwnedOperationRegistry<Token> {

    class Entry<T>(
        val operationID: String,
        val kind: OperationKind,
        val ownerGeneration: Long,
        val stopHandler: RunStopHandler?,
        val token: T,
    ) {
        /** Number of live leases holding THIS exact registration. Starts
         *  at 1; same-kind re-acquires increment it. A close decrements
         *  exactly once per lease object (the lease guards its own
         *  double-close); the entry is removed only at zero. */
        internal val leaseCount = AtomicInteger(1)
    }

    private val decisionLock = Any()
    private val entries = ConcurrentHashMap<String, Entry<Token>>()
    private val generationSeq = AtomicLong(0)

    @Volatile
    private var stamp: Long = 0

    val currentStamp: Long get() = stamp

    fun isEmpty(): Boolean = entries.isEmpty()

    fun size(): Int = entries.size

    fun heldKinds(): Set<OperationKind> = entries.values.mapTo(LinkedHashSet()) { it.kind }

    fun heldOperationIDs(): Set<String> = HashSet(entries.keys)

    /**
     * Exact identity for the permit callback and the foreground decision:
     * active == this generation's registration is STILL owned AND the
     * caller proves the real Core FGS is confirmed running. Memory-only
     * and lock-free: no registry lock, no native call, no disk, no UI —
     * the binder thread must never nest into anything the foreground
     * path holds.
     */
    fun isActive(operationID: String, ownerGeneration: Long, foregroundConfirmed: Boolean): Boolean {
        if (!foregroundConfirmed) return false
        val entry = entries[operationID] ?: return false
        return entry.ownerGeneration == ownerGeneration
    }

    /** Refcount of the exact live registration (test/observation only;
     *  never a permit decision path input). */
    fun leaseCount(operationID: String, ownerGeneration: Long): Int {
        val entry = entries[operationID] ?: return 0
        return if (entry.ownerGeneration == ownerGeneration) entry.leaseCount.get() else 0
    }

    /**
     * Register (or attach) service ownership for one REAL operation. The
     * kind conflict is checked under the decision lock so an acquire can
     * never slip between a concurrent stop snapshot's stamp check and its
     * set capture.
     *
     * Returns `entry to created`, or null ONLY on an honest same-id
     * different-kind conflict (the caller reads [kindOf] to build the
     * typed OwnerConflict). The fully-typed pair keeps every caller free
     * of unchecked casts.
     */
    fun acquire(
        operationID: String,
        kind: OperationKind,
        stopHandler: RunStopHandler?,
        tokenFactory: (operationID: String, ownerGeneration: Long) -> Token,
    ): Pair<Entry<Token>, Boolean>? {
        synchronized(decisionLock) {
            val existing = entries[operationID]
            if (existing != null) {
                if (existing.kind != kind) return null
                // Honest attach: the SAME still-owned operation gains a
                // second live lease; the entry stays until BOTH close.
                // A stop handler supplied on attach is ignored — the
                // ORIGINAL registration owns the cancellation route.
                existing.leaseCount.incrementAndGet()
                return existing to false
            }
            val generation = generationSeq.incrementAndGet()
            val token = tokenFactory(operationID, generation)
            val candidate = Entry(operationID, kind, generation, stopHandler, token)
            // putIfAbsent is still belt-and-braces under the lock; a loser
            // would mean an impossible concurrent non-locked insert.
            val winner = entries.putIfAbsent(operationID, candidate)
            if (winner != null) {
                if (winner.kind != kind) return null
                winner.leaseCount.incrementAndGet()
                return winner to false
            }
            stamp += 1
            return candidate to true
        }
    }

    /** Kind of the CURRENT exact-id live registration, if any (used to
     *  turn a null acquire into an honest typed OwnerConflict; a racing
     *  settle between the two reads can only ever make it EMPTY, never
     *  silently reassign an owner). */
    fun kindOf(operationID: String): OperationKind? = entries[operationID]?.kind

    /**
     * Idempotent exact-identity lease release. A stale generation never
     * touches a newer registration; a same-generation release decrements
     * this lease's contribution and removes ONLY at the last close.
     * Returns true when the OWNED SET actually changed (entry removed),
     * which is the only case that must notify the service.
     */
    fun release(operationID: String, ownerGeneration: Long): Boolean {
        synchronized(decisionLock) {
            val existing = entries[operationID] ?: return false
            if (existing.ownerGeneration != ownerGeneration) return false
            val remaining = existing.leaseCount.decrementAndGet()
            if (remaining > 0) return false
            // Last lease of this exact registration settled: remove the
            // exact object identity so a racing newer entry is impossible
            // under this same lock anyway.
            entries.remove(operationID, existing)
            stamp += 1
            return true
        }
    }

    /**
     * Stop-button routing. Under the decision lock the press must match
     * the CURRENT set stamp AND capture the exact owner snapshot the
     * notification was rendered for; anything added or replaced afterwards
     * is invisible or fenced. Handlers are invoked OUTSIDE the lock, only
     * for the captured (operationID, ownerGeneration) pairs, and ONLY if
     * that exact registration is still live — a stale-generation match
     * against a replacement never routes to the replacement. No lease is
     * closed here: ownership stays nonterminal until the real work
     * settles and its owner closes it.
     */
    fun routeStop(intentStamp: Long): Boolean {
        val captured: List<Triple<String, Long, RunStopHandler?>> = synchronized(decisionLock) {
            if (intentStamp != stamp) return false
            entries.values.map { Triple(it.operationID, it.ownerGeneration, it.stopHandler) }
        }
        for ((operationID, generation, handler) in captured) {
            val entry = entries[operationID] ?: continue
            if (entry.ownerGeneration != generation) continue
            entry.stopHandler?.onStopRequested()
        }
        return true
    }

    fun snapshotForTesting(): List<Triple<String, Long, OperationKind>> =
        entries.values.map { Triple(it.operationID, it.ownerGeneration, it.kind) }

    fun resetForTesting() {
        synchronized(decisionLock) {
            entries.clear()
            stamp = 0
            generationSeq.set(0)
        }
    }
}
