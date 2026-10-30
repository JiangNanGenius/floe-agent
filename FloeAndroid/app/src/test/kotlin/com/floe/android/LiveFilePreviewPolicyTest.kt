// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import java.security.MessageDigest
import org.junit.Assert.*
import org.junit.Test

class LiveFilePreviewPolicyTest {
    private fun sha(value: ByteArray) = MessageDigest.getInstance("SHA-256").digest(value)
        .joinToString("") { "%02x".format(it.toInt() and 255) }

    @Test fun completeUnicodeTextUsesTheExactMeasuredBytes() {
        val bytes = "中文 A😀\n".toByteArray()
        val result = LiveFilePreviewPolicy.decode(bytes, sha(bytes), false) as LiveFilePreviewPolicy.Result.Text
        assertEquals("中文 A😀\n", result.value)
        assertFalse(result.truncated)
    }
    @Test fun boundedPrefixCanEndInsideAMultibyteCharacterWithoutShowingReplacement() {
        val bytes = "A😀".toByteArray().copyOf(3)
        val result = LiveFilePreviewPolicy.decode(bytes, sha(bytes), true) as LiveFilePreviewPolicy.Result.Text
        assertEquals("A", result.value)
        assertTrue(result.truncated)
        assertEquals(LiveFilePreviewPolicy.Result.NotText, LiveFilePreviewPolicy.decode(bytes, sha(bytes), false))
    }
    @Test fun invalidInteriorAndBinaryDataNeverBecomeEditableText() {
        val malformed = byteArrayOf(65, -1, 66)
        assertEquals(LiveFilePreviewPolicy.Result.NotText, LiveFilePreviewPolicy.decode(malformed, sha(malformed), true))
        val binary = byteArrayOf(65, 0, 66)
        assertEquals(LiveFilePreviewPolicy.Result.NotText, LiveFilePreviewPolicy.decode(binary, sha(binary), false))
    }
    @Test fun wrongDigestAndOversizedPageAreRejectedAndEmptyFileIsValid() {
        val bytes = "actual".toByteArray()
        assertEquals(LiveFilePreviewPolicy.Result.Invalid, LiveFilePreviewPolicy.decode(bytes, "0".repeat(64), false))
        val large = ByteArray(24577) { 65 }
        assertEquals(LiveFilePreviewPolicy.Result.Invalid, LiveFilePreviewPolicy.decode(large, sha(large), true))
        val empty = ByteArray(0)
        assertEquals("", (LiveFilePreviewPolicy.decode(empty, sha(empty), false) as LiveFilePreviewPolicy.Result.Text).value)
    }
}
