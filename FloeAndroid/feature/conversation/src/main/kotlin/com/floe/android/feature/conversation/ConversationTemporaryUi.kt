// SPDX-License-Identifier: MPL-2.0
//
// Temporary (ephemeral) chat presentation (⇄ ThreadDetailView
// temporaryToolbarItems + TemporaryChatAboutSheet + the VM keep/end state
// machine).
//
// Invariants carried here (TMP-*):
//  - the session lives in RAM only; this surface keeps NO persistent copy
//    (no SavedStateHandle/Bundle/DataStore/preferences/log path exists in
//    this module for any ephemeral content);
//  - backgrounding / lock / rotation retain the session (holders survive);
//    genuine navigation to another conversation or New Task fences and
//    discards host-side, even mid-run — the UI shows whatever the host then
//    projects, and late callbacks are epoch-fenced in the holder;
//  - Keep is only honored after the host's atomic promotion confirms THIS
//    incarnation (applyTemporaryKeepOutcome); PartialRetry is honest ("the
//    durable save committed, the tail is still syncing"), never "nothing
//    saved";
//  - ordinary saved chats NEVER show a temporary switch: starting temporary
//    chat is the New Task launchpad's only entry, so a saved thread cannot
//    implicitly convert itself from within;
//  - the text-only + public-web tool ceiling and the provider's processing
//    policy are stated in readable form in the About sheet — the menu row
//    only carries the short lifecycle line (matching the iOS clamp fix).

package com.floe.android.feature.conversation

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeChipMenu
import com.floe.android.design.CupertinoMenuEntry
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloeText
import com.floe.android.design.FloeToolbar
import com.floe.android.design.IconGlyph

/**
 * The compact header badge menu shown only while the host projects this
 * conversation as the active temporary session. Same entries as the native
 * menu: lifecycle header, About, Keep (state-labeled), End.
 */
@Composable
fun TemporaryChatBadgeMenu(holder: ConversationFlowHolder, modifier: Modifier = Modifier) {
    val state = holder.snapshot.value ?: return
    if (!state.isTemporary) return
    var menuExpanded by remember(state.session) { mutableStateOf(false) }
    val badgeLabel = stringResource(R.string.temporary_badge)
    val aboutLabel = stringResource(R.string.temporary_about)
    val endLabel = stringResource(R.string.temporary_end)
    val keepLabel = stringResource(
        when (holder.temporaryKeepState) {
            TemporaryKeepStateUi.Saving -> R.string.temporary_keep_saving
            TemporaryKeepStateUi.PartialRetry -> R.string.temporary_keep_partial_retry
            is TemporaryKeepStateUi.Failed -> R.string.temporary_keep_failed_retry
            TemporaryKeepStateUi.Idle -> R.string.temporary_keep
        }
    )
    Box(modifier = modifier) {
        Row(
            modifier = Modifier
                .heightIn(min = FloeLayout.MinimumTarget)
                .clickable { menuExpanded = true }
                .padding(horizontal = 10.dp)
                .semantics { contentDescription = badgeLabel },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            IconGlyph(FloeIcons.Bubble, Floe.colors.accent, 16.dp)
            FloeText(badgeLabel, style = Floe.typography.bodyEmphasized, color = Floe.colors.accent)
        }
        FloeChipMenu(expanded = menuExpanded, onDismiss = { menuExpanded = false }) {
            CupertinoMenuEntry(
                title = stringResource(R.string.temporary_header_line),
                selected = false,
                onClick = { /* informational row: lifecycle clamp, ⇄ Text header */ },
            )
            CupertinoMenuEntry(
                title = aboutLabel,
                selected = false,
                onClick = {
                    menuExpanded = false
                    holder.openTemporaryAbout()
                },
            )
            CupertinoMenuEntry(
                title = keepLabel,
                selected = false,
                onClick = {
                    menuExpanded = false
                    holder.keepTemporaryChat()
                },
            )
            CupertinoMenuEntry(
                title = endLabel,
                selected = false,
                onClick = {
                    menuExpanded = false
                    holder.endTemporaryChat()
                },
            )
        }
    }
}

/** ⇄ TemporaryChatAboutSheet: the full readable lifecycle/tools-cloud/voice
 * disclosures (never clipped into a menu row). */
@Composable
fun TemporaryChatAboutSheet(holder: ConversationFlowHolder, modifier: Modifier = Modifier) {
    FloePageSheet(
        visible = holder.showsTemporaryAbout,
        onDismiss = holder::dismissTemporaryAbout,
        modifier = modifier,
    ) {
        Column(modifier = Modifier.fillMaxWidth()) {
            FloeToolbar(
                title = stringResource(R.string.temporary_about_title),
                actions = {
                    val doneCd = stringResource(R.string.action_done)
                    Box(
                        modifier = Modifier
                            .heightIn(min = FloeLayout.MinimumTarget)
                            .clickable(onClick = holder::dismissTemporaryAbout)
                            .padding(horizontal = 16.dp)
                            .semantics { contentDescription = doneCd },
                        contentAlignment = Alignment.Center,
                    ) {
                        FloeText(stringResource(R.string.action_done), style = Floe.typography.bodyEmphasized, color = Floe.colors.accent)
                    }
                },
            )
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                FloeText(stringResource(R.string.temporary_about_lifecycle), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                FloeText(stringResource(R.string.temporary_about_tools), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                FloeText(stringResource(R.string.temporary_about_voice), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                Spacer(Modifier.height(8.dp))
                when (val keep = holder.temporaryKeepState) {
                    is TemporaryKeepStateUi.Failed -> FloeText(
                        stringResource(R.string.temporary_keep_failed_detail, keep.message),
                        style = Floe.typography.metadata,
                        color = Floe.colors.destructive,
                    )
                    TemporaryKeepStateUi.PartialRetry -> FloeText(
                        stringResource(R.string.temporary_keep_partial_detail),
                        style = Floe.typography.metadata,
                        color = Floe.colors.pending,
                    )
                    else -> Unit
                }
            }
        }
    }
}
