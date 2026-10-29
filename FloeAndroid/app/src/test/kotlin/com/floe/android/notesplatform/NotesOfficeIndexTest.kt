// SPDX-License-Identifier: MPL-2.0
package com.floe.android.notesplatform

import com.floe.android.feature.notes.NoteResourceChunk
import com.floe.android.feature.notes.NoteResourceRecord
import com.floe.android.feature.notes.NotesIndexCacheReceipt
import com.floe.android.feature.notes.NotesIndexCacheStatus
import com.floe.android.feature.notes.NotesOfficeTextRequest
import com.floe.android.feature.notes.NotesOfficeTextState
import com.floe.android.feature.notes.NotesService
import com.floe.android.feature.notes.ui.api.NotesOfficeIndexOutcome
import com.floe.android.host.noteschattransfer.FakeNotesServiceBase
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.file.Files
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Office full-text indexing tests.
 *
 * The extractor is exercised through the REAL bounded package/XML readers and
 * normalizers used by the Office verifier. The indexer is exercised against a
 * fake `NotesService` that mirrors the native cache contract: the cache write
 * only lands for the document's CURRENT `officeResourceID` and the observed
 * revision, and a mismatch answers `stale` without writing.
 */
class NotesOfficeIndexTest {

    private fun tempFile(bytes: ByteArray, suffix: String = ".docx"): File {
        val file = Files.createTempFile("notes-office-index", suffix).toFile()
        file.deleteOnExit()
        file.writeBytes(bytes)
        return file
    }

    private fun zip(entries: Map<String, ByteArray>): ByteArray {
        val output = ByteArrayOutputStream()
        ZipOutputStream(output).use { stream ->
            entries.forEach { (name, bytes) ->
                val entry = ZipEntry(name)
                entry.time = 315532800000L
                stream.putNextEntry(entry)
                stream.write(bytes)
                stream.closeEntry()
            }
        }
        return output.toByteArray()
    }

    private fun unzip(bytes: ByteArray): LinkedHashMap<String, ByteArray> {
        val output = LinkedHashMap<String, ByteArray>()
        ZipInputStream(ByteArrayInputStream(bytes)).use { stream ->
            var entry = stream.nextEntry
            while (entry != null) {
                output[entry.name] = stream.readBytes()
                entry = stream.nextEntry
            }
        }
        return output
    }

    private fun rewrite(
        bytes: ByteArray,
        replacements: Map<String, ByteArray>,
    ): ByteArray {
        val entries = unzip(bytes)
        replacements.forEach { (name, value) -> entries[name] = value }
        return zip(entries)
    }

    /* ------------------------------ extraction ----------------------------- */

    @Test
    fun docxBodyTextIsExtracted() {
        val bytes = NotesOoxmlTemplates.create(NotesOoxmlKind.DOCX, "Quarterly plan \u4f60\u597d")
        val extraction = NotesOfficeIndex.extract(tempFile(bytes), NotesOfficeIndexFormat.DOCX)
        assertTrue("unexpected $extraction", extraction is NotesOfficeExtraction.Text)
        extraction as NotesOfficeExtraction.Text
        assertTrue(extraction.text.contains("Quarterly plan \u4f60\u597d"))
        assertFalse(extraction.truncated)
    }

    @Test
    fun xlsxCellsPreserveValuesAndFormulaSource() {
        val template = NotesOoxmlTemplates.create(NotesOoxmlKind.XLSX, "Budget")
        val sheet = (
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" +
                "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">" +
                "<sheetData>" +
                "<row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>Revenue</t></is></c>" +
                "<c r=\"B1\"><f>SUM(B2:B3)</f><v>42</v></c></row>" +
                "</sheetData></worksheet>"
            ).toByteArray()
        val bytes = rewrite(template, mapOf("xl/worksheets/sheet1.xml" to sheet))
        val extraction = NotesOfficeIndex.extract(tempFile(bytes, ".xlsx"), NotesOfficeIndexFormat.XLSX)
        assertTrue("unexpected $extraction", extraction is NotesOfficeExtraction.Text)
        extraction as NotesOfficeExtraction.Text
        assertTrue(extraction.text, extraction.text.contains("Revenue"))
        assertTrue(extraction.text, extraction.text.contains("B1 = SUM(B2:B3)"))
        assertTrue(extraction.text, extraction.text.contains("42"))
    }

    @Test
    fun pptxSlideTextIsExtracted() {
        val bytes = NotesOoxmlTemplates.create(NotesOoxmlKind.PPTX, "Kickoff deck")
        val extraction = NotesOfficeIndex.extract(tempFile(bytes, ".pptx"), NotesOfficeIndexFormat.PPTX)
        assertTrue("unexpected $extraction", extraction is NotesOfficeExtraction.Text)
        extraction as NotesOfficeExtraction.Text
        assertTrue(extraction.text, extraction.text.contains("Kickoff deck"))
    }

    @Test
    fun malformedContainerIsRefusedNotTreatedAsEmpty() {
        val extraction = NotesOfficeIndex.extract(
            tempFile(byteArrayOf(1, 2, 3, 4, 5), ".docx"),
            NotesOfficeIndexFormat.DOCX,
        )
        assertTrue("unexpected $extraction", extraction is NotesOfficeExtraction.Refused)
        assertEquals("zipMalformed", (extraction as NotesOfficeExtraction.Refused).code)
        assertFalse(extraction.unsupported)
    }

    @Test
    fun doctypeAndEntitiesAreRefused() {
        val template = NotesOoxmlTemplates.create(NotesOoxmlKind.DOCX, "Safe title")
        val hostile = (
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" +
                "<!DOCTYPE w:document [<!ENTITY xxe SYSTEM \"file:///etc/passwd\">]>" +
                "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">" +
                "<w:body><w:p><w:r><w:t>&xxe;</w:t></w:r></w:p></w:body></w:document>"
            ).toByteArray()
        val bytes = rewrite(template, mapOf("word/document.xml" to hostile))
        val extraction = NotesOfficeIndex.extract(tempFile(bytes), NotesOfficeIndexFormat.DOCX)
        assertTrue("unexpected $extraction", extraction is NotesOfficeExtraction.Refused)
        assertEquals("xmlUntrusted", (extraction as NotesOfficeExtraction.Refused).code)
    }

    @Test
    fun entryCountBoundIsEnforced() {
        val entries = LinkedHashMap<String, ByteArray>()
        repeat(NotesOoxmlTemplates.MAX_ENTRIES + 2_100) { index ->
            entries["part-$index.xml"] = ByteArray(1)
        }
        val raw = zip(entries)
        val extraction = NotesOfficeIndex.extract(tempFile(raw), NotesOfficeIndexFormat.DOCX)
        assertTrue("unexpected $extraction", extraction is NotesOfficeExtraction.Refused)
        assertEquals("zipTooManyEntries", (extraction as NotesOfficeExtraction.Refused).code)
    }

    @Test
    fun legacyBinaryAndUnknownFormatsAreNeverClaimed() {
        assertNull(NotesOfficeIndex.formatFor("old.doc", "application/msword"))
        assertNull(NotesOfficeIndex.formatFor("data.bin", "application/octet-stream"))
        assertTrue(NotesOfficeIndex.isLegacyBinary("old.xls"))
        assertEquals(NotesOfficeIndexFormat.DOCX, NotesOfficeIndex.formatFor("a.docx", null))
        assertEquals(
            NotesOfficeIndexFormat.XLSX,
            NotesOfficeIndex.formatFor("noext", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
        )
    }

    /* -------------------------------- indexer ------------------------------ */

    private class FakeNotesService : FakeNotesServiceBase() {
        val documents = ConcurrentHashMap<String, NoteDocumentState>()
        val resources = ConcurrentHashMap<String, ByteArray>()
        val cachedText = ConcurrentHashMap<String, String>()
        val cachedError = ConcurrentHashMap<String, String>()
        val readCalls = AtomicInteger(0)
        val cacheWrites = AtomicInteger(0)
        val sizeOverrides = ConcurrentHashMap<String, Long>()
        private val names = ConcurrentHashMap<String, Pair<String, String>>()

        class NoteDocumentState(
            @Volatile var officeResourceID: String,
            @Volatile var revision: Int,
            @Volatile var officeTextResourceID: String? = null,
        )

        fun addResource(id: String, bytes: ByteArray, fileName: String, mediaType: String) {
            resources[id] = bytes
            names[id] = fileName to mediaType
        }

        override suspend fun resourceMetadata(resourceID: String): NoteResourceRecord {
            val bytes = resources[resourceID] ?: throw IllegalStateException("missing resource")
            val (fileName, mediaType) = names[resourceID] ?: ("file.bin" to "application/octet-stream")
            return NoteResourceRecord(
                id = resourceID,
                hash = "0".repeat(64),
                byteCount = sizeOverrides[resourceID] ?: bytes.size.toLong(),
                fileName = fileName,
                mediaType = mediaType,
            )
        }

        override suspend fun readResource(
            resourceID: String,
            offset: Long,
            maxBytes: Int,
        ): NoteResourceChunk {
            readCalls.incrementAndGet()
            val bytes = resources[resourceID] ?: throw IllegalStateException("missing resource")
            val start = offset.toInt().coerceAtLeast(0)
            val max = maxBytes.coerceAtLeast(1)
            val end = minOf(bytes.size, start + max)
            val data = if (start >= bytes.size) ByteArray(0) else bytes.copyOfRange(start, end)
            return NoteResourceChunk(
                resourceID = resourceID,
                offset = offset,
                nextOffset = start.toLong() + data.size,
                totalBytes = bytes.size.toLong(),
                eof = start + data.size >= bytes.size,
                data = data,
            )
        }

        override suspend fun officeTextState(documentID: String): NotesOfficeTextState {
            val document = documents.getValue(documentID)
            val current = document.officeTextResourceID == document.officeResourceID &&
                cachedText.containsKey(document.officeResourceID)
            return NotesOfficeTextState(
                documentID = documentID,
                revision = document.revision,
                current = current,
                retryable = !current,
                sourceResourceID = document.officeResourceID,
                sourceKey = document.officeResourceID,
                cachedResourceID = document.officeTextResourceID,
                textLength = document.officeTextResourceID?.let { cachedText[it]?.length },
                error = document.officeTextResourceID?.let { cachedError[it] },
            )
        }

        override suspend fun cacheOfficeText(request: NotesOfficeTextRequest): NotesIndexCacheReceipt {
            cacheWrites.incrementAndGet()
            val document = documents.getValue(request.documentID)
            val source = request.sourceResourceID
            if (request.expectedRevision != null && request.expectedRevision != document.revision) {
                return receipt(NotesIndexCacheStatus.STALE, request, document, "revisionMismatch", false)
            }
            if (document.officeResourceID != source) {
                return receipt(NotesIndexCacheStatus.STALE, request, document, "sourceChanged", false)
            }
            val text = request.text
            val error = request.error
            if (text != null) cachedText[source] = text
            if (error != null) cachedError[source] = error else cachedError.remove(source)
            document.officeTextResourceID = source
            return receipt(
                NotesIndexCacheStatus.APPLIED, request, document, null, text != null,
            )
        }

        override suspend fun close() = Unit

        private fun receipt(
            status: NotesIndexCacheStatus,
            request: NotesOfficeTextRequest,
            document: NoteDocumentState,
            reason: String?,
            indexed: Boolean,
        ) = NotesIndexCacheReceipt(
            status = status,
            documentID = request.documentID,
            documentRevision = document.revision,
            sourceKey = request.sourceResourceID,
            indexed = indexed,
            retryable = false,
            currentKey = document.officeResourceID,
            storedKey = document.officeTextResourceID,
            textLength = request.text?.length ?: cachedText[request.sourceResourceID]?.length,
            error = request.error ?: cachedError[request.sourceResourceID],
            reason = reason,
        )
    }

    private fun workRoot(): File = Files.createTempDirectory("notes-office-index-work").toFile().also {
        it.deleteOnExit()
    }

    @Test
    fun indexerWritesTheExtractedTextForTheExactResource() = runBlocking {
        val fake = FakeNotesService()
        val bytes = NotesOoxmlTemplates.create(NotesOoxmlKind.DOCX, "Indexed title")
        fake.addResource(
            "res-1", bytes, "report.docx",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        )
        fake.documents["doc-1"] = FakeNotesService.NoteDocumentState("res-1", revision = 3)
        val root = workRoot()
        val indexer = NotesOfficeIndexer(fake, root)

        val outcome = indexer.index("doc-1", "res-1", 3)
        assertTrue("unexpected $outcome", outcome is NotesOfficeIndexOutcome.Indexed)
        outcome as NotesOfficeIndexOutcome.Indexed
        assertEquals(3, outcome.revision)
        assertTrue(outcome.textLength > 0)
        assertFalse(outcome.truncated)
        assertTrue(fake.cachedText.getValue("res-1").contains("Indexed title"))
        assertTrue(fake.readCalls.get() > 0)
        // The index work file is gone; only the empty work directory remains.
        assertEquals(0, File(root, "index").listFiles().orEmpty().size)
    }

    @Test
    fun currentCacheIsReusedWithoutReadingTheResource() = runBlocking {
        val fake = FakeNotesService()
        val bytes = NotesOoxmlTemplates.create(NotesOoxmlKind.DOCX, "Already indexed")
        fake.addResource("res-1", bytes, "report.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        fake.documents["doc-1"] = FakeNotesService.NoteDocumentState("res-1", revision = 2)
        fake.cachedText["res-1"] = "Already indexed"
        fake.documents.getValue("doc-1").officeTextResourceID = "res-1"
        val indexer = NotesOfficeIndexer(fake, workRoot())

        val outcome = indexer.index("doc-1", "res-1", 2)
        assertTrue("unexpected $outcome", outcome is NotesOfficeIndexOutcome.UpToDate)
        assertEquals(0, fake.readCalls.get())
        assertEquals(0, fake.cacheWrites.get())
    }

    @Test
    fun oldSourceIsNeverLabelledAsTheNewBody() = runBlocking {
        val fake = FakeNotesService()
        val oldBytes = NotesOoxmlTemplates.create(NotesOoxmlKind.DOCX, "Old body")
        fake.addResource("res-old", oldBytes, "report.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        // The note has already been replaced with res-new while extraction of
        // the old bytes was still running.
        fake.documents["doc-1"] = FakeNotesService.NoteDocumentState("res-new", revision = 5)
        val indexer = NotesOfficeIndexer(fake, workRoot())

        val outcome = indexer.index("doc-1", "res-old", 4)
        assertTrue("unexpected $outcome", outcome is NotesOfficeIndexOutcome.Stale)
        assertNull(fake.cachedText["res-new"])
        assertNull(fake.cachedText["res-old"])
        assertFalse(outcome.indexed)
    }

    @Test
    fun malformedPackageIsRecordedAsATypedFailureNotEmptySuccess() = runBlocking {
        val fake = FakeNotesService()
        fake.addResource("res-1", byteArrayOf(9, 9, 9), "broken.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        fake.documents["doc-1"] = FakeNotesService.NoteDocumentState("res-1", revision = 1)
        val indexer = NotesOfficeIndexer(fake, workRoot())

        val outcome = indexer.index("doc-1", "res-1", 1)
        assertTrue("unexpected $outcome", outcome is NotesOfficeIndexOutcome.Failed)
        outcome as NotesOfficeIndexOutcome.Failed
        assertEquals("zipMalformed", outcome.failure.detail)
        assertFalse(outcome.retryable)
        assertNull(fake.cachedText["res-1"])
        assertEquals("zipMalformed", fake.cachedError["res-1"])
    }

    @Test
    fun recordedRefusalIsReusedWithoutReadingTheResourceAgain() = runBlocking {
        val fake = FakeNotesService()
        fake.addResource("res-1", byteArrayOf(7, 7), "broken.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        fake.documents["doc-1"] = FakeNotesService.NoteDocumentState("res-1", revision = 1)
        val indexer = NotesOfficeIndexer(fake, workRoot())
        val first = indexer.index("doc-1", "res-1", 1)
        assertTrue(first is NotesOfficeIndexOutcome.Failed)
        val readsAfterFirst = fake.readCalls.get()
        val writesAfterFirst = fake.cacheWrites.get()
        val second = indexer.index("doc-1", "res-1", 1)
        assertTrue("unexpected $second", second is NotesOfficeIndexOutcome.Failed)
        assertEquals("zipMalformed", (second as NotesOfficeIndexOutcome.Failed).failure.detail)
        assertEquals(readsAfterFirst, fake.readCalls.get())
        assertEquals(writesAfterFirst, fake.cacheWrites.get())
    }

    @Test
    fun legacyBinaryResourceIsReportedUnsupportedWithoutACacheText() = runBlocking {
        val fake = FakeNotesService()
        fake.addResource("res-1", byteArrayOf(1, 2, 3), "legacy.doc", "application/msword")
        fake.documents["doc-1"] = FakeNotesService.NoteDocumentState("res-1", revision = 1)
        val indexer = NotesOfficeIndexer(fake, workRoot())

        val outcome = indexer.index("doc-1", "res-1", 1)
        assertTrue("unexpected $outcome", outcome is NotesOfficeIndexOutcome.Unsupported)
        assertEquals("legacyBinaryFormat", (outcome as NotesOfficeIndexOutcome.Unsupported).reason)
        assertNull(fake.cachedText["res-1"])
        assertNotNull(fake.cachedError["res-1"])
    }

    @Test
    fun resourceLargerThanTheIndexCapIsRefusedHonestly() = runBlocking {
        val fake = FakeNotesService()
        fake.addResource(
            "res-1", ByteArray(16), "huge.docx",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        )
        fake.sizeOverrides["res-1"] = NotesOfficeIndex.MAX_RESOURCE_BYTES + 1
        fake.documents["doc-1"] = FakeNotesService.NoteDocumentState("res-1", revision = 1)
        val indexer = NotesOfficeIndexer(fake, workRoot())

        val outcome = indexer.index("doc-1", "res-1", 1)
        assertTrue("unexpected $outcome", outcome is NotesOfficeIndexOutcome.Failed)
        assertEquals("resourceTooLarge", (outcome as NotesOfficeIndexOutcome.Failed).failure.detail)
        assertFalse(outcome.retryable)
        assertEquals(0, fake.readCalls.get())
        assertNull(fake.cachedText["res-1"])
        assertEquals("resourceTooLarge", fake.cachedError["res-1"])
    }
}
