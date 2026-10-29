// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeText
import com.floe.android.design.FloeUnavailableView
import com.floe.android.feature.notes.ui.FloeNotesWorkspace
import com.floe.android.feature.notes.ui.api.NotesSettingsTarget
import com.floe.android.feature.notes.ui.api.NotesWorkspaceCallbacks

@Composable
internal fun NotesDestination(
    showSidebarToggle: Boolean,
    onExpandSidebar: () -> Unit,
    onOpenDrawer: () -> Unit,
    compact: Boolean,
    onOpenSettingsSection: (String) -> Unit,
) {
    val app = LocalContext.current.applicationContext as? FloeApplication
    if (app == null) return
    val state by app.notesPlatform.collectAsState()
    LaunchedEffect(app) { app.ensureNotesPlatform() }
    when (val current = state) {
        is NotesPlatformLoadState.Ready -> FloeNotesWorkspace(
            service = app.notesHost.service,
            ports = current.workspace.ports,
            session = current.workspace.session,
            callbacks = NotesWorkspaceCallbacks(
                onRequestSidebar = if (compact) onOpenDrawer else if (showSidebarToggle) onExpandSidebar else null,
                onOpenSettings = { target ->
                    onOpenSettingsSection(if (target == NotesSettingsTarget.MODELS) com.floe.android.design.FloeSettingsSection.PROVIDERS.name else com.floe.android.design.FloeSettingsSection.GENERAL.name)
                },
            ),
        )
        else -> Column(Modifier.fillMaxSize()) {
            FloeDetailToolbar(
                title = stringResource(R.string.notes),
                showSidebarToggle = showSidebarToggle,
                onExpandSidebar = onExpandSidebar,
                onOpenDrawer = onOpenDrawer,
                compact = compact,
            )
            FloeUnavailableView(
                icon = FloeIcons.BookPages,
                title = stringResource(R.string.notes),
                description = stringResource(if (current == NotesPlatformLoadState.Failed)
                    R.string.notes_open_failed else R.string.notes_open_loading),
                action = if (current == NotesPlatformLoadState.Failed) ({
                    FloeText(
                        text = stringResource(R.string.retry),
                        style = Floe.typography.bodyEmphasized,
                        color = Floe.colors.accent,
                        modifier = Modifier.clickable { app.ensureNotesPlatform() }.padding(12.dp),
                    )
                }) else null,
            )
        }
    }
}
