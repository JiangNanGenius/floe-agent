// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.res.stringResource
import com.floe.android.R
import com.floe.android.design.Floe
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeChoiceMenu
import com.floe.android.design.FloeChoiceOption
import com.floe.android.design.FloeText

@Composable
private fun sourceName(source: UpdateDownloadSource): String = when (source) {
    UpdateDownloadSource.GITHUB -> stringResource(R.string.app_update_source_github)
    UpdateDownloadSource.GHFAST -> "GHFast"
    UpdateDownloadSource.GH_PROXY -> "GH-Proxy"
}

/** Reused by Settings and the pinned download controls; no work starts on composition. */
@Composable
internal fun UpdateSourceSelector(controller: AppUpdateController, ui: AppUpdateUiState) {
    var expanded by remember { mutableStateOf(false) }
    val state = ui.sourceState
    val enabled = !state.switching && ui.install is AppInstallState.Idle &&
        ui.download !is AppDownloadState.Applying && ui.download !is AppDownloadState.Verifying &&
        ui.download !is AppDownloadState.Ready
    Column {
        Box {
            FloeCapsuleAction(
                label = stringResource(R.string.app_update_source_value, sourceName(state.selected)),
                enabled = enabled,
                onClick = { expanded = true },
            )
            FloeChoiceMenu(
                expanded = expanded && enabled,
                onDismissRequest = { expanded = false },
                options = UpdateDownloadSource.entries.map { FloeChoiceOption(it.id, sourceName(it)) },
                selectedKey = state.selected.id,
                onSelect = {
                    expanded = false
                    controller.setDownloadSource(UpdateDownloadSource.fromId(it))
                },
            )
        }
        when {
            state.switching -> FloeText(stringResource(R.string.app_update_source_switching),
                style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
            state.restarted -> FloeText(stringResource(R.string.app_update_source_restarted),
                style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
            state.selected != UpdateDownloadSource.GITHUB -> FloeText(stringResource(R.string.app_update_source_mirror),
                style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
        }
    }
}
