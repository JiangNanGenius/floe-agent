// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.conversation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure presentation contracts for the D04 owned run-output cards: only the
 * last native-verified "available" state enables an action; in-app Office
 * open covers exactly the three OOXML types; every non-available token keeps
 * a visible honest caption; the lane-17 in-app PDF open appears ONLY under
 * the closed verified MIME/extension AGREEMENT (a PDF whose sealed facts
 * disagree keeps Save but never gets a fake preview affordance); and the
 * actionable-card lookup fences taps against the CURRENT projected rows (a
 * refreshed/removed card can never be tapped). */
class RunOutputCardPresentationTest {

    private fun card(availability: String = "available", action: String? = null,
                     mime: String = "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                     name: String = "report.docx") = RunOutputCardUi(
        runId = "run-1", outputId = "o".repeat(64), producerCallId = "call-1",
        displayName = name, mimeType = mime, byteCount = 42,
        availabilityRaw = availability, actionStateRaw = action,
    )

    @Test
    fun sizeLabelKeepsTheFullLongRange() {
        // Main contract: file bytes are shown by a Long-preserving size
        // formatter (real MiB/KiB/B), never narrowed through the token-count
        // formatter — a value above Int range must display honestly.
        assertEquals("0 B", RunOutputCardPresentation.sizeLabel(0L))
        assertEquals("42 B", RunOutputCardPresentation.sizeLabel(42L))
        assertEquals("1.0 KiB", RunOutputCardPresentation.sizeLabel(1_024L))
        assertEquals("1.5 KiB", RunOutputCardPresentation.sizeLabel(1_536L))
        assertEquals("1.0 MiB", RunOutputCardPresentation.sizeLabel(1_048_576L))
        assertEquals("6144.0 MiB", RunOutputCardPresentation.sizeLabel(6L * 1024 * 1024 * 1024))
    }

    @Test
    fun onlyAvailableIsActionable() {
        assertTrue(RunOutputCardPresentation.isActionable("available"))
        for (token in listOf("missing", "changed", "oversized", "rejected", "loading",
                              "unavailable", "nonsense")) {
            assertFalse(token, RunOutputCardPresentation.isActionable(token))
            assertNotNull(token, RunOutputCardPresentation.availabilityLabelRes(token))
        }
        assertNull(RunOutputCardPresentation.availabilityLabelRes("available"))
    }

    @Test
    fun openSupportsOoxmlAndVerifiedAgreementPdf() {
        assertTrue(RunOutputCardPresentation.supportsOpen(
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "a.docx"))
        assertTrue(RunOutputCardPresentation.supportsOpen(
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "a.xlsx"))
        assertTrue(RunOutputCardPresentation.supportsOpen(
            "application/vnd.openxmlformats-officedocument.presentationml.presentation", "a.pptx"))
        // Lane 17: an AGREED durable PDF opens in-app (same isolated
        // renderer + system Print as the Office PDF surfaces). Save stays
        // available for every type regardless (isActionable governs it).
        assertTrue(RunOutputCardPresentation.supportsOpen("application/pdf", "a.pdf"))
        assertTrue(RunOutputCardPresentation.supportsOpen("application/pdf", "Report.PDF"))
        // NO fake preview affordance without the closed agreement:
        assertFalse(RunOutputCardPresentation.supportsOpen("application/pdf", "notes.txt"))
        assertFalse(RunOutputCardPresentation.supportsOpen("text/plain", "a.pdf"))
        assertFalse(RunOutputCardPresentation.supportsOpen("application/octet-stream", "a.pdf"))
        assertFalse(RunOutputCardPresentation.supportsOpen("text/plain", "notes.txt"))
        // The dedicated PDF predicate matches the host router rule exactly.
        assertTrue(RunOutputCardPresentation.supportsPdfOpen("application/pdf", "x.pdf"))
        assertFalse(RunOutputCardPresentation.supportsPdfOpen("application/pdf", "x.docx"))
        assertFalse(RunOutputCardPresentation.supportsPdfOpen("image/pdf", "x.pdf"))
        // Extension fallback agrees with the host OfficePreviewController gate.
        assertTrue(RunOutputCardPresentation.supportsOpen("application/octet-stream", "deck.pptx"))
        assertFalse(RunOutputCardPresentation.supportsOpen("application/octet-stream", "deck.PDF"))
    }

    @Test
    fun transientStatesLabelOnlyTheHonestTerminals() {
        assertEquals(R.string.run_output_saving,
            RunOutputCardPresentation.actionStateLabelRes("saving"))
        assertEquals(R.string.run_output_saved,
            RunOutputCardPresentation.actionStateLabelRes("saved"))
        assertEquals(R.string.run_output_save_cancelled,
            RunOutputCardPresentation.actionStateLabelRes("cancelled"))
        assertEquals(R.string.run_output_save_failed,
            RunOutputCardPresentation.actionStateLabelRes("failed"))
        assertEquals(R.string.run_output_open_blocked,
            RunOutputCardPresentation.actionStateLabelRes("open-blocked"))
        assertNull(RunOutputCardPresentation.actionStateLabelRes(null))
        assertNull(RunOutputCardPresentation.actionStateLabelRes("opening"))
        assertTrue(RunOutputCardPresentation.showsBusy("saving"))
        // The advisory busy-refusal note labels but never fakes in-flight.
        assertFalse(RunOutputCardPresentation.showsBusy("open-blocked"))
    }

    @Test
    fun actionableLookupFencesAgainstCurrentProjection() {
        val live = card()
        val rows: List<TimelineRowUi> = listOf(
            TimelineRowUi.RunOutputGroup("run-1", listOf(live)),
        )
        assertTrue(rows.runOutputIsActionable(live))
        // A busy card is not re-tappable as Save (it exposes Cancel instead).
        val busy = card(action = "saving")
        val busyRows: List<TimelineRowUi> = listOf(
            TimelineRowUi.RunOutputGroup("run-1", listOf(busy)))
        assertFalse(busyRows.runOutputIsActionable(busy))
        // The advisory "open-blocked" refusal note keeps the card
        // re-tappable: closing the live viewer and tapping Open again is the
        // honest recovery it captions (actual C14: a busy-slot Open was
        // honestly refused but silently invisible after one tap).
        val noted = card(action = "open-blocked")
        val notedRows: List<TimelineRowUi> = listOf(
            TimelineRowUi.RunOutputGroup("run-1", listOf(noted)))
        assertTrue(notedRows.runOutputIsActionable(noted))
        // Refreshed away / replaced projections cannot acknowledge old taps.
        val missingRows: List<TimelineRowUi> = listOf(
            TimelineRowUi.RunOutputGroup("run-2", listOf(card())))
        assertFalse(missingRows.runOutputIsActionable(live))
        val staleRows: List<TimelineRowUi> = listOf(
            TimelineRowUi.RunOutputGroup("run-1", listOf(card(availability = "missing"))))
        assertFalse(staleRows.runOutputIsActionable(live))
    }

    @Test
    fun typeShortLabelAndIdentityFieldsStayDisplayOnly() {
        assertEquals("DOCX", RunOutputCardPresentation.typeShortLabel(
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document"))
        assertEquals("PDF", RunOutputCardPresentation.typeShortLabel("application/pdf"))
        assertEquals("PNG", RunOutputCardPresentation.typeShortLabel("image/png"))
        // Group id is stable per run (keys rows in the LazyColumn).
        assertEquals("runOutputs.run-1",
            TimelineRowUi.RunOutputGroup("run-1", listOf(card())).id)
    }
}
