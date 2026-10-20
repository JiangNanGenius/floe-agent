// SPDX-License-Identifier: MPL-2.0
package com.floe.android.credentials

import java.io.OutputStream

internal data class ParsedEnvelope(val iv: ByteArray, val ciphertext: ByteArray)

/**
 * Bounded binary record format:
 *
 * ```
 * offset 0  4 bytes  "FCRD"
 * offset 4  1 byte   format version (1)
 * offset 5  1 byte   IV length (12)
 * offset 6  N bytes  random GCM IV
 * ...       M bytes  ciphertext including the 16-byte GCM tag
 * ```
 *
 * Only ciphertext is persisted; the IV and header are not secret.
 */
internal object EnvelopeCodec {
    const val VERSION = 1
    const val IV_BYTES = 12
    const val GCM_TAG_BYTES = 16
    const val HEADER_BYTES = 6
    const val MIN_ENVELOPE_BYTES = HEADER_BYTES + IV_BYTES + GCM_TAG_BYTES
    const val MAX_ENVELOPE_BYTES = CredentialLimits.MAX_ENVELOPE_BYTES
    const val MAX_CIPHERTEXT_BYTES = CredentialLimits.MAX_SECRET_BYTES + GCM_TAG_BYTES

    private val MAGIC = byteArrayOf('F'.code.toByte(), 'C'.code.toByte(), 'R'.code.toByte(), 'D'.code.toByte())

    fun writeTo(output: OutputStream, iv: ByteArray, ciphertext: ByteArray) {
        if (iv.size != IV_BYTES ||
            ciphertext.size < GCM_TAG_BYTES ||
            ciphertext.size > MAX_CIPHERTEXT_BYTES
        ) {
            throw CredentialStoreException.KeyStoreFailure()
        }
        output.write(MAGIC)
        output.write(VERSION)
        output.write(IV_BYTES)
        output.write(iv)
        output.write(ciphertext)
    }

    fun parse(bytes: ByteArray): ParsedEnvelope {
        if (bytes.size < MIN_ENVELOPE_BYTES || bytes.size > MAX_ENVELOPE_BYTES) {
            throw CredentialStoreException.CorruptRecord()
        }
        for (index in MAGIC.indices) {
            if (bytes[index] != MAGIC[index]) throw CredentialStoreException.CorruptRecord()
        }
        val version = bytes[4].toInt() and 0xFF
        if (version != VERSION) throw CredentialStoreException.CorruptRecord()
        val ivLength = bytes[5].toInt() and 0xFF
        if (ivLength != IV_BYTES) throw CredentialStoreException.CorruptRecord()
        val ciphertextOffset = HEADER_BYTES + ivLength
        if (ciphertextOffset > bytes.size - GCM_TAG_BYTES) throw CredentialStoreException.CorruptRecord()
        val iv = bytes.copyOfRange(HEADER_BYTES, ciphertextOffset)
        val ciphertext = bytes.copyOfRange(ciphertextOffset, bytes.size)
        if (ciphertext.size > MAX_CIPHERTEXT_BYTES) throw CredentialStoreException.CorruptRecord()
        return ParsedEnvelope(iv, ciphertext)
    }
}
