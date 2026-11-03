// SPDX-License-Identifier: MPL-2.0
//
// Verified export of an already-captured CAD viewport PNG into a user-chosen
// SAF document. The capture itself stays App-private until this sink proves
// that the exact bytes were written AND read back from the document URI. A
// cancelled picker or a stale owner never produces a success receipt.
package com.floe.android.host.cad

import android.content.ContentResolver
import android.net.Uri
import android.provider.OpenableColumns
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest
import java.util.Locale

internal data class C04CadCaptureExportArtifact(
    val uri: String,
    val displayName: String,
    val sha256: String,
    val byteCount: Long,
    val pixelWidth: Int,
    val pixelHeight: Int,
    val exportedAtMillis: Long,
)

internal class C04CadExportFailure(val code: String) : Exception(code)

/** One SAF document. Implementations must not widen the URI or add a second
 * document; the exporter verifies the same URI it wrote. */
internal interface C04CadExportSink {
    val uri: String
    fun openOutput(): OutputStream?
    fun openInput(): InputStream?
    fun delete(): Boolean
    fun displayName(): String?
}

internal class C04CadAndroidExportSink(
    private val resolver: ContentResolver,
    private val uriValue: Uri,
) : C04CadExportSink {
    override val uri: String = uriValue.toString()

    override fun openOutput(): OutputStream? =
        runCatching { resolver.openOutputStream(uriValue, "wt") }.getOrNull()
            ?: resolver.openOutputStream(uriValue, "w")

    override fun openInput(): InputStream? = resolver.openInputStream(uriValue)

    override fun delete(): Boolean = runCatching {
        resolver.delete(uriValue, null, null) > 0
    }.getOrDefault(false)

    override fun displayName(): String? = runCatching {
        resolver.query(
            uriValue,
            arrayOf(OpenableColumns.DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst() && !cursor.isNull(0)) cursor.getString(0) else null
        }
    }.getOrNull()
}

/**
 * Writes the exact verified capture artifact into the picked document, then
 * reads the document back. A hash/length/dimension mismatch deletes that
 * document and refuses the success receipt. The private capture is never
 * deleted or modified by this class.
 */
internal class C04CadCaptureExporter(
    private val root: File,
    private val nowMillis: () -> Long = System::currentTimeMillis,
) {
    fun export(
        artifact: C04CadCaptureArtifact,
        sink: C04CadExportSink,
        isCurrent: () -> Boolean = { true },
    ): C04CadCaptureExportArtifact {
        if (!isCurrent()) {
            runCatching { sink.delete() }
            throw C04CadExportFailure("owner")
        }
        if (!sink.uri.startsWith("content://")) throw C04CadExportFailure("uri")
        val canonicalRoot = try {
            root.canonicalFile
        } catch (_: Throwable) {
            throw C04CadExportFailure("root")
        }
        val file = try {
            artifact.file.canonicalFile
        } catch (_: Throwable) {
            throw C04CadExportFailure("artifact")
        }
        val prefix = canonicalRoot.path + File.separator
        if (!file.path.startsWith(prefix) || !file.isFile ||
            file.length() != artifact.byteCount
        ) {
            throw C04CadExportFailure("artifact")
        }
        val bytes = readBounded(file, isCurrent) ?: throw C04CadExportFailure("artifactRead")
        if (!isCurrent()) throw C04CadExportFailure("owner")
        if (bytes.size.toLong() != artifact.byteCount ||
            sha256(bytes) != artifact.sha256.lowercase(Locale.ROOT)
        ) {
            throw C04CadExportFailure("artifactDigest")
        }
        val info = C04CadPng.inspect(bytes) ?: throw C04CadExportFailure("artifactPng")
        if (info.width != artifact.pixelWidth || info.height != artifact.pixelHeight) {
            throw C04CadExportFailure("artifactDimensions")
        }
        var opened = false
        try {
            val output = sink.openOutput() ?: throw C04CadExportFailure("targetOpen")
            opened = true
            output.use { stream ->
                var offset = 0
                while (offset < bytes.size) {
                    if (!isCurrent()) throw C04CadExportFailure("owner")
                    val chunk = minOf(64 * 1024, bytes.size - offset)
                    stream.write(bytes, offset, chunk)
                    offset += chunk
                }
                stream.flush()
            }
            if (!isCurrent()) throw C04CadExportFailure("owner")
            val readBack = sink.openInput()?.use { input ->
                readBounded(input, bytes.size.toLong() + 1L, isCurrent)
            } ?: throw C04CadExportFailure("targetRead")
            if (readBack.size.toLong() != artifact.byteCount ||
                sha256(readBack) != artifact.sha256.lowercase(Locale.ROOT)
            ) {
                throw C04CadExportFailure("targetDigest")
            }
            if (!isCurrent()) throw C04CadExportFailure("owner")
            val name = runCatching { sink.displayName() }.getOrNull()
                ?.takeIf { it.isNotBlank() }
                ?: artifact.fileName
            return C04CadCaptureExportArtifact(
                uri = sink.uri,
                displayName = name.take(240),
                sha256 = artifact.sha256,
                byteCount = artifact.byteCount,
                pixelWidth = artifact.pixelWidth,
                pixelHeight = artifact.pixelHeight,
                exportedAtMillis = nowMillis(),
            )
        } catch (error: Throwable) {
            if (opened) runCatching { sink.delete() }
            throw if (error is C04CadExportFailure) error
            else C04CadExportFailure("targetWrite")
        }
    }

    private fun readBounded(file: File, isCurrent: () -> Boolean): ByteArray? {
        if (!file.isFile || file.length() > C04CadLimits.MAX_CAPTURE_BYTES) return null
        return file.inputStream().use {
            readBounded(it, C04CadLimits.MAX_CAPTURE_BYTES, isCurrent)
        }
    }

    private fun readBounded(
        input: InputStream,
        maximum: Long,
        isCurrent: () -> Boolean,
    ): ByteArray? {
        val output = java.io.ByteArrayOutputStream(minOf(maximum, 64 * 1024L).toInt())
        val buffer = ByteArray(64 * 1024)
        var total = 0L
        while (true) {
            if (!isCurrent()) throw C04CadExportFailure("owner")
            val read = input.read(buffer)
            if (read < 0) break
            if (read == 0) continue
            total += read
            if (total > maximum) return null
            output.write(buffer, 0, read)
        }
        return output.toByteArray()
    }

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(Locale.ROOT, it.toInt() and 0xFF) }
}
