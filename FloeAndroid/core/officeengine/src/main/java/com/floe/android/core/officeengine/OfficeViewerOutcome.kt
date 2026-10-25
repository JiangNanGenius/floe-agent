package com.floe.android.core.officeengine

/** Lifecycle states per the Main host contract (readiness is never implied). */
enum class OfficeViewerState {
    IDLE,

    /** Staged snapshot re-validated (path + digest) and payload unpack running. */
    STAGING,

    /** Native engine initialised for this exact snapshot; page load issued. */
    OPENING,

    /**
     * Page loaded and HULLO handshake completed; waiting for the real render
     * witnesses: document shape (status: JSON), at least one actual tile
     * DELIVERY ("tile:"/"tilecombine:"/"delta:" image message), and a passed
     * painted-frame probe of the visible engine view. An
     * "invalidatetiles:" redraw REQUEST is never sufficient (Main readiness
     * correction 2026-10-26).
     */
    AWAITING_FIRST_RENDER,

    /** All three witnesses observed. The only non-terminal success state in R1. */
    READY_READ_ONLY,

    /**
     * The engine reported a real native `error:` for this mount: the
     * document is not viewable. Honest failure representation (Main
     * decision 2026-10-26) — the host must keep the actual error detail
     * and must NOT keep displaying "Opening" indefinitely. Never a fake
     * READY, and never auto-closed: the user's close of this state is an
     * owned user close (acknowledged) whose outcome stays unclean.
     */
    FAILED,

    /** BYE dispatched; settling exactly once on the close worker. */
    CLOSING,

    /** Terminal for this mount. */
    CLOSED,
}

enum class OfficeFailureCode {
    STAGED_FILE_MISSING,
    STAGED_FILE_MISMATCH,
    UNSUPPORTED_FORMAT,
    PAYLOAD_PREPARE_FAILED,
    NATIVE_LOAD_FAILED,
    ENGINE_BUSY,
    WEBVIEW_ISOLATION_FAILED,
    LOAD_ERROR,
    TRANSPORT_FAILURE,
    ROUTE_UNAVAILABLE,
    SESSION_CANCELLED,
    PROCESS_LOST,
    INTERNAL,
}

/** User-visible outcome read back from the viewer Activity result. */
data class OfficeViewerOutcome(
    val sessionToken: String,
    val closedCleanly: Boolean,
    val failure: OfficeFailureCode?,
    val message: String?,
    /** Document shape witness (twip) when the engine reported one. */
    val witnessWidthTwip: Int,
    val witnessHeightTwip: Int,
    val generation: Long = 0L,
) {
    companion object {
        const val EXTRA_GENERATION = "com.floe.android.office.GENERATION"
        const val EXTRA_REQUEST = "com.floe.android.office.REQUEST"
        const val EXTRA_SESSION_TOKEN = "com.floe.android.office.SESSION_TOKEN"
        const val EXTRA_CLOSED_CLEANLY = "com.floe.android.office.CLOSED_CLEANLY"
        const val EXTRA_FAILURE_CODE = "com.floe.android.office.FAILURE_CODE"
        const val EXTRA_FAILURE_MESSAGE = "com.floe.android.office.FAILURE_MESSAGE"
        const val EXTRA_WITNESS_WIDTH = "com.floe.android.office.WITNESS_WIDTH"
        const val EXTRA_WITNESS_HEIGHT = "com.floe.android.office.WITNESS_HEIGHT"

        /** Rebuild the outcome from an Activity result Intent (null if absent). */
        fun fromResultData(data: android.content.Intent?): OfficeViewerOutcome? {
            val token = data?.getStringExtra(EXTRA_SESSION_TOKEN) ?: return null
            return OfficeViewerOutcome(
                sessionToken = token,
                closedCleanly = data.getBooleanExtra(EXTRA_CLOSED_CLEANLY, false),
                failure = data.getStringExtra(EXTRA_FAILURE_CODE)?.let {
                    runCatching { OfficeFailureCode.valueOf(it) }.getOrNull()
                },
                message = data.getStringExtra(EXTRA_FAILURE_MESSAGE),
                witnessWidthTwip = data.getIntExtra(EXTRA_WITNESS_WIDTH, 0),
                witnessHeightTwip = data.getIntExtra(EXTRA_WITNESS_HEIGHT, 0),
                generation = data.getLongExtra(EXTRA_GENERATION, 0L),
            )
        }
    }
}

/** Fail-closed exception produced by validating factories (message is diagnostic). */
class OfficeException(
    val code: OfficeFailureCode,
    message: String,
) : IllegalArgumentException("$code: $message")

/**
 * Live progress/readiness projection for the viewer chrome. [phaseText] and
 * [percent] mirror genuine engine `progress:` messages only; they are display
 * information, never readiness proof. Readiness requires [documentWitness].
 */
data class OfficeViewerProgress(
    val state: OfficeViewerState,
    val phaseText: String?,
    val percent: Int?,
    val documentWitness: OfficeDocumentWitness?,
    val sessionToken: String = "",
    val generation: Long = 0L,
)

/**
 * Concrete render witnesses per the host contract (Main readiness
 * correction 2026-10-26): document dimensions + actual tile deliveries + the
 * passed painted-frame probe. [tilesInvalidateCount] is diagnostic only —
 * invalidation is a redraw request, never proof anything was painted.
 */
data class OfficeDocumentWitness(
    val widthTwip: Int,
    val heightTwip: Int,
    val tileDeliveryCount: Int,
    val paintedFrameVerified: Boolean,
    val tilesInvalidateCount: Int,
    val readOnlyBarrierObserved: Boolean = false,
    val rendererDrawVerified: Boolean = false,
)
