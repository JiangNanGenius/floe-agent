// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.export

import com.floe.android.core.notesmedia.ink.InkBox
import com.floe.android.core.notesmedia.ink.InkBrushSpec
import com.floe.android.core.notesmedia.ink.InkPageGeometry
import com.floe.android.core.notesmedia.ink.InkSnapshot
import com.floe.android.core.notesmedia.ink.InkStroke
import com.floe.android.core.notesmedia.pdf.PdfPageBox
import com.floe.android.core.notesmedia.pdf.PdfPageGeometry
import com.floe.android.core.notesmedia.pdf.PdfPageId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NotesExportPlannerTest {

    private val sha = "e".repeat(64)

    private fun geometry() = PdfPageGeometry(
        sourceSha256 = sha,
        pages = listOf(
            PdfPageBox.of(612f, 792f, 0f)!!,
            PdfPageBox.of(595f, 842f, 90f)!!,
        ),
        encrypted = false,
    )

    private fun inkSnapshot(): InkSnapshot = InkSnapshot(
        documentId = "doc-1",
        geometry = InkPageGeometry("page-0", 612f, 792f),
        revision = 3,
        strokes = listOf(
            InkStroke(
                id = 1,
                brush = InkBrushSpec.pen(0xFF000000.toInt(), 2f),
                inputs = byteArrayOf(1, 2, 3),
                bounds = InkBox(10f, 10f, 40f, 40f),
            ),
        ),
    )

    private fun overlays(page: PdfPageId) = listOf(
        NotesOverlay.Text(page, InkBox(20f, 20f, 300f, 60f), "Title", 18f, 0xFF000000.toInt()),
        NotesOverlay.Shape(page, InkBox(20f, 100f, 200f, 200f), NotesShapeKind.RECT, 2f, 0xFFFF0000.toInt()),
        NotesOverlay.InkMark(page, InkBox(0f, 0f, 612f, 792f), inkSnapshot()),
    )

    @Test
    fun planPreservesDisplayedPageBoxesAndPaintOrder() {
        val page0 = PdfPageId(0)
        val page1 = PdfPageId(1)
        val result = NotesExportPlanner.plan(
            sha,
            geometry(),
            listOf(page0, page1),
            overlays(page0),
            NotesExportQuality.HIGH,
        )
        val plan = (result as NotesExportPlanResult.Ready).plan
        assertEquals(2, plan.pages.size)
        assertEquals(612, plan.pages[0].outputWidthPt)
        assertEquals(792, plan.pages[0].outputHeightPt)
        // /Rotate 90 page exports at its DISPLAYED landscape size.
        assertEquals(842, plan.pages[1].outputWidthPt)
        assertEquals(595, plan.pages[1].outputHeightPt)
        val order = plan.pages[0].overlays.map { NotesOverlay.order(it) }
        assertEquals(order.sorted(), order)
        assertEquals(NotesOverlay.order(plan.pages[0].overlays.last()), 3)
        assertTrue(plan.pages[0].renderedWidthPx <= 2048)
        assertTrue(plan.pages[0].renderedHeightPx <= 2048)
    }

    @Test
    fun duplicatePagesAreDeduplicated() {
        val page0 = PdfPageId(0)
        val plan = NotesExportPlanner.plan(sha, geometry(), listOf(page0, page0), emptyList()) as NotesExportPlanResult.Ready
        assertEquals(1, plan.plan.pages.size)
    }

    @Test
    fun missingGeometryOrSourceMismatchIsRefused() {
        assertEquals(
            NotesExportRefusal.NO_PAGE_GEOMETRY,
            (NotesExportPlanner.plan(sha, null, listOf(PdfPageId(0)), emptyList()) as NotesExportPlanResult.Refused).refusal,
        )
        assertEquals(
            NotesExportRefusal.NO_PAGE_GEOMETRY,
            (
                NotesExportPlanner.plan("f".repeat(64), geometry(), listOf(PdfPageId(0)), emptyList())
                    as NotesExportPlanResult.Refused
                ).refusal,
        )
    }

    @Test
    fun outOfRangePageAndOutOfPageOverlayAreRefused() {
        assertEquals(
            NotesExportRefusal.PAGE_OUT_OF_RANGE,
            (
                NotesExportPlanner.plan(sha, geometry(), listOf(PdfPageId(5)), emptyList())
                    as NotesExportPlanResult.Refused
                ).refusal,
        )
        val outside = NotesOverlay.Text(
            PdfPageId(0),
            InkBox(1000f, 1000f, 1100f, 1100f),
            "outside",
            12f,
            0xFF000000.toInt(),
        )
        assertEquals(
            NotesExportRefusal.OVERLAY_OUT_OF_PAGE,
            (
                NotesExportPlanner.plan(sha, geometry(), listOf(PdfPageId(0)), listOf(outside))
                    as NotesExportPlanResult.Refused
                ).refusal,
        )
    }

    @Test
    fun overlaysForPagesOutsideTheSelectionAreIgnored() {
        val overlay = NotesOverlay.Text(PdfPageId(1), InkBox(10f, 10f, 100f, 40f), "x", 12f, 0)
        val plan = NotesExportPlanner.plan(sha, geometry(), listOf(PdfPageId(0)), listOf(overlay))
            as NotesExportPlanResult.Ready
        assertEquals(0, plan.plan.pages.single().overlays.size)
    }
}
