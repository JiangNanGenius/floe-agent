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
 *  * native lease authority: the ORIGINAL `handshake` is the authoritative
 *    live-lease fact (`activeLease`/`leaseAdmissionPending`, FloeLinuxAuthority
 *    `!leases.isEmpty` + the reserved-admission flag). Registry record state
 *    is NOT a liveness signal — a healthy project/session container stays
 *    `active` for its whole durable life (lease release never transitions
 *    records, and the frozen authority exposes no stop/delete), so any
 *    retained or pending native lease — or an absent/malformed handshake —
 *    DEFERS the whole scope fail-closed;
 *  * native owner authority: the environment registry's project container
 *    bound to the exact canonical projectID through the registry's OWN
 *    binding — `EnvironmentExecutionCoordinator.acquire` stores the project
 *    record with `ownerID = sha256Hex(canonical workspace path)` and
 *    `name = <workspace directory name> = projectID.uuidString`, so the
 *    proof accepts the exact canonical name binding (or a UUID-keyed
 *    ownerID), and, when present, the session container bound to the exact
 *    canonical conversationID with that project container in its parent
 *    chain; no registry binding means no deletion ("ownershipUnproven"
 *    retention — never a path/prefix guess, never the first project, never
 *    ownership invented from an empty registry);
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
        // 2.5) ORIGINAL native lease authority: registry record state is not
        // a liveness signal (healthy records stay "active" for their whole
        // durable life), so the authoritative live-lease fact is the frozen
        // handshake. ANY retained/pending native lease defers the scope, and
        // an absent or malformed handshake defers fail-closed — never a
        // process-absence guess and never a metadata-state guess.
        if (!handshakeProvesNoNativeLease()) {
            return RuntimeCleanupResults.refused(scope, "nativeLeaseActive")
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
     * Authoritative live-lease fact from the ORIGINAL handshake
     * (`activeLease` + `leaseAdmissionPending`, LinuxAuthorityHandshakeInfo —
     * the actor's `!leases.isEmpty` plus the reserved-admission flag). Strict:
     * absent, malformed or non-boolean fields fail closed (defer); this is
     * never a process-absence guess and never a metadata-state guess.
     */
    private fun handshakeProvesNoNativeLease(): Boolean = runCatching {
        val handshake = authority.handshake()
        nativeLeaseStateAllowsCleanup(
            handshake.opt("activeLease"), handshake.opt("leaseAdmissionPending"),
        )
    }.getOrDefault(false)

    /**
     * Native registry binding proof over the ACTUAL record shape
     * `EnvironmentExecutionCoordinator.acquire` persists: a `project`
     * container bound to the exact canonical projectID through the
     * registry's OWN binding — `name` is the workspace directory basename
     * (`projectID.uuidString`) and `ownerID` the sha256 workspace-path
     * digest (a UUID-keyed ownerID is accepted as the alternate binding) —
     * in a known durable `active` or `stopped` state; plus, when `session` containers exist for
     * the exact conversationID, every one chains to that SAME project
     * container. A healthy record's `active` state is the NORMAL durable
     * state (lease release never transitions records and the frozen
     * authority exposes no stop/delete), so real liveness is gated before
     * this proof by the handshake lease gate, supervisor quiescence, the
     * busy re-probe and the per-key live transfer sessions. Never a
     * path/prefix guess, never the "first project", never ownership invented
     * from an empty registry.
     */
    private fun provesTargetOwnership(scope: RuntimeCleanupScope): Boolean = runCatching {
        val listing = authority.list()
        val environments = listing.optJSONArray("environments") ?: return false
        proveTargetOwnership(environmentRecords(environments), scope.projectID, scope.conversationID)
    }.getOrDefault(false)

    private fun environmentRecords(environments: org.json.JSONArray): List<EnvironmentRecordView> {
        val records = ArrayList<EnvironmentRecordView>(environments.length())
        for (index in 0 until environments.length()) {
            val record = environments.optJSONObject(index) ?: continue
            records.add(EnvironmentRecordView(
                id = record.optString("id"),
                kind = record.optString("kind"),
                ownerID = record.optString("ownerID"),
                name = record.optString("name"),
                parentID = record.optString("parentID").takeIf { it.isNotEmpty() },
                state = record.optString("state"),
            ))
        }
        return records
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

/** One environment-registry record exactly as the ownership proof consumes
 *  it (plain data: no org.json, no Android). */
internal data class EnvironmentRecordView(
    val id: String,
    val kind: String,
    val ownerID: String,
    val name: String,
    val parentID: String?,
    val state: String,
)

/**
 * PURE decision core of the runtime target-ownership proof (the runtimeapp
 * JVM batch executes without org.json/Android — the same pure-core
 * constraint the existing runtime tests document).
 *
 * Contract (the ACTUAL registry bindings, EnvironmentExecutionCoordinator
 * .acquire + EnvironmentRegistry.ensureProjectContainer/ensureSessionContainer):
 *  * the project container carries `ownerID = sha256Hex(canonical workspace
 *    path)` and `name = <workspace directory basename> = projectID.uuidString`
 *    — the proof binds on the exact canonical name (or a UUID-keyed ownerID
 *    as the alternate binding), never case-folded, never a prefix;
 *  * only the known durable `active` and `stopped` states may prove a
 *    binding; deleting, absent and unknown states refuse. `active` is the normal durable state of a healthy record
 *    (lease release never transitions records), so it is NOT a live-lease
 *    signal — real liveness is gated by the caller (handshake lease gate,
 *    supervisor quiescence, busy re-probe, per-key live transfer sessions);
 *  * when session containers exist for the exact conversationID, EVERY one
 *    must chain (bounded, <= 4 hops) to the SAME project container; a
 *    session bound elsewhere contradicts the claimed (conversation, project)
 *    pairing and refuses;
 *  * an absent project binding — including an empty registry — is
 *    `ownershipUnproven`: ownership is NEVER invented.
 */
internal fun proveTargetOwnership(
    records: List<EnvironmentRecordView>,
    projectID: String,
    conversationID: String,
): Boolean {
    val project = records.filter {
        it.kind == "project" && (
            (it.name == projectID && WORKSPACE_OWNER_DIGEST.matches(it.ownerID)) ||
                it.ownerID == projectID
            )
    }.singleOrNull() ?: return false
    if (project.id.isBlank() || project.state !in SETTLED_REGISTRY_STATES) return false
    val sessions = records.filter { it.kind == "session" && it.ownerID == conversationID }
    if (sessions.any { it.id.isBlank() || it.state !in SETTLED_REGISTRY_STATES }) return false
    if (sessions.isNotEmpty()) {
        for (session in sessions) {
            var cursor = session.parentID
            var hops = 0
            var bound = false
            while (cursor != null && hops < 4) {
                if (cursor == project.id) { bound = true; break }
                cursor = records.firstOrNull { it.id == cursor }?.parentID
                hops += 1
            }
            if (!bound) return false
        }
    }
    return true
}

/** The frozen native handshake must explicitly prove both lease facts idle. */
internal fun nativeLeaseStateAllowsCleanup(activeLease: Any?, pendingAdmission: Any?): Boolean =
    activeLease is Boolean && pendingAdmission is Boolean && !activeLease && !pendingAdmission

private val WORKSPACE_OWNER_DIGEST = Regex("^[0-9a-f]{64}$")
private val SETTLED_REGISTRY_STATES = setOf("active", "stopped")
