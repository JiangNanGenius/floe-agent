// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.conversation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The owned-output viewer agreement table: BOTH sealed facts (receipt MIME
 * + sealed display-name extension) must agree; a mismatch in either
 * direction is UNSUPPORTED (honest limitation, never a sniffed guess);
 * unknown types never reach a preview kind; and the staged-extension gate
 * exactly covers the union of the four agreement tables. */
class RunOutputViewerSupportTest {

    @Test
    fun textAndMarkdownRequireAgreement() {
        assertEquals(RunOutputViewerKind.TEXT,
            RunOutputViewerSupport.classify("text/markdown", "qa_report.md"))
        assertEquals(RunOutputViewerKind.TEXT,
            RunOutputViewerSupport.classify("text/x-markdown", "notes.MARKDOWN"))
        assertEquals(RunOutputViewerKind.TEXT,
            RunOutputViewerSupport.classify("text/plain", "log.txt"))
        assertEquals(RunOutputViewerKind.TEXT,
            RunOutputViewerSupport.classify("text/plain; charset=utf-8", "app.log"))
        // Agreement violations — either side alone is never a preview:
        assertEquals(RunOutputViewerKind.UNSUPPORTED,
            RunOutputViewerSupport.classify("text/plain", "notes.md"))
        assertEquals(RunOutputViewerKind.UNSUPPORTED,
            RunOutputViewerSupport.classify("text/markdown", "notes.txt"))
        assertEquals(RunOutputViewerKind.UNSUPPORTED,
            RunOutputViewerSupport.classify("text/html", "page.md"))
        assertEquals(RunOutputViewerKind.UNSUPPORTED,
            RunOutputViewerSupport.classify("application/octet-stream", "notes.md"))
    }

    @Test
    fun imageAgreementCoversDecodeProvableFormats() {
        assertEquals(RunOutputViewerKind.IMAGE,
            RunOutputViewerSupport.classify("image/png", "chart.png"))
        assertEquals(RunOutputViewerKind.IMAGE,
            RunOutputViewerSupport.classify("image/jpeg", "photo.jpeg"))
        assertEquals(RunOutputViewerKind.IMAGE,
            RunOutputViewerSupport.classify("image/jpeg", "photo.JPG"))
        assertEquals(RunOutputViewerKind.IMAGE,
            RunOutputViewerSupport.classify("image/webp", "frame.webp"))
        assertEquals(RunOutputViewerKind.IMAGE,
            RunOutputViewerSupport.classify("image/gif", "anim.gif"))
        assertEquals(RunOutputViewerKind.UNSUPPORTED,
            RunOutputViewerSupport.classify("image/png", "chart.webp"))
        assertEquals(RunOutputViewerKind.UNSUPPORTED,
            RunOutputViewerSupport.classify("image/heic", "photo.heic"))
        assertEquals(RunOutputViewerKind.UNSUPPORTED,
            RunOutputViewerSupport.classify("image/svg+xml", "vector.svg"))
    }

    @Test
    fun audioAndVideoAgreeOnPlayableContainers() {
        assertEquals(RunOutputViewerKind.AUDIO,
            RunOutputViewerSupport.classify("audio/wav", "voice.wav"))
        assertEquals(RunOutputViewerKind.AUDIO,
            RunOutputViewerSupport.classify("audio/x-wav", "voice.wav"))
        assertEquals(RunOutputViewerKind.AUDIO,
            RunOutputViewerSupport.classify("audio/mpeg", "song.mp3"))
        assertEquals(RunOutputViewerKind.AUDIO,
            RunOutputViewerSupport.classify("audio/mp4", "clip.m4a"))
        assertEquals(RunOutputViewerKind.AUDIO,
            RunOutputViewerSupport.classify("audio/ogg", "clip.ogg"))
        assertEquals(RunOutputViewerKind.VIDEO,
            RunOutputViewerSupport.classify("video/mp4", "render.mp4"))
        assertEquals(RunOutputViewerKind.VIDEO,
            RunOutputViewerSupport.classify("video/webm", "render.webm"))
        assertEquals(RunOutputViewerKind.VIDEO,
            RunOutputViewerSupport.classify("video/3gpp", "render.3gp"))
        // Cross-family and mismatch refusals:
        assertEquals(RunOutputViewerKind.UNSUPPORTED,
            RunOutputViewerSupport.classify("audio/wav", "voice.mp3"))
        assertEquals(RunOutputViewerKind.UNSUPPORTED,
            RunOutputViewerSupport.classify("video/mp4", "render.m4a"))
        assertEquals(RunOutputViewerKind.UNSUPPORTED,
            RunOutputViewerSupport.classify("audio/mp4", "render.mp4")) // audio claim over a video name
        assertEquals(RunOutputViewerKind.UNSUPPORTED,
            RunOutputViewerSupport.classify("application/octet-stream", "render.mp4"))
    }

    @Test
    fun emptyAndMalformedFactsRefuse() {
        assertEquals(RunOutputViewerKind.UNSUPPORTED,
            RunOutputViewerSupport.classify("", "a.md"))
        assertEquals(RunOutputViewerKind.UNSUPPORTED,
            RunOutputViewerSupport.classify("text/plain", ""))
        assertEquals(RunOutputViewerKind.UNSUPPORTED,
            RunOutputViewerSupport.classify("text/plain", "noextension"))
        assertEquals(RunOutputViewerKind.UNSUPPORTED,
            RunOutputViewerSupport.classify("text/plain", ".hidden"))
    }

    @Test
    fun supportsPreviewMatchesClassification() {
        assertTrue(RunOutputViewerSupport.supportsPreview("text/markdown", "a.md"))
        assertTrue(RunOutputViewerSupport.supportsPreview("image/png", "a.png"))
        assertTrue(RunOutputViewerSupport.supportsPreview("audio/wav", "a.wav"))
        assertTrue(RunOutputViewerSupport.supportsPreview("video/mp4", "a.mp4"))
        assertFalse(RunOutputViewerSupport.supportsPreview("application/pdf", "a.pdf"))
        assertFalse(RunOutputViewerSupport.supportsPreview(
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "a.docx"))
        assertFalse(RunOutputViewerSupport.supportsPreview("application/octet-stream", "a.bin"))
    }

    @Test
    fun stagedExtensionsCoverExactlyTheAgreementTables() {
        assertEquals(
            sortedSetOf(
                "3gp", "aac", "gif", "jpeg", "jpg", "log", "m4a", "markdown", "md",
                "mp3", "mp4", "ogg", "png", "text", "txt", "wav", "webp", "webm",
            ),
            RunOutputViewerSupport.STAGED_EXTENSIONS,
        )
        // Office/PDF stay owned by their existing lanes — never restaged here.
        assertFalse("pdf" in RunOutputViewerSupport.STAGED_EXTENSIONS)
        assertFalse("docx" in RunOutputViewerSupport.STAGED_EXTENSIONS)
    }
}
