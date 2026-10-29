// SPDX-License-Identifier: MPL-2.0
package com.floe.android.notesplatform

import com.floe.android.feature.notes.ui.presentation.NotesPendingRecovery
import com.floe.android.feature.notes.ui.presentation.NotesRecoveryStore
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Typed failure raised when a recovery record could not be committed. */
class NotesRecoveryStorageException(
    val reason: String,
    cause: Throwable? = null,
) : IOException("notesRecoveryStore: $reason", cause)

/** One file that exists on disk but could not be decoded (never deleted). */
data class NotesRecoveryUnreadable(
    /** Opaque file name only, never the document id or note text. */
    val fileName: String,
    val reason: String,
    val version: Int? = null,
)

/**
 * App-private, durable, atomic [NotesRecoveryStore].
 *
 * Guarantees:
 *  - one record file per document, named from a SHA-256 over the document id
 *    (a document id is never used as a path segment);
 *  - `put` serialises the closed edit vocabulary, writes a fresh part file,
 *    fsyncs it, atomically renames it over the previous record and fsyncs the
 *    directory. It returns only after those steps succeed, so a root-stop
 *    report that says "kept" is backed by durable bytes;
 *  - unexpected/corrupt/unknown-version files are left byte-for-byte in place
 *    and reported through [unreadable]; `pending()` never silently substitutes
 *    an empty record;
 *  - initial loading happens in [open] (call off the UI thread). After that,
 *    `pending()` is an in-memory snapshot and never scans the disk;
 *  - no plaintext content is ever logged by this class. The record file itself
 *    contains the user's own unsaved edits because recovery requires them.
 *
 * Threading: all methods are safe from any thread. `put`/`remove` perform the
 * bounded durable commit synchronously; the Notes UI only invokes them at
 * explicit recovery/stop boundaries, not per keystroke. Callers that must not
 * block a UI thread can wrap them in `withContext(Dispatchers.IO)`; the
 * factory and root-stop path do exactly that where possible.
 */
class DurableNotesRecoveryStore private constructor(
    private val root: File,
    initial: Map<String, NotesPendingRecovery>,
    unreadable: List<NotesRecoveryUnreadable>,
) : NotesRecoveryStore, AutoCloseable {

    private val lock = Any()
    private val records = HashMap<String, NotesPendingRecovery>(initial)
    private val unreadableFiles = unreadable.toMutableList()

    @Volatile
    private var closed = false

    override fun put(recovery: NotesPendingRecovery) {
        require(recovery.documentID.isNotBlank()) { "documentID" }
        val bytes = try {
            NotesRecoveryCodec.encode(recovery)
        } catch (error: IllegalArgumentException) {
            throw NotesRecoveryStorageException("recordTooLarge", error)
        }
        synchronized(lock) {
            if (closed) throw NotesRecoveryStorageException("closed")
            val file = fileFor(recovery.documentID)
            try {
                NotesPlatformFiles.writeAtomicDurable(file, bytes)
            } catch (error: Throwable) {
                throw NotesRecoveryStorageException("commitFailed", error)
            }
            records[recovery.documentID] = recovery
        }
    }

    override fun remove(documentID: String) {
        if (documentID.isBlank()) return
        synchronized(lock) {
            if (closed) return
            records.remove(documentID)
            val file = fileFor(documentID)
            try {
                Files.deleteIfExists(file.toPath())
                NotesPlatformFiles.fsyncDirectory(root)
            } catch (_: IOException) {
                // The in-memory record is gone; a stale file is re-validated on
                // the next load and can never be treated as saved content.
            }
        }
    }

    override fun pending(): List<NotesPendingRecovery> = synchronized(lock) {
        records.values.sortedBy { it.createdAt }
    }

    override fun clear() {
        synchronized(lock) {
            if (closed) return
            records.clear()
            val children = root.listFiles() ?: return
            for (child in children) {
                if (!child.isFile) continue
                runCatching { Files.deleteIfExists(child.toPath()) }
            }
            NotesPlatformFiles.fsyncDirectory(root)
        }
    }

    /** Files kept on disk because they could not be decoded. */
    fun unreadable(): List<NotesRecoveryUnreadable> = synchronized(lock) { unreadableFiles.toList() }

    /** Directory used by this store (diagnostics; never rendered as a path in notes content). */
    fun directory(): File = root

    override fun close() {
        synchronized(lock) { closed = true }
    }

    /** Stable on-disk name; the document id itself never becomes a path. */
    private fun fileFor(documentID: String): File {
        val digest = MessageDigest.getInstance("SHA-256").digest(documentID.encodeToByteArray())
        return File(root, NotesPlatformFiles.hex(digest) + ".recovery")
    }

    companion object {
        const val FILE_SUFFIX = ".recovery"
        private const val MAX_RECORD_FILE_BYTES = NotesRecoveryCodec.MAX_RECORD_BYTES

        /**
         * Loads the App-private recovery directory off the caller's thread.
         * Corrupt/unknown files are preserved and reported, not overwritten.
         */
        suspend fun open(
            root: File,
            ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
        ): DurableNotesRecoveryStore = withContext(ioDispatcher) {
            NotesPlatformFiles.ensureDirectory(root)
            val records = LinkedHashMap<String, NotesPendingRecovery>()
            val unreadable = ArrayList<NotesRecoveryUnreadable>()
            val children = root.listFiles().orEmpty().sortedBy { it.name }
            val now = System.currentTimeMillis()
            for (file in children) {
                if (!file.isFile) continue
                if (Files.isSymbolicLink(file.toPath())) {
                    unreadable += NotesRecoveryUnreadable(file.name, "symlink")
                    continue
                }
                if (file.name.contains(".tmp-") || file.name.contains(".part-")) {
                    val modified = runCatching {
                        Files.getLastModifiedTime(file.toPath(), LinkOption.NOFOLLOW_LINKS).toMillis()
                    }.getOrDefault(now)
                    // A temp file older than an hour is an abandoned commit.
                    if (now - modified > 60 * 60 * 1000L) {
                        runCatching { Files.deleteIfExists(file.toPath()) }
                    }
                    continue
                }
                if (!file.name.endsWith(FILE_SUFFIX)) continue
                if (file.length() <= 0L || file.length() > MAX_RECORD_FILE_BYTES) {
                    unreadable += NotesRecoveryUnreadable(file.name, "sizeOutOfRange")
                    continue
                }
                val bytes = try {
                    file.readBounded(MAX_RECORD_FILE_BYTES)
                } catch (_: IOException) {
                    unreadable += NotesRecoveryUnreadable(file.name, "unreadableFile")
                    continue
                }
                when (val result = NotesRecoveryCodec.decode(bytes)) {
                    is NotesRecoveryDecodeResult.Ok -> {
                        if (records.containsKey(result.record.documentID)) {
                            unreadable += NotesRecoveryUnreadable(file.name, "duplicateDocument")
                        } else {
                            records[result.record.documentID] = result.record
                        }
                    }
                    is NotesRecoveryDecodeResult.Corrupt ->
                        unreadable += NotesRecoveryUnreadable(file.name, result.reason)
                    is NotesRecoveryDecodeResult.UnknownVersion ->
                        unreadable += NotesRecoveryUnreadable(file.name, "unknownVersion", result.version)
                }
            }
            // Orphaned part files are only removed when they are clearly stale;
            // recent ones are preserved for a same-process retry/debug.
            DurableNotesRecoveryStore(root, records, unreadable)
        }
    }
}

/**
 * Convenience wrapper that serialises one pending record to bytes and back.
 * Kept for callers that need to inspect the exact durable payload (tests and
 * diagnostics); production code uses the store directly.
 */
internal object NotesRecoveryPayload {
    fun encode(record: NotesPendingRecovery): ByteArray = NotesRecoveryCodec.encode(record)

    fun decode(bytes: ByteArray): NotesPendingRecovery? =
        (NotesRecoveryCodec.decode(bytes) as? NotesRecoveryDecodeResult.Ok)?.record
}

/** Copies a recovery record into an immutable value (defensive snapshot). */
internal fun NotesPendingRecovery.copyBytes(): NotesPendingRecovery = copy(
    edits = edits.toList(),
    inkDrafts = inkDrafts.mapValues { (_, bytes) -> bytes.copyOf() },
)
