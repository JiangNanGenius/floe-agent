// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import com.floe.android.design.FloeVerticalDivider
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeApprovalCard
import com.floe.android.design.FloeAssistantMessage
import com.floe.android.design.FloeCheckboxRow
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloeReasoningBlock
import com.floe.android.design.FloeText
import com.floe.android.design.FloeToolCard
import com.floe.android.design.FloeToolbar
import com.floe.android.design.FloeUserBubble
import com.floe.android.design.InspectorContent
import com.floe.android.design.InspectorRoute

/**
 * DEBUG-ONLY component preview opened from Diagnostics. Every item is an
 * explicitly labelled synthetic fixture rendered with the real reusable
 * thread/tool/approval components — this never populates the default app or
 * claims user history. Sample selection controls and the optional inspector
 * route work here so G02 can bind live state without replacing components.
 */
@Composable
fun ComponentPreviewScreen(onDismiss: () -> Unit) {
    val colors = Floe.colors
    var tool1Expanded by rememberSaveable { mutableStateOf(false) }
    var tool2Expanded by rememberSaveable { mutableStateOf(true) }
    var reasoningExpanded by rememberSaveable { mutableStateOf(false) }
    var sel1 by rememberSaveable { mutableStateOf(false) }
    var sel2 by rememberSaveable { mutableStateOf(false) }
    var approvalChoice by rememberSaveable { mutableStateOf<String?>(null) }
    var showInspector by rememberSaveable { mutableStateOf(false) }

    BackHandler(onBack = { if (showInspector) showInspector = false else onDismiss() })
    Column(
        Modifier
            .fillMaxSize()
            .background(colors.readingSurface)
            .statusBarsPadding()
            .navigationBarsPadding()
            .imePadding(),
    ) {
        FloeToolbar(
            title = stringResource(R.string.component_preview_title),
            background = colors.readingSurface,
            navigation = {
                FloeCircleButton(
                    icon = FloeIcons.Xmark,
                    contentDescription = stringResource(R.string.close),
                    onClick = onDismiss,
                    visualSize = 38.dp,
                    iconSize = 17.dp,
                )
            },
            actions = {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    SyntheticBannerLabel()
                    Spacer(Modifier.height(0.dp))
                    FloeCircleButton(
                        icon = FloeIcons.Terminal,
                        contentDescription = stringResource(R.string.inspector_sample_open),
                        onClick = { showInspector = !showInspector },
                        visualSize = 38.dp,
                        iconSize = 18.dp,
                    )
                }
            },
        )
        Row(Modifier.weight(1f).fillMaxWidth()) {
            Column(
                Modifier
                    .weight(1f)
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 14.dp),
            ) {
                FloeText(
                    stringResource(R.string.synthetic_fixture_banner),
                    style = Floe.typography.metadata,
                    color = colors.pending,
                    modifier = Modifier.padding(vertical = 10.dp),
                )
                FloeUserBubble(
                    text = stringResource(R.string.preview_user_bubble),
                    metadata = stringResource(R.string.preview_synthetic),
                    modifier = Modifier.fillMaxWidth(),
                )
                FloeAssistantMessage(
                    text = stringResource(R.string.preview_assistant_message),
                    metadata = stringResource(R.string.preview_synthetic),
                )
                FloeReasoningBlock(
                    label = stringResource(R.string.preview_reasoning),
                    excerpt = stringResource(R.string.preview_reasoning_excerpt),
                    expanded = reasoningExpanded,
                    onToggle = { reasoningExpanded = !reasoningExpanded },
                )
                FloeToolCard(
                    toolName = "exec.shell",
                    statusIcon = FloeIcons.Checkmark,
                    statusLabel = stringResource(R.string.preview_status_done),
                    summary = stringResource(R.string.preview_tool1_summary),
                    evidence = listOf(
                        "$ echo floe-preview",
                        "floe-preview",
                        "exit=0 duration=0.02s",
                    ),
                    expanded = tool1Expanded,
                    onToggleExpanded = { tool1Expanded = !tool1Expanded },
                    selected = sel1,
                    onSelectionChange = { sel1 = it },
                )
                FloeToolCard(
                    toolName = "file.write",
                    statusIcon = FloeIcons.Clock,
                    statusLabel = stringResource(R.string.preview_status_running),
                    summary = stringResource(R.string.preview_tool2_summary),
                    evidence = listOf("path: notes/floe-outline.md (synthetic)"),
                    expanded = tool2Expanded,
                    onToggleExpanded = { tool2Expanded = !tool2Expanded },
                    selected = sel2,
                    onSelectionChange = { sel2 = it },
                )
                FloeText(
                    stringResource(R.string.preview_selection_count, sel1.toInt() + sel2.toInt()),
                    style = Floe.typography.metadata,
                    color = colors.secondaryLabel,
                    modifier = Modifier.padding(vertical = 6.dp),
                )
                FloeApprovalCard(
                    title = stringResource(R.string.preview_approval_title),
                    reason = stringResource(R.string.preview_approval_reason),
                    allowLabel = stringResource(R.string.preview_allow),
                    denyLabel = stringResource(R.string.preview_deny),
                    onAllow = { approvalChoice = "allow" },
                    onDeny = { approvalChoice = "deny" },
                )
                if (approvalChoice != null) {
                    FloeText(
                        stringResource(R.string.preview_approval_recorded),
                        style = Floe.typography.metadata,
                        color = colors.success,
                        modifier = Modifier.padding(vertical = 6.dp),
                    )
                }
                Spacer(Modifier.height(20.dp))
            }
            if (showInspector) {
                FloeVerticalDivider()
                Box(
                    Modifier
                        .widthIn(min = 300.dp, max = 430.dp)
                        .fillMaxSize()
                        .background(colors.readingSurface),
                ) {
                    FloeInspectorPane(
                        route = InspectorRoute(InspectorContent.PROGRESS, "synthetic-preview"),
                        onDismiss = { showInspector = false },
                    )
                }
            }
        }
    }
}

@Composable
private fun SyntheticBannerLabel() {
    val colors = Floe.colors
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(7.dp))
            .background(colors.pending.copy(alpha = 0.14f))
            .padding(horizontal = 8.dp, vertical = 4.dp),
    ) {
        FloeText(
            stringResource(R.string.preview_debug_badge),
            style = Floe.typography.metadata,
            color = colors.pending,
        )
    }
}

private fun Boolean.toInt() = if (this) 1 else 0
