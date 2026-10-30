// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import java.time.Instant
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PhoneNetworkServiceTest {
    private val operationID = "123e4567-e89b-12d3-a456-426614174000"

    @Test
    fun constructorDoesNotProbeAndStatusReturnsFrozenEnvelope() = runBlocking {
        val session = FakeSession(
            handler = {
                ProbeResult(observations = JSONObject().put("activeNetwork", true))
            },
        )
        val platform = FakePlatform(session)
        val service = PhoneNetworkService(
            platform = platform,
            clock = { Instant.parse("2026-10-30T01:02:03Z") },
            dispatcher = Dispatchers.Default,
        )
        assertEquals(0, platform.opens)

        val text = service.execute(request("network.status"))
        val json = JSONObject(text)
        assertEquals(1, json.getInt("version"))
        assertEquals("network.status", json.getString("method"))
        assertEquals("phone", json.getString("source"))
        assertEquals("ok", json.getString("status"))
        assertEquals("2026-10-30T01:02:03Z", json.getString("measuredAt"))
        assertTrue(json.getJSONObject("observations").getBoolean("activeNetwork"))
        assertEquals(1, platform.opens)
        assertTrue(session.closed.get())
        service.close()
    }

    @Test
    fun missingPermissionsStopBeforeMeasurement() = runBlocking {
        val session = FakeSession(
            missingPermissions = listOf("android.permission.ACCESS_FINE_LOCATION"),
            handler = { error("must not run") },
        )
        val service = PhoneNetworkService(
            platform = FakePlatform(session),
            dispatcher = Dispatchers.Default,
        )
        val json = JSONObject(service.execute(request("network.wifiScan")))
        assertEquals("permissionRequired", json.getString("status"))
        assertEquals(1, json.getJSONArray("missingPermissions").length())
        assertEquals(0, session.calls.size)
        service.close()
    }

    @Test
    fun cancelClosesSessionAndReturnsCancelled() = runBlocking {
        val gate = CompletableDeferred<ProbeResult>()
        val session = FakeSession(handler = { gate.await() })
        val service = PhoneNetworkService(
            platform = FakePlatform(session),
            dispatcher = Dispatchers.Default,
        )
        val execution = async(Dispatchers.Default) { service.execute(dnsRequest()) }
        session.entered.await()
        service.cancel(operationID)
        val json = JSONObject(execution.await())
        assertEquals("cancelled", json.getString("status"))
        assertTrue(session.closed.get())
        service.close()
    }

    @Test
    fun boundedTimeoutReturnsTimeoutAndClosesSession() = runBlocking {
        val session = FakeSession(
            handler = {
                delay(5_000)
                ProbeResult()
            },
        )
        val service = PhoneNetworkService(
            platform = FakePlatform(session),
            dispatcher = Dispatchers.Default,
        )
        val json = JSONObject(service.execute(dnsRequest(timeoutMs = 500)))
        assertEquals("timeout", json.getString("status"))
        assertEquals(500, json.getJSONObject("observations").getInt("timeoutMs"))
        assertTrue(session.closed.get())
        service.close()
    }

    @Test
    fun duplicateOperationIdIsRejectedWithoutStartingAnotherSession() = runBlocking {
        val gate = CompletableDeferred<ProbeResult>()
        val session = FakeSession(handler = { gate.await() })
        val platform = FakePlatform(session)
        val service = PhoneNetworkService(platform = platform, dispatcher = Dispatchers.Default)
        val first = async(Dispatchers.Default) { service.execute(dnsRequest()) }
        session.entered.await()
        val second = JSONObject(service.execute(dnsRequest()))
        assertEquals("error", second.getString("status"))
        assertEquals("operationInFlight", second.getJSONObject("observations").getString("errorCode"))
        assertEquals(1, platform.opens)
        service.cancel(operationID)
        first.await()
        service.close()
    }

    @Test
    fun closeCancelsInFlightRunAndClosesOwnedSession() = runBlocking {
        val gate = CompletableDeferred<ProbeResult>()
        val session = FakeSession(handler = { gate.await() })
        val service = PhoneNetworkService(
            platform = FakePlatform(session),
            dispatcher = Dispatchers.Default,
        )
        val execution = async(Dispatchers.Default) { service.execute(dnsRequest()) }
        session.entered.await()
        service.close()
        val json = JSONObject(execution.await())
        assertEquals("cancelled", json.getString("status"))
        assertTrue(session.closed.get())
    }

    @Test
    fun watchdogClosesBlockingSessionBeforeTimeoutResult() = runBlocking {
        val started = CompletableDeferred<Unit>()
        val closed = AtomicBoolean(false)
        val handlerExited = AtomicBoolean(false)
        val session = FakeSession(
            onClose = { closed.set(true) },
            handler = {
                started.complete(Unit)
                while (!closed.get()) {
                    try {
                        Thread.sleep(5L)
                    } catch (_: InterruptedException) {
                        break
                    }
                }
                handlerExited.set(true)
                throw java.io.IOException("socket closed by watchdog")
            },
        )
        val service = PhoneNetworkService(
            platform = FakePlatform(session),
            dispatcher = Dispatchers.Default,
        )
        val execution = async(Dispatchers.Default) { service.execute(dnsRequest(timeoutMs = 500)) }
        started.await()
        val json = JSONObject(execution.await())
        assertEquals("timeout", json.getString("status"))
        assertTrue(closed.get())
        assertTrue(handlerExited.get())
        service.close()
    }

    @Test
    fun cancellationClosesBlockingSessionBeforeCancelledResult() = runBlocking {
        val started = CompletableDeferred<Unit>()
        val closed = AtomicBoolean(false)
        val handlerExited = AtomicBoolean(false)
        val session = FakeSession(
            onClose = { closed.set(true) },
            handler = {
                started.complete(Unit)
                while (!closed.get()) {
                    try {
                        Thread.sleep(5L)
                    } catch (_: InterruptedException) {
                        break
                    }
                }
                handlerExited.set(true)
                throw java.io.IOException("socket closed by cancellation")
            },
        )
        val service = PhoneNetworkService(
            platform = FakePlatform(session),
            dispatcher = Dispatchers.Default,
        )
        val execution = async(Dispatchers.Default) { service.execute(dnsRequest()) }
        started.await()
        service.cancel(operationID)
        val json = JSONObject(execution.await())
        assertEquals("cancelled", json.getString("status"))
        assertTrue(closed.get())
        assertTrue(handlerExited.get())
        service.close()
    }

    @Test
    fun directCallerCancellationClosesBlockingSessionImmediately() = runBlocking {
        val started = CompletableDeferred<Unit>()
        val closed = AtomicBoolean(false)
        val handlerExited = AtomicBoolean(false)
        val session = FakeSession(
            onClose = { closed.set(true) },
            handler = {
                started.complete(Unit)
                while (!closed.get()) {
                    try {
                        Thread.sleep(5L)
                    } catch (_: InterruptedException) {
                        break
                    }
                }
                handlerExited.set(true)
                throw java.io.IOException("socket closed by caller cancellation")
            },
        )
        val service = PhoneNetworkService(
            platform = FakePlatform(session),
            dispatcher = Dispatchers.Default,
        )
        val execution = async(Dispatchers.Default) { service.execute(dnsRequest()) }
        started.await()
        execution.cancel()
        try {
            execution.await()
            org.junit.Assert.fail("caller cancellation must propagate")
        } catch (_: java.util.concurrent.CancellationException) {
            // expected: the caller owns this cancellation
        }
        assertTrue(closed.get())
        assertTrue(handlerExited.get())
        service.close()
    }

    @Test
    fun invalidRequestReturnsPlainErrorEnvelope() = runBlocking {
        val session = FakeSession()
        val service = PhoneNetworkService(
            platform = FakePlatform(session),
            dispatcher = Dispatchers.Default,
        )
        val json = JSONObject(service.execute("{"))
        assertEquals("error", json.getString("status"))
        assertEquals("invalidRequest", json.getJSONObject("observations").getString("errorCode"))
        assertTrue(json.getJSONObject("network").has("available"))
        service.close()
    }

    private fun request(method: String, arguments: JSONObject = JSONObject()): String = JSONObject()
        .put("version", 1)
        .put("operationID", operationID)
        .put("method", method)
        .put("arguments", arguments)
        .toString()

    private fun dnsRequest(timeoutMs: Int = 5_000): String = request(
        "network.dnsLookup",
        JSONObject().put("host", "example.com").put("timeoutMs", timeoutMs),
    )

    private class FakePlatform(private val session: FakeSession) : NetworkPlatform {
        var opens = 0
        override fun openSession(request: ParsedRequest): NetworkSession {
            opens++
            return session
        }
    }

    private class FakeSession(
        override val snapshot: NetworkSnapshot = NetworkSnapshot(available = true),
        override val missingPermissions: List<String> = emptyList(),
        private val handler: suspend (String) -> ProbeResult = { ProbeResult() },
        private val onClose: () -> Unit = {},
    ) : NetworkSession {
        val entered = CompletableDeferred<Unit>()
        val closed = AtomicBoolean(false)
        val calls = CopyOnWriteArrayList<String>()

        override suspend fun status(): ProbeResult = dispatch("status")
        override suspend fun wifiScan(refresh: Boolean): ProbeResult = dispatch("wifiScan")
        override suspend fun dnsLookup(host: String, recordType: DnsRecordType, timeoutMs: Int): ProbeResult =
            dispatch("dnsLookup")
        override suspend fun ping(host: String, count: Int, timeoutMs: Int): ProbeResult = dispatch("ping")
        override suspend fun tcpProbe(host: String, port: Int, timeoutMs: Int): ProbeResult = dispatch("tcpProbe")
        override suspend fun http(target: HttpTarget, timeoutMs: Int, maxRedirects: Int): ProbeResult =
            dispatch("http")

        override fun close() {
            closed.set(true)
            onClose()
        }

        private suspend fun dispatch(method: String): ProbeResult {
            calls += method
            entered.complete(Unit)
            return handler(method)
        }
    }
}
