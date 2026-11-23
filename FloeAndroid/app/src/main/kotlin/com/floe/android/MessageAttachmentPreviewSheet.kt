// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloeText
import com.floe.android.design.FloeToolbarIconButton
import com.floe.android.host.MessageAttachmentPreviewController

@Composable
internal fun MessageAttachmentPreviewSheet(
    controller: MessageAttachmentPreviewController,
    conversationId: String,
    compact: Boolean,
) {
    val state by controller.state.collectAsState()
    DisposableEffect(controller, conversationId) {
        onDispose { controller.dismiss(conversationId) }
    }
    val entry = state?.takeIf { it.request.conversationId == conversationId } ?: return
    val context = LocalContext.current
    val onDismiss = { controller.dismiss(conversationId) }
    FloePageSheet(
        visible = true, onDismiss = onDismiss, widthFraction = if (compact) 1f else .74f,
        heightFraction = if (entry.file != null && entry.text == null) .35f else .86f,
    ) {
        Column(Modifier.fillMaxSize()) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FloeText(
                    text = entry.request.displayName.ifBlank { stringResource(R.string.message_attachment_title) },
                    style = Floe.typography.toolbarTitle, modifier = Modifier.weight(1f),
                    maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
                FloeToolbarIconButton(FloeIcons.ChevronDown, stringResource(R.string.done), onClick = onDismiss)
            }
            FloeDivider()
            Column(
                Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                when {
                    entry.loading -> FloeActivityIndicator()
                    entry.file == null -> FloeText(stringResource(R.string.message_attachment_unavailable))
                    entry.text != null -> {
                        SelectionContainer { FloeText(entry.text, style = Floe.typography.evidence) }
                        if (entry.truncated) FloeText(stringResource(R.string.message_attachment_preview_truncated))
                    }
                }
                if (entry.externalOpenFailed) FloeText(stringResource(R.string.message_attachment_external_unavailable))
            }
            if (entry.file != null) {
                FloeDivider()
                FloeCapsuleAction(
                    label = stringResource(R.string.message_attachment_open_with),
                    onClick = { controller.openWith(context, entry) },
                    modifier = Modifier.fillMaxWidth().padding(16.dp),
                )
            }
        }
    }
}
