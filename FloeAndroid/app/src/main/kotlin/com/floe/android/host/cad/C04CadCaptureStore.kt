// SPDX-License-Identifier: MPL-2.0
//
// Verified PNG capture sink for the CAD viewer. The bytes come from the
// renderer's actual canvas (toDataURL), are structurally walked here (PNG
// signature, IHDR, at least one IDAT, terminal IEND), decoded for dimensions
// with BitmapFactory bounds only, written part -> fsync -> atomic rename, then
// re-read and hashed. The App-private output is an artifact, not a rendered
// file and never a replacement for the source document. It becomes a
// user-facing PNG only through C04CadCaptureExporter's verified SAF copy.
package com.floe.android.host.cad

import android.content.Context
import android.graphics.BitmapFactory
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID

internal data class C04CadPngInfo(
    val width: Int,
    val height: Int,
    val header: ByteArray,
    val chunkCount: Int,
)

internal object C04CadPng {
    private val signature = byteArrayOf(
        0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    )

    /** Full bounded chunk walk. A bare signature/IHDR is not enough: the
     * artifact must contain IDAT data and end with IEND. */
    fun inspect(bytes: ByteArray): C04CadPngInfo? = inspect(
        bytes = bytes,
        minEdge = C04CadLimits.MIN_CAPTURE_EDGE,
        maxEdge = C04CadLimits.MAX_CAPTURE_EDGE,
        maxBytes = C04CadLimits.MAX_CAPTURE_BYTES,
    )

    /** Display textures are allowed to be small or larger than a viewport
     * capture; the same structural walk still proves IDAT/IEND. */
    fun inspectTexture(bytes: ByteArray): C04CadPngInfo? = inspect(
        bytes = bytes,
        minEdge = 1,
        maxEdge = C04FloecadLimits.MAX_TEXTURE_EDGE,
        maxBytes = C04FloecadLimits.MAX_TEXTURE_BYTES,
    )

    private fun inspect(
        bytes: ByteArray,
        minEdge: Int,
        maxEdge: Int,
        maxBytes: Long,
    ): C04CadPngInfo? {
        if (bytes.size < 57 || bytes.size.toLong() > maxBytes) return null
        if (!bytes.copyOfRange(0, 8).contentEquals(signature)) return null
        var offset = 8
        var chunks = 0
        var width = 0
        var height = 0
        var sawHeader = false
        var sawData = false
        var sawEnd = false
        while (offset + 12 <= bytes.size) {
            if (chunks++ > 4096) return null
            val length = readUInt32(bytes, offset)
            if (length < 0 || length > bytes.size - offset - 12) return null
            val type = String(bytes, offset + 4, 4, Charsets.US_ASCII)
            if (!sawHeader) {
                if (type != "IHDR" || length != 13) return null
                width = readInt(bytes, offset + 8)
                height = readInt(bytes, offset + 12)
                if (width < minEdge || width > maxEdge ||
                    height < minEdge || height > maxEdge
                ) return null
                val bitDepth = bytes[offset + 16].toInt() and 0xFF
                val colorType = bytes[offset + 17].toInt() and 0xFF
                val validDepth = bitDepth in setOf(1, 2, 4, 8, 16)
                val validColor = colorType in setOf(0, 2, 3, 4, 6)
                if (!validDepth || !validColor) return null
                sawHeader = true
            } else if (type == "IDAT") {
                sawData = true
            } else if (type == "IEND") {
                if (length != 0) return null
                sawEnd = true
                offset += 12
                break
            }
            offset += 12 + length
        }
        if (!sawHeader || !sawData || !sawEnd || offset != bytes.size) return null
        return C04CadPngInfo(
            width = width,
            height = height,
            header = bytes.copyOfRange(0, 33),
            chunkCount = chunks,
        )
    }

    fun headerHex(header: ByteArray): String =
        header.joinToString("") { "%02x".format(Locale.ROOT, it.toInt() and 0xFF) }

    private fun readUInt32(bytes: ByteArray, offset: Int): Int =
        ((bytes[offset].toInt() and 0xFF) shl 24) or
            ((bytes[offset + 1].toInt() and 0xFF) shl 16) or
            ((bytes[offset + 2].toInt() and 0xFF) shl 8) or
            (bytes[offset + 3].toInt() and 0xFF)

    private fun readInt(bytes: ByteArray, offset: Int): Int = readUInt32(bytes, offset)
}

internal data class C04CadCaptureArtifact(
    val file: File,
    val fileName: String,
    val sha256: String,
    val byteCount: Long,
    val pixelWidth: Int,
    val pixelHeight: Int,
    val capturedAtMillis: Long,
    val format: C04CadFormat,
    val pngHeaderHex: String,
)

internal class C04CadCaptureStore(
    context: Context,
    private val root: File = File(
        context.applicationContext.noBackupFilesDir, "floe-cad-captures"),
    private val nowMillis: () -> Long = System::currentTimeMillis,
) {
    /** Reused by the verified SAF exporter; never handed to the WebView or a
     * task as a file authority. */
    val rootDirectory: File get() = root

    fun store(
        sessionToken: String,
        sourceFileName: String,
        bytes: ByteArray,
        width: Int,
        height: Int,
        format: C04CadFormat,
    ): C04CadCaptureArtifact {
        if (!isUUID(sessionToken)) throw C04CadCaptureFailure("invalidSession")
        val info = C04CadPng.inspect(bytes)
            ?: throw C04CadCaptureFailure("invalidPng")
        if (info.width != width || info.height != height) {
            throw C04CadCaptureFailure("captureDimensions")
        }
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
        if (options.outWidth != width || options.outHeight != height) {
            throw C04CadCaptureFailure("captureDecode")
        }
        if (!root.isDirectory && !root.mkdirs()) {
            throw C04CadCaptureFailure("captureStorage")
        }
        if (Files.isSymbolicLink(root.toPath())) {
            throw C04CadCaptureFailure("captureStorage")
        }
        val sessionDir = File(root, sessionToken.lowercase(Locale.ROOT))
        if (!sessionDir.isDirectory && !sessionDir.mkdirs()) {
            throw C04CadCaptureFailure("captureStorage")
        }
        if (Files.isSymbolicLink(sessionDir.toPath())) {
            throw C04CadCaptureFailure("captureStorage")
        }
        val capturedAt = nowMillis()
        val base = sourceFileName.substringBeforeLast('.')
            .replace(Regex("[^A-Za-z0-9._-]"), "_")
            .take(60)
            .ifBlank { "drawing" }
        var finalFile = File(sessionDir, "$base-preview-$capturedAt.png")
        var suffix = 0
        while (finalFile.exists()) {
            suffix += 1
            finalFile = File(sessionDir, "$base-preview-$capturedAt-$suffix.png")
            if (suffix > 100) throw C04CadCaptureFailure("captureStorage")
        }
        val part = File(sessionDir, "${finalFile.name}.part")
        val digest = MessageDigest.getInstance("SHA-256")
        try {
            FileOutputStream(part).use { output ->
                output.write(bytes)
                output.flush()
                output.fd.sync()
            }
            digest.update(bytes)
            try {
                Files.move(
                    part.toPath(), finalFile.toPath(),
                    StandardCopyOption.ATOMIC_MOVE,
                )
            } catch (_: Throwable) {
                Files.move(part.toPath(), finalFile.toPath())
            }
            if (!finalFile.setReadOnly()) throw C04CadCaptureFailure("captureStorage")
            val actual = sha256(finalFile)
            if (actual != digest.digest().joinToString("") {
                    "%02x".format(Locale.ROOT, it.toInt() and 0xFF)
                } || finalFile.length() != bytes.size.toLong()
            ) {
                throw C04CadCaptureFailure("captureDigest")
            }
            return C04CadCaptureArtifact(
                file = finalFile,
                fileName = finalFile.name,
                sha256 = actual,
                byteCount = bytes.size.toLong(),
                pixelWidth = width,
                pixelHeight = height,
                capturedAtMillis = capturedAt,
                format = format,
                pngHeaderHex = C04CadPng.headerHex(info.header),
            )
        } catch (error: Throwable) {
            part.delete()
            finalFile.delete()
            throw if (error is C04CadCaptureFailure) error
            else C04CadCaptureFailure("captureStorage")
        }
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read <= 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") {
            "%02x".format(Locale.ROOT, it.toInt() and 0xFF)
        }
    }

    private fun isUUID(value: String): Boolean = try {
        UUID.fromString(value).toString().equals(value, ignoreCase = true)
    } catch (_: IllegalArgumentException) {
        false
    }
}

internal class C04CadCaptureFailure(val code: String) : Exception(code)
