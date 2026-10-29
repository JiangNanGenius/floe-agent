// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Deterministic JVM source for the real page-edit handshake and ordered dispatch. */
class OfficeEditModePreparationTest {

    private class FakeHost : OfficeEditModePreparation.Host {
        lateinit var preparation: OfficeEditModePreparation
        var mountLive = true
        var editableReady = true
        var pageEditMode = false
        var pageEditModeFresh = false
        var activationWitness = 0L
        var hookResult = true
        var schedulerAvailable = true
        var beforeNative: (() -> Unit)? = null

        /**
         * page-transport85: freshness backed by the REAL witness state
         * machine instead of the raw boolean, so the fast-path gating itself
         * (fact AND activation-witness AND page-reported downlink freshness)
         * is under test. Injected clock: tests set [witnessNowMs].
         */
        val witnessFact = OfficePageEditModeWitness()
        var witnessNowMs = 0L
        var useWitnessFact = false

        /**
         * The current page-truth health read answer for the cached fast
         * path (Main late critical review 2026-10-28): even a triple-fresh
         * cache only selects the cheap route — admission still requires
         * this live verification, and false drives the full handshake.
         */
        var healthVerifyResult = true
        var healthVerifyThrows = false
        var deferHealthVerification = false
        var beforeHealthVerifyResult: (() -> Unit)? = null
        var transportGeneration = 0L

        /** office-background-repair118: which verification route was used. */
        var singleShotVerifyCalls = 0
        var boundedVerifyCalls = 0

        val events = ArrayList<String>()
        val diagnostics = ArrayList<String>()
        private val timeouts = ArrayList<Runnable>()
        private val cancelledTimeouts = HashSet<Int>()
        private data class QueuedHook(
            val token: OfficeEditModePreparationToken,
            val callback: (Boolean) -> Unit,
        )
        private val hooks = ArrayList<QueuedHook>()
        private var issuedHookCount = 0
        private data class QueuedHealth(
            val token: OfficeEditModePreparationToken,
            val callback: (Boolean) -> Unit,
        )
        private val healthReads = ArrayList<QueuedHealth>()

        override fun isMountLive() = mountLive
        override fun isEditableReady() = editableReady
        override fun isPageEditMode() = pageEditMode
        override fun isPageEditModeFresh() =
            if (useWitnessFact) witnessFact.isFresh(witnessNowMs) else pageEditModeFresh
        override fun activationWitnessCount() = activationWitness
        override fun pageTransportGeneration() = transportGeneration

        override fun verifyPageTransportHealth(
            token: OfficeEditModePreparationToken,
            onResult: (Boolean) -> Unit,
        ) {
            singleShotVerifyCalls += 1
            events.add("health-verify")
            if (healthVerifyThrows) throw IllegalStateException("verifier-broken")
            if (deferHealthVerification) {
                healthReads.add(QueuedHealth(token, onResult))
            } else {
                deliverHealth(token, onResult)
            }
        }

        override fun verifyPageTransportHealthUntilFresh(
            token: OfficeEditModePreparationToken,
            onResult: (Boolean) -> Unit,
        ) {
            boundedVerifyCalls += 1
            // Same observable event name so existing event-count assertions are
            // unchanged; only the dedicated route counters distinguish them.
            events.add("health-verify")
            if (healthVerifyThrows) throw IllegalStateException("verifier-broken")
            if (deferHealthVerification) {
                healthReads.add(QueuedHealth(token, onResult))
            } else {
                deliverHealth(token, onResult)
            }
        }

        private fun deliverHealth(
            token: OfficeEditModePreparationToken,
            onResult: (Boolean) -> Unit,
        ) {
            // Real Session fences issuance, then invokes onResult AFTER the
            // asynchronous view/generation check; it does not hold the
            // preparation monitor while the callback mutates test facts.
            val started = preparation.runIfActive(token) { }
            if (!started) {
                events.add("health-verify-fenced")
                return
            }
            beforeHealthVerifyResult?.invoke()
            onResult(healthVerifyResult)
        }

        override fun sendNativeEditable(token: OfficeEditModePreparationToken): Boolean {
            beforeNative?.invoke()
            // Mirrors Session's actual execution-point token fence.
            return preparation.runIfActive(token) { events.add("native") }
        }

        override fun enterPageEditMode(
            token: OfficeEditModePreparationToken,
            onHookResult: (Boolean) -> Unit,
        ) {
            issuedHookCount += 1
            hooks.add(QueuedHook(token, onHookResult))
        }

        override fun runOnControlLane(task: Runnable): Boolean {
            task.run()
            return true
        }

        override fun scheduleTimeout(delayMs: Long, task: Runnable): Any? {
            if (!schedulerAvailable) return null
            timeouts.add(task)
            return timeouts.lastIndex
        }

        override fun cancelTimeout(handle: Any) {
            cancelledTimeouts.add(handle as Int)
        }

        override fun recordDiagnostic(detail: String) {
            diagnostics.add(detail)
        }

        fun runQueuedHook() {
            val hook = hooks.removeFirst()
            val started = preparation.runIfActive(hook.token) {
                events.add("js")
                hook.callback(hookResult)
            }
            if (!started) events.add("js-fenced")
        }

        fun runQueuedHealthVerify() {
            val read = healthReads.removeFirst()
            deliverHealth(read.token, read.callback)
        }

        fun queuedHealthCount() = healthReads.size

        fun emitPageEditMode(enabled: Boolean, generation: Long = transportGeneration) {
            pageEditMode = enabled
            preparation.onPageEditMode(enabled, generation)
        }

        /** Deliberately fires even a cancelled task to prove late callbacks stay fenced. */
        fun fireLatestTimeout() {
            timeouts.last().run()
        }

        fun queuedHookCount() = hooks.size
        fun hookIssueCount() = issuedHookCount
        fun nativeSendCount() = events.count { it == "native" }
    }

    private fun fixture(): Pair<FakeHost, OfficeEditModePreparation> {
        val host = FakeHost()
        val preparation = OfficeEditModePreparation(host)
        host.preparation = preparation
        return host to preparation
    }

    @Test
    fun barrierFalsePageFalseReadySequenceRequiresActualEditAck() {
        val host = FakeHost()
        val preparation = OfficeEditModePreparation(host)
        host.preparation = preparation
        // Exact C07 ordering: the load .uno:ReadOnly barrier was false and
        // READY_EDITABLE was promoted, but the page then reported Viewing.
        host.editableReady = true
        host.pageEditMode = false
        var result: OfficeEditModePreparationResult? = null

        preparation.prepare("select-1") { result = it }
        assertNull(result)
        assertEquals(1, host.nativeSendCount())
        assertEquals(1, host.queuedHookCount())

        // A successful JS hook invocation is NOT edit-mode evidence. The
        // real page forwards its `useractive` transport witness over the
        // bridge BEFORE posting the EDITMODE ack (same JS thread, ordered).
        host.runQueuedHook()
        assertNull(result)
        host.activationWitness = 1
        host.emitPageEditMode(true)
        assertTrue(result!!.isReady)
        assertEquals("page-edit-mode-health-verified", result!!.detail)
    }

    @Test
    fun pageViewingDuringPreparationRefusesBeforeAnyOperation() {
        val (host, preparation) = fixture()
        var result: OfficeEditModePreparationResult? = null
        preparation.prepare("apply-1") { result = it }
        host.emitPageEditMode(false)
        assertEquals(OfficeEditModePreparationFailure.NOT_EDITABLE, result?.failure)
        assertEquals("page-viewing-during-edit-preparation", result?.detail)
    }

    @Test
    fun alreadyObservedEditingIsReadyWithoutOptimisticBootstrap() {
        val (host, preparation) = fixture()
        host.pageEditMode = true
        host.pageEditModeFresh = true
        // The cached route still ends in ONE current page-truth health read
        // (Main late critical review 2026-10-28) — here the live page
        // confirms fresh real downlink data, so no native re-send and no
        // hook are needed.
        host.healthVerifyResult = true
        var result: OfficeEditModePreparationResult? = null
        preparation.prepare("select-2") { result = it }
        assertTrue(result!!.isReady)
        assertEquals("cached-edit-health-verified", result!!.detail)
        assertEquals(1, host.events.count { it == "health-verify" })
        assertEquals(0, host.nativeSendCount())
        assertEquals(0, host.queuedHookCount())
    }

    @Test
    fun cachedFastPathWithUnverifiedPageHealthFallsBackToHandshake() {
        // The cached fact is fresh but the CURRENT page-truth read does not
        // confirm it (watchdog-stalled transport, frozen/replaced view,
        // unreadable answer): NO admission on cached uplinks alone — the
        // full ordered handshake takes over and decides honestly.
        val (host, preparation) = fixture()
        host.pageEditMode = true
        host.pageEditModeFresh = true
        host.healthVerifyResult = false
        var result: OfficeEditModePreparationResult? = null
        preparation.prepare("apply-unverified-cache") { result = it }
        assertNull(result)
        assertEquals(1, host.events.count { it == "health-verify" })
        assertEquals(1, host.nativeSendCount())
        assertEquals(1, host.queuedHookCount())
        // The stalled transport then dies inside the ordered script probe:
        // typed pre-dispatch refusal, never an after-effect UNKNOWN.
        host.hookResult = false
        host.runQueuedHook()
        assertEquals(OfficeEditModePreparationFailure.TRANSPORT, result?.failure)
        assertEquals("page-edit-hook-unavailable", result?.detail)
    }

    @Test
    fun brokenHealthVerifierFallsBackToHandshakeInsteadOfAdmitting() {
        // A verifier that throws synchronously must never become an
        // admission (or a silent hang): the handshake route carries its own
        // typed failure honesty.
        val (host, preparation) = fixture()
        host.pageEditMode = true
        host.pageEditModeFresh = true
        host.healthVerifyThrows = true
        var result: OfficeEditModePreparationResult? = null
        preparation.prepare("apply-broken-verifier") { result = it }
        assertNull(result)
        assertEquals(1, host.nativeSendCount())
        assertEquals(1, host.queuedHookCount())
        // Only the initial warm verifier is broken; the cold final health
        // read must work so this also covers the warm -> cold route latch.
        host.healthVerifyThrows = false
        host.activationWitness = 1
        host.runQueuedHook()
        host.emitPageEditMode(true)
        assertTrue(result!!.isReady)
        assertEquals("page-edit-mode-health-verified", result!!.detail)
    }

    @Test
    fun timeoutAndLateAckCannotCompleteTwice() {
        val (host, preparation) = fixture()
        val results = ArrayList<OfficeEditModePreparationResult>()
        preparation.prepare("apply-timeout") { results.add(it) }
        host.fireLatestTimeout()
        host.emitPageEditMode(true)
        assertEquals(1, results.size)
        assertEquals(OfficeEditModePreparationFailure.TIMEOUT, results.single().failure)
    }

    @Test
    fun readOnlyMountIsRefusedWithoutNativeOrPageMutation() {
        val (host, preparation) = fixture()
        host.editableReady = false
        var result: OfficeEditModePreparationResult? = null
        preparation.prepare("readonly") { result = it }
        assertEquals(OfficeEditModePreparationFailure.NOT_EDITABLE, result?.failure)
        assertTrue(host.events.isEmpty())
        assertEquals(0, host.queuedHookCount())
    }

    @Test
    fun cancelAtNativeExecutionPointSuppressesSendAndLaterHook() {
        val (host, preparation) = fixture()
        var result: OfficeEditModePreparationResult? = null
        host.beforeNative = { preparation.cancel("apply-cancel-native") }

        preparation.prepare("apply-cancel-native") { result = it }
        // cancel owns the operation settlement; preparation itself is silent.
        assertNull(result)
        assertEquals(0, host.nativeSendCount())
        assertEquals(0, host.queuedHookCount())
        host.emitPageEditMode(true)
        assertNull(result)
    }

    @Test
    fun cancelBeforeQueuedWebViewRunnableFencesJsAndTimeout() {
        val (host, preparation) = fixture()
        val results = ArrayList<OfficeEditModePreparationResult>()
        preparation.prepare("apply-cancel-js") { results.add(it) }
        preparation.cancel("apply-cancel-js")
        host.runQueuedHook()
        host.fireLatestTimeout()
        assertTrue(results.isEmpty())
        assertEquals(listOf("native", "js-fenced"), host.events)
    }

    @Test
    fun closeBeforeQueuedHookFencesJsTimeoutAndFuturePreparation() {
        val (host, preparation) = fixture()
        val results = ArrayList<OfficeEditModePreparationResult>()
        preparation.prepare("apply-close") { results.add(it) }
        preparation.close()
        host.runQueuedHook()
        host.fireLatestTimeout()
        host.emitPageEditMode(true)
        assertTrue(results.isEmpty())

        preparation.prepare("after-close") { results.add(it) }
        assertEquals(OfficeEditModePreparationFailure.SESSION_ENDING, results.single().failure)
        assertEquals(listOf("native", "js-fenced"), host.events)
    }

    @Test
    fun hookFailureIsTypedWithoutClaimingPageEdit() {
        val (host, preparation) = fixture()
        host.hookResult = false
        var result: OfficeEditModePreparationResult? = null
        preparation.prepare("apply-hook-missing") { result = it }
        host.runQueuedHook()
        assertEquals(OfficeEditModePreparationFailure.TRANSPORT, result?.failure)
        assertEquals("page-edit-hook-unavailable", result?.detail)
    }

    @Test
    fun ownedDispatchRequiresPageModeAndOrdersNativeBeforeOperation() {
        val events = ArrayList<String>()
        var pageEditing = true
        val sent = OfficeOwnedEditDispatch.run(
            isPageEditMode = { pageEditing },
            sendNativeEditable = { events.add("native") },
            sendOperation = { events.add("operation") },
        )
        assertTrue(sent)
        assertEquals(listOf("native", "operation"), events)

        pageEditing = false
        val viewingSent = OfficeOwnedEditDispatch.run(
            isPageEditMode = { pageEditing },
            sendNativeEditable = { events.add("late-native") },
            sendOperation = { events.add("late-operation") },
        )
        assertFalse(viewingSent)
        assertEquals(listOf("native", "operation"), events)
    }

    @Test
    fun staleCachedEditFactRequiresFreshHandshakeAndWitness() {
        val (host, preparation) = fixture()
        // Exact C15 first-failure admission shape: the cached fact still
        // says editing, but it is no longer fresh (an approval wait aged it
        // past the pinned 30 s proxy watchdog window, or a page-lifecycle
        // restart invalidated it). No immediate admission may happen.
        host.pageEditMode = true
        host.pageEditModeFresh = false
        var result: OfficeEditModePreparationResult? = null
        preparation.prepare("apply-stale") { result = it }
        assertNull(result)
        assertEquals(1, host.nativeSendCount())
        assertEquals(1, host.queuedHookCount())

        // The hook ran and the page acked EDITMODE on, but NO real
        // activation frame was forwarded: the ack rides the bridge, which
        // works even while the page's socket transport is dying. Refuse
        // before any effect instead of riding into an after-effect UNKNOWN.
        host.runQueuedHook()
        host.emitPageEditMode(true)
        assertEquals(OfficeEditModePreparationFailure.NOT_EDITABLE, result?.failure)
        assertEquals("page-activation-witness-missing", result?.detail)
    }

    @Test
    fun freshHandshakeWithActivationWitnessIsReady() {
        val (host, preparation) = fixture()
        host.pageEditMode = true
        host.pageEditModeFresh = false
        var result: OfficeEditModePreparationResult? = null
        preparation.prepare("apply-witnessed") { result = it }
        assertNull(result)
        host.runQueuedHook()
        // The pinned page emits the witness frame only while its transport
        // is open, and before the EDITMODE ack (ordered bridge calls).
        host.activationWitness = 1
        host.emitPageEditMode(true)
        assertTrue(result!!.isReady)
        assertEquals("page-edit-mode-health-verified", result!!.detail)
    }

    @Test
    fun activationWitnessBeforeBaselineCannotCompleteHandshake() {
        val (host, preparation) = fixture()
        // Frames forwarded BEFORE this handshake started are not its
        // witness: the baseline is captured at Active creation.
        host.activationWitness = 7
        var result: OfficeEditModePreparationResult? = null
        preparation.prepare("apply-old-witness") { result = it }
        host.runQueuedHook()
        host.emitPageEditMode(true)
        assertEquals(OfficeEditModePreparationFailure.NOT_EDITABLE, result?.failure)
        assertEquals("page-activation-witness-missing", result?.detail)
    }

    @Test
    fun freshRawEditOnDeadTransportCannotBypassHandshake() {
        // page-transport85 finding A regression, driven through the REAL
        // witness state machine: the page posts a RAW EDITMODE on over the
        // ungated bridge (a direct/manual toggle) while its socket transport
        // is dying — seconds-fresh fact, but no real `useractive` frame can
        // have been forwarded (the pinned page forwards one only at
        // readyState===1). Freshness must NOT admit; the real handshake must
        // run and, on the dead transport, refuse BEFORE any effect.
        val (host, preparation) = fixture()
        host.useWitnessFact = true
        host.pageEditMode = true
        host.witnessNowMs = 50_000
        host.witnessFact.onPageFact(true, 50_000) // raw, unwitnessed
        var result: OfficeEditModePreparationResult? = null
        preparation.prepare("apply-raw-fresh") { result = it }
        // No immediate admission: the handshake started instead.
        assertNull(result)
        assertEquals(1, host.nativeSendCount())
        assertEquals(1, host.queuedHookCount())
        // The dead transport is exactly the 79 probe outcome: the ordered
        // script closes the dying socket synchronously and returns false.
        host.hookResult = false
        host.runQueuedHook()
        assertEquals(OfficeEditModePreparationFailure.TRANSPORT, result?.failure)
        assertEquals("page-edit-hook-unavailable", result?.detail)
        assertTrue(host.events.none { it == "operation" })
    }

    @Test
    fun freshRawEditWithBridgeAckButNoWitnessFrameIsRefused() {
        // Same finding-A shape, second route: the raw toggle's hook DOES run
        // and the page acks EDITMODE on over the bridge (which works even on
        // a dying proxy), but no real activation frame was forwarded after
        // the handshake baseline. The ack alone is not transport proof.
        val (host, preparation) = fixture()
        host.useWitnessFact = true
        host.pageEditMode = true
        host.witnessNowMs = 50_000
        host.witnessFact.onPageFact(true, 50_000)
        var result: OfficeEditModePreparationResult? = null
        preparation.prepare("apply-raw-acked") { result = it }
        assertNull(result)
        host.hookResult = true
        host.runQueuedHook()
        assertNull(result) // hook ran; readiness still needs the page fact
        host.emitPageEditMode(true)
        assertEquals(OfficeEditModePreparationFailure.NOT_EDITABLE, result?.failure)
        assertEquals("page-activation-witness-missing", result?.detail)
    }

    @Test
    fun witnessedFreshEditStillAdmitsImmediatelyWithoutHandshake() {
        // The functional counterpart: genuine healthy background operation
        // must keep working. A handshake-witnessed admission on a
        // pump-delivered transport (a page-truth read reported fresh real
        // downlink data, a real `useractive` was forwarded, then the
        // EDITMODE on ack arrived — the pinned script order) leaves ALL
        // stamps fresh, so the next owned operation inside the window takes
        // only the cheap verification read: no native re-send, no hook.
        val (host, preparation) = fixture()
        host.useWitnessFact = true
        host.pageEditMode = true
        host.activationWitness = 3
        host.healthVerifyResult = true
        host.witnessNowMs = 100_000
        host.witnessFact.onPageReportedFreshDownlink(99_000)
        host.witnessFact.onActivationWitness(100_000)
        host.witnessFact.onPageFact(true, 100_001)
        host.witnessNowMs = 105_000
        var result: OfficeEditModePreparationResult? = null
        preparation.prepare("select-followup") { result = it }
        assertTrue(result!!.isReady)
        assertEquals("cached-edit-health-verified", result!!.detail)
        assertEquals(1, host.events.count { it == "health-verify" })
        assertEquals(0, host.nativeSendCount())
        assertEquals(0, host.queuedHookCount())
    }

    @Test
    fun recentUplinksWithStaleDownlinkCannotAdmitOrDispatchEffect() {
        // Main confirmed fast-path review regression (2026-10-28), the exact
        // watchdog-stalled shape: readyState===1 with msgInflight>=4 and a
        // >30 s stale lastDataTimestamp still forwards `useractive` uplinks
        // and ungated EDITMODE bridge posts until the NEXT doSend evaluates
        // the watchdog. Fresh uplinks with no fresh REAL downlink delivery
        // must produce NO premature READY and NO effect: the handshake runs
        // instead, where the drain+probe force the real verdict.
        val (host, preparation) = fixture()
        host.useWitnessFact = true
        host.pageEditMode = true
        host.activationWitness = 9
        host.witnessNowMs = 80_000
        host.witnessFact.onActivationWitness(80_000) // recent real uplink
        host.witnessFact.onPageFact(true, 80_100) // recent raw EDITMODE on
        // Downlink: one delivery long aged out (stalled polls serve nothing).
        host.witnessFact.onPageReportedFreshDownlink(20_000)
        var result: OfficeEditModePreparationResult? = null
        preparation.prepare("apply-stalled") { result = it }
        // NO immediate admission, NO effect send: the real handshake began.
        assertNull(result)
        assertEquals(1, host.nativeSendCount())
        assertEquals(1, host.queuedHookCount())
        // The stalled transport is dying: the ordered script's synchronous
        // probe closes it before any ack (page-mode79 contract) — typed
        // pre-dispatch refusal, never an after-effect UNKNOWN.
        host.hookResult = false
        host.runQueuedHook()
        assertEquals(OfficeEditModePreparationFailure.TRANSPORT, result?.failure)
        assertEquals("page-edit-hook-unavailable", result?.detail)
        assertTrue(host.events.none { it == "operation" })
    }

    @Test
    fun viewingReentryThenRawOnCannotReuseTheOldWitness() {
        // EDITMODE off (the pinned page posts it exactly when its socket
        // closed or the user left edit mode) voids the activation witness;
        // a following RAW on-fact inside the window is uncorroborated and
        // must go through the handshake.
        val (host, preparation) = fixture()
        host.useWitnessFact = true
        host.witnessNowMs = 200_000
        host.witnessFact.onActivationWitness(200_000)
        host.witnessFact.onPageFact(true, 200_001)
        host.witnessFact.onPageFact(false, 201_000)
        host.witnessFact.onPageFact(true, 202_000) // raw re-on, no witness
        host.pageEditMode = true
        host.witnessNowMs = 202_500
        var result: OfficeEditModePreparationResult? = null
        preparation.prepare("apply-raw-reon") { result = it }
        assertNull(result)
        assertEquals(1, host.queuedHookCount())
    }

    @Test
    fun warmVerifierPendingRawOnAndActivationCannotPublishReadyEarly() {
        // MAIN_FINAL_ADMISSION_ENTRYPOINT_REVIEW: the warm health read is
        // deferred while an unrelated fresh uplink + RAW EDITMODE on arrives.
        // That bridge/uplink pair is exactly the watchdog-stalled shape and
        // must not become an alternate success entrypoint.
        val (host, preparation) = fixture()
        host.pageEditMode = true
        host.pageEditModeFresh = true
        host.deferHealthVerification = true
        var result: OfficeEditModePreparationResult? = null
        preparation.prepare("warm-deferred-health") { result = it }
        assertEquals(1, host.queuedHealthCount())
        host.activationWitness = 1
        host.emitPageEditMode(true)
        assertNull(result)
        assertEquals(0, host.nativeSendCount())
        assertEquals(0, host.queuedHookCount())
        // Only the operation's own current-health answer may complete it.
        host.runQueuedHealthVerify()
        assertTrue(result!!.isReady)
        assertEquals("cached-edit-health-verified", result!!.detail)
    }

    @Test
    fun coldHookPendingRawOnAndActivationCannotPublishReadyEarly() {
        // Same entrypoint review on the cold route: the owned hook/drain has
        // not completed. The early candidate is recorded, never admitted.
        val (host, preparation) = fixture()
        host.pageEditMode = true
        var result: OfficeEditModePreparationResult? = null
        preparation.prepare("cold-deferred-hook") { result = it }
        assertEquals(1, host.queuedHookCount())
        assertEquals(0, host.events.count { it == "health-verify" })
        host.activationWitness = 1
        host.emitPageEditMode(true)
        assertNull(result)
        assertEquals(0, host.events.count { it == "health-verify" })
        // Hook completion releases the candidate into exactly ONE final
        // current-owned page-health read, not directly into READY.
        host.runQueuedHook()
        assertTrue(result!!.isReady)
        assertEquals("page-edit-mode-health-verified", result!!.detail)
        assertEquals(1, host.events.count { it == "health-verify" })
    }

    @Test
    fun coldFinalHealthFailureNeverRepeatsNativeOrHookEffects() {
        val (host, preparation) = fixture()
        host.pageEditMode = true
        host.healthVerifyResult = false
        var result: OfficeEditModePreparationResult? = null
        preparation.prepare("cold-final-health-refused") { result = it }
        host.activationWitness = 1
        host.runQueuedHook()
        host.emitPageEditMode(true)
        assertEquals(OfficeEditModePreparationFailure.TRANSPORT, result?.failure)
        assertEquals("page-health-verification-failed", result?.detail)
        assertEquals(1, host.nativeSendCount())
        assertEquals(1, host.hookIssueCount())
        assertEquals(0, host.queuedHookCount())
        assertEquals(1, host.events.count { it == "health-verify" })
        assertTrue(host.events.none { it == "operation" })
    }

    @Test
    fun warmCachedRouteUsesTheCheapSingleShotVerification() {
        // office-background-repair118: the warm fast path keeps exactly ONE
        // cheap live read; its false outcome falls back to the real handshake
        // (bounded final verification), it must NOT stack budgets.
        val (host, preparation) = fixture()
        host.pageEditMode = true
        host.pageEditModeFresh = true
        host.healthVerifyResult = true
        var result: OfficeEditModePreparationResult? = null
        preparation.prepare("warm-cheap") { result = it }
        assertTrue(result!!.isReady)
        assertEquals("cached-edit-health-verified", result!!.detail)
        assertEquals(1, host.singleShotVerifyCalls)
        assertEquals(0, host.boundedVerifyCalls)
        assertEquals(0, host.nativeSendCount())
        assertEquals(0, host.queuedHookCount())
    }

    @Test
    fun coldRouteFinalVerificationIsBoundedNotSingleShot() {
        // office-background-repair118: the cold route's ONE final verification
        // is the bounded read (asynchronous poll-burst delivery opportunity),
        // never the warm single shot, and never a repeated native/hook effect.
        val (host, preparation) = fixture()
        host.pageEditMode = true
        var result: OfficeEditModePreparationResult? = null
        preparation.prepare("cold-bounded") { result = it }
        host.activationWitness = 1
        host.runQueuedHook()
        host.emitPageEditMode(true)
        assertTrue(result!!.isReady)
        assertEquals("page-edit-mode-health-verified", result!!.detail)
        assertEquals(0, host.singleShotVerifyCalls)
        assertEquals(1, host.boundedVerifyCalls)
        assertEquals(1, host.nativeSendCount())
        assertEquals(1, host.hookIssueCount())
    }

    @Test
    fun coldRouteBoundedRefusalStillRepeatsNoEffects() {
        // A bounded final false is the SAME typed pre-dispatch refusal: one
        // owned verification, no second native send, no second hook.
        val (host, preparation) = fixture()
        host.pageEditMode = true
        host.healthVerifyResult = false
        var result: OfficeEditModePreparationResult? = null
        preparation.prepare("cold-bounded-refused") { result = it }
        host.activationWitness = 1
        host.runQueuedHook()
        host.emitPageEditMode(true)
        assertEquals(OfficeEditModePreparationFailure.TRANSPORT, result?.failure)
        assertEquals("page-health-verification-failed", result?.detail)
        assertEquals(1, host.boundedVerifyCalls)
        assertEquals(0, host.singleShotVerifyCalls)
        assertEquals(1, host.nativeSendCount())
        assertEquals(1, host.hookIssueCount())
        assertEquals(0, host.queuedHookCount())
    }

    @Test
    fun healthCompletionRevalidatesEditPermissionBeforeReady() {
        val (host, preparation) = fixture()
        host.pageEditMode = true
        host.pageEditModeFresh = true
        host.deferHealthVerification = true
        var result: OfficeEditModePreparationResult? = null
        preparation.prepare("warm-permission-drift") { result = it }
        host.editableReady = false // drift while the real read is in flight
        host.runQueuedHealthVerify()
        assertEquals(OfficeEditModePreparationFailure.NOT_EDITABLE, result?.failure)
        assertEquals("edit-permission-lost-during-preparation", result?.detail)
        assertEquals(0, host.nativeSendCount())
        assertEquals(0, host.queuedHookCount())
    }

    @Test
    fun healthCompletionRevalidatesMountBeforeReady() {
        val (host, preparation) = fixture()
        host.pageEditMode = true
        host.pageEditModeFresh = true
        host.deferHealthVerification = true
        var result: OfficeEditModePreparationResult? = null
        preparation.prepare("warm-mount-drift") { result = it }
        host.mountLive = false
        host.runQueuedHealthVerify()
        assertEquals(OfficeEditModePreparationFailure.SESSION_ENDING, result?.failure)
        assertEquals("mount-ended-during-edit-preparation", result?.detail)
        assertEquals(0, host.nativeSendCount())
    }

    @Test
    fun healthCompletionRevalidatesRawEditModeBeforeReady() {
        val (host, preparation) = fixture()
        host.pageEditMode = true
        host.pageEditModeFresh = true
        host.deferHealthVerification = true
        var result: OfficeEditModePreparationResult? = null
        preparation.prepare("warm-mode-drift") { result = it }
        // No helpful off callback: the final completion itself must re-read.
        host.pageEditMode = false
        host.runQueuedHealthVerify()
        assertEquals(OfficeEditModePreparationFailure.NOT_EDITABLE, result?.failure)
        assertEquals("page-edit-mode-lost-before-health-completion", result?.detail)
        assertEquals(0, host.nativeSendCount())
    }

    @Test
    fun generationChangeFencesFinalHealthAndLateEditAck() {
        val (host, preparation) = fixture()
        host.pageEditMode = true
        val results = ArrayList<OfficeEditModePreparationResult>()
        preparation.prepare("generation-change") { results.add(it) }
        host.runQueuedHook()
        host.transportGeneration = 1
        preparation.onPageTransportGenerationChanged()
        assertEquals(1, results.size)
        assertEquals(OfficeEditModePreparationFailure.TRANSPORT, results.single().failure)
        assertEquals("page-transport-generation-changed", results.single().detail)
        host.activationWitness = 1
        host.emitPageEditMode(true) // late new-generation ack cannot complete old token
        assertEquals(1, results.size)
        assertEquals(0, host.events.count { it == "health-verify" })
    }

    @Test
    fun nativeReentryToViewingBlocksFollowingOperationSend() {
        val events = ArrayList<String>()
        var pageEditing = true
        val sent = OfficeOwnedEditDispatch.run(
            isPageEditMode = { pageEditing },
            sendNativeEditable = {
                events.add("native")
                pageEditing = false // synchronous host/page callback
            },
            sendOperation = { events.add("operation") },
        )
        assertFalse(sent)
        assertEquals(listOf("native"), events)
    }
}
