// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Deterministic JVM source for the cached page edit-mode freshness fact
 * (page-mode79 + page-transport85). The raw boolean stays the
 * dispatch-ordering fact; freshness is an ADMISSION property with THREE
 * required ingredients, all from the same page incarnation:
 *
 * 1. A cached EDITMODE-on observation recent inside a window strictly below
 *    the pinned page proxy's 30 s no-response watchdog, never invalidated by
 *    a page-lifecycle restart (page-mode79).
 * 2. An equally recent REAL page-originated `useractive` activation witness
 *    (page-transport85, critical finding A): the page posts EDITMODE on/off
 *    over the UNGATED bridge, which works even on a dying proxy, so a fresh
 *    RAW ack without a transport witness is not an admission fact.
 * 3. An equally recent PAGE-OBSERVED fresh-downlink report (Main confirmed
 *    + late critical reviews 2026-10-28): recent UPLINKS alone do not
 *    disprove the watchdog-stalled state — it keeps `readyState === 1` and
 *    keeps forwarding `useractive`/EDITMODE bridge posts while
 *    `msgInflight >= 4` and the page's own `lastDataTimestamp` is already
 *    stale. The stamp is fed ONLY by reads of the page's OWN counters
 *    (never by the host merely serving a body, which is a delivery
 *    opportunity, not a consumption proof), so it corroborates exactly the
 *    state the pinned 30 s watchdog measures.
 */
class OfficePageEditModeWitnessTest {

    private fun witnessed(windowMs: Long = 15_000): OfficePageEditModeWitness =
        OfficePageEditModeWitness(windowMs).apply {
            // The genuine healthy order: a page-truth health read reported
            // fresh real downlink data (the heartbeat pong consumed by the
            // page), the activation witness frame was forwarded BEFORE the
            // EDITMODE ack (same JS thread, ordered), then the fact.
            onPageReportedFreshDownlink(998)
            onActivationWitness(999)
            onPageFact(true, 1_000)
        }

    @Test
    fun freshWitnessedOnFactAdmitsInsideWindowOnly() {
        val witness = witnessed()
        assertTrue(witness.isEditing())
        assertTrue(witness.isFresh(1_000))
        // ALL THREE ages bind inside the same window: the downlink stamp
        // (998) is the oldest, so its age reaches the window edge first —
        // 15_998 is the last fresh millisecond.
        assertTrue(witness.isFresh(15_998))
        assertFalse(witness.isFresh(15_999))
        assertFalse(witness.isFresh(16_001))
    }

    @Test
    fun freshUplinksWithStaleOrMissingDownlinkAreNotFresh() {
        // Main confirmed fast-path review regression (2026-10-28), exact
        // watchdog-stalled shape: a fresh RAW EDITMODE-on plus a recent
        // real `useractive` uplink — BOTH still producible while
        // readyState===1, msgInflight>=4 and lastDataTimestamp is >30 s
        // stale — with no page-observed fresh downlink report anywhere.
        // NOT an admission fact.
        val witness = OfficePageEditModeWitness(windowMs = 15_000)
        witness.onActivationWitness(50_000)
        witness.onPageFact(true, 50_100)
        assertFalse(witness.isFresh(50_200))
        assertFalse(witness.isFresh(60_000))
        // A page-reported freshness that aged out is equally stale: the
        // pump's ~10 s real-pong cadence is what keeps a healthy mount's
        // page-side counters — and therefore this stamp — fresh.
        val witness2 = OfficePageEditModeWitness(windowMs = 15_000)
        witness2.onPageReportedFreshDownlink(10_000)
        witness2.onActivationWitness(30_000)
        witness2.onPageFact(true, 30_100)
        assertFalse(witness2.isFresh(30_200))
        // One fresh page-truth read re-corroborates immediately.
        witness2.onPageReportedFreshDownlink(30_150)
        assertTrue(witness2.isFresh(30_200))
    }

    @Test
    fun downlinkDeliveryAloneCannotCorroborateARawFact() {
        // Layering: fresh downlink + fresh raw fact but NO activation
        // witness stays uncorroborated (finding A), and fresh downlink +
        // activation but no on-fact is not editing at all.
        val witness = OfficePageEditModeWitness(windowMs = 15_000)
        witness.onPageReportedFreshDownlink(1_000)
        witness.onPageFact(true, 1_100)
        assertFalse(witness.isFresh(1_200))
        val witness2 = OfficePageEditModeWitness(windowMs = 15_000)
        witness2.onPageReportedFreshDownlink(1_000)
        witness2.onActivationWitness(1_050)
        assertFalse(witness2.isFresh(1_200))
        assertFalse(witness2.isEditing())
    }

    @Test
    fun lifecycleRestartInvalidatesTheDownlinkStamp() {
        val witness = witnessed()
        assertTrue(witness.isFresh(1_500))
        witness.onPageLifecycleRestart()
        // New incarnation: neither the old downlink nor the old activation
        // stamp can vouch for it; all three must be re-observed.
        witness.onPageFact(true, 2_000)
        assertFalse(witness.isFresh(2_100))
        witness.onPageReportedFreshDownlink(2_200)
        assertFalse(witness.isFresh(2_300))
        witness.onActivationWitness(2_400)
        assertTrue(witness.isFresh(2_500))
    }

    @Test
    fun neverWitnessedFactIsNotFresh() {
        val witness = OfficePageEditModeWitness(windowMs = 15_000)
        assertFalse(witness.isEditing())
        assertFalse(witness.isFresh(0))
        assertFalse(witness.isFresh(100_000))
    }

    @Test
    fun freshRawOnFactWithoutActivationWitnessIsNotFresh() {
        // page-transport85 finding A regression: the pinned page posts
        // EDITMODE on over the ungated bridge even while its socket
        // transport is dying (Permission.js:730) — a direct/manual raw
        // toggle with a dead transport produces EXACTLY this shape: a
        // seconds-old on-fact and no real `useractive` frame (the page can
        // only forward one at readyState===1). Recent is not transport-proved.
        val witness = OfficePageEditModeWitness(windowMs = 15_000)
        witness.onPageFact(true, 10_000)
        assertTrue(witness.isEditing())
        assertFalse(witness.isFresh(10_000))
        assertFalse(witness.isFresh(15_000))
        assertFalse(witness.isFresh(24_999))
    }

    @Test
    fun staleActivationWitnessWithFreshFactIsNotFresh() {
        val witness = OfficePageEditModeWitness(windowMs = 15_000)
        witness.onActivationWitness(1_000)
        // A raw on-fact long after the witness aged out: the fact alone is
        // inside the window, its corroboration is not — even with a fresh
        // downlink delivery isolating the activation staleness.
        witness.onPageReportedFreshDownlink(29_900)
        witness.onPageFact(true, 30_000)
        assertFalse(witness.isFresh(30_000))
        // A fresh fact with a witness that aged out afterwards is equally
        // uncorroborated: ALL ages bind.
        val witness2 = OfficePageEditModeWitness(windowMs = 15_000)
        witness2.onPageReportedFreshDownlink(1_000)
        witness2.onActivationWitness(1_000)
        witness2.onPageFact(true, 2_000)
        assertTrue(witness2.isFresh(2_500))
        assertFalse(witness2.isFresh(16_001))
    }

    @Test
    fun offFactClearsEditingFreshnessAndActivation() {
        val witness = witnessed()
        assertTrue(witness.isFresh(1_500))
        witness.onPageFact(false, 2_000)
        assertFalse(witness.isEditing())
        assertFalse(witness.isFresh(2_000))
        // A later RAW on-fact cannot resurrect the pre-off witness: viewing
        // re-entry is exactly when the pinned page's socket closed or the
        // user left edit mode, so the old transport proof is void.
        witness.onPageFact(true, 3_000)
        assertFalse(witness.isFresh(3_000))
        // Only a NEW real activation frame re-corroborates.
        witness.onActivationWitness(3_500)
        assertTrue(witness.isFresh(3_600))
    }

    @Test
    fun lifecycleRestartInvalidatesWithoutErasingRawFact() {
        val witness = witnessed()
        // A repeated HULLO / page-issued reload `load` frame: the cached
        // fact belongs to the previous page incarnation. The raw ordering
        // fact is untouched, but admission freshness is gone.
        witness.onPageLifecycleRestart()
        assertTrue(witness.isEditing())
        assertFalse(witness.isFresh(1_500))
        // Only NEW real observations re-witness the new incarnation: a
        // fresh fact alone is still uncorroborated (finding A), and so is
        // a fact with only one of the two corroborations.
        witness.onPageFact(true, 2_000)
        assertFalse(witness.isFresh(2_500))
        witness.onActivationWitness(2_400)
        assertFalse(witness.isFresh(2_500))
        witness.onPageReportedFreshDownlink(2_450)
        assertTrue(witness.isFresh(2_500))
    }

    @Test
    fun activationWitnessFromPreviousIncarnationDoesNotCarryOver() {
        val witness = OfficePageEditModeWitness(windowMs = 15_000)
        witness.onPageReportedFreshDownlink(900)
        witness.onActivationWitness(1_000)
        witness.onPageLifecycleRestart()
        // A new-incarnation raw on-fact inside the window, with both
        // corroboration stamps from BEFORE the restart: incarnation
        // mismatch keeps them out.
        witness.onPageFact(true, 1_200)
        assertFalse(witness.isFresh(1_300))
        witness.onActivationWitness(1_400)
        assertFalse(witness.isFresh(1_500))
        witness.onPageReportedFreshDownlink(1_450)
        assertTrue(witness.isFresh(1_500))
    }

    @Test
    fun clockAnomalyBeforeStampIsNotFresh() {
        val witness = witnessed()
        assertFalse(witness.isFresh(999))
        val witness2 = OfficePageEditModeWitness(windowMs = 15_000)
        witness2.onPageFact(true, 10_000)
        witness2.onActivationWitness(10_500)
        witness2.onPageReportedFreshDownlink(10_200)
        assertFalse(witness2.isFresh(9_999))
    }

    @Test
    fun defaultWindowStaysBelowPinnedWatchdog() {
        // The pinned mobile proxy closes a starved socket once
        // `lastDataTimestamp` is older than 30 s (dist global.js
        // ProxySocket.doSend). The admission window must be strictly below
        // that so a cached fact can never outlive an undetected transport
        // death.
        assertEquals(15_000L, OfficePageEditModeWitness.DEFAULT_FRESH_WINDOW_MS)
        assertTrue(OfficePageEditModeWitness.DEFAULT_FRESH_WINDOW_MS < 30_000L)
    }
}
