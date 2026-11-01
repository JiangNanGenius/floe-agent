// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench

import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeStorageLayer

/**
 * Explicit project + editor identity for every G09-R2 media request.
 *
 * The accepted native epoch is supplied separately by the bound host; it is
 * never encoded by a UI request. [storage] is a real, explicit storage layer
 * and is never inferred from [projectID], a recorded `taskWorkspacePath`, a
 * recorded `environmentID` or the first project in a library. [origin] is the
 * real source route when one exists; it is provenance only and never storage
 * permission.
 *
 * Generation, candidate, export and staged-import calls MUST carry this
 * context (or an opaque native-validated equivalent with the same fields).
 * There is deliberately no `projectID`-only overload in these contracts.
 */
data class CreativeProjectContext(
    val projectID: String,
    val sessionToken: String,
    val storage: CreativeStorageLayer,
    val origin: CreativeOriginContext? = null,
)

/**
 * Frozen G09-R2 bounds.
 *
 * The R1 request/response/Canvas/media-JSON limits are repeated here so the
 * R2 contract can be checked without reading a frozen R1 file. They MUST
 * match `CreativeLimits` exactly; they do not raise those limits.
 */
object WorkbenchR2Limits {
    const val BRIDGE_REQUEST_BYTES = 65_536
    const val BRIDGE_RESPONSE_BYTES = 16 * 1024 * 1024
    const val CANVAS_JSON_BYTES = 15 * 1024 * 1024
    const val MEDIA_JSON_BYTES = 8 * 1024 * 1024

    /** Render tickets are IPC descriptors, not project JSON. */
    const val RENDER_DESCRIPTOR_BYTES = 64 * 1024
    const val RENDER_REPLY_BYTES = 1024 * 1024
    const val MAX_LIVE_RENDER_TICKETS = 2

    /** Largest video command batch accepted by the existing transaction engine. */
    const val VIDEO_COMMANDS_PER_APPLY = 64

    /** Bounded job/candidate list paging for the UI. */
    const val JOB_LIST_DEFAULT = 50
    const val JOB_LIST_MAX = 200

    /**
     * A project asset used as an image generation source/edit/reference. The
     * bytes stay native; the request carries only the owned asset ID. This is
     * a policy cap, not a JSON size.
     */
    const val IMAGE_SOURCE_BYTES = 12 * 1024 * 1024

    /**
     * Large staged imports are STREAMED with a token; these are file-size
     * policy ceilings, not bridge buffers. The generic Canvas asset ceiling
     * (64 MiB) is unchanged.
     */
    const val IMPORT_IMAGE_BYTES = 128L * 1024 * 1024
    const val IMPORT_AUDIO_BYTES = 1024L * 1024 * 1024
    const val IMPORT_VIDEO_BYTES = 8L * 1024 * 1024 * 1024
    const val CANVAS_GENERIC_ASSET_BYTES = 64L * 1024 * 1024

    /**
     * Staging + final copy + small export/scratch headroom. The native
     * importer must preflight free space before opening the source stream and
     * refuse `insufficientStorage` instead of writing a partial asset.
     */
    const val IMPORT_DISK_HEADROOM_BYTES = 512L * 1024 * 1024

    /** A design preview/export payload is a verified file receipt, never inline bytes. */
    const val DESIGN_PREVIEW_BYTES = 8 * 1024 * 1024
    const val DESIGN_SOURCE_BYTES = 64L * 1024 * 1024
}

/** Kind of large staged media import; the ceiling is per kind. */
enum class LargeImportKind(val wire: String) {
    IMAGE("image"),
    AUDIO("audio"),
    VIDEO("video"),
}

data class LargeImportRule(
    val kind: LargeImportKind,
    val maxBytes: Long,
)

/**
 * Per-kind large-import policy. It deliberately does not change the generic
 * Canvas asset ceiling or the R1 media command/JSON bounds.
 */
object LargeImportPolicy {
    const val DUPLICATION_FACTOR = 2L

    val rules: Map<LargeImportKind, LargeImportRule> = mapOf(
        LargeImportKind.IMAGE to LargeImportRule(
            LargeImportKind.IMAGE, WorkbenchR2Limits.IMPORT_IMAGE_BYTES),
        LargeImportKind.AUDIO to LargeImportRule(
            LargeImportKind.AUDIO, WorkbenchR2Limits.IMPORT_AUDIO_BYTES),
        LargeImportKind.VIDEO to LargeImportRule(
            LargeImportKind.VIDEO, WorkbenchR2Limits.IMPORT_VIDEO_BYTES),
    )

    fun rule(kind: LargeImportKind): LargeImportRule = rules.getValue(kind)

    fun accepts(kind: LargeImportKind, byteCount: Long): Boolean =
        byteCount in 1L..rule(kind).maxBytes

    /**
     * Free-space floor before staging: two copies of the source (staging +
     * final) plus [WorkbenchR2Limits.IMPORT_DISK_HEADROOM_BYTES]. Saturates
     * instead of overflowing for pathological values.
     */
    fun requiredFreeBytes(sourceBytes: Long): Long {
        if (sourceBytes <= 0L) return 0L
        val duplicated = if (sourceBytes > Long.MAX_VALUE / DUPLICATION_FACTOR) {
            Long.MAX_VALUE
        } else {
            sourceBytes * DUPLICATION_FACTOR
        }
        val headroom = WorkbenchR2Limits.IMPORT_DISK_HEADROOM_BYTES
        return if (duplicated > Long.MAX_VALUE - headroom) Long.MAX_VALUE else duplicated + headroom
    }
}

/**
 * Typed R2 failure codes surfaced through `CreativeException.code`. R1 generic
 * codes (`invalidPayload`, `staleSession`, `revisionConflict`, `assetTooLarge`,
 * `projectTooLarge`, `storageUnavailable`, `writeFailed`, `outcomeUnknown`)
 * remain valid and are reused, not redefined.
 */
object WorkbenchR2Errors {
    const val GENERATION_UNAVAILABLE = "generationUnavailable"
    const val MODEL_UNAVAILABLE = "modelUnavailable"
    const val PROVIDER_REJECTED = "providerRejected"
    const val PROVIDER_TIMEOUT = "providerTimeout"
    const val JOB_NOT_FOUND = "jobNotFound"
    const val JOB_TERMINAL = "jobTerminal"
    const val CANDIDATE_NOT_FOUND = "candidateNotFound"
    const val CANDIDATE_STALE = "candidateStale"
    const val RENDER_UNSUPPORTED = "renderUnsupported"
    const val RENDERER_UNAVAILABLE = "rendererUnavailable"
    const val RENDER_CANCELLED = "renderCancelled"
    const val RENDER_TIMEOUT = "renderTimeout"
    const val UNSUPPORTED_CODEC = "unsupportedCodec"
    const val UNSUPPORTED_TRANSITION = "unsupportedTransition"
    const val UNSUPPORTED_SOURCE_FORMAT = "unsupportedSourceFormat"
    const val INSUFFICIENT_STORAGE = "insufficientStorage"
    const val IMPORT_TOO_LARGE = "importTooLarge"
    const val RENDER_TICKET_NOT_FOUND = "renderTicketNotFound"
    const val RENDER_TICKET_EXPIRED = "renderTicketExpired"
    const val RENDER_TICKET_ALREADY_SETTLED = "renderTicketAlreadySettled"

    val ALL: Set<String> = setOf(
        GENERATION_UNAVAILABLE, MODEL_UNAVAILABLE, PROVIDER_REJECTED, PROVIDER_TIMEOUT,
        JOB_NOT_FOUND, JOB_TERMINAL, CANDIDATE_NOT_FOUND, CANDIDATE_STALE,
        RENDER_UNSUPPORTED, RENDERER_UNAVAILABLE, RENDER_CANCELLED, RENDER_TIMEOUT,
        UNSUPPORTED_CODEC, UNSUPPORTED_TRANSITION, UNSUPPORTED_SOURCE_FORMAT,
        INSUFFICIENT_STORAGE, IMPORT_TOO_LARGE, RENDER_TICKET_NOT_FOUND,
        RENDER_TICKET_EXPIRED, RENDER_TICKET_ALREADY_SETTLED,
    )
}

/**
 * Closed `floe.creative/6` action names owned by the media/generation half of
 * G09-R2. Design actions live in `:feature:canvascontracts`.
 *
 * The native BridgeV6 dispatcher accepts only this closed set plus the design
 * set; V1–V5 actions are unchanged and are not repeated here.
 */
object WorkbenchWireActions {
    const val MEDIA_VIDEO_LOAD = "media.video.load"
    const val MEDIA_VIDEO_APPLY = "media.video.apply"

    const val GENERATION_MODELS = "generation.models"
    const val GENERATION_IMAGE_SUBMIT = "generation.image.submit"
    const val GENERATION_IMAGE_STATUS = "generation.image.status"
    const val GENERATION_IMAGE_DISMISS = "generation.image.dismiss"
    const val GENERATION_VIDEO_SUBMIT = "generation.video.submit"
    const val GENERATION_VIDEO_STATUS = "generation.video.status"
    const val GENERATION_VIDEO_CANCEL = "generation.video.cancel"
    const val GENERATION_VIDEO_DELIVER = "generation.video.deliver"
    const val GENERATION_CANDIDATES_LIST = "generation.candidates.list"
    const val GENERATION_CANDIDATES_ACCEPT = "generation.candidates.accept"
    const val GENERATION_CANDIDATES_REJECT = "generation.candidates.reject"

    val ALL: List<String> = listOf(
        MEDIA_VIDEO_LOAD,
        MEDIA_VIDEO_APPLY,
        GENERATION_MODELS,
        GENERATION_IMAGE_SUBMIT,
        GENERATION_IMAGE_STATUS,
        GENERATION_IMAGE_DISMISS,
        GENERATION_VIDEO_SUBMIT,
        GENERATION_VIDEO_STATUS,
        GENERATION_VIDEO_CANCEL,
        GENERATION_VIDEO_DELIVER,
        GENERATION_CANDIDATES_LIST,
        GENERATION_CANDIDATES_ACCEPT,
        GENERATION_CANDIDATES_REJECT,
    )
}
