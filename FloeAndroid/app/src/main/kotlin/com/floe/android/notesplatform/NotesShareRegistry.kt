// SPDX-License-Identifier: MPL-2.0
package com.floe.android.notesplatform

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File
import java.io.FileNotFoundException
import java.util.concurrent.ConcurrentHashMap

/**
 * Bounded, process-local registry behind the read-only share provider.
 *
 * An entry is minted only by the Notes export/attachment adapter after the
 * bytes were staged and verified into an App-private cache file. The URI only
 * carries an opaque random token; the provider resolves it to that exact file
 * and never accepts a path, display name or document id from the caller.
 *
 * Lifetime: entries are never deleted while they are recent. The registry
 * sweeps entries older than [MAX_AGE_MILLIS] and enforces a total byte cap by
 * evicting the oldest entries beyond [MAX_TOTAL_BYTES], but never an entry
 * younger than [MIN_AGE_MILLIS] (a receiving app may legitimately open the
 * granted stream a little later). An already-open file descriptor stays valid
 * even if the path is later swept on Unix.
 */
internal object NotesShareRegistry {
    const val MAX_AGE_MILLIS = 7L * 24 * 60 * 60 * 1000
    const val MIN_AGE_MILLIS = 60L * 60 * 1000
    const val MAX_TOTAL_BYTES = 512L * 1024 * 1024
    const val MAX_ENTRIES = 64

    class Entry(
        val token: String,
        val file: File,
        val displayName: String,
        val mimeType: String,
        val byteCount: Long,
        val createdAt: Long,
    ) {
        @Volatile
        var openedAt: Long? = null
    }

    private val entries = ConcurrentHashMap<String, Entry>()

    fun register(file: File, displayName: String, mimeType: String, now: Long = System.currentTimeMillis()): Entry {
        if (!NotesPlatformFiles.isPlainFile(file, NotesPlatformFiles.MAX_STAGED_EXPORT_BYTES)) {
            throw NotesPlatformErrors.failed("exportFileMissing")
        }
        sweep(now)
        val token = NotesPlatformNames.newToken()
        val entry = Entry(
            token = token,
            file = file.absoluteFile,
            displayName = NotesPlatformNames.safeFileName(displayName),
            mimeType = NotesPlatformNames.mimeFor(displayName, mimeType),
            byteCount = file.length(),
            createdAt = now,
        )
        entries[token] = entry
        sweep(now)
        return entry
    }

    fun resolve(token: String?): Entry? {
        if (token.isNullOrEmpty() || token.length > 128) return null
        if (token.any { it !in 'a'..'z' && it !in '0'..'9' }) return null
        return entries[token]
    }

    fun release(token: String?) {
        val entry = token?.let { entries.remove(it) } ?: return
        NotesPlatformFiles.deleteQuietly(entry.file.absoluteFile.parentFile)
    }

    fun sweep(now: Long = System.currentTimeMillis()) {
        val snapshot = entries.values.sortedBy { it.createdAt }
        for (entry in snapshot) {
            if (now - entry.createdAt > MAX_AGE_MILLIS) {
                if (entries.remove(entry.token, entry)) {
                    NotesPlatformFiles.deleteQuietly(entry.file.absoluteFile.parentFile)
                }
            }
        }
        var remaining = entries.values.sortedBy { it.createdAt }.toMutableList()
        var total = remaining.sumOf { it.byteCount }
        while (remaining.size > MAX_ENTRIES ||
            (total > MAX_TOTAL_BYTES && remaining.any { now - it.createdAt > MIN_AGE_MILLIS })
        ) {
            val candidate = remaining.firstOrNull { now - it.createdAt > MIN_AGE_MILLIS } ?: break
            remaining.remove(candidate)
            total -= candidate.byteCount
            if (entries.remove(candidate.token, candidate)) {
                NotesPlatformFiles.deleteQuietly(candidate.file.absoluteFile.parentFile)
            }
        }
    }

    fun clearForTests() {
        entries.values.forEach { NotesPlatformFiles.deleteQuietly(it.file.absoluteFile.parentFile) }
        entries.clear()
    }

    fun authorityFor(context: Context): String = context.packageName + ".notes.exports"

    fun uriFor(context: Context, token: String): Uri = Uri.Builder()
        .scheme("content")
        .authority(authorityFor(context))
        .appendPath("share")
        .appendPath(token)
        .build()
}

/**
 * Read-only provider for bounded share streams. Declared in the App manifest
 * by the small Main integration patch (non-exported,
 * grantUriPermissions=true); it grants nothing by itself and accepts only
 * tokens minted in this process.
 */
class NotesShareProvider : ContentProvider() {
    override fun onCreate(): Boolean = true

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? {
        val entry = entryFor(uri) ?: return null
        val columns = arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        return MatrixCursor(columns, 1).apply {
            addRow(arrayOf<Any>(entry.displayName, entry.byteCount))
        }
    }

    override fun getType(uri: Uri): String? = entryFor(uri)?.mimeType

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw FileNotFoundException("readOnly")
        val entry = entryFor(uri) ?: throw FileNotFoundException("unknownShare")
        val file = entry.file
        if (!NotesPlatformFiles.isPlainFile(file, NotesPlatformFiles.MAX_STAGED_EXPORT_BYTES)) {
            throw FileNotFoundException("shareGone")
        }
        entry.openedAt = System.currentTimeMillis()
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0

    private fun entryFor(uri: Uri): NotesShareRegistry.Entry? {
        if (uri.scheme != "content") return null
        if (context == null) return null
        if (uri.authority != NotesShareRegistry.authorityFor(context!!)) return null
        val segments = uri.pathSegments
        if (segments.size != 2 || segments[0] != "share") return null
        return NotesShareRegistry.resolve(segments[1])
    }
}
