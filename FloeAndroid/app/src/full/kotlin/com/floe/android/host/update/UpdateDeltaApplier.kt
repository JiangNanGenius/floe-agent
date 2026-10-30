// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.RandomAccessFile
import java.security.MessageDigest
import kotlinx.serialization.json.longOrNull

/**
 * Streaming applier for FloePatch v1 (see
 * `scripts/update/produce-update-delta.py`).
 *
 * Bounds and ownership:
 *  * the installed/base APK is opened read-only and streamed through ONE
 *    reusable buffer (default 1 MiB); the 445 MB target is never held in memory;
 *  * the reconstruction is written to a private staging file whose length is
 *    bounded by the manifest's target size, then fsynced;
 *  * the patch file size must equal the release-bound manifest size, the patch
 *    header must match the manifest, and the final output is accepted only when
 *    its exact size AND SHA-256 equal the release-bound target;
 *  * any failure or cancellation deletes the partial output before returning,
 *    so a broken reconstruction can never be offered for installation.
 *
 * No Android types appear here: the exact same code is exercised by the
 * full-flavor JVM tests and by the app.
 */
internal enum class DeltaApplyFailure {
    BASE_MISMATCH,
    PATCH_SIZE_MISMATCH,
    BAD_MAGIC,
    BAD_HEADER,
    UNSUPPORTED_FORMAT,
    OP_INVALID,
    PATCH_TRUNCATED,
    TARGET_SIZE_MISMATCH,
    TARGET_HASH_MISMATCH,
    /**
     * The output (or the base/patch pair) resolved to the same canonical path
     * as a protected input. Nothing was deleted or written.
     */
    ALIASED_INPUT,
    OUTPUT_WRITE,
}

internal sealed interface DeltaApplyResult {
    data class Success(val targetSha256: String, val targetSizeBytes: Long) : DeltaApplyResult
    data class Failure(val reason: DeltaApplyFailure, val detail: String? = null) : DeltaApplyResult
    data object Cancelled : DeltaApplyResult
}

internal object FloePatchFormat {
    val MAGIC = "FLOEPATCH1\n".toByteArray(Charsets.US_ASCII)
    const val VERSION = 1
    const val OP_END = 0x00
    const val OP_COPY = 0x01
    const val OP_INSERT = 0x02
    const val MAX_HEADER_BYTES = 64 * 1024
    const val MAX_OP_COUNT = 10_000_000L
    const val BUFFER_BYTES = 1024 * 1024
}

internal data class PatchHeader(
    val formatVersion: Int,
    val baseSha256: String,
    val baseSizeBytes: Long,
    val targetSha256: String,
    val targetSizeBytes: Long,
    val copies: Long,
    val copyBytes: Long,
    val inserts: Long,
    val insertBytes: Long,
)

internal class FloePatchApplier(private val bufferBytes: Int = FloePatchFormat.BUFFER_BYTES) {
    init { require(bufferBytes in 1..FloePatchFormat.BUFFER_BYTES) { "Invalid patch buffer size" } }


    private class Cancelled : Exception()

    private class PatchTruncated : Exception()

    fun apply(
        base: File,
        patch: File,
        output: File,
        manifest: UpdateDeltaManifest,
        checkCancelled: () -> Boolean = { false },
        onProgress: (Long) -> Unit = {},
    ): DeltaApplyResult {
        // Input preservation comes FIRST, before any delete/write: the
        // applier must never destroy its own base or patch because a caller
        // passed an aliasing output. Canonical paths catch "..", absolute
        // spellings and symlinks; a base/patch alias is refused as well.
        if (aliasesProtectedInput(base, patch, output)) {
            return DeltaApplyResult.Failure(DeltaApplyFailure.ALIASED_INPUT)
        }
        if (!base.isFile || base.length() != manifest.base.sizeBytes) {
            return DeltaApplyResult.Failure(DeltaApplyFailure.BASE_MISMATCH, "base-size")
        }
        if (!patch.isFile || patch.length() != manifest.patch.sizeBytes) {
            return DeltaApplyResult.Failure(DeltaApplyFailure.PATCH_SIZE_MISMATCH)
        }
        if (output.exists() && !output.delete()) {
            return DeltaApplyResult.Failure(DeltaApplyFailure.OUTPUT_WRITE, "stale-output")
        }
        var published = false
        try {
            ensureActive(checkCancelled)
            val baseDigest = digestFile(base, checkCancelled)
            if (!baseDigest.equals(manifest.base.sha256, ignoreCase = true)) {
                return DeltaApplyResult.Failure(DeltaApplyFailure.BASE_MISMATCH, "base-sha256")
            }
            ensureActive(checkCancelled)
            FileInputStream(patch).use { patchStream ->
                val input = BufferedInputStream(patchStream, bufferBytes)
                val magic = ByteArray(FloePatchFormat.MAGIC.size)
                input.readFullyOrFail(magic, 0, magic.size)
                if (!magic.contentEquals(FloePatchFormat.MAGIC)) {
                    return DeltaApplyResult.Failure(DeltaApplyFailure.BAD_MAGIC)
                }
                val headerLength = input.readU32()
                if (headerLength !in 1..FloePatchFormat.MAX_HEADER_BYTES) {
                    return DeltaApplyResult.Failure(DeltaApplyFailure.BAD_HEADER, "header-length")
                }
                val headerText = ByteArray(headerLength)
                input.readFullyOrFail(headerText, 0, headerLength)
                val header = parseHeader(String(headerText, Charsets.UTF_8))
                    ?: return DeltaApplyResult.Failure(DeltaApplyFailure.BAD_HEADER, "header")
                val headerFailure = validateHeader(header, manifest)
                if (headerFailure != null) return DeltaApplyResult.Failure(headerFailure)

                val digest = MessageDigest.getInstance("SHA-256")
                val buffer = ByteArray(bufferBytes)
                var written = 0L
                var copies = 0L
                var inserts = 0L
                var copyBytes = 0L
                var insertBytes = 0L
                var ended = false
                FileOutputStream(output).use { fileOutput ->
                    val out = BufferedOutputStream(fileOutput, bufferBytes)
                    RandomAccessFile(base, "r").use { baseFile ->
                        while (!ended) {
                            ensureActive(checkCancelled)
                            val kind = input.read()
                            if (kind < 0) {
                                return DeltaApplyResult.Failure(DeltaApplyFailure.PATCH_TRUNCATED, "no-end")
                            }
                            when (kind) {
                                FloePatchFormat.OP_END -> {
                                    val total = input.readU64()
                                    if (total != written) {
                                        return DeltaApplyResult.Failure(
                                            DeltaApplyFailure.TARGET_SIZE_MISMATCH,
                                            "end-total",
                                        )
                                    }
                                    ended = true
                                }
                                FloePatchFormat.OP_COPY -> {
                                    val offset = input.readU64()
                                    val length = input.readU32().toLong()
                                    if (offset < 0L || length <= 0L ||
                                        offset > header.baseSizeBytes - length
                                    ) {
                                        return DeltaApplyResult.Failure(DeltaApplyFailure.OP_INVALID, "copy-range")
                                    }
                                    if (written + length > header.targetSizeBytes) {
                                        return DeltaApplyResult.Failure(DeltaApplyFailure.TARGET_SIZE_MISMATCH)
                                    }
                                    baseFile.seek(offset)
                                    var remaining = length
                                    while (remaining > 0L) {
                                        ensureActive(checkCancelled)
                                        val want = minOf(remaining, buffer.size.toLong()).toInt()
                                        val count = baseFile.read(buffer, 0, want)
                                        if (count <= 0) {
                                            return DeltaApplyResult.Failure(
                                                DeltaApplyFailure.OP_INVALID,
                                                "short-base",
                                            )
                                        }
                                        digest.update(buffer, 0, count)
                                        out.write(buffer, 0, count)
                                        written += count
                                        remaining -= count
                                    }
                                    copies += 1
                                    copyBytes += length
                                    onProgress(written)
                                }
                                FloePatchFormat.OP_INSERT -> {
                                    val length = input.readU32().toLong()
                                    if (length <= 0L) {
                                        return DeltaApplyResult.Failure(DeltaApplyFailure.OP_INVALID, "insert-zero")
                                    }
                                    if (written + length > header.targetSizeBytes) {
                                        return DeltaApplyResult.Failure(DeltaApplyFailure.TARGET_SIZE_MISMATCH)
                                    }
                                    var remaining = length
                                    while (remaining > 0L) {
                                        ensureActive(checkCancelled)
                                        val want = minOf(remaining, buffer.size.toLong()).toInt()
                                        input.readFullyOrFail(buffer, 0, want)
                                        digest.update(buffer, 0, want)
                                        out.write(buffer, 0, want)
                                        written += want
                                        remaining -= want
                                    }
                                    inserts += 1
                                    insertBytes += length
                                    onProgress(written)
                                }
                                else -> return DeltaApplyResult.Failure(DeltaApplyFailure.OP_INVALID, "opcode")
                            }
                        }
                    }
                    out.flush()
                    fileOutput.fd.sync()
                }
                if (written != header.targetSizeBytes) {
                    return DeltaApplyResult.Failure(DeltaApplyFailure.TARGET_SIZE_MISMATCH)
                }
                if (copies != header.copies || inserts != header.inserts ||
                    copyBytes != header.copyBytes || insertBytes != header.insertBytes
                ) {
                    return DeltaApplyResult.Failure(DeltaApplyFailure.OP_INVALID, "op-totals")
                }
                val actual = digest.digest().joinToString("") { "%02x".format(it) }
                if (!actual.equals(header.targetSha256, ignoreCase = true)) {
                    return DeltaApplyResult.Failure(DeltaApplyFailure.TARGET_HASH_MISMATCH)
                }
                if (output.length() != header.targetSizeBytes) {
                    return DeltaApplyResult.Failure(DeltaApplyFailure.TARGET_SIZE_MISMATCH)
                }
                published = true
                return DeltaApplyResult.Success(actual, written)
            }
        } catch (cancelled: Cancelled) {
            return DeltaApplyResult.Cancelled
        } catch (truncated: PatchTruncated) {
            return DeltaApplyResult.Failure(DeltaApplyFailure.PATCH_TRUNCATED)
        } catch (failure: IOException) {
            return DeltaApplyResult.Failure(DeltaApplyFailure.OUTPUT_WRITE, failure.javaClass.simpleName)
        } finally {
            if (!published) output.delete()
        }
    }

    private fun aliasesProtectedInput(base: File, patch: File, output: File): Boolean {
        fun canonical(file: File): String? = runCatching { file.canonicalPath }.getOrNull()
        val basePath = canonical(base) ?: base.absolutePath
        val patchPath = canonical(patch) ?: patch.absolutePath
        val outputPath = canonical(output) ?: output.absolutePath
        return outputPath == basePath || outputPath == patchPath || basePath == patchPath
    }

    private fun validateHeader(header: PatchHeader, manifest: UpdateDeltaManifest): DeltaApplyFailure? {
        if (header.formatVersion != FloePatchFormat.VERSION) {
            return DeltaApplyFailure.UNSUPPORTED_FORMAT
        }
        if (header.baseSizeBytes != manifest.base.sizeBytes ||
            !header.baseSha256.equals(manifest.base.sha256, ignoreCase = true)
        ) {
            return DeltaApplyFailure.BASE_MISMATCH
        }
        if (header.targetSizeBytes != manifest.target.sizeBytes ||
            !header.targetSha256.equals(manifest.target.sha256, ignoreCase = true)
        ) {
            return DeltaApplyFailure.BAD_HEADER
        }
        if (header.targetSizeBytes <= 0L ||
            header.copies < 0L || header.inserts < 0L ||
            header.copyBytes < 0L || header.insertBytes < 0L ||
            header.copies > FloePatchFormat.MAX_OP_COUNT ||
            header.inserts > FloePatchFormat.MAX_OP_COUNT ||
            header.copies > FloePatchFormat.MAX_OP_COUNT - header.inserts ||
            header.copyBytes > header.targetSizeBytes || header.insertBytes > header.targetSizeBytes ||
            header.copyBytes != header.targetSizeBytes - header.insertBytes
        ) {
            return DeltaApplyFailure.BAD_HEADER
        }
        return null
    }

    private fun parseHeader(text: String): PatchHeader? {
        if (text.length > FloePatchFormat.MAX_HEADER_BYTES) return null
        val root = runCatching {
            kotlinx.serialization.json.Json.parseToJsonElement(text) as? kotlinx.serialization.json.JsonObject
        }.getOrNull() ?: return null
        fun obj(key: String) = root[key] as? kotlinx.serialization.json.JsonObject
        fun string(node: kotlinx.serialization.json.JsonObject?, key: String): String? =
            (node?.get(key) as? kotlinx.serialization.json.JsonPrimitive)
                ?.takeIf { it.isString }?.content
        fun long(node: kotlinx.serialization.json.JsonObject?, key: String): Long? =
            (node?.get(key) as? kotlinx.serialization.json.JsonPrimitive)?.longOrNull

        if (string(root, "format") != "floepatch") return null
        val version = long(root, "formatVersion")?.takeIf { it in 1..Int.MAX_VALUE.toLong() }?.toInt() ?: return null
        val base = obj("base") ?: return null
        val target = obj("target") ?: return null
        val ops = obj("ops") ?: return null
        val baseSha = string(base, "sha256") ?: return null
        val targetSha = string(target, "sha256") ?: return null
        if (!baseSha.matches(SHA256) || !targetSha.matches(SHA256)) return null
        return PatchHeader(
            formatVersion = version,
            baseSha256 = baseSha,
            baseSizeBytes = long(base, "sizeBytes") ?: return null,
            targetSha256 = targetSha,
            targetSizeBytes = long(target, "sizeBytes") ?: return null,
            copies = long(ops, "copies") ?: return null,
            copyBytes = long(ops, "copyBytes") ?: return null,
            inserts = long(ops, "inserts") ?: return null,
            insertBytes = long(ops, "insertBytes") ?: return null,
        )
    }

    private fun ensureActive(checkCancelled: () -> Boolean) {
        if (checkCancelled()) throw Cancelled()
    }

    private fun digestFile(file: File, checkCancelled: () -> Boolean): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(bufferBytes)
        FileInputStream(file).use { input ->
            while (true) {
                ensureActive(checkCancelled)
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun InputStream.readFullyOrFail(target: ByteArray, offset: Int, length: Int) {
        var read = 0
        while (read < length) {
            val count = read(target, offset + read, length - read)
            if (count < 0) throw PatchTruncated()
            read += count
        }
    }

    private fun InputStream.readU32(): Int {
        var value = 0
        for (shift in 0 until 4) {
            val byte = read()
            if (byte < 0) throw PatchTruncated()
            value = value or ((byte and 0xFF) shl (shift * 8))
        }
        return value
    }

    private fun InputStream.readU64(): Long {
        var value = 0L
        for (shift in 0 until 8) {
            val byte = read()
            if (byte < 0) throw PatchTruncated()
            value = value or ((byte.toLong() and 0xFFL) shl (shift * 8))
        }
        return value
    }

    private companion object {
        val SHA256 = Regex("[0-9a-f]{64}")
    }
}
