// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.HomeDraftTransfer
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Home launchpad -> real controller fixture tests (the root FIRST-SEND UI
 * path, which the leaf ConversationHost tests bypass):
 *  - cold start: the real model becomes visible on the launchpad once the
 *    projection loads (previously the chip always showed "no model");
 *  - provider/model change republishes reactively;
 *  - the picker selection persists the durable default (full preferences CAS);
 *  - send launches exactly once, only after the real model snapshot exists,
 *    preserving the chosen canonical model + provider;
 *  - a typed send rejection settles sending and reports the reason (the page
 *    restores the draft from it).
 */
class HomeLaunchpadHostTest {

    private val conversationId = "11111111-1111-4111-8111-111111111111"
    private val createdId = "55555555-5555-4555-8555-555555555555"
    private val providerId = "8E19AA7E-C0F2-4532-8A49-0CE3AC782C68"
    private val modelId = "B2F1A0C4-1111-4222-8333-444455556666"
    private val secondModelId = "C3F2B1D5-2222-4333-8444-555566667777"
    private val runId = "22222222-2222-4222-8222-222222222222"
    private val tempId = "33333333-3333-4333-8333-333333333333"
    private val tempIncarnation = "44444444-4444-4444-8444-444444444444"

    private class Exchange(
        val script: (String) -> String,
    ) : HostBridgeExchange {
        val requests = CopyOnWriteArrayList<String>()
        override fun exchange(request: String): String {
            requests.add(request)
            return script(request)
        }

        fun envelopesOf(command: String): List<kotlinx.serialization.json.JsonObject> =
            requests.mapNotNull { raw ->
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

    private class Script {
        var rejectRunStart = false
        var rejectTempStart = false
        var rejectCreate = false
        var temporary = false
        var modelRows = ""
    }

    private fun temporarySessionValue(): String =
        """{"session":"active","conversationID":"$tempId",""" +
            """"incarnation":"$tempIncarnation","ceiling":"public-web","rootEpoch":7}"""

    private fun temporarySessionReply(): String =
        """{"conversationID":"$tempId","resourceID":"session.$tempId",""" +
            """"revision":"$tempIncarnation","title":"Temporary",""" +
            """"runs":[],"pendingInputs":[]}"""

    private fun providerRow(): String =
        """{"id":"$providerId","kind":"custom","wireProtocol":"openAIChatCompletions",""" +
            """"baseURL":"https://example.invalid/v1","displayName":"DeepSeek Cloud QA",""" +
            """"region":null,"isEnabled":true,"allowsPlainHTTP":false,""" +
            """"toolNameCompatibility":true,"createdAt":"2026-10-20T00:00:00.000Z",""" +
            """"updatedAt":"2026-10-20T00:00:00.000Z","syncRevision":3,""" +
            """"secret":{"configured":true,"opaqueReference":"ref:v1:abc","synchronizable":false}}"""

    private fun modelRow(id: String, remote: String, display: String): String =
        """{"id":"$id","providerID":"$providerId","remoteModelID":"$remote",""" +
            """"displayName":"$display","limits":{"contextTokens":128000,"maxOutputTokens":8192},""" +
            """"capabilities":{"rawValue":7},"explicitCapabilities":null,"useSurfaces":null,""" +
            """"reasoningEffort":"automatic","isEnabled":true,""" +
            """"isHiddenFromPrimaryPicker":false,""" +
            """"revision":{"resourceID":"model.$id","version":"digest"}}"""

    private fun preferencesValue(): String =
        """{"revision":{"resourceID":"preferences","version":"1"},""" +
            """"preferences":{"onboardingStatus":"seen",""" +
            """"defaultAgentModelID":"$modelId","generalAuxiliaryLLMModelID":null,""" +
            """"canvasAgentModelID":null,"visionModelID":null,"canvasVisionModelID":null,""" +
            """"approvalModelID":null,"packageReviewModelID":null,"autonomousImageRouting":false,""" +
            """"auxiliaryImageMode":"shared","sharedImageModelID":null,"imageGenerationModelID":null,""" +
            """"imageEditingModelID":null,"defaultVideoModelID":null,""" +
            """"updatedAt":770000000.0,"syncRevision":1}}"""

    private fun effectPage(correlation: String, receiptTag: String, effectsJson: String): String =
        """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3",""" +
            """"correlationID":"$correlation","cursor":{"operationReceiptID":"op:v1:$receiptTag",""" +
            """"sequence":2},"effects":[$effectsJson],"hasMore":false,"resyncRequired":false}"""

    private fun accepted(valueJson: String? = null, sequence: Int = 1): String {
        val value = if (valueJson == null) "" else ""","value":$valueJson"""
        return """{"sequence":$sequence,"kind":"accepted"$value}"""
    }

    private fun detail(vararg pairs: Pair<String, String>): String =
        pairs.joinToString(",", "[", "]") { (k, v) -> """{"key":"$k","value":"$v"}""" }

    private fun buildExchange(script: Script): Exchange = Exchange { raw ->
        val correlation = correlationOf(raw)
        when {
            raw.contains("\"operation\":\"effect.poll\"") -> {
                when (receiptOf(raw)) {
                    "op:v1:providers" -> effectPage(
                        correlation, "providers",
                        accepted("""{"rows":[${providerRow()}]}"""),
                    )
                    "op:v1:models" -> effectPage(
                        correlation, "models",
                        accepted("""{"rows":[${modelRow(modelId, "deepseek-flash", "DeepSeek Cloud QA")}${script.modelRows}]}"""),
                    )
                    "op:v1:preferences" -> effectPage(
                        correlation, "preferences", accepted(preferencesValue()),
                    )
                    "op:v1:prefsave" -> effectPage(
                        correlation, "prefsave",
                        accepted("""{"revision":{"resourceID":"preferences","version":"2"}}"""),
                    )
                    "op:v1:conversationCreate" -> {
                        if (script.rejectCreate) {
                            effectPage(
                                correlation, "conversationCreate",
                                """{"sequence":1,"kind":"rejected","code":"runtimeUnavailable",""" +
                                    """"detail":${detail("reason" to "runtime_unavailable")}}""",
                            )
                        } else {
                            effectPage(
                                correlation, "conversationCreate",
                                accepted("""{"conversationID":"$createdId"}"""),
                            )
                        }
                    }
                    "op:v1:conversationGet" -> effectPage(
                        correlation, "conversationGet",
                        accepted(
                            if (script.temporary) temporarySessionReply()
                            else """{"conversationID":"$createdId","title":"Task",""" +
                                """"revision":{"resourceID":"conversation.${createdId.uppercase()}","version":"digest-1"},""" +
                                """"runs":[],"pendingInputs":[]}""",
                        ),
                    )
                    "op:v1:tempStart" -> {
                        if (script.rejectTempStart) {
                            effectPage(
                                correlation, "tempStart",
                                """{"sequence":1,"kind":"rejected","code":"runtimeUnavailable",""" +
                                    """"detail":${detail("reason" to "temporary_unavailable")}}""",
                            )
                        } else {
                            effectPage(
                                correlation, "tempStart",
                                accepted(temporarySessionValue()),
                            )
                        }
                    }
                    "op:v1:messagePage" -> effectPage(
                        correlation, "messagePage",
                        accepted("""{"rows":[],"hasEarlier":false,"earlierCursor":null}"""),
                    )
                    "op:v1:runStart" -> {
                        if (script.rejectRunStart) {
                            effectPage(
                                correlation, "runStart",
                                """{"sequence":1,"kind":"rejected","code":"needsConfiguration",""" +
                                    """"detail":${detail("reason" to "model_unavailable")}}""",
                            )
                        } else {
                            effectPage(
                                correlation, "runStart",
                                """{"sequence":1,"kind":"prepared","detail":${detail(
                                    "conversationID" to createdId,
                                    "runID" to runId,
                                    "resourceID" to "run.${runId.uppercase()}",
                                    "version" to "preparing",
                                )}},""" + accepted(
                                    """{"conversationID":"$createdId","runID":"$runId"}""", 2,
                                ),
                            )
                        }
                    }
                    "op:v1:runSnapshot" -> effectPage(
                        correlation, "runSnapshot",
                        accepted(
                            """{"schema":"floe.command-envelope/3","conversationID":"$createdId",""" +
                                """"runID":"$runId","durableState":"preparing",""" +
                                """"revision":{"resourceID":"run.${runId.uppercase()}","version":"preparing"},""" +
                                """"isTerminal":false,"pendingApproval":null,"approvalRevision":null,""" +
                                """"pendingInputs":[],"queueRevision":null,"durableWatermark":1}""",
                        ),
                    )
                    "op:v1:catalog" -> effectPage(correlation, "catalog", accepted("""{"rows":[]}"""))
                    else -> effectPage(correlation, "other", accepted(null))
                }
            }
            raw.contains("\"command\":\"config.providers.list\"") ->
                """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"op:v1:providers"}"""
            raw.contains("\"command\":\"config.models.list\"") ->
                """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"op:v1:models"}"""
            raw.contains("\"command\":\"config.preferences.get\"") ->
                """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"op:v1:preferences"}"""
            raw.contains("\"command\":\"config.preferences.save\"") ->
                """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"op:v1:prefsave"}"""
            raw.contains("\"command\":\"conversation.create\"") ->
                """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"op:v1:conversationCreate"}"""
            raw.contains("\"command\":\"conversation.get\"") ->
                """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"op:v1:conversationGet"}"""
            raw.contains("\"command\":\"temp.start\"") ->
                """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"op:v1:tempStart"}"""
            raw.contains("\"command\":\"conversation.messagePage\"") ->
                """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"op:v1:messagePage"}"""
            raw.contains("\"command\":\"run.start\"") ->
                """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"op:v1:runStart"}"""
            raw.contains("\"command\":\"run.snapshot\"") ->
                """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"op:v1:runSnapshot"}"""
            raw.contains("\"command\":\"config.catalog.search\"") ->
                """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"op:v1:catalog"}"""
            else ->
                """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"op:v1:other"}"""
        }
    }

    private fun host(script: Script, exchange: Exchange): RuntimeHost = RuntimeHost(
        commandClient = RuntimeHostCommandClient(
            exchange = exchange,
            scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default),
            ioDispatcher = kotlinx.coroutines.Dispatchers.Default,
            budgets = HostWireBudgets(effectPollIntervalMillis = 1),
        ),
        gatewayCapability = MutableStateFlow(com.floe.android.SecretGatewayCapability.Loading),
        bootstrapCapability = MutableStateFlow(com.floe.android.RuntimeBootstrapCapability.Idle),
        scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default),
        ioDispatcher = kotlinx.coroutines.Dispatchers.Default,
    )

    private suspend fun readyHost(script: Script, exchange: Exchange): RuntimeHost {
        val host = host(script, exchange)
        host.conversations.start() // Install the real provider/model observation before store readiness.
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("providerConfigurationDomain", true, emptyList())
        host.onDomainAvailability("conversationDomain", true, emptyList())
        host.onDomainAvailability("runDomain", true, emptyList())
        host.onDomainAvailability("temporaryDomain", true, emptyList())
        host.home.start()
        val deadline = System.nanoTime() + 3_000_000_000L
        while (host.home.modelLabel.value == null && System.nanoTime() < deadline) delay(10)
        return host
    }

    private suspend fun awaitUntil(timeoutMillis: Long = 3_000, check: () -> Boolean): Boolean {
        val deadline = System.nanoTime() + timeoutMillis * 1_000_000
        while (System.nanoTime() < deadline) {
            if (check()) return true
            delay(10)
        }
        return check()
    }

    @Test
    fun coldStartPublishesTheRealModelToTheLaunchpad() = runBlocking {
        val script = Script()
        val exchange = buildExchange(script)
        val host = readyHost(script, exchange)
        assertEquals("DeepSeek Cloud QA", host.home.modelLabel.value)
        assertEquals(modelId, host.home.selectedModelId.value)
        assertTrue(host.home.availability.value.providerConfigured)
        assertTrue(host.home.availability.value.temporaryChatAvailable)
        assertTrue(host.home.modelOptions.value.any { it.isUsable })
        host.stop()
    }

    @Test
    fun providerModelChangeRepublishesReactively() = runBlocking {
        val script = Script()
        val exchange = buildExchange(script)
        val host = readyHost(script, exchange)
        assertEquals(modelId, host.home.selectedModelId.value)
        // A second model appears on the real models page; the projection (and
        // the launchpad's options) grow without any manual refresh.
        script.modelRows = "," + modelRow(secondModelId, "deepseek-reasoner", "DeepSeek Reasoner")
        host.conversations.refreshModels()
        assertTrue(
            awaitUntil {
                host.home.modelOptions.value.any { it.modelId == secondModelId }
            },
        )
        host.stop()
    }

    @Test
    fun pickerSelectionPersistsTheDurableDefault() = runBlocking {
        val script = Script().apply {
            modelRows = "," + modelRow(secondModelId, "deepseek-reasoner", "DeepSeek Reasoner")
        }
        val exchange = buildExchange(script)
        val host = readyHost(script, exchange)
        assertTrue(
            awaitUntil { host.home.modelOptions.value.any { it.modelId == secondModelId } },
        )
        assertTrue(host.home.selectModel(secondModelId))
        assertEquals(secondModelId, host.home.selectedModelId.value)
        assertTrue(
            awaitUntil { exchange.envelopesOf("config.preferences.save").isNotEmpty() },
        )
        val payload = exchange.envelopesOf("config.preferences.save").first()["payload"]!!.jsonObject
        assertEquals(secondModelId, payload["defaultAgentModelID"]!!.jsonPrimitive.content)
        assertEquals("1", payload["syncRevision"]!!.jsonPrimitive.content)
        host.stop()
    }

    @Test
    fun sendLaunchesExactlyOnceWithTheChosenCanonicalModel() = runBlocking {
        val script = Script()
        val exchange = buildExchange(script)
        val host = readyHost(script, exchange)
        var failure: String? = null
        assertFalse(host.home.sending.value)
        host.home.send("Hello home", "chat", temporary = false) { failure = it }
        assertTrue(
            "run.start must follow the real create + model proof",
            awaitUntil { exchange.envelopesOf("run.start").size == 1 },
        )
        val payload = exchange.envelopesOf("run.start").first()["payload"]!!.jsonObject
        assertEquals("chat", payload["mode"]!!.jsonPrimitive.content)
        assertEquals(modelId, payload["modelID"]!!.jsonPrimitive.content)
        assertEquals(providerId, payload["providerID"]!!.jsonPrimitive.content)
        // Exactly one create, no duplicate auto-send on the settled path.
        assertEquals(1, exchange.envelopesOf("conversation.create").size)
        assertTrue(awaitUntil { !host.home.sending.value })
        assertNull(failure)
        host.stop()
    }

    @Test
    fun sendRejectionSettlesAndReportsTheReason() = runBlocking {
        val script = Script().apply { rejectRunStart = true }
        val exchange = buildExchange(script)
        val host = readyHost(script, exchange)
        val failure = AtomicReference<String?>(null)
        host.home.send("Hello home", "chat", temporary = false) { failure.set(it) }
        assertTrue(
            awaitUntil { failure.get() != null },
        )
        assertEquals("needsConfiguration", failure.get())
        assertTrue(awaitUntil { !host.home.sending.value })
        // The typed rejection must settle sending; no retry storm.
        assertEquals(1, exchange.envelopesOf("run.start").size)
        host.stop()
    }
    @Test
    fun emptyTemporaryHeaderOpensRealRamThreadWithoutLaunching() = runBlocking {
        val script = Script().apply { temporary = true }
        val exchange = buildExchange(script)
        val host = readyHost(script, exchange)
        val failure = AtomicReference<String?>(null)
        val admitted = AtomicInteger(0)
        host.home.send(
            "",
            "chat",
            temporary = true,
            onAdmitted = { _: HomeSendToken, _: Boolean -> admitted.incrementAndGet() },
        ) { failure.set(it) }
        assertTrue(
            "the empty header must start exactly one real temporary session",
            awaitUntil { exchange.envelopesOf("temp.start").size == 1 },
        )
        assertTrue(awaitUntil { admitted.get() == 1 })
        assertTrue(awaitUntil { !host.home.sending.value })
        val ref = host.conversations.activeTemporarySession()
        assertNotNull(ref)
        assertEquals(tempId, ref!!.conversationId)
        assertEquals(tempIncarnation, ref.incarnationId)
        assertTrue(exchange.envelopesOf("run.start").isEmpty())
        val entry = host.conversations.entryFor(tempId)
        assertNotNull(entry)
        host.conversations.loadThread(entry!!.holder.session)
        assertTrue(awaitUntil { entry.holder.snapshot.value?.hasLoaded == true })
        val snapshot = entry.holder.snapshot.value!!
        assertFalse(snapshot.isConversationMissing)
        assertTrue(snapshot.isTemporary)
        assertEquals(tempIncarnation, snapshot.temporaryIncarnationId)
        assertNull(failure.get())
        host.stop()
    }

    @Test
    fun rejectedTemporaryStartNeverAdmitsOrLaunches() = runBlocking {
        val script = Script().apply {
            temporary = true
            rejectTempStart = true
        }
        val exchange = buildExchange(script)
        val host = readyHost(script, exchange)
        val failure = AtomicReference<String?>(null)
        val admitted = AtomicInteger(0)
        host.home.send(
            "keep me",
            "chat",
            temporary = true,
            onAdmitted = { _: HomeSendToken, _: Boolean -> admitted.incrementAndGet() },
        ) { failure.set(it) }
        assertTrue(awaitUntil { failure.get() != null })
        assertEquals(0, admitted.get())
        assertTrue(awaitUntil { !host.home.sending.value })
        assertEquals(1, exchange.envelopesOf("temp.start").size)
        assertTrue(exchange.envelopesOf("run.start").isEmpty())
        assertNull(host.conversations.activeTemporarySession())
        val payload = exchange.envelopesOf("temp.start").first()["payload"]!!.jsonObject
        assertEquals("keep me", payload["draft"]!!.jsonPrimitive.content)
        host.stop()
    }

    /* ============ G05-R3 first use: provider-free fresh ordinary task ============ */

    @Test
    fun createFreshTaskHandsOffTheDraftAndOpensTheTaskWithoutAnyLaunch() = runBlocking {
        val script = Script()
        val exchange = buildExchange(script)
        val host = readyHost(script, exchange)
        val draftText = "open my terminal"
        val store = com.floe.android.FloeFoundation.draftStore
        HomeDraftTransfer.update(store, draftText)
        val failure = AtomicReference<String?>(null)
        // Flag-before-counter publication: await the deterministic CALLBACK
        // outcome (the route publishes inside the lock, the token-bearing
        // callback fires right after it), never a fixed assertion order.
        val consumedOutcome = AtomicReference<Boolean?>(null)
        val tokenCurrentAtCallback = AtomicReference<Boolean?>(null)
        val consumed = AtomicInteger(0)
        host.home.createFreshTask(
            text = draftText,
            onDraftConsumed = { token, flag ->
                // Captured, never asserted on the IO callback thread.
                tokenCurrentAtCallback.set(host.home.isCurrentHome(token))
                consumedOutcome.set(flag)
                consumed.incrementAndGet()
            },
            onFailure = { _, reason -> failure.set(reason) },
        )
        assertTrue(
            "the fresh task dispatches exactly one real conversation.create",
            awaitUntil { exchange.envelopesOf("conversation.create").size == 1 },
        )
        assertTrue(
            "the token-bearing handoff callback fires exactly once with the" +
                " committed transfer outcome",
            awaitUntil { consumedOutcome.get() != null },
        )
        assertTrue(consumedOutcome.get() == true)
        assertTrue(tokenCurrentAtCallback.get() == true)
        assertEquals(1, consumed.get())
        assertTrue(
            "the created conversation must own the landed route",
            awaitUntil { host.conversations.navigationRequest.value != null },
        )
        val target = host.conversations.navigationRequest.value
        assertTrue(
            "navigation lands on the EXACT created conversation id",
            target is com.floe.android.design.SidebarSelection.Conversation &&
                target.conversationId == createdId,
        )
        // THE ORDINARY ownership API with the exact draft title; NOTHING is
        // launched — no run.start, no temp.start, no model request.
        val payload = exchange.envelopesOf("conversation.create").first()["payload"]!!.jsonObject
        assertEquals(draftText, payload["title"]!!.jsonPrimitive.content)
        assertTrue(exchange.envelopesOf("run.start").isEmpty())
        assertTrue(exchange.envelopesOf("temp.start").isEmpty())
        // The draft HANDS OFF: HOME_DRAFT is consumed for the EXACT
        // transferred text under the publish section (never sent).
        assertNull(failure.get())
        synchronized(store) { assertEquals("", HomeDraftTransfer.draft(store)) }
        assertTrue(awaitUntil { !host.home.sending.value })
        host.stop()
    }

    @Test
    fun blankCreateFreshTaskOpensAnEmptyUntitledTaskWithoutTouchingTheDraft() = runBlocking {
        val script = Script()
        val exchange = buildExchange(script)
        val host = readyHost(script, exchange)
        val store = com.floe.android.FloeFoundation.draftStore
        HomeDraftTransfer.update(store, "unsent private prompt")
        val consumed = AtomicInteger(0)
        host.home.createFreshTask(text = "", onDraftConsumed = { _, _ -> consumed.incrementAndGet() }) { _, _ -> }
        assertTrue(awaitUntil { host.conversations.navigationRequest.value != null })
        // A BLANK tap carries no text: the create is the native untitled row
        // (NO payload) and the unrelated Home draft SURVIVES untouched.
        assertNull(exchange.envelopesOf("conversation.create").first()["payload"])
        val target = host.conversations.navigationRequest.value
        assertTrue(
            target is com.floe.android.design.SidebarSelection.Conversation &&
                target.conversationId == createdId,
        )
        assertTrue(exchange.envelopesOf("run.start").isEmpty())
        assertEquals(1, consumed.get())
        synchronized(store) { assertEquals("unsent private prompt", HomeDraftTransfer.draft(store)) }
        host.stop()
    }

    @Test
    fun createFreshTaskIsRefusedWhileATemporarySendOwnsHome() = runBlocking {
        val script = Script().apply { temporary = true }
        val exchange = buildExchange(script)
        val host = readyHost(script, exchange)
        val freshFailure = AtomicReference<String?>(null)
        // The temporary send claims the Home request lock synchronously.
        host.home.send("", "chat", temporary = true) { }
        host.home.createFreshTask(text = "later", onDraftConsumed = { _, _ -> }) { _, reason -> freshFailure.set(reason) }
        assertTrue(
            "the temporary start still runs exactly once",
            awaitUntil { exchange.envelopesOf("temp.start").size == 1 },
        )
        assertTrue(awaitUntil { host.conversations.activeTemporarySession() != null })
        // One Home-owned transition at a time: the fresh task never slipped
        // a durable create beside the in-flight temporary, and a silently
        // refused tap invents no typed failure of its own.
        assertTrue(exchange.envelopesOf("conversation.create").isEmpty())
        assertNull(freshFailure.get())
        // The temporary ceiling is untouched: it opened no ordinary row and
        // launched no run.
        assertTrue(exchange.envelopesOf("run.start").isEmpty())
        host.stop()
    }

    @Test
    fun createFreshTaskSurfacesTypedCreateRejectionWithoutNavigation() = runBlocking {
        val script = Script().apply { rejectCreate = true }
        val exchange = buildExchange(script)
        val host = readyHost(script, exchange)
        val failure = AtomicReference<String?>(null)
        val store = com.floe.android.FloeFoundation.draftStore
        HomeDraftTransfer.update(store, "keep me")
        host.home.createFreshTask(text = "keep me", onDraftConsumed = { _, _ -> }) { _, reason -> failure.set(reason) }
        assertTrue(awaitUntil { failure.get() != null })
        assertEquals("runtimeUnavailable", failure.get())
        // A refused create navigates nowhere, launches nothing, and the
        // draft was NEVER consumed; the Home lock settles exactly once.
        assertNull(host.conversations.navigationRequest.value)
        synchronized(store) { assertEquals("keep me", HomeDraftTransfer.draft(store)) }
        assertTrue(exchange.envelopesOf("run.start").isEmpty())
        assertTrue(exchange.envelopesOf("temp.start").isEmpty())
        assertEquals(1, exchange.envelopesOf("conversation.create").size)
        assertTrue(awaitUntil { !host.home.sending.value })
        host.stop()
    }

    @Test
    fun freshTaskOwnedRouteIsRefusedWhenActualNavigationMovesDuringTheWait() = runBlocking {
        val script = Script()
        val exchange = buildExchange(script)
        val host = readyHost(script, exchange)
        host.home.createFreshTask(text = "", onDraftConsumed = { _, _ -> }) { _, _ -> }
        assertTrue(
            awaitUntil { host.conversations.navigationRequest.value != null },
        )
        val target = host.conversations.navigationRequest.value!!
        // Observation only (NOT a consumed handle): the published route is an
        // OWNED Home navigation intent — production claim policy untouched;
        // applyHostNavigation below obtains its OWN claim exactly like the
        // shell's serial consumer does.
        val claim = host.home.claimNavigation(target)
        assertTrue("the fresh task publishes as an OWNED Home navigation",
            claim is HomeNavigationClaim.Owned)
        val committed = java.util.concurrent.atomic.AtomicBoolean(false)
        val applied = host.home.applyHostNavigation(
            target,
            waitForAdmission = {
                // The ACTUAL navigation (New Task press) lands AFTER the
                // internal claim, exactly while the shell's fence awaits:
                // it fences the request and withdraws the published intent.
                host.home.onNavigation(
                    com.floe.android.design.SidebarSelection.Workbench(
                        com.floe.android.design.WorkbenchSelection.NEW_TASK,
                    ),
                )
                true
            },
            commit = { committed.set(true) },
        )
        // The FINAL owned re-check (commitNavigation) sees the invalidated
        // OwnedNavigation and refuses the stale route: no theft, no commit.
        assertFalse(applied)
        assertFalse(committed.get())
        assertNull(host.conversations.navigationRequest.value)
        // The durable row itself still exists (history), created exactly once.
        assertEquals(1, exchange.envelopesOf("conversation.create").size)
        host.stop()
    }

    @Test
    fun lateFreshTaskCreateCannotClearOrHijackANewerHomeRequest() = runBlocking {
        val script = Script().apply { temporary = true }
        val exchange = buildExchange(script)
        val host = readyHost(script, exchange)
        val barrierHits = AtomicInteger(0)
        val sendingAtTempPublish = AtomicReference<Boolean?>(null)
        val oldFailure = AtomicReference<String?>(null)
        // ONE deterministic seam: hit 1 = the old create, right BEFORE its
        // publish section; hit 2 = the newer temporary, right BEFORE its own
        // publish. Production never sets this barrier.
        host.home.admissionPublishBarrier = {
            when (barrierHits.incrementAndGet()) {
                1 -> {
                    // Actual navigation away from Home, then a NEWER
                    // temporary request claims Home synchronously.
                    host.home.onNavigation(
                        com.floe.android.design.SidebarSelection.Workbench(
                            com.floe.android.design.WorkbenchSelection.NEW_TASK,
                        ),
                    )
                    host.home.send("", "chat", temporary = true) { }
                }
                2 -> sendingAtTempPublish.set(host.home.sending.value)
            }
        }
        host.home.createFreshTask(text = "old", onDraftConsumed = { _, _ -> }) { _, reason -> oldFailure.set(reason) }
        assertTrue(awaitUntil { exchange.envelopesOf("temp.start").size == 1 })
        assertTrue(
            "the NEWER temporary request still owned its lock when its own" +
                " publish ran: the superseded create never cleared it",
            awaitUntil { sendingAtTempPublish.get() == true },
        )
        assertTrue(awaitUntil { host.conversations.activeTemporarySession() != null })
        assertTrue(
            "the only published route is the newer temporary's exact target",
            awaitUntil { host.conversations.navigationRequest.value != null },
        )
        val nav = host.conversations.navigationRequest.value
        assertTrue(
            "the late create settlement never stole the route",
            nav is com.floe.android.design.SidebarSelection.Conversation &&
                nav.conversationId == tempId,
        )
        assertNull(oldFailure.get())
        host.home.admissionPublishBarrier = null
        host.stop()
    }

}
