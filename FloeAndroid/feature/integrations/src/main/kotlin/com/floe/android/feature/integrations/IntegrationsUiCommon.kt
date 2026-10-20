// SPDX-License-Identifier: MPL-2.0
//
// Shared chrome for the Skills/MCP panes. Visual values come only from the
// frozen Floe design-system roles; nothing here invents a new language.
//
// PROVISIONAL geometry: no native iPad captures exist yet for the Skills /
// Connectors / MCP screens (ios-reference currently holds the 12 provider
// screens only). The width/height fractions below deliberately reuse the
// measured provider-sheet language (large grouped editor ≈72–82% centered on
// wide, full-width bottom on compact) as a stand-in. Main will capture the
// real iPad references and tune these constants; the structure (toolbar
// placement, section order, controls) is mapped 1:1 from the SwiftUI source.

package com.floe.android.feature.integrations

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloeStatusLine
import com.floe.android.design.FloeText

/** Provisional sheet fractions pending iPad captures (see header). */
internal object IntegrationsSheetMetrics {
    const val MCP_EDITOR_WIDTH_FRACTION = 0.72f
    const val MCP_EDITOR_HEIGHT_FRACTION = 0.86f
    const val UPGRADE_WIDTH_FRACTION = 0.72f
    const val UPGRADE_HEIGHT_FRACTION = 0.86f
    const val INSTALL_REVIEW_WIDTH_FRACTION = 0.60f
    const val INSTALL_REVIEW_HEIGHT_FRACTION = 0.72f
    const val SKILL_FORM_WIDTH_FRACTION = 0.60f
    const val SKILL_FORM_HEIGHT_FRACTION = 0.66f
}

/** Grouped-plane section footer (iOS InsetGrouped footer copy). */
@Composable
fun IntegrationSectionFooter(text: String, modifier: Modifier = Modifier) {
    FloeText(
        text = text,
        style = Floe.typography.metadata,
        color = Floe.colors.secondaryLabel,
        modifier = modifier.padding(start = 20.dp, end = 20.dp, top = 6.dp, bottom = 16.dp),
    )
}

/** Inline host finding line (destructive text + warning glyph, readable). */
@Composable
fun IntegrationIssueLine(text: String, modifier: Modifier = Modifier) {
    FloeStatusLine(
        icon = FloeIcons.WarningTriangle,
        text = text,
        color = Floe.colors.destructive,
        modifier = modifier.padding(start = 20.dp, end = 20.dp, top = 6.dp),
    )
}

/** Secondary metadata line (catalog status, host explanations). */
@Composable
fun IntegrationMetaLine(text: String, modifier: Modifier = Modifier) {
    FloeText(
        text = text,
        style = Floe.typography.metadata,
        color = Floe.colors.secondaryLabel,
        modifier = modifier.padding(horizontal = 20.dp, vertical = 4.dp),
        maxLines = 3,
        overflow = TextOverflow.Ellipsis,
    )
}

/**
 * Sheet toolbar for pushed/presented forms: Cancel leading, confirm-action
 * trailing, spinner in place of the confirm while in flight (never a fake
 * success). Mirrors the provider editor chrome so both flows read alike.
 */
@Composable
fun IntegrationEditorToolbar(
    confirmLabel: String,
    cancelLabel: String,
    inFlight: Boolean,
    confirmEnabled: Boolean,
    onCancel: () -> Unit,
    onConfirm: () -> Unit,
    modifier: Modifier = Modifier,
    confirmTint: androidx.compose.ui.graphics.Color? = null,
    confirmTag: String = "integration.confirmAction",
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        FloeCapsuleAction(
            label = cancelLabel,
            onClick = onCancel,
            tint = Floe.colors.label,
            modifier = Modifier.testTag("integration.cancelAction"),
        )
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (inFlight) {
                FloeActivityIndicator(description = confirmLabel)
            } else {
                FloeCapsuleAction(
                    label = confirmLabel,
                    onClick = onConfirm,
                    enabled = confirmEnabled,
                    tint = confirmTint,
                    modifier = Modifier.testTag(confirmTag),
                )
            }
        }
    }
}

/** Inline list-pane header: large title leading + trailing circular actions. */
@Composable
fun IntegrationPaneHeader(
    title: String,
    modifier: Modifier = Modifier,
    actions: @Composable RowScope.() -> Unit = {},
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp)
            .padding(start = 16.dp, end = 12.dp, top = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        FloeText(
            title,
            style = Floe.typography.navLargeTitle,
            color = Floe.colors.label,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            content = actions,
        )
    }
}

/** Circular chrome button re-exported for page brevity. */
@Composable
fun IntegrationCircleAction(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    contentDescription: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    FloeCircleButton(
        icon = icon,
        contentDescription = contentDescription,
        onClick = onClick,
        modifier = modifier,
        enabled = enabled,
    )
}

/** Back-chevron row header for pushed list panes (⇄ NavigationLink titles). */
@Composable
fun IntegrationPushedPaneHeader(title: String, onBack: () -> Unit, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = FloeLayout.MinimumTarget)
            .padding(horizontal = 8.dp, vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        FloeCircleButton(
            icon = FloeIcons.ChevronBack,
            contentDescription = title,
            onClick = onBack,
            visualSize = 34.dp,
            iconSize = 18.dp,
        )
        Column(Modifier.padding(start = 6.dp)) {
            FloeText(title, style = Floe.typography.navLargeTitle, color = Floe.colors.label)
        }
    }
}
