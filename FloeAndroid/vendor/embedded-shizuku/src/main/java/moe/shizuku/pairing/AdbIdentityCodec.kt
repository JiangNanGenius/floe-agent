// SPDX-License-Identifier: Apache-2.0
// Floe-authored serializer for the ADB TLS identity kept in approved Floe
// credential storage. The private key is only ever written through the host
// CredentialStore, never to logs, preferences or public files.
package moe.shizuku.pairing

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.security.KeyFactory
import java.security.KeyPair
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.spec.PKCS8EncodedKeySpec

object AdbIdentityCodec {

    private const val MAGIC = 0x464C4F45 // "FLOE"
    private const val VERSION = 1
    const val MAX_BYTES = 32 * 1024
    private const val MAX_KEY_BYTES = 8 * 1024
    private const val MAX_CERT_BYTES = 8 * 1024
    const val MAX_NAME_BYTES = 64

    sealed interface Result {
        data class Ok(val identity: AdbIdentity) : Result
        data class Rejected(val code: String) : Result
    }

    fun encode(identity: AdbIdentity): ByteArray {
        val name = identity.displayName.toByteArray(Charsets.UTF_8)
        val key = identity.privateKeyPkcs8
        val certificate = identity.certificateBytes
        require(name.size in 1..MAX_NAME_BYTES) { "identity name out of bounds" }
        require(key.size in 1..MAX_KEY_BYTES) { "identity key out of bounds" }
        require(certificate.size in 1..MAX_CERT_BYTES) { "identity certificate out of bounds" }
        val out = ByteArrayOutputStream()
        try {
            DataOutputStream(out).use { stream ->
                stream.writeInt(MAGIC)
                stream.writeByte(VERSION)
                stream.writeByte(0)
                stream.writeShort(name.size)
                stream.writeInt(key.size)
                stream.writeInt(certificate.size)
                stream.write(name)
                stream.write(key)
                stream.write(certificate)
            }
            return out.toByteArray().also { require(it.size <= MAX_BYTES) { "identity record too large" } }
        } finally {
            key.fill(0)
        }
    }

    fun decode(bytes: ByteArray): Result {
        if (bytes.size !in 1..MAX_BYTES) return Result.Rejected("size")
        return try {
            DataInputStream(ByteArrayInputStream(bytes)).use { stream ->
                if (stream.readInt() != MAGIC) return Result.Rejected("magic")
                if (stream.readUnsignedByte() != VERSION) return Result.Rejected("version")
                if (stream.readUnsignedByte() != 0) return Result.Rejected("flags")
                val nameSize = stream.readUnsignedShort()
                val keySize = stream.readInt()
                val certSize = stream.readInt()
                if (nameSize !in 1..MAX_NAME_BYTES) return Result.Rejected("name")
                if (keySize !in 1..MAX_KEY_BYTES) return Result.Rejected("key")
                if (certSize !in 1..MAX_CERT_BYTES) return Result.Rejected("cert")
                if (nameSize + keySize + certSize != stream.available()) return Result.Rejected("length")
                val nameBytes = ByteArray(nameSize).also { stream.readFully(it) }
                val keyBytes = ByteArray(keySize).also { stream.readFully(it) }
                val certBytes = ByteArray(certSize).also { stream.readFully(it) }
                val name = String(nameBytes, Charsets.UTF_8)
                if (name.any { it == '\u0000' || it.isISOControl() }) return Result.Rejected("name_chars")
                if (stream.available() != 0) return Result.Rejected("trailing")
                val privateKey = try {
                    KeyFactory.getInstance("RSA").generatePrivate(PKCS8EncodedKeySpec(keyBytes))
                } finally {
                    keyBytes.fill(0)
                }
                val certificate = try {
                    CertificateFactory.getInstance("X.509")
                        .generateCertificate(certBytes.inputStream()) as X509Certificate
                } finally {
                    // Certificate is public material but the buffer is still bounded and dropped.
                }
                val publicKey = certificate.publicKey
                Result.Ok(AdbIdentity(KeyPair(publicKey, privateKey), certificate, name))
            }
        } catch (t: Throwable) {
            Result.Rejected("malformed")
        }
    }
}
