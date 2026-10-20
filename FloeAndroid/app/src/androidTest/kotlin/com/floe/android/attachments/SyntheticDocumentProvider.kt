// SPDX-License-Identifier: MPL-2.0
package com.floe.android.attachments

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File
import java.io.FileNotFoundException

/**
 * RB-7 synthetic document provider for the Android instrumented staging
 * tests. It serves DETERMINISTIC synthetic bytes under three namespaces:
 *
 *   content://<testApplicationId>.staging/doc/<name>     known size + name
 *   content://<testApplicationId>.staging/pipe/<bytes>   unknown size
 *   content://<testApplicationId>.staging/gone/<name>    unavailable URI
 *
 * The authority is DERIVED from the ACTUAL variant test application ID
 * (the merged androidTest manifest resolves `${applicationId}.staging` to
 * exactly this package). The former fixed authority
 * `com.floe.android.test.staging` collided between the full and play test
 * APKs (`INSTALL_FAILED_CONFLICTING_PROVIDER`), which blocked installing
 * both variants' instrumented tests side by side. No uninstall/clearData
 * workaround is needed anymore: each variant owns a unique authority, the
 * merged manifest identity is asserted by the staging test, and both test
 * packages' data stay separate.
 *
 * No real user document, photo or external storage is ever touched. The
 * provider is declared only in the androidTest manifest.
 */
class SyntheticDocumentProvider : ContentProvider() {

    companion object {
        /** Suffix appended to the REAL instrumentation (test APK) package to
         *  form the variant-unique provider authority. */
        const val STAGING_AUTHORITY_SUFFIX = ".staging"

        /** Resolved from the actual instrumentation package at call time —
         *  the same identity the merged manifest placeholder is derived
         *  from, never a hardcoded per-variant literal. */
        val AUTHORITY: String
            get() = androidx.test.platform.app.InstrumentationRegistry
                .getInstrumentation().context.packageName + STAGING_AUTHORITY_SUFFIX
        private const val DOC_SIZE = 150_000
        private var openAttempts = 0

        fun resetCounters() { openAttempts = 0 }
        fun openAttemptCount(): Int = openAttempts

        fun docUri(name: String): Uri =
            Uri.parse("content://$AUTHORITY/doc/$name")
        fun pipeUri(bytes: Int): Uri =
            Uri.parse("content://$AUTHORITY/pipe/$bytes")
        fun goneUri(name: String): Uri =
            Uri.parse("content://$AUTHORITY/gone/$name")

        /** Deterministic byte pattern (never random so digests are stable). */
        fun bytesFor(name: String, count: Int): ByteArray =
            ByteArray(count) { index -> ((name.hashCode() + index) and 0xFF).toByte() }

        /** Pipe payload bytes (distinct pattern; unknown total). */
        fun pipeBytes(count: Int): ByteArray =
            ByteArray(count) { index -> ((index * 31 + 7) and 0xFF).toByte() }
    }

    override fun onCreate(): Boolean = true

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?,
                       selectionArgs: Array<out String>?, sortOrder: String?): Cursor? {
        val columns = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        val cursor = MatrixCursor(columns)
        when (uri.pathSegments.firstOrNull()) {
            "doc" -> {
                val row = arrayOfNulls<Any>(columns.size)
                for ((index, column) in columns.withIndex()) {
                    row[index] = when (column) {
                        OpenableColumns.DISPLAY_NAME -> uri.lastPathSegment ?: "doc.bin"
                        OpenableColumns.SIZE -> DOC_SIZE.toLong()
                        else -> null
                    }
                }
                cursor.addRow(row)
            }
            "pipe" -> {
                // Unknown-size pipe: DISPLAY_NAME only, NO SIZE column value
                // (providers that cannot report a size must not pretend).
                val row = arrayOfNulls<Any>(columns.size)
                for ((index, column) in columns.withIndex()) {
                    row[index] = if (column == OpenableColumns.DISPLAY_NAME) {
                        "pipe.bin"
                    } else null
                }
                cursor.addRow(row)
            }
            "gone" -> Unit  // empty cursor: the URI resolves to nothing
        }
        return cursor
    }

    override fun getType(uri: Uri): String? = when (uri.pathSegments.firstOrNull()) {
        "doc" -> "application/octet-stream"
        "pipe" -> "application/octet-stream"
        else -> null
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        openAttempts += 1
        if (mode != "r") throw java.lang.SecurityException("read-only test provider")
        val segments = uri.pathSegments
        val directory = File(requireNotNull(context).cacheDir,
                             "synthetic-provider-${segments.firstOrNull()}")
        directory.mkdirs()
        val file = File(directory, (uri.lastPathSegment ?: "doc").replace('/', '_'))
        when (segments.firstOrNull()) {
            "doc" -> {
                if (!file.exists()) {
                    file.writeBytes(bytesFor(uri.lastPathSegment ?: "doc", DOC_SIZE))
                }
            }
            "pipe" -> {
                val count = uri.lastPathSegment?.toIntOrNull() ?: 0
                if (!file.exists()) file.writeBytes(pipeBytes(count))
            }
            else -> throw FileNotFoundException("synthetic uri unavailable")
        }
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? =
        throw UnsupportedOperationException("read-only test provider")

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int =
        throw UnsupportedOperationException("read-only test provider")

    override fun update(uri: Uri, values: ContentValues?, selection: String?,
                        selectionArgs: Array<out String>?): Int =
        throw UnsupportedOperationException("read-only test provider")
}
