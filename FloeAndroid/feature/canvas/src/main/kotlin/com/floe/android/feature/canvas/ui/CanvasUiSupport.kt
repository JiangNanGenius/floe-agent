// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.canvas.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeStatusLine
import com.floe.android.design.FloeText
import com.floe.android.feature.canvas.CanvasNode
import com.floe.android.feature.canvas.ui.presentation.CanvasFailure
import com.floe.android.feature.canvas.ui.presentation.CanvasFailureKind
import com.floe.android.feature.canvas.ui.presentation.CanvasNotice
import com.floe.android.feature.canvas.ui.presentation.NodeDisplayKind
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

internal fun CanvasFailure.titleRes(): Int = when (kind) {
    CanvasFailureKind.NEEDS_CORE_UPDATE -> R.string.canvas_core_update_title
    CanvasFailureKind.RUNTIME_NOT_READY -> R.string.canvas_runtime_waiting_title
    CanvasFailureKind.REVISION_CONFLICT -> R.string.canvas_failure_revision_title
    CanvasFailureKind.OUTCOME_UNKNOWN -> R.string.canvas_failure_unknown_title
    CanvasFailureKind.NOT_FOUND -> R.string.canvas_failure_not_found_title
    CanvasFailureKind.CORRUPT -> R.string.canvas_failure_corrupt_title
    CanvasFailureKind.TOO_LARGE -> R.string.canvas_failure_too_large_title
    CanvasFailureKind.UNSUPPORTED_SCHEMA -> R.string.canvas_failure_unsupported_title
    CanvasFailureKind.SESSION_LOST -> R.string.canvas_failure_session_title
    CanvasFailureKind.STORAGE -> R.string.canvas_failure_storage_title
    CanvasFailureKind.ASSET -> R.string.canvas_import_failed_title
    CanvasFailureKind.INVALID_REQUEST -> R.string.canvas_operation_failed_title
    CanvasFailureKind.UNKNOWN -> R.string.canvas_operation_failed_title
}

internal fun CanvasFailure.bodyRes(): Int = when (kind) {
    CanvasFailureKind.NEEDS_CORE_UPDATE -> R.string.canvas_core_update_body
    CanvasFailureKind.RUNTIME_NOT_READY -> R.string.canvas_runtime_waiting_body
    CanvasFailureKind.REVISION_CONFLICT -> R.string.canvas_failure_revision_body
    CanvasFailureKind.OUTCOME_UNKNOWN -> R.string.canvas_failure_unknown_body
    CanvasFailureKind.NOT_FOUND -> R.string.canvas_failure_not_found_body
    CanvasFailureKind.CORRUPT -> R.string.canvas_failure_corrupt_body
    CanvasFailureKind.TOO_LARGE -> R.string.canvas_failure_too_large_body
    CanvasFailureKind.UNSUPPORTED_SCHEMA -> R.string.canvas_failure_unsupported_body
    CanvasFailureKind.SESSION_LOST -> R.string.canvas_failure_session_body
    CanvasFailureKind.STORAGE -> R.string.canvas_failure_storage_body
    CanvasFailureKind.ASSET -> R.string.canvas_import_failed_body
    CanvasFailureKind.INVALID_REQUEST -> R.string.canvas_operation_failed_body
    CanvasFailureKind.UNKNOWN -> R.string.canvas_operation_failed_body
}

internal fun CanvasNotice.textRes(): Int = when (this) {
    CanvasNotice.REFERENCE_PENDING -> R.string.canvas_notice_reference_pending
    CanvasNotice.DESIGN_METADATA_READ_ONLY -> R.string.canvas_notice_design_metadata
    CanvasNotice.LEGACY_INK_READ_ONLY -> R.string.canvas_notice_legacy_ink
    CanvasNotice.LEGACY_STROKES_READ_ONLY -> R.string.canvas_notice_legacy_strokes
    CanvasNotice.DELETION_NOT_UNDOABLE -> R.string.canvas_delete_clears_undo
    CanvasNotice.UNDO_NOT_AVAILABLE -> R.string.canvas_undo_unavailable
    CanvasNotice.RELOADED_FROM_DISK -> R.string.canvas_notice_conflict_reloaded
    CanvasNotice.RECOVERY_CHECKED -> R.string.canvas_notice_recovered
}

internal fun NodeDisplayKind.labelRes(): Int = when (this) {
    NodeDisplayKind.TEXT -> R.string.canvas_node_type_text
    NodeDisplayKind.STICKY -> R.string.canvas_node_type_sticky
    NodeDisplayKind.CARD -> R.string.canvas_node_type_card
    NodeDisplayKind.SHAPE -> R.string.canvas_node_type_shape
    NodeDisplayKind.IMAGE -> R.string.canvas_node_type_image
    NodeDisplayKind.VIDEO -> R.string.canvas_node_video
    NodeDisplayKind.AUDIO -> R.string.canvas_node_audio
    NodeDisplayKind.FILE -> R.string.canvas_node_file
    NodeDisplayKind.GROUP -> R.string.canvas_node_group
    NodeDisplayKind.GENERATION -> R.string.canvas_node_generated
    NodeDisplayKind.SCENE_3D -> R.string.canvas_node_scene
    NodeDisplayKind.UNKNOWN -> R.string.canvas_node_placeholder
}

internal fun shapeLabelRes(shape: String?): Int = when (shape) {
    "rectangle" -> R.string.canvas_shape_rectangle
    "ellipse" -> R.string.canvas_shape_ellipse
    "diamond" -> R.string.canvas_shape_diamond
    "triangle" -> R.string.canvas_shape_triangle
    else -> R.string.canvas_shape_rounded
}

internal fun nodeAccessibleTitle(node: CanvasNode, fallback: String): String {
    val text = node.title?.takeIf { it.isNotBlank() }
        ?: node.text.takeIf { it.isNotBlank() }
    return text?.lineSequence()?.firstOrNull()?.take(80) ?: fallback
}

internal fun formatCanvasDate(raw: String): String {
    if (raw.isBlank()) return ""
    return try {
        val instant = Instant.parse(raw)
        DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT)
            .withZone(ZoneId.systemDefault())
            .format(instant)
    } catch (_: Throwable) {
        raw.take(16)
    }
}

@Composable
internal fun CanvasInlineFailure(
    failure: CanvasFailure,
    onRetry: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        FloeStatusLine(
            icon = FloeIcons.WarningTriangle,
            text = stringResource(failure.titleRes()),
            color = Floe.colors.pending,
            style = Floe.typography.bodyEmphasized,
        )
        FloeText(
            stringResource(failure.bodyRes()),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
        if (onRetry != null && failure.retryable) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.End,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FloeCapsuleAction(
                    label = stringResource(R.string.canvas_retry),
                    onClick = onRetry,
                )
            }
        }
    }
}

@Composable
internal fun CanvasInlineNotice(text: String, modifier: Modifier = Modifier) {
    FloeStatusLine(
        icon = FloeIcons.InfoCircle,
        text = text,
        color = Floe.colors.secondaryLabel,
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 6.dp),
    )
}
