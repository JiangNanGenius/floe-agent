// SPDX-License-Identifier: MPL-2.0
//
// Shared chrome for the provider/model panes: sheet toolbars (capsule actions),
// section header/footer text, and status lines. Every visual value comes from
// the frozen Floe design-system roles; nothing here invents a new language.

package com.floe.android.feature.providers

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeCapsuleButton
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloeStatusLine
import com.floe.android.design.FloeText

/** Grouped-plane section footer (iOS InsetGrouped footer copy). */
@Composable
fun ProviderSectionFooter(text: String, modifier: Modifier = Modifier) {
    FloeText(
        text = text,
        style = Floe.typography.metadata,
        color = Floe.colors.secondaryLabel,
        modifier = modifier.padding(start = 20.dp, end = 20.dp, top = 6.dp, bottom = 16.dp),
    )
}

/** Inline field-level finding under a card (Swift preflight authority text). */
@Composable
fun ProviderIssueLine(text: String, modifier: Modifier = Modifier) {
    FloeStatusLine(
        icon = FloeIcons.WarningTriangle,
        text = text,
        color = Floe.colors.destructive,
        modifier = modifier.padding(start = 20.dp, end = 20.dp, top = 6.dp),
    )
}

/**
 * Editor sheet toolbar: Cancel leading, Save trailing (large title follows in
 * the scrolling header). In-flight Save shows the spinner and can never
 * dispatch a duplicate (the caller also gates through the holder).
 */
@Composable
fun ProviderEditorToolbar(
    saveLabel: String,
    cancelLabel: String,
    inFlight: Boolean,
    saveEnabled: Boolean,
    onCancel: () -> Unit,
    onSave: () -> Unit,
    modifier: Modifier = Modifier,
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
            modifier = Modifier.testTag("provider.cancelAction"),
        )
        if (inFlight) {
            Row(
                modifier = Modifier.heightIn(min = FloeLayout.MinimumTarget),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                FloeActivityIndicator(description = saveLabel)
                FloeText(saveLabel, style = Floe.typography.bodyEmphasized, color = Floe.colors.secondaryLabel)
            }
        } else {
            FloeCapsuleAction(
                label = saveLabel,
                onClick = onSave,
                enabled = saveEnabled,
                tint = Floe.colors.label,
                modifier = Modifier.testTag("provider.saveAction"),
            )
        }
    }
}

/**
 * Inline editor toolbar (nested model editor) — mirrors the iPad
 * `.navigationTitle` + `.navigationBarTitleDisplayMode(.inline)` composition:
 * Cancel leading, the principal title centered on the pane independently of
 * the button widths, Save trailing. Cancel/Save callbacks and the Save enabled
 * gate are preserved; this is the same 3-slot geometry as the model manager.
 */
@Composable
fun ProviderInlineEditorToolbar(
    title: String,
    cancelLabel: String,
    saveLabel: String,
    saveEnabled: Boolean,
    onCancel: () -> Unit,
    onSave: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 10.dp),
    ) {
        FloeCapsuleAction(
            label = cancelLabel,
            onClick = onCancel,
            tint = Floe.colors.label,
            modifier = Modifier.align(Alignment.CenterStart),
        )
        FloeText(
            title,
            style = Floe.typography.toolbarTitle,
            color = Floe.colors.label,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier
                .align(Alignment.Center)
                .padding(horizontal = 88.dp),
        )
        FloeCapsuleAction(
            label = saveLabel,
            onClick = onSave,
            enabled = saveEnabled,
            tint = Floe.colors.label,
            modifier = Modifier.align(Alignment.CenterEnd),
        )
    }
}

/**
 * Inline pane toolbar (model manager) — follows the captured iPad header
 * (ios-reference/10-model-management-empty.png): refresh circle leading, the
 * principal title centered on the pane, and the Done capsule trailing. The
 * title is centered independently of the different leading/trailing button
 * widths so EN and ZH keep the same composition.
 */
@Composable
fun ProviderInlinePaneToolbar(
    title: String,
    leadingDescription: String?,
    leadingEnabled: Boolean,
    onLeading: () -> Unit,
    leadingInFlight: Boolean,
    trailingLabel: String,
    onTrailing: () -> Unit,
    modifier: Modifier = Modifier,
    showLeading: Boolean = true,
) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 10.dp),
    ) {
        Row(
            modifier = Modifier
                .align(Alignment.CenterStart)
                .heightIn(min = FloeLayout.MinimumTarget),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (showLeading && leadingDescription != null) {
                if (leadingInFlight) {
                    Row(
                        modifier = Modifier.heightIn(min = FloeLayout.MinimumTarget),
                        verticalAlignment = Alignment.CenterVertically,
                    ) { FloeActivityIndicator() }
                } else {
                    FloeCircleButton(
                        icon = FloeIcons.Refresh,
                        contentDescription = leadingDescription,
                        onClick = onLeading,
                        enabled = leadingEnabled,
                        visualSize = 38.dp,
                        iconSize = 18.dp,
                    )
                }
            }
        }
        FloeText(
            title,
            style = Floe.typography.toolbarTitle,
            color = Floe.colors.label,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier
                .align(Alignment.Center)
                .padding(horizontal = 88.dp),
        )
        FloeCapsuleAction(
            label = trailingLabel,
            onClick = onTrailing,
            tint = Floe.colors.label,
            modifier = Modifier
                .align(Alignment.CenterEnd)
                .testTag("provider.doneAction"),
        )
    }
}

/**
 * Purpose chooser body (⇄ ProviderListView.swift:84 confirmationDialog).
 * The host chooses the surface: on wide windows the presentation host resolves
 * the measured Settings category boundary (or the measured + trigger when the
 * category is collapsed); compact keeps the bottom action sheet. Only the
 * three real service roles are offered; selection and dismissal stay with the
 * caller so the provider navigation/holder ownership is unchanged.
 *
 * The copy and controls are the same on both surfaces. The capsule labels opt
 * into unbounded wrapping so translated or large-font role names grow the
 * content-fit popover (the body scrolls when needed) instead of being
 * ellipsized or clipped inside a fixed role row.
 */
@Composable
internal fun ProviderPurposeChooserContent(
    onRoleChosen: (ProviderServiceRoleUi) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        FloeText(
            stringResource(R.string.role_chooser_message),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
            modifier = Modifier.padding(horizontal = 4.dp, vertical = 6.dp),
        )
        ProviderPurposeRoleButton(
            role = ProviderServiceRoleUi.CONVERSATION,
            onRoleChosen = onRoleChosen,
        )
        ProviderPurposeRoleButton(
            role = ProviderServiceRoleUi.IMAGE,
            onRoleChosen = onRoleChosen,
        )
        ProviderPurposeRoleButton(
            role = ProviderServiceRoleUi.VIDEO,
            onRoleChosen = onRoleChosen,
        )
    }
}

@Composable
private fun ProviderPurposeRoleButton(
    role: ProviderServiceRoleUi,
    onRoleChosen: (ProviderServiceRoleUi) -> Unit,
) {
    FloeCapsuleButton(
        // The chooser uses the native confirmationDialog provider labels
        // (ProviderListView.swift:84-88), not the shorter editor section
        // labels ("Chat model" / "Image generation and editing").
        label = roleChooserLabel(role),
        onClick = { onRoleChosen(role) },
        modifier = Modifier.testTag("provider.purposeOption.${role.name}"),
        maxLines = Int.MAX_VALUE,
    )
}

@Composable
private fun roleChooserLabel(role: ProviderServiceRoleUi): String = when (role) {
    ProviderServiceRoleUi.CONVERSATION -> stringResource(R.string.role_conversation_provider)
    ProviderServiceRoleUi.IMAGE -> stringResource(R.string.role_image_provider)
    ProviderServiceRoleUi.VIDEO -> stringResource(R.string.role_video_provider)
}
