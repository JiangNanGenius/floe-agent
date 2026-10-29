// SPDX-License-Identifier: MPL-2.0
package com.floe.android.notesplatform

import com.floe.android.feature.notes.NotesException
import com.floe.android.feature.notes.ui.api.NotesPortFailure
import com.floe.android.feature.notes.ui.api.NotesPortFailureException
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.io.RandomAccessFile
import java.nio.channels.FileChannel
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.coroutines.CoroutineDispatcher

/**
 * Path-free, framework-free helpers shared by the Notes platform adapters.
 *
 * Everything here is plain JVM code so the same rules can be exercised by a
 * JVM unit test without loading Android framework classes. The rules are
 * deliberately conservative: a display name is never a path, a resource id is
 * never a path, a cache file is never shared after its bounded lease, and an
 * acknowledged durable write is fsynced + atomically renamed before the call
 * returns.
 */
internal object NotesPlatformNames {
    const val MAX_FILE_NAME_CHARS = 200
    private const val FALLBACK_NAME = "note"
    private val SEPARATORS = charArrayOf('/', '\\', '\u0000')

    /** One safe display segment. Never empty, never contains a separator. */
    fun safeFileName(raw: String?, fallback: String = FALLBACK_NAME, extension: String? = null): String {
        // A provider display name may include path-looking segments; only the
        // last segment is a name, and any residual separator becomes '_'.
        val lastSegment = (raw ?: "")
            .substringAfterLast('/')
            .substringAfterLast('\\')
        val cleaned = lastSegment
            .trim()
            .replace('\n', ' ')
            .replace('\r', ' ')
            .map { if (it in SEPARATORS) '_' else it }
            .joinToString("")
            .trimStart('.')
            .trim()
            .ifBlank { fallback }
        val dot = cleaned.lastIndexOf('.')
        val base = if (dot > 0) cleaned.substring(0, dot) else cleaned
        val ext = extension?.let { normalizeExtension(it) }
            ?: if (dot > 0) normalizeExtension(cleaned.substring(dot + 1)) else null
        val suffix = if (ext.isNullOrEmpty()) "" else ".$ext"
        val budget = (MAX_FILE_NAME_CHARS - suffix.length).coerceAtLeast(1)
        val safeBase = base.take(budget).trim().ifBlank { fallback.take(budget) }
        return safeBase + suffix
    }

    fun normalizeExtension(extension: String?): String? =
        extension?.trim()?.trimStart('.')?.lowercase(Locale.ROOT)
            ?.takeIf { it.isNotEmpty() && it.length <= 16 && it.all { c -> c in 'a'..'z' || c in '0'..'9' } }

    fun extensionOf(name: String?): String? =
        name?.substringAfterLast('.', "")?.lowercase(Locale.ROOT)?.takeIf { it.isNotEmpty() }

    /** Concrete MIME for a file name; never a wildcard. */
    fun mimeFor(fileName: String?, declared: String? = null): String {
        val concrete = declared?.trim()?.lowercase(Locale.ROOT)
        if (!concrete.isNullOrEmpty() && concrete != "application/octet-stream" &&
            '*' !in concrete && concrete.contains('/')
        ) {
            return concrete
        }
        return when (extensionOf(fileName)) {
            "pdf" -> "application/pdf"
            "docx" -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            "xlsx" -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            "pptx" -> "application/vnd.openxmlformats-officedocument.presentationml.presentation"
            "odt" -> "application/vnd.oasis.opendocument.text"
            "ods" -> "application/vnd.oasis.opendocument.spreadsheet"
            "odp" -> "application/vnd.oasis.opendocument.presentation"
            "png" -> "image/png"
            "jpg", "jpeg" -> "image/jpeg"
            "webp" -> "image/webp"
            "gif" -> "image/gif"
            "txt" -> "text/plain"
            "md", "markdown" -> "text/markdown"
            "zip" -> "application/zip"
            "floenote" -> "application/vnd.floe.notes.archive"
            "ink" -> "application/vnd.floe.notes.ink"
            else -> "application/octet-stream"
        }
    }

    val OFFICE_EDIT_EXTENSIONS: Set<String> = setOf("docx", "xlsx", "pptx")

    fun isOfficeEditable(name: String?): Boolean = extensionOf(name) in OFFICE_EDIT_EXTENSIONS

    fun mimeForOfficeExtension(extension: String): String = when (normalizeExtension(extension)) {
        "docx" -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        "xlsx" -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        "pptx" -> "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        else -> "application/octet-stream"
    }

    /** Best-effort extension for a provider MIME; null when it is not concrete. */
    fun extensionForMime(mediaType: String?): String? {
        val type = mediaType?.lowercase(Locale.ROOT)?.substringBefore(';')?.trim() ?: return null
        return when (type) {
            "application/pdf" -> "pdf"
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document" -> "docx"
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" -> "xlsx"
            "application/vnd.openxmlformats-officedocument.presentationml.presentation" -> "pptx"
            "application/vnd.oasis.opendocument.text" -> "odt"
            "application/vnd.oasis.opendocument.spreadsheet" -> "ods"
            "application/vnd.oasis.opendocument.presentation" -> "odp"
            "application/msword" -> "doc"
            "application/vnd.ms-excel" -> "xls"
            "application/vnd.ms-powerpoint" -> "ppt"
            "image/png" -> "png"
            "image/jpeg" -> "jpg"
            "image/webp" -> "webp"
            "image/gif" -> "gif"
            "text/plain" -> "txt"
            "text/markdown" -> "md"
            "application/zip" -> "zip"
            else -> null
        }
    }

    /** Opaque URI/cache token grammar (never a path). */
    fun newToken(): String = UUID.randomUUID().toString().replace("-", "")
}

internal object NotesPlatformFiles {
    const val CHUNK_BYTES = 64 * 1024
    /** Notes resource hard cap (matches the foundation protocol). */
    const val MAX_STAGED_PICK_BYTES: Long = 512L * 1024 * 1024
    /** Export/authored stream cap; larger exports are refused typed. */
    const val MAX_STAGED_EXPORT_BYTES: Long = 512L * 1024 * 1024
    /** Bounded image source cap for probe/cover/overlay decoding. */
    const val MAX_STAGED_IMAGE_BYTES: Long = 256L * 1024 * 1024
    /** Existing Office working-copy cap. */
    const val MAX_OFFICE_BYTES: Long = 256L * 1024 * 1024
    /** One recovery/share token's bounded retention. */
    const val CACHE_MAX_AGE_MILLIS: Long = 7L * 24 * 60 * 60 * 1000

    fun ensureDirectory(directory: File): File {
        if (!directory.isDirectory && !directory.mkdirs() && !directory.isDirectory) {
            throw IOException("directoryUnavailable")
        }
        if (Files.isSymbolicLink(directory.toPath())) throw IOException("symlinkedDirectory")
        return directory
    }

    fun newWorkDirectory(root: File, prefix: String): File {
        ensureDirectory(root)
        val directory = File(root, "$prefix-${NotesPlatformNames.newToken()}")
        Files.createDirectory(directory.toPath())
        return directory
    }

    fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().buffered(CHUNK_BYTES).use { input ->
            val buffer = ByteArray(CHUNK_BYTES)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        return hex(digest.digest())
    }

    fun hex(bytes: ByteArray): String {
        val out = StringBuilder(bytes.size * 2)
        for (b in bytes) {
            val v = b.toInt() and 0xff
            out.append(HEX[v ushr 4]).append(HEX[v and 0x0f])
        }
        return out.toString()
    }

    /** Regular, non-symlink, non-empty and within [maxBytes]. */
    fun isPlainFile(file: File, maxBytes: Long): Boolean {
        if (!file.isAbsolute) return false
        val path = file.toPath()
        if (Files.isSymbolicLink(path)) return false
        if (!Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS)) return false
        val size = runCatching { Files.size(path) }.getOrDefault(-1L)
        return size in 1..maxBytes
    }

    /**
     * Bounded, cancellable copy into [destination] with a streaming SHA-256.
     * The destination is created fresh (CREATE_NEW), fully written, fsynced
     * and only then renamed from its part file. The caller owns containment.
     */
    suspend fun copyToNewFile(
        destination: File,
        maxBytes: Long,
        isCancelled: () -> Boolean = { false },
        open: suspend () -> InputStream,
    ): StagedByteFile = withContext(kotlinx.coroutines.Dispatchers.IO) {
        require(maxBytes > 0L) { "maxBytes" }
        val job = currentCoroutineContext()[kotlinx.coroutines.Job]
        fun fence() {
            job?.ensureActive()
            if (isCancelled()) throw CancellationException("notesCopyCancelled")
        }
        val parent = destination.absoluteFile.parentFile ?: throw IOException("noParent")
        ensureDirectory(parent)
        val part = File(parent, destination.name + ".part-" + NotesPlatformNames.newToken())
        val digest = MessageDigest.getInstance("SHA-256")
        var total = 0L
        try {
            val input = open()
            try {
                val output = FileOutputStream(part)
                try {
                    val buffer = ByteArray(CHUNK_BYTES)
                    while (true) {
                        fence()
                        val read = input.read(buffer)
                        if (read < 0) break
                        total += read
                        if (total > maxBytes) throw IOException("contentTooLarge")
                        digest.update(buffer, 0, read)
                        output.write(buffer, 0, read)
                    }
                    output.flush()
                    runCatching { output.fd.sync() }
                } finally {
                    runCatching { input.close() }
                    runCatching { output.close() }
                }
            } finally {
                runCatching { input.close() }
            }
            if (total <= 0L) throw IOException("emptyContent")
            Files.move(
                part.toPath(),
                destination.toPath(),
                StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING,
            )
            fsyncDirectory(parent)
            StagedByteFile(destination.absoluteFile, total, hex(digest.digest()))
        } catch (error: Throwable) {
            runCatching { Files.deleteIfExists(part.toPath()) }
            throw error
        }
    }

    suspend fun copyFromReader(
        destination: File,
        maxBytes: Long,
        read: suspend (offset: Long, maxBytes: Int) -> ByteArray,
    ): StagedByteFile = withContext(kotlinx.coroutines.Dispatchers.IO) {
        require(maxBytes > 0L) { "maxBytes" }
        val job = currentCoroutineContext()[kotlinx.coroutines.Job]
        val parent = destination.absoluteFile.parentFile ?: throw IOException("noParent")
        ensureDirectory(parent)
        val part = File(parent, destination.name + ".part-" + NotesPlatformNames.newToken())
        val digest = MessageDigest.getInstance("SHA-256")
        var offset = 0L
        try {
            val output = FileOutputStream(part)
            try {
                var guard = 0
                while (true) {
                    job?.ensureActive()
                    if (guard++ > MAX_READ_ITERATIONS) throw IOException("readDidNotTerminate")
                    val remaining = maxBytes - offset
                    if (remaining <= 0L) throw IOException("contentTooLarge")
                    val request = minOf(CHUNK_BYTES.toLong(), remaining + 1).toInt()
                    val chunk = read(offset, request)
                    if (chunk.isEmpty()) break
                    if (chunk.size > request) throw IOException("chunkTooLarge")
                    offset += chunk.size
                    if (offset > maxBytes) throw IOException("contentTooLarge")
                    digest.update(chunk)
                    output.write(chunk)
                }
                output.flush()
                runCatching { output.fd.sync() }
            } finally {
                runCatching { output.close() }
            }
            if (offset <= 0L) throw IOException("emptyContent")
            Files.move(
                part.toPath(),
                destination.toPath(),
                StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING,
            )
            fsyncDirectory(parent)
            StagedByteFile(destination.absoluteFile, offset, hex(digest.digest()))
        } catch (error: Throwable) {
            runCatching { Files.deleteIfExists(part.toPath()) }
            throw error
        }
    }

    /**
     * Durable atomic replacement for small control records (recovery). The
     * temp file is fsynced, atomically renamed, then the directory is fsynced
     * where the platform supports it. A failure never replaces the existing
     * record.
     */
    fun writeAtomicDurable(destination: File, bytes: ByteArray) {
        val parent = destination.absoluteFile.parentFile ?: throw IOException("noParent")
        ensureDirectory(parent)
        val temp = File(parent, destination.name + ".tmp-" + NotesPlatformNames.newToken())
        try {
            FileChannel.open(
                temp.toPath(),
                StandardOpenOption.CREATE_NEW,
                StandardOpenOption.WRITE,
            ).use { channel ->
                var buffer = java.nio.ByteBuffer.wrap(bytes)
                while (buffer.hasRemaining()) channel.write(buffer)
                channel.force(true)
            }
            try {
                Files.move(
                    temp.toPath(),
                    destination.toPath(),
                    StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING,
                )
            } catch (_: AtomicMoveNotSupportedException) {
                Files.move(temp.toPath(), destination.toPath(), StandardCopyOption.REPLACE_EXISTING)
            }
            fsyncDirectory(parent)
        } catch (error: Throwable) {
            runCatching { Files.deleteIfExists(temp.toPath()) }
            throw error
        }
    }

    /** Best-effort directory fsync; unsupported on some JVM/macOS filesystems. */
    fun fsyncDirectory(directory: File) {
        runCatching {
            FileChannel.open(directory.toPath(), StandardOpenOption.READ).use { it.force(true) }
        }
    }

    /**
     * Copies one existing file to a fresh destination, fsyncs and atomically
     * renames it. Returns the read-back facts of the new file.
     */
    fun copyFileDurable(source: File, destination: File, maxBytes: Long): StagedByteFile {
        val size = runCatching { Files.size(source.toPath()) }.getOrDefault(-1L)
        if (size <= 0L || size > maxBytes) throw IOException("sourceSizeOutOfRange")
        val parent = destination.absoluteFile.parentFile ?: throw IOException("noParent")
        ensureDirectory(parent)
        val part = File(parent, destination.name + ".part-" + NotesPlatformNames.newToken())
        val digest = MessageDigest.getInstance("SHA-256")
        var total = 0L
        try {
            source.inputStream().buffered(CHUNK_BYTES).use { input ->
                FileOutputStream(part).use { output ->
                    val buffer = ByteArray(CHUNK_BYTES)
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        total += read
                        if (total > maxBytes) throw IOException("contentTooLarge")
                        digest.update(buffer, 0, read)
                        output.write(buffer, 0, read)
                    }
                    output.flush()
                    runCatching { output.fd.sync() }
                }
            }
            if (total != size) throw IOException("sourceChanged")
            Files.move(
                part.toPath(),
                destination.toPath(),
                StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING,
            )
            fsyncDirectory(parent)
            return StagedByteFile(destination.absoluteFile, total, hex(digest.digest()))
        } catch (error: Throwable) {
            runCatching { Files.deleteIfExists(part.toPath()) }
            throw error
        }
    }

    fun deleteQuietly(file: File?) {
        if (file == null) return
        runCatching { file.deleteRecursively() }
    }

    /** Removes only entries older than [maxAgeMillis] under [directory]. */
    fun sweepOlderThan(directory: File?, maxAgeMillis: Long, now: Long = System.currentTimeMillis()) {
        if (directory == null || !directory.isDirectory) return
        val children = directory.listFiles() ?: return
        for (child in children) {
            val modified = runCatching { Files.getLastModifiedTime(child.toPath()).toMillis() }.getOrDefault(now)
            if (now - modified < maxAgeMillis) continue
            deleteQuietly(child)
        }
    }

    private const val MAX_READ_ITERATIONS = 100_000
    private val HEX = "0123456789abcdef".toCharArray()
}

internal data class StagedByteFile(val file: File, val byteCount: Long, val sha256: String)

/**
 * Random-access reader over one App-staged picked/export file. Offsets are
 * absolute; a short read at EOF is returned as-is (callers loop until empty).
 */
internal class StagedFileReader(
    val file: File,
    val byteCount: Long,
    private val onClose: (() -> Unit)? = null,
    private val ioDispatcher: CoroutineDispatcher = kotlinx.coroutines.Dispatchers.IO,
) {
    private val handle = RandomAccessFile(file, "r")
    private val lock = Any()
    @Volatile
    private var closed = false

    suspend fun read(offset: Long, maxBytes: Int): ByteArray = withContext(ioDispatcher) {
        if (maxBytes <= 0) throw NotesPortFailureException(
            NotesPortFailure(NotesPortFailure.FAILED, "invalidReadSize"),
        )
        synchronized(lock) {
            if (closed) throw NotesPortFailureException(
                NotesPortFailure(NotesPortFailure.CANCELLED, "closed"),
            )
            if (offset < 0L || offset > byteCount) throw NotesPortFailureException(
                NotesPortFailure(NotesPortFailure.FAILED, "offsetOutOfRange"),
            )
            val remaining = byteCount - offset
            if (remaining <= 0L) return@synchronized ByteArray(0)
            val length = minOf(maxBytes.toLong(), remaining).toInt()
            handle.seek(offset)
            val buffer = ByteArray(length)
            var read = 0
            while (read < length) {
                val n = handle.read(buffer, read, length - read)
                if (n < 0) break
                read += n
            }
            if (read == 0) ByteArray(0) else buffer.copyOf(read)
        }
    }

    fun close() {
        synchronized(lock) {
            if (closed) return
            closed = true
            runCatching { handle.close() }
        }
        runCatching { onClose?.invoke() }
    }
}

internal object NotesPlatformErrors {
    fun failure(code: String, detail: String? = null): NotesPortFailureException =
        NotesPortFailureException(NotesPortFailure(code, detail))

    fun unavailable(detail: String? = null) = failure(NotesPortFailure.UNAVAILABLE, detail)
    fun failed(detail: String? = null) = failure(NotesPortFailure.FAILED, detail)
    fun unsupported(detail: String? = null) = failure(NotesPortFailure.UNSUPPORTED, detail)
    fun notConfigured(detail: String? = null) = failure(NotesPortFailure.NOT_CONFIGURED, detail)
    fun cancelled(detail: String? = null) = failure(NotesPortFailure.CANCELLED, detail)
    fun busy(detail: String? = null) = failure(NotesPortFailure.BUSY, detail)
    fun notFound(detail: String? = null) = failure(NotesPortFailure.NOT_FOUND, detail)

    fun notes(error: Throwable, fallbackDetail: String? = null): NotesPortFailureException = when (error) {
        is NotesPortFailureException -> error
        is NotesException -> NotesPortFailureException(
            NotesPortFailure(
                when (error.code) {
                    "notFound" -> NotesPortFailure.NOT_FOUND
                    "conflict", "busy" -> NotesPortFailure.BUSY
                    "staleGeneration", "notesNotBound" -> NotesPortFailure.UNAVAILABLE
                    "requestTooLarge", "responseTooLarge" -> NotesPortFailure.UNSUPPORTED
                    "invalidPayload", "invalidDocument", "invalidOperation" -> NotesPortFailure.FAILED
                    else -> NotesPortFailure.FAILED
                },
                error.reason ?: fallbackDetail,
            ),
        )
        is CancellationException -> throw error
        else -> failed(fallbackDetail ?: "unexpectedFailure")
    }
}

/**
 * Pure decision table for the Office edit read-back. Kept free of Android
 * types so the exact "never claim an unobserved save" rules can be tested in
 * a JVM unit test.
 */
internal enum class NotesOfficeReadbackDecision {
    SAVED,
    UNCHANGED,
    EDITOR_FAILED,
    EDITOR_UNCLEAN,
    UNSAVED_AT_CLOSE,
    INVALID_SAVED_COPY,
    MISSING_RESULT,
    STALE_RESULT,
}

internal object NotesOfficeReadbackPolicy {
    /**
     * @param resultPresent an Activity result carrying the exact session token
     * @param tokenMatches the result token equals the launched session token
     * @param closedCleanly the engine reported its exact clean close
     * @param failureCode a terminal Office failure code, or null
     * @param digestChanged the read-back working copy differs from the source
     * @param explicitSaveCompleted the App completed and settled one exact
     *        Save-Copy handoff (the viewer's only authorized close-after-edit
     *        path) for this session
     * @param validOoxml the read-back/settled bytes pass the bounded OOXML check
     */
    fun decide(
        resultPresent: Boolean,
        tokenMatches: Boolean,
        closedCleanly: Boolean,
        failureCode: String?,
        digestChanged: Boolean,
        explicitSaveCompleted: Boolean,
        validOoxml: Boolean,
    ): NotesOfficeReadbackDecision = when {
        !resultPresent -> NotesOfficeReadbackDecision.MISSING_RESULT
        !tokenMatches -> NotesOfficeReadbackDecision.STALE_RESULT
        failureCode != null -> NotesOfficeReadbackDecision.EDITOR_FAILED
        !closedCleanly -> NotesOfficeReadbackDecision.EDITOR_UNCLEAN
        // The viewer's Save-Copy-and-close handoff is the only explicit
        // close-after-edit path. Its bytes were written + read back by the
        // App and settled with the engine, so this is the only case allowed
        // to become a saved note resource.
        explicitSaveCompleted -> if (validOoxml) {
            NotesOfficeReadbackDecision.SAVED
        } else {
            NotesOfficeReadbackDecision.INVALID_SAVED_COPY
        }
        !digestChanged -> NotesOfficeReadbackDecision.UNCHANGED
        // A changed working copy with no App settlement is a Discard or an
        // autosave we cannot prove; never import it.
        else -> NotesOfficeReadbackDecision.UNSAVED_AT_CLOSE
    }
}

internal fun java.io.File.readBounded(maxBytes: Long): ByteArray {
    if (length() > maxBytes) throw IOException("tooLarge")
    return inputStream().use { input ->
        val output = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(NotesPlatformFiles.CHUNK_BYTES)
        while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            output.write(buffer, 0, read)
            if (output.size().toLong() > maxBytes) throw IOException("tooLarge")
        }
        output.toByteArray()
    }
}

internal fun OutputStream.writeFully(bytes: ByteArray) {
    write(bytes)
    flush()
}
