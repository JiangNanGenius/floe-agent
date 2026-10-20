// SPDX-License-Identifier: MPL-2.0
//
// Providers screen content (⇄ ProviderListView.swift) hosted inside the
// existing settings detail column:
//  - empty state: quiet centered antenna glyph + title + one explanatory
//    sentence; add is a top trailing circular control (reference 02);
//  - populated: role-grouped cards (chat always; image/video only when
//    present) with real saved rows: name, honest credential state, endpoint,
//    model count and the enable switch; tap opens the editor, long-press
//    offers the destructive delete confirmation;
//  - the host's list error (e.g. delete failed) is shown as a plain banner.
// No fabricated data: rows render exactly the host projection.

package com.floe.android.feature.providers

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeHostPopoverCard
import com.floe.android.design.FloeBadgePill
import com.floe.android.design.FloeBadgeTone
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeConfirmDialog
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeInlineSwitch
import com.floe.android.design.FloeSectionRow
import com.floe.android.design.FloeSettingsHostGeometry
import com.floe.android.design.FloeSettingsSectionCard
import com.floe.android.design.FloeStatusLine
import com.floe.android.design.FloeText
import com.floe.android.design.FloeUnavailableView
import com.floe.android.design.FloeWindowInsetsPx

@Composable
fun ProviderListPage(
    state: ProviderListUiState,
    onAdd: () -> Unit,
    onOpen: (role: ProviderServiceRoleUi, providerId: String) -> Unit,
    onToggleEnabled: (providerId: String, enabled: Boolean) -> Unit,
    onDeleteConfirmed: (providerId: String) -> Unit,
    modifier: Modifier = Modifier,
    anchoredRoleChooserVisible: Boolean = false,
    onRoleChosen: (ProviderServiceRoleUi) -> Unit = {},
    onRoleChooserDismiss: () -> Unit = {},
    hostGeometry: FloeSettingsHostGeometry? = null,
) {
    var deleteCandidate by remember { mutableStateOf<ProviderListRowUi?>(null) }
    // Real measured + control geometry. The Settings host (when embedded in
    // the actual page) supplies the measured category/detail/window/insets
    // snapshot; this list owns the + trigger and merges its bounds. The
    // standalone component preview has no category geometry and therefore
    // resolves the measured + trigger fallback. Neither path uses a guessed
    // left origin or a fixed device width.
    var addButtonBounds by remember { mutableStateOf<Rect?>(null) }

    Column(modifier = modifier.fillMaxSize().testTag("provider.list")) {
        // Add: the reference places a circular + at the top trailing edge of
        // the providers content. The host settings header keeps its own
        // large title; this control belongs to the module content.
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 16.dp, end = 16.dp, top = 4.dp),
            horizontalArrangement = Arrangement.End,
        ) {
            FloeCircleButton(
                icon = FloeIcons.Plus,
                contentDescription = stringResource(R.string.provider_add),
                onClick = onAdd,
                modifier = Modifier
                    .onGloballyPositioned { coordinates ->
                        addButtonBounds = coordinates.boundsInWindow()
                    }
                    .testTag("provider.addAction"),
            )
        }

        if (state.errorMessage != null) {
            FloeStatusLine(
                icon = FloeIcons.WarningTriangle,
                text = state.errorMessage,
                color = Floe.colors.destructive,
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp),
            )
        }

        if (state.isLoading && state.isEmpty) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                FloeActivityIndicator(description = stringResource(R.string.loading_cd))
            }
            return@Column
        }

        if (state.isEmpty) {
            Box(Modifier.fillMaxSize().weight(1f)) {
                FloeUnavailableView(
                    icon = FloeIcons.Antenna,
                    title = stringResource(R.string.provider_settings_title),
                    description = stringResource(R.string.provider_empty_hint),
                )
            }
            return@Column
        }

        Column(modifier = Modifier.fillMaxSize().weight(1f).verticalScroll(rememberScrollState())) {
            ProviderListSection(
                title = stringResource(R.string.role_conversation_provider),
                rows = state.conversationProviders,
                role = ProviderServiceRoleUi.CONVERSATION,
                onOpen = onOpen,
                onToggleEnabled = onToggleEnabled,
                onLongPress = { deleteCandidate = it },
            )
            if (state.imageProviders.isNotEmpty()) {
                ProviderListSection(
                    title = stringResource(R.string.section_image_provider),
                    rows = state.imageProviders,
                    role = ProviderServiceRoleUi.IMAGE,
                    onOpen = onOpen,
                    onToggleEnabled = onToggleEnabled,
                    onLongPress = { deleteCandidate = it },
                    footer = stringResource(R.string.section_image_footer),
                )
            }
            if (state.videoProviders.isNotEmpty()) {
                ProviderListSection(
                    title = stringResource(R.string.section_video_provider),
                    rows = state.videoProviders,
                    role = ProviderServiceRoleUi.VIDEO,
                    onOpen = onOpen,
                    onToggleEnabled = onToggleEnabled,
                    onLongPress = { deleteCandidate = it },
                    footer = stringResource(R.string.section_video_footer),
                )
            }
            Spacer(Modifier.height(16.dp))
        }
    }

    // Wide purpose menu. The host geometry resolves the real category pane
    // trailing boundary plus the selected row vertical reference; the card is
    // content-fit and the arrow points right into the boundary. If the wide
    // category is collapsed or absent (or the standalone component has no
    // Settings host), the same resolver attaches a content-fit card to this
    // measured + trigger. Compact windows keep the bottom action sheet
    // rendered by the destination; the resolver suppresses the popup there.
    val anchor = addButtonBounds
    if (anchoredRoleChooserVisible && anchor != null) {
        val density = LocalDensity.current
        val layoutDirection = LocalLayoutDirection.current
        val windowInfo = LocalWindowInfo.current
        val safeDrawing = WindowInsets.safeDrawing
        val safeBottom = safeDrawing.getBottom(density)
        val imeBottom = WindowInsets.ime.getBottom(density)
        val baseGeometry = if (hostGeometry != null) {
            hostGeometry
        } else {
            remember(density, windowInfo.containerSize, safeDrawing, safeBottom, imeBottom) {
                val width = windowInfo.containerSize.width.coerceAtLeast(1)
                val height = windowInfo.containerSize.height.coerceAtLeast(1)
                FloeSettingsHostGeometry(
                    windowBoundsPx = Rect(0f, 0f, width.toFloat(), height.toFloat()),
                    categoryPaneBoundsPx = null,
                    detailPaneBoundsPx = null,
                    triggerBoundsPx = null,
                    safeInsetsPx = FloeWindowInsetsPx(
                        leftPx = safeDrawing.getLeft(density, layoutDirection),
                        topPx = safeDrawing.getTop(density),
                        rightPx = safeDrawing.getRight(density, layoutDirection),
                        bottomPx = safeBottom,
                    ),
                    imeBottomInsetPx = (imeBottom - safeBottom).coerceAtLeast(0),
                    wideLayout = true,
                    categoryPaneVisible = false,
                    density = density.density,
                    fontScale = density.fontScale,
                )
            }
        }
        FloeHostPopoverCard(
            visible = true,
            onDismiss = onRoleChooserDismiss,
            // The ADD button lives in the DETAIL pane: this chooser must
            // anchor to the ACTUAL plus bounds (trigger fallback), never to
            // the host's selected CATEGORY row. The host geometry carries a
            // selected-category-row anchor for the category-level purpose
            // surface, so it is explicitly cleared here (otherwise the mode
            // resolver chooses CATEGORY_BOUNDARY and the menu jumps into the
            // left category pane).
            geometry = baseGeometry.copy(
                triggerBoundsPx = anchor,
                selectedCategoryRowBoundsPx = null,
                selectedProviderRowBoundsPx = null,
            ),
            modifier = Modifier.testTag("provider.purposeMenu"),
        ) {
            ProviderPurposeChooserContent(onRoleChosen = onRoleChosen)
        }
    }

    val candidate = deleteCandidate
    if (candidate != null) {
        FloeConfirmDialog(
            title = stringResource(R.string.delete_confirm_title),
            message = stringResource(R.string.delete_confirm_message),
            confirmLabel = stringResource(R.string.menu_delete),
            dismissLabel = stringResource(R.string.action_cancel),
            onConfirm = {
                deleteCandidate = null
                onDeleteConfirmed(candidate.providerId)
            },
            onDismiss = { deleteCandidate = null },
        )
    }
}

@Composable
private fun ProviderListSection(
    title: String,
    rows: List<ProviderListRowUi>,
    role: ProviderServiceRoleUi,
    onOpen: (role: ProviderServiceRoleUi, providerId: String) -> Unit,
    onToggleEnabled: (providerId: String, enabled: Boolean) -> Unit,
    onLongPress: (ProviderListRowUi) -> Unit,
    footer: String? = null,
) {
    Column(Modifier.padding(horizontal = 16.dp, vertical = 6.dp)) {
        FloeSettingsSectionCard(title = title) {
            rows.forEach { row ->
                FloeSectionRow(
                    onClick = { onOpen(role, row.providerId) },
                    onLongClick = { onLongPress(row) },
                    title = {
                        ProviderRowTitle(row)
                    },
                    trailing = {
                        FloeInlineSwitch(
                            checked = row.enabled,
                            onCheckedChange = { onToggleEnabled(row.providerId, it) },
                            description = stringResource(R.string.row_enable_cd),
                        )
                    },
                )
            }
        }
        if (footer != null) {
            ProviderSectionFooter(footer)
        }
    }
}

@Composable
private fun ProviderRowTitle(row: ProviderListRowUi) {
    Column(modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FloeText(
                row.displayName,
                style = Floe.typography.body,
                color = Floe.colors.label,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false),
            )
            if (row.credentialState == ProviderCredentialStateUi.AWAITING_CONFIGURATION) {
                FloeBadgePill(
                    text = stringResource(R.string.row_waiting_key),
                    tone = FloeBadgeTone.PENDING,
                )
            }
            if (!row.enabled) {
                FloeText(
                    stringResource(R.string.row_disabled),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
        }
        FloeText(
            row.endpointSummary,
            style = Floe.typography.evidence,
            color = Floe.colors.secondaryLabel,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        FloeText(
            stringResource(R.string.row_models_count, row.modelCount),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
    }
}
