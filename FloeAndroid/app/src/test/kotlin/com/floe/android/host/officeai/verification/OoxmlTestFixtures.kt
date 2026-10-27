// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officeai.verification

import java.io.ByteArrayOutputStream
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/** Builds REAL OOXML ZIP fixtures for the actual verifier object. These are
 * writers (test side), never a mirrored parser: the production code under
 * test reads the packages. All fixtures stay tiny so the suite is bounded and
 * fast, and cap-abort tests use declared-size fakes via RawZipBuilder.
 */
internal object OoxmlTestFixtures {

    const val W_NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    const val A_NS = "http://schemas.openxmlformats.org/drawingml/2006/main"
    const val P_NS = "http://schemas.openxmlformats.org/presentationml/2006/main"
    const val R_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    const val S_NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    const val PKG_REL_NS = "http://schemas.openxmlformats.org/package/2006/relationships"
    const val SLIDE_REL_TYPE = "$R_NS/slide"
    const val WORKSHEET_REL_TYPE = "$R_NS/worksheet"
    const val SHARED_STRINGS_REL_TYPE = "$R_NS/sharedStrings"

    private const val XML_DECL = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"

    fun esc(value: String): String = buildString(value.length + 8) {
        for (ch in value) {
            when (ch) {
                '&' -> append("&amp;")
                '<' -> append("&lt;")
                '>' -> append("&gt;")
                else -> append(ch)
            }
        }
    }

    fun sha256(bytes: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val out = StringBuilder(64)
        for (b in digest.digest(bytes)) {
            out.append("%02x".format(b.toInt() and 0xFF))
        }
        return out.toString()
    }

    fun zipOf(entries: Map<String, ByteArray>): ByteArray {
        val out = ByteArrayOutputStream()
        ZipOutputStream(out).use { zip ->
            for ((name, data) in entries) {
                zip.putNextEntry(ZipEntry(name))
                zip.write(data)
                zip.closeEntry()
            }
        }
        return out.toByteArray()
    }

    // -----------------------------------------------------------------
    // DOCX
    // -----------------------------------------------------------------

    fun wordPara(text: String): String =
        "<w:p><w:r><w:t xml:space=\"preserve\">${esc(text)}</w:t></w:r></w:p>"

    fun wordDocumentXml(innerBody: String): String =
        XML_DECL + "<w:document xmlns:w=\"$W_NS\"><w:body>$innerBody</w:body></w:document>"

    fun docxBytes(
        documentXml: String,
        extras: Map<String, ByteArray> = emptyMap(),
    ): ByteArray = docxBytesRaw(documentXml.toByteArray(StandardCharsets.UTF_8), extras)

    fun docxBytesRaw(
        documentBytes: ByteArray,
        extras: Map<String, ByteArray> = emptyMap(),
    ): ByteArray {
        val entries = LinkedHashMap<String, ByteArray>()
        entries["[Content_Types].xml"] =
            (XML_DECL + "<Types xmlns=\"$PKG_REL_NS\"></Types>")
                .toByteArray(StandardCharsets.UTF_8)
        entries["word/document.xml"] = documentBytes
        entries.putAll(extras)
        return zipOf(entries)
    }

    fun docxBytesWithHeader(headerText: String, bodyInner: String): ByteArray =
        docxBytes(
            wordDocumentXml(bodyInner),
            extras = mapOf(
                "word/header1.xml" to wordDocumentXml(headerText).toByteArray(StandardCharsets.UTF_8),
            ),
        )

    // -----------------------------------------------------------------
    // PPTX
    // -----------------------------------------------------------------

    data class PptSlide(
        val relId: String,
        val fileName: String,
        val paragraphs: List<String>,
    ) {
        fun slideXml(): String {
            val inner = paragraphs.joinToString("") {
                "<a:p><a:r><a:t xml:space=\"preserve\">${esc(it)}</a:t></a:r></a:p>"
            }
            return XML_DECL +
                "<p:sld xmlns:p=\"$P_NS\" xmlns:a=\"$A_NS\">" +
                "<p:cSld><p:sp><p:txBody>$inner</p:txBody></p:sp></p:cSld></p:sld>"
        }
    }

    fun pptxBytes(
        slidesInLogicalOrder: List<PptSlide>,
        externalSlideRel: String? = null,
    ): ByteArray {
        val ids = slidesInLogicalOrder.mapIndexed { index, slide ->
            "<p:sldId id=\"${256 + index}\" r:id=\"${slide.relId}\"/>"
        }.joinToString("")
        val presentation = XML_DECL +
            "<p:presentation xmlns:p=\"$P_NS\" xmlns:r=\"$R_NS\"><p:sldIdLst>$ids</p:sldIdLst></p:presentation>"
        val rels = StringBuilder(
            XML_DECL + "<Relationships xmlns=\"$PKG_REL_NS\">",
        )
        for (slide in slidesInLogicalOrder) {
            if (externalSlideRel != null && slide.relId == externalSlideRel) {
                rels.append(
                    "<Relationship Id=\"${slide.relId}\" Type=\"$SLIDE_REL_TYPE\" " +
                        "Target=\"http://invalid.invalid/slides/${slide.fileName}\" " +
                        "TargetMode=\"External\"/>",
                )
            } else {
                rels.append(
                    "<Relationship Id=\"${slide.relId}\" Type=\"$SLIDE_REL_TYPE\" " +
                        "Target=\"slides/${slide.fileName}\"/>",
                )
            }
        }
        rels.append("</Relationships>")
        val entries = LinkedHashMap<String, ByteArray>()
        entries["[Content_Types].xml"] =
            (XML_DECL + "<Types xmlns=\"$PKG_REL_NS\"></Types>")
                .toByteArray(StandardCharsets.UTF_8)
        entries["ppt/presentation.xml"] = presentation.toByteArray(StandardCharsets.UTF_8)
        entries["ppt/_rels/presentation.xml.rels"] = rels.toString().toByteArray(StandardCharsets.UTF_8)
        for (slide in slidesInLogicalOrder) {
            entries["ppt/slides/${slide.fileName}"] =
                slide.slideXml().toByteArray(StandardCharsets.UTF_8)
        }
        return zipOf(entries)
    }

    // -----------------------------------------------------------------
    // XLSX
    // -----------------------------------------------------------------

    data class XlsxCell(
        val address: String,
        val t: String? = null,
        val f: String? = null,
        val fAttrs: String? = null,
        val v: String? = null,
        val inline: String? = null,
    ) {
        fun xml(): String {
            val builder = StringBuilder()
            builder.append("<c r=\"$address\"")
            if (t != null) builder.append(" t=\"$t\"")
            builder.append(">")
            if (f != null || fAttrs != null) {
                builder.append("<f")
                    .append(fAttrs ?: "")
                    .append(">")
                    .append(f?.let { esc(it) } ?: "")
                    .append("</f>")
            }
            if (v != null) builder.append("<v>${esc(v)}</v>")
            if (inline != null) {
                builder.append("<is><t xml:space=\"preserve\">${esc(inline)}</t></is>")
            }
            builder.append("</c>")
            return builder.toString()
        }
    }

    data class XlsxSheet(
        val relId: String,
        val fileName: String,
        val cells: List<XlsxCell>,
        val relType: String = WORKSHEET_REL_TYPE,
    )

    fun xlsxBytes(
        sheetsInTabOrder: List<XlsxSheet>,
        sharedStrings: List<String>? = null,
        sharedStringsRelOverride: Pair<String, String>? = null,
    ): ByteArray {
        val sheets = sheetsInTabOrder.mapIndexed { index, sheet ->
            "<sheet name=\"Tab${index + 1}\" sheetId=\"${index + 1}\" r:id=\"${sheet.relId}\"/>"
        }.joinToString("")
        val workbook = XML_DECL +
            "<workbook xmlns=\"$S_NS\" xmlns:r=\"$R_NS\"><sheets>$sheets</sheets></workbook>"
        val rels = StringBuilder(
            XML_DECL + "<Relationships xmlns=\"$PKG_REL_NS\">",
        )
        for (sheet in sheetsInTabOrder) {
            rels.append(
                "<Relationship Id=\"${sheet.relId}\" Type=\"${sheet.relType}\" " +
                    "Target=\"worksheets/${sheet.fileName}\"/>",
            )
        }
        if (sharedStrings != null) {
            val target = sharedStringsRelOverride?.second ?: "sharedStrings.xml"
            val type = sharedStringsRelOverride?.first ?: SHARED_STRINGS_REL_TYPE
            rels.append(
                "<Relationship Id=\"rIdShared\" Type=\"$type\" Target=\"$target\"/>",
            )
        }
        rels.append("</Relationships>")
        val entries = LinkedHashMap<String, ByteArray>()
        entries["[Content_Types].xml"] =
            (XML_DECL + "<Types xmlns=\"$PKG_REL_NS\"></Types>")
                .toByteArray(StandardCharsets.UTF_8)
        entries["xl/workbook.xml"] = workbook.toByteArray(StandardCharsets.UTF_8)
        entries["xl/_rels/workbook.xml.rels"] = rels.toString().toByteArray(StandardCharsets.UTF_8)
        for (sheet in sheetsInTabOrder) {
            val rowGroups = LinkedHashMap<Int, MutableList<XlsxCell>>()
            for (cell in sheet.cells) {
                val row = cell.address.filter { it.isDigit() }.toIntOrNull() ?: 1
                rowGroups.getOrPut(row) { ArrayList() }.add(cell)
            }
            val rows = rowGroups.entries.joinToString("") { (rowNum, cells) ->
                "<row r=\"$rowNum\">${cells.joinToString("") { it.xml() }}</row>"
            }
            val sheetXml = XML_DECL +
                "<worksheet xmlns=\"$S_NS\"><sheetData>$rows</sheetData></worksheet>"
            entries["xl/worksheets/${sheet.fileName}"] =
                sheetXml.toByteArray(StandardCharsets.UTF_8)
        }
        if (sharedStrings != null) {
            val sst = XML_DECL +
                "<sst xmlns=\"$S_NS\" count=\"${sharedStrings.size}\" " +
                "uniqueCount=\"${sharedStrings.size}\">" +
                sharedStrings.joinToString("") { "<si><t xml:space=\"preserve\">${esc(it)}</t></si>" } +
                "</sst>"
            val target = sharedStringsRelOverride?.second ?: "sharedStrings.xml"
            val part = if (target.startsWith("/")) target.substring(1) else "xl/$target"
            entries[part] = sst.toByteArray(StandardCharsets.UTF_8)
        }
        return zipOf(entries)
    }

    // -----------------------------------------------------------------
    // Raw hand-built ZIPs for malicious/edge structures the normal writers
    // cannot express (encrypted flag, fake declared sizes, unsafe names,
    // broken local headers).
    // -----------------------------------------------------------------

    data class RawEntry(
        val name: String,
        val payload: ByteArray,
        val method: Int = 0,
        val flags: Int = 0,
        val declaredUsize: Long = payload.size.toLong(),
        val declaredCsize: Long = payload.size.toLong(),
        val localSignatureOverride: ByteArray? = null,
    )

    fun rawZip(entries: List<RawEntry>): ByteArray {
        val out = ByteArrayOutputStream()
        val central = ByteArrayOutputStream()
        for (entry in entries) {
            val nameBytes = entry.name.toByteArray(StandardCharsets.UTF_8)
            val offset = out.size()
            val crc = CRC32()
            crc.update(entry.payload)
            val localSig = entry.localSignatureOverride
                ?: byteArrayOf('P'.code.toByte(), 'K'.code.toByte(), 3, 4)
            out.write(localSig)
            out.write(u16(20))
            out.write(u16(entry.flags))
            out.write(u16(entry.method))
            out.write(u16(0))
            out.write(u16(0))
            out.write(u32(crc.value))
            out.write(u32(entry.declaredCsize))
            out.write(u32(entry.declaredUsize))
            out.write(u16(nameBytes.size))
            out.write(u16(0))
            out.write(nameBytes)
            out.write(entry.payload)

            central.write(u32(0x02014B50L))
            central.write(u16(20))
            central.write(u16(20))
            central.write(u16(entry.flags))
            central.write(u16(entry.method))
            central.write(u16(0))
            central.write(u16(0))
            central.write(u32(crc.value))
            central.write(u32(entry.declaredCsize))
            central.write(u32(entry.declaredUsize))
            central.write(u16(nameBytes.size))
            central.write(u16(0))
            central.write(u16(0))
            central.write(u16(0))
            central.write(u16(0))
            central.write(u32(0))
            central.write(u32(offset.toLong()))
            central.write(nameBytes)
        }
        val cdBytes = central.toByteArray()
        val cdOffset = out.size()
        out.write(cdBytes)
        out.write(u32(0x06054B50L))
        out.write(u16(0))
        out.write(u16(0))
        out.write(u16(entries.size))
        out.write(u16(entries.size))
        out.write(u32(cdBytes.size.toLong()))
        out.write(u32(cdOffset.toLong()))
        out.write(u16(0))
        return out.toByteArray()
    }

    private fun u16(value: Int): ByteArray = byteArrayOf(
        (value and 0xFF).toByte(),
        ((value ushr 8) and 0xFF).toByte(),
    )

    private fun u32(value: Long): ByteArray = byteArrayOf(
        (value and 0xFF).toByte(),
        ((value ushr 8) and 0xFF).toByte(),
        ((value ushr 16) and 0xFF).toByte(),
        ((value ushr 24) and 0xFF).toByte(),
    )
}
