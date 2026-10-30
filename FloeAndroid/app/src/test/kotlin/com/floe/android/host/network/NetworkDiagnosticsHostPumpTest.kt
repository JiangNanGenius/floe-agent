// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.network

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class NetworkDiagnosticsHostPumpTest {
    private val operation = "00000000-0000-4000-8000-000000000001"
    private val task = "00000000-0000-4000-8000-000000000002"
    private val run = "00000000-0000-4000-8000-000000000003"

    private inner class Transport(val method: String = "network.status") : NetworkDiagnosticsNativeTransport {
        val nextClaim = AtomicBoolean(true)
        val stop = AtomicBoolean(false)
        val completions = AtomicInteger()
        val closes = AtomicInteger()
        val done = CompletableDeferred<JSONObject>()
        var onDescribe: () -> Unit = {}
        val request: ByteArray get() = JSONObject().put("version", 1).put("operationID", operation)
            .put("method", method).put("arguments", JSONObject()).toString().toByteArray()
        override fun bindEpoch(epoch: Long) = if (epoch == 7L) 0 else -102
        override fun next(timeoutMillis: Int): Long {
            if (nextClaim.compareAndSet(true, false)) return 1L
            Thread.sleep(5)
            return 0L
        }
        override fun describe(claim: Long): ByteArray {
            onDescribe()
            return JSONObject().put("operation", "network.execute").put("epoch", "7")
                .put("method", method).put("operationID", operation).put("taskID", task).put("runID", run)
                .put("payloadBytes", request.size).put("budgetMs", 45000).toString().toByteArray()
        }
        override fun payload(claim: Long) = request
        override fun isLive(claim: Long) = 1
        override fun shouldStop(claim: Long) = if (stop.get()) 1 else 0
        override fun complete(claim: Long, status: Int, value: ByteArray): Int {
            completions.incrementAndGet()
            done.complete(JSONObject(String(value, Charsets.UTF_8)))
            return 0
        }
        override fun close(epoch: Long): Int { closes.incrementAndGet(); return 0 }
        override fun stats(): ByteArray? = null
        override fun readiness(): ByteArray? = null
        fun observation(status: String = "ok"): String = JSONObject()
            .put("version", 1).put("operationID", operation).put("method", method).put("source", "phone")
            .put("measuredAt", "2026-10-30T00:00:00Z").put("status", status)
            .put("network", JSONObject().put("available", true)).put("observations", JSONObject())
            .apply { if (status == "permissionRequired") put("missingPermissions", org.json.JSONArray().put("android.permission.ACCESS_FINE_LOCATION")) }
            .toString()
    }

    private fun pump(scope: CoroutineScope, epoch: AtomicLong, transport: Transport, service: PhoneNetworkServicePort,
                     permission: (NetworkPermissionRequest) -> Unit = {}): NetworkDiagnosticsHostPump =
        NetworkDiagnosticsHostPump(scope, Dispatchers.IO, { epoch.get() }, { service }, transport, permission,
            NetworkDiagnosticsTiming(nextPollMillis = 5, maximumExecutionMillis = 1000, cancelPollMillis = 5))

    @Test fun successSettlesOnceAndDrainsBeforeClose() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val transport = Transport()
        val calls = AtomicInteger()
        val lane = pump(scope, AtomicLong(7), transport, object : PhoneNetworkServicePort {
            override suspend fun execute(requestJson: String): String { calls.incrementAndGet(); return transport.observation() }
            override fun cancel(operationID: String) { fail("Successful request was unexpectedly cancelled") }
        })
        try {
            assertTrue(lane.start(7))
            assertEquals("ok", withTimeout(2000) { transport.done.await() }.getString("status"))
            assertTrue(lane.stopAndJoin(7, 1000))
            assertEquals(1, calls.get())
            assertEquals(1, transport.completions.get())
            assertEquals(1, transport.closes.get())
        } finally { scope.cancel() }
    }

    @Test fun epochReplacementAfterDescriptorPreventsDispatch() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val epoch = AtomicLong(7)
        val transport = Transport().apply { onDescribe = { epoch.set(8) } }
        val calls = AtomicInteger()
        val lane = pump(scope, epoch, transport, object : PhoneNetworkServicePort {
            override suspend fun execute(requestJson: String): String { calls.incrementAndGet(); return transport.observation() }
            override fun cancel(operationID: String) = Unit
        })
        try {
            assertTrue(lane.start(7))
            assertEquals("laneFenced", withTimeout(2000) { transport.done.await() }.getString("code"))
            assertTrue(lane.stopAndJoin(7, 1000))
            assertEquals(0, calls.get())
            assertEquals(1, transport.completions.get())
        } finally { scope.cancel() }
    }

    @Test fun stopSignalCancelsOnlyClaimedOperationAndSettlesOnce() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val transport = Transport()
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val cancels = AtomicInteger()
        val lane = pump(scope, AtomicLong(7), transport, object : PhoneNetworkServicePort {
            override suspend fun execute(requestJson: String): String {
                entered.complete(Unit); release.await(); return transport.observation("cancelled")
            }
            override fun cancel(operationID: String) {
                assertEquals(operation, operationID); cancels.incrementAndGet(); release.complete(Unit)
            }
        })
        try {
            assertTrue(lane.start(7))
            withTimeout(2000) { entered.await() }
            transport.stop.set(true)
            assertEquals("sessionEnding", withTimeout(2000) { transport.done.await() }.getString("code"))
            assertTrue(lane.stopAndJoin(7, 1000))
            assertEquals(1, cancels.get())
            assertEquals(1, transport.completions.get())
        } finally { release.complete(Unit); scope.cancel() }
    }

    @Test fun permissionRefusalForwardsGuidanceWithoutReplayingService() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val transport = Transport("network.wifiScan")
        val calls = AtomicInteger()
        val notice = CompletableDeferred<NetworkPermissionRequest>()
        val lane = pump(scope, AtomicLong(7), transport, object : PhoneNetworkServicePort {
            override suspend fun execute(requestJson: String): String { calls.incrementAndGet(); return transport.observation("permissionRequired") }
            override fun cancel(operationID: String) = Unit
        }, permission = { notice.complete(it) })
        try {
            assertTrue(lane.start(7))
            assertEquals("permissionRequired", withTimeout(2000) { transport.done.await() }.getString("status"))
            assertEquals(operation, withTimeout(2000) { notice.await() }.operationID)
            assertTrue(lane.stopAndJoin(7, 1000))
            assertEquals(1, calls.get())
            assertEquals(1, transport.completions.get())
        } finally { scope.cancel() }
    }
}
