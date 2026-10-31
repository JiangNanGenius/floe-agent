// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.pcap

import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.security.MessageDigest
import java.util.UUID
import org.json.JSONObject

data class PcapStoredAnalysis(
    val analysisID: String,
    val directory: File,
    val summaryFile: File,
    val manifestFile: File,
    val json: String,
    /** Workspace-scoped UI analyses have no task; a task-scoped artifact keeps its owner. */
    val ownerTaskId: String? = null,
    val ownerWorkspaceId: String? = null,
    /** Explicit user grant: Agent tools may read this artifact (never a file grant). */
    val agentReadable: Boolean = false,
)

/**
 * App-private, atomically published summaries keyed by an opaque analysis ID.
 * A directory rename is the only publication step: readers see either no
 * analysis or summary+manifest together. Raw capture bytes are never accepted
 * here; the App host deletes its temporary copy before/after publishing.
 */
class PcapAnalysisStore internal constructor(
    private val rootDirectory: File,
    private val fileOperations: PcapFileOperations,
    private val stagingIdFactory: () -> String,
) {
    constructor(rootDirectory: File) : this(
        rootDirectory = rootDirectory,
        fileOperations = PlatformPcapFileOperations,
        stagingIdFactory = { UUID.randomUUID().toString() },
    )

    fun write(
        summary: PcapSummary,
        ownerTaskId: String? = null,
        ownerWorkspaceId: String? = null,
        agentReadable: Boolean = false,
    ): PcapStoredAnalysis {
        require(ownerTaskId == null || (ownerTaskId.isNotBlank() && ownerTaskId.length <= 64 &&
            ownerTaskId.none { it.code < 0x20 || it.code == 0x7f })) { "ownerTaskId bounded" }
        require(ownerWorkspaceId == null || (ownerWorkspaceId.isNotBlank() &&
            ownerWorkspaceId.length <= 128 &&
            ownerWorkspaceId.none { it.code < 0x20 || it.code == 0x7f })) {
            "ownerWorkspaceId bounded"
        }
        val json = PcapSummaryCodec.encode(summary)
        val bytes = json.toByteArray(Charsets.UTF_8)
        val analysisID = summary.analysisID
        val finalDirectory = File(rootDirectory, directoryName(analysisID))
        if (finalDirectory.exists()) throw IOException("analysisAlreadyExists")
        if (!rootDirectory.isDirectory && !rootDirectory.mkdirs()) {
            throw IOException("analysisDirectoryUnavailable")
        }
        if (!rootDirectory.isDirectory) throw IOException("analysisDirectoryUnavailable")
        val staging = File(
            rootDirectory,
            ".pcap-$analysisID.staging-${stagingIdFactory()}",
        )
        var stagingCreated = false
        var published = false
        try {
            fileOperations.createDirectory(staging)
            stagingCreated = true
            val summaryFile = File(staging, "summary.json")
            val manifestFile = File(staging, "manifest.json")
            fileOperations.writeAndSync(summaryFile, bytes)
            val manifest = JSONObject()
                .put("schema", "floe.pcap-analysis-files.v1")
                .put("analysisID", analysisID)
                .put("bytes", bytes.size)
                .put("sha256", MessageDigest.getInstance("SHA-256").digest(bytes)
                    .joinToString("") { "%02x".format(it) })
                .put("ownerTaskId", ownerTaskId ?: JSONObject.NULL)
                .put("ownerWorkspaceId", ownerWorkspaceId ?: JSONObject.NULL)
                .put("agentReadable", agentReadable)
                .toString(2)
            fileOperations.writeAndSync(manifestFile, manifest.toByteArray(Charsets.UTF_8))
            fileOperations.moveDirectory(staging, finalDirectory)
            published = true
            return PcapStoredAnalysis(
                analysisID = analysisID,
                directory = finalDirectory,
                summaryFile = File(finalDirectory, "summary.json"),
                manifestFile = File(finalDirectory, "manifest.json"),
                json = json,
                ownerTaskId = ownerTaskId,
                ownerWorkspaceId = ownerWorkspaceId,
                agentReadable = agentReadable,
            )
        } finally {
            if (!published && stagingCreated) runCatching { fileOperations.deleteRecursively(staging) }
        }
    }

    fun read(analysisID: String): PcapStoredAnalysis? {
        validateId(analysisID)
        val directory = File(rootDirectory, directoryName(analysisID))
        if (!directory.isDirectory) return null
        val summary = File(directory, "summary.json")
        if (!summary.isFile || summary.length() > PcapLimits.MAX_RESULT_BYTES) return null
        val json = try {
            summary.readBytes().toString(Charsets.UTF_8)
        } catch (_: IOException) {
            return null
        }
        // Re-validate through the shared decoder so a partially written or
        // tampered file can never be projected as a real analysis.
        runCatching { PcapSummaryCodec.entry(json) }.getOrElse { return null }
        val manifest = runCatching {
            val file = File(directory, "manifest.json")
            if (!file.isFile || file.length() > 8_192) null
            else JSONObject(file.readText())
        }.getOrNull()
        val ownerTaskId = manifest?.opt("ownerTaskId")?.toString()
            ?.takeIf { it != "null" && it.length <= 64 }
        val ownerWorkspaceId = manifest?.opt("ownerWorkspaceId")?.toString()
            ?.takeIf { it != "null" && it.length <= 128 }
        val agentReadable = manifest?.optBoolean("agentReadable") == true
        return PcapStoredAnalysis(
            analysisID = analysisID,
            directory = directory,
            summaryFile = summary,
            manifestFile = File(directory, "manifest.json"),
            json = json,
            ownerTaskId = ownerTaskId,
            ownerWorkspaceId = ownerWorkspaceId,
            agentReadable = agentReadable,
        )
    }

    fun list(limit: Int = PcapLimits.MAX_STORED_ANALYSES): List<PcapStoredEntry> {
        val directories = rootDirectory.listFiles()
            ?.filter { it.isDirectory && it.name.startsWith("pcap-") }
            ?.sortedByDescending { it.lastModified() }
            ?.take(limit.coerceIn(1, PcapLimits.MAX_STORED_ANALYSES))
            .orEmpty()
        return directories.mapNotNull { directory ->
            val id = directory.name.removePrefix("pcap-")
            val stored = runCatching { read(id) }.getOrNull() ?: return@mapNotNull null
            runCatching { PcapSummaryCodec.entry(stored.json).copy(agentReadable = stored.agentReadable) }
                .getOrNull()
        }
    }

    /** Explicit user Agent-read grant; never implies any file/network permission. */
    fun setAgentReadable(analysisID: String, readable: Boolean): PcapStoredAnalysis? {
        validateId(analysisID)
        val directory = File(rootDirectory, directoryName(analysisID))
        if (!directory.isDirectory) return null
        val manifestFile = File(directory, "manifest.json")
        val manifest = runCatching {
            if (manifestFile.isFile && manifestFile.length() <= 8_192) {
                JSONObject(manifestFile.readText())
            } else {
                null
            }
        }.getOrNull() ?: return null
        manifest.put("agentReadable", readable)
        fileOperations.writeFileAtomically(manifestFile, manifest.toString(2).toByteArray(Charsets.UTF_8))
        return read(analysisID)
    }

    fun delete(analysisID: String): Boolean {
        validateId(analysisID)
        val directory = File(rootDirectory, directoryName(analysisID))
        if (!directory.exists()) return false
        fileOperations.deleteRecursively(directory)
        return !directory.exists()
    }

    private fun validateId(analysisID: String) {
        require(runCatching { UUID.fromString(analysisID) }.isSuccess) { "analysisID must be a UUID" }
    }

    private fun directoryName(analysisID: String): String = "pcap-$analysisID"
}

internal interface PcapFileOperations {
    fun createDirectory(directory: File)
    fun writeAndSync(file: File, bytes: ByteArray)
    fun moveDirectory(source: File, destination: File)
    fun writeFileAtomically(destination: File, bytes: ByteArray)
    fun deleteRecursively(file: File)
}

internal object PlatformPcapFileOperations : PcapFileOperations {
    override fun createDirectory(directory: File) {
        if (!directory.mkdir() || !directory.isDirectory) throw IOException("stagingDirectoryUnavailable")
    }

    override fun writeAndSync(file: File, bytes: ByteArray) {
        FileOutputStream(file, false).use { output ->
            output.write(bytes)
            output.flush()
            output.fd.sync()
        }
    }

    override fun moveDirectory(source: File, destination: File) {
        if (destination.exists() || !source.renameTo(destination)) throw IOException("analysisCommitFailed")
    }

    override fun writeFileAtomically(destination: File, bytes: ByteArray) {
        val temporary = File(destination.parentFile, ".${destination.name}.tmp-${UUID.randomUUID()}")
        try {
            writeAndSync(temporary, bytes)
            try {
                java.nio.file.Files.move(
                    temporary.toPath(), destination.toPath(),
                    java.nio.file.StandardCopyOption.REPLACE_EXISTING,
                    java.nio.file.StandardCopyOption.ATOMIC_MOVE,
                )
            } catch (_: java.nio.file.AtomicMoveNotSupportedException) {
                java.nio.file.Files.move(
                    temporary.toPath(), destination.toPath(),
                    java.nio.file.StandardCopyOption.REPLACE_EXISTING,
                )
            }
        } finally {
            if (temporary.exists()) runCatching { temporary.delete() }
        }
    }

    override fun deleteRecursively(file: File) {
        if (file.exists() && !file.deleteRecursively()) throw IOException("analysisCleanupFailed")
    }
}

internal fun readBoundedFile(file: File, limit: Long): ByteArray? {
    if (!file.isFile || file.length() <= 0 || file.length() > limit) return null
    return try {
        FileInputStream(file).use { input ->
            val bytes = ByteArray(file.length().toInt())
            var offset = 0
            while (offset < bytes.size) {
                val read = input.read(bytes, offset, bytes.size - offset)
                if (read < 0) break
                offset += read
            }
            if (offset == bytes.size) bytes else null
        }
    } catch (_: IOException) {
        null
    }
}
