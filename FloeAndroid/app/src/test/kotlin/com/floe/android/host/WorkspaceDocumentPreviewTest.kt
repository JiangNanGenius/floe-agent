// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import java.io.File
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * G07.1 preview contract (pure JVM; no Compose/device/PDF renderer):
 *  - only real PDF/raster extensions reach the new full-window viewer, and
 *    SVG/TIFF stay typed unsupported instead of pretending to decode;
 *  - the PDF magic proof reads the actual copied bytes;
 *  - image sampling always stays inside the fixed edge/pixel bounds, so a
 *    forged or huge raster can never request an unbounded bitmap;
 *  - page/zoom navigation stays inside the renderer's accepted bounds;
 *  - stager refusals map to the honest typed UI decision and retry policy.
 */
class WorkspaceDocumentPreviewTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun onlyRealPdfAndBitmapFamilyExtensionsReachThePreview() {
        assertEquals(WorkspacePreviewKind.PDF, WorkspaceDocumentPreviewPolicy.kindForPath("docs/Q3 report.PDF"))
        for (name in listOf("a.png", "b.jpg", "c.jpeg", "d.webp", "e.gif", "f.bmp", "g.heic", "h.heif")) {
            assertEquals(name, WorkspacePreviewKind.IMAGE, WorkspaceDocumentPreviewPolicy.kindForPath("shots/$name"))
        }
        // Explicitly NOT claimed: no decoder exists in this App.
        for (name in listOf("icon.svg", "scan.tiff", "scan.TIF")) {
            assertNull(name, WorkspaceDocumentPreviewPolicy.kindForPath(name))
            assertTrue(name, WorkspaceDocumentPreviewPolicy.isUnsupportedImage(name))
        }
        // All other routed families keep their own surfaces.
        for (name in listOf("notes/a.md", "a.docx", "clip.mp4", "part.dxf", "bundle.zip", "lib.so")) {
            assertNull(name, WorkspaceDocumentPreviewPolicy.kindForPath(name))
            assertFalse(name, WorkspaceDocumentPreviewPolicy.isUnsupportedImage(name))
        }
    }

    @Test fun eachPurposeHasItsOwnClosedFormatSetAndInputCap() {
        assertEquals(setOf("pdf"), WorkspaceDocumentPreviewPolicy.formatsFor(WorkspacePreviewKind.PDF))
        assertTrue("png" in WorkspaceDocumentPreviewPolicy.formatsFor(WorkspacePreviewKind.IMAGE))
        assertFalse("pdf" in WorkspaceDocumentPreviewPolicy.formatsFor(WorkspacePreviewKind.IMAGE))
        assertEquals(
            WorkspaceOfficeSnapshotStager.MAX_BYTES,
            WorkspaceDocumentPreviewPolicy.maxBytesFor(WorkspacePreviewKind.PDF),
        )
        assertEquals(
            WorkspaceDocumentPreviewPolicy.MAX_IMAGE_BYTES,
            WorkspaceDocumentPreviewPolicy.maxBytesFor(WorkspacePreviewKind.IMAGE),
        )
        assertTrue(WorkspaceDocumentPreviewPolicy.MAX_IMAGE_BYTES < WorkspaceOfficeSnapshotStager.MAX_BYTES)
    }

    @Test fun pdfMagicIsProvedOnTheActualSnapshotBytes() {
        val good = temporary.newFile("good.pdf")
        good.writeBytes("%PDF-1.7\n".toByteArray())
        assertTrue(WorkspaceDocumentPreviewPolicy.hasPdfMagic(good))
        for (name in listOf("short.pdf", "wrong.pdf", "empty.pdf")) {
            val file = temporary.newFile(name)
            if (name == "short.pdf") file.writeBytes("%PDF".toByteArray())
            if (name == "wrong.pdf") file.writeBytes("PK\u0003\u0004docx".toByteArray())
            assertFalse(name, WorkspaceDocumentPreviewPolicy.hasPdfMagic(file))
        }
        assertFalse(WorkspaceDocumentPreviewPolicy.hasPdfMagic(File(temporary.root, "absent.pdf")))
    }

    @Test fun imageSamplingStaysInsideFixedEdgeAndPixelBounds() {
        // Small images are decoded at full resolution.
        assertEquals(1, WorkspaceDocumentPreviewPolicy.imageSampleSize(640, 480))
        // 8k×6k would allocate 192 MB as ARGB_8888: sample down to <=12 MP.
        val wide = WorkspaceDocumentPreviewPolicy.imageSampleSize(8192, 6144)
        assertTrue(wide > 1)
        assertTrue("${8192 / wide}x${6144 / wide}", 8192L / wide * (6144L / wide) <=
            WorkspaceDocumentPreviewPolicy.MAX_IMAGE_PIXELS)
        // An extremely long thin strip is bounded by the longest edge.
        val strip = WorkspaceDocumentPreviewPolicy.imageSampleSize(100_000, 100)
        assertTrue(100_000L / strip <= WorkspaceDocumentPreviewPolicy.MAX_IMAGE_EDGE_PX)
        // A forged non-positive size never gets a real allocation claim.
        assertEquals(1, WorkspaceDocumentPreviewPolicy.imageSampleSize(0, 500))
        assertEquals(1, WorkspaceDocumentPreviewPolicy.imageSampleSize(-1, -1))
        // The sample is always a positive power of two BitmapFactory accepts.
        for ((w, h) in listOf(100 to 100, 9000 to 9000, 30_000 to 20_000)) {
            val sample = WorkspaceDocumentPreviewPolicy.imageSampleSize(w, h)
            assertTrue(sample >= 1)
            assertEquals(0, sample and (sample - 1))
        }
    }

    @Test fun pageAndZoomNavigationStayInsideRendererBounds() {
        assertTrue(WorkspaceDocumentPreviewPolicy.validPdfPageCount(1))
        assertFalse(WorkspaceDocumentPreviewPolicy.validPdfPageCount(0))
        assertFalse(WorkspaceDocumentPreviewPolicy.validPdfPageCount(-3))
        assertTrue(WorkspaceDocumentPreviewPolicy.validPdfPage(0, 3))
        assertTrue(WorkspaceDocumentPreviewPolicy.validPdfPage(2, 3))
        assertFalse(WorkspaceDocumentPreviewPolicy.validPdfPage(3, 3))
        assertFalse(WorkspaceDocumentPreviewPolicy.validPdfPage(-1, 3))

        assertEquals(100, WorkspaceDocumentPreviewPolicy.zoomPercent(
            WorkspaceDocumentPreviewPolicy.DEFAULT_ZOOM_INDEX))
        for (index in -5..10) {
            val percent = WorkspaceDocumentPreviewPolicy.zoomPercent(index)
            assertTrue(percent in 25..400)
        }
        assertEquals(0, WorkspaceDocumentPreviewPolicy.zoomIndexFor(50))
        assertEquals(WorkspaceDocumentPreviewPolicy.DEFAULT_ZOOM_INDEX,
            WorkspaceDocumentPreviewPolicy.zoomIndexFor(12345))
        assertEquals(0, WorkspaceDocumentPreviewPolicy.nextZoomIndex(0, -1))
        assertEquals(WorkspaceDocumentPreviewPolicy.ZOOM_PERCENTS.lastIndex,
            WorkspaceDocumentPreviewPolicy.nextZoomIndex(
                WorkspaceDocumentPreviewPolicy.ZOOM_PERCENTS.lastIndex, 1))
    }

    @Test fun stagerRefusalsBecomeHonestTypedDecisions() {
        assertEquals(
            WorkspacePreviewState.Failure.OWNER,
            WorkspaceDocumentPreviewPolicy.failureFor(
                WorkspaceOfficeSnapshotStager.Failure("ownerChanged")),
        )
        assertEquals(
            WorkspacePreviewState.Failure.TOO_LARGE,
            WorkspaceDocumentPreviewPolicy.failureFor(
                WorkspaceOfficeSnapshotStager.Failure("contentTooLarge")),
        )
        // Everything else is a typed source/storage refusal, never a guess.
        for (code in listOf("invalidOfficePath", "sourceRefused:-1", "snapshotDigestMismatch")) {
            assertEquals(
                WorkspacePreviewState.Failure.SOURCE,
                WorkspaceDocumentPreviewPolicy.failureFor(WorkspaceOfficeSnapshotStager.Failure(code)),
            )
        }
        // Only transient renderer/transport/prompt-required states retry.
        assertTrue(WorkspaceDocumentPreviewPolicy.retryable(WorkspacePreviewState.Failure.TRANSPORT))
        assertTrue(WorkspaceDocumentPreviewPolicy.retryable(WorkspacePreviewState.Failure.RENDER))
        assertTrue(WorkspaceDocumentPreviewPolicy.retryable(
            WorkspacePreviewState.Failure.PASSWORD_REQUIRED))
        for (failure in listOf(
            WorkspacePreviewState.Failure.OWNER,
            WorkspacePreviewState.Failure.SOURCE,
            WorkspacePreviewState.Failure.TOO_LARGE,
            WorkspacePreviewState.Failure.INVALID,
            WorkspacePreviewState.Failure.UNSUPPORTED,
            WorkspacePreviewState.Failure.PASSWORD_REJECTED,
            WorkspacePreviewState.Failure.PASSWORD_UNSUPPORTED,
        )) {
            assertFalse(failure.name, WorkspaceDocumentPreviewPolicy.retryable(failure))
        }
    }

    @Test fun ownerIdentityRequiresRealUUIDsAndAPositiveEpoch() {
        val task = UUID.randomUUID().toString()
        val workspace = UUID.randomUUID().toString()
        val owner = Owner(task, workspace, 9, 3)
        assertEquals(task, owner.taskID)
        assertEquals(workspace, owner.workspaceID)
        fun refused(block: () -> Unit) {
            try {
                block()
            } catch (_: IllegalArgumentException) {
                return
            }
            throw AssertionError("Expected the owner identity to be refused")
        }
        refused { Owner("not-a-uuid", workspace, 9, 3) }
        refused { Owner(task, "also-not-a-uuid", 9, 3) }
        refused { Owner(task, workspace, 0, 3) }
        refused { Owner(task, workspace, 9, -1) }
    }
}
