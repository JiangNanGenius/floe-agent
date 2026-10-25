// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import android.content.Context
import android.content.Intent
import android.os.IBinder
import com.floe.android.core.officeengine.OfficeCloseAck
import com.floe.android.core.officeengine.OfficeCloseAckPolicy
import com.floe.android.core.officeengine.OfficeEngine
import com.floe.android.core.officeengine.OfficePreviewRequest
import com.floe.android.core.officeengine.OfficeViewerOutcome
import com.floe.android.safgateway.SafOperation
import com.floe.android.safgateway.SafFailure
import com.floe.android.safgateway.SafOutcome
import java.io.File
import java.util.Locale
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Main-process, Application-owned preview admission and input lifetime.
 * Native work belongs to the module's Office process. This controller owns
 * only its two input transports and exact platform-launch incarnations.
 * A view remount never cancels staging or invents another native document.
 */
internal class OfficePreviewController(context: Context, private val scope: CoroutineScope) {
    private val context = context.applicationContext
    private val workspaceRoot = File(this.context.applicationInfo.dataDir, "files/OfficeInputs/workspace")
    private val providerRoot = File(this.context.applicationInfo.dataDir, "files/OfficeInputs/provider")
    private val workspace = WorkspaceOfficeSnapshotStager(workspaceRoot)
    private val provider = OfficeProviderSnapshotStager(this.context, providerRoot)
    private val lock = Any()
    private var sequence = 0L
    private var active: Operation? = null

    /**
     * Parent endpoint of the module's narrow close-intent capability
     * (OfficeCloseAckPolicy). The engine process calls it SYNCHRONOUSLY to
     * acknowledge one exact current user close BEFORE posting the native
     * BYE whose process exit (std::_exit(0)) bypasses every Java
     * Activity-result path in the viewer process. Acknowledgement records
     * close ownership only: it never marks closedCleanly and never deletes
     * the retained staged snapshot. The record is consumed by the real
     * Activity result (or dropped when the operation is replaced).
     */
    private val closeAckBinder: IBinder by lazy { OfficeCloseAck.parentBinder(this::acceptCloseIntent) }

    /** lock-protected: the acknowledged close for the current operation. */
    private var ackedClose: OfficeCloseAckPolicy.AckRequest? = null
    val pickerNamespace = PlatformLaunchOwnership.mintNamespace()
    val viewerNamespace = PlatformLaunchOwnership.mintNamespace()

    data class ViewerLaunch(val incarnation: Long, val request: OfficePreviewRequest)
    data class State(val picker: Long? = null, val viewer: ViewerLaunch? = null,
                     val staging: Boolean = false, val cancelling: Boolean = false,
                     val error: String? = null)
    private val mutableState = MutableStateFlow(State())
    val state: StateFlow<State> = mutableState
    /** Original failure retained in RAM for explicit diagnostics, never
     * interpolated into ordinary UI copy or automatic logs. */
    @Volatile var diagnosticFailure: Any? = null
        private set

    private enum class Phase { PICKING, STAGING, LAUNCH, VIEWING }
    private class Operation(val id: Long, var phase: Phase, val ownerCurrent: () -> Boolean) {
        @Volatile var retired = false
        @Volatile var input: File? = null
        @Volatile var sessionToken: String? = null
        @Volatile var providerIO: SafOperation<OfficeProviderSnapshotStager.Snapshot>? = null
    }

    private fun current(op: Operation): Boolean = synchronized(lock) {
        active === op && !op.retired && op.ownerCurrent()
    }

    private fun admit(phase: Phase, owner: () -> Boolean): Operation? = synchronized(lock) {
        if (active != null || sequence == Long.MAX_VALUE) {
            mutableState.value = mutableState.value.copy(error = "busy")
            return null
        }
        diagnosticFailure = null
        ackedClose = null
        Operation(++sequence, phase, owner).also { active = it }
    }

    fun requestProviderPick() {
        val op = admit(Phase.PICKING) { true } ?: return
        synchronized(lock) { mutableState.value = State(picker = op.id) }
    }

    fun onPickerResult(incarnation: Long, uri: String?, actualFlags: Int) {
        val op = synchronized(lock) {
            active?.takeIf { it.id == incarnation && it.phase == Phase.PICKING && !it.retired }
                ?.also { it.phase = Phase.STAGING; mutableState.value = State(staging = true) }
        } ?: return
        if (uri == null) { settle(op, null); return }
        scope.launch(Dispatchers.IO) {
            try {
                val operation = provider.submit(uri, actualFlags) { current(op) }
                op.providerIO = operation
                if (op.retired) operation.cancel()
                // Request cancellation does not prove provider IO stopped.
                val result = withContext(NonCancellable) { operation.await() }
                when (result) {
                    is SafOutcome.Failure -> {
                        recordFailure(op, result)
                        settle(op, if (op.retired || result.failure == SafFailure.Cancelled) null
                            else if (result.failure is SafFailure.SizeLimitExceeded) "tooLarge"
                            else if (result.failure is SafFailure.Unsupported) "format" else "source")
                    }
                    is SafOutcome.Success -> {
                        val snapshot = result.value
                        op.input = snapshot.file
                        prepare(op, OfficePreviewRequest.of(
                            sessionToken = snapshot.sessionID, stagedFilePath = snapshot.file.canonicalPath,
                            sha256 = snapshot.sha256, lengthBytes = snapshot.bytes,
                            displayName = snapshot.displayName,
                            languageTag = languageTag(),
                        ))
                    }
                }
            } catch (error: Exception) {
                recordFailure(op, error); settle(op, stagingError(op, error))
            } catch (error: LinkageError) {
                recordFailure(op, error); settle(op, stagingError(op, error))
            }
        }
    }

    fun openWorkspace(owner: WorkspaceOfficeSnapshotStager.Owner, path: String, ownerCurrent: () -> Boolean) {
        val op = admit(Phase.STAGING, ownerCurrent) ?: return
        mutableState.value = State(staging = true)
        scope.launch(Dispatchers.IO) {
            try {
                val snapshot = workspace.stage(owner, path) { current(op) }
                op.input = snapshot.file
                prepare(op, OfficePreviewRequest.of(
                    sessionToken = snapshot.sessionID, stagedFilePath = snapshot.file.canonicalPath,
                    sha256 = snapshot.sha256, lengthBytes = snapshot.bytes,
                    displayName = path.substringAfterLast('/'), languageTag = languageTag(),
                    ownerTaskId = owner.taskID, workspaceId = owner.workspaceID,
                    nativeEpoch = owner.nativeEpoch.toString(), hostGeneration = owner.hostGeneration.toString(),
                    sourceLogicalPath = snapshot.logicalPath, sourceId = snapshot.sourceID,
                    sourceRevision = snapshot.sourceRevision,
                ))
            } catch (error: Exception) {
                recordFailure(op, error); settle(op, stagingError(op, error))
            } catch (error: LinkageError) {
                recordFailure(op, error); settle(op, stagingError(op, error))
            }
        }
    }

    private fun prepare(op: Operation, result: Result<OfficePreviewRequest>) {
        val request = result.getOrNull()
        if (request == null) {
            result.exceptionOrNull()?.let { recordFailure(op, it) }
            settle(op, if (op.retired) null else "format"); return
        }
        synchronized(lock) {
            if (!current(op)) { settle(op, null); return }
            op.sessionToken = request.sessionToken
            op.phase = Phase.LAUNCH
            mutableState.value = State(viewer = ViewerLaunch(op.id, request))
        }
    }

    /**
     * Validates one engine close-intent acknowledgement on a Binder thread:
     * ONLY the current, un-retired VIEWING operation whose opaque viewer
     * incarnation AND session token match exactly may be acknowledged
     * (shape/allowlist were already enforced fail-closed by the endpoint).
     * Stale owners, replacements and internal teardowns are rejected; the
     * record is consumed only by the later real Activity result.
     */
    private fun acceptCloseIntent(ack: OfficeCloseAckPolicy.AckRequest): Boolean = synchronized(lock) {
        val op = active?.takeIf { !it.retired }
        android.util.Log.d("OfficeCloseAck", "parent owner active=${op != null} viewing=${op?.phase == Phase.VIEWING} incarnationMatch=${op?.id == ack.viewerIncarnation} tokenMatch=${op?.sessionToken == ack.sessionToken}")
        if (op == null) return false
        if (op.id != ack.viewerIncarnation || op.phase != Phase.VIEWING || op.sessionToken != ack.sessionToken) {
            return false
        }
        ackedClose = ack
        true
    }

    /** Claim immediately before launching, on the UI thread. Admission is
     * fenced again after asynchronous input preparation, not just at click.
     * The close-intent capability and this launch's opaque incarnation are
     * attached to the private viewer Intent only (OfficeCloseAckPolicy).
     * The IBinder travels via Bundle.putBinder (it is not a Parcelable) on
     * the same non-exported launch Intent that carries the request. */
    fun claimViewer(incarnation: Long): Intent? = synchronized(lock) {
        val op = active?.takeIf { it.id == incarnation && it.phase == Phase.LAUNCH } ?: return null
        if (!current(op)) { settle(op, null); return null }
        val request = mutableState.value.viewer?.request ?: return null
        op.phase = Phase.VIEWING
        val intent = OfficeEngine.previewIntent(context, request)
        intent.putExtra(OfficeCloseAckPolicy.EXTRA_VIEWER_INCARNATION, op.id)
        val extras = intent.extras ?: android.os.Bundle()
        extras.putBinder(OfficeCloseAckPolicy.EXTRA_CLOSE_ACK, closeAckBinder)
        intent.replaceExtras(extras)
        intent
    }

    fun onViewerResult(incarnation: Long, data: Intent?) {
        val op = synchronized(lock) {
            active?.takeIf { it.id == incarnation && it.phase == Phase.VIEWING }
        } ?: return
        val outcome = OfficeViewerOutcome.fromResultData(data)
        val exact = outcome?.sessionToken == op.sessionToken
        if (outcome != null) recordFailure(op, outcome)
        // Consume the close-intent record only for THIS exact operation and
        // token; an acknowledgement never settles the slot by itself.
        val acked = synchronized(lock) {
            ackedClose?.takeIf {
                it.viewerIncarnation == incarnation && it.sessionToken == op.sessionToken
            }?.also { ackedClose = null } != null
        }
        val resolution = OfficeCloseAckPolicy.resolveViewerResult(
            ownerCurrent = op.ownerCurrent(),
            outcomePresent = outcome != null,
            exactToken = exact,
            failureName = outcome?.failure?.name,
            closedCleanly = outcome?.closedCleanly == true,
            ackedUserClose = acked,
        )
        // Only an exact native clean-close receipt permits removing an input
        // already handed to the engine (unchanged rule). An acknowledged
        // user close whose result was bypassed by the engine's native
        // std::_exit(0) is honest uncertainty: no open-failure report, the
        // staged snapshot is retained, closedCleanly is never inferred.
        // Unknown/unacknowledged dead-process results keep failing as before.
        settle(op, resolution.errorKey, removeInput = resolution.removeInput)
    }

    fun launchFailed(incarnation: Long) {
        val op = synchronized(lock) { active?.takeIf { it.id == incarnation } } ?: return
        // Preserve after a possibly accepted cross-process launch.
        settle(op, "viewer", removeInput = false)
    }

    /** Explicit navigation/cancel only; never called by composition disposal. */
    fun cancelUnopened() = synchronized(lock) {
        val op = active ?: return
        if (op.phase == Phase.VIEWING) return
        op.retired = true
        op.providerIO?.cancel()
        if (op.phase == Phase.STAGING) {
            mutableState.value = State(staging = true, cancelling = true)
        } else settle(op, null)
    }

    fun clearError() = synchronized(lock) { mutableState.value = mutableState.value.copy(error = null) }
    fun reportSourceUnavailable() = synchronized(lock) { mutableState.value = mutableState.value.copy(error = "source") }

    private fun stagingError(op: Operation, error: Throwable): String? = when {
        op.retired -> null
        error is WorkspaceOfficeSnapshotStager.Failure && error.code == "contentTooLarge" -> "tooLarge"
        else -> "source"
    }

    private fun recordFailure(op: Operation, error: Any) = synchronized(lock) {
        if (active === op) diagnosticFailure = error
    }

    private fun settle(op: Operation, error: String?, removeInput: Boolean = true) = synchronized(lock) {
        if (active !== op) return
        // A close-intent belongs only to the operation it acknowledged.
        ackedClose = null
        if (removeInput) op.input?.let { file ->
            scope.launch(Dispatchers.IO) { removeOwnUnreferencedInput(file) }
        }
        active = null
        mutableState.value = State(error = error)
    }

    private fun removeOwnUnreferencedInput(file: File?) {
        if (file == null) return
        runCatching {
            val parent = file.parentFile?.canonicalFile ?: return
            val roots = setOf(workspaceRoot.canonicalFile, providerRoot.canonicalFile)
            val container = parent.parentFile ?: return
            if (container !in roots || runCatching { java.util.UUID.fromString(parent.name) }.isFailure) return
            // No recursive traversal of native-created links or unknown files.
            file.delete()
            parent.delete()
        }
    }

    private fun languageTag(): String = context.resources.configuration.locales.get(0).toLanguageTag()

    companion object {
        fun supports(path: String): Boolean = path.substringAfterLast('.', "").lowercase(Locale.ROOT) in
            setOf("docx", "xlsx", "pptx")
        val MIME_TYPES = arrayOf(
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        )
    }
}
