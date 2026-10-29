// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.notes

import com.floe.android.feature.notes.ImportedResource
import com.floe.android.feature.notes.MindMapAttachment
import com.floe.android.feature.notes.MindMapAttachmentKind
import com.floe.android.feature.notes.MindMapConnection
import com.floe.android.feature.notes.MindMapConnectionOffset
import com.floe.android.feature.notes.MindMapNode
import com.floe.android.feature.notes.MindMapPoint
import com.floe.android.feature.notes.MindMapSummary
import com.floe.android.feature.notes.NoteCoverMode
import com.floe.android.feature.notes.NoteCoverState
import com.floe.android.feature.notes.NoteDocument
import com.floe.android.feature.notes.NoteDocumentKind
import com.floe.android.feature.notes.NoteDocumentSummary
import com.floe.android.feature.notes.NoteElement
import com.floe.android.feature.notes.NoteElementKind
import com.floe.android.feature.notes.NoteHistoryState
import com.floe.android.feature.notes.NoteMindMapLink
import com.floe.android.feature.notes.NotePage
import com.floe.android.feature.notes.NotePaper
import com.floe.android.feature.notes.NoteRect
import com.floe.android.feature.notes.NoteResourceRecord
import com.floe.android.feature.notes.NoteSourceReference
import com.floe.android.feature.notes.NoteSourceSpace
import com.floe.android.feature.notes.NoteTextSlice
import com.floe.android.feature.notes.Notebook
import com.floe.android.feature.notes.NotesArchiveChunk
import com.floe.android.feature.notes.NotesArchiveHandle
import com.floe.android.feature.notes.NotesCounts
import com.floe.android.feature.notes.NotesDocumentPage
import com.floe.android.feature.notes.NotesEvent
import com.floe.android.feature.notes.NotesEventBatch
import com.floe.android.feature.notes.NotesLibrarySummary
import com.floe.android.feature.notes.NotesProposalSummary
import com.floe.android.feature.notes.NotesEdit
import com.floe.android.feature.notes.NotesException
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

/**
 * Exact `floe.notes/4` JSON projection. It is intentionally hand-written:
 * the contract module stays dependency-free, and the native schema is the
 * closed wire vocabulary (no reflection-based field aliases).
 */
internal object NotesWireCodec {

    // MARK: - Request values

    fun request(
        operation: String,
        requestID: String,
        epoch: Long? = null,
        action: String? = null,
        payload: JsonObject? = null,
        cursor: Long? = null,
        limit: Int? = null,
    ): JsonObject = buildJsonObject {
        put("version", 4)
        put("operation", operation)
        put("requestID", requestID)
        if (epoch != null) put("epoch", epoch)
        if (action != null) put("action", action)
        if (payload != null) put("payload", payload)
        if (cursor != null) put("cursor", cursor)
        if (limit != null) put("limit", limit)
    }

    fun payload(vararg pairs: Pair<String, JsonElement?>): JsonObject = buildJsonObject {
        pairs.forEach { (key, value) -> if (value != null) put(key, value) else put(key, JsonNull) }
    }

    fun string(value: String): JsonElement = JsonPrimitive(value)
    fun number(value: Int): JsonElement = JsonPrimitive(value)
    fun number(value: Long): JsonElement = JsonPrimitive(value)
    fun number(value: Double): JsonElement = JsonPrimitive(value)
    fun bool(value: Boolean): JsonElement = JsonPrimitive(value)
    fun array(values: Iterable<JsonElement>): JsonArray = buildJsonArray { values.forEach { add(it) } }

    // MARK: - Edit encoding

    fun encodeEdits(edits: List<NotesEdit>): JsonArray = buildJsonArray {
        edits.forEach { edit -> add(encodeEdit(edit)) }
    }

    private fun encodeEdit(edit: NotesEdit): JsonObject = when (edit) {
        is NotesEdit.Rename -> buildJsonObject {
            put("action", "rename"); put("text", edit.text)
        }
        is NotesEdit.MoveToNotebook -> buildJsonObject {
            put("action", "moveToNotebook")
            put("notebookID", edit.notebookID?.let(::JsonPrimitive) ?: JsonNull)
        }
        is NotesEdit.Favorite -> buildJsonObject {
            put("action", "favorite"); put("isFavorite", edit.isFavorite)
        }
        is NotesEdit.Tags -> buildJsonObject {
            put("action", "tags"); putJsonArray("tags") { edit.tags.forEach { add(JsonPrimitive(it)) } }
        }
        is NotesEdit.TextSource -> buildJsonObject {
            put("action", "textSource"); put("id", edit.id)
            put("text", edit.text?.let(::JsonPrimitive) ?: JsonNull)
        }
        is NotesEdit.InsertPage -> buildJsonObject {
            put("action", "insertPage"); put("page", encodePage(edit.page)); put("index", edit.index)
        }
        is NotesEdit.UpdatePage -> buildJsonObject {
            put("action", "updatePage"); put("page", encodePage(edit.page))
        }
        is NotesEdit.MovePage -> buildJsonObject {
            put("action", "movePage"); put("pageID", edit.pageID); put("index", edit.index)
        }
        is NotesEdit.DuplicatePage -> buildJsonObject {
            put("action", "duplicatePage"); put("pageID", edit.pageID)
        }
        is NotesEdit.DeletePage -> buildJsonObject {
            put("action", "deletePage"); put("pageID", edit.pageID)
        }
        is NotesEdit.Drawing -> buildJsonObject {
            put("action", "drawing"); put("pageID", edit.pageID)
            put("resourceID", edit.resourceID?.let(::JsonPrimitive) ?: JsonNull)
        }
        is NotesEdit.UpsertElement -> buildJsonObject {
            put("action", "upsertElement"); put("pageID", edit.pageID)
            put("element", encodeElement(edit.element))
        }
        is NotesEdit.DeleteElements -> buildJsonObject {
            put("action", "deleteElements"); put("pageID", edit.pageID)
            putJsonArray("ids") { edit.ids.forEach { add(JsonPrimitive(it)) } }
        }
        is NotesEdit.UpsertNode -> buildJsonObject {
            put("action", "upsertNode"); put("node", encodeNode(edit.node))
        }
        is NotesEdit.DeleteBranch -> buildJsonObject {
            put("action", "deleteBranch"); put("nodeID", edit.nodeID)
        }
        is NotesEdit.UpsertConnection -> buildJsonObject {
            put("action", "upsertConnection"); put("connection", encodeConnection(edit.connection))
        }
        is NotesEdit.DeleteConnection -> buildJsonObject {
            put("action", "deleteConnection"); put("connectionID", edit.connectionID)
        }
        is NotesEdit.ReplaceMindMap -> buildJsonObject {
            put("action", "replaceMindMap")
            putJsonArray("nodes") { edit.nodes.forEach { add(encodeNode(it)) } }
            putJsonArray("connections") { edit.connections.forEach { add(encodeConnection(it)) } }
        }
        is NotesEdit.LinkMindMap -> buildJsonObject {
            put("action", "linkMindMap"); put("link", encodeLink(edit.link))
        }
        is NotesEdit.UnlinkMindMap -> buildJsonObject {
            put("action", "unlinkMindMap"); put("linkID", edit.linkID)
        }
        is NotesEdit.ReplaceOfficeResource -> buildJsonObject {
            put("action", "replaceOfficeResource"); put("resourceID", edit.resourceID)
        }
        is NotesEdit.MindMapLayout -> buildJsonObject {
            put("action", "mindMapLayout"); put("direction", edit.direction)
            putJsonArray("summaries") { edit.summaries.forEach { add(encodeSummary(it)) } }
        }
    }

    internal fun encodeRect(rect: NoteRect): JsonObject = buildJsonObject {
        put("x", rect.x); put("y", rect.y); put("width", rect.width); put("height", rect.height)
    }

    private fun encodeSlice(slice: NoteTextSlice): JsonObject = buildJsonObject {
        put("start", slice.start); put("count", slice.count)
        slice.total?.let { put("total", it) }
    }

    private fun encodeSource(source: NoteSourceReference): JsonObject = buildJsonObject {
        put("space", source.space.wire)
        put("documentID", source.documentID)
        put("revision", source.revision)
        source.pageID?.let { put("pageID", it) }
        source.nodeID?.let { put("nodeID", it) }
        source.region?.let { put("region", encodeRect(it)) }
        source.recordingSeconds?.let { put("recordingSeconds", it) }
    }

    private fun encodeElement(element: NoteElement): JsonObject = buildJsonObject {
        put("id", element.id)
        put("kind", element.kind.wire)
        put("frame", encodeRect(element.frame))
        put("text", element.text)
        element.resourceID?.let { put("resourceID", it) }
        put("color", element.color)
        put("fontSize", element.fontSize)
        element.textFormat?.let { put("textFormat", it) }
        element.textSourceID?.let { put("textSourceID", it) }
        element.textSlice?.let { put("textSlice", encodeSlice(it)) }
        element.source?.let { put("source", encodeSource(it)) }
        put("isAIGenerated", element.isAIGenerated)
    }

    private fun encodeAttachment(attachment: MindMapAttachment): JsonObject = buildJsonObject {
        put("id", attachment.id)
        put("resourceID", attachment.resourceID)
        put("fileName", attachment.fileName)
        put("mediaType", attachment.mediaType)
        put("kind", attachment.kind.wire)
        put("caption", attachment.caption)
        attachment.source?.let { put("source", encodeSource(it)) }
    }

    private fun encodePage(page: NotePage): JsonObject = buildJsonObject {
        put("id", page.id)
        put("width", page.width)
        put("height", page.height)
        put("paper", page.paper.wire)
        page.backgroundResourceID?.let { put("backgroundResourceID", it) }
        page.pdfPageIndex?.let { put("pdfPageIndex", it) }
        page.drawingResourceID?.let { put("drawingResourceID", it) }
        putJsonArray("elements") { page.elements.forEach { add(encodeElement(it)) } }
        put("isBookmarked", page.isBookmarked)
        page.extractedText?.let { put("extractedText", it) }
        page.ocrText?.let { put("ocrText", it) }
        page.ocrSourceKey?.let { put("ocrSourceKey", it) }
        page.ocrError?.let { put("ocrError", it) }
        page.textExtractionTruncated?.let { put("textExtractionTruncated", it) }
    }

    private fun encodeNode(node: MindMapNode): JsonObject = buildJsonObject {
        put("id", node.id)
        node.parentID?.let { put("parentID", it) }
        put("title", node.title)
        put("note", node.note)
        put("order", node.order)
        put("isCollapsed", node.isCollapsed)
        node.color?.let { put("color", it) }
        node.imageResourceID?.let { put("imageResourceID", it) }
        node.attachments?.let { values ->
            putJsonArray("attachments") { values.forEach { add(encodeAttachment(it)) } }
        }
        node.style?.let { values ->
            putJsonObject("style") { values.forEach { (key, value) -> put(key, value) } }
        }
        node.tags?.let { values -> putJsonArray("tags") { values.forEach { add(JsonPrimitive(it)) } } }
        node.icons?.let { values -> putJsonArray("icons") { values.forEach { add(JsonPrimitive(it)) } } }
        node.direction?.let { put("direction", it) }
        node.branchColor?.let { put("branchColor", it) }
        node.hyperLink?.let { put("hyperLink", it) }
        node.isAIGenerated?.let { put("isAIGenerated", it) }
        node.source?.let { put("source", encodeSource(it)) }
        node.position?.let {
            putJsonObject("position") { put("x", it.x); put("y", it.y) }
        }
    }

    private fun encodeConnection(connection: MindMapConnection): JsonObject = buildJsonObject {
        put("id", connection.id)
        put("from", connection.from)
        put("to", connection.to)
        put("title", connection.title)
        connection.delta1?.let { putJsonObject("delta1") { put("x", it.x); put("y", it.y) } }
        connection.delta2?.let { putJsonObject("delta2") { put("x", it.x); put("y", it.y) } }
        connection.bidirectional?.let { put("bidirectional", it) }
        connection.style?.let { values ->
            putJsonObject("style") { values.forEach { (key, value) -> put(key, value) } }
        }
    }

    private fun encodeSummary(summary: MindMapSummary): JsonObject = buildJsonObject {
        put("id", summary.id)
        put("label", summary.label)
        put("parent", summary.parent)
        put("start", summary.start)
        put("end", summary.end)
        summary.style?.let { values ->
            putJsonObject("style") { values.forEach { (key, value) -> put(key, value) } }
        }
    }

    private fun encodeLink(link: NoteMindMapLink): JsonObject = buildJsonObject {
        put("id", link.id)
        put("documentID", link.documentID)
        link.pageID?.let { put("pageID", it) }
    }

    // MARK: - Response decoding

    fun decodeDocument(element: JsonElement?): NoteDocument {
        val o = element as? JsonObject ?: fail("document")
        return NoteDocument(
            schemaVersion = o.int("schemaVersion") ?: 2,
            id = o.requiredString("id"),
            kind = NoteDocumentKind.fromWire(o.requiredString("kind")) ?: fail("document.kind"),
            notebookID = o.string("notebookID"),
            title = o.requiredString("title"),
            revision = o.int("revision") ?: fail("document.revision"),
            pages = o.array("pages")?.map { decodePage(it) }.orEmpty(),
            textSources = o.obj("textSources")?.let { source ->
                source.entries.associate { (key, value) -> key to (value as? JsonPrimitive)?.contentOrNull.orEmpty() }
            },
            nodes = o.array("nodes")?.map { decodeNode(it) }.orEmpty(),
            connections = o.array("connections")?.map { decodeConnection(it) }.orEmpty(),
            linkedMindMaps = o.array("linkedMindMaps")?.map { decodeLink(it) },
            mindMapDirection = o.int("mindMapDirection"),
            summaries = o.array("summaries")?.map { decodeMindMapSummary(it) },
            tags = o.strings("tags"),
            isFavorite = o.bool("isFavorite") ?: false,
            createdAt = o.double("createdAt") ?: 0.0,
            updatedAt = o.double("updatedAt") ?: 0.0,
            deletedAt = o.double("deletedAt"),
            officeResourceID = o.string("officeResourceID"),
            officeFileName = o.string("officeFileName"),
            officeTextResourceID = o.string("officeTextResourceID"),
            officeExtractedText = o.string("officeExtractedText"),
            officeTextError = o.string("officeTextError"),
            officePreviewSourceID = o.string("officePreviewSourceID"),
            officePreviewResourceID = o.string("officePreviewResourceID"),
            engineeringResourceID = o.string("engineeringResourceID"),
            engineeringFileName = o.string("engineeringFileName"),
            coverResourceID = o.string("coverResourceID"),
            coverRevision = o.int("coverRevision"),
        )
    }

    private fun decodePage(element: JsonElement): NotePage {
        val o = element as? JsonObject ?: fail("page")
        return NotePage(
            id = o.requiredString("id"),
            width = o.double("width") ?: 768.0,
            height = o.double("height") ?: 1024.0,
            paper = NotePaper.fromWire(o.string("paper") ?: "plain") ?: fail("page.paper"),
            backgroundResourceID = o.string("backgroundResourceID"),
            pdfPageIndex = o.int("pdfPageIndex"),
            drawingResourceID = o.string("drawingResourceID"),
            elements = o.array("elements")?.map { decodeElement(it) }.orEmpty(),
            isBookmarked = o.bool("isBookmarked") ?: false,
            extractedText = o.string("extractedText"),
            ocrText = o.string("ocrText"),
            ocrSourceKey = o.string("ocrSourceKey"),
            ocrError = o.string("ocrError"),
            textExtractionTruncated = o.bool("textExtractionTruncated"),
        )
    }

    private fun decodeElement(element: JsonElement): NoteElement {
        val o = element as? JsonObject ?: fail("element")
        return NoteElement(
            id = o.requiredString("id"),
            kind = NoteElementKind.fromWire(o.string("kind") ?: "text") ?: fail("element.kind"),
            frame = o.obj("frame")?.let { decodeRect(it) } ?: NoteRect(),
            text = o.string("text") ?: "",
            resourceID = o.string("resourceID"),
            color = o.string("color") ?: "#202020",
            fontSize = o.double("fontSize") ?: 20.0,
            textFormat = o.string("textFormat"),
            textSourceID = o.string("textSourceID"),
            textSlice = o.obj("textSlice")?.let { decodeSlice(it) },
            source = o.obj("source")?.let { decodeSource(it) },
            isAIGenerated = o.bool("isAIGenerated") ?: false,
        )
    }

    private fun decodeRect(o: JsonObject): NoteRect = NoteRect(
        x = o.double("x") ?: 0.0,
        y = o.double("y") ?: 0.0,
        width = o.double("width") ?: 240.0,
        height = o.double("height") ?: 120.0,
    )

    private fun decodeSlice(o: JsonObject): NoteTextSlice = NoteTextSlice(
        start = o.int("start") ?: fail("slice.start"),
        count = o.int("count") ?: fail("slice.count"),
        total = o.int("total"),
    )

    private fun decodeSource(o: JsonObject): NoteSourceReference = NoteSourceReference(
        space = NoteSourceSpace.fromWire(o.string("space") ?: "notes") ?: fail("source.space"),
        documentID = o.requiredString("documentID"),
        revision = o.int("revision") ?: fail("source.revision"),
        pageID = o.string("pageID"),
        nodeID = o.string("nodeID"),
        region = o.obj("region")?.let { decodeRect(it) },
        recordingSeconds = o.double("recordingSeconds"),
    )

    private fun decodeAttachment(o: JsonObject): MindMapAttachment = MindMapAttachment(
        id = o.requiredString("id"),
        resourceID = o.requiredString("resourceID"),
        fileName = o.requiredString("fileName"),
        mediaType = o.requiredString("mediaType"),
        kind = MindMapAttachmentKind.fromWire(o.string("kind") ?: "file") ?: fail("attachment.kind"),
        caption = o.string("caption") ?: "",
        source = o.obj("source")?.let { decodeSource(it) },
    )

    private fun decodeNode(element: JsonElement): MindMapNode {
        val o = element as? JsonObject ?: fail("node")
        return MindMapNode(
            id = o.requiredString("id"),
            parentID = o.string("parentID"),
            title = o.requiredString("title"),
            note = o.string("note") ?: "",
            order = o.int("order") ?: 0,
            isCollapsed = o.bool("isCollapsed") ?: false,
            color = o.string("color"),
            imageResourceID = o.string("imageResourceID"),
            attachments = o.array("attachments")?.map { decodeAttachment(it as? JsonObject ?: fail("attachment")) },
            style = o.stringMap("style"),
            tags = o.strings("tags"),
            icons = o.strings("icons"),
            direction = o.int("direction"),
            branchColor = o.string("branchColor"),
            hyperLink = o.string("hyperLink"),
            isAIGenerated = o.bool("isAIGenerated"),
            source = o.obj("source")?.let { decodeSource(it) },
            position = o.obj("position")?.let {
                MindMapPoint(it.double("x") ?: 0.0, it.double("y") ?: 0.0)
            },
        )
    }

    private fun decodeConnection(element: JsonElement): MindMapConnection {
        val o = element as? JsonObject ?: fail("connection")
        return MindMapConnection(
            id = o.requiredString("id"),
            from = o.requiredString("from"),
            to = o.requiredString("to"),
            title = o.string("title") ?: "",
            delta1 = o.obj("delta1")?.let {
                MindMapConnectionOffset(it.double("x") ?: 0.0, it.double("y") ?: 0.0)
            },
            delta2 = o.obj("delta2")?.let {
                MindMapConnectionOffset(it.double("x") ?: 0.0, it.double("y") ?: 0.0)
            },
            bidirectional = o.bool("bidirectional"),
            style = o.stringMap("style"),
        )
    }

    private fun decodeMindMapSummary(element: JsonElement): MindMapSummary {
        val o = element as? JsonObject ?: fail("summary")
        return MindMapSummary(
            id = o.requiredString("id"),
            label = o.requiredString("label"),
            parent = o.requiredString("parent"),
            start = o.int("start") ?: fail("summary.start"),
            end = o.int("end") ?: fail("summary.end"),
            style = o.stringMap("style"),
        )
    }

    private fun decodeLink(element: JsonElement): NoteMindMapLink {
        val o = element as? JsonObject ?: fail("link")
        return NoteMindMapLink(
            id = o.requiredString("id"),
            documentID = o.requiredString("documentID"),
            pageID = o.string("pageID"),
        )
    }

    fun decodeNotebook(element: JsonElement): Notebook {
        val o = element as? JsonObject ?: fail("notebook")
        return Notebook(
            id = o.requiredString("id"),
            title = o.requiredString("title"),
            createdAt = o.double("createdAt") ?: 0.0,
        )
    }

    fun decodeSummary(element: JsonElement): NoteDocumentSummary {
        val o = element as? JsonObject ?: fail("summary")
        return NoteDocumentSummary(
            id = o.requiredString("id"),
            kind = NoteDocumentKind.fromWire(o.requiredString("kind")) ?: fail("summary.kind"),
            notebookID = o.string("notebookID"),
            title = o.requiredString("title"),
            revision = o.int("revision") ?: fail("summary.revision"),
            pageCount = o.int("pageCount") ?: 0,
            nodeCount = o.int("nodeCount") ?: 0,
            tags = o.strings("tags"),
            isFavorite = o.bool("isFavorite") ?: false,
            createdAt = o.double("createdAt") ?: 0.0,
            updatedAt = o.double("updatedAt") ?: 0.0,
            deletedAt = o.double("deletedAt"),
            coverResourceID = o.string("coverResourceID"),
            coverRevision = o.int("coverRevision"),
            officeFileName = o.string("officeFileName"),
            engineeringFileName = o.string("engineeringFileName"),
            preview = o.string("preview") ?: "",
        )
    }

    fun decodeDocumentPage(o: JsonObject): NotesDocumentPage = NotesDocumentPage(
        documents = o.array("documents")?.map { decodeSummary(it) }.orEmpty(),
        truncated = o.bool("truncated") ?: false,
        total = o.int("total") ?: 0,
    )

    fun decodeLibrary(o: JsonObject): NotesLibrarySummary {
        val counts = o.obj("counts") ?: fail("library.counts")
        return NotesLibrarySummary(
            notebooks = o.array("notebooks")?.map { decodeNotebook(it) }.orEmpty(),
            counts = NotesCounts(
                documents = counts.int("documents") ?: 0,
                trashed = counts.int("trashed") ?: 0,
                favorites = counts.int("favorites") ?: 0,
                notebooks = counts.int("notebooks") ?: 0,
                mindMaps = counts.int("mindMaps") ?: 0,
                office = counts.int("office") ?: 0,
                engineering = counts.int("engineering") ?: 0,
            ),
            recent = o.array("recent")?.map { decodeSummary(it) }.orEmpty(),
        )
    }

    fun decodeHistory(o: JsonObject): NoteHistoryState = NoteHistoryState(
        canUndo = o.bool("canUndo") ?: false,
        canRedo = o.bool("canRedo") ?: false,
    )

    fun decodeCover(o: JsonObject): NoteCoverState = NoteCoverState(
        coverMode = if (o.string("coverMode") == "custom") NoteCoverMode.CUSTOM else NoteCoverMode.AUTOMATIC,
        coverResourceID = o.string("coverResourceID"),
        coverRevision = o.int("coverRevision") ?: 0,
        contentRevision = o.int("contentRevision") ?: fail("cover.contentRevision"),
    )

    fun decodeResource(o: JsonObject): NoteResourceRecord = NoteResourceRecord(
        id = o.requiredString("id"),
        hash = o.requiredString("hash"),
        byteCount = o.long("byteCount") ?: fail("resource.byteCount"),
        fileName = o.requiredString("fileName"),
        mediaType = o.requiredString("mediaType"),
    )

    fun decodeImportedResource(o: JsonObject): ImportedResource = ImportedResource(
        resourceID = o.requiredString("resourceID"),
        mediaType = o.requiredString("mediaType"),
        byteCount = o.long("byteCount") ?: fail("imported.byteCount"),
        fileName = o.requiredString("fileName"),
        sha256 = o.requiredString("sha256"),
    )

    fun decodeArchiveHandle(o: JsonObject): NotesArchiveHandle = NotesArchiveHandle(
        handle = o.requiredString("handle"),
        byteCount = o.long("byteCount") ?: fail("archive.byteCount"),
        fileName = o.requiredString("fileName"),
    )

    fun decodeArchiveChunk(o: JsonObject): NotesArchiveChunk = NotesArchiveChunk(
        handle = o.requiredString("handle"),
        offset = o.long("offset") ?: 0,
        nextOffset = o.long("nextOffset") ?: 0,
        totalBytes = o.long("totalBytes") ?: 0,
        eof = o.bool("eof") ?: false,
        data = decodeBase64(o.string("dataBase64") ?: ""),
    )

    fun decodeResourceChunk(o: JsonObject): com.floe.android.feature.notes.NoteResourceChunk =
        com.floe.android.feature.notes.NoteResourceChunk(
            resourceID = o.requiredString("resourceID"),
            offset = o.long("offset") ?: 0,
            nextOffset = o.long("nextOffset") ?: 0,
            totalBytes = o.long("totalBytes") ?: 0,
            eof = o.bool("eof") ?: false,
            data = decodeBase64(o.string("dataBase64") ?: ""),
        )

    fun decodeEventBatch(o: JsonObject): NotesEventBatch = NotesEventBatch(
        sequence = o.long("sequence") ?: 0,
        cursor = o.long("cursor") ?: 0,
        events = o.array("events")?.map { element ->
            val event = element as? JsonObject ?: fail("event")
            NotesEvent(
                sequence = event.long("sequence") ?: fail("event.sequence"),
                kind = event.requiredString("kind"),
                documentID = event.string("documentID"),
                revision = event.int("revision"),
            )
        }.orEmpty(),
        hasMore = o.bool("hasMore") ?: false,
        resyncRequired = o.bool("resyncRequired") ?: false,
    )

    fun decodeProposals(o: JsonObject): List<NotesProposalSummary> =
        o.array("proposals")?.map { element ->
            val proposal = element as? JsonObject ?: fail("proposal")
            NotesProposalSummary(
                id = proposal.requiredString("id"),
                documentID = proposal.requiredString("documentID"),
                baseRevision = proposal.int("baseRevision") ?: fail("proposal.baseRevision"),
                title = proposal.requiredString("title"),
                summary = proposal.string("summary") ?: "",
                createdAt = proposal.double("createdAt") ?: 0.0,
            )
        }.orEmpty()

    fun decodeBase64(value: String): ByteArray =
        if (value.isEmpty()) ByteArray(0) else java.util.Base64.getDecoder().decode(value)

    fun encodeBase64(value: ByteArray): String = java.util.Base64.getEncoder().encodeToString(value)

    // MARK: - Strict helpers

    private fun fail(name: String): Nothing = throw NotesException("invalidPayload", "missing:$name")
}

internal fun JsonObject.requiredString(name: String): String =
    string(name)?.takeIf { it.isNotEmpty() } ?: throw NotesException("invalidPayload", "missing:$name")

internal fun JsonObject.string(name: String): String? =
    (this[name] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.contentOrNull

internal fun JsonObject.int(name: String): Int? =
    (this[name] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.intOrNull

internal fun JsonObject.long(name: String): Long? =
    (this[name] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.longOrNull

internal fun JsonObject.double(name: String): Double? =
    (this[name] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.doubleOrNull

internal fun JsonObject.bool(name: String): Boolean? =
    (this[name] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.booleanOrNull

internal fun JsonObject.obj(name: String): JsonObject? = this[name] as? JsonObject

internal fun JsonObject.array(name: String): JsonArray? = this[name] as? JsonArray

internal fun JsonObject.strings(name: String): List<String> =
    (this[name] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p !is JsonNull }?.contentOrNull }
        .orEmpty()

internal fun JsonObject.stringMap(name: String): Map<String, String>? =
    (this[name] as? JsonObject)?.entries?.mapNotNull { (key, value) ->
        ((value as? JsonPrimitive)?.takeIf { it !is JsonNull }?.contentOrNull)?.let { key to it }
    }?.toMap()
