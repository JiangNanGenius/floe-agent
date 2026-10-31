// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.pairing

import com.floe.android.contracts.CredentialStore
import moe.shizuku.pairing.AdbIdentity
import moe.shizuku.pairing.AdbIdentityCodec
import moe.shizuku.pairing.SelfSignedCertificate
import java.security.KeyPairGenerator

internal class IdentityException(val code: String, cause: Throwable? = null) : Exception(code, cause)

/**
 * Stores the ADB TLS identity only through the host's approved CredentialStore
 * (implemented by core/credentials in the App). The stored bytes are the
 * versioned private-key/certificate envelope; there is no plaintext preference,
 * file or in-memory fallback and nothing is logged.
 */
internal class PairingIdentityStore(private val credentials: CredentialStore) {

    suspend fun load(): AdbIdentity? {
        val bytes = try {
            credentials.read(REFERENCE)
        } catch (e: Throwable) {
            throw IdentityException("identity_read", e)
        } ?: return null
        val result = try {
            AdbIdentityCodec.decode(bytes)
        } finally {
            bytes.fill(0)
        }
        return when (result) {
            is AdbIdentityCodec.Result.Ok -> result.identity
            is AdbIdentityCodec.Result.Rejected -> throw IdentityException("identity_${result.code}")
        }
    }

    suspend fun loadOrCreate(displayName: String): AdbIdentity {
        load()?.let { return it }
        val identity = try {
            val generator = KeyPairGenerator.getInstance("RSA")
            generator.initialize(2048)
            val pair = generator.generateKeyPair()
            val certificate = SelfSignedCertificate.create(pair)
            AdbIdentity(pair, certificate, sanitizeName(displayName))
        } catch (e: Throwable) {
            throw IdentityException("identity_generate", e)
        }
        val encoded = AdbIdentityCodec.encode(identity)
        try {
            credentials.write(REFERENCE, encoded)
        } catch (e: Throwable) {
            throw IdentityException("identity_write", e)
        } finally {
            encoded.fill(0)
        }
        return identity
    }

    suspend fun forget() {
        try {
            credentials.delete(REFERENCE)
        } catch (e: Throwable) {
            throw IdentityException("identity_delete", e)
        }
    }

    private fun sanitizeName(value: String): String {
        val cleaned = value.filter { it.isLetterOrDigit() || it == '-' || it == '_' || it == '.' }
            .take(48)
        return if (cleaned.isEmpty()) "floe-agent" else cleaned
    }

    companion object {
        const val REFERENCE = "floe-system-adb-identity-v1"
    }
}
