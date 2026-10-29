// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.feature.conversation.ApprovalModeUi
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Permission-gesture fence regressions (permission-repair119, 2026-10-29;
 * atomic-admission cohort permission-atomic-fence124, 2026-10-29).
 *
 * One explicit human gesture composes AT MOST ONE `run.policy.update`
 * mutation; the LATEST human intent supersedes older queued/in-flight
 * settlements, and a retired/navigated/epoch-changed/run-changed settlement
 * can never adopt a policy mode or invalidate the CAS state that now belongs
 * to another intent. A stale refusal is surfaced with its typed code
 * (detail["wire"], the post-repair producer contract), invalidates and
 * re-reads the snapshot once, and is never auto-replayed.
 *
 * Atomic admission (124): RuntimeHost settles operations on ioDispatcher
 * while a human tap can concurrently bump the gesture sequence, so the
 * latest-intent check and the projection mutation must execute under ONE
 * monitor — a separate locked boolean read admits a gesture that a
 * concurrent tap has already superseded. `latestIntentAdmissionIsAtomic…`
 * drives the real production admission helper with latches (no sleeps) and
 * proves a concurrent tap cannot slip between the check and the mutation.
 *
 * AUTHORED, NOTRUN — Main compiles/runs this cohort with the host JVM batch.
 * Scripted transport double of the real v3 wire; the REAL host controller and
 * projection builder. No device, no native code.
 */
class ConversationPermissionGestureFenceTest {

    private val conversationId = "11111111-1111-4111-8111-111111111111"
    private val runId = "22222222-2222-4222-8222-222222222222"
    private val otherRunId = "33333333-3333-4333-8333-333333333333"
    private val stamp = "2026-10-29T05:33:41.028Z"
    private val newStamp = "2026-10-29T06:40:00.000Z"

    // ------------------------------------------------------------ transport

    /** Scripted v3 double: submits queue immediately (unique receipt per
     * submission); policy polls park until released when auto response is
     * off, so superseded/in-flight settlements are driven deterministically. */
    private class HeldExchange : HostBridgeExchange {
        val requests = CopyOnWriteArrayList<String>()
        val policyReceipts = CopyOnWriteArrayList<String>()
        private val parks = ConcurrentHashMap<String, CompletableDeferred<Unit>>()
        private val counter = AtomicInteger(0)
        @Volatile var policyAccepted: Boolean = true
        @Volatile var autoPolicyResponse: Boolean = true

        fun release(receipt: String) {
            parks.remove(receipt)?.complete(Unit)
        }

        private fun commandOf(raw: String): String =
            runCatching {
                Json.parseToJsonElement(raw).jsonObject["envelope"]
                    ?.jsonObject?.get("command")?.jsonPrimitive?.content
            }.getOrNull() ?: ""

        fun submits(command: String): List<JsonObject> = requests.mapNotNull { raw ->
            val root = runCatching { Json.parseToJsonElement(raw).jsonObject }.getOrNull()
                ?: return@mapNotNull null
            if ((root["operation"]?.jsonPrimitive?.content) != "command.submit") return@mapNotNull null
            val envelope = root["envelope"]?.jsonObject ?: return@mapNotNull null
            if ((envelope["command"]?.jsonPrimitive?.content) != command) return@mapNotNull null
            envelope
        }

        private fun policyTerminal(correlation: String, receipt: String): String =
            if (policyAccepted) {
                effectPage(correlation, receipt,
                    """{"sequence":1,"kind":"accepted",""" +
                        """"detail":[{"key":"appliedToLiveRun","value":"true"},""" +
                        """{"key":"policyVersion","value":"$newStampStatic"}]}""")
            } else {
                effectPage(correlation, receipt,
                    """{"sequence":1,"kind":"rejected","code":"ordinaryRuntimeBlocked",""" +
                        """"detail":[{"key":"wire","value":"staleRevision"},""" +
                        """{"key":"error","value":"staleRevision"},""" +
                        """{"key":"reason","value":"revisionMismatch"}]}""")
            }

        override fun exchange(request: String): String {
            requests.add(request)
            return when {
                request.contains("\"operation\":\"command.submit\"") -> {
                    val correlation = correlationOf(request)
                    val command = commandOf(request)
                    val receipt = "op:v1:" + command.replace(".", "") +
                        "-${counter.incrementAndGet()}"
                    if (command == "run.policy.update") policyReceipts.add(receipt)
                    """{"version":3,"ok":true,"queued":true,"correlationID":${JsonPrimitive(correlation)},"operationReceiptID":${JsonPrimitive(receipt)}}"""
                }
                request.contains("\"command\":\"effect.poll\"") -> {
                    val receipt = receiptOf(request)
                    val correlation = correlationOf(request)
                    when {
                        receipt.startsWith("op:v1:runpolicyupdate") -> {
                            if (!autoPolicyResponse) {
                                runBlocking {
                                    parks.getOrPut(receipt) { CompletableDeferred() }.await()
                                }
                            }
                            policyTerminal(correlation, receipt)
                        }
                        receipt.startsWith("op:v1:runsnapshot") ->
                            effectPage(correlation, receipt,
                                """{"sequence":1,"kind":"accepted","value":${snapshotPageJson()}}""")
                        else ->
                            effectPage(correlation, receipt,
                                """{"sequence":1,"kind":"failed","code":"unknown"}""")
                    }
                }
                else -> """{"version":3,"ok":false,"error":"unsupportedOperation"}"""
            }
        }

        private fun effectPage(correlation: String, receipt: String, effects: String): String =
            """{"version":3,"requestID":${JsonPrimitive(correlation)},"ok":true,""" +
                """"schema":"floe.effect-cursor/3","correlationID":${JsonPrimitive(correlation)},""" +
                """"cursor":{"operationReceiptID":${JsonPrimitive(receipt)},"sequence":99},""" +
                """"effects":[$effects],"hasMore":false,"resyncRequired":false}"""

        private fun snapshotPageJson(): String =
            """{"conversationID":"$conversationIdStatic","runID":"$runIdStatic",""" +
                """"durableState":"executingTool",""" +
                """"revision":{"resourceID":"run.${runIdStatic.uppercase()}","version":"executingTool"},""" +
                """"isTerminal":false,"conversationMode":"chat","goal":"hi","liveOwner":true,""" +
                """"pendingApproval":null,"approvalRevision":null,"pendingInputs":[],""" +
                """"queueRevision":{"resourceID":"pendingQueue.${conversationIdStatic.uppercase()}",""" +
                """"version":"queue-digest"},"durableWatermark":7,""" +
                """"policyRevision":{"resourceID":"taskPolicy.${conversationIdStatic.uppercase()}",""" +
                """"version":"$newStampStatic"}}"""

        companion object {
            const val conversationIdStatic = "11111111-1111-4111-8111-111111111111"
            const val runIdStatic = "22222222-2222-4222-8222-222222222222"
            const val newStampStatic = "2026-10-29T06:40:00.000Z"
        }
    }

    // --------------------------------------------------------------- fixtures

    private fun client(exchange: HostBridgeExchange) = RuntimeHostCommandClient(
        exchange = exchange,
        scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default),
        ioDispatcher = kotlinx.coroutines.Dispatchers.Default,
        budgets = HostWireBudgets(effectPollIntervalMillis = 1),
    )

    private fun host(exchange: HostBridgeExchange) = RuntimeHost(
        commandClient = client(exchange),
        gatewayCapability = MutableStateFlow(com.floe.android.SecretGatewayCapability.Loading),
        bootstrapCapability = MutableStateFlow(com.floe.android.RuntimeBootstrapCapability.Idle),
        scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default),
        ioDispatcher = kotlinx.coroutines.Dispatchers.Default,
    ).also { host ->
        // The REAL controller gates run mutations on truthful host readiness
        // (store + run domain). A fixture that never publishes readiness would
        // refuse before reaching the fence under test, so use the same public
        // admission points the Application uses (no fabricated readiness).
        host.onBootstrapCapability(com.floe.android.RuntimeBootstrapCapability.OwnedStoreReady)
        host.onDomainAvailability("runDomain", available = true, missing = emptyList())
    }

    private val snapshotJsonRaw: String
        get() = """{"conversationID":"$conversationId","runID":"$runId",""" +
            """"durableState":"executingTool",""" +
            """"revision":{"resourceID":"run.${runId.uppercase()}","version":"executingTool"},""" +
            """"isTerminal":false,"conversationMode":"chat","goal":"hi","liveOwner":true,""" +
            """"pendingApproval":null,"approvalRevision":null,"pendingInputs":[],""" +
            """"queueRevision":{"resourceID":"pendingQueue.${conversationId.uppercase()}",""" +
            """"version":"queue-digest"},"durableWatermark":7,""" +
            """"policyRevision":{"resourceID":"taskPolicy.${conversationId.uppercase()}",""" +
            """"version":"$stamp"}}"""

    /** Registers the holder and seeds the CURRENT run + proven policy
     * revision through the REAL snapshot decoder — no shortcuts. */
    private fun seed(host: RuntimeHost): ConversationFlowHolderEntry {
        val holder = host.conversations.holderFor(
            conversationId, isTemporary = false, incarnationId = null)
        val entry = host.conversations.entryFor(conversationId)
        checkNotNull(entry) { "holderFor must register the entry" }
        entry.builder.selectedRunId = runId
        val page = ConversationWire.decodeSnapshotPage(Json.parseToJsonElement(snapshotJsonRaw))
        checkNotNull(page) { "fixture page must decode through the real decoder" }
        entry.builder.applySnapshot(page)
        return entry
    }

    private data class Settled(
        val accepted: Boolean,
        val code: String?,
        val appliedToLiveRun: Boolean,
        val revisionAtSettle: String?,
    )

    private fun recorder(
        entry: ConversationFlowHolderEntry,
        into: CopyOnWriteArrayList<Settled>,
    ): (Boolean, String?, Boolean) -> Unit = { accepted, code, applied ->
        into.add(Settled(accepted, code, applied, entry.builder.policyRevision?.version))
    }

    private suspend fun await(
        description: String,
        condition: () -> Boolean,
    ) {
        repeat(300) {
            if (condition()) return
            delay(10)
        }
        throw AssertionError("timeout waiting for $description")
    }

    private suspend fun awaitPolicySubmits(
        exchange: HeldExchange,
        count: Int,
    ) = await("$count run.policy.update submits") { exchange.policyReceipts.size >= count }

    // ----------------------------------------------------------------- tests

    @org.junit.Test
    fun oneGestureSendsExactlyOneMutationAndAdoptsAckVersion() = runBlocking {
        val exchange = HeldExchange()
        val host = host(exchange)
        val entry = seed(host)
        val settlements = CopyOnWriteArrayList<Settled>()

        val started = host.conversations.updateTaskApprovalMode(
            entry.holder.session, ApprovalModeUi.FULL_ACCESS,
            recorder(entry, settlements))

        org.junit.Assert.assertTrue(started)
        await("settlement") { settlements.size >= 1 }
        org.junit.Assert.assertEquals(Settled(true, null, true, newStamp), settlements[0])
        org.junit.Assert.assertEquals(1, exchange.submits("run.policy.update").size)
        val envelope = exchange.submits("run.policy.update")[0]
        org.junit.Assert.assertEquals(
            "fullAccess",
            (envelope["payload"] as JsonObject)["approvalMode"]?.jsonPrimitive?.content)
        org.junit.Assert.assertEquals(
            stamp,
            (envelope["payload"] as JsonObject)["expectedPolicyVersion"]?.jsonPrimitive?.content)
        // The ack's REAL policyVersion is adopted as the new CAS identity.
        org.junit.Assert.assertEquals(newStamp, entry.builder.policyRevision?.version)
    }

    @org.junit.Test
    fun staleRefusalInvalidatesAtSettleRefreshesOnceAndNeverReplays() = runBlocking {
        val exchange = HeldExchange()
        exchange.policyAccepted = false
        val host = host(exchange)
        val entry = seed(host)
        val settlements = CopyOnWriteArrayList<Settled>()

        val started = host.conversations.updateTaskApprovalMode(
            entry.holder.session, ApprovalModeUi.FULL_ACCESS,
            recorder(entry, settlements))

        org.junit.Assert.assertTrue(started)
        await("settlement") { settlements.size >= 1 }
        // Typed code surfaces through the frozen detail["wire"] decode; the
        // revision is invalidated BEFORE onSettled (the post-settlement
        // snapshot refresh re-adopts the durable stamp asynchronously).
        org.junit.Assert.assertEquals(
            Settled(false, "staleRevision", false, null), settlements[0])
        org.junit.Assert.assertEquals(1, exchange.submits("run.policy.update").size)
        // The designed recovery: invalidate + ONE authoritative re-read,
        // never an automatic replay of the rejected gesture.
        await("one snapshot refresh") { exchange.submits("run.snapshot").size >= 1 }
        org.junit.Assert.assertEquals(1, exchange.submits("run.snapshot").size)
        org.junit.Assert.assertEquals(1, exchange.submits("run.policy.update").size)
    }

    @org.junit.Test
    fun supersededOlderGestureCannotInvalidateOrAdoptForAnotherIntent() = runBlocking {
        val exchange = HeldExchange()
        exchange.autoPolicyResponse = false
        exchange.policyAccepted = false
        val host = host(exchange)
        val entry = seed(host)
        val first = CopyOnWriteArrayList<Settled>()
        val second = CopyOnWriteArrayList<Settled>()

        org.junit.Assert.assertTrue(host.conversations.updateTaskApprovalMode(
            entry.holder.session, ApprovalModeUi.FULL_ACCESS,
            recorder(entry, first)))
        awaitPolicySubmits(exchange, 1)
        val firstReceipt = exchange.policyReceipts[0]

        org.junit.Assert.assertTrue(host.conversations.updateTaskApprovalMode(
            entry.holder.session, ApprovalModeUi.AUTOMATIC,
            recorder(entry, second)))
        awaitPolicySubmits(exchange, 2)
        val secondReceipt = exchange.policyReceipts[1]

        org.junit.Assert.assertEquals(2, exchange.submits("run.policy.update").size)

        // The superseded gesture's rejection reports honestly but touches
        // NOTHING: the newer intent's CAS state stands.
        exchange.policyAccepted = false
        exchange.release(firstReceipt)
        await("first settlement") { first.size >= 1 }
        org.junit.Assert.assertEquals(
            Settled(false, "staleRevision", false, stamp), first[0])
        org.junit.Assert.assertEquals(stamp, entry.builder.policyRevision?.version)

        // The LATEST intent settles and adopts its ack's REAL version.
        exchange.policyAccepted = true
        exchange.release(secondReceipt)
        await("second settlement") { second.size >= 1 }
        org.junit.Assert.assertEquals(Settled(true, null, true, newStamp), second[0])
        org.junit.Assert.assertEquals(newStamp, entry.builder.policyRevision?.version)
    }

    @org.junit.Test
    fun runChangedSettlementCannotApplyOrInvalidateOldGesture() = runBlocking {
        val exchange = HeldExchange()
        exchange.autoPolicyResponse = false
        exchange.policyAccepted = false
        val host = host(exchange)
        val entry = seed(host)
        val settlements = CopyOnWriteArrayList<Settled>()

        org.junit.Assert.assertTrue(host.conversations.updateTaskApprovalMode(
            entry.holder.session, ApprovalModeUi.FULL_ACCESS,
            recorder(entry, settlements)))
        awaitPolicySubmits(exchange, 1)
        val receipt = exchange.policyReceipts[0]

        // The selected run changed while the mutation was in flight.
        entry.builder.selectedRunId = otherRunId
        exchange.release(receipt)
        await("settlement") { settlements.size >= 1 }

        org.junit.Assert.assertEquals(
            Settled(false, "staleRevision", false, stamp), settlements[0])
        // No projection mutation: the proven CAS identity is NOT invalidated
        // for the now-selected run's surface.
        org.junit.Assert.assertEquals(stamp, entry.builder.policyRevision?.version)
        org.junit.Assert.assertEquals(0, exchange.submits("run.snapshot").size)
    }

    @org.junit.Test
    fun temporarySessionRefusesWithoutAnyMutation() = runBlocking {
        val exchange = HeldExchange()
        val host = host(exchange)
        val entry = seed(host)
        entry.builder.isTemporary = true
        val settlements = CopyOnWriteArrayList<Settled>()

        val started = host.conversations.updateTaskApprovalMode(
            entry.holder.session, ApprovalModeUi.FULL_ACCESS,
            recorder(entry, settlements))

        org.junit.Assert.assertFalse(started)
        org.junit.Assert.assertEquals(
            Settled(false, "temporaryPolicyNotDurable", false, stamp), settlements[0])
        org.junit.Assert.assertEquals(0, exchange.submits("run.policy.update").size)
        org.junit.Assert.assertEquals(0, exchange.submits("run.snapshot").size)
    }

    // ------------------------------------------------- 124 atomic admission

    /** The production admission helper holds its monitor across the fence
     * check AND the projection mutation: while gesture A's settlement is
     * inside its check, a concurrent newer tap parks on the same monitor
     * and only proceeds after the mutation completed. The pre-atomic
     * separate-boolean-read shape let the tap slip exactly into this
     * window; this test drives that window with latches, no sleeps. */
    @org.junit.Test
    fun latestIntentAdmissionIsAtomicAgainstConcurrentTap() {
        val exchange = HeldExchange()
        val host = host(exchange)
        val entry = seed(host)

        val seq = entry.nextPolicyGestureIntent()
        val insideCheck = CountDownLatch(1)
        val letCheckReturn = CountDownLatch(1)
        val mutationRan = AtomicBoolean(false)
        val admitted = AtomicBoolean(false)

        // Gesture A's settlement admission parks INSIDE its fence check —
        // precisely the window in which the pre-atomic code had already
        // released the lock after a separate boolean read.
        val worker = kotlin.concurrent.thread(start = true) {
            admitted.set(entry.withLatestPolicyGestureIntent(seq, check = {
                insideCheck.countDown()
                letCheckReturn.await(10, TimeUnit.SECONDS)
                true
            }, apply = {
                mutationRan.set(true)
            }))
        }
        org.junit.Assert.assertTrue(
            "worker must reach its fence check",
            insideCheck.await(10, TimeUnit.SECONDS),
        )

        // A concurrent newer tap attempts the SAME monitor while A holds it
        // between check and mutation.
        val tapStarted = CountDownLatch(1)
        val tapDone = CountDownLatch(1)
        val tapObservedMutation = AtomicBoolean(false)
        kotlin.concurrent.thread(start = true) {
            tapStarted.countDown()
            entry.nextPolicyGestureIntent()
            tapObservedMutation.set(mutationRan.get())
            tapDone.countDown()
        }
        org.junit.Assert.assertTrue(
            "tap must start", tapStarted.await(10, TimeUnit.SECONDS))

        // With the atomic admission the tap is parked on the monitor, so it
        // CANNOT finish before the mutation does. The bounded window only
        // guards liveness; the assertions below rest on monitor ordering,
        // not on wall time.
        val tapFinishedEarly = tapDone.await(2, TimeUnit.SECONDS)
        letCheckReturn.countDown()
        org.junit.Assert.assertTrue(
            "tap must finish", tapDone.await(10, TimeUnit.SECONDS))
        worker.join(10_000)
        org.junit.Assert.assertFalse("worker must finish", worker.isAlive)

        org.junit.Assert.assertTrue(
            "still-latest settlement must be admitted", admitted.get())
        org.junit.Assert.assertFalse(
            "concurrent tap finished inside the admission window — the " +
                "latest-intent check and the mutation are not atomic",
            tapFinishedEarly)
        org.junit.Assert.assertTrue(
            "concurrent tap slipped between the latest-intent check and " +
                "the projection mutation",
            tapObservedMutation.get())
        // The tap is the newer intent now; A is honestly superseded and a
        // repeated admission for A refuses.
        org.junit.Assert.assertFalse(entry.withLatestPolicyGestureIntent(
            seq, check = { true }, apply = {}))
    }

    /** End-to-end through the REAL controller: an older gesture whose
     * ACCEPTED settlement lands after a newer tap reports its own outcome
     * honestly but its FullAccess decision must never overwrite the newer
     * intent's adopted mode/CAS identity. */
    @org.junit.Test
    fun supersededOlderAcceptedGestureCannotAdoptAnotherIntentsMode() = runBlocking {
        val exchange = HeldExchange()
        exchange.autoPolicyResponse = false
        val host = host(exchange)
        val entry = seed(host)
        val first = CopyOnWriteArrayList<Settled>()
        val second = CopyOnWriteArrayList<Settled>()

        org.junit.Assert.assertTrue(host.conversations.updateTaskApprovalMode(
            entry.holder.session, ApprovalModeUi.FULL_ACCESS,
            recorder(entry, first)))
        awaitPolicySubmits(exchange, 1)
        val firstReceipt = exchange.policyReceipts[0]

        org.junit.Assert.assertTrue(host.conversations.updateTaskApprovalMode(
            entry.holder.session, ApprovalModeUi.AUTOMATIC,
            recorder(entry, second)))
        awaitPolicySubmits(exchange, 2)
        val secondReceipt = exchange.policyReceipts[1]

        // The LATEST intent settles FIRST and adopts its ack's REAL version.
        exchange.release(secondReceipt)
        await("second settlement") { second.size >= 1 }
        org.junit.Assert.assertEquals(Settled(true, null, true, newStamp), second[0])
        org.junit.Assert.assertEquals(newStamp, entry.builder.policyRevision?.version)
        org.junit.Assert.assertEquals(
            ApprovalModeUi.AUTOMATIC, entry.holder.snapshot.value?.approvalMode)

        // The superseded gesture's acceptance reports honestly but touches
        // NOTHING: the newer intent's mode and CAS identity stand.
        exchange.release(firstReceipt)
        await("first settlement") { first.size >= 1 }
        org.junit.Assert.assertEquals(Settled(true, null, true, newStamp), first[0])
        org.junit.Assert.assertEquals(newStamp, entry.builder.policyRevision?.version)
        org.junit.Assert.assertEquals(
            ApprovalModeUi.AUTOMATIC, entry.holder.snapshot.value?.approvalMode)
        org.junit.Assert.assertEquals(2, exchange.submits("run.policy.update").size)
    }
}
