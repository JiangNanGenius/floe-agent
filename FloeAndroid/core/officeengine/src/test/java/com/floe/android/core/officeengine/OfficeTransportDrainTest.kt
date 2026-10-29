// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Deterministic JVM source for the bounded pre-admission wake drain
 * (page-transport85, hardened by office-background-repair118 and
 * docx-socket-repair122).
 *
 * The drain is a health-RESTORATION opportunity, never an admission gate:
 * every proceed outcome still runs the ordered handshake script, whose
 * probe/connected-gate/witness contract stays the single honest verdict.
 * What the decision must guarantee (docx-socket-repair122 additions marked):
 *
 * - a page whose own counters prove fresh real downlink data proceeds
 *   immediately (the pinned close additionally needs >30 s staleness, so the
 *   probe cannot reach the fatal branch);
 * - a closed/closing transport proceeds immediately (retrying cannot heal it;
 *   the script's connected() gate owns the typed refusal);
 * - a stale-but-open page BELOW the pinned in-flight cap retries with one
 *   armed poll each iteration (the wake shape: the heartbeat's real `pong`
 *   is still queued host-side);
 * - NEW: a page whose in-flight counter is pinned at the cap (`msgInflight
 *   >= 4`) never gets a probe — the pinned doSend() would only walk the
 *   ladder, and at >30 s staleness that same call closes the socket (the
 *   actual C17 DOCX first failure). It retries READ-ONLY, and if the cap is
 *   still pinned at the end of the budget the drain REFUSES instead of
 *   running the handshake's probe burst into the same close;
 * - NEW: an unreadable/absent answer is never promoted to a health fact and
 *   never authorizes a blind injection.
 */
class OfficeTransportDrainTest {

    private fun health(
        readyState: Int = 1,
        msgInflight: Int = 0,
        stalenessMs: Long = 0L,
    ) = OfficeReadOnlyProtocol.OfficeTransportHealth(readyState, msgInflight, stalenessMs)

    @Test
    fun freshRealDataProceedsImmediately() {
        assertEquals(
            OfficeTransportDrain.Decision.PROCEED_SCRIPT,
            OfficeTransportDrain.decide(health(stalenessMs = 0), 0),
        )
        assertEquals(
            OfficeTransportDrain.Decision.PROCEED_SCRIPT,
            OfficeTransportDrain.decide(health(stalenessMs = 14_999), 0),
        )
        // Freshness makes the proceed safe whatever the in-flight count:
        // the pinned close condition additionally requires >30 s staleness.
        assertEquals(
            OfficeTransportDrain.Decision.PROCEED_SCRIPT,
            OfficeTransportDrain.decide(health(msgInflight = 4, stalenessMs = 10), 0),
        )
    }

    @Test
    fun freshnessBoundaryIsStrict() {
        assertEquals(
            OfficeTransportDrain.Decision.RETRY_WITH_PROBE,
            OfficeTransportDrain.decide(health(stalenessMs = 15_000), 0),
        )
        assertEquals(15_000L, OfficeTransportDrain.FRESH_STALENESS_MS)
        assertTrue(OfficeTransportDrain.FRESH_STALENESS_MS < 30_000L)
    }

    @Test
    fun staleButOpenBelowCapRetriesWithAProbe() {
        // The safe wake shape: in-flight below the pinned cap, the real pong
        // still queued host-side; every retry arms one bounded poll (the
        // pinned doSend() creates its XHR and cannot reach the fatal branch).
        for (attempt in 0 until OfficeTransportDrain.MAX_ATTEMPTS - 1) {
            assertEquals(
                "attempt $attempt",
                OfficeTransportDrain.Decision.RETRY_WITH_PROBE,
                OfficeTransportDrain.decide(health(msgInflight = 0, stalenessMs = 300_000), attempt),
            )
        }
        // Budget exhausted below the cap: proceed and let the real handshake
        // decide honestly. Never a drain-owned refusal for a safe page.
        assertEquals(
            OfficeTransportDrain.Decision.PROCEED_SCRIPT,
            OfficeTransportDrain.decide(
                health(msgInflight = 3, stalenessMs = 300_000),
                OfficeTransportDrain.MAX_ATTEMPTS - 1,
            ),
        )
    }

    @Test
    fun pinnedInFlightCapNeverGetsAProbeAndRefusesAtTheEnd() {
        // docx-socket-repair122: the actual C17 wake shape — the enter-edit
        // handshake's four polls were still deferred (msgInflight == 4) when
        // staleness was already far past 30 s. An injected doSend() here only
        // walks the ladder and then closes the socket, so every iteration must
        // be READ-ONLY, and the exhausted budget must REFUSE (never run the
        // burst into the same close).
        for (attempt in 0 until OfficeTransportDrain.MAX_ATTEMPTS - 1) {
            assertEquals(
                "attempt $attempt",
                OfficeTransportDrain.Decision.RETRY_READ_ONLY,
                OfficeTransportDrain.decide(health(msgInflight = 4, stalenessMs = 300_000), attempt),
            )
        }
        assertEquals(
            OfficeTransportDrain.Decision.REFUSE_ARMED,
            OfficeTransportDrain.decide(
                health(msgInflight = 4, stalenessMs = 300_000),
                OfficeTransportDrain.MAX_ATTEMPTS - 1,
            ),
        )
        // Above the cap behaves the same way (stale, so not fresh).
        assertEquals(
            OfficeTransportDrain.Decision.RETRY_READ_ONLY,
            OfficeTransportDrain.decide(health(msgInflight = 7, stalenessMs = 30_001), 0),
        )
        assertEquals(
            OfficeTransportDrain.Decision.REFUSE_ARMED,
            OfficeTransportDrain.decide(
                health(msgInflight = 7, stalenessMs = 30_001),
                OfficeTransportDrain.MAX_ATTEMPTS - 1,
            ),
        )
    }

    @Test
    fun deadOrNeverOpenedTransportProceedsImmediately() {
        for (readyState in listOf(0, 2, 3)) {
            assertEquals(
                "readyState $readyState",
                OfficeTransportDrain.Decision.PROCEED_SCRIPT,
                OfficeTransportDrain.decide(health(readyState = readyState, stalenessMs = 999_999), 0),
            )
        }
    }

    @Test
    fun unreadableAnswersAreNeverHealthFactsAndNeverProbeBlind() {
        // null (nosocket/err/garbage per parseTransportHealth) is never fresh
        // and never authorizes an injection: bounded READ-ONLY retries, then
        // the unchanged honest script verdict (no drain-owned refusal for an
        // unprovable page).
        for (attempt in 0 until OfficeTransportDrain.MAX_ATTEMPTS - 1) {
            assertEquals(
                "attempt $attempt",
                OfficeTransportDrain.Decision.RETRY_READ_ONLY,
                OfficeTransportDrain.decide(null, attempt),
            )
        }
        assertEquals(
            OfficeTransportDrain.Decision.PROCEED_SCRIPT,
            OfficeTransportDrain.decide(null, OfficeTransportDrain.MAX_ATTEMPTS - 1),
        )
    }

    @Test
    fun clockAnomalyStalenessIsNotFresh() {
        // A negative age (page clock anomaly) fails the `0 until` window:
        // bounded retries below the cap (a probe there is still safe), then
        // the honest script verdict.
        assertEquals(
            OfficeTransportDrain.Decision.RETRY_WITH_PROBE,
            OfficeTransportDrain.decide(health(stalenessMs = -1), 0),
        )
        assertFalse(OfficeTransportDrain.isFresh(health(stalenessMs = -1)))
    }

    @Test
    fun sharedFreshnessCriterionIsHonest() {
        // office-background-repair118: ONE page-truth criterion used by the
        // drain, the cached fast path AND the cold route's bounded final
        // verification. Fresh only on an OPEN socket with real recent
        // downlink data; closed/clock-anomaly/unreadable are never fresh.
        assertTrue(OfficeTransportDrain.isFresh(health(stalenessMs = 0)))
        assertTrue(OfficeTransportDrain.isFresh(health(stalenessMs = 14_999)))
        assertFalse(OfficeTransportDrain.isFresh(health(stalenessMs = 15_000)))
        assertFalse(OfficeTransportDrain.isFresh(health(stalenessMs = -1)))
        assertFalse(OfficeTransportDrain.isFresh(health(readyState = 3, stalenessMs = 0)))
        assertFalse(OfficeTransportDrain.isFresh(health(readyState = 0)))
        assertFalse(OfficeTransportDrain.isFresh(null))
        // Closed socket must refuse IMMEDIATELY (PROCEED), never retry.
        assertEquals(
            OfficeTransportDrain.Decision.PROCEED_SCRIPT,
            OfficeTransportDrain.decide(health(readyState = 3, stalenessMs = 999_999), 0),
        )
    }

    @Test
    fun coldRouteCombinedBoundsStayInsideThePreparationTimeout() {
        // office-background-repair118: the cold route may spend ONE drain
        // budget (pre-handshake) plus ONE bounded final verification; both
        // use the SAME MAX_ATTEMPTS * RETRY_DELAY bound and together must
        // leave clear margin inside the 10 s preparation timeout. No timeout
        // is added or extended.
        val oneBudget = OfficeTransportDrain.MAX_ATTEMPTS * OfficeTransportDrain.RETRY_DELAY_MS
        assertTrue(oneBudget <= 3_000L)
        assertTrue(oneBudget * 2 < OfficeEditModePreparation.DEFAULT_TIMEOUT_MS)
    }

    @Test
    fun hiddenGateBudgetFitsTheSamePreparationTimeout() {
        // docx-socket-repair122: the hidden route's gate (one health read plus
        // one host ping/pong wait per attempt) must also fit the UNCHANGED
        // preparation timeout, together with the handshake and its single
        // final read. No timeout inflation.
        val gate = OfficeHiddenTransportAdmission.GATE_ATTEMPTS *
            OfficeHiddenTransportAdmission.PONG_WAIT_MS
        assertTrue(gate <= 3_000L)
        assertTrue(gate < OfficeEditModePreparation.DEFAULT_TIMEOUT_MS)
    }

    @Test
    fun budgetStaysInsideThePreparationTimeout() {
        // The drain runs inside the preparation's bounded 10 s timeout
        // (OfficeEditModePreparation.DEFAULT_TIMEOUT_MS): worst-case cost
        // is MAX_ATTEMPTS retry delays plus one evaluateJavascript round
        // trip per iteration — the delays alone must leave clear margin for
        // the handshake script that follows.
        assertEquals(20, OfficeTransportDrain.MAX_ATTEMPTS)
        assertEquals(150L, OfficeTransportDrain.RETRY_DELAY_MS)
        val worstCaseDelayMs = OfficeTransportDrain.MAX_ATTEMPTS * OfficeTransportDrain.RETRY_DELAY_MS
        assertTrue(worstCaseDelayMs <= 3_000L)
        assertTrue(worstCaseDelayMs < OfficeEditModePreparation.DEFAULT_TIMEOUT_MS)
    }
}
