// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import android.content.ClipData
import android.content.ClipboardManager
import android.os.Build
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import com.floe.android.BuildConfig
import com.floe.android.R
import com.floe.android.design.*

/** Explicit local details only. No paths, commands, output, VNC credentials,
 * connection addresses or automatic report upload are included. */
@Composable
internal fun LinuxDesktopDiagnosticsAction(state: LinuxDesktopState) {
    val context = LocalContext.current
    var visible by remember { mutableStateOf(false) }
    if (state.failure != null && state.failureStage in setOf("packages", "session_bus", "vnc_tools", "desktop")) {
        FloeText(stringResource(R.string.linux_desktop_components_hint), color = Floe.colors.secondaryLabel)
    }
    FloeCapsuleButton(stringResource(R.string.linux_desktop_diagnostics), onClick = { visible = true })
    if (visible) {
        fun safe(value: String?) = value?.takeIf { it.matches(Regex("[A-Za-z0-9_.:-]{1,128}")) } ?: "-"
        val text = stringResource(R.string.linux_desktop_diagnostic_content,
            Build.VERSION.SDK_INT.toString(), "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})",
            safe(state.phase), safe(state.failureStage), safe(state.failureCode), safe(state.taskID),
            safe(state.workspaceID), safe(state.environmentID), safe(state.runtimeGeneration))
        FloeConfirmDialog(title = stringResource(R.string.linux_desktop_diagnostics), message = text,
            confirmLabel = stringResource(R.string.linux_desktop_copy_details), dismissLabel = stringResource(R.string.done),
            onConfirm = {
                val copied = runCatching {
                    checkNotNull(context.getSystemService(ClipboardManager::class.java)).setPrimaryClip(
                        ClipData.newPlainText(context.getString(R.string.linux_desktop_diagnostics), text))
                }.isSuccess
                if (copied) visible = false
                else android.widget.Toast.makeText(context, R.string.linux_desktop_copy_failed,
                    android.widget.Toast.LENGTH_SHORT).show()
            }, onDismiss = { visible = false })
    }
}
