// SPDX-License-Identifier: MPL-2.0
//
// C07 consumer coverage regressions: real container signatures for the media
// formats the App already supports, honest mismatch refusal, package review
// routing/gating and the unchanged bounded copy budget.
//
// Pure JVM (ByteArrayInputStream + pure policy). No provider, URI grant, App
// state, database, network or device participates.
// AUTHORED, NOT RUN by this lane.
package com.floe.android.host.entryflow

import com.floe.android.feature.entryflow.EntryReviewAvailability
import java.io.ByteArrayInputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class C07EntryConsumerCoverageTest {
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

    private fun probe(bytes: ByteArray): C07ProbeKind =
        C07ContentSniffer.probe(ByteArrayInputStream(bytes))

    private fun ascii(value: String): ByteArray = value.toByteArray(Charsets.US_ASCII)

    private fun isoBmff(brand: String, compatible: String? = null): ByteArray {
        val bytes = ByteArray(if (compatible == null) 16 else 20)
        bytes[0] = 0
        bytes[1] = 0
        bytes[2] = 0
        bytes[3] = bytes.size.toByte()
        "ftyp".toByteArray(Charsets.US_ASCII).copyInto(bytes, 4)
        brand.toByteArray(Charsets.US_ASCII).copyInto(bytes, 8)
        compatible?.toByteArray(Charsets.US_ASCII)?.copyInto(bytes, 16)
        return bytes
    }

    @Test
    fun detectsActualMediaAndCadContainerSignatures() {
        assertEquals(C07ProbeKind.HEIC, probe(isoBmff("heic", "mif1")))
        assertEquals(C07ProbeKind.HEIC, probe(isoBmff("mif1")))
        assertEquals(C07ProbeKind.AVIF, probe(isoBmff("avif", "mif1")))
        // Generic HEIF major + AVIF compatible brand is still AVIF; the
        // compatible `mif1` on a HEIC file must not flip it to AVIF.
        assertEquals(C07ProbeKind.AVIF, probe(isoBmff("mif1", "avif")))
        assertEquals(C07ProbeKind.HEIC, probe(isoBmff("mif1", "heic")))
        assertEquals(C07ProbeKind.ISO_BMFF, probe(isoBmff("isom")))
        assertEquals(C07ProbeKind.ISO_BMFF, probe(isoBmff("qt  ")))
        assertEquals(C07ProbeKind.MP3, probe(ascii("ID3\u0004\u0000")))
        assertEquals(C07ProbeKind.MP3, probe(byteArrayOf(0xFF.toByte(), 0xFB.toByte(), 0x90.toByte(), 0x64)))
        assertEquals(C07ProbeKind.AAC, probe(byteArrayOf(0xFF.toByte(), 0xF1.toByte(), 0x50.toByte(), 0x80.toByte())))
        assertEquals(
            C07ProbeKind.WAV,
            probe(ascii("RIFF") + ByteArray(4) + ascii("WAVEfmt ")),
        )
        assertEquals(C07ProbeKind.FLAC, probe(ascii("fLaC\u0000\u0000")))
        assertEquals(C07ProbeKind.OGG, probe(ascii("OggS\u0000\u0002")))
        assertEquals(
            C07ProbeKind.WEBM,
            probe(byteArrayOf(0x1A, 0x45, 0xDF.toByte(), 0xA3.toByte(), 0x01)),
        )
        assertEquals(C07ProbeKind.GLB, probe(ascii("glTF\u0002\u0000\u0000\u0000")))
        assertEquals(C07ProbeKind.BMP, probe(bmpHeader()))
    }

    private fun bmpHeader(): ByteArray {
        val bytes = ByteArray(30)
        bytes[0] = 'B'.code.toByte()
        bytes[1] = 'M'.code.toByte()
        bytes[2] = bytes.size.toByte()
        return bytes
    }

    @Test
    fun reconcilesDeclaredTypesAgainstRealBytes() {
        assertEquals(
            "image/heic",
            C07ContentSniffer.reconcile("image/heic", C07ProbeKind.HEIC, "photo.heic").mimeType,
        )
        assertEquals(
            C07EntryContentClass.IMAGE,
            C07ContentSniffer.reconcile("image/heic", C07ProbeKind.HEIC, "photo.heic").contentClass,
        )
        assertEquals(
            C07EntryRefusal.CONTENT_MISMATCH,
            C07ContentSniffer.reconcile("image/png", C07ProbeKind.HEIC, "photo.png").refusal,
        )
        assertEquals(
            "image/avif",
            C07ContentSniffer.reconcile("application/octet-stream", C07ProbeKind.AVIF, "photo.avif").mimeType,
        )
        assertEquals(
            "audio/mpeg",
            C07ContentSniffer.reconcile("audio/mpeg", C07ProbeKind.MP3, "voice.mp3").mimeType,
        )
        assertEquals(
            C07EntryRefusal.CONTENT_MISMATCH,
            C07ContentSniffer.reconcile("audio/mpeg", C07ProbeKind.JPEG, "voice.mp3").refusal,
        )
        assertEquals(
            "video/mp4",
            C07ContentSniffer.reconcile("video/mp4", C07ProbeKind.ISO_BMFF, "clip.mp4").mimeType,
        )
        assertEquals(
            "video/quicktime",
            C07ContentSniffer.reconcile("video/quicktime", C07ProbeKind.ISO_BMFF, "clip.mov").mimeType,
        )
        assertEquals(
            C07EntryContentClass.CAD,
            C07ContentSniffer.reconcile("model/gltf-binary", C07ProbeKind.GLB, "scene.glb").contentClass,
        )
        assertEquals(
            C07EntryRefusal.CONTENT_MISMATCH,
            C07ContentSniffer.reconcile("model/gltf-binary", C07ProbeKind.TEXT, "scene.glb").refusal,
        )
        // CAD is extension-routed: unrecognized bytes stay opaque data with no
        // invented preview, but the real pinned reader still owns the format.
        val dxf = C07ContentSniffer.reconcile("application/octet-stream", C07ProbeKind.UNKNOWN, "plan.dxf")
        assertEquals("application/dxf", dxf.mimeType)
        assertEquals(C07EntryContentClass.CAD, dxf.contentClass)
        assertNull(dxf.refusal)
        // A recognized container with an unrelated name is opaque DATA.
        val opaque = C07ContentSniffer.reconcile("application/octet-stream", C07ProbeKind.ISO_BMFF, "clip.bin")
        assertEquals(C07EntryContentClass.DATA, opaque.contentClass)
        assertEquals("application/octet-stream", opaque.mimeType)
        assertEquals(
            C07EntryContentClass.SOURCE,
            C07ContentSniffer.reconcile("text/x-python", C07ProbeKind.TEXT, "tool.py").contentClass,
        )
        assertEquals(
            C07EntryRefusal.CONTENT_MISMATCH,
            C07ContentSniffer.reconcile("text/x-python", C07ProbeKind.ISO_BMFF, "tool.py").refusal,
        )
    }

    @Test
    fun packageReconciliationRequiresTheArchiveFamily() {
        val note = C07ContentSniffer.reconcile("application/zip", C07ProbeKind.ZIP, "Story.floenote")
        assertEquals(C07EntryPackageKind.NOTE, note.packageKind)
        assertEquals(C07EntryContentClass.PACKAGE, note.contentClass)
        assertEquals(
            C07EntryRefusal.CONTENT_MISMATCH,
            C07ContentSniffer.reconcile("application/zip", C07ProbeKind.TEXT, "Story.floenote").refusal,
        )
        val cad = C07ContentSniffer.reconcile("application/octet-stream", C07ProbeKind.UNKNOWN, "Model.floecad")
        assertEquals(C07EntryPackageKind.CAD, cad.packageKind)
        assertNull(cad.refusal)
    }

    @Test
    fun packageDestinationsAreGatedByRealWiringNotByFormatSupport() {
        assertEquals(
            EntryReviewAvailability.NOT_APPLICABLE,
            C07EntryDestinationGate.review(C07EntryPackageKind.NONE, true, true),
        )
        assertEquals(
            EntryReviewAvailability.MISSING_OWNER,
            C07EntryDestinationGate.review(C07EntryPackageKind.NOTE, false, true),
        )
        assertEquals(
            EntryReviewAvailability.DIRECTORY_UNAVAILABLE,
            C07EntryDestinationGate.review(C07EntryPackageKind.CAD, true, false),
        )
        assertEquals(
            EntryReviewAvailability.AVAILABLE,
            C07EntryDestinationGate.review(C07EntryPackageKind.CAD, true, true),
        )
        assertEquals(
            EntryReviewAvailability.AVAILABLE,
            C07EntryDestinationGate.review(C07EntryPackageKind.BACKUP, true, false),
        )
        // Task/Notes are never offered for a package.
        assertFalse(C07EntryDestinationGate.offersTask(true, C07EntryPackageKind.NOTE))
        assertFalse(C07EntryDestinationGate.offersNotes(true, C07EntryPackageKind.NOTE))
        assertTrue(C07EntryDestinationGate.offersTask(true, C07EntryPackageKind.NONE))
        assertTrue(C07EntryDestinationGate.offersNotes(true, C07EntryPackageKind.NONE))
    }

    @Test
    fun boundedCopyBudgetRefusesAboveCapOnly() {
        val exact = C07EntryByteBudget(ENTRY_MAX_TOTAL_BYTES)
        exact.consume(ENTRY_MAX_TOTAL_BYTES)
        val overflow = C07EntryByteBudget(ENTRY_MAX_TOTAL_BYTES)
        val failure = runCatching { overflow.consume(ENTRY_MAX_TOTAL_BYTES + 1) }.exceptionOrNull()
        assertTrue(failure is C07EntryImportException)
        assertEquals(C07EntryRefusal.TOO_LARGE, (failure as C07EntryImportException).refusal)
        val negative = runCatching { overflow.consume(-1) }.exceptionOrNull()
        assertEquals(C07EntryRefusal.TOO_LARGE, (negative as C07EntryImportException).refusal)

        assertEquals(
            C07EntryRefusal.UNREADABLE,
            (C07SharePolicy.validate(
                listOf(file("video/mp4", "clip.mp4", -2)),
            ) as C07ShareValidation.Refused).code,
        )
        // Unknown size stays honest at admission and is enforced while copying.
        assertTrue(
            C07SharePolicy.validate(listOf(file("video/mp4", "clip.mp4", -1))) is
                C07ShareValidation.Accepted,
        )
    }

    @Test
    fun failedIntakeOnlySuppressesRedeliveryInsideTheWindow() {
        val fingerprint = "c".repeat(64)
        val now = 5_000_000L
        val failed = C07JournalRecord(
            fingerprint = fingerprint,
            intakeID = "11111111-1111-1111-1111-111111111111",
            status = C07EntryJournalStatus.FAILED,
            updatedAt = now,
            expiresAt = now + ENTRY_DEDUP_WINDOW_MS,
        )
        assertTrue(C07EntryDedup.blocks(failed, fingerprint, null, now + 1))
        assertFalse(C07EntryDedup.blocks(failed, fingerprint, null, failed.expiresAt))
        // A changed payload is a genuinely new entry, never blocked by content
        // dedup guessing; the explicit retry surface stays usable.
        assertFalse(C07EntryDedup.blocks(failed, "d".repeat(64), null, now + 1))
        assertFalse(
            C07EntryDedup.blocks(
                failed.copy(status = C07EntryJournalStatus.ADMITTED),
                fingerprint,
                null,
                now + 1,
            ),
        )
        assertTrue(
            C07EntryDedup.blocks(
                failed.copy(status = C07EntryJournalStatus.ADMITTED),
                fingerprint,
                failed.intakeID,
                now + 1,
            ),
        )
    }

    @Test
    fun capturedItemNeverExposesUriTextOrGrantState() {
        val item = file("image/heic", "photo.heic", 12)
        val rendered = item.toString()
        assertFalse(rendered.contains("content://"))
        assertFalse(rendered.contains("photo.heic"))
        assertFalse(rendered.contains("grant"))
        assertNotNull(C07SharePolicy.formatFor("image/heic", "photo.heic"))
    }
}
