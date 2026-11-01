// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeText
import com.floe.android.design.FloeUnavailableView
import com.floe.android.feature.workbench.ui.api.MediaPickedSource
import com.floe.android.feature.workbench.ui.state.MediaWorkspaceSession

/**
 * One project editor entry used by the document MEDIA/IMAGE route.
 *
 * The App route owns source staging + session creation; this composable only
 * presents the loading/error surface and the feature's full-window cover. The
 * module never invents a source or a project on its own.
 */
@Composable
fun FloeMediaProject(
    session: MediaWorkspaceSession,
    pickImage: suspend () -> MediaPickedSource?,
    onRetry: () -> Unit,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
    mediaPicker: com.floe.android.feature.workbench.ui.r2.WorkbenchMediaPicker? = null,
) {
    var everOpened by remember(session) { mutableStateOf(false) }
    val editor = session.editor
    LaunchedEffect(editor) {
        if (editor != null) {
            everOpened = true
        } else if (everOpened) {
            onClose()
        }
    }
    if (editor != null) {
        MediaEditorCover(
            session = session,
            editor = editor,
            pickImage = pickImage,
            mediaPicker = mediaPicker,
        )
        return
    }
    Column(
        modifier
            .fillMaxSize()
            .background(Floe.colors.readingSurface),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        val failure = session.failure
        if (failure == null) {
            FloeActivityIndicator()
            FloeText(
                stringResource(R.string.media_busy_loading),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.padding(top = 10.dp),
            )
        } else {
            FloeUnavailableView(
                icon = FloeIcons.WarningTriangle,
                title = stringResource(failure.titleRes()),
                description = stringResource(failure.bodyRes()),
                action = {
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        FloeCapsuleAction(
                            label = stringResource(R.string.media_retry),
                            onClick = {
                                session.clearFailure()
                                onRetry()
                            },
                        )
                        FloeCapsuleAction(
                            label = stringResource(R.string.media_close),
                            onClick = onClose,
                            tint = Floe.colors.accent,
                        )
                    }
                },
            )
        }
    }
}
