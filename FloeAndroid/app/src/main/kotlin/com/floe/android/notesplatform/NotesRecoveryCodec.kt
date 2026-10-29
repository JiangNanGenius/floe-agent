// SPDX-License-Identifier: MPL-2.0
package com.floe.android.notesplatform

import com.floe.android.feature.notes.MindMapAttachment
import com.floe.android.feature.notes.MindMapAttachmentKind
import com.floe.android.feature.notes.MindMapConnection
import com.floe.android.feature.notes.MindMapConnectionOffset
import com.floe.android.feature.notes.MindMapNode
import com.floe.android.feature.notes.MindMapPoint
import com.floe.android.feature.notes.MindMapSummary
import com.floe.android.feature.notes.NoteDocumentKind
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
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.security.MessageDigest

/**
 * Closed, versioned binary codec for one durable unsaved-edit record.
 *
 * Why a separate codec instead of the native Notes wire:
 *  - this record must be readable after process death and before any native
 *    runtime epoch is accepted, so it cannot depend on JNI or a Notes store;
 *  - the payload is the CLOSED `NotesEdit` vocabulary plus page-keyed ink
 *    bytes, never a free-form map, JSON blob or reflection graph;
 *  - an unknown version / bad digest / invalid model is reported as a typed
 *    refusal and the original file stays untouched for recovery.
 *
 * Layout: 8-byte magic, i32 version, i32 payload length, payload, SHA-256 of
 * the payload. All strings are UTF-8 with an i32 byte length. Every list and
 * string has a hard bound so a corrupt length can never trigger a huge
 * allocation.
 */
internal sealed class NotesRecoveryDecodeResult {
    data class Ok(val record: NotesPendingRecovery) : NotesRecoveryDecodeResult()
    data class Corrupt(val reason: String) : NotesRecoveryDecodeResult()
    data class UnknownVersion(val version: Int) : NotesRecoveryDecodeResult()
}

internal object NotesRecoveryCodec {
    const val MAGIC = "FLOEREC1"
    const val VERSION = 1
    const val MAX_RECORD_BYTES = 64L * 1024 * 1024
    const val MAX_EDITS = 10_000
    const val MAX_INK_DRAFTS = 2_000
    const val MAX_INK_BYTES = 48L * 1024 * 1024
    private const val HEADER_BYTES = 16
    private const val DIGEST_BYTES = 32
    private const val MAX_STRING_BYTES = 4 * 1024 * 1024
    private const val MAX_LIST = 20_000

    fun encode(record: NotesPendingRecovery): ByteArray {
        val payload = ByteArrayOutputStream()
        DataOutputStream(payload).use { out ->
            out.writeUTF8(record.documentID, MAX_STRING_BYTES)
            out.writeUTF8(record.documentKind, MAX_STRING_BYTES)
            out.writeUTF8(record.documentTitle, MAX_STRING_BYTES)
            out.writeInt(record.baseRevision)
            out.writeUTF8(record.requestTitle, MAX_STRING_BYTES)
            out.writeI32Count(record.edits.size, MAX_EDITS)
            record.edits.forEach { out.writeEdit(it) }
            out.writeUTF8(record.reasonCode, MAX_STRING_BYTES)
            out.writeLong(record.createdAt)
            out.writeNullableString(record.requestID)
            out.writeI32Count(record.inkDrafts.size, MAX_INK_DRAFTS)
            var inkBytes = 0L
            record.inkDrafts.forEach { (pageID, bytes) ->
                inkBytes += bytes.size.toLong()
                if (inkBytes > MAX_INK_BYTES) throw IllegalArgumentException("inkDraftsTooLarge")
                out.writeUTF8(pageID, MAX_STRING_BYTES)
                out.writeI32Count(bytes.size, MAX_INK_BYTES.toInt())
                out.write(bytes)
            }
        }
        val body = payload.toByteArray()
        val total = HEADER_BYTES + body.size.toLong() + DIGEST_BYTES
        if (total > MAX_RECORD_BYTES) throw IllegalArgumentException("recordTooLarge")
        val output = ByteArrayOutputStream(total.toInt())
        DataOutputStream(output).use { out ->
            out.write(MAGIC.toByteArray(Charsets.US_ASCII))
            out.writeInt(VERSION)
            out.writeInt(body.size)
            out.write(body)
            out.write(MessageDigest.getInstance("SHA-256").digest(body))
        }
        return output.toByteArray()
    }

    fun decode(bytes: ByteArray): NotesRecoveryDecodeResult {
        if (bytes.size < HEADER_BYTES + DIGEST_BYTES) return NotesRecoveryDecodeResult.Corrupt("truncated")
        if (bytes.size.toLong() > MAX_RECORD_BYTES) return NotesRecoveryDecodeResult.Corrupt("tooLarge")
        val magic = String(bytes, 0, 8, Charsets.US_ASCII)
        if (magic != MAGIC) return NotesRecoveryDecodeResult.Corrupt("badMagic")
        val input = DataInputStream(ByteArrayInputStream(bytes))
        input.readFully(ByteArray(8))
        val version = input.readInt()
        if (version != VERSION) return NotesRecoveryDecodeResult.UnknownVersion(version)
        val length = input.readInt()
        if (length <= 0 || length > bytes.size - HEADER_BYTES - DIGEST_BYTES) {
            return NotesRecoveryDecodeResult.Corrupt("badLength")
        }
        val body = ByteArray(length)
        input.readFully(body)
        val expected = ByteArray(DIGEST_BYTES)
        input.readFully(expected)
        if (input.available() != 0) return NotesRecoveryDecodeResult.Corrupt("trailingBytes")
        val actual = MessageDigest.getInstance("SHA-256").digest(body)
        if (!MessageDigest.isEqual(expected, actual)) return NotesRecoveryDecodeResult.Corrupt("digestMismatch")
        val reader = DataInputStream(ByteArrayInputStream(body))
        return try {
            val record = NotesPendingRecovery(
                documentID = reader.readUTF8(MAX_STRING_BYTES),
                documentKind = reader.readUTF8(MAX_STRING_BYTES),
                documentTitle = reader.readUTF8(MAX_STRING_BYTES),
                baseRevision = reader.readInt(),
                requestTitle = reader.readUTF8(MAX_STRING_BYTES),
                edits = reader.readList(MAX_EDITS) { reader.readEdit() },
                reasonCode = reader.readUTF8(MAX_STRING_BYTES),
                createdAt = reader.readLong(),
                requestID = reader.readNullableString(),
                inkDrafts = buildMap {
                    val count = reader.readBoundedCount(MAX_INK_DRAFTS)
                    var total = 0L
                    repeat(count) {
                        val pageID = reader.readUTF8(MAX_STRING_BYTES)
                        val size = reader.readBoundedCount(MAX_INK_BYTES.toInt())
                        total += size.toLong()
                        if (total > MAX_INK_BYTES) throw IllegalArgumentException("inkDraftsTooLarge")
                        val draft = ByteArray(size)
                        reader.readFully(draft)
                        put(pageID, draft)
                    }
                },
            )
            if (record.documentID.isBlank()) return NotesRecoveryDecodeResult.Corrupt("missingDocument")
            if (reader.available() != 0) return NotesRecoveryDecodeResult.Corrupt("trailingBytes")
            NotesRecoveryDecodeResult.Ok(record)
        } catch (_: IllegalArgumentException) {
            NotesRecoveryDecodeResult.Corrupt("invalidRecord")
        } catch (_: java.io.IOException) {
            NotesRecoveryDecodeResult.Corrupt("truncatedPayload")
        } catch (_: IndexOutOfBoundsException) {
            NotesRecoveryDecodeResult.Corrupt("truncatedPayload")
        }
    }

    /* ------------------------------- edits -------------------------------- */

    private fun DataOutputStream.writeEdit(edit: NotesEdit) {
        when (edit) {
            is NotesEdit.Rename -> {
                writeInt(ID_RENAME); writeUTF8(edit.text, MAX_STRING_BYTES)
            }
            is NotesEdit.MoveToNotebook -> {
                writeInt(ID_MOVE_NOTEBOOK); writeNullableString(edit.notebookID)
            }
            is NotesEdit.Favorite -> {
                writeInt(ID_FAVORITE); writeBoolean(edit.isFavorite)
            }
            is NotesEdit.Tags -> {
                writeInt(ID_TAGS); writeStringList(edit.tags)
            }
            is NotesEdit.TextSource -> {
                writeInt(ID_TEXT_SOURCE); writeUTF8(edit.id, MAX_STRING_BYTES); writeNullableString(edit.text)
            }
            is NotesEdit.InsertPage -> {
                writeInt(ID_INSERT_PAGE); writePage(edit.page); writeInt(edit.index)
            }
            is NotesEdit.UpdatePage -> {
                writeInt(ID_UPDATE_PAGE); writePage(edit.page)
            }
            is NotesEdit.MovePage -> {
                writeInt(ID_MOVE_PAGE); writeUTF8(edit.pageID, MAX_STRING_BYTES); writeInt(edit.index)
            }
            is NotesEdit.DuplicatePage -> {
                writeInt(ID_DUPLICATE_PAGE); writeUTF8(edit.pageID, MAX_STRING_BYTES)
            }
            is NotesEdit.DeletePage -> {
                writeInt(ID_DELETE_PAGE); writeUTF8(edit.pageID, MAX_STRING_BYTES)
            }
            is NotesEdit.Drawing -> {
                writeInt(ID_DRAWING); writeUTF8(edit.pageID, MAX_STRING_BYTES); writeNullableString(edit.resourceID)
            }
            is NotesEdit.UpsertElement -> {
                writeInt(ID_UPSERT_ELEMENT); writeUTF8(edit.pageID, MAX_STRING_BYTES); writeElement(edit.element)
            }
            is NotesEdit.DeleteElements -> {
                writeInt(ID_DELETE_ELEMENTS); writeUTF8(edit.pageID, MAX_STRING_BYTES); writeStringList(edit.ids)
            }
            is NotesEdit.UpsertNode -> {
                writeInt(ID_UPSERT_NODE); writeNode(edit.node)
            }
            is NotesEdit.DeleteBranch -> {
                writeInt(ID_DELETE_BRANCH); writeUTF8(edit.nodeID, MAX_STRING_BYTES)
            }
            is NotesEdit.UpsertConnection -> {
                writeInt(ID_UPSERT_CONNECTION); writeConnection(edit.connection)
            }
            is NotesEdit.DeleteConnection -> {
                writeInt(ID_DELETE_CONNECTION); writeUTF8(edit.connectionID, MAX_STRING_BYTES)
            }
            is NotesEdit.ReplaceMindMap -> {
                writeInt(ID_REPLACE_MIND_MAP)
                writeI32Count(edit.nodes.size, MAX_LIST)
                edit.nodes.forEach { writeNode(it) }
                writeI32Count(edit.connections.size, MAX_LIST)
                edit.connections.forEach { writeConnection(it) }
            }
            is NotesEdit.LinkMindMap -> {
                writeInt(ID_LINK_MIND_MAP); writeUTF8(edit.link.id, MAX_STRING_BYTES)
                writeUTF8(edit.link.documentID, MAX_STRING_BYTES); writeNullableString(edit.link.pageID)
            }
            is NotesEdit.UnlinkMindMap -> {
                writeInt(ID_UNLINK_MIND_MAP); writeUTF8(edit.linkID, MAX_STRING_BYTES)
            }
            is NotesEdit.ReplaceOfficeResource -> {
                writeInt(ID_REPLACE_OFFICE); writeUTF8(edit.resourceID, MAX_STRING_BYTES)
            }
            is NotesEdit.MindMapLayout -> {
                writeInt(ID_MIND_MAP_LAYOUT); writeInt(edit.direction)
                writeI32Count(edit.summaries.size, MAX_LIST)
                edit.summaries.forEach { writeSummary(it) }
            }
        }
    }

    private fun DataInputStream.readEdit(): NotesEdit = when (val id = readInt()) {
        ID_RENAME -> NotesEdit.Rename(readUTF8(MAX_STRING_BYTES))
        ID_MOVE_NOTEBOOK -> NotesEdit.MoveToNotebook(readNullableString())
        ID_FAVORITE -> NotesEdit.Favorite(readBooleanStrict())
        ID_TAGS -> NotesEdit.Tags(readStringList())
        ID_TEXT_SOURCE -> NotesEdit.TextSource(readUTF8(MAX_STRING_BYTES), readNullableString())
        ID_INSERT_PAGE -> NotesEdit.InsertPage(readPage(), readInt())
        ID_UPDATE_PAGE -> NotesEdit.UpdatePage(readPage())
        ID_MOVE_PAGE -> NotesEdit.MovePage(readUTF8(MAX_STRING_BYTES), readInt())
        ID_DUPLICATE_PAGE -> NotesEdit.DuplicatePage(readUTF8(MAX_STRING_BYTES))
        ID_DELETE_PAGE -> NotesEdit.DeletePage(readUTF8(MAX_STRING_BYTES))
        ID_DRAWING -> NotesEdit.Drawing(readUTF8(MAX_STRING_BYTES), readNullableString())
        ID_UPSERT_ELEMENT -> NotesEdit.UpsertElement(readUTF8(MAX_STRING_BYTES), readElement())
        ID_DELETE_ELEMENTS -> NotesEdit.DeleteElements(readUTF8(MAX_STRING_BYTES), readStringList())
        ID_UPSERT_NODE -> NotesEdit.UpsertNode(readNode())
        ID_DELETE_BRANCH -> NotesEdit.DeleteBranch(readUTF8(MAX_STRING_BYTES))
        ID_UPSERT_CONNECTION -> NotesEdit.UpsertConnection(readConnection())
        ID_DELETE_CONNECTION -> NotesEdit.DeleteConnection(readUTF8(MAX_STRING_BYTES))
        ID_REPLACE_MIND_MAP -> NotesEdit.ReplaceMindMap(
            nodes = readList(MAX_LIST) { readNode() },
            connections = readList(MAX_LIST) { readConnection() },
        )
        ID_LINK_MIND_MAP -> NotesEdit.LinkMindMap(
            NoteMindMapLink(
                id = readUTF8(MAX_STRING_BYTES),
                documentID = readUTF8(MAX_STRING_BYTES),
                pageID = readNullableString(),
            ),
        )
        ID_UNLINK_MIND_MAP -> NotesEdit.UnlinkMindMap(readUTF8(MAX_STRING_BYTES))
        ID_REPLACE_OFFICE -> NotesEdit.ReplaceOfficeResource(readUTF8(MAX_STRING_BYTES))
        ID_MIND_MAP_LAYOUT -> NotesEdit.MindMapLayout(
            direction = readInt(),
            summaries = readList(MAX_LIST) { readSummary() },
        )
        else -> throw IllegalArgumentException("unknownEdit:$id")
    }

    /* ------------------------------- models ------------------------------- */

    private fun DataOutputStream.writeRect(rect: NoteRect) {
        writeDouble(rect.x); writeDouble(rect.y); writeDouble(rect.width); writeDouble(rect.height)
    }

    private fun DataInputStream.readRect(): NoteRect = NoteRect(
        x = readDouble(), y = readDouble(), width = readDouble(), height = readDouble(),
    )

    private fun DataOutputStream.writeSlice(slice: NoteTextSlice) {
        writeInt(slice.start); writeInt(slice.count); writeInt(slice.total ?: -1)
    }

    private fun DataInputStream.readSlice(): NoteTextSlice {
        val start = readInt(); val count = readInt(); val total = readInt()
        return NoteTextSlice(start, count, total.takeIf { it >= 0 })
    }

    private fun DataOutputStream.writeSource(source: NoteSourceReference) {
        writeUTF8(source.space.wire, MAX_STRING_BYTES)
        writeUTF8(source.documentID, MAX_STRING_BYTES)
        writeInt(source.revision)
        writeNullableString(source.pageID)
        writeNullableString(source.nodeID)
        writeBoolean(source.region != null)
        source.region?.let { writeRect(it) }
        writeBoolean(source.recordingSeconds != null)
        source.recordingSeconds?.let { writeDouble(it) }
    }

    private fun DataInputStream.readSource(): NoteSourceReference {
        val space = NoteSourceSpace.fromWire(readUTF8(MAX_STRING_BYTES))
            ?: throw IllegalArgumentException("sourceSpace")
        val documentID = readUTF8(MAX_STRING_BYTES)
        val revision = readInt()
        val pageID = readNullableString()
        val nodeID = readNullableString()
        val region = if (readBooleanStrict()) readRect() else null
        val recording = if (readBooleanStrict()) readDouble() else null
        return NoteSourceReference(space, documentID, revision, pageID, nodeID, region, recording)
    }

    private fun DataOutputStream.writeElement(element: NoteElement) {
        writeUTF8(element.id, MAX_STRING_BYTES)
        writeUTF8(element.kind.wire, MAX_STRING_BYTES)
        writeRect(element.frame)
        writeUTF8(element.text, MAX_STRING_BYTES)
        writeNullableString(element.resourceID)
        writeUTF8(element.color, MAX_STRING_BYTES)
        writeDouble(element.fontSize)
        writeNullableString(element.textFormat)
        writeNullableString(element.textSourceID)
        writeBoolean(element.textSlice != null)
        element.textSlice?.let { writeSlice(it) }
        writeBoolean(element.source != null)
        element.source?.let { writeSource(it) }
        writeBoolean(element.isAIGenerated)
    }

    private fun DataInputStream.readElement(): NoteElement {
        val id = readUTF8(MAX_STRING_BYTES)
        val kind = NoteElementKind.fromWire(readUTF8(MAX_STRING_BYTES))
            ?: throw IllegalArgumentException("elementKind")
        val frame = readRect()
        val text = readUTF8(MAX_STRING_BYTES)
        val resourceID = readNullableString()
        val color = readUTF8(MAX_STRING_BYTES)
        val fontSize = readDouble()
        val textFormat = readNullableString()
        val textSourceID = readNullableString()
        val slice = if (readBooleanStrict()) readSlice() else null
        val source = if (readBooleanStrict()) readSource() else null
        val ai = readBooleanStrict()
        return NoteElement(id, kind, frame, text, resourceID, color, fontSize, textFormat,
            textSourceID, slice, source, ai)
    }

    private fun DataOutputStream.writePage(page: NotePage) {
        writeUTF8(page.id, MAX_STRING_BYTES)
        writeDouble(page.width); writeDouble(page.height)
        writeUTF8(page.paper.wire, MAX_STRING_BYTES)
        writeNullableString(page.backgroundResourceID)
        writeInt(page.pdfPageIndex ?: -1)
        writeNullableString(page.drawingResourceID)
        writeI32Count(page.elements.size, MAX_LIST)
        page.elements.forEach { writeElement(it) }
        writeBoolean(page.isBookmarked)
        writeNullableString(page.extractedText)
        writeNullableString(page.ocrText)
        writeNullableString(page.ocrSourceKey)
        writeNullableString(page.ocrError)
        writeInt(page.textExtractionTruncated?.let { if (it) 1 else 0 } ?: -1)
    }

    private fun DataInputStream.readPage(): NotePage {
        val id = readUTF8(MAX_STRING_BYTES)
        val width = readDouble(); val height = readDouble()
        val paper = NotePaper.fromWire(readUTF8(MAX_STRING_BYTES)) ?: throw IllegalArgumentException("paper")
        val background = readNullableString()
        val pdfIndex = readInt().takeIf { it >= 0 }
        val drawing = readNullableString()
        val elements = readList(MAX_LIST) { readElement() }
        val bookmarked = readBooleanStrict()
        val extracted = readNullableString()
        val ocrText = readNullableString()
        val ocrKey = readNullableString()
        val ocrError = readNullableString()
        val truncated = when (val value = readInt()) {
            1 -> true
            0 -> false
            -1 -> null
            else -> throw IllegalArgumentException("truncatedFlag")
        }
        return NotePage(id, width, height, paper, background, pdfIndex, drawing, elements,
            bookmarked, extracted, ocrText, ocrKey, ocrError, truncated)
    }

    private fun DataOutputStream.writeAttachment(attachment: MindMapAttachment) {
        writeUTF8(attachment.id, MAX_STRING_BYTES)
        writeUTF8(attachment.resourceID, MAX_STRING_BYTES)
        writeUTF8(attachment.fileName, MAX_STRING_BYTES)
        writeUTF8(attachment.mediaType, MAX_STRING_BYTES)
        writeUTF8(attachment.kind.wire, MAX_STRING_BYTES)
        writeUTF8(attachment.caption, MAX_STRING_BYTES)
        writeBoolean(attachment.source != null)
        attachment.source?.let { writeSource(it) }
    }

    private fun DataInputStream.readAttachment(): MindMapAttachment {
        val id = readUTF8(MAX_STRING_BYTES)
        val resourceID = readUTF8(MAX_STRING_BYTES)
        val fileName = readUTF8(MAX_STRING_BYTES)
        val mediaType = readUTF8(MAX_STRING_BYTES)
        val kind = MindMapAttachmentKind.fromWire(readUTF8(MAX_STRING_BYTES))
            ?: throw IllegalArgumentException("attachmentKind")
        val caption = readUTF8(MAX_STRING_BYTES)
        val source = if (readBooleanStrict()) readSource() else null
        return MindMapAttachment(id, resourceID, fileName, mediaType, kind, caption, source)
    }

    private fun DataOutputStream.writeNode(node: MindMapNode) {
        writeUTF8(node.id, MAX_STRING_BYTES)
        writeNullableString(node.parentID)
        writeUTF8(node.title, MAX_STRING_BYTES)
        writeUTF8(node.note, MAX_STRING_BYTES)
        writeInt(node.order)
        writeBoolean(node.isCollapsed)
        writeNullableString(node.color)
        writeNullableString(node.imageResourceID)
        writeBoolean(node.attachments != null)
        node.attachments?.let { list ->
            writeI32Count(list.size, MAX_LIST)
            list.forEach { writeAttachment(it) }
        }
        writeNullableStringMap(node.style)
        writeNullableStringList(node.tags)
        writeNullableStringList(node.icons)
        writeInt(node.direction ?: -1)
        writeNullableString(node.branchColor)
        writeNullableString(node.hyperLink)
        writeInt(node.isAIGenerated?.let { if (it) 1 else 0 } ?: -1)
        writeBoolean(node.source != null)
        node.source?.let { writeSource(it) }
        writeBoolean(node.position != null)
        node.position?.let { writeDouble(it.x); writeDouble(it.y) }
    }

    private fun DataInputStream.readNode(): MindMapNode {
        val id = readUTF8(MAX_STRING_BYTES)
        val parent = readNullableString()
        val title = readUTF8(MAX_STRING_BYTES)
        val note = readUTF8(MAX_STRING_BYTES)
        val order = readInt()
        val collapsed = readBooleanStrict()
        val color = readNullableString()
        val image = readNullableString()
        val attachments = if (readBooleanStrict()) readList(MAX_LIST) { readAttachment() } else null
        val style = readNullableStringMap()
        val tags = readNullableStringList()
        val icons = readNullableStringList()
        val direction = readInt().takeIf { it >= 0 }
        val branchColor = readNullableString()
        val hyperLink = readNullableString()
        val ai = when (val value = readInt()) {
            1 -> true
            0 -> false
            -1 -> null
            else -> throw IllegalArgumentException("aiFlag")
        }
        val source = if (readBooleanStrict()) readSource() else null
        val position = if (readBooleanStrict()) MindMapPoint(readDouble(), readDouble()) else null
        return MindMapNode(
            id = id, parentID = parent, title = title, note = note, order = order,
            isCollapsed = collapsed, color = color, imageResourceID = image,
            attachments = attachments, style = style, tags = tags, icons = icons,
            direction = direction, branchColor = branchColor, hyperLink = hyperLink,
            isAIGenerated = ai, source = source, position = position,
        )
    }

    private fun DataOutputStream.writeConnection(connection: MindMapConnection) {
        writeUTF8(connection.id, MAX_STRING_BYTES)
        writeUTF8(connection.from, MAX_STRING_BYTES)
        writeUTF8(connection.to, MAX_STRING_BYTES)
        writeUTF8(connection.title, MAX_STRING_BYTES)
        writeBoolean(connection.delta1 != null)
        connection.delta1?.let { writeDouble(it.x); writeDouble(it.y) }
        writeBoolean(connection.delta2 != null)
        connection.delta2?.let { writeDouble(it.x); writeDouble(it.y) }
        writeInt(connection.bidirectional?.let { if (it) 1 else 0 } ?: -1)
        writeNullableStringMap(connection.style)
    }

    private fun DataInputStream.readConnection(): MindMapConnection {
        val id = readUTF8(MAX_STRING_BYTES)
        val from = readUTF8(MAX_STRING_BYTES)
        val to = readUTF8(MAX_STRING_BYTES)
        val title = readUTF8(MAX_STRING_BYTES)
        val delta1 = if (readBooleanStrict()) MindMapConnectionOffset(readDouble(), readDouble()) else null
        val delta2 = if (readBooleanStrict()) MindMapConnectionOffset(readDouble(), readDouble()) else null
        val bidirectional = when (val value = readInt()) {
            1 -> true
            0 -> false
            -1 -> null
            else -> throw IllegalArgumentException("bidirectionalFlag")
        }
        val style = readNullableStringMap()
        return MindMapConnection(id, from, to, title, delta1, delta2, bidirectional, style)
    }

    private fun DataOutputStream.writeSummary(summary: MindMapSummary) {
        writeUTF8(summary.id, MAX_STRING_BYTES)
        writeUTF8(summary.label, MAX_STRING_BYTES)
        writeUTF8(summary.parent, MAX_STRING_BYTES)
        writeInt(summary.start); writeInt(summary.end)
        writeNullableStringMap(summary.style)
    }

    private fun DataInputStream.readSummary(): MindMapSummary {
        val id = readUTF8(MAX_STRING_BYTES)
        val label = readUTF8(MAX_STRING_BYTES)
        val parent = readUTF8(MAX_STRING_BYTES)
        val start = readInt(); val end = readInt()
        val style = readNullableStringMap()
        return MindMapSummary(id, label, parent, start, end, style)
    }

    /* ------------------------------- helpers ------------------------------ */

    private fun DataOutputStream.writeUTF8(value: String, maxBytes: Int) {
        val bytes = value.encodeToByteArray()
        if (bytes.size > maxBytes) throw IllegalArgumentException("stringTooLarge")
        writeInt(bytes.size)
        write(bytes)
    }

    private fun DataInputStream.readUTF8(maxBytes: Int): String {
        val size = readBoundedCount(maxBytes)
        val bytes = ByteArray(size)
        readFully(bytes)
        return bytes.decodeToString(throwOnInvalidSequence = true)
    }

    private fun DataOutputStream.writeNullableString(value: String?) {
        writeBoolean(value != null)
        value?.let { writeUTF8(it, MAX_STRING_BYTES) }
    }

    private fun DataInputStream.readNullableString(): String? =
        if (readBooleanStrict()) readUTF8(MAX_STRING_BYTES) else null

    private fun DataOutputStream.writeStringList(values: List<String>) {
        writeI32Count(values.size, MAX_LIST)
        values.forEach { writeUTF8(it, MAX_STRING_BYTES) }
    }

    private fun DataInputStream.readStringList(): List<String> = readList(MAX_LIST) { readUTF8(MAX_STRING_BYTES) }

    private fun DataOutputStream.writeNullableStringList(values: List<String>?) {
        writeBoolean(values != null)
        values?.let { writeStringList(it) }
    }

    private fun DataInputStream.readNullableStringList(): List<String>? =
        if (readBooleanStrict()) readStringList() else null

    private fun DataOutputStream.writeNullableStringMap(values: Map<String, String>?) {
        writeBoolean(values != null)
        if (values == null) return
        writeI32Count(values.size, MAX_LIST)
        values.forEach { (key, value) ->
            writeUTF8(key, MAX_STRING_BYTES)
            writeUTF8(value, MAX_STRING_BYTES)
        }
    }

    private fun DataInputStream.readNullableStringMap(): Map<String, String>? {
        if (!readBooleanStrict()) return null
        val count = readBoundedCount(MAX_LIST)
        val map = LinkedHashMap<String, String>(count)
        repeat(count) { map[readUTF8(MAX_STRING_BYTES)] = readUTF8(MAX_STRING_BYTES) }
        return map
    }

    private fun DataOutputStream.writeI32Count(count: Int, max: Int) {
        if (count < 0 || count > max) throw IllegalArgumentException("countOutOfRange")
        writeInt(count)
    }

    private fun DataInputStream.readBoundedCount(max: Int): Int {
        val count = readInt()
        if (count < 0 || count > max) throw IllegalArgumentException("countOutOfRange")
        return count
    }

    private fun <T> DataInputStream.readList(max: Int, readItem: () -> T): List<T> {
        val count = readBoundedCount(max)
        val list = ArrayList<T>(count)
        repeat(count) { list.add(readItem()) }
        return list
    }

    private fun DataInputStream.readBooleanStrict(): Boolean = when (val value = readUnsignedByte()) {
        0 -> false
        1 -> true
        else -> throw IllegalArgumentException("boolean")
    }

    private const val ID_RENAME = 1
    private const val ID_MOVE_NOTEBOOK = 2
    private const val ID_FAVORITE = 3
    private const val ID_TAGS = 4
    private const val ID_TEXT_SOURCE = 5
    private const val ID_INSERT_PAGE = 6
    private const val ID_UPDATE_PAGE = 7
    private const val ID_MOVE_PAGE = 8
    private const val ID_DUPLICATE_PAGE = 9
    private const val ID_DELETE_PAGE = 10
    private const val ID_DRAWING = 11
    private const val ID_UPSERT_ELEMENT = 12
    private const val ID_DELETE_ELEMENTS = 13
    private const val ID_UPSERT_NODE = 14
    private const val ID_DELETE_BRANCH = 15
    private const val ID_UPSERT_CONNECTION = 16
    private const val ID_DELETE_CONNECTION = 17
    private const val ID_REPLACE_MIND_MAP = 18
    private const val ID_LINK_MIND_MAP = 19
    private const val ID_UNLINK_MIND_MAP = 20
    private const val ID_REPLACE_OFFICE = 21
    private const val ID_MIND_MAP_LAYOUT = 22
}
