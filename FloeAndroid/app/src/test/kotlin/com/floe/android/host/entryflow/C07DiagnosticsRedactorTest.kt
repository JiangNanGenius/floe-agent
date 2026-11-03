// SPDX-License-Identifier: MPL-2.0
//
// C07 diagnostic-export privacy regressions. The test touches only the pure
// redactor; no Android diagnostic source, SAF document, log store or network
// is opened. AUTHORED, NOT RUN by this lane.
package com.floe.android.host.entryflow

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class C07DiagnosticsRedactorTest {
    @Test
    fun secretsPathsUrisAndAccountsAreRemoved() {
        val hash = "0123456789abcdef".repeat(4)
        val input = """
            authorization: Bearer sk-abcdefghijklmnopqrstuvwxyz123456
            api_key = super-secret-value
            refresh_token=abc.def.ghi
            jwt eyJabcdefghij.eyJklmnopqr.eyJstuvwxyz
            /Users/alice/Library/private/file.txt
            /data/user/0/com.floe.android/files/db
            content://private.provider/document/42
            file:///storage/emulated/0/Download/private.pdf
            alice@example.com
            api_keyword_notes = harmless
            sha256 $hash
        """.trimIndent()

        val redacted = C07EntryRedactor.redact(input)
        listOf(
            "sk-abcdefghijklmnopqrstuvwxyz123456",
            "super-secret-value",
            "abc.def.ghi",
            "eyJabcdefghij.eyJklmnopqr.eyJstuvwxyz",
            "/Users/alice",
            "/data/user/0",
            "content://private.provider",
            "file:///storage",
            "alice@example.com",
        ).forEach { secret ->
            assertFalse("leaked: $secret", redacted.contains(secret))
        }
        assertTrue(redacted.contains(hash))
        assertTrue(redacted.contains("api_keyword_notes = harmless"))
    }

    @Test
    fun controlCharactersAreRemovedAndBytesStayBounded() {
        val input = "line\u0000one\nline\u0007two\n" + "共享".repeat(80_000)
        val bounded = C07EntryRedactor.bounded(input, 4_096)
        assertFalse(bounded.contains('\u0000'))
        assertTrue(bounded.toByteArray(Charsets.UTF_8).size <= 4_096)
        assertTrue(bounded.endsWith("[truncated]\n"))
        // The cut must not leave a replacement character from a split code point.
        assertFalse(bounded.contains('\uFFFD'))
    }

    @Test
    fun shortHashAndOrdinaryCopySurvive() {
        val input = "version=1.7.51 build=292\n" +
            "sha256 " + "a".repeat(64) + "\n" +
            "The task stopped after a network timeout."
        val redacted = C07EntryRedactor.redact(input)
        assertTrue(redacted.contains("version=1.7.51 build=292"))
        assertTrue(redacted.contains("a".repeat(64)))
        assertTrue(redacted.contains("network timeout"))
    }
}
