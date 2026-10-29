// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

/**
 * Service-owned bounded background transport pump for the pinned mobile
 * fake-websocket (page-transport85).
 *
 * Why this exists (all facts pinned in the C15 causal record and the
 * producer source at revision 2333344185931274f9c49d6c12a408cefcef6844):
 *
 * - The pinned mobile page has NO polling of its own: `MobileSocket`
 *   overrides `_setPollInterval()` with a no-op (browser/js/global.js:1900)
 *   and `close()` with a no-op (global.js:1899), so `window.socket.doSend()`
 *   runs ONLY when this host injects it. The host is the sole poll source.
 * - The page's transport watchdog (global.js:1688-1717) closes the socket
 *   with code 1006 exactly when THREE facts hold inside one `doSend()`
 *   call: `msgInflight >= 4`, the throttle ladder already at its 500 ms cap,
 *   and `performance.now() - lastDataTimestamp > 30 s`.
 * - `lastDataTimestamp` and the ladder are reset ONLY by a non-empty 200
 *   poll response (global.js:1731-1742); an empty 200 merely walks the idle
 *   ladder (global.js:1751-1761). So keeping a hidden/idle mount's transport
 *   genuinely healthy requires delivering REAL downlink data, not just polls.
 * - The pinned producer supports exactly one real, document-independent
 *   downlink heartbeat: a client `ping` is answered by wsd itself with
 *   `pong rendercount=<n>` (wsd/ClientSession.cpp:1006-1009 at the pinned
 *   revision). It is WSD-local (never forwarded to the kit), it is neither a
 *   `status:` nor a `commandvalues:` frame, so it cannot collide with the
 *   precision correlation ledger or the `.uno:ReadOnly` barrier, and the
 *   pinned page tolerates an unsolicited `pong` (browser/src/app/Socket.ts
 *   only consumes it under `_debug.pingOn`, otherwise it falls through to
 *   the unknown-message debug log). The host uplink write is message-atomic
 *   under the producer's global FakeSocket mutex (net/FakeSocket.cpp:693),
 *   so a main-thread ping can never interleave with a control-lane command.
 * - While the Office window is hidden the page's loads are deferred (its poll
 *   XHRs cannot complete), so NO host action can refresh the page's
 *   `lastDataTimestamp` during the hidden window. What the host CAN do is
 *   (a) keep one real `pong` waiting in the bounded
 *   [org.libreoffice.androidlib.MobileSocket] queue so the FIRST poll that
 *   completes after the wake delivers real data and resets the watchdog state,
 *   and (b) strictly bound the queued injections so the wake does not replay a
 *   trigger flood that walks the ladder to the cap before any poll can
 *   complete (the actual C15 kill sequence).
 *
 * docx-socket-repair122 CORRECTION (actual C17 DOCX first failure,
 * 2026-10-29): the earlier assumption that an injected `doSend()` does not
 * EXECUTE on a hidden WebView is wrong. The retained C17 logcat shows
 * injected JS running while the window was hidden ('Error: sending on closed
 * socket' every ~20 s after the close) and the fatal watchdog firing inside a
 * host injection at 17:04:00.123 with `msgInflight` still pinned at the cap by
 * the handshake's four deferred polls. A hidden injection can therefore never
 * deliver data (the polls are deferred) and can only walk the ladder — and at
 * >30 s staleness it closes the socket. The host must inject NO `doSend()`
 * while the page window is not visible; the session gates every injection on
 * the live view visibility and the drain reads the page's own counters before
 * arming a poll ([OfficeTransportWatchdog] / [OfficeHiddenTransportAdmission]).
 *
 * Contract (pure JVM; callers inject `SystemClock.elapsedRealtime()`):
 *
 * 1. ONE round at a time. [onTick] opens a round at most once per
 *    [intervalMs] and only when no round is open; [requestRound] opens one
 *    on demand (the admission drain's retry path) under the same bound.
 *    Opening a round is the caller's cue to send ONE `ping` uplink and issue
 *    ONE poll injection. While a round is open (injection queued behind a
 *    frozen renderer, waiting for execution or arrival) no further
 *    ping/probe is ever produced: a hidden window of any length accumulates
 *    at most one queued injection and one queued pong.
 * 2. EVERY injection carries a host-minted, never-reused identity
 *    ([onInjectionIssued] `injectionSeq`), and a heartbeat round's injection
 *    additionally carries its [currentRoundId]. Execution, settle and
 *    arrival bookkeeping accept ONLY identity-matched calls: a stale
 *    callback from a previous view/socket generation (after [reset]) or a
 *    superseded injection can never mark a newer round executed, complete
 *    it, or clear the gate. This is the async-identity contract required by
 *    Main's late critical review (2026-10-28); the host additionally fences
 *    callbacks by captured view identity before reaching this class.
     * 3. A round completes on the FIRST of: a non-failure served poll after
     *    the CURRENT injection executed ([onPollServed] — old pre-freeze XHRs
     *    cannot release a still-queued injection), or the bounded settle window
     *    after the ROUND'S OWN injection executed without producing a poll
 *    ([onProbeSettled] — the pinned `doSend()` early-returns at
 *    `msgInflight >= 4`, walking one ladder step and issuing nothing;
 *    holding the gate after that would stall the transport). An injection
 *    that never executes (frozen renderer) keeps the round open on purpose:
 *    that is the flood bound.
 * 4. [pollOutstanding] is the PAGE-side single-pending-poll gate for every
 *    `doSend()` injection (ordinary [OfficeSendTrigger] traffic included):
 *    an injection not yet matched by a served poll must not be stacked.
 *    The gate is released only by real, identity-consistent events — a
 *    served poll, the settled execution of exactly that injection, a
 *    view/socket change ([reset]) or the mount terminal ([stop]) — never by
 *    elapsed time alone, because elapsed time is exactly what a frozen
 *    renderer produces. The bound is never relaxed: at most one injection
 *    is outstanding at any instant.
 * 5. [stop] is terminal for the mount; [reset] re-arms bookkeeping for a
 *    re-attached view/socket (a fresh [org.libreoffice.androidlib.MobileSocket]
 *    with a fresh serial space) without un-stopping a stopped pump.
 *
 * Interval bound: [DEFAULT_HEARTBEAT_INTERVAL_MS] must stay strictly below
 * half the pinned 30 s no-response window, so that even the worst observed
 * race (a poll served empty just before the pong is queued, deferring real
 * delivery to the next round) leaves the page's `lastDataTimestamp` at most
 * ~2 intervals + settle old while the renderer runs — never reaching the
 * 30 s staleness the watchdog requires.
 *
 * Thread safety: called from the main thread (ticks, injection issuance,
 * execution/settle callbacks) and from the WebView network thread
 * ([onPollServed] via `MobileSocket.write()`); all state is guarded by this
 * object's monitor.
 */
internal class OfficeTransportPump(
    private val intervalMs: Long = DEFAULT_HEARTBEAT_INTERVAL_MS,
) {
    enum class TickDecision { HEARTBEAT, PROBE, IDLE }

    private val lock = Any()
    private var stopped = false

    // --- heartbeat round identity ---
    private var roundOpen = false
    private var openRoundId = 0L
    private var nextRoundId = 1L
    private var lastRoundEndMs = 0L
    private var arrivalSinceOpen = false
    private var roundProbeIssued = false

    // --- injection identity (single-pending-poll gate) ---
    private var outstandingSeq = 0L
    private var outstandingRoundId = 0L
    private var executedSeq = 0L

    /**
     * One scheduler tick. [TickDecision.HEARTBEAT] authorizes EXACTLY one
     * `ping` uplink plus one poll injection for a freshly opened round.
     * [TickDecision.PROBE] authorizes ONLY the missing probe for an already-
     * pinged round whose foreign blocking injection just settled (never a
     * second ping). [TickDecision.IDLE] has no transport side effect.
     */
    fun onTick(nowMs: Long): TickDecision = synchronized(lock) {
        when {
            stopped -> TickDecision.IDLE
            roundOpen && outstandingSeq != 0L -> TickDecision.IDLE
            // The round's ping may have opened behind ordinary traffic. Once
            // that foreign injection settles, arm the ALREADY OPEN round's
            // own probe WITHOUT sending a second ping; otherwise the open
            // round would wedge forever and real pong delivery would stop.
            roundOpen && !roundProbeIssued -> TickDecision.PROBE
            roundOpen -> TickDecision.IDLE
            nowMs - lastRoundEndMs < intervalMs -> TickDecision.IDLE
            else -> {
                openRoundLocked()
                TickDecision.HEARTBEAT
            }
        }
    }

    /**
     * Opens a round ON DEMAND, ignoring the interval gate — the bounded
     * pre-admission drain uses this when the page's own counters show stale
     * real data: an immediate `ping` queues the real `pong` whose delivery
     * the drain's armed polls then witness. Still strictly one open round at
     * a time, so a drain can never produce more than one outstanding
     * heartbeat; false when a round is already open or the pump is stopped.
     */
    fun requestRound(): Boolean = synchronized(lock) {
        if (stopped || roundOpen) {
            false
        } else {
            openRoundLocked()
            true
        }
    }

    /** Identity of the currently open round (0 when none is open). */
    fun currentRoundId(): Long = synchronized(lock) { if (roundOpen) openRoundId else 0L }

    /**
     * Records one issued `doSend()` injection under its host-minted,
     * never-reused [injectionSeq]; [roundId] is the heartbeat round it
     * belongs to (0 for ordinary traffic and drain-only probes). Callers
     * MUST have checked [pollOutstanding] first — the bound is one.
     */
    fun onInjectionIssued(injectionSeq: Long, roundId: Long) = synchronized(lock) {
        require(injectionSeq != 0L) { "injection identity must be non-zero" }
        outstandingSeq = injectionSeq
        outstandingRoundId = roundId
        if (roundOpen && roundId != 0L && roundId == openRoundId) {
            roundProbeIssued = true
        }
        Unit
    }

    /** A matched issuance attempt failed synchronously; nothing became pending. */
    fun onInjectionIssueFailed(injectionSeq: Long, nowMs: Long) = synchronized(lock) {
        if (outstandingSeq == injectionSeq) {
            val failedRoundId = outstandingRoundId
            outstandingSeq = 0L
            outstandingRoundId = 0L
            executedSeq = 0L
            // A failed evaluateJavascript issuance must not wedge this round
            // forever. Retry with a NEW ping on a later interval; no hidden
            // immediate retry and no effect on a foreign open round.
            if (roundOpen && failedRoundId != 0L && failedRoundId == openRoundId) {
                completeRoundLocked(nowMs)
            }
        }
        Unit
    }

    /**
     * A non-failure page poll reached the host (`MobileSocket.write()` planned
     * an empty/body 200). Arrival matches only a CURRENT EXECUTED injection;
     * an older pre-freeze XHR cannot release a queued injection or complete
     * its round. Arrival is NOT a page-consumption proof for admission
     * freshness — see
     * `OfficePageEditModeWitness.onPageReportedFreshDownlink`, which is fed
     * only by the page's own health reads.
     */
    fun onPollServed(nowMs: Long) = synchronized(lock) {
        // Up to four XHRs from BEFORE the current injection may legitimately
        // reach the host. Their arrival must not release a still-queued
        // injection or complete its round while the renderer is frozen.
        // Every injection (ordinary trigger traffic included) has an
        // execution callback, so only a current executed injection — or an
        // already idle gate — may use arrival as delivery progress.
        if (outstandingSeq == 0L || executedSeq != outstandingSeq) {
            return@synchronized Unit
        }
        outstandingSeq = 0L
        outstandingRoundId = 0L
        executedSeq = 0L
        if (roundOpen && !arrivalSinceOpen) {
            arrivalSinceOpen = true
            completeRoundLocked(nowMs)
        }
        Unit
    }

    /**
     * The injection [injectionSeq] actually ran in the renderer. Identity-
     * matched: a stale callback (previous view/socket generation, superseded
     * injection) marks nothing and returns false so the host will NOT replace
     * the current injection's settle task.
     */
    fun onProbeExecuted(injectionSeq: Long): Boolean = synchronized(lock) {
        if (injectionSeq != 0L && injectionSeq == outstandingSeq) {
            executedSeq = injectionSeq
            true
        } else {
            false
        }
    }

    /**
     * The bounded settle window after an identity-matched [onProbeExecuted]
     * elapsed with no served poll: that injection's `doSend()` necessarily
     * early-returned at the pinned `msgInflight >= 4` gate (or its poll was
     * lost). Releases the gate for EXACTLY that injection, and completes its
     * heartbeat round when it was the round's own injection. A settle for a
     * superseded/stale identity is a deterministic no-op — it can never
     * clear a newer outstanding injection or complete a newer round.
     */
    fun onProbeSettled(injectionSeq: Long, nowMs: Long) = synchronized(lock) {
        if (injectionSeq == 0L) return@synchronized Unit
        if (outstandingSeq == injectionSeq && executedSeq == injectionSeq) {
            val settledRoundId = outstandingRoundId
            outstandingSeq = 0L
            outstandingRoundId = 0L
            executedSeq = 0L
            // The round completes only when the settled injection WAS this
            // round's own injection and no arrival completed it earlier.
            if (roundOpen && !arrivalSinceOpen && settledRoundId != 0L && settledRoundId == openRoundId) {
                completeRoundLocked(nowMs)
            }
        }
        Unit
    }

    /**
     * The page-side single-pending-poll gate: true while one issued
     * injection has not been matched by a served poll or its own settled
     * execution. Callers MUST NOT issue another `doSend()` injection
     * meanwhile (that stacking is the C15 wake flood); the served poll's
     * own tail re-arm continues the delivery chain.
     */
    fun pollOutstanding(): Boolean = synchronized(lock) { outstandingSeq != 0L }

    /** A heartbeat round is currently open (diagnostics/tests). */
    fun isRoundOpen(): Boolean = synchronized(lock) { roundOpen }

    /**
     * View/socket change (attach or detach): the queued-injection reality
     * and the serial space both belong to the OLD
     * [org.libreoffice.androidlib.MobileSocket]; drop ALL bookkeeping so
     * stale callbacks from the old generation match nothing and the next
     * tick can open a fresh round immediately. Never un-stops.
     */
    fun reset() = synchronized(lock) {
        roundOpen = false
        openRoundId = 0L
        arrivalSinceOpen = false
        roundProbeIssued = false
        outstandingSeq = 0L
        outstandingRoundId = 0L
        executedSeq = 0L
        lastRoundEndMs = 0L
        Unit
    }

    /** Mount terminal: no further rounds, gate cleared, irreversible. */
    fun stop() = synchronized(lock) {
        stopped = true
        roundOpen = false
        openRoundId = 0L
        arrivalSinceOpen = false
        roundProbeIssued = false
        outstandingSeq = 0L
        outstandingRoundId = 0L
        executedSeq = 0L
        Unit
    }

    fun isStopped(): Boolean = synchronized(lock) { stopped }

    private fun openRoundLocked() {
        roundOpen = true
        openRoundId = nextRoundId++
        arrivalSinceOpen = false
        roundProbeIssued = false
    }

    private fun completeRoundLocked(nowMs: Long) {
        roundOpen = false
        openRoundId = 0L
        arrivalSinceOpen = false
        roundProbeIssued = false
        lastRoundEndMs = nowMs
    }

    companion object {
        /**
         * Strictly below half the pinned 30 s no-response watchdog
         * (global.js:1707) so a running renderer's `lastDataTimestamp` can
         * never age past the watchdog between two heartbeat deliveries,
         * even when one round's poll is served empty just before the pong
         * is queued. Also below the 15 s admission freshness window
         * ([OfficePageEditModeWitness.DEFAULT_FRESH_WINDOW_MS]) so an
         * ordinary approval wait re-witnesses through the real handshake
         * instead of riding a cached fact.
         */
        const val DEFAULT_HEARTBEAT_INTERVAL_MS = 10_000L

        /**
         * Bounded window for a served poll to follow an executed injection
         * before its settle releases the gate anyway (the pinned `doSend()`
         * early-return path). Generous against a local intercepted XHR
         * round trip (milliseconds — the response is served from memory in
         * `MobileSocket.write()`), short enough that the ~3 s admission
         * drain budget contains several probe cycles.
         */
        const val PROBE_SETTLE_MS = 500L
    }
}

/**
 * Bounded pre-admission wake drain decision (page-transport85).
 *
 * The enter-edit handshake's synchronous 24-call `doSend()` probe
 * ([OfficeReadOnlyProtocol.PAGE_ENTER_EDIT_SCRIPT]) forces the pinned
 * watchdog to evaluate NOW. On a page whose transport is genuinely dying
 * that is the intended typed pre-dispatch refusal (page-mode79). But on a
 * HEALTHY page woken from a hidden-WebView wait the probe can run while up
 * to four frozen poll XHRs are still in flight (`msgInflight >= 4`): every
 * probe call then walks the throttle ladder instead of polling, and if the
 * ladder reaches its cap while `lastDataTimestamp` is still stale the
 * watchdog kills a transport that was about to recover — a healthy mount
 * turned into a perpetual dead-document refusal.
 *
 * The drain removes that false kill WITHOUT weakening the probe: before the
 * handshake script runs, the host performs a bounded series of read-only
 * page-health reads, each iteration arming at most one poll so the waiting
 * real `pong` (queued by [OfficeTransportPump] during the hidden window) can
 * be delivered. Real delivery resets `lastDataTimestamp` in the page itself
 * (global.js:1739), and a `doSend()` can only close the socket when the
 * staleness exceeds 30 s — so once the drain observes fresh real data IN
 * THE PAGE'S OWN COUNTERS, the subsequent probe PROVABLY cannot kill the
 * page, whatever the ladder or in-flight state. When the drain cannot
 * observe freshness within its budget (a genuinely stuck renderer, a closed
 * socket), the script still runs and gives its honest verdict: the drain is
 * a health-restoration opportunity, never an admission gate and never a
 * success claim.
 *
 * Pure decision source; the fenced iteration loop (token, mount, captured-
 * view identity) lives in the session.
 */
internal object OfficeTransportDrain {
    /**
     * One bounded iteration outcome (docx-socket-repair122):
     *
     *  - [RETRY_WITH_PROBE] — open, below the pinned in-flight cap and stale:
     *    arm ONE poll. Safe by construction: with `msgInflight < 4` the pinned
     *    `doSend()` takes its send path and cannot reach the watchdog branch,
     *    whatever the staleness is.
     *  - [RETRY_READ_ONLY] — the state must change on the PAGE's side before
     *    any injection is safe: the in-flight counter is pinned at the cap
     *    (the pinned `doSend()` would only walk the ladder; at >30 s staleness
     *    it would close the socket) or the answer was unreadable (never probe
     *    blind). Read again after a real delay and inject nothing.
     *  - [PROCEED_SCRIPT] — fresh real data, a closed transport, a budget that
     *    ended without a provable hazard, or an unreadable page: the ordered
     *    handshake stays the single honest verdict.
     *  - [REFUSE_ARMED] — the page's in-flight counter is STILL pinned at the
     *    cap when the budget ends. Running the handshake's synchronous probe
     *    burst here would close a page that is only waiting for its own
     *    deferred polls (the actual C17 wake shape), so refuse honestly
     *    (pre-dispatch, no injection) instead of killing it.
     */
    enum class Decision { RETRY_WITH_PROBE, RETRY_READ_ONLY, PROCEED_SCRIPT, REFUSE_ARMED }

    /**
     * The ONE page-truth freshness criterion (office-background-repair118),
     * shared by the pre-handshake wake drain, the cached fast path's live
     * read and the cold route's bounded final verification: real downlink
     * data demonstrably fresh in the PAGE's own clock on an OPEN socket. An
     * unreadable/absent answer or a page clock anomaly is never fresh
     * (honest), so it can never admit by itself.
     */
    fun isFresh(health: OfficeReadOnlyProtocol.OfficeTransportHealth?): Boolean =
        health != null && health.readyState == 1 &&
            health.stalenessMs in 0 until FRESH_STALENESS_MS

    /**
     * One drain iteration decision. [health] is the parsed page-truth read
     * (null when the page answer was absent/garbage/stale-view); [attempt]
     * is the zero-based index of the iteration that produced it.
     *
     * docx-socket-repair122: the decision never authorizes an injection the
     * pinned proxy could turn into a close. `msgInflight >= 4` disables the
     * poll arm entirely (the pinned `doSend()` early-returns before creating
     * its XHR, so the poll could only walk the ladder), and a budget that ends
     * with the counter still pinned refuses instead of running the probe
     * burst. Everything else is the unchanged 85/118 contract.
     */
    fun decide(
        health: OfficeReadOnlyProtocol.OfficeTransportHealth?,
        attempt: Int,
    ): Decision = when {
        // Real downlink data is demonstrably fresh in the PAGE's own clock:
        // the probe cannot reach its >30 s staleness condition. Proceed.
        isFresh(health) -> Decision.PROCEED_SCRIPT
        // A closed/closing (or never-opened) transport cannot be drained;
        // the script's connected() gate owns the typed refusal. Retrying
        // only burns the budget.
        health != null && health.readyState != 1 -> Decision.PROCEED_SCRIPT
        // Budget exhausted: only a page whose own counters still prove the
        // in-flight cap is pinned is refused (the burst would close it);
        // every other shape proceeds to the real handshake verdict.
        attempt + 1 >= MAX_ATTEMPTS ->
            if (health != null && health.readyState == 1 &&
                health.msgInflight >= OfficeTransportWatchdog.INFLIGHT_CAP
            ) {
                Decision.REFUSE_ARMED
            } else {
                Decision.PROCEED_SCRIPT
            }
        // Safe to arm one poll: the pinned doSend() creates its XHR and can
        // never evaluate the fatal branch at this in-flight count.
        OfficeTransportWatchdog.canInjectSafely(health) -> Decision.RETRY_WITH_PROBE
        // In-flight cap pinned, or an unreadable answer: let the page's own
        // deferred polls drain (or the view re-answer) before any injection.
        else -> Decision.RETRY_READ_ONLY
    }

    /**
     * Bounded iterations; with [RETRY_DELAY_MS] the whole drain costs at
     * most ~3 s of the preparation's 10 s timeout on a page that never
     * becomes fresh, and one round trip (~ms) on a healthy running page.
     */
    const val MAX_ATTEMPTS = 20
    const val RETRY_DELAY_MS = 150L

    /**
     * Freshness the drain must observe in the page's own
     * `performance.now() - lastDataTimestamp`. Mirrors the admission
     * freshness window and leaves at least 15 s of margin against the
     * pinned 30 s close condition even if the probe runs immediately after.
     */
    const val FRESH_STALENESS_MS = 15_000L
}
