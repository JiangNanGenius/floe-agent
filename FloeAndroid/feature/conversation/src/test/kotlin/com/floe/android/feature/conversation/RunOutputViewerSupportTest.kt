// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.conversation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The owned-output viewer classification table: image/audio/video keep
 * their exact MIME+extension agreement, while plain text, code and unknown
 * UTF-8 candidates use the same broad policy as the workspace editor and
 * are still content-probed before display. Non-text families and arbitrary
 * binaries never fall through to a text or fake preview. */
class RunOutputViewerSupportTest {

    @Test
    fun textFamiliesCoverPlainTextAndCodeWithoutBinaryDrift() {
        assertEquals(RunOutputViewerKind.TEXT,
            RunOutputViewerSupport.classify("text/markdown", "qa_report.md"))
        assertEquals(RunOutputViewerKind.TEXT,
            RunOutputViewerSupport.classify("text/x-markdown", "notes.MARKDOWN"))
        assertEquals(RunOutputViewerKind.TEXT,
            RunOutputViewerSupport.classify("text/plain", "log.txt"))
        assertEquals(RunOutputViewerKind.TEXT,
            RunOutputViewerSupport.classify("text/plain; charset=utf-8", "app.log"))
        // The Android publisher's documented octet-stream fallback for
        // uncommon text/code extensions is still a bounded TEXT candidate;
        // the viewer strictly probes UTF-8/NUL before rendering.
        assertEquals(RunOutputViewerKind.TEXT,
            RunOutputViewerSupport.classify("application/octet-stream", "notes.md"))
        assertEquals(RunOutputViewerKind.TEXT,
            RunOutputViewerSupport.classify("application/octet-stream", "script.py"))
        assertEquals(RunOutputViewerKind.TEXT,
            RunOutputViewerSupport.classify("application/octet-stream", "build.sh"))
        assertEquals(RunOutputViewerKind.TEXT,
            RunOutputViewerSupport.classify("application/octet-stream", "page.html"))
        assertEquals(RunOutputViewerKind.TEXT,
            RunOutputViewerSupport.classify("text/csv", "data.csv"))
        assertEquals(RunOutputViewerKind.TEXT,
            RunOutputViewerSupport.classify("application/json", "config.json"))
        assertEquals(RunOutputViewerKind.TEXT,
            RunOutputViewerSupport.classify("text/xml", "layout.xml"))
        assertEquals(RunOutputViewerKind.TEXT,
            RunOutputViewerSupport.classify("application/octet-stream", "README"))
        assertEquals(RunOutputViewerKind.TEXT,
            RunOutputViewerSupport.classify("application/octet-stream", "unknown.foobar"))
        // Non-text families never fall through to a text or binary decode.
        assertEquals(RunOutputViewerKind.UNSUPPORTED,
            RunOutputViewerSupport.classify("text/plain", "notes.png"))
        assertEquals(RunOutputViewerKind.UNSUPPORTED,
            RunOutputViewerSupport.classify("text/plain", "report.docx"))
        assertEquals(RunOutputViewerKind.UNSUPPORTED,
            RunOutputViewerSupport.classify("application/octet-stream", "archive.zip"))
        assertEquals(RunOutputViewerKind.UNSUPPORTED,
            RunOutputViewerSupport.classify("application/octet-stream", "render.mp4"))
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
        // A sealed display name never starts with a dot, and an
        // extensionless/unknown name is a real text candidate once its MIME
        // says text or the publisher fallback applies.
        assertEquals(RunOutputViewerKind.TEXT,
            RunOutputViewerSupport.classify("text/plain", "noextension"))
        assertEquals(RunOutputViewerKind.TEXT,
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
    fun stagedExtensionsCoverTextAndMediaAgreementTables() {
        for (extension in listOf(
            "txt", "md", "log", "csv", "tsv", "html", "htm", "py", "js", "ts",
            "rs", "swift", "tex", "rst", "json", "yaml", "toml", "xml",
            "png", "jpg", "jpeg", "webp", "gif", "wav", "mp3", "m4a", "ogg",
            "mp4", "webm", "3gp",
        )) {
            assertTrue(extension, extension in RunOutputViewerSupport.STAGED_EXTENSIONS)
        }
        // Office/PDF and arbitrary binaries stay owned by their native lanes
        // — never restaged as a text preview.
        for (extension in listOf("pdf", "docx", "xlsx", "pptx", "zip", "bin", "exe", "wasm")) {
            assertFalse(extension, extension in RunOutputViewerSupport.STAGED_EXTENSIONS)
        }
    }
}
