// SPDX-License-Identifier: MPL-2.0
//
// C02 pure paging state machine. It enforces the actual wire contract before
// any bytes reach the screen:
//   * a page must start at the expected offset;
//   * text byte length must equal endOffset - offset;
//   * a non-null nextOffset must equal endOffset (the cursor never skips);
//   * totalBytes must cover the page;
//   * every page must carry the same retained digest and ref.
// Missing/legacy, changed, temporary and corrupt states stay explicit.
package com.floe.android.feature.toolresults

data class ToolResultDetailState(
    val phase: Phase = Phase.HIDDEN,
    val taskId: String = "",
    val callId: String? = null,
    val ref: String? = null,
    val offset: Int = 0,
    val endOffset: Int = 0,
    val totalBytes: Int = 0,
    val text: String = "",
    val sha256: String? = null,
    val originalDigest: String? = null,
    val nextOffset: Int? = null,
    val previousOffsets: List<Int> = emptyList(),
    val captureState: String = "complete",
    val durability: String? = null,
    val restoredFromDisk: Boolean = false,
    val evictedCopies: Int = 0,
    val errorCode: String? = null,
    val errorMessage: String? = null,
    val inFlight: Boolean = false,
) {
    enum class Phase {
        HIDDEN,
        LOADING,
        READY,
        LEGACY_SUMMARY_ONLY,
        TEMPORARY_UNAVAILABLE,
        ERROR,
    }

    val hasNext: Boolean get() = phase == Phase.READY && nextOffset != null
    val hasPrevious: Boolean get() = phase == Phase.READY && previousOffsets.isNotEmpty()
}

object ToolResultDetailReducer {
    const val defaultPageBytes = 4_096
    const val maximumPageBytes = 32_000

    fun hidden(): ToolResultDetailState = ToolResultDetailState()

    fun open(
        taskId: String,
        callId: String?,
        ref: String?,
        temporary: Boolean,
        pageBytes: Int = defaultPageBytes,
    ): ToolResultDetailState {
        if (temporary) {
            return ToolResultDetailState(
                phase = ToolResultDetailState.Phase.TEMPORARY_UNAVAILABLE,
                taskId = taskId,
                callId = callId,
                ref = ref,
            )
        }
        return ToolResultDetailState(
            phase = ToolResultDetailState.Phase.LOADING,
            taskId = taskId,
            callId = callId,
            ref = ref,
            offset = 0,
            inFlight = true,
            // The requested page size is only a UI hint; the next offset is
            // always taken from the actual reply.
        )
    }

    fun loadingFrom(
        state: ToolResultDetailState,
        offset: Int,
    ): ToolResultDetailState {
        if (state.phase == ToolResultDetailState.Phase.TEMPORARY_UNAVAILABLE) return state
        return state.copy(
            phase = ToolResultDetailState.Phase.LOADING,
            offset = maxOf(0, offset),
            inFlight = true,
            errorCode = null,
            errorMessage = null,
        )
    }

    fun loaded(
        state: ToolResultDetailState,
        page: ToolResultPageUi,
    ): ToolResultDetailState {
        fun invalid(code: String, message: String): ToolResultDetailState =
            state.copy(
                phase = ToolResultDetailState.Phase.ERROR,
                inFlight = false,
                errorCode = code,
                errorMessage = message,
            )

        if (page.ref.length != 27 || !page.ref.startsWith("tr_") ||
            !page.ref.drop(3).all { it in '0'..'9' || it in 'a'..'f' }
        ) {
            return invalid("badIdentity", "The retained result identity is invalid.")
        }
        if (page.sha256.length != 64 ||
            !page.sha256.all { it in '0'..'9' || it in 'a'..'f' }
        ) {
            return invalid("badDigest", "The retained result digest is invalid.")
        }
        if (state.ref != null && state.ref != page.ref) {
            return invalid("changed", "The retained result changed; reopen it from offset 0.")
        }
        val expectedOffset = when (state.phase) {
            ToolResultDetailState.Phase.READY,
            ToolResultDetailState.Phase.LOADING -> state.offset
            else -> page.offset
        }
        if (page.offset != expectedOffset) {
            return invalid(
                "cursorMismatch",
                "The reply started at ${page.offset} but the next requested offset was $expectedOffset.",
            )
        }
        if (page.totalBytes < page.endOffset || page.endOffset < page.offset) {
            return invalid("badWindow", "The reply's byte extent is inconsistent.")
        }
        val actualBytes = page.text.toByteArray(Charsets.UTF_8).size
        if (actualBytes != page.endOffset - page.offset) {
            return invalid(
                "badWindow",
                "The reply declared ${page.endOffset - page.offset} bytes but delivered $actualBytes.",
            )
        }
        val next = page.nextOffset
        if (next != null && next != page.endOffset) {
            return invalid("cursorMismatch", "nextOffset must equal endOffset.")
        }
        if (next != null && next <= page.offset) {
            return invalid("cursorMismatch", "nextOffset did not advance.")
        }
        if (next != null && page.endOffset >= page.totalBytes) {
            return invalid("badWindow", "A completed result advertised another page.")
        }
        if (next == null && page.endOffset < page.totalBytes) {
            return invalid("badWindow", "The page ended before the retained output.")
        }
        if (state.sha256 != null && state.sha256 != page.sha256) {
            return invalid("staleCapture", "The retained result changed between pages.")
        }
        val history = if (state.phase == ToolResultDetailState.Phase.READY &&
            page.offset != state.offset
        ) {
            state.previousOffsets + state.offset
        } else {
            state.previousOffsets
        }
        return state.copy(
            phase = ToolResultDetailState.Phase.READY,
            taskId = state.taskId,
            callId = if (page.callId.isNotEmpty()) page.callId else state.callId,
            ref = page.ref,
            offset = page.offset,
            endOffset = page.endOffset,
            totalBytes = page.totalBytes,
            text = page.text,
            sha256 = page.sha256,
            originalDigest = page.originalDigest,
            nextOffset = next,
            previousOffsets = history,
            captureState = page.captureState,
            durability = page.durability,
            restoredFromDisk = page.restoredFromDisk,
            evictedCopies = page.evictedCopies,
            inFlight = false,
            errorCode = null,
            errorMessage = null,
        )
    }

    fun failed(
        state: ToolResultDetailState,
        code: String,
        message: String,
    ): ToolResultDetailState {
        return when (code) {
            "missing" -> state.copy(
                phase = ToolResultDetailState.Phase.LEGACY_SUMMARY_ONLY,
                inFlight = false,
                errorCode = code,
                errorMessage = message,
            )
            "temporaryTaskRefused" -> state.copy(
                phase = ToolResultDetailState.Phase.TEMPORARY_UNAVAILABLE,
                inFlight = false,
                errorCode = code,
                errorMessage = message,
            )
            else -> state.copy(
                phase = ToolResultDetailState.Phase.ERROR,
                inFlight = false,
                errorCode = code,
                errorMessage = message,
            )
        }
    }

    fun next(state: ToolResultDetailState): ToolResultDetailState {
        val next = state.nextOffset ?: return state
        val history = if (state.phase == ToolResultDetailState.Phase.READY) {
            state.previousOffsets + state.offset
        } else {
            state.previousOffsets
        }
        return loadingFrom(state.copy(previousOffsets = history), next)
    }

    fun previous(state: ToolResultDetailState): ToolResultDetailState {
        val offset = state.previousOffsets.lastOrNull() ?: return state
        return loadingFrom(
            state.copy(previousOffsets = state.previousOffsets.dropLast(1)),
            offset,
        )
    }

    /** Restarts a changed/corrupt page sequence at offset 0. The stable ref
     * is kept (it names the current record), but the old digest/bytes are
     * cleared so they cannot be mixed with the new revision. */
    fun restart(state: ToolResultDetailState): ToolResultDetailState = state.copy(
        phase = ToolResultDetailState.Phase.LOADING,
        offset = 0,
        endOffset = 0,
        totalBytes = 0,
        text = "",
        sha256 = null,
        originalDigest = null,
        nextOffset = null,
        previousOffsets = emptyList(),
        inFlight = true,
        errorCode = null,
        errorMessage = null,
    )

    fun retry(state: ToolResultDetailState): ToolResultDetailState {
        if (state.phase == ToolResultDetailState.Phase.LEGACY_SUMMARY_ONLY) {
            return loadingFrom(state, 0)
        }
        return loadingFrom(state, state.offset)
    }

    fun dismiss(state: ToolResultDetailState): ToolResultDetailState = state.copy(
        phase = ToolResultDetailState.Phase.HIDDEN,
        inFlight = false,
    )
}
