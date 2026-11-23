// SPDX-License-Identifier: MPL-2.0
//
// Minimal, dependency-free Word (.docx) writer for the meeting document
// export. A .docx is an OPC ZIP package; this writes the three required parts
// ([Content_Types].xml, _rels/.rels, word/document.xml) plus a small
// word/styles.xml so Title/Heading render bold in Word and LibreOffice. All
// user text is XML-escaped and UTF-8; the ZIP entries use a fixed timestamp so
// the same paragraphs always produce the same bytes.
package com.floe.android.host.meetingexchange

import java.io.ByteArrayOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

internal object MeetingDocumentOffice {
    const val CONTENT_TYPES =
        "[Content_Types].xml"
    const val RELS = "_rels/.rels"
    const val DOCUMENT = "word/document.xml"
    const val STYLES = "word/styles.xml"
    const val DOCUMENT_RELS = "word/_rels/document.xml.rels"

    /** Renders the shared paragraphs into a complete .docx byte array. */
    fun docx(paragraphs: List<MeetingOfficeParagraph>): ByteArray {
        val out = ByteArrayOutputStream()
        ZipOutputStream(out).use { zip ->
            zip.setComment(null)
            zip.putEntry(CONTENT_TYPES, contentTypes())
            zip.putEntry(RELS, rootRels())
            zip.putEntry(DOCUMENT, documentXml(paragraphs))
            zip.putEntry(STYLES, stylesXml())
            zip.putEntry(DOCUMENT_RELS, documentRels())
        }
        return out.toByteArray()
    }

    private fun ZipOutputStream.putEntry(name: String, bytes: ByteArray) {
        val entry = ZipEntry(name)
        entry.time = 0L
        entry.method = ZipEntry.DEFLATED
        putNextEntry(entry)
        write(bytes)
        closeEntry()
    }

    private fun contentTypes(): ByteArray = xml(
        "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">" +
            "<Default Extension=\"rels\" " +
            "ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>" +
            "<Default Extension=\"xml\" ContentType=\"application/xml\"/>" +
            "<Override PartName=\"/word/document.xml\" " +
            "ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>" +
            "<Override PartName=\"/word/styles.xml\" " +
            "ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/>" +
            "</Types>",
    )

    private fun rootRels(): ByteArray = xml(
        "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" +
            "<Relationship Id=\"rId1\" " +
            "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" " +
            "Target=\"word/document.xml\"/>" +
            "</Relationships>",
    )

    private fun documentRels(): ByteArray = xml(
        "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" +
            "<Relationship Id=\"rId1\" " +
            "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" " +
            "Target=\"styles.xml\"/>" +
            "</Relationships>",
    )

    private fun stylesXml(): ByteArray = xml(
        "<w:styles xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">" +
            "<w:style w:type=\"paragraph\" w:styleId=\"Title\">" +
            "<w:name w:val=\"Title\"/><w:qFormat/>" +
            "<w:rPr><w:b/><w:sz w:val=\"56\"/></w:rPr>" +
            "</w:style>" +
            "<w:style w:type=\"paragraph\" w:styleId=\"Heading1\">" +
            "<w:name w:val=\"heading 1\"/><w:qFormat/>" +
            "<w:rPr><w:b/><w:sz w:val=\"32\"/></w:rPr>" +
            "</w:style>" +
            "</w:styles>",
    )

    private fun documentXml(paragraphs: List<MeetingOfficeParagraph>): ByteArray {
        val body = StringBuilder()
        paragraphs.forEach { paragraph ->
            body.append("<w:p>")
            when (paragraph.style) {
                MeetingOfficeParagraphStyle.TITLE ->
                    body.append("<w:pPr><w:pStyle w:val=\"Title\"/></w:pPr>")
                MeetingOfficeParagraphStyle.HEADING ->
                    body.append("<w:pPr><w:pStyle w:val=\"Heading1\"/></w:pPr>")
                MeetingOfficeParagraphStyle.BODY -> Unit
            }
            body.append("<w:r><w:t xml:space=\"preserve\">")
            body.append(escapeXml(paragraph.text))
            body.append("</w:t></w:r></w:p>")
        }
        body.append("<w:sectPr/>")
        return xml(
            "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">" +
                "<w:body>" + body.toString() + "</w:body></w:document>",
        )
    }

    private fun xml(body: String): ByteArray =
        ("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" + body)
            .toByteArray(Charsets.UTF_8)

    /** Escapes the five XML entities; control characters become spaces. */
    internal fun escapeXml(text: String): String {
        val out = StringBuilder(text.length)
        text.forEach { char ->
            when (char) {
                '&' -> out.append("&amp;")
                '<' -> out.append("&lt;")
                '>' -> out.append("&gt;")
                '"' -> out.append("&quot;")
                '\'' -> out.append("&apos;")
                else -> if (char.isISOControl() && char != '\t') out.append(' ') else out.append(char)
            }
        }
        return out.toString()
    }
}
