// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.feature.conversation.AgentExecutionModeUi
import com.floe.android.feature.conversation.RunLaunchRequest
import com.floe.android.feature.conversation.TemporarySessionRef
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Settings/Privacy summary owner + settlement lifecycle.
 *
 * Scripted transport doubles only; no JNI, real store, device or network.
 * These exercise production host/controller callbacks in controlled order.
 *
 * The Alpha4 failure left Settings/Privacy on the visible "Loading…" card
 * after a temporary-chat turn was discarded, and a process restart recovered
 * it. These tests cover the connected App lifecycle:
 *  * a settings surface is admitted by its OWN settings domain, never by
 *    provider-configuration readiness; a domain that becomes ready after the
 *    one-shot host start still loads its summary;
 *  * every terminal class settles (a closed/replaced/valueless terminal is a
 *    typed retryable error, never an eternal loading card);
 *  * a completed temporary turn (temp.start -> run.start -> terminal event ->
 *    temp.end) leaves the root privacy summary usable, and the page-open
 *    ensure still refreshes real counts afterwards.
 */
class SettingsSummaryLifecycleTest {

    private val tempConversationId = "aaaaaaaa-1111-4111-8111-111111111111"
    private val tempRunId = "bbbbbbbb-2222-4222-8222-222222222222"
    private val providerId = "8E19AA7E-C0F2-4532-8A49-0CE3AC782C68"
    private val modelId = "B2F1A0C4-1111-4222-8333-444455556666"
    private val rootEpoch = 7L
    private val histRev = "sha256:" + "1".repeat(64)
    private val mcfgRev = "sha256:" + "2".repeat(64)

    private class ScriptExchange(
        private val effectFor: (receipt: String, correlation: String) -> String?,
        private val receiptFor: (command: String, correlation: String) -> String = { _, c ->
            "op:v1:other-$c"
        },
    ) : HostBridgeExchange {
        val requests = CopyOnWriteArrayList<String>()

        override fun exchange(request: String): String {
            requests.add(request)
            val correlation = correlationOf(request)
            if (request.contains("\"operation\":\"effect.poll\"")) {
                val receipt = receiptOf(request)
                return effectFor(receipt, correlation)
                    ?: emptyPage(correlation, receipt)
            }
            val receipt = receiptFor(commandOf(request), correlation)
            return """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"$receipt"}"""
        }

        fun count(command: String): Int =
            requests.count { it.contains("\"command\":\"$command\"") }

        private fun emptyPage(correlation: String, receipt: String): String =
            """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3",""" +
                """"correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":0},""" +
                """"effects":[],"hasMore":false,"resyncRequired":false}"""

        companion object {
            fun commandOf(raw: String): String {
                val marker = "\"command\":\""
                val start = raw.indexOf(marker).takeIf { it >= 0 } ?: return ""
                val from = start + marker.length
                val end = raw.indexOf('"', from)
                return if (end > from) raw.substring(from, end) else ""
            }
        }
    }

    private fun testHost(
        exchange: HostBridgeExchange,
        epoch: () -> Long? = { rootEpoch },
    ): RuntimeHost {
        val client = RuntimeHostCommandClient(
            exchange = exchange,
            scope = kotlinx.coroutines.CoroutineScope(Dispatchers.Default),
            ioDispatcher = Dispatchers.Default,
            budgets = HostWireBudgets(effectPollIntervalMillis = 1),
        )
        return RuntimeHost(
            commandClient = client,
            gatewayCapability = kotlinx.coroutines.flow.MutableStateFlow(
                com.floe.android.SecretGatewayCapability.Loading),
            bootstrapCapability = kotlinx.coroutines.flow.MutableStateFlow(
                com.floe.android.RuntimeBootstrapCapability.Idle),
            scope = kotlinx.coroutines.CoroutineScope(Dispatchers.Default),
            ioDispatcher = Dispatchers.Default,
        ).also { it.nativeRootEpochReader = epoch }
    }

    private suspend fun await(
        timeoutMillis: Long = 3_000,
        condition: () -> Boolean,
    ): Boolean {
        val deadline = System.nanoTime() + timeoutMillis * 1_000_000L
        while (System.nanoTime() < deadline) {
            if (condition()) return true
            delay(10)
        }
        return condition()
    }

    private fun accepted(correlation: String, receipt: String, doc: String): String =
        """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3",""" +
            """"correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":1},""" +
            """"effects":[{"sequence":1,"kind":"accepted","page":$doc}],"hasMore":false,"resyncRequired":false}"""

    private fun closed(correlation: String, receipt: String): String =
        """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3",""" +
            """"correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":1},""" +
            """"effects":[{"sequence":1,"kind":"closed","detail":[]}],"hasMore":false,"resyncRequired":false}"""

    private fun replaced(correlation: String, receipt: String): String =
        """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3",""" +
            """"correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":1},""" +
            """"effects":[{"sequence":1,"kind":"replaced","detail":[]}],"hasMore":false,"resyncRequired":false}"""

    private fun cancelled(correlation: String, receipt: String): String =
        """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3",""" +
            """"correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":1},""" +
            """"effects":[{"sequence":1,"kind":"cancelled","detail":[]}],"hasMore":false,"resyncRequired":false}"""

    private fun summaryDoc(
        conversations: Int = 11,
        runs: Int = 15,
        persistedGrants: Int = 0,
        inMemoryGrants: Int = 0,
    ): String =
        """{"history":{"conversationCount":$conversations,"runCount":$runs,""" +
            """"persistedGrantCount":$persistedGrants,"inMemoryGrantCount":$inMemoryGrants,""" +
            """"revision":"$histRev"},""" +
            """"modelConfiguration":{"providerCount":2,"modelCount":2,""" +
            """"secretReferenceCount":2,"preferencesSyncRevision":4,"revision":"$mcfgRev"},""" +
            """"credentialAvailability":"AVAILABLE","snapshot":{"dbSnapshotTransaction":true,""" +
            """"inMemoryGrantBracket":"ok","retriesBounded":0}}"""

    @Test
    fun parallelSettingsResultsCannotRestorePrivacyLoading() = runBlocking {
        val host = testHost(ScriptExchange(effectFor = { _, _ -> null }))
        val update = host.settings.javaClass.declaredMethods.single {
            it.name == "update" && it.parameterTypes.size == 1
        }.apply { isAccessible = true }
        val firstEntered = java.util.concurrent.CountDownLatch(1)
        val releaseFirst = java.util.concurrent.CountDownLatch(1)
        val secondStarted = java.util.concurrent.CountDownLatch(1)
        val secondThread = java.util.concurrent.atomic.AtomicReference<Thread>()
        val workers = java.util.concurrent.Executors.newFixedThreadPool(2)
        try {
            val memory = workers.submit {
                val mutation: (SettingsHostController.SettingsHostState) -> SettingsHostController.SettingsHostState = { state ->
                    firstEntered.countDown()
                    check(releaseFirst.await(3, java.util.concurrent.TimeUnit.SECONDS))
                    state.copy(memoryStatus = SettingsHostController.SurfaceStatus(error = "memorySettled"))
                }
                update.invoke(host.settings, mutation)
            }
            assertTrue(firstEntered.await(3, java.util.concurrent.TimeUnit.SECONDS))
            val privacy = workers.submit {
                secondThread.set(Thread.currentThread())
                secondStarted.countDown()
                val mutation: (SettingsHostController.SettingsHostState) -> SettingsHostController.SettingsHostState = { state ->
                    state.copy(privacyStatus = SettingsHostController.SurfaceStatus(error = "privacySettled"))
                }
                update.invoke(host.settings, mutation)
            }
            assertTrue(secondStarted.await(3, java.util.concurrent.TimeUnit.SECONDS))
            val deadline = System.nanoTime() + 3_000_000_000L
            while (!privacy.isDone && secondThread.get().state != Thread.State.BLOCKED &&
                System.nanoTime() < deadline) Thread.sleep(1)
            assertTrue("second result neither settled nor serialized", privacy.isDone ||
                secondThread.get().state == Thread.State.BLOCKED)
            releaseFirst.countDown()
            memory.get(3, java.util.concurrent.TimeUnit.SECONDS)
            privacy.get(3, java.util.concurrent.TimeUnit.SECONDS)
            val state = host.settings.state.value
            assertFalse("a late memory result restored already-settled privacy Loading", state.privacyStatus.loading)
            assertEquals("privacySettled", state.privacyStatus.error)
            assertEquals("memorySettled", state.memoryStatus.error)
        } finally {
            releaseFirst.countDown()
            workers.shutdownNow()
            host.stop()
        }
    }

    // ------------------------------------------------------- owner lifecycle

    @Test
    fun privacyDomainAdmittedAfterHostStartLoadsTheSummary() = runBlocking {
        val exchange = ScriptExchange(
            receiptFor = { command, c ->
                when (command) {
                    "privacy.summary.get" -> "op:v1:privacy-$c"
                    else -> "op:v1:other-$c"
                }
            },
            effectFor = { receipt, correlation ->
                if (receipt.startsWith("op:v1:privacy-")) {
                    accepted(correlation, receipt, summaryDoc())
                } else {
                    closed(correlation, receipt)
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        // Provider configuration is admitted at store readiness, but the
        // privacy surface is NOT: its native command key belongs to the
        // optional privacy extension and must never be dispatched on the
        // provider-configuration fallback.
        host.settings.start()
        assertTrue(host.settings.state.value.privacyStatus.loading)
        assertNull(host.settings.state.value.privacy.summary)
        assertEquals(0, exchange.count("privacy.summary.get"))

        // The real domain becomes available after the one-shot start. The
        // transition itself must load the surface; no page reopen/restart.
        host.onDomainAvailability("settingsPrivacy", true, emptyList())
        assertTrue(
            "late privacy admission did not load the root summary",
            await { host.settings.state.value.privacy.summary != null },
        )
        val state = host.settings.state.value
        assertEquals(11L, state.privacy.summary!!.conversationCount)
        assertEquals(15L, state.privacy.summary!!.runCount)
        assertEquals(2L, state.privacy.summary!!.providerCount)
        assertEquals(2L, state.privacy.summary!!.modelCount)
        assertNull(state.privacyStatus.error)
        assertFalse(state.privacyStatus.loading)
        assertEquals(1, exchange.count("privacy.summary.get"))
        host.stop()
    }

    @Test
    fun valuelessCompletedReadSettlesTypedRetryableError() = runBlocking {
        val reads = AtomicInteger(0)
        val exchange = ScriptExchange(
            receiptFor = { command, c ->
                if (command == "privacy.summary.get") "op:v1:privacy-$c"
                else "op:v1:other-$c"
            },
            effectFor = { receipt, correlation ->
                if (receipt.startsWith("op:v1:privacy-")) {
                    if (reads.getAndIncrement() == 0) {
                        closed(correlation, receipt)
                    } else {
                        accepted(correlation, receipt, summaryDoc())
                    }
                } else {
                    closed(correlation, receipt)
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("settingsPrivacy", true, emptyList())
        host.settings.refreshPrivacySummary()
        assertTrue(
            "a completed terminal without a summary document must surface a typed error " +
                "(status=${host.settings.state.value.privacyStatus})",
            await { host.settings.state.value.privacyStatus.error == "summaryUnavailable" },
        )
        assertFalse(host.settings.state.value.privacyStatus.loading)
        assertNull(host.settings.state.value.privacy.summary)

        // The page-open recovery path is a real new read and recovers.
        host.settings.ensurePrivacySummaryLoaded()
        assertTrue(await { host.settings.state.value.privacy.summary != null })
        assertNull(host.settings.state.value.privacyStatus.error)
        assertEquals(11L, host.settings.state.value.privacy.summary!!.conversationCount)
        host.stop()
    }

    @Test
    fun malformedSummaryNeverBecomesInventedZeroCounts() = runBlocking {
        for (bad in listOf(
            "{}",
            summaryDoc().replace("\"conversationCount\":11", "\"conversationCount\":-1"),
            summaryDoc().replace("\"modelCount\":2", "\"modelCount\":\"unknown\""),
        )) {
            val reads = AtomicInteger(0)
            val exchange = ScriptExchange(
                receiptFor = { command, c ->
                    if (command == "privacy.summary.get") "op:v1:privacy-$c"
                    else "op:v1:other-$c"
                },
                effectFor = { receipt, correlation ->
                    if (receipt.startsWith("op:v1:privacy-")) {
                        accepted(correlation, receipt,
                            if (reads.getAndIncrement() == 0) bad else summaryDoc())
                    } else closed(correlation, receipt)
                },
            )
            val host = testHost(exchange)
            host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
            host.onDomainAvailability("settingsPrivacy", true, emptyList())
            host.settings.refreshPrivacySummary()
            assertTrue(await { host.settings.state.value.privacyStatus.error == "summaryUnavailable" })
            assertFalse(host.settings.state.value.privacyStatus.loading)
            assertNull(host.settings.state.value.privacy.summary)
            host.settings.ensurePrivacySummaryLoaded()
            assertTrue(await { host.settings.state.value.privacy.summary != null })
            assertEquals(11L, host.settings.state.value.privacy.summary!!.conversationCount)
            assertNull(host.settings.state.value.privacyStatus.error)
            host.stop()
        }
    }

    @Test
    fun replacedTerminalSettlesSupersededInsteadOfLoadingForever() = runBlocking {
        val exchange = ScriptExchange(
            receiptFor = { _, c -> "op:v1:privacy-$c" },
            effectFor = { receipt, correlation -> replaced(correlation, receipt) },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("settingsPrivacy", true, emptyList())
        host.settings.refreshPrivacySummary()
        assertTrue(
            await { host.settings.state.value.privacyStatus.error == "superseded" },
        )
        assertFalse(host.settings.state.value.privacyStatus.loading)
        assertNull(host.settings.state.value.privacy.summary)
        host.stop()
    }

    @Test
    fun pageOpenRecoversUnsettledPrivacySurface() = runBlocking {
        val exchange = ScriptExchange(
            receiptFor = { command, c ->
                if (command == "privacy.summary.get") "op:v1:privacy-$c"
                else "op:v1:other-$c"
            },
            effectFor = { receipt, correlation ->
                if (receipt.startsWith("op:v1:privacy-")) {
                    accepted(correlation, receipt, summaryDoc())
                } else {
                    closed(correlation, receipt)
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("settingsPrivacy", true, emptyList())
        assertNull(host.settings.state.value.privacy.summary)
        assertTrue(host.settings.state.value.privacyStatus.loading)

        host.settings.ensurePrivacySummaryLoaded()
        assertTrue(await { host.settings.state.value.privacy.summary != null })
        assertEquals(1, exchange.count("privacy.summary.get"))
        assertNull(host.settings.state.value.privacyStatus.error)
        assertFalse(host.settings.state.value.privacyStatus.loading)
        host.stop()
    }

    /**
     * The actual Alpha7 freshness defect: the Privacy card kept showing the
     * startup-era summary (counts loaded once for the process) no matter how
     * often the page was opened, because the page-entry ensure returned
     * early whenever ANY summary had settled. The dynamic counts — above all
     * the runtime grant array appended by the live actor between visits —
     * must refresh on EVERY actual page entry: the settled projection stays
     * on screen while the fresh read is pending, and a late reply from a
     * superseded read generation can never rewind the fresh counts.
     */
    @Test
    fun pageEntryRefreshesSettledSummaryWithLiveCounts() = runBlocking {
        val reads = AtomicInteger(0)
        val staleReplyRelease = java.util.concurrent.CountDownLatch(1)
        val exchange = ScriptExchange(
            receiptFor = { command, c ->
                if (command == "privacy.summary.get") {
                    "op:v1:privacy-${reads.incrementAndGet()}-$c"
                } else {
                    "op:v1:other-$c"
                }
            },
            effectFor = { receipt, correlation ->
                when {
                    // Startup read: the process-lifetime first counts, 0
                    // runtime grants — the values that used to stick forever.
                    receipt.startsWith("op:v1:privacy-1-") ->
                        accepted(correlation, receipt, summaryDoc())
                    // First page-entry read: held so the superseded late
                    // reply proves the generation fence.
                    receipt.startsWith("op:v1:privacy-2-") -> {
                        check(
                            staleReplyRelease.await(
                                5, java.util.concurrent.TimeUnit.SECONDS,
                            ),
                        )
                        accepted(
                            correlation, receipt,
                            summaryDoc(111, 115, inMemoryGrants = 9),
                        )
                    }
                    // Repeated page-entry read: the fresh authoritative
                    // backend answer (new task + one live approved grant).
                    receipt.startsWith("op:v1:privacy-3-") ->
                        accepted(
                            correlation, receipt,
                            summaryDoc(14, 18, inMemoryGrants = 1),
                        )
                    else -> closed(correlation, receipt)
                }
            },
        )
        val host = testHost(exchange)
        try {
            host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
            // Simulate the host's explicit startup reader: 11/15, 0 grants.
            host.onDomainAvailability("settingsPrivacy", true, emptyList())
            host.settings.refreshPrivacySummary()
            assertTrue(await { host.settings.state.value.privacy.summary != null })
            assertEquals(11L, host.settings.state.value.privacy.summary!!.conversationCount)
            assertEquals(15L, host.settings.state.value.privacy.summary!!.runCount)
            assertEquals(0L, host.settings.state.value.privacy.summary!!.inMemoryGrantCount)

            // First actual page entry: a fresh read starts even though a
            // summary settled at startup — the cached 0-grant counts must
            // not be mistaken as fresh — and the settled projection stays
            // on screen while the read is pending.
            host.settings.ensurePrivacySummaryLoaded()
            assertTrue(
                "page entry must start a fresh read over a settled summary",
                await { exchange.count("privacy.summary.get") == 2 },
            )
            assertEquals(
                11L,
                host.settings.state.value.privacy.summary!!.conversationCount,
            )
            assertEquals(
                0L,
                host.settings.state.value.privacy.summary!!.inMemoryGrantCount,
            )

            // A repeated page entry supersedes the held read and lands the
            // live counts.
            host.settings.ensurePrivacySummaryLoaded()
            assertTrue(
                await {
                    host.settings.state.value.privacy.summary!!.conversationCount == 14L
                },
            )
            assertEquals(18L, host.settings.state.value.privacy.summary!!.runCount)
            assertEquals(1L, host.settings.state.value.privacy.summary!!.inMemoryGrantCount)
            assertNull(host.settings.state.value.privacyStatus.error)
            assertFalse(host.settings.state.value.privacyStatus.loading)

            // The held older-generation reply can never rewind the fresh
            // counts.
            staleReplyRelease.countDown()
            delay(150)
            assertEquals(14L, host.settings.state.value.privacy.summary!!.conversationCount)
            assertEquals(1L, host.settings.state.value.privacy.summary!!.inMemoryGrantCount)
            assertNull(host.settings.state.value.privacyStatus.error)
        } finally {
            staleReplyRelease.countDown()
            host.stop()
        }
    }

    @Test
    fun cancelledTerminalSettlesTypedErrorInsteadOfLoadingForever() = runBlocking {
        val exchange = ScriptExchange(
            receiptFor = { command, c ->
                if (command == "privacy.summary.get") "op:v1:privacy-$c"
                else "op:v1:other-$c"
            },
            effectFor = { receipt, correlation ->
                if (receipt.startsWith("op:v1:privacy-")) {
                    cancelled(correlation, receipt)
                } else {
                    closed(correlation, receipt)
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("settingsPrivacy", true, emptyList())
        host.settings.refreshPrivacySummary()
        assertTrue(await { host.settings.state.value.privacyStatus.error == "cancelled" })
        assertFalse(host.settings.state.value.privacyStatus.loading)
        assertNull(host.settings.state.value.privacy.summary)
        host.stop()
    }

    // ------------------------------------------- completed temporary turn

    /**
     * The completed-turn path Main identified as necessary: a real
     * temp.start, a real run.start that reaches a terminal run event, then
     * temp.end. The root privacy summary must stay usable and the page-open
     * ensure must still refresh it afterwards. No cloud/network call: the
     * transport is a fixed scripted local exchange.
     */
    @Test
    fun completedTemporaryTurnLeavesPrivacySummaryUsable() = runBlocking {
        var endCorrelation: String? = null
        val eventPolls = AtomicInteger(0)
        val privacyReads = AtomicInteger(0)
        val exchange = ScriptExchange(
            receiptFor = { command, c ->
                when (command) {
                    "temp.start" -> "op:v1:tstart"
                    "config.providers.list" -> "op:v1:providers"
                    "conversation.get" -> "op:v1:cget-$c"
                    "run.start" -> "op:v1:rstart"
                    "temp.end" -> {
                        endCorrelation = c
                        "op:v1:tend"
                    }
                    "privacy.summary.get" -> "op:v1:privacy-$c"
                    else -> "op:v1:other-$c"
                }
            },
            effectFor = { receipt, correlation ->
                when {
                    receipt == "op:v1:tstart" -> accepted(
                        correlation, receipt,
                        """{"conversationID":"$tempConversationId","incarnation":"inc-1","rootEpoch":$rootEpoch}""",
                    )
                    receipt == "op:v1:providers" -> accepted(
                        correlation, receipt,
                        """{"rows":[${providerRow()}]}""",
                    )
                    receipt.startsWith("op:v1:cget-") -> accepted(
                        correlation, receipt,
                        """{"conversationID":"$tempConversationId","title":"Temporary",""" +
                            """"revision":{"resourceID":"conversation.${tempConversationId.uppercase()}",""" +
                            """"version":"digest-1"},"runs":[],"pendingInputs":[],""" +
                            """"taskPolicy":{"resolvedApprovalMode":"ask"}}""",
                    )
                    receipt == "op:v1:rstart" -> runStartPage(correlation, receipt)
                    receipt.startsWith("op:v1:privacy-") -> {
                        privacyReads.incrementAndGet()
                        accepted(correlation, receipt, summaryDoc())
                    }
                    receipt == "op:v1:tend" -> {
                        // Admit from the exact typed ack first; the accepted
                        // terminal is deliberately delivered on the NEXT poll
                        // (a late completion after the route may move).
                        if (eventPolls.getAndIncrement() == 0) {
                            """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3",""" +
                                """"correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":1},""" +
                                """"effects":[{"sequence":1,"kind":"prepared","value":${ack(endCorrelation!!)}}],""" +
                                """"hasMore":true,"resyncRequired":false}"""
                        } else {
                            """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3",""" +
                                """"correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":2},""" +
                                """"effects":[{"sequence":2,"kind":"accepted","value":{"session":"ended"}}],""" +
                                """"hasMore":false,"resyncRequired":false}"""
                        }
                    }
                    else -> closed(correlation, receipt)
                }
            },
        )
        // The run event pump is separate from the effect pumps; intercept it
        // at the exchange boundary by returning the run's terminal page.
        val eventExchange = object : HostBridgeExchange {
            override fun exchange(request: String): String {
                if (request.contains("\"operation\":\"event.poll\"")) {
                    exchange.requests.add(request)
                    val correlation = correlationOf(request)
                    return eventPage(correlation)
                }
                return exchange.exchange(request)
            }
        }
        val host = testHost(eventExchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("conversationDomain", true, emptyList())
        host.onDomainAvailability("runDomain", true, emptyList())
        host.onDomainAvailability("temporaryDomain", true, emptyList())
        host.onDomainAvailability("settingsPrivacy", true, emptyList())
        host.providers.refreshProviders()
        assertTrue(
            "the real provider row must project before the temporary launch",
            await { host.providers.destination.value.list.conversationProviders.isNotEmpty() },
        )
        host.settings.refreshPrivacySummary()
        assertTrue(await { host.settings.state.value.privacy.summary != null })
        val before = host.settings.state.value.privacy.summary!!.conversationCount

        // 1. A real temporary session exists.
        var started: TemporarySessionRef? = null
        var startFailure: String? = null
        assertTrue(
            host.conversations.startTemporarySession(
                draft = "Reply only LOCAL_OK.",
                preferredModelID = null,
                onStarted = { started = it },
                onFailure = { startFailure = it },
            ),
        )
        assertTrue("temp.start failed: $startFailure", await { started != null })
        val ref = started!!

        // 2. A real run launches for that temporary conversation and reaches
        //    a completed terminal event (the completed-turn shape).
        val holder = host.conversations.holderFor(
            conversationId = ref.conversationId,
            isTemporary = true,
            incarnationId = ref.incarnationId,
            temporaryNativeRootEpoch = ref.nativeRootEpoch,
        )
        var admitted = false
        var launchFailure: String? = null
        assertTrue(
            host.conversations.startRun(
                RunLaunchRequest(
                    conversationId = ref.conversationId,
                    sessionEpoch = holder.session.sessionEpoch,
                    goalText = "Reply only LOCAL_OK.",
                    attachments = emptyList(),
                    executionMode = AgentExecutionModeUi.CHAT,
                    modelId = modelId,
                    workspaceId = null,
                    temporaryIncarnationId = ref.incarnationId,
                    launchGeneration = 1,
                    providerId = providerId,
                ),
                { ok, reason ->
                    admitted = ok
                    launchFailure = reason
                },
            ),
        )
        assertTrue(
            "run.start not admitted: $launchFailure tempStart=${exchange.count("temp.start")} " +
                "cget=${exchange.count("conversation.get")} rstart=${exchange.count("run.start")} " +
                "tend=${exchange.count("temp.end")} " +
                "requests=${exchange.requests.takeLast(6)}",
            await { admitted },
        )
        assertTrue(
            "the completed run event must settle the holder",
            await { holder.snapshot.value?.isRunning == false },
        )

        // 3. New task discards the temporary session through the real fence.
        assertTrue(host.conversations.endTemporaryChat(ref))
        assertTrue(
            "temporary fence did not admit the exact ref",
            await { host.conversations.activeTemporarySession() == null },
        )
        // Let the DELAYED temp.end terminal arrive after the route moved.
        delay(100)
        // The root summary is NOT part of the temporary holder: it must
        // survive the retirement and its late terminal untouched.
        assertEquals(before, host.settings.state.value.privacy.summary!!.conversationCount)
        assertNull(host.settings.state.value.privacyStatus.error)

        // 4. Opening Settings/Privacy after the completed-turn exit now
        //    RE-READS the settled surface: the counts are live data, so a
        //    page entry is a fresh authoritative read, never a
        //    process-lifetime cache hit. The exit itself did not lose the
        //    root summary — it stays usable across the refresh (the
        //    scripted backend still answers 11/15 here; fresh counts
        //    replacing stale ones are pinned by
        //    pageEntryRefreshesSettledSummaryWithLiveCounts below).
        val readsBefore = privacyReads.get()
        host.settings.ensurePrivacySummaryLoaded()
        assertTrue(
            "page entry must re-read the settled privacy summary",
            await { privacyReads.get() > readsBefore },
        )
        assertTrue(
            await {
                !host.settings.state.value.privacyStatus.loading &&
                    host.settings.state.value.privacyStatus.error == null
            },
        )
        val after = host.settings.state.value
        assertEquals(11L, after.privacy.summary!!.conversationCount)
        assertEquals(15L, after.privacy.summary!!.runCount)
        assertNull(after.privacyStatus.error)
        assertFalse(after.privacyStatus.loading)
        host.stop()
    }

    /**
     * Failed/cancelled temporary run retirement (the original sequence began
     * with a real failed 401 temporary request). The failed run is discarded
     * through the same fence; the root privacy summary must still load after
     * that retirement. This is the failed-side lifecycle companion to the
     * successful completed-turn test above; neither alone claims the native
     * 401→success device sequence, which Main reproduces on the owned AVD.
     */
    @Test
    fun failedTemporaryTurnStillLeavesPrivacySummaryUsable() = runBlocking {
        var endCorrelation: String? = null
        val exchange = ScriptExchange(
            receiptFor = { command, c ->
                when (command) {
                    "temp.start" -> "op:v1:tstart"
                    "config.providers.list" -> "op:v1:providers"
                    "conversation.get" -> "op:v1:cget-$c"
                    "run.start" -> "op:v1:rstart"
                    "temp.end" -> {
                        endCorrelation = c
                        "op:v1:tend"
                    }
                    "privacy.summary.get" -> "op:v1:privacy-$c"
                    else -> "op:v1:other-$c"
                }
            },
            effectFor = { receipt, correlation ->
                when {
                    receipt == "op:v1:tstart" -> accepted(
                        correlation, receipt,
                        """{"conversationID":"$tempConversationId","incarnation":"inc-1","rootEpoch":$rootEpoch}""",
                    )
                    receipt == "op:v1:providers" -> accepted(
                        correlation, receipt,
                        """{"rows":[${providerRow()}]}""",
                    )
                    receipt.startsWith("op:v1:cget-") -> accepted(
                        correlation, receipt,
                        """{"conversationID":"$tempConversationId","title":"Temporary",""" +
                            """"revision":{"resourceID":"conversation.${tempConversationId.uppercase()}",""" +
                            """"version":"digest-1"},"runs":[],"pendingInputs":[],""" +
                            """"taskPolicy":{"resolvedApprovalMode":"ask"}}""",
                    )
                    receipt == "op:v1:rstart" -> """{"version":3,"requestID":"$correlation","ok":true,""" +
                        """"schema":"floe.effect-cursor/3","correlationID":"$correlation",""" +
                        """"cursor":{"operationReceiptID":"$receipt","sequence":1},""" +
                        """"effects":[{"sequence":1,"kind":"failed","code":"authentication",""" +
                        """"detail":[]}],"hasMore":false,"resyncRequired":false}"""
                    receipt == "op:v1:tend" -> """{"version":3,"requestID":"$correlation","ok":true,""" +
                        """"schema":"floe.effect-cursor/3","correlationID":"$correlation",""" +
                        """"cursor":{"operationReceiptID":"$receipt","sequence":2},""" +
                        """"effects":[{"sequence":1,"kind":"prepared","value":${ack(endCorrelation!!)}},""" +
                        """{"sequence":2,"kind":"accepted","value":{"session":"ended"}}],""" +
                        """"hasMore":false,"resyncRequired":false}"""
                    receipt.startsWith("op:v1:privacy-") -> accepted(
                        correlation, receipt, summaryDoc(),
                    )
                    else -> closed(correlation, receipt)
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("conversationDomain", true, emptyList())
        host.onDomainAvailability("runDomain", true, emptyList())
        host.onDomainAvailability("temporaryDomain", true, emptyList())
        host.onDomainAvailability("settingsPrivacy", true, emptyList())
        host.providers.refreshProviders()
        assertTrue(await { host.providers.destination.value.list.conversationProviders.isNotEmpty() })
        host.settings.refreshPrivacySummary()
        assertTrue(await { host.settings.state.value.privacy.summary != null })

        var started: TemporarySessionRef? = null
        var startFailure: String? = null
        assertTrue(
            host.conversations.startTemporarySession(
                draft = "Reply only LOCAL_OK.",
                preferredModelID = null,
                onStarted = { started = it },
                onFailure = { startFailure = it },
            ),
        )
        assertTrue("temp.start failed: $startFailure", await { started != null })
        val ref = started!!
        val holder = host.conversations.holderFor(
            conversationId = ref.conversationId,
            isTemporary = true,
            incarnationId = ref.incarnationId,
            temporaryNativeRootEpoch = ref.nativeRootEpoch,
        )
        var launchFailed = false
        var launchReason: String? = null
        assertTrue(
            host.conversations.startRun(
                RunLaunchRequest(
                    conversationId = ref.conversationId,
                    sessionEpoch = holder.session.sessionEpoch,
                    goalText = "Reply only LOCAL_OK.",
                    attachments = emptyList(),
                    executionMode = AgentExecutionModeUi.CHAT,
                    modelId = modelId,
                    workspaceId = null,
                    temporaryIncarnationId = ref.incarnationId,
                    launchGeneration = 1,
                    providerId = providerId,
                ),
                { ok, reason ->
                    if (!ok) {
                        launchFailed = true
                        launchReason = reason
                    }
                },
            ),
        )
        assertTrue(
            "the failed run terminal must settle as a launch failure (reason=$launchReason)",
            await { launchFailed },
        )
        assertEquals("authentication", launchReason)
        assertTrue(host.conversations.endTemporaryChat(ref))
        assertTrue(await { host.conversations.activeTemporarySession() == null })

        host.settings.ensurePrivacySummaryLoaded()
        assertTrue(
            await {
                host.settings.state.value.privacy.summary != null &&
                    !host.settings.state.value.privacyStatus.loading
            },
        )
        assertEquals(11L, host.settings.state.value.privacy.summary!!.conversationCount)
        assertNull(host.settings.state.value.privacyStatus.error)
        host.stop()
    }

    private fun providerRow(): String =
        """{"id":"$providerId","kind":"custom","wireProtocol":"openAIChatCompletions",""" +
            """"baseURL":"https://api.example.invalid/v1","displayName":"Local QA","region":null,""" +
            """"isEnabled":true,"allowsPlainHTTP":false,"toolNameCompatibility":true,""" +
            """"createdAt":"2026-10-20T00:00:00.000Z","updatedAt":"2026-10-20T00:00:00.000Z",""" +
            """"syncRevision":3,"secret":{"configured":true,"opaqueReference":"ref:v1:abc",""" +
            """"synchronizable":false}}"""

    private fun runStartPage(correlation: String, receipt: String): String =
        """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3",""" +
            """"correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":2},""" +
            """"effects":[{"sequence":1,"kind":"prepared","detail":[""" +
            """{"key":"conversationID","value":"$tempConversationId"},""" +
            """{"key":"runID","value":"$tempRunId"},""" +
            """{"key":"resourceID","value":"run.${tempRunId.uppercase()}"},""" +
            """{"key":"version","value":"preparing"}]},""" +
            """{"sequence":2,"kind":"accepted","value":{"conversationID":"$tempConversationId",""" +
            """"runID":"$tempRunId"}}],"hasMore":false,"resyncRequired":false}"""

    private fun eventPage(correlation: String): String {
        val payload = JsonPrimitive("""{"state":"completed"}""").toString()
        return """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.event-cursor/3",""" +
            """"correlationID":"$correlation","cursor":{"runID":"$tempRunId","sequence":1},""" +
            """"durable":{"windowState":"attached","events":[{"sequence":1,"kind":"status",""" +
            """"createdAt":123,"payload":$payload}],"hasMore":false,"resyncRequired":false,""" +
            """"nextSequence":1},"live":{"liveState":"noConsumer","frames":[],"resyncRequired":false},""" +
            """"resyncRequired":false}"""
    }

    private fun ack(correlation: String): String =
        """{"navigationFence":{"admitted":true,"conversationID":"$tempConversationId",""" +
            """"incarnationID":"inc-1","requestCorrelationID":"$correlation","epoch":$rootEpoch}}"""
}
