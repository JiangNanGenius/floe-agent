// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.RuntimeBootstrapCapability
import com.floe.android.SecretGatewayCapability
import com.floe.android.feature.providers.ConnectionProbeUi
import com.floe.android.feature.providers.ConnectionTestUi
import com.floe.android.feature.providers.ProviderEditorIdentity
import com.floe.android.feature.providers.ProviderServiceRoleUi
import com.floe.android.feature.providers.WireProtocolUi
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * G04-R2 actual-UI blocker family: a plain-HTTP endpoint WITHOUT the
 * local/private opt-in is correctly refused TYPED by native BEFORE any
 * request (transport contract unchanged), but the ordinary UI surfaced the
 * raw closed identifier `invalidEnvelope` (Main's Alpha10 proof: the same
 * candidate connected and saved once the actual switch was ON; entry/
 * HTTP_OPT_IN_ACTUAL.json). This suite pins the actionable EN/zh mapping for
 * the envelope-refusal family plus honest passthrough of every OTHER closed
 * code, and the real draft-probe publish path through the trusted seam.
 * No safety behavior is asserted away here: the same refusal must still
 * happen with the switch off.
 */
class ProviderPlainHttpGuidanceTest {

    private companion object {
        const val ACK_COPY =
            "This endpoint uses plain HTTP. Turn on Allow plain HTTP " +
                "(local/private only), or use an HTTPS address."
        const val PRIVATE_COPY =
            "Plain HTTP is only allowed for localhost or private-network addresses. " +
                "Use a local or private address, or switch to HTTPS."
        const val GENERIC_COPY =
            "Couldn't use these provider settings. Check the endpoint, protocol, " +
                "name and headers, then try again."
        const val ROUTE_TOKEN = "rt:v1:0123456789abcdef0123456789abcdef"
    }

    // ------------------------------------------------------------- mapping

    private fun controller(): ProviderHostController {
        val exchange = object : HostBridgeExchange {
            override fun exchange(request: String): String =
                "{\"version\":3,\"ok\":false,\"correlationID\":\"" + correlationOf(request) +
                    "\",\"error\":\"notUsed\",\"reason\":\"notUsed\"}"
        }
        val host = RuntimeHost(
            commandClient = RuntimeHostCommandClient(
                exchange = exchange,
                scope = CoroutineScope(Dispatchers.Default),
                ioDispatcher = Dispatchers.Default,
                budgets = HostWireBudgets(effectPollIntervalMillis = 1),
            ),
            gatewayCapability = MutableStateFlow(SecretGatewayCapability.Ready),
            bootstrapCapability = MutableStateFlow(RuntimeBootstrapCapability.Idle),
            scope = CoroutineScope(Dispatchers.Default),
            ioDispatcher = Dispatchers.Default,
        )
        host.onBootstrapCapability(RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("providerConfigurationDomain", true, emptyList())
        host.nativeRootEpochReader = { 7L }
        host.providers.routeAuthority = object : HostRouteAuthority {
            override fun open(
                kind: HostEditorKind,
                editorID: String,
                uiGeneration: Long,
                expectedNativeRootEpoch: Long,
            ) = ROUTE_TOKEN

            override fun clear(token: String) = Unit
        }
        return host.providers
    }

    private fun correlationOf(request: String): String =
        Regex("\"correlationID\":\"([^\"]+)\"").find(request)?.groupValues?.get(1) ?: "c1"

    @Test
    fun draftValidationAckRefusalMapsToActionableOptInCopy() {
        val providers = controller()
        assertEquals(
            ACK_COPY,
            providers.providerFailureCopy(
                "invalidEnvelope", "draftValidation.plainHTTPRequiresAcknowledgement"),
        )
    }

    @Test
    fun saveProviderValidationAckRefusalMapsToSameOptInCopy() {
        val providers = controller()
        assertEquals(
            ACK_COPY,
            providers.providerFailureCopy(
                "invalidEnvelope",
                "providerValidation[plainHTTP:plainHTTPRequiresAcknowledgement:" +
                    "providers.validation.plain_http_ack]",
            ),
        )
    }

    @Test
    fun privateNetworkRefusalMapsToAddressGuidance() {
        val providers = controller()
        assertEquals(
            PRIVATE_COPY,
            providers.providerFailureCopy(
                "invalidEnvelope",
                "providerValidation[plainHTTP:plainHTTPRequiresPrivateNetwork:" +
                    "providers.validation.plain_http_private_only]",
            ),
        )
        assertEquals(
            PRIVATE_COPY,
            providers.providerFailureCopy(
                "invalidEnvelope", "draftValidation.plainHTTPRequiresPrivateNetwork"),
        )
    }

    @Test
    fun otherEnvelopeRefusalsMapToHonestGenericCopy() {
        val providers = controller()
        for (reason in listOf("candidateParse", "candidate.baseURL", "unknownField.candidate.x")) {
            assertEquals(GENERIC_COPY, providers.providerFailureCopy("invalidEnvelope", reason))
        }
        assertEquals(GENERIC_COPY, providers.providerFailureCopy("invalidEnvelope", null))
    }

    @Test
    fun unrelatedClosedCodesStayVerbatim() {
        // No blanket success, no hidden diagnostics: every code OUTSIDE the
        // mapped envelope family keeps its closed identifier exactly.
        val providers = controller()
        for (code in listOf(
            "transportUnavailable", "credentialUnavailable", "staleRevision",
            "duplicateInFlight", "notFound", "runtimeUnavailable",
        )) {
            assertEquals(code, providers.providerFailureCopy(code, "transportGateClosed"))
        }
        assertEquals(
            "runtimeUnavailable",
            providers.providerFailureCopy("runtimeUnavailable", "probeFailed(connectionFailed)"),
        )
    }

    // ----------------------------------------------------- behavioral seam

    /** The REAL settled refusal envelope G02HostDraftProbe.failurePayload
     * produces for a plain-HTTP draft without the opt-in (status failed +
     * errorCode invalidEnvelope + closed draftValidation reason). */
    private class FailedDraftProbe(private val failureJSON: String) : HostDraftProbe {
        val submitCalls = AtomicInteger(0)
        @Volatile var lastCandidate: String? = null
        private val handles = ConcurrentHashMap<String, Boolean>()

        override fun submit(candidateJSON: String, secret: String?, routeToken: String): String? {
            submitCalls.incrementAndGet()
            lastCandidate = candidateJSON
            val handle = "dp:v1:%032x".format(submitCalls.get())
            handles[handle] = true
            return handle
        }

        override fun poll(handle: String, routeToken: String): String =
            if (handles.containsKey(handle)) "S$failureJSON" else "R-117"

        override fun cancel(handle: String, routeToken: String) = Unit
    }

    @Test
    fun draftProbeEnvelopeRefusalSurfacesActionableCopyNotRawIdentifier() = runBlocking {
        val providers = controller()
        val seam = FailedDraftProbe(
            "{\"status\":\"failed\",\"errorCode\":\"invalidEnvelope\"," +
                "\"reason\":\"draftValidation.plainHTTPRequiresAcknowledgement\"}",
        )
        providers.draftProbe = seam
        val identity = ProviderEditorIdentity(
            editorId = "new-conversation-guidance",
            epoch = 1,
            role = ProviderServiceRoleUi.CONVERSATION,
        )
        providers.editorOpened(identity)
        // A remote (non-local-broker) endpoint keeps this test hermetic; the
        // seam payload below IS the exact closed refusal the device produced
        // for the unchecked HTTP opt-in, so the mapping path is exercised
        // with the real settled envelope bytes. (The broker-covered 127.x
        // variant runs the SAME seam+mapping once the system grant arrives.)
        val probe = ConnectionProbeUi(
            endpointAbsoluteString = "http://api.example.invalid/v1",
            wireProtocol = WireProtocolUi.OPENAI_CHAT_COMPLETIONS,
            nonSecretHeaders = emptyMap(),
            credentialDraft = "synthetic-placeholder-key",
            allowsPlainHttp = false,
            toolNameCompatibility = false,
        )
        assertTrue(providers.testConnection(identity, probe))
        val deadline = System.nanoTime() + 3_000_000_000L
        var state: ConnectionTestUi? = null
        while (System.nanoTime() < deadline) {
            state = providers.destination.value.editor?.testState
            if (state is ConnectionTestUi.Failed) break
            delay(10)
        }
        val failed = state as? ConnectionTestUi.Failed
        assertTrue("draft probe must settle Failed through the seam", failed != null)
        assertEquals(ACK_COPY, failed!!.reason)
        assertNotEquals("invalidEnvelope", failed.reason)
    }

    @Test
    fun reasonOfReadsTheClosedNativeReason() {
        // The settled envelope carries the diagnostic reason next to the
        // closed code; ProviderWire must surface it for the mapping without
        // ever exposing bodies or secrets (native emits closed tokens only).
        val providers = controller()
        val payload = kotlinx.serialization.json.Json.parseToJsonElement(
            "{\"status\":\"failed\",\"errorCode\":\"invalidEnvelope\"," +
                "\"reason\":\"candidate.baseURL\"}",
        ) as kotlinx.serialization.json.JsonObject
        assertEquals("candidate.baseURL", ProviderWire.reasonOf(payload))
        assertEquals("invalidEnvelope", ProviderWire.failureOf(payload))
    }
}
