// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.export

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.security.MessageDigest
import java.util.Locale
import java.util.IdentityHashMap
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream
import javax.xml.parsers.DocumentBuilderFactory
import org.w3c.dom.Element

/* ------------------------------------------------------------------------- */
/* Model                                                                     */
/* ------------------------------------------------------------------------- */

/**
 * One text run in a generated WordprocessingML paragraph.
 *
 * [hyperlinkURL] is only honoured for http(s)/mailto URLs. Anything else stays
 * literal text (never an embedded file/command link). [fontSizePt] is the
 * author's note font size; the builder clamps it to Word's representable
 * half-point range instead of inventing layout.
 */
public data class NotesDocxRun(
    public val text: String,
    public val bold: Boolean = false,
    public val italic: Boolean = false,
    public val monospace: Boolean = false,
    public val color: String? = null,
    public val fontSizePt: Double? = null,
    public val hyperlinkURL: String? = null,
)

public enum class NotesDocxParagraphStyle { BODY, QUOTE, CODE }

public sealed interface NotesDocxBlock {
    public data class Title(public val runs: List<NotesDocxRun>) : NotesDocxBlock
    public data class Heading(public val level: Int, public val runs: List<NotesDocxRun>) : NotesDocxBlock
    public data class Paragraph(
        public val runs: List<NotesDocxRun>,
        public val style: NotesDocxParagraphStyle = NotesDocxParagraphStyle.BODY,
    ) : NotesDocxBlock
    public data class ListItem(
        public val level: Int,
        public val ordered: Boolean,
        public val runs: List<NotesDocxRun>,
    ) : NotesDocxBlock
    public data class Table(public val rows: List<NotesDocxTableRow>) : NotesDocxBlock
    public data class Image(public val image: NotesDocxImage) : NotesDocxBlock
    public data object Divider : NotesDocxBlock
}

public data class NotesDocxTableRow(
    public val cells: List<String>,
    /** Header rows repeat on later pages and are bold. */
    public val header: Boolean = false,
)

/**
 * A bounded PNG/JPEG picture embedded into the package. Width/height/left/top
 * are EMU (914400 per inch) and describe the note's own geometry. A
 * [behindText] picture is the page's non-text visual layer (PDF background,
 * background image, ink, shapes) rendered by the existing protected Notes
 * exporter; it is anchored behind editable text at the full page size.
 */
public data class NotesDocxImage(
    public val bytes: ByteArray,
    public val mediaType: String,
    public val widthEmu: Long,
    public val heightEmu: Long,
    public val leftEmu: Long = 0L,
    public val topEmu: Long = 0L,
    public val altText: String = "",
    public val behindText: Boolean = false,
)

public data class NotesDocxPage(
    public val widthPt: Double,
    public val heightPt: Double,
    public val blocks: List<NotesDocxBlock> = emptyList(),
    /** Non-text page layer; anchored behind [blocks]. */
    public val background: NotesDocxImage? = null,
)

public data class NotesDocxDocument(
    public val title: String,
    public val pages: List<NotesDocxPage>,
    /** Optional truthful conversion note appended to the last page. */
    public val footerNote: String? = null,
    public val creator: String = "Floe",
)

public data class NotesDocxBuildResult(
    public val bytes: ByteArray,
    public val sha256: String,
    public val pageCount: Int,
    public val imageCount: Int,
    public val byteCount: Long,
)

public class NotesDocxBuildException(public val reason: String) : IllegalArgumentException(reason)

/* ------------------------------------------------------------------------- */
/* Builder                                                                   */
/* ------------------------------------------------------------------------- */

/**
 * Small, self-authored WordprocessingML package builder for Notes export.
 *
 * It is deliberately not a general-purpose Word engine. It emits a real,
 * standards-shaped `.docx` from the content the caller explicitly supplies:
 * paragraphs, headings, ordered/bullet lists, tables, external hyperlinks,
 * anchored PNG/JPEG media and per-page section geometry. Typed text remains
 * editable Word text. Non-text page layers are supplied by the caller as an
 * already-rendered page image (the existing protected Notes renderer owns that
 * composition); this builder only packages it honestly.
 *
 * Every package is re-opened and structurally validated before its digest is
 * returned: ZIP bounds/traversal/duplicates, content types, relationships,
 * main document XML, style/numbering parts, page sections, hyperlink targets,
 * embedded image bytes and their relationship ids. A build either returns a
 * validated package or throws [NotesDocxBuildException]; it never returns a
 * partial or "looks like zip" file.
 */
private const val XML_HEADER = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
private const val REL_NS = "http://schemas.openxmlformats.org/package/2006/relationships"
private const val CONTENT_TYPES_NS = "http://schemas.openxmlformats.org/package/2006/content-types"
private const val OFFICE_DOCUMENT_REL =
    "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
private const val CORE_PROPS_REL =
    "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties"
private const val REL_OFFICE_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
private const val WORD_NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
private const val DRAWING_NS = "http://schemas.openxmlformats.org/drawingml/2006/main"
private const val PICTURE_NS = "http://schemas.openxmlformats.org/drawingml/2006/picture"
private const val WORDPROCESSING_DRAWING_NS =
    "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
private const val MAIN_CONTENT_TYPE =
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"
private const val STYLES_CONTENT_TYPE =
    "application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"
private const val NUMBERING_CONTENT_TYPE =
    "application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"
private const val CORE_CONTENT_TYPE = "application/vnd.openxmlformats-package.core-properties+xml"
private const val IMAGE_PNG = "image/png"
private const val IMAGE_JPEG = "image/jpeg"
private const val EMU_PER_POINT = 12_700.0

private data class ImagePart(
    val image: NotesDocxImage,
    val relationID: String,
    val partName: String,
    val extension: String,
    val digest: String,
)

private fun isSupportedHyperlink(value: String): Boolean {
    val lower = value.trim().lowercase(Locale.ROOT)
    return lower.startsWith("https://") || lower.startsWith("http://") || lower.startsWith("mailto:")
}

/**
 * File-local WordprocessingML body writer. Kept top-level so it can use the
 * file's private package constants without leaking them through the public
 * builder surface.
 */
private class BodyWriter(private val imageParts: List<ImagePart>) {
    val hasLists: Boolean
        get() = lists
    private var lists = false
    private val hyperlinks = LinkedHashMap<String, String>()
    private var nextHyperlink = 10
    private val imageByRef = IdentityHashMap<NotesDocxImage, ImagePart>()

    init {
        for (part in imageParts) imageByRef[part.image] = part
    }

    fun write(document: NotesDocxDocument): String {
        val out = StringBuilder(32_000)
        out.append(XML_HEADER)
        out.append("<w:document xmlns:w=\"").append(WORD_NS)
            .append("\" xmlns:r=\"").append(REL_OFFICE_NS)
            .append("\" xmlns:wp=\"").append(WORDPROCESSING_DRAWING_NS)
            .append("\" xmlns:a=\"").append(DRAWING_NS)
            .append("\" xmlns:pic=\"").append(PICTURE_NS)
            .append("\"><w:body>")
        writeParagraph(out, listOf(NotesDocxRun(document.title)), "Title", null)
        document.pages.forEachIndexed { index, page ->
            page.background?.let { background ->
                out.append("<w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\" w:line=\"20\" w:lineRule=\"exact\"/></w:pPr><w:r>")
                writeDrawing(out, background)
                out.append("</w:r></w:p>")
            }
            page.blocks.forEach { block -> writeBlock(out, block) }
            if (index < document.pages.lastIndex) {
                out.append("<w:p><w:pPr><w:sectPr>")
                writeSectionProperties(out, page)
                out.append("</w:sectPr></w:pPr></w:p>")
            }
        }
        document.footerNote?.takeIf { it.isNotBlank() }?.let { note ->
            writeParagraph(
                out,
                listOf(NotesDocxRun(note, italic = true, color = "#666666")),
                null,
                NotesDocxParagraphStyle.QUOTE,
            )
        }
        out.append("<w:sectPr>")
        writeSectionProperties(out, document.pages.last())
        out.append("</w:sectPr></w:body></w:document>")
        return out.toString()
    }

    private fun writeSectionProperties(out: StringBuilder, page: NotesDocxPage) {
        val width = Math.round(page.widthPt * 20.0).coerceAtLeast(144)
        val height = Math.round(page.heightPt * 20.0).coerceAtLeast(144)
        out.append("<w:pgSz w:w=\"").append(width).append("\" w:h=\"").append(height).append("\"/>")
        out.append("<w:pgMar w:top=\"720\" w:right=\"720\" w:bottom=\"720\" w:left=\"720\"")
            .append(" w:header=\"0\" w:footer=\"0\" w:gutter=\"0\"/>")
        out.append("<w:cols w:space=\"720\"/>")
    }

    private fun writeBlock(out: StringBuilder, block: NotesDocxBlock) {
        when (block) {
            is NotesDocxBlock.Title -> writeParagraph(out, block.runs, "Title", null)
            is NotesDocxBlock.Heading -> writeParagraph(
                out,
                block.runs,
                "Heading" + block.level.coerceIn(1, 6),
                null,
            )
            is NotesDocxBlock.Paragraph -> writeParagraph(out, block.runs, null, block.style)
            is NotesDocxBlock.ListItem -> {
                lists = true
                val numId = if (block.ordered) 2 else 1
                out.append("<w:p><w:pPr><w:numPr><w:ilvl w:val=\"")
                    .append(block.level.coerceIn(0, 2))
                    .append("\"/><w:numId w:val=\"").append(numId)
                    .append("\"/></w:numPr></w:pPr>")
                writeRuns(out, block.runs)
                out.append("</w:p>")
            }
            is NotesDocxBlock.Table -> writeTable(out, block)
            is NotesDocxBlock.Image -> {
                out.append("<w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\" w:line=\"20\"")
                    .append(" w:lineRule=\"exact\"/></w:pPr><w:r>")
                writeDrawing(out, block.image)
                out.append("</w:r></w:p>")
            }
            NotesDocxBlock.Divider -> out.append(
                "<w:p><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"C8C8C8\"/></w:pBdr></w:pPr></w:p>",
            )
        }
    }

    private fun writeParagraph(
        out: StringBuilder,
        runs: List<NotesDocxRun>,
        styleID: String?,
        paragraphStyle: NotesDocxParagraphStyle?,
    ) {
        out.append("<w:p><w:pPr>")
        if (styleID != null) out.append("<w:pStyle w:val=\"").append(styleID).append("\"/>")
        when (paragraphStyle) {
            NotesDocxParagraphStyle.QUOTE -> out.append("<w:pStyle w:val=\"Quote\"/>")
            NotesDocxParagraphStyle.CODE -> out.append("<w:pStyle w:val=\"Code\"/>")
            NotesDocxParagraphStyle.BODY, null -> Unit
        }
        out.append("</w:pPr>")
        writeRuns(out, runs)
        out.append("</w:p>")
    }

    private fun writeRuns(out: StringBuilder, runs: List<NotesDocxRun>) {
        for (run in runs) {
            val url = run.hyperlinkURL?.takeIf { isSupportedHyperlink(it) }
            if (url != null) {
                val id = hyperlinks.getOrPut(url) { "rIdLink" + (nextHyperlink++) }
                out.append("<w:hyperlink r:id=\"").append(id).append("\" w:history=\"1\">")
                writeRun(out, run.copy(hyperlinkURL = null))
                out.append("</w:hyperlink>")
            } else {
                writeRun(out, run.copy(hyperlinkURL = null))
            }
        }
    }

    private fun writeRun(out: StringBuilder, run: NotesDocxRun) {
        val text = cleanText(run.text)
        if (text.isEmpty()) return
        out.append("<w:r><w:rPr>")
        val face = if (run.monospace) "Consolas" else "Arial"
        out.append("<w:rFonts w:ascii=\"").append(face)
            .append("\" w:hAnsi=\"").append(face)
            .append("\" w:eastAsia=\"Noto Sans CJK SC\" w:cs=\"").append(face).append("\"/>")
        if (run.bold) out.append("<w:b/><w:bCs/>")
        if (run.italic) out.append("<w:i/><w:iCs/>")
        run.color?.let { color ->
            val rgb = color.removePrefix("#")
            val six = if (rgb.length == 8) rgb.substring(2) else rgb
            out.append("<w:color w:val=\"").append(six.uppercase(Locale.ROOT)).append("\"/>")
        }
        run.fontSizePt?.let { size ->
            val halfPoints = Math.round(size * 2.0).toInt().coerceIn(2, 3_276)
            out.append("<w:sz w:val=\"").append(halfPoints).append("\"/>")
            out.append("<w:szCs w:val=\"").append(halfPoints).append("\"/>")
        }
        out.append("</w:rPr>")
        appendText(out, text)
        out.append("</w:r>")
    }

    /** Emits text with explicit breaks/tabs; Word never treats it as markup. */
    private fun appendText(out: StringBuilder, text: String) {
        var first = true
        var i = 0
        val buffer = StringBuilder()
        fun flush() {
            if (buffer.isEmpty()) return
            out.append("<w:t xml:space=\"preserve\">").append(xmlText(buffer.toString())).append("</w:t>")
            buffer.setLength(0)
        }
        while (i < text.length) {
            when (val c = text[i]) {
                '\n' -> {
                    flush()
                    out.append("<w:br/>")
                }
                '\t' -> {
                    flush()
                    out.append("<w:tab/>")
                }
                '\r' -> Unit
                else -> {
                    if (first && c == ' ') out.append("<w:t xml:space=\"preserve\"> </w:t>").also { first = false }
                    else {
                        buffer.append(c)
                        first = false
                    }
                }
            }
            i++
        }
        flush()
    }

    private fun writeTable(out: StringBuilder, table: NotesDocxBlock.Table) {
        val columns = table.rows.first().cells.size
        out.append("<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/>")
            .append("<w:tblW w:w=\"0\" w:type=\"auto\"/>")
            .append("<w:tblBorders>")
            .append("<w:top w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"BFBFBF\"/>")
            .append("<w:left w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"BFBFBF\"/>")
            .append("<w:bottom w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"BFBFBF\"/>")
            .append("<w:right w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"BFBFBF\"/>")
            .append("<w:insideH w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"BFBFBF\"/>")
            .append("<w:insideV w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"BFBFBF\"/>")
            .append("</w:tblBorders><w:tblLook w:val=\"04A0\" w:firstRow=\"1\" w:lastRow=\"0\"")
            .append(" w:firstColumn=\"1\" w:lastColumn=\"0\" w:noHBand=\"0\" w:noVBand=\"1\"/>")
            .append("</w:tblPr><w:tblGrid>")
        repeat(columns) { out.append("<w:gridCol w:w=\"2400\"/>") }
        out.append("</w:tblGrid>")
        table.rows.forEach { row ->
            out.append("<w:tr>")
            if (row.header) out.append("<w:trPr><w:tblHeader/></w:trPr>")
            row.cells.forEach { cell ->
                out.append("<w:tc><w:tcPr><w:tcW w:w=\"0\" w:type=\"auto\"/></w:tcPr><w:p>")
                if (cell.isNotBlank()) {
                    writeRun(out, NotesDocxRun(cell, bold = row.header))
                }
                out.append("</w:p></w:tc>")
            }
            out.append("</w:tr>")
        }
        out.append("</w:tbl>")
    }

    private fun writeDrawing(out: StringBuilder, image: NotesDocxImage) {
        val part = imageByRef[image] ?: throw NotesDocxBuildException("imageNotRegistered")
        val index = part.relationID.removePrefix("rIdImg")
        val name = "Picture $index"
        val behind = if (image.behindText) 1 else 0
        out.append("<w:drawing><wp:anchor distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\"")
            .append(" simplePos=\"0\" relativeHeight=\"0\" behindDoc=\"").append(behind)
            .append("\" locked=\"0\" layoutInCell=\"1\" allowOverlap=\"1\">")
            .append("<wp:simplePos x=\"0\" y=\"0\"/>")
            .append("<wp:positionH relativeFrom=\"page\"><wp:posOffset>")
            .append(image.leftEmu).append("</wp:posOffset></wp:positionH>")
            .append("<wp:positionV relativeFrom=\"page\"><wp:posOffset>")
            .append(image.topEmu).append("</wp:posOffset></wp:positionV>")
            .append("<wp:extent cx=\"").append(image.widthEmu).append("\" cy=\"")
            .append(image.heightEmu).append("\"/>")
            .append("<wp:effectExtent l=\"0\" t=\"0\" r=\"0\" b=\"0\"/><wp:wrapNone/>")
            .append("<wp:docPr id=\"").append(index).append("\" name=\"").append(name)
            .append("\" descr=\"").append(xmlAttr(cleanText(image.altText))).append("\"/>")
            .append("<a:graphic><a:graphicData uri=\"")
            .append(PICTURE_NS).append("\"><pic:pic><pic:nvPicPr><pic:cNvPr id=\"")
            .append(index).append("\" name=\"").append(name).append("\"/><pic:cNvPicPr/>")
            .append("</pic:nvPicPr><pic:blipFill><a:blip r:embed=\"")
            .append(part.relationID).append("\"/><a:stretch><a:fillRect/></a:stretch>")
            .append("</pic:blipFill><pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"")
            .append(image.widthEmu).append("\" cy=\"").append(image.heightEmu)
            .append("\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom>")
            .append("</pic:spPr></pic:pic></a:graphicData></a:graphic></wp:anchor></w:drawing>")
    }

    fun relationshipsXML(): String {
        val out = StringBuilder()
        out.append(XML_HEADER).append("<Relationships xmlns=\"").append(REL_NS).append("\">")
        out.append("<Relationship Id=\"rId1\" Type=\"").append(REL_OFFICE_NS)
            .append("/styles\" Target=\"styles.xml\"/>")
        if (lists) {
            out.append("<Relationship Id=\"rId2\" Type=\"").append(REL_OFFICE_NS)
                .append("/numbering\" Target=\"numbering.xml\"/>")
        }
        imageParts.forEach { part ->
            out.append("<Relationship Id=\"").append(part.relationID).append("\" Type=\"")
                .append(REL_OFFICE_NS).append("/image\" Target=\"media/")
                .append(part.partName.substringAfter("word/media/")).append("\"/>")
        }
        hyperlinks.forEach { (url, id) ->
            out.append("<Relationship Id=\"").append(id).append("\" Type=\"")
                .append(REL_OFFICE_NS).append("/hyperlink\" Target=\"")
                .append(xmlAttr(url)).append("\" TargetMode=\"External\"/>")
        }
        out.append("</Relationships>")
        return out.toString()
    }
}

private fun cleanText(raw: String): String {
    if (raw.isEmpty()) return ""
    val out = StringBuilder(raw.length)
    var i = 0
    while (i < raw.length) {
        val c = raw[i]
        when {
            c == '\n' || c == '\r' || c == '\t' -> out.append(c)
            c.code < 0x20 -> Unit
            c.isHighSurrogate() && i + 1 < raw.length && raw[i + 1].isLowSurrogate() -> {
                out.append(c).append(raw[i + 1])
                i++
            }
            c.isSurrogate() -> Unit
            c == '\uFFFE' || c == '\uFFFF' -> Unit
            else -> out.append(c)
        }
        i++
    }
    return out.toString()
}

private fun xmlText(value: String): String = buildString(value.length + 16) {
    for (ch in value) {
        when (ch) {
            '&' -> append("&amp;")
            '<' -> append("&lt;")
            '>' -> append("&gt;")
            else -> append(ch)
        }
    }
}

private fun xmlAttr(value: String): String = buildString(value.length + 16) {
    for (ch in value) {
        when (ch) {
            '&' -> append("&amp;")
            '<' -> append("&lt;")
            '>' -> append("&gt;")
            '"' -> append("&quot;")
            '\'' -> append("&apos;")
            else -> append(ch)
        }
    }
}

private fun escapeForAttribute(value: String): String = cleanText(value).replace('\n', ' ').replace('\r', ' ')

private fun hex(bytes: ByteArray): String {
    val out = StringBuilder(bytes.size * 2)
    for (b in bytes) {
        val value = b.toInt() and 0xFF
        out.append(HEX[value ushr 4]).append(HEX[value and 0x0F])
    }
    return out.toString()
}

private val HEX = "0123456789abcdef".toCharArray()

public object NotesDocxPackageBuilder {

    public const val MAX_PAGES: Int = 500
    public const val MAX_BLOCKS_PER_PAGE: Int = 2_000
    public const val MAX_RUNS_PER_BLOCK: Int = 500
    public const val MAX_TABLE_ROWS: Int = 500
    public const val MAX_TABLE_COLUMNS: Int = 64
    public const val MAX_IMAGES: Int = 1_024
    public const val MAX_IMAGE_BYTES: Int = 8 * 1024 * 1024
    public const val MAX_TEXT_BYTES: Int = 8 * 1024 * 1024
    public const val MAX_TOTAL_BYTES: Int = 64 * 1024 * 1024
    /** Word's own maximum page edge is 22in (1584pt). */
    public const val MAX_PAGE_PT: Double = 1_584.0
    public const val MIN_PAGE_PT: Double = 72.0

    public fun build(
        document: NotesDocxDocument,
        factory: DocumentBuilderFactory = DocumentBuilderFactory.newInstance(),
    ): NotesDocxBuildResult {
        if (document.pages.isEmpty()) throw NotesDocxBuildException("noPages")
        if (document.pages.size > MAX_PAGES) throw NotesDocxBuildException("tooManyPages")
        if (document.title.encodeToByteArray().size > MAX_TEXT_BYTES) {
            throw NotesDocxBuildException("titleTooLarge")
        }
        if ((document.footerNote?.encodeToByteArray()?.size ?: 0) > MAX_TEXT_BYTES) {
            throw NotesDocxBuildException("footerTooLarge")
        }
        if (document.creator.encodeToByteArray().size > MAX_TEXT_BYTES) {
            throw NotesDocxBuildException("creatorTooLarge")
        }
        val imageParts = collectImages(document)
        val body = BodyWriter(imageParts)
        val bodyXML = body.write(document)
        val relsXML = body.relationshipsXML()
        val numbering = body.hasLists
        val parts = LinkedHashMap<String, ByteArray>()
        parts["[Content_Types].xml"] = contentTypesXML(imageParts, numbering).encodeToByteArray()
        parts["_rels/.rels"] = (
            XML_HEADER +
                "<Relationships xmlns=\"$REL_NS\">" +
                "<Relationship Id=\"rId1\" Type=\"$OFFICE_DOCUMENT_REL\" Target=\"word/document.xml\"/>" +
                "<Relationship Id=\"rId2\" Type=\"$CORE_PROPS_REL\" Target=\"docProps/core.xml\"/>" +
                "</Relationships>"
            ).encodeToByteArray()
        parts["docProps/core.xml"] = corePropertiesXML(document.title, document.creator).encodeToByteArray()
        parts["word/document.xml"] = bodyXML.encodeToByteArray()
        parts["word/_rels/document.xml.rels"] = relsXML.encodeToByteArray()
        parts["word/styles.xml"] = stylesXML().encodeToByteArray()
        if (numbering) parts["word/numbering.xml"] = numberingXML().encodeToByteArray()
        for (part in imageParts) {
            parts[part.partName] = part.image.bytes
        }
        val bytes = zip(parts)
        val validation = validate(bytes, document.pages.size, imageParts, factory)
        if (!validation.ok) throw NotesDocxBuildException(validation.reason ?: "invalidPackage")
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
        return NotesDocxBuildResult(
            bytes = bytes,
            sha256 = hex(digest),
            pageCount = document.pages.size,
            imageCount = imageParts.size,
            byteCount = bytes.size.toLong(),
        )
    }

    /* --------------------------- content collection --------------------------- */

    private fun collectImages(document: NotesDocxDocument): List<ImagePart> {
        val collected = ArrayList<NotesDocxImage>()
        for (page in document.pages) {
            validatePage(page)
            page.background?.let { collected += it }
            for (block in page.blocks) {
                if (block is NotesDocxBlock.Image) collected += block.image
            }
        }
        if (collected.isEmpty()) return emptyList()
        if (collected.size > MAX_IMAGES) throw NotesDocxBuildException("tooManyImages")
        var total = 0L
        val parts = ArrayList<ImagePart>(collected.size)
        collected.forEachIndexed { index, image ->
            if (image.bytes.isEmpty()) throw NotesDocxBuildException("emptyImage")
            if (image.bytes.size > MAX_IMAGE_BYTES) throw NotesDocxBuildException("imageTooLarge")
            total += image.bytes.size
            if (total > MAX_TOTAL_BYTES) throw NotesDocxBuildException("imagesTooLarge")
            if (image.widthEmu <= 0L || image.heightEmu <= 0L) throw NotesDocxBuildException("imageSize")
            if (image.widthEmu > MAX_PAGE_PT.toLong() * 12_700L ||
                image.heightEmu > MAX_PAGE_PT.toLong() * 12_700L
            ) {
                throw NotesDocxBuildException("imageSize")
            }
            if (image.leftEmu < 0L || image.topEmu < 0L) throw NotesDocxBuildException("imagePosition")
            val detected = detectImageType(image.bytes)
                ?: throw NotesDocxBuildException("imageFormat")
            val declared = image.mediaType.lowercase(Locale.ROOT).substringBefore(';').trim()
            if (declared != detected) throw NotesDocxBuildException("imageTypeMismatch")
            val extension = if (detected == IMAGE_PNG) "png" else "jpg"
            val digest = hex(MessageDigest.getInstance("SHA-256").digest(image.bytes))
            parts += ImagePart(
                image = image,
                relationID = "rIdImg${index + 1}",
                partName = "word/media/image${index + 1}.$extension",
                extension = extension,
                digest = digest,
            )
        }
        return parts
    }

    private fun validatePage(page: NotesDocxPage) {
        if (!page.widthPt.isFinite() || !page.heightPt.isFinite()) {
            throw NotesDocxBuildException("pageSize")
        }
        if (page.widthPt < MIN_PAGE_PT || page.heightPt < MIN_PAGE_PT) {
            throw NotesDocxBuildException("pageSize")
        }
        if (page.widthPt > MAX_PAGE_PT || page.heightPt > MAX_PAGE_PT) {
            throw NotesDocxBuildException("pageTooLarge")
        }
        if (page.blocks.size > MAX_BLOCKS_PER_PAGE) throw NotesDocxBuildException("tooManyBlocks")
        for (block in page.blocks) {
            when (block) {
                is NotesDocxBlock.Title -> validateRuns(block.runs)
                is NotesDocxBlock.Heading -> {
                    if (block.level !in 1..6) throw NotesDocxBuildException("headingLevel")
                    validateRuns(block.runs)
                }
                is NotesDocxBlock.Paragraph -> validateRuns(block.runs)
                is NotesDocxBlock.ListItem -> {
                    if (block.level !in 0..2) throw NotesDocxBuildException("listLevel")
                    validateRuns(block.runs)
                }
                is NotesDocxBlock.Table -> {
                    if (block.rows.isEmpty() || block.rows.size > MAX_TABLE_ROWS) {
                        throw NotesDocxBuildException("tableRows")
                    }
                    val columns = block.rows.first().cells.size
                    if (columns == 0 || columns > MAX_TABLE_COLUMNS) {
                        throw NotesDocxBuildException("tableColumns")
                    }
                    if (block.rows.any { it.cells.size != columns }) {
                        throw NotesDocxBuildException("tableShape")
                    }
                    block.rows.forEach { row ->
                        row.cells.forEach { cell ->
                            if (cell.encodeToByteArray().size > MAX_TEXT_BYTES) {
                                throw NotesDocxBuildException("tableCellTooLarge")
                            }
                        }
                    }
                }
                is NotesDocxBlock.Image -> {
                    val pageWidth = Math.round(page.widthPt * EMU_PER_POINT)
                    val pageHeight = Math.round(page.heightPt * EMU_PER_POINT)
                    if (block.image.leftEmu + block.image.widthEmu > pageWidth + 1_270L ||
                        block.image.topEmu + block.image.heightEmu > pageHeight + 1_270L
                    ) {
                        throw NotesDocxBuildException("imageOutOfPage")
                    }
                }
                NotesDocxBlock.Divider -> Unit
            }
        }
        page.background?.let { background ->
            val pageWidth = Math.round(page.widthPt * EMU_PER_POINT)
            val pageHeight = Math.round(page.heightPt * EMU_PER_POINT)
            if (background.leftEmu != 0L || background.topEmu != 0L ||
                background.widthEmu != pageWidth || background.heightEmu != pageHeight
            ) {
                throw NotesDocxBuildException("backgroundGeometry")
            }
            if (!background.behindText) throw NotesDocxBuildException("backgroundNotBehind")
        }
    }

    private fun validateRuns(runs: List<NotesDocxRun>) {
        if (runs.size > MAX_RUNS_PER_BLOCK) throw NotesDocxBuildException("tooManyRuns")
        for (run in runs) {
            if (run.text.encodeToByteArray().size > MAX_TEXT_BYTES) {
                throw NotesDocxBuildException("textTooLarge")
            }
            if (run.fontSizePt != null && (!run.fontSizePt.isFinite() || run.fontSizePt <= 0.0)) {
                throw NotesDocxBuildException("fontSize")
            }
            run.color?.let { color ->
                if (!Regex("^#[0-9A-Fa-f]{6}(?:[0-9A-Fa-f]{2})?$").matches(color)) {
                    throw NotesDocxBuildException("color")
                }
            }
            run.hyperlinkURL?.let { url ->
                if (!isSupportedHyperlink(url)) throw NotesDocxBuildException("hyperlink")
            }
        }
    }

    private fun detectImageType(bytes: ByteArray): String? {
        if (bytes.size >= 8 &&
            bytes[0] == 0x89.toByte() && bytes[1] == 0x50.toByte() && bytes[2] == 0x4E.toByte() &&
            bytes[3] == 0x47.toByte() && bytes[4] == 0x0D.toByte() && bytes[5] == 0x0A.toByte() &&
            bytes[6] == 0x1A.toByte() && bytes[7] == 0x0A.toByte()
        ) {
            return IMAGE_PNG
        }
        if (bytes.size >= 3 &&
            bytes[0] == 0xFF.toByte() && bytes[1] == 0xD8.toByte() && bytes[2] == 0xFF.toByte()
        ) {
            return IMAGE_JPEG
        }
        return null
    }

    /* ------------------------------- XML writer ------------------------------- */

    /* --------------------------- package XML parts --------------------------- */

    private fun contentTypesXML(imageParts: List<ImagePart>, numbering: Boolean): String {
        val imageExtensions = imageParts.map { it.extension }.toSortedSet()
        val out = StringBuilder()
        out.append(XML_HEADER).append("<Types xmlns=\"").append(CONTENT_TYPES_NS).append("\">")
        out.append("<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>")
        out.append("<Default Extension=\"xml\" ContentType=\"application/xml\"/>")
        for (extension in imageExtensions) {
            out.append("<Default Extension=\"").append(extension).append("\" ContentType=\"")
                .append(if (extension == "png") IMAGE_PNG else IMAGE_JPEG).append("\"/>")
        }
        out.append("<Override PartName=\"/word/document.xml\" ContentType=\"").append(MAIN_CONTENT_TYPE).append("\"/>")
        out.append("<Override PartName=\"/word/styles.xml\" ContentType=\"").append(STYLES_CONTENT_TYPE).append("\"/>")
        out.append("<Override PartName=\"/docProps/core.xml\" ContentType=\"").append(CORE_CONTENT_TYPE).append("\"/>")
        if (numbering) {
            out.append("<Override PartName=\"/word/numbering.xml\" ContentType=\"").append(NUMBERING_CONTENT_TYPE).append("\"/>")
        }
        out.append("</Types>")
        return out.toString()
    }

    private fun corePropertiesXML(title: String, creator: String): String {
        val safeCreator = escapeForAttribute(cleanText(creator).ifBlank { "Floe" })
        return XML_HEADER +
            "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\"" +
            " xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\"" +
            " xmlns:dcmitype=\"http://purl.org/dc/dcmitype/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">" +
            "<dc:title>" + xmlText(cleanText(title).ifBlank { "Notes" }) + "</dc:title>" +
            "<dc:creator>" + xmlText(safeCreator) + "</dc:creator>" +
            "<cp:lastModifiedBy>" + xmlText(safeCreator) + "</cp:lastModifiedBy>" +
            "</cp:coreProperties>"
    }

    private fun stylesXML(): String = XML_HEADER + """
        <w:styles xmlns:w="$WORD_NS">
        <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:eastAsia="Noto Sans CJK SC" w:cs="Arial"/><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>
        <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:after="240"/></w:pPr><w:rPr><w:b/><w:sz w:val="52"/><w:szCs w:val="52"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="320" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="60"/><w:szCs w:val="60"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="280" w:after="100"/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:sz w:val="52"/><w:szCs w:val="52"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="80"/><w:outlineLvl w:val="2"/></w:pPr><w:rPr><w:b/><w:sz w:val="48"/><w:szCs w:val="48"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Heading4"><w:name w:val="heading 4"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="200" w:after="60"/><w:outlineLvl w:val="3"/></w:pPr><w:rPr><w:b/><w:sz w:val="44"/><w:szCs w:val="44"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Heading5"><w:name w:val="heading 5"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="180" w:after="60"/><w:outlineLvl w:val="4"/></w:pPr><w:rPr><w:b/><w:sz w:val="40"/><w:szCs w:val="40"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Heading6"><w:name w:val="heading 6"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="160" w:after="40"/><w:outlineLvl w:val="5"/></w:pPr><w:rPr><w:b/><w:sz w:val="36"/><w:szCs w:val="36"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:ind w:left="720" w:right="720"/></w:pPr><w:rPr><w:i/><w:color w:val="555555"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:shd w:val="clear" w:color="auto" w:fill="F3F3F3"/><w:spacing w:after="80"/></w:pPr><w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas" w:cs="Consolas"/><w:sz w:val="20"/><w:szCs w:val="20"/></w:rPr></w:style>
        <w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:tblPr><w:tblBorders><w:top w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/><w:left w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/><w:bottom w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/><w:right w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/><w:insideH w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/><w:insideV w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/></w:tblBorders></w:tblPr></w:style>
        </w:styles>
    """.trimIndent()

    private fun numberingXML(): String = XML_HEADER + """
        <w:numbering xmlns:w="$WORD_NS">
        <w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="hybridMultilevel"/>
        <w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="•"/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial"/></w:rPr></w:lvl>
        <w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="◦"/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="1440" w:hanging="360"/></w:pPr><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial"/></w:rPr></w:lvl>
        <w:lvl w:ilvl="2"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="▪"/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="2160" w:hanging="360"/></w:pPr><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial"/></w:rPr></w:lvl>
        </w:abstractNum>
        <w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="hybridMultilevel"/>
        <w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl>
        <w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="lowerLetter"/><w:lvlText w:val="%2."/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="1440" w:hanging="360"/></w:pPr></w:lvl>
        <w:lvl w:ilvl="2"><w:start w:val="1"/><w:numFmt w:val="lowerRoman"/><w:lvlText w:val="%3."/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="2160" w:hanging="360"/></w:pPr></w:lvl>
        </w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
        <w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>
        </w:numbering>
    """.trimIndent()

    /* ------------------------------ validation ------------------------------ */

    private data class Validation(val ok: Boolean, val reason: String? = null)

    public fun validate(
        bytes: ByteArray,
        expectedPages: Int? = null,
        factory: DocumentBuilderFactory = DocumentBuilderFactory.newInstance(),
    ): NotesDocxValidation = validate(bytes, expectedPages, null, factory).let {
        NotesDocxValidation(it.ok, it.reason)
    }

    private fun validate(
        bytes: ByteArray,
        expectedPages: Int?,
        expectedImages: List<ImagePart>?,
        factory: DocumentBuilderFactory,
    ): Validation {
        if (bytes.isEmpty() || bytes.size > MAX_TOTAL_BYTES) return Validation(false, "size")
        val parts = LinkedHashMap<String, ByteArray>()
        var total = 0L
        try {
            ZipInputStream(ByteArrayInputStream(bytes)).use { input ->
                var entry: ZipEntry? = input.nextEntry
                while (entry != null) {
                    if (entry.isDirectory) return Validation(false, "directoryEntry")
                    val name = entry.name
                    if (!isSafeEntryName(name)) return Validation(false, "entryName")
                    if (parts.containsKey(name)) return Validation(false, "duplicateEntry")
                    if (parts.size >= 2_048) return Validation(false, "tooManyEntries")
                    val output = ByteArrayOutputStream()
                    val buffer = ByteArray(16 * 1024)
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        total += read
                        if (total > MAX_TOTAL_BYTES) return Validation(false, "expandedTooLarge")
                        output.write(buffer, 0, read)
                        if (output.size() > MAX_TOTAL_BYTES) return Validation(false, "partTooLarge")
                    }
                    parts[name] = output.toByteArray()
                    entry = input.nextEntry
                }
            }
        } catch (_: IOException) {
            return Validation(false, "notZip")
        }
        val contentTypes = parts["[Content_Types].xml"] ?: return Validation(false, "contentTypesMissing")
        val contentTypesDoc = parseXml(contentTypes, factory) ?: return Validation(false, "contentTypesInvalid")
        val overrides = contentTypesDoc.getElementsByTagNameNS(CONTENT_TYPES_NS, "Override")
        val declared = HashSet<String>()
        for (i in 0 until overrides.length) {
            val element = overrides.item(i) as? Element ?: continue
            val partName = element.getAttribute("PartName")
            if (partName.startsWith("/")) declared += partName.removePrefix("/")
        }
        if ("word/document.xml" !in declared) return Validation(false, "mainContentTypeMissing")
        if ("word/styles.xml" !in declared) return Validation(false, "stylesContentTypeMissing")
        val defaults = contentTypesDoc.getElementsByTagNameNS(CONTENT_TYPES_NS, "Default")
        val declaredDefaults = HashSet<String>()
        for (i in 0 until defaults.length) {
            val element = defaults.item(i) as? Element ?: continue
            declaredDefaults += element.getAttribute("Extension").lowercase(Locale.ROOT)
        }
        if ("rels" !in declaredDefaults || "xml" !in declaredDefaults) {
            return Validation(false, "contentTypeDefaultsMissing")
        }
        val hasNumbering = parts.containsKey("word/numbering.xml")
        if (hasNumbering && "word/numbering.xml" !in declared) {
            return Validation(false, "numberingContentTypeMissing")
        }
        val documentXML = parts["word/document.xml"] ?: return Validation(false, "documentMissing")
        val documentDoc = parseXml(documentXML, factory) ?: return Validation(false, "documentInvalid")
        val root = documentDoc.documentElement ?: return Validation(false, "documentInvalid")
        if (root.localName != "document") return Validation(false, "documentRoot")
        if (root.namespaceURI != WORD_NS) return Validation(false, "documentNamespace")
        if (expectedPages != null) {
            val sections = documentDoc.getElementsByTagNameNS(WORD_NS, "sectPr").length
            if (sections != expectedPages) return Validation(false, "pageSectionMismatch")
        }
        for (required in listOf("_rels/.rels", "word/styles.xml")) {
            if (!parts.containsKey(required)) return Validation(false, "requiredPart:$required")
        }
        val styles = parseXml(parts.getValue("word/styles.xml"), factory)
            ?: return Validation(false, "stylesInvalid")
        if (styles.documentElement?.localName != "styles") return Validation(false, "stylesRoot")
        if (hasNumbering) {
            val numbering = parseXml(parts.getValue("word/numbering.xml"), factory)
                ?: return Validation(false, "numberingInvalid")
            if (numbering.documentElement?.localName != "numbering") return Validation(false, "numberingRoot")
        }
        val rootRels = parseRelationshipTargets(
            parts["_rels/.rels"] ?: return Validation(false, "rootRelsMissing"),
            "",
            factory,
        ) ?: return Validation(false, "rootRelsInvalid")
        if ("word/document.xml" !in rootRels.internalTargets) {
            return Validation(false, "mainRelationshipMissing")
        }
        if (rootRels.internalTargets.any { !parts.containsKey(it) }) {
            return Validation(false, "rootRelationshipTargetMissing")
        }
        val rels = parseRelationshipTargets(
            parts["word/_rels/document.xml.rels"] ?: return Validation(false, "documentRelsMissing"),
            "word/",
            factory,
        ) ?: return Validation(false, "documentRelsInvalid")
        if (rels.internalTargets.any { !parts.containsKey(it) }) {
            return Validation(false, "relationshipTargetMissing")
        }
        val blips = documentDoc.getElementsByTagNameNS(DRAWING_NS, "blip")
        var embedCount = 0
        for (i in 0 until blips.length) {
            val blip = blips.item(i) as? Element ?: continue
            val embed = blip.getAttributeNS(REL_OFFICE_NS, "embed")
            if (embed.isEmpty()) continue
            embedCount += 1
            if (embed !in rels.byID) return Validation(false, "imageRelationshipMissing")
        }
        if (expectedImages != null) {
            for (image in expectedImages) {
                if (image.extension !in declaredDefaults) {
                    return Validation(false, "imageContentTypeMissing")
                }
            }
            if (embedCount != expectedImages.size) return Validation(false, "imageCountMismatch")
            for (image in expectedImages) {
                val part = parts[image.partName] ?: return Validation(false, "imagePartMissing")
                val digest = hex(MessageDigest.getInstance("SHA-256").digest(part))
                if (digest != image.digest) return Validation(false, "imageDigestMismatch")
                if ("word/" + (rels.byID[image.relationID]?.target ?: "") != image.partName) {
                    return Validation(false, "imageRelationshipTarget")
                }
            }
        }
        val hyperlinks = documentDoc.getElementsByTagNameNS(WORD_NS, "hyperlink")
        for (i in 0 until hyperlinks.length) {
            val link = hyperlinks.item(i) as? Element ?: continue
            val id = link.getAttributeNS(REL_OFFICE_NS, "id")
            val relationship = rels.byID[id] ?: return Validation(false, "hyperlinkRelationshipMissing")
            if (!relationship.external) return Validation(false, "hyperlinkNotExternal")
            if (!isSupportedHyperlink(relationship.target)) return Validation(false, "hyperlinkTarget")
        }
        for (entry in parts.entries) {
            if (entry.key.endsWith(".xml") || entry.key.endsWith(".rels")) {
                if (parseXml(entry.value, factory) == null) {
                    return Validation(false, "partXmlInvalid:" + entry.key)
                }
            }
        }
        return Validation(true)
    }

    private data class Relationship(
        val id: String,
        val target: String,
        val external: Boolean,
    )

    private data class Relationships(
        val byID: Map<String, Relationship>,
        val internalTargets: Set<String>,
    )

    private fun parseRelationshipTargets(
        bytes: ByteArray,
        base: String,
        factory: DocumentBuilderFactory,
    ): Relationships? {
        val doc = parseXml(bytes, factory) ?: return null
        val root = doc.documentElement ?: return null
        if (root.localName != "Relationships") return null
        val nodes = doc.getElementsByTagNameNS(REL_NS, "Relationship")
        val byID = LinkedHashMap<String, Relationship>()
        val internalTargets = LinkedHashSet<String>()
        for (i in 0 until nodes.length) {
            val element = nodes.item(i) as? Element ?: continue
            val id = element.getAttribute("Id")
            val target = element.getAttribute("Target")
            val external = element.getAttribute("TargetMode").equals("External", ignoreCase = true)
            if (id.isBlank() || target.isBlank() || byID.containsKey(id)) return null
            if (!external) {
                if (target.startsWith('/') || target.contains("..") || target.contains('\\')) return null
                val resolved = base + target
                if (!isSafeEntryName(resolved)) return null
                internalTargets += resolved
            }
            byID[id] = Relationship(id, target, external)
        }
        return Relationships(byID, internalTargets)
    }

    private fun parseXml(bytes: ByteArray, factory: DocumentBuilderFactory): org.w3c.dom.Document? = try {
        factory.isNamespaceAware = true
        runCatching { factory.isXIncludeAware = false }
        factory.setExpandEntityReferences(false)
        runCatching {
            factory.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true)
        }
        runCatching {
            factory.setFeature("http://xml.org/sax/features/external-general-entities", false)
        }
        runCatching {
            factory.setFeature("http://xml.org/sax/features/external-parameter-entities", false)
        }
        runCatching {
            factory.setFeature("http://apache.org/xml/features/nonvalidating/load-external-dtd", false)
        }
        factory.newDocumentBuilder().parse(ByteArrayInputStream(bytes))
    } catch (_: Exception) {
        null
    }

    /* -------------------------------- helpers -------------------------------- */

    private fun isSafeEntryName(name: String): Boolean =
        name.isNotEmpty() && !name.startsWith('/') && !name.contains('\\') &&
            !name.contains("..") && name.none { it.code < 0x20 }

    private fun zip(parts: Map<String, ByteArray>): ByteArray {
        val output = ByteArrayOutputStream()
        ZipOutputStream(output).use { zip ->
            for ((name, content) in parts) {
                if (!isSafeEntryName(name)) throw NotesDocxBuildException("entryName")
                if (content.size > MAX_TOTAL_BYTES) throw NotesDocxBuildException("partTooLarge")
                val entry = ZipEntry(name)
                entry.time = 315532800000L // 1980-01-01, deterministic
                zip.putNextEntry(entry)
                zip.write(content)
                zip.closeEntry()
            }
        }
        return output.toByteArray()
    }
}

public data class NotesDocxValidation(val ok: Boolean, val reason: String? = null)
