// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

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
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.R
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeConfirmDialog
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloeSecureFormField
import com.floe.android.design.FloeSectionRow
import com.floe.android.design.FloeSettingsSectionCard
import com.floe.android.design.FloeSheetPlacement
import com.floe.android.design.FloeText

/** Nested settings sheet. Secret input is RAM-only remember, never saveable,
 * restored, published in the host projection, or read back from storage.
 */
@Composable
fun GitHubCredentialEditor(controller: GitHubCredentialHostController) {
    val state by controller.state.collectAsState()
    val editorId = state.editorId ?: return
    var token by remember(editorId) { mutableStateOf("") }
    var revealed by remember(editorId) { mutableStateOf(false) }
    var confirmRemove by remember(editorId) { mutableStateOf(false) }
    DisposableEffect(editorId) {
        onDispose { controller.closeEditor(editorId) }
    }
    val wide = LocalConfiguration.current.screenWidthDp >= 700
    FloePageSheet(
        visible = true,
        onDismiss = { token = ""; controller.closeEditor(editorId) },
        widthFraction = if (wide) 0.66f else 1f,
        heightFraction = if (wide) 0.66f else 0.94f,
        placement = if (wide) FloeSheetPlacement.CENTER else FloeSheetPlacement.BOTTOM,
    ) {
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                FloeText(stringResource(R.string.git_credentials_title), style = Floe.typography.section)
                Spacer(Modifier.weight(1f))
                FloeCapsuleAction(
                    label = stringResource(R.string.git_credentials_done),
                    onClick = { token = ""; controller.closeEditor(editorId) },
                )
            }
            FloeSettingsSectionCard(title = null) {
                FloeSectionRow(title = {
                    FloeText(
                        stringResource(when (state.configured) {
                            true -> R.string.git_credentials_stored
                            false -> R.string.git_credentials_not_stored
                            null -> R.string.git_credentials_status_pending
                        }),
                        color = Floe.colors.secondaryLabel,
                    )
                })
                FloeSecureFormField(
                    label = stringResource(R.string.git_credentials_token),
                    value = token,
                    // Keep one excess character so overlong pastes are rejected,
                    // never silently truncated into a different valid token.
                    onValueChange = { token = it.take(513) },
                    revealed = revealed,
                    onRevealedChange = { revealed = it },
                    revealOnLabel = stringResource(R.string.git_credentials_show),
                    revealOffLabel = stringResource(R.string.git_credentials_hide),
                    enabled = !state.busy,
                    isError = state.notice == GitHubCredentialHostController.Notice.INVALID_TOKEN,
                )
            }
            FloeText(
                stringResource(R.string.git_credentials_footer),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
            if (state.busy) {
                FloeActivityIndicator(description = stringResource(R.string.git_credentials_working))
            }
            state.notice?.let { notice ->
                FloeText(
                    stringResource(when (notice) {
                        GitHubCredentialHostController.Notice.SAVED -> R.string.git_credentials_saved
                        GitHubCredentialHostController.Notice.REMOVED -> R.string.git_credentials_removed
                        GitHubCredentialHostController.Notice.INVALID_TOKEN -> R.string.git_credentials_invalid
                        GitHubCredentialHostController.Notice.UNAVAILABLE -> R.string.git_credentials_unavailable
                    }),
                    color = if (notice == GitHubCredentialHostController.Notice.UNAVAILABLE ||
                        notice == GitHubCredentialHostController.Notice.INVALID_TOKEN
                    ) Floe.colors.pending else Floe.colors.secondaryLabel,
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                FloeCapsuleAction(
                    label = stringResource(R.string.git_credentials_save),
                    enabled = !state.busy && token.isNotBlank(),
                    onClick = {
                        if (controller.save(editorId, token)) { token = ""; revealed = false }
                    },
                )
                if (state.configured == true) {
                    FloeCapsuleAction(
                        label = stringResource(R.string.git_credentials_remove),
                        enabled = !state.busy,
                        tint = Floe.colors.destructive,
                        onClick = { confirmRemove = true },
                    )
                } else if (state.notice == GitHubCredentialHostController.Notice.UNAVAILABLE) {
                    FloeCapsuleAction(
                        label = stringResource(R.string.git_credentials_retry),
                        enabled = !state.busy,
                        onClick = { controller.refresh(editorId) },
                    )
                }
            }
        }
        if (confirmRemove) {
            FloeConfirmDialog(
                title = stringResource(R.string.git_credentials_remove),
                message = stringResource(R.string.git_credentials_remove_message),
                confirmLabel = stringResource(R.string.git_credentials_remove),
                dismissLabel = stringResource(R.string.git_credentials_cancel),
                onConfirm = {
                    confirmRemove = false
                    token = ""
                    controller.delete(editorId)
                },
                onDismiss = { confirmRemove = false },
            )
        }
    }
}
