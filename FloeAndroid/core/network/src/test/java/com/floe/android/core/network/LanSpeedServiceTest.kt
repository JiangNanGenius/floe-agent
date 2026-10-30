// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LanSpeedServiceTest {
    private val operationID = "123e4567-e89b-12d3-a456-426614174000"

    @Test
    fun lanDiscoverDispatchesThroughFrozenService() = runBlocking {
        val session = ScriptedSession(
            onLan = {
                ProbeResult(
                    observations = JSONObject().put(
                        "mdns",
                        JSONObject().put("noReplies", true).put("serviceCount", 0),
                    ),
                )
            },
        )
        val service = PhoneNetworkService(
            platform = FakePlatform(session),
            dispatcher = Dispatchers.Default,
        )
        val json = JSONObject(service.execute(lanRequest()))
        assertEquals("network.lanDiscover", json.getString("method"))
        assertEquals("ok", json.getString("status"))
        assertTrue(json.getJSONObject("observations").getJSONObject("mdns").getBoolean("noReplies"))
        assertTrue(session.closed.get())
        service.close()
    }

    @Test
    fun missingPermissionStopsBeforeSpeedMeasurement() = runBlocking {
        val session = ScriptedSession(
            missingPermissions = listOf("android.permission.INTERNET"),
            onSpeed = { error("speed measurement must not start") },
        )
        val service = PhoneNetworkService(
            platform = FakePlatform(session),
            dispatcher = Dispatchers.Default,
        )
        val json = JSONObject(service.execute(speedRequest()))
        assertEquals("permissionRequired", json.getString("status"))
        assertEquals(1, json.getJSONArray("missingPermissions").length())
        assertEquals(0, session.calls)
        service.close()
    }

    @Test
    fun cancelRetainsPublishedPartialSpeedBytes() = runBlocking {
        val gate = CompletableDeferred<ProbeResult>()
        val entered = CompletableDeferred<Unit>()
        val session = ScriptedSession(
            onSpeed = {
                sessionPartial(
                    JSONObject()
                        .put("budget", JSONObject().put("maxBytesPerDirection", 8_388_608))
                        .put(
                            "download",
                            JSONObject()
                                .put("payloadBytes", 1_234)
                                .put("measuredBytes", 1_234)
                                .put("completionReason", "inProgress"),
                        ),
                )
                entered.complete(Unit)
                gate.await()
            },
        )
        val service = PhoneNetworkService(
            platform = FakePlatform(session),
            dispatcher = Dispatchers.Default,
        )
        val execution = async(Dispatchers.Default) { service.execute(speedRequest()) }
        entered.await()
        service.cancel(operationID)
        val json = JSONObject(execution.await())
        assertEquals("cancelled", json.getString("status"))
        assertEquals(1_234L, json.getJSONObject("observations").getJSONObject("download").getLong("payloadBytes"))
        assertTrue(json.getJSONObject("observations").getBoolean("partial"))
        assertTrue(session.closed.get())
        service.close()
    }

    @Test
    fun timeoutRetainsPublishedPartialSpeedBytes() = runBlocking {
        val session = ScriptedSession(
            onSpeed = {
                sessionPartial(
                    JSONObject().put(
                        "download",
                        JSONObject()
                            .put("payloadBytes", 2_048)
                            .put("measuredBytes", 2_048)
                            .put("completionReason", "inProgress"),
                    ),
                )
                delay(10_000)
                ProbeResult()
            },
        )
        val service = PhoneNetworkService(
            platform = FakePlatform(session),
            dispatcher = Dispatchers.Default,
        )
        val json = JSONObject(
            service.execute(
                speedRequest(durationBudgetMs = 1_000, timeoutMs = 2_500),
            ),
        )
        assertEquals("timeout", json.getString("status"))
        assertEquals(2_048L, json.getJSONObject("observations").getJSONObject("download").getLong("payloadBytes"))
        assertTrue(json.getJSONObject("observations").getBoolean("partial"))
        assertEquals(2_500, json.getJSONObject("observations").getInt("timeoutMs"))
        service.close()
    }

    private fun sessionPartial(observations: JSONObject) {
        // ScriptedSession.partial is assigned by the handler below via this
        // helper's receiver; kept as a small explicit step so the test shows
        // that the service only reads a provider-published partial.
        currentSession!!.partial = ProbeResult(
            observations = observations,
            limitations = listOf("partial measurement retained"),
        )
    }

    private var currentSession: ScriptedSession? = null

    private fun lanRequest(): String = JSONObject()
        .put("version", 1)
        .put("operationID", operationID)
        .put("method", "network.lanDiscover")
        .put(
            "arguments",
            JSONObject()
                .put("serviceTypes", JSONArray().put("_http._tcp"))
                .put("timeoutMs", 5_000),
        )
        .toString()

    private fun speedRequest(
        durationBudgetMs: Int = 1_000,
        timeoutMs: Int = 2_500,
    ): String = JSONObject()
        .put("version", 1)
        .put("operationID", operationID)
        .put("method", "network.speedTest")
        .put(
            "arguments",
            JSONObject()
                .put("downloadUrl", "https://example.com/payload")
                .put("durationBudgetMs", durationBudgetMs)
                .put("timeoutMs", timeoutMs),
        )
        .toString()

    private class FakePlatform(private val session: ScriptedSession) : NetworkPlatform {
        override fun openSession(request: ParsedRequest): NetworkSession = session
    }

    private inner class ScriptedSession(
        override val snapshot: NetworkSnapshot = NetworkSnapshot(available = true, metered = false),
        override val missingPermissions: List<String> = emptyList(),
        private val onLan: suspend () -> ProbeResult = { ProbeResult() },
        private val onSpeed: suspend () -> ProbeResult = { ProbeResult() },
    ) : NetworkSession {
        val closed = AtomicBoolean(false)
        var calls = 0
        @Volatile var partial: ProbeResult? = null

        init {
            currentSession = this
        }

        override suspend fun status(): ProbeResult = ProbeResult()
        override suspend fun wifiScan(refresh: Boolean): ProbeResult = ProbeResult()
        override suspend fun dnsLookup(
            host: String,
            recordType: DnsRecordType,
            timeoutMs: Int,
        ): ProbeResult = ProbeResult()
        override suspend fun ping(host: String, count: Int, timeoutMs: Int): ProbeResult = ProbeResult()
        override suspend fun tcpProbe(host: String, port: Int, timeoutMs: Int): ProbeResult = ProbeResult()
        override suspend fun http(
            target: HttpTarget,
            timeoutMs: Int,
            maxRedirects: Int,
        ): ProbeResult = ProbeResult()

        override suspend fun lanDiscover(request: LanDiscoveryRequest): ProbeResult {
            calls++
            return onLan()
        }

        override suspend fun speedTest(request: SpeedTestRequest): ProbeResult {
            calls++
            return onSpeed()
        }

        override fun partialResult(): ProbeResult? = partial

        override fun close() {
            closed.set(true)
        }
    }
}
