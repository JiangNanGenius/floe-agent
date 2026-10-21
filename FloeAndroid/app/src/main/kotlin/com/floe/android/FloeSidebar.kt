// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeConversationRow
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloeSelectionStyle
import com.floe.android.design.FloeSectionHeader
import com.floe.android.design.FloeSidebarRow
import com.floe.android.design.FloeText
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.MoreDestination
import com.floe.android.design.SidebarSelection
import com.floe.android.design.WorkbenchSelection
import com.floe.android.design.fixedSidebarRoutes

/**
 * Shared sidebar body (persistent column and compact drawer render the same
 * structure, like iOS projects one column into two idioms). Fixed routes in
 * the locked order, then the chat section. Without a runtime host (G01 /
 * preview) the section stays an honest empty and never invents a device
 * history; with the host it renders the REAL produced history rows (the
 * same `conversation.list` wire the Task Center consumes) under the same
 * serial selection path.
 */
@Composable
fun FloeSidebar(
    selection: SidebarSelection,
    onSelect: (SidebarSelection) -> Unit,
    onOpenSettings: () -> Unit,
    onCollapseRequested: (() -> Unit)?,
    modifier: Modifier = Modifier,
    runtimeHost: com.floe.android.host.RuntimeHost? = null,
) {
    val newTaskKey = SidebarSelection.Workbench(WorkbenchSelection.NEW_TASK)
    val overviewKey = SidebarSelection.Workbench(WorkbenchSelection.OVERVIEW)
    Column(
        modifier = modifier
            .fillMaxSize()
            .background(Floe.colors.sidebarSurface),
    ) {
        // Sidebar toolbar: "Floe Agent" centered + round collapse control.
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(FloeLayout.ToolbarHeight),
            contentAlignment = Alignment.Center,
        ) {
            FloeText(
                stringResource(R.string.brand_shell_title),
                style = Floe.typography.toolbarTitle,
            )
            if (onCollapseRequested != null) {
                com.floe.android.design.FloeCircleButton(
                    icon = FloeIcons.SidebarToggle,
                    contentDescription = stringResource(R.string.collapse_task_list),
                    onClick = onCollapseRequested,
                    visualSize = 38.dp,
                    iconSize = 20.dp,
                    modifier = Modifier.align(Alignment.CenterEnd).padding(end = 10.dp),
                )
            }
        }
        Column(
            Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(bottom = 8.dp),
        ) {
            Spacer(Modifier.height(6.dp))
            FloeSidebarRow(
                icon = FloeIcons.NewTask,
                label = stringResource(R.string.new_task),
                selected = selection == newTaskKey,
                onClick = { onSelect(newTaskKey) },
                selectionStyle = FloeSelectionStyle.BLUE,
                modifier = Modifier.padding(horizontal = 12.dp),
            )
            FloeSidebarRow(
                icon = FloeIcons.Checklist,
                label = stringResource(R.string.task_center),
                selected = selection == overviewKey,
                onClick = { onSelect(overviewKey) },
                selectionStyle = FloeSelectionStyle.GRAY,
                modifier = Modifier.padding(horizontal = 12.dp),
            )
            FloeSidebarRow(
                icon = FloeIcons.BookPages,
                label = stringResource(R.string.notes),
                selected = selection == SidebarSelection.More(MoreDestination.NOTES),
                onClick = { onSelect(SidebarSelection.More(MoreDestination.NOTES)) },
                selectionStyle = FloeSelectionStyle.GRAY,
                modifier = Modifier.padding(horizontal = 12.dp),
            )
            FloeSidebarRow(
                icon = FloeIcons.Creative,
                label = stringResource(R.string.creative),
                selected = selection == SidebarSelection.More(MoreDestination.CREATIVE),
                onClick = { onSelect(SidebarSelection.More(MoreDestination.CREATIVE)) },
                selectionStyle = FloeSelectionStyle.GRAY,
                modifier = Modifier.padding(horizontal = 12.dp),
            )
            FloeSidebarRow(
                icon = FloeIcons.Puzzle,
                label = stringResource(R.string.plugins),
                selected = selection == SidebarSelection.More(MoreDestination.SKILLS),
                onClick = { onSelect(SidebarSelection.More(MoreDestination.SKILLS)) },
                selectionStyle = FloeSelectionStyle.GRAY,
                modifier = Modifier.padding(horizontal = 12.dp),
            )

            FloeSectionHeader(stringResource(R.string.workspaces))
            // Truthful empty state. Filled workspace rows are exercised only
            // in the labelled debug preview.
            FloeText(
                stringResource(R.string.no_projects_yet),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.padding(start = 20.dp, end = 16.dp, bottom = 4.dp),
            )

            FloeSectionHeader(stringResource(R.string.chat))
            val historyState = runtimeHost?.conversations?.historyHolder?.state?.value
            val recent = historyState?.items.orEmpty().take(5)
            if (runtimeHost == null || recent.isEmpty()) {
                FloeText(
                    stringResource(R.string.no_conversations_yet),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                    modifier = Modifier.padding(start = 20.dp, end = 16.dp, bottom = 4.dp),
                )
            } else {
                // REAL rows from the produced history wire (same titles and
                // running projection the Task Center list shows); a tap
                // travels the shell's single serial selection reducer.
                recent.forEach { item ->
                    val key = SidebarSelection.Conversation(item.id)
                    FloeConversationRow(
                        title = com.floe.android.feature.conversation.conversationDisplayTitle(
                            item,
                            stringResource(com.floe.android.feature.conversation.R.string.history_untitled),
                        ),
                        selected = selection == key,
                        onClick = { onSelect(key) },
                        modifier = Modifier.padding(horizontal = 12.dp),
                    )
                }
            }
        }

        FloeDivider()
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(horizontal = 16.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            FloeCircleButton(
                icon = FloeIcons.Gearshape,
                contentDescription = stringResource(R.string.settings),
                onClick = onOpenSettings,
                visualSize = 34.dp,
                iconSize = 19.dp,
                background = androidx.compose.ui.graphics.Color.Transparent,
                hairline = false,
                tint = Floe.colors.label,
            )
            Spacer(Modifier.weight(1f))
        }
    }
}

