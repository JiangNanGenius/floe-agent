// SPDX-License-Identifier: MPL-2.0
package com.floe.android.credentials

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.OutputStream
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/**
 * Same-directory temporary file, fsync, then atomic rename over the committed
 * record. A failed write leaves the previous record in place; a successful
 * rename exposes either the old or the new complete envelope, never a partial
 * one. Android has no portable Java API for fsync of the parent directory, so
 * this is atomic visibility plus file-data durability, not a power-loss
 * journal.
 *
 * Every path check uses [CredentialFileMetadata] with `NOFOLLOW_LINKS`, so an
 * inaccessible path is a typed failure rather than a silent "absent" result.
 */
internal object AtomicRecordFile {
    fun replace(target: File, writer: (OutputStream) -> Unit) {
        val directory = target.parentFile ?: throw CredentialStoreException.StorageFailure()
        ensureDirectory(directory)
        val existing = CredentialFileMetadata.attributesOrNull(target)
        if (existing != null && (existing.isSymbolicLink || !existing.isRegularFile)) {
            throw CredentialStoreException.StorageFailure()
        }

        // Same-record writes are serialized by the caller's per-record lock,
        // so any older temp for this target is stale. Ciphertext-only temp
        // files from a process crash are removed here; other records use a
        // different prefix and are never touched.
        val prefix = "floe-record-${target.name}-"
        val staleFiles = try {
            directory.listFiles { file ->
                file.isFile && file.name.startsWith(prefix) && file.name.endsWith(".tmp")
            }
        } catch (error: SecurityException) {
            throw CredentialStoreException.StorageFailure(error)
        }
        staleFiles?.forEach { stale -> runCatching { stale.delete() } }

        val temporary = try {
            File.createTempFile(prefix, ".tmp", directory)
        } catch (error: IOException) {
            throw CredentialStoreException.StorageFailure(error)
        } catch (error: SecurityException) {
            throw CredentialStoreException.StorageFailure(error)
        } catch (error: IllegalArgumentException) {
            throw CredentialStoreException.StorageFailure(error)
        }

        try {
            FileOutputStream(temporary).use { output ->
                writer(output)
                output.flush()
                output.fd.sync()
            }
            try {
                Files.move(
                    temporary.toPath(),
                    target.toPath(),
                    StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING,
                )
            } catch (error: AtomicMoveNotSupportedException) {
                throw CredentialStoreException.StorageFailure(error)
            }
        } catch (error: CredentialStoreException) {
            throw error
        } catch (error: IOException) {
            throw CredentialStoreException.StorageFailure(error)
        } catch (error: SecurityException) {
            throw CredentialStoreException.StorageFailure(error)
        } catch (error: UnsupportedOperationException) {
            throw CredentialStoreException.StorageFailure(error)
        } finally {
            // After a successful rename the path no longer exists; this is a
            // no-op. On any failure it removes the uncommitted temporary file.
            // Cleanup must never mask the primary typed failure.
            runCatching { temporary.delete() }
        }
    }

    fun ensureDirectory(directory: File) {
        val existing = CredentialFileMetadata.attributesOrNull(directory)
        if (existing != null) {
            if (existing.isSymbolicLink || !existing.isDirectory) {
                throw CredentialStoreException.StorageFailure()
            }
            return
        }
        val created = try {
            directory.mkdirs()
        } catch (error: SecurityException) {
            throw CredentialStoreException.StorageFailure(error)
        }
        if (created) return
        val after = CredentialFileMetadata.attributesOrNull(directory)
        if (after == null || after.isSymbolicLink || !after.isDirectory) {
            throw CredentialStoreException.StorageFailure()
        }
    }
}
