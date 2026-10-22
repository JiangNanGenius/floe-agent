// SPDX-License-Identifier: MPL-2.0
package com.floe.android.workspacebridge

import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.BasicFileAttributes
import java.security.MessageDigest

/**
 * G03-R3 (job-7e9db10b801940c2): the runtime-UID execution core of the
 * `runtimeWorkspaceCopies.clear` lane. Deletes ONLY the COMPLETE proven
 * target-project scope inside THIS runtime's private workspace root —
 * never a path prefix, never the first project, never capped at the
 * bounded evidence keys:
 *
 *  * the stable lease copy `Workspaces/<exact canonical projectID>` (the
 *    deterministic project mapping the original lease materialized);
 *  * the project sync manifest `Workspaces/.floe-ws-<projectID lowercase>`;
 *  * target-attributable transfer journals `Workspaces/.floe-wt-<key>` —
 *    attribution requires the evidence session key EXACTLY matching the
 *    directory name AND a valid `marker.json` (record=="session",
 *    sessionKey==key). Anything else stays untouched: unrelated projects,
 *    other journals, shared environment roots (Environments/Base/Scratch
 *    live OUTSIDE this root by construction), user exports and
 *    unknown/foreign/unsafe paths are retained.
 *
 * Safety rails (all fail closed with an honest RETENTION, never a fake
 * success):
 *  * caller-proven active-work gates run BEFORE any effect — a live grant
 *    for a target key defers; an unrelated busy workload also defers (the
 *    caller owns stop/recovery authority; this engine never cancels
 *    anything, and deletion happens only after the caller proved whole
 *    runtime-UID process quiescence);
 *  * symlinks are never followed (NOFOLLOW everywhere; any entry — even a
 *    dangling link — at a target-attributable path refuses);
 *  * retirement is atomic: each target path is MOVED (ATOMIC_MOVE) into a
 *    scope-deterministic hidden retire directory
 *    `Workspaces/.floe-wipe-<projectID lowercase>-<targetEpoch>` BEFORE any
 *    unlink; the durable owner metadata rides as the sidecar marker file
 *    `Workspaces/.floe-wipe-<...>.json` (never inside the deleted tree), an
 *    interrupted pass revalidates it and CONTINUES, and it is removed only
 *    after the WHOLE scope committed;
 *  * bounded enumeration: exceeding the per-pass effect budget refuses with
 *    retention ("partial budget exhausted" is NEVER reported cleared);
 *  * truncated evidence with a remaining recoverable (un-acknowledged or
 *    open-preserve) journal refuses until attribution settles;
 *  * real directory drain (fsync) is required before ack;
 *  * `bytesFreed` is the sum of ACTUAL regular-file sizes removed (logical
 *    bytes), `pathsRemoved` the real unlinked paths — never a df claim,
 *    never an echo placeholder.
 *
 * The deterministic executor proof digest covers the scope identity, the
 * executor UID and this pass's measured effect, so a "cleared" receipt is
 * always bound to a real, reproducible execution record.
 */
class WorkspaceCopyWiper(
    private val workspacesRoot: File,
    private val ownership: (RuntimeCleanupScope) -> Boolean,
    private val activeWork: () -> Boolean = { false },
    private val liveSession: (String) -> Boolean = { false },
    private val directoryDrain: (File) -> Boolean = { true },
    private val executorUid: Int = -1,
    private val limits: Limits = Limits(),
) {
    data class Limits(val maximumUnlinkOps: Int = 50_000, val maximumUnlinkBytes: Long = Long.MAX_VALUE)

    sealed class Outcome {
        data class Cleared(val pathsRemoved: Long, val bytesFreed: Long, val proofDigest: String) : Outcome()
        /** Honest retention: `progressPaths` material already moved/removed
         *  stays removed; the obligation retries from the durable marker
         *  (never a cleared ack, never a rolled-back lie). */
        data class Retained(val reason: String, val progressPaths: Long = 0, val progressBytes: Long = 0) : Outcome()
    }

    private class Counter {
        var paths = 0L
        var bytes = 0L
        var unlinks = 0
    }

    /** Executes one bounded, idempotent pass over the proven scope. */
    fun run(scope: RuntimeCleanupScope): Outcome {
        // Re-validate the scope locally (defense in depth: the engine owns
        // the deletion, so it re-checks EVERY addressing rule first).
        if (!RuntimeCleanupScope.requestIDMatches(scope.requestID) ||
            !RuntimeCleanupScope.uuidMatches(scope.conversationID) ||
            !RuntimeCleanupScope.uuidMatches(scope.projectID) ||
            scope.targetEpoch <= 0 ||
            scope.workspaceRelativePath != "PrivateTasks/${scope.conversationID}" ||
            scope.evidenceSessionKeys.size > RuntimeCleanupScope.MAX_EVIDENCE_KEYS ||
            scope.evidenceSessionKeys.any { !RuntimeCleanupScope.sessionKeyMatches(it) } ||
            scope.evidenceSessionKeys.distinct().size != scope.evidenceSessionKeys.size
        ) return Outcome.Retained("scopeInvalid")

        // Active work defers the TARGET; unrelated running work A also
        // defers B here (never cancel A — the caller owns stop authority).
        if (activeWork()) return Outcome.Retained("ownedWorkActive")

        val root = workspacesRoot.canonicalFile
        if (root != workspacesRoot) return Outcome.Retained("rootUnsafe")
        if (!root.present()) {
            // The runtime's workspace root does not exist at all: nothing
            // target-owned can survive here (e.g. runtime data reset after
            // the scope was proven). Honest zero-effect completion; the
            // claim/epoch/ownership gates already passed above.
            return Outcome.Cleared(0, 0, wipeProofDigest(
                scope, executorUid, 0, 0, projectRemoved = false, manifestRemoved = false,
                journalsRemoved = 0, journalsRetained = 0))
        }
        if (!root.isDirectoryNoFollow()) return Outcome.Retained("rootUnsafe")

        val evidence = scope.evidenceSessionKeys.toSet()
        val project = directChild(root, scope.projectID) ?: return Outcome.Retained("pathUnsafe")
        val manifest = directChild(root, MANIFEST_PREFIX + scope.projectID.lowercase())
            ?: return Outcome.Retained("pathUnsafe")
        val retireName = WIPE_PREFIX + scope.projectID.lowercase() + "-" + scope.targetEpoch
        val retire = directChild(root, retireName) ?: return Outcome.Retained("pathUnsafe")
        // Durable owner metadata rides as a SIDEcar marker file so it is
        // never inside the deleted tree: it is created BEFORE any effect
        // and removed ONLY after the whole scope committed.
        val scopeMarker = directChild(root, "$retireName.json") ?: return Outcome.Retained("pathUnsafe")
        val journals = evidence.mapNotNull { key -> directChild(root, JOURNAL_PREFIX + key)?.let { key to it } }
        if (journals.size != evidence.size) return Outcome.Retained("pathUnsafe")

        // Source safety: every tree must be a REAL directory and the marker
        // a REAL regular file. Links (including dangling ones), impostor
        // file types and unstatable entries refuse the whole scope.
        for ((name, candidate) in listOf(
            "project" to project, "manifest" to manifest, "retire" to retire,
        ) + journals.map { (key, dir) -> "journal${key.take(8)}" to dir }) {
            if (!candidate.present() || candidate.isDirectoryNoFollow()) continue
            val attrs = candidate.lstat()
            val kind = when {
                attrs == null -> "unstatable"
                attrs.isSymbolicLink -> "symlink"
                else -> "notDirectory"
            }
            return Outcome.Retained("unsafe$name:$kind")
        }
        if (scopeMarker.present() && !scopeMarker.isRegularNoFollow()) {
            return Outcome.Retained("unsafeMarker:notRegular")
        }

        val sources = listOf(project, manifest, retire, scopeMarker) + journals.map { it.second }
        val anyTargetMaterialPresent = sources.any { it.present() }

        // Journals must carry their ORIGINAL owner marker to be attributable;
        // a target-named-but-unmarked journal is unknown material -> refuse.
        for ((key, dir) in journals) {
            if (!dir.present()) continue
            val journalMarker = readMarker(File(dir, "marker.json"))
                ?: return Outcome.Retained("journalMarkerInvalid")
            if (journalMarker.optString("record") != "session" || journalMarker.optString("sessionKey") != key) {
                return Outcome.Retained("journalMarkerMismatch")
            }
        }

        // Ownership proof: present material REQUIRES the positive original
        // binding (native lease registry authority via the caller). Nothing
        // present + no binding is the proven-absent idempotent completion.
        if (anyTargetMaterialPresent && !ownership(scope)) return Outcome.Retained("ownershipUnproven")

        // Live grants for ANY target key defer the whole scope (never delete
        // under an open transfer session).
        for ((key, dir) in journals) if (dir.present() && liveSession(key)) return Outcome.Retained("grantLive")

        // Honest attribution under truncated evidence: an unattributed
        // journal that is still RECOVERABLE (un-acknowledged or open
        // preserves) MAY be target-owned; refuse until the existing stale
        // journal authority retires it. Never delete unknown metadata.
        if (scope.evidenceTruncated && recoverableUnattributedJournal(root, evidence)) {
            return Outcome.Retained("attributionIncomplete")
        }

        val counter = Counter()

        if (!anyTargetMaterialPresent) {
            // Proven absent: zero-effect honest completion (idempotent
            // settle after a prior full pass or a runtime data reset).
            return Outcome.Cleared(0, 0, wipeProofDigest(
                scope, executorUid, 0, 0, projectRemoved = false, manifestRemoved = false,
                journalsRemoved = 0, journalsRetained = 0))
        }

        // A committed pass that died between the last tree unlink and the
        // marker unlink finalizes the retirement first.
        if (scopeMarker.present() && !retire.present() &&
            !project.present() && !manifest.present() && journals.none { it.second.present() }
        ) {
            if (!deleteQuietly(scopeMarker)) return Outcome.Retained("markerUnlinkFailed")
            if (!runCatching { directoryDrain(root) }.getOrDefault(false)) return Outcome.Retained("drainUnproven")
            return Outcome.Cleared(0, 0, wipeProofDigest(
                scope, executorUid, 0, 0, projectRemoved = false, manifestRemoved = false,
                journalsRemoved = 0, journalsRetained = 0))
        }

        // Continue an interrupted earlier pass first (hidden retire tree).
        if (retire.present() || scopeMarker.present()) {
            if (scopeMarker.present()) {
                val markerValue = readMarker(scopeMarker) ?: return Outcome.Retained("retireMarkerInvalid")
                if (markerValue.optString("conversationID") != scope.conversationID ||
                    markerValue.optString("projectID") != scope.projectID ||
                    markerValue.optLong("targetEpoch", -1) != scope.targetEpoch
                ) return Outcome.Retained("retireScopeMismatch")
            } else {
                // A scope-named retire tree WITHOUT its sidecar marker is
                // unknown hidden material: refuse (never sweep blind).
                return Outcome.Retained("retireUnmarked")
            }
            if (retire.present()) {
                when (val wipe = deleteTreeNoFollow(retire, counter)) {
                    is TreeResult.Budget -> return Outcome.Retained("wipeBudget", counter.paths, counter.bytes)
                    is TreeResult.Failed -> return Outcome.Retained(wipe.reason, counter.paths, counter.bytes)
                    is TreeResult.Done -> Unit
                }
            }
            if (!project.present() && !manifest.present() && journals.none { it.second.present() }) {
                // The retire tree held ALL remaining target material; this
                // pass's real effect is the hidden-tree removal (measured).
                if (!deleteQuietly(scopeMarker)) return Outcome.Retained("markerUnlinkFailed", counter.paths, counter.bytes)
                if (!runCatching { directoryDrain(root) }.getOrDefault(false)) {
                    return Outcome.Retained("drainUnproven", counter.paths, counter.bytes)
                }
                return Outcome.Cleared(counter.paths, counter.bytes, wipeProofDigest(
                    scope, executorUid, counter.paths, counter.bytes, projectRemoved = false,
                    manifestRemoved = false, journalsRemoved = 0, journalsRetained = 0))
            }
        }

        // Durable owner metadata FIRST (sidecar marker, then the retire
        // directory), then the ATOMIC move-aside of every remaining target
        // path BEFORE any unlink. A failed/uncertain move RETAINS.
        val markerValue = org.json.JSONObject()
            .put("record", "workspace-wipe")
            .put("operation", RuntimeCleanupScope.OPERATION)
            .put("deletionSet", RuntimeCleanupScope.DELETION_SET)
            .put("requestID", scope.requestID)
            .put("conversationID", scope.conversationID)
            .put("projectID", scope.projectID)
            .put("targetEpoch", scope.targetEpoch)
            .put("createdAtMs", System.currentTimeMillis())
        if (!scopeMarker.present()) {
            if (!runCatching { writeMarker(scopeMarker, markerValue) }.isSuccess) {
                return Outcome.Retained("retireMarkerUnwritable", counter.paths, counter.bytes)
            }
            if (!scopeMarker.isRegularNoFollow()) {
                return Outcome.Retained("retireMarkerUncommitted", counter.paths, counter.bytes)
            }
        }
        if (!(retire.mkdir() || retire.isDirectoryNoFollow())) return Outcome.Retained("retireUncreatable")

        var projectMoved = false
        var manifestMoved = false
        var journalsMoved = 0
        fun move(source: File, targetName: String): Boolean {
            val destination = File(retire, targetName)
            if (destination.present()) return false
            return runCatching {
                Files.move(source.toPath(), destination.toPath(), StandardCopyOption.ATOMIC_MOVE)
            }.isSuccess
        }
        if (project.present()) {
            if (!move(project, "project-copy")) return Outcome.Retained("moveProjectFailed", counter.paths, counter.bytes)
            projectMoved = true
        }
        if (manifest.present()) {
            if (!move(manifest, "project-manifest")) return Outcome.Retained("moveManifestFailed", counter.paths, counter.bytes)
            manifestMoved = true
        }
        if (journals.any { it.second.present() } && !File(retire, "journals").mkdir()) {
            if (!File(retire, "journals").isDirectoryNoFollow()) {
                return Outcome.Retained("moveJournalDirFailed", counter.paths, counter.bytes)
            }
        }
        for ((key, dir) in journals) {
            if (!dir.present()) continue
            if (!move(dir, "journals/$key")) return Outcome.Retained("moveJournalFailed", counter.paths, counter.bytes)
            journalsMoved += 1
        }

        // Bounded deletion of the retired tree (real measured effects).
        when (val wipe = deleteTreeNoFollow(retire, counter)) {
            is TreeResult.Budget -> return Outcome.Retained("wipeBudget", counter.paths, counter.bytes)
            is TreeResult.Failed -> return Outcome.Retained(wipe.reason, counter.paths, counter.bytes)
            is TreeResult.Done -> Unit
        }
        // ALL scope committed: only now retire the durable owner metadata.
        if (!deleteQuietly(scopeMarker)) return Outcome.Retained("markerUnlinkFailed", counter.paths, counter.bytes)
        if (!runCatching { directoryDrain(root) }.getOrDefault(false)) {
            return Outcome.Retained("drainUnproven", counter.paths, counter.bytes)
        }
        return Outcome.Cleared(counter.paths, counter.bytes, wipeProofDigest(
            scope, executorUid, counter.paths, counter.bytes, projectMoved, manifestMoved,
            journalsMoved, evidence.size - journalsMoved))
    }

    // MARK: - internals

    private sealed class TreeResult {
        object Done : TreeResult()
        object Budget : TreeResult()
        data class Failed(val reason: String) : TreeResult()
    }

    private class Frame(val path: String, val depth: Int) { var expanded = false }

    /** No-follow bottom-up delete with measured logical counts. A symlink
     *  is deleted as the link itself; its target is NEVER followed. */
    private fun deleteTreeNoFollow(top: File, counter: Counter): TreeResult {
        val stack = ArrayDeque<Frame>()
        stack.addLast(Frame("", 0))
        while (stack.isNotEmpty()) {
            val frame = stack.last()
            val level = if (frame.path.isEmpty()) top else File(top, frame.path)
            if (!frame.expanded) {
                frame.expanded = true
                if (frame.depth > WorkspaceRelativeValidation.MAX_COMPONENTS + 16) {
                    return TreeResult.Failed("treeTooDeep")
                }
                val children = runCatching { level.list()?.toList() }.getOrNull()
                    ?: return TreeResult.Failed("unlistable")
                for (rawName in children) {
                    val relative = if (frame.path.isEmpty()) rawName else "${frame.path}/$rawName"
                    val child = File(level, rawName)
                    val attrs = child.lstat() ?: return TreeResult.Failed("unstatableEntry")
                    if (attrs.isDirectory) {
                        stack.addLast(Frame(relative, frame.depth + 1))
                        continue
                    }
                    if (counter.unlinks >= limits.maximumUnlinkOps) return TreeResult.Budget
                    if (attrs.isRegularFile && counter.bytes + attrs.size() > limits.maximumUnlinkBytes) {
                        return TreeResult.Budget
                    }
                    if (!deleteQuietly(child)) return TreeResult.Failed("unlinkFailed")
                    counter.unlinks += 1
                    counter.paths += 1
                    if (attrs.isRegularFile) counter.bytes += attrs.size()
                }
            } else {
                stack.removeLast()
                if (frame.path.isEmpty()) continue // the top closes after all frames
                if (counter.unlinks >= limits.maximumUnlinkOps) return TreeResult.Budget
                if (!deleteQuietly(level)) return TreeResult.Failed("rmdirFailed")
                counter.unlinks += 1
                counter.paths += 1
            }
        }
        if (counter.unlinks >= limits.maximumUnlinkOps) return TreeResult.Budget
        if (!deleteQuietly(top)) return TreeResult.Failed("rmdirTopFailed")
        counter.unlinks += 1
        counter.paths += 1
        return TreeResult.Done
    }

    private fun deleteQuietly(file: File): Boolean =
        runCatching { Files.delete(file.toPath()) }.isSuccess

    private fun recoverableUnattributedJournal(root: File, evidence: Set<String>): Boolean {
        val children = runCatching { root.listFiles { file -> file.name.startsWith(JOURNAL_PREFIX) } }
            .getOrNull() ?: return true // unlistable: unknown metadata -> refuse
        for (child in children) {
            val key = child.name.removePrefix(JOURNAL_PREFIX)
            if (key in evidence || !RuntimeCleanupScope.sessionKeyMatches(key)) continue
            if (!child.isDirectoryNoFollow()) continue // foreign/unsafe: not target-proven here
            if (!workspaceJournalAcknowledgedFor(child) || workspacePreserveCountFor(child) != 0) return true
        }
        return false
    }

    companion object {
        private const val MANIFEST_PREFIX = ".floe-ws-"
        private const val JOURNAL_PREFIX = ".floe-wt-"
        private const val WIPE_PREFIX = ".floe-wipe-"
    }
}

// MARK: - file primitives shared with the wipe engine (strict no-follow)

private fun File.lstat(): BasicFileAttributes? = runCatching {
    Files.readAttributes(toPath(), BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS)
}.getOrNull()

private fun File.present(): Boolean = lstat() != null
private fun File.isDirectoryNoFollow(): Boolean = lstat()?.isDirectory == true
private fun File.isRegularNoFollow(): Boolean = lstat()?.isRegularFile == true

/** Exactly one canonical child of the root (no traversal, no separators). */
private fun directChild(root: File, name: String): File? {
    if (name.isEmpty() || name == "." || name == ".." || '/' in name ||
        name.toByteArray(Charsets.UTF_8).size > 255
    ) return null
    val child = File(root, name)
    // Keep the leaf unresolved so its lstat can refuse symlinks without following them.
    return if (child.parentFile == root) child else null
}

private fun readMarker(file: File): org.json.JSONObject? = runCatching {
    if (!file.isRegularNoFollow()) return null
    Files.newByteChannel(file.toPath(), java.nio.file.StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS).use { channel ->
        if (channel.size() > 4096L) return null
        val buffer = java.nio.ByteBuffer.allocate(4097)
        while (buffer.hasRemaining()) {
            val read = channel.read(buffer)
            if (read < 0) break
            if (read == 0) return null
        }
        if (buffer.position() > 4096) return null
        org.json.JSONObject(String(buffer.array(), 0, buffer.position(), Charsets.UTF_8))
    }
}.getOrNull()

private fun writeMarker(file: File, json: org.json.JSONObject) {
    FileOutputStream(file).use { stream ->
        stream.write(json.toString().toByteArray(Charsets.UTF_8))
        stream.flush()
        stream.fd.sync()
    }
}

/** Terminal-ack tail probe, same grammar as `RuntimeWorkspaceSession`. */
private fun workspaceJournalAcknowledgedFor(journal: File): Boolean = runCatching {
    val path = File(journal, "journal.jsonl").toPath()
    if (!Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS)) return false
    Files.newByteChannel(path, java.nio.file.StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS).use { channel ->
        val size = channel.size()
        val buffer = java.nio.ByteBuffer.allocate(minOf(65536L, size).toInt())
        channel.position(maxOf(0L, size - buffer.capacity()))
        while (buffer.hasRemaining() && channel.read(buffer) > 0) { }
        buffer.flip()
        val text = Charsets.UTF_8.decode(buffer).toString()
        val key = journal.name.removePrefix(".floe-wt-")
        text.lineSequence().any { line ->
            val row = runCatching { org.json.JSONObject(line) }.getOrNull()
            row?.optString("record") == "ack" && row.optString("sessionKey") == key
        }
    }
}.getOrDefault(false)

private fun workspacePreserveCountFor(journal: File): Int = runCatching {
    val path = File(journal, "preserve").toPath()
    if (Files.notExists(path, LinkOption.NOFOLLOW_LINKS)) return 0
    if (!Files.isDirectory(path, LinkOption.NOFOLLOW_LINKS)) return Int.MAX_VALUE
    Files.newDirectoryStream(path).use { if (it.iterator().hasNext()) 1 else 0 }
}.getOrDefault(Int.MAX_VALUE)

/** Deterministic execution proof over the scope identity + the ACTUAL
 *  measured effect of one wipe pass. */
internal fun wipeProofDigest(scope: RuntimeCleanupScope, executorUid: Int, pathsRemoved: Long,
                             bytesFreed: Long, projectRemoved: Boolean, manifestRemoved: Boolean,
                             journalsRemoved: Int, journalsRetained: Int): String {
    val record = "v1|${RuntimeCleanupScope.OPERATION}|${RuntimeCleanupScope.DELETION_SET}|${scope.conversationID}|" +
        "${scope.projectID}|${scope.targetEpoch}|$executorUid|$pathsRemoved|$bytesFreed|" +
        "$projectRemoved|$manifestRemoved|$journalsRemoved|$journalsRetained"
    return MessageDigest.getInstance("SHA-256").digest(record.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }
}
