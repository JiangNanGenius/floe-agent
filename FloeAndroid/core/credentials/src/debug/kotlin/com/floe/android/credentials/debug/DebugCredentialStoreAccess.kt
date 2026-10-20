// SPDX-License-Identifier: MPL-2.0
package com.floe.android.credentials.debug

import android.content.Context
import com.floe.android.credentials.AndroidKeystoreCredentialStore
import com.floe.android.credentials.CredentialReferenceCodec
import com.floe.android.credentials.CredentialStoreLayout
import java.io.File
import java.security.GeneralSecurityException
import java.security.KeyStore
import java.util.concurrent.Executor

/**
 * Debug-only QA access to opaque record paths and key aliases.
 *
 * This object never returns plaintext or key material; it exists so
 * instrumentation tests can simulate tampering, cross-reference swaps and key
 * loss without duplicating the production layout. It is compiled only into the
 * debug variant (`src/debug`), never into release.
 */
object DebugCredentialStoreAccess {
    fun moduleRoot(context: Context): File = CredentialStoreLayout.root(context)

    /**
     * Test-only store that uses an explicitly controlled I/O executor. The
     * production constructor still uses the single shared executor. Tests use
     * this to hold a write at the dispatch boundary while mutating the caller's
     * input array; real AndroidKeyStore encryption still runs.
     */
    fun storeWithControlledIo(
        context: Context,
        namespace: String,
        dispatch: Executor,
    ): AndroidKeystoreCredentialStore =
        AndroidKeystoreCredentialStore(
            context.applicationContext ?: context,
            namespace,
            dispatch,
        )

    fun storageDirectory(context: Context, namespace: String): File {
        CredentialReferenceCodec.requireNamespace(namespace)
        return CredentialStoreLayout.namespaceDirectory(context, namespace)
    }

    fun recordFile(context: Context, namespace: String, reference: String): File {
        CredentialReferenceCodec.requireReference(reference)
        return CredentialStoreLayout.recordFile(context, namespace, reference)
    }

    fun recordFiles(context: Context, namespace: String): List<File> {
        val directory = storageDirectory(context, namespace)
        if (!directory.isDirectory) return emptyList()
        return directory.listFiles()
            ?.filter { it.isFile && it.name.endsWith(CredentialStoreLayout.RECORD_SUFFIX) }
            ?.sortedBy { it.name }
            ?: emptyList()
    }

    fun keyAlias(namespace: String, reference: String): String =
        CredentialStoreLayout.keyAlias(namespace, reference)

    fun hasKey(namespace: String, reference: String): Boolean =
        aliasExists(CredentialStoreLayout.keyAlias(namespace, reference))

    fun deleteKey(namespace: String, reference: String) {
        deleteAlias(CredentialStoreLayout.keyAlias(namespace, reference))
    }

    fun deleteAlias(alias: String) {
        val keyStore = openKeyStore()
        try {
            if (keyStore.containsAlias(alias)) keyStore.deleteEntry(alias)
        } catch (error: GeneralSecurityException) {
            throw IllegalStateException("debug key deletion failed", error)
        }
    }

    fun aliasExists(alias: String): Boolean {
        val keyStore = openKeyStore()
        return try {
            keyStore.containsAlias(alias)
        } catch (error: GeneralSecurityException) {
            throw IllegalStateException("debug key lookup failed", error)
        }
    }

    /** Test-only tamper writer; production always writes through the atomic path. */
    fun overwriteRecord(context: Context, namespace: String, reference: String, bytes: ByteArray) {
        recordFile(context, namespace, reference).writeBytes(bytes)
    }

    fun readRecordBytes(context: Context, namespace: String, reference: String): ByteArray =
        recordFile(context, namespace, reference).readBytes()

    /**
     * Removes every record file in one QA namespace and the corresponding
     * per-record keys. Unknown file names are removed without touching keys.
     */
    fun deleteNamespace(context: Context, namespace: String) {
        val directory = storageDirectory(context, namespace)
        val files = directory.listFiles() ?: return
        files.filter { it.isFile }.forEach { file ->
            val name = file.name
            if (name.endsWith(CredentialStoreLayout.RECORD_SUFFIX)) {
                val recordId = name.removeSuffix(CredentialStoreLayout.RECORD_SUFFIX)
                if (recordId.length == 64 && recordId.all { it in '0'..'9' || it in 'a'..'f' }) {
                    runCatching { deleteAlias(CredentialReferenceCodec.keyAliasForRecordId(recordId)) }
                }
            }
            file.delete()
        }
        directory.delete()
    }

    private fun openKeyStore(): KeyStore =
        KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

    private const val ANDROID_KEYSTORE = "AndroidKeyStore"
}
