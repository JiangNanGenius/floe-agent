// SPDX-License-Identifier: MPL-2.0
//
// C02 tool-result detail pane. It is embedded in the EXISTING tool card's
// expanded evidence area; it is not a replacement conversation surface. Every
// page is an actual UTF-8 byte window from the retained (post-redaction)
// result, and the next cursor is always the reply's nextOffset.
package com.floe.android.feature.toolresults

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloePrimaryAction
import com.floe.android.design.FloeText
import kotlinx.coroutines.launch

/** App-host-provided reader. Null keeps the affordance hidden instead of
 * advertising a pageable result the host cannot serve. */
val LocalToolResultDetailSource = staticCompositionLocalOf<ToolResultDetailSource?> { null }

/**
 * Compact entry placed below the existing tool card evidence. It opens a
 * bounded reader; the card's recorded summary stays untouched above.
 */
@Composable
public fun ToolResultDetailSection(
    taskId: String,
    callId: String,
    temporary: Boolean,
    modifier: Modifier = Modifier,
    runId: String? = null,
    ref: String? = null,
) {
    if (temporary) return
    val source = LocalToolResultDetailSource.current ?: return
    var state by remember(taskId, runId, callId, ref) {
        mutableStateOf(ToolResultDetailReducer.hidden())
    }
    var visible by rememberSaveable(taskId, runId, callId, ref) { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    fun load(offset: Int) {
        val requested = ToolResultDetailReducer.loadingFrom(state, offset)
        state = requested
        scope.launch {
            try {
                val page = source.load(
                    taskId = taskId,
                    runId = runId,
                    callId = callId.takeIf { it.isNotBlank() },
                    // After the first reply, continue by the stable record ref
                    // rather than a call id that a later run could reuse.
                    ref = state.ref ?: ref,
                    offset = offset,
                    maxBytes = ToolResultDetailReducer.defaultPageBytes,
                    expectedSHA256 = state.sha256,
                    temporary = false,
                )
                // A late reply for an offset the user already left must not
                // replace the newer page.
                if (state.offset == offset) {
                    state = ToolResultDetailReducer.loaded(state, page)
                }
            } catch (failure: ToolResultDetailException) {
                if (state.offset == offset) {
                    state = ToolResultDetailReducer.failed(
                        state, failure.code, failure.message ?: "",
                    )
                }
            } catch (failure: Exception) {
                if (state.offset == offset) {
                    state = ToolResultDetailReducer.failed(
                        state, "unavailable", "",
                    )
                }
            }
        }
    }

    // A rotation restores `visible` but not the in-memory page state; reload
    // the first retained window instead of showing an empty open sheet.
    LaunchedEffect(visible, taskId, runId, callId, ref) {
        if (visible && state.phase == ToolResultDetailState.Phase.HIDDEN) {
            state = ToolResultDetailReducer.open(taskId, callId, ref, temporary = false)
            load(0)
        }
    }
    FloeCapsuleAction(
        label = stringResource(R.string.toolresult_open),
        onClick = {
            visible = true
            state = ToolResultDetailReducer.open(taskId, callId, ref, temporary = false)
            load(0)
        },
        modifier = modifier,
    )
    ToolResultDetailPane(
        visible = visible,
        state = state,
        onDismiss = {
            visible = false
            state = ToolResultDetailReducer.dismiss(state)
        },
        onPrevious = prev@{
            val previous = state.previousOffsets.lastOrNull() ?: return@prev
            state = ToolResultDetailReducer.previous(state)
            load(previous)
        },
        onNext = next@{
            val nextOffset = state.nextOffset ?: return@next
            state = ToolResultDetailReducer.next(state)
            load(nextOffset)
        },
        onRetry = {
            val errorCode = state.errorCode
            val restart = errorCode != null && errorCode in setOf(
                "changed", "staleCapture", "cursorMismatch", "badWindow",
                "badIdentity", "badDigest", "offsetOutOfRange",
            )
            val offset = if (restart ||
                state.phase == ToolResultDetailState.Phase.LEGACY_SUMMARY_ONLY
            ) {
                0
            } else {
                state.offset
            }
            state = if (restart) {
                val restarted = ToolResultDetailReducer.restart(state)
                if (errorCode == "badIdentity") restarted.copy(ref = null) else restarted
            } else {
                ToolResultDetailReducer.retry(state)
            }
            load(offset)
        },
    )
}

/** Bounded page reader. `compact` gives phone widths a full-height sheet. */
@Composable
public fun ToolResultDetailPane(
    visible: Boolean,
    state: ToolResultDetailState,
    onDismiss: () -> Unit,
    onPrevious: () -> Unit,
    onNext: () -> Unit,
    onRetry: () -> Unit,
    modifier: Modifier = Modifier,
    compact: Boolean = true,
) {
    if (!visible) return
    FloePageSheet(
        visible = visible,
        onDismiss = onDismiss,
        modifier = modifier,
        widthFraction = if (compact) 1f else 0.72f,
        heightFraction = 0.9f,
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 20.dp, vertical = 16.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                FloeText(
                    stringResource(R.string.toolresult_title),
                    style = Floe.typography.bodyEmphasized,
                    color = Floe.colors.label,
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.toolresult_close),
                    onClick = onDismiss,
                )
            }
            when (state.phase) {
                ToolResultDetailState.Phase.HIDDEN -> Unit
                ToolResultDetailState.Phase.LOADING -> {
                    Row(
                        modifier = Modifier.fillMaxWidth().heightIn(min = 44.dp),
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        FloeActivityIndicator()
                        FloeText(
                            stringResource(R.string.toolresult_loading),
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                        )
                    }
                }
                ToolResultDetailState.Phase.READY -> {
                    val meta = stringResource(
                        R.string.toolresult_meta,
                        state.offset,
                        state.endOffset,
                        state.totalBytes,
                    )
                    FloeText(meta, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                    val captureLabel = when (state.captureState) {
                        "complete" -> stringResource(R.string.toolresult_capture_complete)
                        "retentionTruncated" -> stringResource(R.string.toolresult_capture_retention)
                        "executionOutputTruncated" -> stringResource(R.string.toolresult_capture_upstream)
                        "executionOutputTruncated+retentionTruncated" ->
                            stringResource(R.string.toolresult_capture_both)
                        else -> state.captureState
                    }
                    FloeText(
                        stringResource(R.string.toolresult_capture_state, captureLabel),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                    val durability = state.durability
                    if (durability != null) {
                        val storageLabel = if (durability == "durable") {
                            stringResource(R.string.toolresult_storage_saved)
                        } else {
                            stringResource(R.string.toolresult_storage_memory)
                        }
                        FloeText(
                            stringResource(R.string.toolresult_storage_state, storageLabel),
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                        )
                    }
                    if (state.restoredFromDisk) {
                        FloeText(
                            stringResource(R.string.toolresult_restored),
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                        )
                    }
                    if (state.evictedCopies > 0) {
                        FloeText(
                            stringResource(R.string.toolresult_evicted, state.evictedCopies),
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                        )
                    }
                    FloeDivider()
                    FloeText(
                        state.text,
                        style = Floe.typography.evidence,
                        color = Floe.colors.label,
                    )
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        if (state.hasPrevious) {
                            FloeCapsuleAction(
                                label = stringResource(R.string.toolresult_previous),
                                onClick = onPrevious,
                            )
                        }
                        if (state.hasNext) {
                            FloePrimaryAction(
                                label = stringResource(R.string.toolresult_next),
                                onClick = onNext,
                            )
                        }
                    }
                }
                ToolResultDetailState.Phase.LEGACY_SUMMARY_ONLY -> {
                    FloeText(
                        stringResource(R.string.toolresult_legacy),
                        style = Floe.typography.body,
                        color = Floe.colors.secondaryLabel,
                    )
                    FloePrimaryAction(
                        label = stringResource(R.string.toolresult_retry),
                        onClick = onRetry,
                    )
                }
                ToolResultDetailState.Phase.TEMPORARY_UNAVAILABLE -> {
                    FloeText(
                        stringResource(R.string.toolresult_temporary),
                        style = Floe.typography.body,
                        color = Floe.colors.secondaryLabel,
                    )
                }
                ToolResultDetailState.Phase.ERROR -> {
                    FloeText(
                        stringResource(R.string.toolresult_error),
                        style = Floe.typography.body,
                        color = Floe.colors.destructive,
                    )
                    val errorMessage = state.errorMessage
                    if (errorMessage != null && errorMessage.isNotBlank()) {
                        FloeText(errorMessage, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                    }
                    FloePrimaryAction(
                        label = stringResource(R.string.toolresult_retry),
                        onClick = onRetry,
                    )
                }
            }
        }
    }
}
