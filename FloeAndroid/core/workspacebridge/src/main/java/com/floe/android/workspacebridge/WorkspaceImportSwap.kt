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
 *   into place → acknowledge → prune ONLY previous copies proven already
 *   synced to Core.
 *
 * Guarantees:
 *  * cancellation/failure DURING SWAP restores the prior workspace exactly
 *    (reverse journal); nothing staged mid-way leaks in;
 *  * un-synced / unknown previous runtime output is never blindly removed:
 *    its bytes move to the owner-marked preserve tree and stay recoverable
 *    (reported counts; the sync manifest only licenses pruning copies the
 *    Core baseline already proved synced);
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

class WorkspaceSwapException(val code: String) : Exception(code)

class WorkspaceImportSwap(
    private val destination: File,
    private val stageRoot: File,
    private val preserveRoot: File,
    private val journalFile: File,
    private val manifest: WorkspaceSyncManifest?,
    private val ops: WorkspaceSwapOps,
) {
    data class SwapOutcome(
        val created: Int,
        val replacedSynced: Int,
        val preservedUnsynced: Int,
        val unchanged: Int,
        val conflicts: List<String>,
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
                    .let { outcome ->
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
        }
        ops.fsyncDirectory(destination)
        return SwapOutcome(created, replacedSynced, preservedUnsynced, unchanged, conflicts)
    }

    private fun swapFile(index: Int, entry: StagedEntry, target: File): String {
        val stage = File(stageRoot, entry.path)
        return when (ops.kind(target)) {
            SwapKind.MISSING -> {
                if (!ops.rename(stage, target)) "conflict"
                else {
                    appendJournal(swapRecord(index, entry, "created", null))
                    "created"
                }
            }
            SwapKind.FILE -> {
                val current = ops.streamDigest(target) ?: return "conflict"
                if (current.first == entry.digest && current.second == entry.size) {
                    ops.unlink(stage)
                    appendJournal(swapRecord(index, entry, "unchanged", null))
                    return "unchanged"
                }
                val syncedPrevious = manifest?.let { it.lookup(entry.path)?.digest == current.first } == true
                val preservedRel = if (syncedPrevious) entry.path else entry.path
                if (!moveAside(target, preservedRel)) return "conflict"
                if (!ops.rename(stage, target)) {
                    // Best-effort immediate undo of THIS entry before the
                    // caller runs the full reverse restore.
                    ops.rename(File(preserveRoot, preservedRel), target)
                    return "conflict"
                }
                val action = if (syncedPrevious) "swappedSynced" else "swappedPreserved"
                appendJournal(swapRecord(index, entry, action, preservedRel))
                if (syncedPrevious) "swappedSynced" else "swappedPreserved"
            }
            SwapKind.SYMLINK -> {
                val preservedRel = entry.path
                if (!moveAside(target, preservedRel)) return "conflict"
                if (!ops.rename(stage, target)) {
                    ops.rename(File(preserveRoot, preservedRel), target)
                    return "conflict"
                }
                appendJournal(swapRecord(index, entry, "swappedPreserved", preservedRel))
                "swappedPreserved"
            }
            else -> "conflict"
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

    private fun swapRecord(index: Int, entry: StagedEntry, action: String, preservedRel: String?): JSONObject =
        JSONObject()
            .put("record", "s")
            .put("i", index)
            .put("path", entry.path)
            .put("kind", entry.kind)
            .put("action", action)
            .put("preservedRel", preservedRel ?: JSONObject.NULL)

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
     *  tree and counted. Safe to call multiple times. */
    fun restore(): Int {
        val lines = runCatching { journalFile.readLines() }.getOrDefault(emptyList())
        val failures = intArrayOf(0)
        for (line in lines.asReversed()) {
            val record = runCatching { JSONObject(line) }.getOrNull() ?: continue
            when (record.optString("record")) {
                "s" -> restoreSwap(record, failures)
                "p" -> {
                    val directory = File(destination, record.optString("path"))
                    if (ops.kind(directory) == SwapKind.DIRECTORY) ops.rmdir(directory)
                }
                "ack" -> return failures[0] // acked transactions restore nothing further
            }
        }
        ops.fsyncDirectory(destination)
        return failures[0]
    }

    private fun restoreSwap(record: JSONObject, failures: IntArray) {
        val path = record.optString("path")
        val action = record.optString("action")
        val kind = record.optString("kind")
        val target = File(destination, path)
        val preservedRel = if (record.isNull("preservedRel")) null else record.optString("preservedRel").takeIf { it.isNotEmpty() }
        when (action) {
            "created", "mkdir" -> {
                val currentKind = ops.kind(target)
                if (kind == "directory" && currentKind == SwapKind.DIRECTORY) {
                    if (!ops.rmdir(target)) failures[0] += 1
                } else if (kind != "directory" && (currentKind == SwapKind.FILE || currentKind == SwapKind.SYMLINK)) {
                    if (!ops.unlink(target)) failures[0] += 1
                }
            }
            "swappedSynced", "swappedPreserved" -> {
                val currentKind = ops.kind(target)
                if (currentKind == SwapKind.FILE || currentKind == SwapKind.SYMLINK) ops.unlink(target)
                val preserved = preservedRel?.let { File(preserveRoot, it) }
                if (preserved != null && ops.kind(preserved) != SwapKind.MISSING) {
                    if (!ops.rename(preserved, target)) failures[0] += 1
                }
            }
            "unchanged", "conflict" -> Unit
        }
    }

    // MARK: - Acknowledge (after the Core FINISH receipt)

    /** Prunes ONLY previous copies whose bytes the manifest proved already
     *  synced to Core, commits the new sync manifest, and marks the journal
     *  acknowledged. Un-synced preserves remain recoverable indefinitely. */
    fun acknowledge(entries: List<StagedEntry>): Int {
        val lines = runCatching { journalFile.readLines() }.getOrDefault(emptyList())
        var pruned = 0
        for (line in lines) {
            val record = runCatching { JSONObject(line) }.getOrNull() ?: continue
            if (record.optString("record") != "s" || record.optString("action") != "swappedSynced") continue
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
 *  path → last ACKed staged digest/size. It ONLY licenses pruning prior
 *  copies whose current bytes match it exactly; unknown paths default to
 *  un-synced (preserve). */
class WorkspaceSyncManifest(
    private val journalParent: File,
    projectID: String,
    private val ops: WorkspaceSwapOps,
) {
    data class SyncRecord(val digest: String, val size: Long)

    private val directory = File(journalParent, ".floe-ws-" + projectID.lowercase())
    private val file = File(directory, "manifest.jsonl")

    fun lookup(path: String): SyncRecord? {
        val lines = runCatching { file.readLines() }.getOrDefault(emptyList())
        for (line in lines) {
            val record = runCatching { JSONObject(line) }.getOrNull() ?: continue
            if (record.optString("path") == path) {
                return SyncRecord(record.optString("digest"), record.optLong("size", -1))
            }
        }
        return null
    }

    /** Atomic full rewrite: tmp + fsync + rename. */
    fun commit(entries: List<StagedEntry>) {
        if (!directory.isDirectory) ops.mkdir(directory)
        val temp = File(directory, "manifest.tmp")
        FileOutputStream(temp, false).use { stream ->
            for (entry in entries.filter { it.kind == "file" }) {
                val record = JSONObject().put("path", entry.path).put("digest", entry.digest).put("size", entry.size)
                stream.write((record.toString() + "\n").toByteArray(Charsets.UTF_8))
            }
            stream.flush()
            stream.fd.sync()
        }
        if (!ops.rename(temp, file)) runCatching { temp.delete() }
    }
}

