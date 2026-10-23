// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import android.content.Context
import android.os.IBinder
import com.floe.android.linuxruntime.supervision.ProcCensus
import com.floe.android.linuxruntime.supervision.RuntimeWorkSupervisor
import com.floe.android.workspacebridge.RuntimeWorkspaceSession
import com.floe.android.workspacebridge.WorkspaceCancelSignal
import com.floe.android.workspacebridge.WorkspaceExportOutcome
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.atomic.AtomicReference

/**
 * ONE real generation identity per runtime PROCESS instance. The kernel
 * reports it through `status`; the preflight echoes it in its result. Both
 * read the same value because both run in the same RuntimeApplication
 * process. It is a measured identity only: authentication stays entirely
 * with `RuntimePeerVerifier` / `RuntimeForegroundPermit`; a restart yields
 * a different nonce, so the trusted host can fence silent generation swaps
 * instead of re-anchoring an epoch onto a different peer.
 */
internal object RuntimeProcessIdentity {
    val pid: Int get() = android.os.Process.myPid()
    val bootToken: String = ByteArray(16)
        .also { java.security.SecureRandom().nextBytes(it) }
        .joinToString("") { "%02x".format(it) }
}

/**
 * G03-R3 FIRST-USE WORKSPACE PREFLIGHT — the runtime-side executor of the
 * frozen NON-EXECUTING round trip (FROZEN_HOST_CONTRACT.firstUsePreflight +
 * Main's host operation amendment).
 *
 * It reuses ONLY the ORIGINAL authorities:
 *  * `LinuxAuthorityClient.acquire` — the original environment registry
 *    resolver (session → project → shared → base with the explicit write
 *    layer) for the REAL project/run/(conversation/environment) identities;
 *  * `RuntimeWorkspaceSession` — the original grant-bound import/export
 *    pipeline (journal-staged atomic swap, faithful PFD mirroring, budgets
 *    and free-disk reserve enforced by the engine);
 *  * `RuntimeWorkSupervisor.recoverBeforeAdmission` + `ProcCensus.snapshot`
 *    — real whole-runtime-UID reaping/quiescence: the no-children proofs.
 *
 * What it NEVER does: no `PRootLaunchSpec`, no `supervisor.start`, no
 * command/cwd/env/stdin field is accepted (the closed payload field set
 * makes a command structurally impossible), no process is ever spawned,
 * and no network is touched — offline/denied-LAN states cannot block a
 * local preflight. A non-empty baseline whose guest mirror stages NOTHING,
 * or whose imported baseline entries are missing/changed in the guest tree,
 * is refused as a deletion plan BEFORE any Core commit (the ORIGINAL
 * session pipeline's precommit faithful-mirror guard); the applied-plan
 * check is retained as the second layer for real deletions and staged
 * refusals. A COMPLETE faithful re-mirror that commits zero changes (the
 * workspace already in sync — unchanged entries are planned with no
 * effect by the ORIGINAL engine) is honest and settles ready (G03-R3
 * cold-start repair; see mirrorHonestyViolation).
 *
 * Lease evidence: the ORIGINAL lease is acquired exclusively (the kernel's
 * single-workload admission already fences shells/installs) and released
 * through `abandonUnstarted` — the authority's own never-started path —
 * with census proofs before and after. The returned `leaseProofDigest` is
 * SHA-256 over a CANONICAL encoding of the actual acquire/release/no-children
 * events (never a hash of "true").
 */
internal class PreflightHarness(
    val context: Context,
    val authority: LinuxAuthorityClient,
    val supervisor: RuntimeWorkSupervisor,
    val census: ProcCensus,
    /** recover() + configure(): reaps strays under a proven quiescence gate
     *  and re-verifies the PUBLISHED rootfs revision against the original
     *  installer manifest before the authority is configured. */
    val ensureConfigured: () -> Unit,
    val ownedPath: (String) -> File,
    val heldLease: AtomicReference<LinuxAuthorityClient.Lease?>,
    val installID: AtomicReference<String?>,
)

internal object RuntimeWorkspacePreflight {

    /** The CLOSED control field set. Any command-like key fails here, by
     *  construction, before any file work. */
    internal val ALLOWED_FIELDS = setOf("projectID", "runID", "conversationID", "environmentID")

    /** Test seams (same-module internal only; not a runtime toggle): the
     *  guard decisions are pinned directly by the authored regressions. */
    internal val ALLOWED_FIELDS_FOR_TEST: Set<String> get() = ALLOWED_FIELDS
    internal fun exportCodeForTest(outcome: WorkspaceExportOutcome): String = exportCode(outcome)

    fun execute(harness: PreflightHarness, payload: JSONObject, grant: IBinder,
                cancelled: () -> Boolean): JSONObject {
        require(payload.keys().asSequence().all { it in ALLOWED_FIELDS }) { "preflightFieldsInvalid" }
        // Core identities travel as ORIGINAL bytes (Swift UUID.uuidString and
        // the CoreWorkspaceGrant echoes are UPPER-CASE canonical); only the
        // grammar is validated here, never a case transform.
        val projectID = canonicalUUID(payload.getString("projectID"))
        val runID = canonicalUUID(payload.getString("runID"))
        val conversationID = canonicalUUID(payload.getString("conversationID"))
        val environmentID = payload.optString("environmentID").takeIf { it.isNotEmpty() }
        check(harness.heldLease.get() == null && harness.installID.get() == null) { "preflightBusy" }
        // Root quiescence proof BEFORE any data work: reap stale strays,
        // require a clean same-UID census, then verify+configure the
        // published rootfs through the ORIGINAL paths.
        harness.ensureConfigured()
        if (!quiescent(harness)) return aborted("quiescence_unproven")
        val lease = harness.authority.acquire(
            JSONObject().put("projectID", projectID).put("runID", runID)
                .put("conversationID", conversationID)
                .also { if (environmentID != null) it.put("environmentID", environmentID) })
        harness.heldLease.set(lease)
        var session: RuntimeWorkspaceSession? = null
        var completed = false
        try {
            val descriptor = lease.descriptor
            // The original resolver owns workspace selection; this only maps
            // its absolute authority path into this runtime's storage.
            val workspace = harness.ownedPath(descriptor.getString("workspaceRoot"))
            check(descriptor.optString("runID") == runID || !descriptor.has("runID")) { "leaseRunMismatch" }
            session = RuntimeWorkspaceSession(harness.context, grant, projectID, runID, workspace)
            val imported = session.importBeforeLaunch(WorkspaceCancelSignal { cancelled() })
            check(imported.skippedCount == 0) { "mirrorUnsupportedEntries" }
            val mirrored = (imported.createdCount + imported.replacedSyncedCount +
                imported.preservedUnsyncedCount + imported.unchangedCount).toLong()
            // Still no children immediately before export (nothing was ever
            // spawned by this path; this proves it, it does not assume it).
            if (!quiescent(harness)) {
                return aborted("quiescence_lost")
            }
            // ORIGINAL session pipeline with the precommit faithful-mirror
            // guard: a baseline entry that is NOT faithfully represented in
            // the guest is refused BEFORE any Core commit (EXPORT_BEGIN /
            // EXPORT_FINISH never reach the engine), not merely after the
            // applied plan. The post-commit honesty check below stays as the
            // second layer for staged refusals / applied deletions.
            val outcome = session.exportAfterQuiescence(WorkspaceCancelSignal { cancelled() }, faithfulMirror = true)
            if (cancelled()) return aborted("cancelled")
            val synced = outcome as? WorkspaceExportOutcome.Synced
                ?: return aborted(exportCode(outcome))
            // Faithful-mirror honesty: deletions or staged refusals mean the
            // export was NOT a faithful mirror of the imported baseline.
            mirrorHonestyViolation(mirrored, synced.created, synced.replaced, synced.directories,
                synced.deleted, synced.links, synced.stagedRefusals)?.let { return aborted(it) }
            // Real release of the ORIGINAL lease through the never-started
            // authority path; the authority itself proves/refuses it.
            // Real release of the ORIGINAL never-started lease BEFORE the
            // proof is reported: acquire -> mirror -> export -> abandon with
            // post-release census. An unprovable release KEEPS the lease
            // (authority-owned), never a fabricated clearance.
            harness.authority.abandonUnstarted(lease)
            val released = harness.heldLease.compareAndSet(lease, null)
            val post = harness.census.snapshot()
            if (!released) return aborted("lease_retained")
            if (!post.isCleanlyQuiescent) return aborted("quiescence_lost")
            val evidence = canonicalEvidence(lease.id, lease.environmentID, projectID, runID,
                mirrored, synced.created, synced.replaced, synced.directories, synced.links,
                post.scannedCount)
            val digest = sha256Hex(evidence)
            session.close()
            completed = true
            return JSONObject().put("status", "ready")
                .put("environmentID", lease.environmentID)
                .put("mirroredEntries", mirrored)
                .put("exportedCreated", synced.created)
                .put("exportedReplaced", synced.replaced)
                .put("exportedDirectories", synced.directories)
                .put("exportedLinks", synced.links)
                .put("enginePlanDigest", synced.planDigest)
                .put("leaseProofDigest", digest)
                // Process-generation identity echo, measured HERE, so the
                // host can bind the mapping/lease facts to the SAME live
                // peer that the preflight actually ran on.
                .put("runtimePid", RuntimeProcessIdentity.pid)
                .put("runtimeBootToken", RuntimeProcessIdentity.bootToken)
        } catch (failure: Exception) {
            val code = failure.message?.takeIf { it.length in 1..32 && it.all { c -> c.code in 0x21..0x7e } }
                ?: if (cancelled()) "cancelled" else "preflight_failed"
            return aborted(code)
        } finally {
            // Every non-ready exit (aborted return, cancellation or
            // exception) attempts the REAL no-children release. Never
            // fabricate: a failed/uncertain abandon keeps the lease held
            // (authority-owned, next-recovery-swept); staged bytes stay
            // recoverable in the Core-side journal until the original sweep
            // proves them stale. EOF/cancel is never treated as exit.
            if (!completed) {
                runCatching { harness.authority.abandonUnstarted(lease) }
                    .onSuccess { harness.heldLease.compareAndSet(lease, null) }
                runCatching { session?.close() }
            }
        }
    }

    /** True only from a fresh live census: fully readable inventory, zero
     *  own-UID live processes, zero ambiguous candidates. */
    private fun quiescent(harness: PreflightHarness): Boolean {
        val snapshot = harness.census.snapshot()
        return snapshot.isCleanlyQuiescent
    }

    /** Faithful-mirror decision, pure and testable: returns the refusal
     *  code when the APPLIED export plan actually damaged the mirror: a
     *  real DELETION against the imported baseline, or a staged entry the
     *  engine refused to commit.
     *
     *  G03-R3 cold-start repair (candidate09 device deadlock,
     *  COLD_READINESS_DISCOVERY_FAILURE_09.json): the previous
     *  `mirror_empty` branch treated a legitimate NO-CHANGE re-mirror as
     *  dishonest. The ORIGINAL engine dedupes per path — an unchanged
     *  file/directory/link is planned with NO effect
     *  (WorkspaceCommitPlanner: "Unchanged everywhere: nothing to write"),
     *  so EVERY first-use preflight of an existing conversation whose
     *  workspace is already in sync applied exactly zero entries on a
     *  COMPLETE, faithful, zero-conflict commit. That reply was aborted as
     *  mirror_empty, the pump invalidated the whole generation's facts on
     *  it, and the next attempt produced the identical zero-delta —
     *  exec.shell stayed honestly un-advertised forever (UI Retry re-runs
     *  the same round trip; no Linux command can ever change the workspace
     *  it cannot run). Cold-existing AND new-task turns after the first
     *  in-sync run share this deadlock; it, not the schema loading, is why
     *  real tools.search answers "No matching executable tool".
     *  The forbidden case this branch tried to catch — a non-empty
     *  baseline whose guest mirror silently staged NOTHING — is already
     *  refused BEFORE any Core commit by the precommit faithful-mirror
     *  guard (RuntimeWorkspaceSession.faithfulMirrorViolation: missing
     *  entries -> deletion_plan, including the empty mirror of a non-empty
     *  baseline; changed representation -> mirror_unfaithful), by the
     *  budget-complete walk (a truncating walk returns budgetExceeded
     *  before EXPORT_BEGIN) and by skippedCount==0 enforced in the
     *  executor. With all of those passed, a Synced outcome carrying zero
     *  applied entries and zero deletions/refusals has exactly one sound
     *  reading: baseline == guest == Core current, an honest zero-delta
     *  sync. NOTHING is hardened here: the real grant, real whole-UID
     *  quiescence proofs, real commit settlement, real abandonUnstarted
     *  lease release and the real index-read-back digest are all still
     *  required for the ready reply. The `mirror_empty` token stays in the
     *  closed diagnostic vocabulary for historical records; no producer in
     *  this lane can still emit it. */
    internal fun mirrorHonestyViolation(mirrored: Long, created: Long, replaced: Long,
                                        directories: Long, deleted: Long, links: Long,
                                        stagedRefusals: Int): String? = when {
        deleted > 0 -> "deletion_plan"
        stagedRefusals > 0 -> "mirror_refused"
        else -> null
    }

    private fun exportCode(outcome: WorkspaceExportOutcome): String = when (outcome) {
        is WorkspaceExportOutcome.Synced -> "unexpected"
        is WorkspaceExportOutcome.Conflict -> if (outcome.status == "aborted") "cancelled" else "mapping_conflict"
        is WorkspaceExportOutcome.RecoverableFailure -> outcome.code.take(32)
    }

    /** Fixed key order, bounded tokens only — the digest is over the REAL
     *  event record, so any replay with different ids/digests differs. */
    internal fun canonicalEvidence(leaseID: String, environmentID: String, projectID: String,
                                   runID: String, mirrored: Long, created: Long, replaced: Long,
                                   directories: Long, links: Long, censusScanned: Int): String =
        "{" + listOf(
            "\"acquire\":\"original-authority\"",
            "\"release\":\"abandonUnstarted\"",
            "\"quiescence\":\"proven-no-children\"",
            "\"leaseID\":\"$leaseID\"",
            "\"environmentID\":\"$environmentID\"",
            "\"projectID\":\"$projectID\"",
            "\"runID\":\"$runID\"",
            "\"mirrored\":$mirrored",
            "\"created\":$created",
            "\"replaced\":$replaced",
            "\"directories\":$directories",
            "\"links\":$links",
            "\"censusScanned\":$censusScanned",
        ).joinToString(",") + "}"

    internal fun sha256Hex(text: String): String =
        MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }

    /**
     * Swift `UUID.uuidString` (and every ORIGINAL grant/Core identity echo)
     * canonicalises as UPPER-CASE 8-4-4-4-12 hex; Java's own lowercase
     * control request IDs are a separate wire grammar (RuntimeWire validates
     * them). Validate the ACTUAL uppercase canonical form here and return
     * the ORIGINAL bytes unchanged — never a case transform, never a relaxed
     * grant equality. All-digit fixtures pass both grammars and therefore
     * miss this bug; meaningful fixtures must contain A-F.
     */
    internal fun canonicalUUID(text: String): String {
        val parsed = UUID.fromString(text)
        require(parsed.toString().uppercase() == text) { "identityNotCanonical" }
        return text
    }

    private fun aborted(reason: String): JSONObject =
        JSONObject().put("status", "aborted").put("reason", reason.take(32))
}
