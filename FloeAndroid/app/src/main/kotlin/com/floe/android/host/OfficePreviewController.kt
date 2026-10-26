// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import android.content.Context
import android.content.Intent
import android.os.IBinder
import com.floe.android.core.officeengine.OfficeCloseAck
import com.floe.android.core.officeengine.OfficeCloseAckPolicy
import com.floe.android.core.officeengine.OfficeEngine
import com.floe.android.core.officeengine.OfficePermission
import com.floe.android.core.officeengine.OfficePreviewRequest
import com.floe.android.core.officeengine.OfficeViewerOutcome
import com.floe.android.safgateway.SafOperation
import com.floe.android.safgateway.SafFailure
import com.floe.android.safgateway.SafOutcome
import com.floe.android.safgateway.SafUriRef
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
 * its two input transports, the owned mutable EDIT working copies, the exact
 * platform-launch incarnations and the Save-Copy host wiring. Both routes
 * (system picker and workspace) now open a SEPARATELY OWNED writable working
 * copy staged from the still-verified immutable snapshot; public default
 * READ_ONLY callers remain safe because the snapshot paths and the module's
 * READ_ONLY default are unchanged. A view remount never cancels staging,
 * save IO or invents another native document.
 */
internal class OfficePreviewController(context: Context, private val scope: CoroutineScope) {
    private val context = context.applicationContext
    private val workspaceRoot = File(this.context.applicationInfo.dataDir, "files/OfficeInputs/workspace")
    private val providerRoot = File(this.context.applicationInfo.dataDir, "files/OfficeInputs/provider")
    private val workingRoot = File(this.context.applicationInfo.dataDir, "files/OfficeInputs/working")
    private val workspace = WorkspaceOfficeSnapshotStager(workspaceRoot)
    private val provider = OfficeProviderSnapshotStager(this.context, providerRoot)
    /** R2: separate owned MUTABLE working copy per edit route (never a chmod of
     * the immutable snapshot or any original; retained after close for recovery). */
    private val working = OfficeEditableCopyStager(workingRoot)
    /** Application-owned Save-Copy handoff: exact-session controllers, module
     * command bind, host channel and the SAF gateway IO it schedules. Views
     * never own this lifetime. */
    private val saveCopy = OfficeSaveCopyHost(this.context)
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
        /** Immutable snapshot staged from the provider/workspace (EDIT routes). */
        @Volatile var snapshot: File? = null
        /** Owned mutable working copy handed to the engine (EDIT routes). */
        @Volatile var workingCopy: File? = null
        /** True once the route staged an EDIT working copy for this operation. */
        @Volatile var editable = false
        /** Provider same-original refusal facts from the source snapshot (null for workspace docs). */
        @Volatile var saveOriginal: OfficeSaveCopyOriginal? = null
        /** Set exactly once by settle: fences late Save-Copy/owner-alive reads. */
        @Volatile var viewEnded = false
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
                        op.snapshot = snapshot.file
                        op.input = snapshot.file
                        // EDIT route (Main 2026-10-26): stage a separately owned
                        // MUTABLE working copy from the verified immutable snapshot.
                        // The snapshot and the provider original are never chmod'd,
                        // truncated or overwritten; the same-original refusal below
                        // uses the snapshot's existing source URI / document id.
                        val copy = working.stage(
                            source = snapshot.file, sourceBytes = snapshot.bytes,
                            sourceSha256 = snapshot.sha256, extension = snapshot.file.extension,
                            isCurrent = { current(op) },
                        )
                        op.workingCopy = copy.file
                        op.input = copy.file
                        op.editable = true
                        op.saveOriginal = OfficeSaveCopyOriginal(
                            SafUriRef(snapshot.sourceUri), snapshot.sourceDocumentID,
                        )
                        prepare(op, OfficePreviewRequest.of(
                            sessionToken = copy.sessionID, stagedFilePath = copy.file.canonicalPath,
                            sha256 = copy.sha256, lengthBytes = copy.bytes,
                            displayName = snapshot.displayName,
                            languageTag = languageTag(),
                            permission = OfficePermission.EDIT,
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
                op.snapshot = snapshot.file
                op.input = snapshot.file
                // EDIT route: same separately owned mutable working copy from
                // the verified workspace snapshot. Real task/workspace/epoch/
                // generation/source facts are carried; none is invented. A
                // workspace document is not a provider URI, so same-original
                // refusal does not apply and original overwrite remains
                // unsupported in this copy-only slice.
                val copy = working.stage(
                    source = snapshot.file, sourceBytes = snapshot.bytes,
                    sourceSha256 = snapshot.sha256, extension = snapshot.file.extension,
                    isCurrent = { current(op) },
                )
                op.workingCopy = copy.file
                op.input = copy.file
                op.editable = true
                prepare(op, OfficePreviewRequest.of(
                    sessionToken = copy.sessionID, stagedFilePath = copy.file.canonicalPath,
                    sha256 = copy.sha256, lengthBytes = copy.bytes,
                    displayName = path.substringAfterLast('/'), languageTag = languageTag(),
                    permission = OfficePermission.EDIT,
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
        if (op.editable) {
            // Publish the token before opening the session so ANY settle path
            // (including a concurrent retirement during open) closes exactly it.
            op.sessionToken = request.sessionToken
            // Lock-free liveness closure: the Save-Copy core calls this while
            // holding its own lock, so it must never re-enter the preview lock.
            val alive = { !op.retired && !op.viewEnded }
            if (!saveCopy.beginEditSession(request.sessionToken, request.displayName, op.saveOriginal, alive)) {
                recordFailure(op, saveCopy.lastDiagnostic() ?: "edit session unavailable")
                settle(op, if (op.retired) null else "source")
                return
            }
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
     * The R2 viewer Intent carries the existing close-intent capability and
     * opaque incarnation plus, for EDIT routes, the application-owned
     * Save-Copy host channel (same trust model: inert IBinder extras on the
     * non-exported viewer launch Intent only, per OfficeEngine.viewerIntent).
     * The module owns the Edit affordance, page mode and its own witnesses;
     * the App only attaches these capabilities and owns files/persistence. */
    fun claimViewer(incarnation: Long): Intent? = synchronized(lock) {
        val op = active?.takeIf { it.id == incarnation && it.phase == Phase.LAUNCH } ?: return null
        if (!current(op)) { settle(op, null); return null }
        val request = mutableState.value.viewer?.request ?: return null
        op.phase = Phase.VIEWING
        OfficeEngine.viewerIntent(
            context, request, closeAckBinder, op.id,
            hostSaveChannel = if (op.editable) saveCopy.channel else null,
        )
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
        error is OfficeEditableCopyStager.Failure && error.code == "contentTooLarge" -> "tooLarge"
        else -> "source"
    }

    private fun recordFailure(op: Operation, error: Any) = synchronized(lock) {
        if (active === op) diagnosticFailure = error
    }

    private fun settle(op: Operation, error: String?, removeInput: Boolean = true) = synchronized(lock) {
        if (active !== op) return
        // A close-intent belongs only to the operation it acknowledged.
        ackedClose = null
        op.viewEnded = true
        if (op.editable) {
            // Close the exact Save-Copy session. Its controller releases only
            // after scheduled IO drains (quiescence, never a mid-IO clear);
            // in-flight transfers keep their honest verified outcome.
            op.sessionToken?.let { saveCopy.endEditSession(it) }
            // Retention contract: the mutable working copy and any module-
            // verified outputs are NEVER deleted here — on success, failure,
            // cancel or process loss they stay the recoverable base (a
            // user-visible recovery flow is separate pending work). Only the
            // immutable intermediate snapshot follows removal eligibility.
            if (removeInput) op.snapshot?.let { file ->
                scope.launch(Dispatchers.IO) { removeOwnUnreferencedInput(file) }
            }
        } else if (removeInput) {
            op.input?.let { file ->
                scope.launch(Dispatchers.IO) { removeOwnUnreferencedInput(file) }
            }
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
