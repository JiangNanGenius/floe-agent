// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui.r2

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloeSettingsSectionCard
import com.floe.android.design.FloeSheetPlacement
import com.floe.android.design.FloeText
import com.floe.android.design.FloeSecureFormField
import com.floe.android.feature.workbench.ui.MediaInlineFailure
import com.floe.android.feature.workbench.ui.R

/**
 * Shared super-resolution backend configuration sheet.
 *
 * This is the ONE retained flow behind both the media editor "Configure"
 * shortcut and the settings entry: it configures or revokes the real fal.ai
 * backend through the original settings/credential services. The key is
 * RAM-only state, handed once to the App host (which writes it to the device
 * credential store); it is never restored, logged or sent as JSON.
 */
@Composable
fun MediaEnhancementConfigurationSheet(
    controller: WorkbenchEnhancementConfigurationController,
    onDismiss: () -> Unit,
) {
    LaunchedEffect(Unit) { controller.reload() }

    var key by remember { mutableStateOf("") }
    var name by remember { mutableStateOf("") }
    var revealed by remember { mutableStateOf(false) }
    var confirmRevoke by remember { mutableStateOf(false) }

    val configuration = controller.configuration
    val busy = controller.busy

    FloePageSheet(
        visible = true,
        onDismiss = {
            key = ""
            controller.dismiss()
            onDismiss()
        },
        widthFraction = 1f,
        heightFraction = 0.94f,
        placement = FloeSheetPlacement.BOTTOM,
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                FloeText(
                    stringResource(R.string.media_enhancement_config_title),
                    style = Floe.typography.section,
                )
                Spacer(Modifier.weight(1f))
                FloeCapsuleAction(
                    label = stringResource(R.string.media_enhancement_config_done),
                    onClick = {
                        key = ""
                        controller.dismiss()
                        onDismiss()
                    },
                )
            }
            FloeSettingsSectionCard(title = null) {
                when {
                    controller.loading && configuration == null ->
                        Row(
                            Modifier.fillMaxWidth().padding(16.dp),
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            FloeActivityIndicator()
                            FloeText(
                                stringResource(R.string.media_enhancement_config_status_checking),
                                style = Floe.typography.metadata,
                            )
                        }
                    configuration?.legacyProviderProfileReferenced == true ->
                        FloeText(
                            stringResource(R.string.media_enhancement_config_legacy),
                            style = Floe.typography.metadata,
                            color = Floe.colors.pending,
                            modifier = Modifier.padding(16.dp),
                        )
                    controller.configured ->
                        FloeText(
                            stringResource(
                                R.string.media_enhancement_config_status_configured,
                                configuration?.displayName ?: configuration?.endpointID.orEmpty(),
                            ),
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                            modifier = Modifier.padding(16.dp),
                        )
                    else ->
                        FloeText(
                            stringResource(R.string.media_enhancement_config_status_unconfigured),
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                            modifier = Modifier.padding(16.dp),
                        )
                }
                FloePlainFormField(
                    label = stringResource(R.string.media_enhancement_config_name_label),
                    value = name,
                    onValueChange = { name = it.take(64) },
                    enabled = !busy,
                )
                FloeSecureFormField(
                    label = stringResource(R.string.media_enhancement_config_key_label),
                    value = key,
                    onValueChange = { raw -> key = raw.take(257) },
                    revealed = revealed,
                    onRevealedChange = { revealed = it },
                    revealOnLabel = stringResource(R.string.media_enhancement_config_show),
                    revealOffLabel = stringResource(R.string.media_enhancement_config_hide),
                    enabled = !busy,
                )
            }
            val failure = controller.failure
            when {
                failure != null -> MediaInlineFailure(
                    failure = failure,
                    onRetry = { controller.reload() },
                )
                controller.notice == WorkbenchEnhancementConfigurationController.Notice.SAVED ->
                    FloeText(
                        stringResource(R.string.media_enhancement_config_saved),
                        style = Floe.typography.metadata,
                        color = Floe.colors.success,
                    )
                controller.notice == WorkbenchEnhancementConfigurationController.Notice.REVOKED ->
                    FloeText(
                        stringResource(R.string.media_enhancement_config_revoked),
                        style = Floe.typography.metadata,
                        color = Floe.colors.success,
                    )
            }
            FloeText(
                stringResource(R.string.media_enhancement_config_footer),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (busy) {
                    FloeActivityIndicator(
                        description = stringResource(
                            R.string.media_enhancement_config_busy),
                    )
                }
                Spacer(Modifier.weight(1f))
                if (controller.configured) {
                    FloeCapsuleAction(
                        label = stringResource(
                            if (confirmRevoke) {
                                R.string.media_enhancement_config_revoke_confirm
                            } else {
                                R.string.media_enhancement_config_revoke
                            }),
                        onClick = {
                            if (confirmRevoke) {
                                confirmRevoke = false
                                key = ""
                                controller.revoke()
                            } else {
                                confirmRevoke = true
                            }
                        },
                        enabled = !busy,
                    )
                }
                FloeCapsuleAction(
                    label = stringResource(R.string.media_enhancement_config_save),
                    onClick = {
                        controller.save(
                            displayName = name,
                            apiKey = key.trim().ifEmpty { null },
                        )
                        key = ""
                        revealed = false
                        confirmRevoke = false
                    },
                    // A blank key with nothing configured would save an
                    // unusable row; require a key for the first save. With an
                    // existing credential a blank key keeps it (name edits).
                    enabled = !busy && (key.isNotBlank() || controller.configured),
                )
            }
        }
    }
}
