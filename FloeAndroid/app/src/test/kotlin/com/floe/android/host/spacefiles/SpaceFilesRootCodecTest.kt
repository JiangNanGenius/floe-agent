// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.spacefiles

import com.floe.android.safgateway.SafUriRef
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Saved-root metadata codec: exact identities in, exact identities out. */
class SpaceFilesRootCodecTest {

    @Test
    fun roundTripsExactUriBytesAndDisplayText() {
        val roots = listOf(
            SpaceFilesRoot(
                uri = SafUriRef("content://com.floe.test.documents/tree/primary%3ASpaceFiles"),
                name = "Space Files",
                savedAtMillis = 1_000L,
            ),
            SpaceFilesRoot(
                uri = SafUriRef("content://com.floe.test.documents/tree/primary%3ADownload%2FQA"),
                name = "QA \"quoted\"\nsecond line",
                savedAtMillis = 2_000L,
            ),
        )

        val decoded = SpaceFilesRootCodec.decode(SpaceFilesRootCodec.encode(roots))

        assertEquals(roots, decoded)
        assertEquals(
            "the provider tree URI keeps its exact percent-encoded form",
            "content://com.floe.test.documents/tree/primary%3ADownload%2FQA",
            decoded[1].uri.uriString,
        )
    }

    @Test
    fun blankAndMalformedInputDecodeToNothing() {
        assertTrue(SpaceFilesRootCodec.decode(null).isEmpty())
        assertTrue(SpaceFilesRootCodec.decode("").isEmpty())
        assertTrue(SpaceFilesRootCodec.decode("   ").isEmpty())
        assertTrue(SpaceFilesRootCodec.decode("not-json").isEmpty())
        assertTrue(SpaceFilesRootCodec.decode("{\"uri\":\"content://x\"}").isEmpty())
    }

    @Test
    fun nonContentAndMalformedRowsAreDroppedWithoutGuessing() {
        val raw = """
            [
              {"uri":"file:///sdcard/Download","name":"path","savedAtMillis":1},
              {"uri":"content://com.floe.test.documents/tree/ok","name":"kept"},
              {"name":"missing uri","savedAtMillis":3},
              "not-an-object"
            ]
        """.trimIndent()

        val decoded = SpaceFilesRootCodec.decode(raw)

        assertEquals(1, decoded.size)
        assertEquals("content://com.floe.test.documents/tree/ok", decoded.single().uri.uriString)
        assertEquals("kept", decoded.single().name)
        assertEquals("a missing time is preserved as unknown, never invented", 0L, decoded.single().savedAtMillis)
    }

    @Test
    fun duplicateUrisKeepTheFirstExactRow() {
        val raw = """
            [
              {"uri":"content://com.floe.test.documents/tree/one","name":"first","savedAtMillis":1},
              {"uri":"content://com.floe.test.documents/tree/one","name":"second","savedAtMillis":2}
            ]
        """.trimIndent()

        val decoded = SpaceFilesRootCodec.decode(raw)

        assertEquals(1, decoded.size)
        assertEquals("first", decoded.single().name)
        assertEquals(1L, decoded.single().savedAtMillis)
    }

    @Test
    fun encodedMetadataCarriesNoGrantOrContentFields() {
        val encoded = SpaceFilesRootCodec.encode(
            listOf(
                SpaceFilesRoot(
                    uri = SafUriRef("content://com.floe.test.documents/tree/one"),
                    name = "One",
                    savedAtMillis = 1L,
                ),
            ),
        )

        assertTrue(encoded.contains("\"uri\""))
        assertTrue(encoded.contains("\"name\""))
        assertTrue(encoded.contains("\"savedAtMillis\""))
        assertTrue("permission bits must not be persisted", !encoded.contains("read", ignoreCase = true))
        assertTrue("provider ACLs must not be persisted", !encoded.contains("write", ignoreCase = true))
    }
}
