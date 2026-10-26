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
     * R2 editable-ready variant — an HONEST edit claim tied to real native
     * facts, never to a read-only getter alone. Requires, for this exact
     * mount: the R1 render witnesses (shape + tile delivery + painted frame
     * + renderer draw), the ordered permission barrier reply after the
     * service issued the real kit command `setviewreadonly value=false`
     * (kit/ChildSession.cpp), the server-originated write-permission frames
     * (`perm: edit` and/or `filemode:{readOnly:false}` — unmasked native
     * truth, wsd/ClientSession.cpp setReadOnly/sendFileMode), a
     * non-load-readonly `.uno:ReadOnly` barrier answer, and no
     * modify-password protection. A degraded EDIT mount (protected document,
     * missing permission frames) falls back to READY_READ_ONLY with an
     * explicit notice and `editPermissionEstablished=false` — it never
     * pretends to be editable.
     */
    READY_EDITABLE,

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
    /**
     * R2 honest close facts (all default-valued, so every R1 call site and
     * parcel reader keeps working):
     *  - [dirtyAtClose] mirrors the kit's last real `statechanged:`
     *    `.uno:ModifiedStatus` fact (false when never observed — the App must
     *    treat "never observed" conservatively, this flag never *proves*
     *    clean);
     *  - [editPermissionEstablished] is true only when the full native
     *    edit-permission witness set completed for this mount;
     *  - [saveReceiptDescriptors] are bounded flat
     *    [OfficeSaveReceipt.descriptorLine] strings for every receipt issued
     *    during the mount, so the App can recover staged-output identities
     *    (paths/sha/bytes) even though the engine process may already be
     *    gone. The App — never this module — decides what those bytes mean
     *    for its own commit ledger.
     */
    val dirtyAtClose: Boolean = false,
    val editPermissionEstablished: Boolean = false,
    val saveReceiptCount: Int = 0,
    val saveReceiptDescriptors: List<String> = emptyList(),
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
        const val EXTRA_DIRTY_AT_CLOSE = "com.floe.android.office.DIRTY_AT_CLOSE"
        const val EXTRA_EDIT_PERMISSION_ESTABLISHED = "com.floe.android.office.EDIT_PERMISSION_ESTABLISHED"
        const val EXTRA_SAVE_RECEIPT_COUNT = "com.floe.android.office.SAVE_RECEIPT_COUNT"
        const val EXTRA_SAVE_RECEIPT_DESCRIPTORS = "com.floe.android.office.SAVE_RECEIPT_DESCRIPTORS"

        /** Bounded descriptor list carried in one Activity result. */
        const val MAX_RECEIPT_DESCRIPTORS = 24

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
                dirtyAtClose = data.getBooleanExtra(EXTRA_DIRTY_AT_CLOSE, false),
                editPermissionEstablished = data.getBooleanExtra(EXTRA_EDIT_PERMISSION_ESTABLISHED, false),
                saveReceiptCount = data.getIntExtra(EXTRA_SAVE_RECEIPT_COUNT, 0),
                saveReceiptDescriptors = data.getStringArrayListExtra(EXTRA_SAVE_RECEIPT_DESCRIPTORS)
                    ?.take(MAX_RECEIPT_DESCRIPTORS)
                    ?.filter { it.isNotEmpty() }
                    ?: emptyList(),
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
    /** R2: the full native edit-permission witness set completed (see READY_EDITABLE). */
    val editPermissionObserved: Boolean = false,
)
