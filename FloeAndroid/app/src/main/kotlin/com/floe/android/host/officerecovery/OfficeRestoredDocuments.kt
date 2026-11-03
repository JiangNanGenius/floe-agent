// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officerecovery

import android.content.Context
import java.io.File
import java.io.FileInputStream
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID
import org.json.JSONObject

/**
 * Fresh App-owned Office documents restored from retained recovery content.
 *
 * The Swift C07 restore writes ONE new directory per restore below
 * `files/OfficeInputs/restored/<restoreID>/` with a bounded `manifest.json`
 * and the exact document bytes. This store only READS that durable index. It
 * never creates, edits or executes a document, and it never restores a live
 * recovery session, grant, destination URI or journal record.
 */
internal data class OfficeRestoredDocument(
    val restoreID: String,
    val documentID: String,
    val fileName: String,
    val displayName: String,
    val format: String,
    val kind: Kind,
    val byteCount: Long,
    val sha256: String,
) {
    internal enum class Kind { WORKING_COPY, VERIFIED_OUTPUT }
}

internal class OfficeRestoredDocumentStore(
    private val root: File,
) {
    companion object {
        const val SCHEMA = "floe.office-restored/1"
        private const val MAX_MANIFEST_BYTES = 512L * 1024L
        private const val MAX_RESTORES = 64
        private const val MAX_DOCUMENTS = 200
        private const val MAX_PER_RESTORE = 64
        val SHA256_HEX = Regex("^[0-9a-f]{64}$")
        val FORMATS = setOf("docx", "xlsx", "pptx", "pdf")

        fun forContext(context: Context): OfficeRestoredDocumentStore =
            OfficeRestoredDocumentStore(
                File(context.applicationInfo.dataDir, "files/OfficeInputs/restored"),
            )
    }

    private val canonicalRoot: File? =
        runCatching { root.canonicalFile }.getOrNull()

    /** Bounded metadata projection; no file is opened for content here. */
    fun list(): List<OfficeRestoredDocument> {
        val directory = canonicalRoot ?: return emptyList()
        if (!directory.isDirectory) return emptyList()
        val children = runCatching {
            directory.listFiles()
                ?.filter {
                    it.isDirectory &&
                        runCatching { UUID.fromString(it.name) }.isSuccess
                }
                ?.sortedByDescending { it.name }
        }.getOrNull() ?: return emptyList()
        val result = ArrayList<OfficeRestoredDocument>(16)
        val seen = HashSet<String>()
        for (child in children.take(MAX_RESTORES)) {
            for (document in readManifest(child)) {
                if (result.size >= MAX_DOCUMENTS) return result
                if (!seen.add(document.documentID)) continue
                result += document
            }
        }
        return result
    }

    fun resolve(documentID: String): OfficeRestoredDocument? =
        list().firstOrNull { it.documentID == documentID }

    /**
     * Re-verifies the exact App-owned file before any preview launch: canonical
     * containment, regular non-symlink file, declared length and SHA-256.
     * Returns null on any mismatch; callers surface a truthful failure.
     */
    fun verifiedFile(document: OfficeRestoredDocument): File? {
        val directory = canonicalRoot ?: return null
        val restore = File(directory, document.restoreID).canonicalFile
        if (restore.parentFile?.path != directory.path) return null
        val file = File(restore, document.fileName).canonicalFile
        if (file.parentFile?.path != restore.path) return null
        if (!file.path.startsWith(directory.path + File.separator)) return null
        if (java.nio.file.Files.isSymbolicLink(file.toPath())) return null
        if (!file.isFile || file.length() != document.byteCount) return null
        val digest = runCatching { sha256(file) }.getOrNull() ?: return null
        if (digest != document.sha256) return null
        return file
    }

    private fun readManifest(directory: File): List<OfficeRestoredDocument> {
        // Only a restore whose owned-data transaction committed may surface
        // documents. A pending/incomplete restore is rolled back exactly.
        val complete = File(directory, "complete.json")
        if (!complete.isFile || complete.length() !in 1L..4096L) {
            return emptyList()
        }
        val marker = runCatching {
            JSONObject(complete.readText(StandardCharsets.UTF_8))
        }.getOrNull()
        if (marker?.optString("restoreID") != directory.name) {
            return emptyList()
        }
        val manifest = File(directory, "manifest.json")
        if (!manifest.isFile || manifest.length() !in 1L..MAX_MANIFEST_BYTES) {
            return emptyList()
        }
        val text = runCatching {
            FileInputStream(manifest).use { input ->
                val buffer = ByteArray(manifest.length().toInt())
                var offset = 0
                while (offset < buffer.size) {
                    val read = input.read(buffer, offset, buffer.size - offset)
                    if (read <= 0) return@use null
                    offset += read
                }
                String(buffer, StandardCharsets.UTF_8)
            }
        }.getOrNull() ?: return emptyList()
        val json = runCatching { JSONObject(text) }.getOrNull() ?: return emptyList()
        if (json.optString("schema") != SCHEMA) return emptyList()
        val restoreID = json.optString("restoreID")
        if (runCatching { UUID.fromString(restoreID) }.isFailure ||
            restoreID != directory.name
        ) {
            return emptyList()
        }
        val array = json.optJSONArray("documents") ?: return emptyList()
        if (array.length() > MAX_PER_RESTORE) return emptyList()
        val result = ArrayList<OfficeRestoredDocument>(array.length())
        for (index in 0 until array.length()) {
            val item = array.optJSONObject(index) ?: continue
            val documentID = item.optString("documentID")
            val id = runCatching { UUID.fromString(documentID) }.getOrNull() ?: continue
            val format = item.optString("format").lowercase(Locale.ROOT)
            if (format !in FORMATS) continue
            val fileName = item.optString("fileName")
            if (fileName != "$documentID.$format") continue
            val displayName = item.optString("displayName")
                .filter { it.code >= 0x20 && it.code != 0x7f }
                .trim()
            if (displayName.isEmpty() ||
                displayName.toByteArray(StandardCharsets.UTF_8).size > 240 ||
                displayName.contains('/') || displayName.contains('\\')
            ) {
                continue
            }
            val kind = when (item.optString("kind")) {
                "workingCopy" -> OfficeRestoredDocument.Kind.WORKING_COPY
                "verifiedOutput" -> OfficeRestoredDocument.Kind.VERIFIED_OUTPUT
                else -> continue
            }
            val bytes = item.optLong("byteCount", -1L)
            if (bytes !in 1L..MAX_OFFICE_RECOVERY_BYTES) continue
            val sha = item.optString("sha256")
            if (!SHA256_HEX.matches(sha)) continue
            val restoredAt = item.optString("restoredAt")
            if (restoredAt.isEmpty() || restoredAt.length > 64 ||
                restoredAt.any { it.code < 0x20 || it.code == 0x7f }
            ) {
                continue
            }
            result += OfficeRestoredDocument(
                restoreID = restoreID,
                documentID = id.toString(),
                fileName = fileName,
                displayName = displayName.take(240),
                format = format,
                kind = kind,
                byteCount = bytes,
                sha256 = sha,
            )
        }
        return result
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buffer = ByteArray(1 shl 20)
            var readTotal = 0L
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                if (read == 0) continue
                readTotal += read
                if (readTotal > MAX_OFFICE_RECOVERY_BYTES) {
                    throw IllegalStateException("documentTooLarge")
                }
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }
}

/** Host half of the read-only preview of one restored document. */
internal sealed class OfficeRestoredOpenResult {
    data class Accepted(val sessionToken: String) : OfficeRestoredOpenResult()
    data class Refused(val code: String) : OfficeRestoredOpenResult()
}

internal interface OfficeRestoredDocumentOpenPort {
    fun open(
        document: OfficeRestoredDocument,
        path: File,
        observedSha256: String,
        observedBytes: Long,
    ): OfficeRestoredOpenResult
}
