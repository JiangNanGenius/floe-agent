// SPDX-License-Identifier: MPL-2.0
package com.floe.android.workspacebridge

import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream

/**
 * Transactional FRESH import into the STABLE engine workspace directory.
 *
 * The original native lease descriptor is `Workspaces/<projectUUID>` — the
 * SAME directory across shell calls (coordinator coherence note
 * 2026-10-22). Re-import therefore cannot use plain O_EXCL materialization:
 * after the first command the destination already contains the previous
 * snapshot. This engine performs, with only atomic renames inside the
 * runtime app-data volume:
 *
 *   stage (journal-owned, outside the destination) → per-entry compare →
 *   move-aside previous bytes to an OWNER-MARKED backup → swap staged file
 *   into place → retire ONLY durable-proof-synced paths the fresh Core
 *   snapshot no longer owns (authoritative native deletion) → acknowledge →
 *   prune ONLY previous copies proven already synced to Core.
 *
 * Guarantees:
 *  * cancellation/failure DURING SWAP restores the prior workspace exactly
 *    (reverse journal); nothing staged mid-way leaks in;
 *  * un-synced / unknown previous runtime output is never blindly removed:
 *    its bytes move to the owner-marked preserve tree and stay recoverable
 *    (reported counts; the sync manifest only licenses pruning copies the
 *    Core baseline already proved synced);
 *  * a path ABSENT from the fresh snapshot is retired ONLY when a durable
 *    import manifest / successful-export ledger proves it was previously
 *    synced AND the current destination still matches the proven
 *    representation. Exact unchanged copies are pruned after acknowledge;
 *    diverged bytes are preserved and reported as conflicts. Unproven
 *    paths are never touched by absence;
 *  * independent, unmarked existing data that no snapshot path collides
 *    with is never touched at all (later exports may legitimately sync it);
 *  * no guessed scratch directories: everything lives under the caller's
 *    explicit destination plus its sibling journal.
 *
 * Android-free by design (all filesystem effects go through
 * [WorkspaceSwapOps]) so the transactional behaviour is unit-testable.
 */
class StagedEntry(
    val path: String,
    val kind: String,           // "file" | "directory" | "symlink"
    val mode: Int,
    val linkTarget: String?,
    val digest: String,         // computed by the importer over ACTUAL staged bytes
    val size: Long,
)

/** One regular-file copy the swap engine ACTUALLY swapped (both renames
 *  landed): `preservedSha256/preservedBytes` describe the destination bytes
 *  measured by the ORIGINAL digest-CAS read immediately before those exact
 *  bytes were moved into the owner-marked preserve tree; `installedSha256/
 *  installedBytes` the staged Core baseline bytes that really took their
 *  place. Facts exist ONLY after the real custody moves — never for a
 *  planned, rolled-back or kind-mismatched entry, and symlinks (which the
 *  engine never hashes) stay honestly unmeasured. */
data class SwappedCopy(
    val path: String,
    val action: String,            // "swappedPreserved" | "swappedSynced"
    val preservedSha256: String,   // destination bytes actually moved aside
    val preservedBytes: Long,
    val installedSha256: String,   // staged baseline bytes actually landed
    val installedBytes: Long,
)

/** ACTUAL per-entry outcome of one reverse-restore pass over the swap
 *  journal: `restoredPriorChanges` counts preserved copies genuinely renamed
 *  BACK into the destination, `revertedNewEntries` counts created/mkdir
 *  entries genuinely unlinked/removed, `retainedFailures` keeps the exact
 *  meaning [WorkspaceImportSwap.restore] always had (entries that could not
 *  be restored and stay recoverable in the preserve tree). Counters only
 *  report operations that SUCCEEDED; nothing here is inferred from intent. */
data class SwapRestoreSummary(
    val restoredPriorChanges: Int,
    val revertedNewEntries: Int,
    val retainedFailures: Int,
)

class WorkspaceSwapException(val code: String) : Exception(code)

class WorkspaceImportSwap(
    private val destination: File,
    private val stageRoot: File,
    private val preserveRoot: File,
    private val journalFile: File,
    private val manifest: WorkspaceSyncManifest?,
    private val ops: WorkspaceSwapOps,
    /** Latest authoritative generation; null preserves legacy callers.
     * Empty explicitly forbids pruning from a stale/unavailable proof. */
    private val priorProofs: Map<String, List<WorkspaceSyncedProof>>? = null,
    /** Observational finite phase only; never controls admission or cancellation. */
    private val onFirstAppliedChange: () -> Unit = {},
) {
    data class SwapOutcome(
        val created: Int,
        val replacedSynced: Int,
        val preservedUnsynced: Int,
        val unchanged: Int,
        val conflicts: List<String>,
        /** Measured facts for every regular-file entry the swap actually
         *  swapped (see [SwappedCopy]). Empty for engines whose journal was
         *  written before these facts existed — legacy restore/acknowledge
         *  paths parse and act on those unchanged. */
        val preserved: List<SwappedCopy> = emptyList(),
        val retainedExisting: Int = 0,
        val createdBytes: Long = 0,
        /** Previously synced entries ABSENT from the new Core snapshot whose
         *  current destination representation still EXACTLY matched a
         *  durable import/export proof. The authoritative native deletion
         *  won; the identical synced copy had no independent value and its
         *  journaled backup is pruned on acknowledge. */
        val retiredSynced: Int = 0,
        /** Previously synced entries ABSENT from the new Core snapshot whose
         *  current bytes/target DIVERGED from every proof. They were moved
         *  into the owner-marked preserve tree and their paths are reported
         *  as recoverable conflicts; they are never re-exported. */
        val retiredModified: Int = 0,
    )

    /** Applies every staged entry atomically. `shouldCancel` is checked
     *  before EACH entry; a cancel throws AFTER completing nothing further,
     *  and the caller MUST call [restore] (which is also safe to call after
     *  any other failure). */
    fun apply(entries: List<StagedEntry>, shouldCancel: () -> Boolean): SwapOutcome {
        val ordered = entries.sortedWith(
            compareBy({ if (it.kind == "directory") 0 else if (it.kind == "file") 1 else 2 },
                      { it.path }),
        )
        var created = 0
        var replacedSynced = 0
        var preservedUnsynced = 0
        var unchanged = 0
        val conflicts = mutableListOf<String>()
        val preservedFacts = mutableListOf<SwappedCopy>()
        var changeObserved = false
        for ((index, entry) in ordered.withIndex()) {
            if (shouldCancel()) {
                appendJournal(JSONObject().put("record", "cancel").put("i", index))
                throw WorkspaceSwapException("swapCancelled")
            }
            val target = File(destination, entry.path)
            if (!ensureParentDirectories(entry.path, index)) {
                conflicts.add(entry.path)
                continue
            }
            when (entry.kind) {
                "directory" -> when (ops.kind(target)) {
                    SwapKind.DIRECTORY -> {
                        unchanged += 1
                        appendJournal(swapRecord(index, entry, "unchanged", null))
                    }
                    SwapKind.MISSING -> {
                        if (!ops.mkdir(target)) {
                            conflicts.add(entry.path); continue
                        }
                        created += 1
                        appendJournal(swapRecord(index, entry, "mkdir", null))
                    }
                    else -> {
                        conflicts.add(entry.path)
                        stashStage(entry)
                        appendJournal(swapRecord(index, entry, "conflict", null))
                    }
                }
                "file" -> swapFile(index, entry, target)
                    .let { (outcome, fact) ->
                        fact?.let(preservedFacts::add)
                        when (outcome) {
                            "created" -> created += 1
                            "unchanged" -> unchanged += 1
                            "swappedSynced" -> replacedSynced += 1
                            "swappedPreserved" -> preservedUnsynced += 1
                            else -> {
                                conflicts.add(entry.path)
                                stashStage(entry)
                            }
                        }
                    }
                "symlink" -> swapSymlink(index, entry, target)
                    .let { outcome ->
                        when (outcome) {
                            "created" -> created += 1
                            "unchanged" -> unchanged += 1
                            "swappedPreserved" -> preservedUnsynced += 1
                            "swappedSynced" -> replacedSynced += 1
                            else -> {
                                conflicts.add(entry.path)
                                stashStage(entry)
                            }
                        }
                    }
            }
            if (!changeObserved && created + replacedSynced + preservedUnsynced > 0) {
                changeObserved = true
                // Every counted change has already landed AND been journaled.
                // Diagnostic failure cannot change the transaction or its restore.
                runCatching { onFirstAppliedChange() }
            }
        }
        ops.fsyncDirectory(destination)
        return SwapOutcome(created, replacedSynced, preservedUnsynced, unchanged, conflicts, preservedFacts.toList())
    }

    /** New task inputs while another session owns the live tree. Existing
     * entries are never renamed, chmod'ed or deleted, even after cancellation.
     * These journal actions deliberately do not participate in reverse restore:
     * a live process may already have changed a newly delivered input. */
    fun applyMissingOnly(entries: List<StagedEntry>, onCreated: (StagedEntry) -> Unit = {},
                         shouldCancel: () -> Boolean): SwapOutcome {
        var created = 0
        var retained = 0
        var bytes = 0L
        val conflicts = mutableListOf<String>()
        val ordered = entries.sortedWith(compareBy({ if (it.kind == "directory") 0 else 1 }, { it.path }))
        for ((index, entry) in ordered.withIndex()) {
            if (shouldCancel()) throw WorkspaceSwapException("inputImportCancelled")
            val before = ops.kindNoFollow(destination, entry.path)
            if (before != SwapKind.MISSING) {
                if (before == SwapKind.UNREADABLE) conflicts.add(entry.path) else retained += 1
                continue
            }
            val installed = when (entry.kind) {
                "directory" -> ops.createNewDirectory(destination, entry.path)
                "file" -> ops.installNewFile(File(stageRoot, entry.path), destination, entry.path)
                "symlink" -> entry.linkTarget?.let { ops.createNewSymlink(destination, entry.path, it) } ?: false
                else -> false
            }
            if (installed) {
                created += 1
                if (entry.kind == "file") bytes += entry.size
                appendJournal(swapRecord(index, entry, "newInputCreated", null))
                onCreated(entry)
            } else if (ops.kindNoFollow(destination, entry.path) in
                setOf(SwapKind.FILE, SwapKind.DIRECTORY, SwapKind.SYMLINK)) {
                retained += 1 // A concurrent guest won atomic creation.
            } else {
                conflicts.add(entry.path)
            }
        }
        ops.fsyncDirectory(destination)
        return SwapOutcome(created, 0, 0, 0, conflicts, retainedExisting = retained, createdBytes = bytes)
    }

    /**
     * Retire destination entries whose authoritative Core entry was deleted
     * NATIVELY, while never treating mere absence as permission to delete.
     *
     * Called INSIDE the same import transaction, after the fresh snapshot was
     * applied, with [proofs] built from the DURABLE import manifest plus the
     * last FAILED-SAFE export ledger. Only a path absent from the new
     * snapshot AND previously proven synced is considered:
     *
     *  * current file/symlink matching every recorded kind+digest/size or
     *    link target -> `retiredSynced` (move aside, prune after the Core
     *    baseline finish); the native deletion wins over the identical
     *    synced copy;
     *  * current file/symlink that diverged -> `retiredModified` (move aside
     *    to the owner-marked preserve tree, report a recoverable conflict);
     *  * proven directory, empty after proven children -> removed; a
     *    directory retaining unproven guest-only children is left intact and
     *    those children remain ordinary additions;
     *  * a non-empty directory replacing a proven file/symlink is reported
     *    as a conflict WITHOUT touching its guest data.
     *
     * Unproven paths, special files, unreadable entries and any path whose
     * ancestor chain is not made of real directories are never followed,
     * renamed or deleted. Every effect is journaled; [restoreDetailed]
     * reverses it. Any effect failure throws so the caller preserves the
     * prior workspace and never exports a half-retired mirror.
     */
    fun retireAbsent(proofs: Map<String, List<WorkspaceSyncedProof>>,
                     livePaths: Set<String>,
                     allowSyncedPrune: Boolean = true,
                     shouldCancel: () -> Boolean): SwapOutcome {
        var retiredSynced = 0
        var retiredModified = 0
        val conflicts = mutableListOf<String>()
        val ordered = proofs.keys.asSequence()
            .filter { it !in livePaths }
            .sortedWith(compareByDescending<String> { it.count { character -> character == '/' } }
                .thenByDescending { it })
            .toList()
        for ((ordinal, path) in ordered.withIndex()) {
            if (shouldCancel()) {
                appendJournal(JSONObject().put("record", "cancel").put("i", ordinal))
                throw WorkspaceSwapException("swapCancelled")
            }
            val components = WorkspaceRelativeValidation.validate(path) ?: continue
            val candidates = proofs[path] ?: continue
            if (!realParentDirectories(components)) continue
            val target = File(destination, path)
            when (ops.kind(target)) {
                SwapKind.FILE -> {
                    val measured = ops.streamDigest(target)
                    val synced = allowSyncedPrune && (measured?.let { value ->
                        candidates.any { proof ->
                            proof.kind == "file" && proof.size == value.second &&
                                proof.digest == value.first
                        }
                    } ?: false)
                    if (!moveAside(target, path)) throw WorkspaceSwapException("retireBlocked")
                    val action = if (synced) "retiredSynced" else "retiredModified"
                    appendJournal(retirementRecord(ordinal, path, "file", action, path,
                        measured?.first, measured?.second ?: 0L))
                    if (synced) {
                        retiredSynced += 1
                    } else {
                        retiredModified += 1
                        conflicts.add(path)
                    }
                }
                SwapKind.SYMLINK -> {
                    val currentTarget = ops.readLink(target)
                    val synced = allowSyncedPrune && (currentTarget?.let { value ->
                        candidates.any { proof ->
                            proof.kind == "symlink" && proof.linkTarget == value
                        }
                    } ?: false)
                    if (!moveAside(target, path)) throw WorkspaceSwapException("retireBlocked")
                    val action = if (synced) "retiredSynced" else "retiredModified"
                    appendJournal(retirementRecord(ordinal, path, "symlink", action, path, null, 0L))
                    if (synced) {
                        retiredSynced += 1
                    } else {
                        retiredModified += 1
                        conflicts.add(path)
                    }
                }
                SwapKind.DIRECTORY -> {
                    val provenDirectory = candidates.any { it.kind == "directory" }
                    val children = target.list()
                    if (children == null) continue
                    if (children.isNotEmpty()) {
                        // Guest-only descendants are independent data. Keep
                        // them (and their container), but surface a kind
                        // replacement of a proven file/symlink as a conflict.
                        if (!provenDirectory) {
                            appendJournal(JSONObject().put("record", "s").put("i", ordinal)
                                .put("path", path).put("kind", "directory")
                                .put("action", "conflict").put("preservedRel", JSONObject.NULL))
                            conflicts.add(path)
                        }
                        continue
                    }
                    if (!ops.rmdir(target)) throw WorkspaceSwapException("retireBlocked")
                    val action = if (provenDirectory) "retiredSyncedDirectory" else "retiredModifiedDirectory"
                    appendJournal(retirementRecord(ordinal, path, "directory", action, null, null, 0L))
                    if (provenDirectory) {
                        retiredSynced += 1
                    } else {
                        retiredModified += 1
                        conflicts.add(path)
                    }
                }
                else -> Unit // MISSING/OTHER/UNREADABLE: never guessed or followed
            }
        }
        ops.fsyncDirectory(destination)
        return SwapOutcome(0, 0, 0, 0, conflicts,
            retiredSynced = retiredSynced, retiredModified = retiredModified)
    }

    private fun realParentDirectories(components: List<String>): Boolean {
        var cursor = destination
        for (index in 0 until components.size - 1) {
            cursor = File(cursor, components[index])
            if (ops.kind(cursor) != SwapKind.DIRECTORY) return false
        }
        return true
    }

    private fun retirementRecord(index: Int, path: String, kind: String, action: String,
                                 preservedRel: String?, digest: String?, size: Long): JSONObject {
        val record = JSONObject().put("record", "s").put("i", index)
            .put("path", path).put("kind", kind).put("action", action)
            .put("preservedRel", preservedRel ?: JSONObject.NULL)
        if (digest != null) record.put("preservedSha256", digest).put("preservedBytes", size)
        return record
    }

    private fun swapFile(index: Int, entry: StagedEntry, target: File): Pair<String, SwappedCopy?> {
        val stage = File(stageRoot, entry.path)
        return when (ops.kind(target)) {
            SwapKind.MISSING -> {
                if (!ops.rename(stage, target)) "conflict" to null
                else {
                    appendJournal(swapRecord(index, entry, "created", null))
                    "created" to null
                }
            }
            SwapKind.FILE -> {
                val current = ops.streamDigest(target) ?: return "conflict" to null
                if (current.first == entry.digest && current.second == entry.size) {
                    ops.unlink(stage)
                    appendJournal(swapRecord(index, entry, "unchanged", null))
                    return "unchanged" to null
                }
                val syncedPrevious = if (priorProofs != null) {
                    priorProofs[entry.path]?.any {
                        it.kind == "file" && it.digest == current.first && it.size == current.second
                    } == true
                } else manifest?.let { it.lookup(entry.path)?.digest == current.first } == true
                val preservedRel = if (syncedPrevious) entry.path else entry.path
                if (!moveAside(target, preservedRel)) return "conflict" to null
                if (!ops.rename(stage, target)) {
                    // Best-effort immediate undo of THIS entry before the
                    // caller runs the full reverse restore.
                    ops.rename(File(preserveRoot, preservedRel), target)
                    return "conflict" to null
                }
                val action = if (syncedPrevious) "swappedSynced" else "swappedPreserved"
                // REAL custody facts, recorded only after BOTH renames landed:
                // `current` is the digest/size of the destination bytes the
                // just-completed move-aside carried into the preserve tree;
                // `entry` is the staged baseline that just took its place.
                val fact = SwappedCopy(entry.path, action, current.first, current.second,
                                       entry.digest, entry.size)
                appendJournal(swapRecord(index, entry, action, preservedRel, fact))
                action to fact
            }
            SwapKind.SYMLINK -> {
                val preservedRel = entry.path
                if (!moveAside(target, preservedRel)) return "conflict" to null
                if (!ops.rename(stage, target)) {
                    ops.rename(File(preserveRoot, preservedRel), target)
                    return "conflict" to null
                }
                appendJournal(swapRecord(index, entry, "swappedPreserved", preservedRel))
                // The engine never hashed a symlink destination; no digest
                // fact exists for this entry and none is fabricated.
                "swappedPreserved" to null
            }
            else -> "conflict" to null
        }
    }

    private fun swapSymlink(index: Int, entry: StagedEntry, target: File): String {
        return when (ops.kind(target)) {
            SwapKind.MISSING -> {
                if (!ops.symlink(entry.linkTarget ?: return "conflict", target)) "conflict"
                else {
                    appendJournal(swapRecord(index, entry, "created", null))
                    "created"
                }
            }
            SwapKind.SYMLINK, SwapKind.FILE -> {
                val preservedRel = entry.path
                if (!moveAside(target, preservedRel)) return "conflict"
                if (!ops.symlink(entry.linkTarget ?: "broken", target)) {
                    ops.rename(File(preserveRoot, preservedRel), target)
                    return "conflict"
                }
                appendJournal(swapRecord(index, entry, "swappedPreserved", preservedRel))
                "swappedPreserved"
            }
            else -> "conflict"
        }
    }

    /** True when the existing entry was moved into the owner-marked preserve
     *  tree (atomic rename inside the same volume). */
    private fun moveAside(existing: File, relativePath: String): Boolean {
        val preserveTarget = File(preserveRoot, relativePath)
        preserveTarget.parentFile?.let { parent ->
            var cursor: File? = parent
            val chain = mutableListOf<File>()
            while (cursor != null && !cursor.isDirectory) {
                chain.add(0, cursor)
                cursor = cursor.parentFile
            }
            for (directory in chain) ops.mkdir(directory)
            if (!parent.isDirectory) return false
        }
        if (ops.kind(preserveTarget) != SwapKind.MISSING) return false
        return ops.rename(existing, preserveTarget)
    }

    private fun ensureParentDirectories(path: String, index: Int): Boolean {
        val parts = path.split("/")
        var cursor = destination
        for (part in parts.dropLast(1)) {
            cursor = File(cursor, part)
            when (ops.kind(cursor)) {
                SwapKind.DIRECTORY -> continue
                SwapKind.MISSING -> {
                    if (!ops.mkdir(cursor)) return false
                    appendJournal(JSONObject().put("record", "p").put("i", index).put("path", relativeOf(cursor)))
                }
                else -> return false
            }
        }
        return true
    }

    private fun relativeOf(file: File): String =
        file.absolutePath.removePrefix(destination.absolutePath + "/")

    private fun swapRecord(index: Int, entry: StagedEntry, action: String, preservedRel: String?,
                           fact: SwappedCopy? = null): JSONObject =
        JSONObject()
            .put("record", "s")
            .put("i", index)
            .put("path", entry.path)
            .put("kind", entry.kind)
            .put("action", action)
            .put("preservedRel", preservedRel ?: JSONObject.NULL)
            .also { record ->
                // Custody facts ride the SAME journal line only when the
                // engine actually measured them; legacy readers ignore the
                // extra keys and restore/acknowledge keep working.
                if (fact != null) {
                    record.put("preservedSha256", fact.preservedSha256)
                        .put("preservedBytes", fact.preservedBytes)
                        .put("installedSha256", fact.installedSha256)
                        .put("installedBytes", fact.installedBytes)
                }
            }

    private fun stashStage(entry: StagedEntry) {
        val stage = File(stageRoot, entry.path)
        if (ops.kind(stage) == SwapKind.MISSING) return
        val conflictTarget = File(preserveRoot, "stage-conflicts/" + entry.path)
        conflictTarget.parentFile?.let { parent ->
            var cursor: File? = parent
            val chain = mutableListOf<File>()
            while (cursor != null && !cursor.isDirectory) {
                chain.add(0, cursor)
                cursor = cursor.parentFile
            }
            for (directory in chain) ops.mkdir(directory)
        }
        if (ops.kind(conflictTarget) == SwapKind.MISSING) ops.rename(stage, conflictTarget)
    }

    // MARK: - Reverse restore

    /** Reverse-undoes every recorded swap/mkdir so the destination equals
     *  its prior state. Preserved copies are restored IN PLACE; a copy that
     *  cannot be restored (foreign kind appeared) is left in the preserve
     *  tree and counted. Safe to call multiple times. Returns the SAME
     *  retained-failure count the engine has always returned. */
    fun restore(): Int = restoreDetailed().retainedFailures

    /** Same single reverse-journal pass as [restore], but reporting the
     *  ACTUAL typed outcome: how many preserved prior changes were genuinely
     *  renamed back, how many new entries were genuinely reverted, and how
     *  many failures were retained in the preserve tree. Counters increment
     *  ONLY on a successful operation — never on intent. */
    fun restoreDetailed(): SwapRestoreSummary {
        val lines = runCatching { journalFile.readLines() }.getOrDefault(emptyList())
        // [0]=retainedFailures (unchanged semantics), [1]=restoredPriorChanges,
        // [2]=revertedNewEntries.
        val counters = intArrayOf(0, 0, 0)
        for (line in lines.asReversed()) {
            val record = runCatching { JSONObject(line) }.getOrNull() ?: continue
            when (record.optString("record")) {
                "s" -> restoreSwap(record, counters)
                "p" -> {
                    val directory = File(destination, record.optString("path"))
                    if (ops.kind(directory) == SwapKind.DIRECTORY && ops.rmdir(directory)) counters[2] += 1
                }
                "ack" -> return SwapRestoreSummary(restoredPriorChanges = counters[1],
                                                   revertedNewEntries = counters[2],
                                                   retainedFailures = counters[0]) // acked transactions restore nothing further (exact legacy early-return)
            }
        }
        ops.fsyncDirectory(destination)
        return SwapRestoreSummary(restoredPriorChanges = counters[1],
                                  revertedNewEntries = counters[2],
                                  retainedFailures = counters[0])
    }

    private fun restoreSwap(record: JSONObject, counters: IntArray) {
        val path = record.optString("path")
        val action = record.optString("action")
        val kind = record.optString("kind")
        val target = File(destination, path)
        val preservedRel = if (record.isNull("preservedRel")) null else record.optString("preservedRel").takeIf { it.isNotEmpty() }
        when (action) {
            "created", "mkdir" -> {
                val currentKind = ops.kind(target)
                if (kind == "directory" && currentKind == SwapKind.DIRECTORY) {
                    if (ops.rmdir(target)) counters[2] += 1 else counters[0] += 1
                } else if (kind != "directory" && (currentKind == SwapKind.FILE || currentKind == SwapKind.SYMLINK)) {
                    if (ops.unlink(target)) counters[2] += 1 else counters[0] += 1
                }
            }
            "swappedSynced", "swappedPreserved", "retiredSynced", "retiredModified" -> {
                val currentKind = ops.kind(target)
                if (currentKind == SwapKind.FILE || currentKind == SwapKind.SYMLINK) ops.unlink(target)
                val preserved = preservedRel?.let { File(preserveRoot, it) }
                if (preserved == null || ops.kind(preserved) == SwapKind.MISSING) {
                    // The prior bytes are no longer recoverable from this
                    // journal: report the failure instead of pretending the
                    // retired entry was restored.
                    counters[0] += 1
                } else if (ops.rename(preserved, target)) {
                    counters[1] += 1
                } else {
                    counters[0] += 1
                }
            }
            "retiredSyncedDirectory", "retiredModifiedDirectory" -> {
                when (ops.kind(target)) {
                    SwapKind.MISSING -> {
                        if (ops.mkdir(target)) counters[1] += 1 else counters[0] += 1
                    }
                    // A concurrent owner may already have recreated the
                    // directory; the prior state is genuinely present.
                    SwapKind.DIRECTORY -> {
                        counters[1] += 1
                    }
                    else -> counters[0] += 1
                }
            }
            "unchanged", "conflict" -> Unit
        }
    }

    // MARK: - Acknowledge (after the Core FINISH receipt)

    /** Prunes ONLY previous copies whose bytes the manifest/ledger proved
     *  already synced to Core (including unchanged copies retired by an
     *  authoritative native deletion), commits the new sync manifest, and
     *  marks the journal acknowledged. Un-synced/modified preserves remain
     *  recoverable indefinitely. */
    fun acknowledge(entries: List<StagedEntry>): Int {
        val lines = runCatching { journalFile.readLines() }.getOrDefault(emptyList())
        var pruned = 0
        for (line in lines) {
            val record = runCatching { JSONObject(line) }.getOrNull() ?: continue
            if (record.optString("record") != "s") continue
            val action = record.optString("action")
            if (action != "swappedSynced" && action != "retiredSynced") continue
            val preservedRel = if (record.isNull("preservedRel")) null else record.optString("preservedRel")
            if (preservedRel.isNullOrEmpty()) continue
            val file = File(preserveRoot, preservedRel)
            if (ops.kind(file) == SwapKind.FILE || ops.kind(file) == SwapKind.SYMLINK) {
                if (ops.unlink(file)) pruned += 1
            }
        }
        manifest?.commit(entries)
        appendJournal(JSONObject().put("record", "ack").put("prunedSynced", pruned))
        ops.fsyncDirectory(destination)
        return pruned
    }

    /** Residual un-synced preserves still recoverable (sweep gate). */
    fun openPreserveCount(): Int = countTree(preserveRoot)

    private fun countTree(root: File): Int {
        if (ops.kind(root) != SwapKind.DIRECTORY) return 0
        var count = 0
        val stack = ArrayDeque<File>()
        stack.addLast(root)
        while (stack.isNotEmpty()) {
            val directory = stack.removeLast()
            val children = directory.listFiles() ?: continue
            for (child in children) {
                when (ops.kind(child)) {
                    SwapKind.DIRECTORY -> stack.addLast(child)
                    SwapKind.FILE, SwapKind.SYMLINK -> count += 1
                    else -> Unit
                }
            }
        }
        return count
    }

    private fun appendJournal(record: JSONObject) {
        FileOutputStream(journalFile, true).use { stream ->
            stream.write((record.toString() + "\n").toByteArray(Charsets.UTF_8))
            stream.flush()
            stream.fd.sync()
        }
    }
}

/** Workspace-stable sync manifest (sibling of the destination, OUTSIDE it):
 *  path → the representation the last ACKed Core baseline installed. It
 *  licenses pruning prior copies whose current bytes match it exactly, and
 *  is one of the two durable inputs to native-deletion retirement (the other
 *  is [WorkspaceSyncedLedger]). Unknown paths default to un-synced
 *  (preserve). Directory/symlink lines are additive; legacy file-only lines
 *  keep their original meaning. */
class WorkspaceSyncManifest(
    private val journalParent: File,
    projectID: String,
    private val ops: WorkspaceSwapOps,
) {
    data class SyncRecord(val digest: String, val size: Long)

    private val directory = File(journalParent, ".floe-ws-" + projectID.lowercase())
    private val file = File(directory, FILE_NAME)

    /** A new ACKed import starts a distinct proof generation, even when its
     * bytes happen to equal an older baseline. Legacy manifests have none. */
    fun generation(): String? {
        if (ops.kind(directory) != SwapKind.DIRECTORY || ops.kind(file) != SwapKind.FILE) return null
        return runCatching {
            file.bufferedReader().use { reader ->
                val header = JSONObject(reader.readLine() ?: return@use null)
                if (header.optString("record") != "baseline") return@use null
                java.util.UUID.fromString(header.getString("generation")).toString()
            }
        }.getOrNull()
    }

    /** All durable imported-baseline proofs, bounded by the transfer entry
     *  budget. A malformed line is ignored (it can only make retirement more
     *  conservative). */
    fun snapshot(): List<WorkspaceSyncedProof> {
        if (ops.kind(directory) != SwapKind.DIRECTORY || ops.kind(file) != SwapKind.FILE) {
            return emptyList()
        }
        val result = mutableListOf<WorkspaceSyncedProof>()
        runCatching {
            file.forEachLine { line ->
                if (result.size >= MAX_ENTRIES) return@forEachLine
                val record = runCatching { JSONObject(line) }.getOrNull() ?: return@forEachLine
                val path = record.optString("path", "")
                val kind = record.optString("kind", "file")
                val target = if (record.isNull("linkTarget")) null
                else record.optString("linkTarget", "").takeIf { it.isNotEmpty() }
                val proof = WorkspaceSyncedProof(
                    path, kind, record.optLong("size", -1), record.optString("digest", ""), target,
                )
                if (validSyncedProof(proof)) result.add(proof)
            }
        }
        return result
    }

    fun lookup(path: String): SyncRecord? {
        if (ops.kind(directory) != SwapKind.DIRECTORY || ops.kind(file) != SwapKind.FILE) {
            return null
        }
        var found: SyncRecord? = null
        runCatching {
            file.forEachLine { line ->
                if (found != null) return@forEachLine
                val record = runCatching { JSONObject(line) }.getOrNull() ?: return@forEachLine
                if (record.optString("path") != path) return@forEachLine
                if (record.optString("kind", "file") != "file") return@forEachLine
                val digest = record.optString("digest", "")
                if (!digest.matches(SYNCED_PROOF_DIGEST)) return@forEachLine
                found = SyncRecord(digest, record.optLong("size", -1))
            }
        }
        return found
    }

    /** Atomic full rewrite: tmp + fsync + rename. Only representations that
     *  can be proven are written; the caller passes the entries the swap
     *  ACTUALLY installed (conflict paths are excluded). */
    fun commit(entries: List<StagedEntry>) {
        when (ops.kind(directory)) {
            SwapKind.MISSING -> if (!ops.mkdir(directory)) return
            SwapKind.DIRECTORY -> Unit
            else -> return
        }
        val temp = File(directory, TEMP_NAME)
        if (ops.kind(temp) != SwapKind.MISSING && !ops.unlink(temp)) return
        if (ops.kind(temp) != SwapKind.MISSING) return
        try {
            FileOutputStream(temp, false).use { stream ->
                val header = JSONObject().put("record", "baseline")
                    .put("generation", java.util.UUID.randomUUID().toString())
                stream.write((header.toString() + "\n").toByteArray(Charsets.UTF_8))
                for (entry in entries) {
                    val proof = syncedProofFor(entry) ?: continue
                    val record = JSONObject()
                        .put("path", proof.path)
                        .put("kind", proof.kind)
                        .put("size", proof.size)
                        .put("digest", proof.digest)
                    if (proof.linkTarget != null) record.put("linkTarget", proof.linkTarget)
                    stream.write((record.toString() + "\n").toByteArray(Charsets.UTF_8))
                }
                stream.flush()
                stream.fd.sync()
            }
        } catch (_: Exception) {
            return
        }
        if (!ops.rename(temp, file)) runCatching { temp.delete() }
        else ops.fsyncDirectory(directory)
    }

    private companion object {
        const val FILE_NAME = "manifest.jsonl"
        const val TEMP_NAME = "manifest.tmp"
        const val MAX_ENTRIES = 100_000
    }
}

