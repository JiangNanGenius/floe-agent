// SPDX-License-Identifier: MPL-2.0
package com.floe.android.notesplatform

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.Locale
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream
import javax.xml.parsers.DocumentBuilderFactory
import org.w3c.dom.Element

internal enum class NotesOoxmlKind(
    val extension: String,
    val mimeType: String,
    val mainPart: String,
    val mainContentType: String,
    val rootLocalName: String,
) {
    DOCX(
        "docx",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "word/document.xml",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml",
        "document",
    ),
    XLSX(
        "xlsx",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "xl/workbook.xml",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml",
        "workbook",
    ),
    PPTX(
        "pptx",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "ppt/presentation.xml",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml",
        "presentation",
    );

    companion object {
        fun forExtension(extension: String?): NotesOoxmlKind? =
            entries.firstOrNull { it.extension == NotesPlatformNames.normalizeExtension(extension) }
    }
}

internal data class NotesOoxmlValidation(val ok: Boolean, val reason: String? = null) {
    companion object {
        val Valid = NotesOoxmlValidation(true)
        fun invalid(reason: String) = NotesOoxmlValidation(false, reason)
    }
}

/**
 * Minimal, self-authored OOXML blanks.
 *
 * The three containers mirror the repository's synthetic Office fixtures
 * (`fixtures/office/...`): only the parts the pinned engine needs to recognise
 * a valid document, workbook or deck are emitted. The title is inert text:
 * XML-escaped, stripped of XML-1.0-illegal controls, and never used as a path.
 * No code, macro, external relation or host interpreter is involved.
 *
 * Every produced container is re-opened and structurally validated by
 * [validate] before it is handed to the Notes import path.
 */
internal object NotesOoxmlTemplates {
    const val MAX_ENTRIES = 64
    const val MAX_PART_BYTES = 4 * 1024 * 1024
    const val MAX_TOTAL_BYTES = 16 * 1024 * 1024
    const val MAX_TITLE_CHARS = 200

    private const val XML_HEADER = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
    private const val REL_NS = "http://schemas.openxmlformats.org/package/2006/relationships"
    private const val CONTENT_TYPES_NS = "http://schemas.openxmlformats.org/package/2006/content-types"
    private const val OFFICE_DOCUMENT_REL =
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
    private const val WORD_NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    private const val SHEET_NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    private const val PRESENTATION_NS =
        "http://schemas.openxmlformats.org/presentationml/2006/main"
    private const val DRAWING_NS = "http://schemas.openxmlformats.org/drawingml/2006/main"
    private const val REL_OFFICE_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    fun create(kind: NotesOoxmlKind, title: String): ByteArray {
        val cleanTitle = cleanText(title).ifBlank { "Untitled" }.take(MAX_TITLE_CHARS)
        val parts = when (kind) {
            NotesOoxmlKind.DOCX -> docx(cleanTitle)
            NotesOoxmlKind.XLSX -> xlsx(cleanTitle)
            NotesOoxmlKind.PPTX -> pptx(cleanTitle)
        }
        return zip(parts)
    }

    /**
     * Bounded structural validation: ZIP container, no traversal/duplicate
     * names/size bombs, `[Content_Types].xml` declares the exact main part and
     * content type, and the main part parses as the expected XML root.
     */
    fun validate(bytes: ByteArray, kind: NotesOoxmlKind): NotesOoxmlValidation =
        validate(bytes, kind, DocumentBuilderFactory.newInstance())

    internal fun validate(
        bytes: ByteArray,
        kind: NotesOoxmlKind,
        factory: DocumentBuilderFactory,
    ): NotesOoxmlValidation {
        if (bytes.isEmpty() || bytes.size > MAX_TOTAL_BYTES) return NotesOoxmlValidation.invalid("size")
        val parts = LinkedHashMap<String, ByteArray>()
        var total = 0L
        try {
            ZipInputStream(ByteArrayInputStream(bytes)).use { input ->
                var entry: ZipEntry? = input.nextEntry
                while (entry != null) {
                    if (entry.isDirectory) return NotesOoxmlValidation.invalid("directoryEntry")
                    val name = entry.name
                    if (name.isEmpty() || name.startsWith('/') || name.contains("..") ||
                        name.contains('\\') || name.any { it.code < 0x20 }
                    ) {
                        return NotesOoxmlValidation.invalid("entryName")
                    }
                    if (parts.containsKey(name)) return NotesOoxmlValidation.invalid("duplicateEntry")
                    if (parts.size >= MAX_ENTRIES) return NotesOoxmlValidation.invalid("tooManyEntries")
                    val output = ByteArrayOutputStream()
                    val buffer = ByteArray(16 * 1024)
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        total += read
                        if (total > MAX_TOTAL_BYTES) return NotesOoxmlValidation.invalid("expandedTooLarge")
                        output.write(buffer, 0, read)
                        if (output.size() > MAX_PART_BYTES) return NotesOoxmlValidation.invalid("partTooLarge")
                    }
                    parts[name] = output.toByteArray()
                    entry = input.nextEntry
                }
            }
        } catch (_: Exception) {
            return NotesOoxmlValidation.invalid("notZip")
        }
        if (parts.isEmpty()) return NotesOoxmlValidation.invalid("emptyZip")
        val contentTypes = parts["[Content_Types].xml"]
            ?: return NotesOoxmlValidation.invalid("contentTypesMissing")
        val contentTypesDoc = parseXml(contentTypes, factory)
            ?: return NotesOoxmlValidation.invalid("contentTypesInvalid")
        val overrides = contentTypesDoc.getElementsByTagNameNS(CONTENT_TYPES_NS, "Override")
        var declared = false
        for (i in 0 until overrides.length) {
            val element = overrides.item(i) as? Element ?: continue
            val partName = element.getAttribute("PartName")
            if (partName == "/" + kind.mainPart &&
                element.getAttribute("ContentType") == kind.mainContentType
            ) {
                declared = true
                break
            }
        }
        if (!declared) return NotesOoxmlValidation.invalid("mainContentTypeMissing")
        for (required in requiredParts(kind)) {
            if (!parts.containsKey(required)) return NotesOoxmlValidation.invalid("requiredPart:$required")
        }
        val mainBytes = parts[kind.mainPart] ?: return NotesOoxmlValidation.invalid("mainPartMissing")
        val mainDoc = parseXml(mainBytes, factory)
            ?: return NotesOoxmlValidation.invalid("mainPartInvalid")
        val root = mainDoc.documentElement ?: return NotesOoxmlValidation.invalid("mainPartInvalid")
        if (root.localName != kind.rootLocalName) return NotesOoxmlValidation.invalid("mainRoot")
        return NotesOoxmlValidation.Valid
    }

    /** True when [bytes] look like a bounded OOXML container of [kind]. */
    fun validate(bytes: ByteArray, extension: String?): NotesOoxmlValidation {
        val kind = NotesOoxmlKind.forExtension(extension)
            ?: return NotesOoxmlValidation.invalid("unsupportedFormat")
        return validate(bytes, kind)
    }

    private fun requiredParts(kind: NotesOoxmlKind): List<String> = when (kind) {
        NotesOoxmlKind.DOCX -> listOf("_rels/.rels", "word/document.xml")
        NotesOoxmlKind.XLSX -> listOf(
            "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels",
            "xl/worksheets/sheet1.xml",
        )
        NotesOoxmlKind.PPTX -> listOf(
            "_rels/.rels", "ppt/presentation.xml", "ppt/_rels/presentation.xml.rels",
            "ppt/theme/theme1.xml", "ppt/slideMasters/slideMaster1.xml",
            "ppt/slideLayouts/slideLayout1.xml", "ppt/slides/slide1.xml",
        )
    }

    private fun docx(title: String): List<Pair<String, String>> = listOf(
        "[Content_Types].xml" to
            "$XML_HEADER<Types xmlns=\"$CONTENT_TYPES_NS\">" +
            "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>" +
            "<Default Extension=\"xml\" ContentType=\"application/xml\"/>" +
            "<Override PartName=\"/word/document.xml\" ContentType=\"${NotesOoxmlKind.DOCX.mainContentType}\"/>" +
            "</Types>",
        "_rels/.rels" to
            "$XML_HEADER<Relationships xmlns=\"$REL_NS\"><Relationship Id=\"rId1\" Type=\"$OFFICE_DOCUMENT_REL\" Target=\"word/document.xml\"/></Relationships>",
        "word/document.xml" to
            "$XML_HEADER<w:document xmlns:w=\"$WORD_NS\"><w:body>" +
            "<w:p><w:r><w:t xml:space=\"preserve\">${xmlText(title)}</w:t></w:r></w:p>" +
            "<w:p/><w:sectPr><w:pgSz w:w=\"12240\" w:h=\"15840\"/>" +
            "<w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\"/>" +
            "</w:sectPr></w:body></w:document>",
    )

    private fun xlsx(title: String): List<Pair<String, String>> {
        val sheetName = sheetName(title)
        return listOf(
            "[Content_Types].xml" to
                "$XML_HEADER<Types xmlns=\"$CONTENT_TYPES_NS\">" +
                "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>" +
                "<Default Extension=\"xml\" ContentType=\"application/xml\"/>" +
                "<Override PartName=\"/xl/workbook.xml\" ContentType=\"${NotesOoxmlKind.XLSX.mainContentType}\"/>" +
                "<Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" +
                "</Types>",
            "_rels/.rels" to
                "$XML_HEADER<Relationships xmlns=\"$REL_NS\"><Relationship Id=\"rId1\" Type=\"$OFFICE_DOCUMENT_REL\" Target=\"xl/workbook.xml\"/></Relationships>",
            "xl/workbook.xml" to
                "$XML_HEADER<workbook xmlns=\"$SHEET_NS\" xmlns:r=\"$REL_OFFICE_NS\">" +
                "<sheets><sheet name=\"${xmlAttr(sheetName)}\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>",
            "xl/_rels/workbook.xml.rels" to
                "$XML_HEADER<Relationships xmlns=\"$REL_NS\">" +
                "<Relationship Id=\"rId1\" Type=\"$REL_OFFICE_NS/worksheet\" Target=\"worksheets/sheet1.xml\"/>" +
                "</Relationships>",
            "xl/worksheets/sheet1.xml" to
                "$XML_HEADER<worksheet xmlns=\"$SHEET_NS\"><dimension ref=\"A1\"/><sheetData/></worksheet>",
        )
    }

    private fun pptx(title: String): List<Pair<String, String>> = listOf(
        "[Content_Types].xml" to
            "$XML_HEADER<Types xmlns=\"$CONTENT_TYPES_NS\">" +
            "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>" +
            "<Default Extension=\"xml\" ContentType=\"application/xml\"/>" +
            "<Override PartName=\"/ppt/presentation.xml\" ContentType=\"${NotesOoxmlKind.PPTX.mainContentType}\"/>" +
            "<Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml\"/>" +
            "<Override PartName=\"/ppt/slideLayouts/slideLayout1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml\"/>" +
            "<Override PartName=\"/ppt/slides/slide1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>" +
            "<Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>" +
            "</Types>",
        "_rels/.rels" to
            "$XML_HEADER<Relationships xmlns=\"$REL_NS\"><Relationship Id=\"rId1\" Type=\"$OFFICE_DOCUMENT_REL\" Target=\"ppt/presentation.xml\"/></Relationships>",
        "ppt/presentation.xml" to
            "$XML_HEADER<p:presentation xmlns:a=\"$DRAWING_NS\" xmlns:r=\"$REL_OFFICE_NS\" xmlns:p=\"$PRESENTATION_NS\">" +
            "<p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst>" +
            "<p:sldIdLst><p:sldId id=\"256\" r:id=\"rId2\"/></p:sldIdLst>" +
            "<p:sldSz cx=\"9144000\" cy=\"6858000\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/>" +
            "</p:presentation>",
        "ppt/_rels/presentation.xml.rels" to
            "$XML_HEADER<Relationships xmlns=\"$REL_NS\">" +
            "<Relationship Id=\"rId1\" Type=\"$REL_OFFICE_NS/slideMaster\" Target=\"slideMasters/slideMaster1.xml\"/>" +
            "<Relationship Id=\"rId2\" Type=\"$REL_OFFICE_NS/slide\" Target=\"slides/slide1.xml\"/>" +
            "</Relationships>",
        "ppt/theme/theme1.xml" to THEME_XML,
        "ppt/slideMasters/slideMaster1.xml" to
            "$XML_HEADER<p:sldMaster xmlns:a=\"$DRAWING_NS\" xmlns:r=\"$REL_OFFICE_NS\" xmlns:p=\"$PRESENTATION_NS\">" +
            "<p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>" +
            "<p:grpSpPr/></p:spTree></p:cSld>" +
            "<p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/></p:sldLayoutIdLst>" +
            "</p:sldMaster>",
        "ppt/slideMasters/_rels/slideMaster1.xml.rels" to
            "$XML_HEADER<Relationships xmlns=\"$REL_NS\">" +
            "<Relationship Id=\"rId1\" Type=\"$REL_OFFICE_NS/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/>" +
            "<Relationship Id=\"rId2\" Type=\"$REL_OFFICE_NS/theme\" Target=\"../theme/theme1.xml\"/>" +
            "</Relationships>",
        "ppt/slideLayouts/slideLayout1.xml" to
            "$XML_HEADER<p:sldLayout xmlns:a=\"$DRAWING_NS\" xmlns:r=\"$REL_OFFICE_NS\" xmlns:p=\"$PRESENTATION_NS\" type=\"blank\">" +
            "<p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>" +
            "<p:grpSpPr/></p:spTree></p:cSld></p:sldLayout>",
        "ppt/slideLayouts/_rels/slideLayout1.xml.rels" to
            "$XML_HEADER<Relationships xmlns=\"$REL_NS\">" +
            "<Relationship Id=\"rId1\" Type=\"$REL_OFFICE_NS/slideMaster\" Target=\"../slideMasters/slideMaster1.xml\"/>" +
            "</Relationships>",
        "ppt/slides/slide1.xml" to
            "$XML_HEADER<p:sld xmlns:a=\"$DRAWING_NS\" xmlns:r=\"$REL_OFFICE_NS\" xmlns:p=\"$PRESENTATION_NS\">" +
            "<p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>" +
            "<p:grpSpPr/>" +
            "<p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"Title 1\"/><p:cNvSpPr><a:spLocks noGrp=\"1\"/></p:cNvSpPr>" +
            "<p:nvPr><p:ph type=\"title\"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/>" +
            "<a:p><a:r><a:t>${xmlText(title)}</a:t></a:r></a:p></p:txBody></p:sp>" +
            "</p:spTree></p:cSld></p:sld>",
        "ppt/slides/_rels/slide1.xml.rels" to
            "$XML_HEADER<Relationships xmlns=\"$REL_NS\">" +
            "<Relationship Id=\"rId1\" Type=\"$REL_OFFICE_NS/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/>" +
            "</Relationships>",
    )

    private fun zip(parts: List<Pair<String, String>>): ByteArray {
        val output = ByteArrayOutputStream()
        ZipOutputStream(output).use { zip ->
            for ((name, content) in parts) {
                val bytes = content.encodeToByteArray()
                if (bytes.size > MAX_PART_BYTES) throw IllegalArgumentException("partTooLarge")
                val entry = ZipEntry(name)
                entry.time = 315532800000L // 1980-01-01, deterministic
                zip.putNextEntry(entry)
                zip.write(bytes)
                zip.closeEntry()
            }
        }
        return output.toByteArray()
    }

    private fun parseXml(bytes: ByteArray, factory: DocumentBuilderFactory): org.w3c.dom.Document? {
        return try {
            factory.isNamespaceAware = true
            // Android's platform DocumentBuilderFactory rejects XInclude
            // configuration even when disabling it (it unconditionally throws
            // UnsupportedOperationException). XInclude is unsupported and unused
            // here, so keep this guard best-effort like the SAX features below.
            runCatching { factory.isXIncludeAware = false }
            factory.setExpandEntityReferences(false)
            runCatching { factory.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true) }
            runCatching { factory.setFeature("http://xml.org/sax/features/external-general-entities", false) }
            runCatching { factory.setFeature("http://xml.org/sax/features/external-parameter-entities", false) }
            runCatching { factory.setFeature("http://apache.org/xml/features/nonvalidating/load-external-dtd", false) }
            factory.newDocumentBuilder().parse(ByteArrayInputStream(bytes))
        } catch (_: Exception) {
            null
        }
    }

    fun cleanText(raw: String?): String {
        if (raw == null) return ""
        val builder = StringBuilder(minOf(raw.length, MAX_TITLE_CHARS * 2))
        for (ch in raw) {
            when {
                ch == '\n' || ch == '\r' || ch == '\t' -> builder.append(' ')
                ch < ' ' -> Unit
                ch == '\uFFFE' || ch == '\uFFFF' -> Unit
                else -> builder.append(ch)
            }
        }
        return builder.toString().trim()
    }

    fun sheetName(title: String): String {
        val invalid = charArrayOf('[', ']', ':', '*', '?', '/', '\\')
        var name = cleanText(title).map { if (it in invalid) ' ' else it }.joinToString("").trim()
        if (name.startsWith("'")) name = name.drop(1)
        if (name.endsWith("'")) name = name.dropLast(1)
        if (name.equals("History", ignoreCase = true)) name = "Sheet1"
        name = name.take(31).trim()
        return name.ifBlank { "Sheet1" }
    }

    fun xmlText(value: String): String = buildString(value.length + 16) {
        for (ch in value) {
            when (ch) {
                '&' -> append("&amp;")
                '<' -> append("&lt;")
                '>' -> append("&gt;")
                else -> append(ch)
            }
        }
    }

    fun xmlAttr(value: String): String = buildString(value.length + 16) {
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

    fun kindForMime(mediaType: String?): NotesOoxmlKind? {
        val type = mediaType?.lowercase(Locale.ROOT)?.substringBefore(';')?.trim() ?: return null
        return NotesOoxmlKind.entries.firstOrNull { it.mimeType == type }
    }

    private val THEME_XML: String =
        "$XML_HEADER<a:theme xmlns:a=\"$DRAWING_NS\" name=\"Floe\"><a:themeElements>" +
        "<a:clrScheme name=\"Floe\"><a:dk1><a:srgbClr val=\"000000\"/></a:dk1><a:lt1><a:srgbClr val=\"FFFFFF\"/></a:lt1>" +
        "<a:dk2><a:srgbClr val=\"000000\"/></a:dk2><a:lt2><a:srgbClr val=\"FFFFFF\"/></a:lt2>" +
        "<a:accent1><a:srgbClr val=\"3B82F6\"/></a:accent1><a:accent2><a:srgbClr val=\"8B5CF6\"/></a:accent2>" +
        "<a:accent3><a:srgbClr val=\"22C55E\"/></a:accent3><a:accent4><a:srgbClr val=\"EAB308\"/></a:accent4>" +
        "<a:accent5><a:srgbClr val=\"F97316\"/></a:accent5><a:accent6><a:srgbClr val=\"EF4444\"/></a:accent6>" +
        "<a:hlink><a:srgbClr val=\"3B82F6\"/></a:hlink><a:folHlink><a:srgbClr val=\"8B5CF6\"/></a:folHlink></a:clrScheme>" +
        "<a:fontScheme name=\"Floe\"><a:majorFont><a:latin typeface=\"Calibri\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:majorFont>" +
        "<a:minorFont><a:latin typeface=\"Calibri\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:minorFont></a:fontScheme>" +
        "<a:fmtScheme name=\"Floe\"><a:fillStyleLst><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>" +
        "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:fillStyleLst>" +
        "<a:lnStyleLst><a:ln><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln>" +
        "<a:ln><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln>" +
        "<a:ln><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln></a:lnStyleLst>" +
        "<a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle>" +
        "<a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>" +
        "<a:bgFillStyleLst><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>" +
        "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>" +
        "</a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>"
}
