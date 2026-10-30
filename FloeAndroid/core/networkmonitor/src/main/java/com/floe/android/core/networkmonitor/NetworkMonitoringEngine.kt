// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.networkmonitor

import java.util.UUID
import java.util.concurrent.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

fun interface NetworkMonitorClock {
    fun nowNanos(): Long
}

sealed interface NetworkMonitorStartResult {
    data class Started(val sessionId: String) : NetworkMonitorStartResult
    data class AlreadyActive(val sessionId: String) : NetworkMonitorStartResult
    data object Closed : NetworkMonitorStartResult
}

/**
 * One bounded, sequential monitoring session. Construction and StateFlow collection do no work.
 * The Android Service owns the supplied scope; a view never owns the probe Job.
 */
class NetworkMonitoringEngine(
    private val executor: NetworkMonitorExecutor,
    private val scope: CoroutineScope,
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val clock: NetworkMonitorClock = NetworkMonitorClock { System.nanoTime() },
    private val wallClock: () -> Long = System::currentTimeMillis,
    private val idFactory: () -> String = { UUID.randomUUID().toString() },
) {
    private val lock = Any()
    private val mutableState = MutableStateFlow(NetworkMonitorSessionState())
    val state: StateFlow<NetworkMonitorSessionState> = mutableState

    private var generation = 0L
    private var active: MutableSession? = null
    private var lastSnapshot: NetworkMonitorSessionSnapshot? = null
    private var closed = false

    fun start(
        config: NetworkMonitorConfig,
        owner: NetworkMonitorOwner,
        sessionId: String = newMonitorId(idFactory),
    ): NetworkMonitorStartResult {
        require(runCatching { UUID.fromString(sessionId) }.isSuccess) { "sessionId must be a UUID" }
        synchronized(lock) {
            active?.let { return NetworkMonitorStartResult.AlreadyActive(it.sessionId) }
            if (closed) return NetworkMonitorStartResult.Closed
            val now = clock.nowNanos()
            val session = MutableSession(
                sessionId = sessionId,
                generation = ++generation,
                config = config,
                owner = owner,
                startedAtEpochMillis = wallClock(),
                startedAtElapsedNanos = now,
                deadlineAtElapsedNanos = saturatingAdd(now, config.durationMillis * NANOS_PER_MILLI),
            )
            active = session
            mutableState.value = session.state(NetworkMonitorPhase.RUNNING)
            val job = scope.launch(dispatcher) { runSession(session) }
            session.job = job
            job.invokeOnCompletion { cause -> complete(session, cause) }
            return NetworkMonitorStartResult.Started(sessionId)
        }
    }

    /** Non-blocking and idempotent. Exact-operation cancellation precedes Job cancellation. */
    fun requestStop(
        sessionId: String,
        reason: NetworkMonitorEndReason = NetworkMonitorEndReason.USER_STOP,
    ): Boolean {
        val operationID: String?
        val job: Job
        synchronized(lock) {
            val session = active?.takeIf { it.sessionId == sessionId } ?: return false
            if (session.stopReason == null) session.stopReason = reason
            mutableState.value = session.state(NetworkMonitorPhase.STOPPING, session.stopReason)
            operationID = session.activeOperationID?.takeIf { it != session.cancelledOperationID }
            if (operationID != null) session.cancelledOperationID = operationID
            job = session.job ?: return true
        }
        if (operationID != null) runCatching { executor.cancel(operationID) }
        job.cancel()
        return true
    }

    suspend fun stopAndJoin(
        sessionId: String,
        timeoutMillis: Long = 5_000,
        reason: NetworkMonitorEndReason = NetworkMonitorEndReason.USER_STOP,
    ): Boolean {
        require(timeoutMillis > 0) { "timeoutMillis must be positive" }
        val job = synchronized(lock) {
            val session = active?.takeIf { it.sessionId == sessionId }
            if (session == null) {
                return lastSnapshot?.takeIf { it.sessionId == sessionId } != null
            }
            session.job
        }
        requestStop(sessionId, reason)
        if (job == null) return true
        return withTimeoutOrNull(timeoutMillis) { job.join() } != null
    }

    /** Only the live or most recently completed session remains available for an explicit report. */
    fun snapshot(sessionId: String): NetworkMonitorSessionSnapshot? = synchronized(lock) {
        active?.takeIf { it.sessionId == sessionId }?.snapshot(
            endedAtEpochMillis = null,
            endedAtElapsedNanos = null,
            failed = false,
        ) ?: lastSnapshot?.takeIf { it.sessionId == sessionId }
    }

    /** No restart is possible after close; already returned results remain generation-fenced. */
    fun close() {
        val sessionId = synchronized(lock) {
            if (closed) return
            closed = true
            generation++
            active?.sessionId
        }
        if (sessionId != null) requestStop(sessionId, NetworkMonitorEndReason.SERVICE_DESTROYED)
    }

    private suspend fun runSession(session: MutableSession) {
        try {
            var ending: NetworkMonitorEndReason? = null
            while (ending == null) {
                val cycleNow = clock.nowNanos()
                if (cycleNow >= session.deadlineAtElapsedNanos) {
                    ending = NetworkMonitorEndReason.DURATION_REACHED
                    break
                }
                for (probe in session.config.probes) {
                    if (!currentCoroutineContext().isActive) return
                    val beforeProbe = clock.nowNanos()
                    if (beforeProbe >= session.deadlineAtElapsedNanos) {
                        ending = NetworkMonitorEndReason.DURATION_REACHED
                        break
                    }
                    val operationID = newMonitorId(idFactory)
                    synchronized(lock) {
                        if (active !== session || session.generation != generation) return
                        session.returnedOperationID = null
                        session.activeOperationID = operationID
                    }
                    val startedAt = clock.nowNanos()
                    var failureCode: String? = null
                    val raw = try {
                        executor.execute(probe.requestJson(operationID))
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (_: Exception) {
                        failureCode = "operationFailed"
                        ""
                    }
                    val finishedAt = clock.nowNanos()
                    synchronized(lock) {
                        if (session.activeOperationID == operationID) {
                            session.activeOperationID = null
                            session.returnedOperationID = operationID
                        }
                    }
                    if (!owns(session, operationID)) return
                    val sequence = synchronized(lock) { session.buffer.totalObservationCount + 1 }
                    var observation = if (failureCode != null) {
                        NetworkMonitorObservationParser.failure(
                            sequence = sequence,
                            operationID = operationID,
                            method = probe.kind.wireMethod,
                            measuredAt = java.time.Instant.ofEpochMilli(wallClock()).toString(),
                            code = failureCode!!,
                            startedAtElapsedNanos = startedAt,
                            finishedAtElapsedNanos = finishedAt,
                        )
                    } else {
                        NetworkMonitorObservationParser.parse(
                            raw = raw,
                            sequence = sequence,
                            expectedOperationID = operationID,
                            expectedMethod = probe.kind.wireMethod,
                            fallbackMeasuredAtEpochMillis = wallClock(),
                            startedAtElapsedNanos = startedAt,
                            finishedAtElapsedNanos = finishedAt,
                        )
                    }
                    val networkEnd = networkFence(session, observation)
                    if (networkEnd != null) {
                        ending = networkEnd
                        break
                    }
                    if (observation.rawBytes > NetworkMonitorLimits.MAX_RAW_RESULT_BYTES) {
                        observation = NetworkMonitorObservationParser.failure(
                            sequence, operationID, probe.kind.wireMethod, observation.measuredAt,
                            "resultTooLarge", startedAt, finishedAt,
                        )
                        ending = NetworkMonitorEndReason.DATA_CAP_REACHED
                    }
                    val admitted = synchronized(lock) {
                        if (active !== session || session.generation != generation || session.stopReason != null) {
                            false
                        } else {
                            val accepted = session.buffer.add(observation)
                            if (accepted) mutableState.value = session.state(NetworkMonitorPhase.RUNNING)
                            accepted
                        }
                    }
                    if (!admitted) {
                        if (ending == null) ending = NetworkMonitorEndReason.DATA_CAP_REACHED
                        val capObservation = NetworkMonitorObservationParser.failure(
                            sequence = sequence,
                            operationID = operationID,
                            method = probe.kind.wireMethod,
                            measuredAt = observation.measuredAt,
                            code = "dataCapReached",
                            startedAtElapsedNanos = startedAt,
                            finishedAtElapsedNanos = finishedAt,
                        )
                        synchronized(lock) {
                            if (active === session && session.stopReason == null) {
                                session.buffer.add(capObservation)
                                mutableState.value = session.state(NetworkMonitorPhase.RUNNING)
                            }
                        }
                        break
                    }
                    if (ending != null) break
                }
                if (ending != null) break
                val remainingNanos = session.deadlineAtElapsedNanos - clock.nowNanos()
                if (remainingNanos <= 0L) {
                    ending = NetworkMonitorEndReason.DURATION_REACHED
                    break
                }
                delay(minOf(session.config.intervalMillis * NANOS_PER_MILLI, remainingNanos) / NANOS_PER_MILLI)
            }
            synchronized(lock) {
                if (session.stopReason == null) session.stopReason = ending
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            synchronized(lock) {
                session.failed = true
                if (session.stopReason == null) session.stopReason = NetworkMonitorEndReason.EXECUTOR_FAILURE
            }
        }
    }

    /** A session never silently changes its captured Android Network, including to metered/cellular. */
    private fun networkFence(
        session: MutableSession,
        observation: NetworkMonitorObservation,
    ): NetworkMonitorEndReason? {
        val key = observation.capturedNetworkKey
        if (key == "unknown") {
            return if (observation.actualNetwork.booleans["available"] == true) {
                NetworkMonitorEndReason.NETWORK_IDENTITY_UNAVAILABLE
            } else {
                null
            }
        }
        synchronized(lock) {
            val expected = session.capturedNetworkKey
            if (expected == null) {
                session.capturedNetworkKey = key
                return null
            }
            return if (expected == key) null else NetworkMonitorEndReason.NETWORK_CHANGED
        }
    }

    private fun owns(session: MutableSession, operationID: String): Boolean = synchronized(lock) {
        active === session && session.generation == generation &&
            session.activeOperationID == null && session.returnedOperationID == operationID &&
            session.stopReason == null
    }

    private fun complete(session: MutableSession, cause: Throwable?) {
        synchronized(lock) {
            if (active !== session || session.terminal) return
            session.terminal = true
            if (cause != null && cause !is CancellationException) {
                session.failed = true
                if (session.stopReason == null) session.stopReason = NetworkMonitorEndReason.EXECUTOR_FAILURE
            }
            if (session.stopReason == null) session.stopReason = NetworkMonitorEndReason.SERVICE_DESTROYED
            val endedAt = clock.nowNanos()
            lastSnapshot = session.snapshot(wallClock(), endedAt, session.failed)
            active = null
            mutableState.value = session.state(
                if (session.failed) NetworkMonitorPhase.FAILED else NetworkMonitorPhase.COMPLETED,
                session.stopReason,
                endedAt,
            )
        }
    }

    private class MutableSession(
        val sessionId: String,
        val generation: Long,
        val config: NetworkMonitorConfig,
        val owner: NetworkMonitorOwner,
        val startedAtEpochMillis: Long,
        val startedAtElapsedNanos: Long,
        val deadlineAtElapsedNanos: Long,
    ) {
        val buffer = NetworkMonitorObservationBuffer()
        var job: Job? = null
        var activeOperationID: String? = null
        var returnedOperationID: String? = null
        var cancelledOperationID: String? = null
        var stopReason: NetworkMonitorEndReason? = null
        var capturedNetworkKey: String? = null
        var terminal = false
        var failed = false

        fun snapshot(
            endedAtEpochMillis: Long?,
            endedAtElapsedNanos: Long?,
            failed: Boolean,
        ): NetworkMonitorSessionSnapshot = NetworkMonitorSessionSnapshot(
            sessionId = sessionId,
            config = config,
            owner = owner,
            startedAtEpochMillis = startedAtEpochMillis,
            startedAtElapsedNanos = startedAtElapsedNanos,
            endedAtEpochMillis = endedAtEpochMillis,
            endedAtElapsedNanos = endedAtElapsedNanos,
            deadlineAtElapsedNanos = deadlineAtElapsedNanos,
            observations = buffer.observations(),
            totalObservationCount = buffer.totalObservationCount,
            droppedObservationCount = buffer.droppedObservationCount,
            consumedRawBytes = buffer.consumedRawBytes,
            retainedRawBytes = buffer.retainedRawBytes,
            endReason = stopReason,
            failed = failed,
        )

        fun state(
            phase: NetworkMonitorPhase,
            reason: NetworkMonitorEndReason? = stopReason,
            endedAtElapsedNanos: Long? = null,
        ): NetworkMonitorSessionState {
            val snapshot = snapshot(
                endedAtEpochMillis = null,
                endedAtElapsedNanos = endedAtElapsedNanos,
                failed = failed,
            )
            return NetworkMonitorSessionState(
                phase = phase,
                sessionId = sessionId,
                owner = owner,
                startedAtEpochMillis = startedAtEpochMillis,
                startedAtElapsedNanos = startedAtElapsedNanos,
                deadlineAtElapsedNanos = deadlineAtElapsedNanos,
                observationCount = snapshot.totalObservationCount,
                droppedObservationCount = snapshot.droppedObservationCount,
                consumedRawBytes = snapshot.consumedRawBytes,
                retainedRawBytes = snapshot.retainedRawBytes,
                lastObservation = snapshot.observations.lastOrNull(),
                endReason = reason,
            )
        }
    }

    private companion object {
        const val NANOS_PER_MILLI = 1_000_000L

        fun saturatingAdd(left: Long, right: Long): Long {
            val result = left + right
            return if (right > 0 && result < left) Long.MAX_VALUE else result
        }

    }
}

internal class NetworkMonitorObservationBuffer(
    private val maxObservations: Int = NetworkMonitorLimits.MAX_OBSERVATIONS,
    private val maxRawBytes: Long = NetworkMonitorLimits.MAX_SESSION_RAW_BYTES.toLong(),
) {
    private val ring = ArrayDeque<NetworkMonitorObservation>()
    var totalObservationCount = 0L
        private set
    var droppedObservationCount = 0L
        private set
    var consumedRawBytes = 0L
        private set
    var retainedRawBytes = 0L
        private set

    fun add(observation: NetworkMonitorObservation): Boolean {
        if (consumedRawBytes + observation.rawBytes > maxRawBytes) return false
        ring.addLast(observation)
        totalObservationCount++
        consumedRawBytes += observation.rawBytes
        retainedRawBytes += observation.rawBytes
        while (ring.size > maxObservations) {
            val removed = ring.removeFirst()
            retainedRawBytes -= removed.rawBytes
            droppedObservationCount++
        }
        return true
    }

    fun observations(): List<NetworkMonitorObservation> = ring.toList()
}
