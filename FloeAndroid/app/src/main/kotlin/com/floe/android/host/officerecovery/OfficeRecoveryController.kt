// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officerecovery

import java.io.File
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/**
 * App-owned recovery review and action controller.
 *
 * Cold start: [refresh] loads the durable journal, re-measures every referenced
 * artifact against the live App-owned roots, and publishes a review projection.
 * It NEVER opens, saves, retries, executes or deletes anything by itself.
 *
 * Actions are explicit and re-validate everything again at the moment of use:
 *  - open: re-hash the mutable working copy, then hand its exact path/digest
 *    to the existing Office viewer through [OfficeRecoveryOpenPort];
 *  - save a copy: only a module-verified OUTPUT_READY may be offered. The
 *    existing SAF Save-Copy controller performs the actual CREATE_DOCUMENT
 *    write and destination read-back; the journal records TRANSFERRING before
 *    the provider is touched and SAVED only on verified equality;
 *  - check destination: read the destination back under a LIVE grant. A
 *    missing/expired grant yields GrantRequired — never a write, never a
 *    silent re-take;
 *  - discard: delete ONLY the App-owned working copy and verified output for
 *    exactly one candidate; destination files chosen by the user are never
 *    touched.
 *
 * Process loss during TRANSFERRING is UNCERTAIN. Nothing retries it. The user
 * may check the destination or deliberately save a new copy; the original is
 * never overwritten.
 */
internal class OfficeRecoveryController(
    private val scope: CoroutineScope,
    private val journal: OfficeRecoveryJournal,
    private val artifacts: OfficeRecoveryArtifacts,
    private val exportPort: OfficeRecoveryExportPort,
    private val openPort: OfficeRecoveryOpenPort,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val now: () -> Long = { System.currentTimeMillis() },
) {
    private companion object {
        const val RESULT_OK = -1
        const val SAVED_RETENTION_MS = 30L * 24 * 60 * 60 * 1000
        const val CLEAN_RETENTION_MS = 7L * 24 * 60 * 60 * 1000
        val TERMINAL_EVICTABLE = setOf(
            OfficeRecoveryPhase.SAVED,
            OfficeRecoveryPhase.CLOSED_CLEAN,
            OfficeRecoveryPhase.DISCARDED,
        )
    }

    private val stateLock = Any()
    private val mutableState = MutableStateFlow(OfficeRecoveryState())
    val state: StateFlow<OfficeRecoveryState> = mutableState

    /** Internal failures retained for diagnostics, never ordinary UI copy. */
    @Volatile
    var diagnostic: Any? = null
        private set

    @Volatile
    private var views: List<OfficeRecoveryView> = emptyList()

    private var autoReview = true
    private var pendingExportRequest: String? = null
    private val originals = ConcurrentHashMap<String, OfficeRecoveryOriginalState>()
    private val pendingDiscards = ConcurrentHashMap<String, String>() // sessionToken -> candidateId

    init {
        scope.launch(ioDispatcher) { refreshInternal(initial = true, surfaceNew = false) }
    }

    // ------------------------------------------------------------------
    // Presentation
    // ------------------------------------------------------------------

    fun show() {
        publish { it.copy(visible = true, message = null) }
        refresh()
    }

    fun dismiss() {
        val launch = synchronized(stateLock) {
            val current = mutableState.value.launch
            if (current != null) pendingExportRequest = null
            mutableState.value = mutableState.value.copy(visible = false, launch = null)
            current
        }
        launch?.let { runCatching { exportPort.cancel(it.requestId) } }
    }

    fun select(candidateId: String) {
        if (views.none { it.id == candidateId }) return
        publish { it.copy(selectedId = candidateId, message = null) }
    }

    fun back() = publish { it.copy(selectedId = null, message = null) }

    fun refresh() {
        scope.launch(ioDispatcher) { refreshInternal(initial = false, surfaceNew = false) }
    }

    private fun publish(transform: (OfficeRecoveryState) -> OfficeRecoveryState) {
        synchronized(stateLock) { mutableState.value = transform(mutableState.value) }
    }

    private fun view(candidateId: String): OfficeRecoveryView? = views.firstOrNull { it.id == candidateId }

    // ------------------------------------------------------------------
    // Explicit actions
    // ------------------------------------------------------------------

    fun open(candidateId: String) {
        val current = view(candidateId) ?: return
        if (!current.canOpen) {
            publish { it.copy(message = "openUnavailable") }
            return
        }
        publish { it.copy(busyId = candidateId, message = null) }
        scope.launch(ioDispatcher) {
            val candidate = runCatching { journal.candidate(candidateId) }.getOrNull()
            val working = candidate?.let { artifacts.inspectWorkingCopy(it) }
            if (candidate == null || working?.state != OfficeRecoveryFileState.AVAILABLE ||
                working.sha256 == null
            ) {
                finishBusy(candidateId, "openUnavailable")
                return@launch
            }
            if (openPort.activeCandidateId() == candidateId) {
                finishBusy(candidateId, "alreadyOpen")
                return@launch
            }
            val result = runCatching { openPort.open(candidate, working.sha256, working.bytes) }
                .getOrElse { OfficeRecoveryOpenResult.Refused(it.javaClass.simpleName) }
            when (result) {
                is OfficeRecoveryOpenResult.Accepted -> {
                    runCatching { journal.touchWorkingCopyBase(candidateId, working.sha256, working.bytes) }
                        .onFailure { diagnostic = it }
                    publish {
                        // Keep the review sheet mounted behind the viewer: a
                        // failed/returning mount must remain reachable in this
                        // same process, and the user can dismiss it explicitly.
                        it.copy(
                            busyId = null,
                            selectedId = null,
                            message = null,
                        )
                    }
                    refreshInternal(initial = false, surfaceNew = false)
                }
                is OfficeRecoveryOpenResult.Refused -> finishBusy(candidateId, "openUnavailable")
            }
        }
    }

    fun saveCopy(candidateId: String) {
        val current = view(candidateId) ?: return
        if (!current.canExport || current.output != OfficeRecoveryFileState.AVAILABLE) {
            publish { it.copy(message = "exportUnavailable") }
            return
        }
        if (synchronized(stateLock) { mutableState.value.launch != null }) return
        publish { it.copy(busyId = candidateId, message = null) }
        scope.launch(ioDispatcher) {
            val candidate = runCatching { journal.candidate(candidateId) }.getOrNull()
            val output = candidate?.let { artifacts.inspectOutput(it) }
            val format = candidate?.outputFormat?.lowercase(Locale.ROOT)
            if (candidate == null || output?.state != OfficeRecoveryFileState.AVAILABLE ||
                output.sha256 == null || candidate.outputPath == null || format == null
            ) {
                finishBusy(candidateId, "exportUnavailable")
                return@launch
            }
            val source = OfficeRecoveryVerifiedSource(
                path = candidate.outputPath,
                sha256 = output.sha256,
                bytes = output.bytes,
                format = format,
            )
            val prepared = runCatching { exportPort.prepare(candidate, source) }
                .getOrElse { OfficeRecoveryPrepareOutcome.Refused(it.javaClass.simpleName) }
            when (prepared) {
                is OfficeRecoveryPrepareOutcome.Ready -> publish {
                    it.copy(
                        busyId = null,
                        message = null,
                        launch = OfficeRecoveryExportLaunch(
                            requestId = prepared.requestId,
                            candidateId = candidateId,
                            spec = prepared.spec,
                        ),
                    )
                }
                is OfficeRecoveryPrepareOutcome.Refused -> {
                    diagnostic = prepared.code
                    finishBusy(candidateId, "exportUnavailable")
                }
            }
        }
    }

    /**
     * Re-authorise the EXACT uncertain destination through the existing
     * OPEN_DOCUMENT picker. The result is accepted only when it names the same
     * destination identity and its bytes still verify; a different file is
     * never treated as the previous destination.
     */
    fun reauthorizeDestination(candidateId: String) {
        val current = view(candidateId) ?: return
        if (!current.canCheckDestination) {
            publish { it.copy(message = "checkUnavailable") }
            return
        }
        val candidate = runCatching { journal.candidate(candidateId) }.getOrNull() ?: return
        if (candidate.destinationUri == null || candidate.outputSha256 == null || candidate.outputBytes <= 0L) {
            publish { it.copy(message = "checkUnavailable") }
            return
        }
        publish { it.copy(busyId = candidateId, message = null) }
        scope.launch(ioDispatcher) {
            val prepared = runCatching { exportPort.prepareDestinationReauthorization(candidate) }
                .getOrElse { OfficeRecoveryPrepareOutcome.Refused(it.javaClass.simpleName) }
            when (prepared) {
                is OfficeRecoveryPrepareOutcome.Ready -> publish {
                    it.copy(
                        busyId = null,
                        message = null,
                        launch = OfficeRecoveryExportLaunch(
                            requestId = prepared.requestId,
                            candidateId = candidateId,
                            spec = prepared.spec,
                            purpose = OfficeRecoveryLaunchPurpose.REAUTHORIZE,
                        ),
                    )
                }
                is OfficeRecoveryPrepareOutcome.Refused -> finishBusy(candidateId, "checkUnavailable")
            }
        }
    }

    /**
     * The effect forwards the ACTUAL system picker result for one prepared
     * launch. Cancellation never writes. An accepted URI is persisted as
     * TRANSFERRING BEFORE the provider is touched; a failed journal commit
     * aborts with no write.
     */
    fun onPickerResult(requestId: String, resultCode: Int, uriString: String?, resultFlags: Int) {
        var matched: OfficeRecoveryExportLaunch? = null
        synchronized(stateLock) {
            val current = mutableState.value.launch
            if (current != null && current.requestId == requestId) {
                mutableState.value = mutableState.value.copy(launch = null, busyId = current.candidateId)
                matched = current
            }
        }
        val launch = matched ?: return
        if (resultCode != RESULT_OK || uriString.isNullOrBlank()) {
            runCatching { exportPort.cancel(requestId) }
            finishBusy(launch.candidateId, "cancelled")
            return
        }
        val acceptedUri = uriString ?: return
        if (launch.purpose == OfficeRecoveryLaunchPurpose.REAUTHORIZE) {
            scope.launch(ioDispatcher) {
                val candidate = runCatching { journal.candidate(launch.candidateId) }.getOrNull()
                val expectedUri = candidate?.destinationUri
                val expectedSha = candidate?.outputSha256
                val expectedBytes = candidate?.outputBytes ?: 0L
                if (candidate == null || expectedUri == null || expectedSha == null || expectedBytes <= 0L) {
                    runCatching { exportPort.cancel(requestId) }
                    finishBusy(launch.candidateId, "checkUnavailable")
                    return@launch
                }
                val result = runCatching {
                    exportPort.deliverDestinationReauthorization(
                        requestId,
                        acceptedUri,
                        resultFlags,
                        expectedUri,
                        expectedSha,
                        expectedBytes,
                    )
                }.getOrElse { OfficeRecoveryDestinationCheck.Unavailable(it.javaClass.simpleName) }
                when (result) {
                    is OfficeRecoveryDestinationCheck.Verified -> {
                        journal.settleSave(
                            launch.candidateId,
                            candidate.outputOpId ?: "destination-reauthorized",
                            OfficeRecoverySaveFacts(
                                saved = true,
                                uncertain = false,
                                code = null,
                                destinationUri = expectedUri,
                                destinationSha256 = result.sha256,
                                destinationBytes = result.bytes,
                            ),
                        )
                        finishBusy(launch.candidateId, "checkSaved")
                    }
                    is OfficeRecoveryDestinationCheck.Differs -> {
                        runCatching {
                            journal.update(launch.candidateId) {
                                it.copy(
                                    phase = OfficeRecoveryPhase.UNCERTAIN,
                                    destinationVerified = false,
                                    lastErrorCode = "destination-differs",
                                    updatedAtMillis = now(),
                                )
                            }
                        }
                        finishBusy(launch.candidateId, "checkDiffers")
                    }
                    is OfficeRecoveryDestinationCheck.GrantRequired -> {
                        runCatching {
                            journal.update(launch.candidateId) {
                                it.copy(
                                    phase = OfficeRecoveryPhase.UNCERTAIN,
                                    destinationVerified = false,
                                    lastErrorCode = "grant-required",
                                    updatedAtMillis = now(),
                                )
                            }
                        }
                        finishBusy(launch.candidateId, "checkGrant")
                    }
                    is OfficeRecoveryDestinationCheck.Unavailable -> finishBusy(launch.candidateId, "checkUnavailable")
                }
                refreshInternal(initial = false, surfaceNew = false)
            }
            return
        }
        scope.launch(ioDispatcher) {
            val started = runCatching {
                journal.markTransferStarted(launch.candidateId, requestId, acceptedUri)
            }.getOrDefault(false)
            if (!started) {
                runCatching { exportPort.cancel(requestId) }
                finishBusy(launch.candidateId, "journalUnavailable")
                return@launch
            }
            val fenced = synchronized(stateLock) {
                if (pendingExportRequest != null) false
                else {
                    pendingExportRequest = requestId
                    true
                }
            }
            if (!fenced) {
                finishBusy(launch.candidateId, "stale")
                return@launch
            }
            val scheduled = runCatching {
                exportPort.deliver(requestId, acceptedUri, resultFlags) { outcome ->
                    onExportOutcome(launch.candidateId, outcome)
                }
            }.getOrDefault(false)
            if (!scheduled) {
                synchronized(stateLock) { if (pendingExportRequest == requestId) pendingExportRequest = null }
                journal.settleSave(
                    launch.candidateId,
                    journal.candidate(launch.candidateId)?.outputOpId ?: requestId,
                    OfficeRecoverySaveFacts(
                        saved = false,
                        uncertain = false,
                        code = "scheduler-unavailable",
                        destinationUri = null,
                        destinationSha256 = null,
                        destinationBytes = 0L,
                    ),
                )
                finishBusy(launch.candidateId, "exportUnavailable")
            }
        }
    }

    fun onPickerLaunchFailed(requestId: String) {
        var matched: OfficeRecoveryExportLaunch? = null
        synchronized(stateLock) {
            val current = mutableState.value.launch
            if (current != null && current.requestId == requestId) {
                mutableState.value = mutableState.value.copy(launch = null)
                matched = current
            }
        }
        val launch = matched ?: return
        runCatching { exportPort.cancel(requestId) }
        finishBusy(
            launch.candidateId,
            if (launch.purpose == OfficeRecoveryLaunchPurpose.REAUTHORIZE) "checkUnavailable" else "exportUnavailable",
        )
    }

    private fun onExportOutcome(candidateId: String, outcome: OfficeRecoveryExportOutcome) {
        // The Save-Copy callback runs on the gateway IO thread; journal writes
        // and artifact re-measurement must never block that lane.
        scope.launch(ioDispatcher) {
            val matched = synchronized(stateLock) {
                if (pendingExportRequest != outcome.requestId) false
                else {
                    pendingExportRequest = null
                    true
                }
            }
            if (!matched) return@launch
            if (outcome !is OfficeRecoveryExportOutcome.Stale) {
                val facts = when (outcome) {
                    is OfficeRecoveryExportOutcome.Saved -> OfficeRecoverySaveFacts(
                        saved = true,
                        uncertain = false,
                        code = null,
                        destinationUri = outcome.destinationUri,
                        destinationSha256 = outcome.sha256,
                        destinationBytes = outcome.bytes,
                    )
                    is OfficeRecoveryExportOutcome.Uncertain -> OfficeRecoverySaveFacts(
                        saved = false,
                        uncertain = true,
                        code = outcome.code,
                        destinationUri = outcome.destinationUri,
                        destinationSha256 = null,
                        destinationBytes = 0L,
                    )
                    is OfficeRecoveryExportOutcome.Failed -> OfficeRecoverySaveFacts(
                        saved = false,
                        uncertain = false,
                        code = outcome.code,
                        destinationUri = null,
                        destinationSha256 = null,
                        destinationBytes = 0L,
                    )
                    is OfficeRecoveryExportOutcome.Cancelled -> OfficeRecoverySaveFacts(
                        saved = false,
                        uncertain = false,
                        code = outcome.code,
                        destinationUri = null,
                        destinationSha256 = null,
                        destinationBytes = 0L,
                    )
                    is OfficeRecoveryExportOutcome.Stale -> null
                }
                if (facts != null) {
                    runCatching {
                        journal.settleSave(
                            candidateId,
                            journal.candidate(candidateId)?.outputOpId ?: outcome.requestId,
                            facts,
                        )
                    }.onFailure { diagnostic = it }
                }
            }
            val key = when (outcome) {
                is OfficeRecoveryExportOutcome.Saved -> "saved"
                is OfficeRecoveryExportOutcome.Uncertain -> "saveUncertain"
                is OfficeRecoveryExportOutcome.Failed -> "saveFailed"
                is OfficeRecoveryExportOutcome.Cancelled -> "cancelled"
                is OfficeRecoveryExportOutcome.Stale -> "stale"
            }
            publish { it.copy(busyId = null, message = key) }
            refreshInternal(initial = false, surfaceNew = false)
        }
    }

    fun checkDestination(candidateId: String) {
        val current = view(candidateId) ?: return
        if (!current.canCheckDestination || current.destinationVerified) {
            publish { it.copy(message = "checkUnavailable") }
            return
        }
        val candidate = runCatching { journal.candidate(candidateId) }.getOrNull() ?: return
        val uri = candidate.destinationUri ?: return
        if (candidate.outputSha256 == null || candidate.outputBytes <= 0L) {
            publish { it.copy(message = "checkUnavailable") }
            return
        }
        publish { it.copy(busyId = candidateId, message = null) }
        scope.launch(ioDispatcher) {
            val result = runCatching {
                exportPort.checkDestination(uri, candidate.outputSha256, candidate.outputBytes)
            }.getOrElse { OfficeRecoveryDestinationCheck.Unavailable(it.javaClass.simpleName) }
            when (result) {
                is OfficeRecoveryDestinationCheck.Verified -> {
                    journal.settleSave(
                        candidateId,
                        candidate.outputOpId ?: "destination-check",
                        OfficeRecoverySaveFacts(
                            saved = true,
                            uncertain = false,
                            code = null,
                            destinationUri = uri,
                            destinationSha256 = result.sha256,
                            destinationBytes = result.bytes,
                        ),
                    )
                    finishBusy(candidateId, "checkSaved")
                }
                is OfficeRecoveryDestinationCheck.Differs -> {
                    runCatching {
                        journal.update(candidateId) {
                            it.copy(
                                phase = OfficeRecoveryPhase.UNCERTAIN,
                                destinationVerified = false,
                                lastErrorCode = "destination-differs",
                                updatedAtMillis = now(),
                            )
                        }
                    }
                    finishBusy(candidateId, "checkDiffers")
                }
                is OfficeRecoveryDestinationCheck.GrantRequired -> {
                    runCatching {
                        journal.update(candidateId) {
                            it.copy(
                                phase = OfficeRecoveryPhase.UNCERTAIN,
                                destinationVerified = false,
                                lastErrorCode = "grant-required",
                                updatedAtMillis = now(),
                            )
                        }
                    }
                    finishBusy(candidateId, "checkGrant")
                }
                is OfficeRecoveryDestinationCheck.Unavailable -> finishBusy(candidateId, "checkUnavailable")
            }
            refreshInternal(initial = false, surfaceNew = false)
        }
    }

    fun probeOriginal(candidateId: String) {
        val candidate = runCatching { journal.candidate(candidateId) }.getOrNull() ?: return
        if (openPort.activeCandidateId() == candidateId) {
            publish { it.copy(message = "alreadyOpen") }
            return
        }
        publish { it.copy(busyId = candidateId, message = null) }
        scope.launch(ioDispatcher) {
            val result = runCatching { openPort.probeOriginal(candidate) }
                .getOrElse { OfficeRecoveryOriginalState.UNAVAILABLE }
            originals[candidateId] = result
            val key = when (result) {
                OfficeRecoveryOriginalState.UNCHANGED -> "originalUnchanged"
                OfficeRecoveryOriginalState.CHANGED -> "originalChanged"
                OfficeRecoveryOriginalState.UNAVAILABLE -> "originalUnavailable"
                OfficeRecoveryOriginalState.NOT_APPLICABLE -> "originalUnavailable"
            }
            finishBusy(candidateId, key)
            refreshInternal(initial = false, surfaceNew = false)
        }
    }

    fun discard(candidateId: String) {
        val current = view(candidateId) ?: return
        if (!current.canDiscard) {
            publish { it.copy(message = "discardBusy") }
            return
        }
        publish { it.copy(busyId = candidateId, message = null) }
        scope.launch(ioDispatcher) {
            val candidate = runCatching { journal.candidate(candidateId) }.getOrNull()
            if (candidate == null) {
                finishBusy(candidateId, null)
                return@launch
            }
            val busy = openPort.activeCandidateId() == candidateId ||
                exportPort.hasActiveFor(candidateId) ||
                candidate.originSessionToken?.let { exportPort.isSessionBusy(it) } == true
            if (busy) {
                finishBusy(candidateId, "discardBusy")
                return@launch
            }
            val cleaned = runCatching { artifacts.deleteOwned(candidate) }.getOrDefault(false)
            val removed = cleaned && runCatching { journal.remove(candidateId) }.isSuccess
            if (removed) {
                originals.remove(candidateId)
                publish {
                    it.copy(
                        busyId = null,
                        selectedId = null,
                        message = "discarded",
                    )
                }
            } else {
                runCatching {
                    journal.update(candidateId) {
                        it.copy(lastErrorCode = "cleanup-failed", updatedAtMillis = now())
                    }
                }
                finishBusy(candidateId, "discardFailed")
            }
            refreshInternal(initial = false, surfaceNew = false)
        }
    }

    /**
     * Reclaim terminal records BEFORE adding a new candidate. The journal's
     * own eviction callback must never run under the journal lock while it
     * inspects the viewer/handoff locks; this App-owned pass is called on the
     * IO dispatcher and performs the same safety checks without nesting them.
     * Only SAVED / CLOSED_CLEAN / DISCARDED records are eligible; active,
     * exporting, uncertain, export-ready and closed-unsaved records are not.
     */
    internal fun reclaimCapacity() {
        if (!runCatching { journal.isFull() }.getOrDefault(false)) return
        val active = runCatching { openPort.activeCandidateId() }.getOrNull()
        val ordered = runCatching { journal.snapshot() }.getOrDefault(emptyList())
            .sortedBy { it.updatedAtMillis }
        for (candidate in ordered) {
            if (!runCatching { journal.isFull() }.getOrDefault(false)) return
            if (candidate.phase !in TERMINAL_EVICTABLE) continue
            if (candidate.id == active) continue
            if (runCatching { exportPort.hasActiveFor(candidate.id) }.getOrDefault(true)) continue
            if (candidate.phase == OfficeRecoveryPhase.SAVED) {
                if (!candidate.destinationVerified) continue
                val working = artifacts.inspectWorkingCopy(candidate)
                if (laterWorkingBytes(candidate, working)) continue
            }
            val tokenBusy = candidate.originSessionToken?.let {
                runCatching { exportPort.isSessionBusy(it) }.getOrDefault(true)
            } == true
            if (tokenBusy) continue
            if (runCatching { artifacts.deleteOwned(candidate) }.getOrDefault(false)) {
                runCatching { journal.remove(candidate.id) }
            }
        }
    }

    // ------------------------------------------------------------------
    // Viewer reconcile / quiescence
    // ------------------------------------------------------------------

    /**
     * Called by the App Office controller ONLY with the actual viewer result
     * (or an explicit discard the user chose). The immutable snapshot has
     * already been released by the caller; this only reconciles the mixed
     * working copy and verified outputs.
     */
    fun onViewerClosed(
        candidateId: String?,
        sessionToken: String?,
        resultPresent: Boolean,
        closedCleanly: Boolean,
        dirtyAtClose: Boolean,
        discarded: Boolean,
        outputDescriptors: List<String>,
    ) {
        if (candidateId == null) return
        scope.launch(ioDispatcher) {
            val candidate = runCatching { journal.candidate(candidateId) }.getOrNull() ?: return@launch
            if (discarded) {
                runCatching {
                    journal.markViewerClosed(
                        candidateId, resultPresent, closedCleanly, dirtyAtClose, true,
                    )
                }
                val token = sessionToken ?: candidate.originSessionToken
                if (token != null && exportPort.isSessionBusy(token)) {
                    pendingDiscards[token] = candidateId
                } else {
                    val latest = runCatching { journal.candidate(candidateId) }.getOrNull()
                    if (latest != null && runCatching { artifacts.deleteOwned(latest) }.getOrDefault(false)) {
                        runCatching { journal.remove(candidateId) }
                    }
                }
                refreshInternal(initial = false, surfaceNew = false)
                return@launch
            }
            if (candidate.outputPath == null) {
                adoptMissedOutput(candidate, outputDescriptors)
            }
            val changedAfterSave = if (candidate.phase == OfficeRecoveryPhase.SAVED) {
                laterWorkingBytes(candidate, artifacts.inspectWorkingCopy(candidate))
            } else {
                null
            }
            runCatching {
                journal.markViewerClosed(
                    candidateId, resultPresent, closedCleanly, dirtyAtClose, false,
                    workingCopyChangedAfterSave = changedAfterSave,
                )
            }
            refreshInternal(initial = false, surfaceNew = true)
        }
    }

    /** One session fully drained (no scheduled save IO remains). */
    fun onSessionQuiescent(sessionToken: String) {
        val candidateId = pendingDiscards.remove(sessionToken) ?: return
        scope.launch(ioDispatcher) {
            val candidate = runCatching { journal.candidate(candidateId) }.getOrNull() ?: return@launch
            if (candidate.phase == OfficeRecoveryPhase.DISCARDED &&
                runCatching { artifacts.deleteOwned(candidate) }.getOrDefault(false)
            ) {
                runCatching { journal.remove(candidateId) }
            }
            refreshInternal(initial = false, surfaceNew = false)
        }
    }

    /**
     * The viewer result carries bounded OUTPUT_READY descriptors specifically
     * so a missed host-channel receipt can be recovered without a live engine.
     * Adopt only the newest descriptor whose actual bytes still verify against
     * an owned output path, and only when no output is already recorded.
     */
    private fun adoptMissedOutput(candidate: OfficeRecoveryCandidate, descriptors: List<String>) {
        for (receipt in outputReadyReceipts(descriptors).asReversed()) {
            val path = receipt.outputDocumentPath ?: continue
            val generation = runCatching { File(path).parentFile?.name?.toLong() }.getOrNull() ?: continue
            if (generation < 1L) continue
            val probe = candidate.copy(
                outputPath = path,
                outputSha256 = receipt.outputSha256,
                outputBytes = receipt.outputBytes,
                outputFormat = receipt.format?.lowercase(Locale.ROOT),
                outputOpId = receipt.opId,
                outputNativeGeneration = generation,
            )
            if (artifacts.inspectOutput(probe).state != OfficeRecoveryFileState.AVAILABLE) continue
            val adopted = receipt.copy(
                generation = generation,
                sessionToken = candidate.originSessionToken.orEmpty(),
            )
            if (journal.recordOutputReady(candidate.id, adopted)) return
        }
    }

    // ------------------------------------------------------------------
    // Refresh / projection
    // ------------------------------------------------------------------

    private fun finishBusy(candidateId: String, message: String?) {
        publish {
            if (it.busyId != candidateId) it else it.copy(busyId = null, message = message ?: it.message)
        }
    }

    private fun refreshInternal(initial: Boolean, surfaceNew: Boolean) {
        val candidates = runCatching { journal.snapshot() }.getOrElse {
            diagnostic = it
            emptyList()
        }
        val nowMillis = now()
        val active = runCatching { openPort.activeCandidateId() }.getOrNull()
        val busy = synchronized(stateLock) { mutableState.value.busyId }
        val retained = ArrayList<OfficeRecoveryCandidate>(candidates.size)
        for (candidate in candidates) {
            if (runCatching { sweep(candidate, nowMillis, active) }.getOrDefault(false)) continue
            retained += candidate
        }
        // Cold start: a TRANSFERRING record can have no live writer in THIS
        // process. Normalize it to UNCERTAIN once, before any user action, so
        // the destination is reviewable/checkable and never auto-retried.
        val projection = if (initial) {
            retained.map { candidate ->
                if (candidate.phase == OfficeRecoveryPhase.TRANSFERRING) {
                    runCatching {
                        journal.update(candidate.id) { current ->
                            current.copy(
                                phase = OfficeRecoveryPhase.UNCERTAIN,
                                lastErrorCode = "process-loss",
                                updatedAtMillis = now(),
                            )
                        }
                    }.getOrNull() ?: candidate.copy(
                        phase = OfficeRecoveryPhase.UNCERTAIN,
                        lastErrorCode = "process-loss",
                    )
                } else {
                    candidate
                }
            }
        } else {
            retained
        }
        // A SAVED record certifies only the working-copy base captured at the
        // verified save/output. If the actual working copy has since received
        // later bytes (including after process loss), keep those bytes
        // unresolved; the earlier destination must not certify them.
        val reconciled = projection.map { candidate ->
            if (candidate.phase != OfficeRecoveryPhase.SAVED) {
                candidate
            } else {
                val working = artifacts.inspectWorkingCopy(candidate)
                val laterBytes = laterWorkingBytes(candidate, working)
                if (!laterBytes) {
                    candidate
                } else {
                    runCatching {
                        journal.update(candidate.id) { current ->
                            current.copy(
                                phase = OfficeRecoveryPhase.CLOSED_UNSAVED,
                                lastErrorCode = "unsaved-after-save",
                                updatedAtMillis = now(),
                            )
                        }
                    }.getOrNull() ?: candidate.copy(
                        phase = OfficeRecoveryPhase.CLOSED_UNSAVED,
                        lastErrorCode = "unsaved-after-save",
                    )
                }
            }
        }
        val nextViews = reconciled.map { toView(it, active, busy) }
        views = nextViews
        val shouldSurface = synchronized(stateLock) {
            val current = mutableState.value
            val surface = (initial && autoReview && nextViews.any { it.unresolved }) ||
                (surfaceNew && nextViews.any { it.unresolved })
            if (initial) autoReview = false
            current.copy(
                loading = false,
                visible = current.visible || surface,
                selectedId = current.selectedId?.takeIf { id -> nextViews.any { it.id == id } },
                candidates = nextViews,
            )
        }
        synchronized(stateLock) { mutableState.value = shouldSurface }
    }

    /**
     * Bounded retention ONLY for App-owned candidates:
     *  - SAVED older than 30 days and CLOSED_CLEAN older than 7 days are
     *    deleted + dropped, but a SAVED record is skipped unless it is
     *    destination-verified and the actual working copy has no later bytes;
     *  - DISCARDED records are deleted as soon as no session/export is busy;
     *  - active, uncertain, export-ready and closed-unsaved records are NEVER
     *    swept — even if their files are missing (the truthful failure stays
     *    reviewable until the user discards it).
     */
    private fun sweep(
        candidate: OfficeRecoveryCandidate,
        nowMillis: Long,
        activeCandidateId: String?,
    ): Boolean {
        if (activeCandidateId == candidate.id) return false
        val age = nowMillis - candidate.updatedAtMillis
        val tokenBusy = candidate.originSessionToken?.let { exportPort.isSessionBusy(it) } == true
        val exportBusy = exportPort.hasActiveFor(candidate.id)
        val expired = when (candidate.phase) {
            OfficeRecoveryPhase.DISCARDED -> true
            OfficeRecoveryPhase.SAVED -> age > SAVED_RETENTION_MS
            OfficeRecoveryPhase.CLOSED_CLEAN -> age > CLEAN_RETENTION_MS
            else -> false
        }
        if (!expired || tokenBusy || exportBusy) return false
        if (candidate.phase == OfficeRecoveryPhase.SAVED) {
            if (!candidate.destinationVerified) return false
            val working = artifacts.inspectWorkingCopy(candidate)
            if (laterWorkingBytes(candidate, working)) return false
        }
        if (!runCatching { artifacts.deleteOwned(candidate) }.getOrDefault(false)) return false
        runCatching { journal.remove(candidate.id) }
        return true
    }

    /**
     * True only when the ACTUAL working copy contains bytes that are neither
     * the verified output nor the working-copy base captured when that output
     * was produced. Missing/corrupt working copies have no later recoverable
     * bytes; a SAVED record may then be capacity-reclaimed without losing a
     * later unsaved copy.
     */
    private fun laterWorkingBytes(
        candidate: OfficeRecoveryCandidate,
        working: OfficeRecoveryArtifacts.WorkingFacts,
    ): Boolean {
        if (working.state != OfficeRecoveryFileState.AVAILABLE) return false
        val actual = working.sha256 ?: return false
        val output = candidate.outputSha256
        val baseAtOutput = candidate.outputWorkingCopyBaseSha256
        val savedBase = candidate.savedWorkingCopySha256
        return when {
            output != null && actual == output -> false
            baseAtOutput != null && actual == baseAtOutput -> false
            savedBase != null && actual == savedBase -> false
            output != null || baseAtOutput != null -> true
            savedBase != null -> true
            else -> candidate.dirtyAtClose != false
        }
    }

    private fun toView(
        candidate: OfficeRecoveryCandidate,
        activeCandidateId: String?,
        busyId: String?,
    ): OfficeRecoveryView {
        val working = artifacts.inspectWorkingCopy(candidate)
        val output = if (candidate.hasVerifiedOutput) {
            artifacts.inspectOutput(candidate)
        } else {
            OfficeRecoveryArtifacts.OutputFacts(OfficeRecoveryFileState.MISSING)
        }
        val active = activeCandidateId == candidate.id
        val busy = busyId == candidate.id
        val original = originals[candidate.id]
        val limitations = candidate.materialLimitations().toMutableList()
        when (original) {
            OfficeRecoveryOriginalState.CHANGED -> limitations += OfficeRecoveryLimitation.ORIGINAL_CHANGED
            OfficeRecoveryOriginalState.UNAVAILABLE -> limitations += OfficeRecoveryLimitation.ORIGINAL_UNAVAILABLE
            else -> Unit
        }
        if (candidate.phase == OfficeRecoveryPhase.CLOSED_UNSAVED && candidate.outputPath != null) {
            limitations += OfficeRecoveryLimitation.UNSAVED_AFTER_SAVE
        }
        if (working.state != OfficeRecoveryFileState.AVAILABLE ||
            (candidate.hasVerifiedOutput && output.state != OfficeRecoveryFileState.AVAILABLE)
        ) {
            limitations += OfficeRecoveryLimitation.MISSING_OR_CORRUPT
        }
        return OfficeRecoveryView(
            id = candidate.id,
            displayName = candidate.displayName,
            format = candidate.format,
            phase = candidate.phase,
            updatedAtMillis = candidate.updatedAtMillis,
            workingCopy = working.state,
            workingCopySha256 = working.sha256,
            workingCopyBytes = working.bytes,
            workingCopyChangedSinceBase = working.changedSinceBase,
            output = output.state,
            outputBytes = output.bytes,
            canOpen = working.state == OfficeRecoveryFileState.AVAILABLE && !active && !busy,
            canExport = output.state == OfficeRecoveryFileState.AVAILABLE &&
                candidate.phase != OfficeRecoveryPhase.DISCARDED &&
                !(candidate.phase == OfficeRecoveryPhase.CLOSED_UNSAVED &&
                    candidate.lastErrorCode == "unsaved-after-save") &&
                !active && !busy,
            canCheckDestination = candidate.phase == OfficeRecoveryPhase.UNCERTAIN &&
                candidate.destinationUri != null && !active && !busy,
            canProbeOriginal = !active && !busy &&
                candidate.route != OfficeRecoveryRoute.RUN_OUTPUT &&
                (candidate.originalUri != null || candidate.sourceLogicalPath != null),
            canDiscard = !active && !busy && !exportPort.hasActiveFor(candidate.id),
            destinationVerified = candidate.destinationVerified,
            originalState = original,
            limitations = limitations,
            lastErrorCode = candidate.lastErrorCode,
            dirtyAtClose = candidate.dirtyAtClose,
        )
    }
}
