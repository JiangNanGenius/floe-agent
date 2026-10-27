// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officeai.verification

import java.io.File
import java.security.MessageDigest
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Paths

/** Independently proves the App-owned export file is a plain regular
 * non-symlink file of the declared size whose full streamed SHA-256 equals
 * the declared digest, BEFORE any content parsing. Never mutates the file.
 */
internal object ArtifactGuard {

    /** Returns null when the artifact is trusted, else a refusal code. */
    fun check(file: File, sha256: String, declaredBytes: Long): String? {
        if (!isHexDigest(sha256)) return VerificationCodes.ARTIFACT_DIGEST_INVALID
        if (declaredBytes <= 0L) return VerificationCodes.ARTIFACT_SIZE_INVALID
        if (declaredBytes > VerificationLimits.MAX_ARTIFACT_BYTES) {
            return VerificationCodes.ARTIFACT_TOO_LARGE
        }
        val plain = try {
            val path = Paths.get(file.path)
            Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS) &&
                !Files.isSymbolicLink(path)
        } catch (error: RuntimeException) {
            false
        }
        if (!plain) return VerificationCodes.ARTIFACT_MISSING
        val actual = try {
            file.length()
        } catch (error: RuntimeException) {
            -1L
        }
        if (actual != declaredBytes) return VerificationCodes.ARTIFACT_SIZE_MISMATCH
        val streamed = streamedSha256Hex(file) ?: return VerificationCodes.ARTIFACT_MISSING
        if (streamed != sha256.lowercase()) return VerificationCodes.ARTIFACT_DIGEST_MISMATCH
        return null
    }

    fun isHexDigest(value: String): Boolean {
        if (value.length != 64) return false
        for (ch in value) {
            val ok = ch in '0'..'9' || ch in 'a'..'f' || ch in 'A'..'F'
            if (!ok) return false
        }
        return true
    }

    /** Streams the whole file through SHA-256 with a bounded buffer; the
     * caller has already size-capped the artifact.
     */
    fun streamedSha256Hex(file: File): String? = try {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(VerificationLimits.READ_CHUNK_BYTES)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        toHexLower(digest.digest())
    } catch (error: Exception) {
        null
    }

    fun toHexLower(bytes: ByteArray): String {
        val out = StringBuilder(bytes.size * 2)
        for (b in bytes) {
            val v = b.toInt() and 0xFF
            out.append(HEX_CHARS[v ushr 4])
            out.append(HEX_CHARS[v and 0x0F])
        }
        return out.toString()
    }

    private val HEX_CHARS = "0123456789abcdef".toCharArray()
}
