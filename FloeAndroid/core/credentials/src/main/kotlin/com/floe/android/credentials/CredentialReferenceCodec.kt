// SPDX-License-Identifier: MPL-2.0
package com.floe.android.credentials

import java.nio.charset.StandardCharsets
import java.security.MessageDigest

/**
 * Opaque identifier rules and deterministic, path-safe derivation.
 *
 * Raw references never become filenames or key aliases. A SHA-256 digest of the
 * namespace and reference is used for both, so traversal characters in caller
 * input cannot escape the module's private directory even if validation is
 * bypassed by a future caller.
 */
internal object CredentialReferenceCodec {
    const val RECORD_DOMAIN = "floe.cred.record.v1"
    const val ALIAS_DOMAIN = "floe.cred.key.v1"
    const val NAMESPACE_DOMAIN = "floe.cred.namespace.v1"

    private val referencePattern = Regex("[A-Za-z0-9][A-Za-z0-9._:-]*")
    private val namespacePattern = Regex("[A-Za-z0-9][A-Za-z0-9._-]*")

    fun requireReference(reference: String): String {
        if (reference.length > CredentialLimits.MAX_REFERENCE_CHARS || !referencePattern.matches(reference)) {
            throw CredentialStoreException.InvalidReference()
        }
        return reference
    }

    fun requireNamespace(namespace: String): String {
        if (namespace.length > CredentialLimits.MAX_NAMESPACE_CHARS || !namespacePattern.matches(namespace)) {
            throw CredentialStoreException.InvalidNamespace()
        }
        return namespace
    }

    fun recordId(namespace: String, reference: String): String =
        sha256Hex(NAMESPACE_DOMAIN, namespace, RECORD_DOMAIN, reference)

    fun namespaceId(namespace: String): String = sha256Hex(NAMESPACE_DOMAIN, namespace)

    fun keyAlias(namespace: String, reference: String): String =
        "$ALIAS_DOMAIN.${recordId(namespace, reference)}"

    fun keyAliasForRecordId(recordId: String): String = "$ALIAS_DOMAIN.$recordId"

    private fun sha256Hex(vararg fields: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
        fields.forEachIndexed { index, field ->
            if (index > 0) digest.update(0.toByte())
            digest.update(field.toByteArray(StandardCharsets.UTF_8))
        }
        return toHex(digest.digest())
    }

    private fun toHex(bytes: ByteArray): String {
        val alphabet = "0123456789abcdef"
        val chars = CharArray(bytes.size * 2)
        bytes.forEachIndexed { index, byte ->
            val value = byte.toInt() and 0xFF
            chars[index * 2] = alphabet[value ushr 4]
            chars[index * 2 + 1] = alphabet[value and 0x0F]
        }
        return String(chars)
    }
}
