// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.spacefiles

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Name/MIME policy used for provider requests and bounded previews. These are
 * the real gates: an unsafe display segment must never reach a provider call,
 * an SVG must never be claimed as a decodable bitmap, and an unknown size must
 * never be printed as 0.
 */
class SpaceFilesNamesTest {

    @Test
    fun acceptsOneOrdinaryDisplaySegment() {
        assertTrue(SpaceFilesNames.isSafeSegment("notes.txt"))
        assertTrue(SpaceFilesNames.isSafeSegment("Design QA 2026"))
        assertTrue(SpaceFilesNames.isSafeSegment("报告-01.pdf"))
        assertTrue(SpaceFilesNames.isSafeSegment(".gitignore"))
    }

    @Test
    fun refusesSeparatorsTraversalControlsAndOversizeNames() {
        assertFalse(SpaceFilesNames.isSafeSegment(""))
        assertFalse(SpaceFilesNames.isSafeSegment("   "))
        assertFalse(SpaceFilesNames.isSafeSegment("a/b"))
        assertFalse(SpaceFilesNames.isSafeSegment("a\\b"))
        assertFalse(SpaceFilesNames.isSafeSegment(".."))
        assertFalse(SpaceFilesNames.isSafeSegment("."))
        assertFalse(SpaceFilesNames.isSafeSegment("a\u0000b"))
        assertFalse(SpaceFilesNames.isSafeSegment(" padded "))
        assertFalse(SpaceFilesNames.isSafeSegment("x".repeat(256)))
        assertTrue("255 ASCII bytes is still one legal segment", SpaceFilesNames.isSafeSegment("x".repeat(255)))
    }

    @Test
    fun newTextFilesUseTheTypedExtensionMime() {
        assertEquals("text/markdown", SpaceFilesNames.mimeForNewTextFile("notes.md"))
        assertEquals("application/json", SpaceFilesNames.mimeForNewTextFile("data.JSON"))
        assertEquals("text/csv", SpaceFilesNames.mimeForNewTextFile("rows.csv"))
        assertEquals("text/html", SpaceFilesNames.mimeForNewTextFile("page.html"))
        assertEquals("text/plain", SpaceFilesNames.mimeForNewTextFile("plain-name"))
    }

    @Test
    fun textPreviewFollowsDeclaredMimeAndKnownTextNames() {
        assertTrue(SpaceFilesNames.allowsTextPreview("text/plain", "a.bin"))
        assertTrue(SpaceFilesNames.allowsTextPreview("application/json", "data"))
        assertTrue(SpaceFilesNames.allowsTextPreview("application/octet-stream", "README.md"))
        assertTrue("SVG is text XML, not a bitmap", SpaceFilesNames.allowsTextPreview("image/svg+xml", "icon.svg"))
        assertFalse(SpaceFilesNames.allowsTextPreview("application/octet-stream", "blob.bin"))
        assertFalse(SpaceFilesNames.allowsTextPreview("application/pdf", "document.pdf"))
    }

    @Test
    fun imagePreviewOnlyClaimsRasterImages() {
        assertTrue(SpaceFilesNames.allowsImagePreview("image/png", "photo.png"))
        assertTrue(SpaceFilesNames.allowsImagePreview("image/jpeg", "photo"))
        assertTrue(SpaceFilesNames.allowsImagePreview("application/octet-stream", "photo.jpg"))
        assertFalse(SpaceFilesNames.allowsImagePreview("image/svg+xml", "icon.svg"))
        assertFalse(SpaceFilesNames.allowsImagePreview("application/pdf", "document.pdf"))
    }

    @Test
    fun byteSizesAreHumanAndNeverTurnUnknownIntoZero() {
        assertEquals("0 B", SpaceFilesNames.formatBytes(0))
        assertEquals("1023 B", SpaceFilesNames.formatBytes(1023))
        assertEquals("1.0 KB", SpaceFilesNames.formatBytes(1024))
        assertEquals("1.5 KB", SpaceFilesNames.formatBytes(1536))
        assertEquals("1.0 MB", SpaceFilesNames.formatBytes(1024L * 1024))
        assertEquals("2.5 GB", SpaceFilesNames.formatBytes((2.5 * 1024 * 1024 * 1024).toLong()))
    }

    @Test
    fun extensionsAreLowercasedAndDotOnlyNamesHaveNone() {
        assertEquals("md", SpaceFilesNames.extensionOf("Notes.MD"))
        assertEquals("gitignore", SpaceFilesNames.extensionOf(".gitignore"))
        assertEquals("", SpaceFilesNames.extensionOf("no-extension"))
        assertEquals("", SpaceFilesNames.extensionOf("."))
        assertEquals("", SpaceFilesNames.extensionOf("trailing."))
    }
}
