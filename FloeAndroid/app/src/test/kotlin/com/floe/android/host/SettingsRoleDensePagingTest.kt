// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.RuntimeBootstrapCapability
import com.floe.android.SecretGatewayCapability
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** Deferred App tests: the real controller and command client consume
 * byte-dense, single-row pages. No native/network/device qualification. */
class SettingsRoleDensePagingTest {
    private class DenseExchange(var count: Int) : HostBridgeExchange {
        private val pages = java.util.concurrent.ConcurrentHashMap<String, String>()
        private var sequence = 0
        var refusedIndex: Int? = null
        val indices = java.util.concurrent.CopyOnWriteArrayList<Int>()
        private val provider = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

        override fun exchange(request: String): String {
            val correlation = correlationOf(request)
            if (request.contains("\"operation\":\"effect.poll\"")) {
                val receipt = receiptOf(request)
                val page = pages.getValue(receipt)
                return """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":1},"effects":[{"sequence":1,"kind":"accepted","page":$page}],"hasMore":false,"resyncRequired":false}"""
            }
            val envelope = Json.parseToJsonElement(request).jsonObject["envelope"]!!.jsonObject
            val command = envelope["command"]!!.jsonPrimitive.content
            val page = when (command) {
                "config.preferences.get" -> """{"revision":{"resourceID":"preferences","version":"7"},"preferences":{}}"""
                "config.providers.list" -> """{"rows":[{"id":"$provider","kind":"custom","wireProtocol":"openAIChatCompletions","baseURL":"https://dense.invalid/v1","displayName":"Dense provider","isEnabled":true,"syncRevision":1,"secret":{"configured":true}}],"hasMore":false}"""
                "config.models.list" -> {
                    val payload = envelope["payload"]!!.jsonObject
                    check(payload["providerID"]!!.jsonPrimitive.content == provider)
                    val index = payload["cursor"]?.jsonPrimitive?.content?.toInt() ?: 0
                    indices.add(index)
                    if (index == refusedIndex) {
                        return """{"version":3,"ok":false,"correlationID":"$correlation","error":"dense_page_refused"}"""
                    }
                    val row = buildJsonObject {
                        put("id", UUID(0, (index + 1).toLong()).toString())
                        put("providerID", provider)
                        put("remoteModelID", "dense-$index")
                        put("displayName", "Dense $index " + "x".repeat(30_000))
                        put("capabilities", 7)
                        put("isEnabled", true)
                    }
                    // Two such rows exceed the native 49,152-byte page
                    // budget. A 200-item maximum cannot guarantee 200 rows.
                    check(row.toString().toByteArray().size in 24_577..49_149)
                    buildJsonObject {
                        put("rows", JsonArray(listOf(row)))
                        put("hasMore", index + 1 < count)
                        if (index + 1 < count) put("nextCursor", (index + 1).toString())
                    }.toString()
                }
                else -> error("Unexpected command $command")
            }
            val receipt = "op:v1:dense${++sequence}"
            pages[receipt] = page
            return """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"$receipt"}"""
        }
    }

    private suspend fun withHost(exchange: DenseExchange, block: suspend (RuntimeHost) -> Unit) {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val client = RuntimeHostCommandClient(
            exchange = exchange, scope = scope, ioDispatcher = Dispatchers.Default,
            budgets = HostWireBudgets(effectPollIntervalMillis = 1))
        val host = RuntimeHost(
            commandClient = client,
            gatewayCapability = MutableStateFlow(SecretGatewayCapability.Loading),
            bootstrapCapability = MutableStateFlow(RuntimeBootstrapCapability.Idle),
            scope = scope, ioDispatcher = Dispatchers.Default)
        try {
            host.onBootstrapCapability(RuntimeBootstrapCapability.OwnedStoreReady)
            block(host)
        } finally {
            host.stop()
            scope.cancel()
        }
    }

    @Test fun readsAll512SupportedModelsWhenEachByteDenseRowNeedsItsOwnPage() = runBlocking {
        val exchange = DenseExchange(512)
        withHost(exchange) { host ->
            host.settings.roles.refresh()
            val state = withTimeout(20_000) {
                host.settings.roles.state.first {
                    it.error != null || it.choices[SettingsRoleModelController.RoleSlot.DEFAULT_AGENT]?.size == 512
                }
            }
            assertNull(state.error)
            val choices = state.choices.getValue(SettingsRoleModelController.RoleSlot.DEFAULT_AGENT)
            assertEquals((1..512).map { UUID(0, it.toLong()).toString() }.toSet(),
                choices.map { it.modelId }.toSet())
            assertEquals((0 until 512).toList(), exchange.indices)
        }
    }

    @Test fun laterPageRefusalPreservesTheLastWholeProjection() = runBlocking {
        val exchange = DenseExchange(12)
        withHost(exchange) { host ->
            host.settings.roles.refresh()
            val initial = withTimeout(10_000) {
                host.settings.roles.state.first { it.error != null ||
                    it.choices[SettingsRoleModelController.RoleSlot.DEFAULT_AGENT]?.size == 12 }
            }
            assertNull(initial.error)
            exchange.count = 14
            exchange.refusedIndex = 9
            host.settings.roles.refresh()
            val refused = withTimeout(10_000) { host.settings.roles.state.first { it.error != null } }
            assertEquals(initial.choices, refused.choices)
            assertTrue(exchange.indices.contains(9))
        }
    }
}
