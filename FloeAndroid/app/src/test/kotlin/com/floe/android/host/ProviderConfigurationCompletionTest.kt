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
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * G02 provider-configuration completion (job-31c) JVM coverage:
 *
 *  1. lossless existing-provider editor reconstruction from the bounded
 *     additive secret-free projection (presetID + non-secret headers) plus
 *     the real model rows, and a Keep save that PRESERVES all of them;
 *  2. list-level enable/disable through the complete frozen Keep candidate +
 *     the real persisted revision (never `.enabled.set`, never a permanent
 *     local refusal);
 *  3. unsaved/dirty draft probe/discovery through the trusted host seam
 *     (proof the SAVED profile is not probed about a changed draft), with
 *     saved-unchanged probes still using the frozen `config.provider.probe`;
 *  4. cancel/close owns real cancellation of the draft probe.
 */
class ProviderConfigurationCompletionTest {

    @Test
    fun discoveredModelUsesNativeNestedLimitsAndScalarCapabilities() {
        val rows = ProviderWire.decodeDiscoveredModels(Json.parseToJsonElement("""
            {"discoveredModels":[
              {"remoteModelID":"native","limits":{"contextTokens":8192,"maxOutputTokens":1024},"capabilities":5},
              {"remoteModelID":"legacy","contextTokens":6000,"maxOutputTokens":500,"capabilities":[1,4]},
              {"remoteModelID":"unspecified"},
              {"remoteModelID":"invalid","limits":{"contextTokens":0,"maxOutputTokens":-1}}
            ]}
        """))
        assertEquals(listOf(8192, 6000, 128_000, 0), rows.map { it.contextTokens })
        assertEquals(listOf(1024, 500, 0, -1), rows.map { it.maxOutputTokens })
        assertEquals(rows[0].capabilities, rows[1].capabilities)
        assertTrue(rows[0].capabilities.contains(com.floe.android.feature.providers.ModelCapabilityUi.TEXT))
        assertTrue(rows[0].capabilities.contains(com.floe.android.feature.providers.ModelCapabilityUi.TOOLS))
    }

    private val json = Json { ignoreUnknownKeys = true }

    private companion object {
        const val PROVIDER_ID = "11111111-1111-1111-1111-111111111111"
        const val MODEL_ID = "22222222-2222-2222-2222-222222222222"
        const val ROUTE_TOKEN = "rt:v1:0123456789abcdef0123456789abcdef"

        val PROVIDER_ROW = """
            {"id":"$PROVIDER_ID","kind":"openAI","wireProtocol":"openai-chat-completions",
             "baseURL":"https://api.example.invalid/v1","displayName":"Persisted",
             "region":null,"isEnabled":false,"allowsPlainHTTP":false,
             "toolNameCompatibility":true,"createdAt":"2026-10-20T00:00:00.000Z",
             "updatedAt":"2026-10-20T00:00:00.000Z","syncRevision":3,
             "secret":{"configured":true,"opaqueReference":"ref:v1:aa","synchronizable":false},
             "presetID":"deepseek",
             "nonSecretHeaders":{"X-Org":"persisted","X-Route":"direct"}}
        """.trimIndent()

        val MODEL_ROW = """
            {"id":"$MODEL_ID","providerID":"$PROVIDER_ID","remoteModelID":"kept-model",
             "displayName":"Kept Model","limits":{"contextTokens":4096,"maxOutputTokens":1024},
             "capabilities":5,"reasoningEffort":null,"isEnabled":false,
             "isHiddenFromPrimaryPicker":true,
             "revision":{"resourceID":"model.$MODEL_ID","version":"d1"}}
        """.trimIndent()

        const val PREFERENCES = """
            {"preferences":{"defaultAgentModelID":"$MODEL_ID"},
             "revision":{"resourceID":"settings.model-preferences","version":"r1"}}
        """
    }

    private class Exchange : HostBridgeExchange {
        var providerRow: String = PROVIDER_ROW
        var modelRow: String = MODEL_ROW
        val commands = java.util.concurrent.CopyOnWriteArrayList<String>()
        val saveEnvelopes = java.util.concurrent.CopyOnWriteArrayList<String>()
        val probeEnvelopes = java.util.concurrent.CopyOnWriteArrayList<String>()
        private val receiptKinds = ConcurrentHashMap<String, String>()
        private val receiptValues = ConcurrentHashMap<String, String>()
        private val receiptSequence = AtomicInteger(0)

        override fun exchange(request: String): String {
            val correlation = correlationOf(request)
            if (request.contains("\"operation\":\"effect.poll\"")) {
                val receipt = receiptOf(request)
                val kind = receiptKinds[receipt] ?: return emptyPage(correlation, receipt)
                val value = receiptValues[receipt]
                return if (value != null) {
                    completedPage(correlation, receipt, value)
                } else {
                    emptyPage(correlation, receipt)
                }
            }
            val command = when {
                request.contains("\"command\":\"config.providers.list\"") -> "plist"
                request.contains("\"command\":\"config.models.list\"") -> "models"
                request.contains("\"command\":\"config.preferences.get\"") -> "prefs"
                request.contains("\"command\":\"config.catalog.search\"") -> "catalog"
                request.contains("\"command\":\"config.provider.save\"") -> "save"
                request.contains("\"command\":\"config.provider.probe\"") -> "probe"
                else -> null
            } ?: return """{"version":3,"ok":false,"error":"invalidEnvelope","reason":"unscripted"}"""
            commands.add(command)
            val value = when (command) {
                "plist" -> """{"rows":[$providerRow]}"""
                "models" -> """{"rows":[$modelRow]}"""
                "prefs" -> PREFERENCES
                "catalog" -> """{"rows":[]}"""
                "save" -> {
                    saveEnvelopes.add(request)
                    """{"state":"completed","value":{"state":"committed","providerID":"$PROVIDER_ID"}}"""
                }
                "probe" -> {
                    probeEnvelopes.add(request)
                    """{"status":"connected","modelCount":1,"discoveredModels":[{"id":"33333333-3333-3333-3333-333333333333","providerID":"$PROVIDER_ID","remoteModelID":"saved-model","displayName":"Saved Model","limits":{"contextTokens":4096,"maxOutputTokens":1024},"capabilities":5}],"failureReason":null}"""
                }
                else -> "{}"
            }
            val number = receiptSequence.incrementAndGet()
            val receipt = "op:v1:$command$number"
            receiptKinds[receipt] = command
            receiptValues[receipt] = value
            return queued(correlation, receipt)
        }

        private fun queued(correlation: String, receipt: String): String =
            """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"$receipt"}"""

        private fun completedPage(correlation: String, receipt: String, value: String): String =
            """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":1},"effects":[{"sequence":1,"kind":"accepted","value":$value}],"hasMore":false,"resyncRequired":false}"""

        private fun emptyPage(correlation: String, receipt: String): String =
            """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":0},"effects":[],"hasMore":true,"resyncRequired":false}"""
    }

    private class FakeRouteAuthority : HostRouteAuthority {
        val opened = AtomicInteger(0)
        val cleared = AtomicInteger(0)
        override fun open(
            kind: HostEditorKind,
            editorID: String,
            uiGeneration: Long,
            expectedNativeRootEpoch: Long,
        ): String? {
            opened.incrementAndGet()
            return ROUTE_TOKEN
        }

        override fun clear(token: String) {
            cleared.incrementAndGet()
        }
    }

    private class FakeDraftProbe(
        private val pending: Boolean = false,
        private val payload: String = """{"status":"connected","modelCount":2,"discoveredModels":[{"id":"44444444-4444-4444-4444-444444444444","providerID":"11111111-1111-1111-1111-111111111111","remoteModelID":"draft-model-0","displayName":"Draft Model 0","limits":{"contextTokens":8192,"maxOutputTokens":2048},"capabilities":5},{"id":"55555555-5555-5555-5555-555555555555","providerID":"11111111-1111-1111-1111-111111111111","remoteModelID":"draft-model-1","displayName":"Draft Model 1","limits":{"contextTokens":8192,"maxOutputTokens":2048},"capabilities":5}]}""",
    ) : HostDraftProbe {
        val submitCalls = AtomicInteger(0)
        val cancelCalls = AtomicInteger(0)
        @Volatile var lastCandidate: String? = null
        @Volatile var lastSecret: String? = null
        @Volatile var lastRoute: String? = null
        private val handles = ConcurrentHashMap<String, Boolean>()

        override fun submit(candidateJSON: String, secret: String?, routeToken: String): String? {
            submitCalls.incrementAndGet()
            lastCandidate = candidateJSON
            lastSecret = secret
            lastRoute = routeToken
            val handle = "dp:v1:" + "%032x".format(submitCalls.get())
            handles[handle] = true
            return handle
        }

        override fun poll(handle: String, routeToken: String): String =
            if (handles.containsKey(handle)) {
                if (pending) "P" else "S$payload"
            } else "R-117"

        override fun cancel(handle: String, routeToken: String) {
            cancelCalls.incrementAndGet()
        }
    }

    private fun host(exchange: HostBridgeExchange): RuntimeHost {
        val host = RuntimeHost(
            commandClient = RuntimeHostCommandClient(
                exchange = exchange,
                scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default),
                ioDispatcher = kotlinx.coroutines.Dispatchers.Default,
                budgets = HostWireBudgets(effectPollIntervalMillis = 1),
            ),
            gatewayCapability = kotlinx.coroutines.flow.MutableStateFlow(
                SecretGatewayCapability.Ready),
            bootstrapCapability = kotlinx.coroutines.flow.MutableStateFlow(
                RuntimeBootstrapCapability.Idle),
            scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default),
            ioDispatcher = kotlinx.coroutines.Dispatchers.Default,
        )
        host.onBootstrapCapability(RuntimeBootstrapCapability.OwnedStoreReady)
        host.nativeRootEpochReader = { 7L }
        host.providers.routeAuthority = FakeRouteAuthority()
        return host
    }

    private suspend fun waitUntil(timeoutMillis: Long = 3_000, predicate: () -> Boolean) {
        val deadline = System.nanoTime() + timeoutMillis * 1_000_000L
        while (System.nanoTime() < deadline) {
            if (predicate()) return
            delay(10)
        }
        assertTrue("condition not reached", predicate())
    }

    private suspend fun load(host: RuntimeHost) {
        host.providers.refreshProviders()
        waitUntil { !host.providers.destination.value.list.isLoading }
        waitUntil {
            host.providers.destination.value.list.conversationProviders
                .any { it.providerId == PROVIDER_ID }
        }
        // The editor seeds only from a COMPLETE model read; a saved profile
        // must never reopen from a partial/empty cache.
        waitUntil { host.conversations.modelsProjectionReadyForEditing() }
    }

    private fun editorIdentity(editorId: String = "$PROVIDER_ID-conversation-1") =
        ProviderEditorIdentity(editorId = editorId, epoch = 1, role = ProviderServiceRoleUi.CONVERSATION)

    /** The frozen inner `floe.command-envelope/3` document. */
    private fun envelopeOf(raw: String): JsonObject {
        val root = json.parseToJsonElement(raw) as JsonObject
        return root["envelope"]?.jsonObject ?: root
    }

    /** The envelope's closed `payload` member. */
    private fun payloadOf(raw: String): JsonObject =
        envelopeOf(raw)["payload"]!!.jsonObject

    // ------------------------------------------------------------------ 1

    @Test
    fun seedEditorReconstructsPersistedProfileAndKeepPreservesIt() = runBlocking {
        val exchange = Exchange()
        val host = host(exchange)
        load(host)
        val seed = host.providers.seedEditorFor(ProviderServiceRoleUi.CONVERSATION, PROVIDER_ID)
        assertNotNull(seed)
        val snapshot = seed!!.snapshot
        assertEquals(false, snapshot.enabled)
        assertEquals("Persisted", snapshot.displayName)
        assertEquals("https://api.example.invalid/v1", snapshot.baseUrl)
        assertEquals(true, snapshot.toolNameCompatibility)
        assertEquals("X-Org: persisted\nX-Route: direct", snapshot.nonSecretHeaders)
        assertEquals("deepseek", snapshot.supplier?.presetId)
        assertEquals(1, snapshot.models.size)
        val model = snapshot.models.single()
        assertEquals(MODEL_ID, model.savedModelId)
        assertEquals(false, model.enabled)
        assertEquals(true, model.hiddenFromPrimaryPicker)
        assertEquals(MODEL_ID, snapshot.defaultModelDraftId)

        // Opening the editor publishes the seed (no blank Add-Provider state).
        val identity = editorIdentity()
        host.providers.editorOpened(identity)
        waitUntil { host.providers.destination.value.editor?.identity?.editorId == identity.editorId }
        val published = host.providers.destination.value.editor!!
        assertTrue(published.isEditingExisting)
        assertFalse(published.testState is ConnectionTestUi.Testing)

        // A Keep save from the reopened editor carries EVERY persisted field.
        assertTrue(host.providers.saveProvider(identity, snapshot, null))
        waitUntil { exchange.saveEnvelopes.isNotEmpty() }
        val payload = payloadOf(exchange.saveEnvelopes.single())
        assertEquals("keep", payload["secretIntent"]?.jsonPrimitive?.contentOrNull)
        assertFalse(payload.toString().contains("ingressToken"))
        assertFalse(exchange.saveEnvelopes.single().contains("ingressToken"))
        val candidate = payload["candidate"]!!.jsonObject
        assertEquals("deepseek", candidate["presetID"]?.jsonPrimitive?.contentOrNull)
        val headers = candidate["nonSecretHeaders"]!!.jsonObject
        assertEquals("persisted", headers["X-Org"]?.jsonPrimitive?.contentOrNull)
        assertEquals("direct", headers["X-Route"]?.jsonPrimitive?.contentOrNull)
        assertEquals(false, candidate["isEnabled"]?.jsonPrimitive?.boolean)
        assertEquals(true, candidate["toolNameCompatibility"]?.jsonPrimitive?.boolean)
        val models = candidate["selectedModels"]!!.jsonArray
        assertEquals(1, models.size)
        assertEquals(MODEL_ID, models.single().jsonObject["id"]?.jsonPrimitive?.contentOrNull)
        assertEquals(false, models.single().jsonObject["isEnabled"]?.jsonPrimitive?.boolean)
        assertEquals(false, candidate["createIntent"]?.jsonPrimitive?.boolean)
        val revision = envelopeOf(exchange.saveEnvelopes.single())["revision"]!!.jsonObject
        assertEquals("provider.$PROVIDER_ID", revision["resourceID"]?.jsonPrimitive?.contentOrNull)
        assertEquals("3", revision["version"]?.jsonPrimitive?.contentOrNull)
    }

    // ------------------------------------------------------------------ 2

    @Test
    fun listToggleWritesOneClosedMetadataKeepWithActualRevision() = runBlocking {
        val exchange = Exchange()
        val host = host(exchange)
        load(host)
        assertTrue(host.providers.setProviderEnabled(PROVIDER_ID, true))
        waitUntil { exchange.saveEnvelopes.isNotEmpty() }
        val payload = payloadOf(exchange.saveEnvelopes.single())
        assertEquals("keep", payload["secretIntent"]?.jsonPrimitive?.contentOrNull)
        assertEquals("3", envelopeOf(exchange.saveEnvelopes.single())["revision"]!!.jsonObject["version"]?.jsonPrimitive?.contentOrNull)
        assertEquals(setOf("secretIntent", "metadata"), payload.keys)
        val metadata = payload["metadata"]!!.jsonObject
        assertEquals(setOf("id", "isEnabled"), metadata.keys)
        assertEquals(PROVIDER_ID, metadata["id"]?.jsonPrimitive?.contentOrNull)
        assertEquals(true, metadata["isEnabled"]?.jsonPrimitive?.boolean)
        assertFalse(payload.containsKey("candidate"))
        assertFalse(payload.containsKey("ingressToken"))
        // The narrow original-store CAS is covered by the 512-model native
        // suite; this fixture proves the App sends no model/header/key copy.
        // Refreshed persisted state remains the only success projection.
        // Requesting the ALREADY persisted state performs no write.
        assertTrue(host.providers.setProviderEnabled(PROVIDER_ID, false))
        assertEquals(1, exchange.saveEnvelopes.size)
    }

    // ------------------------------------------------------------------ 3

    @Test
    fun dirtyDraftProbeUsesTrustedSeamInsteadOfTheSavedProfile() = runBlocking {
        val exchange = Exchange()
        val host = host(exchange)
        val seam = FakeDraftProbe()
        host.providers.draftProbe = seam
        load(host)
        val identity = editorIdentity()
        host.providers.editorOpened(identity)
        val changedEndpoint = "https://changed.example.invalid/v1"
        val probe = ConnectionProbeUi(
            endpointAbsoluteString = changedEndpoint,
            wireProtocol = WireProtocolUi.OPENAI_CHAT_COMPLETIONS,
            nonSecretHeaders = mapOf("X-Org" to "changed"),
            credentialDraft = "sk-typed-now",
            allowsPlainHttp = false,
            toolNameCompatibility = true,
        )
        assertTrue(host.providers.testConnection(identity, probe))
        waitUntil { seam.submitCalls.get() == 1 }
        waitUntil {
            host.providers.destination.value.editor?.testState is ConnectionTestUi.Succeeded
        }
        // The DRAFT candidate (not the saved profile) was frozen and sent.
        val candidate = json.parseToJsonElement(seam.lastCandidate!!) as JsonObject
        assertEquals(changedEndpoint, candidate["baseURL"]?.jsonPrimitive?.contentOrNull)
        assertEquals(
            "changed",
            candidate["nonSecretHeaders"]!!.jsonObject["X-Org"]?.jsonPrimitive?.contentOrNull)
        assertEquals("sk-typed-now", seam.lastSecret)
        assertEquals(ROUTE_TOKEN, seam.lastRoute)
        // The saved-profile probe command was NEVER sent about the draft.
        assertTrue(exchange.probeEnvelopes.isEmpty())
        val succeeded = host.providers.destination.value.editor?.testState as ConnectionTestUi.Succeeded
        assertEquals(2, succeeded.discoveredModelCount)
    }

    @Test
    fun unchangedSavedConnectionStillUsesTheFrozenProbeCommand() = runBlocking {
        val exchange = Exchange()
        val host = host(exchange)
        val seam = FakeDraftProbe()
        host.providers.draftProbe = seam
        load(host)
        val identity = editorIdentity()
        host.providers.editorOpened(identity)
        val unchanged = ConnectionProbeUi(
            endpointAbsoluteString = "https://api.example.invalid/v1",
            wireProtocol = WireProtocolUi.OPENAI_CHAT_COMPLETIONS,
            nonSecretHeaders = emptyMap(),
            credentialDraft = null,
            allowsPlainHttp = false,
            toolNameCompatibility = true,
        )
        assertTrue(host.providers.testConnection(identity, unchanged))
        waitUntil { exchange.probeEnvelopes.isNotEmpty() }
        assertEquals(0, seam.submitCalls.get())
        val payload = payloadOf(exchange.probeEnvelopes.single())
        assertEquals(PROVIDER_ID, payload["providerID"]?.jsonPrimitive?.contentOrNull)
    }

    // ------------------------------------------------------------------ 4

    @Test
    fun editorCloseAndCancelOwnTheDraftProbeCancellation() = runBlocking {
        val exchange = Exchange()
        val host = host(exchange)
        val seam = FakeDraftProbe(pending = true)
        host.providers.draftProbe = seam
        load(host)
        val identity = editorIdentity("new-conversation-1")
        host.providers.editorOpened(identity)
        val probe = ConnectionProbeUi(
            endpointAbsoluteString = "https://new.example.invalid/v1",
            wireProtocol = WireProtocolUi.OPENAI_CHAT_COMPLETIONS,
            nonSecretHeaders = emptyMap(),
            credentialDraft = "sk-new",
            allowsPlainHttp = false,
            toolNameCompatibility = false,
        )
        assertTrue(host.providers.testConnection(identity, probe))
        waitUntil { seam.submitCalls.get() == 1 }
        host.providers.cancelConnectionTest(identity)
        waitUntil { seam.cancelCalls.get() >= 1 }
        assertEquals(ConnectionTestUi.Idle, host.providers.destination.value.editor?.testState)

        // Re-submit, then close the editor: close cancels the owned probe.
        assertTrue(host.providers.testConnection(identity, probe))
        waitUntil { seam.submitCalls.get() == 2 }
        val before = seam.cancelCalls.get()
        host.providers.editorClosed(identity, discarded = true)
        waitUntil { seam.cancelCalls.get() > before }
    }
}
