// SPDX-License-Identifier: MPL-2.0
package com.floe.android.workspacebridge

import android.content.Context
import android.os.IBinder
import android.os.Parcel
import android.os.ParcelFileDescriptor
import android.os.RemoteException
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.system.StructStat
import com.floe.android.runtimeipc.RuntimePackages
import com.floe.android.runtimeipc.RuntimePeerVerifier
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap

/**
 * The RUNTIME-side session: the only view a distinct-UID runtime process has
 * of one explicitly granted Core workspace. It holds an opaque grant Binder
 * (Main transports it beside foregroundPermit; nothing here can mint or
 * deserialize a grant from JSON), addresses entries ONLY by workspace-
 * relative paths + indexes, and never learns any Core absolute path.
 *
 * Insertion contract (Main):
 *  * `importBeforeLaunch` — after the native environment lease is acquired
 *    and BEFORE the Linux process launches. The lease destination is the
 *    STABLE `Workspaces/<projectUUID>` directory: a repeat import is
 *    transactional (journal-owned staging outside the destination + atomic
 *    move-aside/swap; cancel restores the prior workspace; un-synced prior
 *    bytes stay recoverable; independent unmarked data is never touched).
 *  * `exportAfterQuiescence` — AFTER the supervisor's whole-UID stop proof
 *    and BEFORE lease release/result completion (no output sync while Linux
 *    descendants can still mutate the workspace).
 *  * the Core foreground lease stays held across both (the grant DRAINS
 *    entered file transactions when Main's pump closes it before lease
 *    release).
 *
 * Failures/cancellation preserve the existing runtime workspace plus the
 * recoverable staged data on the Core side, and report conflict/unsynced
 * honestly — never CLI success when output never reached Core.
 */
class RuntimeWorkspaceSession(
    contextRuntime: Context,
    private val grant: IBinder,
    private val expectedProjectID: String,
    private val expectedRunID: String,
    destination: File,
) : java.io.Closeable {

    private val context = contextRuntime.applicationContext
    private val destination: File = destination.canonicalFile
    private var budgets: WorkspaceBudgetsView? = null
    private var sessionKey: String? = null
    private var journalDirectory: File? = null
    private var imported = false
    private var exportSettled = false
    /** R3 preflight precommit guard input: the ACTUAL imported baseline
     *  representation (kind/size/contained link target per relative path),
     *  recorded from the same staged entries that were swapped into the
     *  destination. Memory-only, session-scoped, never a second pipeline. */
    private val importedBaseline = HashMap<String, WorkspaceMirrorEntry>()

    init {
        val packages = RuntimePackages.forRuntime(context.packageName)
        // Exact counterpart Core package UID + signature, BEFORE any async
        // work — a same-signer stranger or shared-UID package is refused.
        RuntimePeerVerifier(context).verifyPeer(packages.core)
        val dataRoot = context.dataDir.canonicalFile
        require(WorkspaceRelativeValidation.containedCanonical(dataRoot, destination)) {
            "Workspace destination must live inside this runtime's app-private storage"
        }
        require(!destination.canonicalPath.contains("/.floe-wt-") &&
            !destination.canonicalPath.contains("/.floe-ws-")) { "destination cannot be a transfer journal" }
        if (!destination.isDirectory) {
            // The original lease materializes the engine workspace; creating
            // an own-territory directory here never selects a new location.
            if (!destination.mkdirs() && !destination.isDirectory) {
                throw WorkspaceBridgeException("destinationUnavailable")
            }
        }
    }

    // MARK: - Import (transactional fresh swap into the STABLE destination)

    fun importBeforeLaunch(cancel: WorkspaceCancelSignal): WorkspaceImportReceipt {
        require(!imported) { "import already completed for this session" }
        val state = requireOk(
            transact(WorkspaceBridgeWire.GET_STATE, identityControl()).first,
            "stateUnavailable",
        )
        budgets = requireBudgets(state.optJSONObject("budgets"))
        if (!state.optBoolean("open", false)) throw WorkspaceBridgeException("grantClosed")
        // Exact case-sensitive identity echo (owner IDs ride UNCHANGED).
        if (state.optString("projectID") != expectedProjectID || state.optString("runID") != expectedRunID) {
            throw WorkspaceBridgeException("grantIdentityMismatch")
        }
        val view = budgets ?: throw WorkspaceBridgeException("budgetsMissing")
        val begin = requireOk(transact(WorkspaceBridgeWire.BASELINE_BEGIN, JSONObject()).first, "baselineUnavailable")
        val key = begin.optString("sessionKey")
        if (!key.matches(Regex(WorkspaceBridgeWire.SESSION_KEY_REGEX))) throw WorkspaceBridgeException("sessionKeyInvalid")
        sessionKey = key
        liveSessions.put(key, true)
        val entryCount = begin.optLong("entryCount", -1)
        if (entryCount < 0 || entryCount > view.entryCount.toLong()) {
            throw WorkspaceBridgeException(if (entryCount < 0) "baselineMalformed" else "budgetExceeded")
        }
        val skipped = begin.optInt("skippedCount", 0)

        val journal = openJournal(key)
        val stageRoot = File(journal, "stage")
        val preserveRoot = File(journal, "preserve")
        if (!stageRoot.mkdirs() || !preserveRoot.mkdirs()) {
            throw WorkspaceBridgeException("journalUnavailable")
        }
        val ops = DefaultSwapOps()
        val manifest = WorkspaceSyncManifest(destination.parentFile ?: throw WorkspaceBridgeException("destinationRootInvalid"),
                                            expectedProjectID, ops)
        val swap = WorkspaceImportSwap(destination, stageRoot, preserveRoot, File(journal, "swap.jsonl"),
                                       manifest, ops)

        val staged = mutableListOf<StagedEntry>()
        var stagedBytes = 0L
        var swapOutcome: WorkspaceImportSwap.SwapOutcome? = null
        try {
            // Phase 1: stream every baseline entry into the journal-owned
            // staging tree (destination untouched). Digests are computed
            // over the ACTUAL bytes received.
            var index = 0L
            while (index < entryCount) {
                if (cancel.shouldCancel() || !grant.alive()) throw WorkspaceBridgeException("importCancelled")
                val headerReply = requireOk(
                    transact(WorkspaceBridgeWire.BASELINE_HEADER, JSONObject().put("index", index)).first,
                    "headerUnavailable",
                )
                if (headerReply.optBoolean("end", false)) {
                    throw WorkspaceBridgeException("snapshotTableShort") // integrity: refuse, never truncate
                }
                val path = headerReply.optString("path")
                val components = WorkspaceRelativeValidation.validate(path)
                    ?: throw WorkspaceBridgeException("snapshotPathUnsafe")
                val kind = headerReply.optString("kind")
                when (kind) {
                    "file" -> {
                        val dataReply = transact(WorkspaceBridgeWire.BASELINE_DATA, JSONObject().put("index", index))
                        requireOk(dataReply.first, "dataUnavailable")
                        if (dataReply.first.optString("path") != path ||
                            dataReply.first.optString("kind") != "file"
                        ) {
                            dataReply.second?.close()
                            throw WorkspaceBridgeException("snapshotHeaderMismatch")
                        }
                        val descriptor = dataReply.second ?: throw WorkspaceBridgeException("snapshotDataMissing")
                        try {
                            val size = dataReply.first.optLong("size", -1)
                            if (size < 0 || size > view.maximumEntryBytes) throw WorkspaceBridgeException("budgetExceeded")
                            val target = File(stageRoot, path)
                            target.parentFile?.let { parent ->
                                if (!parent.isDirectory && !parent.mkdirs()) {
                                    throw WorkspaceBridgeException("stageParentUnavailable")
                                }
                            }
                            if (freeBytes(journal) - size < view.freeDiskReserveBytes) {
                                throw WorkspaceBridgeException("diskReserveUnmet")
                            }
                            if (stagedBytes + size > view.totalBytes) throw WorkspaceBridgeException("budgetExceeded")
                            val written = streamToStage(descriptor.fileDescriptor, target, size + 1, view, cancel)
                            if (written != size) throw WorkspaceBridgeException("snapshotSizeUnderrun:$written")
                            stagedBytes += written
                            val digest = digestOfFile(target) ?: throw WorkspaceBridgeException("stageDigestFailed")
                            staged.add(StagedEntry(path, "file", dataReply.first.optInt("mode", WorkspaceFileModes.FILE_DEFAULT)
                                                 and WorkspaceFileModes.SAFE_MASK, null, digest, written))
                        } finally {
                            descriptor.close()
                        }
                    }
                    "directory" -> staged.add(StagedEntry(path, "directory",
                        headerReply.optInt("mode", WorkspaceFileModes.DIR_DEFAULT) and WorkspaceFileModes.SAFE_MASK,
                        null, "", 0))
                    "symlink" -> {
                        val targetValue = headerReply.optString("linkTarget")
                        if (!WorkspaceRelativeValidation.linkTargetContained(
                                targetValue, components, view.maximumLinkTargetBytes
                            )
                        ) {
                            // A Core snapshot that violates containment is a
                            // hostile/corrupt reply: refuse the WHOLE import;
                            // never follow links outside the destination.
                            throw WorkspaceBridgeException("snapshotLinkEscape")
                        }
                        staged.add(StagedEntry(path, "symlink", WorkspaceFileModes.LINK_NOMINAL, targetValue, "", 0))
                    }
                    else -> throw WorkspaceBridgeException("snapshotKindUnknown")
                }
                index += 1
            }

            // Phase 2: atomic swap into the STABLE destination.
            swapOutcome = try {
                swap.apply(staged) { cancel.shouldCancel() || !grant.alive() }
            } catch (failure: WorkspaceSwapException) {
                val restore = swap.restoreDetailed()
                // The reverse restore's ACTUAL typed outcome: how many prior
                // changes were genuinely renamed back, how many new entries
                // were genuinely reverted, how many failures stay retained in
                // the preserve journal. Counters increment only on successful
                // operations. This structured evidence rides the exception
                // and remains COMPONENT-LOCAL + journal truth: the CURRENT
                // failed-start path reaches the app only as the generic
                // kernel "operation_failed" receipt, so nothing here may be
                // described as a surfaced rollback proof until Main merges
                // the bounded failed-receipt handoff (PROPOSED-HANDOFF).
                // The legacy code string below is byte-identical to before.
                val restoreEvidence = JSONObject()
                    .put("record", "importRestore")
                    .put("sessionKey", key)
                    .put("runID", expectedRunID)
                    .put("trigger", failure.code)
                    .put("restoredPriorChanges", restore.restoredPriorChanges.toLong())
                    .put("revertedNewEntries", restore.revertedNewEntries.toLong())
                    .put("retainedFailures", restore.retainedFailures.toLong())
                throw WorkspaceBridgeException(
                    if (restore.retainedFailures == 0) failure.code
                    else "${failure.code}:restoreFailures${restore.retainedFailures}",
                    failure,
                    restoreEvidence,
                )
            }

            // Phase 3: Core acknowledgement, THEN prune only synced backups.
            requireOk(
                transact(
                    WorkspaceBridgeWire.BASELINE_FINISH,
                    JSONObject().put("appliedCount", staged.size.toLong()).put("appliedBytes", stagedBytes),
                ).first,
                "finishUnavailable",
            )
            swap.acknowledge(staged)
            markJournalAcknowledged(journal, key)
        } catch (failure: Exception) {
            // Staging-only leftovers never reached the destination; the swap
            // journal (if any) was restored above. Keep the journal directory
            // for recovery/sweep; independent destination data is untouched.
            if (failure is WorkspaceBridgeException) throw failure
            throw WorkspaceBridgeException("importFailed", failure)
        }
        imported = true
        // Record the faithful representation of the imported baseline BEFORE
        // any later export decision (the R3 preflight precommit guard).
        for (entry in staged) {
            importedBaseline[entry.path] = WorkspaceMirrorEntry(entry.kind, entry.size, entry.linkTarget, entry.digest)
        }
        val outcome = requireNotNull(swapOutcome) { "swap outcome missing after acknowledged import" }
        val conflicts = outcomeConflicts(swap, journal)
        // Digest-verified preserved copies: ONLY real custody facts the swap
        // engine measured on successful move-aside + install. Entries it
        // cannot show (symlink preserves, kind mismatch, unhashed legacy
        // journals) stay honestly absent, never zeroed or fabricated.
        val verifiedPreserved = outcome.preserved.filter { fact ->
            fact.action == "swappedPreserved" &&
                fact.preservedSha256.matches(RECOVERY_DIGEST) &&
                fact.installedSha256.matches(RECOVERY_DIGEST) &&
                fact.preservedBytes in 0..view.maximumEntryBytes &&
                fact.installedBytes in 0..view.maximumEntryBytes &&
                fact.path.toByteArray(Charsets.UTF_8).size <= RECOVERY_MAX_PATH_BYTES &&
                WorkspaceRelativeValidation.validate(fact.path) != null
        }
        stageRoot.deleteRecursivelySafe()
        return WorkspaceImportReceipt(
            key,
            runID = expectedRunID,
            createdCount = outcome.created,
            replacedSyncedCount = outcome.replacedSynced,
            preservedUnsyncedCount = outcome.preservedUnsynced,
            unchangedCount = outcome.unchanged,
            conflictPaths = conflicts.take(16),
            conflictsTruncated = conflicts.size > 16,
            appliedBytes = stagedBytes,
            skippedCount = skipped,
            budgets = view,
            preservedCopies = verifiedPreserved.take(RECOVERY_MAX_ENTRIES).map { fact ->
                WorkspacePreservedCopy(fact.path, fact.preservedSha256, fact.preservedBytes,
                                       fact.installedSha256, fact.installedBytes)
            },
            preservedCopiesTruncated = verifiedPreserved.size > RECOVERY_MAX_ENTRIES,
        )
    }

    private fun outcomeConflicts(swap: WorkspaceImportSwap, journal: File): List<String> {
        // Conflicts are recorded as swap journal "conflict" lines (both sides
        // preserved: destination intact, staged copy moved to preserve).
        return runCatching {
            File(journal, "swap.jsonl").readLines().mapNotNull { line ->
                val record = runCatching { JSONObject(line) }.getOrNull()
                if (record?.optString("action") == "conflict") record.optString("path") else null
            }
        }.getOrDefault(emptyList())
    }

    // MARK: - Export

    /**
     * `faithfulMirror` is the R3 preflight-only mode (default OFF keeps the
     * ORIGINAL shell-export semantics untouched, including legitimate
     * deletions). When ON, the guest tree is walked and checked against the
     * recorded imported baseline BEFORE `EXPORT_BEGIN`: a missing baseline
     * entry (deletion plan) or a changed representation is refused with a
     * recoverable failure that never reached any Core commit. The existing
     * applied-plan honesty check remains the post-commit second layer; this
     * is the same pipeline, not a parallel workspace mechanism.
     */
    fun exportAfterQuiescence(cancel: WorkspaceCancelSignal, faithfulMirror: Boolean = false): WorkspaceExportOutcome {
        val key = sessionKey ?: return WorkspaceExportOutcome.RecoverableFailure("noSession", false, null)
        val view = budgets ?: return WorkspaceExportOutcome.RecoverableFailure("budgetsMissing", false, key)
        if (!imported) return WorkspaceExportOutcome.RecoverableFailure("importPending", false, key)
        if (exportSettled) return WorkspaceExportOutcome.RecoverableFailure("exportSettled", false, key)
        // PRECOMMIT faithful mirror: the walk + baseline check run BEFORE
        // EXPORT_BEGIN so an unfaithful mirror never reaches ANY Core commit
        // (v1 checked honesty only after EXPORT_FINISH had applied the
        // transaction, which is too late to refuse a deletion/empty plan).
        var prewalked: List<GuestEntry>? = null
        if (faithfulMirror) {
            val walked = walkGuestTree(view)
                ?: return WorkspaceExportOutcome.RecoverableFailure("budgetExceeded", false, key)
            val mirrored = walked.associate { entry ->
                val digest = if (entry.kind == "file" && importedBaseline.containsKey(entry.path)) {
                    digestOfFile(File(destination, entry.path))
                        ?: return WorkspaceExportOutcome.RecoverableFailure("mirror_unreadable", false, key)
                } else ""
                entry.path to WorkspaceMirrorEntry(entry.kind, entry.size, entry.linkTarget, digest)
            }
            faithfulMirrorViolation(importedBaseline.toMap(), mirrored)?.let {
                return WorkspaceExportOutcome.RecoverableFailure(it, false, key)
            }
            prewalked = walked
        }
        try {
            requireOk(transact(WorkspaceBridgeWire.EXPORT_BEGIN, JSONObject()).first, "exportBeginUnavailable")
        } catch (failure: WorkspaceBridgeException) {
            return WorkspaceExportOutcome.RecoverableFailure(failure.code, true, key)
        }
        var sequence = 0L
        try {
            val entries = prewalked ?: run {
                walkGuestTree(view) ?: run {
                    abortOnce("budgetExceeded")
                    return WorkspaceExportOutcome.RecoverableFailure("budgetExceeded", true, key)
                }
            }
            for (entry in entries) {
                if (cancel.shouldCancel()) {
                    abortOnce("cancelled")
                    return WorkspaceExportOutcome.RecoverableFailure("cancelled", true, key)
                }
                val header = entry.header(sequence)
                var descriptor: ParcelFileDescriptor? = null
                try {
                    descriptor = if (entry.kind == "file") {
                        // An unreadable guest file is a HARD failure: skipping
                        // it would make Core classify the path as deleted.
                        // The guest tree is quiescent here (whole-UID stop
                        // proof precedes export per Main's insertion point),
                        // so the walk-time lstat (S_ISREG, never a symlink)
                        // plus this open cannot race a swap-under path.
                        try {
                            ParcelFileDescriptor.open(File(destination, entry.path),
                                                      ParcelFileDescriptor.MODE_READ_ONLY)
                        } catch (_: Exception) {
                            throw WorkspaceBridgeException("entryUnreadable")
                        }
                    } else {
                        null
                    }
                    val reply = transact(WorkspaceBridgeWire.EXPORT_STAGE, header, descriptor)
                    requireOk(reply.first, "stageUnavailable")
                } finally {
                    descriptor?.close()
                }
                sequence += 1
            }
        } catch (failure: WorkspaceBridgeException) {
            if (failure.code == "transportUncertain") {
                return readFinishReceiptOnce(key)
            }
            abortOnce(failure.code)
            return WorkspaceExportOutcome.RecoverableFailure(failure.code, true, key)
        } catch (failure: Exception) {
            abortOnce("exportStagingFailed")
            return WorkspaceExportOutcome.RecoverableFailure("exportStagingFailed", true, key)
        }
        return readFinishReceiptOnce(key)
    }

    private fun readFinishReceiptOnce(key: String): WorkspaceExportOutcome {
        val first = try {
            transact(WorkspaceBridgeWire.EXPORT_FINISH, JSONObject())
        } catch (_: RemoteException) {
            null
        } catch (_: Exception) {
            null
        }
        val reply = first ?: try {
            // One re-read of the TERMINAL RECEIPT (idempotent; no effects
            // can re-run). Still uncertain => explicit unknown, never a
            // fabricated sync.
            transact(WorkspaceBridgeWire.EXPORT_FINISH, JSONObject())
        } catch (_: Exception) {
            return WorkspaceExportOutcome.RecoverableFailure("exportResultUncertain", true, key)
        }
        val outcome = try {
            requireOk(reply.first, "finishMalformed")
        } catch (_: WorkspaceBridgeException) {
            return WorkspaceExportOutcome.RecoverableFailure("finishUnavailable", true, key)
        }
        exportSettled = true
        val result = outcome.optString("result")
        val applied = outcome.optJSONObject("applied") ?: JSONObject()
        val counts = outcome.optJSONObject("counts") ?: JSONObject()
        val preview = outcome.optJSONObject("preview") ?: JSONObject()
        val recovery = outcome.optJSONObject("recovery") ?: JSONObject()
        val conflicts = mutableListOf<WorkspaceConflictRecord>()
        preview.optJSONArray("conflicts")?.let { array ->
            for (i in 0 until array.length()) {
                val item = array.optJSONObject(i) ?: continue
                conflicts.add(
                    WorkspaceConflictRecord(item.optString("path"), item.optString("kind"),
                                            item.optBoolean("artifact", false)),
                )
            }
        }
        val truncated = preview.optBoolean("truncated", false) || outcome.optBoolean("previewTruncated", false)
        return when (result) {
            "synced" -> WorkspaceExportOutcome.Synced(
                key,
                applied.optLong("created"), applied.optLong("replaced"), applied.optLong("directories"),
                applied.optLong("deleted"), applied.optLong("links"),
                counts.optInt("stagedRefusals"), outcome.optString("planDigest"),
            )
            "conflict", "aborted" -> WorkspaceExportOutcome.Conflict(
                key, result,
                applied.optLong("created"), applied.optLong("replaced"), applied.optLong("directories"),
                applied.optLong("deleted"), applied.optLong("links"),
                conflicts, truncated,
                counts.optInt("failed"), counts.optInt("stagedRefusals"),
                recovery.optString("indexDigest", "unavailable"),
            )
            "receiptIncomplete" -> WorkspaceExportOutcome.RecoverableFailure("receiptIncomplete", true, key)
            else -> WorkspaceExportOutcome.RecoverableFailure("finishResultUnknown", true, key)
        }
    }

    /** The GRANT closes only through the Core-side drained close; the runtime
     *  session forgets local bookkeeping. Acknowledged journals with zero
     *  open preserves become sweep-eligible; anything else is preserved. */
    override fun close() {
        sessionKey?.let { liveSessions.remove(it) }
        val journal = journalDirectory
        if (imported && journal != null && openPreserveCount(journal) == 0 && isAcknowledged(journal)) {
            journal.deleteRecursivelySafe()
        }
    }

    // MARK: - Guest tree walk (bounded, no-follow listing)

    private class GuestEntry(val path: String, val kind: String, val size: Long, val mode: Int, val linkTarget: String?) {
        fun header(sequence: Long): JSONObject {
            val control = JSONObject().put("seq", sequence).put("path", path).put("kind", kind)
            if (kind == "file") control.put("size", size).put("mode", mode)
            if (kind == "directory") control.put("mode", mode)
            if (kind == "symlink") control.put("linkTarget", linkTarget ?: "")
            return control
        }
    }

    private fun walkGuestTree(view: WorkspaceBudgetsView): List<GuestEntry>? {
        val entries = mutableListOf<GuestEntry>()
        var totalBytes = 0L
        val stack = ArrayDeque<Pair<String, Int>>()
        stack.addLast("" to 0)
        while (stack.isNotEmpty()) {
            val (prefix, depth) = stack.removeLast()
            if (depth > WorkspaceRelativeValidation.MAX_COMPONENTS) return null
            val level = if (prefix.isEmpty()) destination else File(destination, prefix)
            val names = level.list()?.sorted() ?: continue
            for (rawName in names) {
                val relative = if (prefix.isEmpty()) rawName else "$prefix/$rawName"
                WorkspaceRelativeValidation.validate(relative) ?: return null
                val absolute = File(destination, relative)
                val stat = absolute.lstatOrNull() ?: return null // unreadable mid-quit: fail closed
                val mode = stat.st_mode and WorkspaceFileModes.ALL_BITS
                when {
                    OsConstants.S_ISREG(stat.st_mode) -> {
                        if (stat.st_size > view.maximumEntryBytes) return null
                        totalBytes += stat.st_size
                        if (totalBytes > view.totalBytes) return null
                        entries.add(GuestEntry(relative, "file", stat.st_size, mode, null))
                    }
                    OsConstants.S_ISDIR(stat.st_mode) -> {
                        entries.add(GuestEntry(relative, "directory", 0, mode, null))
                        stack.addLast(relative to depth + 1)
                    }
                    OsConstants.S_ISLNK(stat.st_mode) -> {
                        val target = try {
                            Os.readlink(absolute.absolutePath)
                        } catch (_: Exception) {
                            return null
                        }
                        entries.add(GuestEntry(relative, "symlink", 0, WorkspaceFileModes.LINK_NOMINAL, target))
                    }
                    else -> continue // FIFO/socket/device: never exported
                }
                if (entries.size > view.entryCount) return null
            }
        }
        return entries
    }

    // MARK: - Staging primitives (journal-owned, exclusive, no-follow)

    private fun streamToStage(source: java.io.FileDescriptor, target: File, maxBytes: Long,
                              view: WorkspaceBudgetsView, cancel: WorkspaceCancelSignal): Long {
        val outFd = try {
            Os.open(target.absolutePath, OsConstants.O_WRONLY or OsConstants.O_CREAT or
                OsConstants.O_EXCL or OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC,
                WorkspaceFileModes.FILE_DEFAULT)
        } catch (failure: ErrnoException) {
            throw WorkspaceBridgeException("stageOpenFailed:${failure.errno}")
        }
        try {
            val buffer = ByteArray(view.frameBytes)
            var moved = 0L
            while (true) {
                if (cancel.shouldCancel()) throw WorkspaceBridgeException("importCancelled")
                val count = try {
                    Os.read(source, buffer, 0, buffer.size)
                } catch (failure: ErrnoException) {
                    throw WorkspaceBridgeException("sourceReadFailed:${failure.errno}")
                }
                if (count == 0) break
                moved += count
                if (moved > maxBytes) throw WorkspaceBridgeException("sourceSizeOverflow")
                var written = 0
                while (written < count) {
                    val n = try {
                        Os.write(outFd, buffer, written, count - written)
                    } catch (failure: ErrnoException) {
                        throw WorkspaceBridgeException("stageWriteFailed:${failure.errno}")
                    }
                    written += n
                }
            }
            try {
                Os.fsync(outFd)
            } catch (failure: ErrnoException) {
                throw WorkspaceBridgeException("stageFsyncFailed:${failure.errno}")
            }
            return moved
        } finally {
            runCatching { Os.close(outFd) }
        }
    }

    private fun digestOfFile(file: File): String? {
        val fd = try {
            Os.open(file.absolutePath, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC, 0)
        } catch (_: Exception) {
            return null
        }
        try {
            val hasher = MessageDigest.getInstance("SHA-256")
            val buffer = ByteArray(65_536)
            while (true) {
                val count = try {
                    Os.read(fd, buffer, 0, buffer.size)
                } catch (_: ErrnoException) {
                    return null
                }
                if (count == 0) break
                hasher.update(buffer, 0, count)
            }
            return hasher.digest().joinToString("") { "%02x".format(it) }
        } finally {
            runCatching { Os.close(fd) }
        }
    }

    private fun freeBytes(path: File): Long = try {
        android.os.StatFs(path.absolutePath).availableBytes
    } catch (_: Exception) {
        -1
    }

    // MARK: - Journal lifecycle

    private fun openJournal(key: String): File {
        val parent = destination.parentFile ?: throw WorkspaceBridgeException("destinationRootInvalid")
        val directory = File(parent, ".floe-wt-$key")
        if (directory.exists()) throw WorkspaceBridgeException("journalCollision")
        if (!directory.mkdirs()) throw WorkspaceBridgeException("journalUnavailable")
        JSONObject().put("record", "session").put("sessionKey", key).put("runID", expectedRunID)
            .put("createdAtMs", System.currentTimeMillis()).writeFsynced(File(directory, "marker.json"))
        journalDirectory = directory
        return directory
    }

    private fun markJournalAcknowledged(journal: File, key: String) {
        JSONObject().put("record", "ack").put("sessionKey", key)
            .put("acknowledgedAtMs", System.currentTimeMillis()).appendFsynced(File(journal, "journal.jsonl"))
    }

    private fun isAcknowledged(journal: File): Boolean = workspaceJournalAcknowledged(journal)

    private fun openPreserveCount(journal: File): Int = workspacePreserveCount(journal)

    // MARK: - Transport helpers

    private fun identityControl(): JSONObject = JSONObject()
        .put("projectID", expectedProjectID)
        .put("runID", expectedRunID)

    private fun transact(code: Int, control: JSONObject,
                         descriptor: ParcelFileDescriptor? = null): Pair<JSONObject, ParcelFileDescriptor?> {
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        try {
            data.writeInterfaceToken(WorkspaceBridgeWire.DESCRIPTOR)
            val text = control.toString()
            if (!WorkspaceBridgeWire.fitsBound(text)) throw WorkspaceBridgeException("requestOverBound")
            data.writeString(text)
            if (descriptor != null) data.writeFileDescriptor(descriptor.fileDescriptor)
            if (!grant.transact(code, data, reply, 0)) throw WorkspaceBridgeException("transportUncertain")
            return WorkspaceParcelIO.readReply(reply)
        } catch (failure: RemoteException) {
            throw WorkspaceBridgeException("transportUncertain", failure)
        } finally {
            data.recycle()
            reply.recycle()
        }
    }

    private fun requireOk(reply: JSONObject, codePrefix: String): JSONObject {
        if (!reply.optBoolean("ok", false)) {
            throw WorkspaceBridgeException(reply.optString("code").takeIf { it.isNotEmpty() } ?: codePrefix)
        }
        return reply
    }

    private fun requireBudgets(json: JSONObject?): WorkspaceBudgetsView {
        return WorkspaceBudgetsView.sanitize(json) ?: throw WorkspaceBridgeException("budgetsUnsanitary")
    }

    private fun abortOnce(reason: String) {
        runCatching { transact(WorkspaceBridgeWire.ABORT, JSONObject().put("reason", reason)) }
        // Deliberately NO retry loop: an uncertain abort leaves the native
        // session recoverable; Core-side drained grant.close() finalizes it.
    }

    private fun File.lstatOrNull(): StructStat? = try {
        Os.lstat(absolutePath)
    } catch (_: Exception) {
        null
    }

    private fun JSONObject.writeFsynced(file: File) {
        FileOutputStream(file).use { stream ->
            stream.write(toString().toByteArray(Charsets.UTF_8))
            stream.flush()
            stream.fd.sync()
        }
    }

    private fun JSONObject.appendFsynced(file: File) {
        FileOutputStream(file, true).use { stream ->
            stream.write((toString() + "\n").toByteArray(Charsets.UTF_8))
            stream.flush()
            stream.fd.sync()
        }
    }

    private fun File.deleteRecursivelySafe() { deleteWorkspaceTreeNoFollow() }

    companion object {
        /**
         * Precommit faithful-mirror decision (pure and boundary-testable):
         * EVERY imported baseline entry must still be represented in the
         * guest tree with the same kind (a file keeps its byte size, a
         * symlink keeps its contained target). A missing baseline entry is
         * the headline forbidden case — an applied plan would delete Core
         * content (including the empty mirror of a non-empty baseline) — so
         * it must be refused BEFORE any commit. Independent guest-side
         * ADDITIONS are legitimate (the ORIGINAL import never touched them)
         * and stay permitted, exactly like the unchanged shell semantics.
         */
        fun faithfulMirrorViolation(baseline: Map<String, WorkspaceMirrorEntry>,
                                    guest: Map<String, WorkspaceMirrorEntry>): String? {
            var deleted = false
            var unfaithful = false
            for ((path, expected) in baseline) {
                val actual = guest[path]
                if (actual == null) { deleted = true; continue }
                if (actual.kind != expected.kind ||
                    (expected.kind == "file" && (actual.size != expected.size || actual.sha256 != expected.sha256)) ||
                    (expected.kind == "symlink" && actual.linkTarget != expected.linkTarget)
                ) unfaithful = true
            }
            return when {
                deleted -> "deletion_plan"
                unfaithful -> "mirror_unfaithful"
                else -> null
            }
        }

        private val liveSessions = ConcurrentHashMap<String, Boolean>()

        // Recovery projection bounds (diagnostic metadata ONLY; the real
        // transaction budgets live in WorkspaceRelativeValidation and the
        // grant budgets, and nothing here widens them).
        private const val RECOVERY_MAX_ENTRIES = 16
        private const val RECOVERY_MAX_PATH_BYTES = 256
        private const val RECOVERY_MAX_JSON_BYTES = 8_192
        private val RECOVERY_DIGEST = Regex("^[0-9a-f]{64}$")
        private val BOUNDED_TOKEN = Regex("^[!-~]{1,48}$")

        /**
         * Bounded per-execution recovery projection from the ORIGINAL owned
         * session facts ONLY: the opaque recovery/session key, the exact run
         * identity echoed by the grant, what the import swap actually
         * installed/preserved (measured digests + byte sizes of real custody
         * moves), and what the export settle actually reported. Relative
         * paths and counters only — no absolute paths, no content, no raw
         * keys beyond the recovery key the failure card already shows.
         * Returns null when there is NOTHING truthful to add (a consumer
         * must then leave the field ABSENT, never a fake zero). The final
         * envelope is serialized-size bound-guarded: over-budget entries are
         * dropped with an honest truncated flag rather than widening the
         * wire or truncating mid-string.
         */
        fun executionRecoveryJSON(receipt: WorkspaceImportReceipt,
                                  outcome: WorkspaceExportOutcome): JSONObject? {
            if (!receipt.sessionKey.matches(Regex(WorkspaceBridgeWire.SESSION_KEY_REGEX))) return null
            val importSection = JSONObject()
                .put("outcome", when {
                    receipt.preservedUnsyncedCount > 0 -> "swappedPreserved"
                    receipt.conflictPaths.isNotEmpty() || receipt.conflictsTruncated -> "conflict"
                    receipt.replacedSyncedCount > 0 -> "swappedSynced"
                    else -> "clean"
                })
                .put("created", receipt.createdCount.toLong())
                .put("replacedSynced", receipt.replacedSyncedCount.toLong())
                .put("preservedUnsynced", receipt.preservedUnsyncedCount.toLong())
                .put("unchanged", receipt.unchangedCount.toLong())
                .put("appliedBytes", receipt.appliedBytes)
            val copies = importCopies(receipt)
            if (copies.isNotEmpty()) {
                importSection.put("preserved", org.json.JSONArray().apply { copies.forEach { put(it) } })
                if (receipt.preservedCopiesTruncated) importSection.put("preservedTruncated", true)
            }
            if (receipt.conflictPaths.isNotEmpty()) {
                importSection.put("conflicts", org.json.JSONArray().apply {
                    receipt.conflictPaths.filter { it.toByteArray(Charsets.UTF_8).size <= RECOVERY_MAX_PATH_BYTES }
                        .take(RECOVERY_MAX_ENTRIES).forEach { put(it) }
                })
                if (receipt.conflictsTruncated) importSection.put("conflictsTruncated", true)
            }
            val export = exportSectionJSON(outcome)
            val envelope = JSONObject()
                .put("sessionKey", receipt.sessionKey)
                .put("import", importSection)
                .put("export", export)
            if (receipt.runID.isNotEmpty()) envelope.put("runID", receipt.runID)
            if (envelope.toString().toByteArray(Charsets.UTF_8).size <= RECOVERY_MAX_JSON_BYTES) return envelope
            // Over budget: drop the largest optional lists (never the status
            // or identity skeleton), then re-check; still over → NO metadata.
            importSection.remove("preserved"); importSection.remove("preservedTruncated")
            importSection.put("preservedDroppedForBudget", true)
            importSection.remove("conflicts"); importSection.remove("conflictsTruncated")
            importSection.put("conflictsDroppedForBudget", true)
            dropOverBudgetSections(export)
            return if (envelope.toString().toByteArray(Charsets.UTF_8).size <= RECOVERY_MAX_JSON_BYTES)
                envelope else null
        }

        private fun importCopies(receipt: WorkspaceImportReceipt): MutableList<JSONObject> =
            receipt.preservedCopies.take(RECOVERY_MAX_ENTRIES).map { copy ->
                JSONObject()
                    .put("path", copy.path)
                    .put("action", "swappedPreserved")
                    .put("preservedSha256", copy.preservedSha256)
                    .put("preservedBytes", copy.preservedBytes)
                    .put("installedBaselineSha256", copy.installedBaselineSha256)
                    .put("installedBaselineBytes", copy.installedBaselineBytes)
            }.toMutableList()

        /** The runtime's OWN typed export view from the original outcome
         *  classes. The Core-side pump may REPLACE this section with the
         *  captured EXPORT_FINISH reply (same session key); both views keep
         *  the original vocabularies, and unobserved fields stay absent. */
        private fun exportSectionJSON(outcome: WorkspaceExportOutcome): JSONObject = when (outcome) {
            is WorkspaceExportOutcome.Synced -> JSONObject()
                .put("result", "synced")
                .put("applied", appliedJSON(outcome.created, outcome.replaced, outcome.directories,
                                            outcome.deleted, outcome.links))
                .put("stagedRefusals", outcome.stagedRefusals.toLong())
                .apply { putOptionalDigest("planDigest", outcome.planDigest) }
            is WorkspaceExportOutcome.Conflict -> JSONObject()
                .put("result", if (outcome.status == "aborted") "aborted" else "conflict")
                .put("applied", appliedJSON(outcome.created, outcome.replaced, outcome.directories,
                                            outcome.deleted, outcome.links))
                .put("failed", outcome.failed.toLong())
                .put("stagedRefusals", outcome.stagedRefusals.toLong())
                .apply {
                    val shown = outcome.conflicts
                        .filter { it.path.toByteArray(Charsets.UTF_8).size <= RECOVERY_MAX_PATH_BYTES &&
                                 it.kind.matches(BOUNDED_TOKEN) }
                        .take(RECOVERY_MAX_ENTRIES)
                    if (shown.isNotEmpty()) {
                        put("conflicts", org.json.JSONArray().apply {
                            shown.forEach { conflict ->
                                put(JSONObject().put("path", conflict.path).put("kind", conflict.kind)
                                    .put("artifact", conflict.hasArtifact))
                            }
                        })
                        if (outcome.conflictsTruncated) put("conflictsTruncated", true)
                    }
                    putOptionalDigest("indexDigest", outcome.indexDigest)
                }
            is WorkspaceExportOutcome.RecoverableFailure -> JSONObject().apply {
                outcome.code.takeIf { it.matches(BOUNDED_TOKEN) }?.let { put("failureCode", it) }
                put("stagedPreserved", outcome.stagedPreserved)
                if (outcome.sessionKey != null &&
                    outcome.sessionKey.matches(Regex(WorkspaceBridgeWire.SESSION_KEY_REGEX))
                ) put("exportSessionKey", outcome.sessionKey)
            }
        }

        private fun appliedJSON(created: Long, replaced: Long, directories: Long,
                                deleted: Long, links: Long): JSONObject =
            JSONObject().put("created", created).put("replaced", replaced)
                .put("directories", directories).put("deleted", deleted).put("links", links)

        private fun JSONObject.putOptionalDigest(key: String, value: String): JSONObject {
            if (value.matches(RECOVERY_DIGEST)) put(key, value)
            return this
        }

        private fun dropOverBudgetSections(export: JSONObject) {
            export.remove("conflicts"); export.remove("conflictsTruncated")
            export.remove("applied")
        }

        /** G03-R3 cleanup gate: true while a session key has an OPEN runtime
         * -side transfer session. A scoped wipe must DEFER (never delete)
         *  under a live grant; recovery journals are only wiped when their
         *  key is provably not live. */
        fun isLiveSessionKey(sessionKey: String): Boolean =
            sessionKey.matches(Regex(WorkspaceBridgeWire.SESSION_KEY_REGEX)) &&
                liveSessions.containsKey(sessionKey)

        /** Sweep STALE runtime-side transfer journals ONLY: acknowledged,
         *  zero open preserves, valid marker, session key outside the live
         *  set, older than the grace. Unknown/active/UN-ACKED/with-unsynced-
         *  preserves journals are preserved (recoverable, never blindly
         *  deleted). */
        fun sweepStaleRuntimeJournals(journalParent: File, nowMs: Long, graceMs: Long): JSONObject {
            var cleaned = 0
            var preserved = 0
            val noFollow = java.nio.file.LinkOption.NOFOLLOW_LINKS
            if (!java.nio.file.Files.isDirectory(journalParent.toPath(), noFollow) || journalParent.canonicalFile != journalParent) {
                return JSONObject().put("cleaned", 0).put("preserved", 0)
            }
            val children = journalParent.listFiles { file -> file.name.startsWith(".floe-wt-") }
                ?: return JSONObject().put("cleaned", 0).put("preserved", 0)
            for (directory in children) {
                val key = directory.name.removePrefix(".floe-wt-")
                val marker = if (java.nio.file.Files.isDirectory(directory.toPath(), noFollow))
                    readWorkspaceMarker(File(directory, "marker.json")) else null
                val createdAt = marker?.optLong("createdAtMs", -1) ?: -1
                val validMarker = marker != null && marker.optString("record") == "session" &&
                    marker.optString("sessionKey") == key && key.matches(Regex(WorkspaceBridgeWire.SESSION_KEY_REGEX)) &&
                    createdAt in 1..nowMs
                if (!validMarker || liveSessions.containsKey(key) || nowMs - createdAt <= graceMs ||
                    !workspaceJournalAcknowledged(directory) || workspacePreserveCount(directory) != 0) {
                    preserved += 1
                } else if (directory.deleteWorkspaceTreeNoFollow()) cleaned += 1 else preserved += 1
            }
            return JSONObject().put("cleaned", cleaned).put("preserved", preserved)
        }
    }
}

/** One recorded baseline/guest representation used by the R3 precommit
 *  faithful-mirror guard (kind + byte size for files + contained symlink
 *  target). Deliberately path-keyed and relative-only: no Core absolute
 *  path, no second transfer machinery. */
data class WorkspaceMirrorEntry(val kind: String, val size: Long, val linkTarget: String?, val sha256: String = "")

/** Cheap liveness check WITHOUT allocating a binder callback: false once the
 *  Core grant object is gone; close/ownership then follows Main's pump rules. */
private fun IBinder.alive(): Boolean = try {
    pingBinder()
} catch (_: Exception) {
    false
}


/** Cleanup is a no-follow tree operation, including links to directories. */
private fun File.deleteWorkspaceTreeNoFollow(): Boolean = runCatching {
    java.nio.file.Files.walkFileTree(toPath(), object : java.nio.file.SimpleFileVisitor<java.nio.file.Path>() {
        override fun visitFile(file: java.nio.file.Path, attrs: java.nio.file.attribute.BasicFileAttributes): java.nio.file.FileVisitResult {
            java.nio.file.Files.delete(file)
            return java.nio.file.FileVisitResult.CONTINUE
        }
        override fun postVisitDirectory(dir: java.nio.file.Path, error: java.io.IOException?): java.nio.file.FileVisitResult {
            if (error != null) throw error
            java.nio.file.Files.delete(dir)
            return java.nio.file.FileVisitResult.CONTINUE
        }
    })
}.isSuccess

private fun readWorkspaceMarker(file: File): JSONObject? = runCatching {
    if (!java.nio.file.Files.isRegularFile(file.toPath(), java.nio.file.LinkOption.NOFOLLOW_LINKS)) return null
    java.nio.file.Files.newInputStream(file.toPath(), java.nio.file.StandardOpenOption.READ,
        java.nio.file.LinkOption.NOFOLLOW_LINKS).use { input ->
        val bytes = ByteArray(4097)
        var count = 0
        while (count < bytes.size) {
            val n = input.read(bytes, count, bytes.size - count)
            if (n < 0) break
            count += n
        }
        if (count > 4096) return null
        JSONObject(Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(bytes, 0, count)).toString())
    }
}.getOrNull()

/** A terminal acknowledgement is at the journal tail; never load a whole guest-sized log. */
private fun workspaceJournalAcknowledged(journal: File): Boolean = runCatching {
    val path = File(journal, "journal.jsonl").toPath()
    if (!java.nio.file.Files.isRegularFile(path, java.nio.file.LinkOption.NOFOLLOW_LINKS)) return false
    java.nio.file.Files.newByteChannel(path, java.nio.file.StandardOpenOption.READ,
        java.nio.file.LinkOption.NOFOLLOW_LINKS).use { channel ->
        val size = channel.size()
        val buffer = java.nio.ByteBuffer.allocate(minOf(65536L, size).toInt())
        channel.position(maxOf(0L, size - buffer.capacity()))
        while (buffer.hasRemaining() && channel.read(buffer) > 0) { }
        buffer.flip()
        val text = Charsets.UTF_8.decode(buffer).toString()
        text.lineSequence().any { line ->
            val row = runCatching { JSONObject(line) }.getOrNull()
            row?.optString("record") == "ack" && row.optString("sessionKey") == journal.name.removePrefix(".floe-wt-")
        }
    }
}.getOrDefault(false)

/** Unknown/unreadable or linked recovery directories must be retained. */
private fun workspacePreserveCount(journal: File): Int = runCatching {
    val path = File(journal, "preserve").toPath()
    val noFollow = java.nio.file.LinkOption.NOFOLLOW_LINKS
    if (java.nio.file.Files.notExists(path, noFollow)) return 0
    if (!java.nio.file.Files.isDirectory(path, noFollow)) return Int.MAX_VALUE
    java.nio.file.Files.newDirectoryStream(path).use { if (it.iterator().hasNext()) 1 else 0 }
}.getOrDefault(Int.MAX_VALUE)
