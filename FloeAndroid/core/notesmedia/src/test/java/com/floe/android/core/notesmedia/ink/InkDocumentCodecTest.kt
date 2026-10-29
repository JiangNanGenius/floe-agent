// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.ink

import com.floe.android.core.notesmedia.media.InkFormat
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class InkDocumentCodecTest {

    private fun stroke(id: Long, family: String = InkBrushSpec.FAMILY_PEN) = InkStroke(
        id = id,
        brush = InkBrushSpec(family, 0xFF336699.toInt(), 3.5f),
        inputs = byteArrayOf(1, 2, 3, 4, 5),
        bounds = InkBox(10f, 20f, 30f, 40f),
        transform = InkAffine(1f, 0f, 0f, 1f, 4f, -2f),
    )

    private fun snapshot(strokes: List<InkStroke> = listOf(stroke(1), stroke(2))) = InkSnapshot(
        documentId = "doc-1",
        geometry = InkPageGeometry("page-1", 612f, 792f),
        revision = 7,
        strokes = strokes,
    )

    @Test
    fun roundTripPreservesEverything() {
        val original = snapshot()
        val encoded = InkDocumentCodec.encode(original)
        assertTrue(encoded is InkEncodeResult.Ok)
        val bytes = (encoded as InkEncodeResult.Ok).bytes
        assertEquals(InkFormat.CURRENT, InkDocumentCodec.probeVersion(bytes))
        val decoded = InkDocumentCodec.decode(bytes)
        assertTrue(decoded is InkDecodeResult.Ok)
        val restored = (decoded as InkDecodeResult.Ok).snapshot
        assertEquals(original.documentId, restored.documentId)
        assertEquals(original.geometry, restored.geometry)
        assertEquals(original.revision, restored.revision)
        assertEquals(2, restored.strokes.size)
        assertArrayEquals(original.strokes[0].inputs, restored.strokes[0].inputs)
        assertEquals(original.strokes[0], restored.strokes[0])
    }

    @Test
    fun emptyDocumentRoundTrips() {
        val encoded = InkDocumentCodec.encode(snapshot(emptyList())) as InkEncodeResult.Ok
        val decoded = InkDocumentCodec.decode(encoded.bytes) as InkDecodeResult.Ok
        assertEquals(0, decoded.snapshot.strokes.size)
        assertEquals(7L, decoded.snapshot.revision)
    }

    @Test
    fun corruptedByteFailsChecksum() {
        val bytes = (InkDocumentCodec.encode(snapshot()) as InkEncodeResult.Ok).bytes
        bytes[bytes.size / 2] = (bytes[bytes.size / 2].toInt() xor 0x5A).toByte()
        val decoded = InkDocumentCodec.decode(bytes)
        assertTrue(decoded is InkDecodeResult.Invalid)
        assertTrue(
            (decoded as InkDecodeResult.Invalid).refusal in setOf(
                InkCodecRefusal.CHECKSUM_MISMATCH,
                InkCodecRefusal.INVALID_FIELD,
                InkCodecRefusal.TRUNCATED,
            ),
        )
    }

    @Test
    fun truncationAndTrailingBytesAreRefused() {
        val bytes = (InkDocumentCodec.encode(snapshot()) as InkEncodeResult.Ok).bytes
        assertTrue(
            (InkDocumentCodec.decode(bytes.copyOf(bytes.size - 3)) as InkDecodeResult.Invalid)
                .refusal == InkCodecRefusal.TRUNCATED,
        )
        val padded = bytes + byteArrayOf(0, 0)
        assertEquals(
            InkCodecRefusal.TRAILING_BYTES,
            (InkDocumentCodec.decode(padded) as InkDecodeResult.Invalid).refusal,
        )
    }

    @Test
    fun badMagicAndUnsupportedVersionAreRefused() {
        val bytes = (InkDocumentCodec.encode(snapshot()) as InkEncodeResult.Ok).bytes
        val badMagic = bytes.copyOf().also { it[0] = 'X'.code.toByte() }
        assertEquals(
            InkCodecRefusal.BAD_MAGIC,
            (InkDocumentCodec.decode(badMagic) as InkDecodeResult.Invalid).refusal,
        )
        val future = bytes.copyOf().also { it[8] = 0; it[9] = 9 }
        assertEquals(
            InkCodecRefusal.UNSUPPORTED_VERSION,
            (InkDocumentCodec.decode(future) as InkDecodeResult.Invalid).refusal,
        )
        assertNull(InkDocumentCodec.probeVersion("nope".toByteArray()))
    }

    @Test
    fun nonFiniteBoundsAreRefusedByTheModel() {
        var threw = false
        try {
            InkStroke(
                id = 1,
                brush = InkBrushSpec.pen(0, 1f),
                inputs = byteArrayOf(1),
                bounds = InkBox(Float.NaN, 0f, 1f, 1f),
            )
        } catch (_: IllegalArgumentException) {
            threw = true
        }
        assertTrue(threw)
    }
}
