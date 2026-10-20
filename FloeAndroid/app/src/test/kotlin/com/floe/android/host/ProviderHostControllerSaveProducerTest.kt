// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.RuntimeBootstrapCapability
import com.floe.android.SecretGatewayCapability
import com.floe.android.feature.providers.ModelDraftRowUi
import com.floe.android.feature.providers.ProviderDraftSnapshot
import com.floe.android.feature.providers.ProviderEditorIdentity
import com.floe.android.feature.providers.ProviderServiceRoleUi
import com.floe.android.feature.providers.SupplierChoice
import com.floe.android.feature.providers.WireProtocolUi
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * REAL producer regression for the first-install custom-provider Save crash
 * (Main formal package UID 10235 / PID 20067, 2026-10-20):
 *
 *  `ProviderHostController.saveProvider` resolved the save kind with
 *  `catalogKinds[draft.supplier?.presetId]`; a first-install draft has NO
 *  supplier, so `ConcurrentHashMap.get(null)` threw
 *  `NullPointerException` before the candidate/route/ingress path ran.
 *
 * These cases drive the ACTUAL [ProviderHostController] producer over a real
 * [RuntimeHost] (scripted transport + one-shot submitter doubles, no native
 * library), and pin:
 *  * a new custom/no-preset draft is admitted, freezes a `custom` candidate
 *    and enters the existing native route + one-shot `int:v1:` credential
 *    command (the public command carries only `secretIntent`/`ingressToken`);
 *  * a persisted row keeps its PERSISTED `ProviderKind` even when the draft
 *    names a catalog preset whose kind differs;
 *  * a selected known catalog preset still supplies the catalog kind for a
 *    NEW provider;
 *  * the synthetic credential text never enters a command or the intent JSON.
 */
class ProviderHostControllerSaveProducerTest {

    private val json = Json { ignoreUnknownKeys = false }

    private class Exchange(private val catalogPage: String) : HostBridgeExchange {
        val requests = CopyOnWriteArrayList<String>()
        private val receiptCommands = ConcurrentHashMap<String, String>()
        private val counter = AtomicInteger(0)

        override fun exchange(request: String): String {
            requests += request
            val correlation = correlationOf(request)
            val receipt = receiptOf(request)
            if (request.contains("\"operation\":\"effect.poll\"")) {
                val command = receiptCommands[receipt] ?: "unknown"
                val value = when (command) {
                    "config.providers.list" -> """{"rows":[]}"""
                    "config.models.list" -> """{"rows":[]}"""
                    "config.catalog.search" -> catalogPage
                    "config.provider.save" -> """{"saved":true}"""
                    else -> "{}"
                }
                return completedPage(correlation, receipt, value)
            }
            val command = COMMAND_PATTERN.find(request)?.groupValues?.get(1) ?: "unknown"
            val number = counter.incrementAndGet()
            val minted = "op:v1:producer$number"
            receiptCommands[minted] = command
            return """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"$minted"}"""
        }

        private fun completedPage(correlation: String, receipt: String, value: String): String =
            """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":1},"effects":[{"sequence":1,"kind":"accepted","value":$value}],"hasMore":false,"resyncRequired":false}"""

        companion object {
            val COMMAND_PATTERN = Regex("\"command\":\"([^\"]+)\"")
        }
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
            return ProviderHostControllerSaveProducerTest.ROUTE_TOKEN
        }

        override fun clear(token: String) {
            cleared.incrementAndGet()
        }
    }

    private class FakeSubmitter : HostSecureIngressSubmitter {
        val calls = AtomicInteger(0)
        @Volatile var lastIntent: String? = null
        @Volatile var lastRoute: String? = null
        @Volatile var lastBytes: ByteArray? = null

        override fun submit(intentCoreJSON: String, routeToken: String, value: ByteArray): String? {
            calls.incrementAndGet()
            lastIntent = intentCoreJSON
            lastRoute = routeToken
            lastBytes = value.copyOf()
            return ProviderHostControllerSaveProducerTest.INGRESS_TOKEN
        }
    }

    private fun host(exchange: HostBridgeExchange): RuntimeHost {
        val host = RuntimeHost(
            commandClient = RuntimeHostCommandClient(
                exchange = exchange,
                scope = CoroutineScope(Dispatchers.Default),
                ioDispatcher = Dispatchers.Default,
                budgets = HostWireBudgets(effectPollIntervalMillis = 1),
            ),
            gatewayCapability = MutableStateFlow(SecretGatewayCapability.Loading),
            bootstrapCapability = MutableStateFlow(RuntimeBootstrapCapability.Idle),
            scope = CoroutineScope(Dispatchers.Default),
            ioDispatcher = Dispatchers.Default,
        )
        // Real admission path: owned store + the REAL provider domain label.
        host.onBootstrapCapability(RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("providerConfigurationDomain", true, emptyList())
        // JVM fixture: the native Root epoch readback is injected synthetically
        // (device/native coverage lives in the instrumented suites).
        host.nativeRootEpochReader = { 31L }
        return host
    }

    private fun controller(host: RuntimeHost, route: FakeRouteAuthority, submitter: FakeSubmitter) =
        ProviderHostController(host, route).also { it.secureIngress = submitter }

    private suspend fun waitUntil(timeoutMillis: Long = 3_000, predicate: () -> Boolean) {
        val deadline = System.nanoTime() + timeoutMillis * 1_000_000L
        while (System.nanoTime() < deadline) {
            if (predicate()) return
            delay(10)
        }
        assertTrue("condition not reached", predicate())
    }

    private fun requestsFor(exchange: Exchange, command: String): List<String> =
        exchange.requests.filter { it.contains("\"command\":\"$command\"") }

    private fun envelope(raw: String): JsonObject =
        (json.parseToJsonElement(raw) as JsonObject)["envelope"] as JsonObject

    private fun draft(
        displayName: String,
        supplier: SupplierChoice?,
        modelId: String,
    ): ProviderDraftSnapshot = ProviderDraftSnapshot(
        role = ProviderServiceRoleUi.CONVERSATION,
        displayName = displayName,
        supplier = supplier,
        protocol = WireProtocolUi.OPENAI_CHAT_COMPLETIONS,
        baseUrl = "https://example.invalid/v1",
        models = listOf(ModelDraftRowUi(
            draftModelId = "manual-$modelId",
            savedModelId = null,
            remoteModelID = modelId,
            displayName = modelId,
            capabilities = emptySet(),
            selectedForSave = true,
        )),
        defaultModelDraftId = "manual-$modelId",
    )

    private fun deepseekChoice(): SupplierChoice = SupplierChoice(
        presetId = "deepseek",
        displayName = "DeepSeek",
        catalogEntryId = "deepseek",
        absoluteEndpointDefault = "https://api.deepseek.com/v1",
        routeFamily = "",
        authStyle = "bearer",
        supportsPlainHttpChoice = false,
        suggestsToolNameCompatibility = true,
    )

    @Test
    fun newCustomDraftWithoutPresetIsAdmittedThroughRealProducerAndNativeRoute() = runBlocking {
        val exchange = Exchange(CATALOG_PAGE)
        val host = host(exchange)
        val route = FakeRouteAuthority()
        val submitter = FakeSubmitter()
        val providers = controller(host, route, submitter)

        val identity = ProviderEditorIdentity("new-1", 1, ProviderServiceRoleUi.CONVERSATION)
        providers.editorOpened(identity)
        // The exact Main reproduction state: no supplier/preset chosen at all.
        val started = providers.saveProvider(
            identity,
            draft("Formal Smoke", supplier = null, modelId = "deepseek-chat"),
            SYNTHETIC_NONSECRET_KEY,
        )
        assertTrue("Save must be admitted, not throw", started)

        assertEquals(1, route.opened.get())
        assertEquals(1, submitter.calls.get())
        assertEquals(ROUTE_TOKEN, submitter.lastRoute)
        assertArrayEquals(SYNTHETIC_NONSECRET_KEY.toByteArray(), submitter.lastBytes!!)

        val intent = json.parseToJsonElement(submitter.lastIntent!!) as JsonObject
        assertEquals("providerSave", intent["subject"]!!.jsonObject["kind"]!!.jsonPrimitive.content)
        assertEquals("set", intent["intent"]!!.jsonPrimitive.content)
        val candidate = intent["candidate"]!!.jsonObject
        val providerID = candidate["id"]!!.jsonPrimitive.content
        UUID.fromString(providerID)
        assertEquals(providerID, intent["subject"]!!.jsonObject["id"]!!.jsonPrimitive.content)
        assertEquals("custom", candidate["kind"]!!.jsonPrimitive.content)
        assertFalse("no supplier means no presetID", candidate.containsKey("presetID"))
        assertTrue(candidate["createIntent"]!!.jsonPrimitive.boolean)
        val baseRevision = intent["baseRevision"]!!.jsonObject
        assertEquals("provider.$providerID", baseRevision["resourceID"]!!.jsonPrimitive.content)
        assertEquals("0", baseRevision["version"]!!.jsonPrimitive.content)
        assertEquals("deepseek-chat", candidate["selectedModels"]!!.jsonArray[0]
            .jsonObject["remoteModelID"]!!.jsonPrimitive.content)
        // The secret is never part of the frozen public candidate/intent.
        assertFalse(intent.toString().contains(SYNTHETIC_NONSECRET_KEY))

        waitUntil { requestsFor(exchange, "config.provider.save").isNotEmpty() }
        val command = envelope(requestsFor(exchange, "config.provider.save").single())
        assertEquals("config.provider.save", command["command"]!!.jsonPrimitive.content)
        assertEquals("providers",
            command["configurationScope"]!!.jsonPrimitive.content)
        assertEquals("set", command["payload"]!!.jsonObject["secretIntent"]!!.jsonPrimitive.content)
        assertEquals(INGRESS_TOKEN,
            command["payload"]!!.jsonObject["ingressToken"]!!.jsonPrimitive.content)
        // Frozen one-shot grammar: NO candidate on the public command.
        assertEquals(setOf("secretIntent", "ingressToken"), command["payload"]!!.jsonObject.keys)
        assertTrue(command["createIntent"]!!.jsonPrimitive.boolean)
        assertFalse(command.containsKey("revision"))
        assertFalse("credential must never enter a public command",
            exchange.requests.any { it.contains(SYNTHETIC_NONSECRET_KEY) })
    }

    @Test
    fun persistedProviderKindBeatsASelectedCatalogPreset() = runBlocking {
        val exchange = Exchange(CATALOG_PAGE)
        val host = host(exchange)
        val route = FakeRouteAuthority()
        val submitter = FakeSubmitter()
        val providers = controller(host, route, submitter)

        val providerID = UUID.randomUUID().toString()
        // The REAL persisted list row: kind anthropic + canonical revision.
        val page = json.parseToJsonElement(
            """{"rows":[{"id":"$providerID","kind":"anthropic",""" +
                """"wireProtocol":"openAIChatCompletions",""" +
                """"baseURL":"https://example.invalid/v1",""" +
                """"displayName":"Existing QA","region":"global","isEnabled":true,""" +
                """"allowsPlainHTTP":false,"toolNameCompatibility":"strict",""" +
                """"createdAt":"2026-10-20T00:00:00.000Z",""" +
                """"updatedAt":"2026-10-20T00:00:00.000Z","syncRevision":7,""" +
                """"secret":{"configured":true,"synchronizable":false}}]}""",
        )
        ProviderWire.decodeProviderRows(page)

        // Seed the controller's REAL preset→kind map with the ACTUAL catalog
        // page decoder. (The full refreshCatalog UI projection needs an
        // Android string resource, unrelated to this producer decision; its
        // decode contract is pinned by ProviderEditorCatalogContractTest.)
        seedCatalogKinds(providers, CATALOG_PAGE)

        val identity = ProviderEditorIdentity(
            "$providerID-conversation-1", 2, ProviderServiceRoleUi.CONVERSATION)
        providers.editorOpened(identity)
        // Keep save (no new secret) still uses the closed candidate + revision.
        assertTrue(providers.saveProvider(
            identity,
            draft("Existing QA", supplier = deepseekChoice(), modelId = "deepseek-chat"),
            credentialDraft = null,
        ))

        // No credential was supplied: the keep branch carries the candidate on
        // the public command instead of a one-shot ingress token.
        waitUntil { requestsFor(exchange, "config.provider.save").isNotEmpty() }
        val command = envelope(requestsFor(exchange, "config.provider.save").single())
        val payload = command["payload"]!!.jsonObject
        assertEquals(setOf("secretIntent", "candidate"), payload.keys)
        assertEquals("keep", payload["secretIntent"]!!.jsonPrimitive.content)
        val candidate = payload["candidate"]!!.jsonObject
        // Persisted extras win over catalogKinds["deepseek"] == "openAI".
        assertEquals("anthropic", candidate["kind"]!!.jsonPrimitive.content)
        assertEquals("deepseek", candidate["presetID"]!!.jsonPrimitive.content)
        assertEquals(providerID, candidate["id"]!!.jsonPrimitive.content)
        assertFalse(candidate["createIntent"]!!.jsonPrimitive.boolean)
        val revision = command["revision"]!!.jsonObject
        assertEquals("provider.$providerID", revision["resourceID"]!!.jsonPrimitive.content)
        assertEquals("7", revision["version"]!!.jsonPrimitive.content)
        assertFalse(command["payload"]!!.jsonObject.containsKey("ingressToken"))
    }

    @Test
    fun selectedKnownCatalogPresetSuppliesTheKindForANewProvider() = runBlocking {
        val exchange = Exchange(CATALOG_PAGE)
        val host = host(exchange)
        val route = FakeRouteAuthority()
        val submitter = FakeSubmitter()
        val providers = controller(host, route, submitter)

        seedCatalogKinds(providers, CATALOG_PAGE)

        val identity = ProviderEditorIdentity("new-2", 3, ProviderServiceRoleUi.CONVERSATION)
        providers.editorOpened(identity)
        assertTrue(providers.saveProvider(
            identity,
            draft("DeepSeek QA", supplier = deepseekChoice(), modelId = "deepseek-chat"),
            credentialDraft = null,
        ))
        waitUntil { requestsFor(exchange, "config.provider.save").isNotEmpty() }
        val command = envelope(requestsFor(exchange, "config.provider.save").single())
        val candidate = command["payload"]!!.jsonObject["candidate"]!!.jsonObject
        assertEquals("openAI", candidate["kind"]!!.jsonPrimitive.content)
        assertEquals("deepseek", candidate["presetID"]!!.jsonPrimitive.content)
        assertTrue(candidate["createIntent"]!!.jsonPrimitive.boolean)
    }

    /**
     * Fills the controller's private preset→kind map from the ACTUAL catalog
     * decoder page. Only the Android string resource of the custom-preset UI
     * label is unavailable in a pure JVM fixture; the save decision and the
     * map contents are the real production ones.
     */
    private fun seedCatalogKinds(controller: ProviderHostController, page: String) {
        val field = ProviderHostController::class.java
            .getDeclaredField("catalogKinds")
        field.isAccessible = true
        @Suppress("UNCHECKED_CAST")
        val kinds = field.get(controller) as ConcurrentHashMap<String, String>
        kinds.putAll(ProviderWire.catalogKinds(json.parseToJsonElement(page)))
    }

    private companion object {
        const val SYNTHETIC_NONSECRET_KEY = "synthetic-nonsecret-producer-key-not-real"
        const val ROUTE_TOKEN = "rt:v1:0123456789abcdef0123456789abcdef"
        const val INGRESS_TOKEN = "int:v1:fedcba9876543210fedcba9876543210"
        val CATALOG_PAGE =
            """{"rows":[{"presetID":"deepseek","name":"DeepSeek","aliases":[],""" +
                """"kind":"openAI","defaultProtocol":"openai-chat-completions",""" +
                """"baseURL":"https://api.deepseek.com/v1",""" +
                """"domains":["api.deepseek.com"],"models":["deepseek-chat"],""" +
                """"availability":"available","upstreamID":"deepseek",""" +
                """"authStyle":"bearer","toolNameCompatibility":true,""" +
                """"serviceOffers":[]}]}"""
    }
}
