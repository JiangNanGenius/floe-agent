// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.creative

import com.floe.android.feature.canvas.CanvasProjectEnvelope
import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.canvas.CreativeLimits
import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.workbench.MediaProjectEnvelope
import java.io.File
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

/** Typed internal request handed to the closed native source-create action. */
internal data class CreativeCanvasSourceRequest(
    val token: String,
    val opID: String,
    val name: String,
    val workspaceID: String?,
    val fileName: String,
    val mimeType: String?,
    val byteCount: Long,
    val sha256: String,
    val sourceKind: String,
    val width: Int?,
    val height: Int?,
    val sessionToken: String,
)

internal data class CreativeMediaSourceRequest(
    val token: String,
    val opID: String,
    val name: String,
    val kind: String,
    val storage: CreativeStorageLayer,
    val origin: CreativeOriginContext?,
    val fileName: String,
    val mimeType: String?,
    val byteCount: Long,
    val sha256: String,
    val sourceKind: String,
    val width: Int,
    val height: Int,
    val durationSeconds: Double?,
    val frameRate: Double?,
    val rotationDegrees: Double?,
    val sessionToken: String,
)

/**
 * Host-owned orchestration for "new project from a user-selected file".
 *
 * It stages the SAF bytes once, measures the actual staged bytes, derives the
 * project name/kind/dimensions the user did not supply, and calls ONE native
 * action that publishes a complete project. The staged copy is always removed
 * afterwards (success or failure); no Kotlin project/asset store exists and a
 * failed import never asks the native side to "clean up" an empty project.
 *
 * Cancellation contract: the bytes are staged with ordinary cooperative
 * cancellation, the coroutine is checked again right before dispatch, and the
 * native commit is awaited inside [NonCancellable]. A commit reply is never
 * thrown away because the UI scope was cancelled mid-call; if the caller is
 * gone, the durable native intent/receipt keeps a retry with the same `opID`
 * exact and idempotent.
 */
internal class CreativeSourceCreateController<S>(
    private val stage: suspend (source: S, sessionToken: String) -> CreativeStagedAsset,
    private val inspect: (File) -> CreativeSourceMetadata?,
    private val discard: (String) -> Unit,
    private val canvasCommit: suspend (CreativeCanvasSourceRequest) -> CanvasProjectEnvelope,
    private val mediaCommit: suspend (CreativeMediaSourceRequest) -> MediaProjectEnvelope,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    suspend fun createCanvas(
        source: S,
        name: String,
        workspaceID: String?,
        sessionToken: String,
        opID: String,
    ): CanvasProjectEnvelope {
        requireOperationID(opID)
        val cleanName = requireName(name)
        CreativeOwnership.requireSessionToken(sessionToken)
        val staged = stage(source, sessionToken)
        try {
            val metadata = measure(staged)
            // Pre-commit fence: a scope cancelled while staging must not
            // create anything; the staged copy is removed in `finally`.
            currentCoroutineContext().ensureActive()
            val request = CreativeCanvasSourceRequest(
                token = staged.token,
                opID = opID,
                name = cleanName,
                workspaceID = workspaceID?.takeIf { it.isNotBlank() },
                fileName = staged.fileName,
                mimeType = resolvedMime(staged.mimeType, metadata),
                byteCount = staged.byteCount,
                sha256 = staged.sha256,
                sourceKind = (metadata?.kind ?: CreativeSourceKind.FILE).wire,
                // A Canvas node does not need pixel dimensions; only pass a
                // measured size that the native bounds check accepts.
                width = metadata?.width?.takeIf { it in 2..8192 },
                height = metadata?.height?.takeIf { it in 2..8192 },
                sessionToken = sessionToken,
            )
            return withContext(NonCancellable) { canvasCommit(request) }
        } finally {
            discard(staged.token)
        }
    }

    suspend fun createMedia(
        source: S,
        name: String,
        kind: String,
        storage: CreativeStorageLayer,
        origin: CreativeOriginContext?,
        sessionToken: String,
        opID: String,
    ): MediaProjectEnvelope {
        requireOperationID(opID)
        val cleanName = requireName(name)
        CreativeOwnership.requireSessionToken(sessionToken)
        val expectedKind = when (kind.lowercase()) {
            "image" -> CreativeSourceKind.IMAGE
            "video" -> CreativeSourceKind.VIDEO
            else -> throw CreativeException("invalidRequest", "invalidProjectKind")
        }
        val staged = stage(source, sessionToken)
        try {
            val metadata = measure(staged)
                ?: throw CreativeException(
                    "unsupportedSourceFormat", "unrecognizedSourceBytes", retryable = false)
            if (metadata.kind != expectedKind) {
                throw CreativeException(
                    "sourceKindMismatch", "sourceKindMismatch", retryable = false)
            }
            val width = metadata.width
            val height = metadata.height
            if (width == null || height == null || width !in 2..8192 || height !in 2..8192) {
                throw CreativeException(
                    "invalidSourceDimensions", "invalidSourceDimensions", retryable = false)
            }
            val duration = if (expectedKind == CreativeSourceKind.VIDEO) {
                val seconds = metadata.durationSeconds
                if (seconds == null || !seconds.isFinite() || seconds <= 0.0) {
                    throw CreativeException(
                        "invalidSourceDuration", "missingSourceDuration", retryable = false)
                }
                seconds
            } else {
                null
            }
            currentCoroutineContext().ensureActive()
            val request = CreativeMediaSourceRequest(
                token = staged.token,
                opID = opID,
                name = cleanName,
                kind = expectedKind.wire,
                storage = storage,
                origin = origin,
                fileName = staged.fileName,
                mimeType = resolvedMime(staged.mimeType, metadata),
                byteCount = staged.byteCount,
                sha256 = staged.sha256,
                sourceKind = expectedKind.wire,
                width = width,
                height = height,
                durationSeconds = duration,
                frameRate = metadata.frameRate,
                rotationDegrees = metadata.rotationDegrees,
                sessionToken = sessionToken,
            )
            return withContext(NonCancellable) { mediaCommit(request) }
        } finally {
            discard(staged.token)
        }
    }

    private suspend fun measure(staged: CreativeStagedAsset): CreativeSourceMetadata? {
        val file = staged.file
        if (!file.isFile || file.length() != staged.byteCount) {
            throw CreativeException("assetStagingInvalid", "stagedBytesChanged")
        }
        return withContext(ioDispatcher) { inspect(file) }
    }

    private fun resolvedMime(
        explicit: String?,
        metadata: CreativeSourceMetadata?,
    ): String? {
        val trimmed = explicit?.trim()?.takeIf { it.isNotEmpty() }
        val recognised = trimmed != null &&
            (trimmed.startsWith("image/") ||
                trimmed.startsWith("video/") ||
                trimmed.startsWith("audio/"))
        return if (recognised) trimmed else metadata?.mimeType ?: trimmed
    }

    private fun requireOperationID(value: String) {
        if (!value.matches(Regex("[A-Za-z0-9._-]{1,96}"))) {
            throw CreativeException("invalidRequest", "invalidOperationID")
        }
    }

    private fun requireName(value: String): String {
        val trimmed = value.trim()
        if (trimmed.isEmpty() ||
            trimmed.toByteArray(Charsets.UTF_8).size > CreativeLimits.NAME_BYTES) {
            throw CreativeException("invalidRequest", "invalidName")
        }
        return trimmed
    }
}
