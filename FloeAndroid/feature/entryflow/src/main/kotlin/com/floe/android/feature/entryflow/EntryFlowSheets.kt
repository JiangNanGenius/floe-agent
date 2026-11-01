// SPDX-License-Identifier: MPL-2.0
@file:OptIn(io.github.robinpcrd.cupertino.ExperimentalCupertinoApi::class)

package com.floe.android.feature.entryflow

import android.text.format.Formatter
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActionSheet
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeCapsuleButton
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloePrimaryAction
import com.floe.android.design.FloeText
import io.github.robinpcrd.cupertino.CupertinoActivityIndicator

/**
 * Share/open arrival chooser. Presentation only: the App host has already
 * checked types, bounded sizes and grants; this surface only asks the person
 * where the bytes should land. Nothing is sent or run by arriving here.
 */
@Composable
public fun EntryShareSheet(
    visible: Boolean,
    state: EntryShareUi,
    onDismiss: () -> Unit,
    onChooseTask: () -> Unit,
    onChooseNotes: () -> Unit,
    onDiscard: () -> Unit,
    onOpenNotes: () -> Unit,
) {
    val colors = Floe.colors
    val context = LocalContext.current
    FloeActionSheet(visible = visible, onDismiss = onDismiss, maxCardWidth = 560.dp) {
        Column(
            Modifier
                .fillMaxWidth()
                .heightIn(max = 640.dp)
                .padding(horizontal = 20.dp, vertical = 16.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                FloeText(
                    stringResource(R.string.entry_share_title),
                    style = Floe.typography.title,
                    modifier = Modifier.weight(1f),
                )
                if (state.phase != EntrySharePhase.COMPLETE) {
                    FloeCapsuleAction(
                        label = stringResource(R.string.entry_share_cancel),
                        onClick = onDiscard,
                        enabled = state.phase != EntrySharePhase.WORKING,
                    )
                }
            }
            Spacer(Modifier.height(6.dp))
            FloeText(
                stringResource(
                    R.string.entry_share_body,
                    if (state.items.isEmpty()) state.totalCount else state.itemCount,
                ),
                style = Floe.typography.metadata,
                color = colors.secondaryLabel,
            )
            Spacer(Modifier.height(10.dp))
            FloeDivider()
            Column(
                Modifier
                    .fillMaxWidth()
                    .heightIn(max = 280.dp)
                    .verticalScroll(rememberScrollState()),
            ) {
                state.items.forEach { item ->
                    Row(
                        Modifier.fillMaxWidth().padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        FloeText(
                            if (item.isText) {
                                stringResource(R.string.entry_share_item_text)
                            } else {
                                item.displayName
                            },
                            style = Floe.typography.body,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f),
                        )
                        if (!item.isText) {
                            Spacer(Modifier.width(8.dp))
                            FloeText(
                                Formatter.formatShortFileSize(context, item.byteCount),
                                style = Floe.typography.metadata,
                                color = colors.secondaryLabel,
                            )
                        }
                    }
                }
                state.textPreview?.let { preview ->
                    FloeText(
                        preview,
                        style = Floe.typography.metadata,
                        color = colors.secondaryLabel,
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.padding(top = 4.dp, bottom = 8.dp),
                    )
                }
            }
            FloeDivider()
            Spacer(Modifier.height(12.dp))
            when (state.phase) {
                EntrySharePhase.PREPARING -> Row(
                    Modifier.fillMaxWidth().padding(vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    CupertinoActivityIndicator(color = colors.secondaryLabel)
                    FloeText(
                        if (state.checkedCount > 0) {
                            stringResource(
                                R.string.entry_share_checking,
                                state.checkedCount,
                                state.totalCount,
                            )
                        } else {
                            stringResource(R.string.entry_share_preparing)
                        },
                        style = Floe.typography.metadata,
                        color = colors.secondaryLabel,
                    )
                }

                EntrySharePhase.WORKING -> Row(
                    Modifier.fillMaxWidth().padding(vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    CupertinoActivityIndicator(color = colors.secondaryLabel)
                    FloeText(
                        stringResource(R.string.entry_share_saving_notes),
                        style = Floe.typography.metadata,
                        color = colors.secondaryLabel,
                    )
                }

                EntrySharePhase.COMPLETE -> {
                    FloeText(
                        if (state.savedNotes > 0) {
                            stringResource(R.string.entry_share_saved_notes, state.savedNotes)
                        } else {
                            stringResource(R.string.entry_share_added_task)
                        },
                        style = Floe.typography.body,
                    )
                    Spacer(Modifier.height(10.dp))
                    if (state.canOpenNotes) {
                        FloePrimaryAction(
                            label = stringResource(R.string.entry_share_open_notes),
                            onClick = onOpenNotes,
                            modifier = Modifier.fillMaxWidth(),
                        )
                        Spacer(Modifier.height(8.dp))
                    }
                    FloeCapsuleButton(
                        label = stringResource(R.string.entry_action_done),
                        onClick = onDismiss,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }

                EntrySharePhase.FAILED -> {
                    FloeText(
                        stringResource(shareErrorText(state.error)),
                        style = Floe.typography.body,
                        color = colors.destructive,
                    )
                    Spacer(Modifier.height(10.dp))
                    FloeCapsuleButton(
                        label = stringResource(R.string.entry_share_notes),
                        onClick = onChooseNotes,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Spacer(Modifier.height(8.dp))
                    FloeCapsuleButton(
                        label = stringResource(R.string.entry_share_task),
                        onClick = onChooseTask,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Spacer(Modifier.height(8.dp))
                    FloeCapsuleAction(
                        label = stringResource(R.string.entry_share_cancel),
                        onClick = onDiscard,
                    )
                }

                EntrySharePhase.READY -> {
                    FloeCapsuleButton(
                        label = stringResource(R.string.entry_share_task),
                        onClick = onChooseTask,
                        modifier = Modifier.fillMaxWidth(),
                        prominent = true,
                    )
                    Spacer(Modifier.height(8.dp))
                    FloeCapsuleButton(
                        label = stringResource(R.string.entry_share_notes),
                        onClick = onChooseNotes,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Spacer(Modifier.height(10.dp))
                    FloeText(
                        stringResource(R.string.entry_share_nothing_sent),
                        style = Floe.typography.metadata,
                        color = colors.secondaryLabel,
                    )
                }
            }
        }
    }
}

@Composable
private fun shareErrorText(error: EntryShareError?): Int = when (error) {
    EntryShareError.EMPTY -> R.string.entry_share_empty
    EntryShareError.STALE -> R.string.entry_share_stale
    EntryShareError.BUSY -> R.string.entry_share_busy
    EntryShareError.TEMP_REFUSED -> R.string.entry_share_temp_refused
    EntryShareError.GRANT_REVOKED -> R.string.entry_share_grant_revoked
    EntryShareError.TOO_LARGE -> R.string.entry_share_item_too_large
    EntryShareError.ITEM_LIMIT -> R.string.entry_share_item_limit
    EntryShareError.UNSUPPORTED -> R.string.entry_share_unsupported
    EntryShareError.UNREADABLE -> R.string.entry_share_unreadable
    EntryShareError.NOTES_UNAVAILABLE -> R.string.entry_share_notes_unavailable
    EntryShareError.STAGING_UNAVAILABLE -> R.string.entry_share_staging_unavailable
    EntryShareError.FAILED, null -> R.string.entry_share_failed
}

/**
 * Lightweight, skippable first-run guide. It only presents the shipped
 * defaults and links to the existing Settings editors; it never writes a
 * provider/model/voice choice and never gates App use.
 */
@Composable
public fun EntrySetupGuideSheet(
    state: EntrySetupUi,
    onNext: () -> Unit,
    onBack: () -> Unit,
    onSkip: () -> Unit,
    onFinish: () -> Unit,
    onAction: () -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = Floe.colors
    val step = state.step
    FloePageSheet(
        visible = state.visible,
        onDismiss = onDismiss,
        widthFraction = 1f,
        heightFraction = 1f,
    ) {
        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp, vertical = 20.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                FloeText(
                    stringResource(R.string.entryflow_setup_title),
                    style = Floe.typography.title,
                    modifier = Modifier.weight(1f),
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.entry_setup_skip),
                    onClick = onSkip,
                )
            }
            Spacer(Modifier.height(8.dp))
            FloeText(
                stringResource(R.string.entry_setup_progress, state.index + 1, state.total),
                style = Floe.typography.metadata,
                color = colors.secondaryLabel,
            )
            Spacer(Modifier.height(18.dp))
            FloeText(stringResource(setupTitle(step)), style = Floe.typography.section)
            Spacer(Modifier.height(8.dp))
            FloeText(
                stringResource(setupBody(step)),
                style = Floe.typography.body,
                color = colors.secondaryLabel,
            )
            setupActionLabel(step)?.let { label ->
                Spacer(Modifier.height(18.dp))
                FloePrimaryAction(
                    label = stringResource(label),
                    onClick = onAction,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            Spacer(Modifier.height(28.dp))
            FloeDivider()
            Spacer(Modifier.height(12.dp))
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (state.canGoBack) {
                    FloeCapsuleAction(
                        label = stringResource(R.string.entry_setup_back),
                        onClick = onBack,
                    )
                }
                Spacer(Modifier.weight(1f))
                FloePrimaryAction(
                    label = stringResource(
                        if (state.isLast) R.string.entry_setup_finish else R.string.entry_setup_next,
                    ),
                    onClick = if (state.isLast) onFinish else onNext,
                    modifier = Modifier.widthIn(min = 132.dp),
                )
            }
        }
    }
}

private fun setupTitle(step: EntrySetupStep): Int = when (step) {
    EntrySetupStep.WELCOME -> R.string.entry_setup_welcome_title
    EntrySetupStep.MODELS -> R.string.entry_setup_models_title
    EntrySetupStep.VOICE -> R.string.entry_setup_voice_title
    EntrySetupStep.FILES -> R.string.entry_setup_files_title
    EntrySetupStep.NOTIFICATIONS -> R.string.entry_setup_notifications_title
    EntrySetupStep.DONE -> R.string.entry_setup_done_title
}

private fun setupBody(step: EntrySetupStep): Int = when (step) {
    EntrySetupStep.WELCOME -> R.string.entry_setup_welcome_body
    EntrySetupStep.MODELS -> R.string.entry_setup_models_body
    EntrySetupStep.VOICE -> R.string.entry_setup_voice_body
    EntrySetupStep.FILES -> R.string.entry_setup_files_body
    EntrySetupStep.NOTIFICATIONS -> R.string.entry_setup_notifications_body
    EntrySetupStep.DONE -> R.string.entry_setup_done_body
}

private fun setupActionLabel(step: EntrySetupStep): Int? = when (step) {
    EntrySetupStep.MODELS -> R.string.entry_setup_models_action
    EntrySetupStep.VOICE -> R.string.entry_setup_voice_action
    else -> null
}

/** Non-modal, dismissible notice used by the shell for honest route outcomes. */
@Composable
public fun EntryNoticeCard(
    kind: EntryNoticeKind?,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    if (kind == null) return
    val colors = Floe.colors
    Box(
        modifier
            .widthIn(max = 560.dp)
            .background(colors.chromeSurface, RoundedCornerShape(14.dp))
            .clickable(onClick = onDismiss)
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        FloeText(
            stringResource(noticeText(kind)),
            style = Floe.typography.body,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

private fun noticeText(kind: EntryNoticeKind): Int = when (kind) {
    EntryNoticeKind.INVALID_LINK -> R.string.entry_notice_invalid_link
    EntryNoticeKind.TASK_UNAVAILABLE -> R.string.entry_notice_task_unavailable
    EntryNoticeKind.SCHEDULE_UNAVAILABLE -> R.string.entry_notice_schedule_unavailable
    EntryNoticeKind.SHARE_UNAVAILABLE -> R.string.entry_notice_share_unavailable
    EntryNoticeKind.BUSY -> R.string.entry_notice_busy
    EntryNoticeKind.ALREADY_HANDLED -> R.string.entry_notice_already_handled
    EntryNoticeKind.DISCARDED -> R.string.entry_notice_discarded
    EntryNoticeKind.OPEN_FAILED -> R.string.entry_notice_open_failed
    EntryNoticeKind.TEMP_REFUSED -> R.string.entry_notice_temp_refused
    EntryNoticeKind.TOO_LARGE -> R.string.entry_notice_too_large
    EntryNoticeKind.ITEM_LIMIT -> R.string.entry_notice_item_limit
    EntryNoticeKind.UNSUPPORTED -> R.string.entry_notice_unsupported
    EntryNoticeKind.GRANT_REVOKED -> R.string.entry_notice_grant_revoked
    EntryNoticeKind.UNREADABLE -> R.string.entry_notice_unreadable
    EntryNoticeKind.NOTES_UNAVAILABLE -> R.string.entry_notice_notes_unavailable
    EntryNoticeKind.STAGING_UNAVAILABLE -> R.string.entry_notice_staging_unavailable
    EntryNoticeKind.UNAVAILABLE -> R.string.entry_notice_unavailable
}
