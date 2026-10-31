// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.RuntimeBootstrapCapability
import com.floe.android.SecretGatewayCapability
import com.floe.android.feature.providers.ModelCapabilityUi
import com.floe.android.feature.providers.ProviderCredentialStateUi
import com.floe.android.feature.providers.ProviderFormLogic
import com.floe.android.feature.providers.ProviderListRowUi
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
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.add
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Run28 root-cause repair (Android complete model capability overrides):
 *  * the repair carrier is the EXACT persisted full row + its native CAS
 *    revision with ONLY `explicitCapabilities` replaced;
 *  * only the provable legacy delta mask (non-zero, editable-only, base owns
 *    TEXT) is repaired — intentional OFF / reviewed zero / media masks are
 *    untouched;
 *  * a refused atomic `config.model.save` leaves the record untouched and is
 *    not blindly retried at the same revision;
 *  * the composer's `supportsText` reads the same EFFECTIVE mask run
 *    admission uses.
 */
class ProviderCapabilityOverrideRepairTest {

    private val provider = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private val model = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

    private fun modelRowObject(
        capabilities: Int = 39,
        explicit: Int? = 2,
        revisionVersion: String = "v1",
        id: String = model,
        extraCapabilityBit: Int = 0,
        revisionResourceID: String = "model.$model",
    ): JsonObject = buildJsonObject {
        put("id", id)
        put("providerID", provider)
        put("remoteModelID", "wire-model")
        put("displayName", "Legacy Model")
        put("limits", buildJsonObject {
            put("contextTokens", 8192)
            put("maxOutputTokens", 512)
        })
        put("capabilities", capabilities or extraCapabilityBit)
        put("pricing", buildJsonObject {
            put("currency", "USD")
            put("inputPerMillion", 0.5)
            put("outputPerMillion", 1.5)
        })
        put("useSurfaces", 5)
        put("reasoningEffort", "high")
        if (explicit != null) put("explicitCapabilities", explicit)
        put("isEnabled", true)
        put("isHiddenFromPrimaryPicker", false)
        put("revision", buildJsonObject {
            put("resourceID", revisionResourceID)
            put("version", revisionVersion)
        })
    }

    private fun modelPage(
        capabilities: Int = 39,
        explicit: Int? = 2,
        revisionVersion: String = "v1",
        id: String = model,
        extraCapabilityBit: Int = 0,
        revisionResourceID: String = "model.$model",
    ): JsonObject = buildJsonObject {
        put("rows", buildJsonArray {
            add(modelRowObject(capabilities, explicit, revisionVersion, id,
                extraCapabilityBit, revisionResourceID))
        })
    }

    private fun decodedRow(
        capabilities: Int = 39,
        explicit: Int? = 2,
        revisionVersion: String = "v1",
        id: String = model,
        extraCapabilityBit: Int = 0,
        revisionResourceID: String = "model.$model",
    ): ProviderWire.ModelRow =
        ProviderWire.decodeModelRows(
            modelPage(capabilities, explicit, revisionVersion, id,
                extraCapabilityBit, revisionResourceID),
        )!!.single()

    private fun providerRow(): ProviderListRowUi = ProviderListRowUi(
        providerId = provider, displayName = "Legacy",
        endpointSummary = "https://example.invalid/v1", modelCount = 1,
        enabled = true, credentialState = ProviderCredentialStateUi.CONFIGURED,
        revisionVersion = "7",
    )

    private class Exchange(
        private val modelRowJSON: String = "",
        private val rejectModelSave: Boolean = false,
    ) : HostBridgeExchange {
        val requests = CopyOnWriteArrayList<String>()
        private val receiptCommands = ConcurrentHashMap<String, String>()
        private val counter = AtomicInteger(0)

        fun saveRequests(): List<String> = requests.filter {
            it.contains("\"command\":\"config.model.save\"")
        }

        override fun exchange(request: String): String {
            requests += request
            val correlation = correlationOf(request)
            val receipt = receiptOf(request)
            if (request.contains("\"operation\":\"effect.poll\"")) {
                val command = receiptCommands[receipt] ?: "unknown"
                if (command == "config.model.save" && rejectModelSave) {
                    return """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":1},"effects":[{"sequence":1,"kind":"rejected","code":"staleRevision","detail":[{"key":"reason","value":"modelSnapshotDigest"}]}],"hasMore":false,"resyncRequired":false}"""
                }
                val value = when (command) {
                    "config.providers.list" -> """{"rows":[{"id":"$PROVIDER_ID","kind":"custom","wireProtocol":"openAIChatCompletions","baseURL":"https://example.invalid/v1","displayName":"Legacy","isEnabled":true,"allowsPlainHTTP":false,"toolNameCompatibility":"strict","syncRevision":7,"secret":{"configured":true,"synchronizable":false}}]}"""
                    "config.catalog.search" -> """{"rows":[]}"""
                    "config.models.list" ->
                        if (modelRowJSON.isBlank()) """{"rows":[]}"""
                        else """{"rows":[$modelRowJSON]}"""
                    "config.preferences.get" -> """{"preferences":{}}"""
                    else -> "{}"
                }
                return completedPage(correlation, receipt, value)
            }
            val command = COMMAND_PATTERN.find(request)?.groupValues?.get(1) ?: "unknown"
            val minted = "op:v1:repair${counter.incrementAndGet()}"
            receiptCommands[minted] = command
            return """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"$minted"}"""
        }

        private fun completedPage(correlation: String, receipt: String, value: String): String =
            """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":1},"effects":[{"sequence":1,"kind":"accepted","value":$value}],"hasMore":false,"resyncRequired":false}"""

        companion object {
            val COMMAND_PATTERN = Regex("\"command\":\"([^\"]+)\"")
            const val PROVIDER_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
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
        host.onBootstrapCapability(RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("providerConfigurationDomain", true, emptyList())
        host.nativeRootEpochReader = { 31L }
        return host
    }

    private fun controller(host: RuntimeHost = host(Exchange())): ProviderHostController =
        ProviderHostController(host, object : HostRouteAuthority {
            override fun open(
                kind: HostEditorKind,
                editorID: String,
                uiGeneration: Long,
                expectedNativeRootEpoch: Long,
            ): String? = null

            override fun clear(token: String) = Unit
        })

    private suspend fun waitUntil(timeoutMillis: Long = 3_000, predicate: () -> Boolean) {
        val deadline = System.nanoTime() + timeoutMillis * 1_000_000L
        while (System.nanoTime() < deadline) {
            if (predicate()) return
            delay(10)
        }
        assertTrue("condition not reached", predicate())
    }

    private fun envelope(raw: String): JsonObject =
        (Json.parseToJsonElement(raw) as JsonObject)["envelope"] as JsonObject

    @Test fun repairCarrierIsExactSnapshotPlusExplicitOnly() {
        val row = decodedRow()
        val command = controller().capabilityRepairCommand(row, "${model.uppercase()}|v1")!!
        assertEquals("config.model.save", command.request.command)
        assertEquals(HostScope.ApplicationConfiguration("models"), command.request.scope)
        assertTrue(command.request.stateful)
        assertEquals(HostRevision("model.$model", "v1"), command.request.revision)
        val payload = command.request.payload as JsonObject
        assertFalse("the native revision member is not a snapshot field",
            payload.containsKey("revision"))
        assertEquals(39, payload["explicitCapabilities"]!!.jsonPrimitive.int)
        // Unknown/extension members that the persisted row carries survive
        // byte-for-byte at the payload boundary.
        assertEquals(5, payload["useSurfaces"]!!.jsonPrimitive.int)
        assertEquals("high", payload["reasoningEffort"]!!.jsonPrimitive.content)
        assertEquals(8192, payload["limits"]!!.jsonObject["contextTokens"]!!.jsonPrimitive.int)
        assertEquals(true, payload["isEnabled"]!!.jsonPrimitive.boolean)

        val original = row.originalProjection!!.filterKeys { it != "revision" }
        val expected = JsonObject(LinkedHashMap(original).apply {
            put("explicitCapabilities", JsonPrimitive(39))
        })
        assertEquals(expected, payload)
    }

    @Test fun unknownBaseCapabilityBitIsPreservedInRepairedExplicit() {
        val futureBit = 1 shl 25
        val row = decodedRow(capabilities = 39, explicit = 2, extraCapabilityBit = futureBit)
        assertEquals(39 or futureBit, row.capabilitiesRaw)
        // The complete base selected value is the source; only unknown
        // non-editable metadata may be carried over from the ownership mask.
        assertEquals(39 or futureBit,
            ProviderFormLogic.repairedLegacyExplicitCapabilities(
                row.capabilitiesRaw, row.savedMetadata?.explicitCapabilitiesRaw))
    }

    @Test fun onlyProvablyInvalidConversationDeltaRowsProduceRepairCarriers() {
        val controller = controller()
        fun repairedExplicit(capabilities: Int, explicit: Int?): Int? =
            controller.capabilityRepairCommand(
                decodedRow(capabilities = capabilities, explicit = explicit), "a|v1")
                ?.request?.payload?.let { (it as JsonObject)["explicitCapabilities"]!!.jsonPrimitive.int }

        // Main's exact ownership-mask cases: derive FROM the complete base.
        assertEquals(37, repairedExplicit(37, 2))
        assertEquals(39, repairedExplicit(39, 2))
        assertEquals(35, repairedExplicit(35, 6))
        assertEquals(33, repairedExplicit(33, 4))
        // Reviewed zero, approval-only and non-conversation media overrides
        // are complete authoritative decisions: never repaired/promoted.
        assertNull(repairedExplicit(37, 0))
        assertNull(repairedExplicit(39, 0))
        assertNull(repairedExplicit(37, 32))
        assertNull(repairedExplicit(24, 8))
        // An unknown non-editable bit makes the mask unprovable: skip it.
        assertNull(repairedExplicit(37, 2 or (1 shl 25)))
        // Valid complete explicit with TEXT keeps its authority.
        assertNull(repairedExplicit(39, 35))
        assertNull(repairedExplicit(39, 39))
        assertNull(repairedExplicit(39, 1))
        // Nil provenance and media rows are never touched.
        assertNull(repairedExplicit(39, null))
        assertNull(controller.capabilityRepairCommand(
            decodedRow(capabilities = ModelCapabilityUi.IMAGE_GENERATION.swiftBit
                or ModelCapabilityUi.IMAGE_EDITING.swiftBit, explicit = 2), "a|v1"))
    }

    @Test fun reviewedAndMediaOverridesProduceNoMigrationCommandAtAll() {
        val second = "cccccccc-cccc-cccc-cccc-cccccccccccc"
        val third = "dddddddd-dddd-dddd-dddd-dddddddddddd"
        val fourth = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
        val exchange = Exchange()
        val controller = controller(host(exchange))
        controller.repairProviders = { listOf(providerRow()) }
        controller.repairModelRows = {
            listOf(
                decodedRow(capabilities = 37, explicit = 0),
                decodedRow(capabilities = 37, explicit = 32, id = second,
                    revisionResourceID = "model.$second"),
                decodedRow(capabilities = 24, explicit = 8, id = third,
                    revisionResourceID = "model.$third"),
                decodedRow(capabilities = 37, explicit = 2 or (1 shl 25), id = fourth,
                    revisionResourceID = "model.$fourth"),
            )
        }
        assertTrue(controller.capabilityRepairCommands().isEmpty())
        controller.dispatchCapabilityRepairPass()
        runBlocking { delay(250) }
        assertTrue(exchange.saveRequests().isEmpty())
    }

    @Test fun completeSweepRepairsOnlyTheProvenLegacyRow() = runBlocking {
        val legacy = model
        val reviewed = "cccccccc-cccc-cccc-cccc-cccccccccccc"
        val media = "dddddddd-dddd-dddd-dddd-dddddddddddd"
        val valid = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
        val exchange = Exchange()
        val controller = controller(host(exchange))
        controller.repairProviders = { listOf(providerRow()) }
        controller.repairModelRows = {
            listOf(
                decodedRow(capabilities = 37, explicit = 2),
                decodedRow(capabilities = 37, explicit = 0, id = reviewed,
                    revisionResourceID = "model.$reviewed"),
                decodedRow(capabilities = 24, explicit = 8, id = media,
                    revisionResourceID = "model.$media"),
                decodedRow(capabilities = 39, explicit = 35, id = valid,
                    revisionResourceID = "model.$valid"),
            )
        }
        val commands = controller.capabilityRepairCommands()
        assertEquals(1, commands.size)
        assertEquals(HostRevision("model.$legacy", "v1"), commands.single().request.revision)

        controller.dispatchCapabilityRepairPass()
        waitUntil { exchange.saveRequests().size == 1 }
        delay(250)
        // Exactly one write: every reviewed/media/valid row was left alone.
        assertEquals(1, exchange.saveRequests().size)
        val command = envelope(exchange.saveRequests().single())
        assertEquals("model.$legacy", command["revision"]!!.jsonObject["resourceID"]!!.jsonPrimitive.content)
        assertEquals(37, command["payload"]!!.jsonObject["explicitCapabilities"]!!.jsonPrimitive.int)
    }

    @Test fun missingOrForeignRevisionRefusesInsteadOfFabricatingACasToken() {
        val controller = controller()
        val missingRevision = ModelRowWithoutRevision()
        assertNull(controller.capabilityRepairCommand(missingRevision.row, "a|v1"))
        // Foreign resource identity must not be reused as this model's CAS.
        assertNull(controller.capabilityRepairCommand(
            decodedRow(revisionResourceID = "model.cccccccc-cccc-cccc-cccc-cccccccccccc"),
            "a|v1"))
    }

    @Test fun refusedAtomicRepairPreservesRecordAndNeverRetriesSameRevision() = runBlocking {
        val exchange = Exchange(modelRowJSON = modelRowObject().toString(),
            rejectModelSave = true)
        val host = host(exchange)
        val controller = controller(host)
        controller.repairProviders = {
            listOf(ProviderListRowUi(
                providerId = provider, displayName = "Legacy",
                endpointSummary = "https://example.invalid/v1", modelCount = 1,
                enabled = true, credentialState = ProviderCredentialStateUi.CONFIGURED,
                revisionVersion = "7",
            ))
        }
        val row = decodedRow()
        controller.repairModelRows = { listOf(row) }

        controller.dispatchCapabilityRepairPass()
        waitUntil { exchange.saveRequests().isNotEmpty() }
        val command = envelope(exchange.saveRequests().single())
        assertEquals("config.model.save", command["command"]!!.jsonPrimitive.content)
        assertEquals("models", command["configurationScope"]!!.jsonPrimitive.content)
        val revision = command["revision"]!!.jsonObject
        assertEquals("model.$model", revision["resourceID"]!!.jsonPrimitive.content)
        assertEquals("v1", revision["version"]!!.jsonPrimitive.content)
        assertEquals(39, command["payload"]!!.jsonObject["explicitCapabilities"]!!.jsonPrimitive.int)

        // A typed refusal writes nothing and the SAME revision is never
        // replayed: the original record is preserved as the only truth.
        delay(250)
        assertEquals(1, exchange.saveRequests().size)
        assertTrue(controller.capabilityRepairCommands().isEmpty())
        assertEquals(2, row.originalProjection!!["explicitCapabilities"]!!.jsonPrimitive.int)
    }

    @Test fun completeLoadedSweepTriggersOneTargetedRepairAndIsIdempotent() = runBlocking {
        val exchange = Exchange(modelRowJSON = modelRowObject().toString())
        val controller = controller(host(exchange))
        controller.repairProviders = {
            listOf(ProviderListRowUi(
                providerId = provider, displayName = "Legacy",
                endpointSummary = "https://example.invalid/v1", modelCount = 1,
                enabled = true, credentialState = ProviderCredentialStateUi.CONFIGURED,
                revisionVersion = "7",
            ))
        }
        controller.repairModelRows = { listOf(decodedRow()) }

        controller.maybeRepairLegacyCapabilityOverrides(loaded = true, sweep = 1)
        waitUntil { exchange.saveRequests().size == 1 }
        val command = envelope(exchange.saveRequests().single())
        assertEquals("config.model.save", command["command"]!!.jsonPrimitive.content)
        assertEquals(39, command["payload"]!!.jsonObject["explicitCapabilities"]!!.jsonPrimitive.int)

        // The same sweep is never re-offered, and the exact revision is never
        // replayed even by a later projection of the same (fake) row.
        controller.maybeRepairLegacyCapabilityOverrides(loaded = true, sweep = 1)
        delay(250)
        assertEquals(1, exchange.saveRequests().size)
    }

    @Test fun composerVisibilityUsesTheSameEffectiveMaskAsRunAdmission() {
        // Before repair: run sees explicit=2 (no text) and refuses; the
        // composer must not offer that model.
        assertFalse(decodedRow(explicit = 2).supportsText)
        assertTrue(decodedRow(explicit = 35).supportsText)
        // Explicit Tools off does not hide a text model.
        assertTrue(decodedRow(explicit = 33).supportsText)
        // Reviewed zero / approval-only are genuinely text-less decisions:
        // the picker hides them until the user edits, even though the base
        // row may still carry the TEXT catalog bit.
        assertFalse(decodedRow(capabilities = 37, explicit = 0).supportsText)
        assertFalse(decodedRow(capabilities = 37, explicit = 32).supportsText)
    }

    private class ModelRowWithoutRevision {
        val row: ProviderWire.ModelRow = ProviderWire.decodeModelRows(
            Json.parseToJsonElement(
                """{"rows":[{"id":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",""" +
                    """"providerID":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",""" +
                    """"remoteModelID":"wire-model","displayName":"Legacy",""" +
                    """"limits":{"contextTokens":8192,"maxOutputTokens":512},""" +
                    """"capabilities":39,"explicitCapabilities":2,"isEnabled":true}]}""",
            ),
        )!!.single()
    }
}
