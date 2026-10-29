// SPDX-License-Identifier: MPL-2.0
package com.floe.android.notesplatform

import com.floe.android.feature.notes.NotesEdit
import com.floe.android.feature.notes.ui.presentation.NotesPendingRecovery
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NotesDurableRecoveryStoreTest {

    private fun tempDir(): File = Files.createTempDirectory("notes-recovery-test").toFile().also {
        it.deleteOnExit()
    }

    private fun recovery(documentID: String, createdAt: Long = 10L) = NotesPendingRecovery(
        documentID = documentID,
        documentKind = "notebook",
        documentTitle = "Title",
        baseRevision = 3,
        requestTitle = "edit",
        edits = listOf(NotesEdit.Rename("name"), NotesEdit.Favorite(true)),
        reasonCode = "conflict",
        createdAt = createdAt,
        requestID = "request-1",
        inkDrafts = mapOf("page-1" to byteArrayOf(1, 2, 3)),
    )

    @Test
    fun putIsDurableAndVisibleAfterReopen() = runBlocking {
        val root = tempDir()
        val store = DurableNotesRecoveryStore.open(root, Dispatchers.IO)
        store.put(recovery("doc-1"))
        store.put(recovery("doc-2", createdAt = 20L))
        assertEquals(2, root.listFiles()!!.count { it.name.endsWith(".recovery") })
        store.close()

        val reopened = DurableNotesRecoveryStore.open(root, Dispatchers.IO)
        val pending = reopened.pending()
        assertEquals(listOf("doc-1", "doc-2"), pending.map { it.documentID })
        assertEquals("request-1", pending[0].requestID)
        assertTrue(pending[0].inkDrafts["page-1"]!!.contentEquals(byteArrayOf(1, 2, 3)))
        reopened.close()
    }

    @Test
    fun removeAndClearDeleteOnlyTheirRecords() = runBlocking {
        val root = tempDir()
        val store = DurableNotesRecoveryStore.open(root, Dispatchers.IO)
        store.put(recovery("doc-1"))
        store.put(recovery("doc-2", createdAt = 20L))
        store.remove("doc-1")
        assertEquals(listOf("doc-2"), store.pending().map { it.documentID })
        store.clear()
        assertTrue(store.pending().isEmpty())
        assertFalse(root.listFiles().orEmpty().any { it.name.endsWith(".recovery") })
        store.close()
    }

    @Test
    fun corruptAndUnknownFilesArePreservedAndReported() = runBlocking {
        val root = tempDir()
        val store = DurableNotesRecoveryStore.open(root, Dispatchers.IO)
        store.put(recovery("doc-1"))
        store.close()

        val corrupt = File(root, "corrupt.recovery")
        corrupt.writeBytes(byteArrayOf(1, 2, 3))
        val unknown = File(root, "unknown.recovery")
        val encoded = NotesRecoveryCodec.encode(recovery("doc-2"))
        val patched = encoded.copyOf()
        javanio(patched, 99)
        unknown.writeBytes(patched)

        val reopened = DurableNotesRecoveryStore.open(root, Dispatchers.IO)
        assertEquals(listOf("doc-1"), reopened.pending().map { it.documentID })
        assertEquals(2, reopened.unreadable().size)
        assertTrue(reopened.unreadable().any { it.reason == "unknownVersion" && it.version == 99 })
        assertTrue(corrupt.isFile)
        assertTrue(unknown.isFile)
        reopened.close()
    }

    @Test
    fun documentIdIsNeverUsedAsAPath() = runBlocking {
        val root = tempDir()
        val store = DurableNotesRecoveryStore.open(root, Dispatchers.IO)
        store.put(recovery("../../escape"))
        val files = root.listFiles().orEmpty()
        assertEquals(1, files.size)
        assertTrue(files[0].name.endsWith(".recovery"))
        assertFalse(files[0].name.contains(".."))
        assertFalse(File(root.parentFile, "escape.recovery").exists())
        store.close()
    }

    @Test
    fun aFailedDurableCommitKeepsTheLiveRecordAndStore() = runBlocking {
        val root = tempDir()
        val store = DurableNotesRecoveryStore.open(root, Dispatchers.IO)
        store.put(recovery("doc-1"))
        val recordFile = root.listFiles()!!.single { it.name.endsWith(".recovery") }
        val beforeBytes = recordFile.readBytes()
        assertTrue("test needs a non-writable directory", root.setWritable(false, false))
        try {
            val failure = runCatching {
                store.put(recovery("doc-1", createdAt = 99L))
            }.exceptionOrNull()
            assertTrue(failure is NotesRecoveryStorageException)
            assertEquals(10L, store.pending().single().createdAt)
            assertTrue(recordFile.readBytes().contentEquals(beforeBytes))
        } finally {
            root.setWritable(true, false)
        }
        // The store remains live and can commit once storage is healthy again.
        store.put(recovery("doc-1", createdAt = 101L))
        assertEquals(101L, store.pending().single().createdAt)
        store.close()
    }

    @Test
    fun aCommitFailureIsTypedAndNeverReplacesTheExistingRecord() = runBlocking {
        val root = tempDir()
        val store = DurableNotesRecoveryStore.open(root, Dispatchers.IO)
        store.put(recovery("doc-1"))
        // A closed store refuses new commits with a typed storage failure.
        store.close()
        val failure = runCatching { store.put(recovery("doc-1", createdAt = 99L)) }.exceptionOrNull()
        assertTrue(failure is NotesRecoveryStorageException)
        val reopened = DurableNotesRecoveryStore.open(root, Dispatchers.IO)
        assertEquals(10L, reopened.pending().single().createdAt)
        reopened.close()
    }

    private fun javanio(bytes: ByteArray, version: Int) {
        java.nio.ByteBuffer.wrap(bytes, 8, 4).order(java.nio.ByteOrder.BIG_ENDIAN).putInt(version)
    }
}
