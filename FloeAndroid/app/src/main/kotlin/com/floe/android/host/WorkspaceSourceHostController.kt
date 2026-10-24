// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.bridge.WorkspaceSourceNative
import com.floe.android.safgateway.ChildScan
import com.floe.android.safgateway.CommitPermit
import com.floe.android.safgateway.PageRequest
import com.floe.android.safgateway.PickAcceptResult
import com.floe.android.safgateway.PickKind
import com.floe.android.safgateway.PickRequestSpec
import com.floe.android.safgateway.PreparedSave
import com.floe.android.safgateway.PreparedState
import com.floe.android.safgateway.ProbeFlag
import com.floe.android.safgateway.ReleaseResult
import com.floe.android.safgateway.SafAccessFlag
import com.floe.android.safgateway.SafCancelToken
import com.floe.android.safgateway.SafCancelledException
import com.floe.android.safgateway.SafDocument
import com.floe.android.safgateway.SafDocumentRef
import com.floe.android.safgateway.SafFailure
import com.floe.android.safgateway.SafGatewayService
import com.floe.android.safgateway.SafOperation
import com.floe.android.safgateway.SafOutcome
import com.floe.android.safgateway.SafPlatformBackend
import com.floe.android.safgateway.SafSharedGrantBroker
import com.floe.android.safgateway.SafSize
import com.floe.android.safgateway.SafUriKind
import com.floe.android.safgateway.SafUriRef
import com.floe.android.safgateway.SavePolicy
import com.floe.android.safgateway.SaveReceipt
import com.floe.android.safgateway.StagedCopy
import com.floe.android.safgateway.StagedLocalRef
import com.floe.android.safgateway.WriteOpen
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject

/**
 * G04-R1 trusted provider SOURCE HOST lane (App side).
 *
 * The controller the reusable Files/Workspace picker drives. It owns NOTHING
 * authoritative: Swift owns source registration, journal 47, the working-copy
 * commit and every digest (`floe_g04_source_host_*`, see
 * G04WorkspaceSourceHostAPI.swift + the G04WorkspaceSourceCoordinator
 * file-backed overloads). The lane owns exactly four things, each fenced by
 * the FULL captured identity (taskID + workspaceID + nativeEpoch +
 * hostGeneration + launchIncarnation):
 *
 *  1. pending platform-pick requests — the composition launches
 *     `SafPickerIntents.from(spec)` through StartActivityForResult so the
 *     ACTUAL returned intent flags survive; a callback the launch-ownership
 *     ledger does not dispatch to THIS incarnation is dropped with no
 *     controller call and no state write (accepted attachment/skills
 *     discipline);
 *  2. grant acceptance — `acceptPickResult` + per-flag reference retain run
 *     inside ONE `SharedUriGrantAuthority.withExclusiveAuthority` section;
 *     the OS persisted-permission probe stays the sole grant truth and this
 *     lane caches nothing as authority; a cancel result is never a grant;
 *  3. the chunked byte pump between real ContentResolver streams and the
 *     trusted native staging — 64 KiB pages under the ORIGINAL 1 GiB
 *     transfer-entry provider budget (the 4 MiB editable-document mailbox cap
 *     does NOT apply to ordinary provider files here, and nothing buffers a
 *     whole file);
 *  4. lifecycle settlement — cancel is only a REQUEST; every gateway
 *     operation is awaited through actual IO and stream-close
 *     (`SafOperation.isDone/await`), native tickets are always finished,
 *     consumed or aborted on every path, journaled ladder rows stay honestly
 *     pending for reconcile, and a rebound root (new epoch) or replaced owner
 *     fence can never be touched by this lane's late work.
 *
 * There is deliberately no model-facing entry: the callers are the App's own
 * Files inspector UI (WorkspaceSourcePicker) and the Application-owned
 * bootstrap/reconciliation hooks.
 */
internal class WorkspaceSourceHostController(
    /** Caller-owned directory for the gateway-side recovery originals and
     * the replacement/export transfer files (Application passes
     * `<cacheDir>/WorkspaceSourceRecovery`; tests pass a temp dir). Journal
     * 47 references these identities; native never deletes them, and this
     * lane removes its OWN transfer files only after the ladder reached a
     * durable terminal for THAT receipt — never the recovery originals. */
    recoveryRoot: File,
    private val scope: CoroutineScope,
    private val ioDispatcher: CoroutineDispatcher,
    private val currentNativeEpoch: () -> Long?,
    private val gatewayProvider: (Long) -> SafGatewayService?,
    private val backendProvider: (Long) -> SafPlatformBackend?,
    private val channel: WorkspaceSourceChannel = NativeWorkspaceSourceChannel,
) {
    private val lanes = ConcurrentHashMap<String, Lane>()

    /** Epochs permanently fenced by [retireEpoch]. Mirrors the native
     * authority, where a retired root generation answers `retired` / -502
     * "belongs to a retired root" permanently for every hop created under
     * it; a stale or replayed binder must never mint a fresh App-side lane on a
     * dead generation (MODULE_API: "retireEpoch fences lanes"; every entry
     * revalidates the EXACT live root epoch). */
    private val retiredEpochs = ConcurrentHashMap<Long, Boolean>()

    val recoveryRoot: File = recoveryRoot.apply { mkdirs() }

    /** Bootstrap for one accepted root epoch: ONE bounded reconciliation of
     * each bound lane over the ORIGINAL durable source rows (source_page +
     * recovery_page) before any release UI is enabled. A refusal stays typed
     * /unavailable — never a success claim, never a permission cache. */
    fun beginEpoch(epoch: Long) {
        lanes.values.filter { it.nativeEpoch == epoch }.forEach { lane ->
            scope.launch(ioDispatcher) { lane.refresh() }
        }
    }

    /** Root stop / rebind: fence every lane of THIS generation and record the
     * epoch as permanently retired. Owned requests are cancelled as a request
     * (their IO settles inside their own NonCancellable section), this lane's
     * pick references are released, and no late callback or in-flight pump can
     * touch a newer root afterwards. */
    fun retireEpoch(epoch: Long) {
        retiredEpochs[epoch] = true
        val doomed = lanes.entries.filter { it.value.nativeEpoch == epoch }
        for (entry in doomed) {
            entry.value.stop()
            lanes.remove(entry.key, entry.value)
        }
    }

    /** Binds (or rebinds) the lane for ONE durable identity under the exact
     * captured owner. A newer pane generation of the same identity takes
     * ownership; an owner trying to reuse a retiring lane fails closed, and a
     * retired root generation can NEVER be bound again — even if the host's
     * epoch pointer is replayed at it. */
    fun laneFor(taskID: String, workspaceID: String, nativeEpoch: Long, hostGeneration: Long,
                isCurrentOwner: () -> Boolean): Lane? {
        if (nativeEpoch <= 0 || currentNativeEpoch() != nativeEpoch) return null
        if (retiredEpochs.containsKey(nativeEpoch)) return null
        val task = try { UUID.fromString(taskID) } catch (_: IllegalArgumentException) { return null }
        val workspace = try { UUID.fromString(workspaceID) } catch (_: IllegalArgumentException) { return null }
        if (!task.toString().equals(taskID, true) || !workspace.toString().equals(workspaceID, true)) return null
        val key = "${task.toString().uppercase(Locale.ROOT)}|${workspace.toString().uppercase(Locale.ROOT)}|$nativeEpoch"
        var created = false
        val lane = lanes.computeIfAbsent(key) {
            created = true
            Lane(taskID = task.toString(), workspaceID = workspace.toString(),
                 nativeEpoch = nativeEpoch, initialGeneration = hostGeneration,
                 initialOwner = isCurrentOwner)
        }
        if (!created && !lane.rebind(hostGeneration, isCurrentOwner)) return null
        // Retirement may race construction after the initial admission
        // check and miss this late insertion in its lane snapshot.
        if (retiredEpochs.containsKey(nativeEpoch) || currentNativeEpoch() != nativeEpoch) {
            lane.stop()
            lanes.remove(key, lane)
            return null
        }
        return lane
    }

    fun stats(): String? {
        val reply = SourceHostReply.call { buffer -> runCatching { channel.hostStats(buffer) }.getOrDefault(-599) }
        return if (reply.protocolOk) reply.body?.toString() else null
    }

    // -----------------------------------------------------------------------
    // One bound provider lane. Identity is captured AT BIND and rides every
    // request; nothing here re-reads "the current task/workspace" late.
    // -----------------------------------------------------------------------

    inner class Lane internal constructor(
        val taskID: String,
        val workspaceID: String,
        val nativeEpoch: Long,
        initialGeneration: Long,
        initialOwner: () -> Boolean,
    ) {
        /** Opaque per-lane namespace for the composition's platform-launch
         * ownership ledger (same rule as the accepted attachment/skills
         * lanes; the panel mirrors the key through `rememberSaveable`). */
        val launchNamespace: String = PlatformLaunchOwnership.mintNamespace()

        private val incarnation = AtomicLong(0)
        private val stopped = AtomicBoolean(false)
        private val busy = AtomicBoolean(false)
        @Volatile private var ownerGeneration: Long = initialGeneration
        @Volatile private var ownerFence: () -> Boolean = initialOwner
        @Volatile private var activeOperation: SafOperation<*>? = null
        @Volatile private var pickReferences: List<SafSharedGrantBroker.Lease> = emptyList()

        private val ui = MutableStateFlow(WorkspaceSourceLaneState())
        val state: StateFlow<WorkspaceSourceLaneState> = ui

        internal fun rebind(generation: Long, isCurrentOwner: () -> Boolean): Boolean {
            if (stopped.get()) return false
            synchronized(this) {
                if (stopped.get()) return false
                if (generation < ownerGeneration) return false
                ownerGeneration = generation
                ownerFence = isCurrentOwner
            }
            return true
        }

        fun stop() {
            if (!stopped.compareAndSet(false, true)) return
            activeOperation?.cancel()   // REQUEST only; its IO settles itself
            closePickReferences()
            busy.set(false)
            mutate { it.copy(pending = null, busy = false, runtimeAvailable = false) }
        }

        // ---- admission: full captured identity, checked at EVERY step ----

        private fun admitted(): Boolean =
            !stopped.get() && !retiredEpochs.containsKey(nativeEpoch) &&
                currentNativeEpoch() == nativeEpoch && ownerFence()

        private fun gateway(): SafGatewayService? =
            if (!admitted()) null else gatewayProvider(nativeEpoch)

        private fun backend(): SafPlatformBackend? =
            if (!admitted()) null else backendProvider(nativeEpoch)

        private fun mutate(transform: (WorkspaceSourceLaneState) -> WorkspaceSourceLaneState) {
            ui.value = transform(ui.value)
        }

        private fun closePickReferences() {
            val references = pickReferences
            pickReferences = emptyList()
            references.asReversed().forEach { runCatching { it.release() } }
        }

        private inline fun <R> whenIdle(body: () -> R): R? =
            if (!stopped.get() && busy.compareAndSet(false, true)) body() else null

        private fun endIdle() {
            busy.set(false)
            mutate { it.copy(busy = false, progressBytes = null) }
        }

        private fun resultBusy() =
            result("journalRefused", "another provider operation is active on this lane")

        /** A missing legacy .so (the pre-source-host build) must be an honest
         * runtimeUnavailable, never a crash of the App process. Inline so the
         * body may run the real suspend ladder from a suspend call site. */
        private inline fun <T> guardedRun(onLinkage: () -> T, onError: (String) -> T,
                                          body: () -> T): T = try {
            body()
        } catch (cancel: kotlinx.coroutines.CancellationException) {
            throw cancel
        } catch (_: LinkageError) {
            onLinkage()
        } catch (error: Exception) {
            onError(error.javaClass.simpleName)
        }
        /** Await ACTUAL settlement (IO + finalizers), never a detach-on-timeout.
         * The cancellation watch only REQUESTS op.cancel() while identity
         * fails; settlement still comes from `SafOperation.await(0)`. The wait
         * runs on a NonCancellable context so job teardown cannot abandon a
         * live stream before its close/finalizers. */
        private suspend fun <T> settled(op: SafOperation<T>): SafOutcome<T> =
            withContext(ioDispatcher + NonCancellable) {
                activeOperation = op
                val watch = launch {
                    while (!op.isDone) {
                        if (!admitted()) op.cancel()
                        delay(50)
                    }
                }
                try {
                    op.await()
                } finally {
                    watch.cancel()
                    activeOperation = null
                }
            }

        private suspend fun <T> gatewayOutcome(
            body: (SafCancelToken) -> SafOutcome<T>,
        ): SafOutcome<T> {
            val service = gateway()
                ?: return SafOutcome.failure(SafFailure.Failed("runtime unavailable"))
            val op = runCatching { service.submit(body) }
                .getOrElse { return SafOutcome.failure(SafFailure.Failed("gateway admission closed")) }
            return settled(op)
        }

        // ---- platform pick lifecycle -------------------------------------

        /** Capture a new pick request for the composition effect to launch.
         * While a live picker may still be showing, the ledger holds the
         * lane; this controller just records the newest pending identity —
         * a late callback for a superseded incarnation DROPS at the panel
         * with no controller call. Returns the incarnation, or null when
         * the lane cannot serve the request. */
        fun requestPick(kind: PickKind, purpose: PickPurpose, mimeTypes: List<String> = emptyList(),
                        suggestedName: String? = null, initialDirectory: String? = null): Long? {
            val service = gateway() ?: return null
            val spec = when (kind) {
                PickKind.OPEN_DOCUMENT -> service.grants.pickerForOpenDocument(
                    mimeTypes, initialDirectory?.let(::SafUriRef))
                PickKind.OPEN_TREE -> service.grants.pickerForTree(initialDirectory?.let(::SafUriRef))
                PickKind.CREATE_DOCUMENT -> {
                    val name = suggestedName?.takeIf { validDisplayName(it) } ?: return null
                    runCatching {
                        service.grants.pickerForCreateDocument(
                            mimeTypes.firstOrNull() ?: "application/octet-stream", name,
                            initialDirectory?.let(::SafUriRef))
                    }.getOrNull() ?: return null
                }
            }
            val issued = incarnation.incrementAndGet()
            mutate { it.copy(pending = WorkspaceSourcePendingPick(issued, spec, purpose)) }
            return issued
        }

        /** User dismissal before any result: cancel = NO user grant.
         * Nothing is accepted, retained, persisted or released here — the
         * lane's existing pick references belong to previously ACCEPTED
         * results only, never to a cancelled one. */
        fun cancelPending(incarnation: Long) {
            val pending = ui.value.pending ?: return
            if (pending.incarnation != incarnation) return
            mutate { it.copy(pending = null) }
        }

        /** Typed no-op entry for a ledger-Dropped callback: a dropped result
         * must NOT cancel, clear or re-launch anything; the pending request
         * stays owned until its own settle/cancel rule. */
        fun droppedCallback() = Unit

        /** Accept ONLY the explicit result URI + actual returned flags. A
         * null/blank URI is a user cancel and never invents a grant;
         * persistence truth comes from the platform take attempts inside the
         * gateway (no second policy DB exists here). */
        fun onPickerResult(incarnation: Long, uriString: String?, flags: Int): WorkspaceSourceResult {
            val service = gateway() ?: return RUNTIME_UNAVAILABLE
            val pending = ui.value.pending?.takeIf { it.incarnation == incarnation }
                ?: return result("journalRefused", "pick callback does not own the current request")
            if (uriString.isNullOrBlank()) {
                mutate { it.copy(pending = null) }
                return result("cancelled", "user dismissed the system picker")
            }
            val accept: PickAcceptResult = SharedUriGrantAuthority.withExclusiveAuthority {
                val outcome = service.grants.acceptPickResult(pending.spec, uriString, flags)
                if (outcome is PickAcceptResult.Accepted) {
                    val references = outcome.granted.map { flag ->
                        SharedUriGrantAuthority.broker.retain(outcome.uri, flag)
                    }
                    closePickReferences()
                    pickReferences = references
                }
                outcome
            }
            mutate { it.copy(pending = null) }
            return when (val accepted = accept) {
                is PickAcceptResult.Accepted -> {
                    val derivedDocument = accepted.uri.uriString.substringAfterLast('/')
                        .takeIf { marker -> marker != accepted.uri.uriString }
                    mutate {
                        it.copy(
                            accepted = WorkspaceSourceAcceptedPick(
                                uri = accepted.uri.uriString,
                                kind = accepted.kind.name,
                                granted = accepted.granted.map { flag -> flag.name }.toSet(),
                                persisted = accepted.persisted.map { flag -> flag.name }.toSet(),
                                transientOnly = accepted.transientOnly,
                                needsRePick = accepted.needsRePickWhenExpired,
                                purpose = pending.purpose,
                                requestKey = pending.spec.requestKey,
                                documentId = derivedDocument,
                            ),
                            lastResult = result("ok", accepted.reason.ifBlank { "system grant accepted" }),
                        )
                    }
                    result("ok")
                }
                is PickAcceptResult.Cancelled -> result("cancelled", accepted.reason)
                is PickAcceptResult.Rejected -> result("failed", "pick result refused: ${accepted.reason}")
            }
        }

        /** Select a child of an ALREADY-granted tree: the access anchor is
         * the exact tree URI (children inherit the granted conversation);
         * no new system permission is requested or implied, and read-only
         * truth comes from the platform probe, never from this note. */
        fun selectTreeChild(treeUri: String, documentId: String, displayName: String): WorkspaceSourceResult {
            val service = gateway() ?: return RUNTIME_UNAVAILABLE
            val providerBackend = backend() ?: return RUNTIME_UNAVAILABLE
            if (providerBackend.classifyUri(treeUri) != SafUriKind.TREE) {
                return result("failed", "not a granted tree URI")
            }
            val evidence = service.grants.currentAccess(SafUriRef(treeUri))
            if (!evidence.read && evidence.probeRead == ProbeFlag.DENIED) {
                return result("rePickRequired", "the tree grant is no longer live")
            }
            val derived = providerBackend.documentUriFor(SafUriRef(treeUri), documentId)
                ?: return result("failed", "provider did not resolve the tree child")
            mutate {
                it.copy(accepted = WorkspaceSourceAcceptedPick(
                    uri = derived.uriString, kind = SafUriKind.DOCUMENT.name,
                    granted = setOf(SafAccessFlag.READ.name), persisted = emptySet(),
                    transientOnly = false, needsRePick = false,
                    purpose = PickPurpose.IMPORT, requestKey = "tree-child",
                    documentId = documentId, treeAnchor = treeUri, displayName = displayName))
            }
            return result("ok")
        }

        fun clearAccepted() {
            closePickReferences()
            mutate { it.copy(accepted = null) }
        }

        // ---- provider browse ---------------------------------------------

        suspend fun browseTree(treeUri: String, parentDocumentId: String?, cursor: String?,
                               limit: Int = 256): WorkspaceSourceBrowseOutcome {
            // Admission first: a stopped / rebound / owner-replaced lane is
            // runtimeUnavailable, never a misleading "another operation is
            // active" busy refusal.
            if (!admitted()) return WorkspaceSourceBrowseOutcome(RUNTIME_UNAVAILABLE)
            return whenIdle {
                try { guardedRun(
                    { WorkspaceSourceBrowseOutcome(RUNTIME_UNAVAILABLE) },
                    { name -> WorkspaceSourceBrowseOutcome(result("failed", "source host error $name")) },
                ) {
                    if (backend()?.classifyUri(treeUri) != SafUriKind.TREE) {
                        return@guardedRun WorkspaceSourceBrowseOutcome(result("failed", "not a tree URI"))
                    }
                    val scan = gatewayOutcome { cancel ->
                        val anchor = SafUriRef(treeUri)
                        val references = listOf(SharedUriGrantAuthority.broker.retain(anchor, SafAccessFlag.READ))
                        try {
                            val service = gateway()
                            if (service == null) {
                                SafOutcome.failure(SafFailure.Failed("runtime unavailable"))
                            } else {
                                service.operations.listTreePage(anchor, parentDocumentId,
                                                                PageRequest(limit.coerceIn(1, 256), cursor), cancel)
                            }
                        } finally {
                            references.asReversed().forEach { runCatching { it.release() } }
                        }
                    }
                    return@guardedRun when (val outer = scan) {
                        is SafOutcome.Failure -> WorkspaceSourceBrowseOutcome(mapFailure(outer.failure))
                        is SafOutcome.Success -> WorkspaceSourceBrowseOutcome(
                            result("ok"),
                            outer.value.documents.map { document ->
                                WorkspaceSourceChildUi(
                                    documentId = document.ref.documentId ?: "",
                                    uri = document.ref.uri.uriString,
                                    displayName = document.displayName,
                                    mimeType = document.mimeType,
                                    bytes = (document.size as? SafSize.Known)?.bytes,
                                    isDirectory = document.mimeType == SafDocument.MIME_DIR,
                                    virtual = document.capabilities.virtual,
                                    writable = document.capabilities.write,
                                )
                            },
                            outer.value.nextCursorToken,
                        )
                    }
                } } finally { endIdle() }
            } ?: resultBusyBrowse()
        }

        private fun resultBusyBrowse() =
            WorkspaceSourceBrowseOutcome(result("journalRefused", "another provider operation is active"))

        // ---- durable row reconciliation (bootstrap + after terminals) ----

        /** ONE bounded walk over the ORIGINAL durable source rows +
         * unfinished journal receipts. Release UI may only act on references
         * this returned; unknown pre-existing grants stay conservatively
         * retained (never a Kotlin permission DB). */
        suspend fun refresh(): WorkspaceSourceResult = guardedRun(
            { RUNTIME_UNAVAILABLE }, { name -> result("failed", "source host error $name") },
        ) {
            if (!admitted()) return@guardedRun RUNTIME_UNAVAILABLE
            val sourceRows = ArrayList<WorkspaceSourceRowUi>()
            var after = ""
            var guard = 0
            var stoppedEarly: SourceHostReply? = null
            while (guard < 16) {
                guard += 1
                val reply = SourceHostReply.call { buffer ->
                    runCatching { channel.sourcePage(nativeEpoch, workspaceID, after, 32, buffer) }
                        .getOrDefault(-599)
                }
                if (!reply.ok) {
                    stoppedEarly = reply
                    break
                }
                reply.rows("rows").forEach { row -> sourceRows.add(row.toSourceUi()) }
                after = reply.text("nextAfterID")
                if (after.isEmpty()) break
            }
            val recoveries = ArrayList<WorkspaceSourceRecoveryUi>()
            after = ""
            guard = 0
            while (guard < 16) {
                guard += 1
                val reply = SourceHostReply.call { buffer ->
                    runCatching { channel.recoveryPage(nativeEpoch, workspaceID, after, 64, buffer) }
                        .getOrDefault(-599)
                }
                if (!reply.ok) break
                reply.rows("rows").forEach { row -> recoveries.add(row.toRecoveryUi()) }
                after = reply.text("nextAfterID")
                if (after.isEmpty()) break
            }
            val blocked = recoveries
                .filter { recovery -> recovery.state == "prepared" || recovery.state == "writing" }
                .map { recovery -> recovery.reference }.toSet()
            val service = gateway()
            val sweep = service?.grants?.revalidate()
            val lost = (sweep?.lost.orEmpty() + sweep?.lostSessionGrants.orEmpty())
                .map { grant -> grant.uriString }.toSet()
            mutate {
                it.copy(
                    runtimeAvailable = service != null && stoppedEarly == null,
                    sources = sourceRows,
                    recoveries = recoveries,
                    blockedReferences = blocked,
                    expiredReferences = lost,
                )
            }
            if (stoppedEarly != null && sourceRows.isEmpty()) mapReply(stoppedEarly)
            else result("ok", "", mapOf("sources" to sourceRows.size.toString(),
                                        "recoveries" to recoveries.size.toString()))
        }

        // ---- import: provider -> chunked native staging -> verified commit + bind ----

        suspend fun importAcceptedToWorkspace(targetPath: String,
                                              typedAcceptMime: String? = null): WorkspaceSourceResult {
            // Admission first: a stopped / rebound lane fails closed with the
            // honest runtimeUnavailable token — never a busy "operation is
            // active" refusal, and never a late pump into a newer root.
            if (!admitted()) return RUNTIME_UNAVAILABLE
            val accepted = ui.value.accepted ?: return result("unbound", "pick a document first")
            if (accepted.purpose != PickPurpose.IMPORT) {
                return result("failed", "the current pick is not an import pick")
            }
            if (!validLogicalPath(targetPath)) return result("failed", "invalid workspace path")
            return whenIdle {
                try { guardedRun({ RUNTIME_UNAVAILABLE }, { name -> result("failed", "source host error $name") }) { importLocked(accepted, targetPath, typedAcceptMime) } }
                finally { endIdle() }
            } ?: resultBusy()
        }

        private suspend fun importLocked(accepted: WorkspaceSourceAcceptedPick, targetPath: String,
                                         typedAcceptMime: String?): WorkspaceSourceResult {
            mutate { it.copy(busy = true, progressBytes = 0, lastResult = null) }
            val service = gateway() ?: return RUNTIME_UNAVAILABLE
            var stage = 0L
            try {
                val sourceID = UUID.randomUUID().toString()
                stage = runCatching {
                    channel.stageOpen(nativeEpoch, taskID, workspaceID, "import", targetPath,
                                      accepted.uri, accepted.documentId ?: "", sourceID)
                }.getOrDefault(-599)
                if (stage <= 0) return mapStatus(stage.toInt())
                val target = resolveTarget(accepted)
                    ?: return result("failed", "provider target unresolved")
                val meta = gatewayOutcome { cancel -> service.operations.metadata(target, cancel) }
                val document = when (meta) {
                    is SafOutcome.Failure -> return mapFailure(meta.failure)
                    is SafOutcome.Success -> meta.value
                }
                if (document.capabilities.virtual && typedAcceptMime == null) {
                    return result("unsupported",
                        "virtual document: choose one of the provider stream types before importing")
                }
                var stageRefusal = 0
                val pump = gatewayOutcome { cancel ->
                    val references = retainedFor(accepted.uri, read = true, write = false)
                    try {
                        val summary = service.operations.streamRead(
                            target, PROVIDER_COPY_BUDGET_BYTES, typedAcceptMime, cancel,
                        ) { chunk, count ->
                            if (stageRefusal == 0) {
                                val status = runCatching { channel.stageWrite(stage, chunk, 0, count) }
                                    .getOrDefault(-599)
                                if (status != 0) {
                                    stageRefusal = status
                                    throw SafCancelledException("stage refused")
                                }
                                publishProgress(count.toLong())
                            }
                        }
                        when (summary) {
                            is SafOutcome.Failure -> SafOutcome.failure(summary.failure, summary.detail)
                            is SafOutcome.Success -> SafOutcome.success(stageRefusal)
                        }
                    } finally {
                        releaseAll(references)
                    }
                }
                if (stageRefusal != 0) return mapStatus(stageRefusal)
                if (pump is SafOutcome.Failure) return mapFailure(pump.failure)
                // The commit + bind hop runs OUTSIDE the gateway executor so a
                // long native hash/verify never starves mailbox ticket IO.
                val finish = SourceHostReply.call { buffer ->
                    runCatching { channel.stageFinish(stage, buffer) }.getOrDefault(-599)
                }
                if (!finish.ok) return mapReply(finish)
                mutate {
                    it.copy(lastResult = result("ok", "", mapOf(
                        "sourceID" to finish.text("sourceID"),
                        "path" to targetPath,
                        "sha256" to finish.text("sha256"),
                        "bytes" to finish.text("bytes"),
                        "revision" to finish.text("revision"),
                    )))
                }
                val refreshed = refresh()
                if (!refreshed.statusEquals("ok")) {
                    // The import itself settled natively; only the bounded
                    // row-list reload failed. Report it honestly as ok +
                    // refresh detail, never as a failed import.
                    mutate { it.copy(lastResult = ui.value.lastResult!!.copy(detail = "imported; row refresh pending")) }
                }
                return ui.value.lastResult!!
            } finally {
                // The staged scratch is this lane's own temp: on success the
                // verified body already sits in the workspace, on failure
                // nothing was committed. Either way release it (the native
                // import hop is idempotent against the committed file).
                if (stage != 0L) runCatching { channel.stageAbort(stage) }
            }
        }

        // ---- save: the journal-admitted destructive ladder ----------------

        /**
         * Destructive save ONLY when the journal ladder completed: staged
         * fresh provider backup (native-verified) -> journal `prepared` ->
         * second fresh observation -> ONE-TIME `writing` claim -> the exact
         * gateway receipt token's single permit -> gateway serialized write
         * -> provider read-back streamed to native -> `settle` decides
         * committed (binding CAS) / conflict. Cancel/loss/timeout at any
         * phase leaves recoverable bytes and an honest journal row; this
         * lane NEVER retries-to-green.
         */
        suspend fun savePathToProvider(path: String): WorkspaceSourceResult {
            if (!admitted()) return RUNTIME_UNAVAILABLE
            if (!validLogicalPath(path)) return result("failed", "invalid workspace path")
            return whenIdle {
                try { guardedRun({ RUNTIME_UNAVAILABLE }, { name -> result("failed", "source host error $name") }) { saveLocked(path) } } finally { endIdle() }
            } ?: resultBusy()
        }

        private suspend fun saveLocked(path: String): WorkspaceSourceResult {
            mutate { it.copy(busy = true, progressBytes = 0, lastResult = null) }
            val service = gateway() ?: return RUNTIME_UNAVAILABLE
            val lookup = SourceHostReply.call { buffer ->
                runCatching { channel.sourceLookup(nativeEpoch, workspaceID, path, buffer) }.getOrDefault(-599)
            }
            if (!lookup.ok) return mapReply(lookup)
            val row = lookup.body!!.toSourceUi()
            var saveTicket = 0L
            var backupTicket = 0L
            var freshTicket = 0L
            var readbackTicket = 0L
            var replacementFile: File? = null
            var terminalReached = false
            var permitIssued = false
            try {
                saveTicket = runCatching {
                    channel.egressOpen(nativeEpoch, "save", taskID, workspaceID, path, row.id)
                }.getOrDefault(-599)
                if (saveTicket <= 0) return mapStatus(saveTicket.toInt())
                val info = SourceHostReply.call { buffer ->
                    runCatching { channel.egressInfo(saveTicket, buffer) }.getOrDefault(-599)
                }
                if (!info.ok) return mapReply(info)
                val snapshotSha = info.text("sha256")
                val snapshotBytes = info.number("bytes") ?: return result("failed", "snapshot facts missing")
                val recoveryID = info.text("recoveryID")

                val target = refFromRow(row) ?: return result("failed", "row reference unresolved")
                val access = service.grants.currentAccess(SafUriRef(row.reference))
                if (!access.write && access.probeWrite == ProbeFlag.DENIED) {
                    return if (!access.read && access.probeRead == ProbeFlag.DENIED) mapFailure(SafFailure.Revoked)
                    else mapFailure(SafFailure.ReadOnly)
                }

                // PHASE 0 — the gateway preserves the CURRENT provider bytes
                // into caller-owned recovery storage BEFORE any decision.
                val preparedOutcome = gatewayOutcome { cancel ->
                    val references = retainedFor(row.reference, read = true, write = true)
                    try {
                        service.workingCopy.prepareSave(target, row.sha256.ifBlank { null },
                                                        recoveryRoot, PROVIDER_COPY_BUDGET_BYTES, cancel)
                    } finally {
                        releaseAll(references)
                    }
                }
                val prepared: PreparedSave = when (preparedOutcome) {
                    is SafOutcome.Failure -> return mapFailure(preparedOutcome.failure)
                    is SafOutcome.Success -> preparedOutcome.value
                }
                if (prepared.state == PreparedState.SOURCE_CHANGED) {
                    return result("sourceChangedSinceImport",
                        "provider bytes changed before the ladder opened; the original is preserved for review",
                        mapOf("recoveryFile" to prepared.receipt.file.name))
                }

                // PHASE 1a — stream the preserved backup into native staging;
                // native RE-HASHES it (a Kotlin receipt hash is never the
                // journaled authority by itself).
                backupTicket = runCatching {
                    channel.stageOpen(nativeEpoch, taskID, workspaceID, "backup-verify",
                                      "", row.reference, row.documentID, row.id)
                }.getOrDefault(-599)
                if (backupTicket <= 0) return mapStatus(backupTicket.toInt())
                var backupRefusal = 0
                val backupPump = gatewayOutcome { cancel ->
                    FileInputStream(prepared.receipt.file.file).use { input ->
                        val pumped = pumpInto(input, backupTicket, cancel) { status -> backupRefusal = status }
                        pumped
                    }
                }
                if (backupRefusal != 0) return mapStatus(backupRefusal)
                if (backupPump is SafOutcome.Failure) return mapFailure(backupPump.failure)
                val backupFinish = SourceHostReply.call { buffer ->
                    runCatching { channel.stageFinish(backupTicket, buffer) }.getOrDefault(-599)
                }
                if (!backupFinish.ok) return mapReply(backupFinish)

                // PHASE 1b — journal `prepared` (drift refuses the permit and
                // creates/replaces NOTHING). The native stage is consumed.
                val preparedReply = SourceHostReply.call { buffer ->
                    runCatching { channel.savePrepare(saveTicket, backupTicket,
                                                      prepared.receipt.receiptId, buffer) }.getOrDefault(-599)
                }
                backupTicket = 0
                if (!preparedReply.ok) return mapReply(preparedReply)

                // PHASE 2 — SECOND fresh provider observation, native-hashed,
                // into the ONE-TIME durable claim.
                freshTicket = runCatching {
                    channel.stageOpen(nativeEpoch, taskID, workspaceID, "fresh-observe",
                                      "", row.reference, row.documentID, row.id)
                }.getOrDefault(-599)
                if (freshTicket <= 0) return mapStatus(freshTicket.toInt())
                var freshRefusal = 0
                val freshPump = gatewayOutcome { cancel ->
                    val references = retainedFor(row.reference, read = true, write = false)
                    try {
                        val summary = service.operations.streamRead(
                            target, PROVIDER_COPY_BUDGET_BYTES, null, cancel,
                        ) { chunk, count ->
                            if (freshRefusal == 0) {
                                val status = runCatching { channel.stageWrite(freshTicket, chunk, 0, count) }
                                    .getOrDefault(-599)
                                if (status != 0) {
                                    freshRefusal = status
                                    throw SafCancelledException("stage refused")
                                }
                            }
                        }
                        when (summary) {
                            is SafOutcome.Failure -> SafOutcome.failure(summary.failure, summary.detail)
                            is SafOutcome.Success -> SafOutcome.success(freshRefusal)
                        }
                    } finally {
                        releaseAll(references)
                    }
                }
                if (freshRefusal != 0) return mapStatus(freshRefusal)
                if (freshPump is SafOutcome.Failure) return mapFailure(freshPump.failure)
                val claimReply = SourceHostReply.call { buffer ->
                    runCatching { channel.saveClaim(saveTicket, freshTicket, buffer) }.getOrDefault(-599)
                }
                freshTicket = 0
                if (!claimReply.ok) return mapReply(claimReply)

                // PHASE 3 — pull the FROZEN native snapshot down in bounded
                // pages into the caller-owned replacement file; the gateway
                // performs the serialized destructive write with the ONE
                // native permit; the provider READ-BACK is then streamed down
                // into native staging and the settle hop (never this lane's
                // hash) decides the durable terminal.
                replacementFile = File(recoveryRoot, "replacement-$recoveryID.bin")
                val pulled = pullEgressToFile(saveTicket, replacementFile)
                if (pulled is SafOutcome.Failure) return mapFailure(pulled.failure)
                if (sha256OfFile(replacementFile) != snapshotSha) {
                    return result("conflict", "replacement transfer file does not match the native snapshot")
                }
                val bridge = PermitBridge(saveTicket, prepared.receipt.receiptId) { permitIssued = true }
                val commitOutcome = gatewayOutcome { cancel ->
                    service.workingCopy.commitSave(
                        prepared, StagedLocalRef(replacementFile, replacementFile.name), snapshotSha,
                        SavePolicy(preferSaveAsWhenReplacementNotProven = false,
                                   allowDestructiveOverwrite = true,
                                   allowSaveAsSibling = true,
                                   recoveryByteLimit = PROVIDER_COPY_BUDGET_BYTES),
                        bridge, cancel)
                }
                val receipt: SaveReceipt? = when (commitOutcome) {
                    // The write ATTEMPT may have started; the row stays where
                    // the journal put it and the read-back below is the only
                    // terminal decision (never an abandon-to-green).
                    is SafOutcome.Failure -> null
                    is SafOutcome.Success -> commitOutcome.value
                }

                readbackTicket = runCatching {
                    channel.stageOpen(nativeEpoch, taskID, workspaceID, "readback",
                                      "", row.reference, row.documentID, row.id)
                }.getOrDefault(-599)
                if (readbackTicket <= 0) {
                    return honestlyPending(recoveryID, "provider unreadable for the read-back")
                }
                var readbackRefusal = 0
                val readbackPump = gatewayOutcome { cancel ->
                    val references = retainedFor(row.reference, read = true, write = false)
                    try {
                        val summary = service.operations.streamRead(
                            target, PROVIDER_COPY_BUDGET_BYTES, null, cancel,
                        ) { chunk, count ->
                            if (readbackRefusal == 0) {
                                val status = runCatching { channel.stageWrite(readbackTicket, chunk, 0, count) }
                                    .getOrDefault(-599)
                                if (status != 0) {
                                    readbackRefusal = status
                                    throw SafCancelledException("stage refused")
                                }
                            }
                        }
                        when (summary) {
                            is SafOutcome.Failure -> SafOutcome.failure(summary.failure, summary.detail)
                            is SafOutcome.Success -> SafOutcome.success(readbackRefusal)
                        }
                    } finally {
                        releaseAll(references)
                    }
                }
                if (readbackPump is SafOutcome.Failure) {
                    return if (readbackPump.failure is SafFailure.Cancelled) {
                        honestlyPending(recoveryID, "cancelled after a destructive attempt; " +
                            "the journaled row stays pending and only the provider's actual bytes decide it")
                    } else {
                        honestlyPending(recoveryID, "provider read-back failed " +
                            "(${readbackPump.failure.code}); the journaled row stays pending for reconcile")
                    }
                }
                val settle = SourceHostReply.call { buffer ->
                    runCatching { channel.saveSettle(saveTicket, readbackTicket, buffer) }.getOrDefault(-599)
                }
                readbackTicket = 0
                terminalReached = true
                // The settle BODY is the journal's own verdict: a protocol-OK
                // body naming `conflict` (ok:0 + providerReadbackMismatch) is
                // the honest conflict terminal, never a generic failure.
                val state = settle.text("state")
                if (!settle.ok && !(settle.protocolOk && state.isNotEmpty())) return mapReply(settle)
                if (state == "committed") {
                    runCatching { service.workingCopy.adoptRecovery(prepared.receipt.receiptId) }
                    runCatching { replacementFile.delete() }
                    mutate {
                        it.copy(lastResult = result("ok", "", mapOf(
                            "path" to path, "sha256" to snapshotSha,
                            "bytes" to snapshotBytes.toString(), "recoveryID" to recoveryID,
                            "journal" to state,
                        )))
                    }
                    refresh()
                    return ui.value.lastResult!!
                }
                return result("conflict",
                    when (receipt) {
                        is SaveReceipt.SaveAsCreated -> "the provider rejected the destructive replace; a " +
                            "sibling was created and the original stays untouched — review in Reconcile"
                        else -> "provider read-back does not match the replacement; the recovery is " +
                            "preserved — review in Reconcile"
                    },
                    mapOf("recoveryID" to recoveryID, "state" to state,
                          "observedSHA256" to settle.text("observedSHA256")))
            } finally {
                if (backupTicket != 0L) runCatching { channel.stageAbort(backupTicket) }
                if (freshTicket != 0L) runCatching { channel.stageAbort(freshTicket) }
                if (readbackTicket != 0L) runCatching { channel.stageAbort(readbackTicket) }
                if (!terminalReached) {
                    // Honest abandon BEFORE a permit was handed records
                    // `retained`; after a permit/during a write the native
                    // side REFUSES abandon (-508) and the durable `writing`
                    // row stays honestly pending — decided only by the
                    // provider's actual bytes at a later reconcile, never here.
                    runCatching { channel.saveRetain(saveTicket, ByteArray(SourceHostReply.REPLY_BYTES)) }
                }
                runCatching { channel.egressClose(saveTicket) }
                if (!terminalReached && !permitIssued) {
                    // No destructive write started: the replacement transfer
                    // file is this lane's own scratch and nothing references
                    // it durably. The gateway recovery receipt (if any) is
                    // NEVER deleted here.
                    runCatching { replacementFile?.delete() }
                }
            }
        }

        private fun honestlyPending(recoveryID: String, why: String): WorkspaceSourceResult =
            result("providerOffline",
                "$why. The journaled row stays honestly pending and can be reconciled when the " +
                "provider returns; nothing was relabeled success.",
                mapOf("recoveryID" to recoveryID))

        // ---- non-destructive save-as / export ------------------------------

        /** Save AS into the document the user just CREATE_DOCUMENT-picked
         * (the platform created a DISTINCT empty document; overwriting any
         * other document is impossible by construction). The native working
         * copy streams DOWN in bounded pages into the new provider document
         * and the native egress-verify (two native digests) decides the
         * reported integrity. Journal 47 is NOT touched: no binding or
         * destructive permit exists on a brand-new document. */
        suspend fun saveAsAccepted(path: String): WorkspaceSourceResult {
            if (!admitted()) return RUNTIME_UNAVAILABLE
            val accepted = ui.value.accepted ?: return result("unbound", "pick a save-as destination first")
            if (accepted.purpose != PickPurpose.SAVE_TARGET) {
                return result("failed", "the current pick is not a save-as destination pick")
            }
            if (!validLogicalPath(path)) return result("failed", "invalid workspace path")
            return whenIdle {
                try { guardedRun({ RUNTIME_UNAVAILABLE }, { name -> result("failed", "source host error $name") }) { saveAsLocked(accepted, path) } } finally { endIdle() }
            } ?: resultBusy()
        }

        private suspend fun saveAsLocked(accepted: WorkspaceSourceAcceptedPick, path: String): WorkspaceSourceResult {
            mutate { it.copy(busy = true, progressBytes = 0, lastResult = null) }
            val service = gateway() ?: return RUNTIME_UNAVAILABLE
            var egressTicket = 0L
            var verifyTicket = 0L
            try {
                val target = SafDocumentRef(accepted.treeAnchor?.let(::SafUriRef), accepted.documentId,
                                            null, SafUriRef(accepted.uri))
                val evidence = service.grants.currentAccess(SafUriRef(accepted.uri))
                if (!evidence.write && evidence.probeWrite == ProbeFlag.DENIED) {
                    return mapFailure(SafFailure.ReadOnly)
                }
                egressTicket = runCatching {
                    channel.egressOpen(nativeEpoch, "export", taskID, workspaceID, path, "")
                }.getOrDefault(-599)
                if (egressTicket <= 0) return mapStatus(egressTicket.toInt())
                val info = SourceHostReply.call { buffer ->
                    runCatching { channel.egressInfo(egressTicket, buffer) }.getOrDefault(-599)
                }
                if (!info.ok) return mapReply(info)
                val snapshotSha = info.text("sha256")
                val snapshotBytes = info.number("bytes") ?: return result("failed", "snapshot facts missing")
                var writeRefusal = 0
                val write = gatewayOutcome { cancel ->
                    val references = retainedFor(accepted.uri, read = true, write = true)
                    try {
                        val open = backend()?.openWriteTruncate(target, cancel)
                        when (open) {
                            null -> SafOutcome.failure(SafFailure.Failed("backend unavailable"))
                            is WriteOpen.Opened -> {
                                open.output.use { stream ->
                                    var offset = 0L
                                    while (writeRefusal == 0) {
                                        cancel.ensureActive()
                                        if (!admitted()) { writeRefusal = -502; break }
                                        val page = ByteArray(CHUNK_BYTES)
                                        val copied = runCatching {
                                            channel.egressRead(egressTicket, offset, page)
                                        }.getOrDefault(-599)
                                        if (copied < 0) { writeRefusal = copied; break }
                                        if (copied == 0) break
                                        stream.write(page, 0, copied)
                                        offset += copied
                                        publishProgress(copied.toLong())
                                    }
                                    stream.flush()
                                }
                                SafOutcome.success(writeRefusal)
                            }
                            WriteOpen.NotFound -> SafOutcome.failure(SafFailure.NotFound)
                            WriteOpen.UnsupportedMode ->
                                SafOutcome.failure(SafFailure.Unsupported("provider rejected the write mode"))
                        }
                    } finally {
                        releaseAll(references)
                    }
                }
                if (writeRefusal != 0) return mapStatus(writeRefusal)
                if (write is SafOutcome.Failure) return mapFailure(write.failure)
                verifyTicket = runCatching {
                    channel.stageOpen(nativeEpoch, taskID, workspaceID, "export-verify",
                                      "", accepted.uri, accepted.documentId ?: "", "")
                }.getOrDefault(-599)
                if (verifyTicket <= 0) return mapStatus(verifyTicket.toInt())
                val readback = pumpProviderIntoStage(service, target, accepted.uri, verifyTicket)
                if (!readback.statusEquals("ok")) return readback
                val finish = SourceHostReply.call { buffer ->
                    runCatching { channel.stageFinish(verifyTicket, buffer) }.getOrDefault(-599)
                }
                if (!finish.ok) return mapReply(finish)
                val verify = SourceHostReply.call { buffer ->
                    runCatching { channel.egressVerify(egressTicket, verifyTicket, buffer) }.getOrDefault(-599)
                }
                verifyTicket = 0
                if (!verify.ok) return mapReply(verify)
                if (verify.number("match") != 1L) {
                    return result("conflict",
                        "provider read-back does not match the exported snapshot; the created document " +
                        "is kept and nothing was deleted",
                        mapOf("created" to accepted.uri, "observedSHA256" to verify.text("observedSHA256")))
                }
                return result("ok", "", mapOf("created" to accepted.uri, "path" to path,
                                               "sha256" to snapshotSha, "bytes" to snapshotBytes.toString()))
            } finally {
                if (verifyTicket != 0L) runCatching { channel.stageAbort(verifyTicket) }
                runCatching { channel.egressClose(egressTicket) }
            }
        }

        /** Export into a NEW document under a picked tree via the gateway's
         * create + staged write + read-back verification (ACTION_CREATE_
         * DOCUMENT semantics: distinct document, never overwrite), then the
         * native egress-verify confirms the bytes from NATIVE digests. */
        suspend fun exportToAcceptedTree(path: String, displayName: String,
                                         parentDocumentId: String?): WorkspaceSourceResult {
            if (!admitted()) return RUNTIME_UNAVAILABLE
            val accepted = ui.value.accepted ?: return result("unbound", "pick a destination folder first")
            if (accepted.purpose != PickPurpose.EXPORT_TARGET) {
                return result("failed", "the current pick is not an export destination pick")
            }
            if (!validLogicalPath(path)) return result("failed", "invalid workspace path")
            if (!validDisplayName(displayName)) return result("failed", "display name must be one safe segment")
            return whenIdle {
                try { guardedRun({ RUNTIME_UNAVAILABLE }, { name -> result("failed", "source host error $name") }) { exportTreeLocked(accepted, path, displayName, parentDocumentId) } }
                finally { endIdle() }
            } ?: resultBusy()
        }

        private suspend fun exportTreeLocked(accepted: WorkspaceSourceAcceptedPick, path: String,
                                             displayName: String, parentDocumentId: String?): WorkspaceSourceResult {
            mutate { it.copy(busy = true, progressBytes = 0, lastResult = null) }
            val service = gateway() ?: return RUNTIME_UNAVAILABLE
            var egressTicket = 0L
            var verifyTicket = 0L
            val transferFile = File(recoveryRoot, "export-${UUID.randomUUID()}.bin")
            try {
                egressTicket = runCatching {
                    channel.egressOpen(nativeEpoch, "export", taskID, workspaceID, path, "")
                }.getOrDefault(-599)
                if (egressTicket <= 0) return mapStatus(egressTicket.toInt())
                val info = SourceHostReply.call { buffer ->
                    runCatching { channel.egressInfo(egressTicket, buffer) }.getOrDefault(-599)
                }
                if (!info.ok) return mapReply(info)
                val snapshotSha = info.text("sha256")
                val snapshotBytes = info.number("bytes") ?: return result("failed", "snapshot facts missing")
                val pulled = pullEgressToFile(egressTicket, transferFile)
                if (pulled is SafOutcome.Failure) return mapFailure(pulled.failure)
                if (sha256OfFile(transferFile) != snapshotSha) {
                    return result("ioFailed", "export transfer file does not match the native snapshot")
                }
                val copy = StagedCopy(
                    local = StagedLocalRef(transferFile, transferFile.name),
                    sourceUri = SafUriRef(accepted.uri), sourceDocumentId = accepted.documentId,
                    bytes = snapshotBytes, sha256 = snapshotSha,
                    sizeHintBytes = snapshotBytes, lastModifiedHintMillis = null,
                    displayName = displayName,
                )
                val export = gatewayOutcome { cancel ->
                    val references = retainedFor(accepted.uri, read = true, write = true)
                    try {
                        service.workingCopy.exportStagedCopy(copy, SafUriRef(accepted.uri),
                                                             parentDocumentId, displayName, cancel)
                    } finally {
                        releaseAll(references)
                    }
                }
                val created = when (export) {
                    is SafOutcome.Failure -> return mapFailure(export.failure)
                    is SafOutcome.Success -> export.value
                }
                if (!created.readbackVerified || created.destinationReadbackSha256 != snapshotSha) {
                    return result("conflict",
                        "gateway read-back did not confirm the exported bytes; the created document is kept",
                        mapOf("created" to created.created.uri.uriString))
                }
                // Native confirmation of the created document (two native
                // digests — a Kotlin receipt hash is never the final word).
                verifyTicket = runCatching {
                    channel.stageOpen(nativeEpoch, taskID, workspaceID, "export-verify",
                                      "", created.created.uri.uriString, created.created.documentId ?: "", "")
                }.getOrDefault(-599)
                if (verifyTicket <= 0) return mapStatus(verifyTicket.toInt())
                val readback = pumpProviderIntoStage(service, created.created,
                                                     created.created.uri.uriString, verifyTicket)
                if (!readback.statusEquals("ok")) return readback
                val finish = SourceHostReply.call { buffer ->
                    runCatching { channel.stageFinish(verifyTicket, buffer) }.getOrDefault(-599)
                }
                if (!finish.ok) return mapReply(finish)
                val verify = SourceHostReply.call { buffer ->
                    runCatching { channel.egressVerify(egressTicket, verifyTicket, buffer) }.getOrDefault(-599)
                }
                verifyTicket = 0
                if (!verify.ok) return mapReply(verify)
                if (verify.number("match") != 1L) {
                    return result("conflict",
                        "provider read-back does not match the exported snapshot; the created document is kept",
                        mapOf("created" to created.created.uri.uriString))
                }
                return result("ok", "", mapOf("created" to created.created.uri.uriString,
                                               "path" to path, "sha256" to snapshotSha,
                                               "bytes" to snapshotBytes.toString()))
            } finally {
                if (verifyTicket != 0L) runCatching { channel.stageAbort(verifyTicket) }
                runCatching { channel.egressClose(egressTicket) }
                runCatching { transferFile.delete() }
            }
        }

        // ---- grant release (revoke) --------------------------------------

        /** Release the OS grant for ONE durable reference. Enabled only for
         * references this lane reloaded from ORIGINAL durable rows, never
         * while an unfinished journal receipt references them, never while
         * the lane is busy, and only inside the broker's exclusive section.
         * Grants another feature (attachments/skills) acquired are preserved
         * by the broker — this lane NEVER releases what it did not own. */
        suspend fun revoke(reference: String): WorkspaceSourceResult {
            if (!admitted()) return RUNTIME_UNAVAILABLE
            return whenIdle {
                try {
                    guardedRun({ RUNTIME_UNAVAILABLE }, { name -> result("failed", "source host error $name") }) {
                        if (ui.value.sources.none { row -> row.reference == reference }) {
                            return@guardedRun result("unbound",
                                "the reference is not a durable bound source in this workspace")
                        }
                        if (reference in ui.value.blockedReferences) {
                            return@guardedRun result("journalRefused",
                                "an unfinished provider recovery references this grant")
                        }
                        val service = gateway() ?: return@guardedRun RUNTIME_UNAVAILABLE
                        val release = SharedUriGrantAuthority.withExclusiveAuthority {
                            service.grants.requestRelease(SafUriRef(reference),
                                                          setOf(SafAccessFlag.READ, SafAccessFlag.WRITE))
                        }
                        val mapped = mapRelease(release)
                        mutate { it.copy(lastResult = mapped) }
                        refresh()
                        mapped
                    }
                } finally { endIdle() }
            } ?: resultBusy()
        }

        private fun mapRelease(release: ReleaseResult): WorkspaceSourceResult = when (release) {
            is ReleaseResult.Released -> result("ok",
                "persisted grant released; the durable row stays and re-picking restores access",
                mapOf("released" to release.flags.joinToString { flag -> flag.name }))
            is ReleaseResult.PartiallyReleased -> result("conflict",
                "partially released: ${release.released.size} down, ${release.retained.size} retained, " +
                "${release.failed.size} failed")
            is ReleaseResult.RetainedByBroker -> result("retained",
                "other live references keep the grant")
            is ReleaseResult.NothingOwned -> result("retained",
                "no release candidate owned by this gateway instance")
            is ReleaseResult.NotOwned -> result("retained",
                "this lane never acquired the grant; it belongs to another feature and is preserved")
            is ReleaseResult.RefusedNoBroker -> result("failed", "release requires the host broker")
        }

        // ---- reconcile ----------------------------------------------------

        suspend fun reconcile(): WorkspaceSourceResult {
            if (!admitted()) return RUNTIME_UNAVAILABLE
            return whenIdle {
                try {
                    guardedRun({ RUNTIME_UNAVAILABLE }, { name -> result("failed", "source host error $name") }) {
                        val reply = SourceHostReply.call { buffer ->
                            runCatching { channel.reconcileRun(nativeEpoch, workspaceID, buffer) }.getOrDefault(-599)
                        }
                        if (!reply.ok) return@guardedRun mapReply(reply)
                        val refreshed = refresh()
                        result("ok", "", mapOf("settled" to reply.text("settled"),
                                               "refresh" to refreshed.status))
                    }
                } finally { endIdle() }
            } ?: resultBusy()
        }

        /** Reconcile ONE interrupted receipt with >4 MiB provider bytes: the
         * provider's CURRENT bytes are streamed into native staging and
         * NATIVE's digest decides (replacement -> committed CAS, backup ->
         * retained, anything else -> conflict). Never re-permits, never
         * retries-to-green. */
        suspend fun reconcileReceipt(recoveryID: String, sourceRow: WorkspaceSourceRowUi): WorkspaceSourceResult {
            if (!admitted()) return RUNTIME_UNAVAILABLE
            return whenIdle {
                try { guardedRun({ RUNTIME_UNAVAILABLE }, { name -> result("failed", "source host error $name") }) { reconcileReceiptLocked(recoveryID, sourceRow) } }
                finally { endIdle() }
            } ?: resultBusy()
        }

        private suspend fun reconcileReceiptLocked(recoveryID: String,
                                                   sourceRow: WorkspaceSourceRowUi): WorkspaceSourceResult {
            mutate { it.copy(busy = true, progressBytes = 0, lastResult = null) }
            val service = gateway() ?: return RUNTIME_UNAVAILABLE
            var stage = 0L
            try {
                val target = refFromRow(sourceRow) ?: return result("failed", "row reference unresolved")
                stage = runCatching {
                    channel.stageOpen(nativeEpoch, taskID, workspaceID, "readback",
                                      "", sourceRow.reference, sourceRow.documentID, sourceRow.id)
                }.getOrDefault(-599)
                if (stage <= 0) return mapStatus(stage.toInt())
                val readback = pumpProviderIntoStage(service, target, sourceRow.reference, stage)
                if (!readback.statusEquals("ok") && !readback.statusEquals("cancelled")) return readback
                if (readback.statusEquals("cancelled")) return readback
                val finish = SourceHostReply.call { buffer ->
                    runCatching { channel.stageFinish(stage, buffer) }.getOrDefault(-599)
                }
                if (!finish.ok) return mapReply(finish)
                val reply = SourceHostReply.call { buffer ->
                    runCatching { channel.reconcileStaged(nativeEpoch, taskID, workspaceID,
                                                          recoveryID, stage, buffer) }.getOrDefault(-599)
                }
                stage = 0
                if (!reply.ok) return mapReply(reply)
                refresh()
                // Return the ACTUAL reconciled result; the finally below only
                // aborts a stage that is still held (stage == 0 here).
                return result("ok", "", mapOf("recoveryID" to recoveryID, "state" to reply.text("state"),
                                        "observedSHA256" to reply.text("observedSHA256")))
            } finally {
                if (stage != 0L) runCatching { channel.stageAbort(stage) }
            }
        }

        // ---- shared primitives --------------------------------------------

        private fun retainedFor(uriString: String, read: Boolean, write: Boolean): List<SafSharedGrantBroker.Lease> {
            val uri = SafUriRef(uriString)
            val flags = buildList {
                if (read) add(SafAccessFlag.READ)
                if (write) add(SafAccessFlag.WRITE)
            }
            // References are taken INSIDE the caller's gateway IO block and
            // released only after the real stream settles (finally under the
            // IO), never on a timeout.
            return flags.map { flag -> SharedUriGrantAuthority.broker.retain(uri, flag) }
        }

        private fun releaseAll(references: List<SafSharedGrantBroker.Lease>) {
            references.asReversed().forEach { runCatching { it.release() } }
        }

        /** Synchronous chunked ingress pump — runs on the gateway executor
         * inside one submitted operation. The cancel token AND the full
         * identity check run between every chunk; a native refusal aborts
         * the pass with the typed status surfaced through [onRefusal]
         * (partial output is never promoted). */
        private fun pumpInto(input: InputStream, ticket: Long, cancel: SafCancelToken,
                             onRefusal: (Int) -> Unit): SafOutcome<Unit> {
            val buffer = ByteArray(CHUNK_BYTES)
            var total = 0L
            while (true) {
                cancel.ensureActive()
                if (!admitted()) return SafOutcome.failure(SafFailure.Cancelled)
                val read = input.read(buffer)
                if (read < 0) break
                total += read
                if (total > PROVIDER_COPY_BUDGET_BYTES) {
                    return SafOutcome.failure(SafFailure.SizeLimitExceeded(PROVIDER_COPY_BUDGET_BYTES))
                }
                val status = runCatching { channel.stageWrite(ticket, buffer, 0, read) }.getOrDefault(-599)
                if (status != 0) {
                    onRefusal(status)
                    throw SafCancelledException("stage refused")
                }
                publishProgress(read.toLong())
            }
            if (total == 0L) return SafOutcome.failure(SafFailure.Failed("empty provider stream"))
            return SafOutcome.success(Unit)
        }

        /** provider document -> one live native stage, with the refusal
         * token surfaced as a typed WorkspaceSourceResult. */
        private suspend fun pumpProviderIntoStage(service: SafGatewayService, target: SafDocumentRef,
                                                  reference: String, stageTicket: Long): WorkspaceSourceResult {
            var refusal = 0
            val pump = gatewayOutcome { cancel ->
                val references = retainedFor(reference, read = true, write = false)
                try {
                    val summary = service.operations.streamRead(
                        target, PROVIDER_COPY_BUDGET_BYTES, null, cancel,
                    ) { chunk, count ->
                        if (refusal == 0) {
                            val status = runCatching { channel.stageWrite(stageTicket, chunk, 0, count) }
                                .getOrDefault(-599)
                            if (status != 0) {
                                refusal = status
                                throw SafCancelledException("stage refused")
                            }
                        }
                    }
                    when (summary) {
                        is SafOutcome.Failure -> SafOutcome.failure(summary.failure, summary.detail)
                        is SafOutcome.Success -> SafOutcome.success(refusal)
                    }
                } finally {
                    releaseAll(references)
                }
            }
            if (refusal != 0) return mapStatus(refusal)
            return when (pump) {
                is SafOutcome.Failure -> mapFailure(pump.failure)
                is SafOutcome.Success -> result("ok")
            }
        }

        private fun pullEgressToFile(ticket: Long, destination: File): SafOutcome<Unit> {
            FileOutputStream(destination).use { output ->
                var offset = 0L
                while (true) {
                    if (!admitted()) return SafOutcome.failure(SafFailure.Cancelled)
                    val page = ByteArray(CHUNK_BYTES)
                    val copied = runCatching { channel.egressRead(ticket, offset, page) }.getOrDefault(-599)
                    if (copied < 0) return SafOutcome.failure(SafFailure.Io("egress read refused $copied"))
                    if (copied == 0) break
                    output.write(page, 0, copied)
                    offset += copied
                    publishProgress(copied.toLong())
                }
                output.flush()
            }
            return SafOutcome.success(Unit)
        }

        private fun publishProgress(delta: Long) {
            val current = ui.value
            mutate { it.copy(progressBytes = (current.progressBytes ?: 0L) + delta) }
        }

        private fun resolveTarget(accepted: WorkspaceSourceAcceptedPick): SafDocumentRef? {
            val providerBackend = backend() ?: return null
            val uri = SafUriRef(accepted.uri)
            return if (accepted.kind == SafUriKind.TREE.name) {
                providerBackend.resolveTreeRoot(uri)
            } else {
                SafDocumentRef(accepted.treeAnchor?.let(::SafUriRef), accepted.documentId, null, uri)
            }
        }

        private fun refFromRow(row: WorkspaceSourceRowUi): SafDocumentRef? {
            val providerBackend = backend() ?: return null
            val uri = SafUriRef(row.reference)
            return when (providerBackend.classifyUri(row.reference)) {
                SafUriKind.TREE -> if (row.documentID.isNotEmpty()) {
                    val derived = providerBackend.documentUriFor(uri, row.documentID) ?: return null
                    SafDocumentRef(uri, row.documentID, null, derived)
                } else providerBackend.resolveTreeRoot(uri)
                SafUriKind.DOCUMENT -> SafDocumentRef(null, row.documentID.ifEmpty { null }, null, uri)
                else -> null
            }
        }

        /** The gateway's destructive-permit hook. Handed at most ONCE per
         * save session, only while the durable row is `writing`, and only to
         * the exact journaled receipt token; everything else is a typed
         * Refused (the gateway then preserves the recovery and never claims
         * success). */
        private inner class PermitBridge(
            val saveTicket: Long,
            val receiptToken: String,
            private val onPermit: () -> Unit,
        ) : com.floe.android.safgateway.SafCommitCoordinator {
            override fun requestCommitPermit(
                receipt: com.floe.android.safgateway.RecoveryReceipt,
            ): CommitPermit {
                if (receipt.receiptId != receiptToken) return CommitPermit.Refused("tokenMismatch")
                if (!admitted()) return CommitPermit.Refused("laneFenced")
                val status = runCatching { channel.savePermit(saveTicket, receiptToken) }.getOrDefault(-599)
                return if (status == 0) {
                    onPermit()
                    CommitPermit.Permitted
                } else {
                    CommitPermit.Refused("permitRefused$status")
                }
            }
        }

        // ---- result/token mapping (UI-facing typed outcomes) --------------

        private fun mapFailure(failure: SafFailure): WorkspaceSourceResult = when (failure) {
            SafFailure.Revoked -> result("revoked",
                "the system no longer holds this grant — re-pick to restore access")
            SafFailure.GrantMissing -> result("grantMissing",
                "no grant exists yet — pick the document first")
            is SafFailure.RePickRequired -> result("rePickRequired",
                "the session grant expired — re-pick restores access")
            SafFailure.ProviderOffline -> result("providerOffline",
                "the document provider is unavailable; nothing was written")
            SafFailure.ReadOnly -> result("readOnly",
                "the provider or grant does not allow writing — use Save As or export")
            is SafFailure.Unsupported -> result("unsupported", failure.hint)
            SafFailure.Cancelled -> result("cancelled",
                "operation cancelled; recoverable bytes were preserved")
            is SafFailure.Conflict -> result("conflict", failure.detail)
            SafFailure.NotFound -> result("notFound", "the provider reports the document is gone")
            is SafFailure.AmbiguousIdentity -> result("conflict", failure.detail)
            is SafFailure.SizeLimitExceeded -> result("sizeLimit",
                "the file exceeds the 1 GiB provider copy budget")
            is SafFailure.Io -> result("ioFailed", failure.detail)
            is SafFailure.Failed -> result("failed", failure.detail)
        }

        private fun mapReply(reply: SourceHostReply): WorkspaceSourceResult {
            if (reply.status < 0) return mapStatus(reply.status)
            val code = reply.errorCode
            if (code.isNotEmpty()) return mapBodyCode(code, reply)
            return result("failed", "native reply body did not match the contract")
        }

        private fun mapBodyCode(code: String, reply: SourceHostReply): WorkspaceSourceResult = when (code) {
            "sourceChangedSinceImport" -> result("sourceChangedSinceImport",
                "the provider file changed since import; nothing was overwritten — re-import or Save As",
                mapOf("reason" to reply.text("reason")))
            "driftAtClaim" -> result("conflict", "the provider changed at the write-permit boundary")
            "workingCopyExists" -> result("workingCopyExists",
                "a different file already exists at that path — choose another path or use Save")
            "emptyFile" -> result("unsupported", "empty files are not imported as provider sources")
            "transportNotBound" -> result("runtimeUnavailable",
                "the provider transport is not bound to this root yet — ordinary workspace editing is unaffected")
            "retired", "identityRefused" -> RUNTIME_UNAVAILABLE
            "sizeExceeded", "aggregateExceeded" -> result("sizeLimit", "over the native staging budget")
            "diskFull" -> result("ioFailed", "device storage is full; nothing was committed")
            "staleRevision", "transitionRefused", "receiptMismatch" ->
                result("journalRefused", "the journal refused this operation ($code); nothing was overwritten")
            "digestMismatch", "readbackMismatch" -> result("conflict",
                "native verification rejected the bytes; recoverable copies were preserved")
            "sourceUnbound", "sourceMissing" ->
                result("unbound", "this file has no bound provider source — import one first")
            "cancelled" -> result("cancelled")
            "invalidMetadata", "invalidWorkingCopy", "pathRefused" -> result("failed", code)
            "internal" -> result("failed", "internal source-host refusal")
            else -> if (code in FROZEN_PROVIDER_TOKENS) result(code) else result("failed", code)
        }

        private fun mapNativeStatus(status: Int): SafOutcome<Unit> =
            SafOutcome.failure(SafFailure.Io("native refusal $status"))

        private fun mapStatus(status: Int): WorkspaceSourceResult = when (status) {
            -501, -505 -> RUNTIME_UNAVAILABLE
            -502 -> result("runtimeUnavailable", "this binding belongs to a retired root")
            -503 -> result("journalRefused", "the native session is unknown (late or duplicate close)")
            -504 -> result("journalRefused", "the ladder phase refused this operation")
            -506 -> result("unbound")
            -507 -> result("journalRefused", "stale binding revision — refresh the source list and retry")
            -508 -> result("journalRefused", "the journal refused this transition; nothing was overwritten")
            -509, -510 -> result("sizeLimit")
            -511 -> result("ioFailed", "device storage is full")
            -512 -> result("journalRefused", "too many concurrent native source sessions")
            -513 -> result("ioFailed", "staged write failed")
            -514 -> result("ioFailed", "staged read failed")
            -515 -> result("conflict", "native digest mismatch")
            -516 -> result("runtimeUnavailable", "provider transport not bound")
            -517 -> result("failed", "typed provider failure (see the operation detail)")
            -518 -> result("failed",
                "the native operation timed out; recoverable bytes were preserved — retry is safe")
            -105 -> result("failed", "invalid arguments")
            -106 -> result("failed", "native reply buffer too small")
            else -> result("failed", "source host status $status")
        }

        private fun result(status: String, detail: String = "",
                           facts: Map<String, String> = emptyMap()) =
            WorkspaceSourceResult(status, detail, facts)
    }

    companion object {
        const val PROVIDER_COPY_BUDGET_BYTES = 1L shl 30
        const val CHUNK_BYTES = 65_536
        val RUNTIME_UNAVAILABLE = WorkspaceSourceResult(
            "runtimeUnavailable",
            "no live accepted native root + bound OS gateway for this binding; " +
            "ordinary workspace editing is unaffected")
        val FROZEN_PROVIDER_TOKENS = setOf(
            "revoked", "grantMissing", "rePickRequired", "readOnly", "unsupported", "cancelled",
            "conflict", "notFound", "ambiguousIdentity", "sizeLimit", "providerOffline", "io", "failed")
    }
}

// ---------------------------------------------------------------------------
// Public lane value types (consumed by WorkspaceSourcePicker + Main mount).
// ---------------------------------------------------------------------------

/** Which flow a captured pick serves. The SAME panel launches all three via
 * `SafPickerIntents.from(spec)` + StartActivityForResult so the ACTUAL
 * returned flags survive; kind compatibility is checked again natively by
 * `acceptPickResult`. */
internal enum class PickPurpose { IMPORT, SAVE_TARGET, EXPORT_TARGET }

internal data class WorkspaceSourcePendingPick(
    val incarnation: Long,
    val spec: PickRequestSpec,
    val purpose: PickPurpose,
)

internal data class WorkspaceSourceAcceptedPick(
    val uri: String,
    val kind: String,
    val granted: Set<String>,
    val persisted: Set<String>,
    val transientOnly: Boolean,
    val needsRePick: Boolean,
    val purpose: PickPurpose,
    val requestKey: String,
    val documentId: String?,
    val treeAnchor: String? = null,
    val displayName: String? = null,
)

/** One durable journal-47 source row (metadata only; never bytes). */
internal data class WorkspaceSourceRowUi(
    val id: String,
    val path: String,
    val kind: String,
    val reference: String,
    val documentID: String,
    val sha256: String,
    val revision: String,
)

internal data class WorkspaceSourceRecoveryUi(
    val id: String,
    val sourceID: String,
    val state: String,
    val reference: String,
)

internal data class WorkspaceSourceChildUi(
    val documentId: String,
    val uri: String,
    val displayName: String,
    val mimeType: String,
    val bytes: Long?,
    val isDirectory: Boolean,
    val virtual: Boolean,
    val writable: Boolean,
)

internal data class WorkspaceSourceBrowseOutcome(
    val result: WorkspaceSourceResult,
    val children: List<WorkspaceSourceChildUi> = emptyList(),
    val nextCursor: String? = null,
)

/** Status tokens the UI maps to strings (EN/zh aligned). NEVER a raw
 * exception, URI, path or internal identifier. */
internal data class WorkspaceSourceResult(
    val status: String,
    val detail: String = "",
    val facts: Map<String, String> = emptyMap(),
) {
    fun statusEquals(other: String): Boolean = status == other
}

internal data class WorkspaceSourceLaneState(
    val runtimeAvailable: Boolean = false,
    val busy: Boolean = false,
    val progressBytes: Long? = null,
    val sources: List<WorkspaceSourceRowUi> = emptyList(),
    val recoveries: List<WorkspaceSourceRecoveryUi> = emptyList(),
    val blockedReferences: Set<String> = emptySet(),
    val expiredReferences: Set<String> = emptySet(),
    val pending: WorkspaceSourcePendingPick? = null,
    val accepted: WorkspaceSourceAcceptedPick? = null,
    val lastResult: WorkspaceSourceResult? = null,
)

// ---------------------------------------------------------------------------
// Channel seam + native adapter + reply plumbing (JVM-test injectable).
// ---------------------------------------------------------------------------

/** The trusted native source-host channel — the ONE seam tests inject.
 * Mirrors `WorkspaceSourceNative` exactly: opaque tickets, bounded JSON
 * replies, typed statuses only; nothing reversible into a path crosses. */
internal interface WorkspaceSourceChannel {
    fun stageOpen(epoch: Long, taskID: String, workspaceID: String, purpose: String,
                  logicalPath: String, sourceReference: String, sourceDocumentID: String, sourceID: String): Long
    fun stageWrite(ticket: Long, data: ByteArray, offset: Int, length: Int): Int
    fun stageFinish(ticket: Long, reply: ByteArray): Int
    fun stageAbort(ticket: Long): Int
    fun egressOpen(epoch: Long, mode: String, taskID: String, workspaceID: String,
                   logicalPath: String, sourceID: String): Long
    fun egressInfo(ticket: Long, reply: ByteArray): Int
    fun egressRead(ticket: Long, offset: Long, target: ByteArray): Int
    fun egressVerify(egressTicket: Long, stageTicket: Long, reply: ByteArray): Int
    fun egressClose(ticket: Long): Int
    fun savePrepare(saveTicket: Long, backupTicket: Long, receiptToken: String, reply: ByteArray): Int
    fun saveClaim(saveTicket: Long, freshTicket: Long, reply: ByteArray): Int
    fun savePermit(saveTicket: Long, receiptToken: String): Int
    fun saveSettle(saveTicket: Long, readbackTicket: Long, reply: ByteArray): Int
    fun saveRetain(saveTicket: Long, reply: ByteArray): Int
    fun sourcePage(epoch: Long, workspaceID: String, afterID: String, limit: Int, reply: ByteArray): Int
    fun sourceLookup(epoch: Long, workspaceID: String, logicalPath: String, reply: ByteArray): Int
    fun recoveryPage(epoch: Long, workspaceID: String, afterID: String, limit: Int, reply: ByteArray): Int
    fun reconcileRun(epoch: Long, workspaceID: String, reply: ByteArray): Int
    fun reconcileStaged(epoch: Long, taskID: String, workspaceID: String, recoveryID: String,
                        stageTicket: Long, reply: ByteArray): Int
    fun hostStats(reply: ByteArray): Int
}

internal object NativeWorkspaceSourceChannel : WorkspaceSourceChannel {
    override fun stageOpen(epoch: Long, taskID: String, workspaceID: String, purpose: String,
                           logicalPath: String, sourceReference: String, sourceDocumentID: String,
                           sourceID: String): Long =
        WorkspaceSourceNative.stageOpen(epoch, taskID, workspaceID, purpose, logicalPath,
                                        sourceReference, sourceDocumentID, sourceID)
    override fun stageWrite(ticket: Long, data: ByteArray, offset: Int, length: Int): Int =
        WorkspaceSourceNative.stageWrite(ticket, data, offset, length)
    override fun stageFinish(ticket: Long, reply: ByteArray): Int =
        WorkspaceSourceNative.stageFinish(ticket, reply)
    override fun stageAbort(ticket: Long): Int = WorkspaceSourceNative.stageAbort(ticket)
    override fun egressOpen(epoch: Long, mode: String, taskID: String, workspaceID: String,
                            logicalPath: String, sourceID: String): Long =
        WorkspaceSourceNative.egressOpen(epoch, mode, taskID, workspaceID, logicalPath, sourceID)
    override fun egressInfo(ticket: Long, reply: ByteArray): Int =
        WorkspaceSourceNative.egressInfo(ticket, reply)
    override fun egressRead(ticket: Long, offset: Long, target: ByteArray): Int =
        WorkspaceSourceNative.egressRead(ticket, offset, target)
    override fun egressVerify(egressTicket: Long, stageTicket: Long, reply: ByteArray): Int =
        WorkspaceSourceNative.egressVerify(egressTicket, stageTicket, reply)
    override fun egressClose(ticket: Long): Int = WorkspaceSourceNative.egressClose(ticket)
    override fun savePrepare(saveTicket: Long, backupTicket: Long, receiptToken: String, reply: ByteArray): Int =
        WorkspaceSourceNative.savePrepare(saveTicket, backupTicket, receiptToken, reply)
    override fun saveClaim(saveTicket: Long, freshTicket: Long, reply: ByteArray): Int =
        WorkspaceSourceNative.saveClaim(saveTicket, freshTicket, reply)
    override fun savePermit(saveTicket: Long, receiptToken: String): Int =
        WorkspaceSourceNative.savePermit(saveTicket, receiptToken)
    override fun saveSettle(saveTicket: Long, readbackTicket: Long, reply: ByteArray): Int =
        WorkspaceSourceNative.saveSettle(saveTicket, readbackTicket, reply)
    override fun saveRetain(saveTicket: Long, reply: ByteArray): Int =
        WorkspaceSourceNative.saveRetain(saveTicket, reply)
    override fun sourcePage(epoch: Long, workspaceID: String, afterID: String, limit: Int, reply: ByteArray): Int =
        WorkspaceSourceNative.sourcePage(epoch, workspaceID, afterID, limit, reply)
    override fun sourceLookup(epoch: Long, workspaceID: String, logicalPath: String, reply: ByteArray): Int =
        WorkspaceSourceNative.sourceLookup(epoch, workspaceID, logicalPath, reply)
    override fun recoveryPage(epoch: Long, workspaceID: String, afterID: String, limit: Int, reply: ByteArray): Int =
        WorkspaceSourceNative.recoveryPage(epoch, workspaceID, afterID, limit, reply)
    override fun reconcileRun(epoch: Long, workspaceID: String, reply: ByteArray): Int =
        WorkspaceSourceNative.reconcileRun(epoch, workspaceID, reply)
    override fun reconcileStaged(epoch: Long, taskID: String, workspaceID: String, recoveryID: String,
                                 stageTicket: Long, reply: ByteArray): Int =
        WorkspaceSourceNative.reconcileStaged(epoch, taskID, workspaceID, recoveryID, stageTicket, reply)
    override fun hostStats(reply: ByteArray): Int = WorkspaceSourceNative.hostStats(reply)
}

/** One status + bounded JSON reply. A negative protocol status means the
 * call never produced a body; a body with ok:0 carries the actionable
 * errorCode token (MODULE_API.json table). */
internal class SourceHostReply private constructor(
    val status: Int,
    val body: JsonObject?,
) {
    val protocolOk: Boolean get() = status >= 0 && body != null
    val ok: Boolean get() = status >= 0 && body?.boolean("ok") == true
    val errorCode: String get() = body?.text("errorCode") ?: ""

    fun text(key: String): String = body?.text(key) ?: ""
    fun number(key: String): Long? = body?.number(key)
    fun rows(key: String): List<JsonObject> = body?.rows(key) ?: emptyList()

    companion object {
        const val REPLY_BYTES = 32 * 1024

        fun call(execute: (ByteArray) -> Int): SourceHostReply {
            val buffer = ByteArray(REPLY_BYTES)
            val status = try { execute(buffer) } catch (_: LinkageError) { return SourceHostReply(-501, null) }
            if (status < 0) return SourceHostReply(status, null)
            val body = runCatching {
                val decoded = Charsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(buffer, 0, status)).toString()
                Json.parseToJsonElement(decoded).jsonObject
            }.getOrNull()
            return if (body == null) SourceHostReply(-599, null) else SourceHostReply(status, body)
        }
    }
}

private fun JsonObject.text(key: String): String? = (this[key] as? JsonPrimitive)?.content
private fun JsonObject.number(key: String): Long? = (this[key] as? JsonPrimitive)?.content?.toLongOrNull()
private fun JsonObject.boolean(key: String): Boolean? = when ((this[key] as? JsonPrimitive)?.content) {
    "true", "1" -> true
    "false", "0" -> false
    else -> null
}
private fun JsonObject.rows(key: String): List<JsonObject> =
    ((this[key] as? JsonArray)?.mapNotNull { element -> element as? JsonObject }) ?: emptyList()

private fun JsonObject.toSourceUi() = WorkspaceSourceRowUi(
    id = text("id") ?: "", path = text("path") ?: "", kind = text("kind") ?: "",
    reference = text("reference") ?: "", documentID = text("documentID") ?: "",
    sha256 = text("sha256") ?: "", revision = text("revision") ?: "")

private fun JsonObject.toRecoveryUi() = WorkspaceSourceRecoveryUi(
    id = text("id") ?: "", sourceID = text("sourceID") ?: "",
    state = text("state") ?: "", reference = text("reference") ?: "")

/** Local mirror of the ORIGINAL journal path grammar (fast honest refusal
 * BEFORE a native session opens; native re-validates authoritatively). */
private fun validLogicalPath(path: String): Boolean {
    if (path.isBlank() || path.length > 1024) return false
    if (path.startsWith("/") || path.startsWith("~") || path.contains("\\")) return false
    return path.split("/").all { segment -> segment.isNotEmpty() && segment != "." && segment != ".." }
}

/** Local safe display-name grammar matching the gateway rule (one segment,
 * no separators, bounded). */
private fun validDisplayName(name: String): Boolean =
    name.isNotBlank() && !name.contains('/') && !name.contains('\\') &&
    name != "." && name != ".." && name.toByteArray(Charsets.UTF_8).size <= 255

private fun sha256OfFile(file: File): String? = runCatching {
    val digest = MessageDigest.getInstance("SHA-256")
    FileInputStream(file).use { input ->
        val buffer = ByteArray(WorkspaceSourceHostController.CHUNK_BYTES)
        while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            digest.update(buffer, 0, read)
        }
    }
    digest.digest().joinToString("") { byte -> "%02x".format(byte.toInt() and 255) }
}.getOrNull()
