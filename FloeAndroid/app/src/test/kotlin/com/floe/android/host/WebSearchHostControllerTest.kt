// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Authored NOTRUN. G02 web-search controller: real get/save envelope,
 * exact webSearchSave ingress, Keep/Set/Clear, CAS, retry and secret hygiene.
 * A scripted transport + one-shot-submitter double stand in for the native
 * owner; no production fake service is added.
 */
class WebSearchHostControllerTest {

    private val json = Json { ignoreUnknownKeys = true }

    private class Exchange : HostBridgeExchange {
        var getValue: String = WebSearchHostControllerTest.DEFAULT_GET
        var saveValue: String? = null
        var saveRejectionCode: String? = null
        var lastSaveEnvelope: String? = null
        var lastGetEnvelope: String? = null
        val getCount = java.util.concurrent.atomic.AtomicInteger(0)
        val saveCount = java.util.concurrent.atomic.AtomicInteger(0)
        private val receiptKinds = ConcurrentHashMap<String, String>()
        private val receiptSequence = java.util.concurrent.atomic.AtomicInteger(0)

        override fun exchange(request: String): String {
            val correlation = correlationOf(request)
            return when {
                request.contains("\"operation\":\"effect.poll\"") -> {
                    val receipt = receiptOf(request)
                    when (receiptKinds[receipt]) {
                        "get" -> completedPage(correlation, receipt, getValue)
                        "save" -> {
                            val code = saveRejectionCode
                            val value = saveValue
                            when {
                                code != null -> rejectedPage(correlation, receipt, code)
                                value != null -> completedPage(correlation, receipt, value)
                                else -> emptyPage(correlation, receipt)
                            }
                        }
                        else -> emptyPage(correlation, receipt)
                    }
                }
                request.contains("\"command\":\"config.websearch.get\"") -> {
                    getCount.incrementAndGet()
                    lastGetEnvelope = request
                    queued(correlation, "get")
                }
                request.contains("\"command\":\"config.websearch.save\"") -> {
                    saveCount.incrementAndGet()
                    lastSaveEnvelope = request
                    queued(correlation, "save")
                }
                else -> """{"version":3,"ok":false,"error":"invalidEnvelope","reason":"unscripted"}"""
            }
        }

        private fun queued(correlation: String, kind: String): String {
            val number = receiptSequence.incrementAndGet()
            val receipt = "op:v1:$kind$number"
            receiptKinds[receipt] = kind
            return """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"$receipt"}"""
        }

        private fun completedPage(correlation: String, receipt: String, value: String): String =
            """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":1},"effects":[{"sequence":1,"kind":"accepted","value":$value}],"hasMore":false,"resyncRequired":false}"""

        private fun rejectedPage(correlation: String, receipt: String, code: String): String =
            """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":1},"effects":[{"sequence":1,"kind":"rejected","code":"$code","detail":[{"key":"reason","value":"$code"}]}],"hasMore":false,"resyncRequired":false}"""

        private fun emptyPage(correlation: String, receipt: String): String =
            """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":0},"effects":[],"hasMore":true,"resyncRequired":false}"""
    }

    /** Synthetic canonical host route handle used by the JVM fixtures. */
    private class FakeRouteAuthority : HostRouteAuthority {
        val opened = java.util.concurrent.atomic.AtomicInteger(0)
        val cleared = java.util.concurrent.atomic.AtomicInteger(0)
        @Volatile var lastExpectedEpoch: Long = -1
        @Volatile var lastUiGeneration: Long = -1
        override fun open(
            kind: HostEditorKind,
            editorID: String,
            uiGeneration: Long,
            expectedNativeRootEpoch: Long,
        ): String? {
            opened.incrementAndGet()
            lastExpectedEpoch = expectedNativeRootEpoch
            lastUiGeneration = uiGeneration
            return ROUTE_TOKEN
        }

        override fun clear(token: String) {
            cleared.incrementAndGet()
        }
    }

    private class FakeSubmitter(
        private val result: WebSearchHostController.SaveIntentSubmission =
            WebSearchHostController.SaveIntentSubmission.Accepted(
                WebSearchHostControllerTest.TOKEN,
            ),
    ) : WebSearchHostController.SaveIntentSubmitter {
        val calls = java.util.concurrent.atomic.AtomicInteger(0)
        @Volatile var lastIntent: String? = null
        @Volatile var lastRoute: String? = null
        @Volatile var lastBytes: ByteArray? = null
        @Volatile var bytesReference: ByteArray? = null

        override fun submit(
            intentCoreJson: String,
            routeToken: String,
            value: ByteArray,
        ): WebSearchHostController.SaveIntentSubmission {
            calls.incrementAndGet()
            lastIntent = intentCoreJson
            lastRoute = routeToken
            lastBytes = value.copyOf()
            bytesReference = value
            return result
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
                com.floe.android.SecretGatewayCapability.Loading),
            bootstrapCapability = kotlinx.coroutines.flow.MutableStateFlow(
                com.floe.android.RuntimeBootstrapCapability.Idle),
            scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default),
            ioDispatcher = kotlinx.coroutines.Dispatchers.Default,
        )
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        // JVM fixtures: the native library is absent, so the trusted host
        // epoch readback and route authority are injected synthetically.
        // (Device/native coverage lives in the instrumented suites.)
        host.nativeRootEpochReader = { 31L }
        host.webSearch.routeAuthority = FakeRouteAuthority()
        return host
    }

    private suspend fun waitUntil(timeoutMillis: Long = 2_000, predicate: () -> Boolean) {
        val deadline = System.nanoTime() + timeoutMillis * 1_000_000L
        while (System.nanoTime() < deadline) {
            if (predicate()) return
            delay(10)
        }
        assertTrue("condition not reached", predicate())
    }

    private suspend fun load(host: RuntimeHost) {
        host.webSearch.refresh()
        waitUntil { host.webSearch.state.value.loaded && !host.webSearch.state.value.loading }
    }

    private suspend fun awaitEditorIdle(host: RuntimeHost) {
        waitUntil {
            val editor = host.webSearch.state.value.editor
            editor == null || !editor.saveInFlight
        }
    }

    /**
     * Returns the frozen inner `floe.command-envelope/3` document from the
     * canonical outer v3 operation request
     * (`{version,operation,requestID,envelope:{...}}`). Assertions below read
     * the inner command/scope/revision/payload members exactly as the native
     * validator does.
     */
    private fun envelope(raw: String?): JsonObject {
        assertTrue(raw != null)
        val root = json.parseToJsonElement(raw!!) as JsonObject
        return root["envelope"] as? JsonObject ?: root
    }

    private fun payload(raw: String?): JsonObject =
        envelope(raw)["payload"] as JsonObject

    @Test
    fun getLoadsProvidersRevisionAndPresets() = runBlocking {
        val exchange = Exchange()
        val host = host(exchange)
        load(host)
        val state = host.webSearch.state.value
        assertEquals("rev-1", state.revision)
        assertEquals(3, state.configurations.size)
        assertEquals(8, state.rows.size) // 3 persisted + 5 missing presets
        assertTrue(state.rows.any {
            it.configuration.id == BRAVE_ID &&
                it.credentialState == WebSearchCredentialState.AVAILABLE &&
                it.configured
        })
        assertTrue(state.rows.count { !it.configured } == 5)
        assertTrue(state.native.getHandler)
    }

    @Test
    fun emptyGetShowsTheEightOriginalPresetsInOrder() = runBlocking {
        val exchange = Exchange()
        exchange.getValue = """{"revision":{"resourceID":"settings.websearch","version":"empty-rev"},"providers":[]}"""
        val host = host(exchange)
        load(host)
        val rows = host.webSearch.state.value.rows
        assertEquals(8, rows.size)
        assertEquals(
            WebSearchProviderPresets.kinds,
            rows.map { it.configuration.kind },
        )
        assertTrue(rows.all { !it.configured })
    }

    @Test
    fun keepSaveIsLegacyMetadataOnlyAndPreservesTheCredential() = runBlocking {
        val exchange = Exchange()
        exchange.saveValue = SAVE_REPLY
        val host = host(exchange)
        load(host)
        assertTrue(host.webSearch.openEditor(BRAVE_ID))
        val editor = host.webSearch.state.value.editor!!
        assertEquals(WebSearchHostController.CredentialIntent.KEEP, editor.credentialIntent)
        host.webSearch.updateDisplayName("Brave Primary")
        val submitter = FakeSubmitter()
        host.webSearch.saveIntentSubmitter = submitter
        assertTrue(host.webSearch.saveEditor())
        awaitEditorIdle(host)
        assertEquals(0, submitter.calls.get())
        val savePayload = payload(exchange.lastSaveEnvelope)
        assertFalse(savePayload.containsKey("credential"))
        val revision = envelope(exchange.lastSaveEnvelope)["revision"] as JsonObject
        assertEquals("settings.websearch", revision.stringStrict("resourceID"))
        assertEquals("rev-1", revision.stringStrict("version"))
        val saved = (savePayload["configurations"] as JsonArray)
            .map { WebSearchProviderConfiguration.fromJson(it as JsonObject)!! }
            .first { it.id == BRAVE_ID }
        assertEquals("Brave Primary", saved.displayName)
        assertTrue(saved.enabled)
        assertNull(host.webSearch.state.value.editor)
    }

    @Test
    fun setSaveUsesExactWebSearchSaveIngressAndNoSecretInTheCommand() = runBlocking {
        val exchange = Exchange()
        exchange.saveValue = SAVE_REPLY_TENCENT
        val host = host(exchange)
        load(host)
        host.webSearch.bindSecureSaveCapability("webSearchSave", true)
        assertTrue(host.webSearch.openEditor(TENCENT_ID))
        val editor = host.webSearch.state.value.editor!!
        assertEquals(WebSearchHostController.CredentialIntent.SET, editor.credentialIntent)
        host.webSearch.updateCredential(WebSearchCredentialField.SECRET_ID, "secret-id-value")
        host.webSearch.updateCredential(WebSearchCredentialField.SECRET_KEY, "secret-key-value")
        host.webSearch.updateDisplayName("Tencent Primary")
        val submitter = FakeSubmitter()
        host.webSearch.saveIntentSubmitter = submitter
        assertTrue(host.webSearch.saveEditor())
        awaitEditorIdle(host)
        assertEquals(1, submitter.calls.get())
        // The intent JSON is the frozen secret-free candidate with the exact
        // closed subject/route/base revision shape.
        val intent = json.parseToJsonElement(submitter.lastIntent!!) as JsonObject
        val subject = intent["subject"] as JsonObject
        assertEquals("webSearchSave", subject.stringStrict("kind"))
        assertEquals(TENCENT_ID, subject.stringStrict("id"))
        assertEquals("set", intent.stringStrict("intent"))
        // Route authority is native: the frozen core never carries a route,
        // and the submitter receives this editor's own native handle.
        assertFalse(intent.containsKey("route"))
        assertEquals(ROUTE_TOKEN, submitter.lastRoute)
        val base = intent["baseRevision"] as JsonObject
        assertEquals("settings.websearch", base.stringStrict("resourceID"))
        assertEquals("rev-1", base.stringStrict("version"))
        val candidate = intent["candidate"] as JsonObject
        assertEquals(TENCENT_ID, candidate.stringStrict("id"))
        assertFalse(candidate.containsKey("credential"))
        assertFalse(submitter.lastIntent!!.contains("secret-id-value"))
        assertFalse(submitter.lastIntent!!.contains("secret-key-value"))
        // The command carries only the opaque token; secret values are absent.
        val command = envelope(exchange.lastSaveEnvelope)
        assertFalse(command.toString().contains("secret-id-value"))
        assertFalse(command.toString().contains("secret-key-value"))
        val credential = payload(exchange.lastSaveEnvelope)["credential"] as JsonObject
        assertEquals(
            setOf("configurationID", "intent", "saveIntentToken"),
            credential.keys,
        )
        assertEquals(TENCENT_ID, credential.stringStrict("configurationID"))
        assertEquals("set", credential.stringStrict("intent"))
        assertEquals(TOKEN, credential.stringStrict("saveIntentToken"))
        // Encoded original WebSearchCredential shape, then zeroed by owner.
        val encoded = (json.parseToJsonElement(
            String(submitter.lastBytes!!, Charsets.UTF_8)) as JsonObject)
        val values = encoded["values"] as JsonObject
        assertEquals("secret-id-value", values.stringStrict("secretId"))
        assertEquals("secret-key-value", values.stringStrict("secretKey"))
        assertTrue(submitter.bytesReference!!.all { it == 0.toByte() })
        assertNull(host.webSearch.state.value.editor)
    }

    @Test
    fun clearSaveUsesExactCredentialEntryWithoutToken() = runBlocking {
        val exchange = Exchange()
        exchange.saveValue = SAVE_REPLY
        val host = host(exchange)
        load(host)
        host.webSearch.bindSecureSaveCapability("webSearchSave", true)
        assertTrue(host.webSearch.openEditor(BRAVE_ID))
        host.webSearch.setCredentialIntent(WebSearchHostController.CredentialIntent.CLEAR)
        val submitter = FakeSubmitter()
        host.webSearch.saveIntentSubmitter = submitter
        assertTrue(host.webSearch.saveEditor())
        awaitEditorIdle(host)
        assertEquals(0, submitter.calls.get())
        val credential = payload(exchange.lastSaveEnvelope)["credential"] as JsonObject
        assertEquals(setOf("configurationID", "intent"), credential.keys)
        assertEquals(BRAVE_ID, credential.stringStrict("configurationID"))
        assertEquals("clear", credential.stringStrict("intent"))
    }

    @Test
    fun setRequiresEveryMandatoryFieldBeforeAnyNativeIngress() = runBlocking {
        val exchange = Exchange()
        val host = host(exchange)
        load(host)
        host.webSearch.bindSecureSaveCapability("webSearchSave", true)
        assertTrue(host.webSearch.openEditor(GOOGLE_ID))
        host.webSearch.updateCredential(WebSearchCredentialField.API_KEY, "key")
        val submitter = FakeSubmitter()
        host.webSearch.saveIntentSubmitter = submitter
        assertFalse(host.webSearch.saveEditor())
        assertEquals(0, submitter.calls.get())
        assertEquals(0, exchange.saveCount.get())
        assertEquals(
            "credentialFieldsRequired",
            host.webSearch.state.value.editor!!.failure,
        )
        host.webSearch.updateCredential(WebSearchCredentialField.ENGINE_ID, "engine")
        exchange.saveValue = SAVE_REPLY_GOOGLE
        assertTrue(host.webSearch.saveEditor())
        awaitEditorIdle(host)
    }

    @Test
    fun setAndClearAreRefusedUntilTheExactSubjectIsBound() = runBlocking {
        val exchange = Exchange()
        val host = host(exchange)
        load(host)
        assertFalse(host.webSearch.state.value.native.secureSave)
        host.webSearch.bindSecureSaveCapability("providerSave", true)
        assertFalse(host.webSearch.state.value.native.secureSave)
        assertTrue(host.webSearch.openEditor(TENCENT_ID))
        host.webSearch.updateCredential(WebSearchCredentialField.SECRET_ID, "id")
        host.webSearch.updateCredential(WebSearchCredentialField.SECRET_KEY, "key")
        val submitter = FakeSubmitter()
        host.webSearch.saveIntentSubmitter = submitter
        assertFalse(host.webSearch.saveEditor())
        assertEquals(0, submitter.calls.get())
        assertEquals(
            "secureSaveUnavailable",
            host.webSearch.state.value.editor!!.failure,
        )
    }

    @Test
    fun duplicateSaveTapDoesNotSubmitTwice() = runBlocking {
        val exchange = Exchange()
        val host = host(exchange)
        load(host)
        exchange.saveValue = null
        assertTrue(host.webSearch.openEditor(BRAVE_ID))
        val before = exchange.saveCount.get()
        assertTrue(host.webSearch.saveEditor())
        waitUntil { exchange.saveCount.get() > before }
        assertFalse(host.webSearch.saveEditor())
        assertEquals(before + 1, exchange.saveCount.get())
        exchange.saveValue = SAVE_REPLY
        awaitEditorIdle(host)
    }

    @Test
    fun failedSavePreservesDraftAndRetriesWithOneMoreIngress() = runBlocking {
        val exchange = Exchange()
        val host = host(exchange)
        load(host)
        host.webSearch.bindSecureSaveCapability("webSearchSave", true)
        assertTrue(host.webSearch.openEditor(TENCENT_ID))
        host.webSearch.updateCredential(WebSearchCredentialField.SECRET_ID, "id")
        host.webSearch.updateCredential(WebSearchCredentialField.SECRET_KEY, "key")
        host.webSearch.updateDisplayName("Retry Me")
        val submitter = FakeSubmitter()
        host.webSearch.saveIntentSubmitter = submitter
        exchange.saveRejectionCode = "staleRevision"
        assertTrue(host.webSearch.saveEditor())
        awaitEditorIdle(host)
        val failed = host.webSearch.state.value.editor
        assertTrue(failed != null)
        assertEquals("staleRevision", failed!!.failure)
        assertEquals("Retry Me", failed.draft.displayName)
        assertEquals("id", failed.draft.credentialValues["secretId"])
        assertEquals(1, failed.failureSequence)
        assertEquals(1, submitter.calls.get())
        // Explicit reload adopts the fresh revision while preserving draft
        // and RAM credential fields; only then is retry safe.
        exchange.getValue = GET_REV3
        assertTrue(host.webSearch.reloadEditorForRetry())
        waitUntil {
            !host.webSearch.state.value.loading &&
                host.webSearch.state.value.editor?.baseRevision == "rev-3"
        }
        assertEquals("Retry Me", host.webSearch.state.value.editor!!.draft.displayName)
        assertEquals(
            "id",
            host.webSearch.state.value.editor!!.draft.credentialValues["secretId"],
        )
        assertNull(host.webSearch.state.value.editor!!.failure)
        exchange.saveRejectionCode = null
        exchange.saveValue = SAVE_REPLY_TENCENT
        assertTrue(host.webSearch.saveEditor())
        awaitEditorIdle(host)
        assertEquals(2, submitter.calls.get())
        val revision = envelope(exchange.lastSaveEnvelope)["revision"] as JsonObject
        assertEquals("rev-3", revision.stringStrict("version"))
        assertNull(host.webSearch.state.value.editor)
    }

    @Test
    fun successfulSaveClosesTheEditorAndWipesTheTransientBytes() = runBlocking {
        val exchange = Exchange()
        val host = host(exchange)
        load(host)
        host.webSearch.bindSecureSaveCapability("webSearchSave", true)
        assertTrue(host.webSearch.openEditor(TENCENT_ID))
        host.webSearch.updateCredential(WebSearchCredentialField.SECRET_ID, "id")
        host.webSearch.updateCredential(WebSearchCredentialField.SECRET_KEY, "key")
        val submitter = FakeSubmitter()
        host.webSearch.saveIntentSubmitter = submitter
        exchange.saveValue = SAVE_REPLY_TENCENT
        assertTrue(host.webSearch.saveEditor())
        awaitEditorIdle(host)
        assertNull(host.webSearch.state.value.editor)
        assertTrue(host.webSearch.state.value.lastSaved)
        assertEquals("rev-2", host.webSearch.state.value.revision)
        assertTrue(submitter.bytesReference!!.all { it == 0.toByte() })
    }

    @Test
    fun staleSaveCallbackCannotMutateAfterStopClosedTheEditor() = runBlocking {
        val exchange = Exchange()
        val host = host(exchange)
        load(host)
        host.webSearch.bindSecureSaveCapability("webSearchSave", true)
        assertTrue(host.webSearch.openEditor(TENCENT_ID))
        host.webSearch.updateCredential(WebSearchCredentialField.SECRET_ID, "id")
        host.webSearch.updateCredential(WebSearchCredentialField.SECRET_KEY, "key")
        val submitter = FakeSubmitter()
        host.webSearch.saveIntentSubmitter = submitter
        exchange.saveValue = null
        assertTrue(host.webSearch.saveEditor())
        waitUntil { host.webSearch.state.value.editor?.saveInFlight == true }
        host.webSearch.stop()
        assertNull(host.webSearch.state.value.editor)
        val revisionBefore = host.webSearch.state.value.revision
        exchange.saveValue = SAVE_REPLY_TENCENT
        delay(100)
        assertNull(host.webSearch.state.value.editor)
        assertEquals(revisionBefore, host.webSearch.state.value.revision)
    }

    @Test
    fun enableToggleUsesMetadataOnlyCasAndNoCredentialEntry() = runBlocking {
        val exchange = Exchange()
        exchange.saveValue = SAVE_REPLY_BRAVE_DISABLED
        val host = host(exchange)
        load(host)
        assertTrue(host.webSearch.setEnabled(BRAVE_ID, false))
        waitUntil { !host.webSearch.state.value.listSaveInFlight }
        val credential = payload(exchange.lastSaveEnvelope)["credential"]
        assertNull(credential)
        val revision = envelope(exchange.lastSaveEnvelope)["revision"] as JsonObject
        assertEquals("rev-1", revision.stringStrict("version"))
        val saved = (payload(exchange.lastSaveEnvelope)["configurations"] as JsonArray)
            .map { WebSearchProviderConfiguration.fromJson(it as JsonObject)!! }
            .first { it.id == BRAVE_ID }
        assertFalse(saved.enabled)
        assertEquals("rev-2", host.webSearch.state.value.revision)
        assertNull(host.webSearch.state.value.listSaveError)
    }

    @Test
    fun malformedSaveReadbackClosesTheSecretSurfaceAndRefreshes() = runBlocking {
        val exchange = Exchange()
        exchange.saveValue = "{}"
        val host = host(exchange)
        load(host)
        exchange.getValue = "{}"
        assertTrue(host.webSearch.openEditor(BRAVE_ID))
        assertTrue(host.webSearch.saveEditor())
        awaitEditorIdle(host)
        waitUntil {
            !host.webSearch.state.value.loading &&
                host.webSearch.state.value.error == "readbackUnavailable"
        }
        assertNull(host.webSearch.state.value.editor)
        assertTrue(host.webSearch.state.value.lastSaved)
        assertEquals("readbackUnavailable", host.webSearch.state.value.error)
    }

    @Test
    fun cancelAndDisposeClearOnlyTheOwnedEditor() = runBlocking {
        val exchange = Exchange()
        val host = host(exchange)
        load(host)
        assertTrue(host.webSearch.openEditor(TENCENT_ID))
        val first = host.webSearch.state.value.editor!!
        host.webSearch.updateCredential(WebSearchCredentialField.SECRET_ID, "id")
        host.webSearch.disposeEditorIfOwned(first.editorId, "foreign-route")
        assertTrue(host.webSearch.state.value.editor != null)
        host.webSearch.disposeEditorIfOwned(first.editorId, first.routeToken)
        assertNull(host.webSearch.state.value.editor)
        assertTrue(host.webSearch.openEditor(TENCENT_ID))
        host.webSearch.closeEditor()
        assertNull(host.webSearch.state.value.editor)
    }



    companion object {
        const val TOKEN = "int:v1:0123456789abcdef0123456789abcdef"
        const val ROUTE_TOKEN = "rt:v1:0123456789abcdef0123456789abcdef"
        const val BRAVE_ID = "11111111-1111-1111-1111-111111111111"
        const val TENCENT_ID = "22222222-2222-2222-2222-222222222222"
        const val GOOGLE_ID = "33333333-3333-3333-3333-333333333333"

        const val TENCENT_PROVIDER = """{"id":"22222222-2222-2222-2222-222222222222","kind":"tencentWSA","displayName":"Tencent Cloud WSA","credentialAccount":"web-search.tencentWSA","credential":"secretMissing","enabled":false,"priority":1,"options":{}}"""
        const val GOOGLE_PROVIDER = """{"id":"33333333-3333-3333-3333-333333333333","kind":"googleProgrammable","displayName":"Google Programmable Search","credentialAccount":"web-search.googleProgrammable","credential":"secretMissing","enabled":false,"priority":3,"options":{}}"""

        val DEFAULT_GET = """{"revision":{"resourceID":"settings.websearch","version":"rev-1"},"providers":[{"id":"11111111-1111-1111-1111-111111111111","kind":"brave","displayName":"Brave Search","credentialAccount":"web-search.brave","credential":"available","enabled":true,"priority":0,"options":{}},$TENCENT_PROVIDER,$GOOGLE_PROVIDER]}"""

        val GET_REV3 = DEFAULT_GET.replace("\"rev-1\"", "\"rev-3\"")
        val SAVE_REPLY = """{"revision":{"resourceID":"settings.websearch","version":"rev-2"},"providers":[{"id":"11111111-1111-1111-1111-111111111111","kind":"brave","displayName":"Brave Primary","credentialAccount":"web-search.brave","credential":"available","enabled":true,"priority":0,"options":{}},$TENCENT_PROVIDER,$GOOGLE_PROVIDER]}"""
        val SAVE_REPLY_BRAVE_DISABLED = """{"revision":{"resourceID":"settings.websearch","version":"rev-2"},"providers":[{"id":"11111111-1111-1111-1111-111111111111","kind":"brave","displayName":"Brave Search","credentialAccount":"web-search.brave","credential":"available","enabled":false,"priority":0,"options":{}},$TENCENT_PROVIDER,$GOOGLE_PROVIDER]}"""
        val SAVE_REPLY_TENCENT = """{"revision":{"resourceID":"settings.websearch","version":"rev-2"},"providers":[{"id":"11111111-1111-1111-1111-111111111111","kind":"brave","displayName":"Brave Search","credentialAccount":"web-search.brave","credential":"available","enabled":true,"priority":0,"options":{}},{"id":"22222222-2222-2222-2222-222222222222","kind":"tencentWSA","displayName":"Tencent Primary","credentialAccount":"web-search.tencentWSA","credential":"available","enabled":false,"priority":1,"options":{}},$GOOGLE_PROVIDER]}"""
        val SAVE_REPLY_GOOGLE = """{"revision":{"resourceID":"settings.websearch","version":"rev-2"},"providers":[{"id":"11111111-1111-1111-1111-111111111111","kind":"brave","displayName":"Brave Search","credentialAccount":"web-search.brave","credential":"available","enabled":true,"priority":0,"options":{}},$TENCENT_PROVIDER,{"id":"33333333-3333-3333-3333-333333333333","kind":"googleProgrammable","displayName":"Google Programmable Search","credentialAccount":"web-search.googleProgrammable","credential":"available","enabled":false,"priority":3,"options":{}}]}"""
    }
}
