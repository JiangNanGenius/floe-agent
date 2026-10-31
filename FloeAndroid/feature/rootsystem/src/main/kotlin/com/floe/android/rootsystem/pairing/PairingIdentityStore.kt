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
 *
 * A generated identity is a pairing candidate until [markPaired] records that
 * the peer handshake completed. Only a paired record may be treated as trust:
 * otherwise a failed or cancelled pairing would leave a key that the device
 * never authorized looking "paired" and make the controller attempt that
 * key on the connect port.
 */
internal class PairingIdentityStore(private val credentials: CredentialStore) {

    suspend fun load(requirePaired: Boolean = false): AdbIdentity? {
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
            is AdbIdentityCodec.Result.Ok ->
                if (requirePaired && !result.paired) null else result.identity
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
        write(identity, paired = false, errorCode = "identity_write")
        return identity
    }

    /**
     * Records a completed pairing for exactly this identity. Rewriting the
     * same envelope reuses the existing per-reference key and atomically
     * replaces the record; the key pair itself never changes.
     */
    suspend fun markPaired(identity: AdbIdentity) {
        write(identity, paired = true, errorCode = "identity_pair_write")
    }

    private suspend fun write(identity: AdbIdentity, paired: Boolean, errorCode: String) {
        val encoded = try {
            AdbIdentityCodec.encode(identity, paired = paired)
        } catch (e: Throwable) {
            throw IdentityException(errorCode, e)
        }
        try {
            credentials.write(REFERENCE, encoded)
        } catch (e: Throwable) {
            throw IdentityException(errorCode, e)
        } finally {
            encoded.fill(0)
        }
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
