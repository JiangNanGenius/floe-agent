// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import androidx.compose.ui.text.input.TextFieldValue
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Task Center single-row delete stale-revision regression (App repair).
 *
 * Authored NOTRUN — source-authored only; no compile/run claim here. Main
 * runs the focused JVM filter named in SOURCE_READY.json.
 *
 * Reproduced production failure (R3Privacy11, candidate11): a conversation
 * opened in Chat caches its row digest from the `conversation.get` reply the
 * flow applied; every durable run/message commit then advances the REAL row
 * digest (ConversationStore.appendMessage touches `updated_at` and the
 * deletion CAS digests the FULL row). The pre-fix
 * `resolveConversationRevision` reused that cached digest for
 * `conversation.delete`, the native admission CAS refused with the typed
 * `staleRevision`, the row stayed, and — because the Completed-only typed
 * deletion observer never sees a refused delete and the history surface used
 * to render no action error — the UI silently did nothing ("No typed deletion
 * observed since launch", all cleanup counts 0, no owned operation/FGS).
 * This is the same stale-cached-revision class already proven and fixed for
 * the second `run.start` (ConversationSecondSendRevisionTest).
 *
 * The scripted transport enforces the REAL Core deletion CAS: a
 * `conversation.delete` whose envelope revision version does not equal the
 * current conversation-row digest is refused exactly like production (typed
 * `staleRevision` rejection, row untouched, no cleanup obligation). Every
 * accepted launch advances the digest exactly like the durable commit does.
 */
class ConversationHistoryDeleteRevisionTest {

    private val conversationId = "11111111-1111-4111-8111-111111111111"
    private val providerId = "8E19AA7E-C0F2-4532-8A49-0CE3AC782C68"
    private val modelId = "B2F1A0C4-1111-4222-8333-444455556666"
    private val runId = "22222222-2222-4222-8222-222222222222"

    // ------------------------------------------------------------- transport

    /**
     * CAS-enforcing double of the real v3 wire. [currentDigest] models the
     * Core conversation-row digest; it advances on every accepted run.start
     * exactly like the durable launch/message commits do, and
     * `conversation.delete` is admitted ONLY under the digest current at
     * settle time, with the production typed refusal otherwise.
     */
    private inner class CasExchange(
        /** Durable run state reported by conversation.get replies. */
        var runState: String = "idle",
        /** When true, every conversation.delete is refused staleRevision
         *  (models a genuine concurrent row advance after the action read). */
        var refuseAllDeletes: Boolean = false,
    ) : HostBridgeExchange {
        val requests = CopyOnWriteArrayList<String>()

        @Volatile var currentDigest = "digest-1"

        /** conversation.delete commands refused for a stale revision. */
        val staleDeleteRejects = AtomicInteger(0)

        /** conversation.delete commands admitted (CAS matched). */
        val deleteAccepted = AtomicInteger(0)

        /** conversation.get commands seen (load + launch + action reads). */
        val conversationGetCount = AtomicInteger(0)

        /** prepared effects emitted for accepted run.start commands. */
        val preparedCount = AtomicInteger(0)

        @Volatile private var lastRunStartRevision: String? = null
        @Volatile private var lastDeleteRevision: String? = null

        override fun exchange(request: String): String {
            requests.add(request)
            val correlation = correlationOf(request)
            return when {
                request.contains("\"operation\":\"event.poll\"") -> eventPollPage(correlation)
                request.contains("\"operation\":\"effect.poll\"") -> {
                    val receipt = receiptOf(request)
                    when (receipt) {
                        "op:v1:providers" -> effect(
                            correlation, "providers",
                            accepted("""{"rows":[${providerRow()}]}"""),
                        )
                        "op:v1:models" -> effect(
                            correlation, "models",
                            accepted("""{"rows":[${modelRow()}]}"""),
                        )
                        "op:v1:preferences" -> effect(
                            correlation, "preferences",
                            accepted(
                                """{"revision":{"resourceID":"preferences","version":"1"},""" +
                                    """"preferences":{"onboardingStatus":"seen",""" +
                                    """"defaultAgentModelID":"$modelId",""" +
                                    """"generalAuxiliaryLLMModelID":null,""" +
                                    """"canvasAgentModelID":null,"visionModelID":null,""" +
                                    """"canvasVisionModelID":null,"approvalModelID":null,""" +
                                    """"packageReviewModelID":null,"autonomousImageRouting":false,""" +
                                    """"auxiliaryImageMode":"shared","sharedImageModelID":null,""" +
                                    """"imageGenerationModelID":null,"imageEditingModelID":null,""" +
                                    """"defaultVideoModelID":null,""" +
                                    """"updatedAt":770000000.0,"syncRevision":1}}""",
                            ),
                        )
                        "op:v1:cget" -> effect(correlation, "cget", accepted(conversationReply()))
                        "op:v1:runStart" -> {
                            val expected = currentDigest
                            val supplied = lastRunStartRevision
                            if (supplied == expected) {
                                // The durable commit advances the row digest.
                                currentDigest = nextDigest(currentDigest)
                                runState = "completed"
                                preparedCount.incrementAndGet()
                                effect(
                                    correlation, "runStart",
                                    """{"sequence":1,"kind":"prepared","detail":[""" +
                                        """{"key":"conversationID","value":"$conversationId"},""" +
                                        """{"key":"runID","value":"$runId"},""" +
                                        """{"key":"resourceID","value":"run.${runId.uppercase()}"},""" +
                                        """{"key":"version","value":"preparing"}]},""" +
                                        accepted(
                                            """{"conversationID":"$conversationId",""" +
                                                """"runID":"$runId"}""",
                                            sequence = 2,
                                        ),
                                )
                            } else {
                                effect(
                                    correlation, "runStart",
                                    """{"sequence":1,"kind":"rejected",""" +
                                        """"code":"ordinaryRuntimeBlocked",""" +
                                        """"detail":[{"key":"reason","value":"revisionMismatch"}]}""",
                                )
                            }
                        }
                        "op:v1:cdel" -> {
                            val supplied = lastDeleteRevision
                            if (!refuseAllDeletes && supplied == currentDigest) {
                                deleteAccepted.incrementAndGet()
                                effect(
                                    correlation, "cdel",
                                    accepted(
                                        """{"conversationID":"$conversationId",""" +
                                            """"workspaceCleanup":"removed",""" +
                                            """"runtimeCleanupHandoff":"awaitingReceipt",""" +
                                            """"runtimeCleanupRequestID":"${"0".repeat(32)}"}""",
                                    ),
                                )
                            } else {
                                staleDeleteRejects.incrementAndGet()
                                effect(
                                    correlation, "cdel",
                                    """{"sequence":1,"kind":"rejected","code":"staleRevision"}""",
                                )
                            }
                        }
                        "op:v1:runSnapshot" ->
                            effect(correlation, "runSnapshot", accepted(runSnapshot()))
                        "op:v1:messagePage" -> effect(
                            correlation, "messagePage",
                            accepted("""{"rows":[],"hasEarlier":false,"earlierCursor":null}"""),
                        )
                        else -> effect(correlation, requireNotNull(receipt) { "missing effect receipt" }, accepted(null))
                    }
                }
                request.contains("\"command\":\"conversation.get\"") -> {
                    conversationGetCount.incrementAndGet()
                    receipt(correlation, "cget")
                }
                request.contains("\"command\":\"run.start\"") -> {
                    lastRunStartRevision = revisionVersionOf(request)
                    receipt(correlation, "runStart")
                }
                request.contains("\"command\":\"conversation.delete\"") -> {
                    lastDeleteRevision = revisionVersionOf(request)
                    receipt(correlation, "cdel")
                }
                request.contains("\"command\":\"run.snapshot\"") ->
                    receipt(correlation, "runSnapshot")
                request.contains("\"command\":\"conversation.messagePage\"") ->
                    receipt(correlation, "messagePage")
                request.contains("\"command\":\"config.providers.list\"") ->
                    receipt(correlation, "providers")
                request.contains("\"command\":\"config.models.list\"") ->
                    receipt(correlation, "models")
                request.contains("\"command\":\"config.preferences.get\"") ->
                    receipt(correlation, "preferences")
                else -> receipt(correlation, "other")
            }
        }

        fun commandsOf(command: String): List<JsonObject> = requests.mapNotNull { raw ->
            val root = runCatching { Json.parseToJsonElement(raw).jsonObject }.getOrNull()
                ?: return@mapNotNull null
            if ((root["operation"]?.jsonPrimitive?.content) != "command.submit") return@mapNotNull null
            val envelope = root["envelope"]?.jsonObject ?: return@mapNotNull null
            if ((envelope["command"]?.jsonPrimitive?.content) != command) return@mapNotNull null
            envelope
        }

        private fun nextDigest(digest: String): String {
            val n = digest.removePrefix("digest-").toIntOrNull() ?: 1
            return "digest-${n + 1}"
        }

        private fun revisionVersionOf(raw: String): String? =
            runCatching {
                val root = Json.parseToJsonElement(raw).jsonObject
                root["envelope"]?.jsonObject
                    ?.get("revision")?.jsonObject
                    ?.get("version")?.jsonPrimitive?.content
            }.getOrNull()

        private fun providerRow(): String =
            """{"id":"$providerId","kind":"custom","wireProtocol":"openAIChatCompletions",""" +
                """"baseURL":"https://example.invalid/v1","displayName":"DeepSeek Cloud QA",""" +
                """"region":null,"isEnabled":true,"allowsPlainHTTP":false,""" +
                """"toolNameCompatibility":true,"createdAt":"2026-10-20T00:00:00.000Z",""" +
                """"updatedAt":"2026-10-20T00:00:00.000Z","syncRevision":3,""" +
                """"secret":{"configured":true,"opaqueReference":"ref:v1:abc","synchronizable":false}}"""

        private fun modelRow(): String =
            """{"id":"$modelId","providerID":"$providerId","remoteModelID":"deepseek-flash",""" +
                """"displayName":"DeepSeek Cloud QA","limits":{"contextTokens":128000,"maxOutputTokens":8192},""" +
                """"capabilities":{"rawValue":7},"explicitCapabilities":null,"useSurfaces":null,""" +
                """"reasoningEffort":"automatic","isEnabled":true,"isHiddenFromPrimaryPicker":false,""" +
                """"revision":{"resourceID":"model.$modelId","version":"digest"}}"""

        private fun conversationReply(): String =
            """{"conversationID":"$conversationId","title":"Task",""" +
                """"revision":{"resourceID":"conversation.${conversationId.uppercase()}",""" +
                """"version":"$currentDigest"},""" +
                """"runs":[{"runID":"$runId","state":"$runState",""" +
                """"modelName":"DeepSeek Cloud QA","startedAt":"2026-10-20T01:00:00.000Z"}],""" +
                """"pendingInputs":[],"taskPolicy":{"resolvedApprovalMode":"ask"}}"""

        private fun runSnapshot(): String =
            """{"schema":"floe.command-envelope/3","conversationID":"$conversationId",""" +
                """"runID":"$runId","durableState":"$runState",""" +
                """"revision":{"resourceID":"run.${runId.uppercase()}","version":"$runState"},""" +
                """"isTerminal":false,"conversationMode":"chat","goal":"hi","liveOwner":false,""" +
                """"pendingApproval":null,"approvalRevision":null,"pendingInputs":[],""" +
                """"queueRevision":{"resourceID":"pendingQueue.${conversationId.uppercase()}",""" +
                """"version":"queue-digest-1"},"durableWatermark":4}"""

        private fun receipt(correlation: String, receiptTag: String): String =
            """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation",""" +
                """"operationReceiptID":"op:v1:$receiptTag"}"""

        private fun accepted(valueJson: String?, sequence: Int = 1): String {
            val value = if (valueJson == null) "" else ""","value":$valueJson"""
            return """{"sequence":$sequence,"kind":"accepted"$value}"""
        }

        private fun eventPollPage(correlation: String): String =
            """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.event-cursor/3",""" +
                """"correlationID":"$correlation","cursor":{"runID":"$runId","sequence":0},""" +
                """"durable":{"windowState":"attached","events":[],"hasMore":false,""" +
                """"resyncRequired":false,"nextSequence":0},""" +
                """"live":{"liveState":"noConsumer","frames":[],"resyncRequired":false},""" +
                """"resyncRequired":false}"""

        private fun effect(
            correlation: String,
            receiptTag: String,
            effectsJson: String,
            sequence: Long = 2,
        ): String =
            """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3",""" +
                """"correlationID":"$correlation","cursor":{"operationReceiptID":"op:v1:$receiptTag",""" +
                """"sequence":$sequence},"effects":[$effectsJson],"hasMore":false,"resyncRequired":false}"""
    }

    private fun correlationOf(request: String): String =
        runCatching {
            Json.parseToJsonElement(request).jsonObject["requestID"]!!.jsonPrimitive.content
        }.getOrDefault("cor")

    private fun receiptOf(request: String): String? =
        runCatching {
            Json.parseToJsonElement(request).jsonObject["envelope"]!!.jsonObject
                .get("effect")!!.jsonObject["operationReceiptID"]!!.jsonPrimitive.content
        }.getOrNull()

    // ----------------------------------------------------------------- hosts

    private fun client(exchange: HostBridgeExchange) = RuntimeHostCommandClient(
        exchange = exchange,
        scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default),
        ioDispatcher = kotlinx.coroutines.Dispatchers.Default,
        budgets = HostWireBudgets(effectPollIntervalMillis = 1),
    )

    private fun host(exchange: HostBridgeExchange): RuntimeHost = RuntimeHost(
        commandClient = client(exchange),
        gatewayCapability = MutableStateFlow(com.floe.android.SecretGatewayCapability.Loading),
        bootstrapCapability = MutableStateFlow(com.floe.android.RuntimeBootstrapCapability.Idle),
        scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default),
        ioDispatcher = kotlinx.coroutines.Dispatchers.Default,
    )

    private suspend fun readyHost(exchange: HostBridgeExchange): RuntimeHost {
        val host = host(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("providerConfigurationDomain", true, emptyList())
        host.onDomainAvailability("conversationDomain", true, emptyList())
        host.onDomainAvailability("runDomain", true, emptyList())
        host.onDomainAvailability("temporaryDomain", true, emptyList())
        host.providers.refreshProviders()
        host.conversations.refreshModels()
        val deadline = System.nanoTime() + 2_000_000_000L
        while (host.conversations.modelOptions().isEmpty() && System.nanoTime() < deadline) {
            delay(10)
        }
        return host
    }

    private suspend fun loadedHolder(
        host: RuntimeHost,
    ): com.floe.android.feature.conversation.ConversationFlowHolder {
        val holder = host.conversations.holderFor(
            conversationId, isTemporary = false, incarnationId = null)
        host.conversations.loadThread(holder.session)
        val deadline = System.nanoTime() + 2_000_000_000L
        while (holder.snapshot.value == null && System.nanoTime() < deadline) delay(10)
        return holder
    }

    private suspend fun awaitCondition(timeoutMillis: Long = 3_000, check: () -> Boolean): Boolean {
        val deadline = System.nanoTime() + timeoutMillis * 1_000_000
        while (System.nanoTime() < deadline) {
            if (check()) return true
            delay(10)
        }
        return check()
    }

    // ----------------------------------------------------------------- tests

    /**
     * THE delete-path regression (the exact R3Privacy11 reproduction shape):
     * open the conversation in Chat (row digest cached), send one run (the
     * durable commit advances the REAL digest), then delete this row from
     * the Task Center surface. The dispatched `conversation.delete` MUST
     * carry the CURRENT digest — which requires one fresh `conversation.get`
     * at action time — so the native CAS admits it and the ORIGINAL
     * lifecycle completes. Pre-fix, the cached stale digest leaves the App
     * here and the transport refuses it with typed `staleRevision`: the
     * delete never completes, no typed deletion is observable and the row
     * stays (the reported silent no-op).
     */
    @Test
    fun taskCenterDeleteAfterRunReadsFreshRowRevision() = runBlocking {
        val exchange = CasExchange(runState = "idle")
        val host = readyHost(exchange)
        val holder = loadedHolder(host)

        // One real send: the accepted launch advances the Core row digest
        // exactly like the durable message commits do.
        holder.onDraftChange(TextFieldValue("seed the workspace"))
        val sent = holder.send()
        assertTrue(
            "seed send must be admitted: $sent",
            sent is com.floe.android.feature.conversation.ConversationFlowResult.Accepted,
        )
        assertTrue(
            "seed prepared echo must land",
            awaitCondition { exchange.preparedCount.get() >= 1 },
        )
        assertEquals("the durable commit advanced the row digest", "digest-2", exchange.currentDigest)

        // Task Center single-row delete on the SAME conversation.
        val dispatched = host.conversations.deleteConversation(conversationId)
        assertTrue("delete must dispatch on an admitted conversation domain", dispatched)

        assertTrue(
            "delete MUST be admitted under the fresh digest (pre-fix: staleRevision refusal)",
            awaitCondition { exchange.deleteAccepted.get() >= 1 },
        )
        val deletes = exchange.commandsOf("conversation.delete")
        assertEquals("exactly one delete, no replay", 1, deletes.size)
        val revision = deletes[0]["revision"]?.jsonObject
        assertNotNull("the frozen deletion CAS carries a revision", revision)
        assertEquals(
            "the delete MUST use the action-time fresh row revision, never the cached one",
            "digest-2",
            revision!!["version"]!!.jsonPrimitive.content,
        )
        assertEquals(
            "the revision names the SAME conversation (parsed-UUID rule)",
            "conversation.${conversationId.uppercase()}",
            revision["resourceID"]!!.jsonPrimitive.content,
        )
        assertEquals(
            "the transport enforces the deletion CAS: no stale revision left the App",
            0,
            exchange.staleDeleteRejects.get(),
        )
        // The fresh-read contract adds ONE action-time read (load + launch
        // pre-send reads were already fresh at their own dispatch points).
        assertTrue(
            "delete path performed its action-time conversation.get",
            exchange.conversationGetCount.get() >= 3,
        )
        // The completed settlement ran through the ORIGINAL release + refresh
        // ownership: the holder was released for the deleted row.
        assertTrue(
            "Completed delete releases the holder",
            awaitCondition { host.conversations.entryFor(conversationId) == null },
        )
        // A real success leaves no failure claim on the history surface.
        assertNull(host.conversations.historyHolder.actionError)
        host.stop()
    }

    /**
     * Truthful typed failure surface: when the ORIGINAL native CAS really
     * refuses (a concurrent row advance after the action-time read — the
     * only way a fresh-read delete can be refused), the exact code lands in
     * the existing history holder so the localized banner shows it. No
     * speculative success, no silent dialog close.
     */
    @Test
    fun refusedDeletePublishesTheExistingTypedFailure() = runBlocking {
        val exchange = CasExchange(runState = "idle", refuseAllDeletes = true)
        val host = readyHost(exchange)
        loadedHolder(host)

        assertTrue(
            "delete must dispatch",
            host.conversations.deleteConversation(conversationId),
        )
        assertTrue(
            "the refused delete settles typed",
            awaitCondition { exchange.staleDeleteRejects.get() >= 1 },
        )
        assertTrue(
            "the history holder publishes the REAL rejection code for the banner",
            awaitCondition { host.conversations.historyHolder.actionError == "staleRevision" },
        )
        // The refused row is never presented as deleted: its holder stays.
        assertNotNull("a refused delete releases nothing", host.conversations.entryFor(conversationId))
        host.stop()
    }
}
