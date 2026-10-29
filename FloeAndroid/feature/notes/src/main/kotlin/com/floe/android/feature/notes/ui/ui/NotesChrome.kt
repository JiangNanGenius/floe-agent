// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui.ui

import android.graphics.BitmapFactory
import android.text.format.DateUtils
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeBadgePill
import com.floe.android.design.FloeBadgeTone
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloeText
import com.floe.android.design.IconGlyph
import com.floe.android.feature.notes.NoteDocumentSummary
import com.floe.android.feature.notes.NoteDocumentKind
import com.floe.android.feature.notes.ui.NotesIcons
import com.floe.android.feature.notes.ui.R
import com.floe.android.feature.notes.ui.presentation.NotesFailure
import com.floe.android.feature.notes.ui.presentation.NotesSaveStatus
import java.util.Locale
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@Composable
internal fun notesDate(millis: Double): String {
    if (millis <= 0.0) return stringResource(R.string.notes_unknown_date)
    return remember(millis) {
        DateUtils.getRelativeTimeSpanString(
            millis.toLong(),
            System.currentTimeMillis(),
            DateUtils.MINUTE_IN_MILLIS,
        ).toString()
    }
}

@Composable
internal fun notesLocaleDate(millis: Double): String {
    if (millis <= 0.0) return stringResource(R.string.notes_unknown_date)
    return remember(millis) {
        java.text.DateFormat.getDateInstance(java.text.DateFormat.MEDIUM, Locale.getDefault())
            .format(java.util.Date(millis.toLong()))
    }
}

@Composable
internal fun NotesIconAction(
    icon: ImageVector,
    contentDescription: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    tint: Color = Floe.colors.label,
    visualSize: Dp = 36.dp,
) {
    FloeCircleButton(
        icon = icon,
        contentDescription = contentDescription,
        onClick = onClick,
        modifier = modifier,
        enabled = enabled,
        visualSize = visualSize,
        iconSize = 20.dp,
        tint = tint,
    )
}

@Composable
internal fun NotesToolbar(
    title: String,
    modifier: Modifier = Modifier,
    navigation: (@Composable RowScope.() -> Unit)? = null,
    actions: (@Composable RowScope.() -> Unit)? = null,
    subtitle: String? = null,
    showHairline: Boolean = true,
) {
    Column(modifier.fillMaxWidth().background(Floe.colors.chromeSurface)) {
        Row(
            modifier = Modifier.fillMaxWidth().heightIn(min = 54.dp).padding(horizontal = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            navigation?.let {
                Row(verticalAlignment = Alignment.CenterVertically, content = it)
            }
            Column(
                modifier = Modifier.weight(1f).padding(horizontal = 4.dp),
                verticalArrangement = Arrangement.Center,
            ) {
                FloeText(
                    title,
                    style = Floe.typography.toolbarTitle,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (subtitle != null) {
                    FloeText(
                        subtitle,
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            actions?.let {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(2.dp),
                    content = it,
                )
            }
        }
        if (showHairline) FloeDivider()
    }
}

@Composable
internal fun NotesFilterChip(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    count: Int? = null,
) {
    val shape = FloeLayout.SidebarSelectionShape
    Row(
        modifier = modifier
            .heightIn(min = FloeLayout.MinimumTarget)
            .clip(shape)
            .background(if (selected) Floe.colors.accent else Floe.colors.chromeSurface)
            .border(0.5.dp, if (selected) Color.Transparent else Floe.colors.chromeHairline, shape)
            .clickable(role = Role.Tab, onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        FloeText(
            label,
            style = Floe.typography.metadata,
            color = if (selected) Color.White else Floe.colors.label,
            maxLines = 1,
        )
        if (count != null) {
            FloeText(
                count.toString(),
                style = Floe.typography.metadata,
                color = if (selected) Color.White.copy(alpha = 0.75f) else Floe.colors.tertiaryLabel,
            )
        }
    }
}

@Composable
internal fun NotesChipRow(content: @Composable RowScope.() -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 12.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
        content = content,
    )
}

internal fun NotesKindIcon(kind: NoteDocumentKind): ImageVector =
    when (kind) {
        NoteDocumentKind.NOTEBOOK -> FloeIcons.BookPages
        NoteDocumentKind.MIND_MAP -> NotesIcons.MindMap
        NoteDocumentKind.OFFICE -> NotesIcons.Document
        NoteDocumentKind.ENGINEERING -> NotesIcons.Document
    }

@Composable
internal fun NotesKindLabel(kind: NoteDocumentKind): String = when (kind) {
    NoteDocumentKind.NOTEBOOK -> stringResource(R.string.notes_kind_note)
    NoteDocumentKind.MIND_MAP -> stringResource(R.string.notes_kind_mind_map)
    NoteDocumentKind.OFFICE -> stringResource(R.string.notes_kind_office)
    NoteDocumentKind.ENGINEERING -> stringResource(R.string.notes_kind_engineering)
}

@Composable
internal fun NotesSummaryLine(summary: NoteDocumentSummary): String = when (summary.kind) {
    NoteDocumentKind.NOTEBOOK -> stringResource(R.string.notes_page_count, summary.pageCount)
    NoteDocumentKind.MIND_MAP -> stringResource(R.string.notes_topic_count, summary.nodeCount)
    NoteDocumentKind.OFFICE -> summary.officeFileName ?: stringResource(R.string.notes_office_file)
    NoteDocumentKind.ENGINEERING -> summary.engineeringFileName ?: stringResource(R.string.notes_engineering_file)
}

@Composable
internal fun NotesFailureText(failure: NotesFailure): String = when (failure.code) {
    "notFound" -> stringResource(R.string.notes_failure_not_found)
    "conflict" -> stringResource(R.string.notes_failure_conflict)
    "invalidDocument" -> stringResource(R.string.notes_failure_invalid)
    "storageUnavailable" -> stringResource(R.string.notes_failure_storage)
    "notesNotBound", "staleGeneration" -> stringResource(R.string.notes_failure_not_ready)
    "resourceUnavailable", "stageNotFound", "stageExpired" -> stringResource(R.string.notes_failure_resource)
    "passwordRequired", "passwordProtected" -> stringResource(R.string.notes_pdf_password_unsupported)
    "unsupportedAction" -> stringResource(R.string.notes_failure_unsupported)
    "requestTooLarge", "responseTooLarge" -> stringResource(R.string.notes_failure_too_large)
    "busy" -> stringResource(R.string.notes_failure_busy)
    "transportFailure", "invalidResponse" -> stringResource(R.string.notes_failure_transport)
    "notConfigured", "notConnected" -> stringResource(R.string.notes_failure_not_configured)
    "cancelled" -> stringResource(R.string.notes_failure_cancelled)
    "permissionDenied" -> stringResource(R.string.notes_failure_permission)
    "portUnavailable" -> stringResource(R.string.notes_failure_port_unavailable)
    "officeCreatePrepareFailed" -> stringResource(R.string.notes_office_create_prepare_failed)
    "officeCreateResourceFailed" -> stringResource(R.string.notes_office_create_resource_failed)
    "officeCreateDocumentFailed" -> stringResource(R.string.notes_office_create_document_failed)
    else -> stringResource(R.string.notes_failure_generic)
}

@Composable
internal fun NotesStatusDot(status: NotesSaveStatus) {
    val color = when (status) {
        NotesSaveStatus.SAVED -> Floe.colors.success
        NotesSaveStatus.DIRTY, NotesSaveStatus.SAVING -> Floe.colors.pending
        NotesSaveStatus.FAILED, NotesSaveStatus.CONFLICT -> Floe.colors.destructive
        NotesSaveStatus.BLOCKED -> Floe.colors.tertiaryLabel
    }
    Box(modifier = Modifier.size(8.dp).clip(CircleShape).background(color))
}

@Composable
internal fun NotesSaveStatusLabel(status: NotesSaveStatus): String = when (status) {
    NotesSaveStatus.SAVED -> stringResource(R.string.notes_saved)
    NotesSaveStatus.DIRTY -> stringResource(R.string.notes_dirty)
    NotesSaveStatus.SAVING -> stringResource(R.string.notes_saving)
    NotesSaveStatus.FAILED -> stringResource(R.string.notes_save_failed)
    NotesSaveStatus.CONFLICT -> stringResource(R.string.notes_conflict)
    NotesSaveStatus.BLOCKED -> stringResource(R.string.notes_read_only_deleted)
}

@Composable
internal fun NotesErrorBanner(
    failure: NotesFailure,
    onRetry: (() -> Unit)? = null,
    onDismiss: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    NotesBanner(
        icon = FloeIcons.WarningTriangle,
        text = NotesFailureText(failure),
        tone = Floe.colors.destructive,
        modifier = modifier,
        actionLabel = onRetry?.let { stringResource(R.string.notes_retry) },
        onAction = onRetry,
        dismissLabel = onDismiss?.let { stringResource(R.string.notes_dismiss) },
        onDismiss = onDismiss,
    )
}

@Composable
internal fun NotesBanner(
    icon: ImageVector,
    text: String,
    tone: Color,
    modifier: Modifier = Modifier,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
    dismissLabel: String? = null,
    onDismiss: (() -> Unit)? = null,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .background(tone.copy(alpha = 0.10f))
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        IconGlyph(icon, tone, 18.dp)
        FloeText(
            text,
            style = Floe.typography.metadata,
            color = Floe.colors.label,
            modifier = Modifier.weight(1f),
            maxLines = 3,
            overflow = TextOverflow.Ellipsis,
        )
        if (actionLabel != null && onAction != null) {
            Box(
                modifier = Modifier
                    .heightIn(min = FloeLayout.MinimumTarget)
                    .clickable(role = Role.Button, onClick = onAction)
                    .padding(horizontal = 8.dp),
                contentAlignment = Alignment.Center,
            ) { FloeText(actionLabel, style = Floe.typography.metadata, color = tone) }
        }
        if (dismissLabel != null && onDismiss != null) {
            Box(
                modifier = Modifier
                    .heightIn(min = FloeLayout.MinimumTarget)
                    .clickable(role = Role.Button, onClick = onDismiss)
                    .padding(horizontal = 8.dp),
                contentAlignment = Alignment.Center,
            ) { FloeText(dismissLabel, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel) }
        }
    }
}

@Composable
internal fun NotesSectionLabel(text: String, modifier: Modifier = Modifier) {
    FloeText(
        text,
        style = Floe.typography.groupHeader,
        color = Floe.colors.secondaryLabel,
        modifier = modifier.padding(horizontal = 16.dp, vertical = 8.dp),
    )
}

@Composable
internal fun NotesValueRow(
    label: String,
    value: String,
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)? = null,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = FloeLayout.MinimumTarget)
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        FloeText(label, style = Floe.typography.body, modifier = Modifier.weight(1f))
        FloeText(
            value,
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** Decoded custom cover; decoding is cached by the exact byte array. */
@Composable
internal fun NotesImageBytes(
    bytes: ByteArray?,
    contentDescription: String?,
    modifier: Modifier = Modifier,
) {
    val bitmap by produceState<android.graphics.Bitmap?>(initialValue = null, bytes) {
        value = withContext(Dispatchers.Default) {
            bytes?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }
        }
    }
    val decoded = bitmap
    if (decoded != null) {
        Image(
            bitmap = decoded.asImageBitmap(),
            contentDescription = contentDescription,
            contentScale = androidx.compose.ui.layout.ContentScale.Crop,
            modifier = modifier,
        )
    } else {
        Box(
            modifier = modifier.background(Floe.colors.fillTertiary),
            contentAlignment = Alignment.Center,
        ) {
            IconGlyph(FloeIcons.Photo, Floe.colors.secondaryLabel, 24.dp)
        }
    }
}

@Composable
internal fun NotesAutomaticCover(summary: NoteDocumentSummary, modifier: Modifier = Modifier) {
    val kind = when (summary.kind) {
        NoteDocumentKind.NOTEBOOK -> stringResource(R.string.notes_kind_note)
        NoteDocumentKind.MIND_MAP -> stringResource(R.string.notes_kind_mind_map)
        NoteDocumentKind.OFFICE -> stringResource(R.string.notes_kind_office)
        NoteDocumentKind.ENGINEERING -> stringResource(R.string.notes_kind_engineering)
    }
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(10.dp))
            .background(Floe.colors.readingSurface)
            .border(0.5.dp, Floe.colors.chromeHairline, RoundedCornerShape(10.dp))
            .padding(12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            IconGlyph(NotesKindIcon(summary.kind), Floe.colors.accent, 16.dp)
            FloeText(kind, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel, maxLines = 1)
            Spacer(Modifier.weight(1f))
            if (summary.isFavorite) {
                IconGlyph(NotesIcons.StarFilled, Floe.colors.pending, 14.dp)
            }
        }
        Spacer(Modifier.height(8.dp))
        FloeText(
            summary.title,
            style = Floe.typography.section,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        Spacer(Modifier.height(4.dp))
        FloeText(
            summary.preview.ifBlank { NotesSummaryLine(summary) },
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
            maxLines = if (summary.kind == NoteDocumentKind.MIND_MAP) 5 else 4,
            overflow = TextOverflow.Ellipsis,
        )
        Spacer(Modifier.weight(1f))
        FloeText(
            notesDate(summary.updatedAt),
            style = Floe.typography.metadata,
            color = Floe.colors.tertiaryLabel,
            maxLines = 1,
        )
    }
}

@Composable
internal fun NotesSaveBadge(status: NotesSaveStatus, modifier: Modifier = Modifier) {
    val tone = when (status) {
        NotesSaveStatus.SAVED -> FloeBadgeTone.SECONDARY
        NotesSaveStatus.DIRTY, NotesSaveStatus.SAVING -> FloeBadgeTone.PENDING
        NotesSaveStatus.FAILED, NotesSaveStatus.CONFLICT -> FloeBadgeTone.DESTRUCTIVE
        NotesSaveStatus.BLOCKED -> FloeBadgeTone.SECONDARY
    }
    FloeBadgePill(text = NotesSaveStatusLabel(status), tone = tone, modifier = modifier)
}

@Composable
internal fun notesSemanticsDescription(text: String): Modifier =
    Modifier.semantics { contentDescription = text }

@Composable
internal fun NotesFill(modifier: Modifier = Modifier) {
    Box(modifier.fillMaxSize().background(Floe.colors.readingSurface))
}

@Composable
internal fun NotesHairline(modifier: Modifier = Modifier) {
    FloeDivider(modifier = modifier.fillMaxWidth())
}

@Composable
internal fun NotesVerticalHairline() {
    Box(Modifier.width(0.5.dp).height(24.dp).background(Floe.colors.separator))
}

@Composable
internal fun NotesPill(label: String, color: Color = Floe.colors.accent) {
    Box(
        modifier = Modifier
            .clip(FloeLayout.SidebarSelectionShape)
            .background(color.copy(alpha = 0.12f))
            .padding(horizontal = 8.dp, vertical = 3.dp),
    ) {
        FloeText(label, style = Floe.typography.metadata, color = color, maxLines = 1)
    }
}
