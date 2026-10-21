// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * R6/R7 deferred behavior tests — AUTHORED, NOTRUN (no JVM/Gradle execution
 * in the source phase; Main runs them in the composed batch). Scripted
 * transport double only; no native bridge, no device.
 *
 * Covers: truthful memory-search semantics; real organize apply/cancel
 * (original payload grammar, correlation+receipt reuse, stale refusal,
 * proposal fencing); personalization revision history paging, revision
 * read with bounded handle paging, rollback grammar, generate cancel with
 * receipt correlation and late-terminal fencing.
 */
class SettingsRequiredActionsTest {

    /** One scripted queue receipt + effect frame table per test. */
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

    /**
     * One accepted terminal carrying the typed page document — the frozen
     * carrier's completed value shape (`kind:"accepted"` + `page` object),
     * exactly like the qualified privacy fixtures.
     */
    private fun completedEffect(correlation: String, receipt: String, page: String) =
        """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3",""" +
            """"correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":1},""" +
            """"effects":[{"sequence":1,"kind":"accepted","page":$page}],"hasMore":false,"resyncRequired":false}"""

    private fun rejectedEffect(correlation: String, receipt: String, code: String) =
        """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3",""" +
            """"correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":1},""" +
            """"effects":[{"sequence":1,"kind":"rejected","code":"$code","detail":[]}],""" +
            """"hasMore":false,"resyncRequired":false}"""

    private fun failedEffect(correlation: String, receipt: String, code: String) =
        """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3",""" +
            """"correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":1},""" +
            """"effects":[{"sequence":1,"kind":"failed","code":"$code","detail":[]}],""" +
            """"hasMore":false,"resyncRequired":false}"""

    @Test
    fun memorySearchKeepsDeletedTruthAndDropsProjectedFabrication() = runBlocking {
        val item = """{"id":"m1","relevance":0.9,"lexicalRank":1,"semanticRank":null,"semanticSimilarity":null,"current":null,"deleted":true}"""
        val reply = """{"items":[$item],"semantic":false,"sideEffects":{"lifecycleMaintained":true,"reinforcementPathExecuted":true,"reinforcedCount":null,"digestsRefreshed":true,"explanation":"x"},"searchHandle":null,"nextCursor":null,"hasMore":false}"""
        val exchange = ScriptExchange(
            receiptFor = { _, c -> "op:v1:search" },
            effectFor = { receipt, correlation ->
                if (receipt == "op:v1:search") completedEffect(correlation, receipt, reply) else null
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.settings.searchMemory("hello")
        kotlinx.coroutines.delay(200)
        val projection = host.settings.state.value.memory.searchItems.single()
        // The original item carries current=null + deleted=true; the App
        // must NOT fabricate a projected row or report "unchanged".
        assertEquals("m1", projection.id)
        assertTrue(projection.deleted)
        assertTrue(projection.changedDuringSearch)
        assertNull(projection.current)
    }

    @Test
    fun organizeProposalFollowsCursorAndApplyUsesOriginalGrammar() = runBlocking {
        val startPage = """{"status":"completed","scannedCount":3,"autoDeletedCount":1,"pendingReviewCount":1,"autoDelete":{"status":"applied","batchID":"b-auto","staleIDs":[]},"proposalStale":false,"semantic":{"skipped":true},"proposalHandle":"hnd:org:1"}"""
        val suggestion = """{"id":"s1","kind":"exactDuplicate","memoryIDs":["m1","m2"],"preferredMemoryID":"m1","reason":"Same fact stored twice.","canApplyAutomatically":true}"""
        val entry1 = """{"id":"m1","scope":{"kind":"user"},"status":"active","content":"Floe prefers concise answers.","factIdentity":null,"originConversationID":null,"originWorkspaceID":null,"updatedAt":"2026-10-21T00:00:00Z"}"""
        val entry2 = """{"id":"m2","scope":{"kind":"user"},"status":"active","content":"Floe prefers concise answers.","factIdentity":null,"originConversationID":null,"originWorkspaceID":null,"updatedAt":"2026-10-21T00:00:01Z"}"""
        val proposalPage1 = """{"proposalID":"p1","generatedAt":"2026-10-21T00:00:00Z","scannedCount":3,"suggestions":[$suggestion],"entries":[$entry1],"nextCursor":"1","stale":false,"staleIDs":[],"autoDelete":{"status":"applied","batchID":"b-auto"}}"""
        val proposalPage2 = """{"proposalID":"p1","generatedAt":"2026-10-21T00:00:00Z","scannedCount":3,"suggestions":[],"entries":[$entry2],"nextCursor":null,"stale":false,"staleIDs":[],"autoDelete":{"status":"applied","batchID":"b-auto"}}"""
        val applyReply = """{"batchID":"b-1","result":"applied","deletedCount":1}"""
        val listReply = """{"entries":[],"nextCursor":null}"""
        var propPolls = 0
        val exchange = ScriptExchange(
            receiptFor = { command, _ ->
                when (command) {
                    "memory.organize.start" -> "op:v1:org"
                    "memory.organize.proposal.read" -> "op:v1:prop"
                    "memory.organize.apply" -> "op:v1:apply"
                    "memory.list" -> "op:v1:list"
                    else -> "op:v1:x"
                }
            },
            effectFor = { receipt, correlation ->
                when (receipt) {
                    "op:v1:org" -> completedEffect(correlation, receipt, startPage)
                    "op:v1:prop" -> {
                        // First poll serves page 1 with a cursor, second the tail.
                        val seen = propPolls++
                        if (seen == 0) completedEffect(correlation, receipt, proposalPage1)
                        else completedEffect(correlation, receipt, proposalPage2)
                    }
                    "op:v1:apply" -> completedEffect(correlation, receipt, applyReply)
                    "op:v1:list" -> completedEffect(correlation, receipt, listReply)
                    else -> null
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("settingsMemory", true, emptyList())

        var startError: String? = "unset"
        host.settings.startOrganize(includeSemantic = false) { startError = it }
        kotlinx.coroutines.delay(250)
        assertNull(startError)
        val organize = host.settings.state.value.memory.organize
        assertTrue(organize != null)
        assertEquals("hnd:org:1", organize!!.proposalHandle)
        assertEquals(1, organize.autoDeletedCount)
        // Both proposal pages merged: suggestion + BOTH entry summaries.
        assertEquals(1, organize.suggestions.size)
        assertEquals(2, organize.entries.size)
        assertEquals("b-auto", organize.autoDelete?.batchID)

        var applyError: String? = "unset"
        host.settings.applyOrganizeSuggestion("s1") { applyError = it }
        kotlinx.coroutines.delay(200)
        assertNull(applyError)
        val applyEnvelope = exchange.envelopes("memory.organize.apply").single()
        assertEquals("memory", (applyEnvelope["configurationScope"] as JsonPrimitive).content)
        assertEquals(true, (applyEnvelope["stateful"] as JsonPrimitive).booleanOrNull)
        assertEquals(true, (applyEnvelope["createIntent"] as JsonPrimitive).booleanOrNull)
        val payload = applyEnvelope["payload"] as JsonObject
        assertEquals(setOf("handle", "suggestionID", "batchID", "syncRevision"), payload.keys)
        assertEquals("hnd:org:1", (payload["handle"] as JsonPrimitive).content)
        assertEquals("s1", (payload["suggestionID"] as JsonPrimitive).content)
        assertTrue(((payload["syncRevision"] as JsonPrimitive).longOrNull ?: 0L) > 0L)
        // batchID is a fresh client-proposed ledger identity (UUID shape).
        val batch = (payload["batchID"] as JsonPrimitive).content
        assertTrue(batch.length == 36 && batch.contains("-"))
    }

    @Test
    fun organizeApplyRefusesStaleProposalWithoutSendingEnvelope() = runBlocking {
        val exchange = ScriptExchange(
            receiptFor = { _, _ -> "op:v1:x" },
            effectFor = { _, _ -> null },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("settingsMemory", true, emptyList())
        // Seed a stale organize surface directly through a completed start.
        val startPage = """{"status":"completed","scannedCount":1,"autoDeletedCount":0,"pendingReviewCount":0,"autoDelete":{"status":"none","batchID":null,"staleIDs":[]},"proposalStale":true,"semantic":{"skipped":true},"proposalHandle":"hnd:stale"}"""
        val scripted = ScriptExchange(
            receiptFor = { command, _ ->
                if (command == "memory.organize.start") "op:v1:org" else "op:v1:x"
            },
            effectFor = { receipt, correlation ->
                if (receipt == "op:v1:org") completedEffect(correlation, receipt, startPage) else null
            },
        )
        val host2 = testHost(scripted)
        host2.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host2.onDomainAvailability("settingsMemory", true, emptyList())
        host2.settings.startOrganize(includeSemantic = false) {}
        kotlinx.coroutines.delay(200)
        assertTrue(host2.settings.state.value.memory.organize?.stale == true)
        var outcome: String? = "unset"
        host2.settings.applyOrganizeSuggestion("s1") { outcome = it }
        kotlinx.coroutines.delay(50)
        assertEquals("staleProposal", outcome)
        assertTrue(scripted.envelopes("memory.organize.apply").isEmpty())
    }

    @Test
    fun organizeCancelReusesStartCorrelationAndVerifiesReceipt() = runBlocking {
        lateinit var startCorrelation: String
        val startPage = """{"status":"completed","scannedCount":1,"autoDeletedCount":0,"pendingReviewCount":0,"autoDelete":{"status":"none","batchID":null,"staleIDs":[]},"proposalStale":false,"semantic":{"skipped":true},"proposalHandle":"hnd:org:9"}"""
        val exchange = object : HostBridgeExchange {
            val requests = java.util.concurrent.CopyOnWriteArrayList<String>()
            @Volatile var cancelReceipt = "op:v1:org"
            @Volatile var settled = false
            override fun exchange(request: String): String {
                requests.add(request)
                val correlation = correlationOf(request)
                if (request.contains("\"operation\":\"effect.poll\"")) {
                    val receipt = receiptOf(request)
                    return if (receipt == "op:v1:org") {
                        if (settled) completedEffect(correlation, receipt, startPage)
                        else """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":0},"effects":[],"hasMore":true,"resyncRequired":false}"""
                    } else {
                        """{"version":3,"requestID":"$correlation","ok":false,"schema":"floe.effect-cursor/3","correlationID":"$correlation","error":"unknownReceipt"}"""
                    }
                }
                return if (request.contains("\"command\":\"memory.organize.start\"")) {
                    startCorrelation = correlation
                    """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"op:v1:org"}"""
                } else {
                    // Cancel admission: same receipt while live (settable).
                    """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"$cancelReceipt"}"""
                }
            }
        }
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("settingsMemory", true, emptyList())
        host.settings.startOrganize(includeSemantic = false) {}
        kotlinx.coroutines.delay(250)
        assertTrue(host.settings.state.value.memory.organize?.startReceipt == "op:v1:org")

        var outcome: String? = "unset"
        host.settings.cancelOrganize { outcome = it }
        kotlinx.coroutines.delay(150)
        assertNull(outcome)
        val cancelEnvelope = exchange.requests
            .filter { it.contains("\"command\":\"memory.organize.cancel\"") }
        assertEquals(1, cancelEnvelope.size)
        // The cancel addresses the REAL operation: same correlation, and the
        // admission re-issued the SAME receipt (liveReceipt path).
        assertTrue(cancelEnvelope.single().contains("\"correlationID\":\"$startCorrelation\""))

        // Once the operation settled, the mailbox mints a NEW receipt for the
        // same correlation: the cancel must admit it honestly typed.
        exchange.settled = true
        exchange.cancelReceipt = "op:v1:reminted"
        var lateOutcome: String? = "unset"
        host.settings.cancelOrganize { lateOutcome = it }
        kotlinx.coroutines.delay(150)
        assertEquals("noActiveOrganize", lateOutcome)
    }

    @Test
    fun lateProposalPageForReplacedHandleIsDropped() = runBlocking {
        // First organize owns the surface; a second start replaces the
        // handle; a late page for the OLD handle must not overwrite.
        val startPageA = """{"status":"completed","scannedCount":1,"autoDeletedCount":0,"pendingReviewCount":0,"autoDelete":{"status":"none","batchID":null,"staleIDs":[]},"proposalStale":false,"semantic":{"skipped":true},"proposalHandle":"hnd:A"}"""
        val startPageB = """{"status":"completed","scannedCount":2,"autoDeletedCount":0,"pendingReviewCount":0,"autoDelete":{"status":"none","batchID":null,"staleIDs":[]},"proposalStale":false,"semantic":{"skipped":true},"proposalHandle":"hnd:B"}"""
        val proposalA = """{"proposalID":"pA","generatedAt":"2026-10-21T00:00:00Z","scannedCount":9,"suggestions":[{"id":"old","kind":"expired","memoryIDs":[],"preferredMemoryID":null,"reason":"old","canApplyAutomatically":false}],"entries":[],"nextCursor":null,"stale":false,"staleIDs":[],"autoDelete":{"status":"none","batchID":null}}"""
        val proposalB = """{"proposalID":"pB","generatedAt":"2026-10-21T00:00:00Z","scannedCount":2,"suggestions":[],"entries":[],"nextCursor":null,"stale":false,"staleIDs":[],"autoDelete":{"status":"none","batchID":null}}"""
        var startCount = 0
        var deliverLateA = false
        val exchange = object : HostBridgeExchange {
            override fun exchange(request: String): String {
                val correlation = correlationOf(request)
                if (request.contains("\"operation\":\"effect.poll\"")) {
                    val receipt = receiptOf(request)
                    return when (receipt) {
                        "op:v1:orgA" -> completedEffect(correlation, receipt, startPageA)
                        "op:v1:orgB" -> completedEffect(correlation, receipt, startPageB)
                        // The first proposal page chain for hnd:A delivers
                        // LATE (after hnd:B owns the surface).
                        "op:v1:propA" ->
                            completedEffect(correlation, receipt, proposalA)
                        "op:v1:propB" ->
                            completedEffect(correlation, receipt, proposalB)
                        else -> """{"version":3,"requestID":"$correlation","ok":false,"schema":"floe.effect-cursor/3","correlationID":"$correlation","error":"unknownReceipt"}"""
                    }
                }
                return when {
                    request.contains("\"command\":\"memory.organize.start\"") -> {
                        startCount++
                        val receipt = if (startCount == 1) "op:v1:orgA" else "op:v1:orgB"
                        """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"$receipt"}"""
                    }
                    request.contains("\"command\":\"memory.organize.proposal.read\"") -> {
                        val receipt = if (deliverLateA) "op:v1:propB" else "op:v1:propA"
                        deliverLateA = true
                        """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"$receipt"}"""
                    }
                    else -> """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"op:v1:x"}"""
                }
            }
        }
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("settingsMemory", true, emptyList())
        host.settings.startOrganize(includeSemantic = false) {}
        kotlinx.coroutines.delay(200)
        host.settings.startOrganize(includeSemantic = false) {}
        kotlinx.coroutines.delay(300)
        val current = host.settings.state.value.memory.organize
        assertEquals("hnd:B", current?.proposalHandle)
        // The late hnd:A page was fenced out: B's empty suggestion list wins.
        assertTrue(current?.suggestions?.isEmpty() == true)
    }

    @Test
    fun personalizationHistoryPagesAndRollbackUsesOriginalGrammar() = runBlocking {
        val active = """{"id":"d3","kind":"soul","workspaceID":null,"revision":3,"source":"manual","evidenceDigest":"e3","isActive":true,"createdAt":"2026-10-21T00:00:02Z","contentBytes":11,"contentDigest":"c3","content":"version three","contentHandle":null}"""
        val meta2 = """{"id":"d2","revision":2,"source":"automatic","isActive":false,"createdAt":"2026-10-21T00:00:01Z","contentBytes":11,"contentDigest":"c2"}"""
        val meta1 = """{"id":"d1","revision":1,"source":"manual","isActive":false,"createdAt":"2026-10-21T00:00:00Z","contentBytes":11,"contentDigest":"c1"}"""
        val cursor = """{"automaticUpdatesEnabled":false,"lastGeneratedAt":null,"completedRunsSinceUpdate":0,"userMessagesSinceUpdate":0,"updatedAt":"2026-10-21T00:00:02Z","revision":"tok:cur:1"}"""
        val getPage1 = """{"active":$active,"latestRevision":3,"revisionsMeta":[$meta2],"cursor":$cursor,"revisionToken":"tok:act:3","revisionsNextCursor":"1"}"""
        val getPage2 = """{"active":$active,"latestRevision":3,"revisionsMeta":[$meta1],"cursor":$cursor,"revisionToken":"tok:act:3","revisionsNextCursor":null}"""
        val rollbackReply = """{"document":$active,"revisionToken":"tok:act:4","latestRevision":4}"""
        var pgetPolls = 0
        val exchange = ScriptExchange(
            receiptFor = { command, _ ->
                when (command) {
                    "personalization.get" -> "op:v1:pget"
                    "personalization.rollback" -> "op:v1:proll"
                    else -> "op:v1:x"
                }
            },
            effectFor = { receipt, correlation ->
                when (receipt) {
                    "op:v1:pget" -> {
                        val seen = pgetPolls++
                        if (seen == 0) completedEffect(correlation, receipt, getPage1)
                        else completedEffect(correlation, receipt, getPage2)
                    }
                    "op:v1:proll" -> completedEffect(correlation, receipt, rollbackReply)
                    else -> null
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("settingsPersonalization", true, emptyList())
        host.settings.refreshPersonalization("soul")
        kotlinx.coroutines.delay(200)
        val surface = host.settings.state.value.personalization
        assertEquals(1, surface.revisions.size)
        assertEquals("1", surface.revisionsNextCursor)

        host.settings.loadMoreRevisions("soul")
        kotlinx.coroutines.delay(200)
        val merged = host.settings.state.value.personalization
        assertEquals(2, merged.revisions.size)
        assertEquals(2, merged.revisions[0].revision)
        assertEquals(1, merged.revisions[1].revision)
        // The continuation request carried the REAL revisionsCursor payload.
        val moreEnvelope = exchange.envelopes("personalization.get")[1]
        val morePayload = moreEnvelope["payload"] as JsonObject
        assertEquals("1", (morePayload["revisionsCursor"] as JsonPrimitive).content)

        var rollbackOutcome: String? = "unset"
        host.settings.rollbackPersonalization("soul", 1) { rollbackOutcome = it }
        kotlinx.coroutines.delay(200)
        assertNull(rollbackOutcome)
        val rollbackEnvelope = exchange.envelopes("personalization.rollback").single()
        val revision = rollbackEnvelope["revision"] as JsonObject
        assertEquals("personalization.soul", (revision["resourceID"] as JsonPrimitive).content)
        assertEquals("tok:act:3", (revision["version"] as JsonPrimitive).content)
        val rollbackPayload = rollbackEnvelope["payload"] as JsonObject
        assertEquals("soul", (rollbackPayload["kind"] as JsonPrimitive).content)
        assertEquals(1L, (rollbackPayload["targetRevision"] as JsonPrimitive).longOrNull)
    }

    @Test
    fun revisionReadFollowsHandlePagingTruthfully() = runBlocking {
        val document = """{"id":"d2","kind":"soul","workspaceID":null,"revision":2,"source":"automatic","evidenceDigest":"e2","isActive":false,"createdAt":"2026-10-21T00:00:01Z","contentBytes":40,"contentDigest":"c2","content":null,"contentHandle":{"handle":"hnd:doc:2","bytes":40}}"""
        val chunk1 = """{"chunk":"first-part|","nextOffset":11}"""
        val chunk2 = """{"chunk":"second-part","nextOffset":null}"""
        var contentPolls = 0
        val exchange = ScriptExchange(
            receiptFor = { command, _ ->
                when (command) {
                    "personalization.revision.read" -> "op:v1:pread"
                    "content.read" -> "op:v1:cread"
                    else -> "op:v1:x"
                }
            },
            effectFor = { receipt, correlation ->
                when (receipt) {
                    "op:v1:pread" -> completedEffect(correlation, receipt, """{"document":$document}""")
                    "op:v1:cread" -> {
                        val seen = contentPolls++
                        if (seen == 0) completedEffect(correlation, receipt, chunk1)
                        else completedEffect(correlation, receipt, chunk2)
                    }
                    else -> null
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("settingsPersonalization", true, emptyList())
        host.settings.readPersonalizationRevision("soul", 2)
        kotlinx.coroutines.delay(250)
        val open = host.settings.state.value.personalization.openRevision
        assertTrue(open != null)
        assertEquals(2, open!!.revision)
        assertEquals("first-part|second-part", open.content)
    }

    @Test
    fun generateCancelRequiresReceiptAndLateTerminalCannotClearNewerRun() =
        runBlocking {
            val exchange = object : HostBridgeExchange {
                val requests = java.util.concurrent.CopyOnWriteArrayList<String>()
                var genBCounter = 0
                var genAStarted = false
                @Volatile var deliverGenATerminal = false
                @Volatile var deliverGenBTerminal = false
                override fun exchange(request: String): String {
                    requests.add(request)
                    val correlation = correlationOf(request)
                    if (request.contains("\"operation\":\"effect.poll\"")) {
                        val receipt = receiptOf(request)
                        return when (receipt) {
                            "op:v1:genA" -> {
                                if (deliverGenATerminal) {
                                    """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":1},"effects":[{"sequence":1,"kind":"cancelled"}],"hasMore":false,"resyncRequired":false}"""
                                } else {
                                    """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":0},"effects":[],"hasMore":true,"resyncRequired":false}"""
                                }
                            }
                            "op:v1:genB" -> {
                                genBCounter++
                                if (deliverGenBTerminal) {
                                    completedEffect(correlation, receipt, """{"status":"committed"}""")
                                } else {
                                    """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":0},"effects":[],"hasMore":true,"resyncRequired":false}"""
                                }
                            }
                            else -> """{"version":3,"requestID":"$correlation","ok":false,"schema":"floe.effect-cursor/3","correlationID":"$correlation","error":"unknownReceipt"}"""
                        }
                    }
                    return if (request.contains("\"command\":\"personalization.generate\"")) {
                        val chosen = if (genAStarted) {
                            "op:v1:genB"
                        } else {
                            genAStarted = true
                            "op:v1:genA"
                        }
                        """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"$chosen"}"""
                    } else {
                        // The cancel admission answers with a foreign receipt:
                        // models the operation-already-settled honest path.
                        """{"version":3,"ok":true,"queued":true,"correlationID":"$correlation","operationReceiptID":"op:v1:x"}"""
                    }
                }
            }
            val host = testHost(exchange)
            host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
            host.onDomainAvailability("settingsPersonalization", true, emptyList())

            // First generation starts and is accepted.
            var firstOutcome: String? = "unset"
            host.settings.generatePersonalization("soul") { firstOutcome = it }
            kotlinx.coroutines.delay(250)
            val afterStart = host.settings.state.value.personalization
            assertTrue(afterStart.generating)
            val receiptA = afterStart.generateReceipt
            val correlationA = afterStart.generateCorrelation
            assertTrue(receiptA != null && correlationA != null)

            // A second generation supersedes the first.
            exchange.deliverGenATerminal = true
            host.settings.generatePersonalization("soul") {}
            kotlinx.coroutines.delay(300)
            val current = host.settings.state.value.personalization
            assertTrue(current.generating)
            assertTrue(current.generateCorrelation != correlationA)

            // Cancel reuses the CURRENT generation correlation; the fixture
            // admission answers with a foreign receipt, which the controller
            // must surface honestly as "noActiveGeneration" (it never claims
            // a cancellation that did not reach the live operation).
            var cancelOutcome: String? = "unset"
            host.settings.cancelPersonalizationGenerate { cancelOutcome = it }
            kotlinx.coroutines.delay(200)
            assertEquals("noActiveGeneration", cancelOutcome)
            val cancelEnvelope = exchange.requests
                .filter { it.contains("\"command\":\"personalization.generate.cancel\"") }
            assertEquals(1, cancelEnvelope.size)
            assertTrue(
                cancelEnvelope.single()
                    .contains("\"correlationID\":\"${current.generateCorrelation}\""),
            )

            // Late terminal of the FIRST generation must not clear the new one.
            exchange.deliverGenATerminal = true
            kotlinx.coroutines.delay(400)
            assertTrue(host.settings.state.value.personalization.generating)

            // Release the current operation only after the stale-result check.
            exchange.deliverGenBTerminal = true
            kotlinx.coroutines.delay(400)
            assertFalse(host.settings.state.value.personalization.generating)
        }

    // ---------------------------------------------------------------- R2

    @Test
    fun memoryInventoryPagesAndBulkDeleteUsesOriginalGrammar() = runBlocking {
        val entry1 = """{"id":"m1","scope":{"kind":"user"},"status":"active","content":"One","confidence":0.9,"importance":0.5,"isPinned":false,"sourceKind":"user","originConversationID":null,"originWorkspaceID":null,"factIdentity":null,"ownership":{"kind":"owned"},"expiresAt":null,"createdAt":"2026-10-21T00:00:00Z","updatedAt":"2026-10-21T00:00:00Z","revision":"dig:1"}"""
        val entry2 = """{"id":"m2","scope":{"kind":"user"},"status":"active","content":"Two","confidence":0.8,"importance":0.4,"isPinned":false,"sourceKind":"user","originConversationID":null,"originWorkspaceID":null,"factIdentity":null,"ownership":{"kind":"owned"},"expiresAt":null,"createdAt":"2026-10-21T00:00:01Z","updatedAt":"2026-10-21T00:00:01Z","revision":"dig:2"}"""
        val page1 = """{"entries":[$entry1],"nextCursor":"1"}"""
        val page2 = """{"entries":[$entry2],"nextCursor":null}"""
        val bulkReply = """{"batchID":"b1","result":"applied","deletedCount":2,"replacedCount":0,"appliedCount":2}"""
        var listCalls = 0
        val exchange = ScriptExchange(
            receiptFor = { command, _ ->
                when (command) {
                    "memory.list" -> if (listCalls++ == 0) "op:v1:l1" else "op:v1:l2"
                    "memory.delete.bulk" -> "op:v1:bulk"
                    else -> "op:v1:x"
                }
            },
            effectFor = { receipt, correlation ->
                when (receipt) {
                    "op:v1:l1" -> completedEffect(correlation, receipt, page1)
                    "op:v1:l2" -> completedEffect(correlation, receipt, page2)
                    "op:v1:bulk" -> completedEffect(correlation, receipt, bulkReply)
                    else -> null
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("settingsMemory", true, emptyList())

        host.settings.refreshMemory()
        kotlinx.coroutines.delay(200)
        val first = host.settings.state.value.memory
        assertEquals(listOf("m1"), first.entries.map { it.id })
        assertEquals("1", first.nextCursor)
        assertEquals("dig:1", first.entries.single().revision)

        host.settings.loadMoreMemory()
        kotlinx.coroutines.delay(200)
        val merged = host.settings.state.value.memory
        assertEquals(listOf("m1", "m2"), merged.entries.map { it.id })
        assertNull(merged.nextCursor)
        // The continuation carried the REAL composer cursor, never a re-read.
        val morePayload = exchange.envelopes("memory.list")[1]["payload"] as JsonObject
        assertEquals("1", (morePayload["cursor"] as JsonPrimitive).content)

        val prepared = host.settings.prepareMemoryBulkDelete(
            listOf("m1" to "dig:1", "m2" to "dig:2"))
        val intent =
            (prepared as SettingsHostController.MemoryBulkDeletePreparation.Ready).intent
        var outcome: SettingsHostController.MemoryMutationOutcome? = null
        host.settings.bulkDeleteMemory(
            intent,
            host.settings.beginMemoryBulkInteraction(),
        ) { outcome = it }
        kotlinx.coroutines.delay(200)
        assertEquals(
            SettingsHostController.MemoryMutationOutcome.Applied,
            outcome,
        )
        val envelope = exchange.envelopes("memory.delete.bulk").single()
        assertTrue((envelope["stateful"] as JsonPrimitive).booleanOrNull == true)
        assertTrue((envelope["createIntent"] as JsonPrimitive).booleanOrNull == true)
        val payload = envelope["payload"] as JsonObject
        assertEquals(setOf("batchID", "syncRevision", "entries"), payload.keys)
        val batchID = (payload["batchID"] as JsonPrimitive).content
        assertTrue(batchID.length == 36 && batchID.contains("-"))
        assertEquals(intent.batchID, batchID)
        assertEquals(intent.syncRevision,
            (payload["syncRevision"] as JsonPrimitive).longOrNull)
        val entries = payload["entries"] as JsonArray
        assertEquals(2, entries.size)
        val firstEntry = entries[0] as JsonObject
        assertEquals(setOf("id", "expectedDigest"), firstEntry.keys)
        assertEquals("m1", (firstEntry["id"] as JsonPrimitive).content)
        assertEquals("dig:1", (firstEntry["expectedDigest"] as JsonPrimitive).content)
    }

    @Test
    fun memorySearchPagesUseHandleAndDiscloseChangedRows() = runBlocking {
        val current = """{"id":"m1","scope":{"kind":"user"},"status":"active","content":"Kept","confidence":0.9,"importance":0.5,"isPinned":false,"sourceKind":"user","originConversationID":null,"originWorkspaceID":null,"factIdentity":null,"ownership":{"kind":"owned"},"expiresAt":null,"createdAt":"2026-10-21T00:00:00Z","updatedAt":"2026-10-21T00:00:00Z","revision":"dig:1"}"""
        val page1 = """{"items":[{"id":"m1","relevance":0.9,"lexicalRank":1,"semanticRank":null,"semanticSimilarity":null,"current":$current,"deleted":false}],"semantic":false,"sideEffects":{"lifecycleMaintained":true,"reinforcementPathExecuted":true,"reinforcedCount":null,"digestsRefreshed":true,"explanation":"x"},"searchHandle":"h1","nextCursor":"1","hasMore":true}"""
        val page2 = """{"items":[{"id":"m2","relevance":0.4,"lexicalRank":2,"semanticRank":null,"semanticSimilarity":null,"current":null,"deleted":true}],"semantic":false,"sideEffects":{"lifecycleMaintained":true,"reinforcementPathExecuted":false,"reinforcedCount":null,"digestsRefreshed":true,"explanation":"x"},"searchHandle":"h1","nextCursor":null,"hasMore":false}"""
        var searchCalls = 0
        val exchange = ScriptExchange(
            receiptFor = { command, _ ->
                when (command) {
                    "memory.search" -> if (searchCalls++ == 0) "op:v1:s1" else "op:v1:s2"
                    else -> "op:v1:x"
                }
            },
            effectFor = { receipt, correlation ->
                when (receipt) {
                    "op:v1:s1" -> completedEffect(correlation, receipt, page1)
                    "op:v1:s2" -> completedEffect(correlation, receipt, page2)
                    else -> null
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("settingsMemory", true, emptyList())

        host.settings.searchMemory("hello")
        kotlinx.coroutines.delay(200)
        val first = host.settings.state.value.memory
        assertEquals(1, first.searchItems.size)
        assertEquals(0, first.searchChangedCount)
        assertTrue(first.searchHasMore)
        assertEquals("h1", first.searchHandle)

        host.settings.loadMoreMemorySearch()
        kotlinx.coroutines.delay(200)
        val paged = host.settings.state.value.memory
        assertEquals(2, paged.searchItems.size)
        assertEquals(1, paged.searchChangedCount)
        assertFalse(paged.searchHasMore)
        val morePayload = exchange.envelopes("memory.search")[1]["payload"] as JsonObject
        assertEquals("hello", (morePayload["query"] as JsonPrimitive).content)
        assertEquals("h1", (morePayload["handle"] as JsonPrimitive).content)
        assertEquals("1", (morePayload["cursor"] as JsonPrimitive).content)
    }

    @Test
    fun usageDimensionPagesAndKeepsUnreportedMetricsNull() = runBlocking {
        val totals = """{"inputTokens":10,"outputTokens":5,"totalTokens":15,"runs":1,"cacheReadTokens":null,"cacheWriteTokens":null,"reasoningTokens":null,"averageTokensPerSecond":null,"averageTimeToFirstTokenMs":null,"averageDurationMs":null}"""
        val row1 = """{"id":"model-1","label":"Model One","inputTokens":7,"outputTokens":3,"runs":1,"cacheReadTokens":null,"cacheWriteTokens":null,"reasoningTokens":null,"averageTokensPerSecond":null,"averageTimeToFirstTokenMs":null,"averageDurationMs":null,"totalTokens":10}"""
        val row2 = """{"id":"model-2","label":"Model Two","inputTokens":3,"outputTokens":2,"runs":1,"cacheReadTokens":null,"cacheWriteTokens":null,"reasoningTokens":null,"averageTokensPerSecond":null,"averageTimeToFirstTokenMs":null,"averageDurationMs":null,"totalTokens":5}"""
        val page1 = """{"totals":$totals,"byDay":[],"rows":[$row1],"nextCursor":"1"}"""
        val page2 = """{"totals":$totals,"byDay":[],"rows":[$row2],"nextCursor":null}"""
        var usageCalls = 0
        val exchange = ScriptExchange(
            receiptFor = { command, _ ->
                if (command == "usage.statistics.get") {
                    if (usageCalls++ == 0) "op:v1:u1" else "op:v1:u2"
                } else "op:v1:unused"
            },
            effectFor = { receipt, correlation ->
                when (receipt) {
                    "op:v1:u1" -> completedEffect(correlation, receipt, page1)
                    "op:v1:u2" -> completedEffect(correlation, receipt, page2)
                    else -> null
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("settingsUsage", true, emptyList())

        host.settings.refreshUsage("model")
        kotlinx.coroutines.delay(200)
        val first = host.settings.state.value.usage
        assertEquals("model", first.dimension)
        assertEquals(1, first.rows.size)
        assertEquals("1", first.nextCursor)
        // Null is "not reported", never a fabricated zero.
        assertNull(first.totals?.cacheReadTokens)
        assertNull(first.rows.single().reasoningTokens)
        val firstPayload = exchange.envelopes("usage.statistics.get")[0]["payload"] as JsonObject
        assertEquals("model", (firstPayload["dimension"] as JsonPrimitive).content)

        host.settings.loadMoreUsage()
        kotlinx.coroutines.delay(200)
        val paged = host.settings.state.value.usage
        assertEquals(2, paged.rows.size)
        assertNull(paged.nextCursor)
        val morePayload = exchange.envelopes("usage.statistics.get")[1]["payload"] as JsonObject
        assertEquals("1", (morePayload["cursor"] as JsonPrimitive).content)
        assertEquals("model", (morePayload["dimension"] as JsonPrimitive).content)
    }

    @Test
    fun candidateReviewPagesDisclosesSweepAndRejectsThroughRealCommand() = runBlocking {
        val candidate = """{"id":"c1","scope":{"kind":"user"},"content":"Pinned fact","confidence":0.9,"stability":0.8,"importance":0.5,"sensitivity":"normal","origin":"user","evidence":[],"conflictsWithEntryIDs":[],"reviewReason":null,"sourceAttachmentID":null,"sourceMIMEType":null,"status":"pending","expiresAt":null,"createdAt":"2026-10-21T00:00:00Z","updatedAt":"2026-10-21T00:00:00Z","revision":"cdig:1"}"""
        val page1 = """{"candidates":[$candidate],"nextCursor":"1","expiredSweepApplied":true}"""
        val page2 = """{"candidates":[],"nextCursor":null,"expiredSweepApplied":false}"""
        val resolveReply = """{"status":"rejected","entry":null}"""
        var listCalls = 0
        val exchange = ScriptExchange(
            receiptFor = { command, _ ->
                when (command) {
                    "memory.candidates.list" -> if (listCalls++ == 0) "op:v1:c1" else "op:v1:c2"
                    "memory.candidate.resolve" -> "op:v1:cres"
                    else -> "op:v1:x"
                }
            },
            effectFor = { receipt, correlation ->
                when (receipt) {
                    "op:v1:c1" -> completedEffect(correlation, receipt, page1)
                    "op:v1:c2" -> completedEffect(correlation, receipt, page2)
                    "op:v1:cres" -> completedEffect(correlation, receipt, resolveReply)
                    else -> null
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("settingsMemory", true, emptyList())

        host.settings.listCandidates()
        kotlinx.coroutines.delay(200)
        val first = host.settings.state.value.memory
        assertEquals(1, first.candidates.size)
        assertEquals("1", first.candidatesNextCursor)
        assertTrue(first.candidatesSweepApplied)

        host.settings.loadMoreCandidates()
        kotlinx.coroutines.delay(200)
        val paged = host.settings.state.value.memory
        assertEquals(1, paged.candidates.size)
        assertNull(paged.candidatesNextCursor)
        // The first page's sweep disclosure is preserved across pages.
        assertTrue(paged.candidatesSweepApplied)
        val morePayload = exchange.envelopes("memory.candidates.list")[1]["payload"] as JsonObject
        assertEquals("1", (morePayload["cursor"] as JsonPrimitive).content)

        var outcome: String? = "unset"
        host.settings.resolveCandidate("c1", "cdig:1", false) { outcome = it }
        kotlinx.coroutines.delay(200)
        assertNull(outcome)
        val resolveEnvelope = exchange.envelopes("memory.candidate.resolve").single()
        val resolvePayload = resolveEnvelope["payload"] as JsonObject
        assertEquals(false, (resolvePayload["activate"] as JsonPrimitive).booleanOrNull)
        assertEquals("c1", (resolvePayload["id"] as JsonPrimitive).content)
    }

    @Test
    fun activePersonalizationHandleIsChunkReadIntoTheEditor() = runBlocking {
        val active = """{"id":"d1","kind":"soul","workspaceID":null,"revision":1,"source":"manual","evidenceDigest":"e1","isActive":true,"createdAt":"2026-10-21T00:00:00Z","contentBytes":6,"contentDigest":"c1","content":null,"contentHandle":{"handle":"h1"}}"""
        val get = """{"active":$active,"latestRevision":1,"revisionsMeta":[],"cursor":{"automaticUpdatesEnabled":false,"lastGeneratedAt":null,"completedRunsSinceUpdate":0,"userMessagesSinceUpdate":0,"updatedAt":"2026-10-21T00:00:00Z","revision":"tok:cur"},"revisionToken":"tok:act:1","revisionsNextCursor":null}"""
        val chunk1 = """{"chunk":"abc","nextOffset":3}"""
        val chunk2 = """{"chunk":"def","nextOffset":null}"""
        var readCalls = 0
        val exchange = ScriptExchange(
            receiptFor = { command, _ ->
                when (command) {
                    "personalization.get" -> "op:v1:pget"
                    "content.read" -> if (readCalls++ == 0) "op:v1:cr1" else "op:v1:cr2"
                    else -> "op:v1:x"
                }
            },
            effectFor = { receipt, correlation ->
                when (receipt) {
                    "op:v1:pget" -> completedEffect(correlation, receipt, get)
                    "op:v1:cr1" -> completedEffect(correlation, receipt, chunk1)
                    "op:v1:cr2" -> completedEffect(correlation, receipt, chunk2)
                    else -> null
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("settingsPersonalization", true, emptyList())
        host.settings.refreshPersonalization("soul")
        kotlinx.coroutines.delay(300)
        val surface = host.settings.state.value.personalization
        // The producer returned a handle (over-budget document); the editor
        // must hold the byte-exact reassembled content, not an empty body.
        assertEquals("abcdef", surface.content)
        assertFalse(surface.contentLoading)
        assertFalse(surface.contentLoadFailed)
        assertEquals("h1", surface.contentHandle)
        val chunkEnvelope = exchange.envelopes("content.read").first()
        val payload = chunkEnvelope["payload"] as JsonObject
        assertEquals("h1", (payload["handle"] as JsonPrimitive).content)
        assertEquals(0L, (payload["offsetBytes"] as JsonPrimitive).longOrNull ?: -1L)
        assertEquals("personalization",
            (chunkEnvelope["configurationScope"] as JsonPrimitive).content)
    }

    // ---------------------------------------------------- R2 source guards

    private fun memoryEntry(
        id: String,
        content: String,
        revision: String,
        pinned: Boolean = false,
    ): String =
        """{"id":"$id","scope":{"kind":"user"},"status":"active","content":"$content",""" +
            """"confidence":0.9,"importance":0.5,"isPinned":$pinned,"sourceKind":"user",""" +
            """"originConversationID":null,"originWorkspaceID":null,"factIdentity":null,""" +
            """"ownership":{"kind":"owned"},"expiresAt":null,""" +
            """"createdAt":"2026-10-21T00:00:00Z","updatedAt":"2026-10-21T00:00:00Z",""" +
            """"revision":"$revision"}"""

    @Test
    fun memoryEditorNeverOpensOnFailureAndFencesLateRow() = runBlocking {
        val entryA = memoryEntry("mA", "Alpha", "dig:a")
        val entryB = memoryEntry("mB", "Beta", "dig:b")
        val gate = java.util.concurrent.CountDownLatch(1)
        var getCalls = 0
        val exchange = ScriptExchange(
            receiptFor = { command, _ ->
                when (command) {
                    "memory.get" -> when (++getCalls) {
                        1 -> "op:v1:getA"
                        2 -> "op:v1:getB"
                        else -> "op:v1:getC"
                    }
                    else -> "op:v1:x"
                }
            },
            effectFor = { receipt, correlation ->
                when (receipt) {
                    // A's terminal is delayed until after B has opened.
                    "op:v1:getA" -> {
                        gate.await()
                        completedEffect(correlation, receipt, entryA)
                    }
                    "op:v1:getB" -> completedEffect(correlation, receipt, entryB)
                    "op:v1:getC" -> rejectedEffect(correlation, receipt, "memoryNotFound")
                    else -> null
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("settingsMemory", true, emptyList())

        host.settings.openMemoryEditor("mA")
        kotlinx.coroutines.delay(100)
        host.settings.openMemoryEditor("mB")
        kotlinx.coroutines.delay(200)
        assertEquals("mB", host.settings.state.value.memoryEditor?.entry?.id)
        gate.countDown()
        kotlinx.coroutines.delay(250)
        // The late A reply belongs to a superseded generation: it must not
        // replace the B editor or open a second one.
        assertEquals("mB", host.settings.state.value.memoryEditor?.entry?.id)
        assertTrue((host.settings.state.value.memoryEditor?.generation ?: 0) > 0)

        // A refused read never opens an editor (the old code ignored false).
        host.settings.openMemoryEditor("mC")
        kotlinx.coroutines.delay(200)
        assertNull(host.settings.state.value.memoryEditor)
        assertEquals("memoryNotFound", host.settings.state.value.memoryEditorError)
        assertFalse(host.settings.state.value.memoryEditorLoading)
    }

    @Test
    fun memoryEditorKeepsFrozenBaseAcrossListRefreshAndTypedStale() = runBlocking {
        var listCalls = 0
        val exchange = ScriptExchange(
            receiptFor = { command, _ ->
                when (command) {
                    "memory.list" -> if (++listCalls == 1) "op:v1:listOld" else "op:v1:listNew"
                    "memory.get" -> "op:v1:mget"
                    "memory.update" -> "op:v1:mupd"
                    else -> "op:v1:x"
                }
            },
            effectFor = { receipt, correlation ->
                when (receipt) {
                    "op:v1:listOld" -> completedEffect(
                        correlation, receipt,
                        """{"entries":[${memoryEntry("mA", "Old listing", "dig:old")}],"nextCursor":null}""",
                    )
                    "op:v1:listNew" -> completedEffect(
                        correlation, receipt,
                        """{"entries":[${memoryEntry("mA", "External edit", "dig:new")}],"nextCursor":null}""",
                    )
                    "op:v1:mget" -> completedEffect(
                        correlation, receipt, memoryEntry("mA", "Fresh body", "dig:fresh"),
                    )
                    "op:v1:mupd" -> rejectedEffect(correlation, receipt, "staleRevision")
                    else -> null
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("settingsMemory", true, emptyList())

        host.settings.refreshMemory()
        kotlinx.coroutines.delay(200)
        host.settings.openMemoryEditor("mA")
        kotlinx.coroutines.delay(200)
        val editor = host.settings.state.value.memoryEditor!!
        assertEquals("Fresh body", editor.entry.content)
        assertEquals("dig:fresh", editor.entry.revision)

        // Background refresh publishes a NEW digest/content in the list.
        host.settings.refreshMemory()
        kotlinx.coroutines.delay(200)
        assertEquals(
            "dig:new",
            host.settings.state.value.memory.entries.single().revision,
        )
        // The open draft keeps its frozen base.
        assertEquals("Fresh body", host.settings.state.value.memoryEditor?.entry?.content)
        assertEquals("dig:fresh", host.settings.state.value.memoryEditor?.entry?.revision)

        var outcome: SettingsHostController.MemoryMutationOutcome? = null
        host.settings.updateMemory("mA", editor.entry.revision, "My edit", null, false) {
            outcome = it
        }
        kotlinx.coroutines.delay(200)
        assertEquals(
            SettingsHostController.MemoryMutationOutcome.Refused("staleRevision"),
            outcome,
        )
        val updateEnvelope = exchange.envelopes("memory.update").single()
        val revision = updateEnvelope["revision"] as JsonObject
        // The frozen base was sent — never the newer digest from the list.
        assertEquals("dig:fresh", (revision["version"] as JsonPrimitive).content)
        // A stale save keeps the draft open (no silent CAS upgrade/close).
        assertEquals("dig:fresh", host.settings.state.value.memoryEditor?.entry?.revision)
    }

    @Test
    fun bulkDeleteIntentIsFrozenAndRetryReusesTheSameBatchIdentity() = runBlocking {
        var bulkCalls = 0
        val exchange = ScriptExchange(
            receiptFor = { command, _ ->
                when (command) {
                    "memory.list" -> "op:v1:mlist"
                    "memory.delete.bulk" -> if (++bulkCalls == 1) {
                        "op:v1:bulk1"
                    } else {
                        "op:v1:bulk2"
                    }
                    else -> "op:v1:x"
                }
            },
            effectFor = { receipt, correlation ->
                when (receipt) {
                    "op:v1:mlist" -> completedEffect(
                        correlation, receipt,
                        """{"entries":[${memoryEntry("m1", "One", "dig:1")},""" +
                            """${memoryEntry("m2", "Two", "dig:2")}],"nextCursor":null}""",
                    )
                    // The first attempt loses the ack AFTER submission: the
                    // write may have committed, so it is Unconfirmed.
                    "op:v1:bulk1" -> failedEffect(correlation, receipt, "transportLost")
                    "op:v1:bulk2" -> completedEffect(
                        correlation, receipt,
                        """{"batchID":"same","result":"applied","deletedCount":2,""" +
                            """"replacedCount":0,"appliedCount":2}""",
                    )
                    else -> null
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("settingsMemory", true, emptyList())
        host.settings.refreshMemory()
        kotlinx.coroutines.delay(200)

        val intent = (host.settings.prepareMemoryBulkDelete(
            listOf("m1" to "dig:1", "m2" to "dig:2"),
        ) as SettingsHostController.MemoryBulkDeletePreparation.Ready).intent
        var first: SettingsHostController.MemoryMutationOutcome? = null
        val interaction = host.settings.beginMemoryBulkInteraction()
        host.settings.bulkDeleteMemory(intent, interaction) { first = it }
        kotlinx.coroutines.delay(200)
        assertEquals(
            SettingsHostController.MemoryMutationOutcome.Unconfirmed("transportLost"),
            first,
        )

        // Retry the SAME uncertain write: same batchID/syncRevision/entries.
        var second: SettingsHostController.MemoryMutationOutcome? = null
        host.settings.bulkDeleteMemory(intent, interaction) { second = it }
        kotlinx.coroutines.delay(200)
        assertEquals(SettingsHostController.MemoryMutationOutcome.Applied, second)

        val envelopes = exchange.envelopes("memory.delete.bulk")
        assertEquals(2, envelopes.size)
        val payloads = envelopes.map { it["payload"] as JsonObject }
        val firstID = (payloads[0]["batchID"] as JsonPrimitive).content
        val secondID = (payloads[1]["batchID"] as JsonPrimitive).content
        assertEquals(firstID, secondID)
        assertEquals(
            (payloads[0]["syncRevision"] as JsonPrimitive).longOrNull,
            (payloads[1]["syncRevision"] as JsonPrimitive).longOrNull,
        )
        val retryEntries = payloads[1]["entries"] as JsonArray
        assertEquals(2, retryEntries.size)
        assertEquals(
            "m1",
            ((retryEntries[0] as JsonObject)["id"] as JsonPrimitive).content,
        )
        assertEquals(
            "dig:2",
            ((retryEntries[1] as JsonObject)["expectedDigest"] as JsonPrimitive).content,
        )

        // Invalid whole selections are refused typed, never filtered down.
        assertTrue(
            host.settings.prepareMemoryBulkDelete(listOf("m1" to "dig:1", "m1" to "dig:2"))
                is SettingsHostController.MemoryBulkDeletePreparation.Invalid,
        )
        assertEquals(
            "duplicateSelection",
            (host.settings.prepareMemoryBulkDelete(
                listOf("m1" to "dig:1", "m1" to "dig:2"),
            ) as SettingsHostController.MemoryBulkDeletePreparation.Invalid).code,
        )
        assertEquals(
            "invalidSelection",
            (host.settings.prepareMemoryBulkDelete(
                listOf("m1" to "dig:1", "m2" to ""),
            ) as SettingsHostController.MemoryBulkDeletePreparation.Invalid).code,
        )
    }

    @Test
    fun personalizationActiveIsTheRealActiveRowAndSaveUsesTheFrozenToken() = runBlocking {
        val active2 = """{"id":"d2","kind":"soul","workspaceID":null,"revision":2,""" +
            """"source":"manual","evidenceDigest":"e2","isActive":true,""" +
            """"createdAt":"2026-10-21T00:00:01Z","contentBytes":2,"contentDigest":"c2",""" +
            """"content":"v2","contentHandle":null}"""
        val active9 = """{"id":"d9","kind":"soul","workspaceID":null,"revision":9,""" +
            """"source":"manual","evidenceDigest":"e9","isActive":true,""" +
            """"createdAt":"2026-10-21T00:00:09Z","contentBytes":2,"contentDigest":"c9",""" +
            """"content":"v9","contentHandle":null}"""
        val cursor = """{"automaticUpdatesEnabled":false,"lastGeneratedAt":null,""" +
            """"completedRunsSinceUpdate":0,"userMessagesSinceUpdate":0,""" +
            """"updatedAt":"2026-10-21T00:00:09Z","revision":"tok:cur"}"""
        val get1 = """{"active":$active2,"latestRevision":5,"revisionsMeta":[],""" +
            """"cursor":$cursor,"revisionToken":"tok:act:2","revisionsNextCursor":null}"""
        val get2 = """{"active":$active9,"latestRevision":9,"revisionsMeta":[],""" +
            """"cursor":$cursor,"revisionToken":"tok:act:9","revisionsNextCursor":null}"""
        var getCalls = 0
        val exchange = ScriptExchange(
            receiptFor = { command, _ ->
                when (command) {
                    "personalization.get" -> if (++getCalls == 1) {
                        "op:v1:pget1"
                    } else {
                        "op:v1:pget2"
                    }
                    "personalization.save" -> "op:v1:psave"
                    else -> "op:v1:x"
                }
            },
            effectFor = { receipt, correlation ->
                when (receipt) {
                    "op:v1:pget1" -> completedEffect(correlation, receipt, get1)
                    "op:v1:pget2" -> completedEffect(correlation, receipt, get2)
                    "op:v1:psave" -> rejectedEffect(correlation, receipt, "staleRevision")
                    else -> null
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("settingsPersonalization", true, emptyList())

        host.settings.refreshPersonalization("soul")
        kotlinx.coroutines.delay(200)
        // latestRevision is MAX(history)=5, but the ACTIVE row is revision 2.
        assertEquals(2, host.settings.state.value.personalization.activeRevision)
        assertEquals(5, host.settings.state.value.personalization.latestRevision)

        // A newer refresh moves the active slot to 9.
        host.settings.refreshPersonalization("soul")
        kotlinx.coroutines.delay(200)
        assertEquals(9, host.settings.state.value.personalization.activeRevision)

        // Saving a draft written on revision 2 must send the FROZEN base
        // token, never the newer one currently in the surface.
        var saveOutcome: String? = "unset"
        host.settings.savePersonalization("soul", "my draft", "tok:act:2") {
            saveOutcome = it
        }
        kotlinx.coroutines.delay(200)
        assertEquals("staleRevision", saveOutcome)
        assertEquals("staleRevision", host.settings.state.value.personalization.saveError)
        val saveEnvelope = exchange.envelopes("personalization.save").single()
        val revision = saveEnvelope["revision"] as JsonObject
        assertEquals("personalization.soul", (revision["resourceID"] as JsonPrimitive).content)
        assertEquals("tok:act:2", (revision["version"] as JsonPrimitive).content)

        // Old-kind draft cannot be saved into the new kind.
        var kindOutcome: String? = "unset"
        host.settings.savePersonalization("userProfile", "x", "tok:act:9") {
            kindOutcome = it
        }
        assertEquals("kindChanged", kindOutcome)
        assertEquals(1, exchange.envelopes("personalization.save").size)

        // A blank base is refused locally (never sent as a blank CAS).
        var blankOutcome: String? = "unset"
        host.settings.savePersonalization("soul", "x", "") { blankOutcome = it }
        assertEquals("noBaseRevision", blankOutcome)
        assertEquals(1, exchange.envelopes("personalization.save").size)
    }

    // ------------------------------------ late mutation-result ownership
    //
    // These tests hold a real operation's effect terminal until AFTER the
    // user has replaced the owning editor/view/selection, then deliver it.
    // The service-owned write and the data refresh must still happen; only
    // the stale UI publication is suppressed.

    @Test
    fun lateMemoryEditorSaveCannotCloseAFresherEditorAndKeepsItsWrite() = runBlocking {
        val entryA = memoryEntry("mA", "Alpha", "dig:a")
        val entryB = memoryEntry("mB", "Beta", "dig:b")
        val gate = java.util.concurrent.CountDownLatch(1)
        var getCalls = 0
        var listCalls = 0
        val exchange = ScriptExchange(
            receiptFor = { command, _ ->
                when (command) {
                    "memory.get" -> if (++getCalls == 1) "op:v1:getA" else "op:v1:getB"
                    "memory.update" -> "op:v1:updA"
                    "memory.list" -> "op:v1:list${++listCalls}"
                    else -> "op:v1:x"
                }
            },
            effectFor = { receipt, correlation ->
                when {
                    receipt == "op:v1:getA" -> completedEffect(correlation, receipt, entryA)
                    receipt == "op:v1:getB" -> completedEffect(correlation, receipt, entryB)
                    receipt == "op:v1:updA" -> {
                        // The authorized A write settles only after B opened.
                        gate.await()
                        completedEffect(correlation, receipt, """{"id":"mA"}""")
                    }
                    receipt.startsWith("op:v1:list") -> completedEffect(
                        correlation, receipt,
                        """{"entries":[$entryA,$entryB],"nextCursor":null}""",
                    )
                    else -> null
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("settingsMemory", true, emptyList())
        host.settings.refreshMemory()
        kotlinx.coroutines.delay(200)
        host.settings.openMemoryEditor("mA")
        kotlinx.coroutines.delay(200)
        val editorA = host.settings.state.value.memoryEditor!!
        host.settings.saveMemoryEditor(editorA, "Edited A", false)
        kotlinx.coroutines.delay(200)

        // Dismiss A and open a NEW editor B while A's terminal is pending.
        host.settings.closeMemoryEditor()
        host.settings.openMemoryEditor("mB")
        kotlinx.coroutines.delay(200)
        val editorB = host.settings.state.value.memoryEditor!!
        assertEquals("mB", editorB.entry.id)
        assertTrue(editorB.generation != editorA.generation)

        gate.countDown()
        kotlinx.coroutines.delay(350)
        val after = host.settings.state.value
        // The late A Applied must not close B nor post its mutation there.
        assertEquals("mB", after.memoryEditor?.entry?.id)
        assertNull(after.memoryEditorMutation)

        // The REAL write ran with the frozen A digest, and its completion
        // still refreshed the global list (truthful data, not a swallowed
        // service effect).
        val updateEnvelope = exchange.envelopes("memory.update").single()
        assertEquals(
            "mA",
            ((updateEnvelope["payload"] as JsonObject)["id"] as JsonPrimitive).content,
        )
        assertEquals(
            "dig:a",
            ((updateEnvelope["revision"] as JsonObject)["version"] as JsonPrimitive).content,
        )
        assertTrue(exchange.envelopes("memory.list").size >= 2)
    }

    @Test
    fun lateMemoryEditorRefusalCannotPolluteAFresherEditor() = runBlocking {
        val entryA = memoryEntry("mA", "Alpha", "dig:a")
        val entryB = memoryEntry("mB", "Beta", "dig:b")
        val gate = java.util.concurrent.CountDownLatch(1)
        var getCalls = 0
        var listCalls = 0
        val exchange = ScriptExchange(
            receiptFor = { command, _ ->
                when (command) {
                    "memory.get" -> if (++getCalls == 1) "op:v1:getA" else "op:v1:getB"
                    "memory.update" -> "op:v1:updA"
                    "memory.list" -> "op:v1:list${++listCalls}"
                    else -> "op:v1:x"
                }
            },
            effectFor = { receipt, correlation ->
                when {
                    receipt == "op:v1:getA" -> completedEffect(correlation, receipt, entryA)
                    receipt == "op:v1:getB" -> completedEffect(correlation, receipt, entryB)
                    receipt == "op:v1:updA" -> {
                        gate.await()
                        rejectedEffect(correlation, receipt, "staleRevision")
                    }
                    receipt.startsWith("op:v1:list") -> completedEffect(
                        correlation, receipt,
                        """{"entries":[$entryA,$entryB],"nextCursor":null}""",
                    )
                    else -> null
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("settingsMemory", true, emptyList())
        host.settings.refreshMemory()
        kotlinx.coroutines.delay(200)
        host.settings.openMemoryEditor("mA")
        kotlinx.coroutines.delay(200)
        val editorA = host.settings.state.value.memoryEditor!!
        host.settings.saveMemoryEditor(editorA, "Edited A", false)
        kotlinx.coroutines.delay(200)
        host.settings.closeMemoryEditor()
        host.settings.openMemoryEditor("mB")
        kotlinx.coroutines.delay(200)
        gate.countDown()
        kotlinx.coroutines.delay(350)
        val after = host.settings.state.value
        // The stale typed refusal belongs to A's dismissed generation: B is
        // still open and no A error is published on it.
        assertEquals("mB", after.memoryEditor?.entry?.id)
        assertNull(after.memoryEditorMutation)
        // A refusal proves nothing was written, so no list refresh is needed.
        assertEquals(1, exchange.envelopes("memory.list").size)
    }

    @Test
    fun currentMemoryEditorMutationStaysOwnedUntilItsEditorIsReplaced() = runBlocking {
        val entryA = memoryEntry("mA", "Alpha", "dig:a")
        var updateCalls = 0
        val exchange = ScriptExchange(
            receiptFor = { command, _ ->
                when (command) {
                    "memory.get" -> "op:v1:getA"
                    "memory.update" -> if (++updateCalls == 1) {
                        "op:v1:updStale"
                    } else {
                        "op:v1:updOk"
                    }
                    "memory.list" -> "op:v1:mlist"
                    else -> "op:v1:x"
                }
            },
            effectFor = { receipt, correlation ->
                when (receipt) {
                    "op:v1:getA" -> completedEffect(correlation, receipt, entryA)
                    "op:v1:updStale" -> rejectedEffect(correlation, receipt, "staleRevision")
                    "op:v1:updOk" -> completedEffect(correlation, receipt, """{"id":"mA"}""")
                    "op:v1:mlist" -> completedEffect(
                        correlation, receipt,
                        """{"entries":[$entryA],"nextCursor":null}""",
                    )
                    else -> null
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("settingsMemory", true, emptyList())
        host.settings.refreshMemory()
        kotlinx.coroutines.delay(200)
        host.settings.openMemoryEditor("mA")
        kotlinx.coroutines.delay(200)
        val editor = host.settings.state.value.memoryEditor!!

        // A refusal while the SAME editor still owns the surface is a real
        // typed result for that editor (not swallowed by the fence).
        host.settings.saveMemoryEditor(editor, "Edited", false)
        kotlinx.coroutines.delay(250)
        val refused = host.settings.state.value
        assertEquals("mA", refused.memoryEditor?.entry?.id)
        assertEquals(
            SettingsHostController.MemoryEditorMutation(
                generation = editor.generation,
                operation = SettingsHostController.MemoryEditorOperation.Save,
                outcome = SettingsHostController.MemoryMutationOutcome.Refused("staleRevision"),
            ),
            refused.memoryEditorMutation,
        )

        // The owned success closes exactly this editor.
        host.settings.saveMemoryEditor(editor, "Edited", false)
        kotlinx.coroutines.delay(250)
        assertNull(host.settings.state.value.memoryEditor)
        assertNull(host.settings.state.value.memoryEditorMutation)
        assertEquals(2, exchange.envelopes("memory.update").size)
    }

    @Test
    fun addMemoryDialogFencesLateResultsAndGuardsDoubleSubmit() = runBlocking {
        val gate = java.util.concurrent.CountDownLatch(1)
        var addCalls = 0
        var listCalls = 0
        val exchange = ScriptExchange(
            receiptFor = { command, _ ->
                when (command) {
                    "memory.add" -> if (++addCalls == 1) "op:v1:addA" else "op:v1:addB"
                    "memory.list" -> "op:v1:mlist${++listCalls}"
                    else -> "op:v1:x"
                }
            },
            effectFor = { receipt, correlation ->
                when {
                    receipt == "op:v1:addA" -> {
                        gate.await()
                        failedEffect(correlation, receipt, "transportLost")
                    }
                    receipt == "op:v1:addB" ->
                        completedEffect(correlation, receipt, """{"id":"mNew"}""")
                    receipt.startsWith("op:v1:mlist") -> completedEffect(
                        correlation, receipt, """{"entries":[],"nextCursor":null}""",
                    )
                    else -> null
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("settingsMemory", true, emptyList())

        host.settings.openAddMemory()
        val generationA = host.settings.state.value.memoryAdd.generation
        host.settings.submitAddMemory("Alpha", "user")
        kotlinx.coroutines.delay(200)
        // A second submit while the same dialog is in flight is ignored.
        host.settings.submitAddMemory("Alpha", "user")
        kotlinx.coroutines.delay(150)
        assertEquals(1, exchange.envelopes("memory.add").size)
        assertTrue(host.settings.state.value.memoryAdd.inFlight)

        // Cancel A and open a NEW add dialog B; then A's transport failure
        // arrives. It must neither close nor fill B.
        host.settings.dismissAddMemory()
        host.settings.openAddMemory()
        val generationB = host.settings.state.value.memoryAdd.generation
        assertTrue(generationB > generationA)
        gate.countDown()
        kotlinx.coroutines.delay(350)
        val afterLate = host.settings.state.value.memoryAdd
        assertTrue(afterLate.open)
        assertEquals(generationB, afterLate.generation)
        assertFalse(afterLate.inFlight)
        assertNull(afterLate.failure)

        // B's own completed add closes the dialog with the original grammar.
        host.settings.submitAddMemory("Beta", "user")
        kotlinx.coroutines.delay(250)
        assertFalse(host.settings.state.value.memoryAdd.open)
        val envelopes = exchange.envelopes("memory.add")
        assertEquals(2, envelopes.size)
        val payload = envelopes[1]["payload"] as JsonObject
        assertEquals("Beta", (payload["content"] as JsonPrimitive).content)
        assertEquals(
            "user",
            ((payload["scope"] as JsonObject)["kind"] as JsonPrimitive).content,
        )
        assertTrue((envelopes[1]["stateful"] as JsonPrimitive).booleanOrNull == true)
        assertTrue((envelopes[1]["createIntent"] as JsonPrimitive).booleanOrNull == true)
    }

    @Test
    fun currentAddFailureKeepsTheDraftAndItsTypedOutcome() = runBlocking {
        var addCalls = 0
        var listCalls = 0
        val exchange = ScriptExchange(
            receiptFor = { command, _ ->
                when (command) {
                    "memory.add" -> "op:v1:add${++addCalls}"
                    "memory.list" -> "op:v1:mlist${++listCalls}"
                    else -> "op:v1:x"
                }
            },
            effectFor = { receipt, correlation ->
                when {
                    receipt == "op:v1:add1" ->
                        rejectedEffect(correlation, receipt, "duplicateMemory")
                    receipt == "op:v1:add2" ->
                        failedEffect(correlation, receipt, "transportLost")
                    receipt == "op:v1:add3" ->
                        completedEffect(correlation, receipt, """{"id":"mNew"}""")
                    receipt.startsWith("op:v1:mlist") -> completedEffect(
                        correlation, receipt, """{"entries":[],"nextCursor":null}""",
                    )
                    else -> null
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("settingsMemory", true, emptyList())

        host.settings.openAddMemory()
        host.settings.submitAddMemory("Alpha", "user")
        kotlinx.coroutines.delay(250)
        val refused = host.settings.state.value.memoryAdd
        assertTrue(refused.open)
        assertFalse(refused.inFlight)
        assertEquals(
            SettingsHostController.MemoryMutationOutcome.Refused("duplicateMemory"),
            refused.failure,
        )
        // The draft stays recoverable; nothing is claimed as written.
        assertEquals(0, exchange.envelopes("memory.list").size)

        // An unconfirmed transport result is NOT reported as a refusal.
        host.settings.submitAddMemory("Alpha", "user")
        kotlinx.coroutines.delay(250)
        val unconfirmed = host.settings.state.value.memoryAdd
        assertTrue(unconfirmed.open)
        assertEquals(
            SettingsHostController.MemoryMutationOutcome.Unconfirmed("transportLost"),
            unconfirmed.failure,
        )
        // An unconfirmed add still reads the REAL list so the user can
        // check whether it landed; the typed outcome stays honest.
        assertTrue(exchange.envelopes("memory.list").isNotEmpty())

        host.settings.submitAddMemory("Alpha", "user")
        kotlinx.coroutines.delay(250)
        assertFalse(host.settings.state.value.memoryAdd.open)
        assertNull(host.settings.state.value.memoryAdd.failure)
    }

    @Test
    fun latePersonalizationSaveCannotRetargetANewerKindView() = runBlocking {
        val soulDoc = personalizationDoc(
            kind = "soul", revision = 2, content = "soul body", token = "tok:soul",
        )
        val profileDoc = personalizationDoc(
            kind = "userProfile", revision = 5, content = "profile body",
            token = "tok:profile",
        )
        val getReplies = java.util.concurrent.ConcurrentLinkedQueue<String>()
        val saveGate = java.util.concurrent.CountDownLatch(1)
        var getCalls = 0
        val exchange = ScriptExchange(
            receiptFor = { command, _ ->
                when (command) {
                    "personalization.get" -> "op:v1:pget${++getCalls}"
                    "personalization.save" -> "op:v1:psave"
                    else -> "op:v1:x"
                }
            },
            effectFor = { receipt, correlation ->
                when {
                    receipt.startsWith("op:v1:pget") -> completedEffect(
                        correlation, receipt, getReplies.poll() ?: soulDoc,
                    )
                    receipt == "op:v1:psave" -> {
                        saveGate.await()
                        completedEffect(correlation, receipt, """{"result":"applied"}""")
                    }
                    else -> null
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("settingsPersonalization", true, emptyList())

        getReplies.add(soulDoc)
        host.settings.refreshPersonalization("soul")
        kotlinx.coroutines.delay(250)
        assertEquals("tok:soul", host.settings.state.value.personalization.revisionToken)

        // Save A is dispatched for soul, then the user switches to profile.
        var saveOutcome: String? = "unset"
        host.settings.savePersonalization("soul", "draft A", "tok:soul") {
            saveOutcome = it
        }
        kotlinx.coroutines.delay(200)
        getReplies.add(profileDoc)
        host.settings.refreshPersonalization("userProfile")
        kotlinx.coroutines.delay(300)
        val profile = host.settings.state.value.personalization
        assertEquals("userProfile", profile.kind)
        assertEquals("profile body", profile.content)
        assertEquals("tok:profile", profile.revisionToken)

        saveGate.countDown()
        kotlinx.coroutines.delay(350)
        val after = host.settings.state.value.personalization
        // The late A success must not switch the surface back to soul.
        assertEquals("userProfile", after.kind)
        assertEquals("profile body", after.content)
        assertEquals("tok:profile", after.revisionToken)
        assertNull(after.saveError)
        assertEquals("staleOwner", saveOutcome)
        // ... and its refresh must not be issued.
        assertEquals(2, exchange.envelopes("personalization.get").size)
        val saveEnvelope = exchange.envelopes("personalization.save").single()
        assertEquals(
            "personalization.soul",
            ((saveEnvelope["revision"] as JsonObject)["resourceID"] as JsonPrimitive).content,
        )
        assertEquals(
            "tok:soul",
            ((saveEnvelope["revision"] as JsonObject)["version"] as JsonPrimitive).content,
        )
    }

    @Test
    fun latePersonalizationRefusalCannotPolluteAnAbaView() = runBlocking {
        val soulDoc = personalizationDoc(
            kind = "soul", revision = 2, content = "soul body", token = "tok:soul",
        )
        val profileDoc = personalizationDoc(
            kind = "userProfile", revision = 5, content = "profile body",
            token = "tok:profile",
        )
        val soulAgain = personalizationDoc(
            kind = "soul", revision = 3, content = "soul again", token = "tok:soul:3",
        )
        val soulSaved = personalizationDoc(
            kind = "soul", revision = 4, content = "soul saved", token = "tok:soul:4",
        )
        val getReplies = java.util.concurrent.ConcurrentLinkedQueue<String>()
        val savePermits = java.util.concurrent.Semaphore(0)
        var getCalls = 0
        var saveCalls = 0
        val exchange = ScriptExchange(
            receiptFor = { command, _ ->
                when (command) {
                    "personalization.get" -> "op:v1:pget${++getCalls}"
                    "personalization.save" -> "op:v1:psave${++saveCalls}"
                    else -> "op:v1:x"
                }
            },
            effectFor = { receipt, correlation ->
                when {
                    receipt.startsWith("op:v1:pget") -> completedEffect(
                        correlation, receipt, getReplies.poll() ?: soulDoc,
                    )
                    receipt == "op:v1:psave1" -> {
                        savePermits.acquire()
                        rejectedEffect(correlation, receipt, "staleRevision")
                    }
                    receipt == "op:v1:psave2" -> {
                        savePermits.acquire()
                        completedEffect(correlation, receipt, """{"result":"applied"}""")
                    }
                    else -> null
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("settingsPersonalization", true, emptyList())

        getReplies.add(soulDoc)
        host.settings.refreshPersonalization("soul")
        kotlinx.coroutines.delay(250)
        var saveOutcome: String? = "unset"
        host.settings.savePersonalization("soul", "draft A", "tok:soul") {
            saveOutcome = it
        }
        kotlinx.coroutines.delay(200)

        // Switch to profile and BACK to soul (ABA): this is a NEW soul view.
        getReplies.add(profileDoc)
        host.settings.refreshPersonalization("userProfile")
        kotlinx.coroutines.delay(250)
        getReplies.add(soulAgain)
        host.settings.refreshPersonalization("soul")
        kotlinx.coroutines.delay(300)
        val reentered = host.settings.state.value.personalization
        assertEquals("soul", reentered.kind)
        assertEquals("soul again", reentered.content)
        assertEquals("tok:soul:3", reentered.revisionToken)

        savePermits.release()
        kotlinx.coroutines.delay(350)
        val afterStale = host.settings.state.value.personalization
        // The old refusal is not written into the ABA-returned view.
        assertEquals("soul", afterStale.kind)
        assertEquals("soul again", afterStale.content)
        assertEquals("tok:soul:3", afterStale.revisionToken)
        assertNull(afterStale.saveError)
        assertEquals("staleOwner", saveOutcome)

        // A save that still owns the current view behaves normally.
        getReplies.add(soulSaved)
        var currentOutcome: String? = "unset"
        host.settings.savePersonalization("soul", "new draft", "tok:soul:3") {
            currentOutcome = it
        }
        savePermits.release()
        kotlinx.coroutines.delay(400)
        val saved = host.settings.state.value.personalization
        assertNull(currentOutcome)
        assertNull(saved.saveError)
        assertEquals("soul", saved.kind)
        assertEquals("soul saved", saved.content)
        assertEquals("tok:soul:4", saved.revisionToken)
        assertEquals(4, exchange.envelopes("personalization.get").size)
    }

    @Test
    fun latePersonalizationAutomaticFailureStaysOutOfANewerKindView() = runBlocking {
        val soulDoc = personalizationDoc(
            kind = "soul", revision = 2, content = "soul body", token = "tok:soul",
        )
        val profileDoc = personalizationDoc(
            kind = "userProfile", revision = 5, content = "profile body",
            token = "tok:profile",
        )
        val getReplies = java.util.concurrent.ConcurrentLinkedQueue<String>()
        val gate = java.util.concurrent.CountDownLatch(1)
        var getCalls = 0
        val exchange = ScriptExchange(
            receiptFor = { command, _ ->
                when (command) {
                    "personalization.get" -> "op:v1:pget${++getCalls}"
                    "personalization.automatic.set" -> "op:v1:pauto"
                    else -> "op:v1:x"
                }
            },
            effectFor = { receipt, correlation ->
                when {
                    receipt.startsWith("op:v1:pget") -> completedEffect(
                        correlation, receipt, getReplies.poll() ?: soulDoc,
                    )
                    receipt == "op:v1:pauto" -> {
                        gate.await()
                        failedEffect(correlation, receipt, "transportLost")
                    }
                    else -> null
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("settingsPersonalization", true, emptyList())
        getReplies.add(soulDoc)
        host.settings.refreshPersonalization("soul")
        kotlinx.coroutines.delay(250)

        var autoOutcome: String? = "unset"
        host.settings.setPersonalizationAutomatic("soul", true) { autoOutcome = it }
        kotlinx.coroutines.delay(200)
        getReplies.add(profileDoc)
        host.settings.refreshPersonalization("userProfile")
        kotlinx.coroutines.delay(300)
        gate.countDown()
        kotlinx.coroutines.delay(350)
        val after = host.settings.state.value.personalization
        assertEquals("userProfile", after.kind)
        assertEquals("tok:profile", after.revisionToken)
        assertNull(after.saveError)
        assertEquals("staleOwner", autoOutcome)
        val envelope = exchange.envelopes("personalization.automatic.set").single()
        assertEquals(
            "personalization.cursor.soul",
            ((envelope["revision"] as JsonObject)["resourceID"] as JsonPrimitive).content,
        )
        assertEquals(
            "soul",
            ((envelope["payload"] as JsonObject)["kind"] as JsonPrimitive).content,
        )
    }

    @Test
    fun lateRollbackFailureCannotClearANewerRollbackFlag() = runBlocking {
        val soulDoc = personalizationDoc(
            kind = "soul", revision = 2, content = "soul body", token = "tok:soul",
        )
        val profileDoc = personalizationDoc(
            kind = "userProfile", revision = 5, content = "profile body",
            token = "tok:profile",
        )
        val profileAgain = personalizationDoc(
            kind = "userProfile", revision = 2, content = "profile old",
            token = "tok:profile:2",
        )
        val getReplies = java.util.concurrent.ConcurrentLinkedQueue<String>()
        val gateA = java.util.concurrent.CountDownLatch(1)
        val gateB = java.util.concurrent.CountDownLatch(1)
        var getCalls = 0
        var rollCalls = 0
        val exchange = ScriptExchange(
            receiptFor = { command, _ ->
                when (command) {
                    "personalization.get" -> "op:v1:pget${++getCalls}"
                    "personalization.rollback" -> "op:v1:proll${++rollCalls}"
                    else -> "op:v1:x"
                }
            },
            effectFor = { receipt, correlation ->
                when {
                    receipt.startsWith("op:v1:pget") -> completedEffect(
                        correlation, receipt, getReplies.poll() ?: profileDoc,
                    )
                    receipt == "op:v1:proll1" -> {
                        gateA.await()
                        failedEffect(correlation, receipt, "transportLost")
                    }
                    receipt == "op:v1:proll2" -> {
                        gateB.await()
                        completedEffect(correlation, receipt, """{"revisionToken":"tok:profile:2"}""")
                    }
                    else -> null
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("settingsPersonalization", true, emptyList())
        getReplies.add(soulDoc)
        host.settings.refreshPersonalization("soul")
        kotlinx.coroutines.delay(250)

        var firstOutcome: String? = "unset"
        host.settings.rollbackPersonalization("soul", 1) { firstOutcome = it }
        kotlinx.coroutines.delay(200)
        getReplies.add(profileDoc)
        host.settings.refreshPersonalization("userProfile")
        kotlinx.coroutines.delay(300)
        var secondOutcome: String? = "unset"
        host.settings.rollbackPersonalization("userProfile", 2) { secondOutcome = it }
        kotlinx.coroutines.delay(200)
        assertTrue(host.settings.state.value.personalization.rollingBack)

        // The older rollback's failure must not clear the NEWER rollback's
        // in-flight flag nor write its error into this view.
        gateA.countDown()
        kotlinx.coroutines.delay(300)
        val afterStale = host.settings.state.value.personalization
        assertTrue(afterStale.rollingBack)
        assertNull(afterStale.rollbackError)
        assertEquals("staleOwner", firstOutcome)

        getReplies.add(profileAgain)
        gateB.countDown()
        kotlinx.coroutines.delay(400)
        val afterOwned = host.settings.state.value.personalization
        assertEquals("userProfile", afterOwned.kind)
        assertNull(secondOutcome)
        assertFalse(afterOwned.rollingBack)
        assertNull(afterOwned.rollbackError)
    }

    @Test
    fun lateBulkDeleteTerminalCannotRewriteANewerSelection() = runBlocking {
        val entry1 = memoryEntry("m1", "One", "dig:1")
        val entry2 = memoryEntry("m2", "Two", "dig:2")
        val gate = java.util.concurrent.CountDownLatch(1)
        var bulkCalls = 0
        var listCalls = 0
        val exchange = ScriptExchange(
            receiptFor = { command, _ ->
                when (command) {
                    "memory.list" -> "op:v1:list${++listCalls}"
                    "memory.delete.bulk" -> "op:v1:bulk${++bulkCalls}"
                    else -> "op:v1:x"
                }
            },
            effectFor = { receipt, correlation ->
                when {
                    receipt.startsWith("op:v1:list") -> completedEffect(
                        correlation, receipt,
                        """{"entries":[$entry1,$entry2],"nextCursor":null}""",
                    )
                    receipt == "op:v1:bulk1" -> {
                        gate.await()
                        completedEffect(
                            correlation, receipt,
                            """{"batchID":"same","result":"applied","deletedCount":2,""" +
                                """"replacedCount":0,"appliedCount":2}""",
                        )
                    }
                    receipt == "op:v1:bulk2" -> failedEffect(correlation, receipt, "transportLost")
                    else -> null
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("settingsMemory", true, emptyList())
        host.settings.refreshMemory()
        kotlinx.coroutines.delay(200)

        val intent = (host.settings.prepareMemoryBulkDelete(
            listOf("m1" to "dig:1", "m2" to "dig:2"),
        ) as SettingsHostController.MemoryBulkDeletePreparation.Ready).intent
        var first: SettingsHostController.MemoryMutationOutcome? = null
        val interactionA = host.settings.beginMemoryBulkInteraction()
        host.settings.bulkDeleteMemory(intent, interactionA) { first = it }
        kotlinx.coroutines.delay(200)

        // A new selection/interaction supersedes A; A's Applied then settles.
        val interactionB = host.settings.beginMemoryBulkInteraction()
        gate.countDown()
        kotlinx.coroutines.delay(350)
        assertNull(first)
        // The service-owned write still refreshed the real list.
        assertTrue(exchange.envelopes("memory.list").size >= 2)

        // The newer interaction's own terminal is delivered normally.
        var second: SettingsHostController.MemoryMutationOutcome? = null
        host.settings.bulkDeleteMemory(intent, interactionB) { second = it }
        kotlinx.coroutines.delay(300)
        assertEquals(
            SettingsHostController.MemoryMutationOutcome.Unconfirmed("transportLost"),
            second,
        )
    }

    /** One `personalization.get` reply with inline active content. */
    private fun personalizationDoc(
        kind: String,
        revision: Int,
        content: String,
        token: String,
    ): String =
        """{"active":{"id":"d$revision","kind":"$kind","workspaceID":null,""" +
            """"revision":$revision,"source":"manual","evidenceDigest":"e$revision",""" +
            """"isActive":true,"createdAt":"2026-10-21T00:00:0${revision % 10}Z",""" +
            """"contentBytes":${content.length},"contentDigest":"c$revision",""" +
            """"content":"$content","contentHandle":null},""" +
            """"latestRevision":$revision,"revisionsMeta":[],""" +
            """"cursor":{"automaticUpdatesEnabled":false},""" +
            """"revisionToken":"$token","revisionsNextCursor":null}"""
}
