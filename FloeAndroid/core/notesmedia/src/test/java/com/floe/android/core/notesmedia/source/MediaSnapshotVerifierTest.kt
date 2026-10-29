// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.source

import com.floe.android.core.notesmedia.media.MediaEditability
import com.floe.android.core.notesmedia.media.MediaResourceDescriptor
import com.floe.android.core.notesmedia.media.NotesMediaType
import com.floe.android.core.notesmedia.media.Sha256
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.nio.file.Files

class MediaSnapshotVerifierTest {

    @get:Rule
    val tmp = TemporaryFolder()

    @Test
    fun verifiesRegularFileWithRealDigest() {
        val bytes = "a real pdf-ish payload".toByteArray()
        val file = tmp.newFile("source.bin").apply { writeBytes(bytes) }
        val result = MediaSnapshotVerifier.verify(file, NotesMediaType.PDF, "source.pdf")
        assertTrue(result is SnapshotResult.Verified)
        val snapshot = (result as SnapshotResult.Verified).snapshot
        assertEquals(Sha256.hex(bytes), snapshot.sha256)
        assertEquals(bytes.size.toLong(), snapshot.byteCount)
        assertTrue(VerifiedMediaSnapshot.officeShapeAgrees(snapshot))
        assertEquals(file.absoluteFile, snapshot.file)
    }

    @Test
    fun descriptorMismatchIsRefused() {
        val bytes = "tampered".toByteArray()
        val file = tmp.newFile("ink.bin").apply { writeBytes(bytes) }
        val descriptor = MediaResourceDescriptor(
            resourceId = "doc-1",
            mediaType = NotesMediaType.FLOE_INK,
            formatVersion = 1,
            byteCount = bytes.size.toLong(),
            sha256 = "0".repeat(64),
            editable = MediaEditability.EDITABLE,
        )
        val result = MediaSnapshotVerifier.verifyDescriptor(file, descriptor)
        assertEquals(SnapshotRefusal.IDENTITY_MISMATCH, (result as SnapshotResult.Refused).reason)
    }

    @Test
    fun emptyFileIsRefused() {
        val file = tmp.newFile("empty.bin")
        assertEquals(
            SnapshotRefusal.EMPTY,
            (MediaSnapshotVerifier.verify(file, NotesMediaType.PDF) as SnapshotResult.Refused).reason,
        )
    }

    @Test
    fun symbolicLinkIsRefused() {
        val target = tmp.newFile("target.bin").apply { writeBytes(byteArrayOf(1, 2, 3)) }
        val link = tmp.root.toPath().resolve("link.bin")
        Files.createSymbolicLink(link, target.toPath())
        assertEquals(
            SnapshotRefusal.SYMLINK,
            (MediaSnapshotVerifier.verify(link.toFile(), NotesMediaType.PDF) as SnapshotResult.Refused).reason,
        )
    }

    @Test
    fun cancellationIsRefusedWithoutPublishingSnapshot() {
        val file = tmp.newFile("cancel.bin").apply { writeBytes(ByteArray(4096) { 1 }) }
        val result = MediaSnapshotVerifier.verify(file, NotesMediaType.PDF) { true }
        assertEquals(SnapshotRefusal.CANCELLED, (result as SnapshotResult.Refused).reason)
    }
}
