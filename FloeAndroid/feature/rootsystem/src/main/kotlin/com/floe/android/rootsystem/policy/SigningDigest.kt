// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.policy

import java.security.MessageDigest
import java.security.cert.X509Certificate

/** Stable signing-identity digest shared by the App config and server verification. */
object SigningDigest {
    fun of(certificates: Array<X509Certificate>): String {
        require(certificates.isNotEmpty()) { "no signing certificates" }
        val digest = MessageDigest.getInstance("SHA-256")
        certificates
            .map { it.encoded }
            .sortedWith { a, b -> compareBytes(a, b) }
            .forEach { digest.update(it) }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun compareBytes(a: ByteArray, b: ByteArray): Int {
        val length = minOf(a.size, b.size)
        for (i in 0 until length) {
            val left = a[i].toInt() and 0xFF
            val right = b[i].toInt() and 0xFF
            if (left != right) return left - right
        }
        return a.size - b.size
    }
}
