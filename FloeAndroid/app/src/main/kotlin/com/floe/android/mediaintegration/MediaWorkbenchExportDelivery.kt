// SPDX-License-Identifier: MPL-2.0
package com.floe.android.mediaintegration

import android.content.Context
import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.workbench.CreativeProjectContext
import com.floe.android.feature.workbench.MediaExportReceipt
import com.floe.android.feature.workbench.MediaExportState
import com.floe.android.feature.workbench.MediaExportStatus
import com.floe.android.feature.workbench.ui.r2.WorkbenchExportDelivery
import com.floe.android.feature.workbench.ui.r2.WorkbenchExportDeliveryResult
import com.floe.android.host.PlatformLaunchOwnership
import com.floe.android.host.SharedUriGrantAuthority
import com.floe.android.host.creative.CreativeHostController
import com.floe.android.host.creative.R2PreparedRenderBinding
import com.floe.android.safgateway.AndroidSafBackend
import com.floe.android.safgateway.PickAcceptResult
import com.floe.android.safgateway.PickRequestSpec
import com.floe.android.safgateway.ProbeFlag
import com.floe.android.safgateway.SafAccessFlag
import com.floe.android.safgateway.SafCancelToken
import com.floe.android.safgateway.SafCancelledException
import com.floe.android.safgateway.SafDocumentRef
import com.floe.android.safgateway.SafGatewayService
import com.floe.android.safgateway.SafOutcome
import com.floe.android.safgateway.WriteOpen
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/** A picker request the mounted App effect must present for one save. */
internal data class MediaWorkbenchPendingPick(
    val incarnation: Long,
    val spec: PickRequestSpec,
    val suggestedName: String,
)

/**
 * App-owned Save/Share delivery for a verified export receipt.
 *
 * Truth rules encoded here:
 *  * the receipt is identified by its FULL binding (project/root/revision/
 *    timeline digest/attempt) plus output path, MIME, size and SHA-256; an
 *    attempt alone is never a Save/Share authority;
 *  * every Save/Share is authorized against an exact owner captured by this
 *    App when it prepared the binding or received a verified status/list
 *    entry, then re-proved live by native `resolveProjectMediaRoot(context)`
 *    for the same epoch/project/storage/origin/durable owner proof;
 *  * neither the receipt path nor any recorded JSON is a root/path authority;
 *    the accepted base ancestor is NEVER a Save/Share fallback;
 *  * the CREATE_DOCUMENT picker result is the only destination grant; its
 *    real returned flags are accepted/stored through the existing SafGateway
 *    and live read+write evidence is re-probed before IO;
 *  * the verified bytes are written to a DISTINCT picked document and read
 *    back with streaming size+SHA equality before [Delivered] is returned;
 *  * a pending pick and an in-flight copy survive rotation (process-scoped
 *    StateFlow + incarnation), and an actual root stop cancels/fences them;
 *  * an already-admitted save keeps the EXACT captured owner proof and its
 *    authorized root for the real IO even if the editor closes; Root stop
 *    waits the whole operation before the native root can be released;
 *  * a failure keeps the possibly-written destination and never relabels it
 *    success; the published export and its journal stay untouched.
 */
internal class MediaWorkbenchExportDelivery(
    context: Context,
    private val hostProvider: () -> CreativeHostController,
) : WorkbenchExportDelivery, MediaWorkbenchReceiptRecorder {
    companion object {
        const val PICK_TIMEOUT_MILLIS = 10 * 60 * 1000L
        const val RETIRE_TIMEOUT_MILLIS = 15_000L
        private const val MAX_DISPLAY_NAME = 120
    }

    private val applicationContext = context.applicationContext
    private val stagingRoot = File(applicationContext.filesDir, "WorkbenchExportScratch")
    private val backend = AndroidSafBackend(applicationContext)
    private val gateway = SafGatewayService(backend)

    /** Opaque launch-lane identity (no URI/user data). */
    val launchNamespace: String = PlatformLaunchOwnership.mintNamespace()

    /**
     * Application-owned worker lifetime: a rotation/UI-scope cancellation
     * must not abort a picked verified save half-way. The caller awaits the
     * exact job, but the job itself belongs to this process scope.
     */
    private val workerScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val deliveryMutex = Mutex()
    private val lock = Any()
    private var active: Active? = null
    private var stopping = false
    private var incarnationCounter = 0L
    @Volatile
    private var boundEpoch = 0L

    private val mutablePending = MutableStateFlow<MediaWorkbenchPendingPick?>(null)
    val pendingPick: StateFlow<MediaWorkbenchPendingPick?> = mutablePending

    /**
     * Bounded transient authority maps. They are NOT a project store and not
     * a second recovery journal: entries exist only while their captured
     * owner can still be re-proved by native in this process.
     */
    private val receipts = MediaWorkbenchReceiptRegistry()
    private val preparedCaptures = MediaWorkbenchPreparedRegistry()

    private sealed interface PickOutcome {
        data class Uri(val uriString: String, val flags: Int) : PickOutcome
        data object UserCancelled : PickOutcome
        data class HostCancelled(val reason: String) : PickOutcome
    }

    private class Active(
        val incarnation: Long,
        val spec: PickRequestSpec,
        val staged: File,
        val scratchDir: File,
        val expectedBytes: Long,
        val expectedSha: String,
        val mimeType: String,
        val ownerProof: String,
        val cancel: SafCancelToken,
        val pending: CompletableDeferred<PickOutcome>,
        val settled: CompletableDeferred<Unit>,
    )

    // MARK: - Captured authority

    /**
     * Records the authorized context of an App-prepared binding. This is
     * captured BEFORE the editor can close and is re-proved at delivery time;
     * a failed capture simply leaves no entry (delivery then refuses rather
     * than falling back to a base root).
     */
    suspend fun recordPrepared(prepared: R2PreparedRenderBinding) {
        val owner = captureOwner(prepared.context)
        if (owner == null || owner.projectID != prepared.context.projectID) return
        if (!isCurrentEpoch(owner.epoch)) return
        val preparedRoot = MediaWorkbenchExportAuthorization.canonicalPath(prepared.mediaRootPath)
            ?: return
        if (preparedRoot != owner.canonicalRootPath) return
        rememberPrepared(
            MediaWorkbenchPreparedCapture(
                owner = owner,
                projectRevision = prepared.projectRevision,
                timelineDigest = prepared.timelineDigest,
                attemptID = prepared.attemptID,
            ),
        )
    }

    override suspend fun recordVerifiedStatus(
        context: CreativeProjectContext,
        status: MediaExportStatus,
    ) {
        val receipt = verifiedReceipt(status) ?: return
        val identity = MediaWorkbenchReceiptIdentity.of(receipt) ?: return
        val owner = captureOwner(context) ?: return
        if (!isCurrentEpoch(owner.epoch)) return
        if (identity.projectID != owner.projectID) return
        val receiptRoot = MediaWorkbenchExportAuthorization.canonicalPath(identity.mediaRootPath)
            ?: return
        if (receiptRoot != owner.canonicalRootPath) return
        rememberReceipt(identity, owner)
    }

    /** Bounded list reply: every verified receipt is bound to this context. */
    suspend fun recordRecovered(
        context: CreativeProjectContext,
        statuses: List<MediaExportStatus>,
    ) {
        val verified = statuses.mapNotNull { verifiedReceipt(it) }
        if (verified.isEmpty()) return
        val owner = captureOwner(context) ?: return
        if (!isCurrentEpoch(owner.epoch)) return
        for (receipt in verified) {
            val identity = MediaWorkbenchReceiptIdentity.of(receipt) ?: continue
            if (identity.projectID != owner.projectID) continue
            val receiptRoot =
                MediaWorkbenchExportAuthorization.canonicalPath(identity.mediaRootPath) ?: continue
            if (receiptRoot != owner.canonicalRootPath) continue
            rememberReceipt(identity, owner)
        }
    }

    /**
     * Observe callbacks are non-suspend. A same-process export normally has
     * its prepared capture, so the full receipt identity can be recorded
     * synchronously; otherwise the owner proof is resolved on the App worker
     * and Save still refuses until that exact proof exists.
     */
    override fun recordObservedStatus(
        context: CreativeProjectContext,
        status: MediaExportStatus,
    ) {
        val receipt = verifiedReceipt(status) ?: return
        val identity = MediaWorkbenchReceiptIdentity.of(receipt) ?: return
        val prepared = preparedCaptures.lookup(identity.attemptID)
        if (prepared != null && prepared.matches(identity) &&
            prepared.owner.context == context &&
            isCurrentEpoch(prepared.owner.epoch)
        ) {
            // Same live editor context: the full receipt identity can be
            // bound synchronously before the UI presents Save.
            rememberReceipt(identity, prepared.owner)
            return
        }
        // A reopened editor (new session token, same durable owner) must be
        // re-proved through the CURRENT context, not the old prepared one.
        workerScope.launch {
            try {
                recordVerifiedStatus(context, status)
            } catch (_: CancellationException) {
                // Process-scope cancellation only; no partial authority.
            } catch (_: Throwable) {
                // No verified owner proof -> Save will refuse honestly.
            }
        }
    }

    /** A new accepted epoch replaces old-epoch captured authority. */
    fun onNativeCreativeBound(epoch: Long) {
        synchronized(lock) {
            stopping = false
            if (epoch > 0L && epoch != boundEpoch) {
                boundEpoch = epoch
                preparedCaptures.clear()
                receipts.clear()
            }
        }
    }

    private fun rememberReceipt(
        identity: MediaWorkbenchReceiptIdentity,
        owner: MediaWorkbenchCapturedOwner,
    ) {
        synchronized(lock) {
            if (isCurrentEpoch(owner.epoch)) {
                receipts.remember(identity, owner)
            }
        }
    }

    private fun rememberPrepared(capture: MediaWorkbenchPreparedCapture) {
        synchronized(lock) {
            if (isCurrentEpoch(capture.owner.epoch)) {
                preparedCaptures.remember(capture)
            }
        }
    }

    /** Root-stop step 1: refuse NEW Save/Share work immediately. */
    fun fenceForRootStop() {
        synchronized(lock) { stopping = true }
    }

    /** Completes one outstanding pick for the exact incarnation. */
    fun completePick(incarnation: Long, uriString: String?, flags: Int) {
        val current = synchronized(lock) {
            active?.takeIf { it.incarnation == incarnation }
        } ?: return
        val outcome = if (uriString.isNullOrBlank()) {
            PickOutcome.UserCancelled
        } else {
            PickOutcome.Uri(uriString, flags)
        }
        current.pending.complete(outcome)
    }

    /** Unmount without a real navigation (rotation) must not cancel a pick. */
    fun cancelPendingForUnmountedSurface(reason: String) {
        val current = synchronized(lock) { active } ?: return
        current.pending.complete(PickOutcome.HostCancelled(reason))
    }

    /**
     * Root-stop step: fence new deliveries, cancel the outstanding pick and
     * the in-flight provider write, then await the exact operation. FALSE
     * keeps the operation (and any partial destination) owned.
     */
    suspend fun retireForRootStop(
        timeoutMillis: Long = RETIRE_TIMEOUT_MILLIS,
    ): Boolean {
        val current = synchronized(lock) {
            stopping = true
            active
        }
        current?.pending?.complete(PickOutcome.HostCancelled("rootStop"))
        current?.cancel?.cancel()
        // Wait for the WHOLE delivery admission (including staging before the
        // destination exists) or the exact active operation. No poll loop and
        // no registry clear before the mutex/owner is actually free.
        val deadline = System.currentTimeMillis() + timeoutMillis.coerceIn(0L, 60_000L)
        val acquired = withTimeoutOrNull(
            (deadline - System.currentTimeMillis()).coerceAtLeast(1L),
        ) {
            deliveryMutex.withLock { }
            true
        } ?: false
        if (!acquired) return false
        val stillActive = synchronized(lock) {
            val retained = active
            if (retained != null) {
                retained.pending.complete(PickOutcome.HostCancelled("rootStop"))
                retained.cancel.cancel()
            }
            retained != null
        }
        if (!stillActive) return true
        val settled = synchronized(lock) { active?.settled }
        return withTimeoutOrNull(1000L) { settled?.await() } != null
    }

    override suspend fun deliverExport(
        receipt: MediaExportReceipt,
    ): WorkbenchExportDeliveryResult {
        // Launch on the App-owned scope, then await it. A cancelled caller
        // abandons the observation, not the real save operation.
        return workerScope.async { runDelivery(receipt) }.await()
    }

    private suspend fun runDelivery(
        receipt: MediaExportReceipt,
    ): WorkbenchExportDeliveryResult = withContext(Dispatchers.IO) {
        if (!deliveryMutex.tryLock()) {
            return@withContext WorkbenchExportDeliveryResult.Failed("exportDeliveryBusy")
        }
        var scratchDir: File? = null
        var admitted: Active? = null
        try {
            if (synchronized(lock) { stopping }) {
                return@withContext WorkbenchExportDeliveryResult.Failed("staleGeneration")
            }
            val identity = MediaWorkbenchReceiptIdentity.of(receipt)
                ?: return@withContext WorkbenchExportDeliveryResult.Failed("invalidReceipt")
            val displayName = safeDisplayName(
                receipt.displayName ?: identity.outputRelativePath.substringAfterLast('/'))
                ?: return@withContext WorkbenchExportDeliveryResult.Failed("invalidReceipt")

            val authorization = authorizeRoot(identity)
            if (authorization is MediaWorkbenchOwnerDecision.Refused) {
                // Missing capture is surfaced as the existing session-lost
                // action ("reopen the project"); foreign/stale keep their
                // exact codes for the UI/diagnostic binding.
                val code = when (authorization.code) {
                    "exportOwnerUnverified" -> "staleSession"
                    else -> authorization.code
                }
                return@withContext WorkbenchExportDeliveryResult.Failed(code)
            }
            val granted = authorization as MediaWorkbenchOwnerDecision.Granted
            val root = granted.canonicalRoot
            val source = MediaWorkbenchExportProof.resolveContainedFile(
                root.path, identity.outputRelativePath)
                ?: return@withContext WorkbenchExportDeliveryResult.Failed("exportOutputMissing")
            if (source.length() != identity.byteCount) {
                return@withContext WorkbenchExportDeliveryResult.Failed("exportOutputChanged")
            }

            val dir = File(stagingRoot, "export-${UUID.randomUUID()}")
            if (!dir.mkdirs() || !isWithin(stagingRoot, dir)) {
                return@withContext WorkbenchExportDeliveryResult.Failed("exportScratchUnavailable")
            }
            scratchDir = dir
            val part = File(dir, "payload.part")
            MediaWorkbenchExportProof.verifyAndStage(
                source = source,
                expectedBytes = identity.byteCount,
                expectedSha256 = identity.sha256,
                stagingTarget = part,
            ) ?: return@withContext WorkbenchExportDeliveryResult.Failed("exportOutputChanged")

            if (synchronized(lock) { stopping }) {
                return@withContext WorkbenchExportDeliveryResult.Failed("staleGeneration")
            }

            val spec = try {
                gateway.grants.pickerForCreateDocument(identity.mimeType, displayName)
            } catch (_: IllegalArgumentException) {
                return@withContext WorkbenchExportDeliveryResult.Failed("invalidReceipt")
            }
            val incarnation = synchronized(lock) { ++incarnationCounter }
            val activeOperation = Active(
                incarnation = incarnation,
                spec = spec,
                staged = part,
                scratchDir = dir,
                expectedBytes = identity.byteCount,
                expectedSha = identity.sha256,
                mimeType = identity.mimeType,
                ownerProof = granted.ownerProof,
                cancel = SafCancelToken(),
                pending = CompletableDeferred(),
                settled = CompletableDeferred(),
            )
            synchronized(lock) {
                if (stopping || active != null) {
                    return@withContext WorkbenchExportDeliveryResult.Failed(
                        if (stopping) "staleGeneration" else "exportDeliveryBusy")
                }
                active = activeOperation
                admitted = activeOperation
                mutablePending.value = MediaWorkbenchPendingPick(
                    incarnation = incarnation, spec = spec, suggestedName = displayName)
            }
            try {
                val outcome = withTimeoutOrNull(PICK_TIMEOUT_MILLIS) {
                    activeOperation.pending.await()
                } ?: PickOutcome.HostCancelled("pickTimeout")
                if (synchronized(lock) { mutablePending.value?.incarnation == incarnation }) {
                    mutablePending.value = null
                }
                when (outcome) {
                    PickOutcome.UserCancelled -> WorkbenchExportDeliveryResult.Cancelled
                    is PickOutcome.HostCancelled -> {
                        if (outcome.reason == "rootStop") {
                            WorkbenchExportDeliveryResult.Failed("staleGeneration")
                        } else {
                            WorkbenchExportDeliveryResult.Failed("exportPickCancelled")
                        }
                    }
                    is PickOutcome.Uri -> writeVerified(
                        active = activeOperation,
                        uriString = outcome.uriString,
                        flags = outcome.flags,
                    )
                }
            } finally {
                if (synchronized(lock) { mutablePending.value?.incarnation == incarnation }) {
                    mutablePending.value = null
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            WorkbenchExportDeliveryResult.Failed(
                (error as? CreativeException)?.code ?: "exportDeliveryFailed")
        } finally {
            if (scratchDir != null) deleteScratch(scratchDir)
            synchronized(lock) {
                if (admitted != null && active === admitted) active = null
            }
            admitted?.settled?.complete(Unit)
            deliveryMutex.unlock()
        }
    }

    // MARK: - Destination write/read-back

    private suspend fun writeVerified(
        active: Active,
        uriString: String,
        flags: Int,
    ): WorkbenchExportDeliveryResult {
        if (synchronized(lock) { stopping } || active.cancel.isCancelled) {
            return WorkbenchExportDeliveryResult.Failed("staleGeneration")
        }
        val accepted = gateway.grants.acceptPickResult(active.spec, uriString, flags)
        when (accepted) {
            is PickAcceptResult.Cancelled -> return WorkbenchExportDeliveryResult.Cancelled
            is PickAcceptResult.Rejected -> return WorkbenchExportDeliveryResult.Failed("pickRejected")
            is PickAcceptResult.Accepted -> Unit
        }
        val granted = (accepted as PickAcceptResult.Accepted)
        if (!granted.granted.contains(SafAccessFlag.READ) ||
            !granted.granted.contains(SafAccessFlag.WRITE)
        ) {
            return WorkbenchExportDeliveryResult.Failed("writeGrantMissing")
        }
        val evidence = try {
            gateway.grants.currentAccess(granted.uri)
        } catch (_: Throwable) {
            null
        }
        val readLive = evidence?.let { it.read && it.probeRead != ProbeFlag.DENIED } ?: false
        val writeLive = evidence?.let { it.write && it.probeWrite != ProbeFlag.DENIED } ?: false
        if (!readLive || !writeLive) {
            return WorkbenchExportDeliveryResult.Failed("exportGrantNotLive")
        }
        val target = SafDocumentRef(
            tree = null,
            documentId = null,
            parentDocumentId = null,
            uri = granted.uri,
        )
        var written = 0L
        val readLease = SharedUriGrantAuthority.broker.retain(granted.uri, SafAccessFlag.READ)
        val writeLease = SharedUriGrantAuthority.broker.retain(granted.uri, SafAccessFlag.WRITE)
        try {
            when (val open = backend.openWriteTruncate(target, active.cancel)) {
                is WriteOpen.UnsupportedMode ->
                    return WorkbenchExportDeliveryResult.Failed("writeUnsupported")
                is WriteOpen.NotFound ->
                    return WorkbenchExportDeliveryResult.Failed("destinationNotFound")
                is WriteOpen.Opened -> {
                    try {
                        FileInputStream(active.staged).use { input ->
                            open.output.use { output ->
                                val buffer = ByteArray(64 * 1024)
                                while (true) {
                                    active.cancel.ensureActive()
                                    val read = input.read(buffer)
                                    if (read < 0) break
                                    output.write(buffer, 0, read)
                                    written += read
                                }
                                output.flush()
                            }
                        }
                    } catch (_: SafCancelledException) {
                        return if (written == 0L && deleteOwnedEmptyDestination(target)) {
                            WorkbenchExportDeliveryResult.Cancelled
                        } else {
                            WorkbenchExportDeliveryResult.Failed("exportCancelledPartial")
                        }
                    } catch (_: IOException) {
                        return WorkbenchExportDeliveryResult.Failed("exportWriteFailed")
                    }
                }
            }
            if (written != active.expectedBytes) {
                return WorkbenchExportDeliveryResult.Failed("exportLengthMismatch")
            }
            val readback = gateway.operations.streamRead(
                target,
                active.expectedBytes,
                null,
                active.cancel,
            ) { _, _ -> }
            return when (readback) {
                is SafOutcome.Failure -> {
                    if (readback.failure == com.floe.android.safgateway.SafFailure.Cancelled) {
                        WorkbenchExportDeliveryResult.Failed("exportCancelledPartial")
                    } else {
                        WorkbenchExportDeliveryResult.Failed("exportVerifyUnavailable")
                    }
                }
                is SafOutcome.Success -> {
                    val summary = readback.value
                    if (!summary.completed ||
                        summary.bytes != active.expectedBytes ||
                        !summary.sha256.equals(active.expectedSha, ignoreCase = true)
                    ) {
                        WorkbenchExportDeliveryResult.Failed("exportVerifyMismatch")
                    } else {
                        WorkbenchExportDeliveryResult.Delivered
                    }
                }
            }
        } finally {
            writeLease.release()
            readLease.release()
        }
    }

    /**
     * Only an empty document that this CREATE_DOCUMENT operation just created
     * is eligible for cleanup; any byte may already be a user-visible partial.
     */
    private fun deleteOwnedEmptyDestination(target: SafDocumentRef): Boolean = try {
        val outcome = gateway.operations.deleteDocument(target, SafCancelToken())
        outcome is SafOutcome.Success
    } catch (_: Throwable) {
        false
    }

    // MARK: - Authority/provenance

    /**
     * Re-authorizes the exact owner captured for this full receipt identity.
     *
     * There is deliberately no accepted-base-root fallback: a missing, stale
     * or foreign owner is a typed refusal (the UI/action must reopen the
     * project), and a root/epoch change rejects old claims. The returned root
     * is the native-issued per-project root, not the receipt path.
     */
    private suspend fun authorizeRoot(
        identity: MediaWorkbenchReceiptIdentity,
    ): MediaWorkbenchOwnerDecision {
        // The FULL receipt identity must have been observed from a real
        // platform status/observe/list reply and bound to a captured owner.
        // A prepared attempt or the receipt's own root/path is not enough.
        val captured = receipts.lookup(identity)
            ?: return MediaWorkbenchOwnerDecision.Refused("exportOwnerUnverified")
        val authority = hostProvider().r2Authority
        val resolved = try {
            authority.resolveProjectMediaRoot(captured.context)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: CreativeException) {
            return MediaWorkbenchOwnerDecision.Refused(
                when (error.code) {
                    "staleSession", "staleGeneration" -> "staleSession"
                    else -> error.code
                },
            )
        } catch (_: Throwable) {
            return MediaWorkbenchOwnerDecision.Refused("rendererUnavailable")
        }
        val live = runCatching { authority.isEpochLive(resolved.epoch) }.getOrDefault(false)
        return MediaWorkbenchExportAuthorization.authorize(
            identity = identity,
            captured = captured,
            resolved = MediaWorkbenchResolvedOwner(
                epoch = resolved.epoch,
                mediaRootPath = resolved.mediaRootPath,
                projectID = resolved.projectID,
                ownerProof = resolved.ownerProof,
                storageKey = resolved.storageKey,
                originKey = resolved.originKey,
                storage = resolved.storage,
            ),
            epochLive = live,
        )
    }

    /**
     * Resolves the CURRENT live native grant for one editor context.
     *
     * The captured proof is the durable project owner, never the ephemeral
     * session digest or the accepted base ancestor. A non-live epoch or an
     * incomplete echo yields no capture, so Save/Share stays refused.
     */
    private suspend fun captureOwner(
        context: CreativeProjectContext,
    ): MediaWorkbenchCapturedOwner? {
        val authority = hostProvider().r2Authority
        val grant = try {
            authority.resolveProjectMediaRoot(context)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            return null
        }
        if (grant.epoch <= 0L || !authority.isEpochLive(grant.epoch)) return null
        if (grant.projectID.isBlank() || grant.projectID != context.projectID) return null
        if (grant.mediaRootPath.isBlank() || grant.ownerProof.isBlank() ||
            grant.storageKey.isBlank()
        ) {
            return null
        }
        val canonicalRoot =
            MediaWorkbenchExportAuthorization.canonicalPath(grant.mediaRootPath) ?: return null
        return MediaWorkbenchCapturedOwner(
            context = context,
            epoch = grant.epoch,
            projectID = grant.projectID,
            canonicalRootPath = canonicalRoot,
            ownerProof = grant.ownerProof,
            storageKey = grant.storageKey,
            originKey = grant.originKey,
            storage = grant.storage,
        )
    }

    // MARK: - Helpers

    private fun isCurrentEpoch(epoch: Long): Boolean =
        boundEpoch <= 0L || epoch == boundEpoch

    private fun verifiedReceipt(status: MediaExportStatus): MediaExportReceipt? {
        if (status.state != MediaExportState.COMPLETED) return null
        return status.receipt
    }

    private fun safeDisplayName(raw: String): String? {
        val trimmed = raw.trim()
        if (trimmed.isEmpty() || trimmed.startsWith('.')) return null
        if (trimmed.any { it.code < 0x20 || it == '/' || it == '\\' }) return null
        if (trimmed.length <= MAX_DISPLAY_NAME) return trimmed
        val extension = trimmed.substringAfterLast('.', "")
        if (extension.isEmpty() || extension.length > 12) {
            return trimmed.take(MAX_DISPLAY_NAME)
        }
        val stem = trimmed.substringBeforeLast('.')
        return stem.take(MAX_DISPLAY_NAME - extension.length - 1) + "." + extension
    }

    private fun isWithin(root: File, candidate: File): Boolean = runCatching {
        val base = root.canonicalFile.path
        val path = candidate.canonicalFile.path
        path.startsWith(base + File.separator) && path != base
    }.getOrDefault(false)

    private fun deleteScratch(directory: File) {
        if (!isWithin(stagingRoot, directory)) return
        runCatching {
            directory.listFiles()?.forEach { it.delete() }
            directory.delete()
        }
    }
}
