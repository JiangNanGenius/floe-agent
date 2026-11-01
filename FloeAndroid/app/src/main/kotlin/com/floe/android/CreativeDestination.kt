// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
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
import com.floe.android.feature.workbench.ui.R as WorkbenchR

/**
 * Existing Creative destination: Canvas (default) + media project library.
 *
 * This is not a new sidebar route; the outer split and fixed route order stay
 * exactly as before. Both libraries open feature-owned full-window editor
 * covers when a project is chosen.
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
    val canvasImagePicker = rememberCanvasImagePicker()
    val mediaImagePicker = rememberMediaFilePicker(CREATIVE_IMAGE_MIME_TYPES)
    val mediaVideoPicker = rememberMediaFilePicker(
        arrayOf("video/mp4", "video/quicktime", "video/x-m4v"),
    )

    Column(Modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
        FloeDetailToolbar(
            title = stringResource(R.string.creative),
            showSidebarToggle = showSidebarToggle,
            onExpandSidebar = onExpandSidebar,
            onOpenDrawer = onOpenDrawer,
            compact = compact,
        )
        if (application == null) {
            FloeUnavailableView(
                icon = FloeIcons.WarningTriangle,
                title = stringResource(CanvasR.string.canvas_unavailable_title),
                description = stringResource(CanvasR.string.canvas_unavailable_body),
            )
            return@Column
        }
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
                )
            } else {
                FloeMediaLibrary(
                    session = CreativeUiHost.mediaLibrarySession(application),
                    pickImage = mediaImagePicker,
                    pickVideo = mediaVideoPicker,
                    modifier = Modifier.fillMaxSize(),
                )
            }
        }
    }
}
