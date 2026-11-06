// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

import java.io.ByteArrayInputStream
import java.io.IOException
import java.nio.charset.CharacterCodingException
import org.junit.Assert.*
import org.junit.Test

class UpdateTextReaderTest {
    @Test fun networkChunksMaySplitEveryMultibyteCharacter() {
        val text = "{\"body\":\"N01–N08 路径，更新说明 🎨\"}"
        val bytes = text.toByteArray(Charsets.UTF_8)
        for (chunk in 1..7) {
            val input = object : ByteArrayInputStream(bytes) {
                override fun read(b: ByteArray, off: Int, len: Int): Int = super.read(b, off, minOf(len, chunk))
            }
            assertEquals(text, UpdateTextReader.read(input, bytes.size.toLong()) { throw IOException("limit") })
        }
    }
    @Test fun limitsStillCountBytesAndMalformedUtf8FailsClosed() {
        assertThrows(IOException::class.java) {
            UpdateTextReader.read(ByteArrayInputStream("路径".toByteArray()), 5) { throw IOException("limit") }
        }
        assertThrows(CharacterCodingException::class.java) {
            UpdateTextReader.read(ByteArrayInputStream(byteArrayOf(0xe8.toByte(), 0xb7.toByte())), 2) { throw IOException("limit") }
        }
    }
    @Test fun knownIssuesStopAtBilingualSectionDivider() {
        assertEquals("中文限制", ReleaseKnownIssues.parse("## 已知问题\n- 中文限制\n\n---\nEnglish release notes\n"))
        assertEquals("Limit", ReleaseKnownIssues.parse("## Known issues\n- Limit\n\n* * *\nOther notes\n"))
    }
}
