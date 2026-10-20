// SPDX-License-Identifier: MPL-2.0
package com.floe.android.credentials.debug

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import com.floe.android.credentials.AndroidKeystoreCredentialStore
import com.floe.android.credentials.CredentialReferenceCodec
import com.floe.android.credentials.CredentialStoreException
import java.io.IOException
import java.security.GeneralSecurityException
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.ProviderException
import java.security.SecureRandom
import java.security.UnrecoverableKeyException
import java.security.spec.MGF1ParameterSpec
import java.security.spec.X509EncodedKeySpec
import java.util.concurrent.ConcurrentHashMap
import javax.crypto.AEADBadTagException
import javax.crypto.BadPaddingException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PSource
import javax.crypto.spec.SecretKeySpec
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Debug-only sealed QA enrollment.
 *
 * The device creates a one-shot RSA-3072 AndroidKeyStore key and exposes only
 * its public key plus public session metadata. A host (or instrumentation test)
 * seals a bounded credential payload with hybrid AES-256-GCM + RSA-OAEP and
 * hands the ciphertext back in-process. Import verifies the session, package,
 * reference and expiry, decrypts directly into the CredentialStore, durably
 * marks the session consumed before the credential mutation, wipes the
 * plaintext buffer and removes the session key/state so replay fails.
 *
 * No socket, exported component, clipboard, argv, log or plaintext file is
 * used. This object exists only in debug builds and is not a release backdoor.
 * It reads no existing user credentials: the only value written is the payload
 * supplied to [seal] for a session created by [begin].
 */
object DebugSealedEnrollment {
    private val OAEP_PARAMETERS = OAEPParameterSpec(
        "SHA-256",
        "MGF1",
        MGF1ParameterSpec.SHA1,
        PSource.PSpecified.DEFAULT,
    )
    private val random = SecureRandom()
    private val sessionMutexes = ConcurrentHashMap<String, Mutex>()

    /**
     * Creates one session and returns public metadata. The private key never
     * leaves AndroidKeyStore. The caller distributes only this descriptor to
     * the host sealer.
     */
    fun begin(
        context: Context,
        namespace: String,
        reference: String,
        ttlMillis: Long = SealedEnrollmentProtocol.DEFAULT_SESSION_TTL_MILLIS,
    ): EnrollmentDescriptor {
        val appContext = context.applicationContext ?: context
        val validatedNamespace = try {
            CredentialReferenceCodec.requireNamespace(namespace)
        } catch (error: CredentialStoreException) {
            throw DebugEnrollmentException.InvalidSession(error)
        }
        val validatedReference = try {
            CredentialReferenceCodec.requireReference(reference)
        } catch (error: CredentialStoreException) {
            throw DebugEnrollmentException.InvalidSession(error)
        }
        if (ttlMillis < 1L || ttlMillis > SealedEnrollmentProtocol.MAX_SESSION_TTL_MILLIS) {
            throw DebugEnrollmentException.InvalidTtl()
        }

        val sessionID = ByteArray(SealedEnrollmentProtocol.SESSION_ID_BYTES)
            .also { random.nextBytes(it) }
            .toHex()
        val alias = SealedEnrollmentProtocol.aliasFor(sessionID)
        var stateWritten = false
        try {
            generateSessionKey(alias)
            val publicKeyDer = loadPublicKeyDer(alias)
            val createdAt = System.currentTimeMillis()
            val state = SessionState(
                protocolVersion = SealedEnrollmentProtocol.VERSION,
                sessionID = sessionID,
                packageName = appContext.packageName,
                namespace = validatedNamespace,
                reference = validatedReference,
                createdAtEpochMillis = createdAt,
                expiresAtEpochMillis = createdAt + ttlMillis,
            )
            SessionStateStore.write(appContext, state)
            stateWritten = true
            return EnrollmentDescriptor(
                protocolVersion = SealedEnrollmentProtocol.VERSION,
                sessionID = sessionID,
                packageName = state.packageName,
                namespace = state.namespace,
                reference = state.reference,
                expiresAtEpochMillis = state.expiresAtEpochMillis,
                publicKeyDer = publicKeyDer,
            )
        } catch (error: Exception) {
            if (stateWritten) runCatching { SessionStateStore.delete(appContext, sessionID) }
            deleteKeyBestEffort(alias)
            if (error is DebugEnrollmentException) throw error
            throw DebugEnrollmentException.SessionCreationFailed(error)
        }
    }

    /**
     * Host-side reference sealer. This is a pure function of the descriptor and
     * payload; it only needs the public key. It is included so instrumentation
     * tests exercise the real wire format, and the future host script can port
     * the same steps.
     */
    fun seal(descriptor: EnrollmentDescriptor, payload: ByteArray): ByteArray {
        validateDescriptor(descriptor)
        if (payload.size > SealedEnrollmentProtocol.MAX_PAYLOAD_BYTES) {
            throw DebugEnrollmentException.InvalidPayload()
        }
        val publicKey = try {
            KeyFactory.getInstance("RSA").generatePublic(X509EncodedKeySpec(descriptor.publicKeyDer))
        } catch (error: GeneralSecurityException) {
            throw DebugEnrollmentException.SealFailed(error)
        } catch (error: IllegalArgumentException) {
            throw DebugEnrollmentException.SealFailed(error)
        }
        val aesGenerator = try {
            KeyGenerator.getInstance("AES")
        } catch (error: GeneralSecurityException) {
            throw DebugEnrollmentException.SealFailed(error)
        }
        val aesKey = try {
            aesGenerator.init(SealedEnrollmentProtocol.AES_KEY_BYTES * 8)
            aesGenerator.generateKey()
        } catch (error: GeneralSecurityException) {
            throw DebugEnrollmentException.SealFailed(error)
        } catch (error: IllegalArgumentException) {
            throw DebugEnrollmentException.SealFailed(error)
        }
        val aesKeyBytes = aesKey.encoded ?: throw DebugEnrollmentException.SealFailed()
        if (aesKeyBytes.size != SealedEnrollmentProtocol.AES_KEY_BYTES) {
            aesKeyBytes.fill(0)
            throw DebugEnrollmentException.SealFailed()
        }
        try {
            try {
                val aes = Cipher.getInstance(SealedEnrollmentProtocol.AES_TRANSFORMATION)
                aes.init(Cipher.ENCRYPT_MODE, aesKey)
                aes.updateAAD(EnrollmentAad.encode(descriptor))
                val ciphertext = aes.doFinal(payload)
                val iv = aes.iv ?: throw DebugEnrollmentException.SealFailed()
                if (iv.size != SealedEnrollmentProtocol.AES_GCM_IV_BYTES) {
                    throw DebugEnrollmentException.SealFailed()
                }
                val rsa = Cipher.getInstance(SealedEnrollmentProtocol.RSA_TRANSFORMATION)
                rsa.init(Cipher.ENCRYPT_MODE, publicKey, OAEP_PARAMETERS)
                val wrappedKey = rsa.doFinal(aesKeyBytes)
                if (wrappedKey.size != SealedEnrollmentProtocol.RSA_WRAPPED_KEY_BYTES) {
                    throw DebugEnrollmentException.SealFailed()
                }
                return SealedEnvelopeCodec.encode(
                    sessionIdBytes(descriptor.sessionID),
                    iv,
                    wrappedKey,
                    ciphertext,
                )
            } catch (error: GeneralSecurityException) {
                throw DebugEnrollmentException.SealFailed(error)
            } catch (error: ProviderException) {
                throw DebugEnrollmentException.SealFailed(error)
            } catch (error: IllegalArgumentException) {
                throw DebugEnrollmentException.SealFailed(error)
            }
        } finally {
            aesKeyBytes.fill(0)
        }
    }

    /**
     * Decrypts one sealed envelope and writes exactly the session's reference.
     *
     * Authentication and payload validation run before any durable mutation,
     * so a tampered or malformed envelope can be retried. Once the envelope is
     * authentic, a durable `.consumed` marker is written before the credential
     * store is touched. From that point the session is spent even if the
     * credential write or cleanup fails or the process dies; callers must
     * reissue a new session for an uncertain or failed write. A successful
     * import then deletes the session state and private key.
     *
     * Imports for the same session are serialized by a coroutine [Mutex], not a
     * thread-bound lock; a continuation may resume on the store's I/O thread.
     */
    suspend fun importSealed(context: Context, sealed: ByteArray): EnrollmentImportResult {
        val appContext = context.applicationContext ?: context
        val envelope = SealedEnvelopeCodec.parse(sealed)
        val sessionID = envelope.sessionID
        return mutexFor(sessionID).withLock {
            val state = SessionStateStore.read(appContext, sessionID)
                ?: throw DebugEnrollmentException.SessionUnknown()
            if (state.packageName != appContext.packageName) {
                throw DebugEnrollmentException.SessionPackageMismatch()
            }
            if (System.currentTimeMillis() >= state.expiresAtEpochMillis) {
                throw DebugEnrollmentException.SessionExpired()
            }
            if (SessionStateStore.isConsumed(appContext, sessionID)) {
                throw DebugEnrollmentException.SessionConsumed()
            }
            val privateKey = loadPrivateKey(sessionID)
            var aesKeyBytes: ByteArray? = null
            var plaintext: ByteArray? = null
            try {
                val rsa = Cipher.getInstance(SealedEnrollmentProtocol.RSA_TRANSFORMATION)
                rsa.init(Cipher.DECRYPT_MODE, privateKey, OAEP_PARAMETERS)
                val unwrapped = rsa.doFinal(envelope.wrappedKey)
                aesKeyBytes = unwrapped
                if (unwrapped.size != SealedEnrollmentProtocol.AES_KEY_BYTES) {
                    throw DebugEnrollmentException.SealedEnvelopeRejected()
                }
                val aes = Cipher.getInstance(SealedEnrollmentProtocol.AES_TRANSFORMATION)
                aes.init(
                    Cipher.DECRYPT_MODE,
                    SecretKeySpec(unwrapped, "AES"),
                    GCMParameterSpec(SealedEnrollmentProtocol.GCM_TAG_BITS, envelope.iv),
                )
                aes.updateAAD(EnrollmentAad.encode(state))
                val decrypted = aes.doFinal(envelope.ciphertext)
                plaintext = decrypted
                if (decrypted.size > SealedEnrollmentProtocol.MAX_PAYLOAD_BYTES) {
                    throw DebugEnrollmentException.InvalidPayload()
                }
                // Durable one-shot consumption MUST precede the credential
                // mutation. A replay after this point is rejected even if the
                // write below throws or cleanup cannot finish.
                SessionStateStore.consume(appContext, sessionID)
                AndroidKeystoreCredentialStore(appContext, state.namespace)
                    .write(state.reference, decrypted)
                if (DebugSealedEnrollmentTestHooks.shouldFailSessionCleanup()) {
                    throw DebugEnrollmentException.SessionCleanupFailed()
                }
                SessionStateStore.delete(appContext, sessionID)
                deleteSessionKey(sessionID)
                SessionStateStore.deleteConsumedMarker(appContext, sessionID)
                EnrollmentImportResult(sessionID, state.reference, decrypted.size)
            } catch (error: AEADBadTagException) {
                throw DebugEnrollmentException.SealedEnvelopeRejected(error)
            } catch (error: BadPaddingException) {
                throw DebugEnrollmentException.SealedEnvelopeRejected(error)
            } catch (error: GeneralSecurityException) {
                throw DebugEnrollmentException.SealedEnvelopeRejected(error)
            } catch (error: ProviderException) {
                throw DebugEnrollmentException.SealedEnvelopeRejected(error)
            } catch (error: IllegalArgumentException) {
                throw DebugEnrollmentException.SealedEnvelopeRejected(error)
            } finally {
                plaintext?.fill(0)
                aesKeyBytes?.fill(0)
            }
        }
    }

    /** Cancels an unused or expired session; idempotent for absent records. */
    fun cancel(context: Context, sessionID: String) {
        if (!SealedEnrollmentProtocol.isSessionId(sessionID)) {
            throw DebugEnrollmentException.InvalidSession()
        }
        val appContext = context.applicationContext ?: context
        val mutex = mutexFor(sessionID)
        if (!mutex.tryLock()) throw DebugEnrollmentException.SessionBusy()
        try {
            deleteSessionKey(sessionID)
            SessionStateStore.delete(appContext, sessionID)
            SessionStateStore.deleteConsumedMarker(appContext, sessionID)
        } finally {
            mutex.unlock()
        }
    }

    fun sessionKeyExists(sessionID: String): Boolean {
        if (!SealedEnrollmentProtocol.isSessionId(sessionID)) {
            throw DebugEnrollmentException.InvalidSession()
        }
        val keyStore = try {
            KeyStore.getInstance(SealedEnrollmentProtocol.ANDROID_KEYSTORE).apply { load(null) }
        } catch (error: GeneralSecurityException) {
            throw IllegalStateException("debug session key lookup failed", error)
        } catch (error: IOException) {
            throw IllegalStateException("debug session key lookup failed", error)
        } catch (error: ProviderException) {
            throw IllegalStateException("debug session key lookup failed", error)
        } catch (error: SecurityException) {
            throw IllegalStateException("debug session key lookup failed", error)
        }
        return try {
            keyStore.containsAlias(SealedEnrollmentProtocol.aliasFor(sessionID))
        } catch (error: GeneralSecurityException) {
            throw IllegalStateException("debug session key lookup failed", error)
        } catch (error: ProviderException) {
            throw IllegalStateException("debug session key lookup failed", error)
        } catch (error: SecurityException) {
            throw IllegalStateException("debug session key lookup failed", error)
        }
    }

    fun sessionStateExists(context: Context, sessionID: String): Boolean =
        SessionStateStore.exists(context.applicationContext ?: context, sessionID)

    private fun validateDescriptor(descriptor: EnrollmentDescriptor) {
        if (descriptor.protocolVersion != SealedEnrollmentProtocol.VERSION ||
            !SealedEnrollmentProtocol.isSessionId(descriptor.sessionID) ||
            descriptor.packageName.isBlank() ||
            descriptor.packageName.length > 256 ||
            descriptor.publicKeyDer.isEmpty() ||
            descriptor.publicKeyDer.size > 4096 ||
            descriptor.expiresAtEpochMillis <= 0
        ) {
            throw DebugEnrollmentException.InvalidSession()
        }
        try {
            CredentialReferenceCodec.requireNamespace(descriptor.namespace)
            CredentialReferenceCodec.requireReference(descriptor.reference)
        } catch (error: CredentialStoreException) {
            throw DebugEnrollmentException.InvalidSession(error)
        }
    }

    private fun sessionIdBytes(sessionID: String): ByteArray {
        if (!SealedEnrollmentProtocol.isSessionId(sessionID)) {
            throw DebugEnrollmentException.InvalidSession()
        }
        val bytes = ByteArray(SealedEnrollmentProtocol.SESSION_ID_BYTES)
        for (index in bytes.indices) {
            bytes[index] = ((hexNibble(sessionID[index * 2]) shl 4) or
                hexNibble(sessionID[index * 2 + 1])).toByte()
        }
        return bytes
    }

    private fun hexNibble(char: Char): Int = when (char) {
        in '0'..'9' -> char - '0'
        else -> char - 'a' + 10
    }

    private fun generateSessionKey(alias: String) {
        try {
            // RSA keys are key pairs, not secret keys: AndroidKeyStore exposes
            // them only through KeyPairGenerator. KeyGenerator serves AES above.
            val generator = KeyPairGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_RSA,
                SealedEnrollmentProtocol.ANDROID_KEYSTORE,
            )
            // API 28-37 AndroidKeyStore OAEP supports MGF1-SHA-1 (the default
            // MGF1 digest). The envelope sealer uses the same explicit spec.
            generator.initialize(
                KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_DECRYPT)
                    .setKeySize(SealedEnrollmentProtocol.RSA_KEY_BITS)
                    .setDigests(KeyProperties.DIGEST_SHA256)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_RSA_OAEP)
                    .build(),
            )
            generator.generateKeyPair()
        } catch (error: GeneralSecurityException) {
            throw DebugEnrollmentException.SessionCreationFailed(error)
        } catch (error: ProviderException) {
            throw DebugEnrollmentException.SessionCreationFailed(error)
        } catch (error: SecurityException) {
            throw DebugEnrollmentException.SessionCreationFailed(error)
        }
    }

    private fun loadPublicKeyDer(alias: String): ByteArray {
        val keyStore = try {
            KeyStore.getInstance(SealedEnrollmentProtocol.ANDROID_KEYSTORE).apply { load(null) }
        } catch (error: GeneralSecurityException) {
            throw DebugEnrollmentException.SessionCreationFailed(error)
        } catch (error: IOException) {
            throw DebugEnrollmentException.SessionCreationFailed(error)
        } catch (error: ProviderException) {
            throw DebugEnrollmentException.SessionCreationFailed(error)
        } catch (error: SecurityException) {
            throw DebugEnrollmentException.SessionCreationFailed(error)
        }
        val certificate = try {
            keyStore.getCertificate(alias)
        } catch (error: GeneralSecurityException) {
            throw DebugEnrollmentException.SessionCreationFailed(error)
        } catch (error: ProviderException) {
            throw DebugEnrollmentException.SessionCreationFailed(error)
        } catch (error: SecurityException) {
            throw DebugEnrollmentException.SessionCreationFailed(error)
        } ?: throw DebugEnrollmentException.SessionCreationFailed()
        return certificate.publicKey?.encoded
            ?: throw DebugEnrollmentException.SessionCreationFailed()
    }

    private fun loadPrivateKey(sessionID: String): PrivateKey {
        val keyStore = try {
            KeyStore.getInstance(SealedEnrollmentProtocol.ANDROID_KEYSTORE).apply { load(null) }
        } catch (error: GeneralSecurityException) {
            throw DebugEnrollmentException.SessionKeyUnavailable(error)
        } catch (error: IOException) {
            throw DebugEnrollmentException.SessionKeyUnavailable(error)
        } catch (error: ProviderException) {
            throw DebugEnrollmentException.SessionKeyUnavailable(error)
        } catch (error: SecurityException) {
            throw DebugEnrollmentException.SessionKeyUnavailable(error)
        }
        val key = try {
            keyStore.getKey(SealedEnrollmentProtocol.aliasFor(sessionID), null)
        } catch (error: UnrecoverableKeyException) {
            throw DebugEnrollmentException.SessionKeyUnavailable(error)
        } catch (error: GeneralSecurityException) {
            throw DebugEnrollmentException.SessionKeyUnavailable(error)
        } catch (error: ProviderException) {
            throw DebugEnrollmentException.SessionKeyUnavailable(error)
        } catch (error: SecurityException) {
            throw DebugEnrollmentException.SessionKeyUnavailable(error)
        }
        return key as? PrivateKey ?: throw DebugEnrollmentException.SessionKeyUnavailable()
    }

    private fun deleteSessionKey(sessionID: String) {
        if (!SealedEnrollmentProtocol.isSessionId(sessionID)) {
            throw DebugEnrollmentException.InvalidSession()
        }
        try {
            val keyStore = KeyStore.getInstance(SealedEnrollmentProtocol.ANDROID_KEYSTORE)
                .apply { load(null) }
            val alias = SealedEnrollmentProtocol.aliasFor(sessionID)
            if (keyStore.containsAlias(alias)) keyStore.deleteEntry(alias)
        } catch (error: GeneralSecurityException) {
            throw DebugEnrollmentException.SessionCleanupFailed(error)
        } catch (error: IOException) {
            throw DebugEnrollmentException.SessionCleanupFailed(error)
        } catch (error: ProviderException) {
            throw DebugEnrollmentException.SessionCleanupFailed(error)
        } catch (error: SecurityException) {
            throw DebugEnrollmentException.SessionCleanupFailed(error)
        }
    }

    private fun deleteKeyBestEffort(alias: String) {
        runCatching {
            val keyStore = KeyStore.getInstance(SealedEnrollmentProtocol.ANDROID_KEYSTORE)
                .apply { load(null) }
            if (keyStore.containsAlias(alias)) keyStore.deleteEntry(alias)
        }
    }

    private fun mutexFor(sessionID: String): Mutex =
        sessionMutexes.computeIfAbsent(sessionID) { Mutex() }
}
