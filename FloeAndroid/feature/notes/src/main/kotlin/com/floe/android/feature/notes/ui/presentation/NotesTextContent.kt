// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui.presentation

import com.floe.android.feature.notes.NoteDocument
import com.floe.android.feature.notes.NoteDocumentKind
import com.floe.android.feature.notes.NoteElement
import com.floe.android.feature.notes.NoteElementKind
import com.floe.android.feature.notes.NotePage
import com.floe.android.feature.notes.NoteRect
import com.floe.android.feature.notes.NotesEdit
import java.util.UUID

/**
 * Pure text content helpers. The native model stores an element either inline
 * (`text`) or as a slice of `textSources[textSourceID]`; both forms must read,
 * search and render identically. Editing a sliced element detaches it into an
 * inline element so one edit never mutates another element's shared source.
 */
public fun resolveElementText(document: NoteDocument, element: NoteElement): String {
    val sourceID = element.textSourceID ?: return element.text
    val source = document.textSources?.get(sourceID) ?: return element.text
    val slice = element.textSlice ?: return source
    val start = slice.start.coerceIn(0, source.length)
    val end = (slice.start + slice.count).coerceIn(start, source.length)
    return source.substring(start, end)
}

public fun elementPreview(document: NoteDocument, element: NoteElement, max: Int = 120): String =
    resolveElementText(document, element).replace('\n', ' ').take(max)

public data class NoteTextMatch(
    public val documentID: String,
    public val pageID: String?,
    public val elementID: String?,
    public val nodeID: String?,
    public val sourceKind: String,
    public val utf16Start: Int,
    public val utf16Length: Int,
    public val snippet: String,
    public val editable: Boolean,
) {
    public companion object {
        public const val ELEMENT: String = "element"
        public const val PAGE_TEXT: String = "pageText"
        public const val NODE_TITLE: String = "nodeTitle"
        public const val NODE_NOTE: String = "nodeNote"
    }
}

public fun findTextMatches(
    document: NoteDocument,
    query: String,
    matchCase: Boolean = false,
    limit: Int = 400,
): List<NoteTextMatch> {
    val needle = query.trim()
    if (needle.isEmpty() || limit <= 0) return emptyList()
    val output = mutableListOf<NoteTextMatch>()
    fun scan(
        text: String,
        pageID: String?,
        elementID: String?,
        nodeID: String?,
        kind: String,
        editable: Boolean,
    ) {
        var from = 0
        while (from <= text.length - needle.length && output.size < limit) {
            val index = text.indexOf(needle, startIndex = from, ignoreCase = !matchCase)
            if (index < 0) break
            output += NoteTextMatch(
                documentID = document.id,
                pageID = pageID,
                elementID = elementID,
                nodeID = nodeID,
                sourceKind = kind,
                utf16Start = index,
                utf16Length = needle.length,
                snippet = searchSnippet(text, needle),
                editable = editable,
            )
            from = index + needle.length.coerceAtLeast(1)
        }
    }
    document.pages.forEach { page ->
        page.elements.filter { it.kind == NoteElementKind.TEXT }.forEach { element ->
            scan(resolveElementText(document, element), page.id, element.id, null,
                NoteTextMatch.ELEMENT, editable = true)
        }
        val extracted = page.extractedText?.takeIf { it.isNotBlank() }
        val ocr = page.ocrText?.takeIf { it.isNotBlank() && it != extracted }
        extracted?.let { scan(it, page.id, null, null, NoteTextMatch.PAGE_TEXT, editable = false) }
        ocr?.let { scan(it, page.id, null, null, NoteTextMatch.PAGE_TEXT, editable = false) }
    }
    if (document.kind == NoteDocumentKind.MIND_MAP) {
        document.nodes.forEach { node ->
            scan(node.title, null, null, node.id, NoteTextMatch.NODE_TITLE, editable = true)
            if (node.note.isNotBlank()) {
                scan(node.note, null, null, node.id, NoteTextMatch.NODE_NOTE, editable = true)
            }
        }
    }
    return output
}

/** Counts of non-editable page/PDF text matches, shown honestly by replace UI. */
public fun readOnlyMatchCount(matches: List<NoteTextMatch>): Int = matches.count { !it.editable }

private fun replaceAllLiteral(
    text: String,
    query: String,
    replacement: String,
    matchCase: Boolean,
): Pair<String, Int> {
    if (query.isEmpty()) return text to 0
    val builder = StringBuilder(text.length)
    var from = 0
    var count = 0
    while (from <= text.length - query.length) {
        val index = text.indexOf(query, startIndex = from, ignoreCase = !matchCase)
        if (index < 0) break
        builder.append(text, from, index)
        builder.append(replacement)
        from = index + query.length
        count++
    }
    if (count == 0) return text to 0
    builder.append(text, from, text.length)
    return builder.toString() to count
}

/**
 * One-occurrence replacement preserving every other character and every other
 * element/topic. A source-backed element is detached into inline text so the
 * shared source cannot change under another cited element.
 */
public fun planReplaceMatch(
    document: NoteDocument,
    match: NoteTextMatch,
    replacement: String,
): NotesEdit? {
    if (!match.editable) return null
    val elementID = match.elementID
    if (elementID != null) {
        val page = document.pages.firstOrNull { page -> page.elements.any { it.id == elementID } }
            ?: return null
        val element = page.elements.firstOrNull { it.id == elementID } ?: return null
        val text = resolveElementText(document, element)
        val start = match.utf16Start.coerceIn(0, text.length)
        val end = (start + match.utf16Length).coerceIn(start, text.length)
        val updated = text.replaceRange(start, end, replacement)
        return NotesEdit.UpsertElement(
            pageID = page.id,
            element = element.copy(
                text = updated,
                textSourceID = null,
                textSlice = null,
            ),
        )
    }
    val nodeID = match.nodeID ?: return null
    val node = document.nodes.firstOrNull { it.id == nodeID } ?: return null
    val text = if (match.sourceKind == NoteTextMatch.NODE_TITLE) node.title else node.note
    val start = match.utf16Start.coerceIn(0, text.length)
    val end = (start + match.utf16Length).coerceIn(start, text.length)
    val updated = text.replaceRange(start, end, replacement)
    return NotesEdit.UpsertNode(
        if (match.sourceKind == NoteTextMatch.NODE_TITLE) node.copy(title = updated)
        else node.copy(note = updated),
    )
}

public data class NotesReplacePlan(
    public val edits: List<NotesEdit>,
    public val replaced: Int,
    public val skippedReadOnly: Int,
)

/**
 * Build one undoable batch for Replace All across editable note text and mind
 * map topics. Page OCR/PDF-derived text is never rewritten; its match count is
 * returned so the UI can state what was skipped.
 */
public fun planReplaceAll(
    document: NoteDocument,
    query: String,
    replacement: String,
    matchCase: Boolean = false,
): NotesReplacePlan {
    val needle = query.trim()
    if (needle.isEmpty()) return NotesReplacePlan(emptyList(), 0, 0)
    val matches = findTextMatches(document, needle, matchCase, limit = 10_000)
    val edits = mutableListOf<NotesEdit>()
    var replaced = 0
    val skipped = matches.count { !it.editable }

    val byElement = matches.filter { it.elementID != null }.groupBy { it.elementID!! }
    byElement.forEach { (elementID, values) ->
        val pageID = values.first().pageID ?: return@forEach
        val page = document.pages.firstOrNull { it.id == pageID } ?: return@forEach
        val element = page.elements.firstOrNull { it.id == elementID } ?: return@forEach
        val (updated, count) = replaceAllLiteral(
            resolveElementText(document, element), needle, replacement, matchCase,
        )
        if (count > 0) {
            replaced += count
            edits += NotesEdit.UpsertElement(
                pageID = pageID,
                element = element.copy(
                    text = updated,
                    textSourceID = null,
                    textSlice = null,
                ),
            )
        }
    }

    val byNode = matches.filter { it.nodeID != null }
        .groupBy { it.nodeID!! to it.sourceKind }
    byNode.forEach { (key, values) ->
        val (nodeID, kind) = key
        val node = document.nodes.firstOrNull { it.id == nodeID } ?: return@forEach
        val (updated, count) = if (kind == NoteTextMatch.NODE_TITLE) {
            replaceAllLiteral(node.title, needle, replacement, matchCase)
        } else {
            replaceAllLiteral(node.note, needle, replacement, matchCase)
        }
        if (count > 0) {
            replaced += count
            edits += NotesEdit.UpsertNode(
                if (kind == NoteTextMatch.NODE_TITLE) node.copy(title = updated) else node.copy(note = updated),
            )
        }
    }
    // Only page OCR/PDF-derived text is non-editable; element and topic matches
    // were rewritten above.
    return NotesReplacePlan(edits, replaced, matches.count { it.sourceKind == NoteTextMatch.PAGE_TEXT })
}

/* ------------------------------- Markdown -------------------------------- */

public sealed interface NotesMarkdownBlock {
    public data class Heading(public val level: Int, public val text: String) : NotesMarkdownBlock
    public data class Paragraph(public val text: String) : NotesMarkdownBlock
    public data class Bullet(
        public val ordered: Boolean,
        public val index: Int,
        public val indent: Int,
        public val text: String,
    ) : NotesMarkdownBlock
    public data class Quote(public val text: String) : NotesMarkdownBlock
    public data class Code(public val text: String) : NotesMarkdownBlock
    public data object Divider : NotesMarkdownBlock
}

/**
 * Deliberate, bounded Markdown block preview (headings, lists, quotes, fenced
 * code, rules, paragraphs). Inline emphasis/link markers are removed for
 * display; this is a reading preview, not a full CommonMark implementation and
 * it never executes HTML or links.
 */
public fun parseMarkdownBlocks(text: String): List<NotesMarkdownBlock> {
    if (text.isBlank()) return emptyList()
    val output = mutableListOf<NotesMarkdownBlock>()
    var inCode = false
    val code = StringBuilder()
    text.replace("\r\n", "\n").lines().forEach { line ->
        if (line.trimStart().startsWith("```")) {
            if (inCode) {
                output += NotesMarkdownBlock.Code(code.toString().trimEnd('\n'))
                code.clear()
                inCode = false
            } else {
                inCode = true
            }
            return@forEach
        }
        if (inCode) {
            code.append(line).append('\n')
            return@forEach
        }
        val trimmed = line.trim()
        when {
            trimmed.isEmpty() -> Unit
            trimmed == "---" || trimmed == "***" || trimmed == "___" ->
                output += NotesMarkdownBlock.Divider
            trimmed.startsWith("#") -> {
                val level = trimmed.takeWhile { it == '#' }.length.coerceIn(1, 6)
                val body = trimmed.dropWhile { it == '#' }.trim()
                if (body.isNotEmpty()) output += NotesMarkdownBlock.Heading(level, inlinePlain(body))
            }
            trimmed.startsWith(">") ->
                output += NotesMarkdownBlock.Quote(inlinePlain(trimmed.drop(1).trim()))
            trimmed.startsWith("- ") || trimmed.startsWith("* ") || trimmed.startsWith("+ ") -> {
                val indent = line.indexOfFirst { !it.isWhitespace() }.coerceAtLeast(0) / 2
                output += NotesMarkdownBlock.Bullet(false, 0, indent, inlinePlain(trimmed.drop(2)))
            }
            Regex("^\\d+[.)]\\s+.*").matches(trimmed) -> {
                val number = trimmed.takeWhile { it.isDigit() }.toIntOrNull() ?: 1
                val body = trimmed.dropWhile { it.isDigit() }.dropWhile { it == '.' || it == ')' }.trim()
                val indent = line.indexOfFirst { !it.isWhitespace() }.coerceAtLeast(0) / 2
                output += NotesMarkdownBlock.Bullet(true, number, indent, inlinePlain(body))
            }
            else -> output += NotesMarkdownBlock.Paragraph(inlinePlain(trimmed))
        }
    }
    if (inCode && code.isNotEmpty()) output += NotesMarkdownBlock.Code(code.toString().trimEnd('\n'))
    return output
}

private fun inlinePlain(text: String): String = text
    .replace(Regex("!\\[([^]]*)]\\([^)]*\\)"), "$1")
    .replace(Regex("\\[([^]]*)]\\([^)]*\\)"), "$1")
    .replace(Regex("(`{1,3})(.*?)\\1"), "$2")
    .replace(Regex("(\\*\\*|__)(.*?)\\1"), "$2")
    .replace(Regex("(?<!\\*)\\*(?!\\s)(.*?)(?<!\\s)\\*(?!\\*)"), "$1")
    .replace(Regex("(?<!_)_(?!\\s)(.*?)(?<!\\s)_(?!_)"), "$1")

public fun markdownPlainText(text: String): String =
    parseMarkdownBlocks(text).joinToString("\n") { block ->
        when (block) {
            is NotesMarkdownBlock.Heading -> block.text
            is NotesMarkdownBlock.Paragraph -> block.text
            is NotesMarkdownBlock.Bullet -> "• ".repeat(block.indent + 1) + block.text
            is NotesMarkdownBlock.Quote -> block.text
            is NotesMarkdownBlock.Code -> block.text
            NotesMarkdownBlock.Divider -> "——"
        }
    }

/* --------------------------- large text planning -------------------------- */

public fun interface NotesIdSource {
    public fun next(): String

    public companion object {
        public fun random(): NotesIdSource = NotesIdSource { UUID.randomUUID().toString() }
    }
}

public data class NotesTextPlan(
    public val edits: List<NotesEdit>,
    public val split: Boolean,
    public val resultingPages: Int,
)

private const val DEFAULT_TEXT_CHUNK_CHARS = 1_200

/** Never cut a UTF-16 surrogate pair in half at a chunk boundary. */
private fun safeCodePointBoundary(text: String, index: Int): Int {
    if (index <= 0 || index >= text.length) return index
    return if (Character.isLowSurrogate(text[index]) && Character.isHighSurrogate(text[index - 1])) {
        index - 1
    } else {
        index
    }
}

private fun splitIntoChunks(text: String, maxChars: Int): List<String> {
    if (text.length <= maxChars) return listOf(text)
    val chunks = mutableListOf<String>()
    var start = 0
    while (start < text.length) {
        var end = (start + maxChars).coerceAtMost(text.length)
        if (end < text.length) {
            val newline = text.lastIndexOf('\n', end - 1)
            if (newline > start + maxChars / 2) end = newline + 1
            else {
                val space = text.lastIndexOf(' ', end - 1)
                if (space > start + maxChars / 2) end = space + 1
            }
        }
        if (end < text.length) {
            val safe = safeCodePointBoundary(text, end)
            end = when {
                safe > start -> safe
                else -> (end + 1).coerceAtMost(text.length)
            }
        }
        chunks += text.substring(start, end)
        start = end
    }
    return chunks
}

/**
 * A page is a fixed paper rectangle, so chunking by character count alone can
 * still produce an element taller than the page (short lines waste width).
 * Split by estimated display height as well; a text block longer than the
 * paper continues on the next page instead of being clipped.
 */
private fun splitToFitPage(
    text: String,
    maxChars: Int,
    width: Double,
    fontSize: Double,
    maxHeight: Double,
): List<String> {
    if (width <= 0.0 || maxHeight <= 0.0) return splitIntoChunks(text, maxChars)
    return splitIntoChunks(text, maxChars).flatMap { chunk ->
        splitRecursive(chunk, width, fontSize, maxHeight)
    }
}

private fun splitRecursive(
    chunk: String,
    width: Double,
    fontSize: Double,
    maxHeight: Double,
): List<String> {
    if (chunk.length <= 64 || estimatedTextHeight(chunk, width, fontSize) <= maxHeight) {
        return listOf(chunk)
    }
    val mid = chunk.length / 2
    val newline = chunk.lastIndexOf('\n', mid)
    val space = chunk.lastIndexOf(' ', mid)
    val candidate = when {
        newline > chunk.length / 4 -> newline + 1
        space > chunk.length / 4 -> space + 1
        else -> mid
    }.coerceIn(1, chunk.length - 1)
    val safe = safeCodePointBoundary(chunk, candidate)
    val split = when {
        safe in 1 until chunk.length -> safe
        candidate < chunk.length - 1 -> candidate + 1
        else -> candidate
    }
    return splitRecursive(chunk.substring(0, split), width, fontSize, maxHeight) +
        splitRecursive(chunk.substring(split), width, fontSize, maxHeight)
}

internal fun estimatedTextHeight(text: String, width: Double, fontSize: Double): Double {
    val charsPerLine = (width / (fontSize * 0.55)).toInt().coerceAtLeast(8)
    val lines = text.split('\n').sumOf { line ->
        ((line.length + charsPerLine - 1) / charsPerLine).coerceAtLeast(1)
    }
    return (lines * fontSize * 1.45 + 28.0).coerceAtLeast(64.0)
}

private fun nextFreeY(page: NotePage): Double =
    (page.elements.maxOfOrNull { it.frame.y + it.frame.height } ?: 40.0) + 16.0

private fun newPageLike(page: NotePage?, id: String, paper: com.floe.android.feature.notes.NotePaper): NotePage =
    NotePage(id = id, width = page?.width ?: 768.0, height = page?.height ?: 1024.0, paper = paper)

/**
 * Plans insertion of a potentially large text body without ever truncating it.
 * Text larger than one safe block is split at line/word boundaries into
 * multiple text elements; when the current page runs out of room the overflow
 * continues on new pages. The caller applies the resulting edits as one
 * logical operation (the controller budgets requests separately).
 */
public fun planTextInsertion(
    document: NoteDocument,
    pageID: String?,
    text: String,
    markdown: Boolean,
    ids: NotesIdSource = NotesIdSource.random(),
    maxChars: Int = DEFAULT_TEXT_CHUNK_CHARS,
): NotesTextPlan {
    val normalized = text.replace("\r\n", "\n")
    if (normalized.isBlank()) return NotesTextPlan(emptyList(), false, 0)
    val pageIndex = document.pages.indexOfFirst { it.id == pageID }.takeIf { it >= 0 }
    val basePage = pageIndex?.let { document.pages[it] }
    val textWidth = ((basePage?.width ?: 768.0) - 80.0).coerceAtLeast(160.0)
    val textHeight = (basePage?.height ?: 1024.0) - 64.0
    val chunks = splitToFitPage(normalized, maxChars, textWidth, 18.0, textHeight)
    val edits = mutableListOf<NotesEdit>()
    var currentPage = basePage
    var currentPageID = basePage?.id
    var y = currentPage?.let(::nextFreeY) ?: 40.0
    var insertIndex = (pageIndex ?: document.pages.size - 1) + 1
    var createdPages = 0
    var firstChunk = true

    chunks.forEachIndexed { index, chunk ->
        val width = ((currentPage?.width ?: 768.0) - 80.0).coerceAtLeast(160.0)
        val height = estimatedTextHeight(chunk, width, 18.0)
        if (currentPage != null && y + height > currentPage.height - 24.0 && !(firstChunk && index == 0 && currentPage.elements.isEmpty())) {
            val page = newPageLike(basePage, ids.next(), basePage?.paper ?: com.floe.android.feature.notes.NotePaper.PLAIN)
            currentPage = page
            currentPageID = page.id
            y = 40.0
            createdPages++
            edits += NotesEdit.InsertPage(page = page, index = insertIndex)
            insertIndex++
        }
        val elementID = ids.next()
        val element = NoteElement(
            id = elementID,
            kind = NoteElementKind.TEXT,
            frame = NoteRect(x = 40.0, y = y, width = width, height = height),
            text = chunk.trimEnd('\n'),
            fontSize = 18.0,
            textFormat = if (markdown) "markdown" else null,
        )
        if (currentPageID == null) {
            val page = newPageLike(basePage, ids.next(), basePage?.paper ?: com.floe.android.feature.notes.NotePaper.PLAIN)
            currentPage = page
            currentPageID = page.id
            createdPages++
            edits += NotesEdit.InsertPage(
                page = page.copy(elements = listOf(element)),
                index = insertIndex,
            )
            insertIndex++
        } else {
            edits += NotesEdit.UpsertElement(pageID = currentPageID!!, element = element)
        }
        y += height + 16.0
        firstChunk = false
    }
    return NotesTextPlan(
        edits = edits,
        split = chunks.size > 1,
        resultingPages = createdPages + if (basePage != null) 1 else createdPages,
    )
}

/**
 * Replaces one element's text. Small edits keep the element identity. Large
 * edits keep the original id for the first block and create continuation
 * elements/pages, so a paste is never silently truncated or dropped.
 */
public fun planElementTextReplacement(
    document: NoteDocument,
    pageID: String,
    element: NoteElement,
    text: String,
    markdown: Boolean,
    ids: NotesIdSource = NotesIdSource.random(),
    maxChars: Int = DEFAULT_TEXT_CHUNK_CHARS,
): NotesTextPlan {
    val pageIndex = document.pages.indexOfFirst { it.id == pageID }
    val page = document.pages.getOrNull(pageIndex) ?: return NotesTextPlan(emptyList(), false, 0)
    val normalized = text.replace("\r\n", "\n")
    // A text box near the page bottom must expand from the top; otherwise its
    // first block is clipped before the continuation pages are reached.
    val startY = if (page.height - element.frame.y - 16.0 < 240.0) 40.0 else element.frame.y
    val textWidth = (page.width - element.frame.x - 16.0).coerceAtLeast(160.0)
    val availableHeight = (page.height - startY - 16.0).coerceAtLeast(160.0)
    val chunks = splitToFitPage(
        normalized,
        maxChars,
        textWidth,
        element.fontSize,
        availableHeight,
    )
    val firstHeight = estimatedTextHeight(chunks.first(), textWidth, element.fontSize)
    val firstFrame = if (chunks.size == 1) {
        element.frame.copy(
            width = textWidth,
            height = if (firstHeight > element.frame.height &&
                element.frame.y + firstHeight <= page.height - 16.0
            ) {
                firstHeight
            } else {
                element.frame.height
            },
        )
    } else {
        com.floe.android.feature.notes.NoteRect(
            x = element.frame.x.coerceAtMost((page.width - textWidth).coerceAtLeast(0.0)),
            y = startY,
            width = textWidth,
            height = firstHeight.coerceAtMost(availableHeight),
        )
    }
    val first = element.copy(
        frame = firstFrame,
        text = chunks.first().trimEnd('\n'),
        textFormat = if (markdown) "markdown" else null,
        textSourceID = null,
        textSlice = null,
    )
    if (chunks.size == 1) {
        return NotesTextPlan(listOf(NotesEdit.UpsertElement(pageID, first)), false, 1)
    }
    val edits = mutableListOf<NotesEdit>(NotesEdit.UpsertElement(pageID, first))
    var y = firstFrame.y + firstFrame.height + 16.0
    var currentPage = page
    var currentPageID = pageID
    var insertIndex = pageIndex + 1
    var createdPages = 0
    chunks.drop(1).forEach { chunk ->
        val width = textWidth
        val height = estimatedTextHeight(chunk, width, element.fontSize)
        if (y + height > currentPage.height - 24.0) {
            val newPage = newPageLike(page, ids.next(), page.paper)
            currentPage = newPage
            currentPageID = newPage.id
            y = 40.0
            createdPages++
            edits += NotesEdit.InsertPage(newPage, insertIndex)
            insertIndex++
        }
        val continuation = NoteElement(
            id = ids.next(),
            kind = NoteElementKind.TEXT,
            frame = NoteRect(element.frame.x, y, width, height),
            text = chunk.trimEnd('\n'),
            color = element.color,
            fontSize = element.fontSize,
            textFormat = if (markdown) "markdown" else null,
        )
        edits += NotesEdit.UpsertElement(currentPageID, continuation)
        y += height + 16.0
    }
    return NotesTextPlan(edits, split = true, resultingPages = createdPages + 1)
}

/* -------------------------- request size budgeting ------------------------ */

/**
 * Conservative request-size estimate. JSON escaping can double a string's
 * bytes; numbers and envelopes add a small fixed cost. [SAFE_BATCH_BYTES] is
 * the general autosave/UI warning threshold. [MAX_SAFE_BATCH_BYTES] is used by
 * the editor flush so one user-intent plan that fits the bridge limit is sent
 * as ONE native apply (one undo). Above it, the plan must be split because the
 * staged text API has no multi-element/multi-page atomic batch mode.
 */
public object NotesRequestBudget {
    public const val SAFE_BATCH_BYTES: Int = 48_000
    /** Bounded below [com.floe.android.feature.notes.NotesProtocol.MAX_REQUEST_BYTES]. */
    public const val MAX_SAFE_BATCH_BYTES: Int = 60_000

    public fun estimateBytes(edits: List<NotesEdit>): Int = edits.sumOf { edit ->
        val strings = when (edit) {
            is NotesEdit.Rename -> listOf(edit.text)
            is NotesEdit.Tags -> edit.tags
            is NotesEdit.TextSource -> listOfNotNull(edit.id, edit.text)
            is NotesEdit.InsertPage -> pageStrings(edit.page)
            is NotesEdit.UpdatePage -> pageStrings(edit.page)
            is NotesEdit.UpsertElement -> elementStrings(edit.element)
            is NotesEdit.DeleteElements -> edit.ids
            is NotesEdit.UpsertNode -> nodeStrings(edit.node)
            is NotesEdit.UpsertConnection -> listOf(edit.connection.id, edit.connection.from, edit.connection.to, edit.connection.title)
            is NotesEdit.ReplaceMindMap -> edit.nodes.flatMap(::nodeStrings) + edit.connections.flatMap { listOf(it.id, it.from, it.to, it.title) }
            is NotesEdit.LinkMindMap -> listOf(edit.link.id, edit.link.documentID)
            is NotesEdit.MindMapLayout -> edit.summaries.map { it.label }
            else -> emptyList()
        }
        val textBytes = strings.sumOf { it.toByteArray(Charsets.UTF_8).size * 2 }
        64 + textBytes
    }

    public fun exceeds(edits: List<NotesEdit>, budget: Int = SAFE_BATCH_BYTES): Boolean =
        estimateBytes(edits) > budget

    /** Greedy ordered chunks; a single oversize edit travels alone. */
    public fun split(
        edits: List<NotesEdit>,
        budget: Int = SAFE_BATCH_BYTES,
    ): List<List<NotesEdit>> {
        if (edits.isEmpty()) return emptyList()
        val chunks = mutableListOf<MutableList<NotesEdit>>()
        var current = mutableListOf<NotesEdit>()
        var currentBytes = 0
        edits.forEach { edit ->
            val bytes = estimateBytes(listOf(edit))
            if (current.isNotEmpty() && currentBytes + bytes > budget) {
                chunks += current
                current = mutableListOf()
                currentBytes = 0
            }
            current += edit
            currentBytes += bytes
        }
        if (current.isNotEmpty()) chunks += current
        return chunks
    }

    private fun pageStrings(page: NotePage): List<String> =
        page.elements.flatMap(::elementStrings) +
            listOfNotNull(page.id, page.backgroundResourceID, page.drawingResourceID, page.ocrText, page.extractedText)

    private fun elementStrings(element: NoteElement): List<String> =
        listOf(element.id, element.text, element.color, element.resourceID ?: "", element.textFormat ?: "") +
            listOfNotNull(element.textSourceID)

    private fun nodeStrings(node: com.floe.android.feature.notes.MindMapNode): List<String> =
        listOf(node.id, node.parentID ?: "", node.title, node.note) +
            (node.attachments?.map { it.fileName } ?: emptyList()) +
            (node.tags ?: emptyList())
}
