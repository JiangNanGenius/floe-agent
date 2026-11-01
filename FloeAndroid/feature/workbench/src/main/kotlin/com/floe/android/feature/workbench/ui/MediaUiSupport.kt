// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui

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
import com.floe.android.feature.workbench.ImageLayer
import com.floe.android.feature.workbench.MediaAssetReference
import com.floe.android.feature.workbench.ui.presentation.MediaFailure
import com.floe.android.feature.workbench.ui.presentation.MediaFailureKind
import com.floe.android.feature.workbench.ui.presentation.MediaNotice
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

internal fun MediaFailure.titleRes(): Int = when (kind) {
    MediaFailureKind.NEEDS_CORE_UPDATE -> R.string.media_core_update_title
    MediaFailureKind.RUNTIME_NOT_READY -> R.string.media_runtime_waiting_title
    MediaFailureKind.REVISION_CONFLICT -> R.string.media_failure_revision_title
    MediaFailureKind.OUTCOME_UNKNOWN -> R.string.media_failure_unknown_title
    MediaFailureKind.NOT_FOUND -> R.string.media_failure_not_found_title
    MediaFailureKind.CORRUPT -> R.string.media_failure_corrupt_title
    MediaFailureKind.TOO_LARGE -> R.string.media_failure_too_large_title
    MediaFailureKind.OWNER_BLOCKED -> R.string.media_failure_owner_title
    MediaFailureKind.ORIGIN_REQUIRED -> R.string.media_failure_owner_title
    MediaFailureKind.STORAGE -> R.string.media_failure_storage_title
    MediaFailureKind.ASSET -> R.string.media_asset_import_failed_title
    MediaFailureKind.SESSION_LOST -> R.string.media_failure_session_title
    MediaFailureKind.INVALID_REQUEST -> R.string.media_operation_failed_title
    MediaFailureKind.UNKNOWN -> R.string.media_operation_failed_title
}

internal fun MediaFailure.bodyRes(): Int = when (kind) {
    MediaFailureKind.NEEDS_CORE_UPDATE -> R.string.media_core_update_body
    MediaFailureKind.RUNTIME_NOT_READY -> R.string.media_runtime_waiting_body
    MediaFailureKind.REVISION_CONFLICT -> R.string.media_failure_revision_body
    MediaFailureKind.OUTCOME_UNKNOWN -> R.string.media_failure_unknown_body
    MediaFailureKind.NOT_FOUND -> R.string.media_failure_not_found_body
    MediaFailureKind.CORRUPT -> R.string.media_failure_corrupt_body
    MediaFailureKind.TOO_LARGE -> R.string.media_failure_too_large_body
    MediaFailureKind.OWNER_BLOCKED -> R.string.media_failure_owner_body
    MediaFailureKind.ORIGIN_REQUIRED -> R.string.media_failure_origin_body
    MediaFailureKind.STORAGE -> R.string.media_failure_storage_body
    MediaFailureKind.ASSET -> R.string.media_asset_import_failed_body
    MediaFailureKind.SESSION_LOST -> R.string.media_failure_session_body
    MediaFailureKind.INVALID_REQUEST -> R.string.media_operation_failed_body
    MediaFailureKind.UNKNOWN -> R.string.media_operation_failed_body
}

internal fun MediaNotice.textRes(): Int = when (this) {
    MediaNotice.ASSET_IMPORTED -> R.string.media_asset_imported
    MediaNotice.ASSET_IMPORTED_NO_LAYER -> R.string.media_asset_imported_no_layer
    MediaNotice.RELOADED -> R.string.media_reloaded
    MediaNotice.LAYER_REMOVED -> R.string.media_layer_delete
    MediaNotice.MISSING_ASSETS -> R.string.media_missing_asset_title
}

internal fun layerKindLabelRes(layer: ImageLayer): Int = when (layer.kind) {
    "image" -> R.string.media_layer_image
    "text" -> R.string.media_layer_text
    "freehand" -> R.string.media_layer_freehand
    "fill" -> R.string.media_layer_fill
    else -> R.string.media_layer_name_unnamed
}

internal fun mediaKindLabelRes(kind: String): Int =
    if (kind == "video") R.string.media_kind_video else R.string.media_kind_image

internal fun originLabelRes(kind: String?): Int = when (kind) {
    "workspace" -> R.string.media_origin_workspace
    "files" -> R.string.media_origin_files
    "chat" -> R.string.media_origin_chat
    "canvas" -> R.string.media_origin_canvas
    else -> R.string.media_origin_standalone
}

internal fun mediaAssetKindLabelRes(asset: MediaAssetReference): Int = when (asset.kind) {
    "image" -> R.string.media_asset_kind_image
    "video" -> R.string.media_asset_kind_video
    else -> R.string.media_asset_kind_other
}

internal fun assetMeta(asset: MediaAssetReference): String {
    val bytes = asset.byteCount
    val size = if (bytes != null && bytes > 0) formatBytes(bytes) else "—"
    return size
}

internal fun formatBytes(bytes: Long): String {
    if (bytes < 1024) return "$bytes B"
    val kb = bytes / 1024.0
    if (kb < 1024) return String.format(java.util.Locale.US, "%.0f KB", kb)
    val mb = kb / 1024.0
    if (mb < 1024) return String.format(java.util.Locale.US, "%.1f MB", mb)
    return String.format(java.util.Locale.US, "%.2f GB", mb / 1024.0)
}

internal fun formatMediaDate(raw: String): String {
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
internal fun MediaInlineFailure(
    failure: MediaFailure,
    onRetry: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
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
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.End,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FloeCapsuleAction(
                    label = stringResource(R.string.media_retry),
                    onClick = onRetry,
                )
            }
        }
    }
}

@Composable
internal fun MediaInlineNotice(text: String, modifier: Modifier = Modifier) {
    FloeStatusLine(
        icon = FloeIcons.InfoCircle,
        text = text,
        color = Floe.colors.secondaryLabel,
        modifier = modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
    )
}
