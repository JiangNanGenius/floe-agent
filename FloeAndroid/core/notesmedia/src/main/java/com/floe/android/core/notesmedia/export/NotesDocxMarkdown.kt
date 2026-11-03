// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.export

import java.util.Locale

/**
 * Bounded conversion of an authored Markdown text element into Word blocks.
 *
 * This is intentionally a small, explicit subset, not a CommonMark engine:
 * headings, bullet/ordered lists, block quotes, fenced code, pipe tables,
 * horizontal rules, paragraphs, bold/italic/inline code and http(s)/mailto
 * links. Unsupported syntax stays literal text. The caller must keep the
 * original Markdown element available as the editable source of truth; the
 * DOCX output is a material conversion, never a claim of full Markdown or
 * native Word/layout fidelity.
 */
public object NotesDocxMarkdown {

    public const val MAX_BLOCKS: Int = 600
    public const val MAX_TEXT_CHARS: Int = 400_000

    private val HEADING = Regex("^(#{1,6})\\s+(.*)$")
    private val BULLET = Regex("^(\\s*)[-*+]\\s+(.*)$")
    private val ORDERED = Regex("^(\\s*)(\\d{1,9})[.)]\\s+(.*)$")
    private val QUOTE = Regex("^\\s*>\\s?(.*)$")
    private val DIVIDER = Regex("^\\s{0,3}(?:(?:\\*\\s*){3,}|(?:-\\s*){3,}|(?:_\\s*){3,})$")
    private val TABLE_SEPARATOR = Regex("^\\s*\\|?\\s*:?-{3,}:?\\s*(?:\\|\\s*:?-{3,}:?\\s*)+\\|?\\s*$")

    public fun markdownBlocks(
        text: String,
        baseColor: String? = null,
        fontSizePt: Double? = null,
    ): List<NotesDocxBlock> = parse(text, markdown = true, baseColor, fontSizePt)

    public fun plainBlocks(
        text: String,
        baseColor: String? = null,
        fontSizePt: Double? = null,
    ): List<NotesDocxBlock> = parse(text, markdown = false, baseColor, fontSizePt)

    private fun parse(
        raw: String,
        markdown: Boolean,
        baseColor: String?,
        fontSizePt: Double?,
    ): List<NotesDocxBlock> {
        if (raw.length > MAX_TEXT_CHARS) throw IllegalArgumentException("textTooLarge")
        val lines = raw.replace("\r\n", "\n").replace('\r', '\n').split('\n')
        val blocks = ArrayList<NotesDocxBlock>()
        var index = 0
        val paragraph = ArrayList<String>()
        fun style(run: NotesDocxRun): NotesDocxRun = run.copy(
            color = run.color ?: baseColor,
            fontSizePt = run.fontSizePt ?: fontSizePt,
        )
        // Heading sizes come from the Word heading styles so H1..H3 remain
        // larger than the author's body size even for a 20pt note element.
        fun headingStyle(run: NotesDocxRun): NotesDocxRun = run.copy(
            color = run.color ?: baseColor,
            fontSizePt = null,
        )
        fun flushParagraph() {
            if (paragraph.isEmpty()) return
            val joined = paragraph.joinToString("\n")
            paragraph.clear()
            val runs = if (markdown) inlineRuns(joined) { run -> style(run) } else listOf(style(NotesDocxRun(joined)))
            if (runs.any { it.text.isNotEmpty() }) blocks += NotesDocxBlock.Paragraph(runs)
            if (blocks.size > MAX_BLOCKS) throw IllegalArgumentException("tooManyBlocks")
        }
        while (index < lines.size) {
            val line = lines[index]
            if (line.isBlank()) {
                flushParagraph()
                index++
                continue
            }
            if (markdown && isFence(line)) {
                flushParagraph()
                val fence = line.trimStart().take(3)
                val body = StringBuilder()
                index++
                while (index < lines.size && !lines[index].trimStart().startsWith(fence)) {
                    if (body.isNotEmpty()) body.append('\n')
                    body.append(lines[index])
                    index++
                }
                if (index < lines.size) index++ // closing fence
                if (body.isNotEmpty()) {
                    blocks += NotesDocxBlock.Paragraph(
                        listOf(style(NotesDocxRun(body.toString(), monospace = true))),
                        NotesDocxParagraphStyle.CODE,
                    )
                }
                if (blocks.size > MAX_BLOCKS) throw IllegalArgumentException("tooManyBlocks")
                continue
            }
            if (markdown) {
                val heading = HEADING.matchEntire(line)
                if (heading != null) {
                    flushParagraph()
                    val level = heading.groupValues[1].length.coerceIn(1, 6)
                    blocks += NotesDocxBlock.Heading(
                        level,
                        inlineRuns(heading.groupValues[2]) { run -> headingStyle(run) },
                    )
                    index++
                    if (blocks.size > MAX_BLOCKS) throw IllegalArgumentException("tooManyBlocks")
                    continue
                }
                if (DIVIDER.matches(line)) {
                    flushParagraph()
                    blocks += NotesDocxBlock.Divider
                    index++
                    continue
                }
                val bullet = BULLET.matchEntire(line)
                if (bullet != null) {
                    flushParagraph()
                    blocks += NotesDocxBlock.ListItem(
                        level = indentLevel(bullet.groupValues[1]),
                        ordered = false,
                        runs = inlineRuns(bullet.groupValues[2]) { run -> style(run) },
                    )
                    index++
                    continue
                }
                val ordered = ORDERED.matchEntire(line)
                if (ordered != null) {
                    flushParagraph()
                    blocks += NotesDocxBlock.ListItem(
                        level = indentLevel(ordered.groupValues[1]),
                        ordered = true,
                        runs = inlineRuns(ordered.groupValues[3]) { run -> style(run) },
                    )
                    index++
                    continue
                }
                if (QUOTE.matches(line)) {
                    flushParagraph()
                    val quoted = ArrayList<String>()
                    while (index < lines.size) {
                        val match = QUOTE.matchEntire(lines[index]) ?: break
                        quoted += match.groupValues[1]
                        index++
                    }
                    blocks += NotesDocxBlock.Paragraph(
                        inlineRuns(quoted.joinToString("\n")) { run -> style(run) },
                        NotesDocxParagraphStyle.QUOTE,
                    )
                    if (blocks.size > MAX_BLOCKS) throw IllegalArgumentException("tooManyBlocks")
                    continue
                }
                if (line.contains('|') && index + 1 < lines.size && isTableSeparator(lines[index + 1])) {
                    flushParagraph()
                    val table = parseTable(lines, index) { run -> style(run) }
                    if (table != null) {
                        blocks += table.first
                        index = table.second
                    } else {
                        paragraph += line
                        index++
                    }
                    if (blocks.size > MAX_BLOCKS) throw IllegalArgumentException("tooManyBlocks")
                    continue
                }
            }
            paragraph += line
            index++
        }
        flushParagraph()
        if (blocks.isEmpty() && raw.isNotBlank()) {
            val runs = listOf(style(NotesDocxRun(raw)))
            blocks += NotesDocxBlock.Paragraph(runs)
        }
        return blocks
    }

    private fun isFence(line: String): Boolean {
        val trimmed = line.trimStart()
        return trimmed.startsWith("```") || trimmed.startsWith("~~~")
    }

    private fun isTableSeparator(line: String): Boolean =
        line.contains('-') && TABLE_SEPARATOR.matches(line) ||
            (line.contains('|') && line.all { it == '|' || it == '-' || it == ':' || it == ' ' } && line.contains('-'))

    private fun parseTable(
        lines: List<String>,
        start: Int,
        style: (NotesDocxRun) -> NotesDocxRun,
    ): Pair<NotesDocxBlock.Table, Int>? {
        val header = splitTableRow(lines[start]) ?: return null
        if (header.isEmpty()) return null
        val separator = splitTableRow(lines[start + 1]) ?: return null
        if (separator.size != header.size) return null
        val rows = ArrayList<NotesDocxTableRow>()
        rows += NotesDocxTableRow(header.map { flattenInline(it) }, header = true)
        var index = start + 2
        while (index < lines.size) {
            val line = lines[index]
            if (line.isBlank() || !line.contains('|')) break
            val cells = splitTableRow(line) ?: break
            if (cells.size != header.size) break
            rows += NotesDocxTableRow(cells.map { flattenInline(it) })
            index++
            if (rows.size > NotesDocxPackageBuilder.MAX_TABLE_ROWS) throw IllegalArgumentException("tableTooLarge")
        }
        return NotesDocxBlock.Table(rows) to index
    }

    private fun splitTableRow(line: String): List<String>? {
        var value = line.trim()
        if (value.startsWith("|")) value = value.drop(1)
        if (value.endsWith("|")) value = value.dropLast(1)
        if (value.isBlank()) return emptyList()
        val cells = ArrayList<String>()
        val current = StringBuilder()
        var escaped = false
        for (character in value) {
            when {
                escaped -> {
                    current.append(character)
                    escaped = false
                }
                character == '\\' -> escaped = true
                character == '|' -> {
                    cells += current.toString().trim()
                    current.setLength(0)
                }
                else -> current.append(character)
            }
        }
        cells += current.toString().trim()
        return cells
    }

    private fun indentLevel(prefix: String): Int =
        (prefix.replace("\t", "  ").length / 2).coerceIn(0, 2)

    private fun inlineRuns(text: String, style: (NotesDocxRun) -> NotesDocxRun): List<NotesDocxRun> {
        val runs = ArrayList<NotesDocxRun>()
        val literal = StringBuilder()
        fun flushLiteral() {
            if (literal.isNotEmpty()) {
                runs += style(NotesDocxRun(literal.toString()))
                literal.setLength(0)
            }
        }
        var index = 0
        while (index < text.length) {
            val character = text[index]
            when {
                character == '\\' && index + 1 < text.length -> {
                    literal.append(text[index + 1])
                    index += 2
                }
                character == '`' -> {
                    val end = text.indexOf('`', index + 1)
                    if (end > index + 1) {
                        flushLiteral()
                        runs += style(NotesDocxRun(text.substring(index + 1, end), monospace = true))
                        index = end + 1
                    } else {
                        literal.append(character)
                        index++
                    }
                }
                character == '*' && index + 1 < text.length && text[index + 1] == '*' -> {
                    val end = text.indexOf("**", index + 2)
                    if (end > index + 2) {
                        flushLiteral()
                        runs += style(NotesDocxRun(text.substring(index + 2, end), bold = true))
                        index = end + 2
                    } else {
                        literal.append(character)
                        index++
                    }
                }
                character == '*' -> {
                    val end = text.indexOf('*', index + 1)
                    if (end > index + 1) {
                        flushLiteral()
                        runs += style(NotesDocxRun(text.substring(index + 1, end), italic = true))
                        index = end + 1
                    } else {
                        literal.append(character)
                        index++
                    }
                }
                character == '[' -> {
                    val close = text.indexOf(']', index + 1)
                    if (close > index + 1 && close + 1 < text.length && text[close + 1] == '(') {
                        val end = text.indexOf(')', close + 2)
                        if (end > close + 2) {
                            val label = text.substring(index + 1, close)
                            val url = text.substring(close + 2, end).trim()
                            flushLiteral()
                            if (isSupportedLink(url)) {
                                runs += style(NotesDocxRun(label, hyperlinkURL = url))
                            } else {
                                runs += style(NotesDocxRun(label))
                            }
                            index = end + 1
                        } else {
                            literal.append(character)
                            index++
                        }
                    } else {
                        literal.append(character)
                        index++
                    }
                }
                character == '!' && index + 1 < text.length && text[index + 1] == '[' -> {
                    // Embedded images are not downloaded or linked; keep the
                    // alternate label as literal text instead of a broken URL.
                    val close = text.indexOf(']', index + 2)
                    literal.append(text, index + 2, if (close > index + 2) close else text.length)
                    index = if (close > index + 2) close + 1 else text.length
                }
                else -> {
                    literal.append(character)
                    index++
                }
            }
        }
        flushLiteral()
        return runs
    }

    private fun flattenInline(text: String): String {
        val runs = inlineRuns(text) { it }
        return runs.joinToString("") { it.text }
    }

    private fun isSupportedLink(value: String): Boolean {
        val lower = value.lowercase(Locale.ROOT)
        return lower.startsWith("https://") || lower.startsWith("http://") || lower.startsWith("mailto:")
    }
}
