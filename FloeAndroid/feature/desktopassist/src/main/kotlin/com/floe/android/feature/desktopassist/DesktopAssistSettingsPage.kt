// SPDX-License-Identifier: MPL-2.0
//
// Full C05 Desktop Assist settings pane. Presentation only: every bridge
// call, credential-vault write and root-epoch check belongs to the App-owned
// `C05DesktopAssistSettingsController`.
//
// Secret handling: the one-time secret exists only in the nested editor's
// RAM-only `remember` buffer. It is never placed in the immutable UI state,
// saveable state, a projection or a log, and it is blanked when the editor
// closes.

package com.floe.android.feature.desktopassist

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeConfirmDialog
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloeSectionRow
import com.floe.android.design.FloeSecureFormField
import com.floe.android.design.FloeSegmented
import com.floe.android.design.FloeSettingsSectionCard
import com.floe.android.design.FloeSheetPlacement
import com.floe.android.design.FloeText

@Composable
public fun DesktopAssistSettingsPage(
    state: DesktopAssistUiState,
    actions: DesktopAssistActions,
) {
    // The Settings sheet owns the single bounded vertical scroll for this
    // pane. A page-level scroll would nest inside it.
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        FloeSettingsSectionCard(title = stringResource(R.string.desktop_assist_cards)) {
            if (state.cards.isEmpty()) {
                FloeSectionRow(
                    title = {
                        FloeText(
                            stringResource(
                                if (state.loading && !state.loaded) {
                                    R.string.desktop_assist_loading
                                } else {
                                    R.string.desktop_assist_empty
                                }
                            ),
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                        )
                    },
                )
            }
            state.cards.forEach { card ->
                FloeSectionRow(
                    onClick = { actions.beginEdit(card.id) },
                    title = {
                        Column(
                            Modifier
                                .fillMaxWidth()
                                .padding(vertical = 4.dp),
                        ) {
                            FloeText(card.label, style = Floe.typography.body, maxLines = 1)
                            FloeText(
                                kindLabel(card.kind),
                                style = Floe.typography.metadata,
                                color = if (card.typingAllowed) {
                                    Floe.colors.secondaryLabel
                                } else {
                                    Floe.colors.tertiaryLabel
                                },
                                maxLines = 1,
                            )
                            FloeText(
                                hostLabel(card.hostID, state.hosts),
                                style = Floe.typography.metadata,
                                color = Floe.colors.tertiaryLabel,
                                maxLines = 1,
                            )
                            FloeText(
                                stringResource(R.string.desktop_assist_reference) + ": " + card.reference,
                                style = Floe.typography.evidence,
                                color = Floe.colors.tertiaryLabel,
                                maxLines = 1,
                            )
                        }
                    },
                    trailing = {
                        FloeCapsuleAction(
                            label = stringResource(
                                if (card.typingAllowed) {
                                    R.string.desktop_assist_editor_edit
                                } else {
                                    R.string.desktop_assist_not_typing_allowed
                                }
                            ),
                            onClick = { actions.beginEdit(card.id) },
                        )
                    },
                )
            }
            FloeSectionRow(
                title = {
                    FloeCapsuleAction(
                        label = stringResource(R.string.desktop_assist_add),
                        onClick = actions::beginCreate,
                        enabled = !state.saving,
                    )
                },
                trailing = {
                    if (state.loading) {
                        FloeText(
                            stringResource(R.string.desktop_assist_loading),
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                        )
                    }
                },
            )
        }
        FloeText(
            stringResource(R.string.desktop_assist_cards_footer),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
        FloeSettingsSectionCard(title = stringResource(R.string.desktop_assist_ocr_title)) {
            FloeSectionRow(
                title = {
                    Column(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                        FloeText(
                            when (state.linuxShellQualified) {
                                true -> stringResource(R.string.desktop_assist_ocr_ready)
                                else -> stringResource(R.string.desktop_assist_ocr_pending)
                            },
                            style = Floe.typography.body,
                            maxLines = 2,
                        )
                        FloeText(
                            stringResource(R.string.desktop_assist_ocr_body),
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                        )
                    }
                },
            )
        }
        state.notice?.let { notice ->
            FloeText(
                noticeLabel(notice),
                style = Floe.typography.metadata,
                color = when (notice) {
                    DesktopAssistNotice.INVALID,
                    DesktopAssistNotice.UNAVAILABLE -> Floe.colors.destructive
                    else -> Floe.colors.secondaryLabel
                },
            )
            FloeCapsuleAction(
                label = stringResource(R.string.desktop_assist_done),
                onClick = actions::dismissNotice,
            )
        }
        if (state.error != null) {
            FloeText(
                stringResource(R.string.desktop_assist_error),
                style = Floe.typography.metadata,
                color = Floe.colors.destructive,
            )
            FloeCapsuleAction(
                label = stringResource(R.string.desktop_assist_retry),
                onClick = actions::refresh,
            )
        }
    }
    state.editor?.let { editor ->
        CardEditorSheet(
            editor = editor,
            hosts = state.hosts,
            saving = state.saving,
            notice = state.notice,
            actions = actions,
        )
    }
}

@Composable
private fun CardEditorSheet(
    editor: DesktopAssistEditorUi,
    hosts: List<DesktopAssistHostUi>,
    saving: Boolean,
    notice: DesktopAssistNotice?,
    actions: DesktopAssistActions,
) {
    // RAM-only; deliberately not rememberSaveable. Process death must not
    // restore a typed secret.
    var secret by remember(editor.editorID) { mutableStateOf("") }
    var revealed by remember(editor.editorID) { mutableStateOf(false) }
    var label by remember(editor.editorID) { mutableStateOf(editor.label) }
    var kind by remember(editor.editorID) { mutableStateOf(editor.kind) }
    var hostID by remember(editor.editorID) { mutableStateOf(editor.hostID) }
    var confirmDelete by remember(editor.editorID) { mutableStateOf(false) }
    DisposableEffect(editor.editorID) {
        onDispose { secret = "" }
    }
    val wide = LocalConfiguration.current.screenWidthDp >= 700
    FloePageSheet(
        visible = true,
        onDismiss = {
            secret = ""
            actions.dismissEditor()
        },
        widthFraction = if (wide) 0.66f else 1f,
        heightFraction = if (wide) 0.72f else 0.94f,
        placement = if (wide) FloeSheetPlacement.CENTER else FloeSheetPlacement.BOTTOM,
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                FloeText(
                    stringResource(
                        if (editor.cardID == null) {
                            R.string.desktop_assist_editor_create
                        } else {
                            R.string.desktop_assist_editor_edit
                        }
                    ),
                    style = Floe.typography.section,
                )
                Spacer(Modifier.weight(1f))
                FloeCapsuleAction(
                    label = stringResource(R.string.desktop_assist_done),
                    onClick = {
                        secret = ""
                        actions.dismissEditor()
                    },
                )
            }
            editor.reference?.let { reference ->
                FloeSettingsSectionCard(title = null) {
                    FloeSectionRow(
                        title = {
                            Column(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                                FloeText(
                                    stringResource(R.string.desktop_assist_reference),
                                    style = Floe.typography.groupHeader,
                                    color = Floe.colors.secondaryLabel,
                                )
                                FloeText(
                                    reference,
                                    style = Floe.typography.evidence,
                                    color = Floe.colors.label,
                                )
                            }
                        },
                        trailing = {
                            val context = LocalContext.current
                            FloeCapsuleAction(
                                label = stringResource(R.string.desktop_assist_copy_reference),
                                onClick = {
                                    val clipboard = context.getSystemService(
                                        Context.CLIPBOARD_SERVICE
                                    ) as? ClipboardManager
                                    clipboard?.setPrimaryClip(
                                        ClipData.newPlainText("Floe credential reference", reference)
                                    )
                                },
                            )
                        },
                    )
                }
            }
            FloeSettingsSectionCard(title = null) {
                FloeSectionRow(
                    title = {
                        FloePlainFormField(
                            label = stringResource(R.string.desktop_assist_label),
                            value = label,
                            onValueChange = { label = it.take(200) },
                            enabled = !saving,
                        )
                    },
                )
                FloeSectionRow(
                    title = {
                        Column(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
                            if (editor.cardID == null) {
                                FloeSegmented(
                                    options = listOf(
                                        stringResource(R.string.desktop_assist_kind_password),
                                        stringResource(R.string.desktop_assist_kind_token),
                                    ),
                                    selectedIndex = if (kind == DesktopAssistKinds.GENERIC_TOKEN) 1 else 0,
                                    onSelect = { index ->
                                        kind = if (index == 1) {
                                            DesktopAssistKinds.GENERIC_TOKEN
                                        } else {
                                            DesktopAssistKinds.WEBSITE_PASSWORD
                                        }
                                    },
                                )
                            } else {
                                // The existing card's kind is immutable through
                                // this editor; replacing it would rewrite the
                                // metadata semantics of an existing reference.
                                FloeText(
                                    kindLabel(kind),
                                    style = Floe.typography.body,
                                    color = Floe.colors.label,
                                )
                            }
                        }
                    },
                )
                FloeSecureFormField(
                    label = if (editor.hasExistingSecret) {
                        stringResource(R.string.desktop_assist_secret_keep)
                    } else {
                        stringResource(R.string.desktop_assist_secret)
                    },
                    value = secret,
                    // Keep one excess byte so overlong pastes are rejected
                    // rather than silently truncated into a shorter secret.
                    onValueChange = { secret = it.take(4_097) },
                    revealed = revealed,
                    onRevealedChange = { revealed = it },
                    revealOnLabel = stringResource(R.string.desktop_assist_show),
                    revealOffLabel = stringResource(R.string.desktop_assist_hide),
                    enabled = !saving,
                )
            }
            FloeText(
                stringResource(R.string.desktop_assist_host_title),
                style = Floe.typography.groupHeader,
                color = Floe.colors.secondaryLabel,
            )
            FloeSettingsSectionCard(title = null) {
                FloeSectionRow(
                    onClick = { hostID = null },
                    enabled = !saving,
                    title = {
                        FloeText(
                            stringResource(R.string.desktop_assist_host_any),
                            style = Floe.typography.body,
                            color = if (hostID == null) Floe.colors.accent else Floe.colors.label,
                            maxLines = 1,
                        )
                    },
                    trailing = {
                        if (hostID == null) {
                            FloeText(
                                stringResource(R.string.desktop_assist_selected),
                                style = Floe.typography.metadata,
                                color = Floe.colors.accent,
                            )
                        }
                    },
                )
                hosts.forEach { host ->
                    FloeSectionRow(
                        onClick = { hostID = host.id },
                        enabled = !saving,
                        title = {
                            Column(Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
                                FloeText(
                                    host.displayName,
                                    style = Floe.typography.body,
                                    color = if (hostID == host.id) {
                                        Floe.colors.accent
                                    } else {
                                        Floe.colors.label
                                    },
                                    maxLines = 1,
                                )
                                FloeText(
                                    host.address,
                                    style = Floe.typography.metadata,
                                    color = Floe.colors.secondaryLabel,
                                    maxLines = 1,
                                )
                            }
                        },
                        trailing = {
                            if (hostID == host.id) {
                                FloeText(
                                    stringResource(R.string.desktop_assist_selected),
                                    style = Floe.typography.metadata,
                                    color = Floe.colors.accent,
                                )
                            }
                        },
                    )
                }
            }
            FloeText(
                stringResource(
                    if (hostID == null) {
                        R.string.desktop_assist_host_any_hint
                    } else {
                        R.string.desktop_assist_host_hint
                    }
                ),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FloeCapsuleAction(
                    label = stringResource(R.string.desktop_assist_save),
                    onClick = {
                        actions.save(editor.editorID, label, kind, hostID, secret)
                        secret = ""
                    },
                    enabled = !saving,
                )
                if (editor.cardID != null) {
                    FloeCapsuleAction(
                        label = stringResource(R.string.desktop_assist_delete),
                        onClick = { confirmDelete = true },
                        enabled = !saving,
                        tint = Floe.colors.destructive,
                    )
                }
                Spacer(Modifier.weight(1f))
                if (saving) {
                    FloeText(
                        stringResource(R.string.desktop_assist_saving),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                }
            }
            notice?.let {
                if (it == DesktopAssistNotice.INVALID ||
                    it == DesktopAssistNotice.UNAVAILABLE
                ) {
                    FloeText(
                        noticeLabel(it),
                        style = Floe.typography.metadata,
                        color = Floe.colors.destructive,
                    )
                }
            }
        }
    }
    if (confirmDelete) {
        FloeConfirmDialog(
            title = stringResource(R.string.desktop_assist_delete_title),
            message = stringResource(R.string.desktop_assist_delete_message),
            confirmLabel = stringResource(R.string.desktop_assist_delete),
            dismissLabel = stringResource(R.string.desktop_assist_cancel),
            onConfirm = {
                confirmDelete = false
                secret = ""
                editor.cardID?.let(actions::delete)
            },
            onDismiss = { confirmDelete = false },
        )
    }
}

@Composable
private fun kindLabel(kind: String): String = when (kind) {
    DesktopAssistKinds.WEBSITE_PASSWORD -> stringResource(R.string.desktop_assist_kind_password)
    DesktopAssistKinds.GENERIC_TOKEN -> stringResource(R.string.desktop_assist_kind_token)
    else -> stringResource(R.string.desktop_assist_kind_other)
}

@Composable
private fun hostLabel(hostID: String?, hosts: List<DesktopAssistHostUi>): String {
    if (hostID == null) return stringResource(R.string.desktop_assist_host_any)
    val host = hosts.firstOrNull { it.id == hostID }
    return host?.displayName ?: stringResource(R.string.desktop_assist_missing_host)
}

@Composable
private fun noticeLabel(notice: DesktopAssistNotice): String = when (notice) {
    DesktopAssistNotice.SAVED -> stringResource(R.string.desktop_assist_notice_saved)
    DesktopAssistNotice.DELETED -> stringResource(R.string.desktop_assist_notice_deleted)
    DesktopAssistNotice.INVALID -> stringResource(R.string.desktop_assist_notice_invalid)
    DesktopAssistNotice.UNAVAILABLE -> stringResource(R.string.desktop_assist_notice_unavailable)
}
