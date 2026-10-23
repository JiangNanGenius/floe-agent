// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.RuntimeBootstrapCapability
import com.floe.android.SecretGatewayCapability
import com.floe.android.feature.providers.ModelCapabilityUi
import com.floe.android.feature.providers.ModelDraftRowUi
import com.floe.android.feature.providers.ProviderEditorIdentity
import com.floe.android.feature.providers.ProviderDraftSnapshot
import com.floe.android.feature.providers.ProviderServiceRoleUi
import com.floe.android.feature.providers.SaveFailurePhaseUi
import com.floe.android.feature.providers.SaveOutcomeUi
import com.floe.android.feature.providers.WireProtocolUi
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * job-2e38 — large provider profiles + compact metadata source (App side).
 * AUTHORED ONLY: NOT compiled, NOT executed by this batch (Main runs the
 * composed batch against the real toolchain). Synthetic host/exchange
 * fixtures only — the same harness class as ProviderConfigurationCompletionTest.
 *
 * Proven behavior:
 *  1. the list toggle issues the CLOSED existing-row metadata keep
 *     ({secretIntent:"keep",metadata:{id,isEnabled}}) under the ACTUAL
 *     persisted revision — never a full-candidate reconstruction, so a
 *     valid large profile toggles with no byte-bound refusal; a typed
 *     native refusal keeps the switch on the persisted truth with an
 *     actionable message (never an optimistic flip);
 *  2. a >16,384-byte draft stages its COMPLETE selected-model body
 *     through the trusted-host seam (ordered chunks within the proven
 *     single-model payload class) and the save candidate carries ONLY the
 *     frozen reference (mutually exclusive with inline selectedModels);
 *     the staged rows equal the inline codec output in order;
 *  3. the Set lease core carries the same small staged candidate inside
 *     the frozen 16,384-byte vault intent bound (models NOT dropped);
 *  4. staging refusal fails preflight honestly: no save command, no
 *     optimistic editor state;
 *  5. retry re-staging cancels the previous un-consumed stage first, and
 *     editor close cancels the tracked stage (un-consumed only — an
 *     accepted save owns its typed values natively);
 *  6. the role picker reads each enabled provider through the ACTUAL
 *     provider-filtered continuation, reaching the 401st…512th model of a
 *     valid large profile (the old 400-row guard's accidental tail
 *     refusal), refuses a beyond-supported provider typed, and never
 *     publishes a partial candidate mix.
 */
class ProviderLargeProfileTest {

    private val json = Json { ignoreUnknownKeys = true }

    private companion object {
        const val PROVIDER_ID = "11111111-1111-1111-1111-111111111111"
        const val ROUTE_TOKEN = "rt:v1:0123456789abcdef0123456789abcdef"
        const val FROZEN_REF =
            "ms:v1:0000000000000000000000000000abcd." +
            "000000000000000000000000000000000000000000000000000000000000dcba"

        val PROVIDER_ROW = """
            {"id":"$PROVIDER_ID","kind":"openAI","wireProtocol":"openai-chat-completions",
             "baseURL":"https://api.example.invalid/v1","displayName":"Persisted",
             "region":null,"isEnabled":false,"allowsPlainHTTP":false,
             "toolNameCompatibility":false,"createdAt":"2026-10-20T00:00:00.000Z",
             "updatedAt":"2026-10-20T00:00:00.000Z","syncRevision":3,
             "secret":{"configured":true,"opaqueReference":"ref:v1:aa","synchronizable":false}}
        """.trimIndent()
    }

    // ------------------------------------------------------------- fakes

    private class Exchange : HostBridgeExchange {
        var providerRow: String = PROVIDER_ROW
        /** "committed" | "stale" | "rejected" */
        var saveOutcome: String = "committed"
        val commands = CopyOnWriteArrayList<String>()
        val saveEnvelopes = CopyOnWriteArrayList<String>()
        val providerPageReads = CopyOnWriteArrayList<String>()
        val roleModelPageReads = CopyOnWriteArrayList<String>()
        /** (providerID, cursor) -> page JSON for the role models read. */
        var modelsResponder: ((providerID: String?, cursor: String?) -> String)? = null
        var providersPage: String? = null
        var preferencesDoc: String? = null
        private val receiptKinds = java.util.concurrent.ConcurrentHashMap<String, String>()
        private val receiptValues = java.util.concurrent.ConcurrentHashMap<String, String>()
        private val receiptFailures = java.util.concurrent.ConcurrentHashMap<String, String>()
        private val receiptSequence = AtomicInteger(0)

        override fun exchange(request: String): String {
            val correlation = correlationOf(request)
            if (request.contains("\"operation\":\"effect.poll\"")) {
                val receipt = receiptOf(request)
                val kind = receiptKinds[receipt] ?: return emptyPage(correlation, receipt)
                val failure = receiptFailures[receipt]
                if (failure != null) return rejectedPage(correlation, receipt, failure)
                val value = receiptValues[receipt]
                return if (value != null) {
                    completedPage(correlation, receipt, value)
                } else {
                    emptyPage(correlation, receipt)
                }
            }
            val payload = payloadOf(request)
            val command = when {
                request.contains("\"command\":\"config.providers.list\"") -> "plist"
                request.contains("\"command\":\"config.models.list\"") -> "models"
                request.contains("\"command\":\"config.preferences.get\"") -> "prefs"
                request.contains("\"command\":\"config.catalog.search\"") -> "catalog"
                request.contains("\"command\":\"config.provider.save\"") -> "save"
                else -> return error(correlation, "unscripted")
            }
            commands.add(command)
            if (command == "plist" && correlation.startsWith("plist-")) providerPageReads.add(request)
            if (command == "models" && correlation.startsWith("rolesmlist-")) roleModelPageReads.add(request)
            val number = receiptSequence.incrementAndGet()
            val receipt = "op:v1:$command$number"
            receiptKinds[receipt] = command
            if (command == "save") {
                saveEnvelopes.add(request)
                when (saveOutcome) {
                    "committed" -> receiptValues[receipt] =
                        """{"state":"completed","value":{"state":"committed","providerID":"$PROVIDER_ID"}}"""
                    "stale" -> receiptFailures[receipt] = "staleRevision"
                    else -> receiptFailures[receipt] = "invalidEnvelope"
                }
                return queued(correlation, receipt)
            }
            val value = when (command) {
                "plist" -> providersPage ?: """{"rows":[$providerRow]}"""
                "models" -> {
                    val providerID = payload?.stringOf("providerID")
                    val cursor = payload?.stringOf("cursor")
                    modelsResponder?.invoke(providerID, cursor) ?: """{"rows":[],"hasMore":false}"""
                }
                "prefs" -> preferencesDoc ?: """{"preferences":{},"revision":{"resourceID":"preferences","version":"7"}}"""
                else -> """{"rows":[]}"""
            }
            receiptValues[receipt] = value
            return queued(correlation, receipt)
        }

        private fun error(correlation: String, reason: String) =
            """{"version":3,"requestID":"$correlation","ok":false,"error":"$reason"}"""

        private fun queued(correlation: String, receipt: String) =
            """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"$receipt"}"""

        private fun completedPage(correlation: String, receipt: String, value: String) =
            """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":1},"effects":[{"sequence":1,"kind":"accepted","value":$value}],"hasMore":false,"resyncRequired":false}"""

        private fun rejectedPage(correlation: String, receipt: String, code: String) =
            """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":1},"effects":[{"sequence":1,"kind":"rejected","code":"$code","detail":[{"key":"reason","value":"typed"}]}],"hasMore":false,"resyncRequired":false}"""

        private fun emptyPage(correlation: String, receipt: String) =
            """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":0},"effects":[],"hasMore":true,"resyncRequired":false}"""

        private fun payloadOf(request: String): JsonObject? = runCatching {
            val root = Json.parseToJsonElement(request) as JsonObject
            (root["envelope"]?.jsonObject ?: root)["payload"] as? JsonObject
        }.getOrNull()

        private fun JsonObject.stringOf(key: String): String? =
            (this[key] as? JsonPrimitive)?.contentOrNull
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

    private class FakeSecureIngress : HostSecureIngressSubmitter {
        val cores = CopyOnWriteArrayList<String>()
        override fun submit(intentCoreJSON: String, routeToken: String, value: ByteArray): String {
            cores.add(intentCoreJSON)
            return "int:v1:0123456789abcdef0123456789abcdef"
        }
    }

    private class FakeStager(
        var beginResult: String? = "msb:v1:" + "a".repeat(32),
        var sealResult: String? = FROZEN_REF,
        var failAppend: Boolean = false,
    ) : HostModelSetStager {
        class Begin(
            val providerID: String,
            val baseResourceID: String,
            val baseVersion: String,
            val createIntent: Boolean,
            val routeToken: String,
        )
        val begins = CopyOnWriteArrayList<Begin>()
        val chunks = CopyOnWriteArrayList<Pair<Int, String>>()
        val sealCounts = CopyOnWriteArrayList<Int>()
        val cancels = CopyOnWriteArrayList<String>()

        override fun begin(
            providerID: String,
            baseResourceID: String,
            baseVersion: String,
            createIntent: Boolean,
            routeToken: String,
        ): String? {
            begins.add(Begin(providerID, baseResourceID, baseVersion, createIntent, routeToken))
            return beginResult
        }

        override fun append(
            stageID: String,
            index: Int,
            chunk: ByteArray,
            routeToken: String,
        ): Boolean {
            if (failAppend) return false
            chunks.add(index to chunk.decodeToString())
            return true
        }

        override fun seal(stageID: String, expectedCount: Int, routeToken: String): String? {
            sealCounts.add(expectedCount)
            return sealResult
        }

        override fun cancel(stageID: String, routeToken: String): Boolean {
            cancels.add(stageID)
            return true
        }
    }

    private fun host(exchange: HostBridgeExchange): RuntimeHost {
        val created = RuntimeHost(
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
        created.onBootstrapCapability(RuntimeBootstrapCapability.OwnedStoreReady)
        created.nativeRootEpochReader = { 7L }
        created.providers.routeAuthority = FakeRouteAuthority()
        return created
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
        waitUntil {
            host.providers.destination.value.list.conversationProviders
                .any { it.providerId == PROVIDER_ID }
        }
    }

    private fun existingIdentity() = ProviderEditorIdentity(
        editorId = "$PROVIDER_ID-conversation-1", epoch = 1,
        role = ProviderServiceRoleUi.CONVERSATION,
    )

    private fun envelopeOf(raw: String): JsonObject {
        val root = json.parseToJsonElement(raw) as JsonObject
        return root["envelope"]?.jsonObject ?: root
    }

    private fun payloadOf(raw: String): JsonObject =
        envelopeOf(raw)["payload"]!!.jsonObject

    private fun largeDraft(count: Int) = ProviderDraftSnapshot(
        role = ProviderServiceRoleUi.CONVERSATION,
        enabled = true,
        displayName = "Large Profile",
        protocol = WireProtocolUi.OPENAI_CHAT_COMPLETIONS,
        baseUrl = "https://api.example.invalid/v1",
        models = List(count) { index ->
            ModelDraftRowUi(
                draftModelId = "draft-$index",
                savedModelId = null,
                remoteModelID = "remote-$index",
                displayName = "Model $index",
                enabled = true,
                capabilities = setOf(
                    ModelCapabilityUi.TEXT, ModelCapabilityUi.TOOLS,
                ),
                contextTokens = 4096,
                maxOutputTokens = 1024,
                selectedForSave = true,
            )
        },
    )

    // ---------------------------------------------------------------- 1

    @Test
    fun toggleIssuesClosedCompactMetadataKeepNoCandidateNoReconstruction() = runBlocking {
        val exchange = Exchange()
        val h = host(exchange)
        load(h)
        val plistBefore = exchange.providerPageReads.size
        assertTrue(h.providers.setProviderEnabled(PROVIDER_ID, true))
        waitUntil { exchange.saveEnvelopes.isNotEmpty() }
        val payload = payloadOf(exchange.saveEnvelopes.last())
        assertEquals("keep", (payload["secretIntent"] as? JsonPrimitive)?.contentOrNull)
        val metadata = payload["metadata"]?.jsonObject
        assertNotNull("compact metadata variant must be issued", metadata)
        assertEquals(PROVIDER_ID, (metadata!!["id"] as? JsonPrimitive)?.contentOrNull)
        assertEquals(true, (metadata["isEnabled"] as? JsonPrimitive)?.booleanOrNull)
        assertNull("metadata form must not smuggle a candidate", payload["candidate"])
        assertNull(payload["ingressToken"])
        val revision = envelopeOf(exchange.saveEnvelopes.last())["revision"]?.jsonObject
        assertEquals("provider.$PROVIDER_ID",
            (revision!!["resourceID"] as? JsonPrimitive)?.contentOrNull)
        assertEquals("3", (revision["version"] as? JsonPrimitive)?.contentOrNull)
        // The refreshed list (never an optimistic flip) owns the surface.
        // Capture before the action: its refresh can settle before payload assertions.
        waitUntil { exchange.providerPageReads.size > plistBefore }
    }

    @Test
    fun toggleTypedRefusalShowsHonestFailureAndKeepsPersistedTruth() = runBlocking {
        val exchange = Exchange()
        exchange.saveOutcome = "stale"
        val h = host(exchange)
        load(h)
        assertTrue(h.providers.setProviderEnabled(PROVIDER_ID, true))
        waitUntil {
            h.providers.destination.value.list.errorMessage != null
        }
        // No fabricated success: after the refresh the row still carries
        // the persisted enabled state (the refreshed page is the truth).
        val row = h.providers.destination.value.list.conversationProviders
            .first { it.providerId == PROVIDER_ID }
        assertEquals(false, row.enabled)
    }

    // ---------------------------------------------------------------- 2

    @Test
    fun largeDraftSaveStagesCompleteBodyAndSendsOnlyFrozenRef() = runBlocking {
        val exchange = Exchange()
        val h = host(exchange)
        load(h)
        val stager = FakeStager()
        h.providers.modelSets = ProviderModelSetStagingController(stager)
        val identity = existingIdentity()
        h.providers.editorOpened(identity)
        val draft = largeDraft(300)
        assertTrue(h.providers.saveProvider(identity, draft, credentialDraft = null))
        waitUntil { exchange.saveEnvelopes.isNotEmpty() }
        // Bindings: actual provider id + actual persisted revision + route.
        val begin = stager.begins.first()
        assertEquals(PROVIDER_ID, begin.providerID)
        assertEquals("provider.$PROVIDER_ID", begin.baseResourceID)
        assertEquals("3", begin.baseVersion)
        assertEquals(false, begin.createIntent)
        assertEquals(ROUTE_TOKEN, begin.routeToken)
        // The staged chunks are the COMPLETE body, in order, same codec:
        // flatten and compare remote ids 0..299.
        val stagedRemotes = stager.chunks.sortedBy { it.first }
            .flatMap { (_, text) ->
                (json.parseToJsonElement(text) as JsonArray).map {
                    (it.jsonObject["remoteModelID"] as JsonPrimitive).contentOrNull!!
                }
            }
        assertEquals(List(300) { "remote-$it" }, stagedRemotes)
        assertEquals(300, stager.sealCounts.last())
        // Candidate: frozen ref only, inline models absent, bound respected.
        val payload = payloadOf(exchange.saveEnvelopes.last())
        assertEquals("keep", (payload["secretIntent"] as? JsonPrimitive)?.contentOrNull)
        val candidate = payload["candidate"]!!.jsonObject
        assertEquals(FROZEN_REF, (candidate["modelSetRef"] as? JsonPrimitive)?.contentOrNull)
        assertNull("mixed model forms must never be submitted", candidate["selectedModels"])
        assertTrue(candidate.toString().encodeToByteArray().size <= 16_384)
        // Scalars preserved from the SAME builder (no reconstruction drift).
        assertEquals("Large Profile", (candidate["displayName"] as? JsonPrimitive)?.contentOrNull)
        assertEquals("openAI", (candidate["kind"] as? JsonPrimitive)?.contentOrNull)
    }

    // ---------------------------------------------------------------- 3

    @Test
    fun stagedSetLeaseCoreCarriesRefInsideTheVaultBound() = runBlocking {
        val exchange = Exchange()
        val h = host(exchange)
        load(h)
        val stager = FakeStager()
        h.providers.modelSets = ProviderModelSetStagingController(stager)
        val ingress = FakeSecureIngress()
        h.providers.secureIngress = ingress
        val identity = existingIdentity()
        h.providers.editorOpened(identity)
        assertTrue(h.providers.saveProvider(identity, largeDraft(300),
            credentialDraft = "sk-synthetic-notreal"))
        waitUntil { ingress.cores.isNotEmpty() && exchange.saveEnvelopes.isNotEmpty() }
        val core = json.parseToJsonElement(ingress.cores.last()) as JsonObject
        val candidate = core["candidate"]!!.jsonObject
        assertEquals(FROZEN_REF, (candidate["modelSetRef"] as? JsonPrimitive)?.contentOrNull)
        assertNull(candidate["selectedModels"])
        assertTrue("the vault intent bound is 16,384 bytes",
            ingress.cores.last().encodeToByteArray().size <= 16_384)
        // The public command carries ONLY the one-shot token (frozen grammar).
        val payload = payloadOf(exchange.saveEnvelopes.last())
        assertEquals("set", (payload["secretIntent"] as? JsonPrimitive)?.contentOrNull)
        assertNotNull(payload["ingressToken"])
        assertNull(payload["candidate"])
    }

    // ---------------------------------------------------------------- 4

    @Test
    fun stagingRefusalFailsPreflightWithoutAnySaveCommand() = runBlocking {
        val exchange = Exchange()
        val h = host(exchange)
        load(h)
        h.providers.modelSets = ProviderModelSetStagingController(FakeStager(beginResult = null))
        val identity = existingIdentity()
        h.providers.editorOpened(identity)
        assertTrue(h.providers.saveProvider(identity, largeDraft(300), credentialDraft = null))
        // No save command was ever submitted; the editor reports the typed
        // preflight failure (honest copy, no optimistic success, no partial).
        delay(150)
        assertEquals(0, exchange.commands.count { it == "save" })
        val editor = h.providers.destination.value.editor
        assertNotNull(editor)
        val outcome = editor!!.saveOutcome
        assertTrue("expected Failed(PREFLIGHT), got $outcome",
            outcome is SaveOutcomeUi.Failed && outcome.phase == SaveFailurePhaseUi.PREFLIGHT)
        assertNotNull(editor.saveError)
    }

    // ---------------------------------------------------------------- 5

    @Test
    fun legalFinalTwoSingleModelBytesKeepExactOrderWithoutRaisingChunkBound() {
        for (targetBytes in listOf(61_439, 61_440)) {
            val empty = JsonObject(mapOf("displayName" to JsonPrimitive("")))
            val row = JsonObject(mapOf("displayName" to JsonPrimitive(
                "x".repeat(targetBytes - empty.toString().encodeToByteArray().size))))
            assertEquals(targetBytes, row.toString().encodeToByteArray().size)
            val prefix = JsonObject(mapOf("displayName" to JsonPrimitive("before")))
            val suffix = JsonObject(mapOf("displayName" to JsonPrimitive("after")))
            val rows = listOf(prefix, row, suffix)
            val stager = FakeStager()
            val controller = ProviderModelSetStagingController(stager)
            val staged = controller.stage("edge-editor", PROVIDER_ID,
                "provider.$PROVIDER_ID", "3", false, ROUTE_TOKEN, rows)
            assertTrue(staged is StagedModelSet.Frozen)
            assertEquals(listOf(0, 1, 2), stager.chunks.map { it.first })
            assertTrue(stager.chunks.all { it.second.encodeToByteArray().size <= 61_440 })
            val decoded = stager.chunks.flatMap { (_, encoded) ->
                when (val chunk = Json.parseToJsonElement(encoded)) {
                    is JsonArray -> chunk.map { it.jsonObject }
                    is JsonObject -> listOf(chunk)
                    else -> throw AssertionError("invalid trusted chunk")
                }
            }
            assertEquals(rows, decoded)
            assertEquals(listOf(3), stager.sealCounts.toList())
        }
    }

    @Test
    fun reStageCancelsPreviousUnconsumedFirstAndEditorCloseCancelsTracked() = runBlocking {
        val stager = FakeStager()
        val controller = ProviderModelSetStagingController(stager)
        val rows = List(2) { index ->
            JsonObject(mapOf("remoteModelID" to JsonPrimitive("r$index")))
        }
        val first = controller.stage("editor-1", PROVIDER_ID,
            "provider.$PROVIDER_ID", "3", false, ROUTE_TOKEN, rows)
        assertTrue(first is StagedModelSet.Frozen)
        val second = controller.stage("editor-1", PROVIDER_ID,
            "provider.$PROVIDER_ID", "3", false, ROUTE_TOKEN, rows)
        assertTrue(second is StagedModelSet.Frozen)
        // Previous stage discarded BEFORE taking capacity again.
        assertEquals(listOf("msb:v1:" + "a".repeat(32)), stager.cancels.take(1))
        // Editor close cancels the currently tracked (un-consumed) record.
        controller.discardFor("editor-1")
        assertTrue(stager.cancels.size >= 2)
    }

    // ---------------------------------------------------------------- 6

    @Test
    fun rolePickerReachesSupportedTailPerProviderViaRealContinuation() = runBlocking {
        val exchange = Exchange()
        exchange.providersPage = """
            {"rows":[
              {"providerID":"p1","displayName":"One","enabled":true,"syncRevision":1},
              {"providerID":"p2","displayName":"Two","enabled":true,"syncRevision":1}
            ]}
        """.trimIndent()
        exchange.preferencesDoc = prefsDoc()
        fun page(pid: String, from: Int, to: Int, next: String?): String {
            val rows = (from until to).joinToString(",") { i ->
                """{"id":"${pid}-m$i","providerID":"$pid","remoteModelID":"r$i",""" +
                    """"displayName":"$pid m$i","isEnabled":true,""" +
                    """"isHiddenFromPrimaryPicker":false,"capabilities":{"rawValue":7},""" +
                    """"useSurfaces":null}"""
            }
            return """{"rows":[$rows],""" +
                """"nextCursor":${next?.let { "\"$it\"" } ?: "null"},""" +
                """"hasMore":${next != null}}"""
        }
        val pages = mapOf(
            "p1|null" to page("p1", 0, 200, "200"),
            "p1|200" to page("p1", 200, 400, "400"),
            "p1|400" to page("p1", 400, 512, null),
            "p2|null" to page("p2", 0, 5, null),
        )
        exchange.modelsResponder = { pid, cursor ->
            pages["$pid|$cursor"] ?: """{"rows":[],"hasMore":false}"""
        }
        val h = host(exchange)
        h.settings.roles.refresh()
        // Preferences finish before the model sweep. Await this request's
        // choices or terminal error; keep the full pagination assertions.
        waitUntil {
            val current = h.settings.roles.state.value
            current.choices.containsKey(SettingsRoleModelController.RoleSlot.DEFAULT_AGENT) ||
                current.error != null
        }
        val state = h.settings.roles.state.value
        assertNull("per-provider sweep must not hit the old 400-row tail refusal: ${state.error}",
            state.error)
        val choices = state.choices[SettingsRoleModelController.RoleSlot.DEFAULT_AGENT]
        assertNotNull(choices)
        // 512 (p1) + 5 (p2): rows beyond the 400th of a valid large
        // provider are now REACHABLE, not refused.
        assertEquals(517, choices!!.size)
        assertTrue(choices.any { it.displayName == "p1 m511" })
        // Every models read carried the provider filter (bounded per
        // provider; one chain per enabled provider, no unbounded global
        // first chain).
        // Count this role sweep's four filtered pages, not independent
        // background conversation-cache reads sharing the same transport.
        assertEquals(4, exchange.roleModelPageReads.size)
        assertTrue(exchange.roleModelPageReads.all { request ->
            val provider = payloadOf(request)["providerID"]?.jsonPrimitive?.content
            provider == "p1" || provider == "p2"
        })
    }

    @Test
    fun providerBeyondSupportedBoundRefusesTypedWithoutPartialPublish() = runBlocking {
        val exchange = Exchange()
        exchange.providersPage = """
            {"rows":[{"providerID":"p1","displayName":"One","enabled":true,"syncRevision":1}]}
        """.trimIndent()
        exchange.preferencesDoc = prefsDoc()
        fun page(from: Int, to: Int, next: String?): String {
            val rows = (from until to).joinToString(",") { i ->
                """{"id":"p1-m$i","providerID":"p1","remoteModelID":"r$i",""" +
                    """"displayName":"p1 m$i","isEnabled":true,""" +
                    """"isHiddenFromPrimaryPicker":false,"capabilities":{"rawValue":7},""" +
                    """"useSurfaces":null}"""
            }
            return """{"rows":[$rows],"nextCursor":${next?.let { "\"$it\"" } ?: "null"},""" +
                """"hasMore":${next != null}}"""
        }
        // 200 + 200 + 113 = 513 > the UNCHANGED native 512 bound.
        val pages = mapOf<String, String>(
            "null" to page(0, 200, "200"),
            "200" to page(200, 400, "400"),
            "400" to page(400, 513, null),
        )
        exchange.modelsResponder = { _, cursor ->
            pages[cursor ?: "null"] ?: """{"rows":[],"hasMore":false}"""
        }
        val h = host(exchange)
        h.settings.roles.refresh()
        waitUntil { h.settings.roles.state.value.error != null }
        assertEquals("models_supported_bound", h.settings.roles.state.value.error)
        // No partial candidate mix published on the refused sweep.
        assertTrue(h.settings.roles.state.value.choices.values.all { it.isEmpty() })
    }

    private fun prefsDoc(): String =
        """{"revision":{"resourceID":"preferences","version":"7"},"preferences":{"onboardingStatus":"completed",""" +
            """"defaultAgentModelID":null,"generalAuxiliaryLLMModelID":null,"canvasAgentModelID":null,""" +
            """"visionModelID":null,"canvasVisionModelID":null,"approvalModelID":null,"packageReviewModelID":null,""" +
            """"auxiliaryImageMode":"shared","sharedImageModelID":null,"imageGenerationModelID":null,""" +
            """"imageEditingModelID":null,"defaultVideoModelID":null,"autonomousImageRouting":false,""" +
            """"updatedAt":"2026-10-20T00:00:00.000Z","syncRevision":7}}"""
}
