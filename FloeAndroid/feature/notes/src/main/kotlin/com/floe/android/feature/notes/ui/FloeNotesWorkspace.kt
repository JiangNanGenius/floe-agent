// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeUnavailableView
import com.floe.android.feature.notes.NotesService
import com.floe.android.feature.notes.ui.api.NotesHostPorts
import com.floe.android.feature.notes.ui.api.NotesWorkspaceCallbacks
import com.floe.android.feature.notes.ui.state.NotesWorkspaceSession
import com.floe.android.feature.notes.ui.state.createNotesWorkspaceSession
import com.floe.android.feature.notes.ui.ui.NotesDocumentPane
import com.floe.android.feature.notes.ui.ui.NotesLibraryPane

/**
 * Public Notes workspace entry.
 *
 * `service` MUST be the App host's real `NotesService` (the lazily constructed
 * `NotesHostController.service`); this composable never reads Application
 * singletons or constructs a transport. `ports` carries the required
 * media/Office/assistant/exchange adapters plus the REQUIRED durable
 * presentation and recovery stores.
 *
 * On phone widths the library and editor are single-pane with Android Back
 * returning to the library. On tablet widths the library stays visible beside
 * the editor; the assistant appears as a third column when the window can
 * afford it. Document/selection/undo/assistant state is per-session, never a
 * global mutable store.
 */
@Composable
public fun FloeNotesWorkspace(
    service: NotesService,
    ports: NotesHostPorts,
    modifier: Modifier = Modifier,
    session: NotesWorkspaceSession? = null,
    callbacks: NotesWorkspaceCallbacks = NotesWorkspaceCallbacks(),
) {
    val owned = session == null
    val actual = session ?: remember(service, ports) {
        createNotesWorkspaceSession(service, ports)
    }
    val controller = actual.controller

    LaunchedEffect(actual) { actual.start() }
    DisposableEffect(actual) {
        onDispose {
            if (owned) {
                // Never cancel a scope with queued user edits; flush first.
                actual.closeAfterFlush()
            }
        }
    }
    BackHandler(enabled = controller.canGoBack()) { controller.goBack() }

    BoxWithConstraints(
        modifier
            .fillMaxSize()
            .background(Floe.colors.groupedSurface)
            // The shell already owns the status-bar inset. Notes owns its
            // bottom edge: without this the phone page footer (and the last
            // library card) rendered underneath the gesture navigation bar.
            .navigationBarsPadding(),
    ) {
        val compact = maxWidth < 600.dp
        val wideLayout = maxWidth >= 1_010.dp
        val libraryWidth = if (maxWidth < 900.dp) 280.dp else 320.dp
        if (compact) {
            val active = controller.activeSession
            if (active == null) {
                NotesLibraryPane(
                    controller = controller,
                    modifiers = Modifier.fillMaxSize(),
                    onRequestSidebar = callbacks.onRequestSidebar,
                )
            } else {
                NotesDocumentPane(
                    controller = controller,
                    session = active,
                    wide = false,
                    compact = true,
                    callbacks = callbacks,
                    modifiers = Modifier.fillMaxSize(),
                )
            }
        } else {
            Row(Modifier.fillMaxSize()) {
                NotesLibraryPane(
                    controller = controller,
                    modifiers = Modifier.width(libraryWidth).fillMaxHeight(),
                    onRequestSidebar = callbacks.onRequestSidebar,
                )
                Box(Modifier.width(0.5.dp).fillMaxHeight().background(Floe.colors.separator))
                Box(Modifier.weight(1f).fillMaxHeight()) {
                    val active = controller.activeSession
                    if (active == null) {
                        FloeUnavailableView(
                            icon = FloeIcons.BookPages,
                            title = stringResource(R.string.notes_select_note),
                            description = stringResource(R.string.notes_select_note_body),
                        )
                    } else {
                        NotesDocumentPane(
                            controller = controller,
                            session = active,
                            wide = wideLayout,
                            compact = false,
                            callbacks = callbacks,
                            modifiers = Modifier.fillMaxSize(),
                        )
                    }
                }
            }
        }
    }
}
