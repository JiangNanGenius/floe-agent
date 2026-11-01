// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.canvas.ui.presentation

import com.floe.android.feature.canvas.CreativeAvailability
import com.floe.android.feature.canvas.CreativeException

/**
 * User-facing classification of a typed creative failure. Raw host reasons
 * (paths, SQL, bridge identifiers) never reach the UI; only a stable kind is
 * exposed and the copy is chosen by the presentation layer.
 */
enum class CanvasFailureKind {
    NEEDS_CORE_UPDATE,
    RUNTIME_NOT_READY,
    SESSION_LOST,
    REVISION_CONFLICT,
    OUTCOME_UNKNOWN,
    NOT_FOUND,
    CORRUPT,
    TOO_LARGE,
    UNSUPPORTED_SCHEMA,
    STORAGE,
    ASSET,
    INVALID_REQUEST,
    UNKNOWN,
}

data class CanvasFailure(
    val kind: CanvasFailureKind,
    /** Stable host code for diagnostics/tests only; never shown verbatim. */
    val code: String? = null,
    val retryable: Boolean = false,
) {
    val availability: CreativeAvailability?
        get() = when (kind) {
            CanvasFailureKind.NEEDS_CORE_UPDATE -> CreativeAvailability.NeedsCoreUpdate
            CanvasFailureKind.RUNTIME_NOT_READY -> CreativeAvailability.WaitingForRuntime
            else -> null
        }
}

object CanvasFailures {
    fun from(error: Throwable): CanvasFailure {
        val typed = error as? CreativeException
        val code = typed?.code
        val kind = when (code) {
            "needsCoreUpdate", "coreTooNew", "unsupportedSchema" ->
                CanvasFailureKind.NEEDS_CORE_UPDATE
            "runtimeUnavailable", "acceptedRootNotLive" ->
                CanvasFailureKind.RUNTIME_NOT_READY
            "staleSession", "staleGeneration", "sessionRequired", "invalidSession" ->
                CanvasFailureKind.SESSION_LOST
            "revisionConflict" -> CanvasFailureKind.REVISION_CONFLICT
            "outcomeUnknown" -> CanvasFailureKind.OUTCOME_UNKNOWN
            "canvasNotFound" -> CanvasFailureKind.NOT_FOUND
            "corruptProject" -> CanvasFailureKind.CORRUPT
            "projectTooLarge", "responseTooLarge" -> CanvasFailureKind.TOO_LARGE
            "unsupportedOperation", "unsupportedAction" ->
                CanvasFailureKind.UNSUPPORTED_SCHEMA
            "assetTooLarge", "assetEmpty", "assetDigestMismatch",
            "assetStagingInvalid", "assetStagingUnavailable", "assetMissing",
            "assetReferenceInvalid",
            -> CanvasFailureKind.ASSET
            "storageUnavailable", "writeFailed", "storageLayerRequired",
            "workspaceStorageUnavailable", "untrustedOwner", "provenanceMismatch",
            "crossOwnerRefused",
            -> CanvasFailureKind.STORAGE
            "invalidRequest", "invalidPayload", "invalidOrigin", "sessionLimit",
            -> CanvasFailureKind.INVALID_REQUEST
            else -> CanvasFailureKind.UNKNOWN
        }
        return CanvasFailure(
            kind = kind,
            code = code,
            retryable = typed?.retryable == true ||
                kind == CanvasFailureKind.RUNTIME_NOT_READY,
        )
    }
}

/** Short-lived, non-blocking status shown above the editor surface. */
enum class CanvasNotice {
    REFERENCE_PENDING,
    DESIGN_METADATA_READ_ONLY,
    LEGACY_INK_READ_ONLY,
    LEGACY_STROKES_READ_ONLY,
    DELETION_NOT_UNDOABLE,
    UNDO_NOT_AVAILABLE,
    RELOADED_FROM_DISK,
    RECOVERY_CHECKED,
}
