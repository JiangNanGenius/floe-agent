// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Provider-editor admission against the REAL per-provider model sweep.
 *
 * AUTHORED ONLY: NOT compiled or executed by this source phase. Transport
 * is a scripted double of the v3 wire (accepted pages + typed rejected
 * terminals); no native code, no device, no network.
 *
 * The destructive case Main found: a completed read of profile A is cached,
 * the user saves profile B, and the NEXT model sweep fails. `modelsReadOnce`
 * is still true and the refresh flag clears, so the old predicate admitted
 * the editor and a Keep save could persist A's erased/old model set. The
 * fixed predicate is bound to the latest SUCCESSFUL sweep generation, the
 * owning native root and the current provider set; a later successful refresh
 * reopens the editor with the complete B set.
 */
class ConversationModelCacheAdmissionTest {

    private val providerId = "8e19aa7e-c0f2-4532-8a49-0ce3ac782c68"
    private val modelA = "aaaaaaaa-1111-4222-8333-444455556666"
    private val modelB1 = "bbbbbbbb-1111-4222-8333-444455556666"
    private val modelB2 = "bbbbbbbb-2222-4333-8444-555566667777"

    private class ScriptedExchange(
        private val script: (String) -> String,
    ) : HostBridgeExchange {
        val requests = CopyOnWriteArrayList<String>()
        override fun exchange(request: String): String {
            requests.add(request)
            return script(request)
        }

        fun commandsOf(command: String): List<JsonObject> = requests.mapNotNull { raw ->
            val root = runCatching { Json.parseToJsonElement(raw).jsonObject }.getOrNull()
                ?: return@mapNotNull null
            if ((root["operation"]?.jsonPrimitive?.content) != "command.submit") {
                return@mapNotNull null
            }
            val envelope = root["envelope"]?.jsonObject ?: return@mapNotNull null
            if ((envelope["command"]?.jsonPrimitive?.content) != command) {
                return@mapNotNull null
            }
            envelope
        }
    }

    private fun receipt(correlation: String, tag: String): String =
        """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation",""" +
            """"operationReceiptID":"op:v1:$tag"}"""

    private fun effectPage(
        correlation: String,
        receiptTag: String,
        effectsJson: String,
    ): String =
        """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3",""" +
            """"correlationID":"$correlation","cursor":{"operationReceiptID":"op:v1:$receiptTag",""" +
            """"sequence":1},"effects":[$effectsJson],"hasMore":false,"resyncRequired":false}"""

    private fun accepted(valueJson: String): String =
        """{"sequence":1,"kind":"accepted","value":$valueJson}"""

    private fun rejected(code: String): String =
        """{"sequence":1,"kind":"rejected","code":"$code","detail":[]}"""

    private fun providerRow(): String =
        """{"id":"$providerId","kind":"custom","wireProtocol":"openAIChatCompletions",""" +
            """"baseURL":"https://example.invalid/v1","displayName":"Provider One",""" +
            """"region":null,"isEnabled":true,"allowsPlainHTTP":false,""" +
            """"toolNameCompatibility":true,"createdAt":"2026-10-21T00:00:00.000Z",""" +
            """"updatedAt":"2026-10-21T00:00:00.000Z","syncRevision":1,""" +
            """"secret":{"configured":true,"opaqueReference":"ref:v1:abc","synchronizable":false}}"""

    private fun modelRow(id: String, remote: String): String =
        """{"id":"$id","providerID":"$providerId","remoteModelID":"$remote",""" +
            """"displayName":"$remote","limits":{"contextTokens":128000,"maxOutputTokens":8192},""" +
            """"capabilities":{"rawValue":7},"explicitCapabilities":null,"useSurfaces":null,""" +
            """"reasoningEffort":"automatic","isEnabled":true,""" +
            """"isHiddenFromPrimaryPicker":false,""" +
            """"revision":{"resourceID":"model.$id","version":"digest"}}"""

    private fun preferencesPage(): String =
        """{"revision":{"resourceID":"preferences","version":"1"},""" +
            """"preferences":{"defaultAgentModelID":"$modelA","syncRevision":1}}"""

    private class SweepScript {
        /** Complete B rows instead of the initial A profile. */
        var serveB = false
        /** Reject every model page (a failed sweep). */
        var failModels = false
        var modelReads = 0
        var failedReads = 0
    }

    private fun buildExchange(script: SweepScript): ScriptedExchange =
        ScriptedExchange { raw ->
            val correlation = correlationOf(raw)
            when {
                raw.contains("\"operation\":\"effect.poll\"") -> {
                    val tag = receiptOf(raw)
                    when (tag) {
                        "op:v1:providers" -> effectPage(
                            correlation, "providers",
                            accepted("""{"rows":[${providerRow()}]}"""),
                        )
                        "op:v1:models" -> {
                            script.modelReads += 1
                            if (script.failModels) {
                                script.failedReads += 1
                                effectPage(correlation, "models", rejected("modelsUnavailable"))
                            } else {
                                val rows = if (script.serveB) {
                                    modelRow(modelB1, "model-b1") + "," +
                                        modelRow(modelB2, "model-b2")
                                } else {
                                    modelRow(modelA, "model-a")
                                }
                                effectPage(
                                    correlation, "models",
                                    accepted("""{"rows":[$rows]}"""),
                                )
                            }
                        }
                        "op:v1:preferences" -> effectPage(
                            correlation, "preferences",
                            accepted(preferencesPage()),
                        )
                        else -> effectPage(correlation, tag, accepted("{}"))
                    }
                }
                raw.contains("\"command\":\"config.providers.list\"") ->
                    receipt(correlation, "providers")
                raw.contains("\"command\":\"config.models.list\"") ->
                    receipt(correlation, "models")
                raw.contains("\"command\":\"config.preferences.get\"") ->
                    receipt(correlation, "preferences")
                else -> receipt(correlation, "other")
            }
        }

    private fun host(exchange: HostBridgeExchange): RuntimeHost {
        val client = RuntimeHostCommandClient(
            exchange = exchange,
            scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default),
            ioDispatcher = kotlinx.coroutines.Dispatchers.Default,
            budgets = HostWireBudgets(effectPollIntervalMillis = 1),
        )
        return RuntimeHost(
            commandClient = client,
            gatewayCapability = MutableStateFlow(com.floe.android.SecretGatewayCapability.Loading),
            bootstrapCapability = MutableStateFlow(com.floe.android.RuntimeBootstrapCapability.Idle),
            scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default),
            ioDispatcher = kotlinx.coroutines.Dispatchers.Default,
        )
    }

    private suspend fun await(condition: () -> Boolean): Boolean {
        val deadline = System.nanoTime() + 5_000_000_000L
        while (System.nanoTime() < deadline) {
            if (condition()) return true
            delay(10)
        }
        return condition()
    }

    @Test
    fun failedSweepAfterAGoodCacheRefusesEditorUntilACompleteRefresh() = runBlocking {
        val script = SweepScript()
        val exchange = buildExchange(script)
        val host = host(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("providerConfigurationDomain", true, emptyList())

        host.providers.refreshProviders()
        assertTrue(await {
            host.providers.destination.value.list.conversationProviders.isNotEmpty()
        })
        host.conversations.refreshModels()
        assertTrue(await {
            host.conversations.modelsProjectionReadyForEditing() &&
                host.conversations.modelRowsForProvider(providerId)
                    .map { it.id } == listOf(modelA)
        })

        // The next sweep (as after saving profile B) fails.
        script.failModels = true
        host.conversations.refreshModels()
        assertTrue(await {
            script.failedReads >= 1 &&
                !host.conversations.modelsProjectionReadyForEditing()
        })
        // The composer keeps the last REAL projection; only destructive
        // editing admission is refused.
        assertTrue(host.conversations.modelProjectionFlow.value.loaded)
        assertEquals(
            listOf(modelA),
            host.conversations.modelRowsForProvider(providerId).map { it.id },
        )

        // A later complete refresh replaces the cache and reopens the
        // editor with the FULL B set.
        script.failModels = false
        script.serveB = true
        host.conversations.refreshModels()
        assertTrue(await {
            host.conversations.modelsProjectionReadyForEditing() &&
                host.conversations.modelRowsForProvider(providerId)
                    .map { it.id } == listOf(modelB1, modelB2)
        })
        assertTrue(exchange.commandsOf("config.models.list").size >= 3)
    }

    @Test
    fun incompleteSweepNeverExposesPriorRowsAsEditingReady() = runBlocking {
        val script = SweepScript().apply { failModels = true }
        val exchange = buildExchange(script)
        val host = host(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("providerConfigurationDomain", true, emptyList())

        host.providers.refreshProviders()
        assertTrue(await {
            host.providers.destination.value.list.conversationProviders.isNotEmpty()
        })
        // Every model page is rejected from the start: no successful sweep
        // exists yet, so no editor may seed from the empty cache.
        host.conversations.refreshModels()
        assertTrue(await {
            exchange.commandsOf("config.models.list").isNotEmpty()
        })
        delay(200)
        assertFalse(host.conversations.modelsProjectionReadyForEditing())
        assertTrue(host.conversations.modelRowsForProvider(providerId).isEmpty())
    }
}
