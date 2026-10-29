// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.export

import com.floe.android.core.officeengine.pdf.OfficePdfGeometry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The export contract must never claim more than it does: the implemented
 * route is a bounded RASTERIZED copy, the original source is preserved, and
 * the platform's native write/annotation APIs are reported as FACTS without
 * enabling an unverified preserving route.
 */
class NotesExportFidelityTest {

    @Test
    fun implementedRouteIsRasterizedAndReportsThatHonestly() {
        val cap = NotesExportCapabilities.pdf(apiLevel = 33, pdfModulePresent = false)
        assertEquals(NotesPdfExportFidelity.RASTERIZED_COPY, cap.fidelity)
        assertTrue(cap.originalSourcePreserved)
        assertFalse("source text is re-rendered, not preserved", cap.sourceTextPreserved)
        assertFalse("source vector content is re-rendered, not preserved", cap.sourceVectorContentPreserved)
        assertTrue(cap.overlayContentFlattenedToPixels)
        assertFalse("no lossless/annotation-preserving route is enabled", cap.preservingRouteEnabled)
        assertEquals(OfficePdfGeometry.MAX_RENDER_DIMENSION_PX, cap.boundedRenderEdgePx)
        assertEquals(NotesExportCapabilities.RASTER_TARGET_DPI, cap.targetDpi)
        assertTrue(cap.preservingRouteBlocker.isNotBlank())
    }

    @Test
    fun platformWriteAndAnnotationFactsAreNotConfusedWithTheModuleRoute() {
        val samsung33 = NotesExportCapabilities.pdf(apiLevel = 33, pdfModulePresent = true)
        assertTrue("write exists via the Mainline module", samsung33.platformNativeWriteApiPresent)
        assertFalse("addPageAnnotation is 36.1+, not Samsung 33", samsung33.platformAnnotationApiPresent)
        assertTrue(samsung33.supportedNativeAnnotationTypes.isEmpty())
        assertFalse(samsung33.preservingRouteEnabled)

        val api37 = NotesExportCapabilities.pdf(apiLevel = 37, pdfModulePresent = false)
        assertTrue(api37.platformNativeWriteApiPresent)
        assertTrue(api37.platformAnnotationApiPresent)
        assertEquals(listOf("FREETEXT", "HIGHLIGHT", "STAMP"), api37.supportedNativeAnnotationTypes)
        assertFalse("the route itself stays disabled until device proof", api37.preservingRouteEnabled)
    }

    @Test
    fun readbackDefaultsToTheRasterizedIdentity() {
        val readback = ExportReadback(
            file = java.io.File("/nonexistent/export.pdf"),
            byteCount = 1,
            sha256 = "a".repeat(64),
            pageCount = 1,
            pageWidthsPt = listOf(612),
            pageHeightsPt = listOf(792),
        )
        assertEquals(NotesPdfExportFidelity.RASTERIZED_COPY, readback.fidelity)
        assertFalse(readback.sourceTextPreserved)
        assertFalse(readback.sourceVectorContentPreserved)
    }

    @Test
    fun diagnosticsLineNeverImpliesLossless() {
        val line = NotesExportCapabilities.diagnosticsLine(33, pdfModulePresent = true)
        assertTrue(line.contains("pdfExport=rasterized_copy"))
        assertTrue(line.contains("textPreserved=false"))
        assertTrue(line.contains("vectorPreserved=false"))
        assertTrue(line.contains("preservingRoute=false"))
        assertFalse(line.contains("/"))
    }
}
