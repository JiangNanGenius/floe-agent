// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.window.DialogWindowProvider
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.unit.dp
import androidx.core.view.WindowCompat
import com.floe.android.design.Floe
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
 * The library remains mounted behind a full-window document presentation, as
 * in the iOS NotesRootView. The editor covers the App sidebar on every window
 * size. Closing it returns to the same library position; editor sessions and
 * pending saves remain owned by the workspace rather than the dialog.
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
    BoxWithConstraints(
        modifier
            .fillMaxSize()
            .background(Floe.colors.groupedSurface)
            // The shell already owns the status-bar inset. Notes owns its
            // bottom edge: without this the phone page footer (and the last
            // library card) rendered underneath the gesture navigation bar.
            .navigationBarsPadding(),
    ) {
        NotesLibraryPane(
            controller = controller,
            modifiers = Modifier.fillMaxSize(),
            onRequestSidebar = callbacks.onRequestSidebar,
        )
    }

    val active = controller.activeSession
    if (active != null) {
        Dialog(
            onDismissRequest = { controller.goBack() },
            properties = DialogProperties(
                usePlatformDefaultWidth = false,
                decorFitsSystemWindows = false,
                dismissOnClickOutside = false,
            ),
        ) {
            // A Dialog owns a different Window from the App shell. Its edge
            // bars must follow this editor's theme, including live changes.
            val window = (LocalView.current.parent as? DialogWindowProvider)?.window
            val view = LocalView.current
            val lightBars = !Floe.colors.isDark
            SideEffect {
                window?.let {
                    WindowCompat.getInsetsController(it, view).apply {
                        isAppearanceLightStatusBars = lightBars
                        isAppearanceLightNavigationBars = lightBars
                    }
                }
            }
            BackHandler(enabled = controller.canGoBack()) { controller.goBack() }
            BoxWithConstraints(
                Modifier.fillMaxSize()
                    .background(Floe.colors.groupedSurface)
                    .safeDrawingPadding(),
            ) {
                NotesDocumentPane(
                    controller = controller,
                    session = active,
                    wide = maxWidth >= 1_010.dp,
                    compact = maxWidth < 600.dp,
                    callbacks = callbacks,
                    modifiers = Modifier.fillMaxSize(),
                )
            }
        }
    }
}
