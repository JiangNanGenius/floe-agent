// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officereview

import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Real package-boundary tests for the retained-snapshot text projection.
 * Each fixture is a bounded ZIP with only the parts the existing OOXML
 * readers resolve; no engine, Android or network is involved.
 */
class OfficeConflictPreviewReaderTest {

    private fun root(name: String): File =
        File(System.getProperty("java.io.tmpdir") ?: ".", name + "-" + UUID.randomUUID()).apply { mkdirs() }

    private fun packageWith(
        directory: File,
        name: String,
        entries: Map<String, String>,
    ): OfficeConflictVersion {
        val file = File(directory, name)
        ZipOutputStream(FileOutputStream(file)).use { zip ->
            for ((entryName, body) in entries) {
                zip.putNextEntry(ZipEntry(entryName))
                zip.write(body.toByteArray(Charsets.UTF_8))
                zip.closeEntry()
            }
        }
        val digest = OfficeConflictArtifacts.digest(file)
            ?: error("fixture digest failed")
        return OfficeConflictVersion(digest.first, digest.second, null, file)
    }

    private fun docx(body: String): Map<String, String> = mapOf(
        "word/document.xml" to """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
              <w:body>$body</w:body>
            </w:document>
        """.trimIndent(),
    )

    private fun paragraph(text: String): String = """
        <w:p><w:r><w:t>$text</w:t></w:r></w:p>
    """.trimIndent()

    @Test
    fun docxProjectionUsesTheActualBodyText() {
        val root = root("preview-docx")
        try {
            val version = packageWith(
                root,
                "mine.docx",
                docx(paragraph("Hello") + paragraph("World")),
            )
            val read = OfficeConflictPreviewReader.read(version, "docx")
            assertTrue(read is OfficeConflictPreviewRead.Ready)
            val ready = read as OfficeConflictPreviewRead.Ready
            assertEquals("Hello\nWorld", ready.text)
            assertFalse(ready.truncated)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun previewIsBoundedAndReportsTruncation() {
        val root = root("preview-bound")
        try {
            val version = packageWith(
                root,
                "mine.docx",
                docx(paragraph("x".repeat(20_000))),
            )
            val read = OfficeConflictPreviewReader.read(version, "docx", maxChars = 512)
            assertTrue(read is OfficeConflictPreviewRead.Ready)
            val ready = read as OfficeConflictPreviewRead.Ready
            assertTrue(ready.truncated)
            assertTrue(ready.text.length <= 512)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun swappedOrNonPackageBytesAreRefusedBeforeParsing() {
        val root = root("preview-swap")
        try {
            val version = packageWith(root, "mine.docx", docx(paragraph("Original")))
            // Replace the retained path with different package bytes. The
            // frozen digest no longer identifies this file, so no reader may
            // parse it (even if the replacement is itself a valid DOCX).
            val replacement = packageWith(root, "replacement.docx", docx(paragraph("Replacement")))
            version.file.writeBytes(replacement.file.readBytes())
            val swapped = OfficeConflictPreviewReader.read(version, "docx")
            assertTrue(swapped is OfficeConflictPreviewRead.Refused)
            assertEquals("snapshotChanged", (swapped as OfficeConflictPreviewRead.Refused).code)

            val notZip = File(root, "not-a-package.docx").apply { writeText("plain text") }
            val digest = OfficeConflictArtifacts.digest(notZip)!!
            val badVersion = OfficeConflictVersion(digest.first, digest.second, null, notZip)
            val bad = OfficeConflictPreviewReader.read(badVersion, "docx")
            assertTrue(bad is OfficeConflictPreviewRead.Refused)
            assertEquals("snapshotChanged", (bad as OfficeConflictPreviewRead.Refused).code)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun packageWithoutTheResolvedBodyPartIsUnsupported() {
        val root = root("preview-missing-part")
        try {
            val version = packageWith(
                root,
                "mine.docx",
                mapOf("word/styles.xml" to "<styles/>"),
            )
            val read = OfficeConflictPreviewReader.read(version, "docx")
            assertTrue(read is OfficeConflictPreviewRead.Refused)
            assertEquals("previewUnsupported", (read as OfficeConflictPreviewRead.Refused).code)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun pptxProjectionUsesTheLogicalSlideOrder() {
        val root = root("preview-pptx")
        try {
            val version = packageWith(
                root,
                "mine.pptx",
                mapOf(
                    "ppt/presentation.xml" to """
                        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                        <p:presentation
                          xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
                          xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
                          <p:sldIdLst><p:sldId id="256" r:id="rId1"/></p:sldIdLst>
                        </p:presentation>
                    """.trimIndent(),
                    "ppt/_rels/presentation.xml.rels" to """
                        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                          <Relationship Id="rId1"
                            Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide"
                            Target="slides/slide1.xml"/>
                        </Relationships>
                    """.trimIndent(),
                    "ppt/slides/slide1.xml" to """
                        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                        <p:sld
                          xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
                          xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
                          <p:cSld><p:spTree><p:sp><p:txBody>
                            <a:p><a:r><a:t>Slide text</a:t></a:r></a:p>
                          </p:txBody></p:sp></p:spTree></p:cSld>
                        </p:sld>
                    """.trimIndent(),
                ),
            )
            val read = OfficeConflictPreviewReader.read(version, "pptx")
            assertTrue(read is OfficeConflictPreviewRead.Ready)
            val text = (read as OfficeConflictPreviewRead.Ready).text
            assertTrue(text.contains("Slide 1"))
            assertTrue(text.contains("Slide text"))
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun xlsxProjectionUsesTheActualPersistedCellText() {
        val root = root("preview-xlsx")
        try {
            val version = packageWith(
                root,
                "mine.xlsx",
                mapOf(
                    "xl/workbook.xml" to """
                        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                        <workbook
                          xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
                          xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
                          <sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets>
                        </workbook>
                    """.trimIndent(),
                    "xl/_rels/workbook.xml.rels" to """
                        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                          <Relationship Id="rId1"
                            Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"
                            Target="worksheets/sheet1.xml"/>
                        </Relationships>
                    """.trimIndent(),
                    "xl/worksheets/sheet1.xml" to """
                        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
                          <sheetData><row r="1">
                            <c r="A1" t="inlineStr"><is><t>Hello cell</t></is></c>
                          </row></sheetData>
                        </worksheet>
                    """.trimIndent(),
                ),
            )
            val read = OfficeConflictPreviewReader.read(version, "xlsx")
            assertTrue(read is OfficeConflictPreviewRead.Ready)
            val text = (read as OfficeConflictPreviewRead.Ready).text
            assertTrue(text.contains("Sheet1"))
            assertTrue(text.contains("A1: Hello cell"))
        } finally {
            root.deleteRecursively()
        }
    }
}
