// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import android.content.Context
import android.os.Process
import android.system.Os
import android.system.OsConstants
import com.floe.android.linuxruntime.supervision.Quiescence
import com.floe.android.linuxruntime.supervision.RecoveryOutcome
import com.floe.android.runtimeipc.RuntimeWire
import com.floe.android.workspacebridge.RuntimeCleanupResults
import com.floe.android.workspacebridge.RuntimeCleanupScope
import com.floe.android.workspacebridge.RuntimeWorkspaceSession
import com.floe.android.workspacebridge.WorkspaceCopyWiper
import java.io.File
import org.json.JSONObject

/**
 * G03-R3 (job-7e9db10b801940c2): the runtime-UID receiver for the typed
 * `runtimeWorkspaceCopies.clear` control. Service composition (never model
 * reachable: RuntimeWire's closed allowlist is reached ONLY through the
 * peer-verified Binder, and this class re-validates the complete scope).
 *
 * Execution authority is entirely ORIGINAL:
 *  * native lease/owner authority: the environment registry's project
 *    container bound to the exact canonical projectID (and, when present,
 *    the session container bound to the exact canonical conversationID with
 *    that project container in its parent chain); no registry binding means
 *    no deletion ("ownershipUnproven" retention — never a name-match wipe);
 *  * process recovery authority: the supervisor's own bounded recovery
 *    sweep must PROVE whole-UID quiescence first; while any workload is
 *    admitted (target or unrelated) recovery refuses and the cleanup
 *    DEFERS honestly — a running workload A is never cancelled to delete B
 *    (the ORIGINAL recovery only stops stale same-UID descendants when the
 *    service itself admits nothing);
 *  * grant authority: an OPEN runtime-side transfer session for any target
 *    evidence key defers the whole scope (never delete under a live grant);
 *  * deletion itself is the no-follow, atomic-retire, bounded
 *    `WorkspaceCopyWiper` over ONLY the complete proven target-project
 *    scope (workspace copy + sync manifest + attributable recovery
 *    journals), with real directory drain before any cleared ack.
 *
 * Every returned object is the typed result the host pump turns into the
 * Core receipt. Uncertainty is always an honest `refused` (the obligation
 * RETAINS and retries idempotently); this class never fabricates cleared.
 */
internal class RuntimeWorkspaceCleanup(
    context: Context,
    private val authority: LinuxAuthorityClient,
    private val supervisor: com.floe.android.linuxruntime.supervision.RuntimeWorkSupervisor,
    private val busy: () -> Boolean,
) {
    private val app = context.applicationContext
    private val root = app.filesDir.canonicalFile

    fun execute(request: RuntimeWire.Request): JSONObject {
        val scope = RuntimeCleanupScope.parse(request.payload)
            ?: return RuntimeCleanupResults.refused(null, "scopeInvalid")
        // 1) Deferral first: any admitted workload (target OR unrelated)
        // keeps the deletion parked; this call never cancels anything.
        if (busy() || supervisor.activeJob() != null) {
            return RuntimeCleanupResults.refused(scope, "ownedWorkActive")
        }
        // 2) Process-recovery authority proves whole-runtime-UID quiescence
        // (stale same-UID descendants are stopped by the ORIGINAL recovery,
        // never a parallel system) before any unlink. Refused/Unknown here
        // is an honest retention, never a partial-scan success.
        val recovery = runCatching { supervisor.recoverBeforeAdmission("workspace-copy-cleanup") }.getOrNull()
        if (recovery !is RecoveryOutcome.Swept || recovery.quiescence !is Quiescence.Proven) {
            return RuntimeCleanupResults.refused(scope, "uidNotQuiescent")
        }
        // 3) Real wipe of the COMPLETE proven target-project scope. The
        // busy re-probe inside covers the (impossible-by-serialization on
        // this control thread) race window defensively.
        val wiper = WorkspaceCopyWiper(
            workspacesRoot = File(root, "Workspaces"),
            ownership = { candidate -> provesTargetOwnership(candidate) },
            activeWork = { busy() || supervisor.activeJob() != null },
            liveSession = { key -> RuntimeWorkspaceSession.isLiveSessionKey(key) },
            directoryDrain = ::drainDirectory,
            executorUid = Process.myUid(),
        )
        return when (val outcome = wiper.run(scope)) {
            is WorkspaceCopyWiper.Outcome.Cleared -> RuntimeCleanupResults.cleared(
                scope, Process.myUid(), outcome.pathsRemoved, outcome.bytesFreed, outcome.proofDigest)
            is WorkspaceCopyWiper.Outcome.Retained -> RuntimeCleanupResults.refused(scope, outcome.reason)
        }
    }

    /**
     * Native lease/registry proof: a `project` container whose ownerID is
     * the EXACT canonical projectID string. When a `session` container for
     * the exact conversationID exists, its parent chain (bounded) MUST
     * reach that project container; an active-state container defers.
     * Never any path/prefix guessing and never the "first project".
     */
    private fun provesTargetOwnership(scope: RuntimeCleanupScope): Boolean = runCatching {
        val listing = authority.list()
        val environments = listing.optJSONArray("environments") ?: return false
        val project = environmentNodes(environments)
            .firstOrNull { it.kind == "project" && it.owner == scope.projectID } ?: return false
        if (project.state == "active") return false
        val sessions = environmentNodes(environments)
            .filter { it.kind == "session" && it.owner == scope.conversationID }
        if (sessions.any { it.state == "active" }) return false
        // When session records exist, every one of them must chain to the
        // SAME project container; a session bound elsewhere contradicts the
        // claimed (conversation, project) pairing.
        if (sessions.isNotEmpty()) {
            for (session in sessions) {
                var cursor = session.parent
                var hops = 0
                var bound = false
                while (cursor != null && hops < 4) {
                    if (cursor == project.id) { bound = true; break }
                    cursor = environmentNodes(environments).firstOrNull { it.id == cursor }?.parent
                    hops += 1
                }
                if (!bound) return false
            }
        }
        true
    }.getOrDefault(false)

    private data class Node(val id: String, val kind: String, val owner: String, val parent: String?, val state: String)

    private fun environmentNodes(environments: org.json.JSONArray): List<Node> {
        val nodes = ArrayList<Node>(environments.length())
        for (index in 0 until environments.length()) {
            val record = environments.optJSONObject(index) ?: continue
            nodes.add(Node(
                id = record.optString("id"),
                kind = record.optString("kind"),
                owner = record.optString("ownerID"),
                parent = record.optString("parentID").takeIf { it.isNotEmpty() },
                state = record.optString("state"),
            ))
        }
        return nodes
    }

    /** True I/O drain: fsync the Workspaces directory so a cleared ack is
     *  never issued before the removals are committed to the filesystem. */
    private fun drainDirectory(directory: File): Boolean = runCatching {
        // ACTUAL SDK37 OsConstants carries no O_DIRECTORY (compile-proven).
        // The genuine no-follow DIRECTORY-fd drain instead: open the exact
        // path with API-28-safe O_RDONLY|O_NOFOLLOW|O_CLOEXEC (a symlinked
        // path fails with ELOOP), prove directory identity from the fd
        // ITSELF via fstat + S_ISDIR BEFORE any fsync, and only then drain.
        // A non-directory or unproven fd never returns true: no dropped
        // directory check, no success fallback, no guessed flags, no new
        // native ABI.
        val fd = Os.open(directory.absolutePath,
            OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC, 0)
        try {
            val provenDirectory = OsConstants.S_ISDIR(Os.fstat(fd).st_mode)
            if (provenDirectory) Os.fsync(fd)
            provenDirectory
        } finally {
            runCatching { Os.close(fd) }
        }
    }.getOrDefault(false)
}
