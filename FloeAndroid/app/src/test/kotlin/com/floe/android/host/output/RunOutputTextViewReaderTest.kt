// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.output

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The real production text reader for the App-owned run-output viewer. These
 * tests write actual files and prove: 64 KiB chunking reaches real EOF (a
 * page window is not whole-file truncation), 256/410 KiB texts are fully
 * returned, BOM/CRLF/emoji/double-BOM bytes decode exactly, NUL/invalid
 * UTF-8 is refused instead of replacement-decoded, and only the reader's own
 * 4 MiB cap reports truncation.
 */
class RunOutputTextViewReaderTest {

    @Test
    fun layoutPagesKeepLargeTextAndEofWithoutOneHugeLayout() {
        val text = "\uFEFF" + "line-中文-😀\r\n".repeat(30_000) + "EOF_410K\r\n"
        val pages = RunOutputTextViewReader.displayPages(text)
        assertTrue(pages.size > 1)
        assertTrue(pages.all { it.length <= RunOutputTextViewReader.DISPLAY_PAGE_CHARS })
        assertEquals(text, pages.joinToString(""))
        assertTrue(pages.last().endsWith("EOF_410K\r\n"))
    }

    @Test
    fun layoutPagesDoNotSplitEmojiOrCrlfOnVeryLongLines() {
        val n = RunOutputTextViewReader.DISPLAY_PAGE_CHARS
        for (boundary in listOf("😀", "\r\n")) {
            val text = "x".repeat(n - 1) + boundary + "y".repeat(n * 2)
            val pages = RunOutputTextViewReader.displayPages(text)
            assertEquals(text, pages.joinToString(""))
            assertTrue(pages.all { it.length <= n })
            assertTrue(pages.none { it.firstOrNull()?.isLowSurrogate() == true })
            assertTrue(pages.none { it.lastOrNull()?.isHighSurrogate() == true })
            assertTrue(pages.dropLast(1).none { it.endsWith('\r') })
        }
    }

    @Test
    fun layoutKeepsAnEmptyFileReadable() {
        assertEquals(listOf(""), RunOutputTextViewReader.displayPages(""))
    }

    private fun tempFile(name: String = "document.txt"): File =
        File(System.getProperty("java.io.tmpdir"), "ro-text-${System.nanoTime()}-$name")
            .also { it.deleteOnExit() }

    private fun success(file: File): RunOutputTextViewReader.Page {
        val result = RunOutputTextViewReader.read(file)
        assertTrue("expected readable UTF-8 text, got $result",
            result is RunOutputTextViewReader.Result.Success)
        return (result as RunOutputTextViewReader.Result.Success).page
    }

    @Test
    fun reads256KiBAnd410KiBThroughRealEof() {
        for (targetBytes in listOf(256 * 1024, 410 * 1024)) {
            val unit = "line-äöü-emoji-😀-中文\r\n"
            val unitBytes = unit.toByteArray(Charsets.UTF_8).size
            val builder = StringBuilder()
            var size = 0
            while (size < targetBytes) {
                builder.append(unit)
                size += unitBytes
            }
            val text = builder.toString()
            val bytes = text.toByteArray(Charsets.UTF_8)
            val file = tempFile("large-$targetBytes.txt")
            try {
                file.writeBytes(bytes)
                val page = success(file)
                assertEquals(bytes.size.toLong(), page.totalBytes)
                assertFalse(page.truncated)
                assertEquals(text, page.text)
                assertTrue("must read multiple 64 KiB pages", page.chunksRead > 1)
            } finally {
                file.delete()
            }
        }
    }

    @Test
    fun preservesBomCrlfEmojiAndDoubleBomExactly() {
        val text = "\uFEFF\uFEFFfirst\r\nsecond 😀 中文\r\n"
        val file = tempFile()
        try {
            file.writeBytes(text.toByteArray(Charsets.UTF_8))
            val page = success(file)
            assertEquals(text, page.text)
            assertFalse(page.truncated)
            assertEquals(text.toByteArray(Charsets.UTF_8).size.toLong(), page.totalBytes)
        } finally {
            file.delete()
        }
    }

    @Test
    fun refusesNulAndInvalidUtf8InsteadOfReplacementDecoding() {
        val nul = tempFile("nul.txt")
        try {
            nul.writeBytes(byteArrayOf(0x41, 0x00, 0x42))
            assertEquals(RunOutputTextViewReader.Result.NotUTF8Text,
                RunOutputTextViewReader.read(nul))
        } finally {
            nul.delete()
        }
        val invalid = tempFile("invalid.txt")
        try {
            invalid.writeBytes(byteArrayOf(0x41, 0x80.toByte(), 0x42))
            assertEquals(RunOutputTextViewReader.Result.NotUTF8Text,
                RunOutputTextViewReader.read(invalid))
        } finally {
            invalid.delete()
        }
        // UTF-16 content carries NUL bytes: never a text decode.
        val utf16 = tempFile("utf16.txt")
        try {
            utf16.writeBytes(byteArrayOf(0xFF.toByte(), 0xFE.toByte(), 0x68, 0x00, 0x69, 0x00))
            assertEquals(RunOutputTextViewReader.Result.NotUTF8Text,
                RunOutputTextViewReader.read(utf16))
        } finally {
            utf16.delete()
        }
    }

    @Test
    fun onlyTheDisplayCapReportsTruncation() {
        val file = tempFile("huge.txt")
        try {
            val cap = RunOutputTextViewReader.MAX_BYTES.toInt()
            val bytes = ByteArray(cap + 64) { 0x61.toByte() }
            file.writeBytes(bytes)
            val page = success(file)
            assertTrue(page.truncated)
            assertEquals(bytes.size.toLong(), page.totalBytes)
            assertEquals(cap, page.text.toByteArray(Charsets.UTF_8).size)
        } finally {
            file.delete()
        }
    }
}
