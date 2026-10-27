// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.pdf

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Contract regression for the PDF export purpose ledger: what an
 * OUTPUT_READY receipt may open is decided EXACTLY ONCE by the registered
 * purpose. These encode the Main UI/ownership decisions (2026-10-27):
 *  - a local PDF purpose can NEVER fall through to the SAF picker path;
 *  - stale, foreign or duplicate terminals open NOTHING (null consume);
 *  - the in-flight newest op is never lost by the tracking bound;
 *  - mount end invalidates everything registered.
 */
class OfficePdfExportLedgerTest {

    @Test
    fun registerThenConsumeIsExactOncePerOp() {
        val ledger = OfficePdfExportLedger()
        assertTrue(ledger.register("export-1", OfficeExportPurpose.PDF_PREVIEW))
        assertEquals(OfficeExportPurpose.PDF_PREVIEW, ledger.consume("export-1"))
        // Duplicate/stale terminal for the same op: consumes to null, so it
        // can never re-open the preview, the picker or flip any notice.
        assertNull(ledger.consume("export-1"))
        assertNull(ledger.consume("export-1"))
    }

    @Test
    fun localPdfPurposesAreNeverSafCopy() {
        val ledger = OfficePdfExportLedger()
        ledger.register("export-a", OfficeExportPurpose.PDF_PREVIEW)
        ledger.register("export-b", OfficeExportPurpose.PDF_PRINT)
        ledger.register("export-c", OfficeExportPurpose.SAF_COPY)
        assertTrue(ledger.consume("export-a") != OfficeExportPurpose.SAF_COPY)
        assertTrue(ledger.consume("export-b") != OfficeExportPurpose.SAF_COPY)
        assertEquals(OfficeExportPurpose.SAF_COPY, ledger.consume("export-c"))
    }

    @Test
    fun unknownAndForeignOpsConsumeToNull() {
        val ledger = OfficePdfExportLedger()
        assertNull(ledger.consume(null))
        assertNull(ledger.consume("never-registered"))
        ledger.register("mine", OfficeExportPurpose.PDF_PREVIEW)
        // Another session's opId shape (different viewer ledger) cannot hit
        // this one: ids are opaque to the ledger; only exact ids consume.
        assertNull(ledger.consume("mine-extended"))
        assertEquals(OfficeExportPurpose.PDF_PREVIEW, ledger.consume("mine"))
    }

    @Test
    fun duplicateRegistrationIsRefusedNotOverwritten() {
        val ledger = OfficePdfExportLedger()
        assertTrue(ledger.register("export-1", OfficeExportPurpose.PDF_PREVIEW))
        // A second purpose for the SAME in-flight op must never silently
        // replace it (an op's authority is fixed at dispatch).
        assertFalse(ledger.register("export-1", OfficeExportPurpose.PDF_PRINT))
        assertEquals(OfficeExportPurpose.PDF_PREVIEW, ledger.consume("export-1"))
    }

    @Test
    fun boundRetiresOldestButNeverTheNewestInFlight() {
        val ledger = OfficePdfExportLedger(maxTracked = 3)
        ledger.register("op-1", OfficeExportPurpose.SAF_COPY)
        ledger.register("op-2", OfficeExportPurpose.PDF_PREVIEW)
        ledger.register("op-3", OfficeExportPurpose.PDF_PRINT)
        ledger.register("op-4", OfficeExportPurpose.PDF_PREVIEW)
        // Oldest retired first, newest always retained.
        assertNull(ledger.consume("op-1"))
        assertEquals(OfficeExportPurpose.PDF_PREVIEW, ledger.consume("op-4"))
        assertTrue(ledger.inFlightCount() <= 3)
    }

    @Test
    fun blankOpsAreNeverAccepted() {
        val ledger = OfficePdfExportLedger()
        assertFalse(ledger.register("", OfficeExportPurpose.PDF_PREVIEW))
    }

    @Test
    fun clearOnMountEndDropsEveryPendingPurpose() {
        val ledger = OfficePdfExportLedger()
        ledger.register("op-a", OfficeExportPurpose.PDF_PREVIEW)
        ledger.register("op-b", OfficeExportPurpose.SAF_COPY)
        ledger.clear()
        assertNull(ledger.consume("op-a"))
        assertNull(ledger.consume("op-b"))
        assertEquals(0, ledger.inFlightCount())
    }
}
