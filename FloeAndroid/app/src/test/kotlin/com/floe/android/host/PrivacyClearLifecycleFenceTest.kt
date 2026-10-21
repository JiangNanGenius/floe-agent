// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * R2 privacy App LIFECYCLE FENCE tests — AUTHORED, NOTRUN (scripted
 * transport doubles only; no JNI, no device, no real store).
 *
 * Closes the Main-verified root/ownership/report-decoding gaps on top of
 * the completed bridge package (job-b11fce093d3d4ef3):
 *  * A — a LATE completion of a clear authorized on a RETIRED root must not
 *    bump the preview generation, replace the new root's report slot or
 *    publish success; the truthful outcome is typed + a current-root
 *    counts refresh, while the authorized write still completes natively;
 *  * B — a counts refresh under a NEW root RESETS every report slot
 *    (remaining/failures/page/partial): carry-over is same-owner only, so
 *    a rootB summary can never inherit rootA's report handle;
 *  * C — report-page reads carry the ACTUAL root (captured/re-checked
 *    off-main), a per-READ generation (the newest read wins; concurrent
 *    same-handle cursor requests can never rewind the slot) and an
 *    in-state-update ownership re-check;
 *  * D — preview creation pins the PROJECTION's cached root epoch and
 *    performs NO native readback on the calling (UI) thread; the actual
 *    root validation stays off-main in the confirm path;
 *  * E — a Completed outcome with a missing/shapeless report exposes
 *    report-unavailable (never a fabricated zero/success), and malformed
 *    recounts (missing/negative/non-integral counts) stay absent with a
 *    typed recount failure + forced partial=true;
 *  * F — holder survival/release is fenced by the holder ENTRY's
 *    globally-unique session epoch (never the UI session epoch, which
 *    restarts at 0 for every fresh holder): a late `notFound` of a dead
 *    holder generation cannot release a re-opened same-id holder (ABA).
 *
 * Native availability keys use the REAL wire labels (e.g. the native
 * `settingsPrivacy`, not a dotted UI label).
 */
class PrivacyClearLifecycleFenceTest {

    /** One scripted queue receipt + effect table per test, by correlation. */
    private class ScriptExchange(
        private val receiptFor: (command: String, correlation: String) -> String,
        private val effectFor: (receipt: String, correlation: String) -> String?,
    ) : HostBridgeExchange {
        val requests = java.util.concurrent.CopyOnWriteArrayList<String>()

        override fun exchange(request: String): String {
            requests.add(request)
            val correlation = correlationOf(request)
            if (request.contains("\"operation\":\"effect.poll\"")) {
                val receipt = receiptOf(request)
                return effectFor(receipt, correlation)
                    ?: """{"version":3,"requestID":"$correlation","ok":false,"schema":"floe.effect-cursor/3","correlationID":"$correlation","error":"unknownReceipt"}"""
            }
            val command = commandOf(request)
            val receipt = receiptFor(command, correlation)
            return """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"$receipt"}"""
        }

        fun envelopes(command: String): List<JsonObject> = requests
            .filter { it.contains("\"command\":\"$command\"") }
            .map { Json.parseToJsonElement(it) as JsonObject }
            .map { it["envelope"] as JsonObject }

        fun count(command: String): Int =
            requests.count { it.contains("\"command\":\"$command\"") }

        fun sawRequestContaining(fragment: String): Boolean =
            requests.any { it.contains(fragment) }

        companion object {
            fun commandOf(raw: String): String {
                val marker = "\"command\":\""
                val start = raw.indexOf(marker).takeIf { it >= 0 } ?: return ""
                val from = start + marker.length
                val end = raw.indexOf('"', from)
                return raw.substring(from, end)
            }

            fun correlationOf(raw: String): String {
                val marker = "\"correlationID\":\""
                val start = raw.indexOf(marker).takeIf { it >= 0 } ?: return ""
                val from = start + marker.length
                val end = raw.indexOf('"', from)
                return raw.substring(from, end)
            }

            fun receiptOf(raw: String): String {
                val marker = "\"operationReceiptID\":\""
                val start = raw.indexOf(marker).takeIf { it >= 0 } ?: return ""
                val from = start + marker.length
                val end = raw.indexOf('"', from)
                return raw.substring(from, end)
            }
        }
    }

    private fun testHost(
        exchange: HostBridgeExchange,
        epoch: () -> Long? = { 7L },
    ): RuntimeHost {
        val client = RuntimeHostCommandClient(
            exchange = exchange,
            scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default),
            ioDispatcher = kotlinx.coroutines.Dispatchers.Default,
            budgets = HostWireBudgets(effectPollIntervalMillis = 1),
        )
        val host = RuntimeHost(
            commandClient = client,
            gatewayCapability = kotlinx.coroutines.flow.MutableStateFlow(
                com.floe.android.SecretGatewayCapability.Loading),
            bootstrapCapability = kotlinx.coroutines.flow.MutableStateFlow(
                com.floe.android.RuntimeBootstrapCapability.Idle),
            scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default),
            ioDispatcher = kotlinx.coroutines.Dispatchers.Default,
        )
        host.nativeRootEpochReader = epoch
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        // NATIVE availability key (the dotted UI label would never admit).
        host.onDomainAvailability("settingsPrivacy", true, emptyList())
        return host
    }

    private fun await(condition: () -> Boolean) {
        val deadline = System.nanoTime() + 3_000_000_000L
        while (System.nanoTime() < deadline) {
            if (condition()) return
            Thread.sleep(10)
        }
        assertTrue("condition not met within timeout", condition())
    }

    private fun accepted(correlation: String, receipt: String, doc: String) =
        """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3",""" +
            """"correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":1},""" +
            """"effects":[{"sequence":1,"kind":"accepted","value":$doc}],"hasMore":false,"resyncRequired":false}"""

    private fun rejected(correlation: String, receipt: String, code: String) =
        """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3",""" +
            """"correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":1},""" +
            """"effects":[{"sequence":1,"kind":"rejected","code":"$code","detail":[]}],""" +
            """"hasMore":false,"resyncRequired":false}"""

    private fun summaryDoc(histRev: String, mcfgRev: String) =
        """{"history":{"conversationCount":2,"runCount":3,"persistedGrantCount":1,"inMemoryGrantCount":0,"revision":"$histRev"},"modelConfiguration":{"providerCount":1,"modelCount":2,"secretReferenceCount":1,"preferencesSyncRevision":4,"revision":"$mcfgRev"},"credentialAvailability":"AVAILABLE","snapshot":{"dbSnapshotTransaction":true,"inMemoryGrantBracket":"ok","retriesBounded":0}}"""

    private fun histRev(n: Int) = "sha256:" + n.toString().repeat(64).take(64)
    private fun mcfgRev(n: Int) = "sha256:" + (n + 100).toString().repeat(64).take(64)

    private val historyClearReport = """{"enumerated":{"conversations":3,"runs":4,"persistedGrants":2,"inMemoryGrants":0},"deleted":{"conversations":2,"runs":2,"persistedGrants":1,"inMemoryGrants":0},"failures":[{"itemID":"c-del","phase":"deleteConversation","reason":"locked"}],"partial":true,"remaining":{"conversationCount":1,"runCount":1,"persistedGrantCount":1,"inMemoryGrantCount":0},"remainingFailure":null,"failurePage":{"handle":"pr:v1:hist1","returned":1,"total":3,"nextCursor":"rc:v1:1"}}"""

    private fun pageDoc(handle: String, itemID: String, nextCursor: String?) =
        """{"report":{"handle":"$handle","kind":"history","items":[{"itemID":"$itemID","phase":"drain","reason":"x"}],"nextCursor":${nextCursor?.let { "\"$it\"" } ?: "null"},"total":3,"done":${if (nextCursor == null) "true" else "false"}}}"""

    // ------------------------------------------------------------- A

    @Test
    fun lateCompletionFromRetiredRootNeverReplacesCurrentRootReport() = runBlocking {
        var epoch: Long? = 7L
        val clearGate = CountDownLatch(1)
        val exchange = ScriptExchange(
            receiptFor = { command, c ->
                // The Root retires the moment the authorized clear is
                // submitted — before any of its effect polls.
                if (command == "privacy.history.clear") epoch = 8L
                "rc:$c"
            },
            effectFor = { receipt, correlation ->
                when {
                    receipt == "rc:prget-1" ->
                        accepted(correlation, receipt, summaryDoc(histRev(1), mcfgRev(1)))
                    receipt.startsWith("rc:prget") ->
                        accepted(correlation, receipt, summaryDoc(histRev(2), mcfgRev(2)))
                    receipt.startsWith("rc:prh") -> {
                        clearGate.await(2, TimeUnit.SECONDS)
                        accepted(correlation, receipt, historyClearReport)
                    }
                    else -> null
                }
            },
        )
        val host = testHost(exchange) { epoch }
        host.onDomainAvailability("conversationDomain", true, emptyList())
        host.privacyConfirmationIssuer = { _, _, _, _, _ -> "pc:v1:cap" }
        host.settings.refreshPrivacySummary()
        await { host.settings.state.value.privacy.summary != null }
        val preview = host.settings.createPrivacyClearPreview(
            SettingsHostController.PrivacyClearAction.HISTORY)!!
        var outcome: String? = "unset"
        host.settings.clearPrivacyHistory(preview) { outcome = it }
        await { exchange.count("privacy.history.clear") == 1 }
        // Surface re-read under the NEW root BEFORE the late terminal lands.
        host.settings.refreshPrivacySummary()
        await { host.settings.state.value.privacy.rootEpoch == 8L }
        assertNull(host.settings.state.value.privacy.reportPage)
        clearGate.countDown()
        await { outcome != "unset" }
        // Truthful typed outcome — NOT success; the rootA report never
        // touched the rootB surface.
        assertEquals("rootChanged", outcome)
        assertEquals("rootChanged", host.settings.state.value.privacyClear?.error)
        assertNull(host.settings.state.value.privacy.reportPage)
        val summary = host.settings.state.value.privacy.summary!!
        assertFalse(summary.partial)
        assertNull(summary.remaining)
        assertEquals(histRev(2), summary.historyRevision)
        // Exactly ONE clear dispatched; no replay against the new root.
        assertEquals(1, exchange.count("privacy.history.clear"))
    }

    // ------------------------------------------------------------- B

    @Test
    fun crossRootSummaryReadResetsReportSlots() = runBlocking {
        var epoch: Long? = 7L
        val exchange = ScriptExchange(
            receiptFor = { _, c -> "rc:$c" },
            effectFor = { receipt, correlation ->
                when {
                    receipt == "rc:prget-1" ->
                        accepted(correlation, receipt, summaryDoc(histRev(1), mcfgRev(1)))
                    receipt.startsWith("rc:prget") ->
                        accepted(correlation, receipt, summaryDoc(histRev(2), mcfgRev(2)))
                    receipt.startsWith("rc:prh") ->
                        accepted(correlation, receipt, historyClearReport)
                    else -> null
                }
            },
        )
        val host = testHost(exchange) { epoch }
        host.onDomainAvailability("conversationDomain", true, emptyList())
        host.privacyConfirmationIssuer = { _, _, _, _, _ -> "pc:v1:cap" }
        host.settings.refreshPrivacySummary()
        await { host.settings.state.value.privacy.summary != null }
        val preview = host.settings.createPrivacyClearPreview(
            SettingsHostController.PrivacyClearAction.HISTORY)!!
        var outcome: String? = "unset"
        host.settings.clearPrivacyHistory(preview) { outcome = it }
        await { outcome == null }
        // Same-root report truth landed.
        val applied = host.settings.state.value.privacy
        assertEquals("pr:v1:hist1", applied.reportPage?.handle)
        assertTrue(applied.summary!!.partial)
        assertEquals(1L, applied.summary.remaining?.conversationCount)
        assertEquals(1, applied.historyFailures.size)
        // The root retires BEFORE the next read starts: the before/after
        // dispatch checks cannot see it (the captured epoch IS the new
        // root), so the DECODER's same-owner rule must reset every slot.
        epoch = 8L
        host.settings.refreshPrivacySummary()
        await { host.settings.state.value.privacy.rootEpoch == 8L }
        val privacy = host.settings.state.value.privacy
        assertNull(privacy.reportPage)
        assertTrue(privacy.historyFailures.isEmpty())
        assertTrue(privacy.modelConfigFailures.isEmpty())
        val summary = privacy.summary!!
        assertFalse(summary.partial)
        assertNull(summary.remaining)
        assertNull(summary.remainingFailure)
        assertNull(summary.modelRemaining)
        assertNull(summary.modelRemainingFailure)
        assertNull(summary.preferencesReset)
        assertEquals(histRev(2), summary.historyRevision)
    }

    // ------------------------------------------------------------- C

    @Test
    fun newestReportPageReadWinsOlderLateReadCannotRewind() = runBlocking {
        val olderGate = CountDownLatch(1)
        val pageReads = java.util.concurrent.atomic.AtomicInteger()
        val exchange = ScriptExchange(
            receiptFor = { command, c ->
                if (command == "privacy.summary.get" && c.startsWith("prpage-")) "rc:prpage-${pageReads.incrementAndGet()}"
                else "rc:$c"
            },
            effectFor = { receipt, correlation ->
                when {
                    receipt.startsWith("rc:prget") ->
                        accepted(correlation, receipt, summaryDoc(histRev(1), mcfgRev(1)))
                    receipt.startsWith("rc:prh") ->
                        accepted(correlation, receipt, historyClearReport)
                    receipt == "rc:prpage-1" -> {
                        // The OLDER read's reply is held back until the
                        // newer read already owns the slot.
                        olderGate.await(2, TimeUnit.SECONDS)
                        accepted(correlation, receipt,
                            pageDoc("pr:v1:hist1", "old-rewind", "rc:v1:9"))
                    }
                    receipt == "rc:prpage-2" ->
                        accepted(correlation, receipt,
                            pageDoc("pr:v1:hist1", "new-item", "rc:v1:3"))
                    else -> null
                }
            },
        )
        val host = testHost(exchange)
        host.privacyConfirmationIssuer = { _, _, _, _, _ -> "pc:v1:cap" }
        host.settings.refreshPrivacySummary()
        await { host.settings.state.value.privacy.summary != null }
        val preview = host.settings.createPrivacyClearPreview(
            SettingsHostController.PrivacyClearAction.HISTORY)!!
        host.settings.clearPrivacyHistory(preview) { }
        await { host.settings.state.value.privacy.reportPage != null }
        // Duplicated "More" tap: two concurrent same-handle cursor reads.
        var olderPage: SettingsHostController.PrivacyReportPage? = null
        var newerPage: SettingsHostController.PrivacyReportPage? = null
        var olderAnswered = false
        var newerAnswered = false
        host.settings.readPrivacyReportPage("pr:v1:hist1", "history", "rc:v1:1", 50) {
            olderPage = it
            olderAnswered = true
        }
        // Wait until the FIRST read is fully issued so its read generation
        // is certainly the older one, then issue the newer read.
        await { exchange.sawRequestContaining("\"cursor\":\"rc:v1:1\"") }
        host.settings.readPrivacyReportPage("pr:v1:hist1", "history", "rc:v1:1", 50) {
            newerPage = it
            newerAnswered = true
        }
        await { newerAnswered }
        assertNotNull(newerPage)
        assertEquals("rc:v1:3", newerPage!!.nextCursor)
        assertEquals("new-item", newerPage!!.items.single().itemID)
        // The newer page owns the slot now.
        assertEquals("rc:v1:3",
            host.settings.state.value.privacy.reportPage!!.nextCursor)
        olderGate.countDown()
        await { olderAnswered }
        // The older late read is refused and must NOT rewind the slot.
        assertNull(olderPage)
        kotlinx.coroutines.delay(200)
        val slot = host.settings.state.value.privacy.reportPage!!
        assertEquals("rc:v1:3", slot.nextCursor)
        assertEquals("new-item", slot.items.single().itemID)
    }

    @Test
    fun reportPageReadFencedByRootChange() = runBlocking {
        var epoch: Long? = 7L
        val exchange = ScriptExchange(
            receiptFor = { _, c -> "rc:$c" },
            effectFor = { receipt, correlation ->
                when {
                    receipt.startsWith("rc:prget") ->
                        accepted(correlation, receipt, summaryDoc(histRev(1), mcfgRev(1)))
                    receipt.startsWith("rc:prh") ->
                        accepted(correlation, receipt, historyClearReport)
                    receipt.startsWith("rc:prpage") -> {
                        // The Root retires between the read and its reply.
                        epoch = 8L
                        accepted(correlation, receipt,
                            pageDoc("pr:v1:hist1", "cross-root", "rc:v1:2"))
                    }
                    else -> null
                }
            },
        )
        val host = testHost(exchange) { epoch }
        host.privacyConfirmationIssuer = { _, _, _, _, _ -> "pc:v1:cap" }
        host.settings.refreshPrivacySummary()
        await { host.settings.state.value.privacy.summary != null }
        val preview = host.settings.createPrivacyClearPreview(
            SettingsHostController.PrivacyClearAction.HISTORY)!!
        host.settings.clearPrivacyHistory(preview) { }
        await { host.settings.state.value.privacy.reportPage != null }
        var answered = false
        var page: SettingsHostController.PrivacyReportPage? = null
        host.settings.readPrivacyReportPage("pr:v1:hist1", "history", "rc:v1:1", 50) {
            page = it
            answered = true
        }
        await { answered }
        // Cross-root page refused; the clear's initial report page survives.
        assertNull(page)
        val slot = host.settings.state.value.privacy.reportPage!!
        assertEquals("c-del", slot.items.single().itemID)
        assertEquals("pr:v1:hist1", slot.handle)
    }

    // ------------------------------------------------------------- D

    @Test
    fun previewCreationPinsProjectedEpochWithoutCallerThreadJni() = runBlocking {
        val testThread = Thread.currentThread()
        val exchange = ScriptExchange(
            receiptFor = { _, c -> "rc:$c" },
            effectFor = { receipt, correlation ->
                when {
                    receipt.startsWith("rc:prget") ->
                        accepted(correlation, receipt, summaryDoc(histRev(1), mcfgRev(1)))
                    receipt.startsWith("rc:prh") ->
                        accepted(correlation, receipt, historyClearReport)
                    else -> null
                }
            },
        )
        // Any native readback invoked synchronously on the CALLING (UI)
        // thread fails the test loudly.
        // Bootstrap runs on the owner's IO dispatcher in the app; only the
        // row-click and preview below deliberately execute on this UI thread.
        val host = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Default) {
            testHost(exchange) {
                if (Thread.currentThread() === testThread) {
                    throw AssertionError("synchronous JNI readback on the UI thread")
                }
                7L
            }
        }
        host.onDomainAvailability("conversationDomain", true, emptyList())
        host.privacyConfirmationIssuer = { _, _, _, _, _ -> "pc:v1:cap" }
        host.settings.refreshPrivacySummary()
        await { host.settings.state.value.privacy.summary != null }
        // Row-click preview creation: pure projection state, NO native call.
        val preview = host.settings.createPrivacyClearPreview(
            SettingsHostController.PrivacyClearAction.HISTORY)!!
        assertEquals(7L, preview.sourceNativeEpoch)
        assertEquals(histRev(1), preview.digest)
        // The confirm path still validates the ACTUAL root off-main and the
        // clear completes end to end.
        var outcome: String? = "unset"
        host.settings.clearPrivacyHistory(preview) { outcome = it }
        await { outcome == null }
        assertEquals("pr:v1:hist1", host.settings.state.value.privacy.reportPage?.handle)
    }

    // ------------------------------------------------------------- E

    /** A Completed clear whose report cannot be used: truthful uncertainty. */
    @Test
    fun completedWithUnusableReportSurfacesUnavailableNotSuccess() = runBlocking {
        // Scenario 1: shapeless object (none of the report vocabulary).
        runUnavailableScenario("""{"surprise":"payload"}""")
        // Scenario 2: a Completed value that is not a report object at all.
        runUnavailableScenario("\"unstructuredReceipt\"")
    }

    private fun runUnavailableScenario(clearDoc: String) {
        val exchange = ScriptExchange(
            receiptFor = { _, c -> "rc:$c" },
            effectFor = { receipt, correlation ->
                when {
                    receipt.startsWith("rc:prget") ->
                        accepted(correlation, receipt, summaryDoc(histRev(1), mcfgRev(1)))
                    receipt.startsWith("rc:prh") ->
                        accepted(correlation, receipt, clearDoc)
                    else -> null
                }
            },
        )
        val host = testHost(exchange)
        host.onDomainAvailability("conversationDomain", true, emptyList())
        host.privacyConfirmationIssuer = { _, _, _, _, _ -> "pc:v1:cap" }
        host.settings.refreshPrivacySummary()
        await { host.settings.state.value.privacy.summary != null }
        val preview = host.settings.createPrivacyClearPreview(
            SettingsHostController.PrivacyClearAction.HISTORY)!!
        var outcome: String? = "unset"
        host.settings.clearPrivacyHistory(preview) { outcome = it }
        await { outcome != "unset" }
        // NO fake zero/success: the status is reportUnavailable and the
        // surface kept no fabricated report state.
        assertEquals("reportUnavailable", outcome)
        assertEquals("reportUnavailable",
            host.settings.state.value.privacyClear?.error)
        assertNull(host.settings.state.value.privacy.reportPage)
        assertFalse(host.settings.state.value.privacy.summary!!.partial)
        // The counts were refreshed under the current root.
        await { exchange.count("privacy.summary.get") >= 2 }
    }

    @Test
    fun historyMalformedRemainingStaysAbsentTypedAndPartial() = runBlocking {
        // Missing runCount/persistedGrantCount/inMemoryGrantCount — the old
        // decoder invented zeros for exactly these.
        val missingFields = """{"enumerated":{"conversations":2,"runs":2,"persistedGrants":0,"inMemoryGrants":0},"deleted":{"conversations":1,"runs":1,"persistedGrants":0,"inMemoryGrants":0},"failures":[],"partial":false,"remaining":{"conversationCount":1},"failurePage":null}"""
        // Negative count — malformed even with the full field set.
        val negativeCount = """{"enumerated":{"conversations":2,"runs":2,"persistedGrants":0,"inMemoryGrants":0},"deleted":{"conversations":1,"runs":1,"persistedGrants":0,"inMemoryGrants":0},"failures":[],"partial":false,"remaining":{"conversationCount":-1,"runCount":1,"persistedGrantCount":0,"inMemoryGrantCount":0},"failurePage":null}"""
        var clearCount = 0
        val summaryReads = java.util.concurrent.atomic.AtomicInteger()
        val clearRequests = java.util.concurrent.atomic.AtomicInteger()
        val exchange = ScriptExchange(
            receiptFor = { command, c ->
                when (command) {
                    "privacy.summary.get" -> "rc:prget-${summaryReads.incrementAndGet()}"
                    "privacy.history.clear" -> "rc:prh-${clearRequests.incrementAndGet()}"
                    else -> "rc:$c"
                }
            },
            effectFor = { receipt, correlation ->
                when {
                    receipt == "rc:prget-1" ->
                        accepted(correlation, receipt, summaryDoc(histRev(1), mcfgRev(1)))
                    receipt.startsWith("rc:prget") ->
                        accepted(correlation, receipt, summaryDoc(histRev(2), mcfgRev(2)))
                    receipt == "rc:prh-1" ->
                        accepted(correlation, receipt, missingFields)
                    receipt == "rc:prh-2" ->
                        accepted(correlation, receipt, negativeCount)
                    else -> null
                }
            },
        )
        val host = testHost(exchange)
        host.onDomainAvailability("conversationDomain", true, emptyList())
        host.privacyConfirmationIssuer = { _, _, _, _, _ -> "pc:v1:cap" }
        host.settings.refreshPrivacySummary()
        await { host.settings.state.value.privacy.summary != null }
        // First clear: remaining present but INCOMPLETE — unavailable.
        val preview1 = host.settings.createPrivacyClearPreview(
            SettingsHostController.PrivacyClearAction.HISTORY)!!
        var outcome1: String? = "unset"
        host.settings.clearPrivacyHistory(preview1) { outcome1 = it }
        await { outcome1 == null }
        val summary1 = host.settings.state.value.privacy.summary!!
        assertNull(summary1.remaining)
        assertEquals("remainingRecountUnavailable", summary1.remainingFailure)
        // The wire claimed full success; the malformed recount forces truth.
        assertTrue(summary1.partial)
        // The post-clear counts refresh must re-project before a new
        // preview can bind (the terminal bumped the preview epoch source).
        await { host.settings.state.value.privacy.summary?.historyRevision == histRev(2) }
        // Second clear after the refresh: NEGATIVE counts — same truth.
        val preview2 = host.settings.createPrivacyClearPreview(
            SettingsHostController.PrivacyClearAction.HISTORY)!!
        var outcome2: String? = "unset"
        host.settings.clearPrivacyHistory(preview2) { outcome2 = it }
        await { outcome2 == null }
        val summary2 = host.settings.state.value.privacy.summary!!
        assertNull(summary2.remaining)
        assertEquals("remainingRecountUnavailable", summary2.remainingFailure)
        assertTrue(summary2.partial)
        clearCount = exchange.count("privacy.history.clear")
        assertEquals(2, clearCount)
    }

    @Test
    fun modelMalformedRemainingStaysAbsentTypedAndPartial() = runBlocking {
        // providerCount only: the old decoder invented modelCount/secretRef 0.
        val missingFields = """{"enumerated":{"providers":2,"models":3,"secretReferences":1},"deleted":{"providers":1,"models":2,"secrets":1},"deletionFailures":[],"preferencesReset":true,"preferencesSyncRevision":5,"partial":false,"remaining":{"providerCount":1},"preferencesFailure":null,"failurePage":null}"""
        val exchange = ScriptExchange(
            receiptFor = { _, c -> "rc:$c" },
            effectFor = { receipt, correlation ->
                when {
                    receipt.startsWith("rc:prget") ->
                        accepted(correlation, receipt, summaryDoc(histRev(1), mcfgRev(1)))
                    receipt.startsWith("rc:prm") ->
                        accepted(correlation, receipt, missingFields)
                    else -> null
                }
            },
        )
        val host = testHost(exchange)
        host.onDomainAvailability("providerConfigurationDomain", true, emptyList())
        host.privacyConfirmationIssuer = { _, _, _, _, _ -> "pc:v1:mod" }
        host.settings.refreshPrivacySummary()
        await { host.settings.state.value.privacy.summary != null }
        val preview = host.settings.createPrivacyClearPreview(
            SettingsHostController.PrivacyClearAction.MODEL_CONFIGURATION)!!
        var outcome: String? = "unset"
        host.settings.clearPrivacyModelConfiguration(preview) { outcome = it }
        await { outcome == null }
        val summary = host.settings.state.value.privacy.summary!!
        assertNull(summary.modelRemaining)
        assertEquals("remainingRecountUnavailable", summary.modelRemainingFailure)
        assertTrue(summary.partial)
        // Independent model-family truth that IS decodable still lands.
        assertEquals(true, summary.preferencesReset)
    }

    // ------------------------------------------------------------- F

    @Test
    fun freshHolderSameUiEpochIsNotReleasedByLateNotFound() = runBlocking {
        var epoch: Long? = 7L
        val getGate = CountDownLatch(1)
        val exchange = ScriptExchange(
            receiptFor = { _, c -> "rc:$c" },
            effectFor = { receipt, correlation ->
                when {
                    receipt.startsWith("rc:prget") ->
                        accepted(correlation, receipt, summaryDoc(histRev(1), mcfgRev(1)))
                    receipt.startsWith("rc:prh") ->
                        accepted(correlation, receipt, historyClearReport)
                    receipt.startsWith("rc:hlist") ->
                        accepted(correlation, receipt, """{"rows":[]}""")
                    receipt.startsWith("rc:cget-prv") -> {
                        // The survival reply is held; meanwhile the holder
                        // is replaced and re-opened (both carry UI session
                        // epoch 0 — the ABA the entry epoch fences).
                        getGate.await(2, TimeUnit.SECONDS)
                        rejected(correlation, receipt, "notFound")
                    }
                    else -> null
                }
            },
        )
        val host = testHost(exchange) { epoch }
        host.onDomainAvailability("conversationDomain", true, emptyList())
        host.privacyConfirmationIssuer = { _, _, _, _, _ -> "pc:v1:cap" }
        val first = host.conversations.holderFor("c-x", isTemporary = false, incarnationId = null)
        val firstEntry = host.conversations.entryFor("c-x")!!
        host.settings.refreshPrivacySummary()
        await { host.settings.state.value.privacy.summary != null }
        val preview = host.settings.createPrivacyClearPreview(
            SettingsHostController.PrivacyClearAction.HISTORY)!!
        var outcome: String? = "unset"
        host.settings.clearPrivacyHistory(preview) { outcome = it }
        await { exchange.count("conversation.get") == 1 }
        // Replace + re-open BEFORE the late notFound lands.
        host.conversations.releaseHolder("c-x")
        assertNull(host.conversations.entryFor("c-x"))
        val second = host.conversations.holderFor("c-x", isTemporary = false, incarnationId = null)
        assertTrue(first !== second)
        getGate.countDown()
        await { outcome != "unset" }
        kotlinx.coroutines.delay(300)
        // The late notFound named the DEAD entry generation: the fresh
        // holder survives (the old fence would have released it).
        val entry = host.conversations.entryFor("c-x")
        assertNotNull(entry)
        assertTrue(entry!!.holder === second)
        assertEquals(firstEntry.sessionEpoch + 1, entry.sessionEpoch)
    }

    // ------------------------------------------- F: shell UI invalidation

    @Test
    fun privacyClearSignalAppliesOnlyToExactVisibleOrigin() {
        val exchange = ScriptExchange(receiptFor = { _, c -> "rc:$c" }, effectFor = { _, _ -> null })
        val host = testHost(exchange)
        val holder = host.conversations.holderFor("c-x", isTemporary = false, incarnationId = null)
        val rebound = host.conversations.holderFor("c-rebound", isTemporary = false, incarnationId = null)
        val signal = PrivacyClearedConversationSignal(
            conversationId = "c-x",
            entryEpoch = 41L,
            rootEpoch = 7L,
            holder = holder,
        )
        fun applies(
            visible: com.floe.android.design.SidebarSelection,
            boundId: String?,
            bound: com.floe.android.feature.conversation.ConversationFlowHolder?,
            liveTemporary: String? = null,
        ) = com.floe.android.privacyClearedConversationAppliesToVisibleOrigin(
            visible = visible,
            boundConversationId = boundId,
            boundHolder = bound,
            origin = signal,
            liveTemporaryConversationId = liveTemporary,
        )
        // Exact still-visible origin: the same id bound to the SAME holder.
        assertTrue(applies(
            com.floe.android.design.SidebarSelection.Conversation("c-x"), "c-x", holder))
        // Moved away (New Task) or Notes: never navigates/retires.
        assertFalse(applies(
            com.floe.android.design.SidebarSelection.Workbench(
                com.floe.android.design.WorkbenchSelection.NEW_TASK), null, null))
        assertFalse(applies(
            com.floe.android.design.SidebarSelection.More(
                com.floe.android.design.MoreDestination.NOTES), null, null))
        // The visible surface is the live RAM temporary: no durable
        // invalidation (temporary sessions are never privacy-existence-checked).
        assertFalse(applies(
            com.floe.android.design.SidebarSelection.Conversation("c-temp"), "c-temp", holder,
            liveTemporary = "c-temp"))
        // Re-opened/rebound same-id holder: a DIFFERENT instance ignores the
        // stale signal (no navigation, no retirement).
        assertFalse(applies(
            com.floe.android.design.SidebarSelection.Conversation("c-x"), "c-x", rebound))
        // Binding id mismatch or an absent binding: nothing to prove.
        assertFalse(applies(
            com.floe.android.design.SidebarSelection.Conversation("c-x"), "c-other", holder))
        assertFalse(applies(
            com.floe.android.design.SidebarSelection.Conversation("c-x"), null, null))
    }

    @Test
    fun privacyClearSignalPublishedOnlyOnAuthoritativeNotFoundRelease() = runBlocking {
        // Scenario A — same-root typed notFound: EXACT signal, then release.
        runSignalScenario(expectSignal = true, survivalReplyNotFound = true, flipRoot = false)
        // Scenario B — the row SURVIVED (partial clear): no signal, holder kept.
        runSignalScenario(expectSignal = false, survivalReplyNotFound = false, flipRoot = false)
        // Scenario C — notFound from a RETIRED root: no signal, holder kept.
        runSignalScenario(expectSignal = false, survivalReplyNotFound = true, flipRoot = true)
        // Off-screen cached deletions cannot replace the visible signal.
        runSignalScenario(expectSignal = false, survivalReplyNotFound = true,
            flipRoot = false, bindVisible = false)
    }

    private suspend fun runSignalScenario(
        expectSignal: Boolean,
        survivalReplyNotFound: Boolean,
        flipRoot: Boolean,
        bindVisible: Boolean = true,
    ) {
        var epoch: Long? = 7L
        val exchange = ScriptExchange(
            receiptFor = { _, c -> "rc:$c" },
            effectFor = { receipt, correlation ->
                when {
                    receipt.startsWith("rc:prget") ->
                        accepted(correlation, receipt, summaryDoc(histRev(1), mcfgRev(1)))
                    receipt.startsWith("rc:prh") ->
                        accepted(correlation, receipt, historyClearReport)
                    receipt.startsWith("rc:hlist") ->
                        accepted(correlation, receipt, """{"rows":[]}""")
                    receipt.startsWith("rc:cget-prv") -> {
                        if (flipRoot) epoch = 8L
                        if (survivalReplyNotFound) {
                            rejected(correlation, receipt, "notFound")
                        } else {
                            accepted(correlation, receipt,
                                """{"revision":{"resourceID":"c","version":"v1"}}""")
                        }
                    }
                    else -> null
                }
            },
        )
        val host = testHost(exchange) { epoch }
        host.onDomainAvailability("conversationDomain", true, emptyList())
        host.privacyConfirmationIssuer = { _, _, _, _, _ -> "pc:v1:cap" }
        val holder = host.conversations.holderFor("c-x", isTemporary = false, incarnationId = null)
        val entryEpoch = host.conversations.entryFor("c-x")!!.sessionEpoch
        host.conversations.holderFor("c-cached", isTemporary = false, incarnationId = null)
        if (bindVisible) host.conversations.bindPrivacyVisibleHolder(holder)
        host.settings.refreshPrivacySummary()
        await { host.settings.state.value.privacy.summary != null }
        val preview = host.settings.createPrivacyClearPreview(
            SettingsHostController.PrivacyClearAction.HISTORY)!!
        var outcome: String? = "unset"
        host.settings.clearPrivacyHistory(preview) { outcome = it }
        await { outcome != "unset" }
        kotlinx.coroutines.delay(200)
        val signal = host.conversations.privacyClearedConversation.value
        if (expectSignal) {
            // The signal names EXACTLY the released holder, entry generation
            // and root — the shell consumes it only after re-validating the
            // still-visible origin and the live root.
            assertNotNull(signal)
            assertEquals("c-x", signal!!.conversationId)
            assertEquals(entryEpoch, signal.entryEpoch)
            assertEquals(7L, signal.rootEpoch)
            assertTrue(signal.holder === holder)
            assertNull(host.conversations.entryFor("c-x"))
        } else {
            assertNull(signal)
            if (survivalReplyNotFound && !flipRoot) {
                assertNull(host.conversations.entryFor("c-x"))
            } else {
                assertNotNull(host.conversations.entryFor("c-x"))
            }
        }
    }
}
