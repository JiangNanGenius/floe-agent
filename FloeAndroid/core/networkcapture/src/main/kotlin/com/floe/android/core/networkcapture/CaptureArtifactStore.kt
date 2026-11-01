// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.networkcapture

import com.floe.android.core.pcap.PcapAnalysisOptions
import com.floe.android.core.pcap.PcapAnalysisStatus
import com.floe.android.core.pcap.PcapAnalyzer
import com.floe.android.core.pcap.PcapAnalysisStore
import com.floe.android.core.pcap.PcapCancellation
import com.floe.android.core.pcap.PcapSource
import com.floe.android.core.pcap.PcapLimits
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

data class CaptureArtifact(
    val sessionId: String,
    val owner: CaptureOwner,
    val mode: CaptureMode,
    val detailed: Boolean,
    val createdAtMillis: Long,
    val stagingFile: File,
    internal val output: FileOutputStream,
    val sink: PcapCaptureSink,
    val maxDurationMillis: Long,
) {
    init {
        require(runCatching { UUID.fromString(sessionId) }.isSuccess) { "sessionId must be a UUID" }
        require(maxDurationMillis > 0) { "duration" }
    }
}

data class RootCaptureArtifact(
    val sessionId: String,
    val owner: CaptureOwner,
    val createdAtMillis: Long,
    val stagingFile: File,
    internal val output: FileOutputStream,
    val maxDurationMillis: Long,
) {
    /** App-host write seam; the raw stream stays internal to this module. */
    fun write(bytes: ByteArray, offset: Int, length: Int) {
        output.write(bytes, offset, length)
    }

    fun flush() {
        output.flush()
    }
}

data class CaptureArtifactResult(
    val sessionId: String,
    val file: File,
    val bytes: Long,
    val sha256: String,
    val partial: Boolean,
    val manifestFile: File,
    val sink: CaptureSinkSummary,
)

data class CaptureAnalysisResult(
    val analysisId: String?,
    val failure: CaptureFailure?,
    val summaryStatus: PcapAnalysisStatus?,
    val limitations: List<String>,
)

/**
 * App-private raw capture files and manifests.
 *
 * The raw capture is kept because the user can re-analyze/export it later;
 * the existing PcapAnalysisStore receives only the bounded aggregate summary.
 * A capture that did not drain cleanly is published as a `-partial.pcap` with
 * an honest manifest; it is never renamed into the complete namespace.
 */
class CaptureArtifactStore(
    private val rootDirectory: File,
    private val clock: () -> Long = System::currentTimeMillis,
    private val idFactory: () -> String = { UUID.randomUUID().toString() },
    private val maxRetainedCaptures: Int = CaptureLimits.MAX_RETAINED_RAW_CAPTURES,
    private val maxRetainedBytes: Long = CaptureLimits.MAX_RETAINED_RAW_BYTES,
) {
    private val stagingDirectory = File(rootDirectory, "staging")
    private val liveStaging = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()

    fun begin(
        sessionId: String,
        owner: CaptureOwner,
        mode: CaptureMode,
        detailed: Boolean,
        maxBytes: Long,
        maxPackets: Long,
        maxDurationMillis: Long,
        nowEpochMicros: () -> Long = { System.currentTimeMillis() * 1_000L },
    ): CaptureArtifact {
        require(runCatching { UUID.fromString(sessionId) }.isSuccess) { "sessionId" }
        if (!stagingDirectory.isDirectory && !stagingDirectory.mkdirs()) {
            throw IOException("captureDirectoryUnavailable")
        }
        pruneRetention()
        val staging = File(stagingDirectory, ".capture-$sessionId.part")
        if (staging.exists()) throw IOException("captureAlreadyExists")
        liveStaging.add(staging.name)
        val output = try {
            FileOutputStream(staging, false)
        } catch (failure: Throwable) {
            liveStaging.remove(staging.name)
            throw failure
        }
        val sink = PcapCaptureSink(
            output = output,
            maxBytes = maxBytes,
            maxPackets = maxPackets,
            nowEpochMicros = nowEpochMicros,
        )
        return CaptureArtifact(
            sessionId = sessionId,
            owner = owner,
            mode = mode,
            detailed = detailed,
            createdAtMillis = clock(),
            stagingFile = staging,
            output = output,
            sink = sink,
            maxDurationMillis = maxDurationMillis,
        )
    }

    /**
     * Flush+fsync+close the staging file and publish either a complete or a
     * recoverable partial artifact. The caller must already have drained the
     * sink; [sink.drained] is the authority and a false result is preserved.
     */
    fun finalize(
        artifact: CaptureArtifact,
        sink: CaptureSinkSummary,
        state: CaptureState,
        startedAtMillis: Long?,
        endedAtMillis: Long,
        limitations: List<String>,
        stopProven: Boolean = true,
    ): CaptureArtifactResult {
        // The store must never fsync/close/rename bytes while the sink writer
        // still owns the output. The caller keeps the artifact/staging file
        // and retries the same drain; no second capture is created.
        if (artifact.sink.isWriterAlive()) {
            throw IOException("captureWriterStillOwnsArtifact")
        }
        // Preserve staging on a write/fsync failure; never publish a durable
        // success receipt after swallowing an I/O failure.
        try {
            artifact.sink.flushForTest()
            artifact.output.fd.sync()
        } finally {
            artifact.output.close()
        }
        val complete = stopProven && sink.drained && sink.failure == null
        val targetName = if (complete) {
            "capture-${artifact.sessionId}.pcap"
        } else {
            "capture-${artifact.sessionId}-partial.pcap"
        }
        val target = File(rootDirectory, targetName)
        if (!rootDirectory.isDirectory && !rootDirectory.mkdirs()) {
            throw IOException("captureDirectoryUnavailable")
        }
        try {
            Files.move(
                artifact.stagingFile.toPath(),
                target.toPath(),
                StandardCopyOption.ATOMIC_MOVE,
            )
        } catch (_: IOException) {
            Files.move(artifact.stagingFile.toPath(), target.toPath())
        }
        val bytes = target.length()
        val sha256 = sha256(target)
        val manifest = File(rootDirectory, "capture-${artifact.sessionId}.json")
        val manifestText = JSONObject()
            .put("schema", "floe.capture-artifact.v1")
            .put("sessionId", artifact.sessionId)
            .put("mode", artifact.mode.wire)
            .put("createdAt", artifact.createdAtMillis)
            .put("startedAt", startedAtMillis ?: JSONObject.NULL)
            .put("endedAt", endedAtMillis)
            .put("phase", state.phase.wire)
            .put("endReason", state.endReason?.wire ?: JSONObject.NULL)
            .put("complete", complete)
            .put("file", target.name)
            .put("bytes", bytes)
            .put("sha256", sha256)
            .put("owner", JSONObject().apply { artifact.owner.wire.forEach { (key, value) -> put(key, value) } })
            .put("detailed", artifact.detailed)
            .put("encryptedTrafficOnly", true)
            .put("ipv6Bypass", true)
            .put("sink", JSONObject()
                .put("writtenPackets", sink.writtenPackets)
                .put("writtenBytes", sink.writtenBytes)
                .put("capturedPackets", sink.capturedPackets)
                .put("capturedBytes", sink.capturedBytes)
                .put("droppedPackets", sink.droppedPackets)
                .put("droppedBytes", sink.droppedBytes)
                .put("unsupportedPackets", sink.unsupportedPackets)
                .put("ipv6BypassedPackets", sink.ipv6BypassedPackets)
                .put("limitReason", sink.limitReason?.wire ?: JSONObject.NULL)
                .put("drained", sink.drained)
                .put("failure", sink.failure?.code ?: JSONObject.NULL))
            .put("limitations", JSONArray(limitations))
            .toString(2)
        writeAtomically(manifest, manifestText.toByteArray(Charsets.UTF_8))
        liveStaging.remove(artifact.stagingFile.name)
        pruneRetention(keep = target.name)
        return CaptureArtifactResult(
            sessionId = artifact.sessionId,
            file = target,
            bytes = bytes,
            sha256 = sha256,
            partial = !complete,
            manifestFile = manifest,
            sink = sink,
        )
    }

    fun beginRoot(
        sessionId: String,
        owner: CaptureOwner,
        maxDurationMillis: Long,
    ): RootCaptureArtifact {
        require(runCatching { UUID.fromString(sessionId) }.isSuccess) { "sessionId" }
        require(maxDurationMillis > 0) { "duration" }
        if (!stagingDirectory.isDirectory && !stagingDirectory.mkdirs()) {
            throw IOException("captureDirectoryUnavailable")
        }
        pruneRetention()
        val staging = File(stagingDirectory, ".capture-$sessionId.part")
        if (staging.exists()) throw IOException("captureAlreadyExists")
        liveStaging.add(staging.name)
        val output = try {
            FileOutputStream(staging, false)
        } catch (failure: Throwable) {
            liveStaging.remove(staging.name)
            throw failure
        }
        return RootCaptureArtifact(
            sessionId = sessionId,
            owner = owner,
            createdAtMillis = clock(),
            stagingFile = staging,
            output = output,
            maxDurationMillis = maxDurationMillis,
        )
    }

    fun finalizeRoot(
        artifact: RootCaptureArtifact,
        progress: RootCaptureProgress,
        state: CaptureState,
        startedAtMillis: Long?,
        endedAtMillis: Long,
        limitations: List<String>,
        stopProven: Boolean = true,
        writerJoined: Boolean = true,
    ): CaptureArtifactResult {
        // The App owns this stream. Finalizing while the root read/write
        // coroutine is still appending would close a file under a live owner,
        // so the caller must prove the writer joined first.
        if (!writerJoined) throw IOException("captureWriterStillOwnsArtifact")
        try {
            artifact.output.fd.sync()
        } finally {
            artifact.output.close()
        }
        val complete = stopProven && progress.drainProven && !progress.malformed &&
            progress.bytes > PcapRecordWriter.GLOBAL_HEADER_BYTES &&
            progress.endReason !in setOf(
                CaptureEndReason.STOP_TIMEOUT,
                CaptureEndReason.DATA_PLANE_ERROR,
                CaptureEndReason.HELPER_UNAVAILABLE,
            )
        val targetName = if (complete) {
            "capture-${artifact.sessionId}.pcap"
        } else {
            "capture-${artifact.sessionId}-partial.pcap"
        }
        val target = File(rootDirectory, targetName)
        if (!rootDirectory.isDirectory && !rootDirectory.mkdirs()) {
            throw IOException("captureDirectoryUnavailable")
        }
        try {
            Files.move(
                artifact.stagingFile.toPath(),
                target.toPath(),
                StandardCopyOption.ATOMIC_MOVE,
            )
        } catch (_: IOException) {
            Files.move(artifact.stagingFile.toPath(), target.toPath())
        }
        val bytes = target.length()
        val sha256 = sha256(target)
        val sink = CaptureSinkSummary(
            writtenPackets = progress.packets,
            writtenBytes = progress.bytes,
            capturedPackets = progress.packets,
            capturedBytes = progress.bytes,
            droppedPackets = 0,
            droppedBytes = 0,
            truncatedPackets = 0,
            unsupportedPackets = 0,
            ipv6BypassedPackets = 0,
            limitReason = state.endReason?.takeIf {
                it == CaptureEndReason.SIZE_LIMIT || it == CaptureEndReason.PACKET_LIMIT ||
                    it == CaptureEndReason.DURATION_LIMIT
            },
            drained = true,
            failure = if (progress.malformed) CaptureFailure("pcapMalformed") else null,
        )
        val manifest = File(rootDirectory, "capture-${artifact.sessionId}.json")
        val manifestText = JSONObject()
            .put("schema", "floe.capture-artifact.v1")
            .put("sessionId", artifact.sessionId)
            .put("mode", CaptureMode.ROOT.wire)
            .put("createdAt", artifact.createdAtMillis)
            .put("startedAt", startedAtMillis ?: JSONObject.NULL)
            .put("endedAt", endedAtMillis)
            .put("phase", state.phase.wire)
            .put("endReason", state.endReason?.wire ?: JSONObject.NULL)
            .put("complete", complete)
            .put("file", target.name)
            .put("bytes", bytes)
            .put("sha256", sha256)
            .put("owner", JSONObject().apply { artifact.owner.wire.forEach { (key, value) -> put(key, value) } })
            .put("detailed", true)
            .put("encryptedTrafficOnly", true)
            .put("ipv6Bypass", false)
            .put("sink", JSONObject()
                .put("writtenPackets", sink.writtenPackets)
                .put("writtenBytes", sink.writtenBytes)
                .put("capturedPackets", sink.capturedPackets)
                .put("capturedBytes", sink.capturedBytes)
                .put("droppedPackets", 0)
                .put("droppedBytes", 0)
                .put("unsupportedPackets", 0)
                .put("ipv6BypassedPackets", 0)
                .put("limitReason", sink.limitReason?.wire ?: JSONObject.NULL)
                .put("drained", true)
                .put("failure", sink.failure?.code ?: JSONObject.NULL))
            .put("limitations", JSONArray(limitations))
            .toString(2)
        writeAtomically(manifest, manifestText.toByteArray(Charsets.UTF_8))
        liveStaging.remove(artifact.stagingFile.name)
        pruneRetention(keep = target.name)
        return CaptureArtifactResult(
            sessionId = artifact.sessionId,
            file = target,
            bytes = bytes,
            sha256 = sha256,
            partial = !complete,
            manifestFile = manifest,
            sink = sink,
        )
    }

    fun abandonRoot(artifact: RootCaptureArtifact) {
        runCatching { artifact.output.close() }
        if (runCatching { artifact.stagingFile.delete() }.getOrDefault(false)) {
            liveStaging.remove(artifact.stagingFile.name)
        }
    }

    fun abandon(artifact: CaptureArtifact) {
        runCatching { artifact.sink.closeAndDrain(250L) }
        // Never close/unlink the staging file while its writer still owns it.
        // The recoverable staging file is left for a real future drain.
        if (artifact.sink.isWriterAlive()) return
        runCatching { artifact.output.close() }
        if (runCatching { artifact.stagingFile.delete() }.getOrDefault(false)) {
            liveStaging.remove(artifact.stagingFile.name)
        }
    }

    fun list(): List<File> = rootDirectory.listFiles()
        ?.filter { it.isFile && it.name.matches(Regex("^capture-[0-9a-fA-F-]{36}(-partial)?\\.pcap$")) }
        ?.sortedByDescending { it.lastModified() }
        .orEmpty()

    private fun pruneRetention(keep: String? = null) {
        val files = list().filter { it.name != keep }
        var total = files.sumOf { it.length() }
        var count = files.size
        for (file in files.asReversed()) {
            if (count <= maxRetainedCaptures && total <= maxRetainedBytes) break
            val size = file.length()
            if (runCatching { file.delete() }.getOrDefault(false)) {
                count -= 1
                total -= size
                val id = file.name.removePrefix("capture-")
                    .removeSuffix("-partial.pcap").removeSuffix(".pcap")
                runCatching { File(rootDirectory, "capture-$id.json").delete() }
            }
        }
        // Incomplete staging files from a killed process are recoverable, not
        // silently published. Keep them for a bounded day, then prune.
        val old = clock() - 24L * 60L * 60L * 1000L
        stagingDirectory.listFiles()?.forEach { file ->
            if (file.isFile && file.name !in liveStaging && file.lastModified() < old) {
                runCatching { file.delete() }
            }
        }
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun writeAtomically(target: File, bytes: ByteArray) {
        val staging = File(target.parentFile, ".${target.name}.staging-${idFactory()}")
        FileOutputStream(staging, false).use { output ->
            output.write(bytes)
            output.flush()
            output.fd.sync()
        }
        try {
            Files.move(staging.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE)
        } catch (_: IOException) {
            Files.move(staging.toPath(), target.toPath())
        }
    }
}

/**
 * Publishes the existing bounded analysis next to the raw capture. The raw
 * file never leaves App-private storage and the analysis gets no implicit
 * Agent-read grant.
 */
class CaptureAnalysisPublisher(
    private val analysisStore: PcapAnalysisStore,
    private val analyzer: PcapAnalyzer = PcapAnalyzer(),
    private val idFactory: () -> String = { UUID.randomUUID().toString() },
) {
    fun publish(
        owner: CaptureOwner,
        result: CaptureArtifactResult,
        detailed: Boolean,
        cancellation: PcapCancellation = PcapCancellation.NONE,
        now: () -> Long = System::currentTimeMillis,
    ): CaptureAnalysisResult {
        if (!result.file.isFile) {
            return CaptureAnalysisResult(null, CaptureFailure("rawMissing"), null, emptyList())
        }
        if (result.bytes > PcapLimits.MAX_SOURCE_BYTES) {
            return CaptureAnalysisResult(
                null,
                CaptureFailure("sourceTooLarge"),
                null,
                listOf("The raw capture exceeds the existing 128 MiB analysis cap."),
            )
        }
        val analysisId = idFactory()
        val summary = analyzer.analyze(
            FilePcapSource(result.file, "Live capture"),
            PcapAnalysisOptions(
                analysisID = analysisId,
                sourceLabel = "Live capture",
                detailed = detailed,
                createdAtEpochMillis = now(),
                cancellation = cancellation,
            ),
        )
        if (summary.status == PcapAnalysisStatus.FAILED || summary.cancelled) {
            return CaptureAnalysisResult(
                null,
                CaptureFailure(if (summary.cancelled) "analysisCancelled" else "analysisFailed"),
                summary.status,
                summary.limitations,
            )
        }
        val stored = runCatching {
            analysisStore.write(
                summary,
                ownerTaskId = owner.taskId,
                ownerWorkspaceId = owner.workspaceId,
                agentReadable = false,
            )
        }.getOrElse { error ->
            return CaptureAnalysisResult(
                null,
                CaptureFailure(
                    if (error is IOException && error.message == "analysisAlreadyExists") {
                        "analysisAlreadyExists"
                    } else {
                        "analysisStoreFailed"
                    },
                ),
                summary.status,
                summary.limitations,
            )
        }
        return CaptureAnalysisResult(
            analysisId = stored.analysisID,
            failure = null,
            summaryStatus = summary.status,
            limitations = summary.limitations,
        )
    }
}

internal class FilePcapSource(
    private val file: File,
    override val label: String?,
) : PcapSource {
    override val sizeBytes: Long get() = file.length()
    override fun openStream(): InputStream = FileInputStream(file)
}
