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
 * On an ACTUAL phone window ([windowWidthDp] below the tablet boundary) the
 * surface follows the iOS Inspector file-list-first flow: the list is the
 * root, selecting a text file pushes the editor, editor Back returns to the
 * list, and list Back leaves the workspace. The 430dp tablet pane keeps the
 * existing compact editor root because its window is still a tablet: phone
 * mode is never inferred from the measured child width alone.
 *
 * The App's `WorkspaceFilesPane` may instead intercept a phone selection and
 * present [FloeIdeDocumentWindow] (the iOS `fullScreenCover` equivalent); in
 * that case the list stays this surface's root and the cover returns to it.
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
    windowWidthDp: Float? = null,
    smallestWindowWidthDp: Float? = null,
) {
    val state by presenter.state.collectAsState()
    val colors = Floe.colors
    if (isTemporarySession) {
        BackHandler(onBack = onBack)
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
        val phoneListFirst = IdeWorkspacePresentation.usesPhoneFileList(windowWidthDp, maxWidth.value, smallestWindowWidthDp)
        val wide = maxWidth >= FloeLayout.PersistentTwoColumnMinWidth && !phoneListFirst
        // One handler for the whole surface: on the phone list, Back leaves
        // the workspace; in the phone editor it returns to the list first.
        // Tablet and wide layouts keep their existing dismiss semantics.
        BackHandler {
            // Read the live level, not this composition's captured state: a
            // second Back pressed before recomposition must still leave the
            // workspace instead of replaying "editor -> list".
            if (IdeWorkspacePresentation.backReturnsToTask(
                    phoneListFirst, presenter.state.value.compactLevel)) {
                onBack()
            } else {
                presenter.showCompactFileList()
            }
        }
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
        } else if (phoneListFirst && state.compactLevel == IdeCompactLevel.FILE_LIST) {
            // Phone root: the workspace list itself, exactly like the iOS
            // inspector Files root. Selecting a text file pushes the editor;
            // a document the host routes to its native viewer keeps the list
            // behind that viewer, so dismissing the viewer returns here.
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
                modifier = Modifier.fillMaxSize(),
            )
        } else if (phoneListFirst) {
            // Phone editor level. Back is the editor's own return to the
            // list; the pane Close above this surface returns to the task.
            // The folder control would duplicate that level, so it is absent.
            EditorColumn(
                presenter = presenter,
                state = state,
                compact = true,
                onOpenTree = {},
                onBack = presenter::showCompactFileList,
                showTreeButton = false,
                backContentDescription = R.string.ide_back_to_files_cd,
            )
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
    backContentDescription: Int = R.string.ide_back_cd,
) {
    IdeEditorArea(
        presenter = presenter,
        state = state,
        compact = compact,
        onOpenTree = onOpenTree,
        onBack = onBack,
        showTreeButton = showTreeButton,
        backContentDescription = backContentDescription,
    )
}

/**
 * The explicit full-window document surface — the Android equivalent of the
 * iOS `WorkspaceIDEView` full-screen cover (FileInspectorView.swift L97-107)
 * opened by a document's expand entry. It is the SAME [IdePresenter] editor
 * column the inspector pane hosts: one tab strip, one set of native buffers,
 * one undo lineage and one save path. Only the available size changes.
 *
 * [onClose] returns to the file list that owns the document; it never closes
 * a tab, discards a draft or releases the presenter. The App closes this
 * cover when the owning task/workspace retires.
 */
@Composable
public fun FloeIdeDocumentWindow(
    presenter: IdePresenter,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
    bottomAccessory: IdeBottomAccessory? = null,
    backContentDescription: Int = R.string.ide_close_full_window_cd,
) {
    val state by presenter.state.collectAsState()
    Box(modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
        EditorColumn(
            presenter = presenter,
            state = state,
            compact = true,
            onOpenTree = {},
            onBack = onClose,
            showTreeButton = false,
            backContentDescription = backContentDescription,
        )
        if (bottomAccessory != null && state.bottomPaneOpen) {
            BottomAccessoryOverlay(presenter, bottomAccessory)
        }
    }
}

/** Public expand glyph for the App's explicit full-window entry (the shared
 * design-system icon inventory is owned by Main; this re-exports the feature's
 * own glyph instead of editing it). */
public val FloeIdeExpandGlyph: androidx.compose.ui.graphics.vector.ImageVector
    get() = FloeIdeIcons.Expand

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
