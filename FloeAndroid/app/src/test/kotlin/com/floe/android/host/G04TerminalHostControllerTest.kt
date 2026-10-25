// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Focused JVM tests for the terminal host controller's settings/lifecycle
 * surface (job-bdebb54ff6ff4403; blank-output repair job-76566fa470184cb6;
 * ownership/input-lane review job-f9d7f7eccf894d74). AUTHORED SOURCE ONLY —
 * not executed by the authoring jobs. Everything here stays off the native
 * transport: an unbound controller must refuse before any JNI touch, event
 * routing is driven through [G04TerminalHostController.handleEvent] with
 * descriptor bytes, and output/input ownership uses REPRESENTATIVE live
 * bindings (a bound generation whose runtime epoch confirms it, plus the
 * conversation-token reverse binding) — no production guard is weakened
 * for a fixture. No Android, no device, no real mailbox.
 */
class G04TerminalHostControllerTest {
    private fun newController(): G04TerminalHostController =
        G04TerminalHostController(CoroutineScope(Dispatchers.Unconfined), Dispatchers.Unconfined) { null }

    @Suppress("UNCHECKED_CAST")
    private fun <V> seedMap(controller: G04TerminalHostController, field: String): MutableMap<String, V> {
        val f = G04TerminalHostController::class.java.getDeclaredField(field)
        f.isAccessible = true
        return f.get(controller) as MutableMap<String, V>
    }

    @Test
    fun refusedOpenReportsItsOutcomeWithoutInventingASession() = runBlocking {
        val controller = newController()
        var refusal: TerminalActionReply? = null
        val session = controller.attachOrOpen("c1", null, 80, 24) { refusal = it }
        assertNull(session)
        assertNull(controller.currentSnapshot("c1"))
        assertTrue(refusal is TerminalActionReply.Refused)
        assertEquals("hostUnbound", (refusal as TerminalActionReply.Refused).code)
    }

    @Test
    fun unboundControllerRefusesDurableToggleWithoutAnyNativeTouch() = runBlocking {
        val controller = newController()
        val reply = controller.setLanguageEnabled("python", false)
        assertTrue(reply is TerminalActionReply.Refused)
        assertEquals("hostUnbound", (reply as TerminalActionReply.Refused).code)
        // The projection mirrors ONLY committed durable state: an unbound
        // refusal changes nothing (settingsKnown stays false, no local lie).
        assertFalse(controller.languageSettingsSnapshot().settingsKnown)
        assertTrue(controller.isLanguageEnabled("python")) // unknown != disabled
    }

    @Test
    fun refusedCloseRetainsTheActualSessionHandleForReconciliation() = runBlocking {
        val controller = newController()
        // Seed only the existing projection; the unbound controller must
        // refuse before JNI and cannot claim physical session release.
        val field = G04TerminalHostController::class.java.getDeclaredField("sessionTokens")
        field.isAccessible = true
        @Suppress("UNCHECKED_CAST")
        val tokens = field.get(controller) as java.util.concurrent.ConcurrentHashMap<String, String>
        tokens["c1"] = "retained-native-session"
        val reply = controller.closeSession("c1")
        assertTrue(reply is TerminalActionReply.Refused)
        assertEquals("retained-native-session", tokens["c1"])
    }

    @Test
    fun capabilitiesReadBeforeBindYieldsNullAndClearsAvailability() = runBlocking {
        val controller = newController()
        assertNull(controller.capabilitiesFor("c1"))
        assertFalse(controller.availability().bound)
        assertFalse(controller.availability().capabilitiesKnown)
    }

    @Test
    fun parsesHonestDefaultsWhenDurableFieldsAreAbsent() {
        val controller = newController()
        val fields = Json.parseToJsonElement("""{"qualified":false,"attached":false}""") as JsonObject
        val parsed = controller.parseLanguageCapabilities(fields)
        assertFalse("absent settingsKnown must NOT be guessed true", parsed.settingsKnown)
        assertEquals(-1L, parsed.settingsRevision)
        assertTrue(parsed.enabled.isEmpty())
        assertTrue(parsed.serverStates.isEmpty())
    }

    @Test
    fun parsesFullDurableMirrorAndEmptyCodesNormalizeToNull() {
        val controller = newController()
        val fields = Json.parseToJsonElement(
            """{
              "qualified":true,"attached":true,"settingsKnown":true,"settingsRevision":3,
              "languageEnabled":{"python":false,"shell":true,"css":false},
              "serverStates":[
                {"language":"python","state":"unavailable","code":"toolMissing"},
                {"language":"shell","state":"ready","code":""}
              ]
            }""",
        ) as JsonObject
        val parsed = controller.parseLanguageCapabilities(fields)
        assertTrue(parsed.settingsKnown)
        assertEquals(3L, parsed.settingsRevision)
        assertEquals(false, parsed.enabled["python"])
        assertEquals(true, parsed.enabled["shell"])
        assertEquals("toolMissing", parsed.serverStates["python"]?.code)
        assertEquals("ready", parsed.serverStates["shell"]?.state)
        assertNull("empty native code must never surface as an empty label input",
            parsed.serverStates["shell"]?.code)
    }

    @Test
    fun languageStatusEventsFanOutToEverySubscriberAndSurviveRemoval() {
        val controller = newController()
        val first = mutableListOf<TerminalLanguageStatus>()
        val second = mutableListOf<TerminalLanguageStatus>()
        val removeFirst = controller.addLanguageStatusListener { first.add(it) }
        controller.addLanguageStatusListener { second.add(it) }
        val legacy = mutableListOf<TerminalLanguageStatus>()
        controller.setLanguageStatusListener { legacy.add(it) }
        val event = ("""{"type":"lspStatus","conversationID":"c1",""" +
            """"language":"css","state":"ready","code":""}""").toByteArray()
        assertTrue(controller.handleEvent(1L, event))
        assertEquals(1, first.size)
        assertEquals(1, second.size)
        assertEquals(1, legacy.size)
        removeFirst()
        assertTrue(controller.handleEvent(2L, event))
        assertEquals(1, first.size) // removed cleanly (multi-subscriber, no clobber)
        assertEquals(2, second.size)
    }

    @Test
    fun controlOverflowFenceReleasesWaitersAndNeverClaimsBound() {
        val controller = newController()
        val event = """{"type":"hostEventOverflow"}""".toByteArray()
        assertTrue(controller.handleEvent(1L, event))
        // Honest fence: local waiters are refused; availability flips to
        // unbound. Native IO/session receipts remain owned by Core (this
        // asserts NOTHING was fabricated either way).
        assertFalse(controller.availability().bound)
        assertFalse(controller.availability().capabilitiesKnown)
    }

    @Test
    fun malformedDescriptorsAreNotClaimedAsEvents() {
        val controller = newController()
        assertFalse(controller.handleEvent(1L, "not json".toByteArray()))
    }

    /* ---- blank-output repair: terminalOutput must reach a LIVE owner ---- */

    /** The runtime authority's live epoch; production returns the Root's
     * native epoch (or null when unbound). */
    private class LiveRoot(var epoch: Long? = null)

    /** A REPRESENTATIVE bound controller: bound generation + matching
     * runtime epoch + stopped=false. Positive fixtures seed this real
     * binding instead of weakening the production guard. */
    private fun boundController(
        output: kotlinx.coroutines.CoroutineDispatcher = Dispatchers.Unconfined,
        input: kotlinx.coroutines.CoroutineDispatcher = Dispatchers.Unconfined,
        epoch: Long = 1L,
        sink: (suspend (String, String, ByteArray) -> Unit)? = null,
    ): Pair<G04TerminalHostController, LiveRoot> {
        val root = LiveRoot(epoch)
        val controller = if (sink == null) {
            G04TerminalHostController(
                CoroutineScope(Dispatchers.Unconfined), output, input) { root.epoch }
        } else {
            G04TerminalHostController(
                CoroutineScope(Dispatchers.Unconfined), output, input, sink) { root.epoch }
        }
        setFieldLong(controller, "boundEpoch", epoch)
        (G04TerminalHostController::class.java.getDeclaredField("stopped")
            .apply { isAccessible = true }.get(controller)
            as java.util.concurrent.atomic.AtomicBoolean).set(false)
        return controller to root
    }

    private fun setFieldLong(controller: G04TerminalHostController, field: String, value: Long) {
        val f = G04TerminalHostController::class.java.getDeclaredField(field)
        f.isAccessible = true
        f.setLong(controller, value)
    }

    @Test
    fun outputForABoundTokenReachesRegisteredObserversInOrder() {
        val (controller, _) = boundController(Dispatchers.Unconfined)
        val tokens = seedMap<String>(controller, "sessionTokens")
        tokens["c1"] = "tok-1"
        val received = mutableListOf<ByteArray>()
        val unregister = controller.addOutputListener("tok-1") { received.add(it) }
        controller.deliverTerminalOutput("tok-1", "hello ".toByteArray())
        controller.deliverTerminalOutput("tok-1", "world".toByteArray())
        // Unconfined scope + Unconfined output dispatcher: delivered inline.
        assertEquals(2, received.size)
        assertEquals("hello ", String(received[0]))
        assertEquals("world", String(received[1]))
        // No engine exists for c1 (engineFor never called): the delivery
        // must NOT crash and the observer path still owns its bytes.
        unregister()
        controller.deliverTerminalOutput("tok-1", "more".toByteArray())
        assertEquals(2, received.size)
    }

    @Test
    fun outputForAnUnboundGenerationIsDroppedEvenWithRegisteredObservers() {
        val controller = newController() // epoch 0 / runtime epoch null
        seedMap<String>(controller, "sessionTokens")["c1"] = "tok-1"
        var seen = 0
        controller.addOutputListener("tok-1") { seen += 1 }
        // Honest bounded behavior: no live generation means NO delivery —
        // even with a registered observer (there is no epoch-0 bypass) —
        // and nothing may feed an unrelated conversation's engine.
        controller.deliverTerminalOutput("tok-1", "x".toByteArray())
        controller.deliverTerminalOutput("nobody", "x".toByteArray())
        controller.deliverTerminalOutput("tok-1", ByteArray(0))
        assertEquals(0, seen)
    }

    @Test
    fun refusedReopenAgainstASettledSnapshotReturnsNullInsteadOfALiveLie() = runBlocking {
        val controller = newController()
        // Simulate the post-close state a Reset/reopen observes: an OLD
        // settled snapshot exists (no token binding).
        val snapshots = seedMap<TerminalSessionSnapshot>(controller, "snapshots")
        snapshots["c1"] = TerminalSessionSnapshot(
            "c1", "old-token", TerminalSessionPhase.CLOSED, "interactive", "",
            null, null, null, 0)
        var refusal: TerminalActionReply? = null
        val session = controller.attachOrOpen("c1", null, 80, 24) { refusal = it }
        // The unbound controller refuses before JNI; with the repair the
        // caller gets NULL (nothing is live), never the stale CLOSED
        // snapshot that kept the pane stuck in a blank "starting" state.
        assertNull(session)
        assertTrue(refusal is TerminalActionReply.Refused)
        assertEquals("hostUnbound", (refusal as TerminalActionReply.Refused).code)
        // The previous authoritative record is untouched (no snapshot write
        // happens for a refused opening).
        assertEquals("old-token", snapshots["c1"]?.sessionToken)
    }

    @Test
    fun settledWaitReportsTheLastObservedTruthBoundedly() = runBlocking {
        val controller = newController()
        assertTrue(controller.awaitSessionSettled("absent", 200))
        val snapshots = seedMap<TerminalSessionSnapshot>(controller, "snapshots")
        snapshots["c2"] = TerminalSessionSnapshot(
            "c2", "t2", TerminalSessionPhase.CLOSED, "interactive", "",
            null, null, null, 0)
        assertTrue(controller.awaitSessionSettled("c2", 200))
        snapshots["c3"] = TerminalSessionSnapshot(
            "c3", "t3", TerminalSessionPhase.RUNNING, "interactive", "",
            null, null, null, 0)
        val started = System.currentTimeMillis()
        assertFalse("a live session must not be declared settled by a timeout",
            controller.awaitSessionSettled("c3", 120))
        assertTrue("the wait must actually bound itself",
            System.currentTimeMillis() - started >= 100)
        snapshots.remove("c3")
        assertTrue(controller.awaitSessionSettled("c3", 50))
    }

    /* ---- review round 2: apply-time ownership fences + serialized input lane ---- */

    /** Dispatches continuations into a manual queue: deliveries/drain
     * steps run ONLY when the test advances them, so "queued before
     * retire/reset/new root" is a REAL state here, not a race the test
     * hopes to win. */
    private class QueuedDispatcher : kotlinx.coroutines.CoroutineDispatcher() {
        private val pending = ArrayDeque<kotlinx.coroutines.Runnable>()
        override fun dispatch(context: kotlin.coroutines.CoroutineContext, block: kotlinx.coroutines.Runnable) {
            pending.add(block)
        }

        fun drainAll() {
            var guard = 0
            while (pending.isNotEmpty()) {
                check(guard++ < 10_000) { "runaway dispatch queue" }
                pending.removeFirst().run()
            }
        }
    }

    @Test
    fun queuedDeliveryAfterTokenRetireNeverTouchesTheReplacementOwners() {
        val output = QueuedDispatcher()
        val (controller, _) = boundController(output)
        val tokens = seedMap<String>(controller, "sessionTokens")
        tokens["c1"] = "tok-1"
        var oldSeen = 0
        var replacementSeen = 0
        val unregisterOld = controller.addOutputListener("tok-1") { oldSeen += 1 }
        controller.addOutputListener("tok-2") { replacementSeen += 1 }
        controller.deliverTerminalOutput("tok-1", "late page".toByteArray())
        // A reset + reopen landed BEFORE the queued apply ran: the old pane
        // disposed its view observer and the conversation re-bound to a
        // fresh token.
        unregisterOld()
        tokens["c1"] = "tok-2"
        output.drainAll()
        assertEquals("retired-token bytes must never reach the replacement observer",
            0, replacementSeen)
        assertEquals("unregistered observers receive nothing", 0, oldSeen)
        // The engine feed is fenced by the SAME apply-time ownership check
        // (engine first, exact token binding required); the engine itself
        // is not constructible here — app JVM tests deliberately never
        // build the vendored emulator.
    }

    @Test
    fun registeredObserversReceiveQueuedPagesInOrderAtApplyTime() {
        val output = QueuedDispatcher()
        val (controller, _) = boundController(output)
        seedMap<String>(controller, "sessionTokens")["c1"] = "tok-1"
        val received = mutableListOf<String>()
        controller.addOutputListener("tok-1") { received.add(String(it)) }
        controller.deliverTerminalOutput("tok-1", "a".toByteArray())
        controller.deliverTerminalOutput("tok-1", "b".toByteArray())
        assertEquals("ownership is re-checked at apply time, not capture time", 0, received.size)
        output.drainAll()
        assertEquals(listOf("a", "b"), received) // one serialized dispatcher keeps mailbox FIFO
    }

    @Test
    fun rootGenerationFenceDropsPagesQueuedAcrossAnEpochChange() {
        val output = QueuedDispatcher()
        val (controller, root) = boundController(output, epoch = 7L)
        seedMap<String>(controller, "sessionTokens")["c1"] = "tok-1"
        var seen = 0
        controller.addOutputListener("tok-1") { seen += 1 }
        controller.deliverTerminalOutput("tok-1", "x".toByteArray())
        // …the Root generation retired before the apply:
        setFieldLong(controller, "boundEpoch", 0L)
        root.epoch = null
        output.drainAll()
        assertEquals("a page admitted under a retired generation must drop", 0, seen)
        // A page admitted under a stale epoch must NOT enter a new world:
        setFieldLong(controller, "boundEpoch", 9L)
        root.epoch = 9L
        // (admitted under 9 while live — delivered:)
        controller.deliverTerminalOutput("tok-1", "y".toByteArray())
        output.drainAll()
        assertEquals(1, seen)
        // The runtime authority disagreeing with the bound epoch refuses too.
        root.epoch = 8L
        controller.deliverTerminalOutput("tok-1", "z".toByteArray())
        output.drainAll()
        assertEquals("currentNativeEpoch must confirm the admitted epoch", 1, seen)
    }

    @Test
    fun observerExceptionNeverStarvesOtherObserversAndRunsAfterTheEngineFeed() {
        val output = QueuedDispatcher()
        val (controller, _) = boundController(output)
        seedMap<String>(controller, "sessionTokens")["c1"] = "tok-1"
        controller.addOutputListener("tok-1") { throw IllegalStateException("broken pane") }
        var secondSeen = 0
        controller.addOutputListener("tok-1") { secondSeen += 1 }
        controller.deliverTerminalOutput("tok-1", "page".toByteArray())
        output.drainAll()
        assertEquals("one throwing observer must not block the later observers " +
            "(the authoritative engine feed already ran FIRST in the apply block)", 1, secondSeen)
    }

    @Test
    fun anObserverRemovedByAPrecedingObserverIsSkippedAtApplyTime() {
        val output = QueuedDispatcher()
        val (controller, _) = boundController(output)
        seedMap<String>(controller, "sessionTokens")["c1"] = "tok-1"
        var secondSeen = 0
        var unregisterSecond: (() -> Unit)? = null
        controller.addOutputListener("tok-1") { unregisterSecond?.invoke() }
        unregisterSecond = controller.addOutputListener("tok-1") { secondSeen += 1 }
        controller.deliverTerminalOutput("tok-1", "page".toByteArray())
        output.drainAll()
        assertEquals("the still-registered check runs before EACH observer", 0, secondSeen)
    }

    private fun laneController(
        input: kotlinx.coroutines.CoroutineDispatcher,
        sent: MutableList<String>,
        issues: MutableList<String>,
    ): Pair<G04TerminalHostController, LiveRoot> {
        val pair = boundController(input = input, sink = { _, sessionToken, bytes ->
            sent.add("$sessionToken|${String(bytes)}")
        })
        pair.first.inputIssueReporter = { issues.add(it) }
        return pair
    }

    @Test
    fun ptyInputLaneDrainsKeystrokesInArrivalOrder() {
        val sent = mutableListOf<String>()
        val issues = mutableListOf<String>()
        val (controller, _) = laneController(Dispatchers.Unconfined, sent, issues)
        seedMap<String>(controller, "sessionTokens")["c1"] = "tok-1"
        val transport = controller.transportFor("c1")
        // The exact real sequence of the retained-command bug: p w d CR,
        // each one its own key event. Before the lane, each launched its
        // own IO coroutine and could reorder at JNI admission.
        for (b in byteArrayOf('p'.code.toByte(), 'w'.code.toByte(), 'd'.code.toByte(), 0x0D)) {
            transport.write(byteArrayOf(b))
        }
        assertEquals(listOf("tok-1|p", "tok-1|w", "tok-1|d", "tok-1|\r"), sent)
        assertTrue("an ordered drain under the live token reports nothing: $issues",
            issues.isEmpty())
    }

    @Test
    fun retiredTokenQueuedInputIsRefusedNotDeliveredToTheReplacement() {
        val sent = mutableListOf<String>()
        val issues = mutableListOf<String>()
        val input = QueuedDispatcher() // consumer cannot run until the test advances it
        val (controller, _) = laneController(input, sent, issues)
        val tokens = seedMap<String>(controller, "sessionTokens")
        tokens["c1"] = "tok-1"
        controller.transportFor("c1").write("x".toByteArray()) // admitted as tok-1
        // Reset + reopen BEFORE the drain: the conversation now owns tok-2.
        tokens["c1"] = "tok-2"
        input.drainAll()
        assertTrue("queued input of a retired token must never reach the replacement session: $sent",
            sent.isEmpty())
        assertTrue(issues.any { it.contains("c1") && it.contains("inputTokenRetired") })
    }

    @Test
    fun staleGenerationQueuedInputIsRefusedAfterANewRootBinds() {
        val sent = mutableListOf<String>()
        val issues = mutableListOf<String>()
        val input = QueuedDispatcher()
        val (controller, root) = laneController(input, sent, issues)
        val tokens = seedMap<String>(controller, "sessionTokens")
        tokens["c1"] = "tok-1"
        controller.transportFor("c1").write("x".toByteArray()) // admitted as epoch 1 / tok-1
        // A new Root generation reuses the controller (stopAndJoin never
        // clears sessionTokens) with a DIFFERENT epoch and token: the
        // admitted-epoch pin on the queued item must refuse it.
        root.epoch = 2L
        setFieldLong(controller, "boundEpoch", 2L)
        tokens["c1"] = "tok-2"
        input.drainAll()
        assertTrue("old-world input must never enter the new world: $sent", sent.isEmpty())
        assertTrue(issues.any { it.contains("inputGenerationStale") })
    }

    @Test
    fun offeredBytesAreCopiedBeforeQueuingSoCallerReuseCannotCorruptInput() {
        val sent = mutableListOf<String>()
        val issues = mutableListOf<String>()
        val input = QueuedDispatcher()
        val (controller, _) = laneController(input, sent, issues)
        seedMap<String>(controller, "sessionTokens")["c1"] = "tok-1"
        val buffer = byteArrayOf('v'.code.toByte(), 'w'.code.toByte())
        controller.transportFor("c1").write(buffer)
        buffer[0] = 'X'.code.toByte() // the caller reuses its array after write()
        input.drainAll()
        assertEquals(listOf("tok-1|vw"), sent)
    }

    @Test
    fun inputRefusalsAreTruthfulUnboundUnknownOverflowAndByteBudget() {
        val sent = mutableListOf<String>()
        val issues = mutableListOf<String>()
        val input = QueuedDispatcher() // nothing drains: the burst stays buffered
        val (controller, root) = laneController(input, sent, issues)
        // 1) unknown conversation under a live generation: sessionUnknown.
        controller.transportFor("c9").write("a".toByteArray())
        assertTrue(issues.any { it.contains("c9") && it.contains("sessionUnknown") })
        assertTrue(sent.isEmpty())
        // 2) unbound generation: hostUnbound — checked BEFORE the token,
        // even though this conversation IS token-bound.
        seedMap<String>(controller, "sessionTokens")["c1"] = "tok-1"
        root.epoch = null
        setFieldLong(controller, "boundEpoch", 0L)
        controller.transportFor("c1").write("a".toByteArray())
        assertTrue(issues.last().contains("hostUnbound"))
        // Restore the live binding for the bounded-lane checks.
        root.epoch = 1L
        setFieldLong(controller, "boundEpoch", 1L)
        // 3) bounded packet count: exactly InputLaneCapacity items admitted,
        // the next write is an EXPLICIT refusal (never a silent drop).
        val transport = controller.transportFor("c1")
        repeat(128) { transport.write(byteArrayOf('q'.code.toByte())) }
        val issuesBeforeOverflow = issues.size
        transport.write("overflow".toByteArray())
        assertEquals(issuesBeforeOverflow + 1, issues.size)
        assertTrue(issues.last().contains("inputLaneOverflow"))
        input.drainAll()
        assertEquals("the admitted burst drains intact, in order, nothing fabricated",
            128, sent.size)
        assertTrue(sent.all { it == "tok-1|q" })
        // 4) bounded BYTES: a fresh lane under the packet cap but over the
        // byte budget refuses too (an item count alone is not boundedness).
        seedMap<String>(controller, "sessionTokens")["c2"] = "tok-2"
        val transport2 = controller.transportFor("c2")
        val chunk = ByteArray(16 * 1024) { 'b'.code.toByte() }
        repeat(16) { transport2.write(chunk) } // 16 * 16 KiB = the 256 KiB budget
        val issuesBeforeBudget = issues.size
        transport2.write(chunk) // 17th -> over budget
        assertEquals(issuesBeforeBudget + 1, issues.size)
        assertTrue(issues.last().contains("inputLaneByteBudget"))
    }

    @Test
    fun rootStopClosesAndJoinsTheOwnedInputWorkersBeforeDeclaringStopped() = runBlocking {
        val sent = mutableListOf<String>()
        val issues = mutableListOf<String>()
        val (controller, _) = laneController(Dispatchers.Unconfined, sent, issues)
        seedMap<String>(controller, "sessionTokens")["c1"] = "tok-1"
        controller.transportFor("c1").write(byteArrayOf('x'.code.toByte()))
        assertEquals(listOf("tok-1|x"), sent) // worker live and ordered
        assertTrue(controller.stopAndJoin(1L, 1_000))
        val lanes = seedMap<Any>(controller, "inputLanes")
        assertTrue("a true stop means every owned worker provably finished", lanes.isEmpty())
        // After a truthful stop the generation is stopped: a late write is
        // refused truthfully at the CLAIM fence and no new lane worker may
        // be created behind the stop's back.
        val issuesBefore = issues.size
        controller.transportFor("c1").write(byteArrayOf('y'.code.toByte()))
        assertEquals(issuesBefore + 1, issues.size)
        assertTrue(issues.last().contains("hostUnbound"))
        assertTrue("no worker may be created after a truthful stop", lanes.isEmpty())
        assertEquals(1, sent.size)
    }

    @Test
    fun laneJoinTimeoutRetainsOwnershipAndReportsFalseWithoutSilentReuse() = runBlocking {
        val sent = mutableListOf<String>()
        val issues = mutableListOf<String>()
        val input = QueuedDispatcher() // the worker can never run: the join cannot complete
        val (controller, _) = laneController(input, sent, issues)
        seedMap<String>(controller, "sessionTokens")["c1"] = "tok-1"
        controller.transportFor("c1").write(byteArrayOf('x'.code.toByte()))
        assertFalse("an unjoinable owned worker must NOT be declared stopped",
            controller.stopAndJoin(1L, 200))
        assertTrue(sent.isEmpty()) // nothing was submitted while ownership was unclear
        val lanes = seedMap<Any>(controller, "inputLanes")
        assertEquals("the retained worker stays owned for a retry", 1, lanes.size)
        // Later writes refuse truthfully at the claim fence (the generation
        // is stopping), and a retry still cannot join → still false.
        controller.transportFor("c1").write(byteArrayOf('y'.code.toByte()))
        assertTrue(issues.any { it.contains("hostUnbound") })
        assertFalse(controller.stopAndJoin(1L, 50))
        assertEquals(1, lanes.size)
        assertTrue(sent.isEmpty())
    }

    @Test
    fun stopAfterReaderRetirementStillProvesLanesJoinedBeforeTrue() = runBlocking {
        val sent = mutableListOf<String>()
        val issues = mutableListOf<String>()
        val input = QueuedDispatcher() // the worker can never run: the join cannot complete
        val (controller, root) = laneController(input, sent, issues)
        seedMap<String>(controller, "sessionTokens")["c1"] = "tok-1"
        controller.transportFor("c1").write(byteArrayOf('x'.code.toByte()))
        // The reader's finally already ran on its own: boundEpoch zeroed
        // BEFORE any lane join. boundEpoch==0 alone must NOT be accepted
        // as proof that the owned workers are gone.
        root.epoch = null
        setFieldLong(controller, "boundEpoch", 0L)
        assertFalse("retained unjoined workers must keep stopAndJoin false",
            controller.stopAndJoin(1L, 100))
        val lanes = seedMap<Any>(controller, "inputLanes")
        assertEquals("ownership retained for a retry", 1, lanes.size)
        // A late write is refused truthfully; no new lane appears.
        val before = issues.size
        controller.transportFor("c1").write(byteArrayOf('y'.code.toByte()))
        assertEquals(before + 1, issues.size)
        assertTrue(issues.last().contains("hostUnbound"))
        assertEquals(1, lanes.size)
        assertTrue(sent.isEmpty())
    }

    @Test
    fun typedInputRefusalsSurfaceThroughTheWatcherAndClearOnFreshSession() {
        val sent = mutableListOf<String>()
        val issues = mutableListOf<String>()
        val (controller, root) = laneController(Dispatchers.Unconfined, sent, issues)
        val observed = mutableListOf<TerminalInputIssue?>()
        controller.watchInputIssues("c1") { observed.add(it) }
        // A typed refusal is a USER-VISIBLE truth, not a log-only one:
        // unbind the generation and write.
        root.epoch = null
        setFieldLong(controller, "boundEpoch", 0L)
        controller.transportFor("c1").write("a".toByteArray())
        controller.transportFor("c1").write("b".toByteArray())
        assertEquals(2, observed.size)
        assertEquals("hostUnbound", observed[0]?.code)
        assertEquals(1, observed[0]?.count)
        assertEquals("hostUnbound", observed[1]?.code)
        assertEquals("consecutive same-code refusals accumulate", 2, observed[1]?.count)
        // A fresh session (attachOrOpen success) or an accepted close clears
        // the surfaced issue — here driven through the same internal hook.
        controller.clearInputIssue("c1")
        assertEquals(3, observed.size)
        assertNull(observed[2])
        // A new refusal after the clear starts a fresh count.
        controller.transportFor("c1").write("c".toByteArray())
        assertEquals("hostUnbound", observed.last()?.code)
        assertEquals(1, observed.last()?.count)
        assertTrue(sent.isEmpty())
    }

    /* ---- run-output binding repair (job-9d948bf8148347c0; device evidence
     * 2026-10-25: an accepted IDE Run produced NO visible output because the
     * Run's sessionToken was never bound — only attachOrOpen assigned tokens,
     * while native answers the runDraft reply BEFORE the first output.
     * Main review round 2: waiter-gated binding, captured-binding CAS,
     * engine ensure at the owned binding boundary, epoch-guarded CAS
     * retirement) ---- */

    private fun seedRunIntent(
        controller: G04TerminalHostController,
        requestID: String,
        conversationID: String,
        epoch: Long,
        previousToken: String? = null,
    ) {
        seedMap<G04TerminalHostController.PendingRunOpen>(controller, "pendingRunOpens")[requestID] =
            G04TerminalHostController.PendingRunOpen(conversationID, epoch, previousToken)
    }

    /** Registers the reply waiter runDraft would hold: a Run binding is only
     * allowed while this exact request is still waiter-owned (review 1). */
    private fun seedReplyWaiter(controller: G04TerminalHostController, requestID: String) {
        seedMap<kotlinx.coroutines.CompletableDeferred<TerminalActionReply>>(
            controller, "replies")[requestID] = kotlinx.coroutines.CompletableDeferred()
    }

    private fun watchEnsuredEngines(controller: G04TerminalHostController): MutableList<String> {
        val ensured = mutableListOf<String>()
        controller.engineEnsurer = { ensured.add(it) }
        return ensured
    }

    private fun actionReplyEvent(requestID: String, ok: Boolean, token: String? = null): ByteArray =
        buildString {
            append("""{"type":"actionReply","requestID":"$requestID","ok":$ok""")
            token?.let { append(""","sessionToken":"$it"""") }
            if (!ok) append(""","code":"notStarted","reason":"engineSlotBusy"""")
            append("}")
        }.toByteArray()

    @Test
    fun acceptedRunReplyBindsItsTokenAndEnsuresTheServiceOwnedEngine() {
        val (controller, _) = boundController(Dispatchers.Unconfined)
        val ensured = watchEnsuredEngines(controller)
        seedReplyWaiter(controller, "req-run-1")
        seedRunIntent(controller, "req-run-1", "c1", 1L)
        // Native ordering: the accepted reply arrives FIRST, carrying the
        // sessionToken; the binding must exist synchronously on this same
        // reader step so the immediately-following output page has an owner.
        assertTrue(controller.handleEvent(1L, actionReplyEvent("req-run-1", true, "tok-run")))
        assertEquals("tok-run", seedMap<String>(controller, "sessionTokens")["c1"])
        assertEquals("the engine is ensured AT the binding boundary, so a Run " +
            "before any pane mounted cannot drop its bytes (review 3)",
            listOf("c1"), ensured)
        val seeded = controller.currentSnapshot("c1")
        assertEquals("the projection is seeded exactly like a fresh attachOrOpen",
            TerminalSessionPhase.STARTING, seeded?.phase)
        assertEquals("tok-run", seeded?.sessionToken)
        val received = mutableListOf<String>()
        controller.addOutputListener("tok-run") { received.add(String(it)) }
        controller.deliverTerminalOutput("tok-run", "C05_IDE_RUN_OK".toByteArray())
        assertEquals(listOf("C05_IDE_RUN_OK"), received)
        // The intent is consumed: the same reply can never bind twice.
        assertTrue(seedMap<Any>(controller, "pendingRunOpens").isEmpty())
    }

    @Test
    fun replyAfterWaiterReleaseConsumesTheIntentWithoutBinding() {
        val (controller, _) = boundController(Dispatchers.Unconfined)
        val ensured = watchEnsuredEngines(controller)
        // Review 1's exact race: submit's timeout cleanup already removed the
        // waiter while runDraft's finally has not yet removed the intent. The
        // late reply must NOT bind — no waiter, no host-owned request.
        seedRunIntent(controller, "req-1", "c1", 1L)
        assertTrue(controller.handleEvent(1L, actionReplyEvent("req-1", true, "tok-run")))
        assertNull(seedMap<String>(controller, "sessionTokens")["c1"])
        assertNull(controller.currentSnapshot("c1"))
        assertTrue("no engine is ensured for a reply nobody waits on", ensured.isEmpty())
        assertTrue("the intent is consumed: it can never bind retroactively",
            seedMap<Any>(controller, "pendingRunOpens").isEmpty())
        // Even a waiter appearing afterwards cannot resurrect the consumed
        // intent (exactly one binding decision per registered request).
        seedReplyWaiter(controller, "req-1")
        assertTrue(controller.handleEvent(2L, actionReplyEvent("req-1", true, "tok-run")))
        assertNull(seedMap<String>(controller, "sessionTokens")["c1"])
    }

    @Test
    fun runReplyForARetiredGenerationOrEpochZeroNeverBinds() {
        // (a) the Root generation moved between submit and reply:
        val (controller, root) = boundController(Dispatchers.Unconfined, epoch = 1L)
        val ensured = watchEnsuredEngines(controller)
        seedReplyWaiter(controller, "req-old")
        seedRunIntent(controller, "req-old", "c1", 1L)
        root.epoch = 2L
        setFieldLong(controller, "boundEpoch", 2L)
        assertTrue(controller.handleEvent(1L, actionReplyEvent("req-old", true, "tok-old")))
        assertNull(seedMap<String>(controller, "sessionTokens")["c1"])
        assertNull(controller.currentSnapshot("c1"))
        assertTrue(ensured.isEmpty())
        // (b) an epoch-0 intent has no fallback route at all:
        val unbound = newController()
        seedReplyWaiter(unbound, "req-zero")
        seedRunIntent(unbound, "req-zero", "c2", 0L)
        assertTrue(unbound.handleEvent(1L, actionReplyEvent("req-zero", true, "tok-zero")))
        assertNull(seedMap<String>(unbound, "sessionTokens")["c2"])
        assertNull(unbound.currentSnapshot("c2"))
    }

    @Test
    fun refusedRunReplyConsumesTheIntentWithoutBinding() {
        val (controller, _) = boundController(Dispatchers.Unconfined)
        val ensured = watchEnsuredEngines(controller)
        seedReplyWaiter(controller, "req-busy")
        seedRunIntent(controller, "req-busy", "c1", 1L)
        assertTrue(controller.handleEvent(1L, actionReplyEvent("req-busy", false)))
        assertNull(seedMap<String>(controller, "sessionTokens")["c1"])
        assertTrue(ensured.isEmpty())
        assertTrue(seedMap<Any>(controller, "pendingRunOpens").isEmpty())
    }

    @Test
    fun overflowFenceClearsRunOpenIntentsSoNoReplyCanBindAfterwards() {
        val (controller, _) = boundController(Dispatchers.Unconfined)
        seedReplyWaiter(controller, "req-fenced")
        seedRunIntent(controller, "req-fenced", "c1", 1L)
        assertTrue(controller.handleEvent(1L, """{"type":"hostEventOverflow"}""".toByteArray()))
        assertTrue("a fenced host holds no owned run intents",
            seedMap<Any>(controller, "pendingRunOpens").isEmpty())
        assertTrue(controller.handleEvent(2L, actionReplyEvent("req-fenced", true, "tok-run")))
        assertNull(seedMap<String>(controller, "sessionTokens")["c1"])
    }

    @Test
    fun acceptedRunReplacesItsOwnStalePredecessorDespiteTheCachedMirror() {
        val (controller, _) = boundController(Dispatchers.Unconfined)
        val ensured = watchEnsuredEngines(controller)
        val tokens = seedMap<String>(controller, "sessionTokens")
        val snapshots = seedMap<TerminalSessionSnapshot>(controller, "snapshots")
        tokens["c1"] = "tok-old"
        // Review 2: the cached mirror can still claim the predecessor is live
        // (it lags a native slot release behind an awaited finish/status).
        // The native-accepted Run is authoritative — the CAS against the
        // binding captured at registration, not this snapshot, decides.
        snapshots["c1"] = TerminalSessionSnapshot(
            "c1", "tok-old", TerminalSessionPhase.RUNNING, "interactive", "",
            null, null, null, 0)
        seedReplyWaiter(controller, "req-1")
        seedRunIntent(controller, "req-1", "c1", 1L, previousToken = "tok-old")
        controller.handleEvent(1L, actionReplyEvent("req-1", true, "tok-run"))
        assertEquals("tok-run", tokens["c1"])
        assertEquals("tok-run", snapshots["c1"]?.sessionToken)
        assertEquals(TerminalSessionPhase.STARTING, snapshots["c1"]?.phase)
        assertEquals(listOf("c1"), ensured)
    }

    @Test
    fun aNewerBindingFencesTheOldRunReplyWithoutStealing() {
        val (controller, _) = boundController(Dispatchers.Unconfined)
        val ensured = watchEnsuredEngines(controller)
        val tokens = seedMap<String>(controller, "sessionTokens")
        // Run submitted while nothing was bound ...
        seedReplyWaiter(controller, "req-1")
        seedRunIntent(controller, "req-1", "c1", 1L, previousToken = null)
        // ... a newer accepted open/reset moved the binding before the reply:
        tokens["c1"] = "tok-shell"
        controller.handleEvent(1L, actionReplyEvent("req-1", true, "tok-run"))
        assertEquals("a late old Run must never steal the newer binding",
            "tok-shell", tokens["c1"])
        assertTrue("nothing is ensured for a fenced reply", ensured.isEmpty())
        assertTrue(seedMap<Any>(controller, "pendingRunOpens").isEmpty())
    }

    @Test
    fun resetRemovalBetweenSubmitAndReplyFencesTheRunBinding() {
        val (controller, _) = boundController(Dispatchers.Unconfined)
        val tokens = seedMap<String>(controller, "sessionTokens")
        tokens["c1"] = "tok-old"
        seedReplyWaiter(controller, "req-1")
        seedRunIntent(controller, "req-1", "c1", 1L, previousToken = "tok-old")
        // An explicit close/reset retired the predecessor mid-flight: the
        // captured binding no longer matches, so the reply is fenced.
        tokens.remove("c1")
        controller.handleEvent(1L, actionReplyEvent("req-1", true, "tok-run"))
        assertNull(tokens["c1"])
        assertNull(controller.currentSnapshot("c1"))
    }

    @Test
    fun immediateExitFinalBytesApplyBeforeTheOrderedRetirement() {
        val output = QueuedDispatcher()
        val (controller, _) = boundController(output)
        val ensured = watchEnsuredEngines(controller)
        val tokens = seedMap<String>(controller, "sessionTokens")
        seedReplyWaiter(controller, "req-run")
        seedRunIntent(controller, "req-run", "c1", 1L)
        // 1) accepted Run reply binds synchronously on the reader path:
        assertTrue(controller.handleEvent(1L, actionReplyEvent("req-run", true, "tok-run")))
        assertEquals("tok-run", tokens["c1"])
        assertEquals(listOf("c1"), ensured)
        val received = mutableListOf<String>()
        controller.addOutputListener("tok-run") { received.add(String(it)) }
        // 2) the program's final output is admitted right after (native
        //    publishes the initial page immediately after the reply):
        controller.deliverTerminalOutput("tok-run", "C05_IDE_RUN_OK".toByteArray())
        // 3) the synchronous CLOSED status lands while the page is queued:
        val closed = ("""{"type":"terminalStatus","conversationID":"c1","sessionToken":"tok-run",""" +
            """"phase":"closed","purpose":"run","runID":"","exitCode":0,"rolledOverBytes":0}""").toByteArray()
        assertTrue(controller.handleEvent(2L, closed))
        assertEquals("the phase truth is applied synchronously",
            TerminalSessionPhase.CLOSED, controller.currentSnapshot("c1")?.phase)
        assertEquals("retirement is ORDERED on the output dispatcher, not applied inline",
            "tok-run", tokens["c1"])
        assertEquals(0, received.size)
        // 4) draining the serialized dispatcher: the accepted page applies
        //    FIRST, then the exact CAS retirement runs behind it:
        output.drainAll()
        assertEquals(listOf("C05_IDE_RUN_OK"), received)
        assertNull(tokens["c1"])
        // 5) post-retirement output stays fenced — never a fabricated delivery:
        controller.deliverTerminalOutput("tok-run", "late".toByteArray())
        output.drainAll()
        assertEquals(1, received.size)
    }

    @Test
    fun closedStatusRetirementNeverErasesAReplacementToken() {
        val output = QueuedDispatcher()
        val (controller, _) = boundController(output)
        val tokens = seedMap<String>(controller, "sessionTokens")
        tokens["c1"] = "tok-old"
        val closed = ("""{"type":"terminalStatus","conversationID":"c1","sessionToken":"tok-old",""" +
            """"phase":"closed","purpose":"interactive","runID":"","rolledOverBytes":0}""").toByteArray()
        assertTrue(controller.handleEvent(1L, closed))
        // A Reset/reopen re-bound the conversation BEFORE the queued
        // retirement applied (the reset race): the removal is an exact
        // per-conversation CAS, so the replacement survives.
        tokens["c1"] = "tok-new"
        output.drainAll()
        assertEquals("tok-new", tokens["c1"])
    }

    @Test
    fun staleRootQueuedRetirementCannotRemoveANewRootBindingEvenWithAReusedToken() {
        val output = QueuedDispatcher()
        val (controller, root) = boundController(output, epoch = 1L)
        val tokens = seedMap<String>(controller, "sessionTokens")
        tokens["c1"] = "tok-reused"
        val closed = ("""{"type":"terminalStatus","conversationID":"c1","sessionToken":"tok-reused",""" +
            """"phase":"closed","purpose":"interactive","runID":"","rolledOverBytes":0}""").toByteArray()
        assertTrue(controller.handleEvent(1L, closed))
        // Review 4: a new Root generation re-binds and (deterministic test
        // shape) the SAME token string is live again before the queued
        // control runs. The captured-epoch guard must refuse the old-Root
        // retirement — value match alone is not ownership.
        root.epoch = 2L
        setFieldLong(controller, "boundEpoch", 2L)
        tokens["c1"] = "tok-reused"
        output.drainAll()
        assertEquals("an old-Root queued retirement must never remove the new binding",
            "tok-reused", tokens["c1"])
    }
}
