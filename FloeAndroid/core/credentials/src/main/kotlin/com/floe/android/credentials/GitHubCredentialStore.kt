// SPDX-License-Identifier: MPL-2.0
package com.floe.android.credentials

import android.content.Context
import com.floe.android.contracts.CredentialStore
import java.security.MessageDigest

/** Device-local Git credential facade over the ONE approved platform store.
 * No SQLite/preferences, backup, repository URL or published model carries a token.
 * The reference follows Swift SecretGatewayNaming and the original Git account;
 * a future Git transport can consume [readToken] without another credential store.
 */
class GitHubCredentialStore(private val store: CredentialStore) {
    suspend fun hasToken(): Boolean {
        val token = readToken() ?: return false
        token.fill(0)
        return true
    }

    /** Caller owns the returned bytes and must erase them after use. */
    suspend fun readToken(): ByteArray? {
        val token = store.read(REFERENCE) ?: return null
        if (!validToken(token)) {
            token.fill(0)
            throw CredentialStoreException.CorruptRecord()
        }
        return token
    }

    /** The platform adapter freezes its own copy before suspending. */
    suspend fun save(token: ByteArray) {
        if (token.size !in 20..512) throw CredentialStoreException.InvalidValue()
        val frozen = token.copyOf()
        try {
            if (!validToken(frozen)) throw CredentialStoreException.InvalidValue()
            store.write(REFERENCE, frozen)
        } finally {
            frozen.fill(0)
        }
    }

    suspend fun delete() = store.delete(REFERENCE)

    companion object {
        const val SERVICE = "org.floeagent.ios.github"
        const val ACCOUNT = "github.primary"
        // Same physical store used by SecretGatewayDispatcher. These are public
        // identity constants, not credentials; only the opaque digest is stored.
        const val STORE_NAMESPACE = "keychainAccount"
        val REFERENCE: String = "ref:v1:" + MessageDigest.getInstance("SHA-256")
            .digest("floe-android-secret:v1\u001f$SERVICE\u001f$ACCOUNT".toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }

        fun validToken(token: ByteArray): Boolean =
            token.size in 20..512 && token.all { it.toInt() in 33..126 }

        fun create(context: Context): GitHubCredentialStore = GitHubCredentialStore(
            AndroidKeystoreCredentialStore.create(context, STORE_NAMESPACE),
        )
    }
}
