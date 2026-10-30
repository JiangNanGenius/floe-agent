// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
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
        // 3) bounded packet count: exactly InputLaneCapacity UNCOALESCABLE
        // frames — each larger than half the coalescing cap, same token/epoch, so no two
        // fit one merged frame — are admitted, and the next write is an
        // EXPLICIT refusal (never a silent drop). linux-product80 changed
        // this fixture from 1-byte frames because tiny consecutive frames
        // now merge at the tail (the retained ~350-byte adb-input burst
        // with inputLaneOverflow x3 on device 2026-10-28 is exactly the
        // false pressure this removes); overflow stays reachable, honest
        // and bounded when tails are full.
        val transport = controller.transportFor("c1")
        val frame = ByteArray(1025) { 'q'.code.toByte() }
        repeat(128) { transport.write(frame) }
        val issuesBeforeOverflow = issues.size
        // The 129th write must ALSO be too large to coalesce into the tail
        // (1025 + 1025 > MaxCoalescedInputFrameBytes), otherwise the lane
        // rightly merges it and never reaches the packet cap. Overflow stays
        // reachable, honest and bounded only for a genuinely non-mergeable
        // frame; a tiny 8-byte write is now absorbed by design.
        transport.write(frame)
        assertEquals(issuesBeforeOverflow + 1, issues.size)
        assertTrue(issues.last().contains("inputLaneOverflow"))
        input.drainAll()
        assertEquals("the admitted burst drains intact, in order, nothing fabricated",
            128, sent.size)
        val expectedFrame = "tok-1|" + frame.decodeToString()
        assertTrue(sent.all { it == expectedFrame })
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

    /** linux-product80 regression (authored, NOT executed by the authoring
     * job): the retained real product failure was a rapid small-keystroke
     * burst (hardware/adb input text, ~350 bytes, filename
     * floe-c15-apt-update.log) honestly refused with inputLaneOverflow x3
     * while the byte budget sat nearly empty. Consecutive same-token/
     * same-epoch frames must coalesce in order instead of overflowing. */
    @Test
    fun keystrokeBurstCoalescesInOrderInsteadOfOverflowRefusal() {
        val sent = mutableListOf<String>()
        val issues = mutableListOf<String>()
        val input = QueuedDispatcher() // nothing drains during the burst
        val (controller, _) = laneController(input, sent, issues)
        seedMap<String>(controller, "sessionTokens")["c1"] = "tok-1"
        val transport = controller.transportFor("c1")
        val burst = ("floe-c15-apt-update.log" +
            ".".repeat(200)).toByteArray(Charsets.UTF_8)
        for (b in burst) transport.write(byteArrayOf(b))
        assertTrue("a small keystroke burst within the byte budget must not " +
            "overflow while tails are coalescable: $issues", issues.isEmpty())
        input.drainAll()
        assertEquals("the whole burst merges into bounded frames", 1, sent.size)
        assertEquals("tok-1|" + burst.decodeToString(), sent[0])
    }

    /** Coalescing is bounded, ordered and never fabricates: frames beyond
     * one coalescing cap keep draining as successive merged frames whose
     * concatenation is EXACTLY the written byte stream, and the merge only
     * applies to the same admitted token/epoch. */
    @Test
    fun coalescedFramesStayBoundedOrderedAndWithoutDuplication() {
        val sent = mutableListOf<String>()
        val issues = mutableListOf<String>()
        val input = QueuedDispatcher()
        val (controller, _) = laneController(input, sent, issues)
        seedMap<String>(controller, "sessionTokens")["c1"] = "tok-1"
        val transport = controller.transportFor("c1")
        repeat(3000) { transport.write(byteArrayOf('a'.code.toByte())) }
        assertTrue("2048-byte coalescing bounds keep a 3000-byte burst inside " +
            "the lane without refusals: $issues", issues.isEmpty())
        input.drainAll()
        assertEquals(2, sent.size)
        assertEquals("tok-1|" + "a".repeat(2048), sent[0])
        assertEquals("tok-1|" + "a".repeat(952), sent[1])
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
        // bind the live conversation, then unbind the generation and write.
        seedMap<String>(controller, "sessionTokens")["c1"] = "tok-1"
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

    /* ---- explicit interactive-terminal → model handoff (job-c4dd7334fa5341d2,
       Main ruling 2026-10-28) ----

       Device evidence 2026-10-27 (FIRST_FAILURE.json): one ordinary task held a
       real interactive PTY, the model proposed ONE `pwd && printf …`, a human
       tapped the ordinary approval, and the engine answered
       `exit=75 status=notStarted` because the SAME conversation's terminal
       still held the single runtime-UID workload slot. The same task with that
       terminal genuinely ended returned `exit=0` (closed-case ACTUAL_RESULT),
       so the slot itself is healthy and only the handoff was missing.

       These tests pin the repaired contract: the captured terminal is closed
       EXACTLY by its own token, the projected settlement is awaited, and the
       REAL engine-slot release is proven before the caller may approve once.
       Every refusal path proves NOTHING was released and no foreign or
       replacement session was touched. The single slot, its caps and the
       close/settle authority are unchanged: no cap is raised and no duplicate
       worker is started here. */

    private fun liveSnapshot(
        conversationID: String,
        token: String,
        phase: TerminalSessionPhase = TerminalSessionPhase.RUNNING,
        purpose: String = "interactive",
    ) = TerminalSessionSnapshot(
        conversationID, token, phase, purpose, "", null, null, null, 0)

    /** A bound controller with BOTH handoff seams injected. The recorded
     * [events] list proves the close → settle → REAL-release ordering, which is
     * the whole point of the repair: no release (and therefore no approve) may
     * precede an actual join. */
    private fun handoffController(
        epoch: Long = 7L,
        closeReply: suspend (String, String) -> TerminalActionReply =
            { _, _ -> TerminalActionReply.Success(buildJsonObject { }) },
        releaseProof: suspend (Int) -> Boolean = { true },
        onClose: ((LiveRoot) -> Unit)? = null,
    ): Triple<G04TerminalHostController, LiveRoot, MutableList<String>> {
        val root = LiveRoot(epoch)
        val events = mutableListOf<String>()
        val controller = G04TerminalHostController(
            CoroutineScope(Dispatchers.Unconfined),
            Dispatchers.Unconfined,
            Dispatchers.Unconfined,
            engineSlotReleaseProof = { timeout ->
                events.add("releaseProof:$timeout"); releaseProof(timeout)
            },
            closeSinkOverride = { conversationID, token ->
                events.add("close:$conversationID:$token")
                onClose?.invoke(root)
                closeReply(conversationID, token)
            },
        ) { root.epoch }
        setFieldLong(controller, "boundEpoch", epoch)
        (G04TerminalHostController::class.java.getDeclaredField("stopped")
            .apply { isAccessible = true }.get(controller)
            as java.util.concurrent.atomic.AtomicBoolean).set(false)
        return Triple(controller, root, events)
    }

    /** Seeds one live interactive terminal exactly as an accepted open plus its
     * authoritative native status event would, and returns the real capture. */
    private fun seedLiveTerminal(
        controller: G04TerminalHostController,
        conversationID: String,
        token: String,
        purpose: String = "interactive",
    ): TerminalHandoffCapture {
        seedMap<String>(controller, "sessionTokens")[conversationID] = token
        seedMap<TerminalSessionSnapshot>(controller, "snapshots")[conversationID] =
            liveSnapshot(conversationID, token, purpose = purpose)
        return checkNotNull(controller.liveInteractiveTerminal(conversationID)) {
            "the seeded live interactive terminal must be capturable"
        }
    }

    /** Marks the projected session settled, exactly as the authoritative
     * `terminalStatus` event does after an accepted close. */
    private fun settleSnapshot(
        controller: G04TerminalHostController,
        conversationID: String,
        token: String,
    ) {
        seedMap<TerminalSessionSnapshot>(controller, "snapshots")[conversationID] =
            liveSnapshot(conversationID, token, phase = TerminalSessionPhase.CLOSED)
    }

    /** Exercises real submit/reply futures and status decoding. The JNI seam
     * emits both events before submit returns; the accepted token is now bound
     * at the reply event itself, so the following RUNNING status already
     * observes the captured handle (the deferred coroutine only re-publishes). */
    private fun interactiveOpenOrderingController(
        statusBeforeReplyResume: Boolean,
        root: LiveRoot,
        afterNativeEvents: () -> Unit = {},
    ): G04TerminalHostController {
        lateinit var controller: G04TerminalHostController
        controller = G04TerminalHostController(
            CoroutineScope(Dispatchers.Unconfined),
            Dispatchers.Unconfined,
            Dispatchers.Unconfined,
            nativeSubmitOverride = { descriptor, _ ->
                val action = Json.parseToJsonElement(String(descriptor)) as JsonObject
                assertEquals("terminalOpen", action["action"]?.jsonPrimitive?.content)
                val requestID = checkNotNull(action["requestID"]?.jsonPrimitive?.content)
                controller.handleEvent(0L,
                    ("{\"type\":\"actionReply\",\"requestID\":\"" + requestID +
                        "\",\"ok\":true,\"sessionToken\":\"tok-open\"}").toByteArray())
                if (statusBeforeReplyResume) controller.handleEvent(0L,
                    """{"type":"terminalStatus","conversationID":"c1","sessionToken":"tok-open",
                        "phase":"running","purpose":"interactive"}""".toByteArray())
                afterNativeEvents()
                1L
            },
        ) { root.epoch }
        // The binding boundary now ensures the service-owned engine; this
        // focused JVM test keeps that registry out of the Android emulator.
        controller.engineEnsurer = { }
        setFieldLong(controller, "boundEpoch", 7L)
        (G04TerminalHostController::class.java.getDeclaredField("stopped")
            .apply { isAccessible = true }.get(controller)
            as java.util.concurrent.atomic.AtomicBoolean).set(false)
        return controller
    }

    @Test
    fun interactiveReplyReprojectsOwnedCaptureWhenRunningStatusArrivesBeforeOpenResumes() = runBlocking {
        val controller = interactiveOpenOrderingController(true, LiveRoot(7L))
        val observed = java.util.concurrent.CopyOnWriteArrayList<TerminalHandoffCapture?>()
        val detach = controller.watchSessions("c1") {
            observed.add(controller.liveInteractiveTerminal("c1"))
        }
        val result = controller.attachOrOpen("c1", null, 80, 24)
        assertEquals(TerminalSessionPhase.RUNNING, result?.phase)
        assertEquals("tok-open", result?.sessionToken)
        assertEquals("the accepted token is bound at the reply, so the running status already projects the capture",
            TerminalHandoffCapture("c1", "tok-open", 7L), observed.first())
        assertEquals("the deferred open coroutine re-publishes the SAME authoritative capture",
            TerminalHandoffCapture("c1", "tok-open", 7L), observed.last())
        detach()
    }

    @Test
    fun interactiveReplyPublishesStartingWithoutInventingRunningWhenStatusComesLater() = runBlocking {
        val controller = interactiveOpenOrderingController(false, LiveRoot(7L))
        val phases = java.util.concurrent.CopyOnWriteArrayList<TerminalSessionPhase>()
        val detach = controller.watchSessions("c1") { phases.add(it.phase) }
        val result = controller.attachOrOpen("c1", null, 80, 24)
        assertEquals(TerminalSessionPhase.STARTING, result?.phase)
        assertEquals(listOf(TerminalSessionPhase.STARTING), phases.toList())
        controller.handleEvent(0L,
            """{"type":"terminalStatus","conversationID":"c1","sessionToken":"tok-open",
                "phase":"running","purpose":"interactive"}""".toByteArray())
        assertEquals(listOf(TerminalSessionPhase.STARTING, TerminalSessionPhase.RUNNING), phases.toList())
        assertEquals(TerminalHandoffCapture("c1", "tok-open", 7L),
            controller.liveInteractiveTerminal("c1"))
        detach()
    }

    @Test
    fun interactiveReplyNeverProjectsHandoffCaptureIntoAChangedNativeEpoch() = runBlocking {
        val root = LiveRoot(7L)
        val controller = interactiveOpenOrderingController(true, root) { root.epoch = 8L }
        val observed = java.util.concurrent.CopyOnWriteArrayList<TerminalHandoffCapture?>()
        val detach = controller.watchSessions("c1") {
            observed.add(controller.liveInteractiveTerminal("c1"))
        }
        controller.attachOrOpen("c1", null, 80, 24)
        assertTrue(observed.isNotEmpty())
        assertTrue("the status observed while generation 7 was live may project its own capture",
            observed.any { it == TerminalHandoffCapture("c1", "tok-open", 7L) })
        assertNull("after the epoch moves, a late binding must not authorize stopping another Root's work",
            observed.last())
        assertNull(controller.liveInteractiveTerminal("c1"))
        detach()
    }

    /** A bound controller whose `nativeSubmitOverride` lets a test choose the
     * exact native event order for one `terminalOpen` (reply, status, both).
     * No real engine is constructed; no production guard is bypassed. */
    private fun interactiveReplyController(
        root: LiveRoot,
        onReply: (G04TerminalHostController, String) -> Unit,
    ): G04TerminalHostController {
        lateinit var controller: G04TerminalHostController
        controller = G04TerminalHostController(
            CoroutineScope(Dispatchers.Unconfined),
            Dispatchers.Unconfined,
            Dispatchers.Unconfined,
            nativeSubmitOverride = { descriptor, _ ->
                val action = Json.parseToJsonElement(String(descriptor)) as JsonObject
                assertEquals("terminalOpen", action["action"]?.jsonPrimitive?.content)
                onReply(controller, checkNotNull(action["requestID"]?.jsonPrimitive?.content))
                1L
            },
        ) { root.epoch }
        controller.engineEnsurer = { }
        setFieldLong(controller, "boundEpoch", 7L)
        (G04TerminalHostController::class.java.getDeclaredField("stopped")
            .apply { isAccessible = true }.get(controller)
            as java.util.concurrent.atomic.AtomicBoolean).set(false)
        return controller
    }

    private fun acceptedOpenReply(requestID: String, token: String): ByteArray =
        ("{\"type\":\"actionReply\",\"requestID\":\"" + requestID +
            "\",\"ok\":true,\"sessionToken\":\"" + token + "\"}").toByteArray()

    private fun nativeStatus(conversationID: String, token: String, phase: String): ByteArray =
        ("{\"type\":\"terminalStatus\",\"conversationID\":\"" + conversationID +
            "\",\"sessionToken\":\"" + token + "\",\"phase\":\"" + phase +
            "\",\"purpose\":\"interactive\"}").toByteArray()

    @Test
    fun acceptedOpenBindsThePaneTokenAtTheReplyBeforeTheWaiterResumes() = runBlocking {
        var boundAtReply: String? = null
        val controller = interactiveReplyController(LiveRoot(7L)) { c, requestID ->
            c.handleEvent(0L, acceptedOpenReply(requestID, "tok-open"))
            // The mailbox reader is still inside the reply event here; the
            // deferred open coroutine cannot have resumed yet. First output
            // and running status follow this point in mailbox order.
            boundAtReply = seedMap<String>(c, "sessionTokens")["c1"]
        }
        val result = controller.attachOrOpen("c1", null, 80, 24)
        assertEquals("the accepted token must already be bound when the reply event returns",
            "tok-open", boundAtReply)
        assertEquals("tok-open", result?.sessionToken)
    }

    @Test
    fun runningStatusUnderTheNativeUUIDSpellingReachesTheOriginalPaneKey() = runBlocking {
        val controller = interactiveReplyController(LiveRoot(7L)) { c, requestID ->
            c.handleEvent(0L, acceptedOpenReply(requestID, "tok-open"))
            // Native names the event with UUID.uuidString (canonical
            // uppercase); the App route/holder key is the original spelling.
            c.handleEvent(0L, nativeStatus("C1", "tok-open", "running"))
        }
        val phases = java.util.concurrent.CopyOnWriteArrayList<TerminalSessionPhase>()
        val detach = controller.watchSessions("c1") { phases.add(it.phase) }
        val result = controller.attachOrOpen("c1", null, 80, 24)
        assertEquals("the authoritative running phase must reach the pane key",
            TerminalSessionPhase.RUNNING, result?.phase)
        assertEquals(TerminalSessionPhase.RUNNING, controller.currentSnapshot("c1")?.phase)
        assertEquals(TerminalSessionPhase.RUNNING, phases.last())
        detach()
    }

    @Test
    fun statusThatPrecedesTheReplyIsAdoptedOnlyByItsExactToken() = runBlocking {
        val controller = interactiveReplyController(LiveRoot(7L)) { c, requestID ->
            c.handleEvent(0L, nativeStatus("C1", "tok-open", "running"))
            c.handleEvent(0L, acceptedOpenReply(requestID, "tok-open"))
        }
        assertEquals("an earlier authoritative status for the SAME token is adopted, never overwritten by STARTING",
            TerminalSessionPhase.RUNNING,
            controller.attachOrOpen("c1", null, 80, 24)?.phase)
    }

    @Test
    fun statusForAnotherTokenNeverProjectsIntoTheAcceptedKey() = runBlocking {
        val controller = interactiveReplyController(LiveRoot(7L)) { c, requestID ->
            c.handleEvent(0L, nativeStatus("C1", "tok-other", "running"))
            c.handleEvent(0L, acceptedOpenReply(requestID, "tok-open"))
        }
        assertEquals("the pane key must stay at its honest seed; no foreign token's phase is adopted",
            TerminalSessionPhase.STARTING,
            controller.attachOrOpen("c1", null, 80, 24)?.phase)
    }

    @Test
    fun closedStatusReachesThePaneKeyAfterTheCloseReplyRemovedTheToken() = runBlocking {
        val controller = interactiveReplyController(LiveRoot(7L)) { c, requestID ->
            c.handleEvent(0L, acceptedOpenReply(requestID, "tok-open"))
            c.handleEvent(0L, nativeStatus("C1", "tok-open", "running"))
        }
        controller.attachOrOpen("c1", null, 80, 24)
        // `closeSession` removes the pane binding as soon as the accepted
        // close reply arrives, which is BEFORE the store's CLOSED status
        // (the reply is emitted first). The pane snapshot for this exact
        // token is the remaining ownership proof and must still receive it.
        seedMap<String>(controller, "sessionTokens").remove("c1")
        val phases = java.util.concurrent.CopyOnWriteArrayList<TerminalSessionPhase>()
        val detach = controller.watchSessions("c1") { phases.add(it.phase) }
        controller.handleEvent(0L, nativeStatus("C1", "tok-open", "closed"))
        assertEquals(TerminalSessionPhase.CLOSED, controller.currentSnapshot("c1")?.phase)
        assertEquals(TerminalSessionPhase.CLOSED, phases.last())
        detach()
    }

    @Test
    fun liveInteractiveTerminalAnswersOnlyForThisHostsOwnLiveManualTerminal() {
        val (controller, root, _) = handoffController(epoch = 11L)
        val capture = seedLiveTerminal(controller, "c1", "tok-1")
        assertEquals("c1", capture.conversationID)
        assertEquals("tok-1", capture.sessionToken)
        assertEquals(11L, capture.nativeEpoch)

        // A different conversation is never answered from this one's state.
        assertNull(controller.liveInteractiveTerminal("c2"))

        // A language/run-draft session is NOT a manual terminal, so ending it
        // is never offered as a handoff.
        seedMap<TerminalSessionSnapshot>(controller, "snapshots")["c1"] =
            liveSnapshot("c1", "tok-1", purpose = "run")
        assertNull(controller.liveInteractiveTerminal("c1"))

        // Every settled phase is a terminal that no longer holds anything.
        for (phase in listOf(TerminalSessionPhase.CLOSED, TerminalSessionPhase.EXITED,
                TerminalSessionPhase.STOPPED, TerminalSessionPhase.FAULT)) {
            seedMap<TerminalSessionSnapshot>(controller, "snapshots")["c1"] =
                liveSnapshot("c1", "tok-1", phase = phase)
            assertNull("phase $phase must not be offered", controller.liveInteractiveTerminal("c1"))
        }

        // A snapshot of a RETIRED token is not a live terminal, and a
        // replacement token is a different terminal.
        seedMap<TerminalSessionSnapshot>(controller, "snapshots")["c1"] =
            liveSnapshot("c1", "tok-1")
        seedMap<String>(controller, "sessionTokens")["c1"] = "tok-2"
        assertNull(controller.liveInteractiveTerminal("c1"))

        // No captured handle at all: nothing is owned here.
        seedMap<String>(controller, "sessionTokens").remove("c1")
        assertNull(controller.liveInteractiveTerminal("c1"))

        // A moved-on or unbound Root generation answers nothing.
        seedMap<String>(controller, "sessionTokens")["c1"] = "tok-1"
        root.epoch = 12L
        assertNull("a replaced Root generation must not answer",
            controller.liveInteractiveTerminal("c1"))
        root.epoch = null
        assertNull(controller.liveInteractiveTerminal("c1"))
    }

    @Test
    fun unboundHostNeverOffersATerminalForHandoff() {
        val controller = newController()
        seedMap<String>(controller, "sessionTokens")["c1"] = "tok-1"
        seedMap<TerminalSessionSnapshot>(controller, "snapshots")["c1"] =
            liveSnapshot("c1", "tok-1")
        assertNull(controller.liveInteractiveTerminal("c1"))
    }

    @Test
    fun handoffReleasesOnlyAfterTheRealEngineSlotProof() = runBlocking {
        var settled: G04TerminalHostController? = null
        val (controller, _, events) = handoffController(
            closeReply = { conversationID, token ->
                settleSnapshot(checkNotNull(settled), conversationID, token)
                TerminalActionReply.Success(buildJsonObject { })
            },
            releaseProof = { true },
        )
        settled = controller
        val capture = seedLiveTerminal(controller, "c1", "tok-1")

        val result = controller.endCapturedTerminalForHandoff(
            capture, settledWaitMillis = 500, releaseProofTimeoutMillis = 1_000)

        assertEquals(TerminalHandoffResult.Released, result)
        // Ordering IS the contract: the exact captured token is closed first
        // and the REAL release proof is consulted only afterwards, exactly
        // once (no hidden retry, no second dispatch, no elapsed-time success).
        assertEquals(listOf("close:c1:tok-1", "releaseProof:1000"), events)
        // The handle is unbound by an exact CAS against the captured token.
        assertNull(seedMap<String>(controller, "sessionTokens")["c1"])
    }

    @Test
    fun anAcceptedStopWithoutRealReleaseNeverAnswersReleased() = runBlocking {
        // THE regression: an accepted `terminalClose` plus a projected CLOSED
        // are only an ACCEPTED stop. Without the engine's real lease release
        // the caller must not approve, or the command is dispatched into an
        // occupied slot and fails exit=75 exactly as before.
        var settled: G04TerminalHostController? = null
        val (controller, _, events) = handoffController(
            closeReply = { conversationID, token ->
                settleSnapshot(checkNotNull(settled), conversationID, token)
                TerminalActionReply.Success(buildJsonObject { })
            },
            releaseProof = { false },
        )
        settled = controller
        val capture = seedLiveTerminal(controller, "c1", "tok-1")
        val result = controller.endCapturedTerminalForHandoff(
            capture, settledWaitMillis = 500, releaseProofTimeoutMillis = 1_000)
        assertEquals("engineSlotStillHeld",
            (result as TerminalHandoffResult.Refused).code)
        assertEquals(listOf("close:c1:tok-1", "releaseProof:1000"), events)
    }

    @Test
    fun aCloseThatNeverStartedConsultsNoReleaseProof() = runBlocking {
        for (reply in listOf<TerminalActionReply>(
            TerminalActionReply.Refused("saturated", "engineSlotBusy"),
            TerminalActionReply.TimedOut,
        )) {
            val (controller, _, events) = handoffController(closeReply = { _, _ -> reply })
            val capture = seedLiveTerminal(controller, "c1", "tok-1")
            val result = controller.endCapturedTerminalForHandoff(
                capture, settledWaitMillis = 200, releaseProofTimeoutMillis = 1_000)
            val code = (result as TerminalHandoffResult.Refused).code
            assertTrue("unexpected refusal code $code for $reply",
                code == "saturated" || code == "closeTimedOut")
            // No release proof, therefore no possible approve/dispatch, and a
            // failed close RETAINS the handle for the original reconciliation.
            assertEquals(listOf("close:c1:tok-1"), events)
            assertEquals("tok-1", seedMap<String>(controller, "sessionTokens")["c1"])
        }
    }

    @Test
    fun aProjectedSessionThatNeverSettledIsNeverPresentedAsReleased() = runBlocking {
        // The close was accepted but the authoritative status stayed LIVE: the
        // honest answer is a bounded refusal, never an elapsed-time success.
        val (controller, _, events) = handoffController()
        val capture = seedLiveTerminal(controller, "c1", "tok-1")
        val result = controller.endCapturedTerminalForHandoff(
            capture, settledWaitMillis = 150, releaseProofTimeoutMillis = 1_000)
        assertEquals("closeNotSettled", (result as TerminalHandoffResult.Refused).code)
        assertEquals(listOf("close:c1:tok-1"), events)
    }

    @Test
    fun aReplacementSessionIsNeverStoppedByAnOlderConsent() = runBlocking {
        // The user consented to the terminal they were shown. If a Reset or a
        // fresh open replaced it meanwhile, that is a DIFFERENT terminal:
        // refuse, close nothing, prove nothing.
        val (controller, _, events) = handoffController()
        val capture = seedLiveTerminal(controller, "c1", "tok-1")
        seedMap<String>(controller, "sessionTokens")["c1"] = "tok-replacement"
        seedMap<TerminalSessionSnapshot>(controller, "snapshots")["c1"] =
            liveSnapshot("c1", "tok-replacement")
        val result = controller.endCapturedTerminalForHandoff(capture)
        assertEquals("staleCapture", (result as TerminalHandoffResult.Refused).code)
        assertTrue("no close and no release proof may happen: $events", events.isEmpty())
        assertEquals("the replacement must still be live and bound",
            "tok-replacement", seedMap<String>(controller, "sessionTokens")["c1"])
        assertNotNull(controller.liveInteractiveTerminal("c1"))
    }

    @Test
    fun anAlreadyRetiredTerminalIsNotACapturableConflict() = runBlocking {
        val (controller, _, events) = handoffController()
        val capture = seedLiveTerminal(controller, "c1", "tok-1")
        seedMap<String>(controller, "sessionTokens").remove("c1")
        val result = controller.endCapturedTerminalForHandoff(capture)
        assertEquals("staleCapture", (result as TerminalHandoffResult.Refused).code)
        assertTrue(events.isEmpty())
    }

    @Test
    fun aMovedOnRootGenerationRefusesBeforeAndAfterTheRealRelease() = runBlocking {
        // Before: the captured epoch is no longer the live bound one.
        val (before, root, beforeEvents) = handoffController(epoch = 21L)
        val captureBefore = seedLiveTerminal(before, "c1", "tok-1")
        root.epoch = 22L
        val refusedBefore = before.endCapturedTerminalForHandoff(captureBefore)
        assertEquals("staleGeneration", (refusedBefore as TerminalHandoffResult.Refused).code)
        assertTrue(beforeEvents.isEmpty())

        // After: the generation is replaced while the handoff is in flight, so
        // a release is never published into a world that no longer owns it.
        // The epoch must move AFTER the close was admitted (inside the real
        // close seam), not before the call: a pre-call move is the separate
        // pre-close fence already covered above and would close nothing.
        val (after, _, afterEvents) = handoffController(
            epoch = 31L, onClose = { root -> root.epoch = 32L })
        val captureAfter = seedLiveTerminal(after, "c1", "tok-1")
        settleSnapshot(after, "c1", "tok-1")
        val refusedAfter = after.endCapturedTerminalForHandoff(
            captureAfter, settledWaitMillis = 200, releaseProofTimeoutMillis = 1_000)
        assertEquals("staleGeneration", (refusedAfter as TerminalHandoffResult.Refused).code)
        assertEquals("the close already happened, but no release is published",
            listOf("close:c1:tok-1"), afterEvents)
    }

    @Test
    fun anEmptyOrUnboundCaptureRefusesWithoutAnyEffect() = runBlocking {
        val (controller, _, events) = handoffController(epoch = 41L)
        for (capture in listOf(
            TerminalHandoffCapture("c1", "", 41L),
            TerminalHandoffCapture("c1", "tok-1", 0L),
        )) {
            val result = controller.endCapturedTerminalForHandoff(capture)
            assertEquals("staleCapture", (result as TerminalHandoffResult.Refused).code)
        }
        assertTrue(events.isEmpty())
    }

    @Test
    fun aCancelledCallerGetsATypedRefusalInsteadOfASilentStop() {
        // Cancellation (navigation away, run stop, surface retirement) must
        // refuse safely: no release is claimed, so the caller can never treat
        // the handoff as completed and approve behind it.
        val events = mutableListOf<String>()
        val gate = Job()
        var observed: TerminalHandoffResult? = null
        val controller = G04TerminalHostController(
            CoroutineScope(Dispatchers.Unconfined),
            Dispatchers.Unconfined,
            Dispatchers.Unconfined,
            engineSlotReleaseProof = { events.add("releaseProof"); true },
            closeSinkOverride = { conversationID, token ->
                events.add("close:$conversationID:$token")
                gate.cancel()
                TerminalActionReply.Success(buildJsonObject { })
            },
        ) { 51L }
        setFieldLong(controller, "boundEpoch", 51L)
        (G04TerminalHostController::class.java.getDeclaredField("stopped")
            .apply { isAccessible = true }.get(controller)
            as java.util.concurrent.atomic.AtomicBoolean).set(false)
        val capture = seedLiveTerminal(controller, "c1", "tok-1")

        // Unconfined: the body runs eagerly, so the cancelled fence is reached
        // deterministically inside this call rather than by polling.
        CoroutineScope(Dispatchers.Unconfined + gate).launch {
            observed = controller.endCapturedTerminalForHandoff(
                capture, settledWaitMillis = 200, releaseProofTimeoutMillis = 1_000)
        }

        val outcome = checkNotNull(observed) { "the unconfined body must have completed" }
        assertEquals("cancelled", (outcome as TerminalHandoffResult.Refused).code)
        assertEquals("no release proof after a cancelled caller",
            listOf("close:c1:tok-1"), events)
    }

    // MARK: - G07.3A real independent tabs (authored)

    @Test
    fun twoTabsReceiveOnlyTheirOwnOutputAndTheirOwnStatus() {
        val (controller, _) = boundController(Dispatchers.Unconfined)
        val tokens = seedMap<String>(controller, "sessionTokens")
        val owners = seedMap<String>(controller, "tokenConversations")
        tokens["c1"] = "tok-a"
        owners["tok-a"] = "c1"
        owners["tok-b"] = "c1"

        // Two REAL emulators owned by the service, one per native session.
        val engineA = controller.engineForTab("tok-a")
        val engineB = controller.engineForTab("tok-b")
        controller.deliverTerminalOutput("tok-a", "AAA".toByteArray())
        controller.deliverTerminalOutput("tok-b", "BBB".toByteArray())
        assertTrue(engineA.visibleText(), engineA.visibleText().contains("AAA"))
        assertFalse(engineB.visibleText(), engineB.visibleText().contains("AAA"))
        assertTrue(engineA.visibleText(), engineB.visibleText().contains("BBB"))
        assertFalse(engineA.visibleText(), engineA.visibleText().contains("BBB"))

        // A terminalStatus for tab B must never overwrite the conversation's
        // default-token projection (tab A). The tab projection is keyed by the
        // exact native session.
        val descriptor = """{"type":"terminalStatus","conversationID":"c1",
            "sessionToken":"tok-b","phase":"running","purpose":"interactive"}"""
            .trimIndent().toByteArray()
        assertTrue(controller.handleEvent(0L, descriptor))
        assertEquals("tok-b", controller.snapshotFor("tok-b")?.sessionToken)
        assertEquals(TerminalSessionPhase.RUNNING, controller.snapshotFor("tok-b")?.phase)
        assertNull("tab A's conversation projection must not show tab B",
            controller.currentSnapshot("c1")?.takeIf { it.sessionToken == "tok-b" })
    }

    @Test
    fun closingOneTabAddressesOnlyThatNativeSession() = runBlocking {
        val closed = mutableListOf<Pair<String, String>>()
        val root = LiveRoot(7L)
        val controller = G04TerminalHostController(
            CoroutineScope(Dispatchers.Unconfined),
            outputDispatcher = Dispatchers.Unconfined,
            inputDispatcher = Dispatchers.Unconfined,
            closeSinkOverride = { conversationID, sessionToken ->
                closed.add(conversationID to sessionToken)
                TerminalActionReply.Success(buildJsonObject { })
            },
            currentNativeEpoch = { root.epoch })
        setFieldLong(controller, "boundEpoch", 7L)
        (G04TerminalHostController::class.java.getDeclaredField("stopped")
            .apply { isAccessible = true }.get(controller)
            as java.util.concurrent.atomic.AtomicBoolean).set(false)
        val tokens = seedMap<String>(controller, "sessionTokens")
        val owners = seedMap<String>(controller, "tokenConversations")
        tokens["c1"] = "tok-a"
        owners["tok-a"] = "c1"
        owners["tok-b"] = "c1"
        val reply = controller.closeTab("tok-b")
        assertTrue(reply is TerminalActionReply.Success)
        assertEquals("the close carries ONLY the tab's exact token", listOf("c1" to "tok-b"), closed)
        assertEquals("tok-a", tokens["c1"])
        assertEquals("c1", owners["tok-a"])
        assertFalse("the closed tab's token is unbound", owners.containsKey("tok-b"))
    }

}
