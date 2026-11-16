// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** Per-host, opaque cursor scope. The token never carries app names or grants. */
internal class DeviceLaunchScopeTokens(secret: ByteArray? = null) {
    private val key = (secret ?: ByteArray(32).also { SecureRandom().nextBytes(it) }).copyOf()

    data class Scope(
        val owner: String,
        val epoch: Long,
        val backend: String,
        val session: String,
        val controlRevision: Long,
        val targetRevision: Long,
        val packages: Set<String>,
    )

    fun token(scope: Scope): String {
        val bytes = ByteArrayOutputStream().also { buffer ->
            DataOutputStream(buffer).use { out ->
                out.writeUTF(scope.owner)
                out.writeLong(scope.epoch)
                out.writeUTF(scope.backend)
                out.writeUTF(scope.session)
                out.writeLong(scope.controlRevision)
                out.writeLong(scope.targetRevision)
                out.writeInt(scope.packages.size)
                scope.packages.sorted().forEach(out::writeUTF)
            }
        }.toByteArray()
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(bytes).take(16).joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    fun matches(scope: Scope, supplied: String): Boolean =
        supplied.matches(Regex("[0-9a-f]{32}")) &&
            MessageDigest.isEqual(token(scope).toByteArray(Charsets.US_ASCII), supplied.toByteArray(Charsets.US_ASCII))
}
