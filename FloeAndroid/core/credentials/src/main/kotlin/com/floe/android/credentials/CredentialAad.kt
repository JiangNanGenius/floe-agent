// SPDX-License-Identifier: MPL-2.0
package com.floe.android.credentials

import java.io.ByteArrayOutputStream
import java.nio.charset.StandardCharsets

/**
 * Canonical additional authenticated data for one credential record.
 *
 * The AAD binds the envelope format version, namespace and opaque reference.
 * Moving a ciphertext file to another reference (or namespace) therefore fails
 * AES-GCM authentication instead of decrypting under a different name.
 */
internal object CredentialAad {
    private const val VERSION = 1 // keep in sync with EnvelopeCodec.VERSION
    private val MAGIC = byteArrayOf('F'.code.toByte(), 'L'.code.toByte(), 'C'.code.toByte(), 'A'.code.toByte())

    fun encode(namespace: String, reference: String): ByteArray {
        val namespaceBytes = namespace.toByteArray(StandardCharsets.UTF_8)
        val referenceBytes = reference.toByteArray(StandardCharsets.UTF_8)
        val output = ByteArrayOutputStream(4 + 1 + 2 + namespaceBytes.size + 2 + referenceBytes.size)
        output.write(MAGIC)
        output.write(VERSION)
        writeU16(output, namespaceBytes.size)
        output.write(namespaceBytes)
        writeU16(output, referenceBytes.size)
        output.write(referenceBytes)
        return output.toByteArray()
    }

    private fun writeU16(output: ByteArrayOutputStream, value: Int) {
        require(value in 0..0xFFFF) { "AAD field too large" }
        output.write((value ushr 8) and 0xFF)
        output.write(value and 0xFF)
    }
}
