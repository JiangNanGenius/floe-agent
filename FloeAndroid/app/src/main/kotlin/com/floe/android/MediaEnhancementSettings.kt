// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeSettingsSectionCard
import com.floe.android.design.FloeText
import com.floe.android.feature.workbench.ui.r2.MediaEnhancementConfigurationSheet
import com.floe.android.feature.workbench.ui.r2.WorkbenchEnhancementConfigurationController
import io.github.robinpcrd.cupertino.section.SectionItem

/**
 * Settings → Providers → Media enhancement entry.
 *
 * Hosts the SAME retained super-resolution backend configuration flow as the
 * media editor "Configure" shortcut; the native side owns the one typed row
 * and the credential in the original stores. Before the runtime host is
 * ready the card stays an honest pending row (no fake state, no hidden JSON).
 */
@Composable
fun MediaEnhancementSettingsCard() {
    val app = LocalContext.current.applicationContext as? FloeApplication
    val controller = remember(app) {
        app?.mediaEnhancementSettings?.configuration
    }
    if (controller == null) {
        HostPendingCard()
        return
    }
    var showSheet by remember { mutableStateOf(false) }
    LaunchedEffect(showSheet) {
        if (showSheet) controller.reload()
    }
    FloeSettingsSectionCard(
        title = stringResource(R.string.media_enhancement_settings_title),
    ) {
        SectionItem(
            title = {
                Row(
                    Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    FloeText(
                        stringResource(
                            when {
                                controller.configured ->
                                    R.string.media_enhancement_settings_configured
                                controller.configuration != null ->
                                    R.string.media_enhancement_settings_unconfigured
                                else ->
                                    R.string.media_enhancement_settings_pending
                            }),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                        modifier = Modifier.weight(1f),
                    )
                    FloeCapsuleAction(
                        label = stringResource(R.string.media_enhancement_settings_configure),
                        onClick = { showSheet = true },
                    )
                }
            },
        )
    }
    if (showSheet) {
        MediaEnhancementConfigurationSheet(
            controller = controller,
            onDismiss = { showSheet = false },
        )
    }
}

@Composable
private fun HostPendingCard() {
    FloeSettingsSectionCard(
        title = stringResource(R.string.media_enhancement_settings_title),
    ) {
        SectionItem(
            title = {
                FloeText(
                    stringResource(R.string.media_enhancement_settings_pending),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                    modifier = Modifier.padding(vertical = 10.dp),
                )
            },
        )
    }
}
