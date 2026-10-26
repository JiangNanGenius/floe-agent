// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

import java.util.concurrent.atomic.AtomicBoolean

/**
 * One-pending-poll coalescer for the pinned mobile fake-websocket.
 *
 * The pinned mobile socket (dist/global.js `class T extends ProxySocket`)
 * deletes `_setPollInterval` and overrides `close()` with a no-op, so
 * `window.socket.doSend()` runs ONLY when this host asks for it. The previous
 * revision asked once per queued native message, turning one engine burst into
 * hundreds of UI-thread and renderer-main-thread script evaluations. That
 * flood is a defect and not just waste: every such `doSend()` that finds the
 * page's in-flight counter at its hard cap of 4 walks the page's own throttle
 * ladder one step (`curPollMs *= 1.15`), and the ACTUAL Alpha13 C02 tablet
 * session walked it from 25 ms to the 500 ms cap in 27 ms — 23 steps. Reaching
 * the cap is what enables the page's fatal `> 30 s` no-response branch ("Close
 * connection after no response for 30secs"), which permanently kills a mobile
 * session that has no reconnect path; see MobileSocket's class header for the
 * full observed chain.
 *
 * Coalescing keeps at most ONE poll pending per view while guaranteeing that
 * the tail of a burst still arms a fresh poll: the flag is released
 * immediately BEFORE the poll is issued, so any message enqueued after that
 * point arms the next one. Combined with the bounded per-response batch in
 * `MobileSocket.write()` (which re-arms while data remains), delivery makes
 * forward progress without depending on new native messages.
 *
 * Pure and thread-safe: no Android type, so the contract is JVM-testable.
 */
class OfficeSendTrigger {

    private val pending = AtomicBoolean(false)

    /**
     * True for exactly one caller per pending poll: only that caller may
     * schedule `doSend()`. Everyone else returns false and relies on the
     * already-scheduled poll (which drains the whole bounded batch).
     */
    fun claim(): Boolean = pending.compareAndSet(false, true)

    /**
     * Ends the pending window. Called immediately BEFORE the poll is issued,
     * and also when scheduling the poll failed, so a claim can never be lost
     * (a lost claim would mean no further poll until the next native message).
     * Idempotent.
     */
    fun release() {
        pending.set(false)
    }

    /** Whether a poll is currently claimed but not yet issued. */
    val isPending: Boolean
        get() = pending.get()
}
