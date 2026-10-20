// SPDX-License-Identifier: MPL-2.0
package com.floe.android.credentials

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.InvalidPathException
import java.nio.file.LinkOption
import java.nio.file.NoSuchFileException
import java.nio.file.attribute.BasicFileAttributes

/**
 * Strict file metadata for the credential layout.
 *
 * [java.io.File.exists] and its companions collapse "the path is absent" and
 * "the path could not be inspected" into `false`. A credential store must only
 * report absence when the filesystem says the path is actually absent.
 * Permission, namespace-path, symlink and I/O failures fail closed as
 * [CredentialStoreException.StorageFailure].
 *
 * `NOFOLLOW_LINKS` makes a symlink visible as a symlink instead of silently
 * following it to another file.
 */
internal object CredentialFileMetadata {
    fun attributesOrNull(file: File): BasicFileAttributes? {
        return try {
            Files.readAttributes(
                file.toPath(),
                BasicFileAttributes::class.java,
                LinkOption.NOFOLLOW_LINKS,
            )
        } catch (error: NoSuchFileException) {
            null
        } catch (error: IOException) {
            throw CredentialStoreException.StorageFailure(error)
        } catch (error: SecurityException) {
            throw CredentialStoreException.StorageFailure(error)
        } catch (error: UnsupportedOperationException) {
            throw CredentialStoreException.StorageFailure(error)
        } catch (error: InvalidPathException) {
            throw CredentialStoreException.StorageFailure(error)
        }
    }
}
