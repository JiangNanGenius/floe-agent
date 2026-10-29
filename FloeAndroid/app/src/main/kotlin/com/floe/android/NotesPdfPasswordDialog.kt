// SPDX-License-Identifier: MPL-2.0
@file:OptIn(io.github.robinpcrd.cupertino.ExperimentalCupertinoApi::class)

package com.floe.android

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
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
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloeSecureFormField
import com.floe.android.design.FloeSettingsSectionCard
import com.floe.android.design.FloeSheetPlacement
import com.floe.android.design.FloeText
import com.floe.android.design.FloeToolbar
import com.floe.android.notesplatform.NotesPdfPasswordPromptBroker

@Composable
internal fun NotesPdfPasswordDialog(broker: NotesPdfPasswordPromptBroker) {
    val request by broker.prompt.collectAsState()
    val prompt = request ?: return
    // Intentionally not saveable. Rotation starts a fresh empty secure field.
    val secret = remember(prompt.id) { mutableStateOf("") }
    var revealed by remember(prompt.id) { mutableStateOf(false) }
    DisposableEffect(prompt.id) {
        onDispose { secret.value = "" }
    }
    val windowWidth = with(LocalDensity.current) { LocalWindowInfo.current.containerSize.width.toDp() }
    val widthFraction = if (windowWidth > 0.dp) (440.dp / windowWidth).coerceIn(0.3f, 0.94f) else 0.9f
    val dismiss = {
        secret.value = ""
        broker.cancelPending(prompt.id)
    }
    FloePageSheet(
        visible = true,
        onDismiss = dismiss,
        placement = FloeSheetPlacement.CENTER,
        widthFraction = widthFraction,
        heightFraction = 0.55f,
    ) {
        Column(Modifier.fillMaxSize().background(Floe.colors.sidebarSurface)) {
            FloeToolbar(
                title = stringResource(R.string.notes_pdf_unlock_title),
                navigation = { FloeCapsuleAction(stringResource(R.string.cancel), onClick = dismiss) },
                actions = {
                    FloeCapsuleAction(
                        label = stringResource(R.string.notes_pdf_unlock_open),
                        enabled = secret.value.isNotEmpty(),
                        onClick = {
                            val characters = secret.value.toCharArray()
                            secret.value = ""
                            broker.answer(prompt.id, characters)
                        },
                    )
                },
            )
            Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp)) {
                FloeText(prompt.fileName, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                FloeSettingsSectionCard(title = null) {
                    FloeSecureFormField(
                        label = stringResource(R.string.notes_pdf_unlock_password),
                        value = secret.value,
                        onValueChange = { if (it.length <= 512) secret.value = it },
                        revealed = revealed,
                        onRevealedChange = { revealed = it },
                        revealOnLabel = stringResource(R.string.notes_pdf_unlock_show),
                        revealOffLabel = stringResource(R.string.notes_pdf_unlock_hide),
                    )
                }
            }
        }
    }
}
