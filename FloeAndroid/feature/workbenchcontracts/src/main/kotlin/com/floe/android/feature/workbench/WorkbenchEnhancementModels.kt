// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench

/**
 * Frozen G09-R2 media-enhancement contract (job-8e175eef3cea48d3).
 *
 * Kotlin mirror of the native `G09R2MediaEnhancementContract.swift`. The
 * native Codable model is the authority; these DTOs only carry the wire
 * projection between the App host and `floe.creative/6`.
 *
 * Honesty invariants carried from the native side:
 *  - Interpolation is REAL motion interpolation (`ffmpeg minterpolate`) in
 *    the task Linux environment, never plain scaling.
 *  - Super-resolution is TRUE SR on the user-configured fal.ai
 *    `fal-ai/bytedance-upscaler/upscale/video` backend; unconfigured state
 *    stays configurable and images are refused with an explicit
 *    supported-type boundary (never a video URL sent to an image model).
 *  - Ordinary resize remains labelled resize on the export surface and is
 *    never presented as enhancement.
 */
enum class EnhancementMethod(val wire: String) {
    INTERPOLATION("interpolation"),
    SUPER_RESOLUTION("superResolution"),
}

sealed interface EnhancementOperation {
    val method: EnhancementMethod

    data class Interpolation(val targetFPS: Double) : EnhancementOperation {
        override val method: EnhancementMethod get() = EnhancementMethod.INTERPOLATION
    }

    data class SuperResolution(val scaleFactor: Int, val bitDepth: Int) :
        EnhancementOperation {
        override val method: EnhancementMethod get() = EnhancementMethod.SUPER_RESOLUTION
    }
}

/** Explicit input/output contract for one enhancement request. */
data class EnhancementRequest(
    /** Path relative to the project media root, containment-checked natively. */
    val inputRelativePath: String,
    val operation: EnhancementOperation,
    val outputFileName: String,
    val overwrite: Boolean = false,
)

data class EnhancementLimits(
    val maximumSourceDimension: Int = 4096,
    val maximumOutputDimension: Int = 8192,
    val maximumDurationSeconds: Int = 3600,
    val maximumFrames: Int = 200_000,
    val maximumTargetFPS: Double = 240.0,
    val scaleFactors: List<Int> = listOf(2, 3, 4),
)

enum class EnhancementPhase(val wire: String) {
    PREFLIGHT("preflight"),
    PROCESSING("processing"),
    VALIDATING("validating"),
    COMMITTING("committing"),
}

data class EnhancementProgress(
    val phase: EnhancementPhase,
    val completedUnits: Int,
    val totalUnits: Int,
) {
    val fraction: Double
        get() = if (totalUnits > 0) {
            (completedUnits.toDouble() / totalUnits).coerceIn(0.0, 1.0)
        } else 0.0
}

enum class EnhancementJobState(val wire: String) {
    QUEUED("queued"),
    RUNNING("running"),
    CANCELLING("cancelling"),
    VALIDATING("validating"),
    COMPLETED("completed"),
    FAILED("failed"),
    CANCELLED("cancelled"),
    OUTCOME_UNKNOWN("outcomeUnknown"),
    ;

    val isTerminal: Boolean
        get() = this == COMPLETED || this == FAILED || this == CANCELLED ||
            this == OUTCOME_UNKNOWN
}

/**
 * Measured result identity. Every field is measured by the native pipeline
 * (guest ffprobe readback + streaming SHA-256); a returned success string is
 * never accepted as evidence. [engine] is the truthful method label
 * (`ffmpeg-minterpolate` or the configured backend name).
 */
data class EnhancementReceipt(
    val outputRelativePath: String,
    val engine: String,
    val method: EnhancementMethod,
    val inputKind: String,
    val sourceWidth: Int,
    val sourceHeight: Int,
    val sourceFPS: Double,
    val sourceDurationSeconds: Double,
    val sourceFrameCount: Int,
    val outputWidth: Int,
    val outputHeight: Int,
    val outputFPS: Double,
    val outputDurationSeconds: Double,
    val outputFrameCount: Int,
    val outputBytes: Long,
    val outputSHA256: String,
    val remoteJobID: String?,
    val warnings: List<String>,
    /** Set when the verified output entered the original importAsset
     *  revision-CAS ownership (asset identity + post-import revision). */
    val importedAssetID: String? = null,
    val importRevision: Long? = null,
    /** Bounded code when the import failed; the output file stays committed
     *  at [outputRelativePath] and the import can be retried. */
    val importErrorCode: String? = null,
)

data class EnhancementStatus(
    val jobID: String,
    val state: EnhancementJobState,
    val progress: EnhancementProgress?,
    val receipt: EnhancementReceipt?,
    val errorCode: String?,
    val errorDetail: String?,
    val retryable: Boolean,
    val canCancel: Boolean,
)

/** Honest per-engine capability; a missing engine names its exact reason. */
data class EnhancementCapability(
    val interpolationReady: Boolean,
    val interpolationEngine: String?,
    val interpolationUnavailableReason: String?,
    val superResolutionReady: Boolean,
    val superResolutionBackendName: String?,
    val superResolutionUnavailableReason: String?,
)

/**
 * Secret-free projection of the super-resolution backend configuration.
 * [credentialConfigured] reports presence only; the bytes never leave the
 * vault. [legacyProviderProfileReferenced] is true for predecessor rows that
 * pointed at a ProviderProfile — those stay an explicit reconfigure state.
 */
data class EnhancementBackendConfiguration(
    val configured: Boolean,
    val displayName: String?,
    val endpointID: String,
    val credentialConfigured: Boolean,
    val legacyProviderProfileReferenced: Boolean,
) {
    companion object {
        /**
         * Mirrors `G09R2EnhancerBackendConfiguration.defaultCredentialAccount`
         * on the native side (pinned by the focused contract tests on both
         * sides of the bridge).
         */
        const val DEFAULT_CREDENTIAL_ACCOUNT = "media.enhancement.superResolution"
    }
}

/** Bounded wire failure codes the native side can return. */
object EnhancementErrorCodes {
    const val UNSUPPORTED_COMBINATION = "unsupportedCombination"
    const val SOURCE_TOO_LARGE = "sourceTooLarge"
    const val OUTPUT_TOO_LARGE = "outputTooLarge"
    const val DURATION_TOO_LONG = "durationTooLong"
    const val FRAME_BOUND_EXCEEDED = "frameBoundExceeded"
    const val TARGET_FPS_INVALID = "targetFPSInvalid"
    const val SCALE_INVALID = "scaleInvalid"
    const val SOURCE_UNREADABLE = "sourceUnreadable"
    const val BACKEND_UNAVAILABLE = "backendUnavailable"
    const val TASK_CONTEXT_REQUIRED = "taskBindingRequired"
    const val OUTPUT_EXISTS = "outputExists"
    const val OUTCOME_UNKNOWN = "outcomeUnknown"
    const val CANCELLED = "cancelled"

    // Configuration save refusal codes (closed wire vocabulary).
    const val ENHANCER_INVALID_ENDPOINT = "enhancerInvalidEndpoint"
    const val ENHANCER_INVALID_ACCOUNT = "enhancerInvalidAccount"
    const val ENHANCER_STORE_UNAVAILABLE = "enhancerStoreUnavailable"
    const val ENHANCER_CREDENTIAL_MISSING = "enhancerCredentialMissing"

    val RETRYABLE: Set<String> = setOf(
        BACKEND_UNAVAILABLE, "linuxUnavailable", OUTCOME_UNKNOWN,
        TASK_CONTEXT_REQUIRED, SOURCE_TOO_LARGE, OUTPUT_TOO_LARGE,
        DURATION_TOO_LONG, FRAME_BOUND_EXCEEDED, TARGET_FPS_INVALID,
        SCALE_INVALID, SOURCE_UNREADABLE, UNSUPPORTED_COMBINATION, OUTPUT_EXISTS,
    )
}
