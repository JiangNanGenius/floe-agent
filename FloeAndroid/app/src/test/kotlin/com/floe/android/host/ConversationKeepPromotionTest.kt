// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.design.SidebarSelection
import com.floe.android.design.WorkbenchSelection
import com.floe.android.feature.conversation.ConversationFlowHolder
import com.floe.android.feature.conversation.ConversationFlowResult
import com.floe.android.feature.conversation.ConversationRejectedReason
import com.floe.android.feature.conversation.TemporaryKeepStateUi
import com.floe.android.feature.conversation.TemporarySessionRef
import com.floe.android.keptPromotionAppliesToVisibleOrigin
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The actual Keep lifecycle on the App side: a REAL committed `temp.keep`
 * receipt (Core promotes the SAME hosted id durably and returns that
 * identity in the receipt value) must be ADOPTED into the ordinary durable
 * projection for the exact bound identity BEFORE the holder's promoted
 * guard is exercised, and the UI must acknowledge the promotion (header
 * leaves Temporary, keep state returns to Idle). The same-id promotion
 * publishes the SCOPED adoption signal (never a generic navigationRequest),
 * and a LATE committed terminal — arriving after genuine leave, a new
 * temporary or a rebind under the same logical id — may only refresh
 * durable history: it never navigates an old id, adopts a replacement
 * surface or lets the shell fence-end a newly visible session (Main's
 * late-Keep ownership decision). A receipt without the durable identity is
 * an honest visible failure, never a silent forever-waiting Saving.
 */
class ConversationKeepPromotionTest {

    /** temp.start / temp.keep / conversation.get with the real receipt
     * shapes; every other command settles as a typed-harmless page. */
    private class KeepExchange : HostBridgeExchange {
        val requests = CopyOnWriteArrayList<String>()
        var keepRequests = 0
        var keepValue = "\"keep\":\"committed\",\"conversationID\":\"tc1\""
        var startConversationID = "tc1"
        var startIncarnation = "inc-1"
        var keepGate: CountDownLatch? = null

        override fun exchange(request: String): String {
            requests.add(request)
            val correlation = correlationOf(request)
            return when {
                request.contains("\"operation\":\"effect.poll\"") ->
                    when (receiptOf(request)) {
                        START_RECEIPT -> acceptedPage(
                            correlation, START_RECEIPT,
                            """{"conversationID":"$startConversationID",""" +
                                """"incarnation":"$startIncarnation","rootEpoch":1}""",
                        )
                        KEEP_RECEIPT -> {
                            keepGate?.await(5, TimeUnit.SECONDS)
                            acceptedPage(correlation, KEEP_RECEIPT, "{$keepValue}")
                        }
                        CGET_RECEIPT -> acceptedPage(
                            correlation, CGET_RECEIPT,
                            """{"conversationID":"tc1","title":"Task",""" +
                                """"revision":{"resourceID":"conversation.tc1","version":"v1"},""" +
                                """"runs":[],"pendingInputs":[]}""",
                        )
                        else -> if (receiptOf(request).startsWith("$KEEP_RECEIPT-")) {
                            keepGate?.await(5, TimeUnit.SECONDS)
                            acceptedPage(correlation, receiptOf(request), "{$keepValue}")
                        } else {
                            acceptedPage(
                                correlation, receiptOf(request), """{"session":"ended"}""",
                            )
                        }
                    }
                request.contains("\"command\":\"temp.start\"") ->
                    queued(correlation, START_RECEIPT)
                request.contains("\"command\":\"temp.keep\"") -> {
                    keepRequests += 1
                    queued(correlation, if (keepRequests == 1) KEEP_RECEIPT else "$KEEP_RECEIPT-$keepRequests")
                }
                request.contains("\"command\":\"conversation.get\"") ->
                    queued(correlation, CGET_RECEIPT)
                else -> queued(correlation, "op:v1:other")
            }
        }

        private fun queued(correlation: String, receipt: String) =
            """{"version":3,"ok":true,"queued":true,""" +
                """"correlationID":"$correlation","operationReceiptID":"$receipt"}"""

        private fun acceptedPage(correlation: String, receipt: String, value: String) =
            """{"version":3,"requestID":"$correlation","ok":true,""" +
                """"schema":"floe.effect-cursor/3","correlationID":"$correlation",""" +
                """"cursor":{"operationReceiptID":"$receipt","sequence":1},""" +
                """"effects":[{"sequence":1,"kind":"accepted","value":$value}],""" +
                """"hasMore":false,"resyncRequired":false}"""

        fun keepEnvelopes(): List<String> =
            requests.filter { it.contains("\"command\":\"temp.keep\"") }

        fun historyListRequests(): Int =
            requests.count { it.contains("\"command\":\"conversation.list\"") }

        companion object {
            const val START_RECEIPT = "op:v1:tstart"
            const val KEEP_RECEIPT = "op:v1:tkeep"
            const val CGET_RECEIPT = "op:v1:cget"
        }
    }

    private fun testHost(exchange: HostBridgeExchange): RuntimeHost = RuntimeHost(
        commandClient = RuntimeHostCommandClient(
            exchange = exchange,
            scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default),
            ioDispatcher = kotlinx.coroutines.Dispatchers.Default,
            budgets = HostWireBudgets(effectPollIntervalMillis = 1),
        ),
        gatewayCapability = kotlinx.coroutines.flow.MutableStateFlow(
            com.floe.android.SecretGatewayCapability.Loading),
        bootstrapCapability = kotlinx.coroutines.flow.MutableStateFlow(
            com.floe.android.RuntimeBootstrapCapability.Idle),
        scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default),
        ioDispatcher = kotlinx.coroutines.Dispatchers.Default,
    )

    private fun readyHost(exchange: KeepExchange): RuntimeHost {
        val host = testHost(exchange)
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("temporaryDomain", true, emptyList())
        host.onDomainAvailability("conversationDomain", true, emptyList())
        host.onDomainAvailability("runDomain", true, emptyList())
        return host
    }

    /** Starts the RAM temporary exactly like the shell does, then binds the
     * surface the way ConversationDestination does: the live-temporary
     * identity is re-asserted through holderFor and the thread is loaded
     * through the ordinary host read path (fresh empty session = no draft). */
    private suspend fun boundTemporarySurface(
        host: RuntimeHost,
        conversationId: String = "tc1",
        incarnationId: String = "inc-1",
    ): Pair<ConversationFlowHolder, TemporarySessionRef> {
        var started: TemporarySessionRef? = null
        var failure: String? = null
        assertTrue(
            host.conversations.startTemporarySession(
                draft = "",
                preferredModelID = null,
                onStarted = { started = it },
                onFailure = { failure = it },
            ),
        )
        assertTrue("temp.start failed: $failure", awaitUntil { started != null })
        val ref = started!!
        val holder = host.conversations.holderFor(
            conversationId = conversationId,
            isTemporary = true,
            incarnationId = incarnationId,
            temporaryNativeRootEpoch = ref.nativeRootEpoch,
        )
        host.conversations.loadThread(holder.session)
        assertTrue("surface projection never arrived", awaitUntil { holder.snapshot.value != null })
        return holder to ref
    }

    @Test
    fun committedKeepAdoptsPromotedProjectionAndPublishesScopedAdoption() = runBlocking {
        val exchange = KeepExchange()
        val host = readyHost(exchange)
        val (holder, _) = boundTemporarySurface(host)

        // Pre-Keep truth: the surface is a live temporary with the exact
        // bound incarnation, and no promoted identity exists yet.
        assertTrue(holder.snapshot.value!!.isTemporary)
        assertEquals("inc-1", holder.snapshot.value!!.temporaryIncarnationId)
        assertNull(holder.snapshot.value!!.promotedConversationId)

        // The badge menu's Keep click (real holder entry point).
        assertEquals(ConversationFlowResult.Accepted, holder.keepTemporaryChat())

        // The same-id promotion arrives as the SCOPED adoption signal;
        // there is deliberately NO generic navigationRequest for the kept
        // surface (the shell persists the durable saved key only while the
        // exact origin surface is current).
        assertTrue(awaitUntil { host.conversations.keptPromotion.value != null })
        val promotion = host.conversations.keptPromotion.value!!
        assertEquals("tc1", promotion.durableConversationId)
        assertNull(host.conversations.navigationRequest.value)
        assertEquals(1, exchange.keepRequests)
        // The Keep carried the EXACT bound CAS revision, not a guess.
        val keepEnvelope = exchange.keepEnvelopes().single()
        assertTrue(keepEnvelope.contains("\"session.tc1\""))
        assertTrue(keepEnvelope.contains("\"inc-1\""))

        // The promoted projection was ADOPTED from the receipt's real
        // identity and the holder acknowledged through its guard: the
        // surface leaves Temporary with no error and no stuck Saving.
        val promoted = holder.snapshot.value!!
        assertFalse(promoted.isTemporary)
        assertNull(promoted.temporaryIncarnationId)
        assertEquals("tc1", promoted.promotedConversationId)
        assertEquals(TemporaryKeepStateUi.Idle, holder.temporaryKeepState)
        assertNull(host.conversations.activeTemporarySession())

        // The shell adoption predicate: the exact current origin persists
        // the durable saved selection; a replaced/leaving surface drops it.
        assertTrue(
            keptPromotionAppliesToVisibleOrigin(
                visible = SidebarSelection.Conversation("tc1"),
                visibleConversationEpoch = holder.session.sessionEpoch,
                origin = promotion.originRef,
            ),
        )
        assertFalse(
            keptPromotionAppliesToVisibleOrigin(
                visible = SidebarSelection.Workbench(WorkbenchSelection.NEW_TASK),
                visibleConversationEpoch = holder.session.sessionEpoch,
                origin = promotion.originRef,
            ),
        )
        host.conversations.keptPromotion.value = null

        // The kept same-id surface is now ordinary: a further Keep click is
        // refused as stale (NOT silently OPERATION_IN_FLIGHT — that stuck-
        // Saving state was the shipped defect) and issues no second commit.
        assertEquals(
            ConversationFlowResult.Rejected(ConversationRejectedReason.STALE),
            holder.keepTemporaryChat(),
        )
        assertEquals(1, exchange.keepRequests)

        // A post-promotion surface recreation re-asserts the durable
        // ordinary identity (the RAM registration is gone) and keeps the
        // receipt-adopted promoted truth.
        val rebound = host.conversations.holderFor(
            conversationId = "tc1", isTemporary = false, incarnationId = null,
        )
        assertSame(holder, rebound)
        host.conversations.loadThread(rebound.session)
        assertTrue(awaitUntil { rebound.snapshot.value!!.promotedConversationId == "tc1" })
        assertFalse(rebound.snapshot.value!!.isTemporary)
        host.stop()
    }

    @Test
    fun recreationKeepsBoundTemporaryIdentityThenKeepPromotesInPlace() = runBlocking {
        val exchange = KeepExchange()
        val host = readyHost(exchange)
        val (holder, _) = boundTemporarySurface(host)

        // Rotation/background/view reconstruction while the RAM session is
        // live: the shell re-asserts the SAME temporary identity. This must
        // preserve the bound incarnation the Keep guard needs (the original
        // hypothesis claimed recreation could erase it; the shipped receipt
        // showed the real blocker was the never-adopted promoted
        // projection — both are pinned here).
        val recreated = host.conversations.holderFor(
            conversationId = "tc1",
            isTemporary = true,
            incarnationId = "inc-1",
            temporaryNativeRootEpoch = 1L,
        )
        assertSame(holder, recreated)
        host.conversations.loadThread(recreated.session)
        assertTrue(awaitUntil { recreated.snapshot.value!!.isTemporary })
        assertEquals("inc-1", recreated.snapshot.value!!.temporaryIncarnationId)

        // Keep after the recreation: the same committed-receipt adoption
        // path. The real-device failure showed this case durable on Core
        // (two Untitled rows + original reply reopened after relaunch)
        // while the App surface stayed Temporary forever.
        assertEquals(ConversationFlowResult.Accepted, recreated.keepTemporaryChat())
        assertTrue(awaitUntil { recreated.snapshot.value!!.promotedConversationId == "tc1" })
        assertFalse(recreated.snapshot.value!!.isTemporary)
        assertEquals(TemporaryKeepStateUi.Idle, recreated.temporaryKeepState)
        assertNull(host.conversations.activeTemporarySession())
        // Scoped signal, not a generic navigation.
        assertNotNull(host.conversations.keptPromotion.value)
        assertNull(host.conversations.navigationRequest.value)
        host.stop()
    }

    @Test
    fun keepReceiptWithoutDurableIdentitySurfacesFailureNotSilentSaving() = runBlocking {
        val exchange = KeepExchange().apply {
            // A wire-contract violation: committed WITHOUT the durable
            // identity. The App must NOT fabricate a promotion (no new id,
            // no reuse of an old success) and must NOT wait forever.
            keepValue = "\"keep\":\"committed\""
        }
        val host = readyHost(exchange)
        val (holder, _) = boundTemporarySurface(host)
        assertEquals(ConversationFlowResult.Accepted, holder.keepTemporaryChat())

        assertTrue(
            awaitUntil {
                holder.temporaryKeepState is TemporaryKeepStateUi.Failed
            },
        )
        assertEquals(
            TemporaryKeepStateUi.Failed("keepIdentityMissing"),
            holder.temporaryKeepState,
        )
        assertNotNull(holder.actionError)
        // Temporary truth is retained until a real identity arrives; the
        // existing bilingual "Retry saving" copy is reachable and a retry
        // hits the real alreadyCommitted receipt.
        assertTrue(holder.snapshot.value!!.isTemporary)
        assertEquals("inc-1", holder.snapshot.value!!.temporaryIncarnationId)
        assertNull(holder.snapshot.value!!.promotedConversationId)
        // No navigation or adoption is invented for an unproven identity.
        assertNull(host.conversations.navigationRequest.value)
        assertNull(host.conversations.keptPromotion.value)
        assertNotNull(host.conversations.activeTemporarySession())
        // Retry consumes a fresh operation receipt for the already-committed
        // identity; it must still adopt the exact originally bound surface.
        exchange.keepValue = "\"keep\":\"alreadyCommitted\",\"conversationID\":\"tc1\""
        assertEquals(ConversationFlowResult.Accepted, holder.keepTemporaryChat())
        assertTrue(awaitUntil { holder.temporaryKeepState == TemporaryKeepStateUi.Idle })
        assertFalse(holder.snapshot.value!!.isTemporary)
        assertEquals("tc1", holder.snapshot.value!!.promotedConversationId)
        assertNull(host.conversations.activeTemporarySession())
        assertNotNull(host.conversations.keptPromotion.value)
        assertEquals(2, exchange.keepRequests)
        host.stop()
    }

    @Test
    fun lateKeepTerminalAfterGenuineLeaveCannotAdoptNavigateOrEndNewTemporary() = runBlocking {
        val exchange = KeepExchange().apply { keepGate = CountDownLatch(1) }
        val host = readyHost(exchange)
        val (holder, ref) = boundTemporarySurface(host)
        assertEquals(ConversationFlowResult.Accepted, holder.keepTemporaryChat())

        // The user genuinely navigates away BEFORE the committed terminal
        // arrives (the exact retired tuple releases the RAM session through
        // the existing late-retirement authority), then a NEW temporary
        // starts and owns the surface.
        assertTrue(host.conversations.retireLateTemporarySession(ref))
        exchange.startConversationID = "tc2"
        exchange.startIncarnation = "inc-2"
        val (secondHolder, secondRef) = boundTemporarySurface(host, "tc2", "inc-2")

        // Now the OLD keep terminal lands (Core genuinely committed tc1).
        val listsBefore = exchange.historyListRequests()
        exchange.keepGate!!.countDown()
        // The stale terminal's ONLY allowed effect is the durable history
        // refresh — wait for it to prove the callback actually ran.
        assertTrue(
            awaitUntil(timeoutMillis = 3_000) {
                exchange.historyListRequests() > listsBefore
            },
        )

        // No old-id navigation, no adoption signal, no mutation of either
        // surface, and the NEW session's registration is untouched.
        assertNull(host.conversations.navigationRequest.value)
        assertNull(host.conversations.keptPromotion.value)
        assertEquals(secondRef, host.conversations.activeTemporarySession())
        assertTrue(holder.snapshot.value!!.isTemporary)
        assertNull(holder.snapshot.value!!.promotedConversationId)
        assertTrue(secondHolder.snapshot.value!!.isTemporary)
        assertEquals("inc-2", secondHolder.snapshot.value!!.temporaryIncarnationId)
        host.stop()
    }

    @Test
    fun staleKeepTerminalAfterRebindCannotMutateReplacementSurface() = runBlocking {
        val exchange = KeepExchange().apply { keepGate = CountDownLatch(1) }
        val host = readyHost(exchange)
        val (holder, ref) = boundTemporarySurface(host)
        assertEquals(ConversationFlowResult.Accepted, holder.keepTemporaryChat())

        // Reconstruction of the same conversation preserves the session.
        val originalSession = holder.session
        holder.rebind("tc1")
        assertEquals(originalSession, holder.session)
        // An actual navigation away and back creates a replacement session
        // while the committed terminal is still in flight.
        holder.rebind("replacement")
        holder.rebind("tc1")
        assertTrue(holder.session.sessionEpoch > ref.sessionEpoch)
        val listsBefore = exchange.historyListRequests()
        exchange.keepGate!!.countDown()
        assertTrue(
            awaitUntil(timeoutMillis = 3_000) {
                exchange.historyListRequests() > listsBefore
            },
        )

        // The late terminal must not adopt the replaced surface, navigate
        // or publish an adoption for it; the genuine durable rows remain
        // reachable through history instead.
        assertNull(host.conversations.keptPromotion.value)
        assertNull(host.conversations.navigationRequest.value)
        val surface = holder.snapshot.value
        assertTrue(surface == null || surface.promotedConversationId == null)
        host.stop()
    }

    private suspend fun awaitUntil(
        timeoutMillis: Long = 2_000,
        check: () -> Boolean,
    ): Boolean {
        val deadline = System.nanoTime() + timeoutMillis * 1_000_000
        while (System.nanoTime() < deadline) {
            if (check()) return true
            delay(10)
        }
        return check()
    }
}
