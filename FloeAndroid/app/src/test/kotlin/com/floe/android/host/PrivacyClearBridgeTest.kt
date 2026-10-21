// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * R2-A trusted privacy-clear App bridge tests — AUTHORED, NOTRUN (scripted
 * transport doubles only; no JNI, no device, no real store).
 *
 * Covers the reviewed chain end to end:
 *  * summary read bound to the ACTUAL native Root epoch (stale-root reply
 *    rejected and reset; newer read supersedes an older late reply);
 *  * immutable tap preview (recomposition/ABA safe): an old-preview confirm
 *    after a refresh is refused WITHOUT any dispatch;
 *  * privileged capability: expected epoch + exact invocation, same
 *    correlation in the envelope, digest as revision.version, opaque token
 *    as the ONLY payload.confirmToken, null capability / root change after
 *    mint refuse without dispatch and without re-mint;
 *  * truthful report projection (actual partial, history/model remaining,
 *    independent preferencesFailure, real providerIDs, failurePage slot);
 *  * visible typed failures (domain wire code surfaces);
 *  * report page reply identity (mismatched handle/kind rejected; a late
 *    page of a superseded report never overwrites the new slot);
 *  * SAME-root consumer refresh: history list + retained-holder
 *    reconciliation (only authoritative notFound under the same root and
 *    exact holder identity releases; temporary RAM sessions and survivors
 *    untouched) and provider/defaults/preferences re-reads.
 */
class PrivacyClearBridgeTest {

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

        companion object {
            fun commandOf(raw: String): String {
                val marker = "\"command\":\""
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
            """"effects":[{"sequence":1,"kind":"accepted","page":$doc}],"hasMore":false,"resyncRequired":false}"""

    /** A valid but terminal-free page: keeps an operation in flight. */
    private fun pending(correlation: String, receipt: String) =
        """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3",""" +
            """"correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":0},""" +
            """"effects":[],"hasMore":false,"resyncRequired":false}"""

    private fun failed(correlation: String, receipt: String, code: String, wire: String) =
        """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3",""" +
            """"correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":1},""" +
            """"effects":[{"sequence":1,"kind":"failed","code":"$code",""" +
            """"detail":[{"key":"wire","value":"$wire"}]}],"hasMore":false,"resyncRequired":false}"""

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

    private val modelClearReport = """{"enumerated":{"providers":2,"models":3,"secretReferences":1},"deleted":{"providers":1,"models":2,"secrets":1},"deletionFailures":[{"providerID":"p-dead","phase":"gatewayDelete","reason":"timeout"}],"preferencesReset":true,"preferencesSyncRevision":5,"remaining":{"providerCount":1,"modelCount":1,"secretReferenceCount":0},"preferencesFailure":"prefsStoreUnavailable","remainingFailure":null,"partial":true,"failurePage":{"handle":"pr:v1:mod1","returned":1,"total":1,"nextCursor":null}}"""

    // ------------------------------------------------------------- reads

    @Test
    fun summaryReadRejectsRootChangedReplyAndResets() = runBlocking {
        var epoch: Long? = 7L
        val exchange = ScriptExchange(
            receiptFor = { _, c -> "rc:$c" },
            effectFor = { receipt, correlation ->
                if (receipt.startsWith("rc:prget")) {
                    // The Root retires between dispatch and reply.
                    epoch = 8L
                    accepted(correlation, receipt, summaryDoc(histRev(1), mcfgRev(1)))
                } else null
            },
        )
        val host = testHost(exchange) { epoch }
        host.settings.refreshPrivacySummary()
        await { host.settings.state.value.privacyStatus.error != null }
        val state = host.settings.state.value
        assertEquals("rootChanged", state.privacyStatus.error)
        // The old-root projection must not survive onto the new root.
        assertNull(state.privacy.summary)
        assertNull(state.privacy.rootEpoch)
        // A retry under the new root applies normally.
        host.settings.refreshPrivacySummary()
        await { host.settings.state.value.privacy.summary != null }
        assertEquals(8L, host.settings.state.value.privacy.rootEpoch)
    }

    @Test
    fun newerSummaryReadSupersedesOlderLateReply() = runBlocking {
        var epoch: Long? = 7L
        val lateReplyGate = CountDownLatch(1)
        var newerApplied = false
        val exchange = ScriptExchange(
            receiptFor = { _, c -> "rc:$c" },
            effectFor = { receipt, correlation ->
                when {
                    receipt == "rc:prget-1" -> {
                        // The first read's reply is held back until the
                        // newer read already owns the surface.
                        lateReplyGate.await(2, TimeUnit.SECONDS)
                        accepted(correlation, receipt, summaryDoc(histRev(9), mcfgRev(9)))
                    }
                    receipt.startsWith("rc:prget") ->
                        accepted(correlation, receipt, summaryDoc(histRev(2), mcfgRev(2)))
                    else -> null
                }
            },
        )
        val host = testHost(exchange) { epoch }
        host.settings.refreshPrivacySummary()          // generation 1 (slow)
        host.settings.refreshPrivacySummary()          // generation 2 (fast)
        await { host.settings.state.value.privacy.summary?.historyRevision == histRev(2) }
        newerApplied = true
        lateReplyGate.countDown()
        kotlinx.coroutines.delay(300)
        // The late generation-1 reply must not replace the newer projection.
        assertTrue(newerApplied)
        assertEquals(histRev(2), host.settings.state.value.privacy.summary?.historyRevision)
    }

    // -------------------------------------------------------- preview/mint

    @Test
    fun stalePreviewAfterRefreshRefusedWithoutDispatch() = runBlocking {
        val summaryReads = java.util.concurrent.atomic.AtomicInteger()
        val exchange = ScriptExchange(
            receiptFor = { command, c ->
                if (command == "privacy.summary.get") "rc:prget-${summaryReads.incrementAndGet()}"
                else "rc:$c"
            },
            effectFor = { receipt, correlation ->
                when {
                    receipt == "rc:prget-1" ->
                        accepted(correlation, receipt, summaryDoc(histRev(1), mcfgRev(1)))
                    receipt == "rc:prget-2" ->
                        accepted(correlation, receipt, summaryDoc(histRev(2), mcfgRev(2)))
                    else -> null
                }
            },
        )
        val host = testHost(exchange)
        host.settings.refreshPrivacySummary()
        await { host.settings.state.value.privacy.summary?.historyRevision == histRev(1) }
        // First tap freezes THIS digest/generation forever.
        val preview = host.settings.createPrivacyClearPreview(
            SettingsHostController.PrivacyClearAction.HISTORY)
        assertNotNull(preview)
        assertEquals(histRev(1), preview!!.digest)
        assertEquals(7L, preview.sourceNativeEpoch)
        // Refresh changes the digest (ABA: same root, new generation).
        host.settings.refreshPrivacySummary()
        await { host.settings.state.value.privacy.summary?.historyRevision == histRev(2) }
        var outcome: String? = "unset"
        host.settings.clearPrivacyHistory(preview) { outcome = it }
        await { outcome != "unset" }
        assertEquals("previewStale", outcome)
        assertEquals(0, exchange.count("privacy.history.clear"))
        // A fresh preview on the current projection works end to end.
        val fresh = host.settings.createPrivacyClearPreview(
            SettingsHostController.PrivacyClearAction.HISTORY)
        assertNotNull(fresh)
        assertEquals(histRev(2), fresh!!.digest)
    }

    @Test
    fun mintBindsExpectedEpochAndCorrelationRidesEnvelope() = runBlocking {
        data class Issue(
            val epoch: Long, val operation: String, val digest: String,
            val invocation: String, val action: String,
        )
        var issue: Issue? = null
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
        val host = testHost(exchange)
        host.privacyConfirmationIssuer = { epoch, operation, digest, invocation, action ->
            issue = Issue(epoch, operation, digest, invocation, action)
            "pc:v1:cap"
        }
        host.settings.refreshPrivacySummary()
        await { host.settings.state.value.privacy.summary != null }
        val preview = host.settings.createPrivacyClearPreview(
            SettingsHostController.PrivacyClearAction.HISTORY)!!
        var outcome: String? = "unset"
        host.settings.clearPrivacyHistory(preview) { outcome = it }
        await { outcome == null }
        assertNotNull(issue)
        assertEquals(7L, issue!!.epoch)
        assertEquals("privacy.history.clear", issue!!.operation)
        assertEquals(histRev(1), issue!!.digest)
        assertEquals("historyClear", issue!!.action)
        // The SAME correlation rides the envelope; the digest stays the
        // revision; ONLY the opaque capability is the payload token.
        val envelope = exchange.envelopes("privacy.history.clear").single()
        val correlation = (envelope["correlationID"] as JsonPrimitive).content
        assertEquals(issue!!.invocation, correlation)
        val revision = envelope["revision"] as JsonObject
        assertEquals("privacy.history", (revision["resourceID"] as JsonPrimitive).content)
        assertEquals(histRev(1), (revision["version"] as JsonPrimitive).content)
        val payload = envelope["payload"] as JsonObject
        assertEquals("pc:v1:cap", (payload["confirmToken"] as JsonPrimitive).content)
        assertNull(host.settings.state.value.privacyClear?.error)
    }

    @Test
    fun nullCapabilityRefusesWithoutDispatch() = runBlocking {
        val exchange = ScriptExchange(
            receiptFor = { _, c -> "rc:$c" },
            effectFor = { receipt, correlation ->
                if (receipt.startsWith("rc:prget")) {
                    accepted(correlation, receipt, summaryDoc(histRev(1), mcfgRev(1)))
                } else null
            },
        )
        val host = testHost(exchange)
        host.privacyConfirmationIssuer = { _, _, _, _, _ -> null }
        host.settings.refreshPrivacySummary()
        await { host.settings.state.value.privacy.summary != null }
        val preview = host.settings.createPrivacyClearPreview(
            SettingsHostController.PrivacyClearAction.HISTORY)!!
        var outcome: String? = "unset"
        host.settings.clearPrivacyHistory(preview) { outcome = it }
        await { outcome != "unset" }
        assertEquals("confirmationUnavailable", outcome)
        assertEquals(0, exchange.count("privacy.history.clear"))
        // The failure is VISIBLE in the owned status.
        assertEquals("confirmationUnavailable",
            host.settings.state.value.privacyClear?.error)
        assertTrue(host.settings.state.value.privacyClear?.inFlight == false)
    }

    @Test
    fun rootChangeAfterMintRefusesWithoutReplay() = runBlocking {
        var epoch: Long? = 7L
        val exchange = ScriptExchange(
            receiptFor = { _, c -> "rc:$c" },
            effectFor = { receipt, correlation ->
                if (receipt.startsWith("rc:prget")) {
                    accepted(correlation, receipt, summaryDoc(histRev(1), mcfgRev(1)))
                } else null
            },
        )
        val host = testHost(exchange) { epoch }
        var mintCalls = 0
        host.privacyConfirmationIssuer = { _, _, _, _, _ ->
            mintCalls += 1
            // The Root retires WHILE the capability is being minted.
            epoch = 8L
            "pc:v1:cap"
        }
        host.settings.refreshPrivacySummary()
        await { host.settings.state.value.privacy.summary != null }
        val preview = host.settings.createPrivacyClearPreview(
            SettingsHostController.PrivacyClearAction.HISTORY)!!
        var outcome: String? = "unset"
        host.settings.clearPrivacyHistory(preview) { outcome = it }
        await { outcome != "unset" }
        assertEquals("rootChanged", outcome)
        assertEquals(0, exchange.count("privacy.history.clear"))
        // No newly minted capability retry against the new root.
        assertEquals(1, mintCalls)
    }

    @Test
    fun duplicateInFlightClearRefused() = runBlocking {
        val exchange = ScriptExchange(
            receiptFor = { _, c -> "rc:$c" },
            effectFor = { receipt, correlation ->
                if (receipt.startsWith("rc:prget")) {
                    accepted(correlation, receipt, summaryDoc(histRev(1), mcfgRev(1)))
                } else if (receipt.startsWith("rc:prh")) {
                    // The first clear never settles within the test window.
                    pending(correlation, receipt)
                } else null
            },
        )
        val host = testHost(exchange)
        host.privacyConfirmationIssuer = { _, _, _, _, _ -> "pc:v1:cap" }
        host.settings.refreshPrivacySummary()
        await { host.settings.state.value.privacy.summary != null }
        val preview = host.settings.createPrivacyClearPreview(
            SettingsHostController.PrivacyClearAction.HISTORY)!!
        var first: String? = "unset"
        host.settings.clearPrivacyHistory(preview) { first = it }
        await { host.settings.state.value.privacyClear?.inFlight == true }
        // Second dispatch of the same preview is refused single-flight.
        var second: String? = "unset"
        host.settings.clearPrivacyHistory(preview) { second = it }
        await { second != "unset" }
        assertEquals("inFlight", second)
        await { exchange.count("privacy.history.clear") == 1 }
        assertEquals(1, exchange.count("privacy.history.clear"))
        assertEquals("unset", first)
    }

    @Test
    fun failedClearSurfacesDomainWireCode() = runBlocking {
        val exchange = ScriptExchange(
            receiptFor = { _, c -> "rc:$c" },
            effectFor = { receipt, correlation ->
                when {
                    receipt.startsWith("rc:prget") ->
                        accepted(correlation, receipt, summaryDoc(histRev(1), mcfgRev(1)))
                    receipt.startsWith("rc:prh") ->
                        failed(correlation, receipt, "staleRevision", "staleRevision")
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
        var outcome: String? = "unset"
        host.settings.clearPrivacyHistory(preview) { outcome = it }
        await { outcome != "unset" }
        assertEquals("staleRevision", outcome)
        assertEquals("staleRevision", host.settings.state.value.privacyClear?.error)
        // The next request cleanly replaces the fenced status.
        val fresh = host.settings.createPrivacyClearPreview(
            SettingsHostController.PrivacyClearAction.HISTORY)
        assertNotNull(fresh)
    }

    // -------------------------------------------------------- projection

    @Test
    fun historyClearProjectsActualPartialRemainingAndFailurePage() = runBlocking {
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
        val host = testHost(exchange)
        host.privacyConfirmationIssuer = { _, _, _, _, _ -> "pc:v1:cap" }
        host.settings.refreshPrivacySummary()
        await { host.settings.state.value.privacy.summary != null }
        val preview = host.settings.createPrivacyClearPreview(
            SettingsHostController.PrivacyClearAction.HISTORY)!!
        var outcome: String? = "unset"
        host.settings.clearPrivacyHistory(preview) { outcome = it }
        await { outcome == null }
        val privacy = host.settings.state.value.privacy
        val summary = privacy.summary!!
        assertTrue(summary.partial)
        assertEquals(1L, summary.remaining?.conversationCount)
        assertNull(summary.remainingFailure)
        assertEquals(1, privacy.historyFailures.size)
        assertEquals("c-del", privacy.historyFailures.single().itemID)
        assertEquals("deleteConversation", privacy.historyFailures.single().phase)
        assertEquals("pr:v1:hist1", privacy.reportPage?.handle)
        assertEquals(false, privacy.reportPage?.done)
        assertEquals(3L, privacy.reportPage?.total)
        // A later counts refresh preserves the report truth.
        await { exchange.count("privacy.summary.get") >= 2 }
        kotlinx.coroutines.delay(200)
        val refreshed = host.settings.state.value.privacy
        assertTrue(refreshed.summary!!.partial)
        assertEquals(1L, refreshed.summary.remaining?.conversationCount)
        assertEquals("pr:v1:hist1", refreshed.reportPage?.handle)
    }

    @Test
    fun modelClearProjectsModelRemainingIndependentPrefsAndProviderIDs() = runBlocking {
        val exchange = ScriptExchange(
            receiptFor = { _, c -> "rc:$c" },
            effectFor = { receipt, correlation ->
                when {
                    receipt.startsWith("rc:prget") ->
                        accepted(correlation, receipt, summaryDoc(histRev(1), mcfgRev(1)))
                    receipt.startsWith("rc:prm") ->
                        accepted(correlation, receipt, modelClearReport)
                    else -> null
                }
            },
        )
        val host = testHost(exchange)
        host.privacyConfirmationIssuer = { _, _, _, _, _ -> "pc:v1:mod" }
        host.settings.refreshPrivacySummary()
        await { host.settings.state.value.privacy.summary != null }
        val preview = host.settings.createPrivacyClearPreview(
            SettingsHostController.PrivacyClearAction.MODEL_CONFIGURATION)!!
        var outcome: String? = "unset"
        host.settings.clearPrivacyModelConfiguration(preview) { outcome = it }
        await { outcome == null }
        val privacy = host.settings.state.value.privacy
        val summary = privacy.summary!!
        // Model-family truth, independent of the history family.
        assertTrue(summary.partial)
        assertEquals(1L, summary.modelRemaining?.providerCount)
        assertEquals(1L, summary.modelRemaining?.modelCount)
        assertEquals(0L, summary.modelRemaining?.secretReferenceCount)
        assertEquals("prefsStoreUnavailable", summary.preferencesFailure)
        assertEquals(true, summary.preferencesReset)
        assertNull(summary.remaining)
        assertTrue(privacy.historyFailures.isEmpty())
        assertEquals(1, privacy.modelConfigFailures.size)
        assertEquals("p-dead", privacy.modelConfigFailures.single().providerID)
        assertEquals("gatewayDelete", privacy.modelConfigFailures.single().phase)
        assertEquals("pr:v1:mod1", privacy.reportPage?.handle)
        assertEquals(true, privacy.reportPage?.done)
    }

    @Test
    fun missingCountsStayAbsentNeverFabricated() = runBlocking {
        val reportNoRemaining = """{"enumerated":{"conversations":1,"runs":1,"persistedGrants":0,"inMemoryGrants":0},"deleted":{"conversations":1,"runs":1,"persistedGrants":0,"inMemoryGrants":0},"failures":[],"partial":false,"remainingFailure":null,"failurePage":null}"""
        val exchange = ScriptExchange(
            receiptFor = { _, c -> "rc:$c" },
            effectFor = { receipt, correlation ->
                when {
                    receipt.startsWith("rc:prget") ->
                        accepted(correlation, receipt, summaryDoc(histRev(1), mcfgRev(1)))
                    receipt.startsWith("rc:prh") ->
                        accepted(correlation, receipt, reportNoRemaining)
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
        var outcome: String? = "unset"
        host.settings.clearPrivacyHistory(preview) { outcome = it }
        await { outcome == null }
        val summary = host.settings.state.value.privacy.summary!!
        // remaining stays NULL (never zeros); the omitted recount is typed.
        assertNull(summary.remaining)
        assertEquals("remainingRecountUnavailable", summary.remainingFailure)
        assertTrue(summary.partial)
        assertNull(host.settings.state.value.privacy.reportPage)
    }

    // --------------------------------------------------------- report page

    @Test
    fun reportPageRejectsMismatchedHandleOrKind() = runBlocking {
        val exchange = ScriptExchange(
            receiptFor = { _, c -> "rc:$c" },
            effectFor = { receipt, correlation ->
                when {
                    receipt.startsWith("rc:prget") ->
                        accepted(correlation, receipt, summaryDoc(histRev(1), mcfgRev(1)))
                    receipt.startsWith("rc:prh") ->
                        accepted(correlation, receipt, historyClearReport)
                    receipt.startsWith("rc:prpage") ->
                        accepted(correlation, receipt,
                            """{"report":{"handle":"pr:v1:FOREIGN","kind":"history","items":[],"nextCursor":null,"total":0,"done":true}}""")
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
        val slotBefore = host.settings.state.value.privacy.reportPage
        var page: SettingsHostController.PrivacyReportPage? = slotBefore
        var answered = false
        host.settings.readPrivacyReportPage("pr:v1:hist1", "history", "rc:v1:1", 50) {
            page = it
            answered = true
        }
        await { answered }
        // Foreign handle rejected: callback null, slot untouched.
        assertNull(page)
        assertEquals(slotBefore, host.settings.state.value.privacy.reportPage)
    }

    @Test
    fun lateReportPageSupersededByNewerClear() = runBlocking {
        val pageGate = CountDownLatch(1)
        var clearCount = 0
        val exchange = ScriptExchange(
            receiptFor = { _, c -> "rc:$c" },
            effectFor = { receipt, correlation ->
                when {
                    receipt.startsWith("rc:prget") ->
                        accepted(correlation, receipt, summaryDoc(histRev(1), mcfgRev(1)))
                    receipt.startsWith("rc:prh") -> {
                        clearCount += 1
                        accepted(correlation, receipt, historyClearReport)
                    }
                    receipt.startsWith("rc:prpage") -> {
                        // The page reply is held until a NEW clear replaced
                        // the report slot.
                        pageGate.await(2, TimeUnit.SECONDS)
                        accepted(correlation, receipt,
                            """{"report":{"handle":"pr:v1:hist1","kind":"history","items":[{"itemID":"x","phase":"drain","reason":"late"}],"nextCursor":null,"total":3,"done":true}}""")
                    }
                    else -> null
                }
            },
        )
        val host = testHost(exchange)
        host.privacyConfirmationIssuer = { _, _, _, _, _ -> "pc:v1:cap" }
        host.settings.refreshPrivacySummary()
        await { host.settings.state.value.privacy.summary != null }
        val generationBeforeClear = host.settings.privacyPreviewEpoch
        val preview = host.settings.createPrivacyClearPreview(
            SettingsHostController.PrivacyClearAction.HISTORY)!!
        var firstOutcome: String? = "unset"
        host.settings.clearPrivacyHistory(preview) { firstOutcome = it }
        await { firstOutcome == null }
        // The clear's own counts refresh re-projects a NEW generation; a
        // second confirm must bind THAT generation, never the old one.
        await { host.settings.privacyPreviewEpoch != generationBeforeClear }
        // Start paging the first report, then complete a NEW clear.
        var answered = false
        host.settings.readPrivacyReportPage("pr:v1:hist1", "history", "rc:v1:1", 50) {
            answered = true
        }
        val preview2 = host.settings.createPrivacyClearPreview(
            SettingsHostController.PrivacyClearAction.HISTORY)!!
        host.settings.clearPrivacyHistory(preview2) { }
        await { exchange.count("privacy.history.clear") == 2 }
        pageGate.countDown()
        await { answered }
        kotlinx.coroutines.delay(200)
        // The late page of the retired report never overwrote the new slot:
        // it still carries the SECOND clear's initial page, not the late one.
        val slot = host.settings.state.value.privacy.reportPage!!
        assertEquals("pr:v1:hist1", slot.handle)
        assertEquals(1, slot.items.size)
        assertEquals("c-del", slot.items.single().itemID)
        assertFalse(slot.done)
    }

    // ------------------------------------------------- consumer refresh

    @Test
    fun historyClearRefreshesConsumersAndReleasesOnlyDeletedHolders() = runBlocking {
        val holderReads = java.util.concurrent.atomic.AtomicInteger()
        val exchange = ScriptExchange(
            receiptFor = { command, c ->
                if (command == "conversation.get") "rc:cget-prv-${holderReads.incrementAndGet()}"
                else "rc:$c"
            },
            effectFor = { receipt, correlation ->
                when {
                    receipt.startsWith("rc:prget") ->
                        accepted(correlation, receipt, summaryDoc(histRev(1), mcfgRev(1)))
                    receipt.startsWith("rc:prh") ->
                        accepted(correlation, receipt, historyClearReport)
                    receipt.startsWith("rc:hlist") ->
                        accepted(correlation, receipt,
                            """{"rows":[{"conversationID":"c-keep","title":"Keep","updatedAt":"2026-10-21T00:00:00Z","archived":false}]}""")
                    receipt == "rc:cget-prv-1" ->
                        rejected(correlation, receipt, "notFound")
                    receipt.startsWith("rc:cget-prv") ->
                        accepted(correlation, receipt, """{"revision":{"resourceID":"c","version":"v1"}}""")
                    else -> null
                }
            },
        )
        val host = testHost(exchange)
        host.onDomainAvailability("conversationDomain", true, emptyList())
        host.privacyConfirmationIssuer = { _, _, _, _, _ -> "pc:v1:cap" }
        // Retained holders: one deleted, one survivor, one RAM-only temporary.
        host.conversations.holderFor("c-del", isTemporary = false, incarnationId = null)
        host.conversations.holderFor("c-keep", isTemporary = false, incarnationId = null)
        host.conversations.holderFor("c-temp", isTemporary = true, incarnationId = "inc-1")
        host.settings.refreshPrivacySummary()
        await { host.settings.state.value.privacy.summary != null }
        val preview = host.settings.createPrivacyClearPreview(
            SettingsHostController.PrivacyClearAction.HISTORY)!!
        var outcome: String? = "unset"
        host.settings.clearPrivacyHistory(preview) { outcome = it }
        await { outcome == null }
        // History list re-read + BOTH non-temporary holders existence-checked.
        await { exchange.count("conversation.list") >= 1 && exchange.count("conversation.get") == 2 }
        assertEquals(2, exchange.count("conversation.get"))
        await { host.conversations.entryFor("c-del") == null }
        // Only the authoritative notFound released its holder; the survivor
        // and the RAM-only temporary session (absent from the first page —
        // NOT proof) are preserved.
        assertNull(host.conversations.entryFor("c-del"))
        assertNotNull(host.conversations.entryFor("c-keep"))
        assertNotNull(host.conversations.entryFor("c-temp"))
    }

    @Test
    fun holderSurvivalReplyFencedByRootAndIdentity() = runBlocking {
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
                        // The Root retired before the notFound reply arrived.
                        epoch = 8L
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
        host.conversations.holderFor("c-keep", isTemporary = false, incarnationId = null)
        host.settings.refreshPrivacySummary()
        await { host.settings.state.value.privacy.summary != null }
        val preview = host.settings.createPrivacyClearPreview(
            SettingsHostController.PrivacyClearAction.HISTORY)!!
        host.settings.clearPrivacyHistory(preview) { }
        await { exchange.count("conversation.get") == 1 }
        getGate.countDown()
        kotlinx.coroutines.delay(300)
        // A notFound from the OLD root must never release under the new one.
        assertNotNull(host.conversations.entryFor("c-keep"))
    }

    @Test
    fun modelClearRefreshesProviderDefaultsAndPreferencesConsumers() = runBlocking {
        val exchange = ScriptExchange(
            receiptFor = { _, c -> "rc:$c" },
            effectFor = { receipt, correlation ->
                when {
                    receipt.startsWith("rc:prget") ->
                        accepted(correlation, receipt, summaryDoc(histRev(1), mcfgRev(1)))
                    receipt.startsWith("rc:prm") ->
                        accepted(correlation, receipt, modelClearReport)
                    receipt.startsWith("rc:plist") ->
                        accepted(correlation, receipt,
                            """{"rows":[],"nextCursor":null,"hasMore":false}""")
                    receipt.startsWith("rc:dget") ->
                        accepted(correlation, receipt,
                            """{"values":{"defaultAgentMode":"human","runningInputMode":"text"}}""")
                    receipt.startsWith("rc:pfget") ->
                        accepted(correlation, receipt,
                            """{"revision":{"resourceID":"preferences","version":5},"preferences":{}}""")
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
        // Real consumers re-read: providers (+model sweep/composer), the
        // persisted defaults and the default-agent preferences.
        assertTrue(exchange.count("config.providers.list") >= 1)
        assertTrue(exchange.count("config.defaults.get") >= 1)
        assertTrue(exchange.count("config.preferences.get") >= 1)
    }

    @Test
    fun clearOnPlainSummaryNeverFabricatesPartialFromSummaryFields() = runBlocking {
        // A MISBEHAVING producer echoing report fields on the plain summary:
        // the App must ignore them (the previous decoder showed false partial).
        val lyingSummary = summaryDoc(histRev(1), mcfgRev(1))
            .replace(""""snapshot":{"dbSnapshotTransaction":true,"inMemoryGrantBracket":"ok","retriesBounded":0}""",
                """"snapshot":{"dbSnapshotTransaction":true,"inMemoryGrantBracket":"ok","retriesBounded":0},"remainingFailure":"unstableGrantSnapshot","partial":true,"failures":[{"itemID":"x","phase":"drain","reason":"fake"}]""")
        val exchange = ScriptExchange(
            receiptFor = { _, c -> "rc:$c" },
            effectFor = { receipt, correlation ->
                if (receipt.startsWith("rc:prget")) {
                    accepted(correlation, receipt, lyingSummary)
                } else null
            },
        )
        val host = testHost(exchange)
        host.settings.refreshPrivacySummary()
        await { host.settings.state.value.privacy.summary != null }
        val summary = host.settings.state.value.privacy.summary!!
        assertFalse(summary.partial)
        assertNull(summary.remainingFailure)
        assertTrue(host.settings.state.value.privacy.historyFailures.isEmpty())
    }
}
