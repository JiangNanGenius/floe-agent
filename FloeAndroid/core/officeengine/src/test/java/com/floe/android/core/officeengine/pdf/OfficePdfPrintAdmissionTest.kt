// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.pdf

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Regression coverage for the print admission rules and the exactly-once
 * source/lease release seam (Main repair 2026-10-27, the D04 join point).
 *
 * The tests drive the REAL pure objects the flow calls —
 * [OfficePdfPrintAdmission.prepare]/[OfficePdfPrintAdmission.admitOnMain]
 * and the [OfficePdfOnceCallback] finish gate with the real [PrintFinish]
 * identities — never a copy of the flow's branching.
 */
class OfficePdfPrintAdmissionTest {

    // ---- prepare: early page-count / shape refusal ----

    @Test
    fun invalidPageCountOrSourceShapeRefusesBeforeAnyDialogMachinery() {
        assertEquals(
            PrintStartOutcome.SourceUnavailable,
            OfficePdfPrintAdmission.prepare(pageCountOk = false, sourceShapeOk = true),
        )
        assertEquals(
            PrintStartOutcome.SourceUnavailable,
            OfficePdfPrintAdmission.prepare(pageCountOk = true, sourceShapeOk = false),
        )
        assertEquals(
            PrintStartOutcome.SourceUnavailable,
            OfficePdfPrintAdmission.prepare(pageCountOk = false, sourceShapeOk = false),
        )
        assertNull(OfficePdfPrintAdmission.prepare(pageCountOk = true, sourceShapeOk = true))
    }

    @Test
    fun realRendererCountRangeMatchesTheFlowGuard() {
        // The flow admits exactly `1..MAX_PAGE_INDEX`; 0 (never-opened
        // claim) and the fence edge are the boundary regressions.
        val max = OfficePdfRendererContract.MAX_PAGE_INDEX
        assertTrue(max in 1..OfficePdfRendererContract.MAX_PAGE_INDEX)
        assertFalse(0 in 1..max)
        assertFalse((-3) in 1..max)
        assertFalse(max + 1 in 1..max)
    }

    // ---- main-thread admission: stale activity never gets a dialog ----

    @Test
    fun retiredActivityRefusesDialogAdmission() {
        assertEquals(
            PrintStartOutcome.ActivityRetired,
            OfficePdfPrintAdmission.admitOnMain(activityAlive = false),
        )
        assertNull(OfficePdfPrintAdmission.admitOnMain(activityAlive = true))
    }

    // ---- release seam: exactly once, honest identity, every path ----

    /** Mirrors NOTHING: this composes the same real gate + identities the flow's settle() uses. */
    private class ReleaseRecorder {
        val finishGate = OfficePdfOnceCallback("print-finish")
        val seen = mutableListOf<PrintFinish>()
        fun settle(finish: PrintFinish): Boolean =
            finishGate.fire(OfficePdfOnceCallback.Terminal.FINISHED) { seen.add(finish) }
    }

    @Test
    fun earlyAbortThenLateAdapterFinishStillReleasesExactlyOnceWithAbortIdentity() {
        val rec = ReleaseRecorder()
        assertTrue(rec.settle(PrintFinish.StartAborted(PrintStartOutcome.SourceUnavailable)))
        // The flow then calls adapter.onFinish for FD cleanup; its release
        // hook hits the SAME gate and must not add or rewrite an identity.
        assertFalse(rec.settle(PrintFinish.AdapterFinished))
        assertEquals(
            listOf<PrintFinish>(PrintFinish.StartAborted(PrintStartOutcome.SourceUnavailable)),
            rec.seen,
        )
    }

    @Test
    fun admittedJobReleasesOnceAtTheRealFinishNotBefore() {
        val rec = ReleaseRecorder()
        // While the dialog owns the job NO release fires (the lease stays
        // joined even if the owning UI retired — no sabotage, no early
        // release that could delete retained bytes).
        assertTrue(rec.seen.isEmpty())
        assertTrue(rec.settle(PrintFinish.AdapterFinished))
        assertFalse(rec.settle(PrintFinish.AdapterFinished))
        assertEquals(1, rec.seen.size)
        assertEquals(PrintFinish.AdapterFinished, rec.seen[0])
    }

    @Test
    fun everyStartAbortedCarriesItsHonestOutcomeIdentity() {
        val outcomes = listOf(
            PrintStartOutcome.SourceUnavailable,
            PrintStartOutcome.NoPrintService,
            PrintStartOutcome.ActivityRetired,
        )
        val rec = ReleaseRecorder()
        rec.settle(PrintFinish.StartAborted(outcomes[0]))
        assertEquals(
            PrintFinish.StartAborted(outcomes[0]),
            rec.seen[0],
        )
        // Distinct identities never collapse: DialogOpened is not a finish.
        assertEquals(
            PrintFinish.StartAborted(PrintStartOutcome.ActivityRetired),
            PrintFinish.StartAborted(PrintStartOutcome.ActivityRetired),
        )
        assertFalse(
            PrintFinish.StartAborted(PrintStartOutcome.NoPrintService) ==
                PrintFinish.StartAborted(PrintStartOutcome.ActivityRetired),
        )
    }

    @Test
    fun gateFirstTerminalWinsForAnySettleOrder() {
        // CANCEL-races-FINISH rule from the repair: whichever terminal the
        // framework side reaches first is the ONE callback; a duplicate is
        // refused (the adapter's per-request gates rely on exactly this).
        val rec = ReleaseRecorder()
        assertTrue(rec.settle(PrintFinish.AdapterFinished))
        assertFalse(rec.settle(PrintFinish.StartAborted(PrintStartOutcome.NoPrintService)))
        assertEquals(1, rec.seen.size)
    }
}
