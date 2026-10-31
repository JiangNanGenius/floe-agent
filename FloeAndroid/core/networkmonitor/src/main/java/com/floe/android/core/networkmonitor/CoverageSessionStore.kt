// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.networkmonitor

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.UUID
import org.json.JSONObject

data class CoverageStoredSession(
    val sessionID: String,
    val directory: File,
    val sessionFile: File,
    val manifestFile: File,
    val session: CoverageSession,
)

/**
 * App-private coverage sessions. New sessions are published by one directory
 * rename; edits replace session.json with an fsynced temp file and an atomic
 * rename. The optional floorplan is a bounded app-private image written the
 * same way. No arbitrary path ever enters this store.
 */
class CoverageSessionStore internal constructor(
    private val rootDirectory: File,
    private val fileOperations: CoverageFileOperations,
    private val stagingIdFactory: () -> String,
) {
    constructor(rootDirectory: File) : this(
        rootDirectory = rootDirectory,
        fileOperations = PlatformCoverageFileOperations,
        stagingIdFactory = { UUID.randomUUID().toString() },
    )

    fun save(session: CoverageSession): CoverageStoredSession {
        val json = CoverageSessionCodec.encode(session)
        val bytes = json.toByteArray(Charsets.UTF_8)
        val finalDirectory = File(rootDirectory, directoryName(session.sessionID))
        if (!finalDirectory.isDirectory) {
            if (!rootDirectory.isDirectory && !rootDirectory.mkdirs()) {
                throw IOException("coverageDirectoryUnavailable")
            }
            val staging = File(rootDirectory, ".coverage-${session.sessionID}.staging-${stagingIdFactory()}")
            var created = false
            var published = false
            try {
                fileOperations.createDirectory(staging)
                created = true
                val sessionFile = File(staging, "session.json")
                fileOperations.writeAndSync(sessionFile, bytes)
                fileOperations.writeAndSync(
                    File(staging, "manifest.json"),
                    manifest(session.sessionID, bytes, null).toByteArray(Charsets.UTF_8),
                )
                fileOperations.moveDirectory(staging, finalDirectory)
                published = true
            } finally {
                if (!published && created) runCatching { fileOperations.deleteRecursively(staging) }
            }
        } else {
            val sessionFile = File(finalDirectory, "session.json")
            val manifestFile = File(finalDirectory, "manifest.json")
            fileOperations.writeAtomically(sessionFile, bytes)
            val floorplanHash = session.floorplan?.sha256
            fileOperations.writeAtomically(
                manifestFile,
                manifest(session.sessionID, bytes, floorplanHash).toByteArray(Charsets.UTF_8),
            )
        }
        return CoverageStoredSession(
            sessionID = session.sessionID,
            directory = finalDirectory,
            sessionFile = File(finalDirectory, "session.json"),
            manifestFile = File(finalDirectory, "manifest.json"),
            session = session,
        )
    }

    fun load(sessionID: String): CoverageSession? {
        validateId(sessionID)
        val directory = File(rootDirectory, directoryName(sessionID))
        if (!directory.isDirectory) return null
        val file = File(directory, "session.json")
        if (!file.isFile || file.length() > CoverageLimits.MAX_SESSION_JSON_BYTES) return null
        val json = runCatching { file.readBytes().toString(Charsets.UTF_8) }.getOrNull() ?: return null
        return runCatching { CoverageSessionCodec.decode(json) }.getOrNull()
            ?.takeIf { it.sessionID == sessionID }
    }

    fun list(limit: Int = CoverageLimits.MAX_SESSIONS): List<CoverageSession> {
        val directories = rootDirectory.listFiles()
            ?.filter { it.isDirectory && it.name.startsWith("coverage-") }
            ?.sortedByDescending { it.lastModified() }
            ?.take(limit.coerceIn(1, CoverageLimits.MAX_SESSIONS))
            .orEmpty()
        return directories.mapNotNull { directory ->
            val id = directory.name.removePrefix("coverage-")
            runCatching { load(id) }.getOrNull()
        }
    }

    fun delete(sessionID: String): Boolean {
        validateId(sessionID)
        val directory = File(rootDirectory, directoryName(sessionID))
        if (!directory.exists()) return false
        fileOperations.deleteRecursively(directory)
        return !directory.exists()
    }

    /**
     * Stores one explicit floorplan image and updates the session atomically
     * afterwards. The image file is written first; a failure to update the
     * session leaves only an unreferenced private file, never a session that
     * points at a missing image.
     */
    fun saveFloorplan(
        sessionID: String,
        bytes: ByteArray,
        mimeType: String,
        width: Int,
        height: Int,
        importedAtEpochMillis: Long = System.currentTimeMillis(),
    ): CoverageSession {
        require(bytes.isNotEmpty() && bytes.size <= CoverageLimits.MAX_FLOORPLAN_BYTES) {
            "floorplan image must be 1 byte .. 8 MiB"
        }
        require(mimeType in setOf("image/png", "image/jpeg", "image/webp")) { "unsupported floorplan type" }
        val session = load(sessionID) ?: throw IOException("coverageSessionNotFound")
        val directory = File(rootDirectory, directoryName(sessionID))
        if (!directory.isDirectory) throw IOException("coverageSessionNotFound")
        val image = File(directory, FLOORPLAN_FILE)
        fileOperations.writeAtomically(image, bytes)
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it) }
        val updated = session.copy(
            floorplan = CoverageFloorplan(
                width = width,
                height = height,
                mimeType = mimeType,
                byteCount = bytes.size.toLong(),
                sha256 = digest,
                importedAtEpochMillis = importedAtEpochMillis,
            ),
            updatedAtEpochMillis = maxOf(session.updatedAtEpochMillis, importedAtEpochMillis),
        )
        save(updated)
        return updated
    }

    fun readFloorplan(sessionID: String): ByteArray? {
        validateId(sessionID)
        val session = load(sessionID) ?: return null
        val metadata = session.floorplan ?: return null
        val file = File(rootDirectory, directoryName(sessionID) + File.separator + FLOORPLAN_FILE)
        if (!file.isFile || file.length() != metadata.byteCount ||
            file.length() > CoverageLimits.MAX_FLOORPLAN_BYTES) return null
        val bytes = runCatching { file.readBytes() }.getOrNull() ?: return null
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it) }
        return if (digest == metadata.sha256) bytes else null
    }

    private fun manifest(sessionID: String, bytes: ByteArray, floorplanHash: String?): String = JSONObject()
        .put("schema", "floe.network-coverage-files.v1")
        .put("sessionID", sessionID)
        .put("sessionBytes", bytes.size)
        .put("sessionSha256", MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it) })
        .put("floorplanFile", if (floorplanHash == null) JSONObject.NULL else FLOORPLAN_FILE)
        .put("floorplanSha256", floorplanHash ?: JSONObject.NULL)
        .toString(2)

    private fun validateId(sessionID: String) {
        require(runCatching { UUID.fromString(sessionID) }.isSuccess) { "sessionID must be a UUID" }
    }

    private fun directoryName(sessionID: String): String = "coverage-$sessionID"

    private companion object {
        const val FLOORPLAN_FILE = "floorplan.img"
    }
}

internal interface CoverageFileOperations {
    fun createDirectory(directory: File)
    fun writeAndSync(file: File, bytes: ByteArray)
    fun moveDirectory(source: File, destination: File)
    fun writeAtomically(destination: File, bytes: ByteArray)
    fun deleteRecursively(file: File)
}

internal object PlatformCoverageFileOperations : CoverageFileOperations {
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
        if (destination.exists() || !source.renameTo(destination)) {
            throw IOException("coverageCommitFailed")
        }
    }

    override fun writeAtomically(destination: File, bytes: ByteArray) {
        val temporary = File(destination.parentFile, ".${destination.name}.tmp-${UUID.randomUUID()}")
        try {
            writeAndSync(temporary, bytes)
            try {
                Files.move(
                    temporary.toPath(), destination.toPath(),
                    StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE,
                )
            } catch (_: java.nio.file.AtomicMoveNotSupportedException) {
                Files.move(
                    temporary.toPath(), destination.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                )
            }
        } finally {
            if (temporary.exists()) runCatching { temporary.delete() }
        }
    }

    override fun deleteRecursively(file: File) {
        if (file.exists() && !file.deleteRecursively()) throw IOException("coverageCleanupFailed")
    }
}
