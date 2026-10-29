// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui.presentation

import com.floe.android.feature.notes.MindMapAttachment
import com.floe.android.feature.notes.MindMapConnection
import com.floe.android.feature.notes.MindMapConnectionOffset
import com.floe.android.feature.notes.MindMapNode
import com.floe.android.feature.notes.MindMapPoint
import com.floe.android.feature.notes.MindMapSummary
import com.floe.android.feature.notes.NoteElement
import com.floe.android.feature.notes.NoteMindMapLink
import com.floe.android.feature.notes.NotePage
import com.floe.android.feature.notes.NoteRect
import com.floe.android.feature.notes.NoteSourceReference
import com.floe.android.feature.notes.NoteTextSlice
import com.floe.android.feature.notes.NotesEdit
import java.security.MessageDigest

/**
 * Content-derived receipt suffix for one native `document.apply` chunk.
 *
 * The chunk identity must survive a process/root restart and must not depend
 * on the chunk's position in the remaining queue (recovery re-chunks the same
 * remaining edits). It also must not use [List.hashCode]: different edit
 * chunks can collide (for example the classic String "Aa"/"BB" collision), and
 * a colliding chunk would look like a retry of the other and be skipped.
 *
 * This writer is a canonical, versioned, ordered encoding of every field of
 * the closed [NotesEdit] vocabulary. Strings are length-prefixed, floating
 * values use raw bits, nullable values have explicit markers, and maps are
 * sorted by key. The SHA-256 therefore depends only on edit content.
 */
public object NotesEditReceipt {
    private const val DOMAIN = "FloeNotesEditChunk/v1"

    public fun digest(edits: List<NotesEdit>): String {
        val writer = CanonicalWriter()
        writer.raw(DOMAIN)
        writer.raw("\n")
        writer.count(edits.size)
        edits.forEach(writer::edit)
        return writer.finish()
    }

    /** Stable request-ID suffix; the base UUID still identifies the user intent. */
    public fun suffix(edits: List<NotesEdit>): String = ":" + digest(edits)

    private class CanonicalWriter {
        private val digest = MessageDigest.getInstance("SHA-256")

        fun raw(value: String) {
            digest.update(value.toByteArray(Charsets.UTF_8))
        }

        fun count(value: Int) {
            raw("C${value};")
        }

        fun string(value: String?) {
            if (value == null) {
                raw("N;")
                return
            }
            raw("S${value.length}:")
            raw(value)
            raw(";")
        }

        fun int(value: Int?) {
            if (value == null) raw("N;") else raw("I$value;")
        }

        fun double(value: Double?) {
            if (value == null) {
                raw("N;")
            } else {
                raw("D${java.lang.Double.doubleToRawLongBits(value)};")
            }
        }

        fun bool(value: Boolean?) {
            if (value == null) raw("N;") else raw(if (value) "B1;" else "B0;")
        }

        fun <T> list(name: String, values: List<T>?, item: (T) -> Unit) {
            raw(name)
            if (values == null) {
                raw("N;")
                return
            }
            raw("[")
            count(values.size)
            values.forEach(item)
            raw("]")
        }

        fun stringList(name: String, values: List<String>?) {
            list(name, values) { string(it) }
        }

        fun map(name: String, values: Map<String, String>?) {
            raw(name)
            if (values == null) {
                raw("N;")
                return
            }
            raw("{")
            count(values.size)
            values.keys.sorted().forEach { key ->
                string(key)
                string(values[key])
            }
            raw("}")
        }

        fun edit(value: NotesEdit) {
            when (value) {
                is NotesEdit.Rename -> { raw("Rename"); string(value.text) }
                is NotesEdit.MoveToNotebook -> { raw("MoveToNotebook"); string(value.notebookID) }
                is NotesEdit.Favorite -> { raw("Favorite"); bool(value.isFavorite) }
                is NotesEdit.Tags -> { raw("Tags"); stringList("tags", value.tags) }
                is NotesEdit.TextSource -> {
                    raw("TextSource")
                    string(value.id)
                    string(value.text)
                }
                is NotesEdit.InsertPage -> {
                    raw("InsertPage")
                    int(value.index)
                    page(value.page)
                }
                is NotesEdit.UpdatePage -> { raw("UpdatePage"); page(value.page) }
                is NotesEdit.MovePage -> { raw("MovePage"); string(value.pageID); int(value.index) }
                is NotesEdit.DuplicatePage -> { raw("DuplicatePage"); string(value.pageID) }
                is NotesEdit.DeletePage -> { raw("DeletePage"); string(value.pageID) }
                is NotesEdit.Drawing -> {
                    raw("Drawing")
                    string(value.pageID)
                    string(value.resourceID)
                }
                is NotesEdit.UpsertElement -> {
                    raw("UpsertElement")
                    string(value.pageID)
                    element(value.element)
                }
                is NotesEdit.DeleteElements -> {
                    raw("DeleteElements")
                    string(value.pageID)
                    stringList("ids", value.ids)
                }
                is NotesEdit.UpsertNode -> { raw("UpsertNode"); node(value.node) }
                is NotesEdit.DeleteBranch -> { raw("DeleteBranch"); string(value.nodeID) }
                is NotesEdit.UpsertConnection -> {
                    raw("UpsertConnection")
                    connection(value.connection)
                }
                is NotesEdit.DeleteConnection -> {
                    raw("DeleteConnection")
                    string(value.connectionID)
                }
                is NotesEdit.ReplaceMindMap -> {
                    raw("ReplaceMindMap")
                    list("nodes", value.nodes) { node(it) }
                    list("connections", value.connections) { connection(it) }
                }
                is NotesEdit.LinkMindMap -> { raw("LinkMindMap"); link(value.link) }
                is NotesEdit.UnlinkMindMap -> { raw("UnlinkMindMap"); string(value.linkID) }
                is NotesEdit.ReplaceOfficeResource -> {
                    raw("ReplaceOfficeResource")
                    string(value.resourceID)
                }
                is NotesEdit.MindMapLayout -> {
                    raw("MindMapLayout")
                    int(value.direction)
                    list("summaries", value.summaries) { summary(it) }
                }
            }
        }

        private fun page(value: NotePage) {
            raw("Page{")
            string(value.id)
            double(value.width)
            double(value.height)
            string(value.paper.name)
            string(value.backgroundResourceID)
            int(value.pdfPageIndex)
            string(value.drawingResourceID)
            list("elements", value.elements) { element(it) }
            bool(value.isBookmarked)
            string(value.extractedText)
            string(value.ocrText)
            string(value.ocrSourceKey)
            string(value.ocrError)
            bool(value.textExtractionTruncated)
            raw("}")
        }

        private fun element(value: NoteElement) {
            raw("Element{")
            string(value.id)
            string(value.kind.name)
            rect(value.frame)
            string(value.text)
            string(value.resourceID)
            string(value.color)
            double(value.fontSize)
            string(value.textFormat)
            string(value.textSourceID)
            slice(value.textSlice)
            source(value.source)
            bool(value.isAIGenerated)
            raw("}")
        }

        private fun node(value: MindMapNode) {
            raw("Node{")
            string(value.id)
            string(value.parentID)
            string(value.title)
            string(value.note)
            int(value.order)
            bool(value.isCollapsed)
            string(value.color)
            string(value.imageResourceID)
            list("attachments", value.attachments) { attachment(it) }
            map("style", value.style)
            stringList("tags", value.tags)
            stringList("icons", value.icons)
            int(value.direction)
            string(value.branchColor)
            string(value.hyperLink)
            bool(value.isAIGenerated)
            source(value.source)
            value.position?.let { point(it) } ?: raw("N;")
            raw("}")
        }

        private fun connection(value: MindMapConnection) {
            raw("Connection{")
            string(value.id)
            string(value.from)
            string(value.to)
            string(value.title)
            value.delta1?.let { offset(it) } ?: raw("N;")
            value.delta2?.let { offset(it) } ?: raw("N;")
            bool(value.bidirectional)
            map("style", value.style)
            raw("}")
        }

        private fun attachment(value: MindMapAttachment) {
            raw("Attachment{")
            string(value.id)
            string(value.resourceID)
            string(value.fileName)
            string(value.mediaType)
            string(value.kind.name)
            string(value.caption)
            source(value.source)
            raw("}")
        }

        private fun summary(value: MindMapSummary) {
            raw("Summary{")
            string(value.id)
            string(value.label)
            string(value.parent)
            int(value.start)
            int(value.end)
            map("style", value.style)
            raw("}")
        }

        private fun link(value: NoteMindMapLink) {
            raw("Link{")
            string(value.id)
            string(value.documentID)
            string(value.pageID)
            raw("}")
        }

        private fun source(value: NoteSourceReference?) {
            if (value == null) {
                raw("N;")
                return
            }
            raw("Source{")
            string(value.space.name)
            string(value.documentID)
            int(value.revision)
            string(value.pageID)
            string(value.nodeID)
            value.region?.let { rect(it) } ?: raw("N;")
            double(value.recordingSeconds)
            raw("}")
        }

        private fun rect(value: NoteRect) {
            raw("Rect{")
            double(value.x)
            double(value.y)
            double(value.width)
            double(value.height)
            raw("}")
        }

        private fun slice(value: NoteTextSlice?) {
            if (value == null) {
                raw("N;")
                return
            }
            raw("Slice{")
            int(value.start)
            int(value.count)
            int(value.total)
            raw("}")
        }

        private fun point(value: MindMapPoint) {
            raw("Point{")
            double(value.x)
            double(value.y)
            raw("}")
        }

        private fun offset(value: MindMapConnectionOffset) {
            raw("Offset{")
            double(value.x)
            double(value.y)
            raw("}")
        }

        fun finish(): String {
            val bytes = digest.digest()
            val hex = CharArray(bytes.size * 2)
            val digits = "0123456789abcdef"
            bytes.forEachIndexed { index, byte ->
                val value = byte.toInt() and 0xff
                hex[index * 2] = digits[value ushr 4]
                hex[index * 2 + 1] = digits[value and 0x0f]
            }
            return String(hex)
        }
    }
}
