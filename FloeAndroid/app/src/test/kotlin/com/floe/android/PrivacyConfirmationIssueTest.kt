// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * R2-A privileged privacy-confirmation ingress (coordinator owner gate).
 * AUTHORED, NOTRUN — scripted fakes only; no JNI, no device, no disk.
 *
 * Covers: expected-epoch mismatch refusal (no ingress call at all), stop /
 * owner-proof-invalid refusal, exact accepted epoch+token+operation+digest+
 * invocation+action forwarding, and typed/defensive null on refusal. The
 * owner token is asserted ONLY as the exact accepted-start token captured by
 * the coordinator (never logged or stored beyond the call boundary).
 */
class PrivacyConfirmationIssueTest {

    private inner class FakeNative : RuntimeNativeApi {
        var statusJson: String? = readyStatus(1)
        override fun ensureLoaded() = Unit
        override fun runtimeOwnerStart(rootPath: String, ownerToken: String, epoch: Long) =
            "op:v1:" + "a".repeat(32)
        override fun runtimeOwnerStop(ownerEpoch: Long, ownerToken: String) =
            "op:v1:" + "b".repeat(32)
        override fun runtimeStatus(): String? = statusJson
    }

    private inner class FakeExchange : RuntimeBridgeExchange {
        private val responders = ConcurrentLinkedQueue<(JsonObject) -> String>()
        fun enqueue(responder: (JsonObject) -> String) { responders.add(responder) }
        override fun exchange(request: String): String {
            val root = Json.parseToJsonElement(request).jsonObject
            responders.poll()?.let { return it(root) }
            return """{"version":3,"requestID":"${root.requestId()}","ok":false,""" +
                """"error":"runtimeUnavailable","reason":"effectReceiptNotFound"}"""
        }
    }

    /** Records every ingress attempt; null result simulates a refusal. */
    private class RecordingIngress(
        var result: String? = "pc:v1:" + "c".repeat(32),
        var throwTyped: Boolean = false,
    ) : PrivacyConfirmationIngress {
        data class Call(
            val epoch: Long, val token: String, val operation: String,
            val digest: String, val invocation: String, val action: String,
        )
        val calls = CopyOnWriteArrayList<Call>()
        override fun issue(
            ownerEpoch: Long,
            ownerToken: String,
            operation: String,
            previewDigest: String,
            invocationID: String,
            action: String,
        ): String? {
            calls.add(Call(ownerEpoch, ownerToken, operation, previewDigest,
                invocationID, action))
            if (throwTyped) {
                throw com.floe.android.bridge.PrivacyConfirmationNativeException(-120)
            }
            return result
        }
    }

    private fun acceptedCoordinator(
        ingress: RecordingIngress,
    ): RuntimeBootstrapCoordinator {
        val native = FakeNative()
        val exchange = FakeExchange()
        exchange.enqueue { request -> gatewayResponse(request.requestId()) }
        exchange.enqueue { request ->
            effectPage(request.requestId(), "op:v1:" + "a".repeat(32),
                """{"sequence":1,"kind":"accepted","detail":[]}""", 1)
        }
        val gateway = MutableStateFlow<SecretGatewayCapability>(
            SecretGatewayCapability.Ready)
        val subject = RuntimeBootstrapCoordinator(
            native = native,
            exchange = exchange,
            gatewayCapability = gateway,
            rootProvider = { "/data/user/0/com.floe.android/files/floe-runtime" },
            ownerTokenProvider = { "0123456789abcdef0123456789abcdef" },
            scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined),
            ioDispatcher = Dispatchers.Unconfined,
            timings = RuntimeBootstrapTimings(
                effectPollIntervalMillis = 1, bootstrapDeadlineMillis = 250,
                shutdownDeadlineMillis = 100),
            privacyIngress = ingress,
        )
        return subject
    }

    @Test
    fun mintForwardsExactAcceptedProofAndInvocation() {
        val ingress = RecordingIngress()
        val subject = acceptedCoordinator(ingress)
        runBlocking { subject.bootstrap() }
        assertEquals(RuntimeBootstrapCapability.OwnedStoreReady, subject.capability.value)
        val capability = subject.issuePrivacyConfirmation(
            expectedNativeEpoch = 1L,
            operation = "privacy.history.clear",
            previewDigest = "sha256:" + "d".repeat(64),
            invocationID = "prh-77",
            action = "historyClear",
        )
        assertEquals("pc:v1:" + "c".repeat(32), capability)
        assertEquals(1, ingress.calls.size)
        val call = ingress.calls.single()
        assertEquals(1L, call.epoch)
        assertEquals("0123456789abcdef0123456789abcdef", call.token)
        assertEquals("privacy.history.clear", call.operation)
        assertEquals("sha256:" + "d".repeat(64), call.digest)
        assertEquals("prh-77", call.invocation)
        assertEquals("historyClear", call.action)
    }

    @Test
    fun mintRefusesExpectedEpochMismatchWithoutIngressCall() {
        val ingress = RecordingIngress()
        val subject = acceptedCoordinator(ingress)
        runBlocking { subject.bootstrap() }
        // A preview captured on the OLD root must never mint for the new one,
        // even when the digest happens to match.
        val capability = subject.issuePrivacyConfirmation(
            expectedNativeEpoch = 0L,   // UI counter / fabricated zero
            operation = "privacy.history.clear",
            previewDigest = "sha256:" + "d".repeat(64),
            invocationID = "prh-78",
            action = "historyClear",
        )
        assertNull(capability)
        assertTrue(ingress.calls.isEmpty())
        val stale = subject.issuePrivacyConfirmation(
            expectedNativeEpoch = 99L,
            operation = "privacy.history.clear",
            previewDigest = "sha256:" + "d".repeat(64),
            invocationID = "prh-79",
            action = "historyClear",
        )
        assertNull(stale)
        assertTrue(ingress.calls.isEmpty())
    }

    @Test
    fun mintRefusesAfterStop() {
        val ingress = RecordingIngress()
        val subject = acceptedCoordinator(ingress)
        runBlocking { subject.bootstrap() }
        runBlocking { subject.shutdown() }
        val capability = subject.issuePrivacyConfirmation(
            expectedNativeEpoch = 1L,
            operation = "privacy.modelConfiguration.clear",
            previewDigest = "sha256:" + "e".repeat(64),
            invocationID = "prm-1",
            action = "modelConfigClear",
        )
        assertNull(capability)
        assertTrue(ingress.calls.isEmpty())
    }

    @Test
    fun typedIngressRefusalSurfacesAsUnavailableCapability() {
        val ingress = RecordingIngress(throwTyped = true)
        val subject = acceptedCoordinator(ingress)
        runBlocking { subject.bootstrap() }
        val capability = subject.issuePrivacyConfirmation(
            expectedNativeEpoch = 1L,
            operation = "privacy.history.clear",
            previewDigest = "sha256:" + "d".repeat(64),
            invocationID = "prh-80",
            action = "historyClear",
        )
        assertNull(capability)
        assertEquals(1, ingress.calls.size)
    }

    private fun gatewayResponse(requestID: String): String =
        """{"version":2,"requestID":"$requestID","ok":true,"secretBackend":{""" +
            """"registered":true,"availability":"AVAILABLE","memoryFallback":false}}"""

    private fun effectPage(requestID: String, receipt: String, effectsJson: String,
                           sequence: Long): String =
        """{"version":3,"requestID":"$requestID","ok":true,""" +
            """"schema":"floe.effect-cursor/3","correlationID":"$requestID",""" +
            """"cursor":{"operationReceiptID":"$receipt","sequence":$sequence},""" +
            """"effects":[$effectsJson],"hasMore":false,"resyncRequired":false}"""

    private fun readyStatus(generation: Long): String =
        """{"version":1,"phase":"starting","gatewayRegistered":true,"ownedStoreReady":true,"ownedStorePhase":"ready","domainRuntimeReady":false,"businessCapabilities":[],"generation":$generation,"retiring":false,"ordinaryRuntimeAdmission":"blocked","missingBindings":["providerConfigurationDomain","runDomain"]}"""

    private fun JsonObject.requestId(): String =
        this["requestID"]!!.jsonPrimitive.content
}
