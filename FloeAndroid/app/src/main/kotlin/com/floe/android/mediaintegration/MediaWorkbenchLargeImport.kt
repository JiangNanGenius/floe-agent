// SPDX-License-Identifier: MPL-2.0
package com.floe.android.mediaintegration

import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.workbench.CreativeProjectContext
import com.floe.android.feature.workbench.LargeImportCancelRequest
import com.floe.android.feature.workbench.LargeImportJobHandle
import com.floe.android.feature.workbench.LargeImportKind
import com.floe.android.feature.workbench.LargeImportRequest
import com.floe.android.feature.workbench.LargeImportState
import com.floe.android.feature.workbench.LargeImportStatus
import com.floe.android.feature.workbench.LargeImportStatusRequest
import com.floe.android.feature.workbench.MediaAssetReceipt
import com.floe.android.feature.workbench.MediaProjectEnvelope
import com.floe.android.feature.workbench.NewMediaProjectKind
import com.floe.android.feature.workbench.WorkbenchR2Limits
import com.floe.android.feature.workbench.ui.api.MediaPickedSource
import com.floe.android.host.creative.CreativeHostController
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

/**
 * Pure routing/classification for the reviewed large-import path.
 *
 * The generic R1 Canvas/media staging cap (64 MiB) is deliberately unchanged;
 * this policy only selects the frozen R2 large-import route where native owns
 * the verified bytes and the per-kind ceilings (image 128 MiB / audio 1 GiB /
 * video 8 GiB).
 */
internal object MediaWorkbenchImportPolicy {
    const val GENERIC_MEDIA_LIMIT = WorkbenchR2Limits.CANVAS_GENERIC_ASSET_BYTES

    fun shouldUseLargeRoute(kind: String, byteCount: Long?): Boolean {
        val normalized = kind.lowercase()
        return when (normalized) {
            "video", "audio" -> true
            "image" -> byteCount != null && byteCount > GENERIC_MEDIA_LIMIT
            else -> false
        }
    }

    fun shouldUseLargeRouteForAsset(source: MediaPickedSource): Boolean {
        val kind = classify(source) ?: return false
        return shouldUseLargeRoute(kind.wire, source.byteCount)
    }

    fun classify(source: MediaPickedSource): LargeImportKind? =
        classifyKind(source.mimeType, source.displayName)

    fun classifyKind(mimeType: String?, displayName: String): LargeImportKind? {
        val mime = mimeType?.lowercase().orEmpty()
        when {
            mime.startsWith("video/") -> return LargeImportKind.VIDEO
            mime.startsWith("audio/") -> return LargeImportKind.AUDIO
            mime.startsWith("image/") -> return LargeImportKind.IMAGE
        }
        val extension = displayName.substringAfterLast('.', "").lowercase()
        return when (extension) {
            "mp4", "mov", "m4v", "mkv", "webm", "3gp" -> LargeImportKind.VIDEO
            "mp3", "m4a", "aac", "wav", "flac", "ogg", "opus" -> LargeImportKind.AUDIO
            "png", "jpg", "jpeg", "webp", "gif", "bmp", "heic", "heif" -> LargeImportKind.IMAGE
            else -> null
        }
    }

    fun newProjectKind(kind: String): NewMediaProjectKind? = when (kind.lowercase()) {
        "image" -> NewMediaProjectKind.IMAGE
        "video" -> NewMediaProjectKind.VIDEO
        else -> null
    }
}

/**
 * App facade over the REAL service-owned V6 large-import actions.
 *
 * The App stages the user URI into service-owned staging under the accepted
 * root, submits metadata only, and polls the truthful native job status. After
 * an accepted submit the staged token is NATIVE-owned: this class never
 * deletes it in a finally, and an ambiguous submit is surfaced as a typed
 * unknown outcome (no blind retry). A new project is returned only after the
 * native commit reports the actual created project id; an existing-project
 * import returns only the native receipt.
 */
internal class MediaWorkbenchLargeImport(
    private val hostProvider: () -> CreativeHostController,
) {
    companion object {
        private const val POLL_FIRST_MILLIS = 250L
        private const val POLL_MAX_MILLIS = 2_000L
        private const val TOTAL_TIMEOUT_MILLIS = 30L * 60 * 1000
    }

    suspend fun createProject(
        source: MediaPickedSource,
        name: String,
        kind: String,
        storage: CreativeStorageLayer,
        origin: CreativeOriginContext?,
        sessionToken: String,
        opID: String,
    ): MediaProjectEnvelope {
        val projectKind = MediaWorkbenchImportPolicy.newProjectKind(kind)
            ?: throw CreativeException("invalidRequest", "invalidProjectKind")
        val importKind = when (projectKind) {
            NewMediaProjectKind.IMAGE -> LargeImportKind.IMAGE
            NewMediaProjectKind.VIDEO -> LargeImportKind.VIDEO
        }
        val originValue = origin
            ?: throw CreativeException("invalidRequest", "missingOriginContext")
        val host = hostProvider()
        val staged = host.r2ImportHost.stageSource(
            uri = source.uri,
            kind = importKind,
            sessionToken = sessionToken,
        )
        val request = LargeImportRequest.NewProject(
            storage = storage,
            origin = originValue,
            name = name,
            kind = projectKind,
            sessionToken = sessionToken,
            opID = opID,
            metadata = staged,
        )
        val handle = host.r2ImportHost.submit(request)
        val status = awaitTerminal(host, handle, sessionToken, opID)
        if (status.state != LargeImportState.COMPLETED) throw failure(status)
        val projectID = status.createdProjectID
            ?: throw CreativeException("invalidCoreResponse", "missingCreatedProject")
        return host.services.open(
            projectID = projectID,
            sessionToken = sessionToken,
            storage = storage,
            origin = origin,
        )
    }

    suspend fun importAsset(
        source: MediaPickedSource,
        projectID: String,
        expectedRevision: Long,
        storage: CreativeStorageLayer,
        origin: CreativeOriginContext?,
        sessionToken: String,
        opID: String,
    ): MediaAssetReceipt {
        val importKind = MediaWorkbenchImportPolicy.classify(source)
            ?: throw CreativeException("invalidRequest", "unsupportedAssetKind")
        val host = hostProvider()
        val staged = host.r2ImportHost.stageSource(
            uri = source.uri,
            kind = importKind,
            sessionToken = sessionToken,
        )
        val request = LargeImportRequest.ExistingProject(
            context = CreativeProjectContext(
                projectID = projectID,
                sessionToken = sessionToken,
                storage = storage,
                origin = origin,
            ),
            expectedRevision = expectedRevision,
            opID = opID,
            metadata = staged,
        )
        val handle = host.r2ImportHost.submit(request)
        val status = awaitTerminal(host, handle, sessionToken, opID)
        if (status.state != LargeImportState.COMPLETED) throw failure(status)
        return status.asset
            ?: throw CreativeException("invalidCoreResponse", "missingImportedAsset")
    }

    private suspend fun awaitTerminal(
        host: CreativeHostController,
        handle: LargeImportJobHandle,
        sessionToken: String,
        opID: String,
    ): LargeImportStatus = try {
        withContext(Dispatchers.IO) {
            val deadline = System.currentTimeMillis() + TOTAL_TIMEOUT_MILLIS
            var wait = POLL_FIRST_MILLIS
            var status = LargeImportStatus(
                jobID = handle.jobID,
                state = handle.state,
                updatedAt = handle.acceptedAt,
            )
            while (!status.state.terminal) {
                if (System.currentTimeMillis() > deadline) {
                    throw CreativeException(
                        "importTimeout", "largeImportTimeout", retryable = true)
                }
                delay(wait)
                wait = (wait * 2).coerceAtMost(POLL_MAX_MILLIS)
                status = host.r2ImportHost.status(
                    LargeImportStatusRequest(handle.jobID, sessionToken))
            }
            status
        }
    } catch (cancelled: CancellationException) {
        withContext(NonCancellable + Dispatchers.IO) {
            runCatching {
                host.r2ImportHost.cancel(
                    LargeImportCancelRequest(handle.jobID, sessionToken, opID))
            }
        }
        throw cancelled
    }

    private fun failure(status: LargeImportStatus): CreativeException {
        val code = status.errorCode ?: when (status.state) {
            LargeImportState.CANCELLED -> "importCancelled"
            LargeImportState.INTERRUPTED -> "importInterrupted"
            LargeImportState.FAILED -> "importFailed"
            else -> "importIncomplete"
        }
        return CreativeException(
            code = code,
            reason = status.state.wire,
            retryable = status.retryable && status.state != LargeImportState.INTERRUPTED,
        )
    }

    private val LargeImportState.terminal: Boolean
        get() = this == LargeImportState.COMPLETED ||
            this == LargeImportState.CANCELLED ||
            this == LargeImportState.FAILED ||
            this == LargeImportState.INTERRUPTED
}
