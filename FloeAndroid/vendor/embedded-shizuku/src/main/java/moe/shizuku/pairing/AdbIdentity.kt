// SPDX-License-Identifier: Apache-2.0
// Floe-authored identity object adapted from RikkaApps/Shizuku AdbKey.kt at
// b844bc491f1790c72328e1a8e5b2349f8978f0ea. Modification record: key material is
// supplied by the host (Floe approved credential storage) instead of being
// generated in this class; no logging, no plaintext persistence.
package moe.shizuku.pairing

import java.net.Socket
import java.security.KeyPair
import java.security.Principal
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.security.interfaces.RSAPublicKey
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLEngine
import javax.net.ssl.X509ExtendedKeyManager
import javax.net.ssl.X509ExtendedTrustManager

/**
 * The Floe ADB TLS identity: one RSA key pair and its self-signed certificate.
 * Instances hold private material in memory only. Callers must not log them.
 */
class AdbIdentity(
    private val keyPair: KeyPair,
    private val certificate: X509Certificate,
    val displayName: String,
) {
    init {
        require(keyPair.private.algorithm == "RSA") { "ADB identity requires RSA" }
        require(keyPair.public is RSAPublicKey) { "ADB identity requires an RSA public key" }
        require(displayName.isNotEmpty() && displayName.length <= 64) { "invalid display name" }
        require(certificate.publicKey.encoded.contentEquals(keyPair.public.encoded)) {
            "ADB identity certificate does not match the private key"
        }
    }

    val adbPublicKey: ByteArray by lazy {
        AdbPublicKey.encode(keyPair.public as RSAPublicKey, displayName)
    }

    val certificateBytes: ByteArray
        get() = certificate.encoded

    val privateKeyPkcs8: ByteArray
        get() = keyPair.private.encoded

    /**
     * ADB AUTH token signature. `SHA1withRSA` produces the PKCS#1 v1.5
     * SHA-1 DigestInfo block adbd verifies, without the hand-built padding
     * table used by the upstream manager.
     */
    fun signAdbToken(token: ByteArray): ByteArray {
        require(token.isNotEmpty() && token.size <= 256) { "invalid adb auth token" }
        val signer = java.security.Signature.getInstance("SHA1withRSA")
        signer.initSign(keyPair.private)
        signer.update(token)
        return signer.sign()
    }

    fun sslContext(): SSLContext {
        val context = SSLContext.getInstance("TLSv1.3")
        context.init(arrayOf(KeyManager()), arrayOf(TrustManager()), SecureRandom())
        return context
    }

    private inner class KeyManager : X509ExtendedKeyManager() {
        private val alias = "floe-adb-identity"

        override fun chooseClientAlias(
            keyTypes: Array<out String>?,
            issuers: Array<out Principal>?,
            socket: Socket?,
        ): String? = if (keyTypes?.contains("RSA") == true) alias else null

        override fun getCertificateChain(alias: String?): Array<X509Certificate>? =
            if (alias == this.alias) arrayOf(certificate) else null

        override fun getPrivateKey(alias: String?): PrivateKey? =
            if (alias == this.alias) keyPair.private else null

        override fun getClientAliases(keyType: String?, issuers: Array<out Principal>?): Array<String>? = null

        override fun getServerAliases(keyType: String?, issuers: Array<out Principal>?): Array<String>? = null

        override fun chooseServerAlias(
            keyType: String?,
            issuers: Array<out Principal>?,
            socket: Socket?,
        ): String? = null
    }

    /** ADB pairing/connect uses its own device certificate chain; the host side is not CA-trusted. */
    private class TrustManager : X509ExtendedTrustManager() {
        override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) = Unit
        override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?, socket: Socket?) = Unit
        override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?, engine: SSLEngine?) = Unit
        override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) = Unit
        override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?, socket: Socket?) = Unit
        override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?, engine: SSLEngine?) = Unit
        override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
    }
}
