// SPDX-License-Identifier: MPL-2.0
//
// G07.2 staged JVM regression source for the Kotlin host wire/pump.
//
// NOT applied by this lane: the owned write scope covers
// `app/src/main/kotlin/com/floe/android/host/network` only, so this file is
// staged for Main to place at the exact destination below before running the
// batch tests. It uses only JVM types + the existing JUnit4/org.json test
// dependencies; no Android runtime, socket, device, credential or build.
//
// Destination:
//   app/src/test/kotlin/com/floe/android/host/network/NetworkDiagnosticsWireG072Test.kt
package com.floe.android.host.network

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class NetworkDiagnosticsWireG072Test {
    private val operation = "00000000-0000-4000-8000-000000000011"
    private val task = "00000000-0000-4000-8000-000000000012"
    private val run = "00000000-0000-4000-8000-000000000013"

    private fun request(method: String, arguments: JSONObject): ByteArray =
        JSONObject()
            .put("version", 1)
            .put("operationID", operation)
            .put("method", method)
            .put("arguments", arguments)
            .toString()
            .toByteArray(Charsets.UTF_8)

    private fun descriptor(method: String, payload: ByteArray, epoch: Long = 7): ByteArray =
        JSONObject()
            .put("operation", "network.execute")
            .put("epoch", epoch.toString())
            .put("method", method)
            .put("operationID", operation)
            .put("taskID", task)
            .put("runID", run)
            .put("payloadBytes", payload.size)
            .put("budgetMs", 45_000)
            .toString()
            .toByteArray(Charsets.UTF_8)

    private fun facts(method: String, arguments: JSONObject): NetworkDiagnosticsWire.RequestFacts {
        val payload = request(method, arguments)
        val ticket = NetworkDiagnosticsWire.parseDescriptor(
            descriptor(method, payload), boundEpoch = 7,
        )
        return NetworkDiagnosticsWire.validateRequest(payload, ticket)
    }

    private inline fun refused(expected: String, block: () -> Unit) {
        try {
            block()
            fail("expected refusal $expected")
        } catch (refusal: NetworkDiagnosticsWire.Refusal) {
            assertEquals(expected, refusal.code)
        }
    }

    @Test
    fun closedMethodSetIncludesBothNewMethodsAndStillRefusesUnknown() {
        assertTrue("network.lanDiscover" in NetworkDiagnosticsWire.METHODS)
        assertTrue("network.speedTest" in NetworkDiagnosticsWire.METHODS)
        assertEquals(8, NetworkDiagnosticsWire.METHODS.size)
        val payload = request("network.lanDiscover", JSONObject()
            .put("serviceTypes", JSONArray().put("_http._tcp")))
        refused("descriptorInvalid") {
            NetworkDiagnosticsWire.parseDescriptor(
                descriptor("network.portScan", payload), boundEpoch = 7,
            )
        }
    }

    @Test
    fun subnetLANHintIsTheNetworkAddressOnly() {
        val arguments = JSONObject()
            .put("serviceTypes", JSONArray().put("_http._tcp"))
            .put("subnetCidr", "192.168.1.0/24")
            .put("ports", JSONArray().put(80))
            .put("timeoutMs", 20_000)
        val result = facts("network.lanDiscover", arguments)
        assertEquals("192.168.1.0", result.targetHost)
    }

    @Test
    fun mdnsOnlyLANHasNoConcreteEndpointHint() {
        val arguments = JSONObject()
            .put("serviceTypes", JSONArray().put("_ipp._tcp"))
            .put("discoveryDurationMs", 4_000)
        val result = facts("network.lanDiscover", arguments)
        assertEquals("network.lanDiscover", result.method)
        assertNull(result.targetHost)
    }

    @Test
    fun speedHintFollowsTheRequestedDirectionAndNeverLeaksUserInfoOrQuery() {
        val download = facts(
            "network.speedTest",
            JSONObject().put("direction", "download")
                .put("downloadUrl", "https://user:secret@speed.example.net/payload?token=abc"),
        )
        assertEquals("speed.example.net", download.targetHost)

        val upload = facts(
            "network.speedTest",
            JSONObject().put("direction", "upload")
                .put("uploadUrl", "https://[2001:db8::1]:8443/upload"),
        )
        assertEquals("2001:db8::1", upload.targetHost)

        val bothLocalUpload = facts(
            "network.speedTest",
            JSONObject().put("direction", "downloadAndUpload")
                .put("downloadUrl", "https://speed.example.net/payload")
                .put("uploadUrl", "https://nas.local/upload"),
        )
        assertEquals("nas.local", bothLocalUpload.targetHost)

        val bothPublic = facts(
            "network.speedTest",
            JSONObject().put("direction", "downloadAndUpload")
                .put("downloadUrl", "https://speed.example.net/payload")
                .put("uploadUrl", "https://uploads.example.net/upload"),
        )
        assertEquals("speed.example.net", bothPublic.targetHost)
    }

    @Test
    fun endpointArgumentsCannotGrantPermissionOrLeakCredentials() {
        // A malformed/credential-bearing URL yields no host hint; the wire
        // stores no permission and grants nothing by itself.
        val malformed = facts(
            "network.speedTest",
            JSONObject().put("direction", "upload")
                .put("uploadUrl", "https://user:secret@"),
        )
        assertNull(malformed.targetHost)

        val payload = request("network.speedTest", JSONObject()
            .put("direction", "upload")
            .put("uploadUrl", "https://nas.local/upload"))
        val ticket = NetworkDiagnosticsWire.parseDescriptor(
            descriptor("network.speedTest", payload), boundEpoch = 7,
        )
        val validFacts = NetworkDiagnosticsWire.validateRequest(payload, ticket)
        val permission = NetworkDiagnosticsWire.permissionRequest(
            observation(
                "permissionRequired", "network.speedTest",
                missing = JSONArray().put("android.permission.ACCESS_LOCAL_NETWORK"),
            ),
            ticket,
            validFacts,
        )
        // The explicit endpoint is only a host-only guidance hint.
        assertNotNull(permission)
        assertEquals("nas.local", permission?.targetHost)
        assertEquals(
            listOf("android.permission.ACCESS_LOCAL_NETWORK"),
            permission?.missingPermissions,
        )
    }

    @Test
    fun existingHTTPHintKeepsItsOriginalHostOnlyBehaviour() {
        val result = facts(
            "network.http",
            JSONObject().put("url", "https://example.com:8443/path?token=secret"),
        )
        assertEquals("network.http", result.method)
        assertEquals("example.com", result.targetHost)
    }

    @Test
    fun mdnsPermissionCarriesAHostFreeGuidanceLabel() {
        val payload = request("network.lanDiscover", JSONObject()
            .put("serviceTypes", JSONArray().put("_http._tcp"))
            .put("discoveryDurationMs", 4_000))
        val ticket = NetworkDiagnosticsWire.parseDescriptor(
            descriptor("network.lanDiscover", payload), boundEpoch = 7,
        )
        val facts = NetworkDiagnosticsWire.validateRequest(payload, ticket)
        val permission = NetworkDiagnosticsWire.permissionRequest(
            observation(
                "permissionRequired", "network.lanDiscover",
                missing = JSONArray().put("android.permission.ACCESS_LOCAL_NETWORK"),
            ),
            ticket,
            facts,
        )
        assertNotNull(permission)
        assertNull(permission?.targetHost)
        assertEquals("Local network discovery (.local/mDNS)", permission?.targetLabel)
    }

    @Test
    fun crossWiredObservationOrEpochIsRefusedBeforeServiceDispatch() {
        val payload = request("network.speedTest", JSONObject()
            .put("direction", "download")
            .put("downloadUrl", "https://speed.example.net/payload"))
        val ticket = NetworkDiagnosticsWire.parseDescriptor(
            descriptor("network.speedTest", payload), boundEpoch = 7,
        )
        refused("descriptorInvalid") {
            NetworkDiagnosticsWire.parseDescriptor(
                descriptor("network.speedTest", payload), boundEpoch = 8,
            )
        }
        refused("observationInvalid") {
            NetworkDiagnosticsWire.validateObservation(
                observation("ok", "network.lanDiscover"), ticket,
            )
        }
        assertEquals(
            "ok",
            NetworkDiagnosticsWire.validateObservation(
                observation("ok", "network.speedTest"), ticket,
            ),
        )
    }

    // ------------------------------------------------------------------
    // Pump integration: permissionRequired from a real staged request still
    // settles once and forwards the host-only hint without replaying.
    // ------------------------------------------------------------------

    @Test
    fun uploadOnlyPermissionForwardsTheExplicitEndpointOnce() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val transport = LanSpeedTransport(
            method = "network.speedTest",
            arguments = JSONObject().put("direction", "upload")
                .put("uploadUrl", "https://nas.local/upload"),
        )
        val calls = AtomicInteger()
        val notice = CompletableDeferred<NetworkPermissionRequest>()
        val lane = NetworkDiagnosticsHostPump(
            scope, Dispatchers.IO, { 7L }, {
                object : PhoneNetworkServicePort {
                    override suspend fun execute(requestJson: String): String {
                        calls.incrementAndGet()
                        return String(
                            transport.observation(
                                "permissionRequired",
                                JSONArray().put("android.permission.ACCESS_LOCAL_NETWORK"),
                            ),
                            Charsets.UTF_8,
                        )
                    }

                    override fun cancel(operationID: String) = Unit
                }
            },
            transport,
            onPermissionRequired = { notice.complete(it) },
            timing = NetworkDiagnosticsTiming(
                nextPollMillis = 5, maximumExecutionMillis = 1_000, cancelPollMillis = 5,
            ),
        )
        try {
            assertTrue(lane.start(7))
            val captured = withTimeout(2_000) { notice.await() }
            assertEquals("network.speedTest", captured.method)
            assertEquals("nas.local", captured.targetHost)
            assertEquals(
                listOf("android.permission.ACCESS_LOCAL_NETWORK"),
                captured.missingPermissions,
            )
            assertEquals("permissionRequired",
                withTimeout(2_000) { transport.done.await() }.getString("status"))
            assertTrue(lane.stopAndJoin(7, 1_000))
            assertEquals(1, calls.get())
            assertEquals(1, transport.completions.get())
        } finally {
            scope.cancel()
        }
    }

    private fun observation(
        status: String,
        method: String,
        missing: JSONArray? = null,
    ): ByteArray = JSONObject()
        .put("version", 1)
        .put("operationID", operation)
        .put("method", method)
        .put("source", "phone")
        .put("measuredAt", "2026-10-30T00:00:00Z")
        .put("status", status)
        .put("network", JSONObject().put("available", true))
        .put("observations", JSONObject())
        .apply { missing?.let { put("missingPermissions", it) } }
        .toString()
        .toByteArray(Charsets.UTF_8)

    private inner class LanSpeedTransport(
        private val method: String,
        private val arguments: JSONObject,
    ) : NetworkDiagnosticsNativeTransport {
        private val nextOnce = AtomicBoolean(true)
        val stop = AtomicBoolean(false)
        val completions = AtomicInteger()
        val done = CompletableDeferred<JSONObject>()
        private val stagedPayload = request(method, arguments)

        override fun bindEpoch(epoch: Long): Int = if (epoch == 7L) 0 else -102
        override fun next(timeoutMillis: Int): Long {
            if (nextOnce.compareAndSet(true, false)) return 1L
            Thread.sleep(5)
            return 0L
        }

        override fun describe(claim: Long): ByteArray = descriptor(method, stagedPayload)
        override fun payload(claim: Long): ByteArray = stagedPayload
        override fun isLive(claim: Long): Int = 1
        override fun shouldStop(claim: Long): Int = if (stop.get()) 1 else 0
        override fun complete(claim: Long, status: Int, value: ByteArray): Int {
            completions.incrementAndGet()
            done.complete(JSONObject(String(value, Charsets.UTF_8)))
            return 0
        }

        override fun close(epoch: Long): Int = 0
        override fun stats(): ByteArray? = null
        override fun readiness(): ByteArray? = null

        fun observation(status: String, missing: JSONArray?): ByteArray =
            this@NetworkDiagnosticsWireG072Test.observation(status, method, missing)
    }
}
