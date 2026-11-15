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

    @Test
    fun legacyAnnotatedNamesKeepTheirVerifiedTypeAndExactTitle() {
        // The confirmed Full18 defect: a real PNG/MP4 seal with one trailing
        // human annotation must stay viewable. The exact sealed string stays
        // the presentation title and canonical path tail; only the derived
        // transfer filename moves the annotation beside the basename.
        val png = RunOutputDisplayName.facts("sydney_creator_meetup_poster.png（海报）")
        assertEquals("sydney_creator_meetup_poster.png（海报）", png.title)
        assertEquals("png", png.extension)
        assertEquals("sydney_creator_meetup_poster（海报）.png", png.transferName)
        assertTrue(png.annotated)
        assertEquals(RunOutputViewerKind.IMAGE,
            RunOutputViewerSupport.classify("image/png", png.title))

        val mp4 = RunOutputDisplayName.facts(
            "sydney_creator_meetup_teaser_12s_1080p.mp4（12秒预告）")
        assertEquals("sydney_creator_meetup_teaser_12s_1080p.mp4（12秒预告）", mp4.title)
        assertEquals("mp4", mp4.extension)
        assertEquals("sydney_creator_meetup_teaser_12s_1080p（12秒预告）.mp4", mp4.transferName)
        assertEquals(RunOutputViewerKind.VIDEO,
            RunOutputViewerSupport.classify("video/mp4", mp4.title))

        assertEquals(RunOutputViewerKind.AUDIO,
            RunOutputViewerSupport.classify("audio/mpeg", "narration.mp3（旁白）"))
        assertEquals(RunOutputViewerKind.IMAGE,
            RunOutputViewerSupport.classify("image/jpeg", "photo.jpg (final)"))
        assertEquals(RunOutputViewerKind.IMAGE,
            RunOutputViewerSupport.classify("image/png", "Poster.PNG（海报）"))
        assertEquals(RunOutputViewerKind.IMAGE,
            RunOutputViewerSupport.classify("image/png", "poster.png【海报】"))
        assertEquals("poster【海报】.png",
            RunOutputDisplayName.facts("poster.png【海报】").transferName)
        // A dot inside the label (`（v1.2）`) must not become the extension.
        assertEquals(RunOutputViewerKind.IMAGE,
            RunOutputViewerSupport.classify("image/png", "poster.png（v1.2）"))
        assertEquals("poster（v1.2）.png",
            RunOutputDisplayName.facts("poster.png（v1.2）").transferName)
        // Text candidates keep their broad content-probed policy, including
        // an unknown extension behind one annotation.
        assertEquals(RunOutputViewerKind.TEXT,
            RunOutputViewerSupport.classify("text/markdown", "notes.md（备注）"))
        assertEquals(RunOutputViewerKind.TEXT,
            RunOutputViewerSupport.classify("application/octet-stream", "script.py（脚本）"))
        assertEquals(RunOutputViewerKind.TEXT,
            RunOutputViewerSupport.classify("application/octet-stream", "notes.foobar（备注）"))
        assertEquals(RunOutputViewerKind.TEXT,
            RunOutputViewerSupport.classify("text/plain", "README（备注）"))
    }

    @Test
    fun legacyAnnotationNeverOverridesMimeAgreementOrAcceptedFormats() {
        // The annotation supplies a filename fact only. The MIME agreement
        // still decides, so a mislabelled image/archive stays unsupported.
        assertEquals(RunOutputViewerKind.UNSUPPORTED,
            RunOutputViewerSupport.classify("image/png", "poster.webp（海报）"))
        assertEquals(RunOutputViewerKind.UNSUPPORTED,
            RunOutputViewerSupport.classify("text/plain", "poster.png（海报）"))
        assertEquals(RunOutputViewerKind.UNSUPPORTED,
            RunOutputViewerSupport.classify("application/octet-stream", "archive.zip（下载）"))
        // One trailing annotation only: a second group, trailing text or a
        // path separator inside the label keeps the legacy opaque name and
        // therefore the existing refusal.
        for (name in listOf(
            "poster.png（海报）（终版）",
            "poster.png（海报）extra",
            "poster.png（../x）",
            "poster.png（海/报）",
            "poster.png（）",
        )) {
            assertEquals(name, RunOutputViewerKind.UNSUPPORTED,
                RunOutputViewerSupport.classify("image/png", name))
        }
    }

    @Test
    fun annotationProjectionLeavesOrdinaryAndDottedBasenamesAlone() {
        val finalPng = RunOutputDisplayName.facts("report (final).png")
        assertEquals("report (final).png", finalPng.title)
        assertEquals("report (final).png", finalPng.transferName)
        assertEquals("png", finalPng.extension)
        assertFalse(finalPng.annotated)
        assertEquals(RunOutputViewerKind.IMAGE,
            RunOutputViewerSupport.classify("image/png", finalPng.title))

        val annotated = RunOutputDisplayName.facts("report (final).png（海报）")
        assertEquals("report (final).png（海报）", annotated.title)
        assertEquals("report (final)（海报）.png", annotated.transferName)
        assertTrue(annotated.annotated)

        // A dotted basename keeps both real dots: only the final suffix is
        // projected and the annotation is inserted before it.
        val dotted = RunOutputDisplayName.facts("foo.bar.png（海报）")
        assertEquals("foo.bar（海报）.png", dotted.transferName)
        assertEquals("png", dotted.extension)

        // Ordinary uppercase extensions are not rewritten for transfer.
        val upper = RunOutputDisplayName.facts("Report.PDF")
        assertEquals("Report.PDF", upper.transferName)
        assertEquals("pdf", upper.extension)
        assertFalse(upper.annotated)
    }
}
