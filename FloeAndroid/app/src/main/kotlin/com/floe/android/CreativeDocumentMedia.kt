// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import android.app.Activity
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeUnavailableView
import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.workbench.ui.FloeMediaProject
import com.floe.android.feature.workbench.ui.R as WorkbenchR
import com.floe.android.host.Owner
import com.floe.android.host.RuntimeHost
import java.util.UUID
import kotlinx.coroutines.CancellationException

/** Image formats the host can measure into a real media project. */
internal fun mediaImageEditSupported(relativePath: String): Boolean {
    val extension = relativePath.substringAfterLast('/').substringAfterLast('.', "")
        .lowercase(java.util.Locale.ROOT)
    return extension in setOf("png", "jpg", "jpeg", "webp", "gif", "bmp")
}

/** R1 media containers: ISO-BMFF only (host measurement supports these). */
internal fun mediaWorkbenchKind(relativePath: String): String? {
    val extension = relativePath.substringAfterLast('/').substringAfterLast('.', "")
        .lowercase(java.util.Locale.ROOT)
    return when (extension) {
        "mp4", "mov", "m4v" -> "video"
        else -> null
    }
}

/**
 * Workspace-file → media project entry used by the existing document surface.
 *
 * The workspace source is streamed through the established verified snapshot
 * egress (the same bounded transport the read-only preview uses), then the
 * atomic App facade creates exactly one project from that staged source. The
 * project uses an explicit app-owned edit copy and carries the REAL workspace
 * origin; the original workspace file is never modified. A stable operation
 * id makes an interrupted creation retry exact.
 */
@Composable
internal fun CreativeDocumentMediaDestination(
    request: WorkspaceDocumentRequest,
    host: RuntimeHost,
    owner: Owner,
    kind: String,
    onBackToFiles: () -> Unit,
) {
    val context = LocalContext.current
    val activity = context as? Activity
    val application = context.applicationContext as? FloeApplication
    if (application == null) {
        LaunchedEffect(Unit) { onBackToFiles() }
        return
    }
    val key = "creative-doc:${request.token}:${owner.nativeEpoch}"
    val session = remember(key) { CreativeUiHost.mediaRouteSession(application, key) }
    val pickImage = rememberMediaFilePicker(CREATIVE_IMAGE_MIME_TYPES)
    var attempt by remember(key) { mutableIntStateOf(0) }
    var stagingFailed by remember(key) { mutableStateOf(false) }
    // Stable across rotation/process restoration for this exact document
    // request: a retried creation is the SAME logical project creation, so an
    // already-committed outcome is replayed instead of publishing a duplicate.
    val opID = remember(key) {
        UUID.nameUUIDFromBytes(
            (
                "floe.g09.document-media|$kind|${request.taskID}|${request.workspaceID}|" +
                    "${request.path}|${request.token}"
                ).toByteArray(Charsets.UTF_8),
        ).toString()
    }
    val projectName = request.fileName.substringBeforeLast('.', request.fileName)
        .ifBlank { request.fileName }
        .take(96)

    LaunchedEffect(key, attempt) {
        if (session.editor != null || session.busy || session.failure != null) {
            return@LaunchedEffect
        }
        session.clearFailure()
        stagingFailed = false
        try {
            val picked = stageWorkspaceMediaSource(
                context = context,
                host = host,
                owner = owner,
                relativePath = request.path,
                kind = kind,
            )
            if (session.isClosed) {
                CreativeDocumentSourceStaging.consume(picked.uri)
                return@LaunchedEffect
            }
            try {
                val accepted = session.importNew(
                    name = projectName,
                    source = picked,
                    kind = kind,
                    storage = CreativeStorageLayer.AppOwned,
                    origin = CreativeOriginContext(
                        kind = CreativeOriginContext.WORKSPACE,
                        ownerID = request.workspaceID,
                    ),
                    editCopy = true,
                    opID = opID,
                )
                if (!accepted) {
                    // The session refused the new editor (closed/replaced);
                    // the staged snapshot was never handed to the import.
                    CreativeDocumentSourceStaging.consume(picked.uri)
                    stagingFailed = true
                }
            } catch (error: Throwable) {
                // The import never took ownership of the staged snapshot.
                CreativeDocumentSourceStaging.consume(picked.uri)
                throw error
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            stagingFailed = true
        }
    }
    DisposableEffect(key) {
        onDispose {
            // Staged-source ownership belongs to the import completion (the
            // App port consumes it in `finally`). Never delete it here: during
            // rotation the retained import may still be reading it. Only a
            // real navigation releases the retained session.
            if (activity?.isChangingConfigurations != true) {
                CreativeUiHost.releaseMediaRoute(key)
            }
        }
    }

    if (stagingFailed) {
        FloeUnavailableView(
            icon = FloeIcons.WarningTriangle,
            title = stringResource(WorkbenchR.string.media_import_failed_title),
            description = stringResource(WorkbenchR.string.media_import_failed_body),
            action = {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                    modifier = Modifier.padding(top = 4.dp),
                ) {
                    FloeCapsuleAction(
                        label = stringResource(WorkbenchR.string.media_retry),
                        onClick = { attempt += 1 },
                    )
                    FloeCapsuleAction(
                        label = stringResource(WorkbenchR.string.media_close),
                        onClick = onBackToFiles,
                        tint = Floe.colors.accent,
                    )
                }
            },
        )
    } else {
        FloeMediaProject(
            session = session,
            pickImage = pickImage,
            onRetry = { attempt += 1 },
            onClose = onBackToFiles,
        )
    }
}
