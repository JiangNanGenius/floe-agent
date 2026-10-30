// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.network

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * RuntimeHost-owned, serialized network diagnostics host pump.
 *
 * Mirrors the accepted [com.floe.android.host.officeai.OfficeAiHostPump]
 * shape over the delivered [com.floe.android.bridge.NetworkDiagnosticsNative]
 * claims:
 *
 *  - ONE reader per bound epoch; tickets execute ONE AT A TIME under
 *    NonCancellable with real admission rechecks (parent cancellation can
 *    never detach an in-flight phone request);
 *  - every CLAIMED ticket settles EXACTLY once: status 0 + observation JSON,
 *    or status 1 + `{"code","detail"}`. A stop/fence/expire never drops a
 *    claimed ticket silently; a negative complete result is terminal
 *    classification and the pump never retries or double-settles;
 *  - `shouldStop == 1` stops NEW dispatch and calls the SAME
 *    `PhoneNetworkService.cancel(operationID)`; the service's own bounded
 *    execute still settles once (no fabricated observation on cancellation);
 *  - the request JSON is handed UNCHANGED to the Application-owned service;
 *    this pump owns no permission state and never retries a probe;
 *  - stop/drain BEFORE Root close: [stopAndJoin] reports false while the old
 *    generation remains owned/pending. The reader's finally performs the
 *    exact-epoch close only after real settlement.
 *
 * Availability is REAL: the eight `network.*` tools are registered by the
 * Swift bind, and the bind is only attempted when an actual service is
 * present. A missing service leaves the lane honestly absent.
 */
internal class NetworkDiagnosticsHostPump(
    private val scope: CoroutineScope,
    private val ioDispatcher: CoroutineDispatcher,
    private val currentNativeEpoch: () -> Long?,
    private val serviceProvider: () -> PhoneNetworkServicePort?,
    private val transport: NetworkDiagnosticsNativeTransport =
        NativeNetworkDiagnosticsTransport,
    private val onPermissionRequired: (NetworkPermissionRequest) -> Unit = {},
    private val timing: NetworkDiagnosticsTiming = NetworkDiagnosticsTiming(),
) {
    private val starts = Mutex()

    private class Session(val epoch: Long) {
        val stopping = AtomicBoolean(false)
        var reader: Job? = null
    }

    private sealed interface Settlement {
        class Success(val body: ByteArray) : Settlement
        class Failure(val code: String, val detail: String?) : Settlement
    }

    @Volatile
    private var session: Session? = null

    private val settlementCount = AtomicInteger(0)
    private val refusedSettlementCount = AtomicInteger(0)
    private val staleSettlementCount = AtomicInteger(0)

    val boundNativeEpoch: Long get() = session?.epoch ?: 0L

    fun isRunning(): Boolean =
        session?.reader?.isActive == true && session?.stopping?.get() == false

    /** Identity-safe counters (no targets, paths, ids or payloads). */
    fun settlementStats(): Triple<Int, Int, Int> = Triple(
        settlementCount.get(), refusedSettlementCount.get(), staleSettlementCount.get(),
    )

    /** Admission for a CLAIMED ticket before any dispatch. */
    private fun admitted(value: Session, claim: Long): Boolean =
        !value.stopping.get() && currentNativeEpoch() == value.epoch &&
            transport.isLive(claim) == 1 && transport.shouldStop(claim) != 1

    /** True when the exact generation/tool call has requested a stop. */
    private fun stopSignal(value: Session, claim: Long): Boolean =
        value.stopping.get() || currentNativeEpoch() != value.epoch ||
            transport.shouldStop(claim) == 1

    private fun fencedSettlement(value: Session): Settlement =
        if (value.stopping.get() || currentNativeEpoch() != value.epoch) {
            Settlement.Failure("laneFenced", null)
        } else {
            Settlement.Failure("sessionEnding", null)
        }

    @OptIn(ExperimentalCoroutinesApi::class)
    suspend fun start(epoch: Long): Boolean = starts.withLock {
        if (!scope.isActive || epoch <= 0 || currentNativeEpoch() != epoch) {
            return@withLock false
        }
        session?.let { existing ->
            return@withLock existing.epoch == epoch &&
                existing.reader?.isActive == true && !existing.stopping.get()
        }
        // No service means no capability. Binding anyway would advertise eight
        // tools the host cannot execute; keep the lane honestly absent.
        if (serviceProvider() == null) return@withLock false
        val bound = try {
            transport.bindEpoch(epoch) == 0
        } catch (_: LinkageError) {
            false
        }
        if (!bound) return@withLock false
        val value = Session(epoch)
        session = value
        value.reader = scope.launch(ioDispatcher, start = CoroutineStart.ATOMIC) {
            try {
                while (isActive && !value.stopping.get() &&
                    currentNativeEpoch() == epoch
                ) {
                    val claim = try {
                        transport.next(timing.nextPollMillis)
                    } catch (_: LinkageError) {
                        value.stopping.set(true)
                        continue
                    }
                    if (claim <= 0) continue
                    withContext(NonCancellable + ioDispatcher) {
                        execute(value, claim)
                    }
                }
            } finally {
                withContext(NonCancellable + ioDispatcher) {
                    value.stopping.set(true)
                    runCatching { transport.close(epoch) }
                    if (session === value) session = null
                }
            }
        }
        true
    }

    /** False means the old generation remains owned/pending. */
    suspend fun stopAndJoin(expectedEpoch: Long, waitMillis: Long): Boolean =
        starts.withLock {
            require(waitMillis > 0)
            val value = session ?: return@withLock true
            if (value.epoch != expectedEpoch) return@withLock false
            value.stopping.set(true)
            val joined = withTimeoutOrNull(waitMillis) {
                value.reader?.join()
                true
            } ?: (value.reader?.isCompleted == true)
            if (!joined) return@withLock false
            if (session === value) session = null
            true
        }

    fun statsJson(): String? = runCatching {
        transport.stats()?.toString(Charsets.UTF_8)
    }.getOrNull()

    fun readinessJson(): String? = runCatching {
        transport.readiness()?.toString(Charsets.UTF_8)
    }.getOrNull()

    // ------------------------------------------------------------------
    // One claim: parse -> recheck -> execute -> settle exactly once
    // ------------------------------------------------------------------

    private suspend fun execute(value: Session, claim: Long) {
        var settlement: Settlement = Settlement.Failure("internal", null)
        try {
            val descriptorBytes = transport.describe(claim)
            if (descriptorBytes == null) {
                settlement = Settlement.Failure("descriptorInvalid", null)
                return
            }
            val ticket = try {
                NetworkDiagnosticsWire.parseDescriptor(descriptorBytes, value.epoch)
            } catch (refusal: NetworkDiagnosticsWire.Refusal) {
                settlement = Settlement.Failure(refusal.code, refusal.detail)
                return
            }
            if (!admitted(value, claim)) {
                settlement = fencedSettlement(value)
                return
            }
            val payload = transport.payload(claim)
            if (payload == null) {
                settlement = Settlement.Failure("requestInvalid", null)
                return
            }
            val facts = try {
                NetworkDiagnosticsWire.validateRequest(payload, ticket)
            } catch (refusal: NetworkDiagnosticsWire.Refusal) {
                settlement = Settlement.Failure(refusal.code, refusal.detail)
                return
            }
            val service = serviceProvider()
            if (service == null) {
                settlement = Settlement.Failure("serviceUnavailable", null)
                return
            }
            if (stopSignal(value, claim)) {
                runCatching { service.cancel(ticket.operationID) }
                settlement = Settlement.Failure("cancelled", null)
                return
            }
            val requestText = NetworkDiagnosticsWire.strictText(payload)
            if (requestText == null) {
                settlement = Settlement.Failure("requestInvalid", null)
                return
            }
            val observation = runService(value, claim, ticket, service, requestText)
            if (observation == null) {
                runCatching { service.cancel(ticket.operationID) }
                settlement = Settlement.Failure("timeout", null)
                return
            }
            val status = try {
                NetworkDiagnosticsWire.validateObservation(observation, ticket)
            } catch (refusal: NetworkDiagnosticsWire.Refusal) {
                settlement = Settlement.Failure(refusal.code, refusal.detail)
                return
            }
            // A cancellation is a REQUEST, but a claim whose owner already
            // asked to stop must settle as a typed fenced/sessionEnding
            // failure: its phone observation belongs to a stopped execution
            // and must never be presented as the tool's result.
            if (stopSignal(value, claim)) {
                settlement = fencedSettlement(value)
                return
            }
            if (status == "permissionRequired" && !stopSignal(value, claim)) {
                // Forward, do not store: the existing Application LAN broker
                // / host UI owns every permission decision and prompt.
                runCatching {
                    NetworkDiagnosticsWire.permissionRequest(
                        observation, ticket, facts,
                    )?.let(onPermissionRequired)
                }
            }
            settlement = Settlement.Success(observation)
        } catch (_: kotlinx.coroutines.CancellationException) {
            // Even under cancellation the claim MUST settle once.
            settlement = Settlement.Failure("cancelled", null)
        } catch (unexpected: Throwable) {
            settlement = Settlement.Failure(
                "serviceFailure", unexpected.javaClass.simpleName.take(48),
            )
        } finally {
            settle(claim, settlement)
        }
    }

    /** Runs one service call with a bounded backstop and a cancellation
     * watcher. Returns null only when the host backstop fired; the service's
     * own typed cancelled/timeout observation is passed through unchanged. */
    private suspend fun runService(
        value: Session,
        claim: Long,
        ticket: NetworkDiagnosticsWire.Ticket,
        service: PhoneNetworkServicePort,
        requestText: String,
    ): ByteArray? = coroutineScope {
        val cancelRequested = AtomicBoolean(false)
        val watcher = launch(ioDispatcher) {
            while (isActive) {
                if (stopSignal(value, claim)) {
                    if (cancelRequested.compareAndSet(false, true)) {
                        runCatching { service.cancel(ticket.operationID) }
                    }
                    break
                }
                delay(timing.cancelPollMillis)
            }
        }
        try {
            withTimeoutOrNull(timing.maximumExecutionMillis) {
                service.execute(requestText)
            }?.toByteArray(Charsets.UTF_8)
        } finally {
            watcher.cancel()
        }
    }

    private fun settle(claim: Long, settlement: Settlement) {
        val (status, body) = when (settlement) {
            is Settlement.Success -> 0 to settlement.body
            is Settlement.Failure -> 1 to NetworkDiagnosticsWire.failureBytes(
                settlement.code, settlement.detail,
            )
        }
        val cap = if (status == 0) {
            NetworkDiagnosticsWire.MAX_OBSERVATION_BYTES
        } else {
            NetworkDiagnosticsWire.MAX_FAILURE_BYTES
        }
        if (body.isEmpty() || body.size > cap) {
            val fallback = NetworkDiagnosticsWire.failureBytes("internal", null)
            refusedSettlementCount.incrementAndGet()
            runCatching { transport.complete(claim, 1, fallback) }
            return
        }
        val result = runCatching { transport.complete(claim, status, body) }
            .getOrDefault(-1)
        if (result == 0) {
            settlementCount.incrementAndGet()
        } else {
            // stale/fenced/not-claimed: the mailbox owns final classification.
            staleSettlementCount.incrementAndGet()
        }
    }
}

internal class NetworkDiagnosticsTiming(
    val nextPollMillis: Int = 250,
    val maximumExecutionMillis: Long = 40_000L,
    val cancelPollMillis: Long = 100L,
)
