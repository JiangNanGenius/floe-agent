// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.meetingexchange

import java.io.ByteArrayInputStream
import java.util.zip.ZipInputStream
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Readability of the lightweight Word (.docx) meeting export.
 *
 * A .docx is an OPC ZIP package; these tests open the produced bytes exactly
 * the way a word processor does — as a ZIP of XML parts — and verify the
 * required parts exist, are well-formed XML, carry the meeting content and
 * escape/encode it safely. No Android, no storage, no provider.
 */
class MeetingDocumentOfficeTest {

    @Test
    fun `docx is a zip with the required opc parts`() {
        val bytes = MeetingDocumentOffice.docx(
            listOf(
                MeetingOfficeParagraph("Weekly review", MeetingOfficeParagraphStyle.TITLE),
                MeetingOfficeParagraph("Notes", MeetingOfficeParagraphStyle.HEADING),
                MeetingOfficeParagraph("A note", MeetingOfficeParagraphStyle.BODY),
            ),
        )
        val parts = unzip(bytes)

        assertTrue(parts.containsKey(MeetingDocumentOffice.CONTENT_TYPES))
        assertTrue(parts.containsKey(MeetingDocumentOffice.RELS))
        assertTrue(parts.containsKey(MeetingDocumentOffice.DOCUMENT))
        assertTrue(parts.containsKey(MeetingDocumentOffice.STYLES))
        assertTrue(parts.containsKey(MeetingDocumentOffice.DOCUMENT_RELS))
        // The package must declare the document content type.
        assertTrue(
            parts.getValue(MeetingDocumentOffice.CONTENT_TYPES).contains(
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml",
            ),
        )
    }

    @Test
    fun `every xml part is well formed`() {
        val paragraphs = paragraphs(
            MeetingExportTestFixtures.detail(
                title = "Weekly review",
                notes = "Decision: ship on Friday",
                segments = listOf(
                    MeetingExportTestFixtures.segment(65_000L, 70_000L, "Spoken text", "Alex"),
                ),
            ),
        )
        val parts = unzip(MeetingDocumentOffice.docx(paragraphs))
        val factory = DocumentBuilderFactory.newInstance()
        factory.isNamespaceAware = false
        listOf(
            MeetingDocumentOffice.CONTENT_TYPES,
            MeetingDocumentOffice.RELS,
            MeetingDocumentOffice.DOCUMENT,
            MeetingDocumentOffice.STYLES,
            MeetingDocumentOffice.DOCUMENT_RELS,
        ).forEach { name ->
            // parse() throws on malformed XML; a word processor would too.
            val doc = factory.newDocumentBuilder()
                .parse(ByteArrayInputStream(parts.getValue(name).toByteArray(Charsets.UTF_8)))
            assertTrue(name, doc.documentElement != null)
        }
    }

    @Test
    fun `document carries title notes and transcript text`() {
        val paragraphs = paragraphs(
            MeetingExportTestFixtures.detail(
                title = "Weekly review",
                notes = "Decision: ship on Friday",
                segments = listOf(
                    MeetingExportTestFixtures.segment(65_000L, 70_000L, "Spoken text", "Alex"),
                ),
            ),
        )
        val document = unzip(MeetingDocumentOffice.docx(paragraphs))
            .getValue(MeetingDocumentOffice.DOCUMENT)

        assertTrue(document.contains("Weekly review"))
        assertTrue(document.contains("Decision: ship on Friday"))
        assertTrue(document.contains("[00:01:05 – 00:01:10] Alex: Spoken text"))
        // Explicit missing-state copy stays present, not invented content.
        val emptyDoc = unzip(
            MeetingDocumentOffice.docx(
                paragraphs(MeetingExportTestFixtures.detail(notes = "", segments = emptyList())),
            ),
        ).getValue(MeetingDocumentOffice.DOCUMENT)
        assertTrue(emptyDoc.contains(MeetingExportTestFixtures.LABELS.noNotes))
        assertTrue(emptyDoc.contains(MeetingExportTestFixtures.LABELS.noTranscript))
    }

    @Test
    fun `user text is xml escaped and unicode survives utf8`() {
        val paragraphs = paragraphs(
            MeetingExportTestFixtures.detail(
                title = "周会 <脚本> & \"引号\"",
                notes = "决定：继续。",
                segments = listOf(
                    MeetingExportTestFixtures.segment(1_000L, 2_000L, "你好 👋", "张三"),
                ),
            ),
        )
        val document = unzip(MeetingDocumentOffice.docx(paragraphs))
            .getValue(MeetingDocumentOffice.DOCUMENT)

        // Raw markup never appears; the escaped entities do.
        assertFalse(document.contains("<脚本>"))
        assertTrue(document.contains("&lt;脚本&gt;"))
        assertTrue(document.contains("&amp;"))
        assertTrue(document.contains("&quot;"))
        assertTrue(document.contains("决定：继续。"))
        assertTrue(document.contains("你好 👋"))
        assertTrue(document.contains("张三"))
        // And the escaped document is still well-formed XML.
        val factory = DocumentBuilderFactory.newInstance()
        factory.isNamespaceAware = false
        factory.newDocumentBuilder().parse(ByteArrayInputStream(document.toByteArray(Charsets.UTF_8)))
    }

    @Test
    fun `same paragraphs produce the same bytes`() {
        val paragraphs = listOf(
            MeetingOfficeParagraph("T", MeetingOfficeParagraphStyle.TITLE),
            MeetingOfficeParagraph("line", MeetingOfficeParagraphStyle.BODY),
        )
        assertEquals(
            MeetingDocumentOffice.docx(paragraphs).toList(),
            MeetingDocumentOffice.docx(paragraphs).toList(),
        )
    }

    private fun paragraphs(detail: com.floe.android.host.meeting.MeetingDetail): List<MeetingOfficeParagraph> =
        MeetingOfficeContent.paragraphs(
            MeetingExportSnapshot.from(detail),
            MeetingExportTestFixtures.LABELS,
            MeetingExportTestFixtures.UTC,
        )

    private fun unzip(bytes: ByteArray): Map<String, String> {
        val parts = LinkedHashMap<String, String>()
        ZipInputStream(ByteArrayInputStream(bytes)).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: break
                parts[entry.name] = zip.readBytes().toString(Charsets.UTF_8)
                zip.closeEntry()
            }
        }
        return parts
    }
}
