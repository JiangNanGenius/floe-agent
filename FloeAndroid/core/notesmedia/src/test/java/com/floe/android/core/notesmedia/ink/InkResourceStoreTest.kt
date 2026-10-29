// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.ink

import com.floe.android.core.notesmedia.media.InkEditRefusal
import com.floe.android.core.notesmedia.media.MediaEditability
import com.floe.android.core.notesmedia.media.NotesMediaType
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayOutputStream

class InkResourceStoreTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private fun snapshot(revision: Long = 1, input: Byte = 7): InkSnapshot {
        val stroke = InkStroke(
            id = 1,
            brush = InkBrushSpec.pen(0xFF112233.toInt(), 2f),
            inputs = byteArrayOf(input, 2, 3),
            bounds = InkBox(10f, 10f, 20f, 20f),
        )
        return InkSnapshot(
            documentId = "doc-a",
            geometry = InkPageGeometry("page-a", 400f, 600f),
            revision = revision,
            strokes = listOf(stroke),
        )
    }

    private fun store(): InkResourceStore = InkResourceStore(tmp.newFolder("resources"))

    @Test
    fun writeThenReadRoundTripsAndExposesDescriptor() {
        val store = store()
        val written = store.write(snapshot()) as InkWriteResult.Ok
        assertEquals(NotesMediaType.FLOE_INK, written.descriptor.mediaType)
        assertEquals(MediaEditability.EDITABLE, written.descriptor.editable)
        val read = store.readEditable("doc-a")
        assertTrue(read is InkReadResult.Editable)
        val editable = read as InkReadResult.Editable
        assertEquals(snapshot(), editable.snapshot)
        assertEquals(written.descriptor, editable.descriptor)
        assertEquals(null, editable.previewFile)
    }

    @Test
    fun secondWriteWithoutExpectedIdentityIsRefusedAndOriginalSurvives() {
        val store = store()
        val first = store.write(snapshot(revision = 1)) as InkWriteResult.Ok
        val refused = store.write(snapshot(revision = 2))
        assertEquals(InkStoreRefusal.ALREADY_EXISTS, (refused as InkWriteResult.Refused).refusal)
        assertEquals(first.descriptor, (store.readEditable("doc-a") as InkReadResult.Editable).descriptor)
    }

    @Test
    fun compareAndSwapRequiresTheExactCurrentDigest() {
        val store = store()
        val first = store.write(snapshot(revision = 1)) as InkWriteResult.Ok
        val wrong = store.write(snapshot(revision = 2), expectedExistingSha256 = "0".repeat(64))
        assertEquals(InkStoreRefusal.IDENTITY_MISMATCH, (wrong as InkWriteResult.Refused).refusal)
        val replaced = store.write(snapshot(revision = 2), expectedExistingSha256 = first.descriptor.sha256)
        assertTrue(replaced is InkWriteResult.Ok)
        assertEquals(2L, (store.readEditable("doc-a") as InkReadResult.Editable).snapshot.revision)
    }

    @Test
    fun tamperedBytesRefuseToOpen() {
        val store = store()
        val first = store.write(snapshot()) as InkWriteResult.Ok
        java.io.File(first.directory, InkResourceLayout.INK_FILE).writeBytes(byteArrayOf(1, 2, 3))
        val read = store.readEditable("doc-a")
        assertEquals(InkStoreRefusal.IDENTITY_MISMATCH, (read as InkReadResult.Refused).refusal)
    }

    @Test
    fun foreignInkIsPreservedVerbatimAndNeverEditable() {
        val store = store()
        val bytes = "PK-DRAWING-BYTES".toByteArray()
        val imported = store.importForeign("pencil-1", NotesMediaType.APPLE_PENCILKIT, bytes)
        assertTrue(imported is InkWriteResult.Ok)
        assertEquals(MediaEditability.PRESERVE_ONLY, (imported as InkWriteResult.Ok).descriptor.editable)
        val read = store.readForeign("pencil-1") as InkReadResult.Foreign
        assertTrue(read.resource.identityHolds())
        assertEquals(InkEditRefusal.FOREIGN_INK_FORMAT, read.resource.requestEdit())
        val out = ByteArrayOutputStream()
        read.resource.copyTo { out }
        assertArrayEquals(bytes, out.toByteArray())
        // The editable reader must refuse the foreign resource.
        assertEquals(InkStoreRefusal.NOT_EDITABLE, (store.readEditable("pencil-1") as InkReadResult.Refused).refusal)
        // Importing Floe ink through the foreign path is refused (no bypass).
        assertEquals(
            InkStoreRefusal.NOT_EDITABLE,
            (store.importForeign("ink-1", NotesMediaType.FLOE_INK, bytes) as InkWriteResult.Refused).refusal,
        )
    }

    @Test
    fun deleteRequiresTheExactDigest() {
        val store = store()
        val first = store.write(snapshot()) as InkWriteResult.Ok
        assertFalse(store.delete("doc-a", "0".repeat(64)))
        assertNotNull(store.readDescriptor("doc-a"))
        assertTrue(store.delete("doc-a", first.descriptor.sha256))
        assertEquals(InkStoreRefusal.NOT_FOUND, (store.readEditable("doc-a") as InkReadResult.Refused).refusal)
    }

    @Test
    fun invalidResourceIdCannotEscapeTheRoot() {
        val store = store()
        val root = tmp.root
        assertEquals(null, InkResourceLayout.directoryFor(root, "../../etc/passwd"))
        assertEquals(null, InkResourceLayout.directoryFor(root, "a/b"))
        assertEquals(
            InkStoreRefusal.INVALID_RESOURCE_ID,
            (store.readEditable("../../etc/passwd") as InkReadResult.Refused).refusal,
        )
    }
}
