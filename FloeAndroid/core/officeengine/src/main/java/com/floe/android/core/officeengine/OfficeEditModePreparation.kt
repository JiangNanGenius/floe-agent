// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

/** Failure of the bounded, operation-owned page edit-mode preparation. */
internal enum class OfficeEditModePreparationFailure {
    NOT_EDITABLE,
    TIMEOUT,
    SESSION_ENDING,
    BUSY,
    TRANSPORT,
}

/** One honest edit-preparation result; readiness is never inferred from a send. */
internal data class OfficeEditModePreparationResult(
    val failure: OfficeEditModePreparationFailure?,
    val detail: String,
) {
    val isReady: Boolean get() = failure == null
}

/** Exact operation/preparation incarnation used at real native/JS execution points. */
internal data class OfficeEditModePreparationToken(
    val opId: String,
    val serial: Long,
    /** Exact page/socket incarnation at admission; never the mount generation. */
    val pageGeneration: Long,
)

/**
 * Freshness/epoch fact for the cached page EDITMODE-on observation.
 *
 * The raw boolean alone is not an admission fact: the C15 first-failure
 * (page-mode79 causal record) proved a mount can carry an EDITMODE-on
 * observation across a hidden-WebView window whose page socket transport
 * was already inside the pinned proxy's 30 s no-response watchdog
 * (dist global.js `ProxySocket.doSend`, pinned source global.js:1704-1712:
 * `msgInflight >= 4` plus `lastDataTimestamp` older than 30 s closes the
 * socket with code 1006). A cached fact older than the watchdog window can
 * therefore silently straddle the page's own transport death, so the fast
 * path may only trust a fact that is (a) recent inside a window strictly
 * smaller than that watchdog and (b) not invalidated by a page-lifecycle
 * restart (a repeated handshake/load frame proves the page incarnation
 * changed). Everything stale goes through the real hook handshake instead.
 *
 * Recency ALONE is still not causal health (page-transport85, critical
 * finding A on page-mode79): the page posts `EDITMODE on` over the
 * UNGATED bridge (pinned Permission.js:730), which works even while the
 * page's socket transport is dying — the exact defect class of the C15
 * incident. A raw/manual EDITMODE-on stamped seconds ago therefore proves
 * only that the bridge works, not that the transport does. Freshness for
 * admission additionally requires ONE real page-originated `useractive`
 * uplink frame ([onActivationWitness]) inside the same window: the pinned
 * page can only forward that frame while its socket transport is actually
 * open (Socket.ts `sendMessage` forwards exactly at `readyState === 1`, and
 * the mobile uplink is the bridge itself), so a recent fact WITHOUT a
 * recent witness — e.g. a fresh raw edit toggle on a dead transport — is
 * not fresh and must go through the real handshake, where the ordered
 * probe/connected-gate/witness contract decides honestly. The genuine
 * handshake order satisfies this by construction: the enter-edit script
 * sends the `useractive` witness BEFORE the page posts its EDITMODE ack
 * (same JS thread, ordered synchronous bridge calls), and a manual toggle
 * on a healthy page produces real activity witnesses the same way. An
 * EDITMODE-off fact clears the activation stamp: the old witness vouched
 * for a page state that no longer exists.
 *
 * Recent UPLINK facts alone are still not downlink health either (Main
 * confirmed fast-path review, 2026-10-28): the watchdog-stalled state
 * keeps `readyState === 1` while `msgInflight >= 4` and
 * `lastDataTimestamp` is already more than 30 s old — the pinned close
 * fires only at the NEXT `doSend()` evaluation, so in that window the
 * ungated EDITMODE bridge AND the `useractive` uplink both still work and
 * would dual-stamp a dying transport fresh. Freshness therefore
 * additionally requires ONE PAGE-OBSERVED fresh-downlink report
 * ([onPageReportedFreshDownlink]) inside the same window and incarnation.
 * Per Main's late critical review (2026-10-28) this stamp is fed ONLY by
 * reads of the page's OWN counters (`PAGE_TRANSPORT_HEALTH_SCRIPT`
 * reporting `readyState === 1` and a fresh `lastDataTimestamp` age on the
 * CURRENT view) — never by the host merely serving a response body, which
 * is a delivery opportunity and not a page-consumption proof. And because
 * even a triple-fresh cache can age between stamping and use, the cached
 * route of `OfficeEditModePreparation` still ends in one live
 * `verifyPageTransportHealth` read; this stamp only selects that cheap
 * route. The heartbeat pump keeps the underlying transport genuinely
 * healthy (real `pong` data per interval) so healthy mounts keep passing
 * the live reads and their witnessed fast path stays cheap; anything less
 * goes through the real handshake, whose drain+probe re-establishes (or
 * honestly refuses) the transport first.
 *
 * Pure JVM state (no Android clock inside): callers pass
 * `SystemClock.elapsedRealtime()` values, which are monotonic.
 */
internal class OfficePageEditModeWitness(
    private val windowMs: Long = DEFAULT_FRESH_WINDOW_MS,
) {
    private var enabled = false
    private var stampMs = 0L
    private var epoch = 0L
    private var witnessEpoch = -1L

    /**
     * Page-incarnation counter, bumped ONLY by [onPageLifecycleRestart].
     * The activation witness belongs to an incarnation, not to a fact
     * version: in the genuine handshake the `useractive` frame is forwarded
     * BEFORE the EDITMODE ack (same JS thread, ordered bridge calls), so
     * tying the witness to the fact epoch would reject every genuine
     * handshake. Tying it to the incarnation rejects exactly what it must:
     * witnesses from a page that restarted its native channel.
     */
    private var incarnation = 0L
    private var activationStampMs = -1L
    private var activationIncarnation = -1L
    private var downlinkStampMs = -1L
    private var downlinkIncarnation = -1L

    /** One real page EDITMODE on/off observation. */
    @Synchronized
    fun onPageFact(on: Boolean, nowMs: Long) {
        epoch += 1L
        enabled = on
        if (on) {
            stampMs = nowMs
            witnessEpoch = epoch
        } else {
            witnessEpoch = -1L
            // Viewing re-entry invalidates the transport witness too: the
            // pinned page posts EDITMODE off exactly when its socket closed
            // or the user left edit mode, so a witness from before that
            // transition cannot vouch for a later raw on-fact.
            activationStampMs = -1L
            activationIncarnation = -1L
        }
    }

    /**
     * One REAL page-originated `useractive` uplink frame accepted for
     * forwarding — the transport-liveness stamp behind [isFresh]. Only the
     * live page can feed it (the pinned kit never sends `useractive`
     * downstream and the host's own native wire never uses it), and the
     * page can only forward it while its socket transport is open.
     */
    @Synchronized
    fun onActivationWitness(nowMs: Long) {
        activationStampMs = nowMs
        activationIncarnation = incarnation
    }

    /**
     * One PAGE-OBSERVED fresh-downlink report: a read of the page's OWN
     * counters (`PAGE_TRANSPORT_HEALTH_SCRIPT`) on the CURRENT view just
     * answered `readyState === 1` with a `lastDataTimestamp` age inside the
     * window — page-consumed truth that real downlink data reset the state
     * the pinned 30 s no-response watchdog reads (global.js:1731-1742).
     * NEVER fed by the host merely serving a response body (a delivery
     * opportunity is not a consumption proof — Main late critical review
     * 2026-10-28), and never by uplink facts: a watchdog-stalled page
     * keeps `readyState === 1` and keeps forwarding `useractive`/EDITMODE
     * bridge posts while its own `lastDataTimestamp` is already stale.
     */
    @Synchronized
    fun onPageReportedFreshDownlink(nowMs: Long) {
        downlinkStampMs = nowMs
        downlinkIncarnation = incarnation
    }

    /**
     * The page restarted its native channel (a second HULLO or a page-issued
     * reload `load` frame): the cached fact describes a previous page
     * incarnation and can no longer vouch for a new owned operation — and
     * neither can an activation witness observed before the restart.
     */
    @Synchronized
    fun onPageLifecycleRestart() {
        epoch += 1L
        incarnation += 1L
    }

    /** The raw observed EDITMODE fact (ordering checks; never admission). */
    @Synchronized
    fun isEditing(): Boolean = enabled

    /**
     * True only for a recent, never-invalidated EDITMODE-on observation
     * CORROBORATED by BOTH an equally recent real activation witness AND an
     * equally recent real downlink delivery, all three from the same page
     * incarnation. Recent uplinks without downlink health (the
     * watchdog-stalled state), or recent without any witness (a raw bridge
     * ack on a dying/dead transport), are NOT fresh.
     */
    @Synchronized
    fun isFresh(nowMs: Long): Boolean {
        if (!enabled || witnessEpoch != epoch) return false
        val age = nowMs - stampMs
        if (age !in 0..windowMs) return false
        if (activationStampMs < 0 || activationIncarnation != incarnation) return false
        val activationAge = nowMs - activationStampMs
        if (activationAge !in 0..windowMs) return false
        if (downlinkStampMs < 0 || downlinkIncarnation != incarnation) return false
        val downlinkAge = nowMs - downlinkStampMs
        return downlinkAge in 0..windowMs
    }

    companion object {
        /**
         * Strictly below the pinned 30 s proxy no-response watchdog so a
         * cached fact can never be older than the earliest possible
         * undetected transport death; small enough that an approval-wait
         * gap always forces the real hook handshake.
         */
        const val DEFAULT_FRESH_WINDOW_MS = 15_000L
    }
}

/**
 * The single ordered dispatch rule shared by precision mutations and flush.
 * The caller MUST hold the session's nativeIngressLock. A current page
 * EDITMODE-on fact is required immediately before the already-authorized
 * native per-view command and the actual operation are sent consecutively on
 * the existing serial wire. Viewing state sends nothing. The native command
 * is ordering, not a success claim; content/save proof remains independent.
 */
internal object OfficeOwnedEditDispatch {
    fun run(
        isPageEditMode: () -> Boolean,
        sendNativeEditable: () -> Unit,
        sendOperation: () -> Unit,
    ): Boolean {
        if (!isPageEditMode()) return false
        sendNativeEditable()
        // A native send can synchronously re-enter host callbacks. Re-check
        // the real page fact before the effect/save command may follow.
        if (!isPageEditMode()) return false
        sendOperation()
        return true
    }
}

/**
 * Bounded operation-owned entry into the pinned page's real edit mode.
 *
 * A load-permission barrier and READY_EDITABLE only make an EDIT mount
 * eligible; they do not prove that its page is editing. EVERY owned
 * admission ends in a CURRENT page-truth check (page-transport85, Main
 * late critical review 2026-10-28): a cached EDITMODE-on observation that
 * is fresh, un-invalidated AND triple-corroborated
 * ([OfficePageEditModeWitness]) only selects the cheap route — ONE live
 * read of the page's own transport counters
 * ([Host.verifyPageTransportHealth]) — and any unverified, unreadable or
 * stale outcome falls back to the full handshake. A stale fact, an
 * uncorroborated fact (a fresh RAW bridge ack with no transport witness is
 * not an admission fact — finding A), or an off fact drives the existing
 * guarded page hook directly and waits for the page's own EDITMODE-on
     * observation PLUS one new real page-originated activation frame
     * (`useractive`) AND the operation's own final current-health read. Early
     * bridge events cannot bypass a deferred warm verifier or cold hook.
     * There is no sleep or sent-flag success path. Every callback is
 * fenced by the Active instance, so cancellation, timeout, mount close and
 * stale JS callbacks can never complete a later operation.
 *
 * Calls normally arrive on the Session control lane. Host timeout/JS hooks
 * are marshalled back to that lane; small state transitions are synchronized
 * so cancel/close remain safe from binder/teardown threads.
 */
internal class OfficeEditModePreparation(
    private val host: Host,
    private val timeoutMs: Long = DEFAULT_TIMEOUT_MS,
) {
    interface Host {
        fun isMountLive(): Boolean
        fun isEditableReady(): Boolean
        fun isPageEditMode(): Boolean

        /**
         * True only when the cached EDITMODE-on fact is recent, was not
         * invalidated by a page-lifecycle restart, AND is corroborated by
         * BOTH an equally recent real page-originated activation witness
         * AND an equally recent PAGE-REPORTED fresh-downlink observation, all
         * from the same incarnation (see [OfficePageEditModeWitness]). The
         * downlink corroboration is a page-reported counter read, never a
         * host-served response opportunity.
         * Neither a stale true, nor a FRESH RAW true from the ungated
         * bridge, nor fresh uplinks alone on a watchdog-stalled transport
         * (readyState 1, msgInflight pinned, no served polls) is an
         * admission fact: anything uncorroborated must re-witness the real
         * page through the handshake below.
         */
        fun isPageEditModeFresh(): Boolean

        /**
         * Monotonic count of REAL page-originated `useractive` uplink frames
         * accepted for forwarding. The pinned page can only emit one while
         * its socket transport is open (Socket.ts `sendMessage` forwards
         * `useractive` exactly when `readyState === 1`; the mobile uplink is
         * the bridge itself — global.js `MobileSocket.send` →
         * `postMobileMessage`), so one new count after the handshake baseline
         * is the transport-liveness witness for the EDITMODE ack.
         */
        fun activationWitnessCount(): Long

        /**
         * Exact page/socket incarnation used by every native/JS execution
         * point. A view attach/detach, repeated HULLO or refused reload
         * advances it; answers and EDITMODE facts from an older incarnation
         * can never settle or authorize this preparation.
         */
        fun pageTransportGeneration(): Long

        /**
         * Runs ONE current page-truth transport-health read — the cached
         * route's cheap verification: host-side serving is a delivery
         * OPPORTUNITY, not proof the page consumed it, so EVERY admission
         * ends in a real read of the page's OWN counters
         * (`readyState`/`lastDataTimestamp` age) on the CURRENT view and
         * generation, fenced by this exact token. A warm false outcome falls
         * back to the one real handshake, whose own final verification is
         * [verifyPageTransportHealthUntilFresh]; a false there is a typed
         * pre-dispatch TRANSPORT refusal, never a hidden effect retry.
         * The result callback is invoked exactly once per active token (a
         * settled preparation drops it), never under the ingress/
         * preparation monitors.
         */
        fun verifyPageTransportHealth(
            token: OfficeEditModePreparationToken,
            onResult: (Boolean) -> Unit,
        )

        /**
         * The COLD route's FINAL page-truth verification
         * (office-background-repair118): the SAME single read as
         * [verifyPageTransportHealth] and the SAME freshness criterion, but
         * retried inside the preparation's EXISTING bounded window while the
         * page's own socket stays OPEN and merely stale, arming the same
         * on-demand heartbeat the pre-handshake drain already uses.
         *
         * Why the cold final read needs it: the actual C17 PPTX
         * `selectSlide` refusal spent the drain's whole ~3 s budget, then its
         * handshake script PASSED its `connected()` gate and really turned
         * the page's EDITMODE on — and the final read, issued ~6 ms later,
         * still reported stale and refused with
         * `page-health-verification-failed`. The pinned enter-edit script
         * fires up to 24 synchronous `doSend()` polls whose XHRs can only
         * COMPLETE asynchronously, so a zero-delay single shot observes the
         * pre-burst `lastDataTimestamp` and deterministically refuses a
         * transport that was already recovering. Giving that one read the
         * bounded delivery opportunity the drain already has removes the
         * false refusal.
         *
         * This is NOT admission leniency and NOT timeout inflation: the
         * freshness criterion is unchanged, a closed/closing socket
         * (`readyState != 1`) still refuses IMMEDIATELY, an exhausted budget
         * still yields the same typed pre-dispatch TRANSPORT refusal, and the
         * whole bound stays inside [DEFAULT_TIMEOUT_MS]. The warm route keeps
         * the cheap single shot, because its false outcome already has a
         * sound fallback (the one real handshake) and must not stack budgets.
         */
        fun verifyPageTransportHealthUntilFresh(
            token: OfficeEditModePreparationToken,
            onResult: (Boolean) -> Unit,
        )

        /**
         * Sends only while this exact token is active at the REAL native
         * dispatch point. False means cancel/close already fenced the send.
         */
        fun sendNativeEditable(token: OfficeEditModePreparationToken): Boolean

        /** Queues the existing guarded page hook; its runnable re-checks token. */
        fun enterPageEditMode(
            token: OfficeEditModePreparationToken,
            onHookResult: (Boolean) -> Unit,
        )

        fun runOnControlLane(task: Runnable): Boolean
        fun scheduleTimeout(delayMs: Long, task: Runnable): Any?
        fun cancelTimeout(handle: Any)
        fun recordDiagnostic(detail: String)
    }

    private data class Active(
        val token: OfficeEditModePreparationToken,
        val callback: (OfficeEditModePreparationResult) -> Unit,
        /** Activation-witness baseline captured before any handshake send. */
        val witnessBaseline: Long,
        /**
         * The cached triple-fresh fact selected the cheap verification
         * route: ONE current page-truth health read instead of the full
         * handshake. It is NEVER the verdict itself (Main late critical
         * review 2026-10-28) — an unverified/corrupted read falls back to
         * the handshake.
         */
        var fastPathEligible: Boolean,
        /** Cold route only: the real queued hook/drain chain was started. */
        var hookIssued: Boolean = false,
        /** Cold route only: the owned hook actually returned success. */
        var hookCompleted: Boolean = false,
        /** Cold candidate only; never sufficient without hook + final health. */
        var editAckObserved: Boolean = false,
        /** Exactly one final cold health read; no hidden handshake retry. */
        var finalHealthStarted: Boolean = false,
        var timeoutHandle: Any? = null,
    ) {
        val opId: String get() = token.opId
    }

    private val lock = Any()
    private var active: Active? = null
    private var nextSerial = 0L
    private var closed = false

    fun prepare(
        opId: String,
        callback: (OfficeEditModePreparationResult) -> Unit,
    ) {
        var started: Active? = null
        val immediate = synchronized(lock) {
            when {
                closed -> OfficeEditModePreparationResult(
                    OfficeEditModePreparationFailure.SESSION_ENDING,
                    "edit-preparation-closed",
                )
                active != null -> OfficeEditModePreparationResult(
                    OfficeEditModePreparationFailure.BUSY,
                    "edit-preparation-already-active",
                )
                !host.isMountLive() -> OfficeEditModePreparationResult(
                    OfficeEditModePreparationFailure.SESSION_ENDING,
                    "mount-not-live",
                )
                !host.isEditableReady() -> OfficeEditModePreparationResult(
                    OfficeEditModePreparationFailure.NOT_EDITABLE,
                    "mount-not-editable-ready",
                )
                else -> {
                    // EVERY owned admission ends in a CURRENT page-truth
                    // check (Main late critical review 2026-10-28): the
                    // cached triple-fresh fact only selects the cheap route
                    // — one live read of the page's own transport counters
                    // — and an uncorroborated, stale or unreadable cached
                    // fact takes the full ordered handshake. Neither a
                    // stale cached true (approval waits, hidden-WebView
                    // throttling), nor a fresh RAW true from the ungated
                    // bridge (finding A: the ack works even on a dying
                    // proxy), nor fresh uplinks alone on a watchdog-stalled
                    // transport can admit by themselves.
                    val pending = Active(
                        OfficeEditModePreparationToken(
                            opId,
                            ++nextSerial,
                            host.pageTransportGeneration(),
                        ),
                        callback,
                        // Captured before any handshake send: only a NEW real
                        // page-originated activation frame can satisfy it.
                        witnessBaseline = host.activationWitnessCount(),
                        fastPathEligible = host.isPageEditModeFresh(),
                    )
                    active = pending
                    started = pending
                    null
                }
            }
        }
        if (immediate != null) {
            callback(immediate)
            return
        }
        val pending = started ?: return
        host.recordDiagnostic(
            "edit preparation start op=$opId pageEditMode=${host.isPageEditMode()} " +
                "fastPath=${pending.fastPathEligible} witnessBaseline=${pending.witnessBaseline}",
        )

        // The bounded timeout is armed BEFORE any asynchronous
        // verification/handshake step so every route is covered, and a
        // missing scheduler refuses before any native/JS side effect.
        val timeoutTask = Runnable {
            dispatchToControlLane(
                Runnable {
                    finish(
                        pending,
                        OfficeEditModePreparationResult(
                            OfficeEditModePreparationFailure.TIMEOUT,
                            "page-edit-mode-timeout",
                        ),
                    )
                },
            )
        }
        val handle = try {
            host.scheduleTimeout(timeoutMs, timeoutTask)
        } catch (t: Throwable) {
            finish(
                pending,
                OfficeEditModePreparationResult(
                    OfficeEditModePreparationFailure.TRANSPORT,
                    "edit-timeout-schedule-${t.javaClass.simpleName}",
                ),
            )
            return
        }
        val stale = synchronized(lock) {
            if (active !== pending) {
                true
            } else {
                pending.timeoutHandle = handle
                false
            }
        }
        if (stale) {
            if (handle != null) host.cancelTimeout(handle)
            return
        }
        if (handle == null) {
            finish(
                pending,
                OfficeEditModePreparationResult(
                    OfficeEditModePreparationFailure.TIMEOUT,
                    "page-edit-mode-no-scheduler",
                ),
            )
            return
        }

        if (pending.fastPathEligible) {
            val verifyStarted = try {
                host.verifyPageTransportHealth(pending.token) { healthy ->
                    dispatchToControlLane(
                        Runnable { completeHealthVerification(pending, healthy) },
                    )
                }
                true
            } catch (t: Throwable) {
                host.recordDiagnostic(
                    "edit preparation health verify failed: ${t.javaClass.simpleName}",
                )
                false
            }
            if (verifyStarted) return
            // A synchronously broken verifier falls back to the handshake,
            // which carries its own typed failure honesty.
        }
        startHandshake(pending)
    }

    /**
     * The page-mode79 ordered handshake route (unchanged contract): the
     * service-owned native editable send, then the guarded page hook
     * (Session prefixes it with the bounded wake drain). A success candidate
     * requires the completed owned hook, the page's EDITMODE-on observation
     * and one new activation after [Active.witnessBaseline], then still passes
     * the operation's final current-health verification before READY.
     */
    private fun startHandshake(pending: Active) {
        synchronized(lock) {
            if (active !== pending) return
            // A warm miss/freshness change has exactly ONE cold continuation;
            // subsequent EDITMODE events must use the cold phase latches.
            pending.fastPathEligible = false
        }
        if (!isCurrentGeneration(pending)) {
            finish(pending, pageGenerationChangedResult())
            return
        }
        if (!host.isMountLive()) {
            finish(
                pending,
                OfficeEditModePreparationResult(
                    OfficeEditModePreparationFailure.SESSION_ENDING,
                    "mount-ended-during-edit-preparation",
                ),
            )
            return
        }
        if (!host.isEditableReady()) {
            finish(
                pending,
                OfficeEditModePreparationResult(
                    OfficeEditModePreparationFailure.NOT_EDITABLE,
                    "edit-permission-lost-during-preparation",
                ),
            )
            return
        }
        try {
            // The page's own edit hook may emit a duplicate setviewreadonly;
            // the precision lease intentionally fences that page duplicate.
            // This service-owned send is the authorized native counterpart.
            if (!host.sendNativeEditable(pending.token)) {
                finish(
                    pending,
                    OfficeEditModePreparationResult(
                        OfficeEditModePreparationFailure.SESSION_ENDING,
                        "native-edit-dispatch-fenced",
                    ),
                )
                return
            }
        } catch (t: Throwable) {
            finish(
                pending,
                OfficeEditModePreparationResult(
                    OfficeEditModePreparationFailure.TRANSPORT,
                    "native-edit-send-${t.javaClass.simpleName}",
                ),
            )
            return
        }

        synchronized(lock) {
            if (active !== pending) return
            pending.hookIssued = true
        }
        try {
            host.enterPageEditMode(pending.token) { hookRan ->
                dispatchToControlLane(
                    Runnable {
                        if (!hookRan) {
                            finish(
                                pending,
                                OfficeEditModePreparationResult(
                                    OfficeEditModePreparationFailure.TRANSPORT,
                                    "page-edit-hook-unavailable",
                                ),
                            )
                            return@Runnable
                        }
                        val current = synchronized(lock) {
                            if (active !== pending) {
                                false
                            } else {
                                pending.hookCompleted = true
                                true
                            }
                        }
                        if (current) maybeStartFinalHealthVerification(pending)
                    }
                )
            }
        } catch (t: Throwable) {
            finish(
                pending,
                OfficeEditModePreparationResult(
                    OfficeEditModePreparationFailure.TRANSPORT,
                    "page-edit-hook-${t.javaClass.simpleName}",
                ),
            )
        }
    }

    /**
     * Cold route: hook + EDITMODE/activation candidate -> ONE final health
     * verification. "ONE" is one owned verification, not necessarily one
     * injection: the cold route uses the bounded read
     * ([Host.verifyPageTransportHealthUntilFresh]) so the handshake script's
     * own asynchronous poll burst gets the real delivery opportunity before
     * an open-but-stale page is refused. It never repeats a native or hook
     * effect and never extends the preparation's bounded timeout.
     */
    private fun maybeStartFinalHealthVerification(pending: Active) {
        val start = synchronized(lock) {
            if (
                active === pending && pending.hookCompleted && pending.editAckObserved &&
                !pending.finalHealthStarted
            ) {
                pending.finalHealthStarted = true
                true
            } else {
                false
            }
        }
        if (!start) return
        try {
            host.verifyPageTransportHealthUntilFresh(pending.token) { healthy ->
                dispatchToControlLane(
                    Runnable { completeHealthVerification(pending, healthy) },
                )
            }
        } catch (t: Throwable) {
            finish(
                pending,
                OfficeEditModePreparationResult(
                    OfficeEditModePreparationFailure.TRANSPORT,
                    "page-final-health-${t.javaClass.simpleName}",
                ),
            )
        }
    }

    /**
     * THE single success boundary for both routes. A current owned health
     * answer is necessary but not sufficient: the final continuation also
     * re-reads the exact generation, mount, edit permission and raw page
     * mode. Cold candidates additionally require the completed owned hook;
     * warm candidates must still carry their corroborated fresh edit fact.
     */
    private fun completeHealthVerification(pending: Active, healthy: Boolean) {
        if (!isCurrentGeneration(pending)) {
            finish(pending, pageGenerationChangedResult())
            return
        }
        if (!healthy) {
            if (pending.fastPathEligible) {
                // Only the WARM failure may fall through to the one real
                // handshake. A failed COLD final read never repeats native/
                // hook effects as a hidden retry.
                startHandshake(pending)
            } else {
                finish(
                    pending,
                    OfficeEditModePreparationResult(
                        OfficeEditModePreparationFailure.TRANSPORT,
                        "page-health-verification-failed",
                    ),
                )
            }
            return
        }
        val failure = when {
            !host.isMountLive() -> OfficeEditModePreparationResult(
                OfficeEditModePreparationFailure.SESSION_ENDING,
                "mount-ended-during-edit-preparation",
            )
            !host.isEditableReady() -> OfficeEditModePreparationResult(
                OfficeEditModePreparationFailure.NOT_EDITABLE,
                "edit-permission-lost-during-preparation",
            )
            !host.isPageEditMode() -> OfficeEditModePreparationResult(
                OfficeEditModePreparationFailure.NOT_EDITABLE,
                "page-edit-mode-lost-before-health-completion",
            )
            !pending.fastPathEligible && !(pending.hookCompleted && pending.editAckObserved) ->
                OfficeEditModePreparationResult(
                    OfficeEditModePreparationFailure.TRANSPORT,
                    "page-edit-phase-evidence-missing",
                )
            pending.fastPathEligible && !host.isPageEditModeFresh() -> null
            else -> null
        }
        if (failure == null && pending.fastPathEligible && !host.isPageEditModeFresh()) {
            // The cached state changed while the warm answer was in flight:
            // its old verification cannot be recycled; use the real hook.
            startHandshake(pending)
            return
        }
        if (failure != null) {
            finish(pending, failure)
            return
        }
        finish(
            pending,
            OfficeEditModePreparationResult(
                null,
                if (pending.fastPathEligible) {
                    "cached-edit-health-verified"
                } else {
                    "page-edit-mode-health-verified"
                },
            ),
        )
    }

    /**
     * Executes a real native/JS side effect only if this exact preparation
     * incarnation is still active. Session calls this while holding
     * nativeIngressLock and uses the SAME lock around cancel/close, so once
     * cancellation returns no late native send or WebView hook can start.
     * No operation callback is invoked under this monitor.
     */
    fun runIfActive(
        token: OfficeEditModePreparationToken,
        action: () -> Unit,
    ): Boolean = synchronized(lock) {
        if (active?.token != token) return@synchronized false
        if (host.pageTransportGeneration() != token.pageGeneration) return@synchronized false
        action()
        true
    }

    /**
     * A view/socket incarnation change fences the real execution points
     * immediately through [runIfActive]. Settlement is marshalled to the
     * normal control lane by Session; a newer preparation is untouched.
     */
    fun onPageTransportGenerationChanged() {
        val pending = synchronized(lock) { active } ?: return
        if (!isCurrentGeneration(pending)) finish(pending, pageGenerationChangedResult())
    }

    /** Consumes the real page EDITMODE observation forwarded by Session. */
    fun onPageEditMode(enabled: Boolean, pageGeneration: Long) {
        val pending = synchronized(lock) { active } ?: return
        // A late fact from an older page incarnation is irrelevant to this
        // preparation; in particular stale OFF cannot reject or settle a new
        // generation's operation as an after-effect UNKNOWN.
        if (pending.token.pageGeneration != pageGeneration) return
        if (!isCurrentGeneration(pending)) {
            finish(pending, pageGenerationChangedResult())
            return
        }
        if (!enabled) {
            finish(
                pending,
                OfficeEditModePreparationResult(
                    OfficeEditModePreparationFailure.NOT_EDITABLE,
                    "page-viewing-during-edit-preparation",
                ),
            )
            return
        }
        // Warm verification has its OWN current-health continuation. An
        // unsolicited/raw on while that read is pending is not an alternate
        // success exit (MAIN_FINAL_ADMISSION_ENTRYPOINT_REVIEW).
        if (pending.fastPathEligible) return
        // Cold candidates may be recorded only after the owned hook chain
        // was issued. They remain unready until the real hook completed AND
        // this operation's own final health read completed successfully.
        if (!pending.hookIssued) return
        val failure = when {
            !host.isMountLive() -> OfficeEditModePreparationResult(
                OfficeEditModePreparationFailure.SESSION_ENDING,
                "mount-ended-during-edit-preparation",
            )
            !host.isEditableReady() -> OfficeEditModePreparationResult(
                OfficeEditModePreparationFailure.NOT_EDITABLE,
                "edit-permission-lost-during-preparation",
            )
            !host.isPageEditMode() -> OfficeEditModePreparationResult(
                OfficeEditModePreparationFailure.NOT_EDITABLE,
                "page-edit-ack-without-current-state",
            )
            host.activationWitnessCount() <= pending.witnessBaseline ->
                OfficeEditModePreparationResult(
                    OfficeEditModePreparationFailure.NOT_EDITABLE,
                    "page-activation-witness-missing",
                )
            else -> null
        }
        if (failure != null) {
            finish(pending, failure)
            return
        }
        synchronized(lock) {
            if (active !== pending) return
            pending.editAckObserved = true
        }
        maybeStartFinalHealthVerification(pending)
    }

    /** Cancels only this exact preparation; its late callbacks become no-ops. */
    fun cancel(opId: String) {
        val cancelled = synchronized(lock) {
            val pending = active?.takeIf { it.opId == opId }
            if (pending != null) active = null
            pending
        } ?: return
        cancelled.timeoutHandle?.let(host::cancelTimeout)
        host.recordDiagnostic("edit preparation cancelled op=$opId")
    }

    /** Mount terminal: clear without invoking an operation callback. */
    fun close() {
        val cancelled = synchronized(lock) {
            closed = true
            val pending = active
            active = null
            pending
        } ?: return
        cancelled.timeoutHandle?.let(host::cancelTimeout)
    }

    private fun finish(
        pending: Active,
        result: OfficeEditModePreparationResult,
    ) {
        val callback = synchronized(lock) {
            if (active !== pending) return
            active = null
            pending.timeoutHandle?.let(host::cancelTimeout)
            pending.callback
        }
        host.recordDiagnostic(
            "edit preparation finish op=${pending.opId} ready=${result.isReady} detail=${result.detail}",
        )
        callback(result)
    }

    private fun isCurrentGeneration(pending: Active): Boolean =
        host.pageTransportGeneration() == pending.token.pageGeneration

    private fun pageGenerationChangedResult() = OfficeEditModePreparationResult(
        OfficeEditModePreparationFailure.TRANSPORT,
        "page-transport-generation-changed",
    )

    private fun dispatchToControlLane(task: Runnable) {
        // During teardown the lane may already be gone. The synchronized
        // Active fence still prevents a stale completion; mount close owns
        // the final UNKNOWN settlement in that case.
        if (!host.runOnControlLane(task)) task.run()
    }

    companion object {
        const val DEFAULT_TIMEOUT_MS = 10_000L
    }
}
