// SPDX-License-Identifier: MPL-2.0
//
// App-level binding between the C07 App-owned controller and the settings
// presentation. This file owns only SAF picker launches and state/callback
// mapping; archive bytes, staging, journals and sinks stay in the native
// domain through the controller.
package com.floe.android.host.dataexchange

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import com.floe.android.feature.dataexchange.DataExchangeSettingsPage
import com.floe.android.feature.dataexchange.DataExchangeUiState
import com.floe.android.host.RuntimeHost
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter

@Composable
internal fun C07DataExchangeSettingsDestination(
    host: RuntimeHost?,
    modifier: Modifier = Modifier,
) {
    if (host == null) {
        DataExchangeSettingsPage(
            state = DataExchangeUiState(loading = false, coreReady = false),
            onCreateBackup = {}, onCancelBackup = {}, onPickRestore = {},
            onPickNoteImport = {}, onConfirmRestore = {}, onCancelRestore = {},
            onRecover = {}, onRefresh = {}, onDismissStatus = {},
            modifier = modifier.fillMaxWidth(),
        )
        return
    }
    val runtimeHost = host
    val controller = remember(runtimeHost) { runtimeHost.c07DataExchange }
    val state by controller.state.collectAsState()
    LaunchedEffect(controller) { controller.enter() }
    LaunchedEffect(state.receipt) {
        if (state.receipt != null) runtimeHost.projects.refresh()
    }

    val createBackup = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("application/zip")
    ) { uri: Uri? ->
        if (uri != null) controller.beginBackup(uri)
    }
    val openBackup = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument()
    ) { uri: Uri? ->
        if (uri != null) controller.beginRestore(uri, importNote = false)
    }
    val openNote = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument()
    ) { uri: Uri? ->
        if (uri != null) controller.beginRestore(uri, importNote = true)
    }

    val suggestedName = remember {
        "Floe-backup-" + LocalDateTime.now()
            .format(DateTimeFormatter.ofPattern("yyyyMMdd-HHmm"))
            + ".floebackup"
    }
    val documentTypes = arrayOf(
        "application/zip",
        "application/x-zip-compressed",
        "application/octet-stream",
    )

    DataExchangeSettingsPage(
        state = state,
        onCreateBackup = { createBackup.launch(suggestedName) },
        onCancelBackup = controller::cancelBackup,
        onPickRestore = { openBackup.launch(documentTypes) },
        onPickNoteImport = { openNote.launch(documentTypes) },
        onConfirmRestore = controller::confirmRestore,
        onCancelRestore = {
            if (state.phase == com.floe.android.feature.dataexchange.DataExchangePhase.REVIEWING) {
                controller.cancelReview()
            } else {
                controller.cancelActive()
            }
        },
        onRecover = controller::recover,
        onRefresh = controller::refresh,
        onDismissStatus = controller::dismissStatus,
        modifier = modifier.fillMaxWidth(),
    )
}
