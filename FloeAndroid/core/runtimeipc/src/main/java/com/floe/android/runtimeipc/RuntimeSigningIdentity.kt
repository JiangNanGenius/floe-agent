// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtimeipc

import android.content.pm.PackageInfo
import android.content.pm.Signature
import java.security.MessageDigest

/** Current signing identity only. Android 9 introduced SigningInfo; its
 * documented single-signer route is the LAST certificate in ordered history.
 * A past signer is never substituted for the current certificate. Both
 * installers use this same reader and retain their exact-set policy. */
object RuntimeSigningIdentity {
    fun read(info: PackageInfo?): Set<String> {
        val signing = runCatching { info?.signingInfo }.getOrNull() ?: return emptySet()
        val multiple = runCatching { signing.hasMultipleSigners() }.getOrNull() ?: return emptySet()
        val current = runCatching { digests(signing.apkContentsSigners).toSet() }.getOrDefault(emptySet())
        val history = if (multiple) emptyList() else
            runCatching { digests(signing.signingCertificateHistory) }.getOrDefault(emptyList())
        return selectCurrent(multiple, current, history)
    }

    private fun digests(values: Array<Signature>?): List<String> = values.orEmpty().map { signature ->
        MessageDigest.getInstance("SHA-256").digest(signature.toByteArray()).joinToString("") { "%02x".format(it) }
    }

    internal fun selectCurrent(multiple: Boolean, current: Set<String>, history: List<String>): Set<String> {
        val sha256 = Regex("^[0-9a-f]{64}$")
        if (current.any { !sha256.matches(it) } || history.any { !sha256.matches(it) }) return emptySet()
        if (multiple) return current.takeIf { it.size >= 2 } ?: emptySet()
        if (current.size > 1) return emptySet()
        val last = history.lastOrNull()
        if (last != null) {
            if (current.isNotEmpty() && current != setOf(last)) return emptySet()
            return setOf(last)
        }
        // Contents are independently a current-signing proof, not a legacy
        // GET_SIGNATURES/oldest-history fallback. Missing proofs still refuse.
        return current
    }
}
