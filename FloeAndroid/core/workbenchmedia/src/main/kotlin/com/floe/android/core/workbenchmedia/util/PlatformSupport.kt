// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.util

import com.floe.android.feature.canvas.CreativePathGuard
import com.floe.android.feature.workbench.WorkbenchR2Errors
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.security.MessageDigest
import java.time.Instant
import java.time.format.DateTimeParseException
import java.util.concurrent.atomic.AtomicLong

/** Monotonic-ish platform clock for job state; never used as a security lease proof. */
internal fun interface MediaClock {
    fun nowMillis(): Long
}

internal class SystemMediaClock : MediaClock {
    override fun nowMillis(): Long = System.currentTimeMillis()
}

internal fun MediaClock.nowIso(): String = Instant.ofEpochMilli(nowMillis()).toString()

internal fun parseInstantOrNull(value: String?): Instant? = try {
    value?.let(Instant::parse)
} catch (_: DateTimeParseException) {
    null
}

internal fun isExpired(value: String?, clock: MediaClock): Boolean {
    val instant = parseInstantOrNull(value) ?: return true
    return !instant.isAfter(Instant.ofEpochMilli(clock.nowMillis()))
}

/**
 * A canonical, root-contained path proof. The root is canonicalized ONCE by
 * the caller from a native-issued lease and is never rebuilt from project
 * JSON. Every path component is checked with the frozen R1 path guard and the
 * final canonical path must still be inside the canonical root.
 */
internal object MediaPaths {
    fun canonicalRoot(rootPath: String): File? = try {
        val root = File(rootPath).canonicalFile
        root.takeIf { it.isDirectory }
    } catch (_: IOException) {
        null
    }

    fun resolveExistingUnder(root: File, relativePath: String): File? {
        if (!CreativePathGuard.isSafeRelativePath(relativePath)) return null
        return try {
            val target = File(root, relativePath).canonicalFile
            if (!target.path.startsWith(root.path.trimEnd(File.separatorChar) + File.separatorChar)) {
                return null
            }
            val nio = target.toPath()
            if (Files.isSymbolicLink(nio) || !Files.isRegularFile(nio, LinkOption.NOFOLLOW_LINKS)) {
                return null
            }
            target.takeIf { it.isFile }
        } catch (_: IOException) {
            null
        }
    }

    fun resolveOutputUnder(root: File, relativePath: String): File? {
        if (!CreativePathGuard.isSafeRelativePath(relativePath)) return null
        return try {
            val target = File(root, relativePath).canonicalFile
            if (!target.path.startsWith(root.path.trimEnd(File.separatorChar) + File.separatorChar)) {
                return null
            }
            // Parent may not exist yet, but its nearest existing ancestor must
            // still be inside the root after symlink resolution.
            var ancestor: File? = target.parentFile
            while (ancestor != null && !ancestor.exists()) ancestor = ancestor.parentFile
            val canonicalAncestor = ancestor?.canonicalFile ?: return null
            val rootPrefix = root.path.trimEnd(File.separatorChar) + File.separatorChar
            if (canonicalAncestor != root && !canonicalAncestor.path.startsWith(rootPrefix)) {
                return null
            }
            target
        } catch (_: IOException) {
            null
        }
    }

    fun assertNotSymlink(path: Path): Boolean =
        !Files.isSymbolicLink(path) && !Files.isDirectory(path, LinkOption.NOFOLLOW_LINKS)

    fun safeComponent(value: String?, max: Int = 128): Boolean {
        if (value.isNullOrEmpty() || value.length > max) return false
        return value.all { it.isLetterOrDigit() || it == '-' || it == '_' || it == '.' } &&
            value != "." && value != ".."
    }
}

internal object Digests {
    private val HEX = "0123456789abcdef".toCharArray()

    fun isSha256(value: String?): Boolean =
        value != null && value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' }

    fun sha256(file: File, limitBytes: Long, cancelled: () -> Boolean = { false }): String? {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(1 shl 20)
        var total = 0L
        return try {
            file.inputStream().use { input: InputStream ->
                while (true) {
                    if (cancelled()) return null
                    val read = input.read(buffer)
                    if (read < 0) break
                    total += read
                    if (total > limitBytes) return null
                    digest.update(buffer, 0, read)
                }
            }
            if (total <= 0L) null else hex(digest.digest())
        } catch (_: IOException) {
            null
        }
    }

    fun sha256(bytes: ByteArray): String = hex(MessageDigest.getInstance("SHA-256").digest(bytes))

    fun hex(bytes: ByteArray): String {
        val out = CharArray(bytes.size * 2)
        var i = 0
        for (b in bytes) {
            val v = b.toInt() and 0xff
            out[i++] = HEX[v ushr 4]
            out[i++] = HEX[v and 0x0f]
        }
        return String(out)
    }
}

internal class AttemptSequence {
    private val counter = AtomicLong(0)
    fun next(prefix: String = "export"): String =
        "$prefix-${System.currentTimeMillis()}-${counter.incrementAndGet()}"
}

internal fun writeFullySync(target: File, bytes: ByteArray) {
    target.parentFile?.mkdirs()
    FileOutputStream(target).use { out ->
        out.write(bytes)
        out.flush()
        out.fd.sync()
    }
}

internal fun atomicReplace(staging: File, target: File) {
    try {
        Files.move(
            staging.toPath(),
            target.toPath(),
            java.nio.file.StandardCopyOption.ATOMIC_MOVE,
        )
    } catch (_: java.nio.file.AtomicMoveNotSupportedException) {
        Files.move(staging.toPath(), target.toPath())
    }
}

/** A typed refusal that maps directly onto the frozen R2 error vocabulary. */
internal class MediaRefusal(
    val code: String,
    override val message: String,
    val retryable: Boolean = false,
) : Exception(message)

internal fun refusal(code: String, message: String, retryable: Boolean = false): MediaRefusal =
    MediaRefusal(code, message, retryable)

internal val RENDER_UNSUPPORTED = WorkbenchR2Errors.RENDER_UNSUPPORTED
internal val RENDERER_UNAVAILABLE = WorkbenchR2Errors.RENDERER_UNAVAILABLE
internal val UNSUPPORTED_CODEC = WorkbenchR2Errors.UNSUPPORTED_CODEC
internal val UNSUPPORTED_TRANSITION = WorkbenchR2Errors.UNSUPPORTED_TRANSITION
internal val UNSUPPORTED_SOURCE_FORMAT = WorkbenchR2Errors.UNSUPPORTED_SOURCE_FORMAT
internal val INSUFFICIENT_STORAGE = WorkbenchR2Errors.INSUFFICIENT_STORAGE
internal val RENDER_CANCELLED = WorkbenchR2Errors.RENDER_CANCELLED
internal val RENDER_TIMEOUT = WorkbenchR2Errors.RENDER_TIMEOUT
internal val RENDER_TICKET_EXPIRED = WorkbenchR2Errors.RENDER_TICKET_EXPIRED
internal const val INVALID_PAYLOAD = "invalidPayload"
internal const val STORAGE_UNAVAILABLE = "storageUnavailable"
internal const val WRITE_FAILED = "writeFailed"
