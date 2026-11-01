// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench

import android.view.Surface
import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeStorageLayer

/**
 * G09-R2 Kotlin media platform ports.
 *
 * These contracts are implementable by a new `core:workbenchmedia` module plus
 * a thin App adapter. They intentionally expose NO Media3/ExoPlayer/Transformer
 * types, no Compose types and no StateFlow: the frozen contract modules stay
 * dependency-free beyond kotlinx.serialization, while the implementation may
 * use Flow/Media3 internally.
 *
 * All byte paths are project-relative values copied from a trusted native
 * envelope and re-validated by the renderer. A URI or path read from project
 * JSON is never accepted as authority. Export is a service-owned job that
 * returns a VERIFIED receipt only after post-write playability/size/digest
 * checks; it never returns a success string as proof of output.
 */
data class CodecCapability(
    val mimeType: String,
    val isEncoder: Boolean,
    val hardwareAccelerated: Boolean,
    val maxWidth: Int,
    val maxHeight: Int,
    val maxFrameRate: Double,
)

/**
 * Actual device/renderer capability probe. Never a universal codec promise:
 * the implementation must query `MediaCodecList`/the pinned Media3 artifact and
 * fill [unavailableReasons] honestly. `crossDissolveSupported` is false unless
 * a tested compositor exists; rendering a hard cut instead is forbidden.
 */
data class RenderCapabilities(
    val encoders: List<CodecCapability> = emptyList(),
    val decoders: List<CodecCapability> = emptyList(),
    val muxers: List<String> = emptyList(),
    val imageFormats: List<String> = emptyList(),
    val heicSupported: Boolean = false,
    val crossDissolveSupported: Boolean = false,
    val maxWidth: Int = 0,
    val maxHeight: Int = 0,
    val maxFrameRate: Double = 0.0,
    val maxDurationSeconds: Double = 0.0,
    val maxClips: Int = 0,
    val maxOutputBytes: Long = 0,
    /** Keyed by capability/codec/container; only actual refusal reasons. */
    val unavailableReasons: Map<String, String> = emptyMap(),
    val probedAt: String,
)

data class PlaybackState(
    val positionSeconds: Double = 0.0,
    val durationSeconds: Double = 0.0,
    val isPlaying: Boolean = false,
    val isBuffering: Boolean = false,
    val ended: Boolean = false,
    val errorCode: String? = null,
)

fun interface PlaybackListener {
    fun onPlaybackState(state: PlaybackState)
}

/**
 * Retained by the editor controller, never by a Composable. The surface is
 * attached/detached explicitly; closing releases the platform player and every
 * listener registration.
 */
interface PlaybackHandle : AutoCloseable {
    val state: PlaybackState

    fun attachSurface(surface: Surface, width: Int, height: Int): Boolean

    fun detachSurface()

    fun seekTo(positionSeconds: Double)

    fun play()

    fun pause()

    /** Callback registration; no Flow dependency in this module. */
    fun subscribe(listener: PlaybackListener): AutoCloseable

    override fun close()
}

/**
 * Native-issued immutable render snapshot lease.
 *
 * This is the ONLY project input the platform renderer may open: a verified
 * file snapshot under a trusted root, not the mutable latest project and not a
 * path from recorded project JSON. The platform opens
 * `mediaRootPath + "/" + relativePath`, checks the digest and never resolves a
 * root itself.
 */
data class RenderSnapshotLease(
    /** Native-issued lease identity, never a credential. */
    val leaseID: String,
    /** Native-issued trusted media root; never a recorded project path. */
    val mediaRootPath: String,
    /** Trusted relative path under the native-issued media root. */
    val relativePath: String,
    val sha256: String,
    val byteCount: Long,
    val expiresAt: String,
)

data class RenderSnapshotRequest(
    val context: CreativeProjectContext,
    val expectedRevision: Long,
    val expectedTimelineDigest: String,
)

/**
 * Resolves an immutable snapshot for a specific project revision. Acquisition
 * is native-issued; release is idempotent. A caller must not reopen a latest
 * project to reconstruct the snapshot.
 */
interface WorkbenchRenderSnapshotPort {
    suspend fun acquire(request: RenderSnapshotRequest): RenderSnapshotLease

    suspend fun release(lease: RenderSnapshotLease)
}

/**
 * All export/render calls bind to an immutable project revision captured from
 * the trusted native envelope. `mediaRootPath` and [snapshot] are copied from
 * the native envelope/lease, never reconstructed from project JSON or a
 * recorded task path. [mediaRootPath] MUST equal [snapshot.mediaRootPath]; the
 * renderer rejects a mismatch. The output path is derived by the service as
 * `Workbench/Exports/<attemptID>.<ext>`.
 */
data class MediaExportBinding(
    val context: CreativeProjectContext,
    val mediaRootPath: String,
    val projectRevision: Long,
    val timelineDigest: String,
    val attemptID: String,
    val snapshot: RenderSnapshotLease,
)

data class PlaybackRequest(
    val binding: MediaExportBinding,
    val startAtSeconds: Double? = null,
)

data class PreviewWindow(
    val startSeconds: Double,
    val durationSeconds: Double,
)

enum class MediaExportKind(val wire: String) {
    PREVIEW("preview"),
    IMAGE("image"),
    VIDEO("video"),
}

data class VideoExportSettings(
    /** Exact encoder MIME from [RenderCapabilities.encoders]. */
    val codecMime: String,
    val width: Int,
    val height: Int,
    val frameRate: Double,
    val quality: Double,
    val fileName: String,
)

data class ImageExportSettings(
    /** "png" | "jpeg" | "heic"; the platform probe must accept it. */
    val format: String,
    val width: Int? = null,
    val height: Int? = null,
    val quality: Double = 0.95,
    val preserveTransparency: Boolean = true,
    val stripMetadata: Boolean = true,
    val fileName: String,
)

sealed interface MediaExportRequest {
    val binding: MediaExportBinding

    data class Video(
        override val binding: MediaExportBinding,
        val settings: VideoExportSettings,
    ) : MediaExportRequest

    data class Image(
        override val binding: MediaExportBinding,
        val settings: ImageExportSettings,
    ) : MediaExportRequest
}

data class MediaExportJobHandle(
    val jobID: String,
    val kind: MediaExportKind,
    val state: MediaExportState,
    val acceptedAt: String,
)

enum class MediaExportState(val wire: String) {
    QUEUED("queued"),
    RUNNING("running"),
    VERIFYING("verifying"),
    COMPLETED("completed"),
    CANCELLED("cancelled"),
    FAILED("failed"),
    INTERRUPTED("interrupted"),
    TIMEOUT("timeout"),
}

data class ExportVerification(
    val playable: Boolean,
    val decodedDurationSeconds: Double?,
    val width: Int,
    val height: Int,
    val audioTrackCount: Int,
    val container: String,
    val codec: String,
)

/**
 * Receipt identity only. It deliberately does not echo the editor session
 * token from [MediaExportBinding]; a receipt can travel to the UI/store
 * without carrying the session credential.
 */
data class MediaExportReceiptBinding(
    val projectID: String,
    val mediaRootPath: String,
    val projectRevision: Long,
    val timelineDigest: String,
    val attemptID: String,
)

/** Only emitted for a verified output. The relative path is under the trusted root. */
data class MediaExportReceipt(
    val binding: MediaExportReceiptBinding,
    val kind: MediaExportKind,
    val outputRelativePath: String,
    val mimeType: String,
    val byteCount: Long,
    val sha256: String,
    val verification: ExportVerification,
    val completedAt: String,
)

data class MediaExportStatus(
    val jobID: String,
    val kind: MediaExportKind,
    val state: MediaExportState,
    val updatedAt: String,
    val progress: Double? = null,
    val receipt: MediaExportReceipt? = null,
    val errorCode: String? = null,
    val retryable: Boolean = false,
)

data class ImagePreviewRequest(
    val binding: MediaExportBinding,
    val window: PreviewWindow? = null,
)

data class ImagePreviewReceipt(
    val binding: MediaExportReceiptBinding,
    val previewRelativePath: String,
    val mimeType: String,
    val byteCount: Long,
    val sha256: String,
    val width: Int,
    val height: Int,
    val generatedAt: String,
)

data class MediaAssetProbeRequest(
    val context: CreativeProjectContext,
    /** Native-issued trusted media root; never a recorded project path. */
    val mediaRootPath: String,
    /** Project-relative path verified by the host; never a URI. */
    val relativePath: String,
)

data class ProbedAsset(
    val relativePath: String,
    val kind: String,
    val mimeType: String,
    val byteCount: Long,
    val width: Int? = null,
    val height: Int? = null,
    val durationSeconds: Double? = null,
    val frameRate: Double? = null,
    val audioTrackCount: Int? = null,
    val rotationDegrees: Double? = null,
    val codec: String? = null,
    val unsupportedReason: String? = null,
)

data class StagedImportMetadata(
    /** Opaque token from the trusted staging service; never a client path. */
    val token: String,
    val kind: LargeImportKind,
    val fileName: String,
    val mimeType: String? = null,
    val byteCount: Long,
    val sha256: String,
    /** Host-measured and native-verified metadata; never a recorded project field. */
    val mediaMetadata: MediaAssetMetadata? = null,
)

data class StagedImportValidation(
    val accepted: Boolean,
    val requiredFreeBytes: Long,
    val maxBytes: Long,
    val refusalCode: String? = null,
)

/** New-project creation is limited to image/video; audio is an existing-project asset. */
enum class NewMediaProjectKind(val wire: String) {
    IMAGE("image"),
    VIDEO("video"),
}

/**
 * Atomic staged import. `ExistingProject` appends to an already-open project
 * with a revision CAS; `NewProject` stages, verifies and creates the project
 * in one operation. There is no empty-project pre-create and no caller-supplied
 * project ID, so a pre-commit failure cannot leave an empty project.
 */
sealed interface LargeImportRequest {
    val opID: String
    val metadata: StagedImportMetadata

    data class ExistingProject(
        val context: CreativeProjectContext,
        val expectedRevision: Long,
        override val opID: String,
        override val metadata: StagedImportMetadata,
    ) : LargeImportRequest

    /**
     * For a new project, [StagedImportMetadata.mediaMetadata] must carry the
     * host-measured/native-verified dimensions (and video duration/frame rate),
     * or [preparedIntentToken] must name a native-prepared intent; otherwise
     * the import is refused before any project file exists.
     */
    data class NewProject(
        val storage: CreativeStorageLayer,
        val origin: CreativeOriginContext,
        val name: String,
        val kind: NewMediaProjectKind,
        val sessionToken: String,
        override val opID: String,
        override val metadata: StagedImportMetadata,
        /** Optional native-prepared intent token; never a client project ID. */
        val preparedIntentToken: String? = null,
    ) : LargeImportRequest
}

data class LargeImportJobHandle(
    val jobID: String,
    val state: LargeImportState,
    val acceptedAt: String,
)

enum class LargeImportState(val wire: String) {
    QUEUED("queued"),
    STAGING("staging"),
    VERIFYING("verifying"),
    IMPORTING("importing"),
    COMMITTING("committing"),
    COMPLETED("completed"),
    CANCELLED("cancelled"),
    FAILED("failed"),
    INTERRUPTED("interrupted"),
}

/** The session token is validated against the durable job owner; no foreign job lookup. */
data class LargeImportStatusRequest(
    val jobID: String,
    val sessionToken: String,
)

data class LargeImportCancelRequest(
    val jobID: String,
    val sessionToken: String,
    val opID: String,
)

/**
 * Progress/cancel result. `createdProjectID`/`asset` are non-null only after a
 * terminal successful commit; a failed/cancelled/pre-commit import returns
 * neither an empty project ID nor an empty project.
 */
data class LargeImportStatus(
    val jobID: String,
    val state: LargeImportState,
    val updatedAt: String,
    val progress: Double? = null,
    val createdProjectID: String? = null,
    val createdRevision: Long? = null,
    val asset: MediaAssetReceipt? = null,
    val errorCode: String? = null,
    val retryable: Boolean = false,
)

/**
 * Streams a bounded staged source into explicit project storage. The import is
 * service-owned and cancellable; [validate] performs the per-kind + free-space
 * preflight before any stream is opened.
 */
interface WorkbenchLargeImportPort {
    fun validate(metadata: StagedImportMetadata): StagedImportValidation

    suspend fun submit(request: LargeImportRequest): LargeImportJobHandle

    suspend fun status(request: LargeImportStatusRequest): LargeImportStatus

    suspend fun cancel(request: LargeImportCancelRequest): LargeImportJobHandle
}

/**
 * Service-owned playback/export/probe surface. Implementations may use
 * Media3 1.11.1 internally; callers never see Media3 types. Every request
 * carries a [MediaExportBinding] with a native-issued [RenderSnapshotLease],
 * so the renderer never reopens a mutable latest project.
 */
interface WorkbenchMediaPlatform {
    fun capabilities(): RenderCapabilities

    fun createPlayer(request: PlaybackRequest): PlaybackHandle

    suspend fun probe(request: MediaAssetProbeRequest): ProbedAsset

    suspend fun renderImagePreview(request: ImagePreviewRequest): ImagePreviewReceipt

    suspend fun submitExport(request: MediaExportRequest): MediaExportJobHandle

    suspend fun exportStatus(
        context: CreativeProjectContext,
        jobID: String,
    ): MediaExportStatus

    suspend fun cancelExport(
        context: CreativeProjectContext,
        jobID: String,
    ): MediaExportJobHandle

    /** Callback subscription for progress/terminal state; no Flow in the contract. */
    fun observeExport(
        context: CreativeProjectContext,
        jobID: String,
        listener: (MediaExportStatus) -> Unit,
    ): AutoCloseable
}
