// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.export

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.Base64
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The DOCX builder is a real package writer, not a renamed ZIP/plaintext
 * export. These regressions inspect the actual WordprocessingML parts,
 * relationships, media bytes, section geometry and bounded refusals.
 */
class NotesDocxPackageBuilderTest {

    private val png: ByteArray = Base64.getDecoder().decode(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
    )

    private fun entries(bytes: ByteArray): Map<String, ByteArray> {
        val result = LinkedHashMap<String, ByteArray>()
        ZipInputStream(ByteArrayInputStream(bytes)).use { input ->
            var entry: ZipEntry? = input.nextEntry
            while (entry != null) {
                val out = ByteArrayOutputStream()
                input.copyTo(out)
                result[entry.name] = out.toByteArray()
                entry = input.nextEntry
            }
        }
        return result
    }

    private fun zip(parts: Map<String, ByteArray>): ByteArray {
        val out = ByteArrayOutputStream()
        ZipOutputStream(out).use { zip ->
            for ((name, bytes) in parts) {
                val entry = ZipEntry(name)
                entry.time = 315532800000L
                zip.putNextEntry(entry)
                zip.write(bytes)
                zip.closeEntry()
            }
        }
        return out.toByteArray()
    }

    private fun emu(points: Double): Long = Math.round(points * 12_700.0)

    private fun image(
        bytes: ByteArray = png,
        widthEmu: Long = 254_000,
        heightEmu: Long = 254_000,
        leftEmu: Long = 0,
        topEmu: Long = 0,
        behind: Boolean = false,
    ) = NotesDocxImage(
        bytes = bytes,
        mediaType = "image/png",
        widthEmu = widthEmu,
        heightEmu = heightEmu,
        leftEmu = leftEmu,
        topEmu = topEmu,
        altText = "Note image",
        behindText = behind,
    )

    private fun baseDocument(): NotesDocxDocument {
        val pageWidth = 768.0
        val pageHeight = 1024.0
        return NotesDocxDocument(
            title = "My & <Note>",
            pages = listOf(
                NotesDocxPage(
                    widthPt = pageWidth,
                    heightPt = pageHeight,
                    background = image(
                        widthEmu = emu(pageWidth),
                        heightEmu = emu(pageHeight),
                        behind = true,
                    ),
                    blocks = listOf(
                        NotesDocxBlock.Heading(1, listOf(NotesDocxRun("Page 1"))),
                        NotesDocxBlock.Paragraph(listOf(NotesDocxRun("Hello & <world>", fontSizePt = 18.0))),
                        NotesDocxBlock.ListItem(0, false, listOf(NotesDocxRun("one"))),
                        NotesDocxBlock.ListItem(0, true, listOf(NotesDocxRun("two"))),
                        NotesDocxBlock.Table(
                            listOf(
                                NotesDocxTableRow(listOf("A", "B"), header = true),
                                NotesDocxTableRow(listOf("1", "2")),
                            ),
                        ),
                        NotesDocxBlock.Paragraph(
                            listOf(NotesDocxRun("link", hyperlinkURL = "https://example.com/?a=1&b=2")),
                        ),
                        NotesDocxBlock.Image(image()),
                    ),
                ),
                NotesDocxPage(
                    widthPt = pageWidth,
                    heightPt = pageHeight,
                    blocks = listOf(NotesDocxBlock.Heading(1, listOf(NotesDocxRun("Page 2")))),
                ),
            ),
            footerNote = "Typed text is editable.",
        )
    }

    @Test
    fun `writes a valid package with real text hierarchy tables links media and page sections`() {
        val built = NotesDocxPackageBuilder.build(baseDocument())
        assertTrue(NotesDocxPackageBuilder.validate(built.bytes, 2).ok)
        assertEquals(2, built.pageCount)
        assertEquals(2, built.imageCount)
        assertEquals(built.byteCount, built.bytes.size.toLong())
        assertEquals(sha256(built.bytes), built.sha256)

        val parts = entries(built.bytes)
        assertTrue(parts.containsKey("[Content_Types].xml"))
        assertTrue(parts.containsKey("_rels/.rels"))
        assertTrue(parts.containsKey("word/document.xml"))
        assertTrue(parts.containsKey("word/styles.xml"))
        assertTrue(parts.containsKey("word/numbering.xml"))
        assertTrue(parts.containsKey("word/media/image1.png"))
        assertTrue(parts.containsKey("word/media/image2.png"))
        assertTrue(parts.getValue("word/media/image1.png").contentEquals(png))

        val document = parts.getValue("word/document.xml").toString(Charsets.UTF_8)
        assertTrue(document.contains("My &amp; &lt;Note&gt;"))
        assertTrue(document.contains("Hello &amp; &lt;world&gt;"))
        assertTrue(document.contains("<w:tbl>"))
        assertTrue(document.contains("<w:tblHeader/>"))
        assertTrue(document.contains("<w:hyperlink"))
        assertTrue(document.contains("<w:numPr>"))
        assertTrue(document.contains("r:embed=\"rIdImg1\""))
        assertTrue(document.contains("r:embed=\"rIdImg2\""))
        assertTrue(document.contains("behindDoc=\"1\""))
        assertTrue(document.contains("behindDoc=\"0\""))
        assertEquals(2, Regex("<w:sectPr>").findAll(document).count())
        assertTrue(document.indexOf("Page 1") < document.indexOf("Page 2"))
        assertTrue(document.contains("Typed text is editable."))

        val rels = parts.getValue("word/_rels/document.xml.rels").toString(Charsets.UTF_8)
        assertTrue(rels.contains("Target=\"https://example.com/?a=1&amp;b=2\""))
        assertTrue(rels.contains("Target=\"media/image1.png\""))
        assertTrue(rels.contains("Target=\"styles.xml\""))
        assertTrue(rels.contains("Target=\"numbering.xml\""))
    }

    @Test
    fun `the same content is deterministic`() {
        val first = NotesDocxPackageBuilder.build(baseDocument())
        val second = NotesDocxPackageBuilder.build(baseDocument())
        assertTrue(first.bytes.contentEquals(second.bytes))
        assertEquals(first.sha256, second.sha256)
    }

    @Test
    fun `refuses unsupported or mismatched image bytes and page geometry`() {
        val badImage = image(bytes = byteArrayOf(1, 2, 3, 4))
        assertThrows("imageFormat") {
            NotesDocxPackageBuilder.build(
                NotesDocxDocument(
                    "Bad",
                    listOf(
                        NotesDocxPage(
                            768.0,
                            1024.0,
                            blocks = listOf(NotesDocxBlock.Image(badImage)),
                        ),
                    ),
                ),
            )
        }
        assertThrows("imageTypeMismatch") {
            NotesDocxPackageBuilder.build(
                NotesDocxDocument(
                    "Bad",
                    listOf(
                        NotesDocxPage(
                            768.0,
                            1024.0,
                            blocks = listOf(NotesDocxBlock.Image(image().copy(mediaType = "image/jpeg"))),
                        ),
                    ),
                ),
            )
        }
        assertThrows("pageTooLarge") {
            NotesDocxPackageBuilder.build(
                NotesDocxDocument("Too large", listOf(NotesDocxPage(1_585.0, 1_024.0))),
            )
        }
        assertThrows("imageOutOfPage") {
            NotesDocxPackageBuilder.build(
                NotesDocxDocument(
                    "Out",
                    listOf(
                        NotesDocxPage(
                            768.0,
                            1024.0,
                            blocks = listOf(NotesDocxBlock.Image(image(leftEmu = emu(760.0)))),
                        ),
                    ),
                ),
            )
        }
        assertThrows("backgroundGeometry") {
            NotesDocxPackageBuilder.build(
                NotesDocxDocument(
                    "Bad background",
                    listOf(
                        NotesDocxPage(
                            768.0,
                            1024.0,
                            background = image(
                                widthEmu = emu(768.0),
                                heightEmu = emu(100.0),
                                behind = true,
                            ),
                        ),
                    ),
                ),
            )
        }
    }

    @Test
    fun `refuses too many pages and invalid hyperlinks`() {
        val pages = (0..NotesDocxPackageBuilder.MAX_PAGES).map {
            NotesDocxPage(768.0, 1024.0)
        }
        assertThrows("tooManyPages") {
            NotesDocxPackageBuilder.build(NotesDocxDocument("Many", pages))
        }
        assertThrows("hyperlink") {
            NotesDocxPackageBuilder.build(
                NotesDocxDocument(
                    "Link",
                    listOf(
                        NotesDocxPage(
                            768.0,
                            1024.0,
                            blocks = listOf(
                                NotesDocxBlock.Paragraph(
                                    listOf(NotesDocxRun("bad", hyperlinkURL = "file:///etc/passwd")),
                                ),
                            ),
                        ),
                    ),
                ),
            )
        }
    }

    @Test
    fun `validation rejects a tampered package and an unknown page count`() {
        val built = NotesDocxPackageBuilder.build(baseDocument())
        assertFalse(NotesDocxPackageBuilder.validate(built.bytes, 3).ok)
        val parts = entries(built.bytes)
        val withoutContentTypes = zip(parts.filterKeys { it != "[Content_Types].xml" })
        assertFalse(NotesDocxPackageBuilder.validate(withoutContentTypes).ok)
        val withMissingMedia = zip(parts.filterKeys { it != "word/media/image1.png" })
        val broken = NotesDocxPackageBuilder.validate(withMissingMedia, 2)
        assertFalse(broken.ok)
        assertEquals("relationshipTargetMissing", broken.reason)
        assertFalse(NotesDocxPackageBuilder.validate(byteArrayOf(1, 2, 3)).ok)
    }

    @Test
    fun `markdown conversion preserves supported structure and keeps unsupported syntax literal`() {
        val blocks = NotesDocxMarkdown.markdownBlocks(
            """
            # Heading

            Paragraph with **bold**, *italic*, `code` and [link](https://example.com).

            - bullet
            - second
            1. ordered

            > quote line

            ```kotlin
            val x = 1
            ```

            | a | b |
            | --- | --- |
            | 1 | 2 |

            <not html>
            """.trimIndent(),
            baseColor = "#123456",
            fontSizePt = 17.0,
        )
        assertTrue(blocks.any { it is NotesDocxBlock.Heading && it.level == 1 })
        assertTrue(blocks.any { it is NotesDocxBlock.ListItem && !it.ordered })
        assertTrue(blocks.any { it is NotesDocxBlock.ListItem && it.ordered })
        assertTrue(blocks.any { it is NotesDocxBlock.Paragraph && it.style == NotesDocxParagraphStyle.QUOTE })
        assertTrue(blocks.any { it is NotesDocxBlock.Paragraph && it.style == NotesDocxParagraphStyle.CODE })
        assertTrue(blocks.any { it is NotesDocxBlock.Table })
        val paragraph = blocks.filterIsInstance<NotesDocxBlock.Paragraph>()
            .first { it.runs.any { run -> run.text.contains("Paragraph") } }
        assertTrue(paragraph.runs.any { it.bold && it.text == "bold" })
        assertTrue(paragraph.runs.any { it.italic && it.text == "italic" })
        assertTrue(paragraph.runs.any { it.monospace && it.text == "code" })
        assertTrue(paragraph.runs.any { it.hyperlinkURL == "https://example.com" && it.text == "link" })
        assertTrue(paragraph.runs.all { it.color == "#123456" && it.fontSizePt == 17.0 })
        val html = blocks.filterIsInstance<NotesDocxBlock.Paragraph>()
            .firstOrNull { block -> block.runs.any { it.text.contains("<not html>") } }
        assertTrue(html != null)
    }

    @Test
    fun `plain text does not become markdown structure`() {
        val blocks = NotesDocxMarkdown.plainBlocks("# not a heading\n- not a list")
        assertEquals(1, blocks.size)
        val paragraph = blocks.single() as NotesDocxBlock.Paragraph
        assertEquals("# not a heading\n- not a list", paragraph.runs.single().text)
        assertNotEquals(NotesDocxParagraphStyle.CODE, paragraph.style)
    }

    private fun assertThrows(reason: String, block: () -> Unit) {
        val error = runCatching { block() }.exceptionOrNull()
        assertTrue("expected NotesDocxBuildException($reason), got $error", error is NotesDocxBuildException)
        assertEquals(reason, (error as NotesDocxBuildException).reason)
    }

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") {
            "%02x".format(it.toInt() and 0xFF)
        }
}
