// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.creative

import com.floe.android.bridge.MediaSnapshotNative
import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.workbench.CreativeProjectContext
import com.floe.android.feature.workbench.MediaProjectEnvelope
import com.floe.android.feature.workbench.MediaProjectReceipt
import com.floe.android.feature.workbench.RenderSnapshotLease
import com.floe.android.feature.workbench.RenderSnapshotRequest
import com.floe.android.feature.workbench.VideoEditCommand
import com.floe.android.feature.workbench.VideoProjectEnvelope
import com.floe.android.feature.workbench.VideoTimeline
import com.floe.android.feature.workbench.WorkbenchRenderSnapshotPort
import com.floe.android.feature.workbench.WorkbenchVideoHostApi
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray

/** R2 load result: the frozen envelope plus the native render timeline digest. */
data class R2VideoProjection(
    val envelope: VideoProjectEnvelope,
    /** Native-computed digest; the only value accepted by snapshot acquire. */
    val timelineDigest: String,
)

/**
 * App host foundation adapter for `floe.creative/6` video read/apply.
 *
 * It crosses the EXISTING `floe_bridge_exchange` C ABI with version 6; there is
 * no Kotlin project store, no fallback root and no path argument. Video writes
 * are the closed typed command vocabulary only — the native shared engine
 * performs the single revision CAS, undo step and durable receipt.
 */
class CreativeR2VideoHost(
    private val transport: CreativeTransport = SwiftCreativeTransport,
    private val epochProvider: () -> Long?,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) : WorkbenchVideoHostApi {
    private val exchangeMutex = Mutex()
    private val json = Json { ignoreUnknownKeys = true }

    override suspend fun loadVideo(
        context: CreativeProjectContext,
    ): VideoProjectEnvelope = loadVideoProjection(context).envelope

    suspend fun loadVideoProjection(
        context: CreativeProjectContext,
    ): R2VideoProjection = withContext(ioDispatcher) {
        val response = command("media.video.load", buildJsonObject {
            put("context", R2MediaWire.encodeContext(context))
        })
        val project = response.objectValue("project")
            ?: throw CreativeException("invalidResponse", "missingMediaProject")
        val timeline = R2MediaWire.decodeTimeline(response.objectValue("timeline"))
        val digest = response.string("timelineDigest")
            ?: throw CreativeException("invalidResponse", "missingTimelineDigest")
        R2VideoProjection(
            envelope = VideoProjectEnvelope(
                project = CreativeWire.decodeMediaProject(project),
                timeline = timeline,
                mediaRootPath = response.string("mediaRootPath").orEmpty(),
                storage = R2MediaWire.decodeStorage(response["storage"]),
                writable = response.bool("writable") ?: false,
                warnings = response.array("warnings")
                    ?.mapNotNull { (it as? kotlinx.serialization.json.JsonPrimitive)?.content }
                    .orEmpty(),
            ),
            timelineDigest = digest,
        )
    }

    override suspend fun applyVideo(
        context: CreativeProjectContext,
        expectedRevision: Long,
        opID: String,
        commands: List<VideoEditCommand>,
    ): MediaProjectReceipt = withContext(ioDispatcher) {
        if (expectedRevision < 0) {
            throw CreativeException("invalidRequest", "invalidRevision")
        }
        if (commands.isEmpty() || commands.size > 64) {
            throw CreativeException("invalidRequest", "invalidCommandCount")
        }
        if (!opID.matches(Regex("[A-Za-z0-9._-]{1,128}"))) {
            throw CreativeException("invalidRequest", "invalidOperationID")
        }
        val response = command("media.video.apply", buildJsonObject {
            put("context", R2MediaWire.encodeContext(context))
            put("expectedRevision", expectedRevision)
            put("opID", opID)
            putJsonArray("commands") {
                commands.forEach { add(R2MediaWire.encodeVideoCommand(it)) }
            }
        })
        CreativeWire.decodeMediaReceipt(response)
    }

    private suspend fun command(action: String, payload: JsonObject): JsonObject {
        val epoch = epochProvider()
            ?: throw CreativeException(
                "staleGeneration", "acceptedRootNotLive", retryable = true)
        if (epoch <= 0L) {
            throw CreativeException(
                "staleGeneration", "acceptedRootNotLive", retryable = true)
        }
        return exchangeMutex.withLock {
            val raw = try {
                transport.exchange(R2MediaWire.request(
                    operation = "command",
                    requestID = CreativeWire.newRequestID(),
                    epoch = epoch,
                    action = action,
                    payload = payload).toString())
            } catch (error: CreativeException) {
                throw error
            } catch (error: Throwable) {
                throw CreativeException(
                    "invalidCoreResponse", "bridgeExchangeFailed", retryable = true)
            }
            if (raw.toByteArray(Charsets.UTF_8).size > 16 * 1024 * 1024) {
                throw CreativeException("responseTooLarge", "bridgeResponseTooLarge")
            }
            R2MediaWire.response(raw)
        }
    }

    @Suppress("unused")
    private fun decodeTimeline(value: JsonObject?): VideoTimeline =
        R2MediaWire.decodeTimeline(value)
}

// MARK: - Snapshot lease host lane

internal interface MediaSnapshotNativeTransport {
    fun acquire(epoch: Long, request: ByteArray): ByteArray?
    fun release(epoch: Long, lease: ByteArray): Int
}

internal object JniMediaSnapshotNativeTransport : MediaSnapshotNativeTransport {
    override fun acquire(epoch: Long, request: ByteArray): ByteArray? =
        MediaSnapshotNative.acquire(epoch, request)

    override fun release(epoch: Long, lease: ByteArray): Int =
        MediaSnapshotNative.release(epoch, lease)
}

/**
 * App adapter for the frozen [WorkbenchRenderSnapshotPort].
 *
 * Acquisition is native-issued through the narrow host ABI (the frozen V6
 * action list has no snapshot action): the App can never construct a lease by
 * value. The returned lease is copied verbatim into [MediaExportBinding]; no
 * project JSON, recorded `taskWorkspacePath` or UI string is used as a root.
 */
internal class CreativeRenderSnapshotPort(
    private val epochProvider: () -> Long?,
    private val native: MediaSnapshotNativeTransport = JniMediaSnapshotNativeTransport,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) : WorkbenchRenderSnapshotPort {
    private val json = Json { ignoreUnknownKeys = true }

    override suspend fun acquire(request: RenderSnapshotRequest): RenderSnapshotLease =
        withContext(ioDispatcher) {
            val epoch = requireEpoch()
            val payload = buildJsonObject {
                put("context", R2MediaWire.encodeContext(request.context))
                put("expectedRevision", request.expectedRevision)
                put("expectedTimelineDigest", request.expectedTimelineDigest)
            }.toString().toByteArray(Charsets.UTF_8)
            if (payload.size > 16 * 1024) {
                throw CreativeException("requestTooLarge", "snapshotRequestTooLarge")
            }
            val reply = native.acquire(epoch, payload)
                ?: throw CreativeException(
                    "rendererUnavailable", "snapshotUnavailable", retryable = true)
            val objectValue = try {
                json.parseToJsonElement(reply.toString(Charsets.UTF_8)) as? JsonObject
            } catch (_: Throwable) {
                null
            } ?: throw CreativeException("invalidResponse", "malformedSnapshotLease")
            if (objectValue.bool("ok") != true) {
                throw CreativeException(
                    code = objectValue.string("error") ?: "rendererUnavailable",
                    reason = objectValue.string("reason"),
                    retryable = objectValue.bool("retryable") ?: false)
            }
            RenderSnapshotLease(
                leaseID = objectValue.string("leaseID")
                    ?: throw CreativeException("invalidResponse", "missingLeaseID"),
                mediaRootPath = objectValue.string("mediaRootPath")
                    ?: throw CreativeException("invalidResponse", "missingMediaRoot"),
                relativePath = objectValue.string("relativePath")
                    ?: throw CreativeException("invalidResponse", "missingRelativePath"),
                sha256 = objectValue.string("sha256").orEmpty(),
                byteCount = objectValue.long("byteCount") ?: 0,
                expiresAt = objectValue.string("expiresAt").orEmpty(),
            )
        }

    override suspend fun release(lease: RenderSnapshotLease) {
        withContext(ioDispatcher) {
            val epoch = requireEpoch()
            val payload = buildJsonObject {
                put("leaseID", lease.leaseID)
                put("mediaRootPath", lease.mediaRootPath)
                put("relativePath", lease.relativePath)
                put("sha256", lease.sha256)
                put("byteCount", lease.byteCount)
                put("expiresAt", lease.expiresAt)
            }.toString().toByteArray(Charsets.UTF_8)
            val status = native.release(epoch, payload)
            if (status != 0) {
                throw CreativeException(
                    if (status == -101) "renderTicketNotFound" else "staleGeneration",
                    "snapshotReleaseRefused")
            }
        }
    }

    private fun requireEpoch(): Long {
        val epoch = epochProvider()
        if (epoch == null || epoch <= 0L) {
            throw CreativeException(
                "staleGeneration", "acceptedRootNotLive", retryable = true)
        }
        return epoch
    }
}
