// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.networkartifact

import com.floe.android.core.networkmonitor.CoverageReportRenderer
import com.floe.android.core.networkmonitor.CoverageSessionStore
import com.floe.android.core.pcap.PcapAnalysisStore
import com.floe.android.core.pcap.PcapFilters
import com.floe.android.core.pcap.PcapProtocol
import com.floe.android.core.pcap.PcapReportRenderer
import com.floe.android.core.pcap.PcapServiceFilter
import com.floe.android.core.pcap.PcapSummaryView
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
 * Existing-authority seam. The App host must implement this from the actual
 * conversation/task authority; an opaque UUID is never authorization.
 * UI-created global artifacts additionally require the explicit per-artifact
 * user Agent-read grant (`agentReadable`) before this is consulted.
 */
data class NetworkArtifactPrincipal(
    val artifactID: String,
    val ownerTaskId: String?,
    val ownerWorkspaceId: String?,
    val agentReadable: Boolean,
)

data class NetworkArtifactCaller(
    val taskID: String,
    val runID: String,
    val epoch: Long,
    val workspaceFingerprint: String?,
)

fun interface NetworkArtifactAccess {
    fun canRead(principal: NetworkArtifactPrincipal, caller: NetworkArtifactCaller): Boolean

    companion object {
        /** Fail closed until the Host binds real task/workspace authority. */
        val DENY_ALL = NetworkArtifactAccess { _, _ -> false }
    }
}

internal interface NetworkArtifactNativeTransport {
    fun bindEpoch(epoch: Long): Int
    fun next(timeoutMillis: Int): Long
    fun describe(claim: Long): ByteArray?
    fun payload(claim: Long): ByteArray?
    fun isLive(claim: Long): Int
    fun shouldStop(claim: Long): Int
    fun complete(claim: Long, status: Int, value: ByteArray): Int
    fun close(epoch: Long): Int
    fun stats(): ByteArray?
    fun readiness(): ByteArray?
}

internal object NativeNetworkArtifactTransport : NetworkArtifactNativeTransport {
    override fun bindEpoch(epoch: Long): Int = NetworkArtifactNative.bindEpoch(epoch)
    override fun next(timeoutMillis: Int): Long = NetworkArtifactNative.next(timeoutMillis)
    override fun describe(claim: Long): ByteArray? = NetworkArtifactNative.describe(claim)
    override fun payload(claim: Long): ByteArray? = NetworkArtifactNative.payload(claim)
    override fun isLive(claim: Long): Int = NetworkArtifactNative.isLive(claim)
    override fun shouldStop(claim: Long): Int = NetworkArtifactNative.shouldStop(claim)
    override fun complete(claim: Long, status: Int, value: ByteArray): Int =
        NetworkArtifactNative.complete(claim, status, value)
    override fun close(epoch: Long): Int = NetworkArtifactNative.close(epoch)
    override fun stats(): ByteArray? = NetworkArtifactNative.stats()
    override fun readiness(): ByteArray? = NetworkArtifactNative.readiness()
}

/**
 * Read-only, epoch-fenced host pump for `network.pcapAnalyze` and
 * `network.coverageSummary`. It never captures, scans or imports; it only
 * projects an already saved bounded App artifact. Every claim is settled
 * exactly once, and a cancellation/fence settles typed without touching the
 * store.
 */
internal class NetworkArtifactHostPump(
    private val scope: CoroutineScope,
    private val ioDispatcher: CoroutineDispatcher,
    private val currentNativeEpoch: () -> Long?,
    private val pcapStore: PcapAnalysisStore,
    private val coverageStore: CoverageSessionStore,
    private val transport: NetworkArtifactNativeTransport = NativeNetworkArtifactTransport,
    private val access: NetworkArtifactAccess = NetworkArtifactAccess.DENY_ALL,
    private val timing: Timing = Timing(),
) {
    internal data class Timing(val nextPollMillis: Int = 250)

    private val starts = Mutex()

    private class Session(val epoch: Long) {
        val stopping = AtomicBoolean(false)
        var reader: Job? = null
    }

    private sealed interface Settlement {
        class Success(val body: ByteArray) : Settlement
        class Failure(val code: String) : Settlement
    }

    @Volatile
    private var session: Session? = null
    private val settledCount = AtomicInteger(0)
    private val failedCount = AtomicInteger(0)
    private val refusedCount = AtomicInteger(0)

    val boundNativeEpoch: Long get() = session?.epoch ?: 0L

    fun isRunning(): Boolean =
        session?.reader?.isActive == true && session?.stopping?.get() == false

    @OptIn(ExperimentalCoroutinesApi::class)
    suspend fun start(epoch: Long): Boolean = starts.withLock {
        if (!scope.isActive || epoch <= 0 || currentNativeEpoch() != epoch) return@withLock false
        session?.let { existing ->
            return@withLock existing.epoch == epoch &&
                existing.reader?.isActive == true && !existing.stopping.get()
        }
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
                while (isActive && !value.stopping.get() && currentNativeEpoch() == epoch) {
                    val claim = try {
                        transport.next(timing.nextPollMillis)
                    } catch (_: LinkageError) {
                        value.stopping.set(true)
                        continue
                    }
                    if (claim <= 0) continue
                    withContext(NonCancellable + ioDispatcher) {
                        settleOne(value, claim)
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

    suspend fun stopAndJoin(expectedEpoch: Long, waitMillis: Long): Boolean = starts.withLock {
        require(waitMillis > 0)
        val value = session ?: return@withLock true
        if (value.epoch != expectedEpoch) return@withLock false
        value.stopping.set(true)
        val joined = kotlinx.coroutines.withTimeoutOrNull(waitMillis) {
            value.reader?.join()
            true
        } ?: (value.reader?.isCompleted == true)
        if (!joined) return@withLock false
        if (session === value) session = null
        true
    }

    fun statsJson(): String? = runCatching { transport.stats()?.toString(Charsets.UTF_8) }.getOrNull()

    fun readinessJson(): String? = runCatching {
        transport.readiness()?.toString(Charsets.UTF_8)
    }.getOrNull() ?: """{"version":1,"tool":"networkArtifact","bound":${isRunning()}}"""

    private fun settleOne(value: Session, claim: Long) {
        var settlement: Settlement = Settlement.Failure("internal")
        try {
            if (value.stopping.get() || currentNativeEpoch() != value.epoch) {
                settlement = Settlement.Failure("laneFenced")
                return
            }
            val descriptorBytes = transport.describe(claim)
            if (descriptorBytes == null) {
                settlement = Settlement.Failure("descriptorInvalid")
                refusedCount.incrementAndGet()
                return
            }
            val ticket = try {
                NetworkArtifactWire.parseDescriptor(descriptorBytes, value.epoch)
            } catch (refusal: NetworkArtifactWire.Refusal) {
                settlement = Settlement.Failure(refusal.code)
                refusedCount.incrementAndGet()
                return
            }
            val payload = transport.payload(claim)
            if (payload == null) {
                settlement = Settlement.Failure("requestInvalid")
                refusedCount.incrementAndGet()
                return
            }
            val request = try {
                NetworkArtifactWire.validateRequest(payload, ticket)
            } catch (refusal: NetworkArtifactWire.Refusal) {
                settlement = Settlement.Failure(refusal.code)
                refusedCount.incrementAndGet()
                return
            }
            if (transport.isLive(claim) != 1 || transport.shouldStop(claim) == 1) {
                settlement = Settlement.Failure("cancelled")
                return
            }
            settlement = when (request) {
                is NetworkArtifactWire.Request.Pcap -> readPcap(request, ticket)
                is NetworkArtifactWire.Request.Coverage -> readCoverage(request, ticket)
            }
        } catch (_: Throwable) {
            settlement = Settlement.Failure("internal")
        } finally {
            if (transport.shouldStop(claim) == 1 && settlement is Settlement.Success) {
                settlement = Settlement.Failure("cancelled")
            }
            val (status, bytes) = when (val result = settlement) {
                is Settlement.Success -> {
                    settledCount.incrementAndGet()
                    0 to result.body
                }
                is Settlement.Failure -> {
                    failedCount.incrementAndGet()
                    1 to NetworkArtifactWire.failure(result.code)
                }
            }
            runCatching { transport.complete(claim, status, bytes) }
        }
    }

    private fun readPcap(
        request: NetworkArtifactWire.Request.Pcap,
        ticket: NetworkArtifactWire.Ticket,
    ): Settlement {
        val stored = runCatching { pcapStore.read(request.analysisID) }.getOrNull()
            ?: return Settlement.Success(
                PcapReportRenderer.unavailableReply(request.analysisID, "analysisNotFound")
                    .toByteArray(Charsets.UTF_8),
            )
        if (!stored.agentReadable) return Settlement.Failure("notAuthorized")
        val principal = NetworkArtifactPrincipal(
            artifactID = stored.analysisID,
            ownerTaskId = stored.ownerTaskId,
            ownerWorkspaceId = stored.ownerWorkspaceId,
            agentReadable = stored.agentReadable,
        )
        if (!access.canRead(principal, ticket.caller())) {
            return Settlement.Failure("notAuthorized")
        }
        val filters = request.filters.toCore()
        val summary = runCatching {
            com.floe.android.core.pcap.PcapSummaryCodec.decode(stored.json)
        }.getOrNull() ?: return Settlement.Failure("analysisInvalid")
        val view = PcapSummaryView.of(summary, filters)
        val reply = PcapReportRenderer.renderToolSummary(view).toByteArray(Charsets.UTF_8)
        if (reply.size > NetworkArtifactWire.MAX_REPLY_BYTES) {
            return Settlement.Failure("resultTooLarge")
        }
        return Settlement.Success(reply)
    }

    private fun readCoverage(
        request: NetworkArtifactWire.Request.Coverage,
        ticket: NetworkArtifactWire.Ticket,
    ): Settlement {
        val session = runCatching { coverageStore.load(request.sessionID) }.getOrNull()
            ?: return Settlement.Success(
                CoverageReportRenderer.unavailableReply(request.sessionID, "sessionNotFound")
                    .toByteArray(Charsets.UTF_8),
            )
        if (!session.agentReadable) return Settlement.Failure("notAuthorized")
        val principal = NetworkArtifactPrincipal(
            artifactID = session.sessionID,
            ownerTaskId = session.ownerTaskId,
            ownerWorkspaceId = session.ownerWorkspaceId,
            agentReadable = session.agentReadable,
        )
        if (!access.canRead(principal, ticket.caller())) {
            return Settlement.Failure("notAuthorized")
        }
        val reply = CoverageReportRenderer.renderToolSummary(
            session, System.currentTimeMillis(),
        ).toByteArray(Charsets.UTF_8)
        if (reply.size > NetworkArtifactWire.MAX_REPLY_BYTES) {
            return Settlement.Failure("resultTooLarge")
        }
        return Settlement.Success(reply)
    }

    private fun NetworkArtifactWire.Ticket.caller(): NetworkArtifactCaller = NetworkArtifactCaller(
        taskID = taskID.toString(),
        runID = runID.toString(),
        epoch = epoch,
        workspaceFingerprint = workspaceFingerprint,
    )

    private fun NetworkArtifactWire.ArtifactFilter.toCore(): PcapFilters = PcapFilters(
        protocols = protocols.mapNotNull(PcapProtocol::fromWire).toSet(),
        services = services.mapNotNull {
            when (it) {
                "dns" -> PcapServiceFilter.DNS
                "http" -> PcapServiceFilter.HTTP
                else -> null
            }
        }.toSet(),
        address = address,
        port = port,
        startEpochMillis = startEpochMillis,
        endEpochMillis = endEpochMillis,
    )
}
