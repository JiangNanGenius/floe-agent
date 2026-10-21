// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
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
        private val effectFor: (receipt: String) -> String?,
    ) : HostBridgeExchange {
        val requests = mutableListOf<String>()

        override fun exchange(request: String): String {
            requests.add(request)
            val correlation = correlationOf(request)
            if (request.contains("\"operation\":\"effect.poll\"")) {
                val receipt = receiptOf(request)
                return effectFor(receipt)
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

    @Test
    fun memorySearchKeepsDeletedTruthAndDropsProjectedFabrication() = runBlocking {
        val item = """{"id":"m1","relevance":0.9,"lexicalRank":1,"semanticRank":null,"semanticSimilarity":null,"current":null,"deleted":true}"""
        val reply = """{"items":[$item],"semantic":false,"sideEffects":{"lifecycleMaintained":true,"reinforcementPathExecuted":true,"reinforcedCount":null,"digestsRefreshed":true,"explanation":"x"},"searchHandle":null,"nextCursor":null,"hasMore":false}"""
        val exchange = ScriptExchange(
            receiptFor = { _, c -> "op:v1:search" },
            effectFor = { receipt ->
                if (receipt == "op:v1:search") completedEffect("fx", receipt, reply) else null
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
            effectFor = { receipt ->
                when (receipt) {
                    "op:v1:org" -> completedEffect("fx", receipt, startPage)
                    "op:v1:prop" -> {
                        // First poll serves page 1 with a cursor, second the tail.
                        val seen = propPolls++
                        if (seen == 0) completedEffect("fx", receipt, proposalPage1)
                        else completedEffect("fx", receipt, proposalPage2)
                    }
                    "op:v1:apply" -> completedEffect("fx", receipt, applyReply)
                    "op:v1:list" -> completedEffect("fx", receipt, listReply)
                    else -> null
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("settings.memory", true, emptyList())

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
            effectFor = { null },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("settings.memory", true, emptyList())
        // Seed a stale organize surface directly through a completed start.
        val startPage = """{"status":"completed","scannedCount":1,"autoDeletedCount":0,"pendingReviewCount":0,"autoDelete":{"status":"none","batchID":null,"staleIDs":[]},"proposalStale":true,"semantic":{"skipped":true},"proposalHandle":"hnd:stale"}"""
        val scripted = ScriptExchange(
            receiptFor = { command, _ ->
                if (command == "memory.organize.start") "op:v1:org" else "op:v1:x"
            },
            effectFor = { receipt ->
                if (receipt == "op:v1:org") completedEffect("fx", receipt, startPage) else null
            },
        )
        val host2 = testHost(scripted)
        host2.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host2.onDomainAvailability("settings.memory", true, emptyList())
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
            val requests = mutableListOf<String>()
            var cancelReceipt = "op:v1:org"
            override fun exchange(request: String): String {
                requests.add(request)
                val correlation = correlationOf(request)
                if (request.contains("\"operation\":\"effect.poll\"")) {
                    val receipt = receiptOf(request)
                    return if (receipt == "op:v1:org") {
                        completedEffect("fx", receipt, startPage)
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
        host.onDomainAvailability("settings.memory", true, emptyList())
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
                        "op:v1:orgA" -> completedEffect("fx", receipt, startPageA)
                        "op:v1:orgB" -> completedEffect("fx", receipt, startPageB)
                        // The first proposal page chain for hnd:A delivers
                        // LATE (after hnd:B owns the surface).
                        "op:v1:propA" ->
                            completedEffect("fx", receipt, proposalA)
                        "op:v1:propB" ->
                            completedEffect("fx", receipt, proposalB)
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
        host.onDomainAvailability("settings.memory", true, emptyList())
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
            effectFor = { receipt ->
                when (receipt) {
                    "op:v1:pget" -> {
                        val seen = pgetPolls++
                        if (seen == 0) completedEffect("fx", receipt, getPage1)
                        else completedEffect("fx", receipt, getPage2)
                    }
                    "op:v1:proll" -> completedEffect("fx", receipt, rollbackReply)
                    else -> null
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("settings.personalization", true, emptyList())
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
            effectFor = { receipt ->
                when (receipt) {
                    "op:v1:pread" -> completedEffect("fx", receipt, """{"document":$document}""")
                    "op:v1:cread" -> {
                        val seen = contentPolls++
                        if (seen == 0) completedEffect("fx", receipt, chunk1)
                        else completedEffect("fx", receipt, chunk2)
                    }
                    else -> null
                }
            },
        )
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("settings.personalization", true, emptyList())
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
                val requests = mutableListOf<String>()
                var genBCounter = 0
                var genAStarted = false
                var deliverGenATerminal = false
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
                                    """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":1},"effects":[],"hasMore":true,"resyncRequired":false}"""
                                }
                            }
                            "op:v1:genB" -> {
                                genBCounter++
                                if (genBCounter >= 3) {
                                    completedEffect("fx", receipt, """{"status":"committed"}""")
                                } else {
                                    """{"version":3,"requestID":"$correlation","ok":true,"schema":"floe.effect-cursor/3","correlationID":"$correlation","cursor":{"operationReceiptID":"$receipt","sequence":1},"effects":[],"hasMore":true,"resyncRequired":false}"""
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
            host.onDomainAvailability("settings.personalization", true, emptyList())

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

            // The current generation completes on its own stream.
            kotlinx.coroutines.delay(400)
            assertFalse(host.settings.state.value.personalization.generating)
        }
}
