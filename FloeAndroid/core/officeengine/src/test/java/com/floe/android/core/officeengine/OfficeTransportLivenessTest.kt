// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Deterministic JVM source for the C17 DOCX transport-liveness repair
 * (docx-socket-repair122).
 *
 * The retained C17 evidence (`device-c17/docx-first-failure/owned-app-logcat.txt`)
 * pins the first 1006 producer: the pinned mobile page proxy closes the socket
 * INSIDE `doSend()` when `msgInflight >= 4` AND the throttle ladder is at its
 * cap AND `performance.now() - lastDataTimestamp > 30 s` (pinned global.js
 * 1696-1716). The host is the ONLY `doSend()` source, so these decisions are
 * the whole safety argument for the hidden approval window:
 *
 * - while the window is hidden the host injects NOTHING, so the watchdog can
 *   never evaluate and the socket cannot be closed;
 * - an injection is allowed only when the page's own in-flight counter is
 *   BELOW the pinned cap (the pinned `doSend()` then takes its send path and
 *   cannot reach the fatal branch, whatever the staleness);
 * - a hidden page is admitted only on its own OPEN socket object plus a real
 *   host-observed wsd `pong`, and the hidden handshake carries NO `doSend()`
 *   burst — the burst is the one thing that can close a hidden page.
 */
class OfficeTransportLivenessTest {

    private fun health(
        readyState: Int = 1,
        msgInflight: Int = 0,
        stalenessMs: Long = 0L,
    ) = OfficeReadOnlyProtocol.OfficeTransportHealth(readyState, msgInflight, stalenessMs)

    @Test
    fun pinnedWatchdogGeometryMatchesThePinnedProxy() {
        // Exactly the constants the pinned dist/global.js evaluates.
        assertEquals(4, OfficeTransportWatchdog.INFLIGHT_CAP)
        assertEquals(30_000L, OfficeTransportWatchdog.STALE_CLOSE_MS)
    }

    @Test
    fun armedRequiresOpenSocketCapAndStrictlyPastThirtySeconds() {
        assertTrue(OfficeTransportWatchdog.isArmed(health(msgInflight = 4, stalenessMs = 30_001)))
        assertTrue(OfficeTransportWatchdog.isArmed(health(msgInflight = 9, stalenessMs = 30_001)))
        // The pinned comparison is `> 30 * 1000`: exactly 30 s is NOT armed.
        assertFalse(OfficeTransportWatchdog.isArmed(health(msgInflight = 4, stalenessMs = 30_000)))
        // Below the cap the pinned doSend() never reaches the fatal branch.
        assertFalse(OfficeTransportWatchdog.isArmed(health(msgInflight = 3, stalenessMs = 999_999)))
        // A closed transport cannot be "armed" — it already happened.
        assertFalse(OfficeTransportWatchdog.isArmed(health(readyState = 3, msgInflight = 4, stalenessMs = 999_999)))
        assertFalse(OfficeTransportWatchdog.isArmed(health(readyState = 0, msgInflight = 4)))
        // An unreadable page is never a health fact.
        assertFalse(OfficeTransportWatchdog.isArmed(null))
    }

    @Test
    fun injectionIsSafeOnlyBelowThePinnedCapOnAnOpenSocket() {
        assertTrue(OfficeTransportWatchdog.canInjectSafely(health(msgInflight = 0, stalenessMs = 999_999)))
        assertTrue(OfficeTransportWatchdog.canInjectSafely(health(msgInflight = 3, stalenessMs = 999_999)))
        // At/above the cap the pinned doSend() can only throttle or close.
        assertFalse(OfficeTransportWatchdog.canInjectSafely(health(msgInflight = 4, stalenessMs = 0)))
        assertFalse(OfficeTransportWatchdog.canInjectSafely(health(msgInflight = 4, stalenessMs = 999_999)))
        assertFalse(OfficeTransportWatchdog.canInjectSafely(health(readyState = 3, msgInflight = 0)))
        assertFalse(OfficeTransportWatchdog.canInjectSafely(null))
    }

    @Test
    fun hiddenAdmissionRequiresOnlyThePagesOwnOpenSocket() {
        // Open socket: admissible even when the in-flight cap is pinned — this
        // route never injects a doSend(), and the hidden page's deferred polls
        // drain normally once the window is visible again.
        assertEquals(
            OfficeHiddenTransportAdmission.Verdict.ADMIT,
            OfficeHiddenTransportAdmission.decide(health(msgInflight = 4, stalenessMs = 999_999)),
        )
        assertEquals(
            OfficeHiddenTransportAdmission.Verdict.ADMIT,
            OfficeHiddenTransportAdmission.decide(health(msgInflight = 0, stalenessMs = 0)),
        )
        // A 1006 close sets readyState to 3: nothing can recover that mount's
        // page socket (one fake-socket session per createCOOLWSD lifetime).
        for (readyState in listOf(0, 2, 3)) {
            assertEquals(
                "readyState $readyState",
                OfficeHiddenTransportAdmission.Verdict.REFUSE_SOCKET_CLOSED,
                OfficeHiddenTransportAdmission.decide(health(readyState = readyState)),
            )
        }
        // nosocket/err/malformed is never a health fact.
        assertEquals(
            OfficeHiddenTransportAdmission.Verdict.REFUSE_UNREADABLE,
            OfficeHiddenTransportAdmission.decide(null),
        )
    }

    @Test
    fun hiddenEnterEditScriptNeverInjectsAPoll() {
        // The whole prevention rests on this: the hidden handshake must not
        // call `doSend()` (that is the fatal watchdog evaluation), while the
        // visible handshake still carries its deliberate 24-call probe burst.
        assertTrue(OfficeReadOnlyProtocol.PAGE_ENTER_EDIT_SCRIPT.contains("doSend"))
        assertFalse(OfficeReadOnlyProtocol.PAGE_ENTER_EDIT_SCRIPT_NO_PROBE.contains("doSend"))
        // The real witness chain is unchanged in the hidden variant: the
        // engine's own activation hook, the connected() gate on the page
        // socket, the real `useractive` uplink and the engine's edit affordance.
        val hidden = OfficeReadOnlyProtocol.PAGE_ENTER_EDIT_SCRIPT_NO_PROBE
        assertTrue(hidden.contains("notifyActive"))
        assertTrue(hidden.contains("connected()"))
        assertTrue(hidden.contains("sendMessage('useractive')"))
        assertTrue(hidden.contains("_proceedEditMode"))
        // The hidden variant additionally refuses unless the page's own raw
        // socket object is open, so a 1006-closed page can never pass the gate
        // by racing `_proceedEditMode()`.
        assertTrue(hidden.contains("ps.readyState!==1"))
    }

    @Test
    fun safeProbeRefusesToEvaluateDoSendAtThePinnedCap() {
        // Every host poll injection uses the page-side safe probe, so the page
        // itself refuses the only injection that can reach the fatal branch.
        val safe = OfficeReadOnlyProtocol.PAGE_SAFE_POLL_PROBE_SCRIPT
        assertTrue(safe.contains("msgInflight"))
        assertTrue(safe.contains(">=4"))
        assertTrue(safe.contains("ps.doSend()"))
        assertEquals(4, OfficeTransportWatchdog.INFLIGHT_CAP)
        // The raw probe (no guard) must not be used by any host injection path;
        // it stays only as the documented pinned baseline shape.
        assertFalse(OfficeReadOnlyProtocol.PAGE_POLL_PROBE_SCRIPT.contains("msgInflight"))
    }

    @Test
    fun hiddenGateStaysInsideThePreparationTimeout() {
        assertEquals(3, OfficeHiddenTransportAdmission.GATE_ATTEMPTS)
        assertEquals(700L, OfficeHiddenTransportAdmission.PONG_WAIT_MS)
        val worstCase = OfficeHiddenTransportAdmission.GATE_ATTEMPTS *
            OfficeHiddenTransportAdmission.PONG_WAIT_MS
        assertTrue(worstCase <= 3_000L)
        assertTrue(worstCase < OfficeEditModePreparation.DEFAULT_TIMEOUT_MS)
    }
}
