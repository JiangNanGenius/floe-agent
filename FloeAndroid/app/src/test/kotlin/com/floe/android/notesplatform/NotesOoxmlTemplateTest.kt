// SPDX-License-Identifier: MPL-2.0
package com.floe.android.notesplatform

import java.io.ByteArrayInputStream
import java.util.zip.ZipInputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NotesOoxmlTemplateTest {

    @Test
    fun createsAndValidatesEveryBlankKind() {
        val title = "Quarterly & <Notes> \"草案\""
        for (kind in NotesOoxmlKind.entries) {
            val bytes = NotesOoxmlTemplates.create(kind, title)
            val validation = NotesOoxmlTemplates.validate(bytes, kind)
            assertTrue("$kind: ${validation.reason}", validation.ok)
            val names = entries(bytes)
            assertTrue(names.contains(kind.mainPart))
            assertTrue(names.contains("[Content_Types].xml"))
            assertTrue(names.contains("_rels/.rels"))
            assertFalse(names.any { it.contains("..") })
        }
    }

    @Test
    fun isDeterministicForTheSameTitle() {
        for (kind in NotesOoxmlKind.entries) {
            assertTrue(
                NotesOoxmlTemplates.create(kind, "Title").contentEquals(
                    NotesOoxmlTemplates.create(kind, "Title"),
                ),
            )
            assertFalse(
                NotesOoxmlTemplates.create(kind, "Title").contentEquals(
                    NotesOoxmlTemplates.create(kind, "Other"),
                ),
            )
        }
    }

    @Test
    fun escapesXmlTextAndStripsIllegalControls() {
        val bytes = NotesOoxmlTemplates.create(NotesOoxmlKind.DOCX, "a&b<c>d\u0000\u0001")
        val text = entriesWithBytes(bytes)["word/document.xml"]!!.toString(Charsets.UTF_8)
        assertTrue(text.contains("a&amp;b&lt;c&gt;d"))
        assertFalse(text.contains('\u0000'))
    }

    @Test
    fun refusesMissingContentTypesAndNonZip() {
        val bytes = NotesOoxmlTemplates.create(NotesOoxmlKind.DOCX, "Title")
        val parts = entriesWithBytes(bytes).filterKeys { it != "[Content_Types].xml" }
        val rebuilt = zip(parts)
        val validation = NotesOoxmlTemplates.validate(rebuilt, NotesOoxmlKind.DOCX)
        assertFalse(validation.ok)
        assertEquals("contentTypesMissing", validation.reason)
        assertFalse(NotesOoxmlTemplates.validate(byteArrayOf(1, 2, 3), NotesOoxmlKind.DOCX).ok)
        assertFalse(NotesOoxmlTemplates.validate(bytes, "xlsx").ok)
    }

    @Test
    fun sheetNamesAreBoundedAndSanitized() {
        assertEquals("Sheet1", NotesOoxmlTemplates.sheetName(""))
        assertEquals("a b c d e f g h", NotesOoxmlTemplates.sheetName("a[b]c:d*e?f/g\\h").trim())
        assertTrue(NotesOoxmlTemplates.sheetName("x".repeat(100)).length <= 31)
        assertEquals("Sheet1", NotesOoxmlTemplates.sheetName("History"))
    }

    @Test
    fun mimeAndExtensionMappingIsConcrete() {
        assertEquals(NotesOoxmlKind.DOCX, NotesOoxmlKind.forExtension("DOCX"))
        assertEquals(NotesOoxmlKind.XLSX, NotesOoxmlTemplates.kindForMime(
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        ))
        assertEquals(null, NotesOoxmlTemplates.kindForMime("*/*"))
        assertNotNull(NotesOoxmlKind.PPTX.mainPart)
    }

    private fun entries(bytes: ByteArray): Set<String> = entriesWithBytes(bytes).keys

    private fun entriesWithBytes(bytes: ByteArray): LinkedHashMap<String, ByteArray> {
        val result = LinkedHashMap<String, ByteArray>()
        ZipInputStream(ByteArrayInputStream(bytes)).use { input ->
            var entry = input.nextEntry
            while (entry != null) {
                val out = java.io.ByteArrayOutputStream()
                input.copyTo(out)
                result[entry.name] = out.toByteArray()
                entry = input.nextEntry
            }
        }
        return result
    }

    private fun zip(parts: Map<String, ByteArray>): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        java.util.zip.ZipOutputStream(out).use { zip ->
            for ((name, bytes) in parts) {
                zip.putNextEntry(java.util.zip.ZipEntry(name))
                zip.write(bytes)
                zip.closeEntry()
            }
        }
        return out.toByteArray()
    }
}
