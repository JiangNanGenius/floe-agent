// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.ide

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActionSheet
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloeUnavailableView
import com.floe.android.design.FloeIcons
import com.floe.android.feature.ide.api.IdeHost
import com.floe.android.feature.ide.ui.IdeEditorArea
import com.floe.android.feature.ide.ui.IdeFileTreePanel
import com.floe.android.feature.ide.ui.FloeIdeIcons

/**
 * An attachable pane slot owned by the App host (terminal renderer / preview /
 * run log are later packages). The IDE module only places the slot; it never
 * fakes content. Null means the bar is absent.
 */
public data class IdeBottomAccessory(
    public val id: String,
    public val label: String,
    public val content: @Composable () -> Unit,
)

/**
 * Creates a presenter bound to [host] for the composition lifetime and fences
 * every late host callback on dispose. Recreate (or let Main recreate) when
 * the owning task/workspace binding changes.
 */
@Composable
public fun rememberIdePresenter(host: IdeHost): IdePresenter {
    val presenter = remember(host, host.bindingGeneration) {
        IdePresenter(host).also { it.start() }
    }
    DisposableEffect(presenter) {
        onDispose { presenter.release() }
    }
    return presenter
}

/**
 * The task-owned IDE surface. Opens from the exact owning ordinary task's
 * workspace files pane; system Back returns to that owner. Wide windows show
 * the split filetree + editor like the iPad; compact windows get a full-screen
 * editor with the tree behind a modal.
 *
 * [isTemporarySession] keeps the temporary-chat file ceiling: no tree, no
 * open, no save — an honest unavailable explanation instead of samples.
 * [onOpenDocument] lets the App route supported binary documents to its
 * owned native viewer before the text editor attempts UTF-8 decoding. True
 * means the host accepted the request, not that rendering has succeeded.
 */
@Composable
public fun FloeIdeWorkspace(
    presenter: IdePresenter,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    bottomAccessory: IdeBottomAccessory? = null,
    isTemporarySession: Boolean = false,
    onOpenDocument: ((String) -> Boolean)? = null,
) {
    val state by presenter.state.collectAsState()
    BackHandler(onBack = onBack)
    val colors = Floe.colors
    if (isTemporarySession) {
        FloeUnavailableView(
            icon = FloeIdeIcons.DocPage,
            title = stringResource(R.string.ide_title_no_document),
            description = stringResource(R.string.ide_temp_session_unavailable),
            modifier = modifier,
        )
        return
    }
    var compactTreeOpen by remember { mutableStateOf(false) }
    BoxWithConstraints(modifier.fillMaxSize().background(colors.readingSurface)) {
        val wide = maxWidth >= FloeLayout.PersistentTwoColumnMinWidth
        if (wide) {
            Row(Modifier.fillMaxSize()) {
                IdeFileTreePanel(
                    state = state.tree,
                    onQuery = presenter::setTreeSearchQuery,
                    onToggle = presenter::toggleTreeExpansion,
                    onOpenFile = { path ->
                        if (onOpenDocument?.invoke(path) != true) presenter.openFile(path)
                    },
                    onOpenHit = { hit ->
                        if (onOpenDocument?.invoke(hit.relativePath) != true) {
                            presenter.openFile(hit.relativePath, com.floe.android.feature.ide.api.IdeOpenReason.SEARCH)
                        }
                    },
                    onRefresh = presenter::refreshTreeKeepingExpansion,
                    modifier = Modifier.width(FloeLayout.SidebarIdealWidth).fillMaxSize(),
                )
                com.floe.android.design.FloeVerticalDivider()
                EditorColumn(presenter, state, compact = false, onOpenTree = {}, onBack = onBack, showTreeButton = false)
            }
        } else {
            EditorColumn(
                presenter = presenter,
                state = state,
                compact = true,
                onOpenTree = { compactTreeOpen = true },
                onBack = onBack,
                showTreeButton = true,
            )
            // Bounded secondary picker (2026-10-25 evidence: the old
            // full-window bottom sheet filled the whole tablet): the tree is
            // clamped to a card on wide windows and keeps the bottom-sheet
            // idiom on compact ones.
            FloeActionSheet(
                visible = compactTreeOpen,
                onDismiss = { compactTreeOpen = false },
                maxCardWidth = 460.dp,
            ) {
                IdeFileTreePanel(
                    state = state.tree,
                    onQuery = presenter::setTreeSearchQuery,
                    onToggle = presenter::toggleTreeExpansion,
                    onOpenFile = { path ->
                        compactTreeOpen = false
                        if (onOpenDocument?.invoke(path) != true) presenter.openFile(path)
                    },
                    onOpenHit = { hit ->
                        compactTreeOpen = false
                        if (onOpenDocument?.invoke(hit.relativePath) != true) {
                            presenter.openFile(hit.relativePath, com.floe.android.feature.ide.api.IdeOpenReason.SEARCH)
                        }
                    },
                    onRefresh = presenter::refreshTreeKeepingExpansion,
                    modifier = Modifier.fillMaxSize(),
                )
            }
        }

        // Attachable host pane (terminal/preview/log) — only present when the
        // App host actually supplies one and the user opened the slot.
        if (bottomAccessory != null && state.bottomPaneOpen) {
            BottomAccessoryOverlay(presenter, bottomAccessory)
        }
    }
}

@Composable
private fun EditorColumn(
    presenter: IdePresenter,
    state: IdeViewState,
    compact: Boolean,
    onOpenTree: () -> Unit,
    onBack: () -> Unit,
    showTreeButton: Boolean,
) {
    IdeEditorArea(
        presenter = presenter,
        state = state,
        compact = compact,
        onOpenTree = onOpenTree,
        onBack = onBack,
        showTreeButton = showTreeButton,
    )
}

/**
 * Bottom-half overlay for the attached host pane. Dismiss returns to the
 * editor. Content itself belongs entirely to the host (later terminal /
 * preview packages); this module provides the slot chrome only.
 */
@Composable
private fun BottomAccessoryOverlay(
    presenter: IdePresenter,
    accessory: IdeBottomAccessory,
) {
    // While the accessory is open, system Back dismisses the PANE first —
    // it never closes the owning editor presentation. (The host-owned
    // session behind the pane survives either way; this only fixes the
    // navigation intent, per the 2026-10-25 wiring review.) Registered
    // deeper than the workspace-root BackHandler, so it wins while shown.
    BackHandler(onBack = { presenter.toggleBottomPane(false) })
    val colors = Floe.colors
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(androidx.compose.ui.graphics.Color.Black.copy(alpha = 0.18f))
            .clickable { presenter.toggleBottomPane(false) },
    ) {
        androidx.compose.foundation.layout.Column(
            modifier = Modifier
                .align(androidx.compose.ui.Alignment.BottomCenter)
                .fillMaxWidth()
                .fillMaxHeight(0.45f)
                .background(colors.chromeSurface)
                // Swallow taps inside the pane; only the scrim dismisses.
                .clickable(enabled = false) { },
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 12.dp, vertical = 4.dp),
                verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
            ) {
                com.floe.android.design.FloeText(
                    accessory.label,
                    style = Floe.typography.metadata,
                    color = colors.secondaryLabel,
                    modifier = Modifier.weight(1f),
                )
                Box(
                    modifier = Modifier
                        .size(FloeLayout.MinimumTarget)
                        .clickable { presenter.toggleBottomPane(false) },
                    contentAlignment = androidx.compose.ui.Alignment.Center,
                ) {
                    com.floe.android.design.IconGlyph(FloeIcons.Xmark, colors.secondaryLabel, 16.dp)
                }
            }
            Box(Modifier.fillMaxSize()) { accessory.content() }
        }
    }
}
