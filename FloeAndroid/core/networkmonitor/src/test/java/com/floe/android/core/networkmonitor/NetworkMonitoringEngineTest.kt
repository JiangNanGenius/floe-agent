// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.networkmonitor

import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NetworkMonitoringEngineTest {
    @Test
    fun constructionDoesNotProbeAndSessionIsSingleAndSequential() = runBlocking {
        val executor = RecordingExecutor { request ->
            delay(20)
            envelope(request, "100")
        }
        val engine = NetworkMonitoringEngine(executor, this, idFactory = sequentialIds())
        assertEquals(0, executor.calls.get())
        val started = engine.start(
            NetworkMonitorConfig(probes = listOf(NetworkMonitorProbe.status(), NetworkMonitorProbe.ping("example.com"))),
            NetworkMonitorOwner("root-1", "task-1"),
        ) as NetworkMonitorStartResult.Started
        assertFalse(engine.requestStop("not-the-active-session"))
        assertEquals(
            started.sessionId,
            (engine.start(NetworkMonitorConfig(), NetworkMonitorOwner("root-2")) as NetworkMonitorStartResult.AlreadyActive).sessionId,
        )
        withTimeout(2_000) { engine.state.first { it.observationCount == 2L } }
        assertTrue(engine.stopAndJoin(started.sessionId))
        assertEquals(2, executor.calls.get())
        assertEquals(1, executor.maximumConcurrent.get())
        assertEquals(2, engine.state.value.observationCount)
        assertEquals(2, engine.snapshot(started.sessionId)?.observations?.size)
        engine.close()
    }

    @Test
    fun stopCancelsExactOperationAndFencesLateResult() = runBlocking {
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val cancelled = AtomicInteger()
        lateinit var operationID: String
        var cancelledOperationID: String? = null
        val executor = object : NetworkMonitorExecutor {
            override suspend fun execute(requestJson: String): String {
                operationID = JSONObject(requestJson).getString("operationID")
                entered.complete(Unit)
                withContext(NonCancellable) { release.await() }
                return envelope(requestJson, "100")
            }

            override fun cancel(operationID: String) {
                cancelledOperationID = operationID
                cancelled.incrementAndGet()
                release.complete(Unit)
            }
        }
        val engine = NetworkMonitoringEngine(executor, this, idFactory = sequentialIds())
        val started = engine.start(NetworkMonitorConfig(), NetworkMonitorOwner("root-1")) as NetworkMonitorStartResult.Started
        withTimeout(2_000) { entered.await() }
        assertTrue(engine.requestStop(started.sessionId))
        assertTrue(engine.stopAndJoin(started.sessionId))
        assertEquals(operationID, cancelledOperationID)
        assertEquals(1, cancelled.get())
        assertEquals(0, engine.snapshot(started.sessionId)?.observations?.size)
        assertEquals(NetworkMonitorEndReason.USER_STOP, engine.snapshot(started.sessionId)?.endReason)
        engine.close()
    }

    @Test
    fun changedCapturedNetworkStopsInsteadOfSwitchingToAnotherNetwork() = runBlocking {
        val executor = RecordingExecutor { request -> envelope(request, if (calls.get() == 1) "100" else "200") }
        val engine = NetworkMonitoringEngine(executor, this, idFactory = sequentialIds())
        val started = engine.start(
            NetworkMonitorConfig(probes = listOf(NetworkMonitorProbe.status(), NetworkMonitorProbe.ping("example.com"))),
            NetworkMonitorOwner("root-1"),
        ) as NetworkMonitorStartResult.Started
        withTimeout(2_000) { engine.state.first { it.isTerminal } }
        val snapshot = engine.snapshot(started.sessionId)
        assertEquals(NetworkMonitorEndReason.NETWORK_CHANGED, snapshot?.endReason)
        assertEquals(1, snapshot?.observations?.size)
        assertEquals(2, executor.calls.get())
        engine.close()
    }

    @Test
    fun monotonicDeadlineEndsSessionWithoutWallClockExtension() = runBlocking {
        val nanos = AtomicLong(0)
        val executor = RecordingExecutor { request ->
            nanos.addAndGet(NetworkMonitorLimits.MIN_DURATION_MILLIS * 1_000_000L)
            envelope(request, "100")
        }
        val engine = NetworkMonitoringEngine(
            executor = executor,
            scope = this,
            clock = NetworkMonitorClock { nanos.get() },
            wallClock = { 1_793_344_000_000L },
            idFactory = sequentialIds(),
        )
        val started = engine.start(
            NetworkMonitorConfig(durationMillis = NetworkMonitorLimits.MIN_DURATION_MILLIS),
            NetworkMonitorOwner("root-1"),
        ) as NetworkMonitorStartResult.Started
        withTimeout(2_000) { engine.state.first { it.isTerminal } }
        assertEquals(NetworkMonitorEndReason.DURATION_REACHED, engine.snapshot(started.sessionId)?.endReason)
        assertEquals(1, executor.calls.get())
        engine.close()
    }

    @Test
    fun observationBufferEnforcesRingAndCumulativeByteCap() {
        val buffer = NetworkMonitorObservationBuffer(maxObservations = 2, maxRawBytes = 100)
        assertTrue(buffer.add(observation(1, 60)))
        assertTrue(buffer.add(observation(2, 30)))
        assertTrue(buffer.add(observation(3, 10)))
        assertEquals(3, buffer.totalObservationCount)
        assertEquals(1, buffer.droppedObservationCount)
        assertEquals(40, buffer.retainedRawBytes)
        assertEquals(listOf(2L, 3L), buffer.observations().map { it.sequence })
        assertEquals(false, buffer.add(observation(4, 1)))
        assertEquals(100, buffer.consumedRawBytes)
    }

    private class RecordingExecutor(
        private val handler: suspend RecordingExecutor.(String) -> String,
    ) : NetworkMonitorExecutor {
        val calls = AtomicInteger()
        private val concurrent = AtomicInteger()
        val maximumConcurrent = AtomicInteger()

        override suspend fun execute(requestJson: String): String {
            calls.incrementAndGet()
            val current = concurrent.incrementAndGet()
            maximumConcurrent.updateAndGet { previous -> maxOf(previous, current) }
            return try {
                handler(requestJson)
            } finally {
                concurrent.decrementAndGet()
            }
        }

        override fun cancel(operationID: String) = Unit
    }

    private companion object {
        fun sequentialIds(): () -> String {
            val count = AtomicInteger()
            return { UUID.nameUUIDFromBytes("monitor-${count.incrementAndGet()}".toByteArray()).toString() }
        }

        fun envelope(request: String, handle: String): String {
            val parsed = JSONObject(request)
            return JSONObject()
                .put("version", 1)
                .put("operationID", parsed.getString("operationID"))
                .put("method", parsed.getString("method"))
                .put("source", "phone")
                .put("status", "ok")
                .put("measuredAt", "2026-10-30T01:02:03Z")
                .put("network", JSONObject().put("available", true).put("handle", handle))
                .put("observations", JSONObject().put("latencyMs", 12))
                .toString()
        }

        fun observation(sequence: Long, rawBytes: Int): NetworkMonitorObservation = NetworkMonitorObservation(
            sequence = sequence,
            operationID = UUID.nameUUIDFromBytes("operation-$sequence".toByteArray()).toString(),
            method = "network.status",
            measuredAt = "2026-10-30T01:02:03Z",
            status = "ok",
            target = null,
            actualNetwork = NetworkMonitorFields(booleans = mapOf("available" to true)),
            transfers = NetworkMonitorFields(),
            details = NetworkMonitorFields(),
            limitations = emptyList(),
            missingPermissions = emptyList(),
            startedAtElapsedNanos = 0,
            finishedAtElapsedNanos = 1,
            rawBytes = rawBytes,
            capturedNetworkKey = "handle:100",
        )
    }
}
