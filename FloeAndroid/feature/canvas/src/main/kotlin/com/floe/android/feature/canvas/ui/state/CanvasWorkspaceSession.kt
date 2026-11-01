// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.canvas.ui.state

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.floe.android.feature.canvas.CanvasHostApi
import com.floe.android.feature.canvas.CanvasProjectEnvelope
import com.floe.android.feature.canvas.CanvasProjectSummary
import com.floe.android.feature.canvas.CreativeAvailability
import com.floe.android.feature.canvas.CreativeSessionTokens
import com.floe.android.feature.canvas.ui.api.CanvasEditorPorts
import com.floe.android.feature.canvas.ui.api.CanvasPickedSource
import com.floe.android.feature.canvas.ui.presentation.CanvasFailure
import com.floe.android.feature.canvas.ui.presentation.CanvasFailureKind
import com.floe.android.feature.canvas.ui.presentation.CanvasFailures
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Retained Canvas library + editor session.
 *
 * The session is created OUTSIDE composition by the App owner and passed to
 * `FloeCanvasLibrary`. Rotation/background/view reconstruction reuses this
 * object (the editor token, the loaded envelope, selection and undo stack are
 * preserved); an actual editor close/navigation retires only the exact token
 * through `closeCanvasEditor(canvasID, sessionToken)`. It never calls a global
 * runtime shutdown and never stores a project library of its own.
 */
@Stable
class CanvasWorkspaceSession(
    private val host: CanvasHostApi,
    val ports: CanvasEditorPorts,
    scope: CoroutineScope? = null,
    private val newToken: () -> String = CreativeSessionTokens::newToken,
    private val newOperationID: () -> String = { UUID.randomUUID().toString() },
) {
    private val ownsScope = scope == null
    private val scope: CoroutineScope =
        scope ?: CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val libraryMutex = Mutex()
    private var started = false
    @Volatile private var closed = false

    var availability: CreativeAvailability? by mutableStateOf(null)
        private set
    var loading by mutableStateOf(true)
        private set
    var refreshing by mutableStateOf(false)
        private set
    var projects by mutableStateOf<List<CanvasProjectSummary>>(emptyList())
        private set
    var failure: CanvasFailure? by mutableStateOf(null)
        private set
    var busy by mutableStateOf(false)
        private set
    var editor: CanvasEditorController? by mutableStateOf(null)
        private set

    val showAvailabilityState: Boolean
        get() = availability != null && availability != CreativeAvailability.Available

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
                        val value = host.canvasLibrary()
                        if (closed) return@withLock
                        projects = value
                    } else {
                        projects = emptyList()
                    }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    availability = CanvasFailures.from(error).availability
                        ?: CreativeAvailability.Unavailable
                    failure = CanvasFailures.from(error)
                } finally {
                    loading = false
                    refreshing = false
                }
            }
        }
    }

    fun refreshQuietly() {
        if (closed) return
        scope.launch {
            libraryMutex.withLock {
                if (closed) return@withLock
                try {
                    val status = host.status()
                    availability = status.availability
                    if (status.availability == CreativeAvailability.Available) {
                        projects = host.canvasLibrary()
                    }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Throwable) {
                    // Keep the previous truthful projection; the visible
                    // error surface comes from the explicit operation.
                }
            }
        }
    }

    fun open(summary: CanvasProjectSummary) {
        if (closed || busy || editor != null) return
        if (summary.corrupt) {
            failure = CanvasFailure(CanvasFailureKind.CORRUPT, "corruptProject")
            return
        }
        scope.launch { openInternal(summary.id) }
    }

    fun createBlank(name: String) {
        if (closed || busy || editor != null) return
        val clean = name.trim()
        if (clean.isEmpty()) {
            failure = CanvasFailure(CanvasFailureKind.INVALID_REQUEST, "invalidName")
            return
        }
        scope.launch {
            libraryMutex.withLock {
                if (closed) return@withLock
                busy = true
                failure = null
                val token = newToken()
                try {
                    val envelope = host.create(clean, null, token)
                    if (closed) return@withLock
                    installEditor(envelope, token, recovery = null)
                    refreshQuietlyLocked()
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    failure = CanvasFailures.from(error)
                } finally {
                    busy = false
                }
            }
        }
    }

    fun importNew(
        name: String,
        source: CanvasPickedSource,
        workspaceID: String? = null,
        opID: String? = null,
    ) {
        if (closed || busy || editor != null) return
        val clean = name.trim()
        if (clean.isEmpty()) {
            failure = CanvasFailure(CanvasFailureKind.INVALID_REQUEST, "invalidName")
            return
        }
        scope.launch {
            libraryMutex.withLock {
                if (closed) return@withLock
                busy = true
                failure = null
                val token = newToken()
                try {
                    val envelope = ports.sourceCreate.createCanvasFromSource(
                        source = source,
                        name = clean,
                        workspaceID = workspaceID,
                        sessionToken = token,
                        opID = opID ?: newOperationID(),
                    )
                    if (closed) return@withLock
                    installEditor(envelope, token, recovery = null)
                    refreshQuietlyLocked()
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    failure = CanvasFailures.from(error)
                } finally {
                    busy = false
                }
            }
        }
    }

    fun rename(summary: CanvasProjectSummary, name: String) {
        if (closed || busy) return
        val clean = name.trim()
        if (clean.isEmpty()) {
            failure = CanvasFailure(CanvasFailureKind.INVALID_REQUEST, "invalidName")
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
                        canvasID = summary.id,
                        expectedRevision = summary.revision,
                        name = clean,
                        sessionToken = token,
                        opID = newOperationID(),
                    )
                    if (closed) return@withLock
                    projects = host.canvasLibrary()
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    failure = CanvasFailures.from(error)
                } finally {
                    runCatching { host.closeCanvasEditor(summary.id, token) }
                    busy = false
                }
            }
        }
    }

    fun delete(summary: CanvasProjectSummary) {
        if (closed || busy) return
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
                        canvasID = summary.id,
                        expectedRevision = summary.revision,
                        sessionToken = token,
                        opID = newOperationID(),
                    )
                    if (closed) return@withLock
                    projects = host.canvasLibrary()
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    failure = CanvasFailures.from(error)
                } finally {
                    // Deleting clears the native session itself; the extra
                    // token-scoped close is a no-op and never a global stop.
                    runCatching { host.closeCanvasEditor(summary.id, token) }
                    busy = false
                }
            }
        }
    }

    /**
     * Token-scoped editor close. Waits for an in-flight patch to settle (the
     * native receipt still records a committed edit), then retires only this
     * editor's token and refreshes the library.
     */
    suspend fun closeEditor(controller: CanvasEditorController) {
        if (editor === controller) editor = null
        runCatching { controller.retire() }
        refreshAfterClose()
    }

    /** Disposal/navigation close: no dialogs, exact token only. */
    fun retireFromUi(controller: CanvasEditorController) {
        if (editor === controller) editor = null
        scope.launch { runCatching { controller.retire() }; refreshAfterClose() }
    }

    private suspend fun refreshAfterClose() {
        if (closed) return
        libraryMutex.withLock {
            if (closed) return@withLock
            runCatching {
                availability = host.status().availability
                if (availability == CreativeAvailability.Available) {
                    projects = host.canvasLibrary()
                }
            }
        }
    }

    suspend fun shutdown() {
        if (closed) return
        closed = true
        val current = editor
        editor = null
        if (current != null) {
            current.markRetired()
            runCatching { host.closeCanvasEditor(current.canvasID, current.sessionToken) }
        }
        if (ownsScope) scope.cancel()
    }

    private suspend fun openInternal(canvasID: String) {
        libraryMutex.withLock {
            if (closed) return@withLock
            busy = true
            failure = null
            val token = newToken()
            try {
                val envelope = host.open(canvasID, token)
                if (closed) {
                    runCatching { host.closeCanvasEditor(canvasID, token) }
                    return@withLock
                }
                val recovery = runCatching { host.recover(canvasID) }.getOrNull()
                installEditor(envelope, token, recovery)
            } catch (cancelled: CancellationException) {
                runCatching { host.closeCanvasEditor(canvasID, token) }
                throw cancelled
            } catch (error: Throwable) {
                runCatching { host.closeCanvasEditor(canvasID, token) }
                failure = CanvasFailures.from(error)
            } finally {
                busy = false
            }
        }
    }

    private fun installEditor(
        envelope: CanvasProjectEnvelope,
        token: String,
        recovery: com.floe.android.feature.canvas.CanvasRecoveryState?,
    ) {
        val controller = CanvasEditorController(
            host = host,
            ports = ports,
            initial = envelope,
            sessionToken = token,
            initialRecovery = recovery,
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
    }

    private suspend fun refreshQuietlyLocked() {
        runCatching {
            availability = host.status().availability
            if (availability == CreativeAvailability.Available) {
                projects = host.canvasLibrary()
            }
        }
    }
}
