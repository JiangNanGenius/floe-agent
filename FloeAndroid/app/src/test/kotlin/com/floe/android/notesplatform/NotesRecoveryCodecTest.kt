// SPDX-License-Identifier: MPL-2.0
package com.floe.android.notesplatform

import com.floe.android.feature.notes.MindMapAttachment
import com.floe.android.feature.notes.MindMapAttachmentKind
import com.floe.android.feature.notes.MindMapConnection
import com.floe.android.feature.notes.MindMapConnectionOffset
import com.floe.android.feature.notes.MindMapNode
import com.floe.android.feature.notes.MindMapPoint
import com.floe.android.feature.notes.MindMapSummary
import com.floe.android.feature.notes.NoteElement
import com.floe.android.feature.notes.NoteElementKind
import com.floe.android.feature.notes.NoteMindMapLink
import com.floe.android.feature.notes.NotePage
import com.floe.android.feature.notes.NotePaper
import com.floe.android.feature.notes.NoteRect
import com.floe.android.feature.notes.NoteSourceReference
import com.floe.android.feature.notes.NoteSourceSpace
import com.floe.android.feature.notes.NoteTextSlice
import com.floe.android.feature.notes.NotesEdit
import com.floe.android.feature.notes.ui.presentation.NotesPendingRecovery
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NotesRecoveryCodecTest {

    private val source = NoteSourceReference(
        space = NoteSourceSpace.CANVAS,
        documentID = "source-doc",
        revision = 7,
        pageID = "source-page",
        region = NoteRect(1.0, 2.0, 30.0, 40.0),
        recordingSeconds = 12.5,
    )

    private val element = NoteElement(
        id = "element-1",
        kind = NoteElementKind.TEXT,
        frame = NoteRect(10.0, 20.0, 200.0, 80.0),
        text = "Hello notes",
        resourceID = "resource-1",
        color = "#112233",
        fontSize = 18.0,
        textFormat = "markdown",
        textSourceID = "text-source-1",
        textSlice = NoteTextSlice(0, 5, 11),
        source = source,
        isAIGenerated = true,
    )

    private val page = NotePage(
        id = "page-1",
        width = 768.0,
        height = 1024.0,
        paper = NotePaper.GRID,
        backgroundResourceID = "background-1",
        pdfPageIndex = 3,
        drawingResourceID = "drawing-1",
        elements = listOf(element),
        isBookmarked = true,
        extractedText = "extracted",
        ocrText = "ocr",
        ocrSourceKey = "opaque-native-key",
        ocrError = null,
        textExtractionTruncated = true,
    )

    private val node = MindMapNode(
        id = "node-1",
        parentID = "node-0",
        title = "Root",
        note = "note",
        order = 2,
        isCollapsed = true,
        color = "#445566",
        imageResourceID = "image-1",
        attachments = listOf(
            MindMapAttachment(
                id = "att-1",
                resourceID = "resource-att",
                fileName = "file.pdf",
                mediaType = "application/pdf",
                kind = MindMapAttachmentKind.DOCUMENT,
                caption = "cap",
                source = source,
            ),
        ),
        style = mapOf("bold" to "true"),
        tags = listOf("a", "b"),
        icons = listOf("star"),
        direction = 1,
        branchColor = "#778899",
        hyperLink = "https://example.invalid",
        isAIGenerated = false,
        source = source,
        position = MindMapPoint(1.25, -3.5),
    )

    private val connection = MindMapConnection(
        id = "conn-1",
        from = "node-1",
        to = "node-2",
        title = "edge",
        delta1 = MindMapConnectionOffset(1.0, 2.0),
        delta2 = MindMapConnectionOffset(3.0, 4.0),
        bidirectional = true,
        style = mapOf("width" to "2"),
    )

    private val summary = MindMapSummary(
        id = "summary-1",
        label = "group",
        parent = "node-1",
        start = 0,
        end = 4,
        style = mapOf("color" to "#000000"),
    )

    private fun allEdits(): List<NotesEdit> = listOf(
        NotesEdit.Rename("Renamed"),
        NotesEdit.MoveToNotebook("notebook-1"),
        NotesEdit.MoveToNotebook(null),
        NotesEdit.Favorite(true),
        NotesEdit.Tags(listOf("tag1", "tag2")),
        NotesEdit.TextSource("text-source-1", "source body"),
        NotesEdit.TextSource("text-source-2", null),
        NotesEdit.InsertPage(page, 0),
        NotesEdit.UpdatePage(page),
        NotesEdit.MovePage("page-1", 4),
        NotesEdit.DuplicatePage("page-1"),
        NotesEdit.DeletePage("page-2"),
        NotesEdit.Drawing("page-1", "drawing-1"),
        NotesEdit.Drawing("page-1", null),
        NotesEdit.UpsertElement("page-1", element),
        NotesEdit.DeleteElements("page-1", listOf("a", "b")),
        NotesEdit.UpsertNode(node),
        NotesEdit.DeleteBranch("node-1"),
        NotesEdit.UpsertConnection(connection),
        NotesEdit.DeleteConnection("conn-1"),
        NotesEdit.ReplaceMindMap(listOf(node), listOf(connection)),
        NotesEdit.LinkMindMap(NoteMindMapLink("link-1", "doc-2", "page-9")),
        NotesEdit.UnlinkMindMap("link-1"),
        NotesEdit.ReplaceOfficeResource("office-resource"),
        NotesEdit.MindMapLayout(2, listOf(summary)),
    )

    private fun record(): NotesPendingRecovery = NotesPendingRecovery(
        documentID = "doc-1",
        documentKind = "notebook",
        documentTitle = "Title",
        baseRevision = 9,
        requestTitle = "Pending edit",
        edits = allEdits(),
        reasonCode = "conflict",
        createdAt = 1_700_000_000_123L,
        requestID = "request-1",
        inkDrafts = mapOf(
            "page-1" to byteArrayOf(1, 2, 3, 4),
            "page-2" to ByteArray(0),
        ),
    )

    @Test
    fun roundTripsTheCompleteClosedVocabulary() {
        val bytes = NotesRecoveryCodec.encode(record())
        val decoded = NotesRecoveryCodec.decode(bytes)
        assertTrue(decoded is NotesRecoveryDecodeResult.Ok)
        val value = (decoded as NotesRecoveryDecodeResult.Ok).record
        // ByteArray values compare by reference in data-class equality; compare
        // every non-ink field structurally, then the ink bytes by content.
        assertEquals(record().copy(inkDrafts = emptyMap()), value.copy(inkDrafts = emptyMap()))
        assertEquals(record().inkDrafts.keys, value.inkDrafts.keys)
        assertTrue(value.inkDrafts["page-1"]!!.contentEquals(byteArrayOf(1, 2, 3, 4)))
        assertTrue(value.inkDrafts["page-2"]!!.isEmpty())
    }

    @Test
    fun refusesACorruptDigestAndKeepsTheOpaqueReason() {
        val bytes = NotesRecoveryCodec.encode(record())
        bytes[bytes.size - 1] = (bytes[bytes.size - 1].toInt() xor 0xff).toByte()
        val decoded = NotesRecoveryCodec.decode(bytes)
        assertEquals("digestMismatch", (decoded as NotesRecoveryDecodeResult.Corrupt).reason)
    }

    @Test
    fun reportsAnUnknownVersionWithoutDecoding() {
        val bytes = NotesRecoveryCodec.encode(record())
        val patched = bytes.copyOf()
        ByteBuffer.wrap(patched, 8, 4).order(ByteOrder.BIG_ENDIAN).putInt(99)
        val decoded = NotesRecoveryCodec.decode(patched)
        assertEquals(99, (decoded as NotesRecoveryDecodeResult.UnknownVersion).version)
    }

    @Test
    fun refusesTruncatedOrTrailingPayloads() {
        val bytes = NotesRecoveryCodec.encode(record())
        assertTrue(NotesRecoveryCodec.decode(bytes.copyOf(bytes.size - 5)) is NotesRecoveryDecodeResult.Corrupt)
        assertTrue(NotesRecoveryCodec.decode(ByteArray(0)) is NotesRecoveryDecodeResult.Corrupt)
        val extended = bytes + byteArrayOf(9)
        assertTrue(NotesRecoveryCodec.decode(extended) is NotesRecoveryDecodeResult.Corrupt)
    }

    @Test
    fun refusesAnInvalidModelWithoutThrowing() {
        val bytes = NotesRecoveryCodec.encode(
            record().copy(edits = listOf(NotesEdit.Tags(emptyList()))),
        )
        // Corrupt the record payload digest-preserving by re-encoding a valid
        // but semantically invalid edit is not possible here; instead cut the
        // body at the last byte (digest mismatch is caught earlier). This test
        // proves that a genuinely shape-valid payload with an invalid model
        // returns Corrupt: an empty document id is rejected after decode.
        val blank = record().copy(documentID = "")
        val blankBytes = NotesRecoveryCodec.encode(blank)
        val decoded = NotesRecoveryCodec.decode(blankBytes)
        assertTrue(decoded is NotesRecoveryDecodeResult.Corrupt)
        assertTrue(bytes.isNotEmpty())
    }

    @Test
    fun boundsInkDraftBytes() {
        val huge = NotesPendingRecovery(
            documentID = "doc-2",
            documentKind = "notebook",
            documentTitle = "T",
            baseRevision = 0,
            requestTitle = "t",
            edits = listOf(NotesEdit.Rename("x")),
            reasonCode = "timeout",
            createdAt = 1L,
            inkDrafts = mapOf("p" to ByteArray((NotesRecoveryCodec.MAX_INK_BYTES + 1).toInt())),
        )
        val failure = runCatching { NotesRecoveryCodec.encode(huge) }.exceptionOrNull()
        assertTrue(failure is IllegalArgumentException)
    }
}
