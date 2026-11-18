// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.UUID
import org.json.JSONObject

/**
 * Full-only writer for the ONE real screenshot artifact root minted by the
 * trusted platform mailbox (`<live owned root>/FloeAgent`).
 *
 * The model never receives a host path: only the existing `VNCArtifacts/`
 * namespace, MIME type, byte count and SHA-256 are returned, and the Swift
 * bridge re-reads/re-verifies the bytes before they can become model-visible
 * image evidence. There is no temp/HOME/first-project fallback: when the actual
 * root getter is null or fenced, the write fails closed.
 */
internal object PlatformArtifactWriter {

    /** Only this writer's long-expired app-cache stages are disposable. */
    fun cleanupExpiredStages(privateDirectory: File, now: Long = System.currentTimeMillis()) {
        val cutoff = now - 24L * 60 * 60 * 1000
        privateDirectory.listFiles()?.forEach { file ->
            if (file.name.startsWith("floe-private-shot-") && file.name.endsWith(".tmp") &&
                file.isFile && file.lastModified() in 1 until cutoff) {
                runCatching { file.delete() }
            }
        }
    }

    data class Artifact(
        val relativePath: String,
        val mimeType: String,
        val byteCount: Int,
        val sha256: String,
    ) {
        fun toJson(): JSONObject = JSONObject()
            .put("relativePath", relativePath)
            .put("mimeType", mimeType)
            .put("byteCount", byteCount)
            .put("sha256", sha256)
    }

    sealed interface Result {
        data class Ok(val artifact: Artifact) : Result
        data class Failed(val code: String) : Result
    }

    sealed interface Preparation {
        data class Ready(val stage: PrivateStage) : Preparation
        data class Failed(val code: String) : Preparation
    }

    /** Prepared entirely in the caller's app-private cache; no public artifact yet. */
    class PrivateStage internal constructor(
        private val temporary: File, private val directory: File, private val name: String,
        private val mimeType: String, private val size: Int, private val digest: ByteArray,
    ) : AutoCloseable {
        private var consumed = false

        /** Caller must hold the live consent/teardown fences across this commit. */
        fun commit(): Result {
            if (consumed) return Result.Failed("artifact_stage_consumed")
            consumed = true
            val target = File(directory, name)
            try {
                if (target.exists()) return Result.Failed("artifact_commit")
                // A same-filesystem rename is the only publication point.
                // A different volume fails closed instead of copying sensitive
                // bytes to the visible namespace outside the commit fence.
                if (!temporary.renameTo(target)) return Result.Failed("artifact_commit")
                return Result.Ok(Artifact("VNCArtifacts/$name", mimeType, size,
                    digest.joinToString("") { "%02x".format(it) }))
            } catch (_: Throwable) {
                return Result.Failed("artifact_write")
            } finally {
                runCatching { temporary.delete() }
            }
        }

        override fun close() { runCatching { temporary.delete() } }
    }

    fun prepare(privateDirectory: File, artifactRoot: String?, bytes: ByteArray, mimeType: String): Preparation {
        if (artifactRoot.isNullOrBlank() || !artifactRoot.startsWith("/")) return Preparation.Failed("artifact_root_unbound")
        if (bytes.isEmpty()) return Preparation.Failed("artifact_empty")
        val extension = when (mimeType) { "image/png" -> "png"; "image/jpeg" -> "jpg"; else -> return Preparation.Failed("artifact_mime") }
        if (!hasImageSignature(bytes, mimeType)) return Preparation.Failed("artifact_signature")
        val root = try { File(artifactRoot).canonicalFile } catch (_: Throwable) { return Preparation.Failed("artifact_root_unbound") }
        val directory = File(root, "VNCArtifacts")
        if ((!directory.exists() && !directory.mkdirs()) || !directory.isDirectory) return Preparation.Failed("artifact_directory")
        val canonical = try { directory.canonicalFile } catch (_: Throwable) { return Preparation.Failed("artifact_directory") }
        if (!canonical.path.startsWith(root.path.trimEnd('/') + "/")) return Preparation.Failed("artifact_escape")
        val temporary = try { File.createTempFile("floe-private-shot-", ".tmp", privateDirectory) }
            catch (_: Throwable) { return Preparation.Failed("artifact_create") }
        var ready = false
        try {
            FileOutputStream(temporary).use { output -> output.write(bytes); output.flush(); output.fd.sync() }
            val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
            val actual = temporary.readBytes()
            try {
                if (actual.size != bytes.size || !MessageDigest.getInstance("SHA-256").digest(actual).contentEquals(digest) ||
                    !hasImageSignature(actual, mimeType)) return Preparation.Failed("artifact_verify")
            } finally { actual.fill(0) }
            ready = true
            return Preparation.Ready(PrivateStage(temporary, canonical,
                UUID.randomUUID().toString() + "." + extension, mimeType, bytes.size, digest))
        } catch (_: Throwable) {
            return Preparation.Failed("artifact_write")
        } finally {
            if (!ready) runCatching { temporary.delete() }
        }
    }

    /**
     * Writes [bytes] under `<artifactRoot>/VNCArtifacts/<uuid>.<ext>` with an
     * atomic rename, fsync and a digest/size re-read of the committed file.
     * The caller-owned byte array is wiped by the caller after this returns.
     */
    fun write(
        artifactRoot: String?,
        bytes: ByteArray,
        mimeType: String,
    ): Result {
        if (artifactRoot.isNullOrBlank() || !artifactRoot.startsWith("/")) {
            return Result.Failed("artifact_root_unbound")
        }
        if (bytes.isEmpty()) return Result.Failed("artifact_empty")
        val extension = when (mimeType) {
            "image/png" -> "png"
            "image/jpeg" -> "jpg"
            else -> return Result.Failed("artifact_mime")
        }
        if (!hasImageSignature(bytes, mimeType)) {
            return Result.Failed("artifact_signature")
        }
        val root = try {
            File(artifactRoot).canonicalFile
        } catch (_: Throwable) {
            return Result.Failed("artifact_root_unbound")
        }
        val directory = File(root, "VNCArtifacts")
        if (!directory.exists() && !directory.mkdirs()) {
            return Result.Failed("artifact_directory")
        }
        if (!directory.isDirectory) return Result.Failed("artifact_directory")
        val canonicalDirectory = try {
            directory.canonicalFile
        } catch (_: Throwable) {
            return Result.Failed("artifact_directory")
        }
        if (!canonicalDirectory.path.startsWith(root.path.trimEnd('/') + "/")) {
            return Result.Failed("artifact_escape")
        }
        val name = UUID.randomUUID().toString() + "." + extension
        val target = File(canonicalDirectory, name)
        val temporary = try {
            File.createTempFile("shot-", ".tmp", canonicalDirectory)
        } catch (_: Throwable) {
            return Result.Failed("artifact_create")
        }
        var committed = false
        try {
            FileOutputStream(temporary).use { output ->
                output.write(bytes)
                output.flush()
                output.fd.sync()
            }
            val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
            if (temporary.length() != bytes.size.toLong()) {
                return Result.Failed("artifact_write")
            }
            if (!temporary.renameTo(target)) return Result.Failed("artifact_commit")
            committed = true
            val actual = target.readBytes()
            if (actual.size != bytes.size) return Result.Failed("artifact_verify")
            val actualDigest = MessageDigest.getInstance("SHA-256").digest(actual)
            if (!actualDigest.contentEquals(digest)) return Result.Failed("artifact_verify")
            if (!hasImageSignature(actual, mimeType)) return Result.Failed("artifact_verify")
            return Result.Ok(
                Artifact(
                    relativePath = "VNCArtifacts/$name",
                    mimeType = mimeType,
                    byteCount = actual.size,
                    sha256 = digest.joinToString("") { "%02x".format(it) },
                ),
            )
        } catch (_: Throwable) {
            return Result.Failed("artifact_write")
        } finally {
            if (!committed) runCatching { temporary.delete() }
        }
    }

    private fun hasImageSignature(bytes: ByteArray, mimeType: String): Boolean =
        when (mimeType) {
            "image/png" -> bytes.size > 8 &&
                bytes[0] == 0x89.toByte() && bytes[1] == 0x50.toByte() &&
                bytes[2] == 0x4E.toByte() && bytes[3] == 0x47.toByte() &&
                bytes[4] == 0x0D.toByte() && bytes[5] == 0x0A.toByte() &&
                bytes[6] == 0x1A.toByte() && bytes[7] == 0x0A.toByte()
            "image/jpeg" -> bytes.size > 3 &&
                bytes[0] == 0xFF.toByte() && bytes[1] == 0xD8.toByte() &&
                bytes[bytes.size - 2] == 0xFF.toByte() &&
                bytes[bytes.size - 1] == 0xD9.toByte()
            else -> false
        }
}
