// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeSegmented
import com.floe.android.design.FloeUnavailableView
import com.floe.android.feature.canvas.ui.FloeCanvasLibrary
import com.floe.android.feature.canvas.ui.R as CanvasR
import com.floe.android.feature.workbench.ui.FloeMediaLibrary
import com.floe.android.feature.workbench.ui.r2.WorkbenchMediaPickKind
import com.floe.android.feature.workbench.ui.r2.WorkbenchMediaPicker
import com.floe.android.feature.workbench.ui.state.MediaReturnOpenRequest
import com.floe.android.feature.workbench.ui.state.MediaWorkspaceSession
import com.floe.android.feature.workbench.ui.R as WorkbenchR
import com.floe.android.designintegration.CreativeDesignEntryAction
import com.floe.android.designintegration.DesignExportPickerEffect
import com.floe.android.host.creative.GenerationReturnNavigation
import com.floe.android.mediaintegration.MediaWorkbenchExportPickerEffect

/**
 * Existing Creative destination: Canvas (default) + media project library.
 *
 * This is not a new sidebar route; the outer split and fixed route order stay
 * exactly as before. Both libraries open feature-owned full-window editor
 * covers when a project is chosen.
 *
 * A validated generation-notification return arrives here ONLY after the
 * shell admitted the ordinary Creative route through its existing temporary-
 * chat fence. It selects the existing media tab and asks the current
 * [MediaWorkspaceSession] to open the exact captured project; the feature's
 * unchanged full-window editor cover keeps the iPad/phone presentation.
 */
@Composable
internal fun CreativeDestination(
    showSidebarToggle: Boolean,
    onExpandSidebar: () -> Unit,
    onOpenDrawer: () -> Unit,
    compact: Boolean,
) {
    val application = LocalContext.current.applicationContext as? FloeApplication
    var tab by rememberSaveable { mutableIntStateOf(0) }
    // One-shot, already-fence-admitted generation return. Consumed here only
    // after the App has switched to the existing media tab and handed the
    // exact request to the application-scoped workshop session; rotation or
    // recomposition therefore cannot open a second editor.
    val approvedReturn by GenerationReturnNavigation.approved.collectAsState()
    LaunchedEffect(application, approvedReturn?.requestID) {
        val request = approvedReturn ?: return@LaunchedEffect
        val app = application ?: return@LaunchedEffect
        tab = 1
        val session = CreativeUiHost.mediaLibrarySession(app)
        session.start()
        session.openReturningProject(
            MediaReturnOpenRequest(
                requestID = request.requestID,
                sequence = request.sequence,
                projectID = request.target.projectID,
                expectedEpoch = request.target.epoch,
                storage = request.target.storage,
                origin = request.target.origin,
            ),
        )
        GenerationReturnNavigation.consumeApproved(request.requestID)
    }
    val canvasImagePicker = rememberCanvasImagePicker()
    val mediaImagePicker = rememberMediaFilePicker(CREATIVE_IMAGE_MIME_TYPES)
    val mediaVideoPicker = rememberMediaFilePicker(
        arrayOf("video/mp4", "video/quicktime", "video/x-m4v"),
    )
    val mediaAudioPicker = rememberMediaFilePicker(arrayOf("audio/*"))
    val mediaPicker = remember(mediaVideoPicker, mediaAudioPicker) {
        WorkbenchMediaPicker { kind ->
            when (kind) {
                WorkbenchMediaPickKind.VIDEO -> mediaVideoPicker()
                WorkbenchMediaPickKind.AUDIO -> mediaAudioPicker()
            }
        }
    }

    Column(Modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
        FloeDetailToolbar(
            title = stringResource(R.string.creative),
            showSidebarToggle = showSidebarToggle,
            onExpandSidebar = onExpandSidebar,
            onOpenDrawer = onOpenDrawer,
            compact = compact,
            actions = {
                // Compact native Floe action INSIDE the existing Creative
                // grouping: opens the App-owned creative design panel. It is
                // not a new sidebar/outer route and adds no column.
                application?.let { app ->
                    CreativeDesignEntryAction(controller = app.designUi.creativeEntry)
                }
            },
        )
        if (application == null) {
            FloeUnavailableView(
                icon = FloeIcons.WarningTriangle,
                title = stringResource(CanvasR.string.canvas_unavailable_title),
                description = stringResource(CanvasR.string.canvas_unavailable_body),
            )
            return@Column
        }
        // App-owned verified-receipt Save/Share destination (process-scoped;
        // rotation keeps the pending pick/operation).
        MediaWorkbenchExportPickerEffect(application.mediaWorkbench.pickerDelivery())
        DesignExportPickerEffect(application.designUi.exportDelivery)
        FloeSegmented(
            options = listOf(
                stringResource(WorkbenchR.string.creative_tab_canvas),
                stringResource(WorkbenchR.string.creative_tab_media),
            ),
            selectedIndex = tab,
            onSelect = { tab = it },
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
        )
        Box(Modifier.weight(1f).fillMaxWidth()) {
            if (tab == 0) {
                FloeCanvasLibrary(
                    session = CreativeUiHost.canvasSession(application),
                    pickImage = canvasImagePicker,
                    modifier = Modifier.fillMaxSize(),
                    designSessions = CreativeUiHost.designSessions(application),
                )
            } else {
                FloeMediaLibrary(
                    session = CreativeUiHost.mediaLibrarySession(application),
                    pickImage = mediaImagePicker,
                    pickVideo = mediaVideoPicker,
                    mediaPicker = mediaPicker,
                    modifier = Modifier.fillMaxSize(),
                )
            }
        }
    }
}
