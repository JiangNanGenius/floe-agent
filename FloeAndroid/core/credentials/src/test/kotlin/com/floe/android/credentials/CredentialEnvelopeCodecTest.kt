// SPDX-License-Identifier: MPL-2.0
package com.floe.android.credentials

import java.io.ByteArrayOutputStream
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class CredentialEnvelopeCodecTest {
    private fun envelope(iv: ByteArray = sampleIv(), ciphertext: ByteArray = sampleCiphertext()): ByteArray {
        val output = ByteArrayOutputStream()
        EnvelopeCodec.writeTo(output, iv, ciphertext)
        return output.toByteArray()
    }

    private fun sampleIv(): ByteArray = ByteArray(EnvelopeCodec.IV_BYTES) { (it + 1).toByte() }

    private fun sampleCiphertext(size: Int = 48): ByteArray = ByteArray(size) { (it * 7).toByte() }

    @Test
    fun roundTripsIvAndCiphertext() {
        val iv = sampleIv()
        val ciphertext = sampleCiphertext()
        val parsed = EnvelopeCodec.parse(envelope(iv, ciphertext))
        assertArrayEquals(iv, parsed.iv)
        assertArrayEquals(ciphertext, parsed.ciphertext)
        assertEquals(EnvelopeCodec.HEADER_BYTES + EnvelopeCodec.IV_BYTES + ciphertext.size,
            envelope(iv, ciphertext).size)
    }

    @Test
    fun acceptsTheMaximumCiphertext() {
        val ciphertext = sampleCiphertext(EnvelopeCodec.MAX_CIPHERTEXT_BYTES)
        val bytes = envelope(ciphertext = ciphertext)
        assertEquals(CredentialLimits.MAX_ENVELOPE_BYTES, bytes.size)
        assertEquals(EnvelopeCodec.MAX_CIPHERTEXT_BYTES, EnvelopeCodec.parse(bytes).ciphertext.size)
    }

    @Test
    fun rejectsBadMagicVersionAndIvLength() {
        val valid = envelope()
        valid[0] = 0
        assertThrows(CredentialStoreException.CorruptRecord::class.java) { EnvelopeCodec.parse(valid) }

        val version = envelope()
        version[4] = 2
        assertThrows(CredentialStoreException.CorruptRecord::class.java) { EnvelopeCodec.parse(version) }

        val ivLength = envelope()
        ivLength[5] = (EnvelopeCodec.IV_BYTES - 1).toByte()
        assertThrows(CredentialStoreException.CorruptRecord::class.java) { EnvelopeCodec.parse(ivLength) }
    }

    @Test
    fun rejectsTruncatedEmptyAndOversizeRecords() {
        assertThrows(CredentialStoreException.CorruptRecord::class.java) {
            EnvelopeCodec.parse(ByteArray(0))
        }
        assertThrows(CredentialStoreException.CorruptRecord::class.java) {
            EnvelopeCodec.parse(ByteArray(EnvelopeCodec.MIN_ENVELOPE_BYTES - 1))
        }
        assertThrows(CredentialStoreException.CorruptRecord::class.java) {
            EnvelopeCodec.parse(ByteArray(EnvelopeCodec.MAX_ENVELOPE_BYTES + 1))
        }
    }

    @Test
    fun rejectsInvalidEncoderInputs() {
        val output = ByteArrayOutputStream()
        assertThrows(CredentialStoreException.KeyStoreFailure::class.java) {
            EnvelopeCodec.writeTo(output, ByteArray(EnvelopeCodec.IV_BYTES - 1), sampleCiphertext())
        }
        assertThrows(CredentialStoreException.KeyStoreFailure::class.java) {
            EnvelopeCodec.writeTo(output, sampleIv(), sampleCiphertext(EnvelopeCodec.GCM_TAG_BYTES - 1))
        }
        assertThrows(CredentialStoreException.KeyStoreFailure::class.java) {
            EnvelopeCodec.writeTo(output, sampleIv(), sampleCiphertext(EnvelopeCodec.MAX_CIPHERTEXT_BYTES + 1))
        }
    }

    @Test
    fun parseCopiesBuffersInsteadOfAliasingTheFileArray() {
        val bytes = envelope()
        val parsed = EnvelopeCodec.parse(bytes)
        val originalIv = parsed.iv.copyOf()
        val originalCiphertext = parsed.ciphertext.copyOf()
        bytes.fill(0)
        assertArrayEquals(originalIv, parsed.iv)
        assertArrayEquals(originalCiphertext, parsed.ciphertext)
        assertFalse(parsed.ciphertext.all { it == 0.toByte() })
    }

    @Test
    fun sizeConstantsMatchTheDocumentedBound() {
        assertTrue(EnvelopeCodec.MAX_CIPHERTEXT_BYTES == CredentialLimits.MAX_SECRET_BYTES + EnvelopeCodec.GCM_TAG_BYTES)
        assertTrue(CredentialLimits.MAX_ENVELOPE_BYTES ==
            EnvelopeCodec.HEADER_BYTES + EnvelopeCodec.IV_BYTES + EnvelopeCodec.MAX_CIPHERTEXT_BYTES)
    }
}
