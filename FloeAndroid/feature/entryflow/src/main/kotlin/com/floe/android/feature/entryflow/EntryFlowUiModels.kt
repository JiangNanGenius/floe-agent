// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.entryflow

/**
 * C07 App-entry presentation models.
 *
 * These types carry display metadata only: file names, counts, byte sizes and
 * user-authored text previews. URIs, paths, grants, IDs and runtime handles
 * stay in the App-owned host and never cross into presentation or logs.
 */

public enum class EntrySharePhase { PREPARING, READY, WORKING, COMPLETE, FAILED }

public enum class EntryShareDestination { TASK, NOTES }

public enum class EntryShareError {
    EMPTY,
    STALE,
    BUSY,
    TEMP_REFUSED,
    GRANT_REVOKED,
    TOO_LARGE,
    ITEM_LIMIT,
    UNSUPPORTED,
    UNREADABLE,
    NOTES_UNAVAILABLE,
    STAGING_UNAVAILABLE,
    FAILED,
}

public data class EntryShareItemUi(
    val displayName: String,
    val byteCount: Long,
    val isText: Boolean,
)

public data class EntryShareUi(
    val items: List<EntryShareItemUi>,
    val textPreview: String?,
    val phase: EntrySharePhase,
    val checkedCount: Int = 0,
    val totalCount: Int = 0,
    val destination: EntryShareDestination? = null,
    val error: EntryShareError? = null,
    val savedNotes: Int = 0,
    val canOpenNotes: Boolean = false,
    /** Opaque live-intake identity; presentation forwards it back, never
     * treats it as a file/task/permission identity. */
    val intakeID: String? = null,
) {
    val itemCount: Int get() = items.size
}

public enum class EntrySetupStep { WELCOME, MODELS, VOICE, FILES, NOTIFICATIONS, DONE }

public data class EntrySetupUi(
    val step: EntrySetupStep,
    val index: Int,
    val total: Int,
    val visible: Boolean,
) {
    val canGoBack: Boolean get() = index > 0
    val isLast: Boolean get() = step == EntrySetupStep.DONE
}

public enum class EntryFeedbackPhase { IDLE, PREPARING, WRITING, COMPLETE, FAILED, CANCELLED }

public enum class EntryFeedbackError { EMPTY_PROBLEM, TOO_LONG, WRITE_FAILED, UNAVAILABLE, CANCELLED }

public data class EntryExportReceiptUi(
    val byteCount: Long,
    val sha256Prefix: String,
)

public data class EntryFeedbackUi(
    val problem: String = "",
    val includeDiagnostics: Boolean = true,
    val phase: EntryFeedbackPhase = EntryFeedbackPhase.IDLE,
    val receipt: EntryExportReceiptUi? = null,
    val error: EntryFeedbackError? = null,
) {
    val busy: Boolean
        get() = phase == EntryFeedbackPhase.PREPARING || phase == EntryFeedbackPhase.WRITING
}

public enum class EntryNoticeKind {
    INVALID_LINK,
    TASK_UNAVAILABLE,
    SCHEDULE_UNAVAILABLE,
    SHARE_UNAVAILABLE,
    BUSY,
    ALREADY_HANDLED,
    DISCARDED,
    OPEN_FAILED,
    TEMP_REFUSED,
    TOO_LARGE,
    ITEM_LIMIT,
    UNSUPPORTED,
    GRANT_REVOKED,
    UNREADABLE,
    NOTES_UNAVAILABLE,
    STAGING_UNAVAILABLE,
    UNAVAILABLE,
}
