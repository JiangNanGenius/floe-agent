// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Settings Memory/Personalization/Usage page-readiness recovery and terminal
 * settlement (G02-R7), plus the additive workspace-directory accounting in
 * the privacy history-clear report decode.
 *
 * Scripted transport doubles only; no JNI, real store, device or network.
 * The host start is the normal first reader; these tests pin the gaps R6
 * closed for Privacy but not for the other settings surfaces:
 *  * a missed initial readiness snapshot leaves the surface on the default
 *    loading flag; the page-open ensure re-reads ONCE (user-triggered, never
 *    a poll) and settles typed `unavailable` when the domain stays blocked;
 *  * Cancelled / Superseded / valueless terminals settle typed retryable
 *    errors — never a permanent "Loading…", never a fabricated empty
 *    inventory/document/zero usage report;
 *  * a settled surface (even an empty one) is never re-read by the ensure;
 *  * the serialized `update {}` aggregate mutation stays intact.
 */
class SettingsPageRecoveryLifecycleTest {

    private val rootEpoch = 7L

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

    private fun memoryListDoc(entries: Int = 2): String {
        val rows = (1..entries).joinToString(",") { index ->
            """{"id":"mem-$index","content":"memory $index","scope":{"kind":"user"},""" +
                """"status":"active","importance":0.5,"isPinned":false,"revision":"r$index"}"""
        }
        return """{"entries":[$rows],"nextCursor":null}"""
    }

    private fun personalizationDoc(kind: String = "soul", content: String = "doc"): String =
        """{"active":{"revision":1,"content":"$content"},"revisionsMeta":[],""" +
            """"revisionsNextCursor":null,"cursor":{"automaticUpdatesEnabled":false},""" +
            """"latestRevision":1,"revisionToken":"tok-$kind"}"""

    private fun usageDoc(): String =
        """{"totals":{"inputTokens":10,"outputTokens":20,"totalTokens":30,"runs":2},""" +
            """"byDay":[],"rows":[],"nextCursor":null}"""

    private fun clearReportDoc(
        workspaceRemoved: String? = null,
        workspaceAbsent: String? = null,
        workspaceDeferred: String? = null,
    ): String {
        val workspace = if (workspaceRemoved != null) {
            ""","workspaceDirectories":{"removed":$workspaceRemoved,""" +
                """"absent":${workspaceAbsent ?: 0},"deferred":${workspaceDeferred ?: 0}}"""
        } else {
            ""
        }
        return """{"enumerated":{"conversations":2,"runs":3,"persistedGrants":0,"inMemoryGrants":0},""" +
            """"deleted":{"conversations":2,"runs":3,"persistedGrants":0,"inMemoryGrants":0},""" +
            """"failures":[],"partial":false,""" +
            """"remaining":{"conversationCount":0,"runCount":0,"persistedGrantCount":0,"inMemoryGrantCount":0}""" +
            "$workspace}"
    }

    // -------------------------------------------------------------- memory

    @Test
    fun memoryEnsureReReadsAnUnsettledSurfaceOnceAndSettles() = runBlocking {
        // The FIRST read's receipt never answers (a genuinely lost
        // terminal); any later read settles normally.
        val lostReceipt = java.util.concurrent.atomic.AtomicReference<String?>(null)
        val exchange = ScriptExchange(
            receiptFor = { command, c ->
                if (command == "memory.list") "op:v1:memory-$c" else "op:v1:other-$c"
            },
            effectFor = { receipt, correlation ->
                if (receipt.startsWith("op:v1:memory-")) {
                    val ignored = lostReceipt.get()
                    when {
                        ignored == null -> {
                            lostReceipt.set(receipt)
                            null
                        }
                        ignored == receipt -> null
                        else -> accepted(correlation, receipt, memoryListDoc())
                    }
                } else {
                    closed(correlation, receipt)
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.settings.start()
        // Late admission loads the inventory once; its terminal is LOST (no
        // effect page ever answers), leaving the surface unsettled.
        host.onDomainAvailability("settingsMemory", true, emptyList())
        assertTrue(await { exchange.count("memory.list") == 1 })
        kotlinx.coroutines.delay(150)
        assertTrue(
            "the lost terminal must not settle the surface",
            host.settings.state.value.memoryStatus.loading,
        )
        assertFalse(host.settings.state.value.memory.loaded)

        // Page open: the still-unsettled surface re-reads once.
        host.settings.ensureMemoryLoaded()
        assertTrue(
            "page-open recovery did not settle the memory inventory",
            await { host.settings.state.value.memory.entries.size == 2 },
        )
        val state = host.settings.state.value
        assertTrue(state.memory.loaded)
        assertFalse(state.memoryStatus.loading)
        assertNull(state.memoryStatus.error)
        assertEquals(2, exchange.count("memory.list"))

        // A second page open NEVER re-reads settled data.
        host.settings.ensureMemoryLoaded()
        kotlinx.coroutines.delay(120)
        assertEquals(2, exchange.count("memory.list"))
        host.stop()
    }

    @Test
    fun memoryCancelledAndSupersededTerminalsSettleTypedErrors() = runBlocking {
        for ((effect, code) in listOf(
            { c: String, r: String -> cancelled(c, r) } to "cancelled",
            { c: String, r: String -> replaced(c, r) } to "superseded",
        )) {
            val exchange = ScriptExchange(
                receiptFor = { command, c ->
                    if (command == "memory.list") "op:v1:memory-$c" else "op:v1:other-$c"
                },
                effectFor = { receipt, correlation ->
                    if (receipt.startsWith("op:v1:memory-")) {
                        effect(correlation, receipt)
                    } else {
                        closed(correlation, receipt)
                    }
                },
            )
            val host = testHost(exchange)
            host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
            host.settings.start()
            host.onDomainAvailability("settingsMemory", true, emptyList())
            assertTrue(
                "memory $code terminal must settle typed (status=" +
                    "${host.settings.state.value.memoryStatus})",
                await { host.settings.state.value.memoryStatus.error == code },
            )
            val state = host.settings.state.value
            assertFalse(state.memoryStatus.loading)
            assertTrue(state.memory.loaded)
            assertTrue(state.memory.entries.isEmpty())
            host.stop()
        }
    }

    @Test
    fun memoryValuelessCompletedTerminalIsNotAFabricatedEmptyInventory() = runBlocking {
        val exchange = ScriptExchange(
            receiptFor = { command, c ->
                if (command == "memory.list") "op:v1:memory-$c" else "op:v1:other-$c"
            },
            effectFor = { receipt, correlation ->
                if (receipt.startsWith("op:v1:memory-")) {
                    closed(correlation, receipt)
                } else {
                    closed(correlation, receipt)
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.settings.start()
        host.onDomainAvailability("settingsMemory", true, emptyList())
        assertTrue(
            "a valueless memory.list terminal must surface a typed error " +
                "(status=${host.settings.state.value.memoryStatus})",
            await { host.settings.state.value.memoryStatus.error == "listUnavailable" },
        )
        assertTrue(host.settings.state.value.memory.loaded)
        host.stop()
    }

    @Test
    fun memoryReadWithoutAdmissionSettlesUnavailableWithoutDispatch() = runBlocking {
        val exchange = ScriptExchange(effectFor = { _, _ -> null })
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.settings.start()
        host.settings.refreshMemory()
        kotlinx.coroutines.delay(120)
        assertEquals(0, exchange.count("memory.list"))
        assertEquals("unavailable", host.settings.state.value.memoryStatus.error)
        assertFalse(host.settings.state.value.memoryStatus.loading)
        host.stop()
    }

    // ----------------------------------------------------- personalization

    @Test
    fun personalizationCancelledTerminalSettlesTypedAndKeepsDocumentClosed() = runBlocking {
        val exchange = ScriptExchange(
            receiptFor = { command, c ->
                if (command == "personalization.get") "op:v1:perso-$c" else "op:v1:other-$c"
            },
            effectFor = { receipt, correlation ->
                if (receipt.startsWith("op:v1:perso-")) {
                    cancelled(correlation, receipt)
                } else {
                    closed(correlation, receipt)
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.settings.start()
        host.onDomainAvailability("settingsPersonalization", true, emptyList())
        assertTrue(
            "personalization cancelled terminal must settle typed (status=" +
                "${host.settings.state.value.personalizationStatus})",
            await { host.settings.state.value.personalizationStatus.error == "cancelled" },
        )
        val surface = host.settings.state.value.personalization
        assertFalse(host.settings.state.value.personalizationStatus.loading)
        assertTrue(surface.loaded)
        assertFalse(surface.contentLoading)
        host.stop()
    }

    @Test
    fun personalizationValuelessTerminalIsNotAnEmptyDocument() = runBlocking {
        val exchange = ScriptExchange(
            receiptFor = { command, c ->
                if (command == "personalization.get") "op:v1:perso-$c" else "op:v1:other-$c"
            },
            effectFor = { receipt, correlation ->
                if (receipt.startsWith("op:v1:perso-")) {
                    closed(correlation, receipt)
                } else {
                    closed(correlation, receipt)
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.settings.start()
        host.onDomainAvailability("settingsPersonalization", true, emptyList())
        assertTrue(
            await { host.settings.state.value.personalizationStatus.error == "documentUnavailable" },
        )
        assertTrue(host.settings.state.value.personalization.loaded)
        host.stop()
    }

    @Test
    fun personalizationEnsureDoesNotRereadASettledDocument() = runBlocking {
        val exchange = ScriptExchange(
            receiptFor = { command, c ->
                if (command == "personalization.get") "op:v1:perso-$c" else "op:v1:other-$c"
            },
            effectFor = { receipt, correlation ->
                if (receipt.startsWith("op:v1:perso-")) {
                    accepted(correlation, receipt, personalizationDoc())
                } else {
                    closed(correlation, receipt)
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.settings.start()
        host.onDomainAvailability("settingsPersonalization", true, emptyList())
        assertTrue(await { host.settings.state.value.personalization.loaded })
        assertEquals(1, exchange.count("personalization.get"))
        host.settings.ensurePersonalizationLoaded()
        kotlinx.coroutines.delay(120)
        assertEquals(1, exchange.count("personalization.get"))
        host.stop()
    }

    // ---------------------------------------------------------------- usage

    @Test
    fun usageSupersededTerminalSettlesTypedAndNeverFabricatesZeroTotals() = runBlocking {
        val exchange = ScriptExchange(
            receiptFor = { command, c ->
                if (command == "usage.statistics.get") "op:v1:usage-$c" else "op:v1:other-$c"
            },
            effectFor = { receipt, correlation ->
                if (receipt.startsWith("op:v1:usage-")) {
                    replaced(correlation, receipt)
                } else {
                    closed(correlation, receipt)
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.settings.start()
        host.onDomainAvailability("settingsUsage", true, emptyList())
        assertTrue(
            "usage superseded terminal must settle typed (status=" +
                "${host.settings.state.value.usageStatus})",
            await { host.settings.state.value.usageStatus.error == "superseded" },
        )
        val state = host.settings.state.value
        assertFalse(state.usageStatus.loading)
        assertTrue(state.usage.loaded)
        assertNull(state.usage.totals)
        host.stop()
    }

    @Test
    fun usageValuelessTerminalIsNotANoUsageReport() = runBlocking {
        val exchange = ScriptExchange(
            receiptFor = { command, c ->
                if (command == "usage.statistics.get") "op:v1:usage-$c" else "op:v1:other-$c"
            },
            effectFor = { receipt, correlation ->
                if (receipt.startsWith("op:v1:usage-")) {
                    closed(correlation, receipt)
                } else {
                    closed(correlation, receipt)
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.settings.start()
        host.onDomainAvailability("settingsUsage", true, emptyList())
        assertTrue(
            await { host.settings.state.value.usageStatus.error == "statisticsUnavailable" },
        )
        assertTrue(host.settings.state.value.usage.loaded)
        host.stop()
    }

    @Test
    fun usageEnsureSettlesUnavailableWhileDomainStaysBlocked() = runBlocking {
        val exchange = ScriptExchange(effectFor = { _, _ -> null })
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.settings.start()
        host.settings.ensureUsageLoaded()
        assertTrue(
            await { host.settings.state.value.usageStatus.error == "unavailable" },
        )
        assertEquals(0, exchange.count("usage.statistics.get"))
        assertFalse(host.settings.state.value.usage.loaded)
        host.stop()
    }

    // ------------------------------------------- privacy clear accounting

    @Test
    fun historyClearReportDecodesRealWorkspaceDirectoryAccounting() = runBlocking {
        val exchange = ScriptExchange(
            receiptFor = { command, c ->
                when (command) {
                    "privacy.summary.get" -> "op:v1:privacy-$c"
                    "privacy.history.clear" -> "op:v1:clear-$c"
                    else -> "op:v1:other-$c"
                }
            },
            effectFor = { receipt, correlation ->
                when {
                    receipt.startsWith("op:v1:privacy-") ->
                        accepted(
                            correlation, receipt,
                            """{"history":{"conversationCount":2,"runCount":3,""" +
                                """"persistedGrantCount":0,"inMemoryGrantCount":0,""" +
                                """"revision":"sha256:1111"},""" +
                                """"modelConfiguration":{"providerCount":0,"modelCount":0,""" +
                                """"secretReferenceCount":0,"preferencesSyncRevision":0,""" +
                                """"revision":"sha256:2222"},""" +
                                """"credentialAvailability":"NEEDS_CONFIGURATION",""" +
                                """"snapshot":{"dbSnapshotTransaction":true,""" +
                                """"inMemoryGrantBracket":"ok","retriesBounded":0}}""",
                        )
                    receipt.startsWith("op:v1:clear-") ->
                        accepted(correlation, receipt, clearReportDoc("1", "1", "0"))
                    else -> closed(correlation, receipt)
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.settings.start()
        host.onDomainAvailability("settingsPrivacy", true, emptyList())
        host.onDomainAvailability("conversationDomain", true, emptyList())
        host.privacyConfirmationIssuer = { _, _, _, _, _ -> "pc:v1:cap" }
        assertTrue(await { host.settings.state.value.privacy.summary != null })

        host.settings.clearPrivacyHistory(
            host.settings.createPrivacyClearPreview(
                SettingsHostController.PrivacyClearAction.HISTORY)!!,
        ) { }
        assertTrue(
            "history clear did not settle",
            await {
                host.settings.state.value.privacyClear != null &&
                    !host.settings.state.value.privacyClear!!.inFlight
            },
        )
        val summary = host.settings.state.value.privacy.summary
        assertEquals(1L, summary?.workspaceRemoved)
        assertEquals(1L, summary?.workspaceAbsent)
        assertEquals(0L, summary?.workspaceDeferred)
        assertEquals(0L, summary?.remaining?.conversationCount)
        assertFalse(summary?.partial ?: true)
        host.stop()
    }

    @Test
    fun olderNativeClearReportWithoutWorkspaceAccountingStaysNullNotZero() = runBlocking {
        val exchange = ScriptExchange(
            receiptFor = { command, c ->
                when (command) {
                    "privacy.summary.get" -> "op:v1:privacy-$c"
                    "privacy.history.clear" -> "op:v1:clear-$c"
                    else -> "op:v1:other-$c"
                }
            },
            effectFor = { receipt, correlation ->
                when {
                    receipt.startsWith("op:v1:privacy-") ->
                        accepted(
                            correlation, receipt,
                            """{"history":{"conversationCount":2,"runCount":3,""" +
                                """"persistedGrantCount":0,"inMemoryGrantCount":0,""" +
                                """"revision":"sha256:1111"},""" +
                                """"modelConfiguration":{"providerCount":0,"modelCount":0,""" +
                                """"secretReferenceCount":0,"preferencesSyncRevision":0,""" +
                                """"revision":"sha256:2222"},""" +
                                """"credentialAvailability":"NEEDS_CONFIGURATION",""" +
                                """"snapshot":{"dbSnapshotTransaction":true,""" +
                                """"inMemoryGrantBracket":"ok","retriesBounded":0}}""",
                        )
                    receipt.startsWith("op:v1:clear-") ->
                        accepted(correlation, receipt, clearReportDoc())
                    else -> closed(correlation, receipt)
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.settings.start()
        host.onDomainAvailability("settingsPrivacy", true, emptyList())
        host.onDomainAvailability("conversationDomain", true, emptyList())
        host.privacyConfirmationIssuer = { _, _, _, _, _ -> "pc:v1:cap" }
        assertTrue(await { host.settings.state.value.privacy.summary != null })
        host.settings.clearPrivacyHistory(
            host.settings.createPrivacyClearPreview(
                SettingsHostController.PrivacyClearAction.HISTORY)!!,
        ) { }
        assertTrue(
            await {
                host.settings.state.value.privacyClear != null &&
                    !host.settings.state.value.privacyClear!!.inFlight
            },
        )
        val summary = host.settings.state.value.privacy.summary
        assertNull(summary?.workspaceRemoved)
        assertNull(summary?.workspaceAbsent)
        assertNull(summary?.workspaceDeferred)
        host.stop()
    }
}
