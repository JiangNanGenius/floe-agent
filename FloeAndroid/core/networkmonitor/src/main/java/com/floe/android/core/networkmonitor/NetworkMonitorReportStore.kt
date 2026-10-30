// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.networkmonitor

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.security.MessageDigest
import java.util.UUID
import org.json.JSONObject

data class NetworkMonitorReportFiles(
    val reportId: String,
    val directory: File,
    val jsonFile: File,
    val markdownFile: File,
    val manifestFile: File,
)

/**
 * Publishes a report pair by renaming one fully synced staging directory. Readers see either no
 * report or JSON+Markdown+manifest together. Existing final exports are never overwritten.
 */
class NetworkMonitorReportStore internal constructor(
    private val rootDirectory: File,
    private val fileOperations: NetworkMonitorFileOperations,
    private val stagingIdFactory: () -> String,
) {
    constructor(rootDirectory: File) : this(
        rootDirectory = rootDirectory,
        fileOperations = PlatformNetworkMonitorFileOperations,
        stagingIdFactory = { UUID.randomUUID().toString() },
    )

    fun write(reportId: String, document: NetworkMonitorReportDocument): NetworkMonitorReportFiles {
        require(runCatching { UUID.fromString(reportId) }.isSuccess) { "reportId must be a UUID" }
        val finalDirectory = File(rootDirectory, "network-monitor-$reportId")
        if (finalDirectory.exists()) throw IOException("reportAlreadyExists")
        if (!rootDirectory.isDirectory && !rootDirectory.mkdirs()) throw IOException("reportDirectoryUnavailable")
        if (!rootDirectory.isDirectory) throw IOException("reportDirectoryUnavailable")
        val stagingDirectory = File(
            rootDirectory,
            ".network-monitor-$reportId.staging-${newMonitorId(stagingIdFactory)}",
        )
        var stagingCreated = false
        var published = false
        try {
            fileOperations.createDirectory(stagingDirectory)
            stagingCreated = true
            val stagedJson = File(stagingDirectory, "report.json")
            val stagedMarkdown = File(stagingDirectory, "report.md")
            val jsonBytes = document.json.toByteArray(Charsets.UTF_8)
            val markdownBytes = document.markdown.toByteArray(Charsets.UTF_8)
            fileOperations.writeAndSync(stagedJson, jsonBytes)
            fileOperations.writeAndSync(stagedMarkdown, markdownBytes)
            val manifest = JSONObject()
                .put("schema", "floe.network-monitor-report-files.v1")
                .put("reportId", reportId)
                .put("files", JSONObject()
                    .put("report.json", fileManifest(jsonBytes))
                    .put("report.md", fileManifest(markdownBytes)))
                .toString(2)
            fileOperations.writeAndSync(
                File(stagingDirectory, "manifest.json"),
                manifest.toByteArray(Charsets.UTF_8),
            )
            // Same-parent directory rename is the single publication/commit operation.
            fileOperations.moveDirectory(stagingDirectory, finalDirectory)
            published = true
            return NetworkMonitorReportFiles(
                reportId = reportId,
                directory = finalDirectory,
                jsonFile = File(finalDirectory, "report.json"),
                markdownFile = File(finalDirectory, "report.md"),
                manifestFile = File(finalDirectory, "manifest.json"),
            )
        } finally {
            // A failed write only removes its own private staging directory; a prior export is intact.
            if (!published && stagingCreated) runCatching { fileOperations.deleteRecursively(stagingDirectory) }
        }
    }

    private fun fileManifest(bytes: ByteArray): JSONObject = JSONObject()
        .put("bytes", bytes.size)
        .put("sha256", MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) })
}

internal interface NetworkMonitorFileOperations {
    fun createDirectory(directory: File)
    fun writeAndSync(file: File, bytes: ByteArray)
    fun moveDirectory(source: File, destination: File)
    fun deleteRecursively(file: File)
}

internal object PlatformNetworkMonitorFileOperations : NetworkMonitorFileOperations {
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
        if (destination.exists() || !source.renameTo(destination)) throw IOException("reportCommitFailed")
    }

    override fun deleteRecursively(file: File) {
        if (file.exists() && !file.deleteRecursively()) throw IOException("stagingCleanupFailed")
    }
}
