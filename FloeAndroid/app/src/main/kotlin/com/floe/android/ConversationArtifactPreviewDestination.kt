// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.activity.compose.BackHandler
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeText
import com.floe.android.design.FloeUnavailableView
import com.floe.android.host.ConversationArtifactPreviewRequest
import com.floe.android.host.G04WorkspaceBridgeClient
import com.floe.android.host.G04WorkspaceEditorController
import com.floe.android.host.RuntimeHost
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withContext

/**
 * Root-composition consumer of the conversation artifact direct-preview
 * request (job-ca4547223bea4819). Tapping a conversation artifact link must
 * open the SELECTED file in its existing typed full-window surface — never a
 * folder browse and never a second click (iOS FilePreviewView parity). This
 * composable adds ONLY the conversation-specific seams around the existing
 * [WorkspaceDocumentDestination]:
 *
 *  - owner admission: the request renders only while its exact conversation
 *    entry is live, ordinary (never temporary) and a native root exists; a
 *    retired/deleted/temporary owner dismisses through the destination's own
 *    `requestIsCurrent` gate, and the shell clears the request on any real
 *    navigation, so a late callback can never open in another conversation;
 *  - code workbench: the CODE_EDITOR surface needs the real read/write
 *    [com.floe.android.feature.ide.IdePresenter]; it is acquired from the
 *    Application-owned editor controller under the EXACT task owner fence
 *    (the same acquire discipline the Files pane uses — the workspace was
 *    already proven to exist by the host's bindExisting, so this never
 *    activates anything). Every other surface reuses its existing viewer and
 *    needs no editor binding at all;
 *  - close/back: both return to the conversation that owns the link. The
 *    destination retires the staged preview session itself; nothing here
 *    duplicates an editor, a file tree or a second viewer.
 *
 * No file bytes, path authority or model identity is carried here — only the
 * already-owned task/workspace/path plus the presentation token.
 */
@Composable
internal fun ConversationArtifactPreviewDestination(
    host: RuntimeHost,
    request: ConversationArtifactPreviewRequest,
    onCleared: () -> Unit,
) {
    val context = LocalContext.current.applicationContext
    val entry = host.conversations.entryFor(request.taskID)
    val temporary = entry?.isTemporary != false
    // The destination re-checks this on every recomposition; a retired root,
    // a deleted entry or a temporary session dismisses to the conversation.
    val ownerCurrent: () -> Boolean = {
        host.conversations.entryFor(request.taskID)?.let { current ->
            !current.isTemporary && request.matchesOwner(
                host.nativeRootEpoch(), host.commandClient.generation(), current.sessionEpoch)
        } == true
    }
    if (!ownerCurrent()) {
        LaunchedEffect(request.token) { onCleared() }
        return
    }
    val documentRequest = remember(
        request.token, request.taskID, request.workspaceID, request.relativePath, request.surface,
    ) {
        WorkspaceDocumentRequest(
            taskID = request.taskID,
            workspaceID = request.workspaceID,
            path = request.relativePath,
            surface = request.surface,
            token = request.token,
        )
    }
    // Code workbench binding: only the CODE_EDITOR surface needs it. The
    // view-lifetime flag guards the async acquire exactly like the Files
    // pane's owner; a dismissed/replaced dialog never adopts a late binding.
    val codeViewAlive = remember(request.token) { AtomicBoolean(true) }
    DisposableEffect(request.token) {
        onDispose { codeViewAlive.set(false) }
    }
    var codeBinding by remember(request.token) {
        mutableStateOf<G04WorkspaceEditorController.Binding?>(null)
    }
    var codeFailure by remember(request.token) { mutableStateOf<String?>(null) }
    LaunchedEffect(request.token, request.surface, host) {
        if (request.surface != WorkspaceDocumentSurface.CODE_EDITOR) return@LaunchedEffect
        codeBinding = null
        codeFailure = null
        try {
            val retained = withContext(host.ioDispatcher) {
                host.workspaceEditors.acquire(request.taskID, { code -> artifactErrorText(context, code) }, codeViewAlive)
            }
            if (codeViewAlive.get()) {
                if (retained.isCurrent() && ownerCurrent()) codeBinding = retained
                else onCleared()
            }
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            if (codeViewAlive.get()) {
                codeFailure = artifactErrorText(
                    context, (error as? G04WorkspaceBridgeClient.Failure)?.code ?: "internalError")
            }
        }
    }
    when {
        // The read/write workbench refused admission (owner retired, sessions
        // saturated, ...): an honest typed cover, never a dead editor page.
        request.surface == WorkspaceDocumentSurface.CODE_EDITOR && codeFailure != null ->
            ConversationArtifactPreviewShell(request.fileName, onCleared) {
                FloeUnavailableView(
                    icon = FloeIcons.WarningTriangle,
                    title = stringResource(R.string.workspace_document_type_text),
                    description = codeFailure!!,
                    modifier = Modifier.fillMaxSize(),
                )
            }

        // The workbench binding is still being acquired: a bounded spinner,
        // not a fake document.
        request.surface == WorkspaceDocumentSurface.CODE_EDITOR && codeBinding == null ->
            ConversationArtifactPreviewShell(request.fileName, onCleared) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    FloeActivityIndicator()
                }
            }

        else -> WorkspaceDocumentDestination(
            request = documentRequest,
            host = host,
            presenter = codeBinding?.presenter,
            bottomAccessory = null,
            ownerTaskID = request.taskID,
            ownerWorkspaceID = request.workspaceID,
            ownerCurrent = ownerCurrent(),
            temporary = temporary,
            onBackToFiles = onCleared,
            onCloseTask = onCleared,
            onOpenFolder = null,
        )
    }
}

/** The one opaque full-window shell for the artifact loading/failure covers:
 * same chrome contract as the real destination (Back + file name + Close,
 * scrim/back dismiss), so the conversation always returns to its exact
 * previous surface. */
@Composable
private fun ConversationArtifactPreviewShell(
    fileName: String,
    onCleared: () -> Unit,
    body: @Composable () -> Unit,
) {
    Dialog(
        onDismissRequest = onCleared,
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
            decorFitsSystemWindows = false,
            dismissOnBackPress = true,
            dismissOnClickOutside = false,
        ),
    ) {
        BackHandler(onBack = onCleared)
        Column(
            Modifier
                .fillMaxSize()
                .background(Floe.colors.readingSurface),
        ) {
            WorkspaceDocumentHeader(
                fileName = fileName,
                onBackToFiles = onCleared,
                onCloseTask = onCleared,
            )
            FloeDivider()
            Box(Modifier.fillMaxWidth().weight(1f)) { body() }
        }
    }
}

/** The Files pane's exact error vocabulary, reused so one honest wording
 * exists per refusal family (internal diagnostics stay in details views). */
private fun artifactErrorText(context: android.content.Context, code: String): String =
    context.getString(
        when (code) {
            "staleRevision", "conflict", "dirtyDocument" -> R.string.workspace_conflict_error
            "secretFile", "escapesRoot", "notAdmitted" -> R.string.workspace_access_error
            "contentTooLarge", "bufferLimit" -> R.string.workspace_size_error
            "languageServerUnavailable" -> R.string.workspace_language_unavailable
            "runtimeBusy" -> R.string.workspace_runtime_slot_busy
            "operationPending" -> R.string.workspace_run_pending
            "ownerChanged", "ownerUnavailable", "retired", "epochMismatch",
            "ownerStopping", "workspaceUnbound",
            -> R.string.workspace_owner_error
            else -> R.string.workspace_operation_error
        }
    )

/**
 * The one honest, dismissible note for a conversation artifact tap whose
 * open never started (owner retired, workspace unbound, viewer busy, ...).
 * The conversation surface drops the tap's Boolean result, so without this
 * the refusal was completely silent. Deliberately concise: the actionable
 * fact is "the file did not open; tap it to try again" — refusal families
 * and diagnostics stay in the typed preview/cover states and details views.
 */
@Composable
internal fun ConversationArtifactOpenNotice(
    failure: kotlinx.coroutines.flow.MutableStateFlow<com.floe.android.host.ConversationArtifactOpenFailure?>,
    modifier: Modifier = Modifier,
) {
    val state by failure.collectAsState()
    if (state == null) return
    Row(
        modifier
            .shadow(8.dp, RoundedCornerShape(16.dp))
            .clip(RoundedCornerShape(16.dp))
            .background(Floe.colors.readingSurface)
            .padding(16.dp),
    ) {
        FloeText(
            text = stringResource(R.string.conversation_artifact_open_failed),
            style = Floe.typography.metadata,
            color = Floe.colors.label,
            modifier = Modifier.weight(1f),
        )
        Spacer(Modifier.width(12.dp))
        FloeText(
            text = stringResource(R.string.close),
            style = Floe.typography.bodyEmphasized,
            color = Floe.colors.accent,
            modifier = Modifier
                .clickable(role = Role.Button) { failure.value = null }
                .semantics { contentDescription = "dismiss" },
        )
    }
}
