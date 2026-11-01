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
import com.floe.android.feature.workbench.ui.api.MediaEditorPorts
import com.floe.android.feature.workbench.ui.api.MediaPickedSource
import com.floe.android.feature.workbench.ui.presentation.MediaFailure
import com.floe.android.feature.workbench.ui.presentation.MediaFailureKind
import com.floe.android.feature.workbench.ui.presentation.MediaFailures
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
) {
    private val ownsScope = scope == null
    private val scope: CoroutineScope =
        scope ?: CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val libraryMutex = Mutex()
    @Volatile private var importJob: Job? = null
    private var started = false
    @Volatile private var closed = false

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

    val showAvailabilityState: Boolean
        get() = availability != null && availability != CreativeAvailability.Available
    val isClosed: Boolean get() = closed

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
        if (editor === controller) editor = null
        runCatching { controller.retire() }
        refreshAfterClose()
    }

    fun retireFromUi(controller: MediaEditorController) {
        if (editor === controller) editor = null
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
