// SPDX-License-Identifier: MPL-2.0
package com.floe.android.design

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

/**
 * Representative thread components: the same composables a real thread will
 * render after G02. Geometry is ported from the iOS chat surface
 * (UserMessageBubble r12 / accent@14% / h12 v8; ToolCallCard/ApprovalCard
 * sectioned cards). They are layout+state primitives: they never fabricate
 * user history by themselves — synthetic fixtures must be passed in and
 * labelled.
 */

/** UserMessageBubble.swift: RoundedRectangle(12), primary@0.14, h12/v8. */
@Composable
fun FloeUserBubble(
    text: String,
    modifier: Modifier = Modifier,
    metadata: String? = null,
) {
    val colors = Floe.colors
    Column(
        modifier = modifier
            .padding(horizontal = 12.dp, vertical = 8.dp)
            .clip(RoundedCornerShape(FloeLayout.BubbleCorner))
            .background(colors.accentFillBubble)
            .padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
        FloeText(text, style = Floe.typography.body, color = colors.label)
        if (metadata != null) {
            Spacer(Modifier.height(4.dp))
            FloeText(metadata, style = Floe.typography.metadata, color = colors.secondaryLabel)
        }
    }
}

@Composable
fun FloeAssistantMessage(
    text: String,
    modifier: Modifier = Modifier,
    metadata: String? = null,
) {
    val colors = Floe.colors
    Column(modifier = modifier.padding(horizontal = 4.dp, vertical = 6.dp)) {
        FloeText(text, style = Floe.typography.body, color = colors.label)
        if (metadata != null) {
            Spacer(Modifier.height(4.dp))
            FloeText(metadata, style = Floe.typography.metadata, color = colors.secondaryLabel)
        }
    }
}

/** ToolCallCardView analog: collapsible tool result with evidence lines. */
@Composable
fun FloeToolCard(
    toolName: String,
    statusIcon: ImageVector,
    statusLabel: String,
    summary: String,
    evidence: List<String>,
    expanded: Boolean,
    onToggleExpanded: () -> Unit,
    selected: Boolean? = null,
    onSelectionChange: ((Boolean) -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val colors = Floe.colors
    val shape = RoundedCornerShape(FloeLayout.BubbleCorner)
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(vertical = 6.dp)
            .clip(shape)
            .border(0.5.dp, colors.separator, shape)
            .background(colors.sectionCardSurface)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = FloeLayout.MinimumTarget)
                .padding(horizontal = 12.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (onSelectionChange != null && selected != null) {
                // Independent 48dp slot: the checkbox owns its own toggle and
                // never sits inside the expander row's padding or click area.
                FloeSelectionSlot(
                    checked = selected,
                    onCheckedChange = onSelectionChange,
                )
            }
            Row(
                modifier = Modifier
                    .weight(1f)
                    .heightIn(min = FloeLayout.MinimumTarget)
                    .clickable(onClick = onToggleExpanded)
                    .padding(horizontal = 4.dp, vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                IconGlyph(statusIcon, colors.secondaryLabel, 18.dp)
                Column(modifier = Modifier.weight(1f)) {
                    FloeText(toolName, style = Floe.typography.bodyEmphasized, color = colors.label, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    FloeText(summary, style = Floe.typography.metadata, color = colors.secondaryLabel, maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
                FloeText(statusLabel, style = Floe.typography.metadata, color = colors.secondaryLabel)
                IconGlyph(if (expanded) FloeIcons.ChevronUp else FloeIcons.ChevronDown, colors.tertiaryLabel, 14.dp)
            }
        }
        if (expanded) {
            Spacer(Modifier.height(6.dp))
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 12.dp)
                    .padding(bottom = 10.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .background(colors.groupedSurface)
                    .padding(10.dp),
            ) {
                if (evidence.isEmpty()) {
                    FloeText("—", style = Floe.typography.evidence, color = colors.secondaryLabel)
                }
                evidence.forEach { line ->
                    FloeText(line, style = Floe.typography.evidence, color = colors.label, modifier = Modifier.padding(vertical = 1.dp))
                }
            }
        }
    }
}

/** ApprovalCardView analog: pending decision card (amber semantics). */
@Composable
fun FloeApprovalCard(
    title: String,
    reason: String,
    allowLabel: String,
    denyLabel: String,
    onAllow: () -> Unit,
    onDeny: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = Floe.colors
    val shape = RoundedCornerShape(FloeLayout.BubbleCorner)
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(vertical = 6.dp)
            .clip(shape)
            .border(0.5.dp, colors.pending.copy(alpha = 0.5f), shape)
            .background(colors.pending.copy(alpha = 0.08f))
            .padding(12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            IconGlyph(FloeIcons.ShieldAlert, colors.pending, 18.dp)
            FloeText(title, style = Floe.typography.section, color = colors.label)
        }
        Spacer(Modifier.height(6.dp))
        FloeText(reason, style = Floe.typography.metadata, color = colors.secondaryLabel)
        Spacer(Modifier.height(10.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            FloeCardAction(denyLabel, colors.secondaryLabel, onDeny)
            FloeCardAction(allowLabel, colors.accent, onAllow)
        }
    }
}

@Composable
private fun FloeCardAction(label: String, tint: androidx.compose.ui.graphics.Color, onClick: () -> Unit) {
    val shape = RoundedCornerShape(9.dp)
    Column(
        modifier = Modifier
            .heightIn(min = FloeLayout.MinimumTarget)
            .clip(shape)
            .border(0.5.dp, tint.copy(alpha = 0.45f), shape)
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 8.dp)
            .semantics { contentDescription = label },
        verticalArrangement = Arrangement.Center,
    ) {
        FloeText(label, style = Floe.typography.bodyEmphasized, color = tint)
    }
}

/** ReasoningBlockView analog: muted collapsed thinking excerpt. */
@Composable
fun FloeReasoningBlock(
    excerpt: String,
    expanded: Boolean,
    onToggle: () -> Unit,
    modifier: Modifier = Modifier,
    label: String = "",
) {
    val colors = Floe.colors
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(vertical = 6.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(colors.groupedSurface)
            .clickable(onClick = onToggle)
            .padding(horizontal = 12.dp, vertical = 10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            IconGlyph(FloeIcons.Gauge, colors.secondaryLabel, 15.dp)
            FloeText(if (label.isEmpty()) "…" else label, style = Floe.typography.metadata, color = colors.secondaryLabel, modifier = Modifier.weight(1f))
            IconGlyph(if (expanded) FloeIcons.ChevronUp else FloeIcons.ChevronDown, colors.tertiaryLabel, 13.dp)
        }
        if (expanded) {
            Spacer(Modifier.height(6.dp))
            FloeText(excerpt, style = Floe.typography.metadata, color = colors.secondaryLabel)
        }
    }
}
