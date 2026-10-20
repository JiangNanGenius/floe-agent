// SPDX-License-Identifier: MPL-2.0
package com.floe.android.credentials

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import com.floe.android.contracts.CredentialStore
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.security.GeneralSecurityException
import java.security.InvalidKeyException
import java.security.KeyStore
import java.security.ProviderException
import java.security.UnrecoverableKeyException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.locks.ReentrantLock
import javax.crypto.AEADBadTagException
import javax.crypto.BadPaddingException
import javax.crypto.Cipher
import javax.crypto.IllegalBlockSizeException
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlin.coroutines.suspendCoroutine

/**
 * AndroidKeyStore-backed implementation of [CredentialStore].
 *
 * Keys are non-exportable AES-256-GCM keys held by AndroidKeyStore, one per
 * namespace/reference pair. Only the bounded ciphertext envelope is written to
 * application-private `noBackupFilesDir`; there is no plaintext file, database,
 * preference or in-memory fallback.
 *
 * The store is process-local for coordination purposes: instances in this
 * process share a per-record lock and a single I/O executor. Concurrent
 * instances therefore serialize reads, writes and deletes for the same record.
 * Multiple Android processes are outside this component's contract.
 *
 * Suspending calls dispatch blocking file and keystore work off the caller's
 * thread. They intentionally complete even if the caller stops waiting, so a
 * committed record cannot be abandoned halfway through a rename. Writes freeze
 * a defensive copy synchronously before the first suspension; the caller's
 * array is never captured, modified or wiped.
 *
 * Record presence is decided with strict `NOFOLLOW_LINKS` metadata. Only a
 * genuine `NoSuchFileException` maps to `null`; permission, namespace-path,
 * non-regular-file, symlink, malformed and I/O failures are typed errors.
 */
class AndroidKeystoreCredentialStore internal constructor(
    context: Context,
    namespace: String,
    private val dispatch: Executor,
) : CredentialStore {
    /** Validated namespace included in key AAD and record derivation. */
    val namespace: String = CredentialReferenceCodec.requireNamespace(namespace)

    constructor(context: Context, namespace: String) : this(
        context,
        namespace,
        CredentialIoExecutor.shared,
    )

    private val appContext: Context = context.applicationContext ?: context

    override suspend fun read(reference: String): ByteArray? {
        val validated = CredentialReferenceCodec.requireReference(reference)
        return dispatchIo { readBlocking(validated) }
    }

    override suspend fun write(reference: String, value: ByteArray) {
        val validated = CredentialReferenceCodec.requireReference(reference)
        if (value.size > CredentialLimits.MAX_SECRET_BYTES) {
            throw CredentialStoreException.InvalidValue()
        }
        // Freeze the caller-owned buffer before the first suspension. Once
        // this coroutine dispatches, the caller is free to mutate or reuse its
        // array; encryption must use the bytes that were passed at call time.
        val frozen = value.copyOf()
        try {
            dispatchIo { writeBlocking(validated, frozen) }
        } finally {
            frozen.fill(0)
        }
    }

    override suspend fun delete(reference: String) {
        val validated = CredentialReferenceCodec.requireReference(reference)
        dispatchIo { deleteBlocking(validated) }
    }

    private fun readBlocking(reference: String): ByteArray? {
        val target = CredentialStoreLayout.recordFile(appContext, namespace, reference)
        val lock = lockFor(target)
        lock.lock()
        try {
            val directory = target.parentFile ?: throw CredentialStoreException.StorageFailure()
            val directoryAttributes = CredentialFileMetadata.attributesOrNull(directory)
                ?: return null
            if (directoryAttributes.isSymbolicLink || !directoryAttributes.isDirectory) {
                throw CredentialStoreException.StorageFailure()
            }
            val attributes = CredentialFileMetadata.attributesOrNull(target) ?: return null
            if (attributes.isSymbolicLink) throw CredentialStoreException.CorruptRecord()
            if (!attributes.isRegularFile) {
                throw CredentialStoreException.StorageFailure()
            }
            val size = attributes.size()
            if (size < EnvelopeCodec.MIN_ENVELOPE_BYTES.toLong() ||
                size > EnvelopeCodec.MAX_ENVELOPE_BYTES.toLong()
            ) {
                throw CredentialStoreException.CorruptRecord()
            }
            val parsed = EnvelopeCodec.parse(readEnvelopeBytes(target, size.toInt()))
            val key = loadKeyForRead(CredentialStoreLayout.keyAlias(namespace, reference))
            val aad = CredentialAad.encode(namespace, reference)
            return decrypt(key, parsed, aad)
        } finally {
            lock.unlock()
        }
    }

    private fun readEnvelopeBytes(file: File, expectedSize: Int): ByteArray {
        val bytes = ByteArray(expectedSize)
        try {
            FileInputStream(file).use { input ->
                var offset = 0
                while (offset < bytes.size) {
                    val count = input.read(bytes, offset, bytes.size - offset)
                    if (count < 0) throw CredentialStoreException.CorruptRecord()
                    offset += count
                }
                // A record that grew after the metadata probe is malformed;
                // never silently accept only the prefix we expected.
                if (input.read() != -1) throw CredentialStoreException.CorruptRecord()
            }
        } catch (error: IOException) {
            throw CredentialStoreException.StorageFailure(error)
        } catch (error: SecurityException) {
            throw CredentialStoreException.StorageFailure(error)
        }
        return bytes
    }

    private fun writeBlocking(reference: String, value: ByteArray) {
        if (value.size > CredentialLimits.MAX_SECRET_BYTES) {
            throw CredentialStoreException.InvalidValue()
        }
        val target = CredentialStoreLayout.recordFile(appContext, namespace, reference)
        val directory = target.parentFile ?: throw CredentialStoreException.StorageFailure()
        AtomicRecordFile.ensureDirectory(directory)
        val lock = lockFor(target)
        lock.lock()
        try {
            val aad = CredentialAad.encode(namespace, reference)
            val encrypted = encryptForReference(
                CredentialStoreLayout.keyAlias(namespace, reference),
                aad,
                value,
            )
            AtomicRecordFile.replace(target) { output ->
                EnvelopeCodec.writeTo(output, encrypted.iv, encrypted.ciphertext)
            }
        } finally {
            lock.unlock()
        }
    }

    private fun deleteBlocking(reference: String) {
        val target = CredentialStoreLayout.recordFile(appContext, namespace, reference)
        val lock = lockFor(target)
        lock.lock()
        try {
            try {
                val directory = target.parentFile
                    ?: throw CredentialStoreException.StorageFailure()
                val directoryAttributes = CredentialFileMetadata.attributesOrNull(directory)
                if (directoryAttributes != null) {
                    if (directoryAttributes.isSymbolicLink || !directoryAttributes.isDirectory) {
                        throw CredentialStoreException.StorageFailure()
                    }
                    val attributes = CredentialFileMetadata.attributesOrNull(target)
                    if (attributes != null) {
                        if (attributes.isSymbolicLink || !attributes.isRegularFile) {
                            throw CredentialStoreException.StorageFailure()
                        }
                        val deleted = try {
                            target.delete()
                        } catch (error: SecurityException) {
                            throw CredentialStoreException.StorageFailure(error)
                        }
                        if (!deleted) {
                            val remaining = CredentialFileMetadata.attributesOrNull(target)
                            if (remaining != null) {
                                throw CredentialStoreException.StorageFailure()
                            }
                        }
                    }
                }
            } catch (error: CredentialStoreException) {
                throw CredentialStoreException.DeleteFailed(error)
            } catch (error: SecurityException) {
                throw CredentialStoreException.DeleteFailed(error)
            }
            try {
                deleteKeyEntry(openKeyStore(), CredentialStoreLayout.keyAlias(namespace, reference))
            } catch (error: CredentialStoreException) {
                throw CredentialStoreException.DeleteFailed(error)
            }
        } finally {
            lock.unlock()
        }
    }

    private fun loadKeyForRead(alias: String): SecretKey {
        val keyStore = openKeyStore()
        val key = try {
            keyStore.getKey(alias, null)
        } catch (error: UnrecoverableKeyException) {
            throw CredentialStoreException.KeyUnavailable(error)
        } catch (error: GeneralSecurityException) {
            throw CredentialStoreException.KeyStoreFailure(error)
        } catch (error: ProviderException) {
            throw CredentialStoreException.KeyStoreFailure(error)
        } catch (error: SecurityException) {
            throw CredentialStoreException.KeyStoreFailure(error)
        }
        return key as? SecretKey ?: throw CredentialStoreException.KeyUnavailable()
    }

    private fun secretKeyForWrite(alias: String): SecretKey {
        val keyStore = openKeyStore()
        val existing = try {
            keyStore.getKey(alias, null)
        } catch (error: UnrecoverableKeyException) {
            null
        } catch (error: GeneralSecurityException) {
            throw CredentialStoreException.KeyStoreFailure(error)
        } catch (error: ProviderException) {
            throw CredentialStoreException.KeyStoreFailure(error)
        } catch (error: SecurityException) {
            throw CredentialStoreException.KeyStoreFailure(error)
        }
        if (existing is SecretKey) return existing
        if (existing != null || containsAlias(keyStore, alias)) {
            deleteKeyEntry(keyStore, alias)
        }
        return generateKey(alias)
    }

    private fun encryptForReference(alias: String, aad: ByteArray, plaintext: ByteArray): EncryptedRecord {
        val key = secretKeyForWrite(alias)
        return try {
            encryptWith(key, aad, plaintext)
        } catch (error: KeyPermanentlyInvalidatedException) {
            // Explicit per-reference replacement: the old key cannot decrypt
            // anything any more, so rotate only this alias after the caller
            // asked for a new value. Other references and their keys are
            // untouched, and no global reset occurs.
            deleteKeyEntry(openKeyStore(), alias)
            val replacement = generateKey(alias)
            try {
                encryptWith(replacement, aad, plaintext)
            } catch (second: KeyPermanentlyInvalidatedException) {
                throw CredentialStoreException.KeyUnavailable(second)
            }
        }
    }

    private fun encryptWith(key: SecretKey, aad: ByteArray, plaintext: ByteArray): EncryptedRecord {
        val cipher = try {
            Cipher.getInstance(AES_TRANSFORMATION)
        } catch (error: GeneralSecurityException) {
            throw CredentialStoreException.KeyStoreFailure(error)
        }
        try {
            cipher.init(Cipher.ENCRYPT_MODE, key)
            cipher.updateAAD(aad)
            val ciphertext = cipher.doFinal(plaintext)
            val iv = cipher.iv ?: throw CredentialStoreException.KeyStoreFailure()
            if (iv.size != EnvelopeCodec.IV_BYTES) throw CredentialStoreException.KeyStoreFailure()
            return EncryptedRecord(iv, ciphertext)
        } catch (error: KeyPermanentlyInvalidatedException) {
            throw error
        } catch (error: InvalidKeyException) {
            throw CredentialStoreException.KeyUnavailable(error)
        } catch (error: GeneralSecurityException) {
            throw CredentialStoreException.KeyStoreFailure(error)
        } catch (error: ProviderException) {
            throw CredentialStoreException.KeyStoreFailure(error)
        } catch (error: SecurityException) {
            throw CredentialStoreException.KeyStoreFailure(error)
        }
    }

    private fun decrypt(key: SecretKey, parsed: ParsedEnvelope, aad: ByteArray): ByteArray {
        val cipher = try {
            Cipher.getInstance(AES_TRANSFORMATION)
        } catch (error: GeneralSecurityException) {
            throw CredentialStoreException.KeyStoreFailure(error)
        }
        try {
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, parsed.iv))
            cipher.updateAAD(aad)
            return cipher.doFinal(parsed.ciphertext)
        } catch (error: KeyPermanentlyInvalidatedException) {
            throw CredentialStoreException.KeyUnavailable(error)
        } catch (error: AEADBadTagException) {
            throw CredentialStoreException.AuthenticationFailed(error)
        } catch (error: BadPaddingException) {
            throw CredentialStoreException.AuthenticationFailed(error)
        } catch (error: IllegalBlockSizeException) {
            throw CredentialStoreException.CorruptRecord(error)
        } catch (error: InvalidKeyException) {
            throw CredentialStoreException.KeyUnavailable(error)
        } catch (error: GeneralSecurityException) {
            throw CredentialStoreException.KeyStoreFailure(error)
        } catch (error: ProviderException) {
            throw CredentialStoreException.KeyStoreFailure(error)
        } catch (error: SecurityException) {
            throw CredentialStoreException.KeyStoreFailure(error)
        }
    }

    private fun openKeyStore(): KeyStore {
        return try {
            KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        } catch (error: GeneralSecurityException) {
            throw CredentialStoreException.KeyStoreFailure(error)
        } catch (error: IOException) {
            throw CredentialStoreException.KeyStoreFailure(error)
        } catch (error: ProviderException) {
            throw CredentialStoreException.KeyStoreFailure(error)
        } catch (error: SecurityException) {
            throw CredentialStoreException.KeyStoreFailure(error)
        }
    }

    private fun containsAlias(keyStore: KeyStore, alias: String): Boolean {
        return try {
            keyStore.containsAlias(alias)
        } catch (error: GeneralSecurityException) {
            throw CredentialStoreException.KeyStoreFailure(error)
        } catch (error: ProviderException) {
            throw CredentialStoreException.KeyStoreFailure(error)
        } catch (error: SecurityException) {
            throw CredentialStoreException.KeyStoreFailure(error)
        }
    }

    private fun deleteKeyEntry(keyStore: KeyStore, alias: String) {
        if (!containsAlias(keyStore, alias)) return
        try {
            keyStore.deleteEntry(alias)
        } catch (error: GeneralSecurityException) {
            throw CredentialStoreException.KeyStoreFailure(error)
        } catch (error: ProviderException) {
            throw CredentialStoreException.KeyStoreFailure(error)
        } catch (error: SecurityException) {
            throw CredentialStoreException.KeyStoreFailure(error)
        }
    }

    private fun generateKey(alias: String): SecretKey {
        return try {
            val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
            generator.init(
                KeyGenParameterSpec.Builder(
                    alias,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(AES_KEY_BITS)
                    .setRandomizedEncryptionRequired(true)
                    .build(),
            )
            generator.generateKey()
        } catch (error: GeneralSecurityException) {
            throw CredentialStoreException.KeyStoreFailure(error)
        } catch (error: ProviderException) {
            throw CredentialStoreException.KeyStoreFailure(error)
        } catch (error: SecurityException) {
            throw CredentialStoreException.KeyStoreFailure(error)
        }
    }

    private fun lockFor(target: File): ReentrantLock =
        LOCKS.computeIfAbsent(target.absolutePath) { ReentrantLock() }

    private suspend fun <T> dispatchIo(block: () -> T): T = suspendCoroutine { continuation ->
        try {
            dispatch.execute {
                continuation.resumeWith(runCatching(block))
            }
        } catch (error: RejectedExecutionException) {
            continuation.resumeWith(Result.failure(CredentialStoreException.StorageFailure(error)))
        }
    }

    companion object {
        /** Convenience factory; the returned type is the stable contract. */
        fun create(context: Context, namespace: String): CredentialStore =
            AndroidKeystoreCredentialStore(context, namespace)

        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val AES_TRANSFORMATION = "AES/GCM/NoPadding"
        private const val AES_KEY_BITS = 256
        private const val GCM_TAG_BITS = 128

        private val LOCKS = ConcurrentHashMap<String, ReentrantLock>()
    }
}

private data class EncryptedRecord(val iv: ByteArray, val ciphertext: ByteArray)

private object CredentialIoExecutor {
    val shared: Executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "floe-credentials-io").apply { isDaemon = true }
    }
}
