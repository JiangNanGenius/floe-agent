// SPDX-License-Identifier: MPL-2.0
package com.floe.android.workspacebridge

import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream

/**
 * One durable proof that a workspace-relative entry was previously synced to
 * Core. Proofs are relative-only: they never carry a Core absolute path, a
 * command, or file content.
 *
 * A proof exists only from an ACTUAL completed transfer:
 *  * the import manifest records exactly what the ACKed Core baseline
 *    installed into the stable `Workspaces/<projectUUID>` destination;
 *  * the export ledger records exactly what a SUCCESSFUL `EXPORT_FINISH`
 *    committed for entries the imported baseline did not already contain
 *    (guest-created files/directories/symlinks, plus adopted live inputs).
 *
 * A proof is a SAFETY INPUT, never an instruction: retirement additionally
 * requires the current destination entry to match the recorded kind and
 * digest/size (files), the exact link target (symlinks), or the directory
 * kind, and only for paths ABSENT from the new Core snapshot. Anything
 * unproven or diverged is preserved, never deleted by absence.
 *
 * LEGACY MIGRATION BOUNDARY (public81/code107 and earlier): the only
 * durable artifact such a build left is `manifest.jsonl` — the digest/size
 * of the last ACKed IMPORT baseline (files only). It has no
 * `exported.jsonl`, so it CANNOT prove that a guest-created or
 * guest-modified representation was ever committed by a successful
 * `EXPORT_FINISH`. This implementation never guesses or manufactures that
 * proof:
 *  * an unchanged destination matching the old import digest is proven
 *    synced and may be retired after an authoritative native deletion;
 *  * a destination whose bytes/link target DIVERGED from the old import
 *    digest is treated as unsynced/modified: it is parked in the
 *    owner-marked preserve tree and reported as a recoverable conflict,
 *    never deleted as if it were the proven synced representation;
 *  * a path with NO durable proof at all is left untouched (and may still
 *    be exported as ordinary guest data); only a subsequent REAL successful
 *    export in this build creates `exported.jsonl` and makes it provable.
 */
data class WorkspaceSyncedProof(
    val path: String,
    val kind: String,          // "file" | "directory" | "symlink"
    val size: Long,            // files only (0 for directory/symlink)
    val digest: String,        // files only (empty otherwise)
    val linkTarget: String?,   // symlinks only
)

internal val SYNCED_PROOF_DIGEST = Regex("^[0-9a-f]{64}$")

/** Strict proof grammar. Malformed/legacy-unknown records are ignored: a
 *  skipped proof can only make retirement MORE conservative. */
internal fun validSyncedProof(proof: WorkspaceSyncedProof): Boolean {
    if (WorkspaceRelativeValidation.validate(proof.path) == null) return false
    return when (proof.kind) {
        "file" -> proof.size >= 0 && proof.digest.matches(SYNCED_PROOF_DIGEST) &&
            proof.linkTarget == null
        "directory" -> proof.size == 0L && proof.digest.isEmpty() && proof.linkTarget == null
        "symlink" -> proof.size == 0L && proof.digest.isEmpty() && proof.linkTarget != null &&
            proof.linkTarget.toByteArray(Charsets.UTF_8).size <=
            WorkspaceRelativeValidation.MAX_TOTAL_BYTES
        else -> false
    }
}

/** The proof representation of one imported/staged entry, or null when the
 *  entry itself cannot be represented truthfully. */
internal fun syncedProofFor(entry: StagedEntry): WorkspaceSyncedProof? {
    val proof = WorkspaceSyncedProof(entry.path, entry.kind, entry.size, entry.digest, entry.linkTarget)
    return proof.takeIf { validSyncedProof(it) }
}

/**
 * Union the durable import manifest with the export ledger (path -> every
 * proven representation; a path may have both an older imported proof and a
 * newer exported proof), then synthesize DIRECTORY proofs for every ancestor
 * of a proven path. An existing file/symlink necessarily lived under real
 * directories in both Core and the destination, so its ancestors were part
 * of the same synced tree; retirement still removes such a directory ONLY
 * when it is empty after its own proven children were handled.
 *
 * The map is relative-path keyed and bounded by the number of stored proof
 * lines (itself bounded by the transfer entry budget).
 */
internal fun mergeSyncedProofs(
    imported: List<WorkspaceSyncedProof>,
    exported: List<WorkspaceSyncedProof>,
): Map<String, List<WorkspaceSyncedProof>> {
    val merged = LinkedHashMap<String, MutableList<WorkspaceSyncedProof>>()
    fun add(proof: WorkspaceSyncedProof) {
        if (!validSyncedProof(proof)) return
        val values = merged.getOrPut(proof.path) { mutableListOf() }
        if (values.none { it == proof }) values.add(proof)
    }
    imported.forEach(::add)
    exported.forEach(::add)
    val ancestorDirectories = LinkedHashSet<String>()
    for (path in merged.keys) {
        val components = WorkspaceRelativeValidation.validate(path) ?: continue
        for (index in 1 until components.size) {
            ancestorDirectories.add(components.subList(0, index).joinToString("/"))
        }
    }
    for (path in ancestorDirectories) {
        val values = merged.getOrPut(path) { mutableListOf() }
        if (values.none { it.kind == "directory" }) {
            values.add(WorkspaceSyncedProof(path, "directory", 0, "", null))
        }
    }
    return merged.mapValues { it.value.toList() }
}

/**
 * Project-scoped complete latest EXPORT ledger, a SIBLING of the stable destination (inside
 * the existing `.floe-ws-<projectID lowercase>` ownership directory that
 * `WorkspaceCopyWiper` already removes as one target-owned unit). It records
 * the exact complete representation a successful export committed, bound to
 * the current import generation. A complete (even empty) export supersedes
 * the older manifest. An uncertainty marker is durable before export begins,
 * so a lost result cannot revive older versions as deletion proofs.
 *
 * These files never enter the destination and are never exposed to the
 * guest through the workspace bind. Writes are temp+fsync+rename; reads and
 * writes refuse a non-directory ownership path and a non-regular ledger
 * (no-follow where the backend provides it).
 */
class WorkspaceSyncedLedger(
    journalParent: File,
    projectID: String,
    private val ops: WorkspaceSwapOps,
) {
    private val directory = File(journalParent, ".floe-ws-" + projectID.lowercase())
    private val file = File(directory, LEDGER_NAME)
    private val manifest = WorkspaceSyncManifest(journalParent, projectID, ops)
    private val lock = Any()

    fun snapshot(): List<WorkspaceSyncedProof> = synchronized(lock) { read().orEmpty() }

    /** Null = no export for this import generation; empty = a complete empty
     * export, or uncertain export evidence. Neither may revive old proofs. */
    fun snapshotOrNull(): List<WorkspaceSyncedProof>? = synchronized(lock) { read() }

    /** Invalidate the previous proof BEFORE any export can mutate Core.
     * If completion/IO is lost, stale imported versions cannot license pruning. */
    fun beginExport(): Boolean = synchronized(lock) { write(emptyList(), "uncertain") }

    /** Atomically REPLACE the ledger with the proofs of THIS successful
     *  export. An empty list is an honest completed empty tree,
     * not an absent/unknown ledger. */
    fun commit(entries: List<WorkspaceSyncedProof>) {
        synchronized(lock) { write(deduplicate(entries), "complete") }
    }

    /** Durably merge one ALREADY-COMMITTED entry (live input adoption). Used
     *  before any export can replace the ledger, so a later failed export
     *  cannot silently drop the proof of an input the Core baseline adopted. */
    fun merge(proof: WorkspaceSyncedProof) {
        if (!validSyncedProof(proof)) return
        synchronized(lock) {
            val merged = LinkedHashMap<String, WorkspaceSyncedProof>()
            for (existing in read() ?: manifest.snapshot()) merged[keyOf(existing)] = existing
            merged.entries.removeAll { it.value.path == proof.path }
            merged[keyOf(proof)] = proof
            write(merged.values.toList(), "complete")
        }
    }

    private fun read(): List<WorkspaceSyncedProof>? {
        if (ops.kind(file) == SwapKind.MISSING) return null
        if (ops.kind(directory) != SwapKind.DIRECTORY || ops.kind(file) != SwapKind.FILE) return emptyList()
        val generation = manifest.generation() ?: return emptyList()
        val result = mutableListOf<WorkspaceSyncedProof>()
        return try {
            file.bufferedReader().use { reader ->
                val header = JSONObject(reader.readLine() ?: return emptyList())
                if (header.optString("record") != "export") return emptyList()
                if (header.optString("generation") != generation) return null
                if (header.optString("state") != "complete") return emptyList()
                reader.forEachLine { line ->
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
            result
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun write(entries: List<WorkspaceSyncedProof>, state: String): Boolean {
        val generation = manifest.generation() ?: return false
        when (ops.kind(directory)) {
            SwapKind.MISSING -> if (!ops.mkdir(directory)) return false
            SwapKind.DIRECTORY -> Unit
            else -> return false
        }
        val temp = File(directory, TEMP_NAME)
        if (ops.kind(temp) != SwapKind.MISSING && !ops.unlink(temp)) return false
        if (ops.kind(temp) != SwapKind.MISSING) return false
        try {
            FileOutputStream(temp, false).use { stream ->
                val header = JSONObject().put("record", "export").put("generation", generation)
                    .put("state", state)
                stream.write((header.toString() + "\n").toByteArray(Charsets.UTF_8))
                for (entry in entries) {
                    val record = JSONObject()
                        .put("path", entry.path)
                        .put("kind", entry.kind)
                        .put("size", entry.size)
                        .put("digest", entry.digest)
                    if (entry.linkTarget != null) record.put("linkTarget", entry.linkTarget)
                    stream.write((record.toString() + "\n").toByteArray(Charsets.UTF_8))
                }
                stream.flush()
                stream.fd.sync()
            }
        } catch (_: Exception) {
            return false
        }
        if (!ops.rename(temp, file)) { runCatching { temp.delete() }; return false }
        ops.fsyncDirectory(directory)
        return true
    }

    private fun deduplicate(entries: List<WorkspaceSyncedProof>): List<WorkspaceSyncedProof> {
        val merged = LinkedHashMap<String, WorkspaceSyncedProof>()
        for (entry in entries) {
            if (validSyncedProof(entry)) merged[keyOf(entry)] = entry
        }
        return merged.values.toList()
    }

    private fun keyOf(proof: WorkspaceSyncedProof): String =
        proof.path + "\u0000" + proof.kind

    private companion object {
        const val LEDGER_NAME = "exported.jsonl"
        const val TEMP_NAME = "exported.tmp"
        const val MAX_ENTRIES = 100_000
    }
}
