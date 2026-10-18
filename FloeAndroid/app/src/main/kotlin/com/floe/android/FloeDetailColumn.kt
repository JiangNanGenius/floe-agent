// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeToolbar
import com.floe.android.design.FloeUnavailableView
import com.floe.android.design.InspectorRoute
import com.floe.android.design.MoreDestination
import com.floe.android.design.SidebarSelection
import com.floe.android.design.WorkbenchSelection

/**
 * Column 2 of the split: renders the selected workbench/more destination.
 * Like iOS `contentColumn`, the detail plane owns its toolbar; the temporary
 * third pane (inspector) lives INSIDE the detail row so the declared two
 * columns stay stable (iOS hit-test rationale, mirrored as structure).
 */
@Composable
fun FloeDetailColumn(
    selection: SidebarSelection,
    showSidebarToggle: Boolean,
    onExpandSidebar: () -> Unit,
    onOpenDrawer: () -> Unit,
    compact: Boolean,
    inspectorRoute: InspectorRoute?,
    onInspectorDismiss: () -> Unit,
    onOpenSettingsSection: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(modifier.fillMaxSize()) {
        when (selection) {
            is SidebarSelection.Workbench -> when (selection.selection) {
                WorkbenchSelection.NEW_TASK -> HomeLaunchpadPage(compact = compact, showSidebarToggle = showSidebarToggle, onExpandSidebar = onExpandSidebar, onOpenDrawer = onOpenDrawer, onOpenSettingsSection = onOpenSettingsSection)
                WorkbenchSelection.OVERVIEW -> FloeTaskCenterPage(showSidebarToggle, onExpandSidebar, onOpenDrawer, compact)
                WorkbenchSelection.CONVERSATION -> FloePlaceholderPage(
                    title = stringResource(R.string.new_task),
                    icon = FloeIcons.Bubble,
                    message = stringResource(R.string.conversation_runtime_pending),
                    showSidebarToggle = showSidebarToggle,
                    onExpandSidebar = onExpandSidebar,
                    onOpenDrawer = onOpenDrawer,
                    compact = compact,
                )
            }
            is SidebarSelection.More -> when (selection.destination) {
                MoreDestination.NOTES -> FloePlaceholderPage(stringResource(R.string.notes), FloeIcons.BookPages, stringResource(R.string.workspace_later_update), showSidebarToggle, onExpandSidebar, onOpenDrawer, compact)
                MoreDestination.CREATIVE -> FloePlaceholderPage(stringResource(R.string.creative), FloeIcons.Creative, stringResource(R.string.workspace_later_update), showSidebarToggle, onExpandSidebar, onOpenDrawer, compact)
                MoreDestination.SKILLS -> FloePlaceholderPage(stringResource(R.string.plugins), FloeIcons.Puzzle, stringResource(R.string.workspace_later_update), showSidebarToggle, onExpandSidebar, onOpenDrawer, compact)
                else -> FloePlaceholderPage(stringResource(R.string.app_name), FloeIcons.InfoCircle, stringResource(R.string.workspace_later_update), showSidebarToggle, onExpandSidebar, onOpenDrawer, compact)
            }
            is SidebarSelection.Workspace -> FloePlaceholderPage(stringResource(R.string.workspaces), FloeIcons.Folder, stringResource(R.string.projects_runtime_pending), showSidebarToggle, onExpandSidebar, onOpenDrawer, compact)
            is SidebarSelection.Conversation -> FloePlaceholderPage(stringResource(R.string.chat), FloeIcons.Bubble, stringResource(R.string.conversation_runtime_pending), showSidebarToggle, onExpandSidebar, onOpenDrawer, compact)
        }
    }
}

@Composable
fun FloeTaskCenterPage(
    showSidebarToggle: Boolean,
    onExpandSidebar: () -> Unit,
    onOpenDrawer: () -> Unit,
    compact: Boolean,
) {
    Column(Modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
        FloeDetailToolbar(
            title = stringResource(R.string.task_center),
            showSidebarToggle = showSidebarToggle,
            onExpandSidebar = onExpandSidebar,
            onOpenDrawer = onOpenDrawer,
            compact = compact,
        )
        FloeUnavailableView(
            icon = FloeIcons.Checklist,
            title = stringResource(R.string.no_tasks_yet),
            description = stringResource(R.string.task_center_empty_note),
        )
    }
}

@Composable
fun FloePlaceholderPage(
    title: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    message: String,
    showSidebarToggle: Boolean,
    onExpandSidebar: () -> Unit,
    onOpenDrawer: () -> Unit,
    compact: Boolean,
) {
    Column(Modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
        FloeDetailToolbar(
            title = title,
            showSidebarToggle = showSidebarToggle,
            onExpandSidebar = onExpandSidebar,
            onOpenDrawer = onOpenDrawer,
            compact = compact,
        )
        FloeUnavailableView(icon = icon, title = title, description = message)
    }
}

/**
 * Detail toolbar: centered title, sidebar affordance leading, actions slot.
 * `compact` is explicit: every compact detail surface (including placeholder
 * and Task Center routes) must pass it so the drawer opener is never omitted
 * (finish review F02).
 */
@Composable
fun FloeDetailToolbar(
    title: String,
    showSidebarToggle: Boolean,
    onExpandSidebar: () -> Unit,
    onOpenDrawer: () -> Unit,
    compact: Boolean,
    actions: (@Composable androidx.compose.foundation.layout.RowScope.() -> Unit)? = null,
) {
    val hasLeading = showSidebarToggle || compact
    FloeToolbar(
        title = title,
        background = Floe.colors.readingSurface,
        navigation = if (hasLeading) {
            {
                if (showSidebarToggle) {
                    FloeCircleButton(
                        icon = FloeIcons.SidebarToggle,
                        contentDescription = stringResource(R.string.expand_task_list),
                        onClick = onExpandSidebar,
                    )
                } else {
                    FloeCircleButton(
                        icon = FloeIcons.SidebarToggle,
                        contentDescription = stringResource(R.string.open_sidebar),
                        onClick = onOpenDrawer,
                    )
                }
            }
        } else null,
        actions = actions,
    )
}
