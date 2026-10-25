// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.ide.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActionSheet
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloeText
import com.floe.android.design.IconGlyph
import com.floe.android.feature.ide.IdeDiffLineKind
import com.floe.android.feature.ide.IdePresenter
import com.floe.android.feature.ide.IdeTabItem
import com.floe.android.feature.ide.IdeViewState
import com.floe.android.feature.ide.R
import com.floe.android.feature.ide.api.IdeCloseDecision
import com.floe.android.feature.ide.api.IdeConflictChoice

/**
 * The IDE editor column: tab strip + command bar + real Sora editor + find /
 * replace bar + status strip, with the diff and conflict surfaces on top.
 * Structure mirrors the iPad `IDENativeTextPane` (tabStrip → editor →
 * findReplaceBar → statusBar) inside the Floe chrome.
 */
@Composable
internal fun IdeEditorArea(
    presenter: IdePresenter,
    state: IdeViewState,
    compact: Boolean,
    onOpenTree: () -> Unit,
    onBack: () -> Unit,
    showTreeButton: Boolean,
) {
    val colors = Floe.colors
    Column(Modifier.fillMaxSize().background(colors.readingSurface)) {
        IdeCommandBar(presenter, state, compact, onOpenTree, onBack, showTreeButton)
        if (state.tabs.isNotEmpty()) {
            IdeTabBar(
                tabs = state.tabs,
                onActivate = presenter::activateTab,
                onClose = presenter::requestCloseTab,
            )
            FloeDivider()
        }
        // Editor body with honest availability states.
        Box(Modifier.weight(1f)) {
            val snapshot = state.snapshot
            when {
                state.activeDocumentKey == null -> EmptyEditorState()
                state.documentLoading -> LoadingEditorState()
                snapshot == null -> LoadingEditorState()
                else -> {
                    SoraEditorView(presenter = presenter, state = state, modifier = Modifier.fillMaxSize())
                    if (state.diff != null) {
                        IdeDiffOverlay(state = state, onClose = presenter::dismissDiff)
                    }
                }
            }
            state.syncError?.let { message ->
                SyncBanner(
                    message = message,
                    canRestore = state.hasRejectedEdits,
                    onRestore = presenter::restoreRejectedEdits,
                    onDismiss = presenter::dismissSyncError,
                    modifier = Modifier.align(Alignment.TopCenter),
                )
            }
        }
        if (state.find.open) {
            FloeDivider()
            IdeFindBar(presenter, state)
        }
        IdeStatusStrip(state)
    }

    // Close-with-dirty decision. Window-bounded secondary popup (device
    // evidence 2026-10-25): the old fractions keyed `compact` from the
    // 430dp inspector pane, so on the real tablet window the sheet opened
    // 1f-wide across the whole 2560x1600 screen. FloeActionSheet sizes
    // against the ACTUAL window inside its Dialog — bounded centered card
    // on wide windows, bottom sheet on compact ones — exactly like the
    // already-fixed filetree picker. All decision callbacks unchanged.
    FloeActionSheet(
        visible = state.closeRequest != null,
        onDismiss = presenter::dismissCloseRequest,
    ) {
        val request = state.closeRequest ?: return@FloeActionSheet
        Column(
            modifier = Modifier.fillMaxWidth().padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            FloeText(stringResource(R.string.ide_close_title), style = Floe.typography.section, color = colors.label)
            FloeText(
                stringResource(R.string.ide_close_message, request.fileName),
                style = Floe.typography.metadata,
                color = colors.secondaryLabel,
            )
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End)) {
                FloeChipButton(stringResource(R.string.ide_close_cancel), onClick = presenter::dismissCloseRequest)
                FloeChipButton(stringResource(R.string.ide_close_discard), onClick = { presenter.resolveCloseRequest(IdeCloseDecision.DISCARD) })
                FloeChipButton(stringResource(R.string.ide_close_save), emphasized = true, onClick = { presenter.resolveCloseRequest(IdeCloseDecision.SAVE) })
            }
        }
    }

    // Conflict / recovery surface — both versions stay available. Same
    // window-bounded secondary popup as above (device evidence
    // 2026-10-25 c05-cas-save-conflict: the old pane-derived compact=1f
    // sheet spanned the entire 2560x1600 window). The review body keeps its
    // bounded fill + scroll; KeepLocal/KeepBoth/UseRemote/CAS callbacks and
    // styling are byte-identical.
    FloeActionSheet(
        visible = state.conflict != null,
        onDismiss = presenter::dismissConflict,
        maxCardWidth = 640.dp,
    ) {
        state.conflict?.let { IdeConflictContent(presenter, it) }
    }
}

@Composable
private fun EmptyEditorState() {
    val colors = Floe.colors
    Column(
        modifier = Modifier.fillMaxSize().padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        IconGlyph(icon = FloeIdeIcons.DocPage, tint = colors.tertiaryLabel, size = 34.dp)
        Spacer(Modifier.height(10.dp))
        FloeText(
            stringResource(R.string.ide_title_no_document),
            style = Floe.typography.section,
            color = colors.secondaryLabel,
        )
        Spacer(Modifier.height(4.dp))
        FloeText(
            stringResource(R.string.ide_empty_hint),
            style = Floe.typography.metadata,
            color = colors.tertiaryLabel,
            maxLines = 2,
        )
    }
}

@Composable
private fun LoadingEditorState() {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(
            modifier = Modifier.size(24.dp),
            color = Floe.colors.accent,
            strokeWidth = 2.dp,
        )
    }
}

/** Toolbar: back/owner chrome + native-authority command buttons. */
@Composable
private fun IdeCommandBar(
    presenter: IdePresenter,
    state: IdeViewState,
    compact: Boolean,
    onOpenTree: () -> Unit,
    onBack: () -> Unit,
    showTreeButton: Boolean,
) {
    val colors = Floe.colors
    val caps = state.snapshot?.capabilities
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = FloeLayout.ToolbarHeight)
            .padding(horizontal = 8.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        if (showTreeButton) {
            FloeCircleButton(
                icon = FloeIcons.Folder,
                contentDescription = stringResource(R.string.ide_open_tree_cd),
                onClick = onOpenTree,
                visualSize = 34.dp,
                iconSize = 16.dp,
            )
        }
        val backCd = stringResource(R.string.ide_back_cd)
        FloeCircleButton(
            icon = FloeIcons.ChevronBack,
            contentDescription = backCd,
            onClick = onBack,
            visualSize = 34.dp,
            iconSize = 16.dp,
        )
        FloeText(
            text = state.snapshot?.relativePath ?: state.activeDocumentKey?.documentId ?: "",
            style = Floe.typography.toolbarTitle,
            color = colors.label,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier
                .weight(1f, fill = false)
                .padding(horizontal = 6.dp),
        )
        Spacer(Modifier.width(4.dp))
        // Command cluster: leading tree/back + title stay pinned, while the
        // trailing actions are measured inside a viewport-bounded, horizontally
        // scrollable Row. On narrow widths (430dp inspector, compact phone)
        // every command stays reachable by swiping with its original
        // minimum touch target and native-authority callback, instead of being
        // clipped past the right edge; on wide windows the cluster keeps its
        // intrinsic width and no scrollbar ever appears.
        Row(
            modifier = Modifier
                .weight(2f, fill = false)
                .clipToBounds()
                .horizontalScroll(rememberScrollState()),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            val readOnly = state.snapshot?.readOnly == true || !state.inputAdmissionOpen
            if (readOnly) {
                FloeText(
                    stringResource(R.string.ide_status_read_only),
                    style = Floe.typography.metadata,
                    color = colors.secondaryLabel,
                )
                Spacer(Modifier.width(6.dp))
            }
            // Save (native authority), enabled only with real dirty + host save.
            val saveEnabled = !readOnly && caps?.save == true && state.dirtyLocal && !state.saveInFlight
            // Resolved in the composable context, then captured by the callback.
            val saveCd = stringResource(R.string.ide_save_cd)
            Box(
                modifier = Modifier
                    .heightIn(min = FloeLayout.MinimumTarget)
                    .clip(RoundedCornerShape(9.dp))
                    .background(if (saveEnabled || state.saveInFlight) colors.accent.copy(alpha = 0.14f) else colors.chromeSurface)
                    .clickable(enabled = saveEnabled) { presenter.requestSave() }
                    .semantics { contentDescription = saveCd }
                    .padding(horizontal = 12.dp, vertical = 8.dp),
                contentAlignment = Alignment.Center,
            ) {
                if (state.saveInFlight) {
                    CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp, color = colors.accent)
                } else {
                    FloeText(
                        stringResource(R.string.ide_save),
                        style = Floe.typography.bodyEmphasized,
                        color = if (saveEnabled) colors.accent else colors.tertiaryLabel,
                    )
                }
            }
            IconAction(FloeIdeIcons.Undo, stringResource(R.string.ide_undo_cd), enabled = caps?.undo == true && !readOnly) {
                presenter.requestUndo()
            }
            IconAction(FloeIdeIcons.Redo, stringResource(R.string.ide_redo_cd), enabled = caps?.redo == true && !readOnly) {
                presenter.requestRedo()
            }
            IconAction(FloeIcons.Magnifier, stringResource(R.string.ide_find_cd), enabled = caps?.find == true) {
                presenter.showFind(!state.find.open)
            }
            IconAction(FloeIdeIcons.Diff, stringResource(R.string.ide_diff_cd), enabled = caps?.diff == true && state.snapshot != null) {
                if (state.diff != null) presenter.dismissDiff() else presenter.requestLoadDiff()
            }
            if (caps?.run == true) {
                IconAction(FloeIcons.PlayRuns, stringResource(R.string.ide_run_cd), enabled = state.snapshot != null && !state.documentLoading) {
                    presenter.requestRun()
                }
            }
            if (caps?.openPreview == true) {
                IconAction(FloeIcons.Eye, stringResource(R.string.ide_preview_cd)) { presenter.requestOpenPreview() }
            }
            if (caps?.terminal == true) {
                IconAction(
                    FloeIcons.Terminal,
                    stringResource(R.string.ide_terminal_cd),
                    active = state.bottomPaneOpen,
                ) { presenter.toggleBottomPane() }
            }
        }
    }
}

@Composable
private fun IconAction(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    contentDescription: String,
    enabled: Boolean = true,
    active: Boolean = false,
    onClick: () -> Unit,
) {
    val colors = Floe.colors
    Box(
        modifier = Modifier
            .size(FloeLayout.MinimumTarget)
            .clip(RoundedCornerShape(if (active) 12.dp else 9.dp))
            .background(if (active) colors.accent.copy(alpha = 0.14f) else androidx.compose.ui.graphics.Color.Transparent)
            .clickable(enabled = enabled, onClick = onClick)
            .semantics { this.contentDescription = contentDescription },
        contentAlignment = Alignment.Center,
    ) {
        IconGlyph(
            icon = icon,
            tint = when {
                !enabled -> colors.tertiaryLabel
                active -> colors.accent
                else -> colors.label
            },
            size = 20.dp,
        )
    }
}

/** Multi-tab strip mirroring the iOS nativeTab chip: icon, title, dirty dot, close, active underline. */
@Composable
private fun IdeTabBar(
    tabs: List<IdeTabItem>,
    onActivate: (String) -> Unit,
    onClose: (String) -> Unit,
) {
    val colors = Floe.colors
    LazyRow(
        modifier = Modifier
            .fillMaxWidth()
            .background(colors.chromeSurface)
            .semantics { contentDescription = "Editor tabs" },
        contentPadding = PaddingValues(horizontal = 8.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        items(tabs, key = { it.descriptor.documentId }) { tab ->
            TabChip(tab = tab, onActivate = { onActivate(tab.descriptor.documentId) }, onClose = { onClose(tab.descriptor.documentId) })
        }
    }
}

@Composable
private fun TabChip(tab: IdeTabItem, onActivate: () -> Unit, onClose: () -> Unit) {
    val colors = Floe.colors
    val desc = tab.descriptor
    val background = if (tab.active) colors.accent.copy(alpha = 0.14f) else colors.chromeSurface
    Column {
        Row(
            modifier = Modifier
                .heightIn(min = FloeLayout.MinimumTarget)
                .clip(RoundedCornerShape(9.dp))
                .background(background)
                .clickable(onClick = onActivate)
                .padding(start = 10.dp, end = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconGlyph(
                icon = if (desc.languageId != null) FloeIdeIcons.Code else FloeIdeIcons.DocPage,
                tint = if (tab.active) colors.accent else colors.secondaryLabel,
                size = 15.dp,
            )
            Spacer(Modifier.width(6.dp))
            FloeText(
                text = desc.fileName,
                style = Floe.typography.metadata,
                color = if (tab.active) colors.label else colors.secondaryLabel,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.widthIn(max = 160.dp),
            )
            when {
                desc.loading == com.floe.android.feature.ide.api.IdeLoadingState.LOADING -> {
                    Spacer(Modifier.width(6.dp))
                    CircularProgressIndicator(modifier = Modifier.size(11.dp), strokeWidth = 1.5.dp, color = colors.accent)
                }
                desc.loading == com.floe.android.feature.ide.api.IdeLoadingState.FAILED -> {
                    Spacer(Modifier.width(6.dp))
                    IconGlyph(icon = FloeIcons.WarningTriangle, tint = colors.destructive, size = 13.dp)
                }
                desc.dirty || tab.localPending -> {
                    // Native dirty truth (or unconfirmed local chain): the dot.
                    val dirtyCd = stringResource(R.string.ide_tab_dirty_cd)
                    Spacer(Modifier.width(6.dp))
                    Box(
                        Modifier
                            .size(6.dp)
                            .clip(RoundedCornerShape(50))
                            .background(colors.pending)
                            .semantics { contentDescription = dirtyCd },
                    )
                }
            }
            val closeCd = stringResource(R.string.ide_tab_close_cd, desc.fileName)
            Box(
                modifier = Modifier
                    .size(FloeLayout.MinimumTarget)
                    .clickable(onClick = onClose)
                    .semantics { contentDescription = closeCd },
                contentAlignment = Alignment.Center,
            ) {
                IconGlyph(icon = FloeIcons.Xmark, tint = colors.secondaryLabel, size = 13.dp)
            }
        }
        Spacer(Modifier.height(2.dp))
        Box(
            Modifier
                .fillMaxWidth()
                .height(2.dp)
                .background(if (tab.active) colors.accent else androidx.compose.ui.graphics.Color.Transparent),
        )
    }
}

/** Find/replace controls — query semantics run in the host authority. */
@Composable
private fun IdeFindBar(presenter: IdePresenter, state: IdeViewState) {
    val colors = Floe.colors
    val find = state.find
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(colors.chromeSurface)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            FindField(
                value = find.query,
                placeholder = stringResource(R.string.ide_find_label),
                onValueChange = presenter::updateFindQuery,
                modifier = Modifier.weight(1f),
            )
            val hits = find.hitCount
            when {
                find.inFlight -> CircularProgressIndicator(modifier = Modifier.size(15.dp), strokeWidth = 2.dp, color = colors.accent)
                hits != null && hits > 0 -> FloeText(
                    "${find.currentHitIndex + 1}/" + stringResource(R.string.ide_hits_count, hits),
                    style = Floe.typography.metadata,
                    color = colors.secondaryLabel,
                )
                hits == 0 -> FloeText(
                    stringResource(R.string.ide_hits_none),
                    style = Floe.typography.metadata,
                    color = colors.secondaryLabel,
                )
                find.error != null -> FloeText(
                    stringResource(R.string.ide_hits_stale),
                    style = Floe.typography.metadata,
                    color = colors.pending,
                )
            }
            val prevCd = stringResource(R.string.ide_find_previous)
            Box(Modifier.size(FloeLayout.MinimumTarget).clickable(enabled = (find.hitCount ?: 0) > 0) { presenter.findPrevious() }.semantics { contentDescription = prevCd }, contentAlignment = Alignment.Center) {
                IconGlyph(icon = FloeIcons.ChevronUp, tint = if ((find.hitCount ?: 0) > 0) colors.label else colors.tertiaryLabel, size = 16.dp)
            }
            val nextCd = stringResource(R.string.ide_find_next)
            Box(Modifier.size(FloeLayout.MinimumTarget).clickable(enabled = (find.hitCount ?: 0) > 0) { presenter.findNext() }.semantics { contentDescription = nextCd }, contentAlignment = Alignment.Center) {
                IconGlyph(icon = FloeIcons.ChevronDown, tint = if ((find.hitCount ?: 0) > 0) colors.label else colors.tertiaryLabel, size = 16.dp)
            }
            ToggleChip(label = stringResource(R.string.ide_match_case), selected = find.caseSensitive) { presenter.setFindCaseSensitive(!find.caseSensitive) }
            ToggleChip(label = stringResource(R.string.ide_whole_word), selected = find.wholeWord) { presenter.setFindWholeWord(!find.wholeWord) }
            val closeCd = stringResource(R.string.ide_find_close_cd)
            Box(Modifier.size(FloeLayout.MinimumTarget).clickable { presenter.showFind(false) }.semantics { contentDescription = closeCd }, contentAlignment = Alignment.Center) {
                IconGlyph(icon = FloeIcons.Xmark, tint = colors.secondaryLabel, size = 15.dp)
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            FindField(
                value = find.replacement,
                placeholder = stringResource(R.string.ide_replace_label),
                onValueChange = presenter::updateFindReplacement,
                modifier = Modifier.weight(1f),
            )
            val canReplace = find.query.isNotEmpty() && (find.hitCount ?: 0) > 0 &&
                state.snapshot?.capabilities?.replace == true && state.snapshot?.readOnly != true && state.inputAdmissionOpen
            FloeChipButton(stringResource(R.string.ide_replace_one), enabled = canReplace) { presenter.replaceCurrent() }
            FloeChipButton(stringResource(R.string.ide_replace_all), enabled = canReplace) { presenter.replaceAll() }
        }
    }
}

@Composable
private fun FindField(
    value: String,
    placeholder: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = Floe.colors
    Box(
        modifier = modifier
            .heightIn(min = FloeLayout.MinimumTarget)
            .clip(RoundedCornerShape(9.dp))
            .background(colors.fillTertiary)
            .padding(horizontal = 10.dp, vertical = 9.dp),
        contentAlignment = Alignment.CenterStart,
    ) {
        if (value.isEmpty()) {
            FloeText(placeholder, style = Floe.typography.metadata, color = colors.placeholderText, maxLines = 1)
        }
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            singleLine = true,
            textStyle = Floe.typography.metadata.copy(color = colors.label),
            cursorBrush = SolidColor(colors.accent),
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun ToggleChip(label: String, selected: Boolean, onClick: () -> Unit) {
    val colors = Floe.colors
    Box(
        modifier = Modifier
            .heightIn(min = FloeLayout.MinimumTarget)
            .clip(RoundedCornerShape(8.dp))
            .background(if (selected) colors.accent.copy(alpha = 0.14f) else colors.chromeSurface)
            .border(0.5.dp, colors.chromeHairline, RoundedCornerShape(8.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 8.dp, vertical = 4.dp),
        contentAlignment = Alignment.Center,
    ) {
        FloeText(
            label,
            style = Floe.typography.metadata,
            color = if (selected) colors.accent else colors.secondaryLabel,
            maxLines = 1,
        )
    }
}

@Composable
private fun FloeChipButton(
    label: String,
    enabled: Boolean = true,
    emphasized: Boolean = false,
    onClick: () -> Unit,
) {
    val colors = Floe.colors
    Box(
        modifier = Modifier
            .heightIn(min = FloeLayout.MinimumTarget)
            .clip(RoundedCornerShape(9.dp))
            .background(
                when {
                    emphasized && enabled -> colors.accent
                    else -> colors.chromeSurface
                },
            )
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 6.dp),
        contentAlignment = Alignment.Center,
    ) {
        FloeText(
            label,
            style = Floe.typography.bodyEmphasized,
            color = when {
                emphasized && enabled -> androidx.compose.ui.graphics.Color.White
                enabled -> colors.label
                else -> colors.tertiaryLabel
            },
            maxLines = 1,
        )
    }
}

/** Status strip mirroring the iOS statusBar: language, caret, save state, problems. */
@Composable
private fun IdeStatusStrip(state: IdeViewState) {
    val colors = Floe.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 30.dp)
            .background(colors.chromeSurface)
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 12.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        val languageLabel = state.snapshot?.languageId ?: stringResource(R.string.ide_status_plain)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            IconGlyph(icon = FloeIdeIcons.Code, tint = colors.secondaryLabel, size = 13.dp)
            FloeText(languageLabel, style = Floe.typography.metadata, color = colors.secondaryLabel, maxLines = 1)
        }
        FloeText(
            stringResource(R.string.ide_status_line_col, state.caretLine + 1, state.caretColumn + 1),
            style = Floe.typography.metadata,
            color = colors.secondaryLabel,
            maxLines = 1,
        )
        if (state.selectionLengthUtf16 > 0) {
            FloeText(
                stringResource(R.string.ide_status_selection_len, state.selectionLengthUtf16),
                style = Floe.typography.metadata,
                color = colors.secondaryLabel,
                maxLines = 1,
            )
        }
        if (state.diagnostics.isNotEmpty()) {
            FloeText(
                stringResource(R.string.ide_status_problems_cd, state.diagnostics.size),
                style = Floe.typography.metadata,
                color = colors.destructive,
                maxLines = 1,
            )
        }
        if (state.snapshot != null) {
            if (state.hasRejectedEdits) {
                FloeText(stringResource(R.string.ide_status_recovery), style = Floe.typography.metadata, color = colors.pending, maxLines = 1)
            } else if (state.pendingTransactionCount > 0) {
                FloeText(
                    stringResource(R.string.ide_status_pending_n, state.pendingTransactionCount),
                    style = Floe.typography.metadata,
                    color = colors.pending,
                    maxLines = 1,
                )
            } else if (state.dirtyLocal) {
                FloeText(stringResource(R.string.ide_status_unsaved), style = Floe.typography.metadata, color = colors.pending, maxLines = 1)
            } else {
                FloeText(stringResource(R.string.ide_status_saved), style = Floe.typography.metadata, color = colors.secondaryLabel, maxLines = 1)
            }
        }
    }
}

/** Banner after a rejected/stale write: keeps local tail restorable. */
@Composable
private fun SyncBanner(
    message: String,
    canRestore: Boolean,
    onRestore: () -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = Floe.colors
    Row(
        modifier = modifier
            .fillMaxWidth()
            .background(colors.pending.copy(alpha = 0.16f))
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        IconGlyph(icon = FloeIcons.WarningTriangle, tint = colors.pending, size = 16.dp)
        FloeText(
            text = message,
            style = Floe.typography.metadata,
            color = colors.label,
            modifier = Modifier.weight(1f),
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        if (canRestore) {
            FloeChipButton(stringResource(R.string.ide_sync_restore_action), enabled = true) { onRestore() }
        }
        val dismissCd = stringResource(R.string.ide_sync_error_cd)
        Box(
            modifier = Modifier
                .size(FloeLayout.MinimumTarget)
                .clickable(onClick = onDismiss)
                .semantics { contentDescription = dismissCd },
            contentAlignment = Alignment.Center,
        ) {
            IconGlyph(icon = FloeIcons.Xmark, tint = colors.secondaryLabel, size = 14.dp)
        }
    }
}

/** Unified diff fed by the native result; per-line colors like the iOS DiffView. */
@Composable
private fun IdeDiffOverlay(state: IdeViewState, onClose: () -> Unit) {
    val colors = Floe.colors
    val diff = state.diff ?: return
    Column(Modifier.fillMaxSize().background(colors.readingSurface)) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = FloeLayout.ToolbarHeight)
                .background(colors.chromeSurface)
                .padding(horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            FloeText(stringResource(R.string.ide_diff_title), style = Floe.typography.toolbarTitle, color = colors.label)
            Spacer(Modifier.width(10.dp))
            FloeText(
                stringResource(R.string.ide_diff_stats, diff.additions, diff.removals),
                style = Floe.typography.metadata,
                color = colors.secondaryLabel,
            )
            Spacer(Modifier.weight(1f))
            val cd = stringResource(R.string.ide_diff_close_cd)
            Box(Modifier.size(FloeLayout.MinimumTarget).clickable(onClick = onClose).semantics { contentDescription = cd }, contentAlignment = Alignment.Center) {
                IconGlyph(icon = FloeIcons.Xmark, tint = colors.secondaryLabel, size = 15.dp)
            }
        }
        FloeDivider()
        if (diff.error != null) {
            Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
                FloeText(stringResource(R.string.ide_diff_error), style = Floe.typography.metadata, color = colors.secondaryLabel, maxLines = 3)
            }
        } else {
            androidx.compose.foundation.lazy.LazyColumn(Modifier.fillMaxSize()) {
                items(diff.lines) { line ->
                    val tint = when (line.kind) {
                        IdeDiffLineKind.ADDITION -> colors.success
                        IdeDiffLineKind.REMOVAL -> colors.destructive
                        IdeDiffLineKind.HUNK_HEADER -> colors.accent
                        else -> colors.secondaryLabel
                    }
                    val bg = when (line.kind) {
                        IdeDiffLineKind.ADDITION -> colors.success.copy(alpha = 0.12f)
                        IdeDiffLineKind.REMOVAL -> colors.destructive.copy(alpha = 0.12f)
                        IdeDiffLineKind.HUNK_HEADER -> colors.accent.copy(alpha = 0.08f)
                        else -> androidx.compose.ui.graphics.Color.Transparent
                    }
                    val a11y = when (line.kind) {
                        IdeDiffLineKind.ADDITION -> stringResource(R.string.ide_diff_added) + " " + line.text.drop(1)
                        IdeDiffLineKind.REMOVAL -> stringResource(R.string.ide_diff_removed) + " " + line.text.drop(1)
                        else -> line.text
                    }
                    Box(
                        Modifier
                            .fillMaxWidth()
                            .background(bg)
                            .semantics { contentDescription = a11y }
                            .padding(horizontal = 8.dp, vertical = 1.dp),
                    ) {
                        FloeText(
                            text = line.text,
                            style = Floe.typography.evidence,
                            color = tint,
                            maxLines = 1,
                            overflow = TextOverflow.Clip,
                        )
                    }
                }
            }
        }
    }
}

/** Conflict review keeping both available versions, like the iOS TextConflictReviewView. */
@Composable
private fun BoxScope.IdeConflictContent(
    presenter: IdePresenter,
    conflict: com.floe.android.feature.ide.api.IdeConflictPayload,
) {
    val colors = Floe.colors
    var selected by remember { mutableStateOf(0) }
    Column(
        modifier = Modifier.fillMaxSize().padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        FloeText(stringResource(R.string.ide_conflict_title), style = Floe.typography.section, color = colors.label)
        FloeText(stringResource(R.string.ide_conflict_body), style = Floe.typography.metadata, color = colors.secondaryLabel)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            ToggleChip(label = stringResource(R.string.ide_conflict_local), selected = selected == 0) { selected = 0 }
            ToggleChip(label = stringResource(R.string.ide_conflict_remote), selected = selected == 1) { selected = 1 }
        }
        Box(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                .clip(RoundedCornerShape(10.dp))
                .background(colors.groupedSurface)
                .verticalScroll(rememberScrollState())
                .padding(10.dp),
        ) {
            FloeText(
                text = if (selected == 0) conflict.localDraftText else conflict.remoteText,
                style = Floe.typography.evidence,
                color = colors.label,
            )
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End)) {
            FloeChipButton(stringResource(R.string.ide_conflict_cancel)) { presenter.dismissConflict() }
            FloeChipButton(stringResource(R.string.ide_conflict_use_remote)) {
                presenter.resolveConflict(IdeConflictChoice.USE_REMOTE, conflict.remoteText)
            }
            FloeChipButton(stringResource(R.string.ide_conflict_keep_both)) {
                presenter.resolveConflict(IdeConflictChoice.KEEP_BOTH, conflict.localDraftText)
            }
            FloeChipButton(stringResource(R.string.ide_conflict_keep_local), emphasized = true) {
                presenter.resolveConflict(IdeConflictChoice.KEEP_LOCAL, conflict.localDraftText)
            }
        }
    }
}
