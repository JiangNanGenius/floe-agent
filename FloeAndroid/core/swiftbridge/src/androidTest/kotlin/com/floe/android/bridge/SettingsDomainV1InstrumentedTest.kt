package com.floe.android.bridge

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.floe.android.contracts.SettingsDomainV1
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayOutputStream

/**
 * Device-side source checks for the settings-domain P0 vocabulary.
 *
 * These tests exercise only pure Kotlin value helpers and the closed payload
 * validator. They register no handler, touch no database, resolve no
 * credential and make no network call. Authored source is not a device pass.
 */
@RunWith(AndroidJUnit4::class)
class SettingsDomainV1InstrumentedTest {
    @Test
    fun payloadValidationRejectsUnknownAndAcceptsClosedShapes() {
        assertNull(SettingsDomainV1.validate(
            command = "memory.add",
            label = "memory",
            createIntent = true,
            revisionPresent = false,
            payload = mapOf("content" to "hello", "scope" to mapOf("kind" to "user")),
        ))
        assertEquals("unknownMemoryField", SettingsDomainV1.validate(
            command = "memory.add",
            label = "memory",
            createIntent = true,
            revisionPresent = false,
            payload = mapOf(
                "content" to "hello",
                "scope" to mapOf("kind" to "user"),
                "dbPath" to "/tmp/x",
            ),
        )?.reason)
        assertEquals("createIntentRequired", SettingsDomainV1.validate(
            command = "personalization.generate",
            label = "personalization",
            createIntent = false,
            revisionPresent = false,
            payload = mapOf("kind" to "soul"),
        )?.reason)
        assertEquals("invalidPayloadField:isPinned", SettingsDomainV1.validate(
            command = "memory.list",
            label = "memory",
            createIntent = false,
            revisionPresent = false,
            payload = mapOf("isPinned" to 1),
        )?.reason)
        assertEquals("unknownDimension", SettingsDomainV1.validate(
            command = "usage.statistics.get",
            label = "usage",
            createIntent = false,
            revisionPresent = false,
            payload = mapOf("dimension" to "everything"),
        )?.reason)
        assertNull(SettingsDomainV1.validate(
            command = "usage.statistics.get",
            label = "usage",
            createIntent = false,
            revisionPresent = false,
            payload = mapOf("dimension" to "model", "limit" to 10),
        ))
    }

    @Test
    fun digestFixedVectorsAreStableOnDevice() {
        val domain = "floe.test-domain.v1"
        assertEquals(
            "sha256:8e266dda37a34717f46567b34e7d01235be575ae642e5cace0c20d42d79ed040",
            SettingsDomainV1.CanonicalDigest.token(
                domain, listOf(listOf(SettingsDomainV1.CanonicalDigest.Field.Null))),
        )
        assertEquals(
            "sha256:c1cc1e8fc89341e28d2a3392b7f6c5d8122d5bab7c4949c458a2fa1001a3e14e",
            SettingsDomainV1.CanonicalDigest.token(
                domain, listOf(listOf(
                    SettingsDomainV1.CanonicalDigest.Field.Text("a\u001Fb")))),
        )
    }

    @Test
    fun chunkReassemblyIsByteExactOnDevice() {
        val content = "A\uD83D\uDE00B\u4E2D\u6587C"
        var offset = 0
        val rebuilt = ByteArrayOutputStream()
        while (true) {
            val chunk = SettingsDomainV1.ContentBudget.chunk(content, offset, 4)
            rebuilt.write(chunk.chunk.toByteArray(Charsets.UTF_8))
            assertTrue(SettingsDomainV1.ContentBudget.fitsPageBudget(chunk))
            offset = chunk.nextOffset ?: break
        }
        assertEquals(content, rebuilt.toString("UTF-8"))
    }

    @Test
    fun terminalPageAndDenseEscapesAreBoundedOnDevice() {
        val terminal = SettingsDomainV1.ContentBudget.chunk("abc", 3, 1)
        assertEquals("", terminal.chunk)
        assertNull(terminal.nextOffset)
        assertTrue(SettingsDomainV1.ContentBudget.fitsPageBudget(terminal))
        var tinyFailed = false
        try {
            SettingsDomainV1.ContentBudget.chunk("abc", 3, 1, 8)
        } catch (_: IllegalArgumentException) {
            tinyFailed = true
        }
        assertTrue("tiny terminal budget must fail typed", tinyFailed)

        // 32KiB of the most expensive ASCII escapes: bounded work, near-budget
        // pages and byte-exact reassembly on the real API 37 runtime.
        val dense = "\"\\\u0001\n".repeat(8_192)
        var offset = 0
        var pages = 0
        val rebuilt = ByteArrayOutputStream()
        while (true) {
            val chunk = SettingsDomainV1.ContentBudget.chunk(dense, offset, 32_768)
            assertTrue(SettingsDomainV1.ContentBudget.fitsPageBudget(chunk))
            assertTrue(chunk.chunk.isNotEmpty())
            rebuilt.write(chunk.chunk.toByteArray(Charsets.UTF_8))
            pages += 1
            offset = chunk.nextOffset ?: break
        }
        assertEquals(dense, rebuilt.toString("UTF-8"))
        assertEquals(3, pages)
    }
}
