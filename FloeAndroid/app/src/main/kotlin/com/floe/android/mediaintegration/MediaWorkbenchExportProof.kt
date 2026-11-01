// SPDX-License-Identifier: MPL-2.0
package com.floe.android.mediaintegration

import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.Locale

/**
 * Pure, bounded file proof for a verified export receipt.
 *
 * The receipt path alone is NEVER write authority. The App re-derives the
 * exact project-relative path under the native-issued receipt root, proves
 * regular-file containment, and streams the exact declared bytes once while
 * hashing. The same pass can stage the bytes into App scratch; the staged
 * bytes are the only source written to a user destination.
 *
 * No Android type is used here, so the proof runs in plain JVM tests.
 */
internal object MediaWorkbenchExportProof {
    /** Bounded save-copy source cap; matches the largest R2 import ceiling. */
    const val MAX_BYTES = 8L * 1024 * 1024 * 1024

    private const val CHUNK_BYTES = 64 * 1024

    data class VerifiedSource(
        val file: File,
        val byteCount: Long,
        val sha256: String,
    )

    fun isSha256Hex(value: String): Boolean =
        value.length == 64 && value.all { it in "0123456789abcdefABCDEF" }

    /**
     * A receipt-relative output path must be a single canonical project
     * relative path. Absolute paths, `..`, empty segments, backslashes and
     * NUL are refused rather than normalized into something else.
     */
    fun isSafeRelativePath(value: String): Boolean {
        if (value.isEmpty() || value.length > 512) return false
        if (value.startsWith("/") || value.contains('\\')) return false
        if (value.contains('\u0000')) return false
        val segments = value.split('/')
        if (segments.any { it.isEmpty() || it == "." || it == ".." }) return false
        return true
    }

    /**
     * Resolve [relativePath] under [mediaRootPath] and prove it is a regular
     * file inside the canonical root. Returns null on any containment or
     * type violation; never falls back to another root.
     */
    fun resolveContainedFile(mediaRootPath: String, relativePath: String): File? {
        if (mediaRootPath.isBlank() || !isSafeRelativePath(relativePath)) return null
        val root = runCatching { File(mediaRootPath).canonicalFile }.getOrNull() ?: return null
        val candidate = runCatching {
            File(root, relativePath).canonicalFile
        }.getOrNull() ?: return null
        val prefix = root.path + File.separator
        if (candidate.path == root.path || !candidate.path.startsWith(prefix)) return null
        if (!candidate.isFile || candidate.isDirectory) return null
        return candidate
    }

    /**
     * Streams exactly [expectedBytes] from [source], verifies the streamed
     * SHA-256 against [expectedSha256] and, when [stagingTarget] is supplied,
     * writes those already-hashed bytes into the App-owned scratch file.
     *
     * Returns null on any length/digest/IO mismatch; a partially staged file
     * is deleted by the caller (the helper deletes it on failure too).
     */
    fun verifyAndStage(
        source: File,
        expectedBytes: Long,
        expectedSha256: String,
        stagingTarget: File? = null,
    ): VerifiedSource? {
        if (expectedBytes !in 1..MAX_BYTES) return null
        if (!isSha256Hex(expectedSha256)) return null
        val canonical = runCatching { source.canonicalFile }.getOrNull() ?: return null
        if (!canonical.isFile || canonical.isDirectory) return null
        if (canonical.length() != expectedBytes) return null
        val digest = MessageDigest.getInstance("SHA-256")
        val part = stagingTarget
        var staged = false
        try {
            FileInputStream(canonical).use { input ->
                val output = if (part != null) {
                    part.parentFile?.mkdirs()
                    FileOutputStream(part)
                } else {
                    null
                }
                try {
                    val buffer = ByteArray(CHUNK_BYTES)
                    var remaining = expectedBytes
                    while (remaining > 0L) {
                        val read = input.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
                        if (read <= 0) return null
                        digest.update(buffer, 0, read)
                        output?.write(buffer, 0, read)
                        remaining -= read
                    }
                    // Exact EOF: the declared size is the whole file, not a prefix.
                    if (input.read() != -1) return null
                    output?.flush()
                    runCatching { output?.fd?.sync() }
                } finally {
                    runCatching { output?.close() }
                }
            }
            val sha = digest.digest().joinToString("") {
                String.format(Locale.ROOT, "%02x", it.toInt() and 0xff)
            }
            if (!sha.equals(expectedSha256, ignoreCase = true)) return null
            staged = part != null
            return VerifiedSource(canonical, expectedBytes, sha.lowercase(Locale.ROOT))
        } catch (_: Throwable) {
            return null
        } finally {
            if (part != null && !staged) runCatching { part.delete() }
        }
    }
}
