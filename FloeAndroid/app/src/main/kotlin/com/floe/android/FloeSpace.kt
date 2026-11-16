// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeCapsuleButton
import com.floe.android.design.FloeChoiceChip
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloeSettingsContentDensity
import com.floe.android.design.FloeText
import com.floe.android.design.IconGlyph
import com.floe.android.design.SidebarSelection
import com.floe.android.design.WorkbenchSelection
import com.floe.android.host.ProjectRowUi
import com.floe.android.host.ProjectUiState
import com.floe.android.host.RuntimeHost

/**
 * Android Space: a lightweight hub over the real hosts the App already owns.
 *
 * - Overview, Notes, Files and Toolbox follow the iOS Space section order.
 *   The Android-only Phone workspace sits directly after Overview and is
 *   present only while the REAL G08 phone-access section is wired.
 * - Notes reuses the existing Notes workspace. Files lists real native
 *   project sources and the existing restricted document picker; it is not
 *   a general SAF file manager yet.
 * - Phone hosts the wired section's exact Compose content and authorization
 *   callbacks in the Space content area, with an explicit return row.
 *   Toolbox keeps the existing device-communication (BLE/USB/TCP), system
 *   services, network, remote and settings destinations; communication is
 *   never a substitute for phone control.
 * - No section creates a workspace, task, project or meeting identity. A
 *   project row carries the id the native `project.list` returned.
 * - [onOpenDocument] and [onOpenMeetings] are optional entries owned by
 *   other features. A null callback removes the row entirely; Space never
 *   renders a disabled or fabricated action.
 */
@Composable
internal fun FloeSpaceDestination(
    showSidebarToggle: Boolean,
    onExpandSidebar: () -> Unit,
    onOpenDrawer: () -> Unit,
    compact: Boolean,
    runtimeHost: RuntimeHost?,
    onNavigate: (SidebarSelection) -> Unit,
    onOpenSettingsSection: (String) -> Unit,
    modifier: Modifier = Modifier,
    onOpenDocument: (() -> Unit)? = null,
    /** Supplied only once the parallel meeting service exposes its real
     * entry. Until then the overview omits the row completely. */
    onOpenMeetings: (() -> Unit)? = null,
    /** The REAL wired phone-access settings section. Its exact Compose
     * content and authorization callbacks render as the independent Phone
     * workspace; null removes the section entirely. BLE/USB communication
     * and generic settings never substitute for it. */
    phoneAccessSection: FloeSettingsExternalSection? = null,
) {
    var sectionKey by rememberSaveable {
        mutableStateOf(FloeSpaceSection.OVERVIEW.key)
    }
    val phoneAvailable = phoneAccessSection != null
    val sections = floeSpaceSections(phoneAvailable)
    val restoredSection = FloeSpaceSection.fromKey(sectionKey)
    val section = if (restoredSection in sections) {
        restoredSection
    } else {
        FloeSpaceSection.OVERVIEW
    }
    LaunchedEffect(phoneAvailable, sectionKey) {
        if (FloeSpaceSection.fromKey(sectionKey) !in sections) {
            sectionKey = FloeSpaceSection.OVERVIEW.key
        }
    }
    val projectsState = if (runtimeHost == null) {
        null
    } else {
        val observed by runtimeHost.projects.state.collectAsState()
        observed
    }
    val storeReady = if (runtimeHost == null) {
        false
    } else {
        val observed by runtimeHost.readiness.collectAsState()
        observed.storeReady
    }
    LaunchedEffect(runtimeHost, storeReady) {
        if (storeReady) runtimeHost?.projects?.refresh()
    }
    val defaultProjectName = stringResource(R.string.project_default_name)
    val runtimeUnavailable = projectsState?.errorCode == "runtime_unavailable" || !storeReady
    val canCreateProject = spaceCanCreateProject(
        hasRuntime = runtimeHost != null,
        runtimeUnavailable = runtimeUnavailable,
        busy = projectsState?.busyProjectId != null,
    )

    Column(modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
        FloeSpaceSwitcher(
            section = section,
            sections = sections,
            compact = compact,
            showSidebarToggle = showSidebarToggle,
            onExpandSidebar = onExpandSidebar,
            onOpenDrawer = onOpenDrawer,
            onSelect = { sectionKey = it.key },
        )
        FloeDivider()
        Box(Modifier.weight(1f).fillMaxWidth()) {
            when (section) {
                FloeSpaceSection.OVERVIEW -> FloeSpaceOverview(
                    projectsState = projectsState,
                    onSelectSection = { sectionKey = it.key },
                    onNavigate = onNavigate,
                    onOpenDocument = onOpenDocument,
                    onOpenMeetings = onOpenMeetings,
                    canCreateProject = canCreateProject,
                    onCreateProject = {
                        runtimeHost?.projects?.create(
                            name = defaultProjectName,
                            onCreated = { projectId ->
                                onNavigate(SidebarSelection.Workspace(projectId))
                            },
                        )
                    },
                    onRetryProjects = { runtimeHost?.projects?.refresh() },
                )
                FloeSpaceSection.NOTES -> NotesDestination(
                    // Space owns the leading navigation affordance in its
                    // switcher row, so the embedded Notes workspace must not
                    // draw a second drawer button. The phone editor itself is
                    // still the existing full-screen Notes document dialog.
                    showSidebarToggle = false,
                    onExpandSidebar = onExpandSidebar,
                    onOpenDrawer = onOpenDrawer,
                    compact = false,
                    onOpenSettingsSection = onOpenSettingsSection,
                )
                FloeSpaceSection.FILES -> FloeSpaceFiles(
                    projectsState = projectsState,
                    canCreateProject = canCreateProject,
                    onNavigate = onNavigate,
                    onOpenDocument = onOpenDocument,
                    onCreateProject = {
                        runtimeHost?.projects?.create(
                            name = defaultProjectName,
                            onCreated = { projectId ->
                                onNavigate(SidebarSelection.Workspace(projectId))
                            },
                        )
                    },
                    onRetryProjects = { runtimeHost?.projects?.refresh() },
                )
                FloeSpaceSection.PHONE -> {
                    val wired = phoneAccessSection
                    if (wired != null) {
                        // The REAL wired phone page: its Compose content,
                        // permission callbacks and nested sheets, hosted in
                        // the Space content area. The switcher and the
                        // explicit back row keep the return path to Space.
                        FloeSpacePhone(
                            section = wired,
                            compact = compact,
                            onBack = {
                                sectionKey = FloeSpaceSection.OVERVIEW.key
                            },
                        )
                    }
                }
                FloeSpaceSection.TOOLBOX -> FloeSpaceToolbox(
                    onNavigate = onNavigate,
                )
            }
        }
    }
}

@Composable
private fun FloeSpaceSwitcher(
    section: FloeSpaceSection,
    sections: List<FloeSpaceSection>,
    compact: Boolean,
    showSidebarToggle: Boolean,
    onExpandSidebar: () -> Unit,
    onOpenDrawer: () -> Unit,
    onSelect: (FloeSpaceSection) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(FloeLayout.ToolbarHeight)
            .padding(horizontal = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        when {
            showSidebarToggle -> FloeCircleButton(
                FloeIcons.SidebarToggle,
                stringResource(R.string.expand_task_list),
                onExpandSidebar,
            )
            compact -> FloeCircleButton(
                FloeIcons.SidebarToggle,
                stringResource(R.string.open_sidebar),
                onOpenDrawer,
            )
            else -> FloeText(
                stringResource(R.string.space_title),
                style = Floe.typography.toolbarTitle,
                modifier = Modifier.padding(start = 8.dp),
            )
        }
        Spacer(Modifier.width(8.dp))
        Row(
            modifier = Modifier
                .weight(1f)
                .horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            sections.forEach { entry ->
                FloeChoiceChip(
                    label = spaceSectionLabel(entry),
                    selected = entry == section,
                    onClick = { onSelect(entry) },
                )
            }
        }
    }
}

@Composable
private fun FloeSpaceOverview(
    projectsState: ProjectUiState?,
    onSelectSection: (FloeSpaceSection) -> Unit,
    onNavigate: (SidebarSelection) -> Unit,
    onOpenDocument: (() -> Unit)?,
    onOpenMeetings: (() -> Unit)?,
    canCreateProject: Boolean,
    onCreateProject: () -> Unit,
    onRetryProjects: () -> Unit,
) {
    val entries = mutableListOf<SpaceEntry>()
    entries += SpaceEntry(
        icon = FloeIcons.BookPages,
        title = stringResource(R.string.space_section_notes),
        caption = stringResource(R.string.space_notes_caption),
        onClick = { onSelectSection(FloeSpaceSection.NOTES) },
    )
    entries += SpaceEntry(
        icon = FloeIcons.Folder,
        title = stringResource(R.string.space_section_files),
        caption = stringResource(R.string.space_files_caption),
        onClick = { onSelectSection(FloeSpaceSection.FILES) },
    )
    entries += SpaceEntry(
        icon = FloeIcons.Chip,
        title = stringResource(R.string.space_section_toolbox),
        caption = stringResource(R.string.space_toolbox_caption),
        onClick = { onSelectSection(FloeSpaceSection.TOOLBOX) },
    )
    entries += SpaceEntry(
        icon = FloeIcons.NewTask,
        title = stringResource(R.string.new_task),
        caption = stringResource(R.string.space_new_task_caption),
        onClick = {
            onNavigate(SidebarSelection.Workbench(WorkbenchSelection.NEW_TASK))
        },
    )
    if (spaceOptionalEntryVisible(onOpenDocument)) {
        entries += SpaceEntry(
            icon = FloeIcons.Document,
            title = stringResource(R.string.space_pick_document),
            caption = stringResource(R.string.space_pick_document_caption),
            onClick = { onOpenDocument?.invoke() },
        )
    }
    if (spaceOptionalEntryVisible(onOpenMeetings)) {
        entries += SpaceEntry(
            icon = FloeIcons.Bubble,
            title = stringResource(R.string.space_meetings),
            caption = stringResource(R.string.space_meetings_caption),
            onClick = { onOpenMeetings?.invoke() },
        )
    }

    SpaceScrollPage {
        FloeText(
            stringResource(R.string.space_subtitle),
            style = Floe.typography.body,
            color = Floe.colors.secondaryLabel,
        )
        SpaceGroupTitle(stringResource(R.string.space_quick_access))
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            val columns = if (maxWidth >= 720.dp) 2 else 1
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                entries.chunked(columns).forEach { rowEntries ->
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        rowEntries.forEach { entry ->
                            Box(Modifier.weight(1f)) {
                                SpaceActionCard(
                                    icon = entry.icon,
                                    title = entry.title,
                                    caption = entry.caption,
                                    onClick = entry.onClick,
                                )
                            }
                        }
                        if (rowEntries.size < columns) Spacer(Modifier.weight(1f))
                    }
                }
            }
        }
        SpaceGroupTitle(stringResource(R.string.projects))
        SpaceProjectSummary(
            projectsState = projectsState,
            canCreateProject = canCreateProject,
            onCreateProject = onCreateProject,
            onRetryProjects = onRetryProjects,
            onShowAll = { onSelectSection(FloeSpaceSection.FILES) },
            onOpenProject = { projectId ->
                onNavigate(SidebarSelection.Workspace(projectId))
            },
        )
    }
}

@Composable
private fun FloeSpaceFiles(
    projectsState: ProjectUiState?,
    canCreateProject: Boolean,
    onNavigate: (SidebarSelection) -> Unit,
    onOpenDocument: (() -> Unit)?,
    onCreateProject: () -> Unit,
    onRetryProjects: () -> Unit,
) {
    SpaceScrollPage {
        SpaceGroupTitle(
            stringResource(R.string.space_project_sources),
            stringResource(R.string.space_project_sources_caption),
        )
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            FloeCapsuleButton(
                label = stringResource(R.string.project_new),
                onClick = onCreateProject,
                enabled = canCreateProject,
                prominent = true,
                modifier = Modifier.weight(1f),
            )
            if (spaceOptionalEntryVisible(onOpenDocument)) {
                FloeCapsuleButton(
                    label = stringResource(R.string.space_pick_document),
                    onClick = { onOpenDocument?.invoke() },
                    modifier = Modifier.weight(1f),
                )
            }
        }
        if (spaceOptionalEntryVisible(onOpenDocument)) {
            FloeText(
                stringResource(R.string.space_pick_document_caption),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
        }
        SpaceProjects(
            projectsState = projectsState,
            canCreateProject = canCreateProject,
            onCreateProject = onCreateProject,
            onRetryProjects = onRetryProjects,
            onOpenProject = { projectId ->
                onNavigate(SidebarSelection.Workspace(projectId))
            },
        )
    }
}

@Composable
private fun FloeSpaceToolbox(
    onNavigate: (SidebarSelection) -> Unit,
) {
    SpaceScrollPage {
        SpaceGroupTitle(stringResource(R.string.space_device_tools))
        FloeSpaceToolboxTarget.entries.forEach { target ->
            val copy = toolboxCopy(target)
            SpaceActionCard(
                icon = copy.icon,
                title = copy.title,
                caption = copy.caption,
                onClick = { onNavigate(target.selection) },
            )
        }
    }
}

@Composable
private fun SpaceProjectSummary(
    projectsState: ProjectUiState?,
    canCreateProject: Boolean,
    onCreateProject: () -> Unit,
    onRetryProjects: () -> Unit,
    onShowAll: () -> Unit,
    onOpenProject: (String) -> Unit,
) {
    when {
        projectsState == null -> SpaceUnavailableProjectLine()
        projectsState.loading && projectsState.projects.isEmpty() -> FloeText(
            stringResource(R.string.space_projects_loading),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
        projectsState.errorCode != null && projectsState.projects.isEmpty() -> Column(
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            SpaceUnavailableProjectLine()
            SpaceTextAction(stringResource(R.string.retry), onRetryProjects)
        }
        projectsState.projects.isEmpty() -> Column(
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            FloeText(
                stringResource(R.string.space_no_projects_title),
                style = Floe.typography.bodyEmphasized,
            )
            FloeText(
                stringResource(R.string.space_no_projects_description),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
            FloeCapsuleButton(
                label = stringResource(R.string.project_new),
                onClick = onCreateProject,
                enabled = canCreateProject,
            )
        }
        else -> Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            projectsState.projects.take(3).forEach { project ->
                SpaceProjectRow(project = project) { onOpenProject(project.id) }
            }
            if (projectsState.projects.size > 3) {
                SpaceTextAction(
                    stringResource(R.string.space_show_all_projects),
                    onShowAll,
                )
            }
        }
    }
}

@Composable
private fun SpaceProjects(
    projectsState: ProjectUiState?,
    canCreateProject: Boolean,
    onCreateProject: () -> Unit,
    onRetryProjects: () -> Unit,
    onOpenProject: (String) -> Unit,
) {
    when {
        projectsState == null -> SpaceUnavailableProjectLine()
        projectsState.loading && projectsState.projects.isEmpty() -> FloeText(
            stringResource(R.string.space_projects_loading),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
        projectsState.errorCode != null && projectsState.projects.isEmpty() -> Column(
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            SpaceUnavailableProjectLine()
            SpaceTextAction(stringResource(R.string.retry), onRetryProjects)
        }
        projectsState.projects.isEmpty() -> Column(
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            FloeText(
                stringResource(R.string.space_no_projects_title),
                style = Floe.typography.bodyEmphasized,
            )
            FloeText(
                stringResource(R.string.space_no_projects_description),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
            if (!canCreateProject) {
                FloeText(
                    stringResource(R.string.space_projects_unavailable),
                    style = Floe.typography.metadata,
                    color = Floe.colors.destructive,
                )
            }
        }
        else -> Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            projectsState.projects.forEach { project ->
                SpaceProjectRow(project = project) { onOpenProject(project.id) }
            }
        }
    }
}

@Composable
private fun SpaceProjectRow(project: ProjectRowUi, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 56.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(Floe.colors.fillTertiary)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconGlyph(FloeIcons.Folder, Floe.colors.accent, 20.dp)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            FloeText(project.name, style = Floe.typography.body)
            FloeText(
                stringResource(R.string.project_task_count, project.taskCount),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
        }
        IconGlyph(FloeIcons.ChevronForward, Floe.colors.tertiaryLabel, 14.dp)
    }
}

@Composable
private fun SpaceActionCard(
    icon: ImageVector,
    title: String,
    caption: String,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 64.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(Floe.colors.fillTertiary)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(36.dp)
                .clip(CircleShape)
                .background(Floe.colors.accentFillFaint),
            contentAlignment = Alignment.Center,
        ) {
            IconGlyph(icon, Floe.colors.accent, 19.dp)
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            FloeText(title, style = Floe.typography.bodyEmphasized)
            FloeText(
                caption,
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
        }
        Spacer(Modifier.width(8.dp))
        IconGlyph(FloeIcons.ChevronForward, Floe.colors.tertiaryLabel, 14.dp)
    }
}

/**
 * The wired phone workspace. Its content is the exact Compose the Settings
 * sheet mounts for `x:phone_access`, so grants, pairing, permission
 * launchers and nested confirmations keep their existing host and lifecycle.
 * The page owns no Space identity; the row above is the explicit return to
 * the Space overview and the section switcher stays visible.
 */
@Composable
private fun FloeSpacePhone(
    section: FloeSettingsExternalSection,
    compact: Boolean,
    onBack: () -> Unit,
) {
    Column(
        Modifier
            .fillMaxSize()
            .background(Floe.colors.groupedSurface),
    ) {
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
            Column(
                Modifier
                    .widthIn(max = 860.dp)
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = FloeLayout.MinimumTarget)
                        .clickable(role = Role.Button, onClick = onBack)
                        .padding(vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    IconGlyph(FloeIcons.ChevronBack, Floe.colors.accent, 16.dp)
                    Spacer(Modifier.width(6.dp))
                    FloeText(
                        stringResource(R.string.space_title),
                        style = Floe.typography.bodyEmphasized,
                        color = Floe.colors.accent,
                    )
                }
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    IconGlyph(FloeIcons.DeviceLocal, Floe.colors.accent, 22.dp)
                    FloeText(
                        stringResource(R.string.space_phone),
                        style = Floe.typography.title,
                    )
                }
                FloeText(
                    stringResource(R.string.space_phone_caption),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
        }
        FloeDivider()
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
                .imePadding()
                .navigationBarsPadding()
                .verticalScroll(rememberScrollState()),
        ) {
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
                Column(Modifier.widthIn(max = 860.dp).fillMaxWidth()) {
                    Spacer(Modifier.height(8.dp))
                    FloeSettingsContentDensity(compact = compact) {
                        section.content()
                    }
                    Spacer(Modifier.height(16.dp))
                }
            }
        }
    }
}

@Composable
private fun SpaceGroupTitle(title: String, caption: String? = null) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        FloeText(title, style = Floe.typography.section)
        if (caption != null) {
            FloeText(
                caption,
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
        }
    }
}

@Composable
private fun SpaceUnavailableProjectLine() {
    FloeText(
        stringResource(R.string.space_projects_unavailable),
        style = Floe.typography.metadata,
        color = Floe.colors.secondaryLabel,
    )
}

@Composable
private fun SpaceTextAction(label: String, onClick: () -> Unit) {
    FloeText(
        label,
        style = Floe.typography.bodyEmphasized,
        color = Floe.colors.accent,
        modifier = Modifier
            .heightIn(min = FloeLayout.MinimumTarget)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(vertical = 12.dp),
    )
}

@Composable
private fun SpaceScrollPage(content: @Composable ColumnScope.() -> Unit) {
    Box(Modifier.fillMaxSize()) {
        Column(
            modifier = Modifier
                .align(Alignment.TopCenter)
                .widthIn(max = 860.dp)
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
            content = content,
        )
    }
}

private class SpaceEntry(
    val icon: ImageVector,
    val title: String,
    val caption: String,
    val onClick: () -> Unit,
)

private class SpaceToolboxCopy(
    val icon: ImageVector,
    val title: String,
    val caption: String,
)

@Composable
private fun toolboxCopy(target: FloeSpaceToolboxTarget): SpaceToolboxCopy = when (target) {
    FloeSpaceToolboxTarget.DEVICES -> SpaceToolboxCopy(
        icon = FloeIcons.Antenna,
        title = stringResource(R.string.space_tool_devices),
        caption = stringResource(R.string.space_tool_devices_caption),
    )
    FloeSpaceToolboxTarget.SYSTEM_SERVICES -> SpaceToolboxCopy(
        icon = FloeIcons.ShieldCheck,
        title = stringResource(R.string.space_tool_system_services),
        caption = stringResource(R.string.space_tool_system_services_caption),
    )
    FloeSpaceToolboxTarget.NETWORK -> SpaceToolboxCopy(
        icon = FloeIcons.Gauge,
        title = stringResource(R.string.space_tool_network),
        caption = stringResource(R.string.space_tool_network_caption),
    )
    FloeSpaceToolboxTarget.REMOTE -> SpaceToolboxCopy(
        icon = FloeIcons.Terminal,
        title = stringResource(R.string.space_tool_remote),
        caption = stringResource(R.string.space_tool_remote_caption),
    )
}

@Composable
private fun spaceSectionLabel(section: FloeSpaceSection): String = when (section) {
    FloeSpaceSection.OVERVIEW -> stringResource(R.string.space_section_overview)
    FloeSpaceSection.NOTES -> stringResource(R.string.space_section_notes)
    FloeSpaceSection.FILES -> stringResource(R.string.space_section_files)
    FloeSpaceSection.TOOLBOX -> stringResource(R.string.space_section_toolbox)
    FloeSpaceSection.PHONE -> stringResource(R.string.space_phone)
}
