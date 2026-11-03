// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.networkcapture

import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.nio.file.Files
import java.security.MessageDigest
import java.util.UUID
import org.json.JSONObject

/**
 * A retained raw capture as described by its own manifest. Only a session UUID
 * is accepted as an identity; no path, display name or model string can select
 * a source file. [file] is always canonical and contained by the store root.
 */
data class RawCaptureRecord(
    val sessionId: String,
    val mode: CaptureMode,
    val createdAtMillis: Long,
    val endedAtMillis: Long?,
    val bytes: Long,
    val sha256: String,
    val partial: Boolean,
    val detailed: Boolean,
    val endReason: String?,
    val file: File,
    val manifestFile: File,
) {
    init {
        require(runCatching { UUID.fromString(sessionId) }.isSuccess) { "sessionId" }
        require(bytes >= 0) { "bytes" }
        require(sha256.matches(Regex("^[0-9a-f]{64}$"))) { "sha256" }
    }
}

data class RawCaptureListing(
    val records: List<RawCaptureRecord>,
    val invalid: Int,
)

/**
 * Read-only projection of App-private `capture-<uuid>*.pcap` files.
 *
 * A record is visible only when its exact manifest, filename, size, digest
 * shape and canonical containment agree. A malformed/traversed manifest is
 * counted as invalid and never becomes a selectable export source.
 */
class RawCaptureLibrary(private val rootDirectory: File) {

    private val filePattern = Regex(
        "^capture-([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-" +
            "[0-9a-fA-F]{4}-[0-9a-fA-F]{12})(-partial)?\\.pcap$",
    )
    private val manifestPattern = Regex(
        "^capture-([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-" +
            "[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\\.json$",
    )

    fun list(): RawCaptureListing {
        val canonicalRoot = runCatching { rootDirectory.canonicalFile }.getOrNull()
            ?: return RawCaptureListing(emptyList(), 0)
        if (!canonicalRoot.isDirectory) return RawCaptureListing(emptyList(), 0)
        val files = canonicalRoot.listFiles().orEmpty()
            .filter { it.isFile && filePattern.matches(it.name) }
        val records = ArrayList<RawCaptureRecord>(files.size)
        var invalid = 0
        for (file in files) {
            val record = runCatching { recordFor(file, canonicalRoot) }.getOrNull()
            if (record == null) invalid += 1 else records += record
        }
        // A manifest without a pcap is stale, not a selectable record. Count
        // each broken artifact once, not again because it was also invalid.
        val pcapIds = files.mapNotNull {
            filePattern.matchEntire(it.name)?.groupValues?.get(1)?.lowercase()
        }.toSet()
        invalid += canonicalRoot.listFiles().orEmpty().count { file ->
            val id = manifestPattern.matchEntire(file.name)?.groupValues?.get(1)?.lowercase()
            file.isFile && id != null && id !in pcapIds
        }
        return RawCaptureListing(
            records = records.sortedByDescending { it.createdAtMillis },
            invalid = invalid,
        )
    }

    fun find(sessionId: String): RawCaptureRecord? {
        if (!runCatching { UUID.fromString(sessionId) }.isSuccess) return null
        val canonicalRoot = runCatching { rootDirectory.canonicalFile }.getOrNull() ?: return null
        if (!canonicalRoot.isDirectory) return null
        val complete = File(canonicalRoot, "capture-$sessionId.pcap")
        val partial = File(canonicalRoot, "capture-$sessionId-partial.pcap")
        val file = when {
            complete.isFile -> complete
            partial.isFile -> partial
            else -> return null
        }
        return runCatching { recordFor(file, canonicalRoot) }.getOrNull()
    }

    private fun recordFor(file: File, canonicalRoot: File): RawCaptureRecord {
        require(Files.isSymbolicLink(file.toPath()).not()) { "symlink" }
        val canonicalFile = file.canonicalFile
        require(canonicalFile.parentFile == canonicalRoot) { "outside store" }
        require(canonicalFile.isFile) { "not a file" }
        val match = filePattern.matchEntire(file.name) ?: throw IOException("name")
        val sessionId = match.groupValues[1].lowercase()
        val partialSuffix = match.groupValues[2].isNotEmpty()
        val manifest = File(canonicalRoot, "capture-$sessionId.json")
        require(manifest.isFile && !Files.isSymbolicLink(manifest.toPath())) { "manifest" }
        val canonicalManifest = manifest.canonicalFile
        require(canonicalManifest.parentFile == canonicalRoot) { "manifest outside store" }
        val json = JSONObject(canonicalManifest.readText(Charsets.UTF_8))
        require(json.getString("schema") == SCHEMA) { "schema" }
        require(json.getString("sessionId").equals(sessionId, ignoreCase = true)) { "session" }
        require(json.getString("file") == file.name) { "file binding" }
        require(json.getLong("bytes") == canonicalFile.length()) { "size drift" }
        require(json.getString("sha256").matches(Regex("^[0-9a-f]{64}$"))) { "digest" }
        val complete = json.getBoolean("complete")
        require(complete != partialSuffix) { "completion marker" }
        val mode = when (json.getString("mode")) {
            CaptureMode.VPN.wire -> CaptureMode.VPN
            CaptureMode.ROOT.wire -> CaptureMode.ROOT
            else -> throw IOException("mode")
        }
        val createdAt = json.getLong("createdAt")
        require(createdAt > 0) { "createdAt" }
        val owner = json.getJSONObject("owner")
        require(owner.getString("ownerId").isNotBlank()) { "owner" }
        require(owner.getLong("nativeEpoch") > 0) { "owner epoch" }
        return RawCaptureRecord(
            sessionId = sessionId,
            mode = mode,
            createdAtMillis = createdAt,
            endedAtMillis = json.optLong("endedAt").takeIf { it > 0 },
            bytes = canonicalFile.length(),
            sha256 = json.getString("sha256"),
            partial = !complete,
            detailed = json.optBoolean("detailed", false),
            endReason = json.optString("endReason").takeIf { it.isNotEmpty() && it != "null" },
            file = canonicalFile,
            manifestFile = canonicalManifest,
        )
    }

    companion object {
        const val SCHEMA = "floe.capture-artifact.v1"
    }
}

/** SAF/host write seam. The core exporter never resolves a path or URI. */
interface RawExportSink {
    fun openDestination(): OutputStream
    fun openDestinationForRead(): InputStream

    /** Deletes only the destination this export attempt created, when safe. */
    fun deleteCreatedDestination(): Boolean
}

data class RawCaptureExportReceipt(
    val sessionId: String,
    val displayName: String,
    val bytes: Long,
    val sha256: String,
    val partial: Boolean,
    val exportedAtMillis: Long,
)

sealed interface RawExportOutcome {
    data class Success(val receipt: RawCaptureExportReceipt) : RawExportOutcome
    data class Failed(val code: String) : RawExportOutcome
    data object Cancelled : RawExportOutcome
}

/**
 * Bounded, verifying copy of one retained raw capture.
 *
 * The source is opened read-only and hashed while it is copied. Success
 * requires: source size/digest match the manifest, the destination accepts
 * every byte, cancellation never fired, and a fresh destination read-back has
 * the same exact size and SHA-256. A failed/cancelled attempt removes only the
 * newly created destination (never the original capture).
 */
class RawCaptureExporter(
    private val chunkBytes: Int = CaptureLimits.RAW_EXPORT_CHUNK_BYTES,
    private val sourceOpener: (File) -> InputStream = { FileInputStream(it) },
    private val clock: () -> Long = System::currentTimeMillis,
) {
    init {
        require(chunkBytes in 4 * 1024..1024 * 1024) { "chunkBytes" }
    }

    fun export(
        record: RawCaptureRecord,
        sink: RawExportSink,
        displayName: String,
        checkCancelled: () -> Boolean = { false },
        onProgress: (Long, Long) -> Unit = { _, _ -> },
    ): RawExportOutcome {
        if (record.bytes > CaptureLimits.MAX_BYTES) {
            return RawExportOutcome.Failed("captureTooLarge")
        }
        if (!record.file.isFile || Files.isSymbolicLink(record.file.toPath())) {
            return RawExportOutcome.Failed("sourceUnavailable")
        }
        if (checkCancelled()) return RawExportOutcome.Cancelled
        val destination = try {
            sink.openDestination()
        } catch (_: Throwable) {
            return RawExportOutcome.Failed("destinationUnavailable")
        }
        // From this point the destination document exists for this attempt.
        // A failed/cancelled copy removes that exact new document only.
        var wrote = true
        var sourceDigest = ""
        var copied = 0L
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            sourceOpener(record.file).use { input ->
                val buffer = ByteArray(chunkBytes)
                while (true) {
                    if (checkCancelled()) {
                        cleanup(destination, sink, wrote)
                        return RawExportOutcome.Cancelled
                    }
                    val read = input.read(buffer)
                    if (read < 0) break
                    if (read == 0) continue
                    copied += read
                    if (copied > record.bytes) {
                        cleanup(destination, sink, wrote = true)
                        return RawExportOutcome.Failed("sourceChanged")
                    }
                    digest.update(buffer, 0, read)
                    try {
                        destination.write(buffer, 0, read)
                        wrote = true
                    } catch (_: IOException) {
                        cleanup(destination, sink, wrote)
                        return RawExportOutcome.Failed("destinationWriteFailed")
                    }
                    onProgress(copied, record.bytes)
                }
                destination.flush()
            }
            sourceDigest = digest.digest().joinToString("") { "%02x".format(it) }
        } catch (_: Throwable) {
            cleanup(destination, sink, wrote)
            return RawExportOutcome.Failed("sourceReadFailed")
        } finally {
            runCatching { destination.close() }
        }
        if (checkCancelled()) {
            cleanupAlreadyClosed(sink, wrote)
            return RawExportOutcome.Cancelled
        }
        if (copied != record.bytes) {
            cleanupAlreadyClosed(sink, wrote)
            return RawExportOutcome.Failed("sourceChanged")
        }
        if (sourceDigest != record.sha256) {
            cleanupAlreadyClosed(sink, wrote)
            return RawExportOutcome.Failed("sourceDigestMismatch")
        }
        val verified = try {
            verifyDestination(
                sink = sink,
                expectedBytes = copied,
                expectedDigest = sourceDigest,
                checkCancelled = checkCancelled,
            )
        } catch (_: Throwable) {
            false
        }
        if (verified != true) {
            cleanupAlreadyClosed(sink, wrote)
            return if (checkCancelled()) RawExportOutcome.Cancelled
            else RawExportOutcome.Failed("destinationVerifyFailed")
        }
        return RawExportOutcome.Success(
            RawCaptureExportReceipt(
                sessionId = record.sessionId,
                displayName = displayName,
                bytes = copied,
                sha256 = sourceDigest,
                partial = record.partial,
                exportedAtMillis = clock(),
            ),
        )
    }

    private fun verifyDestination(
        sink: RawExportSink,
        expectedBytes: Long,
        expectedDigest: String,
        checkCancelled: () -> Boolean,
    ): Boolean {
        val digest = MessageDigest.getInstance("SHA-256")
        var total = 0L
        sink.openDestinationForRead().use { input ->
            val buffer = ByteArray(chunkBytes)
            while (true) {
                if (checkCancelled()) return false
                val read = input.read(buffer)
                if (read < 0) break
                if (read == 0) continue
                total += read
                if (total > expectedBytes) return false
                digest.update(buffer, 0, read)
            }
        }
        return total == expectedBytes &&
            digest.digest().joinToString("") { "%02x".format(it) } == expectedDigest
    }

    private fun cleanup(destination: OutputStream, sink: RawExportSink, wrote: Boolean) {
        runCatching { destination.close() }
        cleanupAlreadyClosed(sink, wrote)
    }

    private fun cleanupAlreadyClosed(sink: RawExportSink, wrote: Boolean) {
        if (wrote) runCatching { sink.deleteCreatedDestination() }
    }
}
