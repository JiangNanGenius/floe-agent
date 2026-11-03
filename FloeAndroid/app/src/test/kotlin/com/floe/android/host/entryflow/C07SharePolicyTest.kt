// SPDX-License-Identifier: MPL-2.0
//
// C07 bounded share/open policy, content sniff and draft-merge regressions.
// Pure JVM (ByteArrayInputStream only): no provider, URI grant or App state.
// AUTHORED, NOT RUN by this lane.
package com.floe.android.host.entryflow

import java.io.ByteArrayInputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class C07SharePolicyTest {
    private fun file(
        mime: String,
        name: String,
        bytes: Long,
        index: Int = 0,
    ): C07EntryCapturedItem = C07EntryCapturedItem(
        index = index,
        kind = C07EntryItemKind.FILE,
        uriString = "content://synthetic/$index",
        mimeType = mime,
        displayName = name,
        declaredBytes = bytes,
        text = null,
    )

    private fun text(value: String, index: Int = 0): C07EntryCapturedItem =
        C07EntryCapturedItem(
            index = index,
            kind = C07EntryItemKind.TEXT,
            uriString = null,
            mimeType = "text/plain",
            displayName = "Shared text",
            declaredBytes = value.toByteArray(Charsets.UTF_8).size.toLong(),
            text = value,
        )

    @Test
    fun acceptsBoundedSupportedItems() {
        val result = C07SharePolicy.validate(
            listOf(text("hello"), file("application/pdf", "Synthetic.pdf", 4096, 1)),
        ) as C07ShareValidation.Accepted
        assertEquals(4096L, result.totalKnownBytes)
        assertEquals(5L, result.textBytes)
    }

    @Test
    fun rejectsCountTextItemAndTotalOverflow() {
        assertEquals(
            C07EntryRefusal.ITEM_LIMIT,
            (C07SharePolicy.validate((1..6).map { file("application/pdf", "f$it.pdf", 1, it) })
                as C07ShareValidation.Refused).code,
        )
        assertEquals(
            C07EntryRefusal.TEXT_TOO_LARGE,
            (C07SharePolicy.validate(
                listOf(text("a".repeat(ENTRY_MAX_TEXT_BYTES.toInt() + 1))),
            ) as C07ShareValidation.Refused).code,
        )
        assertEquals(
            C07EntryRefusal.ITEM_TOO_LARGE,
            (C07SharePolicy.validate(
                listOf(file("application/pdf", "big.pdf", ENTRY_MAX_ITEM_BYTES + 1)),
            ) as C07ShareValidation.Refused).code,
        )
        assertEquals(
            C07EntryRefusal.TOTAL_TOO_LARGE,
            (C07SharePolicy.validate(
                listOf(
                    file("application/pdf", "a.pdf", ENTRY_MAX_ITEM_BYTES, 0),
                    file("application/pdf", "b.pdf", ENTRY_MAX_ITEM_BYTES, 1),
                    file("application/pdf", "c.pdf", 1, 2),
                ),
            ) as C07ShareValidation.Refused).code,
        )
        assertEquals(
            C07EntryRefusal.EMPTY,
            (C07SharePolicy.validate(emptyList()) as C07ShareValidation.Refused).code,
        )
    }

    @Test
    fun rejectsExecutableAndUnknownUnnamedPayloads() {
        // Installable containers have no existing in-App consumer.
        assertEquals(
            C07EntryRefusal.UNSUPPORTED,
            (C07SharePolicy.validate(
                listOf(file("application/vnd.android.package-archive", "install.apk", 12)),
            ) as C07ShareValidation.Refused).code,
        )
        assertEquals(
            C07EntryRefusal.UNSUPPORTED,
            (C07SharePolicy.validate(
                listOf(file("application/x-msdownload", "setup.exe", 12)),
            ) as C07ShareValidation.Refused).code,
        )
        // Unknown binary with no supported identity stays refused.
        assertEquals(
            C07EntryRefusal.UNSUPPORTED,
            (C07SharePolicy.validate(
                listOf(file("application/octet-stream", "payload.bin", 12)),
            ) as C07ShareValidation.Refused).code,
        )
        assertEquals(
            C07EntryRefusal.UNSUPPORTED,
            (C07SharePolicy.validate(
                listOf(file("application/zip", "payload.bin", 12)),
            ) as C07ShareValidation.Refused).code,
        )
    }

    @Test
    fun acceptsHonestUnknownSizeAndKnownExtension() {
        val result = C07SharePolicy.validate(
            listOf(
                file("application/octet-stream", "Synthetic.pdf", -1, 0),
                file("application/zip", "Synthetic.docx", 20, 1),
            ),
        ) as C07ShareValidation.Accepted
        assertEquals(20L, result.totalKnownBytes)
    }

    @Test
    fun admitsExistingMediaCadAndSourceFormatsAsData() {
        for ((mime, name) in listOf(
            "image/heic" to "photo.heic",
            "image/heif" to "photo.heif",
            "image/avif" to "photo.avif",
            "image/bmp" to "scan.bmp",
            "audio/mpeg" to "voice.mp3",
            "audio/mp4" to "voice.m4a",
            "audio/ogg" to "voice.opus",
            "video/mp4" to "clip.mp4",
            "video/quicktime" to "clip.mov",
            "application/dxf" to "plan.dxf",
            "application/acad" to "plan.dwg",
            "application/step" to "part.step",
            "model/gltf-binary" to "scene.glb",
            "text/x-python" to "tool.py",
            "application/json" to "data.json",
            "text/html" to "page.html",
            "application/octet-stream" to "notes.md",
        )) {
            val accepted = C07SharePolicy.validate(listOf(file(mime, name, 1024)))
            assertTrue("expected admission for $mime, got $accepted", accepted is C07ShareValidation.Accepted)
            val admission = accepted as C07ShareValidation.Accepted
            assertTrue(admission.taskAvailable)
            assertTrue(admission.notesAvailable)
            assertEquals(C07EntryPackageKind.NONE, admission.packageKind)
        }
    }

    @Test
    fun routesPackagesToSingleReviewOwnerAndExemptsOwnerBudget() {
        val note = C07SharePolicy.validate(
            listOf(file("application/zip", "Story.floenote", 8_192)),
        ) as C07ShareValidation.Accepted
        assertEquals(C07EntryPackageKind.NOTE, note.packageKind)
        assertTrue(!note.taskAvailable)
        assertTrue(!note.notesAvailable)

        val canvas = C07SharePolicy.validate(
            listOf(file("application/octet-stream", "Board.flocanvas", 1)),
        ) as C07ShareValidation.Accepted
        assertEquals(C07EntryPackageKind.CANVAS, canvas.packageKind)

        val backup = C07SharePolicy.validate(
            listOf(file("application/octet-stream", "Floe-backup.floebackup", ENTRY_MAX_ITEM_BYTES * 4)),
        ) as C07ShareValidation.Accepted
        assertEquals(C07EntryPackageKind.BACKUP, backup.packageKind)
        assertEquals(0L, backup.totalKnownBytes)

        val cad = C07SharePolicy.validate(
            listOf(file("application/octet-stream", "Model.floecad", -1)),
        ) as C07ShareValidation.Accepted
        assertEquals(C07EntryPackageKind.CAD, cad.packageKind)

        assertEquals(
            C07EntryRefusal.PACKAGE_MIXED,
            (C07SharePolicy.validate(
                listOf(
                    file("application/zip", "Story.floenote", 10, 0),
                    file("application/pdf", "Synthetic.pdf", 10, 1),
                ),
            ) as C07ShareValidation.Refused).code,
        )
    }

    @Test
    fun supportedDataIsNeverAPermissionToExecute() {
        val source = C07SharePolicy.validate(
            listOf(file("text/x-shellscript", "install.sh", 128)),
        ) as C07ShareValidation.Accepted
        // Only consumer routing is decided here; no execution/run/install flag
        // exists in the admitted contract.
        assertTrue(source.taskAvailable && source.notesAvailable)
        assertEquals(C07EntryPackageKind.NONE, source.packageKind)
        assertEquals(C07EntryContentClass.SOURCE, C07SharePolicy.formatFor("text/x-shellscript", "install.sh")?.contentClass)
        assertEquals(C07EntryContentClass.SOURCE, C07SharePolicy.formatFor("application/octet-stream", "install.sh")?.contentClass)
    }

    @Test
    fun payloadCapStillBoundsNonPackageItems() {
        assertEquals(
            C07EntryRefusal.ITEM_TOO_LARGE,
            (C07SharePolicy.validate(
                listOf(file("video/mp4", "clip.mp4", ENTRY_MAX_ITEM_BYTES + 1)),
            ) as C07ShareValidation.Refused).code,
        )
    }

    @Test
    fun contentSniffingReconcilesProviderHints() {
        assertEquals(C07ProbeKind.PDF, probe("%PDF-1.7\nsynthetic"))
        assertEquals(C07ProbeKind.PNG, probe(byteArrayOf(-119, 80, 78, 71, 13, 10, 26, 10)))
        assertEquals(C07ProbeKind.JPEG, probe(byteArrayOf(-1, -40, -1, -32, 0, 16)))
        assertEquals(C07ProbeKind.GIF, probe("GIF89a".toByteArray(Charsets.US_ASCII)))
        assertEquals(
            C07ProbeKind.ZIP,
            probe(byteArrayOf(80, 75, 3, 4, 20, 0, 0, 0)),
        )
        assertEquals(C07ProbeKind.TEXT, probe("plain UTF-8 text\n".toByteArray()))

        assertEquals(
            "application/pdf",
            C07ContentSniffer.reconcile("application/pdf", C07ProbeKind.PDF, "a.pdf").mimeType,
        )
        assertEquals(
            C07EntryRefusal.CONTENT_MISMATCH,
            C07ContentSniffer.reconcile("application/pdf", C07ProbeKind.ZIP, "a.pdf").refusal,
        )
        assertEquals(
            "application/pdf",
            C07ContentSniffer.reconcile(
                "application/octet-stream",
                C07ProbeKind.PDF,
                "a.pdf",
            ).mimeType,
        )
        assertEquals(
            C07EntryRefusal.UNSUPPORTED,
            C07ContentSniffer.reconcile("application/octet-stream", C07ProbeKind.UNKNOWN, "a.bin").refusal,
        )
        assertEquals(
            C07EntryRefusal.CONTENT_MISMATCH,
            C07ContentSniffer.reconcile("application/octet-stream", C07ProbeKind.ZIP, "a.pdf").refusal,
        )
        val html = C07ContentSniffer.reconcile("text/html", C07ProbeKind.TEXT, "a.html")
        assertEquals("text/plain", html.mimeType)
        assertEquals(C07EntryContentClass.SOURCE, html.contentClass)
        assertNull(
            C07ContentSniffer.reconcile("text/html", C07ProbeKind.BMP, "a.html").mimeType,
        )
    }

    @Test
    fun draftMergePreservesExistingWorkAndBounds() {
        assertEquals("existing\n\nshared", C07EntryMerge.text("existing", " shared "))
        assertEquals("shared", C07EntryMerge.text("   ", "shared"))
        assertEquals("existing\n\nshared", C07EntryMerge.text("existing\n", "shared"))
        assertNull(C07EntryMerge.text("a".repeat(ENTRY_MAX_TEXT_BYTES.toInt()), "more"))
    }

    @Test
    fun capturedItemToStringNeverLeaksUriOrText() {
        val item = C07EntryCapturedItem(
            index = 0,
            kind = C07EntryItemKind.FILE,
            uriString = "content://private/secret",
            mimeType = "application/pdf",
            displayName = "secret.pdf",
            declaredBytes = 12,
            text = null,
        )
        assertTrue(item.toString().contains("kind=FILE"))
        assertTrue(!item.toString().contains("content://"))
        assertTrue(!item.toString().contains("secret.pdf"))
    }

    private fun probe(text: String): C07ProbeKind =
        C07ContentSniffer.probe(ByteArrayInputStream(text.toByteArray()))

    private fun probe(bytes: ByteArray): C07ProbeKind =
        C07ContentSniffer.probe(ByteArrayInputStream(bytes))
}
