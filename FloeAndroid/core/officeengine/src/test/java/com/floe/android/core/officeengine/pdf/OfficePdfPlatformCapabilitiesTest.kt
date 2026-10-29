// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.pdf

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guard matrix for the real API-37 SDK facts (verified 2026-10-30 against the
 * installed `android.jar`/`api-versions.xml`):
 *  - legacy `PdfRenderer` on 28–30: no password, no text content;
 *  - API 35+: `PdfRenderer(fd, LoadParams)` + `Page.getTextContents()`;
 *  - API 31–34 + Mainline `framework-pdf` module v13+: `PdfRendererPreV` with
 *    the same password/text surface;
 *  - annotations are `since="36.1"` and are only claimed on the verified
 *    API-37 surface.
 */
class OfficePdfPlatformCapabilitiesTest {

    @Test
    fun legacyDevicesGetTypedTextAndPasswordGaps() {
        for (api in 28..30) {
            assertEquals(OfficePdfEngineKind.LEGACY, OfficePdfPlatformCapabilities.engineKind(api, false))
            assertEquals(OfficePdfEngineKind.LEGACY, OfficePdfPlatformCapabilities.engineKind(api, true))
            assertFalse(OfficePdfPlatformCapabilities.textExtractionSupported(api, true))
            assertFalse(OfficePdfPlatformCapabilities.passwordSupported(api, true))
        }
    }

    @Test
    fun api31Through34RequireTheMainlinePdfModule() {
        for (api in 31..34) {
            assertEquals(
                OfficePdfEngineKind.PRE_V,
                OfficePdfPlatformCapabilities.engineKind(api, modulePresent = true),
            )
            assertEquals(
                OfficePdfEngineKind.LEGACY,
                OfficePdfPlatformCapabilities.engineKind(api, modulePresent = false),
            )
            assertTrue(OfficePdfPlatformCapabilities.textExtractionSupported(api, true))
            assertTrue(OfficePdfPlatformCapabilities.passwordSupported(api, true))
            assertFalse(OfficePdfPlatformCapabilities.textExtractionSupported(api, false))
            assertFalse(OfficePdfPlatformCapabilities.passwordSupported(api, false))
        }
    }

    @Test
    fun api35AndAboveUseTheFullFrameworkSurface() {
        for (api in intArrayOf(35, 36, 37)) {
            assertEquals(OfficePdfEngineKind.API_35, OfficePdfPlatformCapabilities.engineKind(api, false))
            assertEquals(OfficePdfEngineKind.API_35, OfficePdfPlatformCapabilities.engineKind(api, true))
            assertTrue(OfficePdfPlatformCapabilities.textExtractionSupported(api, false))
            assertTrue(OfficePdfPlatformCapabilities.passwordSupported(api, false))
        }
        assertEquals(35, OfficePdfPlatformCapabilities.textMinApi())
        assertEquals(31, OfficePdfPlatformCapabilities.textBackportMinApi())
    }

    @Test
    fun nativeAnnotationWriteIsNotClaimedBeforeTheVerifiedSurface() {
        // write() exists from API 35 / module 13, but addPageAnnotation is 36.1.
        val samsung33 = OfficePdfPlatformCapabilities.nativeAnnotationWrite(33, modulePresent = true)
        assertTrue(samsung33.writeApiPresent)
        assertFalse(samsung33.annotationApiPresent)
        assertTrue(samsung33.supportedAnnotationTypes.isEmpty())

        val old = OfficePdfPlatformCapabilities.nativeAnnotationWrite(28, modulePresent = false)
        assertFalse(old.writeApiPresent)
        assertFalse(old.annotationApiPresent)

        val api37 = OfficePdfPlatformCapabilities.nativeAnnotationWrite(37, modulePresent = false)
        assertTrue(api37.writeApiPresent)
        assertTrue(api37.annotationApiPresent)
        assertEquals(listOf("FREETEXT", "HIGHLIGHT", "STAMP"), api37.supportedAnnotationTypes)
    }

    @Test
    fun diagnosticsArePathFreeAndExposeTheEngine() {
        val line = OfficePdfPlatformCapabilities.diagnosticsLine(33, modulePresent = true)
        assertTrue(line.contains("pdfEngine=pre_v"))
        assertTrue(line.contains("text=true"))
        assertTrue(line.contains("password=true"))
        assertFalse(line.contains("/"))
        assertTrue(OfficePdfPlatformCapabilities.diagnosticsLine(28, false).contains("pdfEngine=legacy"))
    }
}
