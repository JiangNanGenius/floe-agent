// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officeai

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * The RuntimeHost-owned, serialized Office AI host pump (host20) — the exact
 * 1:1 mirror of the accepted [com.floe.android.host.WorkspaceSourcePump]
 * shape over the delivered [com.floe.android.bridge.OfficeAiNative] claims:
 *
 *  - one reader per bound epoch; tickets execute ONE AT A TIME under
 *    NonCancellable with real admission rechecks (parent cancellation can
 *    never detach in-flight native/provider work);
 *  - every CLAIMED ticket settles EXACTLY once: status 0 + bounded success
 *    JSON, or status 1 + `{"code","detail"}`. A stop/fence/expire never drops
 *    a claimed ticket silently; a negative [complete] result (stale claim
 *    -101 / fenced -102 / not-claimed -110) is terminal classification — the
 *    pump never retries or double-settles;
 *  - `shouldStop == 1` stops NEW dispatch but work already dispatched to the
 *    engine or the provider ladder runs to its honest terminal (no force
 *    clean-cancel while native/provider IO is live; no auto-replay, no
 *    auto-undo, no close/discard of the working copy);
 *  - stop/drain BEFORE Root close: [stopAndJoin] reports false while the old
 *    generation remains owned/pending — it is never declared stopped because
 *    a wait expired. The reader's own finally performs the exact-epoch
 *    `close` and detaches the Save-Copy receipt observer only after real
 *    settlement.
 *
 * Availability is REAL: `document.office.edit` becomes usable only when
 * [start] actually bound the CURRENT epoch; a LinkageError/refusal keeps the
 * lane honestly absent.
 */
internal class OfficeAiHostPump(
    private val scope: CoroutineScope,
    private val ioDispatcher: CoroutineDispatcher,
    private val currentNativeEpoch: () -> Long?,
    private val ports: OfficeAiDocumentPorts,
    private val transport: OfficeAiNativeTransport,
    private val verifier: OfficeAiSavedPackageVerifier,
    private val timing: OfficeAiTiming = OfficeAiTiming(),
) {
    private val starts = Mutex()

    internal class Session(
        val epoch: Long,
        val binds: SessionBinds,
        val captures: CaptureStore,
        val effects: EffectLedger,
        val selections: SelectionLedger,
        val waiters: SaveWaiters,
        val stopping: AtomicBoolean,
    ) {
        var reader: Job? = null
    }

    /** Admission for a CLAIMED ticket before any dispatch: the bound epoch
     * must still be the live root, the mailbox must still hold the claim and
     * the owning operation must not have stopped it. Mirrors the delivered
     * WorkspaceSourcePump `admitted` rule exactly. */
    private fun admitted(value: Session, claim: Long): Boolean =
        !value.stopping.get() && currentNativeEpoch() == value.epoch &&
            transport.isLive(claim) == 1 && transport.shouldStop(claim) != 1

    /** Live-ticket stop closure the service rechecks BEFORE dispatching a
     * real effect. A stop never revokes work already dispatched: that runs
     * to its honest terminal (no force clean-cancel, no auto-undo, no
     * replay). */
    private fun stopSignal(value: Session, claim: Long): () -> Boolean = {
        value.stopping.get() || currentNativeEpoch() != value.epoch ||
            transport.shouldStop(claim) == 1
    }

    @Volatile
    private var session: Session? = null

    /** Bounded, content-free diagnostic counters (classifications only). */
    private val settlementCount = AtomicInteger(0)
    private val staleSettlementCount = AtomicInteger(0)

    val boundNativeEpoch: Long get() = session?.epoch ?: 0L

    /** Identity-safe settlement stats for explicit diagnostics (no paths,
     * tokens, content or timing claims). */
    fun settlementStats(): Pair<Int, Int> =
        settlementCount.get() to staleSettlementCount.get()

    fun isRunning(): Boolean = session?.reader?.isActive == true &&
        session?.stopping?.get() == false

    @OptIn(ExperimentalCoroutinesApi::class)
    suspend fun start(epoch: Long): Boolean = starts.withLock {
        if (!scope.isActive || epoch <= 0 || currentNativeEpoch() != epoch) return@withLock false
        session?.let { existing ->
            return@withLock existing.epoch == epoch && existing.reader?.isActive == true &&
                !existing.stopping.get()
        }
        val bound = try {
            transport.bindEpoch(epoch) == 0
        } catch (_: LinkageError) {
            false
        }
        if (!bound) return@withLock false
        val value = Session(
            epoch = epoch,
            binds = SessionBinds(),
            captures = CaptureStore(ports::elapsedMs),
            effects = EffectLedger(ports::elapsedMs),
            selections = SelectionLedger(),
            waiters = SaveWaiters(),
            stopping = AtomicBoolean(),
        )
        // The ONE application-owned Save-Copy host instance receives this
        // lane's observer; the existing channel-28 registration and the
        // STAGED_EXPORT Save-Copy filter underneath the observer stay the
        // sole owner of the manual picker flow.
        runCatching { ports.attachSaveReceiptObserver { receipt -> value.waiters.observe(receipt) } }
            .onFailure {
                runCatching { transport.close(epoch) }
                return@withLock false
            }
        session = value
        value.reader = scope.launch(ioDispatcher, start = CoroutineStart.ATOMIC) {
            try {
                while (isActive && !value.stopping.get() && currentNativeEpoch() == epoch) {
                    val claim = try {
                        transport.next(NEXT_POLL_MILLIS)
                    } catch (_: LinkageError) {
                        value.stopping.set(true)
                        continue
                    }
                    if (claim <= 0) continue
                    // Parent cancellation cannot detach native/provider IO:
                    // the claim executes and settles under NonCancellable.
                    withContext(NonCancellable + ioDispatcher) {
                        execute(value, claim)
                    }
                }
            } finally {
                withContext(NonCancellable + ioDispatcher) {
                    value.stopping.set(true)
                    // Claims still in flight were executed inside this same
                    // reader, so by here nothing is pending. Settle records
                    // for the retired generation must never address a newer
                    // pump: clear the RAM ledgers and detach the observer.
                    value.waiters.clear()
                    runCatching { transport.close(epoch) }
                    runCatching { ports.detachSaveReceiptObserver() }
                    runCatching { ports.releaseTransports() }
                    value.binds.clear()
                    value.captures.clear()
                    value.effects.clear()
                    value.selections.clear()
                }
            }
        }
        true
    }

    /** False means the old generation remains owned/pending; it is never
     * replaced or declared stopped merely because a wait expired. */
    suspend fun stopAndJoin(expectedEpoch: Long, waitMillis: Long): Boolean = starts.withLock {
        require(waitMillis > 0)
        val value = session ?: return@withLock true
        if (value.epoch != expectedEpoch) return@withLock false
        value.stopping.set(true)
        val joined = withTimeoutJoin(value, waitMillis)
        if (!joined) return@withLock false
        if (session === value) session = null
        true
    }

    /** A running reader is joined; a reader that finished on its own (an old
     * transport refusal path) is still settled through its NonCancellable
     * finally by this point. */
    private suspend fun withTimeoutJoin(value: Session, waitMillis: Long): Boolean =
        kotlinx.coroutines.withTimeoutOrNull(waitMillis) {
            value.reader?.join()
            true
        } ?: (value.reader?.isCompleted == true)

    /** Diagnostics only: identity-safe counters (no paths, tokens, content). */
    fun statsJson(): String? = runCatching {
        transport.stats()?.toString(Charsets.UTF_8)
    }.getOrNull()

    // ------------------------------------------------------------------
    // One claim: parse -> recheck -> execute -> settle exactly once
    // ------------------------------------------------------------------

    private suspend fun execute(value: Session, claim: Long) {
        var settlement: OfficeAiWire.Settlement =
            OfficeAiWire.Settlement.Failure("internal", null)
        try {
            val descriptor = transport.describe(claim)
            if (descriptor == null) {
                settlement = OfficeAiWire.Settlement.Failure("internal", "descriptor unavailable")
                return
            }
            val ticket = try {
                OfficeAiWire.parseDescriptor(descriptor, value.epoch)
            } catch (refusal: OfficeAiWire.Refusal) {
                settlement = OfficeAiWire.Settlement.Failure(refusal.code, refusal.detail)
                return
            }
            if (!admitted(value, claim)) {
                settlement = if (value.stopping.get() || currentNativeEpoch() != value.epoch) {
                    OfficeAiWire.Settlement.Failure("laneFenced", null)
                } else {
                    OfficeAiWire.Settlement.Failure("sessionEnding", null)
                }
                return
            }
            val staged = when (OfficeAiWire.stageFor(ticket.operation, ticket.fields)) {
                OfficeAiWire.Stage.NONE -> ByteArray(0)
                OfficeAiWire.Stage.REQUIRED, OfficeAiWire.Stage.OPTIONAL ->
                    transport.payload(claim) ?: ByteArray(0)
            }
            val service = OfficeAiHostService(
                epoch = value.epoch,
                ports = ports,
                binds = value.binds,
                captures = value.captures,
                effects = value.effects,
                selections = value.selections,
                saveWaiters = value.waiters,
                verifier = verifier,
                timing = timing,
            )
            settlement = service.execute(ticket, staged, stopSignal(value, claim))
        } catch (cancellation: kotlinx.coroutines.CancellationException) {
            // Even under cancellation the claim MUST settle once (never a
            // silent drop): the mailbox is the only claim garbage collector.
            settlement = OfficeAiWire.Settlement.Failure("sessionEnding", null)
        } catch (unexpected: Throwable) {
            settlement = OfficeAiWire.Settlement.Failure(
                "internal", unexpected.javaClass.simpleName.take(64),
            )
        } finally {
            settle(claim, settlement)
        }
    }

    private fun settle(claim: Long, settlement: OfficeAiWire.Settlement) {
        val body = when (settlement) {
            is OfficeAiWire.Settlement.Success ->
                0 to settlement.body.toString().toByteArray(Charsets.UTF_8)
            is OfficeAiWire.Settlement.Failure ->
                1 to OfficeAiWire.failureBytes(settlement.code, settlement.detail)
        }
        if (body.second.size > if (body.first == 0) OfficeAiWire.MAX_REPLY_BYTES
            else OfficeAiWire.MAX_FAILURE_REPLY_BYTES
        ) {
            // Absolute bound breach: fall back to the smallest typed failure
            // instead of a silent drop or a truncated body.
            val fallback = OfficeAiWire.failureBytes("internal", null)
            runCatching { transport.complete(claim, 1, fallback) }
            return
        }
        settlementCount.incrementAndGet()
        val result = runCatching { transport.complete(claim, body.first, body.second) }.getOrDefault(-1)
        if (result != 0) {
            // -101 stale / -102 fenced / -110 not claimed: the mailbox owns
            // the final classification. The pump NEVER re-dispatches and
            // NEVER double-settles; only a bounded counter records it.
            staleSettlementCount.incrementAndGet()
        }
    }

    private companion object {
        const val NEXT_POLL_MILLIS = 250
    }
}
