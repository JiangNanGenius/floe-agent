// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

/**
 * Pinned page-proxy watchdog geometry and hidden-window admission
 * (docx-socket-repair122).
 *
 * WHY THIS FILE EXISTS — the actual C17 DOCX first failure (2026-10-29, APK
 * 503f21d…, source 14a7067e, G01 API 37):
 *
 * The pinned mobile page proxy parks its fatal watchdog INSIDE `doSend()`
 * (`dist/global.js`, pinned extract `page-mode79/pinned-extracts/global.js`
 * lines 1696-1716):
 *
 *     if (that.msgInflight >= 4) {                        // 1696 pinned cap
 *         if (that.curPollMs < that.maxPollMs) {          // 1701 ladder step
 *             throttle to curPollMs;
 *         } else if (performance.now() - that.lastDataTimestamp > 30 * 1000) {
 *             'Close connection after no response for 30secs';   // 1707-1709
 *             that._signalErrorClose();                   // 1710 -> 1006
 *         } else { 'pausing.'; }
 *         return;
 *     }
 *
 * `MobileSocket` deletes `_setPollInterval` and replaces it (and `close()`)
 * with no-ops (pinned extract lines 1885-1901), so the page NEVER polls on its
 * own and can never re-open itself: every `doSend()` execution — and therefore
 * every possible watchdog evaluation — is produced by the HOST injecting
 * `window.socket.doSend()`.
 *
 * The retained C17 logcat (`device-c17/docx-first-failure/owned-app-logcat.txt`)
 * shows the fatal sequence while the Office window was hidden for the Main
 * approval:
 *
 * - 17:03:37.447-17:03:40.114 — the enter-edit handshake's 24 synchronous
 *   `doSend()` calls pinned `msgInflight` at its cap of 4 and walked the
 *   throttle ladder to its 500 ms cap (22 x 'throttling to …' then 'pausing.').
 *   The four handshake polls never completed: their load/loadend callbacks had
 *   not run 20+ s later (a hidden WebView defers its page loads), which is why
 *   the in-flight counter was still at the cap.
 * - 17:04:00.123 — 'Close connection after no response for 30secs', then
 *   '_onSocketError: undefined' and
 *   '_onSocketClose: code=1006 wasClean=false reason=proxy error'.
 * - 17:04:20+ — 'Error: sending on closed socket' every ~20 s: injected JS
 *   still EXECUTED on the hidden page (only its loads were deferred), so a
 *   host-injected `doSend()` was the execution context of the close.
 *
 * The engine observed the page's EDITMODE drop at monotonic 2206699 (~22.5 s
 * after EDITMODE-on 2184127), and the applyText preparation 100 s later found
 * `readyState != 1` -> `page-edit-hook-unavailable`.
 *
 * So the FIRST producer of the 1006 was NOT a MobileSocket HTTP 503, not an
 * exhausted response budget, not a native error and not a WSD death: it was
 * the pinned page's OWN watchdog, evaluated inside a host-injected `doSend()`
 * while the window was hidden. `lastDataTimestamp` cannot be refreshed during
 * a hidden window (no poll response can be consumed by a hidden page), and
 * with the in-flight counter pinned at the cap every injection could only walk
 * the ladder; once staleness crossed 30 s the next evaluation closed the socket
 * exactly once — with no reconnect path (one fake-socket session per
 * createCOOLWSD lifetime).
 *
 * The ONE provable prevention is therefore host-side: while the page window is
 * not visible the host injects NO `doSend()`. Nothing else can close the
 * socket (the pinned `close()` is a no-op and a hidden page consumes no poll
 * responses), so the transport survives an approval wait of any length. On
 * wake the existing bounded drain delivers the heartbeat's queued real `pong`
 * and the ordered handshake proceeds on genuine page truth.
 *
 * Every `doSend()` source in this module funnels through the session's ONE
 * probe issuance point — the transport pump's heartbeat probe, the wake
 * drain's retry probe, the cold route's final-health retry probe, the manual
 * edit-drain probe, and `MobileSocket.queueSend()`'s `triggerSend()` tail
 * re-arm (which is how a heartbeat `pong` enqueued for the page arms a poll).
 * Gating that single point on live window visibility therefore covers every
 * injection, including the queued-then-executed one the C17 logcat shows
 * running on the hidden page at 17:04:00.123.
 *
 * The second hazard the pinned geometry creates is the WAKE race: a page left
 * hidden with `msgInflight` pinned at the cap would be closed by the FIRST
 * injected poll of the wake drain if staleness had already crossed 30 s. An
 * injection with `msgInflight >= 4` can never deliver data (the pinned
 * `doSend()` early-returns before creating its XHR), so it is never useful:
 * the drain reads the page's own counters first and only arms a poll once the
 * in-flight counter has drained below the cap; the deferred polls complete on
 * their own when the window becomes visible. If the cap is still pinned when
 * the bounded budget expires, the drain refuses honestly ([OfficeTransportDrain
 * .Decision.REFUSE_ARMED]) instead of running the handshake probe burst into a
 * certain close.
 *
 * Pure JVM decisions only (no Android types): the caller supplies the parsed
 * page-truth read ([OfficeReadOnlyProtocol.OfficeTransportHealth]).
 */
internal object OfficeTransportWatchdog {

    /** Pinned `that.msgInflight >= 4` cap (global.js pinned extract line 1696). */
    const val INFLIGHT_CAP = 4

    /** Pinned `performance.now() - lastDataTimestamp > 30 * 1000` (line 1707). */
    const val STALE_CLOSE_MS = 30_000L

    /**
     * True when the pinned watchdog would close the socket if the page
     * evaluated `doSend()` right now: an OPEN socket, the in-flight counter at
     * its cap and staleness STRICTLY past the pinned 30 s window (the pinned
     * comparison is `>`, so exactly 30 000 ms is not armed). In-flight at the
     * cap alone is not "armed" (a lower ladder rung merely throttles), but it
     * is still unsafe to poll — see [canInjectSafely].
     */
    fun isArmed(health: OfficeReadOnlyProtocol.OfficeTransportHealth?): Boolean =
        health != null && health.readyState == 1 &&
            health.msgInflight >= INFLIGHT_CAP && health.stalenessMs > STALE_CLOSE_MS

    /**
     * True when ONE injected `doSend()` is provably unable to close the socket:
     * the transport is open and the in-flight counter is BELOW the pinned cap,
     * so the pinned `doSend()` takes its send path (creates its XHR) instead of
     * the throttle/watchdog branch. Staleness does not matter here — the fatal
     * comparison is only reachable inside the `msgInflight >= 4` branch. An
     * unreadable answer is never safe.
     */
    fun canInjectSafely(health: OfficeReadOnlyProtocol.OfficeTransportHealth?): Boolean =
        health != null && health.readyState == 1 && health.msgInflight < INFLIGHT_CAP
}

/**
 * Hidden-window admission for the operation-owned edit preparation
 * (docx-socket-repair122).
 *
 * While the Office window is hidden no poll response can be consumed by the
 * page (the hidden renderer defers its loads — the C17 handshake polls were
 * still in flight 20+ s later, which is why the watchdog was armed at all), so
 * the visible route's page-consumed freshness criterion is unattainable by
 * construction. The hidden route therefore admits on a DIFFERENT, equally real
 * witness set — never on a fabricated timestamp:
 *
 *  1. the page's OWN socket object reports `readyState === 1` (a 1006 close
 *     sets it to 3 inside `_signalErrorClose`), read live through
 *     `evaluateJavascript` (which does execute on a hidden WebView — the C17
 *     logcat shows injected JS running while the window was hidden);
 *  2. wsd answers a host `ping` with its real `pong rendercount=` frame,
 *     OBSERVED BY THE HOST on `rawCallFakeWebsocketOnMessage` before it is
 *     queued for the page (native-side liveness; no page polling needed);
 *  3. the ordered enter-edit hooks still run in the page WITHOUT the
 *     synchronous 24-call `doSend()` burst (that burst exists only to force the
 *     watchdog evaluation, and forcing it is precisely what kills a recoverable
 *     hidden page), and the page posts its real `useractive` uplink plus its own
 *     EDITMODE-on ack over the ungated bridge — the same witnesses the visible
 *     handshake requires;
 *  4. ONE final page-truth read still reports `readyState === 1`.
 *
 * An armed (in-flight cap pinned) hidden page is still admissible: this route
 * injects NO `doSend()`, so it can neither close the socket nor need the page's
 * deferred polls; the host-issued permission/effect wire and its verification
 * frames do not traverse the page at all. The page's deferred polls complete
 * normally when the window becomes visible again.
 */
internal object OfficeHiddenTransportAdmission {

    /**
     * Bounded hidden-gate attempts. With [PONG_WAIT_MS] the whole gate costs
     * at most ~2.1 s of the preparation's unchanged 10 s timeout, leaving the
     * handshake and the single final read their margin. A wsd that cannot
     * answer a local in-process `ping` within ~700 ms is not a live producer
     * for this mount.
     */
    const val GATE_ATTEMPTS = 3

    /** Wait for ONE host-observed wsd `pong` after each gate `ping`. */
    const val PONG_WAIT_MS = 700L

    enum class Verdict {
        /** The page socket object is open; the hidden route may proceed. */
        ADMIT,

        /** `readyState != 1`: the pinned 1006 already happened; nothing recovers it. */
        REFUSE_SOCKET_CLOSED,

        /** No usable page answer (`nosocket`/`err`/malformed): never a health fact. */
        REFUSE_UNREADABLE,
    }

    fun decide(health: OfficeReadOnlyProtocol.OfficeTransportHealth?): Verdict = when {
        health == null -> Verdict.REFUSE_UNREADABLE
        health.readyState != 1 -> Verdict.REFUSE_SOCKET_CLOSED
        else -> Verdict.ADMIT
    }
}
