// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * R4 deferred behavior tests — AUTHORED, NOTRUN (no JVM/Gradle execution in
 * the source phase; Main runs them in the composed batch). Scripted
 * transport double only.
 *
 * Covers: lossless full-document CAS saves (untouched/unknown fields
 * preserved, only the drafted slot changed); honest stale-revision refusal
 * with draft preservation; original capability/use-surface eligibility
 * rules; unavailable selections preserved (never silently replaced); the
 * original shared↔separate media-mode transition; explicit clears winning
 * over saved values.
 */
class SettingsRolePreferencesTest {

    private class CaptureExchange(
        initialPreferencesGet: String,
        private val saveEffect: (envelope: JsonObject, callIndex: Int) -> String,
    ) : HostBridgeExchange {
        val requests = mutableListOf<String>()
        var preferencesGet: String = initialPreferencesGet
        private var saveCalls = 0
        private var saveFrame: String? = null

        /** Gates for mid-flight edit tests: a closed gate answers polls with
         * a non-terminal frame so the operation stays in flight. */
        var saveGateReleased = true
        var getGateReleased = true

        override fun exchange(request: String): String {
            requests.add(request)
            val correlation = correlationOf(request)
            if (request.contains("\"operation\":\"effect.poll\"")) {
                val receipt = receiptOf(request)
                if (receipt == "op:v1:save") {
                    if (!saveGateReleased) return pending(correlation, receipt)
                    return saveEffectFrame(correlation, receipt)
                }
                if (receipt == "op:v1:prefget" && !getGateReleased) {
                    return pending(correlation, receipt)
                }
                val page = when (receipt) {
                    "op:v1:prefget" -> preferencesGet
                    "op:v1:plist" -> PROVIDERS_PAGE
                    "op:v1:mlist" -> MODELS_PAGE
                    else -> return """{"version":3,"requestID":"$correlation","ok":false,"schema":"floe.effect-cursor/3","correlationID":"$correlation","error":"unknownReceipt"}"""
                }
                return completed(correlation, receipt, page)
            }
            if (request.contains("\"command\":\"config.preferences.save\"")) {
                val envelope = (Json.parseToJsonElement(request) as JsonObject)
                    .let { it["envelope"] as JsonObject }
                saveFrame = saveEffect(envelope, saveCalls++)
                return """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"op:v1:save"}"""
            }
            return when {
                request.contains("\"command\":\"config.preferences.get\"") ->
                    """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"op:v1:prefget"}"""
                request.contains("\"command\":\"config.providers.list\"") ->
                    """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"op:v1:plist"}"""
                request.contains("\"command\":\"config.models.list\"") ->
                    """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"op:v1:mlist"}"""
                else ->
                    """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"op:v1:x"}"""
            }
        }

        /** The save effect frame (accepted page or typed rejection). */
        fun saveEffectFrame(correlation: String, receipt: String): String =
            saveFrame?.replace("CORRELATION", correlation)
                ?: """{"version":3,"requestID":"$correlation","ok":false,"schema":"floe.effect-cursor/3","correlationID":"$correlation","error":"unknownReceipt"}"""

        private fun pending(correlation: String, receipt: String) =
            """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":0},"effects":[],"hasMore":true,"resyncRequired":false}"""

        fun saveEnvelopes(): List<JsonObject> = requests
            .filter { it.contains("\"command\":\"config.preferences.save\"") }
            .map { Json.parseToJsonElement(it) as JsonObject }
            .map { it["envelope"] as JsonObject }

        private fun completed(correlation: String, receipt: String, page: String) =
            """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":1},"effects":[{"sequence":1,"kind":"accepted","page":$page}],"hasMore":false,"resyncRequired":false}"""
    }

    private fun testHost(exchange: HostBridgeExchange): RuntimeHost {
        val client = RuntimeHostCommandClient(
            exchange = exchange,
            scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default),
            ioDispatcher = kotlinx.coroutines.Dispatchers.Default,
            budgets = HostWireBudgets(effectPollIntervalMillis = 1),
        )
        return RuntimeHost(
            commandClient = client,
            gatewayCapability = kotlinx.coroutines.flow.MutableStateFlow(
                com.floe.android.SecretGatewayCapability.Loading),
            bootstrapCapability = kotlinx.coroutines.flow.MutableStateFlow(
                com.floe.android.RuntimeBootstrapCapability.Idle),
            scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default),
            ioDispatcher = kotlinx.coroutines.Dispatchers.Default,
        )
    }

    private fun preferencesDoc(
        defaultAgent: String? = "11111111-1111-1111-1111-111111111111",
        auxiliary: String? = null,
        canvas: String? = "22222222-2222-2222-2222-222222222222",
        vision: String? = "33333333-3333-3333-3333-333333333333",
        mode: String = "separate",
        routing: Boolean = true,
        syncRevision: Int = 7,
    ): String {
        fun uuidOrNull(value: String?): String =
            value?.let { "\"$it\"" } ?: "null"
        return """{"revision":{"resourceID":"preferences","version":$syncRevision},"preferences":{""" +
            """"onboardingStatus":"completed",""" +
            """"defaultAgentModelID":${uuidOrNull(defaultAgent)},""" +
            """"generalAuxiliaryLLMModelID":${uuidOrNull(auxiliary)},""" +
            """"canvasAgentModelID":${uuidOrNull(canvas)},""" +
            """"visionModelID":${uuidOrNull(vision)},""" +
            """"canvasVisionModelID":null,""" +
            """"approvalModelID":null,""" +
            """"packageReviewModelID":null,""" +
            """"autonomousImageRouting":$routing,""" +
            """"auxiliaryImageMode":"$mode",""" +
            """"sharedImageModelID":null,""" +
            """"imageGenerationModelID":null,""" +
            """"imageEditingModelID":null,""" +
            """"defaultVideoModelID":null,""" +
            """"updatedAt":"2026-10-21T00:00:00Z","syncRevision":$syncRevision}}"""
    }

    @Test
    fun refreshDecodesEverySlotAndNeverAutoassigns() = runBlocking {
        val exchange = CaptureExchange(
            initialPreferencesGet = preferencesDoc(),
            saveEffect = { _, _ ->
                "{\"version\":3,\"requestID\":\"CORRELATION\",\"ok\":true,\"schema\":\"floe.effect-cursor/3\",\"correlationID\":\"CORRELATION\",\"cursor\":{\"operationReceiptID\":\"op:v1:save\",\"sequence\":1},\"effects\":[{\"sequence\":1,\"kind\":\"accepted\",\"page\":{\"revision\":{\"resourceID\":\"preferences\",\"version\":8},\"preferences\":{}}}],\"hasMore\":false,\"resyncRequired\":false}"
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.settings.roles.refresh()
        kotlinx.coroutines.delay(300)
        val state = host.settings.roles.state.value
        assertTrue(!state.loading)
        assertNull(state.error)
        assertEquals("7", state.revision)
        assertEquals("11111111-1111-1111-1111-111111111111",
            state.saved[SettingsRoleModelController.RoleSlot.DEFAULT_AGENT])
        // Null slots stay null: reads NEVER autoassign defaults.
        assertNull(state.saved[SettingsRoleModelController.RoleSlot.GENERAL_AUXILIARY_LLM])
        assertEquals("22222222-2222-2222-2222-222222222222",
            state.saved[SettingsRoleModelController.RoleSlot.CANVAS_AGENT])
        assertEquals("33333333-3333-3333-3333-333333333333",
            state.saved[SettingsRoleModelController.RoleSlot.VISION])
        assertNull(state.saved[SettingsRoleModelController.RoleSlot.PACKAGE_REVIEW])
        assertEquals(SettingsRoleModelController.MODE_SEPARATE, state.auxiliaryImageMode)
        assertTrue(state.autonomousImageRouting)
    }

    @Test
    fun saveCopiesWholeDocumentAndChangesOnlyDraftedSlot() = runBlocking {
        val exchange = CaptureExchange(
            initialPreferencesGet = preferencesDoc(),
            saveEffect = { _, _ ->
                "{\"version\":3,\"requestID\":\"CORRELATION\",\"ok\":true,\"schema\":\"floe.effect-cursor/3\",\"correlationID\":\"CORRELATION\",\"cursor\":{\"operationReceiptID\":\"op:v1:save\",\"sequence\":1},\"effects\":[{\"sequence\":1,\"kind\":\"accepted\",\"page\":{\"revision\":{\"resourceID\":\"preferences\",\"version\":8},\"preferences\":{}}}],\"hasMore\":false,\"resyncRequired\":false}"
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.settings.roles.refresh()
        kotlinx.coroutines.delay(300)
        host.settings.roles.select(
            SettingsRoleModelController.RoleSlot.VISION,
            "44444444-4444-4444-4444-444444444444",
        )
        assertTrue(host.settings.roles.state.value.hasDraftChanges)
        host.settings.roles.save()
        kotlinx.coroutines.delay(300)
        val envelope = exchange.saveEnvelopes().single()
        val revision = envelope["revision"] as JsonObject
        assertEquals("preferences", (revision["resourceID"] as JsonPrimitive).content)
        assertEquals("7", (revision["version"] as JsonPrimitive).content)
        val payload = envelope["payload"] as JsonObject
        // EVERY untouched original field is preserved verbatim.
        assertEquals("completed",
            (payload["onboardingStatus"] as JsonPrimitive).content)
        assertEquals("11111111-1111-1111-1111-111111111111",
            (payload["defaultAgentModelID"] as JsonPrimitive).content)
        assertEquals("22222222-2222-2222-2222-222222222222",
            (payload["canvasAgentModelID"] as JsonPrimitive).content)
        assertEquals(SettingsRoleModelController.MODE_SEPARATE,
            (payload["auxiliaryImageMode"] as JsonPrimitive).content)
        assertEquals(true, (payload["autonomousImageRouting"] as JsonPrimitive).content)
        // Only the drafted slot changed; syncRevision is echoed for the
        // writer's full-snapshot CAS gate.
        assertEquals("44444444-4444-4444-4444-444444444444",
            (payload["visionModelID"] as JsonPrimitive).content)
        assertEquals(7L, (payload["syncRevision"] as JsonPrimitive).content.toLong())
        // The save succeeded: the drafted slot was consumed.
        assertTrue(!host.settings.roles.state.value.hasDraftChanges)
    }

    @Test
    fun staleCasRefusesAndPreservesDraftForRetry() = runBlocking {
        var saveCalls = 0
        val successFrame =
            "{\"version\":3,\"requestID\":\"CORRELATION\",\"ok\":true,\"schema\":\"floe.effect-cursor/3\",\"correlationID\":\"CORRELATION\",\"cursor\":{\"operationReceiptID\":\"op:v1:save\",\"sequence\":1},\"effects\":[{\"sequence\":1,\"kind\":\"accepted\",\"page\":{\"revision\":{\"resourceID\":\"preferences\",\"version\":8},\"preferences\":{}}}],\"hasMore\":false,\"resyncRequired\":false}"
        val staleFrame =
            "{\"version\":3,\"requestID\":\"CORRELATION\",\"ok\":true,\"schema\":\"floe.effect-cursor/3\",\"correlationID\":\"CORRELATION\",\"cursor\":{\"operationReceiptID\":\"op:v1:save\",\"sequence\":1},\"effects\":[{\"sequence\":1,\"kind\":\"rejected\",\"code\":\"staleRevision\",\"detail\":[{\"key\":\"reason\",\"value\":\"preferencesCasGate\"}]}],\"hasMore\":false,\"resyncRequired\":false}"
        val exchange = CaptureExchange(
            initialPreferencesGet = preferencesDoc(syncRevision = 7),
            saveEffect = { _, _ ->
                saveCalls++
                // The first save wins the native CAS; the second one races an
                // external revision bump and is refused with zero overwrite.
                if (saveCalls == 1) successFrame else staleFrame
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.settings.roles.refresh()
        kotlinx.coroutines.delay(250)
        host.settings.roles.select(
            SettingsRoleModelController.RoleSlot.VISION, "44444444-4444-4444-4444-444444444444")
        host.settings.roles.save()
        kotlinx.coroutines.delay(300)
        assertTrue(!host.settings.roles.state.value.hasDraftChanges)

        host.settings.roles.select(
            SettingsRoleModelController.RoleSlot.APPROVAL, "55555555-5555-5555-5555-555555555555")
        host.settings.roles.save()
        kotlinx.coroutines.delay(300)
        val state = host.settings.roles.state.value
        // The stale refusal surfaces typed; the DRAFT survives for an
        // explicit retry — nothing is auto-replayed, nothing is lost.
        assertEquals("staleRevision", state.saveError)
        assertEquals("55555555-5555-5555-5555-555555555555",
            state.draft[SettingsRoleModelController.RoleSlot.APPROVAL])
    }

    @Test
    fun eligibilityFollowsOriginalCapabilityAndSurfaceRules() {
        val host = testHost(CaptureExchange(
            initialPreferencesGet = preferencesDoc(),
            saveEffect = { _, _ ->
                "{\"version\":3,\"requestID\":\"CORRELATION\",\"ok\":true,\"schema\":\"floe.effect-cursor/3\",\"correlationID\":\"CORRELATION\",\"cursor\":{\"operationReceiptID\":\"op:v1:save\",\"sequence\":1},\"effects\":[{\"sequence\":1,\"kind\":\"accepted\",\"page\":{\"revision\":{\"resourceID\":\"preferences\",\"version\":8},\"preferences\":{}}}],\"hasMore\":false,\"resyncRequired\":false}"
            },
        ))
        val roles = host.settings.roles
        val capsText = 1            // TEXT
        val capsTextVision = 1 or 2 // TEXT | VISION
        val capsMediaGen = 8        // IMAGE_GENERATION
        val capsApproval = 1 or 32  // TEXT | APPROVAL

        // A media model never leaks into text/vision/approval pickers.
        assertTrue(!roles.eligibleFor(
            SettingsRoleModelController.RoleSlot.GENERAL_AUXILIARY_LLM, capsMediaGen, null))
        assertTrue(!roles.eligibleFor(
            SettingsRoleModelController.RoleSlot.VISION, capsMediaGen, null))
        assertTrue(!roles.eligibleFor(
            SettingsRoleModelController.RoleSlot.APPROVAL, capsMediaGen, null))
        assertTrue(!roles.eligibleFor(
            SettingsRoleModelController.RoleSlot.DEFAULT_AGENT, capsMediaGen, null))
        assertTrue(roles.eligibleFor(
            SettingsRoleModelController.RoleSlot.IMAGE_GENERATION, capsMediaGen, null))

        // Vision requires the dedicated surface + vision capability.
        assertTrue(roles.eligibleFor(
            SettingsRoleModelController.RoleSlot.VISION, capsTextVision, null))
        assertTrue(!roles.eligibleFor(
            SettingsRoleModelController.RoleSlot.VISION, capsText, null))

        // A saved useSurfaces decision wins over the derived fallback:
        // chatAgent explicitly removed excludes the default-agent picker.
        val surfacesNoChat = (1 shl 1) // AUX_VISION only
        assertTrue(!roles.eligibleFor(
            SettingsRoleModelController.RoleSlot.DEFAULT_AGENT, capsTextVision, surfacesNoChat))
        assertTrue(roles.eligibleFor(
            SettingsRoleModelController.RoleSlot.VISION, capsTextVision, surfacesNoChat))

        // Approval surface needs TEXT + APPROVAL and no media caps.
        assertTrue(roles.eligibleFor(
            SettingsRoleModelController.RoleSlot.APPROVAL, capsApproval, null))
        assertTrue(roles.eligibleFor(
            SettingsRoleModelController.RoleSlot.PACKAGE_REVIEW, capsApproval, null))
    }

    @Test
    fun unavailableSelectionIsPreservedAndNeverReplaced() = runBlocking {
        // The saved default agent is NOT among the configured models.
        val exchange = CaptureExchange(
            initialPreferencesGet = preferencesDoc(defaultAgent = "99999999-9999-9999-9999-999999999999"),
            saveEffect = { _, _ ->
                "{\"version\":3,\"requestID\":\"CORRELATION\",\"ok\":true,\"schema\":\"floe.effect-cursor/3\",\"correlationID\":\"CORRELATION\",\"cursor\":{\"operationReceiptID\":\"op:v1:save\",\"sequence\":1},\"effects\":[{\"sequence\":1,\"kind\":\"accepted\",\"page\":{\"revision\":{\"resourceID\":\"preferences\",\"version\":8},\"preferences\":{}}}],\"hasMore\":false,\"resyncRequired\":false}"
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.settings.roles.refresh()
        kotlinx.coroutines.delay(300)
        val state = host.settings.roles.state.value
        val slotState = state.slotState(SettingsRoleModelController.RoleSlot.DEFAULT_AGENT)
        assertEquals(SettingsRoleModelController.SelectionStatus.UNAVAILABLE, slotState.status)
        assertEquals("99999999-9999-9999-9999-999999999999", slotState.selection)

        // Saving an UNRELATED slot keeps the unavailable id byte-identical.
        host.settings.roles.select(
            SettingsRoleModelController.RoleSlot.VISION, "33333333-3333-3333-3333-333333333333")
        host.settings.roles.save()
        kotlinx.coroutines.delay(300)
        val payload = exchange.saveEnvelopes().single()["payload"] as JsonObject
        assertEquals("99999999-9999-9999-9999-999999999999",
            (payload["defaultAgentModelID"] as JsonPrimitive).content)
    }

    @Test
    fun sharedSeparateTransitionFollowsOriginalCapabilities() = runBlocking {
        val exchange = CaptureExchange(
            initialPreferencesGet = preferencesDoc(mode = "shared"),
            saveEffect = { _, _ ->
                "{\"version\":3,\"requestID\":\"CORRELATION\",\"ok\":true,\"schema\":\"floe.effect-cursor/3\",\"correlationID\":\"CORRELATION\",\"cursor\":{\"operationReceiptID\":\"op:v1:save\",\"sequence\":1},\"effects\":[{\"sequence\":1,\"kind\":\"accepted\",\"page\":{\"revision\":{\"resourceID\":\"preferences\",\"version\":8},\"preferences\":{}}}],\"hasMore\":false,\"resyncRequired\":false}"
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.settings.roles.refresh()
        kotlinx.coroutines.delay(300)
        // Seed a shared media choice: model 7777 has generation+editing caps.
        host.settings.roles.select(
            SettingsRoleModelController.RoleSlot.SHARED_IMAGE,
            "77777777-7777-7777-7777-777777777777",
        )
        host.settings.roles.setAuxiliaryMode(separate = true)
        var draft = host.settings.roles.state.value.draft
        assertEquals("77777777-7777-7777-7777-777777777777",
            draft[SettingsRoleModelController.RoleSlot.IMAGE_GENERATION])
        assertEquals("77777777-7777-7777-7777-777777777777",
            draft[SettingsRoleModelController.RoleSlot.IMAGE_EDITING])
        assertTrue(draft.containsKey(SettingsRoleModelController.RoleSlot.SHARED_IMAGE))
        assertNull(draft[SettingsRoleModelController.RoleSlot.SHARED_IMAGE])

        // Back to shared: same model serves both → it becomes the shared one.
        host.settings.roles.setAuxiliaryMode(separate = false)
        draft = host.settings.roles.state.value.draft
        assertEquals("77777777-7777-7777-7777-777777777777",
            draft[SettingsRoleModelController.RoleSlot.SHARED_IMAGE])
        assertNull(draft[SettingsRoleModelController.RoleSlot.IMAGE_GENERATION])
        assertNull(draft[SettingsRoleModelController.RoleSlot.IMAGE_EDITING])
    }

    @Test
    fun explicitClearBeatsSavedValueInPayload() = runBlocking {
        val exchange = CaptureExchange(
            initialPreferencesGet = preferencesDoc(),
            saveEffect = { _, _ ->
                "{\"version\":3,\"requestID\":\"CORRELATION\",\"ok\":true,\"schema\":\"floe.effect-cursor/3\",\"correlationID\":\"CORRELATION\",\"cursor\":{\"operationReceiptID\":\"op:v1:save\",\"sequence\":1},\"effects\":[{\"sequence\":1,\"kind\":\"accepted\",\"page\":{\"revision\":{\"resourceID\":\"preferences\",\"version\":8},\"preferences\":{}}}],\"hasMore\":false,\"resyncRequired\":false}"
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.settings.roles.refresh()
        kotlinx.coroutines.delay(250)
        // Clear the saved canvas agent: the draft holds an explicit null and
        // the save payload must write JsonNull, not the old id.
        host.settings.roles.select(SettingsRoleModelController.RoleSlot.CANVAS_AGENT, null)
        val slotState = host.settings.roles.state.value
            .slotState(SettingsRoleModelController.RoleSlot.CANVAS_AGENT)
        assertEquals(SettingsRoleModelController.SelectionStatus.EMPTY, slotState.status)
        host.settings.roles.save()
        kotlinx.coroutines.delay(250)
        val payload = exchange.saveEnvelopes().single()["payload"] as JsonObject
        assertTrue(payload["canvasAgentModelID"] is JsonNull)
    }

    @Test
    fun midFlightSameSlotEditSurvivesSaveSuccess() = runBlocking {
        val exchange = CaptureExchange(
            initialPreferencesGet = preferencesDoc(),
            saveEffect = { _, _ -> successFrame() },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.settings.roles.refresh()
        kotlinx.coroutines.delay(250)
        // Freeze the save in flight.
        exchange.saveGateReleased = false
        host.settings.roles.select(
            SettingsRoleModelController.RoleSlot.VISION, "44444444-4444-4444-4444-444444444444")
        host.settings.roles.save()
        kotlinx.coroutines.delay(250)
        // Mid-flight: the user changes the SAME slot to a newer model.
        host.settings.roles.select(
            SettingsRoleModelController.RoleSlot.VISION, "66666666-6666-6666-6666-666666666666")
        exchange.saveGateReleased = true
        kotlinx.coroutines.delay(300)
        val state = host.settings.roles.state.value
        // The newer same-slot choice survives; the save consumed nothing.
        assertEquals("66666666-6666-6666-6666-666666666666",
            state.draft[SettingsRoleModelController.RoleSlot.VISION])
        // The persisted truth for the slot is what the save carried.
        assertEquals("44444444-4444-4444-4444-444444444444",
            state.saved[SettingsRoleModelController.RoleSlot.VISION])
    }

    @Test
    fun midFlightSameSlotClearSurvivesSaveSuccess() = runBlocking {
        val exchange = CaptureExchange(
            initialPreferencesGet = preferencesDoc(),
            saveEffect = { _, _ -> successFrame() },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.settings.roles.refresh()
        kotlinx.coroutines.delay(250)
        exchange.saveGateReleased = false
        host.settings.roles.select(
            SettingsRoleModelController.RoleSlot.VISION, "44444444-4444-4444-4444-444444444444")
        host.settings.roles.save()
        kotlinx.coroutines.delay(250)
        // Mid-flight: the user CLEARS the same slot.
        host.settings.roles.select(SettingsRoleModelController.RoleSlot.VISION, null)
        exchange.saveGateReleased = true
        kotlinx.coroutines.delay(300)
        val state = host.settings.roles.state.value
        // The explicit clear (containsKey null) survives the save.
        assertTrue(state.draft.containsKey(SettingsRoleModelController.RoleSlot.VISION))
        assertNull(state.draft[SettingsRoleModelController.RoleSlot.VISION])
        assertEquals("44444444-4444-4444-4444-444444444444",
            state.saved[SettingsRoleModelController.RoleSlot.VISION])
    }

    @Test
    fun staleSavePreservesNewerSameSlotChoiceForRetry() = runBlocking {
        var saveCalls = 0
        val exchange = CaptureExchange(
            initialPreferencesGet = preferencesDoc(),
            saveEffect = { _, _ ->
                saveCalls++
                if (saveCalls == 1) successFrame() else staleFrame()
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.settings.roles.refresh()
        kotlinx.coroutines.delay(250)
        exchange.saveGateReleased = false
        host.settings.roles.select(
            SettingsRoleModelController.RoleSlot.VISION, "44444444-4444-4444-4444-444444444444")
        host.settings.roles.save()
        kotlinx.coroutines.delay(250)
        host.settings.roles.select(
            SettingsRoleModelController.RoleSlot.VISION, "66666666-6666-6666-6666-666666666666")
        exchange.saveGateReleased = true
        kotlinx.coroutines.delay(300)
        // The stale refusal surfaces typed; the NEWER value is what the
        // retry will persist — never the frozen mid-flight snapshot.
        val state = host.settings.roles.state.value
        assertEquals("staleRevision", state.saveError)
        assertEquals("66666666-6666-6666-6666-666666666666",
            state.draft[SettingsRoleModelController.RoleSlot.VISION])
    }

    @Test
    fun untouchedScalarsComeFromFreshDocumentNotWorkingSnapshot() = runBlocking {
        // Another settings editor rewrites the document between our page
        // load and the save: mode separate→shared, routing true→false.
        val exchange = CaptureExchange(
            initialPreferencesGet = preferencesDoc(),
            saveEffect = { _, _ -> successFrame() },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.settings.roles.refresh()
        kotlinx.coroutines.delay(250)
        assertEquals(SettingsRoleModelController.MODE_SEPARATE,
            host.settings.roles.state.value.auxiliaryImageMode)
        exchange.preferencesGet = preferencesDoc(mode = "shared", routing = false)
        host.settings.roles.select(
            SettingsRoleModelController.RoleSlot.VISION, "44444444-4444-4444-4444-444444444444")
        host.settings.roles.save()
        kotlinx.coroutines.delay(300)
        val payload = exchange.saveEnvelopes().single()["payload"] as JsonObject
        // Untouched scalars carry the FRESH document values.
        assertEquals(SettingsRoleModelController.MODE_SHARED,
            (payload["auxiliaryImageMode"] as JsonPrimitive).content)
        assertEquals(false, (payload["autonomousImageRouting"] as JsonPrimitive).content)
    }

    @Test
    fun dirtyScalarsWriteWorkingValueWhileCleanOnesFollowDocument() = runBlocking {
        val exchange = CaptureExchange(
            initialPreferencesGet = preferencesDoc(),
            saveEffect = { _, _ -> successFrame() },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.settings.roles.refresh()
        kotlinx.coroutines.delay(250)
        // External rewrite: mode becomes shared; our working copy still says
        // separate until a refresh lands.
        exchange.preferencesGet = preferencesDoc(mode = "shared", routing = false)
        // The user dirties ONLY routing.
        host.settings.roles.setAutonomousImageRouting(false)
        host.settings.roles.select(
            SettingsRoleModelController.RoleSlot.VISION, "44444444-4444-4444-4444-444444444444")
        host.settings.roles.save()
        kotlinx.coroutines.delay(300)
        val payload = exchange.saveEnvelopes().single()["payload"] as JsonObject
        // Routing: dirty intent → the working value is written.
        assertEquals(false, (payload["autonomousImageRouting"] as JsonPrimitive).content)
        // Mode: clean → the FRESH document value wins over our stale
        // working snapshot (separate).
        assertEquals(SettingsRoleModelController.MODE_SHARED,
            (payload["auxiliaryImageMode"] as JsonPrimitive).content)
    }

    @Test
    fun midFlightModeChangeSurvivesSaveSuccess() = runBlocking {
        val exchange = CaptureExchange(
            initialPreferencesGet = preferencesDoc(),
            saveEffect = { _, _ -> successFrame() },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.settings.roles.refresh()
        kotlinx.coroutines.delay(250)
        // Dirty only routing; freeze the save.
        host.settings.roles.setAutonomousImageRouting(false)
        exchange.saveGateReleased = false
        host.settings.roles.save()
        kotlinx.coroutines.delay(250)
        // Mid-flight: the user switches the media mode.
        host.settings.roles.setAuxiliaryMode(separate = false)
        exchange.saveGateReleased = true
        kotlinx.coroutines.delay(300)
        val state = host.settings.roles.state.value
        // No success-refresh reset: the newer mode choice and its dirty
        // intent survive; the save only cleared the routing intent it wrote.
        assertEquals(SettingsRoleModelController.MODE_SHARED, state.auxiliaryImageMode)
        assertTrue(state.modeDirty)
        assertTrue(!state.routingDirty)
    }

    @Test
    fun lateRefreshPreservesDirtyScalarsAndConvergesWhenDocumentMatches() =
        runBlocking {
            val exchange = CaptureExchange(
                initialPreferencesGet = preferencesDoc(),
                saveEffect = { _, _ -> successFrame() },
            )
            val host = testHost(exchange)
            host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
            host.settings.roles.refresh()
            kotlinx.coroutines.delay(250)
            // Freeze a second refresh; dirty the mode while it is in flight.
            exchange.getGateReleased = false
            host.settings.roles.refresh()
            kotlinx.coroutines.delay(200)
            host.settings.roles.setAuxiliaryMode(separate = false)
            exchange.getGateReleased = true
            kotlinx.coroutines.delay(300)
            var state = host.settings.roles.state.value
            // The late refresh re-anchored slots but kept the dirty mode.
            assertEquals(SettingsRoleModelController.MODE_SHARED, state.auxiliaryImageMode)
            assertTrue(state.modeDirty)

            // Convergence: the document now agrees with the working value.
            exchange.preferencesGet = preferencesDoc(mode = "shared")
            host.settings.roles.refresh()
            kotlinx.coroutines.delay(300)
            state = host.settings.roles.state.value
            assertEquals(SettingsRoleModelController.MODE_SHARED, state.auxiliaryImageMode)
            assertTrue(!state.modeDirty)
        }

    @Test
    fun selectNormalizesAgainstSavedBaseline() = runBlocking {
        val exchange = CaptureExchange(
            initialPreferencesGet = preferencesDoc(),
            saveEffect = { _, _ -> successFrame() },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.settings.roles.refresh()
        kotlinx.coroutines.delay(250)
        val slot = SettingsRoleModelController.RoleSlot.VISION
        val saved = "33333333-3333-3333-3333-333333333333"
        val other = "44444444-4444-4444-4444-444444444444"

        // saved=A → select B → select B again: idempotent, stays B.
        host.settings.roles.select(slot, other)
        host.settings.roles.select(slot, other)
        assertEquals(other, host.settings.roles.state.value.draft[slot])

        // Selecting the SAVED value removes the draft (true revert).
        host.settings.roles.select(slot, saved)
        assertTrue(!host.settings.roles.state.value.draft.containsKey(slot))

        // Explicit clear stays clear across repeated inherit taps.
        host.settings.roles.select(slot, null)
        host.settings.roles.select(slot, null)
        assertTrue(host.settings.roles.state.value.draft.containsKey(slot))
        assertNull(host.settings.roles.state.value.draft[slot])

        // saved=A, cleared, then select A: reverts to saved (draft removed).
        host.settings.roles.select(slot, saved)
        assertTrue(!host.settings.roles.state.value.draft.containsKey(slot))
    }

    private fun successFrame() =
        "{\"version\":3,\"requestID\":\"CORRELATION\",\"ok\":true,\"schema\":\"floe.effect-cursor/3\",\"correlationID\":\"CORRELATION\",\"cursor\":{\"operationReceiptID\":\"op:v1:save\",\"sequence\":1},\"effects\":[{\"sequence\":1,\"kind\":\"accepted\",\"page\":{\"revision\":{\"resourceID\":\"preferences\",\"version\":8},\"preferences\":{}}}],\"hasMore\":false,\"resyncRequired\":false}"

    private fun staleFrame() =
        "{\"version\":3,\"requestID\":\"CORRELATION\",\"ok\":true,\"schema\":\"floe.effect-cursor/3\",\"correlationID\":\"CORRELATION\",\"cursor\":{\"operationReceiptID\":\"op:v1:save\",\"sequence\":1},\"effects\":[{\"sequence\":1,\"kind\":\"rejected\",\"code\":\"staleRevision\",\"detail\":[{\"key\":\"reason\",\"value\":\"preferencesCasGate\"}]}],\"hasMore\":false,\"resyncRequired\":false}"

    companion object {
        private const val PROVIDERS_PAGE = """{"rows":[{"providerID":"p1","displayName":"ACME","enabled":true,"secret":{"configured":true}}],"nextCursor":null,"hasMore":false}"""
        private const val MODELS_PAGE = """{"rows":[{"id":"11111111-1111-1111-1111-111111111111","providerID":"p1","remoteModelID":"m1","displayName":"Agent One","isEnabled":true,"capabilities":{"rawValue":7},"useSurfaces":null},{"id":"22222222-2222-2222-2222-222222222222","providerID":"p1","remoteModelID":"m2","displayName":"Canvas Helper","isEnabled":true,"capabilities":{"rawValue":7},"useSurfaces":null},{"id":"33333333-3333-3333-3333-333333333333","providerID":"p1","remoteModelID":"m3","displayName":"Eyes","isEnabled":true,"capabilities":{"rawValue":3},"useSurfaces":null},{"id":"44444444-4444-4444-4444-444444444444","providerID":"p1","remoteModelID":"m4","displayName":"Eyes Two","isEnabled":true,"capabilities":{"rawValue":3},"useSurfaces":null},{"id":"55555555-5555-5555-5555-555555555555","providerID":"p1","remoteModelID":"m5","displayName":"Reviewer","isEnabled":true,"capabilities":{"rawValue":33},"useSurfaces":null},{"id":"77777777-7777-7777-7777-777777777777","providerID":"p1","remoteModelID":"m7","displayName":"Painter","isEnabled":true,"capabilities":{"rawValue":24},"useSurfaces":null}],"nextCursor":null,"hasMore":false}"""
    }
}
