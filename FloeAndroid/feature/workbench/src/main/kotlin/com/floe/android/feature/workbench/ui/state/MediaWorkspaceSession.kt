// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui.state

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.floe.android.feature.canvas.CreativeAvailability
import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeSessionTokens
import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.workbench.MediaProjectEnvelope
import com.floe.android.feature.workbench.MediaProjectSummary
import com.floe.android.feature.workbench.WorkbenchHostApi
import com.floe.android.feature.workbench.ui.api.MediaAgentBindingFailure
import com.floe.android.feature.workbench.ui.api.MediaAgentBindingPort
import com.floe.android.feature.workbench.ui.api.MediaAgentOwnerContext
import com.floe.android.feature.workbench.ui.api.MediaAgentTaskRequest
import com.floe.android.feature.workbench.ui.api.MediaEditorPorts
import com.floe.android.feature.workbench.ui.api.MediaPickedSource
import com.floe.android.feature.workbench.ui.presentation.MediaFailure
import com.floe.android.feature.workbench.ui.presentation.MediaFailureKind
import com.floe.android.feature.workbench.ui.presentation.MediaFailures
import com.floe.android.feature.workbench.ui.r2.MediaExportCoordinator
import com.floe.android.feature.workbench.ui.r2.WorkbenchR2Ports
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * One notification-return open. [storage]/[origin] are the EXACT explicit
 * values captured from the accepted generation project context; [expectedEpoch]
 * is the native bound epoch the notification was resolved against.
 *
 * This is intentionally not a [MediaProjectSummary]: a stale list row must
 * never select the project/revision that opens.
 */
data class MediaReturnOpenRequest(
    val requestID: String,
    val sequence: Long,
    val projectID: String,
    val expectedEpoch: Long,
    val storage: CreativeStorageLayer,
    val origin: CreativeOriginContext?,
)

enum class MediaReturnOpenDisposition {
    DISPATCHED,
    FOCUSED,
    DUPLICATE,
    STALE,
    REFUSED,
}

enum class MediaReturnEditorAction {
    OPEN_NEW,
    FOCUS_EXISTING,
    REOPEN_AFTER_RETIRE,
}

/**
 * Existing-editor handoff policy for a validated return request. The SAME
 * project with the SAME explicit storage/origin focuses the live session (no
 * duplicate token/editor); anything else must retire the existing editor
 * through its real close lifecycle before installing the returned project.
 */
fun mediaReturnEditorAction(
    existingProjectID: String?,
    existingStorage: CreativeStorageLayer?,
    existingOrigin: CreativeOriginContext?,
    request: MediaReturnOpenRequest,
): MediaReturnEditorAction = when {
    existingProjectID == null -> MediaReturnEditorAction.OPEN_NEW
    existingProjectID == request.projectID &&
        existingStorage == request.storage &&
        existingOrigin == request.origin -> MediaReturnEditorAction.FOCUS_EXISTING
    else -> MediaReturnEditorAction.REOPEN_AFTER_RETIRE
}

fun mediaReturnRequestIsValid(request: MediaReturnOpenRequest): Boolean =
    request.requestID.isNotBlank() && request.requestID.length <= 128 &&
        request.sequence > 0L &&
        request.projectID.isNotBlank() && request.projectID.length <= 128 &&
        request.expectedEpoch > 0L

/**
 * Retained media project library + editor session.
 *
 * Created outside composition by the App owner. Rotation/background reuses the
 * same object, the exact editor token and the loaded envelope. An actual close
 * retires only `closeWorkbenchEditor(projectID, sessionToken)`; no global
 * shutdown is exposed to the UI.
 */
@Stable
class MediaWorkspaceSession(
    private val host: WorkbenchHostApi,
    val ports: MediaEditorPorts,
    scope: CoroutineScope? = null,
    private val newToken: () -> String = CreativeSessionTokens::newToken,
    private val newOperationID: () -> String = { UUID.randomUUID().toString() },
    val r2Ports: WorkbenchR2Ports? = null,
    private val agentBinding: MediaAgentBindingPort? = null,
    /** Real task/workspace this route was opened from; null in the library. */
    val agentOwner: MediaAgentOwnerContext? = null,
) {
    private val ownsScope = scope == null
    private val scope: CoroutineScope =
        scope ?: CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    /**
     * Session-scoped export tracker. It survives editor close so a service
     * export keeps its captured immutable binding and releases that lease only
     * after a true terminal state.
     */
    private val exportCoordinator: MediaExportCoordinator? = r2Ports?.let { portsValue ->
        MediaExportCoordinator(
            platform = portsValue.platform,
            recoveredExports = portsValue.recoveredExports,
            releaseBinding = portsValue.releaseRenderBinding,
            scope = this.scope,
        )
    }

    private val libraryMutex = Mutex()
    @Volatile private var importJob: Job? = null
    @Volatile private var agentJob: Job? = null
    private var started = false
    @Volatile private var closed = false

    // Notification-return ordering. A newer return request always wins; an
    // older dispatched open that finishes late closes its own token and never
    // installs over the newer request/editor.
    private val returnGuard = Any()
    @Volatile private var latestReturnSequence = 0L
    @Volatile private var pendingReturnRequestID: String? = null
    @Volatile private var handledReturnRequestID: String? = null

    var availability: CreativeAvailability? by mutableStateOf(null)
        private set
    var loading by mutableStateOf(true)
        private set
    var refreshing by mutableStateOf(false)
        private set
    var projects by mutableStateOf<List<MediaProjectSummary>>(emptyList())
        private set
    var failure: MediaFailure? by mutableStateOf(null)
        private set
    var busy by mutableStateOf(false)
        private set
    var editor: MediaEditorController? by mutableStateOf(null)
        private set

    /**
     * Explicit Ask AI state. The task creation/binding runs in the App-owned
     * port; this session only carries the request and the bounded result.
     */
    var agentBusy by mutableStateOf(false)
        private set
    var agentFailure by mutableStateOf<String?>(null)
        private set
    var agentTaskID by mutableStateOf<String?>(null)
        private set

    val agentAvailable: Boolean get() = agentBinding != null

    val showAvailabilityState: Boolean
        get() = availability != null && availability != CreativeAvailability.Available
    val isClosed: Boolean get() = closed

    /** True when this session was created with the required R2 ports. */
    val r2Available: Boolean get() = r2Ports != null

    fun start() {
        if (started || closed) return
        started = true
        refresh(initial = true)
    }

    fun refresh(initial: Boolean = false) {
        if (closed) return
        scope.launch {
            libraryMutex.withLock {
                if (closed) return@withLock
                if (initial) loading = true else refreshing = true
                failure = null
                try {
                    val status = host.status()
                    if (closed) return@withLock
                    availability = status.availability
                    if (status.availability == CreativeAvailability.Available) {
                        projects = host.mediaLibrary()
                    } else {
                        projects = emptyList()
                    }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    val mapped = MediaFailures.from(error)
                    failure = mapped
                    availability = mapped.availability ?: CreativeAvailability.Unavailable
                } finally {
                    loading = false
                    refreshing = false
                }
            }
        }
    }

    fun clearFailure() {
        failure = null
    }

    fun refreshQuietly() {
        if (closed) return
        scope.launch {
            libraryMutex.withLock {
                if (closed) return@withLock
                runCatching {
                    availability = host.status().availability
                    if (availability == CreativeAvailability.Available) {
                        projects = host.mediaLibrary()
                    }
                }
            }
        }
    }

    fun open(
        summary: MediaProjectSummary,
        origin: CreativeOriginContext? = null,
        storage: CreativeStorageLayer? = null,
        editCopy: Boolean = false,
    ) {
        if (closed || busy || editor != null) return
        if (summary.corrupt) {
            failure = MediaFailure(MediaFailureKind.CORRUPT, "corruptProject")
            return
        }
        if (storage == null && summary.ownerKind != "standalone") {
            // Origin-owned records must name an explicit storage layer chosen
            // by the user; never let the native nil-storage default infer it.
            failure = MediaFailure(MediaFailureKind.ORIGIN_REQUIRED, "storageLayerRequired")
            return
        }
        scope.launch {
            libraryMutex.withLock {
                if (closed) return@withLock
                busy = true
                failure = null
                val token = newToken()
                try {
                    // Storage and origin are EXPLICIT user choices from the
                    // library sheet (or the document route). Never probe a
                    // second root or infer one from the recorded project.
                    val envelope = host.open(summary.id, token, storage, origin)
                    if (closed) {
                        runCatching { host.closeWorkbenchEditor(summary.id, token) }
                        return@withLock
                    }
                    installEditor(
                        envelope, token, origin, storage ?: envelope.storage, editCopy)
                } catch (cancelled: CancellationException) {
                    runCatching { host.closeWorkbenchEditor(summary.id, token) }
                    throw cancelled
                } catch (error: Throwable) {
                    runCatching { host.closeWorkbenchEditor(summary.id, token) }
                    failure = MediaFailures.from(error)
                } finally {
                    busy = false
                }
            }
        }
    }

    /**
     * App-authorized notification return open.
     *
     * The App already proved the opaque live claim, exact captured
     * storage/origin and native bound epoch. This method:
     *  * opens the project DIRECTLY by id (never by the first/stale summary);
     *  * focuses the same already-visible project instead of duplicating it;
     *  * retires a different existing editor through the real close lifecycle;
     *  * serializes with every other library/open mutation and refuses to
     *    install an older request over a newer one;
     *  * reports the missing/deleted project through the ordinary
     *    [MediaFailure] state instead of claiming success.
     *
     * The actual open runs in the session's application-owned scope, so
     * rotation/composition disposal cannot cancel a real open halfway.
     */
    fun openReturningProject(request: MediaReturnOpenRequest): MediaReturnOpenDisposition {
        if (closed) return MediaReturnOpenDisposition.REFUSED
        if (!mediaReturnRequestIsValid(request)) return MediaReturnOpenDisposition.REFUSED
        synchronized(returnGuard) {
            if (request.requestID == pendingReturnRequestID ||
                request.requestID == handledReturnRequestID
            ) {
                return MediaReturnOpenDisposition.DUPLICATE
            }
            if (request.sequence < latestReturnSequence) {
                return MediaReturnOpenDisposition.STALE
            }
            val action = mediaReturnEditorAction(
                existingProjectID = editor?.projectID,
                existingStorage = editor?.storage,
                existingOrigin = editor?.origin,
                request = request,
            )
            latestReturnSequence = request.sequence
            if (action == MediaReturnEditorAction.FOCUS_EXISTING) {
                // Same live editor + same explicit context: focus only. No
                // second token, no close, no reopen.
                handledReturnRequestID = request.requestID
                pendingReturnRequestID = null
                return MediaReturnOpenDisposition.FOCUSED
            }
            pendingReturnRequestID = request.requestID
        }
        scope.launch { dispatchReturnOpen(request) }
        return MediaReturnOpenDisposition.DISPATCHED
    }

    private suspend fun dispatchReturnOpen(request: MediaReturnOpenRequest) {
        libraryMutex.withLock {
            if (closed) return@withLock
            val stillCurrent = synchronized(returnGuard) {
                pendingReturnRequestID == request.requestID &&
                    request.sequence == latestReturnSequence
            }
            if (!stillCurrent) return@withLock
            busy = true
            failure = null
            val token = newToken()
            try {
                val status = host.status()
                if (closed) return@withLock
                if (status.availability != CreativeAvailability.Available) {
                    failure = MediaFailure(
                        MediaFailureKind.RUNTIME_NOT_READY,
                        status.reason ?: "runtimeUnavailable",
                        retryable = true,
                    )
                    return@withLock
                }
                if (status.boundEpoch != request.expectedEpoch) {
                    // The accepted root changed after the App resolved the
                    // notification. The captured context no longer identifies
                    // a live authority, so nothing is opened and no other
                    // project/root is substituted.
                    failure = MediaFailure(
                        MediaFailureKind.SESSION_LOST,
                        "acceptedRootNotLive",
                    )
                    return@withLock
                }
                if (closed || synchronized(returnGuard) {
                    pendingReturnRequestID != request.requestID ||
                        request.sequence != latestReturnSequence
                }) return@withLock
                val existing = editor
                if (existing != null) {
                    val action = mediaReturnEditorAction(
                        existingProjectID = existing.projectID,
                        existingStorage = existing.storage,
                        existingOrigin = existing.origin,
                        request = request,
                    )
                    if (action == MediaReturnEditorAction.FOCUS_EXISTING) {
                        handledReturnRequestID = request.requestID
                        return@withLock
                    }
                    // Retire the REAL existing editor first. Its native
                    // persisted edit history stays; only this token is
                    // closed. The UI owner is cleared before retire so a
                    // late callback cannot clear/refresh the replacement.
                    editor = null
                    runCatching { existing.retire() }
                }
                if (closed || synchronized(returnGuard) {
                    pendingReturnRequestID != request.requestID ||
                        request.sequence != latestReturnSequence
                }) return@withLock
                val envelope = try {
                    host.open(
                        projectID = request.projectID,
                        sessionToken = token,
                        storage = request.storage,
                        origin = request.origin,
                    )
                } catch (cancelled: CancellationException) {
                    runCatching { host.closeWorkbenchEditor(request.projectID, token) }
                    throw cancelled
                } catch (error: Throwable) {
                    runCatching { host.closeWorkbenchEditor(request.projectID, token) }
                    failure = MediaFailures.from(error)
                    return@withLock
                }
                if (closed) {
                    runCatching { host.closeWorkbenchEditor(request.projectID, token) }
                    return@withLock
                }
                val stillLatest = synchronized(returnGuard) {
                    pendingReturnRequestID == request.requestID &&
                        request.sequence == latestReturnSequence
                }
                if (!stillLatest) {
                    // A newer return request/editor owns the session now.
                    // This token never retires/replaces it.
                    runCatching { host.closeWorkbenchEditor(request.projectID, token) }
                    return@withLock
                }
                installEditor(
                    envelope = envelope,
                    token = token,
                    origin = request.origin,
                    storage = request.storage,
                    editCopy = false,
                )
                synchronized(returnGuard) {
                    handledReturnRequestID = request.requestID
                    pendingReturnRequestID = null
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                failure = MediaFailures.from(error)
            } finally {
                busy = false
                synchronized(returnGuard) {
                    if (pendingReturnRequestID == request.requestID) {
                        pendingReturnRequestID = null
                    }
                }
            }
        }
    }

    /**
     * Explicit user action: connect the OPEN project to a REAL task and open
     * that task with a project reference in its draft. Native records a
     * pending trusted association; it authorizes nothing until the model's
     * first canonically approved media.project call for this exact task/project
     * pins the environment/workspace. Manual editing never calls this.
     */
    fun askAi(editor: MediaEditorController, instruction: String) {
        val port = agentBinding
        if (port == null) {
            agentFailure = "bindingUnavailable"
            return
        }
        if (closed || agentBusy || this.editor !== editor) return
        if (editor.busy || editor.needsReload || !editor.writable) {
            agentFailure = "projectNotReady"
            return
        }
        val owner = agentOwner
        agentBusy = true
        agentFailure = null
        agentTaskID = null
        agentJob = scope.launch {
            if (closed) {
                agentJob = null
                agentBusy = false
                return@launch
            }
            try {
                val receipt = port.askAi(
                    MediaAgentTaskRequest(
                        projectID = editor.projectID,
                        projectRevision = editor.revision,
                        projectName = editor.project.name,
                        ownerTaskID = owner?.taskID,
                        ownerWorkspaceID = owner?.workspaceID,
                        instruction = instruction,
                        selectionOpID = newOperationID(),
                    ),
                )
                if (closed) return@launch
                agentTaskID = receipt.taskID
                // Navigation/open is owned by the App port. Retire only THIS
                // exact editor; a replacement editor is never touched.
                if (this@MediaWorkspaceSession.editor === editor) {
                    this@MediaWorkspaceSession.editor = null
                    runCatching { editor.retire() }
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                agentFailure = (error as? MediaAgentBindingFailure)?.code
                    ?: "taskUnavailable"
            } finally {
                // A newer explicit Ask AI may have replaced the job after a
                // fast finish; never clear an ACTIVE replacement from the old
                // coroutine's finally.
                if (agentJob?.isActive != true) agentJob = null
                agentBusy = false
            }
        }
    }

    fun dismissAgentFailure() {
        agentFailure = null
    }

    fun createBlank(
        name: String,
        width: Int = 2048,
        height: Int = 2048,
        kind: String = "image",
        storage: CreativeStorageLayer = CreativeStorageLayer.AppOwned,
        origin: CreativeOriginContext = CreativeOriginContext.standalone(),
    ) {
        if (closed || busy || editor != null) return
        val clean = name.trim()
        if (clean.isEmpty()) {
            failure = MediaFailure(MediaFailureKind.INVALID_REQUEST, "invalidName")
            return
        }
        scope.launch {
            libraryMutex.withLock {
                if (closed) return@withLock
                busy = true
                failure = null
                val token = newToken()
                try {
                    val envelope = host.create(
                        name = clean,
                        kind = kind,
                        width = width.coerceIn(2, 8192),
                        height = height.coerceIn(2, 8192),
                        frameRate = null,
                        storage = storage,
                        origin = origin,
                        sessionToken = token,
                    )
                    if (closed) {
                        runCatching { host.closeWorkbenchEditor(envelope.project.id, token) }
                        return@withLock
                    }
                    installEditor(envelope, token, origin, storage, editCopy = false)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    failure = MediaFailures.from(error)
                } finally {
                    busy = false
                }
            }
        }
    }

    fun importNew(
        name: String,
        source: MediaPickedSource,
        kind: String,
        storage: CreativeStorageLayer,
        origin: CreativeOriginContext?,
        editCopy: Boolean = false,
        opID: String? = null,
    ): Boolean {
        if (closed || busy || editor != null) return false
        val clean = name.trim()
        if (clean.isEmpty()) {
            failure = MediaFailure(MediaFailureKind.INVALID_REQUEST, "invalidName")
            return false
        }
        importJob = scope.launch {
            libraryMutex.withLock {
                if (closed) return@withLock
                busy = true
                failure = null
                val token = newToken()
                try {
                    val envelope = ports.sourceCreate.createMediaFromSource(
                        source = source,
                        name = clean,
                        kind = kind,
                        storage = storage,
                        origin = origin,
                        sessionToken = token,
                        opID = opID ?: newOperationID(),
                    )
                    if (closed) {
                        runCatching {
                            host.closeWorkbenchEditor(envelope.project.id, token)
                        }
                        return@withLock
                    }
                    installEditor(envelope, token, origin, storage, editCopy)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    failure = MediaFailures.from(error)
                } finally {
                    busy = false
                }
            }
        }
        return true
    }

    fun rename(summary: MediaProjectSummary, name: String) {
        if (closed || busy) return
        if (summary.ownerKind != "standalone") {
            failure = MediaFailure(MediaFailureKind.ORIGIN_REQUIRED, "storageLayerRequired")
            return
        }
        val clean = name.trim()
        if (clean.isEmpty()) {
            failure = MediaFailure(MediaFailureKind.INVALID_REQUEST, "invalidName")
            return
        }
        scope.launch {
            libraryMutex.withLock {
                if (closed) return@withLock
                busy = true
                failure = null
                val token = newToken()
                try {
                    host.open(summary.id, token)
                    if (closed) return@withLock
                    host.rename(
                        projectID = summary.id,
                        expectedRevision = summary.revision,
                        name = clean,
                        sessionToken = token,
                        storage = null,
                        origin = null,
                        opID = newOperationID(),
                    )
                    if (closed) return@withLock
                    projects = host.mediaLibrary()
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    failure = MediaFailures.from(error)
                } finally {
                    runCatching { host.closeWorkbenchEditor(summary.id, token) }
                    busy = false
                }
            }
        }
    }

    fun delete(summary: MediaProjectSummary) {
        if (closed || busy) return
        if (summary.ownerKind != "standalone") {
            failure = MediaFailure(MediaFailureKind.ORIGIN_REQUIRED, "storageLayerRequired")
            return
        }
        scope.launch {
            libraryMutex.withLock {
                if (closed) return@withLock
                busy = true
                failure = null
                val token = newToken()
                try {
                    host.open(summary.id, token)
                    if (closed) return@withLock
                    host.delete(
                        projectID = summary.id,
                        expectedRevision = summary.revision,
                        sessionToken = token,
                        storage = null,
                        origin = null,
                        opID = newOperationID(),
                    )
                    if (closed) return@withLock
                    projects = host.mediaLibrary()
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    failure = MediaFailures.from(error)
                } finally {
                    runCatching { host.closeWorkbenchEditor(summary.id, token) }
                    busy = false
                }
            }
        }
    }

    suspend fun closeEditor(controller: MediaEditorController) {
        if (editor === controller) {
            agentJob?.cancel()
            agentJob = null
            editor = null
        }
        runCatching { controller.retire() }
        refreshAfterClose()
    }

    fun retireFromUi(controller: MediaEditorController) {
        if (editor === controller) {
            agentJob?.cancel()
            agentJob = null
            editor = null
        }
        scope.launch {
            runCatching { controller.retire() }
            refreshAfterClose()
        }
    }

    private suspend fun refreshAfterClose() {
        if (closed) return
        libraryMutex.withLock {
            if (closed) return@withLock
            runCatching {
                availability = host.status().availability
                if (availability == CreativeAvailability.Available) {
                    projects = host.mediaLibrary()
                }
            }
        }
    }

    suspend fun shutdown() {
        if (closed) return
        closed = true
        agentJob?.cancel()
        agentJob = null
        agentBusy = false
        agentFailure = null
        agentTaskID = null
        importJob?.cancel()
        importJob = null
        val current = editor
        editor = null
        if (current != null) {
            current.markRetired()
            runCatching { host.closeWorkbenchEditor(current.projectID, current.sessionToken) }
        }
        if (ownsScope) scope.cancel()
    }

    private fun installEditor(
        envelope: MediaProjectEnvelope,
        token: String,
        origin: CreativeOriginContext?,
        storage: CreativeStorageLayer,
        editCopy: Boolean,
    ) {
        val controller = MediaEditorController(
            host = host,
            ports = ports,
            initial = envelope,
            sessionToken = token,
            storage = storage,
            origin = origin,
            editCopy = editCopy,
            scope = scope,
            newOperationID = newOperationID,
            r2Ports = r2Ports,
            exportCoordinator = exportCoordinator,
            onRetired = { retired ->
                if (editor === retired) {
                    editor = null
                    refreshQuietly()
                }
            },
        )
        editor = controller
        controller.start()
    }
}
