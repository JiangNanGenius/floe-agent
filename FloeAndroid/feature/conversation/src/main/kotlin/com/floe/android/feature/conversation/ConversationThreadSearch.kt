// SPDX-License-Identifier: MPL-2.0
//
// Current-thread find state and the VISIBLE-text projection shared by the
// Android find bar and its JVM tests.
//
// The native `conversation.messageSearch` command owns durable matching. This
// file owns only presentation state and the exact same normalization rules
// used for highlight offsets, so a hit loaded from history still highlights
// the string the row renders. Hidden Markdown link targets, code fences,
// reasoning/tool bytes and internal notices are never part of a searchable
// message body.
package com.floe.android.feature.conversation

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.text.Normalizer
import java.util.Locale

/** One normalized query. Whitespace separates AND terms; a quoted run is one
 * phrase. Duplicate terms collapse, the term/character budgets are bounded. */
class ThreadSearchQuery(raw: String) {
    sealed interface Term {
        val text: String
        data class Word(override val text: String) : Term
        data class Phrase(override val text: String) : Term
    }

    val raw: String = raw.take(MAXIMUM_QUERY_CHARACTERS)
    val terms: List<Term>

    init {
        val parsed = ArrayList<Term>()
        val seen = HashSet<String>()
        val buffer = StringBuilder()
        var inPhrase = false

        fun emit(value: String, phrase: Boolean) {
            val text = value.trim()
            if (text.isEmpty()) return
            val bounded = text.take(if (phrase) MAXIMUM_PHRASE_CHARACTERS else MAXIMUM_WORD_CHARACTERS)
            if (!seen.add(bounded.lowercase(Locale.ROOT))) return
            parsed += if (phrase) Term.Phrase(bounded) else Term.Word(bounded)
        }

        for (character in raw) {
            if (character == '"' || character == '\u201c' || character == '\u201d') {
                if (inPhrase) {
                    emit(buffer.toString(), true)
                    buffer.setLength(0)
                    inPhrase = false
                } else {
                    emit(buffer.toString(), false)
                    buffer.setLength(0)
                    inPhrase = true
                }
                continue
            }
            if (!inPhrase && character.isWhitespace()) {
                emit(buffer.toString(), false)
                buffer.setLength(0)
            } else {
                buffer.append(character)
            }
        }
        emit(buffer.toString(), inPhrase)
        terms = parsed.take(MAXIMUM_TERMS)
    }

    val isEmpty: Boolean get() = terms.isEmpty()

    /** Convenience for callers that hold one parsed query (same matcher the
     *  find bar and highlighting use; never a second rule set). */
    fun matches(text: String): Boolean = ThreadSearchMatcher.matches(text, this)

    companion object {
        const val MAXIMUM_TERMS = 8
        const val MAXIMUM_WORD_CHARACTERS = 64
        const val MAXIMUM_PHRASE_CHARACTERS = 128
        const val MAXIMUM_QUERY_CHARACTERS = 512
    }
}

/** Folded search over the SAME visible string the row renders. */
object ThreadSearchMatcher {
    fun matches(text: String, query: ThreadSearchQuery): Boolean {
        if (query.isEmpty) return false
        val folded = ThreadSearchFolding.fold(text)
        return query.terms.all { term ->
            folded.text.contains(ThreadSearchFolding.fold(term.text).text)
        }
    }

    /** UTF-16 offsets into [text] (the caller's exact visible string). */
    fun ranges(text: String, query: ThreadSearchQuery): List<IntRange> {
        if (query.isEmpty || text.isEmpty()) return emptyList()
        val folded = ThreadSearchFolding.fold(text)
        val found = ArrayList<IntRange>()
        for (term in query.terms) {
            val needle = ThreadSearchFolding.fold(term.text).text
            if (needle.isEmpty()) continue
            var from = 0
            var count = 0
            while (true) {
                val index = folded.text.indexOf(needle, from)
                if (index < 0) break
                val start = folded.originalOffset(index)
                val end = folded.originalOffset(index + needle.length)
                if (end > start) found += start until end
                from = index + needle.length
                count += 1
                if (count >= 512) break
            }
        }
        found.sortWith(compareBy({ it.first }, { it.last }))
        val merged = ArrayList<IntRange>()
        for (range in found) {
            val last = merged.lastOrNull()
            if (last != null && range.first <= last.last + 1) {
                merged[merged.size - 1] = last.first..maxOf(last.last, range.last)
            } else {
                merged += range
            }
        }
        return merged
    }
}

/** NFD/case/width folding with a mapping back to original UTF-16 offsets. */
internal object ThreadSearchFolding {
    data class Folded(val text: String, val offsets: IntArray) {
        fun originalOffset(foldedIndex: Int): Int {
            if (foldedIndex <= 0) return 0
            if (foldedIndex >= offsets.size) return offsets.lastOrNull()?.plus(1) ?: 0
            return offsets[foldedIndex]
        }
    }

    fun fold(value: String): Folded {
        val out = StringBuilder(value.length)
        val offsets = ArrayList<Int>(value.length)
        var charIndex = 0
        var codePointIndex = 0
        while (codePointIndex < value.length) {
            val codePoint = value.codePointAt(codePointIndex)
            val start = charIndex
            charIndex += Character.charCount(codePoint)
            codePointIndex += Character.charCount(codePoint)
            val raw = String(Character.toChars(codePoint))
            val normalized = Normalizer.normalize(raw, Normalizer.Form.NFD)
                .lowercase(Locale.ROOT)
            for (character in normalized) {
                if (character.isCombiningMark()) continue
                out.append(foldWidth(character))
                offsets += start
                if (out.length > 1 shl 20) break
            }
        }
        return Folded(out.toString(), offsets.toIntArray())
    }

    private fun Char.isCombiningMark(): Boolean {
        val type = Character.getType(code)
        return type == Character.NON_SPACING_MARK.toInt() ||
            type == Character.COMBINING_SPACING_MARK.toInt() ||
            type == Character.ENCLOSING_MARK.toInt()
    }

    private fun foldWidth(character: Char): Char {
        val code = character.code
        return when (code) {
            in 0xFF01..0xFF5E -> (code - 0xFEE0).toChar()
            0x3000 -> ' '
            else -> character
        }
    }
}

/** Visible text for the two searchable roles. User text is verbatim; assistant
 * Markdown is flattened (link label kept, target dropped, fences removed). */
object ThreadSearchVisible {
    const val MAXIMUM_SNIPPET_CHARACTERS = 160

    fun visibleText(role: MessageRoleUi, content: String): String =
        if (role == MessageRoleUi.ASSISTANT) visibleText(markdown = content) else content

    fun visibleText(markdown: String): String {
        val output = ArrayList<String>()
        var inFence = false
        for (rawLine in markdown.split('\n')) {
            val trimmed = rawLine.trim()
            if (trimmed.startsWith("```") || trimmed.startsWith("~~~")) {
                inFence = !inFence
                continue
            }
            if (inFence) {
                output += rawLine
                continue
            }
            if (isTableSeparator(trimmed) || isThematicBreak(trimmed) ||
                isReferenceDefinition(trimmed)
            ) continue
            var line = stripBlockMarkers(rawLine)
            line = flattenInline(line)
            val cleaned = line.trim()
            if (cleaned.isEmpty()) {
                if (output.lastOrNull()?.isNotEmpty() == true) output += ""
            } else {
                output += cleaned
            }
        }
        return output.joinToString("\n").trim()
    }

    fun snippet(text: String, query: ThreadSearchQuery, maximumCharacters: Int = 160): String {
        val limit = maxOf(24, maximumCharacters)
        val first = ThreadSearchMatcher.ranges(text, query).firstOrNull()
        if (first == null || first.first >= text.length) {
            return (text.split('\n').firstOrNull { it.isNotEmpty() } ?: text).take(limit)
        }
        var lineStart = first.first
        while (lineStart > 0 && text[lineStart - 1] != '\n') lineStart -= 1
        var lineEnd = first.first
        while (lineEnd < text.length && text[lineEnd] != '\n') lineEnd += 1
        val line = text.substring(lineStart, lineEnd)
        val matchOffset = first.first - lineStart
        val trimmed = line.trim()
        if (trimmed.length <= limit) return trimmed
        val windowStart = maxOf(0, minOf(matchOffset - limit / 3, maxOf(0, line.length - limit)))
        var window = line.substring(windowStart, minOf(line.length, windowStart + limit)).trim()
        if (windowStart > 0) window = "\u2026$window"
        if (windowStart + limit < line.length) window = "$window\u2026"
        return window
    }

    private fun isTableSeparator(line: String): Boolean {
        if (!line.startsWith("|") && !line.contains("|")) return false
        val cells = line.split('|')
        if (cells.size <= 1) return false
        return cells.all { cell ->
            val value = cell.trim()
            value.isNotEmpty() && value.all { it == '-' || it == ':' }
        }
    }

    private fun isThematicBreak(line: String): Boolean {
        if (line.length < 3) return false
        if (!line.all { it == '-' || it == '*' || it == '_' || it == ' ' }) return false
        return line.contains('-') || line.contains('*') || line.contains('_')
    }

    private fun isReferenceDefinition(line: String): Boolean {
        if (!line.startsWith("[")) return false
        val close = line.indexOf(']')
        return close >= 0 && line.getOrNull(close + 1) == ':'
    }

    private fun stripBlockMarkers(rawLine: String): String {
        var line = rawLine.trim()
        if (line.startsWith("|") && line.endsWith("|") && line.length > 1) {
            return line.split('|').map { it.trim() }.filter { it.isNotEmpty() }.joinToString(" ")
        }
        while (line.startsWith(">")) {
            line = line.drop(1).trimStart()
        }
        var hashes = 0
        for (character in line) {
            if (character == '#') hashes += 1 else break
        }
        if (hashes in 1..6 && (line.length == hashes || line.getOrNull(hashes) == ' ')) {
            line = line.drop(hashes).trim()
        }
        val first = line.firstOrNull()
        if (first != null && "-*+".contains(first) &&
            (line.length == 1 || line.getOrNull(1) == ' ')
        ) {
            return line.drop(1).trim()
        }
        var digits = 0
        for (character in line) {
            if (character.isDigit()) digits += 1 else break
        }
        if (digits in 1..9) {
            val marker = line.getOrNull(digits)
            if ((marker == '.' || marker == ')') && line.getOrNull(digits + 1) == ' ') {
                return line.drop(digits + 2).trim()
            }
        }
        return line
    }

    private fun flattenInline(source: String): String {
        val output = StringBuilder(source.length)
        var index = 0
        fun charAt(offset: Int): Char? = source.getOrNull(index + offset)
        while (index < source.length) {
            val character = source[index]
            if (character == '\\') {
                if (index + 1 < source.length) {
                    output.append(source[index + 1])
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            if (character == '!' && charAt(1) == '[') {
                val parsed = parseLink(source, index + 2)
                if (parsed != null) {
                    output.append(parsed.first)
                    index = parsed.second
                    continue
                }
            }
            if (character == '[') {
                val parsed = parseLink(source, index + 1)
                if (parsed != null) {
                    output.append(parsed.first)
                    index = parsed.second
                    continue
                }
            }
            if (character == '<' && source.startsWith("<!--", index)) {
                val end = source.indexOf("-->", index + 4)
                if (end >= 0) {
                    index = end + 3
                    continue
                }
            }
            if (character == '`') {
                var fence = 0
                while (index + fence < source.length && source[index + fence] == '`') fence += 1
                val marker = "`".repeat(fence)
                val end = source.indexOf(marker, index + fence)
                if (end >= 0) {
                    output.append(source, index + fence, end)
                    index = end + fence
                    continue
                }
            }
            if (character == '*' || character == '_' || character == '~') {
                if (character == '_') {
                    var runEnd = index + 1
                    while (runEnd < source.length && source[runEnd] == '_') runEnd += 1
                    // Match the native visible projection: intraword runs are
                    // literal identifiers, including inside outer emphasis.
                    var before = index
                    while (before > 0) {
                        val cp = source.codePointBefore(before)
                        val kind = Character.getType(cp)
                        if (kind != Character.NON_SPACING_MARK.toInt() &&
                            kind != Character.COMBINING_SPACING_MARK.toInt() &&
                            kind != Character.ENCLOSING_MARK.toInt()
                        ) break
                        before -= Character.charCount(cp)
                    }
                    val previousIsWord = before > 0 &&
                        identifierCodePoint(source.codePointBefore(before))
                    val nextIsWord = runEnd < source.length &&
                        identifierCodePoint(source.codePointAt(runEnd))
                    if (previousIsWord && nextIsWord) {
                        output.append(source, index, runEnd)
                        index = runEnd
                        continue
                    }
                }
                if (charAt(1) == character) {
                    index += 2
                    continue
                }
                // Match the native projection: `_` itself is word content
                // for delimiter adjacency, so the remaining marker of a
                // closing `___`/`__` run is still stripped instead of being
                // emitted as literal text (`alpha_beta_`).
                val previousIsWord = index > 0 &&
                    (source[index - 1].isLetterOrDigit() || source[index - 1] == '_')
                val nextIsWord = index + 1 < source.length &&
                    (source[index + 1].isLetterOrDigit() || source[index + 1] == '_')
                if (previousIsWord || nextIsWord) {
                    index += 1
                    continue
                }
            }
            output.append(character)
            index += 1
        }
        return output.toString()
    }

    private fun identifierCodePoint(codePoint: Int): Boolean =
        Character.isLetterOrDigit(codePoint) ||
            Character.getType(codePoint) == Character.LETTER_NUMBER.toInt() ||
            Character.getType(codePoint) == Character.OTHER_NUMBER.toInt()

    /** Returns (visible label, index after the closing syntax). */
    private fun parseLink(source: String, start: Int): Pair<String, Int>? {
        val close = source.indexOf(']', start)
        if (close < 0) return null
        val label = source.substring(start, close)
        val after = close + 1
        if (after >= source.length) return null
        if (source[after] == '(') {
            var depth = 1
            var cursor = after + 1
            var escaped = false
            while (cursor < source.length) {
                val character = source[cursor]
                if (escaped) {
                    escaped = false
                } else if (character == '\\') {
                    escaped = true
                } else if (character == '(') {
                    depth += 1
                } else if (character == ')') {
                    depth -= 1
                    if (depth == 0) return label to (cursor + 1)
                }
                cursor += 1
            }
            return null
        }
        if (source[after] == '[') {
            val refClose = source.indexOf(']', after + 1)
            if (refClose >= 0) return label to (refClose + 1)
        }
        return label to after
    }
}

/* ---------------------------------- state ---------------------------------- */

data class ThreadSearchHitUi(
    val messageId: String,
    val role: MessageRoleUi,
    val snippet: String,
    val createdAtLabel: String,
)

data class ThreadSearchResultUi(
    val hits: List<ThreadSearchHitUi>,
    val includesDurableHistory: Boolean = true,
    val isTemporary: Boolean = false,
)

data class ThreadSearchStateUi(
    val query: String = "",
    val hits: List<ThreadSearchHitUi> = emptyList(),
    val currentIndex: Int = -1,
    val isSearching: Boolean = false,
    val includesDurableHistory: Boolean = false,
    val isTemporary: Boolean = false,
    val error: ThreadSearchErrorUi? = null,
    val focusedMessageId: String? = null,
    val focusGeneration: Long = 0,
    /** One-shot scroll request; consumed by the timeline after the row is
     * present. The selected hit survives Done (no jump to the newest row). */
    val focusRowToken: Long = 0,
    val requestGeneration: Long = 0,
) {
    val hasQuery: Boolean get() = query.isNotBlank()
    val currentHit: ThreadSearchHitUi? get() = hits.getOrNull(currentIndex)
    val countLabel: String get() = if (hits.isEmpty()) "0/0" else "${currentIndex + 1}/${hits.size}"
}

enum class ThreadSearchErrorUi { OLDER_MATCH_UNAVAILABLE, SEARCH_FAILED, STALE_QUERY }
