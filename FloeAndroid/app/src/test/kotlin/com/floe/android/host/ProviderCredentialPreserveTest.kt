// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.RuntimeBootstrapCapability
import com.floe.android.SecretGatewayCapability
import com.floe.android.feature.providers.ModelDraftRowUi
import com.floe.android.feature.providers.ProviderDraftSnapshot
import com.floe.android.feature.providers.ProviderEditorIdentity
import com.floe.android.feature.providers.ProviderServiceRoleUi
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
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Existing-provider credential intent and frozen editor-baseline regressions. */
class ProviderCredentialPreserveTest {

    private val json = Json { ignoreUnknownKeys = false }

    /** The REAL native projection casing: Swift `uuidString` is UPPERCASE. */
    private val providerID: String = UUID.randomUUID().toString().uppercase()
    private val modelID: String = UUID.randomUUID().toString().uppercase()

    private fun providerRow(syncRevision: Int): String =
        """{"id":"$providerID","kind":"openAI",""" +
            """"wireProtocol":"openAIChatCompletions",""" +
            """"baseURL":"http://127.0.0.1:55388/v1",""" +
            """"displayName":"LocalFixture","region":null,"isEnabled":true,""" +
            """"allowsPlainHTTP":true,"toolNameCompatibility":false,""" +
            """"createdAt":"2026-10-23T09:43:00.000Z",""" +
            """"updatedAt":"2026-10-23T09:43:00.000Z","syncRevision":$syncRevision,""" +
            """"secret":{"configured":true,"opaqueReference":"ref:v1:aa",""" +
            """"synchronizable":false},"presetID":null,"nonSecretHeaders":{}}"""

    private val modelRow: String
        get() = """{"id":"$modelID","providerID":"$providerID",""" +
            """"remoteModelID":"kept-model","displayName":"Kept Model",""" +
            """"limits":{"contextTokens":4096,"maxOutputTokens":1024},""" +
            """"capabilities":5,"reasoningEffort":null,"isEnabled":true,""" +
            """"isHiddenFromPrimaryPicker":false,""" +
            """"revision":{"resourceID":"model.$modelID","version":"d1"}}"""

    private class Exchange : HostBridgeExchange {
        @Volatile var providerRows: String = ""
        var modelRows: String = ""
        val commands = CopyOnWriteArrayList<String>()
        val requests = CopyOnWriteArrayList<String>()
        val saveEnvelopes = CopyOnWriteArrayList<String>()
        private val receiptKinds = ConcurrentHashMap<String, String>()
        private val receiptValues = ConcurrentHashMap<String, String>()
        private val receiptSequence = AtomicInteger(0)

        override fun exchange(request: String): String {
            requests.add(request)
            val correlation = correlationOf(request)
            if (request.contains("\"operation\":\"effect.poll\"")) {
                val receipt = receiptOf(request)
                val value = receiptValues[receipt]
                return if (value != null) completedPage(correlation, receipt, value)
                else emptyPage(correlation, receipt)
            }
            val command = when {
                request.contains("\"command\":\"config.providers.list\"") -> "plist"
                request.contains("\"command\":\"config.models.list\"") -> "models"
                request.contains("\"command\":\"config.preferences.get\"") -> "prefs"
                request.contains("\"command\":\"config.catalog.search\"") -> "catalog"
                request.contains("\"command\":\"config.provider.save\"") -> "save"
                else -> return """{"version":3,"ok":false,"correlationID":"$correlation","error":"invalidEnvelope","reason":"unscripted"}"""
            }
            commands.add(command)
            val value = when (command) {
                "plist" -> """{"rows":[${providerRows.ifEmpty { "null" }}]}"""
                    .replace("[null]", "[]")
                "models" -> """{"rows":[${modelRows.ifEmpty { "null" }}]}"""
                    .replace("[null]", "[]")
                "prefs" -> """{"preferences":{"defaultAgentModelID":null},""" +
                    """"revision":{"resourceID":"settings.model-preferences","version":"r1"}}"""
                "catalog" -> """{"rows":[]}"""
                else -> {
                    saveEnvelopes.add(request)
                    """{"state":"completed","value":{"state":"committed"}}"""
                }
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
        override fun open(
            kind: HostEditorKind,
            editorID: String,
            uiGeneration: Long,
            expectedNativeRootEpoch: Long,
        ): String? = ROUTE_TOKEN

        override fun clear(token: String) = Unit
    }

    private class FakeSubmitter : HostSecureIngressSubmitter {
        val calls = AtomicInteger(0)
        @Volatile var lastIntent: String? = null

        override fun submit(intentCoreJSON: String, routeToken: String, value: ByteArray): String? {
            calls.incrementAndGet()
            lastIntent = intentCoreJSON
            return INGRESS_TOKEN
        }
    }

    private class Fixture(val exchange: Exchange, val host: RuntimeHost, val submitter: FakeSubmitter)

    private fun fixture(): Fixture {
        val exchange = Exchange()
        exchange.providerRows = providerRow(7)
        exchange.modelRows = modelRow
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
        host.providers.routeAuthority = FakeRouteAuthority()
        val submitter = FakeSubmitter()
        host.providers.secureIngress = submitter
        return Fixture(exchange, host, submitter)
    }

    /** The REAL page flow: the list page publishes rows (remembering their
     * revisions) and the model projection lands before an editor may seed. */
    private suspend fun load(f: Fixture) {
        f.host.providers.refreshProviders()
        waitUntil {
            f.host.providers.destination.value.list.conversationProviders
                .any { it.providerId == providerID }
        }
        waitUntil { f.host.conversations.modelsProjectionReadyForEditing() }
    }

    private fun identity(suffix: String) = ProviderEditorIdentity(
        editorId = "$providerID-$suffix",
        epoch = 1,
        role = ProviderServiceRoleUi.CONVERSATION,
    )

    private fun draft(modelRemoteID: String): ProviderDraftSnapshot = ProviderDraftSnapshot(
        role = ProviderServiceRoleUi.CONVERSATION,
        displayName = "LocalFixture",
        supplier = null,
        protocol = WireProtocolUi.OPENAI_CHAT_COMPLETIONS,
        baseUrl = "http://127.0.0.1:55388/v1",
        nonSecretHeaders = "",
        allowsPlainHttp = true,
        models = listOf(ModelDraftRowUi(
            draftModelId = "manual-$modelRemoteID",
            savedModelId = null,
            remoteModelID = modelRemoteID,
            displayName = modelRemoteID,
            capabilities = emptySet(),
            selectedForSave = true,
        )),
        defaultModelDraftId = null,
    )

    private suspend fun waitUntil(timeoutMillis: Long = 3_000, predicate: () -> Boolean) {
        val deadline = System.nanoTime() + timeoutMillis * 1_000_000L
        while (System.nanoTime() < deadline) {
            if (predicate()) return
            delay(10)
        }
        assertTrue("condition not reached", predicate())
    }

    private fun envelopeOf(raw: String): JsonObject {
        val root = json.parseToJsonElement(raw) as JsonObject
        return root["envelope"]?.jsonObject ?: root
    }

    // ------------------------------------------------------------------ 1

    @Test
    fun revisionMemoryMatchesAcrossNativeUppercaseAndEditorLowercaseCasing() {
        val id = UUID.randomUUID().toString().uppercase()
        val revision = HostRevision("provider.$id", "7")
        ProviderHostControllerRevisions.remember(id, revision)
        // The editor resolves the identity through java.util.UUID: lowercase.
        assertEquals(
            "the remembered revision must be found regardless of the reader's casing",
            revision,
            ProviderHostControllerRevisions.revision(id.lowercase()),
        )
    }

    // ------------------------------------------------------------------ 2

    @Test
    fun intentBranchMatrixKeepsReplacesAndCreatesStayIsolated() {
        val baseline = HostRevision("provider.X", "7")
        // Untouched credential on an existing provider: KEEP, never clear.
        assertEquals(
            ProviderSaveIntentBranch.KEEP_EXISTING,
            providerSaveIntentBranch(isExistingProvider = true, baseline, credentialDraft = null),
        )
        // Typed credential: SET (explicit replacement).
        assertEquals(
            ProviderSaveIntentBranch.SET_EXISTING,
            providerSaveIntentBranch(isExistingProvider = true, baseline, "typed"),
        )
        // Existing provider without an observed baseline: fail-closed refuse.
        assertEquals(
            ProviderSaveIntentBranch.REFUSE_MISSING_BASELINE,
            providerSaveIntentBranch(isExistingProvider = true, null, credentialDraft = null),
        )
        assertEquals(
            ProviderSaveIntentBranch.REFUSE_MISSING_BASELINE,
            providerSaveIntentBranch(isExistingProvider = true, null, "typed"),
        )
        // Only a genuinely new provider may take the typed create paths.
        assertEquals(
            ProviderSaveIntentBranch.SET_CREATE,
            providerSaveIntentBranch(isExistingProvider = false, null, "typed"),
        )
        assertEquals(
            ProviderSaveIntentBranch.CREATE_WITHOUT_SECRET,
            providerSaveIntentBranch(isExistingProvider = false, null, credentialDraft = null),
        )
    }

    // ------------------------------------------------------------------ 3

    @Test
    fun untouchedCredentialSaveOfExistingProviderIsKeepWithSeededRevision() = runBlocking {
        // The defect reproduced with REAL native casing: reopen the stored
        // provider, touch nothing in the credential field, Save. Before the
        // repair this dispatched secretIntent:"clear" + createIntent (which
        // the native clear chain committed as reference loss).
        val f = fixture()
        load(f)
        val id = identity("conversation-1")
        f.host.providers.editorOpened(id)
        assertTrue(f.host.providers.saveProvider(id, draft("fixture-model-0001"), credentialDraft = null))

        waitUntil { f.exchange.saveEnvelopes.isNotEmpty() }
        val command = envelopeOf(f.exchange.saveEnvelopes.single())
        val payload = command["payload"]!!.jsonObject
        assertEquals(setOf("secretIntent", "candidate"), payload.keys)
        assertEquals("keep", payload["secretIntent"]!!.jsonPrimitive.content)
        val candidate = payload["candidate"]!!.jsonObject
        assertFalse(candidate["createIntent"]!!.jsonPrimitive.boolean)
        assertEquals("openAI", candidate["kind"]!!.jsonPrimitive.content)
        val revision = command["revision"]!!.jsonObject
        assertEquals("provider.$providerID", revision["resourceID"]!!.jsonPrimitive.content)
        assertEquals("7", revision["version"]!!.jsonPrimitive.content)
        assertFalse(payload.containsKey("ingressToken"))
        assertEquals("an untouched credential must not consume ingress", 0, f.submitter.calls.get())
        assertFalse(f.exchange.requests.any { it.contains("\"clear\"") })
    }

    // ------------------------------------------------------------------ 4

    @Test
    fun typedCredentialOnExistingProviderBindsPersistedBaselineNotCreateMarker() = runBlocking {
        // Explicit replacement: the one-shot lease must freeze the ACTUAL
        // persisted baseline — never the "0" expected-absent create marker
        // (which every live row then correctly refused with staleRevision).
        val f = fixture()
        load(f)
        val id = identity("conversation-2")
        f.host.providers.editorOpened(id)
        assertTrue(f.host.providers.saveProvider(id, draft("fixture-model-0001"), SYNTHETIC_NONSECRET_KEY))

        waitUntil { f.submitter.calls.get() > 0 }
        val intent = json.parseToJsonElement(f.submitter.lastIntent!!) as JsonObject
        val baseRevision = intent["baseRevision"]!!.jsonObject
        assertEquals("provider.$providerID", baseRevision["resourceID"]!!.jsonPrimitive.content)
        assertEquals("7", baseRevision["version"]!!.jsonPrimitive.content)

        waitUntil { f.exchange.saveEnvelopes.isNotEmpty() }
        val command = envelopeOf(f.exchange.saveEnvelopes.single())
        val payload = command["payload"]!!.jsonObject
        assertEquals(setOf("secretIntent", "ingressToken"), payload.keys)
        assertEquals("set", payload["secretIntent"]!!.jsonPrimitive.content)
        assertEquals(INGRESS_TOKEN, payload["ingressToken"]!!.jsonPrimitive.content)
        assertEquals("7", command["revision"]!!.jsonObject["version"]!!.jsonPrimitive.content)
        assertFalse(f.exchange.requests.any { it.contains(SYNTHETIC_NONSECRET_KEY) })
    }

    // ------------------------------------------------------------------ 5

    @Test
    fun frozenDraftKeepsSeededBaselineAfterExternalAdvance() = runBlocking {
        // Provider editing is a FROZEN DRAFT: a list refresh that lands
        // after seeding must NOT be adopted by the open editor; the Save
        // still presents the seeded token so the native durable CAS keeps
        // its staleRevision refusal for concurrent/foreign changes.
        val f = fixture()
        load(f)
        val id = identity("conversation-3")
        f.host.providers.editorOpened(id)

        // External writer advances the row; a real refresh re-publishes.
        f.exchange.providerRows = providerRow(9)
        val plistBefore = f.exchange.commands.count { it == "plist" }
        f.host.providers.refreshProviders()
        waitUntil { f.exchange.commands.count { it == "plist" } > plistBefore }

        assertTrue(f.host.providers.saveProvider(id, draft("fixture-model-0001"), credentialDraft = null))
        waitUntil { f.exchange.saveEnvelopes.isNotEmpty() }
        val command = envelopeOf(f.exchange.saveEnvelopes.single())
        val revision = command["revision"]!!.jsonObject
        assertEquals("provider.$providerID", revision["resourceID"]!!.jsonPrimitive.content)
        assertEquals(
            "the editor presents the baseline it was seeded with, never the newer live value",
            "7",
            revision["version"]!!.jsonPrimitive.content,
        )
    }

    // ------------------------------------------------------------------ 6

    @Test
    fun existingEditorWithoutObservedBaselineRefusesBeforeAnyEffect() = runBlocking {
        // Fail-closed: an existing-identity editor that never observed the
        // row's revision must NOT degrade into create/clear, must NOT
        // consume an ingress token and must NOT dispatch any command; the
        // typed credential stays available for a re-seeded retry.
        val unseededID = UUID.randomUUID().toString().uppercase()
        val f = fixture()
        val id = ProviderEditorIdentity(
            editorId = "$unseededID-conversation-9",
            epoch = 1,
            role = ProviderServiceRoleUi.CONVERSATION,
        )
        f.host.providers.editorOpened(id)
        assertTrue(f.host.providers.saveProvider(id, draft("fixture-model-0001"), SYNTHETIC_NONSECRET_KEY))

        waitUntil {
            f.host.providers.destination.value.editor?.let { e ->
                e.identity.editorId == id.editorId && e.saveError != null
            } == true
        }
        val editor = f.host.providers.destination.value.editor!!
        assertEquals("Reopen these settings and try again.", editor.saveError)
        assertEquals(0, f.submitter.calls.get())
        assertTrue(f.exchange.saveEnvelopes.isEmpty())
    }

    // ------------------------------------------------------------------ 7

    @Test
    fun holderFirstSeedPairsTheBaselineAcrossAnInterleavedRefresh() = runBlocking {
        // The exact callgraph race: the holder builds the FIRST seed (and
        // drafts.open consumes it) BEFORE host.editorOpened runs. A list
        // refresh that lands in between must not re-pair the newer revision
        // with the older draft: the seed-aware open binds from the FIRST
        // seed object, so Save still presents 7 (and the native durable CAS
        // keeps the refusal authority over the live row at 9).
        val f = fixture()
        load(f)
        val seed = f.host.providers.seedEditorFor(
            ProviderServiceRoleUi.CONVERSATION, providerID,
        )
        assertNotNull(seed)
        assertEquals("7", seed!!.providerRevisionVersion)

        // The refresh lands AFTER the seed but BEFORE editorOpened.
        f.exchange.providerRows = providerRow(9)
        val plistBefore = f.exchange.commands.count { it == "plist" }
        f.host.providers.refreshProviders()
        waitUntil { f.exchange.commands.count { it == "plist" } > plistBefore }

        val id = identity("conversation-4")
        f.host.providers.editorOpened(id, seed)
        assertTrue(f.host.providers.saveProvider(id, draft("fixture-model-0001"), credentialDraft = null))
        waitUntil { f.exchange.saveEnvelopes.isNotEmpty() }
        val command = envelopeOf(f.exchange.saveEnvelopes.single())
        val revision = command["revision"]!!.jsonObject
        assertEquals(
            "the baseline pairs the holder's FIRST seed, never the interleaved refresh",
            "7",
            revision["version"]!!.jsonPrimitive.content,
        )
    }


    @Test
    fun explicitSeedWithoutRevisionCannotBorrowTheLiveCache() = runBlocking {
        val f = fixture()
        load(f)
        val seeded = requireNotNull(f.host.providers.seedEditorFor(
            ProviderServiceRoleUi.CONVERSATION, providerID,
        ))
        assertEquals("7", seeded.providerRevisionVersion)
        // The cache contains a valid token; the explicit draft did not see it.
        val id = identity("conversation-explicit-unbound")
        f.host.providers.editorOpened(id, seeded.copy(providerRevisionVersion = null))
        assertTrue(f.host.providers.saveProvider(id, draft("fixture-model-0001"), SYNTHETIC_NONSECRET_KEY))
        waitUntil { f.host.providers.destination.value.editor?.saveError != null }
        assertEquals("Reopen these settings and try again.", f.host.providers.destination.value.editor?.saveError)
        assertEquals(0, f.submitter.calls.get())
        assertTrue(f.exchange.saveEnvelopes.isEmpty())
    }

    private companion object {
        const val SYNTHETIC_NONSECRET_KEY = "synthetic-nonsecret-preserve-key-not-real"
        const val ROUTE_TOKEN = "rt:v1:0123456789abcdef0123456789abcdef"
        const val INGRESS_TOKEN = "int:v1:fedcba9876543210fedcba9876543210"
    }
}
