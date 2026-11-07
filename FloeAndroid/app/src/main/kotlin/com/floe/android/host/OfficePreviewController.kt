// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.host.officerecovery.OfficeRecoveryRoute
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.IBinder
import com.floe.android.MainActivity
import com.floe.android.core.officeengine.OfficeApprovalNotice
import com.floe.android.core.officeengine.OfficeApprovalNoticePolicy
import com.floe.android.core.officeengine.OfficeCloseAck
import com.floe.android.core.officeengine.OfficeCloseAckPolicy
import com.floe.android.core.officeengine.OfficeEngine
import com.floe.android.core.officeengine.OfficePermission
import com.floe.android.core.officeengine.OfficePreviewActivity
import com.floe.android.core.officeengine.OfficePreviewRequest
import com.floe.android.core.officeengine.OfficeRequestPolicy
import com.floe.android.core.officeengine.OfficeSaveOriginalChannel
import com.floe.android.core.officeengine.OfficeSaveOriginalHandoffPolicy
import com.floe.android.core.officeengine.OfficeViewerOutcome
import com.floe.android.core.officeengine.revisionreview.OfficeConflictPreviewNaming
import com.floe.android.core.officeengine.revisionreview.OfficeConflictPreviewRole
import com.floe.android.core.officeengine.revisionreview.OfficeConflictReviewChannel
import com.floe.android.host.officereview.OfficeConflictArtifacts
import com.floe.android.host.officereview.OfficeConflictPreviewBuild
import com.floe.android.host.officereview.OfficeConflictPreviewRead
import com.floe.android.host.officereview.OfficeConflictPreviewReader
import com.floe.android.host.officereview.OfficeConflictReviewCoordinator
import com.floe.android.host.officereview.OfficeConflictReviewHost
import com.floe.android.host.officereview.OfficeConflictReviewIdentity
import com.floe.android.host.officereview.OfficeConflictRoute
import com.floe.android.host.officereview.OfficeConflictVersion
import com.floe.android.host.officereview.OfficeOriginalCapture
import com.floe.android.host.officerecovery.OfficeRecoveryArtifacts
import com.floe.android.host.officerecovery.OfficeRecoveryCandidate
import com.floe.android.host.officerecovery.OfficeRecoveryController
import com.floe.android.host.officerecovery.OfficeRecoveryJournal
import com.floe.android.host.officerecovery.OfficeRecoveryOpenPort
import com.floe.android.host.officerecovery.OfficeRecoveryOpenResult
import com.floe.android.host.officerecovery.OfficeRecoveryOriginalState
import com.floe.android.host.officerecovery.OfficeRecoveryPhase
import com.floe.android.host.officerecovery.OfficeRestoredDocument
import com.floe.android.host.officerecovery.OfficeRestoredDocumentOpenPort
import com.floe.android.host.officerecovery.OfficeRestoredOpenResult
import com.floe.android.host.output.NativeRunOutputChannel
import com.floe.android.host.output.RunOutputOfficeSnapshotStager
import com.floe.android.safgateway.SafOperation
import com.floe.android.safgateway.SafFailure
import com.floe.android.safgateway.SafOutcome
import com.floe.android.safgateway.SafUriRef
import java.io.File
import java.nio.file.Files
import java.util.Locale
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
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
    private val runOutputRoot = File(this.context.applicationInfo.dataDir, "files/OfficeInputs/runoutput")
    private val workingRoot = File(this.context.applicationInfo.dataDir, "files/OfficeInputs/working")
    private val workspace = WorkspaceOfficeSnapshotStager(workspaceRoot)
    private val provider = OfficeProviderSnapshotStager(this.context, providerRoot)
    private val pendingProviderPreview = OfficePendingPreviewStore(providerRoot,
        File(this.context.noBackupFilesDir, "office-pending-preview"))
    private val pendingPreviewRestored = java.util.concurrent.atomic.AtomicBoolean()
    /** D04 owned run-output INPUT transport: streams the native-verified snapshot
     * (exact persisted receipt -> lease -> full streamed verify) into this
     * App-owned immutable snapshot root. Never a model path, never a
     * workspace/provider authority claim. */
    private val runOutputs = RunOutputOfficeSnapshotStager(runOutputRoot, NativeRunOutputChannel)
    /** R2: separate owned MUTABLE working copy per edit route (never a chmod of
     * the immutable snapshot or any original; retained after close for recovery). */
    private val working = OfficeEditableCopyStager(workingRoot)
    /** Verified module outputs are written here by the Office engine module. */
    private val outputsRoot = File(this.context.noBackupFilesDir, "floe-office-outputs")
    /** C08 fresh restored documents written by the C07 full restore. */
    private val restoredDocumentsRoot = File(
        this.context.applicationInfo.dataDir, "files/OfficeInputs/restored")
    /** Ownership/byte checks for recovery paths; never authority by itself. */
    private val recoveryArtifacts = OfficeRecoveryArtifacts(workingRoot, outputsRoot)
    private val recoveryJournal: OfficeRecoveryJournal
    /** Application-owned Save-Copy handoff: exact-session controllers, module
     * command bind, host channel and the SAF gateway IO it schedules. Views
     * never own this lifetime. */
    private val saveCopy: OfficeSaveCopyHost
    /** Durable recovery review/action owner (C08 OFC-SAVE-REOPEN). */
    internal val recovery: OfficeRecoveryController
    /** App-owned immutable snapshots used only while a conflict is reviewed. */
    private val reviewRoot = File(
        this.context.noBackupFilesDir,
        OfficeConflictPreviewNaming.REVIEW_ROOT,
    )
    /** App-side implementation of the viewer's exact-token review channel. */
    private val conflictReview: OfficeConflictReviewCoordinator =
        OfficeConflictReviewCoordinator(reviewRoot, object : OfficeConflictReviewHost {
            override fun liveIdentity(sessionToken: String, generation: Long): OfficeConflictReviewIdentity? =
                conflictReviewIdentity(sessionToken, generation)

            override fun captureMine(
                identity: OfficeConflictReviewIdentity,
                directory: File,
            ): OfficeConflictVersion? = conflictMine(identity, directory)

            override fun captureCurrent(
                identity: OfficeConflictReviewIdentity,
                directory: File,
            ): OfficeConflictVersion? = conflictCurrent(identity, directory)

            override fun buildPreview(
                version: OfficeConflictVersion,
                directory: File,
                role: OfficeConflictPreviewRole,
                fileName: String,
                format: String,
                maxChars: Int,
            ): OfficeConflictPreviewBuild {
                // Path escape, symlink swap, byte swap and package identity
                // are re-proved against the retained record before a reader
                // opens the file. The working copy and original are never read.
                val owned = OfficeConflictArtifacts.ownedVersionFile(reviewRoot, directory, version)
                    ?: return OfficeConflictPreviewBuild.Refused("snapshotChanged")
                val read = OfficeConflictPreviewReader.read(
                    version = version.copy(file = owned),
                    format = format,
                    maxChars = maxChars,
                )
                if (read is OfficeConflictPreviewRead.Refused) {
                    return OfficeConflictPreviewBuild.Refused(read.code)
                }
                val ready = read as OfficeConflictPreviewRead.Ready
                val written = OfficeConflictArtifacts.writePreviewText(
                    root = reviewRoot,
                    directory = directory,
                    name = fileName,
                    text = ready.text,
                ) ?: return OfficeConflictPreviewBuild.Refused("previewStorageUnavailable")
                return OfficeConflictPreviewBuild.Ready(
                    sha256 = written.first,
                    bytes = written.second,
                    truncated = ready.truncated,
                )
            }

            override fun deleteReviewDirectory(directory: File) =
                OfficeConflictArtifacts.deleteReviewDirectory(reviewRoot, directory)
        })
    private val conflictReviewBinder: IBinder by lazy {
        OfficeConflictReviewChannel.parentBinder(conflictReview)
    }

    /**
     * Parent endpoint of the module's narrow manual-original-save
     * capability (OfficeSaveOriginalHandoffPolicy, OFC-SAVE-REOPEN): the
     * foreground viewer posts ONE verified working-copy notice here and the
     * App answers with a single bounded verdict. Same trust model as the
     * conflict-review channel: a same-UID, non-exported binder on THIS
     * non-exported launch Intent only; every transaction re-proves the exact
     * owned operation, the live owner and the engine generation. It grants
     * no file, provider or navigation authority by itself.
     */
    private val saveOriginalBinder: IBinder by lazy {
        OfficeSaveOriginalChannel.parentBinder(this::acceptSaveOriginalNotice)
    }

    /**
     * App-side orchestration of the manual workspace original save. Every
     * join is the EXISTING owned object (this controller for the operation
     * and its App-owned working copy; the trusted source-host native lane
     * for the CAS; the RuntimeHost-installed push port for the provider
     * journal). No parallel controller, no raw write path.
     */
    private val saveOriginalHost = OfficeSaveOriginalHost(
        commitPort = NativeOfficeOriginalCommitPort,
        operation = this::saveOriginalOperationFacts,
        verifyWorkingCopy = { file, notice ->
            OfficeSaveOriginalVerification.verify(file, workingRoot, notice)
        },
        workingCopyFile = { path -> File(path) },
    )

    /**
     * RuntimeHost-installed provider journal push (the EXISTING
     * [WorkspaceSourceHostController] headless lane, byte-reusing the Core
     * model path's pushOriginalViaHeadlessLane). Null until Main wiring.
     * The host invokes it AT MOST ONCE per explicit save action, awaited on
     * the handoff lane, and correlates its typed terminal into the final
     * verdict (synced vs source-pending vs source-conflict) — never
     * fire-and-forget. A document without a source binding (or an unwired
     * host) simply skips the push; the local commit answer is unaffected,
     * and a missing lane at call time is an honest source-pending verdict,
     * never evidence the external original updated.
     */
    @Volatile
    internal var saveOriginalPushPort: (suspend (OfficeOriginalPushRequest) -> WorkspaceSourceResult?)? = null

    /** One provider journal push over the existing headless lane, pre-bound
     *  to the exact owner facts and fence by [saveOriginalOperationFacts]. */
    internal data class OfficeOriginalPushRequest(
        val taskID: String,
        val workspaceID: String,
        val nativeEpoch: Long,
        val hostGeneration: Long,
        val logicalPath: String,
        val ownerFence: () -> Boolean,
    )

    private val lock = Any()
    private var sequence = 0L
    private var active: Operation? = null

    init {
        recoveryJournal = OfficeRecoveryJournal(
            root = File(this.context.noBackupFilesDir, "floe-office-recovery"),
            // Bounded retention is performed by OfficeRecoveryController
            // BEFORE an add, outside the journal lock; the journal itself never
            // reaches into viewer/handoff locks.
            canEvict = { false },
            onEvict = { evicted ->
                scope.launch(Dispatchers.IO) { recoveryArtifacts.deleteOwned(evicted) }
            },
        )
        saveCopy = OfficeSaveCopyHost(this.context, scope, recoveryJournal)
        recovery = OfficeRecoveryController(
            scope = scope,
            journal = recoveryJournal,
            artifacts = recoveryArtifacts,
            exportPort = saveCopy,
            openPort = object : OfficeRecoveryOpenPort {
                override fun open(
                    candidate: OfficeRecoveryCandidate,
                    observedSha256: String,
                    observedBytes: Long,
                ): OfficeRecoveryOpenResult = openRecovered(candidate, observedSha256, observedBytes)

                override fun activeCandidateId(): String? = activeRecoveryCandidateId()

                override fun probeOriginal(candidate: OfficeRecoveryCandidate): OfficeRecoveryOriginalState =
                    probeRecoveryOriginal(candidate)
            },
            restoredOpenPort = object : OfficeRestoredDocumentOpenPort {
                override fun open(
                    document: OfficeRestoredDocument,
                    path: File,
                    observedSha256: String,
                    observedBytes: Long,
                ): OfficeRestoredOpenResult = openRestoredReadOnly(
                    document, path, observedSha256, observedBytes)
            },
        )
        saveCopy.setSessionQuiescentListener { token -> recovery.onSessionQuiescent(token) }
        // Review snapshots are temporary, App-owned copies only. A previous
        // process can leave them behind (a crash or a viewer that outlived
        // the App process); no live review can exist before this controller
        // is constructed. Delete only this dedicated root, never working or
        // recovery bytes.
        scope.launch(Dispatchers.IO) {
            reviewRoot.listFiles()?.forEach { child ->
                if (child.isDirectory && child.name.startsWith("review-")) {
                    OfficeConflictArtifacts.deleteReviewDirectory(reviewRoot, child)
                }
            }
        }
    }

    /**
     * Parent endpoint of the module's narrow close-intent capability
     * (OfficeCloseAckPolicy). The engine process calls it SYNCHRONOUSLY to
     * acknowledge one exact current user close BEFORE posting the native
     * BYE whose process exit (std::_exit(0)) bypasses every Java
     * Activity-result path in the viewer process. Acknowledgement records
     * close ownership only: it never marks closedCleanly and never deletes
     * the retained staged snapshot. The record is consumed either by the
     * real Activity result or by the bounded retirement armed on a
     * successful accept (and dropped when the operation settles or is
     * replaced).
     */
    private val closeAckBinder: IBinder by lazy { OfficeCloseAck.parentBinder(this::acceptCloseIntent) }

    /**
     * Parent endpoint of the module's narrow approval-notice capability
     * (OfficeApprovalNoticePolicy, G05-R3 office-approval107): the FOREGROUND
     * viewer polls it (read-only, only while resumed) to learn whether its
     * OWNING conversation currently holds a captured pending approval, so an
     * Ask-first approval stays reviewable WITHOUT closing the owned document
     * (the close route correctly retires the context and the operation then
     * fails stale — device evidence c16 calc-close-context-refusal).
     * Carried ONLY inside the non-exported viewer Activity's own launch
     * Intent, for OWNED opens only. The endpoint answers nothing about any
     * other conversation or operation, and the banner action it feeds never
     * approves, cancels or replays anything — review always happens in the
     * existing conversation approval card.
     */
    private val approvalNoticeBinder: IBinder by lazy { OfficeApprovalNotice.parentBinder(this::answerApprovalNotice) }

    /** lock-protected: the acknowledged close for the current operation. */
    private var ackedClose: OfficeCloseAckPolicy.AckRequest? = null
    /** lock-protected: the single bounded acknowledged-close retirement job.
     * Only the current operation's exact recorded ack may replace it (see
     * [armAckQuiescenceLocked]); a stale accepted close never touches it,
     * and every settle cancels it. */
    private var ackQuiescence: Job? = null
    val pickerNamespace = PlatformLaunchOwnership.mintNamespace()
    val viewerNamespace = PlatformLaunchOwnership.mintNamespace()

    data class ViewerLaunch(val incarnation: Long, val request: OfficePreviewRequest)
    /** Bounded App-owned return identity (G05-R3 office-return109): the
     * EXACT live VIEWING mount — owner conversation, opaque viewer
     * incarnation and session token — published ONLY at the real claim in
     * [claimViewer] and cleared automatically by every State reset
     * (picker/staging/cancel/settle/replacement). This is a navigation
     * record, not a permission: it grants nothing, decides nothing and
     * never bypasses an existing ownership/stale-context guard. */
    data class OwnedViewerReturn(
        val ownerTaskId: String,
        val viewerIncarnation: Long,
        val sessionToken: String,
    )
    data class State(val picker: Long? = null, val viewer: ViewerLaunch? = null,
                     val staging: Boolean = false, val cancelling: Boolean = false,
                     val error: String? = null,
                     val ownedReturn: OwnedViewerReturn? = null)
    private val mutableState = MutableStateFlow(State())
    val state: StateFlow<State> = mutableState
    /** Original failure retained in RAM for explicit diagnostics, never
     * interpolated into ordinary UI copy or automatic logs. */
    @Volatile var diagnosticFailure: Any? = null
        private set

    private enum class Phase { PICKING, STAGING, LAUNCH, VIEWING }
    private class AiLaunchAdmission(val owner: Any, val allows: (String?) -> Boolean)
    private var aiLaunchAdmission: AiLaunchAdmission? = null

    internal fun setAiLaunchAdmission(owner: Any, allows: (String?) -> Boolean) = synchronized(lock) {
        aiLaunchAdmission = AiLaunchAdmission(owner, allows)
    }

    internal fun clearAiLaunchAdmission(owner: Any) = synchronized(lock) {
        if (aiLaunchAdmission?.owner === owner) aiLaunchAdmission = null
    }

    /** Host-owned read-only pending-approval lookup the notice endpoint may
     *  consult (installed by the App wiring; owner-tagged like
     *  [AiLaunchAdmission]). Returns the pending tool name for the owning
     *  conversation, or null. The lookup is the ONLY source of the banner
     *  answer: this controller never invents one. */
    private class ApprovalNoticeLookup(val owner: Any, val pendingToolName: (String) -> String?)
    private var approvalNoticeLookup: ApprovalNoticeLookup? = null

    internal fun setApprovalNoticeLookup(owner: Any, pendingToolName: (String) -> String?) = synchronized(lock) {
        approvalNoticeLookup = ApprovalNoticeLookup(owner, pendingToolName)
    }

    internal fun clearApprovalNoticeLookup(owner: Any) = synchronized(lock) {
        if (approvalNoticeLookup?.owner === owner) approvalNoticeLookup = null
    }

    private class Operation(
        val id: Long,
        var phase: Phase,
        val ownerCurrent: () -> Boolean,
        /** Owner facts captured at open time (Main host20 admission): set
         * ONLY by the workspace route so the Office AI lane's owner-checked
         * retirement can match THIS operation and never another surface's. */
        val ownerTaskId: String? = null,
        val ownerWorkspaceId: String? = null,
        val ownerNativeEpoch: String? = null,
        val requiresAiLaunchAdmission: Boolean = false,
    ) {
        @Volatile var retired = false
        @Volatile var input: File? = null
        @Volatile var sessionToken: String? = null
        @Volatile var providerIO: SafOperation<OfficeProviderSnapshotStager.Snapshot>? = null
        /** Immutable snapshot staged from the provider/workspace (EDIT routes). */
        @Volatile var snapshot: File? = null
        /** Verified digest/size of the staged immutable snapshot (from the
         * REAL staging result, never a claim). */
        @Volatile var snapshotSha256: String? = null
        @Volatile var snapshotBytes: Long = -1L
        /** Owned mutable working copy handed to the engine (EDIT routes). */
        @Volatile var workingCopy: File? = null
        /** Verified digest/size of the ACTUAL editable working copy. */
        @Volatile var workingCopySha256: String? = null
        @Volatile var workingCopyBytes: Long = -1L
        /** True once the route staged an EDIT working copy for this operation. */
        @Volatile var editable = false
        /** Provider same-original refusal facts from the source snapshot (null for workspace docs). */
        @Volatile var saveOriginal: OfficeSaveCopyOriginal? = null
        /** Set exactly once by settle: fences late Save-Copy/owner-alive reads. */
        @Volatile var viewEnded = false
        /** CURRENT authoritative baseline for the workspace original CAS: the
         *  open-time snapshot digest until a proven manual original save
         *  updates it to the committed bytes. Never mutated without the
         *  corresponding bytes/proof (the immutable open-time snapshot pair
         *  below stays untouched). Null when this route owns no workspace
         *  original (provider/run-output/recovery mounts stay copy-only). */
        @Volatile var originalBaselineSha256: String? = null
        @Volatile var originalBaselineBytes: Long = -1L
        /** Fences a second handoff while one original save is in flight. */
        @Volatile var saveOriginalInFlight = false
        /** Durable recovery candidate created before the editable mount. */
        @Volatile var recoveryCandidateId: String? = null
    }

    private fun current(op: Operation): Boolean = synchronized(lock) {
        active === op && !op.retired && op.ownerCurrent()
    }

    private fun admit(
        phase: Phase,
        owner: () -> Boolean,
        workspaceOwner: WorkspaceOfficeSnapshotStager.Owner? = null,
        requiresAiLaunchAdmission: Boolean = false,
    ): Operation? = synchronized(lock) {
        if (active != null || sequence == Long.MAX_VALUE) {
            mutableState.value = mutableState.value.copy(error = "busy")
            return null
        }
        diagnosticFailure = null
        ackedClose = null
        Operation(
            ++sequence, phase, owner,
            ownerTaskId = workspaceOwner?.taskID,
            ownerWorkspaceId = workspaceOwner?.workspaceID,
            ownerNativeEpoch = workspaceOwner?.let { it.nativeEpoch.toString() },
            requiresAiLaunchAdmission = requiresAiLaunchAdmission,
        ).also { active = it }
    }

    fun requestProviderPick() {
        val op = admit(Phase.PICKING, owner = { true }) ?: return
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
                        op.snapshotSha256 = snapshot.sha256
                        op.snapshotBytes = snapshot.bytes
                        op.input = snapshot.file
                        // Global Open Document is a local preview. Editing is
                        // an explicit external/workspace action; downloading a
                        // component must not create an interrupted edit draft.
                        if (!com.floe.android.host.officecomponent.OfficeComponentController.installed(context)) {
                            pendingProviderPreview.save(OfficePendingPreviewStore.Snapshot(
                                snapshot.file.canonicalPath, snapshot.sha256, snapshot.bytes, snapshot.displayName))
                        }
                        prepare(op, OfficePreviewRequest.of(
                            sessionToken = snapshot.sessionID, stagedFilePath = snapshot.file.canonicalPath,
                            sha256 = snapshot.sha256, lengthBytes = snapshot.bytes,
                            displayName = snapshot.displayName,
                            languageTag = languageTag(),
                            permission = OfficePermission.READ_ONLY,
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

    /** Main-shell foreground continuation after split installation killed the
     * old process. Restores only a re-hashed private READ_ONLY provider copy;
     * old task/URI/write authority is never inferred from saved metadata. */
    fun restoreComponentPreview() {
        if (!pendingPreviewRestored.compareAndSet(false, true) || isBusy) return
        scope.launch(Dispatchers.IO) {
            var admitted: Operation? = null
            try {
                val saved = pendingProviderPreview.load() ?: return@launch
                val op = synchronized(lock) {
                    if (active != null) null else admit(Phase.STAGING, owner = { true })
                } ?: return@launch
                admitted = op
                op.input = File(saved.path)
                op.snapshot = op.input
                op.snapshotSha256 = saved.sha256
                op.snapshotBytes = saved.bytes
                prepare(op, OfficePreviewRequest.of(
                    sessionToken = UUID.randomUUID().toString(), stagedFilePath = saved.path,
                    sha256 = saved.sha256, lengthBytes = saved.bytes, displayName = saved.displayName,
                    languageTag = languageTag(), permission = OfficePermission.READ_ONLY))
            } catch (failure: Exception) {
                diagnosticFailure = failure
                val op = admitted
                if (op != null) settle(op, "source", removeInput = false)
                else synchronized(lock) { if (active == null) mutableState.value = State(error = "source") }
            }
        }
    }

    /** Retire only the exact pending OPEN after Android accepted its launch.
     * This is navigation bookkeeping, never a rendering or save receipt. */
    fun viewerLaunchAccepted(incarnation: Long) {
        val op = synchronized(lock) {
            active?.takeIf { it.id == incarnation && it.phase == Phase.VIEWING && !it.editable }
        } ?: return
        val path = op.input?.canonicalPath ?: return
        val sha = op.snapshotSha256 ?: return
        scope.launch(Dispatchers.IO) {
            runCatching { pendingProviderPreview.clearMatching(path, sha, op.snapshotBytes) }
                .onFailure { diagnosticFailure = it }
        }
    }

    fun openWorkspace(owner: WorkspaceOfficeSnapshotStager.Owner, path: String, ownerCurrent: () -> Boolean) =
        openWorkspace(owner, path, ownerCurrent, requiresAiLaunchAdmission = false)

    internal fun openWorkspaceForAi(owner: WorkspaceOfficeSnapshotStager.Owner, path: String, ownerCurrent: () -> Boolean) =
        openWorkspace(owner, path, ownerCurrent, requiresAiLaunchAdmission = true)

    private fun openWorkspace(owner: WorkspaceOfficeSnapshotStager.Owner, path: String, ownerCurrent: () -> Boolean,
                              requiresAiLaunchAdmission: Boolean) {
        val op = admit(Phase.STAGING, ownerCurrent, owner, requiresAiLaunchAdmission) ?: return
        mutableState.value = State(staging = true)
        scope.launch(Dispatchers.IO) {
            try {
                val snapshot = workspace.stage(owner, path) { current(op) }
                op.snapshot = snapshot.file
                op.snapshotSha256 = snapshot.sha256
                op.snapshotBytes = snapshot.bytes
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
                op.workingCopySha256 = copy.sha256
                op.workingCopyBytes = copy.bytes
                op.input = copy.file
                op.editable = true
                // The workspace route owns the original: the open-time
                // snapshot digest is the FIRST CAS baseline. A proven manual
                // original save advances it; nothing else may.
                op.originalBaselineSha256 = snapshot.sha256
                op.originalBaselineBytes = snapshot.bytes
                val candidateId = recordRecoveryCandidate(
                    op = op,
                    route = OfficeRecoveryRoute.WORKSPACE,
                    displayName = path.substringAfterLast('/'),
                    snapshotSha256 = snapshot.sha256,
                    snapshotBytes = snapshot.bytes,
                    copy = copy,
                    original = null,
                    ownerTaskId = owner.taskID,
                    workspaceId = owner.workspaceID,
                    nativeEpoch = owner.nativeEpoch.toString(),
                    hostGeneration = owner.hostGeneration.toString(),
                    sourceLogicalPath = snapshot.logicalPath,
                    sourceId = snapshot.sourceID,
                    sourceRevision = snapshot.sourceRevision,
                )
                if (candidateId == null) {
                    discardUnjournaledWorkingCopy(copy)
                    settle(op, "recovery")
                    return@launch
                }
                op.recoveryCandidateId = candidateId
                if (!com.floe.android.host.officecomponent.OfficeComponentController.installed(context) && current(op)) {
                    (context.applicationContext as? FloeApplication)?.componentDocumentReturns?.prepare(
                        "officepreview", owner.taskID, owner.workspaceID, path)
                }
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

    /** Open ONE exact owned run output (sealed receipt of a completed tool
     * call) through the EXISTING Office preview path. The native lane
     * re-derives the receipt from the run's own durable toolResult record,
     * holds a generation lease across the streamed copy, and verifies the
     * full snapshot digest before any byte is staged; this controller then
     * mirrors the workspace route's R2 discipline: an immutable App-staged
     * snapshot feeds a separately owned MUTABLE working copy, and the
     * run-output ORIGINAL stays immutable and copy-only (no original
     * overwrite exists in this slice). `workspaceId` and `sourceRevision`
     * are absent (null) — a run output is not a workspace document and a
     * content digest is never laundered into an opaque CAS revision; the
     * true identity fields (conversation, run, sealed outputID, epoch,
     * generation, canonical relative path) are carried verbatim. */
    fun openRunOutput(owner: RunOutputOfficeSnapshotStager.Owner, ownerCurrent: () -> Boolean) {
        val op = admit(Phase.STAGING, ownerCurrent) ?: return
        mutableState.value = State(staging = true)
        scope.launch(Dispatchers.IO) {
            try {
                val snapshot = runOutputs.stage(owner) { current(op) }
                op.snapshot = snapshot.file
                op.snapshotSha256 = snapshot.sha256
                op.snapshotBytes = snapshot.bytes
                op.input = snapshot.file
                val copy = working.stage(
                    source = snapshot.file, sourceBytes = snapshot.bytes,
                    sourceSha256 = snapshot.sha256, extension = snapshot.file.extension,
                    isCurrent = { current(op) },
                )
                op.workingCopy = copy.file
                op.workingCopySha256 = copy.sha256
                op.workingCopyBytes = copy.bytes
                op.input = copy.file
                op.editable = true
                val candidateId = recordRecoveryCandidate(
                    op = op,
                    route = OfficeRecoveryRoute.RUN_OUTPUT,
                    displayName = snapshot.displayName,
                    snapshotSha256 = snapshot.sha256,
                    snapshotBytes = snapshot.bytes,
                    copy = copy,
                    original = null,
                    ownerTaskId = owner.conversationID,
                    nativeEpoch = owner.nativeEpoch.toString(),
                    hostGeneration = owner.hostGeneration.toString(),
                    sourceLogicalPath = snapshot.relativePath,
                    sourceId = snapshot.outputID,
                )
                if (candidateId == null) {
                    discardUnjournaledWorkingCopy(copy)
                    settle(op, "recovery")
                    return@launch
                }
                op.recoveryCandidateId = candidateId
                prepare(op, OfficePreviewRequest.of(
                    sessionToken = copy.sessionID, stagedFilePath = copy.file.canonicalPath,
                    sha256 = copy.sha256, lengthBytes = copy.bytes,
                    displayName = snapshot.displayName, languageTag = languageTag(),
                    permission = OfficePermission.EDIT,
                    ownerTaskId = owner.conversationID,
                    nativeEpoch = owner.nativeEpoch.toString(),
                    hostGeneration = owner.hostGeneration.toString(),
                    sourceLogicalPath = snapshot.relativePath,
                    sourceId = snapshot.outputID,
                ))
            } catch (error: Exception) {
                recordFailure(op, error); settle(op, stagingError(op, error))
            } catch (error: LinkageError) {
                recordFailure(op, error); settle(op, stagingError(op, error))
            }
        }
    }

    // ------------------------------------------------------------------
    // C08 durable recovery (working copy + verified outputs)
    // ------------------------------------------------------------------

    /**
     * Persist the App-owned working-copy identity BEFORE the module session
     * is opened. No picker, save transaction or user file is involved here.
     * Failure refuses the open (and removes only this attempt's own copy):
     * editing without a durable recoverability record is never silently
     * allowed.
     */
    private fun recordRecoveryCandidate(
        op: Operation,
        route: OfficeRecoveryRoute,
        displayName: String,
        snapshotSha256: String,
        snapshotBytes: Long,
        copy: OfficeEditableCopyStager.EditableCopy,
        original: OfficeSaveCopyOriginal?,
        ownerTaskId: String? = null,
        workspaceId: String? = null,
        nativeEpoch: String? = null,
        hostGeneration: String? = null,
        sourceLogicalPath: String? = null,
        sourceId: String? = null,
        sourceRevision: String? = null,
    ): String? {
        val now = System.currentTimeMillis()
        val safeName = displayName
            .substringAfterLast('/')
            .substringAfterLast('\\')
            .filter { it.code >= 0x20 && it.code != 0x7f }
            .trim()
            .take(240)
            .ifBlank { "document.${copy.extension}" }
        val candidate = OfficeRecoveryCandidate(
            id = UUID.randomUUID().toString(),
            createdAtMillis = now,
            updatedAtMillis = now,
            phase = OfficeRecoveryPhase.EDITING,
            route = route,
            displayName = safeName,
            format = copy.extension,
            ownerTaskId = ownerTaskId,
            workspaceId = workspaceId,
            nativeEpoch = nativeEpoch,
            hostGeneration = hostGeneration,
            sourceLogicalPath = sourceLogicalPath,
            sourceId = sourceId,
            sourceRevision = sourceRevision,
            originalUri = original?.uri?.uriString,
            originalDocumentId = original?.documentId,
            sourceSha256 = snapshotSha256,
            sourceBytes = snapshotBytes,
            workingCopyPath = runCatching { copy.file.canonicalPath }.getOrElse { copy.file.path },
            workingCopyBaseSha256 = copy.sha256,
            workingCopyBaseBytes = copy.bytes,
            originSessionToken = copy.sessionID,
        )
        return try {
            recovery.reclaimCapacity()
            recoveryJournal.add(candidate).id
        } catch (failure: Exception) {
            recordFailure(op, failure)
            if (failure is OfficeRecoveryJournal.Full) {
                // Make the bounded-ledger refusal actionable: the user can
                // review/discard old records, then open the document again.
                recovery.show()
            }
            null
        }
    }

    /** Remove ONLY this attempt's never-exposed working-copy directory. */
    private fun discardUnjournaledWorkingCopy(copy: OfficeEditableCopyStager.EditableCopy) {
        runCatching {
            val root = workingRoot.canonicalFile
            val parent = copy.file.parentFile?.canonicalFile ?: return
            if (parent.parentFile?.path != root.path) return
            copy.file.delete()
            parent.delete()
        }
    }

    /**
     * Open the EXACT retained working copy in the existing Office viewer.
     * The recovery record supplies no owner/task/workspace claim: the new
     * mount is an unowned editable copy, so recovery metadata can never join
     * the AI lane or authorize a workspace/provider write.
     */
    private fun openRecovered(
        candidate: OfficeRecoveryCandidate,
        observedSha256: String,
        observedBytes: Long,
    ): OfficeRecoveryOpenResult {
        if (candidate.phase == OfficeRecoveryPhase.DISCARDED) {
            return OfficeRecoveryOpenResult.Refused("discarded")
        }
        val op = admit(Phase.LAUNCH, owner = { true })
            ?: return OfficeRecoveryOpenResult.Refused("busy")
        op.recoveryCandidateId = candidate.id
        op.workingCopy = File(candidate.workingCopyPath)
        op.workingCopySha256 = observedSha256
        op.workingCopyBytes = observedBytes
        // The recovery candidate preserves the ORIGINAL source identity,
        // not the working-copy digest. Conflict review must compare the live
        // original against this base, never against the mutable copy.
        op.snapshotSha256 = candidate.sourceSha256
        op.snapshotBytes = candidate.sourceBytes
        op.input = op.workingCopy
        op.editable = true
        op.saveOriginal = candidate.originalUri?.let { uri ->
            runCatching { OfficeSaveCopyOriginal(SafUriRef(uri), candidate.originalDocumentId) }.getOrNull()
        }
        val request = OfficePreviewRequest.of(
            sessionToken = UUID.randomUUID().toString(),
            stagedFilePath = candidate.workingCopyPath,
            sha256 = observedSha256,
            lengthBytes = observedBytes,
            displayName = candidate.displayName,
            languageTag = languageTag(),
            permission = OfficePermission.EDIT,
        ).getOrNull()
        if (request == null) {
            settle(op, "format")
            return OfficeRecoveryOpenResult.Refused("format")
        }
        op.sessionToken = request.sessionToken
        val alive = { !op.retired && !op.viewEnded }
        if (!saveCopy.beginEditSession(
                request.sessionToken,
                request.displayName,
                op.saveOriginal,
                candidate.id,
                alive,
            )
        ) {
            recordFailure(op, saveCopy.lastDiagnostic() ?: "recovery session unavailable")
            settle(op, "recovery")
            return OfficeRecoveryOpenResult.Refused("session")
        }
        synchronized(lock) {
            if (!current(op)) {
                settle(op, null)
                return OfficeRecoveryOpenResult.Refused("stale")
            }
            op.phase = Phase.LAUNCH
            mutableState.value = State(viewer = ViewerLaunch(op.id, request))
        }
        runCatching { recoveryJournal.touchSessionToken(candidate.id, request.sessionToken) }
            .onFailure { diagnosticFailure = it }
        return OfficeRecoveryOpenResult.Accepted(request.sessionToken)
    }

    /**
     * C08 read-only preview for a fresh restored document. The file is
     * re-validated against the ONE App-owned restored root and the digest
     * supplied by the data-exchange controller before admission. No recovery
     * journal record, save session, owner/task claim or provider/workspace
     * write is created: this is a local read-only mount.
     */
    private fun openRestoredReadOnly(
        document: OfficeRestoredDocument,
        path: File,
        observedSha256: String,
        observedBytes: Long,
    ): OfficeRestoredOpenResult {
        val root = runCatching { restoredDocumentsRoot.canonicalFile }.getOrNull()
            ?: return OfficeRestoredOpenResult.Refused("storage")
        val canonical = runCatching { path.canonicalFile }.getOrNull()
            ?: return OfficeRestoredOpenResult.Refused("storage")
        if (!canonical.path.startsWith(root.path + File.separator) ||
            Files.isSymbolicLink(canonical.toPath()) || !canonical.isFile ||
            canonical.length() != observedBytes
        ) {
            return OfficeRestoredOpenResult.Refused("unsafe")
        }
        val op = admit(Phase.LAUNCH, owner = { true })
            ?: return OfficeRestoredOpenResult.Refused("busy")
        op.input = canonical
        op.snapshotSha256 = observedSha256
        op.snapshotBytes = observedBytes
        op.editable = false
        val request = OfficePreviewRequest.of(
            sessionToken = UUID.randomUUID().toString(),
            stagedFilePath = canonical.path,
            sha256 = observedSha256,
            lengthBytes = observedBytes,
            displayName = document.displayName,
            languageTag = languageTag(),
            permission = OfficePermission.READ_ONLY,
        ).getOrNull()
        if (request == null) {
            settle(op, "format")
            return OfficeRestoredOpenResult.Refused("format")
        }
        op.sessionToken = request.sessionToken
        synchronized(lock) {
            if (!current(op)) {
                settle(op, null)
                return OfficeRestoredOpenResult.Refused("stale")
            }
            op.phase = Phase.LAUNCH
            mutableState.value = State(viewer = ViewerLaunch(op.id, request))
        }
        return OfficeRestoredOpenResult.Accepted(request.sessionToken)
    }

    private fun activeRecoveryCandidateId(): String? = synchronized(lock) {
        active?.takeIf { !it.retired && !it.viewEnded }?.recoveryCandidateId
    }

    /**
     * Explicit original probe. Provider reads under the existing live grant;
     * workspace re-reads through the EXISTING native egress authority and
     * compares the verified digest. Neither grants, writes nor overwrites.
     */
    private fun probeRecoveryOriginal(candidate: OfficeRecoveryCandidate): OfficeRecoveryOriginalState {
        return when (candidate.route) {
            OfficeRecoveryRoute.PROVIDER -> candidate.originalUri?.let { uri ->
                saveCopy.probeOriginal(uri, candidate.sourceSha256, candidate.sourceBytes)
            } ?: OfficeRecoveryOriginalState.UNAVAILABLE
            OfficeRecoveryRoute.WORKSPACE -> probeWorkspaceOriginal(candidate)
            OfficeRecoveryRoute.RUN_OUTPUT -> OfficeRecoveryOriginalState.NOT_APPLICABLE
        }
    }

    private fun probeWorkspaceOriginal(candidate: OfficeRecoveryCandidate): OfficeRecoveryOriginalState {
        val taskID = candidate.ownerTaskId ?: return OfficeRecoveryOriginalState.UNAVAILABLE
        val workspaceID = candidate.workspaceId ?: return OfficeRecoveryOriginalState.UNAVAILABLE
        val epoch = candidate.nativeEpoch?.toLongOrNull() ?: return OfficeRecoveryOriginalState.UNAVAILABLE
        val generation = candidate.hostGeneration?.toLongOrNull()
            ?: return OfficeRecoveryOriginalState.UNAVAILABLE
        val path = candidate.sourceLogicalPath ?: return OfficeRecoveryOriginalState.UNAVAILABLE
        val owner = try {
            WorkspaceOfficeSnapshotStager.Owner(taskID, workspaceID, epoch, generation)
        } catch (_: IllegalArgumentException) {
            return OfficeRecoveryOriginalState.UNAVAILABLE
        }
        return try {
            val snapshot = workspace.stage(owner, path) { true }
            val same = snapshot.sha256 == candidate.sourceSha256 && snapshot.bytes == candidate.sourceBytes
            removeOwnUnreferencedInput(snapshot.file)
            if (same) OfficeRecoveryOriginalState.UNCHANGED else OfficeRecoveryOriginalState.CHANGED
        } catch (_: Exception) {
            OfficeRecoveryOriginalState.UNAVAILABLE
        } catch (_: LinkageError) {
            OfficeRecoveryOriginalState.UNAVAILABLE
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
            if (!saveCopy.beginEditSession(
                    request.sessionToken,
                    request.displayName,
                    op.saveOriginal,
                    op.recoveryCandidateId,
                    alive,
                )
            ) {
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
     * Stale owners, replacements and internal teardowns are rejected.
     * The record is consumed either by the later real Activity result or,
     * because the fatal native BYE can make that result never arrive, by
     * the bounded retirement armed here — never by the acknowledgement
     * alone and never with a clean-close claim. Recording and arming happen
     * in ONE lock pass, so no settle or replacement can interleave between
     * them; a duplicate acknowledgement re-arms the same operation (the
     * single job slot is replaced by its own exact owner — idempotent).
     */
    private fun acceptCloseIntent(ack: OfficeCloseAckPolicy.AckRequest): Boolean = synchronized(lock) {
        val current = active?.takeIf { !it.retired }
        android.util.Log.d("OfficeCloseAck", "parent owner active=${current != null} viewing=${current?.phase == Phase.VIEWING} incarnationMatch=${current?.id == ack.viewerIncarnation} tokenMatch=${current?.sessionToken == ack.sessionToken}")
        if (current == null) return false
        if (current.id != ack.viewerIncarnation || current.phase != Phase.VIEWING || current.sessionToken != ack.sessionToken) {
            return false
        }
        ackedClose = ack
        armAckQuiescenceLocked(current)
        true
    }

    /**
     * Answers ONE engine approval-notice query on a Binder thread: ONLY the
     * current, un-retired VIEWING operation whose opaque viewer incarnation,
     * session token AND owner task id all match exactly may be answered
     * ([approvalNoticeAdmissible]; shape/interface/UID were already enforced
     * fail-closed by the endpoint). A stale, settled, replaced or non-owned
     * operation — and any query naming another owner — answers null, so the
     * banner can never be raised for a closed document or another
     * conversation. The pending answer itself comes ONLY from the installed
     * host lookup (read-only, runCatching): this controller never invents
     * approvals and never touches the approval resolve path.
     */
    private fun answerApprovalNotice(query: OfficeApprovalNoticePolicy.Query): String? = synchronized(lock) {
        val current = active?.takeIf { !it.retired } ?: return null
        if (!approvalNoticeAdmissible(
                retired = current.retired,
                viewEnded = current.viewEnded,
                phaseViewing = current.phase == Phase.VIEWING,
                candidateIncarnation = current.id,
                candidateSessionToken = current.sessionToken,
                candidateOwnerTaskId = current.ownerTaskId,
                queryIncarnation = query.viewerIncarnation,
                queryToken = query.sessionToken,
                queryOwnerTaskId = query.ownerTaskId,
            )
        ) {
            return null
        }
        val lookup = approvalNoticeLookup ?: return null
        runCatching { lookup.pendingToolName(query.ownerTaskId) }.getOrNull()
    }

    /**
     * Arms (or re-arms, for a duplicate ack of the same operation) the
     * bounded retirement for ONE exact recorded close-intent. Callers must
     * hold [lock]. Before cancelling or replacing the single global job,
     * revalidate under that same lock that the candidate is STILL the
     * current, un-retired, not-view-ended, VIEWING operation with its exact
     * acknowledgement recorded: a stale accepted close whose operation has
     * already settled or been replaced must never cancel a NEWER operation's
     * armed job — the global slot would keep only the stale expiry no-op
     * and the new close could wedge until process death. The bound is
     * deliberately short and honest: the acknowledgement already delegated
     * the close to the engine, the module serializes a rapid reopen against
     * the old native close, and a platform RESULT_CANCELED that ever did
     * arrive converges to the identical OWNED_CLOSE_UNCERTAIN resolution
     * applied by onViewerResult for a missing result. The delay only needs
     * to exceed the ordinary result delivery latency so the real-result
     * path wins the race whenever delivery exists.
     */
    private fun armAckQuiescenceLocked(op: Operation) {
        if (!ackedCloseStillOwnsSlot(
                activeIsCandidate = active === op,
                retired = op.retired,
                viewEnded = op.viewEnded,
                phaseViewing = op.phase == Phase.VIEWING,
                candidateIncarnation = op.id,
                candidateSessionToken = op.sessionToken,
                ack = ackedClose,
            )
        ) {
            return
        }
        ackQuiescence?.cancel()
        ackQuiescence = scope.launch {
            delay(ACKED_CLOSE_RETIREMENT_MS)
            settleAcknowledgedCloseIfUnclaimed(op)
        }
    }

    /**
     * Bounded-retirement expiry: retire THIS exact operation through the
     * same [OfficeCloseAckPolicy.resolveViewerResult] decision a
     * missing-result onViewerResult applies — honest uncertainty (no error
     * report, never closedCleanly, staged inputs and working copy
     * retained, Save-Copy session closed by the ordinary settle drain). The
     * expiry does NOT claim the engine or its IO quiesced; the engine
     * acknowledged this exact user close and only the admission slot is
     * released. Re-validates the same full identity fence under the lock
     * first, so a settled, replaced or superseded operation — and any
     * acknowledgement recorded for another incarnation/token — is never
     * touched.
     */
    private fun settleAcknowledgedCloseIfUnclaimed(op: Operation) {
        val acked = synchronized(lock) {
            ackedCloseStillOwnsSlot(
                activeIsCandidate = active === op,
                retired = op.retired,
                viewEnded = op.viewEnded,
                phaseViewing = op.phase == Phase.VIEWING,
                candidateIncarnation = op.id,
                candidateSessionToken = op.sessionToken,
                ack = ackedClose,
            )
        }
        if (!acked) return
        val resolution = OfficeCloseAckPolicy.resolveViewerResult(
            ownerCurrent = op.ownerCurrent(),
            outcomePresent = false,
            exactToken = false,
            failureName = null,
            closedCleanly = false,
            ackedUserClose = true,
        )
        if (!settle(op, resolution.errorKey, removeInput = resolution.removeInput)) return
        // The engine acknowledged the exact user close but its native exit
        // bypassed the Activity result. Reconcile the durable record now so a
        // post-save working copy with later bytes is not left certified by the
        // earlier destination merely because no result arrived.
        recovery.onViewerClosed(
            candidateId = op.recoveryCandidateId,
            sessionToken = op.sessionToken,
            resultPresent = false,
            closedCleanly = false,
            dirtyAtClose = false,
            discarded = false,
            outputDescriptors = emptyList(),
        )
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
        // This runs on the launcher's UI thread. Read the shell's LIVE
        // state immediately before the VIEWING flip, with no suspension or
        // event-loop turn before launcher.launch; polling is not authority.
        if (op.requiresAiLaunchAdmission && !runCatching {
                aiLaunchAdmission?.allows?.invoke(op.ownerTaskId) == true
            }.getOrDefault(false)) {
            settle(op, "owner")
            return null
        }
        val request = mutableState.value.viewer?.request ?: return null
        op.phase = Phase.VIEWING
        // G05-R3 office-return109: publish the bounded return identity for the
        // OWNING conversation's explicit "Back to document" strip — ONLY here,
        // at the real VIEWING claim, and ONLY while the published request
        // still names this exact operation's session token. Every State reset
        // (picker/staging/cancel/settle/replacement) clears it by
        // construction; the provider-pick route (ownerTaskId null) never has
        // one. Navigation record only: grants nothing, decides nothing.
        val returnOwner = op.ownerTaskId
        mutableState.value = mutableState.value.copy(
            ownedReturn = if (returnOwner != null && request.sessionToken == op.sessionToken) {
                OwnedViewerReturn(returnOwner, op.id, request.sessionToken)
            } else null,
        )
        // The approval-notice capability + review target attach ONLY to OWNED
        // opens (an owning conversation exists to ask about) and ONLY while a
        // lookup is installed. Both are inert references on this non-exported
        // launch Intent; the module can display the banner and raise the chat,
        // but the answer itself is always re-validated here per query.
        val ownedNotice = op.ownerTaskId != null && approvalNoticeLookup != null
        // Manual original save: ONLY the exact owned workspace EDIT mount
        // with full owner facts receives the capability; every other route
        // stays copy-only and never sees the button.
        val saveOriginalCapable = saveOriginalRouteAuthority(op, request)
        val intent = OfficeEngine.viewerIntent(
            context, request, closeAckBinder, op.id,
            hostSaveChannel = if (op.editable) saveCopy.channel else null,
            approvalNotice = if (ownedNotice) approvalNoticeBinder else null,
            reviewComponent = if (ownedNotice) ComponentName(context, MainActivity::class.java) else null,
            saveOriginalChannel = if (saveOriginalCapable) saveOriginalBinder else null,
        )
        // C08 revision/conflict review capability: a same-UID, non-exported
        // binder on THIS non-exported launch Intent only. It answers observed
        // version facts and admits deliberate decisions; it grants no file or
        // provider write authority. A read-only mount never receives it.
        if (op.editable) {
            val capabilities = Bundle()
            capabilities.putBinder(OfficeConflictReviewChannel.EXTRA_REVIEW_CHANNEL, conflictReviewBinder)
            intent.putExtras(capabilities)
        }
        intent
    }

    /**
     * Explicit owned-document return (G05-R3 office-return109). Raises the
     * SAME already-running viewer Activity named by [target] — no new launch
     * request, no close, no recreation, no second viewer, no approval-service
     * change: review stays on the ordinary conversation card and the
     * document/editContext stay alive underneath.
     *
     * How the concrete instance is guaranteed, honestly:
     *  1. The full identity fence — the established [current(op)] shape
     *     ([op.ownerCurrent] included, matching IDs alone never prove the
     *     current owner) — is decided by the single production predicate
     *     [viewerRestoreAdmissible] (same shape as the established
     *     [approvalNoticeAdmissible] plus the published-request leg).
     *  2. The raise's ACTUAL startActivity dispatch runs INSIDE this same
     *     controller lock. Per the real ActivityStarter behavior (Main
     *     platform check 2026-10-28), REORDER_TO_FRONT selects the concrete
     *     ActivityRecord synchronously during startActivity handling, so no
     *     settle, cancel or new-Operation admission — every one of which
     *     funnels through this same lock — can interleave between the exact-
     *     identity proof and Android's record selection. This is dispatch
     *     linearization, NOT a promise about all later lifecycle events.
     *  3. If the captured instance is already gone at selection (its own
     *     finish/close runs outside this lock, by existing design), the
     *     module's launch validation fails the inert no-request raise closed
     *     immediately (missing-request finish) — never a remount, never a
     *     different document presented as a return. Documented residual:
     *     lifecycle AFTER dispatch proceeds on the ordinary paths (a close
     *     that begins right after the raise is still honored).
     * A stop, close, settle, replacement or superseded mount therefore makes
     * an already-visible stale strip's click either refuse under the fence
     * (false) or fail closed inertly — never a state change, replay or grant.
     *
     * Lock/IPC note: startActivity while holding the lock adds only one
     * synchronous in-app binder dispatch; no lock holder ever blocks on the
     * viewer's main thread, and every other consumer of this lock is
     * in-process.
     */
    fun requestOwnedViewerRestore(target: OwnedViewerReturn): Boolean = synchronized(lock) {
        val op = active
        if (op == null) false
        else if (!viewerRestoreAdmissible(
                retired = op.retired,
                viewEnded = op.viewEnded,
                phaseViewing = op.phase == Phase.VIEWING,
                ownerCurrent = op.ownerCurrent(),
                candidateIncarnation = op.id,
                candidateSessionToken = op.sessionToken,
                candidateOwnerTaskId = op.ownerTaskId,
                publishedRequestMatches = mutableState.value.viewer?.request?.let {
                    it.sessionToken == op.sessionToken &&
                        it.ownerTaskId == op.ownerTaskId &&
                        it.sessionToken == target.sessionToken &&
                        it.ownerTaskId == target.ownerTaskId
                } == true,
                claimedIncarnation = target.viewerIncarnation,
                claimedSessionToken = target.sessionToken,
                claimedOwnerTaskId = target.ownerTaskId,
            )
        ) {
            false
        } else {
            runCatching {
                context.startActivity(OfficeEngine.viewerRestoreIntent(context))
            }.isSuccess
        }
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
        val settled = settle(op, resolution.errorKey, removeInput = resolution.removeInput)
        if (!settled) return
        // C08 reconcile AFTER the admission slot is released: the durable
        // journal learns the real close/discard facts and any OUTPUT_READY
        // descriptor the host channel missed. Nothing here reopens, retries or
        // deletes; the working copy and verified outputs are retained.
        val discarded = data?.getBooleanExtra(OfficePreviewActivity.EXTRA_USER_DISCARDED, false) == true
        recovery.onViewerClosed(
            candidateId = op.recoveryCandidateId,
            sessionToken = op.sessionToken,
            resultPresent = outcome != null,
            closedCleanly = outcome?.closedCleanly == true,
            dirtyAtClose = outcome?.dirtyAtClose == true,
            discarded = discarded,
            outputDescriptors = outcome?.saveReceiptDescriptors.orEmpty(),
        )
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
        } else {
            settle(op, null)
        }
        Unit
    }

    /** True while the single admission slot carries an operation (busy at
     * click time lets the conversation card refuse honestly BEFORE staging;
     * the authoritative check stays inside [admit]). */
    val isBusy: Boolean get() = synchronized(lock) { active != null }

    /**
     * READ-ONLY trusted lookup of the CURRENT owned open operation for a
     * later in-app consumer (e.g. the Main-coordinated Office AI producer) —
     * joins through this getter instead of writing a parallel controller.
     * Answered ONLY from the REAL `active` Operation + its published
     * request under the controller lock, and ONLY when:
     *   * the operation is live (not retired, not view-ended, LAUNCH or
     *     VIEWING — never a closing/closed operation);
     *   * the caller-supplied trusted owner facts match EXACTLY —
     *     ownerTaskId, workspaceId INCLUDING honest absence (the provider /
     *     run-output routes answer only a `null` workspaceId claim), and
     *     nativeEpoch; a model-claimed or "first document" owner can never
     *     resolve another operation.
     * Field honesty: `hostGeneration` is the App command-client generation
     * and `nativeEpoch` the App readback of the accepted root at open time;
     * the ENGINE's own native document generation is NOT claimed here and
     * must be read from the engine by the consumer. `sourceRevision` is the
     * opaque workspace CAS token (null for provider/run-output routes —
     * never fabricated); the snapshot/working-copy SHA-256 fields are the
     * content digests measured at staging — distinct identities, never
     * conflated. `stagedWorkingCopyPath` is the canonical path of the ACTUAL
     * editable working copy, present only when an editable route staged
     * one. This getter grants nothing: it never opens files, never extends
     * leases and authorizes no write.
     */
    data class OwnedOperationSnapshot(
        val sessionToken: String,
        val viewerIncarnation: Long,
        val hostGeneration: String?,
        val nativeEpoch: String?,
        val ownerTaskId: String?,
        val workspaceId: String?,
        val sourceLogicalPath: String?,
        val sourceId: String?,
        val sourceRevision: String?,
        val originalSnapshotSha256: String?,
        val originalSnapshotBytes: Long,
        val editable: Boolean,
        val stagedWorkingCopyPath: String?,
        val stagedWorkingCopySha256: String?,
        val stagedWorkingCopyBytes: Long,
    )

    fun ownedOperationSnapshot(
        ownerTaskId: String,
        workspaceId: String?,
        nativeEpoch: String,
    ): OwnedOperationSnapshot? = synchronized(lock) {
        val op = active ?: return null
        if (op.retired || op.viewEnded) return null
        if (op.phase != Phase.LAUNCH && op.phase != Phase.VIEWING) return null
        if (!op.ownerCurrent()) return null
        val request = mutableState.value.viewer?.request ?: return null
        if (request.sessionToken != op.sessionToken) return null
        if (request.ownerTaskId != ownerTaskId) return null
        if (request.workspaceId != workspaceId) return null
        if (request.nativeEpoch != nativeEpoch) return null
        OwnedOperationSnapshot(
            sessionToken = request.sessionToken,
            viewerIncarnation = op.id,
            hostGeneration = request.hostGeneration,
            nativeEpoch = request.nativeEpoch,
            ownerTaskId = request.ownerTaskId,
            workspaceId = request.workspaceId,
            sourceLogicalPath = request.sourceLogicalPath,
            sourceId = request.sourceId,
            sourceRevision = request.sourceRevision,
            // The Core lane's CAS expectation binds the CURRENT authoritative
            // baseline: after a proven manual original save, the model path
            // and repeat saves compare against the committed bytes, never
            // the stale open-time digest.
            originalSnapshotSha256 = op.originalBaselineSha256 ?: op.snapshotSha256,
            originalSnapshotBytes = if (op.originalBaselineSha256 != null) {
                op.originalBaselineBytes
            } else {
                op.snapshotBytes
            },
            editable = op.editable,
            stagedWorkingCopyPath = op.workingCopy?.let {
                runCatching { it.canonicalPath }.getOrNull()
            },
            stagedWorkingCopySha256 = op.workingCopySha256,
            stagedWorkingCopyBytes = op.workingCopyBytes,
        )
    }

    // ------------------------------------------------------------------
    // C08 original-version conflict review (exact viewer channel)
    // ------------------------------------------------------------------

    /**
     * Re-derives the exact live editing identity for the viewer's request.
     * The engine generation is read from the SAME Save-Copy host binding the
     * viewer already uses; a token-only match is never enough. No path or
     * provider authority is granted by answering.
     */
    private fun conflictReviewIdentity(
        sessionToken: String,
        generation: Long,
    ): OfficeConflictReviewIdentity? {
        synchronized(lock) {
            val op = active ?: return null
            if (op.retired || op.viewEnded || op.phase != Phase.VIEWING || !op.editable ||
                !op.ownerCurrent() || op.sessionToken != sessionToken
            ) return null
            val request = mutableState.value.viewer?.request ?: return null
            if (request.sessionToken != sessionToken || request.permission != OfficePermission.EDIT) return null
            op to request
        }
        // The command binding is established asynchronously when the edit
        // session opens. A bounded wait avoids a false "session fenced"
        // answer during the first frames, while never accepting a different
        // generation.
        var liveGeneration = 0L
        for (attempt in 0 until 20) {
            liveGeneration = runCatching { saveCopy.aiReadGeneration(sessionToken) }.getOrDefault(0L)
            if (liveGeneration == generation) break
            if (attempt < 19) runCatching { Thread.sleep(50L) }
        }
        if (liveGeneration != generation) return null
        return synchronized(lock) {
            val op = active ?: return null
            if (op.retired || op.viewEnded || op.phase != Phase.VIEWING || !op.ownerCurrent() ||
                op.sessionToken != sessionToken
            ) return null
            val request = mutableState.value.viewer?.request ?: return null
            if (request.sessionToken != sessionToken) return null
            val route = when {
                op.saveOriginal != null -> OfficeConflictRoute.PROVIDER
                op.ownerTaskId != null && op.ownerWorkspaceId != null &&
                    op.ownerNativeEpoch?.toLongOrNull() != null &&
                    request.hostGeneration?.toLongOrNull() != null &&
                    request.sourceLogicalPath != null -> OfficeConflictRoute.WORKSPACE
                else -> OfficeConflictRoute.NONE
            }
            OfficeConflictReviewIdentity(
                sessionToken = sessionToken,
                generation = generation,
                route = route,
                // The review compares the live original against the CURRENT
                // authoritative baseline (advanced by a proven manual
                // original save), never stale open-time metadata: after a
                // save, "unchanged" must mean unchanged since THAT version.
                baseSha256 = op.originalBaselineSha256 ?: op.snapshotSha256 ?: request.sha256,
                baseRevision = request.sourceRevision,
                originalUri = op.saveOriginal?.uri?.uriString,
                ownerTaskId = op.ownerTaskId,
                workspaceId = op.ownerWorkspaceId,
                nativeEpoch = op.ownerNativeEpoch?.toLongOrNull(),
                hostGeneration = request.hostGeneration?.toLongOrNull(),
                sourceLogicalPath = request.sourceLogicalPath,
                workingCopy = op.workingCopy ?: return null,
                extension = request.format.fileExtension,
            )
        }
    }

    /** Immutable copy of the ACTUAL working copy, verified as a real package. */
    private fun conflictMine(
        identity: OfficeConflictReviewIdentity,
        directory: File,
    ): OfficeConflictVersion? = OfficeConflictArtifacts.copyVerified(
        source = identity.workingCopy,
        directory = directory,
        name = "mine.${identity.extension}",
        format = identity.extension,
    )

    /**
     * Immutable copy of the live original through its EXISTING read lane.
     * Provider: the shared gateway under the current live grant. Workspace:
     * the native egress snapshot. Neither writes, renames or re-grants.
     */
    private fun conflictCurrent(
        identity: OfficeConflictReviewIdentity,
        directory: File,
    ): OfficeConflictVersion? = when (identity.route) {
        OfficeConflictRoute.PROVIDER -> {
            val uri = identity.originalUri ?: return null
            when (val capture = saveCopy.captureOriginal(uri, directory)) {
                is OfficeOriginalCapture.Captured -> verifyExistingVersion(
                    file = capture.file,
                    expectedSha256 = capture.sha256,
                    expectedBytes = capture.bytes,
                    revision = null,
                    format = identity.extension,
                )
                is OfficeOriginalCapture.Failed -> null
            }
        }
        OfficeConflictRoute.WORKSPACE -> {
            val taskID = identity.ownerTaskId ?: return null
            val workspaceID = identity.workspaceId ?: return null
            val epoch = identity.nativeEpoch ?: return null
            val hostGeneration = identity.hostGeneration ?: return null
            val path = identity.sourceLogicalPath ?: return null
            val owner = try {
                WorkspaceOfficeSnapshotStager.Owner(taskID, workspaceID, epoch, hostGeneration)
            } catch (_: IllegalArgumentException) {
                return null
            }
            val snapshot = try {
                workspace.stage(owner, path) { conflictIdentityStillCurrent(identity) }
            } catch (_: Exception) {
                return null
            } catch (_: LinkageError) {
                return null
            }
            try {
                val copied = OfficeConflictArtifacts.copyVerified(
                    source = snapshot.file,
                    directory = directory,
                    name = "current.${identity.extension}",
                    format = identity.extension,
                    expectedSha256 = snapshot.sha256,
                    expectedBytes = snapshot.bytes,
                )
                copied?.copy(revision = snapshot.sourceRevision)
            } finally {
                removeOwnUnreferencedInput(snapshot.file)
            }
        }
        OfficeConflictRoute.RUN_OUTPUT,
        OfficeConflictRoute.NONE -> null
    }

    /** Chunk-level liveness for the read-only workspace stage (never authority). */
    private fun conflictIdentityStillCurrent(identity: OfficeConflictReviewIdentity): Boolean =
        synchronized(lock) {
            val op = active ?: return false
            !op.retired && !op.viewEnded && op.phase == Phase.VIEWING && op.ownerCurrent() &&
                op.sessionToken == identity.sessionToken
        }

    /** Verifies an already-staged immutable file without rewriting its bytes. */
    private fun verifyExistingVersion(
        file: File,
        expectedSha256: String,
        expectedBytes: Long,
        revision: String?,
        format: String,
    ): OfficeConflictVersion? {
        if (!file.isFile || file.length() != expectedBytes) return null
        val digest = OfficeConflictArtifacts.digest(file) ?: return null
        if (digest.second != expectedBytes || !digest.first.equals(expectedSha256, ignoreCase = true)) return null
        val verified = OfficeRequestPolicy.verifyStagedOutput(file, format)
        if (!verified.verified) return null
        if (!file.setReadOnly()) return null
        return OfficeConflictVersion(digest.first, digest.second, revision, file)
    }

    /** Drop temporary review snapshots for an exact session (never input). */
    private fun releaseConflictReview(sessionToken: String) {
        runCatching { conflictReview.releaseSession(sessionToken) }
    }

    // ------------------------------------------------------------------
    // Manual workspace original save (OFC-SAVE-REOPEN)
    // ------------------------------------------------------------------

    /**
     * True ONLY for an EDIT mount of an ordinary task-owned workspace
     * document whose full owner facts and CAS baseline are present. Mirrors
     * [conflictReviewIdentity]'s WORKSPACE route rule: provider-picked,
     * run-output, recovery and read-only mounts answer false and stay
     * copy-only — never a fake workspace-ownership control.
     */
    private fun saveOriginalRouteAuthority(op: Operation, request: OfficePreviewRequest): Boolean {
        if (op.retired || op.viewEnded || !op.editable || !op.ownerCurrent()) return false
        if (request.permission != OfficePermission.EDIT) return false
        if (op.ownerTaskId == null || op.ownerWorkspaceId == null) return false
        if (op.ownerNativeEpoch?.toLongOrNull() == null) return false
        if (request.hostGeneration?.toLongOrNull() == null) return false
        if (request.sourceLogicalPath.isNullOrEmpty()) return false
        if (op.originalBaselineSha256 == null) return false
        // The durable open-time snapshot pair must exist (the immutable
        // artifact the baseline was derived from).
        return op.snapshot != null && op.snapshotSha256 != null
    }

    /**
     * Resolves the EXACT live owned operation for one original-save notice
     * under the controller lock: current, un-retired, VIEWING, editable,
     * owner-current, exact session token AND the exact engine mount
     * generation (the caller proves the generation with the SAME bounded
     * retry the review lane uses, then this join re-proves it against the
     * captured [Operation]). Marks the handoff in flight so a duplicate
     * notice can never interleave with the verification/commit. Returns
     * null (REFUSED) for any other owner, epoch, session or state.
     */
    private fun saveOriginalOperationFacts(
        sessionToken: String,
        generation: Long,
    ): OfficeSaveOriginalOperation? = synchronized(lock) {
        val op = active ?: return null
        if (op.retired || op.viewEnded || op.phase != Phase.VIEWING || !op.editable ||
            !op.ownerCurrent() || op.sessionToken != sessionToken
        ) return null
        val request = mutableState.value.viewer?.request ?: return null
        if (request.sessionToken != sessionToken || request.permission != OfficePermission.EDIT) {
            return null
        }
        if (op.saveOriginalInFlight) return null
        if (!saveOriginalRouteAuthority(op, request)) return null
        val workingCopy = op.workingCopy ?: return null
        val workingPath = runCatching { workingCopy.canonicalPath }.getOrNull() ?: return null
        val taskID = op.ownerTaskId ?: return null
        val workspaceID = op.ownerWorkspaceId ?: return null
        val epoch = op.ownerNativeEpoch?.toLongOrNull() ?: return null
        val hostGeneration = request.hostGeneration?.toLongOrNull() ?: return null
        val logicalPath = request.sourceLogicalPath ?: return null
        val baselineSha = op.originalBaselineSha256 ?: return null
        // The engine generation binding is established asynchronously when
        // the edit session opens; the bounded retry happens in
        // [acceptSaveOriginalNotice] BEFORE this join, so here we only
        // require the notice generation to be the live one.
        val liveGeneration = runCatching { saveCopy.aiReadGeneration(sessionToken) }.getOrDefault(0L)
        if (liveGeneration != generation) return null
        op.saveOriginalInFlight = true
        OfficeSaveOriginalOperation(
            baselineSha256 = baselineSha,
            baselineBytes = op.originalBaselineBytes,
            commit = OfficeOriginalCommitFacts(
                taskID = taskID,
                workspaceID = workspaceID,
                nativeEpoch = epoch,
                hostGeneration = hostGeneration,
                logicalPath = logicalPath,
                sourceID = request.sourceId,
                sourceRevision = request.sourceRevision,
                expectedOriginalSHA256 = baselineSha,
                sourcePath = workingPath,
            ),
            stillOwned = { saveOriginalStillOwned(sessionToken, workingPath) },
            markCommitted = { sha256, bytes ->
                synchronized(lock) {
                    if (active === op && !op.retired) {
                        // The real commit proved these bytes; only now may
                        // the expectation advance (repeat saves can never
                        // fight stale open-time metadata).
                        op.originalBaselineSha256 = sha256
                        op.originalBaselineBytes = bytes
                    }
                }
            },
            releaseInFlight = {
                synchronized(lock) {
                    if (active === op && op.sessionToken == sessionToken) {
                        op.saveOriginalInFlight = false
                    }
                }
            },
            // Provider sync rides the EXISTING journaled ladder only when a
            // source binding exists AND RuntimeHost installed the push port.
            // The lane itself re-admits the exact owner + live root epoch on
            // every hop, so this fence stays minimal.
            pushOriginal = request.sourceId
                ?.takeIf { it.isNotEmpty() }
                ?.let { saveOriginalPushPort }
                ?.let { push ->
                    suspend {
                        push(
                            OfficeOriginalPushRequest(
                                taskID = taskID,
                                workspaceID = workspaceID,
                                nativeEpoch = epoch,
                                hostGeneration = hostGeneration,
                                logicalPath = logicalPath,
                                ownerFence = { saveOriginalStillOwned(sessionToken, workingPath) },
                            ),
                        )
                    }
                },
        )
    }

    /** Post-commit/post-copy re-fence for ONE exact operation: still the
     *  current, un-retired, not-view-ended, VIEWING owner with the SAME
     *  App-owned working copy. Never touches another owner or a replaced
     *  operation. */
    private fun saveOriginalStillOwned(sessionToken: String, workingPath: String): Boolean =
        synchronized(lock) {
            val op = active ?: return false
            !op.retired && !op.viewEnded && op.phase == Phase.VIEWING && op.ownerCurrent() &&
                op.sessionToken == sessionToken &&
                op.workingCopy?.let { runCatching { it.canonicalPath }.getOrNull() } == workingPath
        }

    /**
     * Answers ONE verified original-save notice on a Binder thread (the
     * viewer posts from its dedicated handoff thread). First proves the
     * exact engine mount generation with the SAME bounded retry the review
     * lane uses, then runs the real orchestration; the native hop blocks
     * this thread to its honest terminal. One of the
     * [OfficeSaveOriginalHandoffPolicy] verdicts; the in-flight mark is
     * always released.
     */
    private fun acceptSaveOriginalNotice(
        notice: OfficeSaveOriginalHandoffPolicy.SaveOriginalNotice,
    ): Int {
        if (OfficeSaveOriginalHandoffPolicy.validateSaveOriginal(
                notice.opId,
                notice.sessionToken,
                notice.generation,
                notice.format,
                notice.workingCopySha256,
                notice.workingCopyBytes,
            ) == null
        ) {
            return OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_REFUSED
        }
        var liveGeneration = 0L
        for (attempt in 0 until 20) {
            liveGeneration = runCatching { saveCopy.aiReadGeneration(notice.sessionToken) }.getOrDefault(0L)
            if (liveGeneration == notice.generation) break
            if (attempt < 19) runCatching { Thread.sleep(50L) }
        }
        if (liveGeneration != notice.generation) {
            return OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_REFUSED
        }
        // The in-flight fence is released by the host on EVERY path after
        // the facts were acquired (see OfficeSaveOriginalOperation).
        return runCatching {
            kotlinx.coroutines.runBlocking { saveOriginalHost.accept(notice) }
        }.getOrDefault(OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_REJECTED)
    }

    /** Narrow READ-ONLY capability join for the G05-R2 Office AI host lane
     * (Main host20): hands out the ONE application-owned Save-Copy host
     * instance so the RuntimeHost pump can read the engine generation/state
     * and submit its own typed save ops through the existing transaction-20
     * binding. It grants nothing else: no new operation, no file access, no
     * lifecycle control; the channel-28 registration and the whole existing
     * viewer Save-Copy flow stay exactly as they are. */
    internal fun officeAiSaveHost(): OfficeSaveCopyHost = saveCopy

    /** Narrow read-only PHASE join for the Office AI lane (Main admission
     * continuation 2026-10-27): true ONLY when the current operation named by
     * these EXACT owner facts has actually reached the VIEWING phase (the
     * viewer claim happened). The AI lane carries its transient foreground/
     * modal/visible-chat admission through staging until this flips, then
     * stops consulting it entirely — a Main pause AFTER a successful claim
     * must never revoke the owned viewing document. LAUNCH/staging/picking
     * answers false, so an unclaimed launch stays retire-able through the
     * existing [cancelUnopened]. Same lock, same exact-match rules as
     * [ownedOperationSnapshot]. */
    internal fun isOwnedOperationViewing(
        ownerTaskId: String,
        workspaceId: String?,
        nativeEpoch: String,
    ): Boolean = synchronized(lock) {
        val op = active ?: return false
        if (op.retired || op.viewEnded || op.phase != Phase.VIEWING || !op.ownerCurrent()) return false
        val request = mutableState.value.viewer?.request ?: return false
        request.sessionToken == op.sessionToken &&
            request.ownerTaskId == ownerTaskId &&
            request.workspaceId == workspaceId &&
            request.nativeEpoch == nativeEpoch
    }

    /** Owner-checked transient-admission retirement (Main host20 admission
     * continuation): cancels ONLY this exact owner's still-UNCLAIMED launch
     * (picking/staging/launch, not VIEWING, not already retired) through the
     * existing explicit-cancel lane. Another surface's operation (e.g. a
     * manual user open that replaced ours) can never be touched, and a
     * claimed VIEWING document is never revoked. Answers whether a cancel
     * actually applied to the matching operation. */
    internal fun cancelUnclaimedOwnedLaunch(
        ownerTaskId: String,
        workspaceId: String?,
        nativeEpoch: String,
    ): Boolean = synchronized(lock) {
        val op = active ?: return false
        if (op.ownerTaskId != ownerTaskId || op.ownerWorkspaceId != workspaceId ||
            op.ownerNativeEpoch != nativeEpoch
        ) {
            return false
        }
        if (op.retired || op.viewEnded || op.phase == Phase.VIEWING) return false
        cancelUnopened()
        true
    }

    fun clearError() = synchronized(lock) { mutableState.value = mutableState.value.copy(error = null) }
    fun reportSourceUnavailable() = synchronized(lock) { mutableState.value = mutableState.value.copy(error = "source") }

    private fun stagingError(op: Operation, error: Throwable): String? = when {
        op.retired -> null
        error is WorkspaceOfficeSnapshotStager.Failure && error.code == "contentTooLarge" -> "tooLarge"
        error is RunOutputOfficeSnapshotStager.Failure && error.code == "contentTooLarge" -> "tooLarge"
        error is OfficeEditableCopyStager.Failure && error.code == "contentTooLarge" -> "tooLarge"
        else -> "source"
    }

    private fun recordFailure(op: Operation, error: Any) = synchronized(lock) {
        if (active === op) diagnosticFailure = error
    }

    private fun settle(op: Operation, error: String?, removeInput: Boolean = true): Boolean {
        var releasedReviewToken: String? = null
        val settled = synchronized(lock) {
            if (active !== op) {
                false
            } else {
                ackQuiescence?.cancel()
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
                    // cancel or process loss they stay the recoverable base owned by
                    // the durable recovery journal and its user-visible review. Only
                    // the immutable intermediate snapshot follows removal eligibility.
                    if (removeInput) op.snapshot?.let { file ->
                        scope.launch(Dispatchers.IO) { removeOwnUnreferencedInput(file) }
                    }
                } else if (removeInput) {
                    op.input?.let { file ->
                        scope.launch(Dispatchers.IO) {
                            runCatching {
                                op.snapshotSha256?.let { sha -> pendingProviderPreview.clearMatching(file.canonicalPath, sha, op.snapshotBytes) }
                                removeOwnUnreferencedInput(file)
                            }.onFailure { diagnosticFailure = it }
                        }
                    }
                }
                releasedReviewToken = op.sessionToken
                active = null
                mutableState.value = State(error = error)
                true
            }
        }
        if (settled) releasedReviewToken?.let { releaseConflictReview(it) }
        return settled
    }

    private fun removeOwnUnreferencedInput(file: File?) {
        if (file == null) return
        runCatching {
            val parent = file.parentFile?.canonicalFile ?: return
            val roots = setOf(workspaceRoot.canonicalFile, providerRoot.canonicalFile,
                              runOutputRoot.canonicalFile)
            val container = parent.parentFile ?: return
            if (container !in roots || runCatching { java.util.UUID.fromString(parent.name) }.isFailure) return
            // No recursive traversal of native-created links or unknown files.
            file.delete()
            parent.delete()
        }
    }

    private fun languageTag(): String = context.resources.configuration.locales.get(0).toLanguageTag()

    companion object {
        /** Bounded acknowledged-close retirement window. See
         *  [armAckQuiescenceLocked]: the expiry releases ONLY the admission
         *  slot for an engine-acknowledged close under honest uncertainty;
         *  it is not a claim of native or IO quiescence. */
        private const val ACKED_CLOSE_RETIREMENT_MS = 4_000L

        fun supports(path: String): Boolean = path.substringAfterLast('.', "").lowercase(Locale.ROOT) in
            setOf("docx", "xlsx", "pptx")
        val MIME_TYPES = arrayOf(
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        )
    }
}

/**
 * Exact-ownership guard shared by the acknowledged-close arming and its
 * bounded-retirement expiry (one decision, both call sites, both made while
 * holding the controller lock): a candidate operation may cancel/replace
 * the single global retirement job or settle through it ONLY while it is
 * still THE current operation, un-retired, not view-ended, in the VIEWING
 * phase, AND the recorded acknowledgement names this exact incarnation and
 * session token. A duplicate acknowledgement for the same still-current
 * operation answers true (its own job slot is replaced — idempotent);
 * any settle, replacement, teardown, or an acknowledgement recorded for a
 * different incarnation/token answers false. JVM-expressible so the
 * regression drives the real production decision; the controller supplies
 * the facts from its lock.
 */
internal fun ackedCloseStillOwnsSlot(
    activeIsCandidate: Boolean,
    retired: Boolean,
    viewEnded: Boolean,
    phaseViewing: Boolean,
    candidateIncarnation: Long,
    candidateSessionToken: String?,
    ack: OfficeCloseAckPolicy.AckRequest?,
): Boolean =
    activeIsCandidate && !retired && !viewEnded && phaseViewing &&
        ack != null && ack.viewerIncarnation == candidateIncarnation &&
        ack.sessionToken == candidateSessionToken

/**
 * Exact-ownership guard of the approval-notice answer (one pure decision,
 * made while holding the controller lock): a query is answered ONLY when the
 * candidate is STILL the current operation — un-retired, not view-ended, in
 * the VIEWING phase — AND the query names this exact incarnation, session
 * token AND owner task id, AND the operation is OWNED (a null candidate
 * owner can never match: the provider-pick route carries no conversation to
 * ask about, mirroring the honest-absence rule of
 * [OfficePreviewController.ownedOperationSnapshot]). A close, settle,
 * replacement or supersede therefore answers "not pending" automatically;
 * JVM-expressible so the regression drives the real production decision.
 */
internal fun approvalNoticeAdmissible(
    retired: Boolean,
    viewEnded: Boolean,
    phaseViewing: Boolean,
    candidateIncarnation: Long,
    candidateSessionToken: String?,
    candidateOwnerTaskId: String?,
    queryIncarnation: Long,
    queryToken: String,
    queryOwnerTaskId: String,
): Boolean =
    !retired && !viewEnded && phaseViewing &&
        candidateOwnerTaskId != null &&
        candidateIncarnation == queryIncarnation &&
        candidateSessionToken == queryToken &&
        candidateOwnerTaskId == queryOwnerTaskId

/**
 * Exact-ownership guard of the explicit owned-document RETURN route
 * (G05-R3 office-return109; one pure decision made while holding the
 * controller lock — and the raise's startActivity dispatch then runs under
 * that SAME lock, see [OfficePreviewController.requestOwnedViewerRestore] —
 * deliberately the same shape as [approvalNoticeAdmissible] plus the
 * established owner fence): a raise of the live viewer is admitted ONLY when
 * the candidate is STILL the current operation — un-retired, not view-ended,
 * in the VIEWING phase, AND its captured [ownerCurrent] closure still
 * answers true (matching ids alone never prove the current owner: this is
 * the same fence [current] applies to the close/notice lanes) — the PUBLISHED
 * request still names this exact operation AND the caller's captured return
 * target (owner conversation + opaque incarnation + session token), AND the
 * operation is OWNED (a null candidate owner can never match: the provider-
 * pick route has no owning conversation to return to). A stop, close,
 * settle, replacement, owner-invalidated conversation or supersede therefore
 * admits nothing; the strip itself disappears with the State reset.
 * JVM-expressible so the regression drives the REAL production decision
 * [requestOwnedViewerRestore] passes.
 */
internal fun viewerRestoreAdmissible(
    retired: Boolean,
    viewEnded: Boolean,
    phaseViewing: Boolean,
    ownerCurrent: Boolean,
    candidateIncarnation: Long,
    candidateSessionToken: String?,
    candidateOwnerTaskId: String?,
    publishedRequestMatches: Boolean,
    claimedIncarnation: Long,
    claimedSessionToken: String?,
    claimedOwnerTaskId: String?,
): Boolean =
    !retired && !viewEnded && phaseViewing && ownerCurrent &&
        publishedRequestMatches &&
        candidateOwnerTaskId != null && candidateSessionToken != null &&
        candidateIncarnation == claimedIncarnation &&
        candidateSessionToken == claimedSessionToken &&
        candidateOwnerTaskId == claimedOwnerTaskId
