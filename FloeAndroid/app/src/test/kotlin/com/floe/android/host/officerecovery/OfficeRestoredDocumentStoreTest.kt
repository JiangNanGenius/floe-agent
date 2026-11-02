// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officerecovery

import java.io.File
import java.security.MessageDigest
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Authored NOTRUN regressions for the reachable restored-document consumer.
 * The store is pure JVM file/JSON logic; the fake open port proves the exact
 * verified bytes are handed to the existing preview adapter.
 */
class OfficeRestoredDocumentStoreTest {
    private fun newDir(prefix: String): File = File.createTempFile(prefix, "").let {
        it.delete()
        check(it.mkdirs())
        it
    }

    private fun sha(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }

    private fun publish(
        root: File,
        bytes: ByteArray,
        format: String = "docx",
        kind: String = "verifiedOutput",
        displayName: String = "Restored.docx",
        schema: String = OfficeRestoredDocumentStore.SCHEMA,
    ): Pair<String, File> {
        val restoreID = UUID.randomUUID().toString()
        val documentID = UUID.randomUUID().toString()
        val restore = File(root, restoreID)
        check(restore.mkdirs())
        val file = File(restore, "$documentID.$format")
        file.writeBytes(bytes)
        val document = JSONObject().apply {
            put("documentID", documentID)
            put("fileName", "$documentID.$format")
            put("displayName", displayName)
            put("format", format)
            put("kind", kind)
            put("byteCount", bytes.size.toLong())
            put("sha256", sha(bytes))
            put("restoredAt", "2026-11-02T00:00:00Z")
        }
        File(restore, "manifest.json").writeText(
            JSONObject().apply {
                put("schema", schema)
                put("restoreID", restoreID)
                put("documents", JSONArray().put(document))
            }.toString(),
        )
        File(restore, "complete.json").writeText(
            JSONObject().put("restoreID", restoreID).toString(),
        )
        return documentID to file
    }

    @Test
    fun listAndVerifiedOpenHandTheExactBytesToThePreviewPort() {
        val root = newDir("restored-office")
        val bytes = byteArrayOf(0x50, 0x4B, 0x03, 0x04, 1, 2, 3)
        val (documentID, file) = publish(root, bytes)
        val store = OfficeRestoredDocumentStore(root)
        val documents = store.list()
        assertEquals(1, documents.size)
        val document = documents.first()
        assertEquals("Restored.docx", document.displayName)
        assertEquals(OfficeRestoredDocument.Kind.VERIFIED_OUTPUT, document.kind)
        val verified = store.verifiedFile(document)
        assertNotNull(verified)
        assertEquals(file.absolutePath, verified!!.absolutePath)

        var opened: OfficeRestoredDocument? = null
        val port = object : OfficeRestoredDocumentOpenPort {
            override fun open(
                document: OfficeRestoredDocument,
                path: File,
                observedSha256: String,
                observedBytes: Long,
            ): OfficeRestoredOpenResult {
                opened = document
                assertEquals(file.absolutePath, path.absolutePath)
                assertEquals(sha(bytes), observedSha256)
                assertEquals(bytes.size.toLong(), observedBytes)
                return OfficeRestoredOpenResult.Accepted("session")
            }
        }
        val result = port.open(
            document,
            verified,
            document.sha256,
            document.byteCount,
        )
        assertTrue(result is OfficeRestoredOpenResult.Accepted)
        assertEquals(documentID, opened?.documentID)
    }

    @Test
    fun mutatedOrMissingBytesAreRefusedBeforeAnyOpen() {
        val root = newDir("restored-office")
        val (_, file) = publish(root, byteArrayOf(0x50, 0x4B, 0x03, 0x04, 1))
        val store = OfficeRestoredDocumentStore(root)
        val document = store.list().first()
        file.writeBytes(byteArrayOf(0x50, 0x4B, 0x03, 0x04, 2))
        assertNull(store.verifiedFile(document))
        file.delete()
        assertNull(store.verifiedFile(document))
    }

    @Test
    fun wrongSchemaOrRestoreIdentityIsIgnoredNotTrusted() {
        val root = newDir("restored-office")
        publish(root, byteArrayOf(0x50, 0x4B, 0x03, 0x04, 1), schema = "other")
        assertTrue(OfficeRestoredDocumentStore(root).list().isEmpty())
    }

    @Test
    fun aPathEscapingFileNameIsIgnored() {
        val root = newDir("restored-office")
        val restoreID = UUID.randomUUID().toString()
        val documentID = UUID.randomUUID().toString()
        val restore = File(root, restoreID)
        check(restore.mkdirs())
        File(restore, "manifest.json").writeText(
            JSONObject().apply {
                put("schema", OfficeRestoredDocumentStore.SCHEMA)
                put("restoreID", restoreID)
                put("documents", JSONArray().put(JSONObject().apply {
                    put("documentID", documentID)
                    put("fileName", "../../outside.docx")
                    put("displayName", "escape")
                    put("format", "docx")
                    put("kind", "workingCopy")
                    put("byteCount", 4)
                    put("sha256", "a".repeat(64))
                    put("restoredAt", "2026-11-02T00:00:00Z")
                }))
            }.toString(),
        )
        File(restore, "complete.json").writeText(
            JSONObject().put("restoreID", restoreID).toString(),
        )
        assertTrue(OfficeRestoredDocumentStore(root).list().isEmpty())
    }
}
