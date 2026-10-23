// SPDX-License-Identifier: MPL-2.0
package com.floe.android.workspacebridge

/** Client-sanitized view of the grant budgets (defense in depth: a corrupt
 *  or hostile CORE reply can never widen what the runtime will materialize;
 *  anything out of the outer ceiling is a refusal, not a clamp). */
data class WorkspaceBudgetsView(
    val totalBytes: Long,
    val entryCount: Int,
    val frameBytes: Int,
    val maximumEntryBytes: Long,
    val freeDiskReserveBytes: Long,
    val maximumRelativePathBytes: Int,
    val maximumLinkTargetBytes: Int,
) {
    companion object {
        fun sanitize(json: org.json.JSONObject?): WorkspaceBudgetsView? {
            json ?: return null
            // Strict integral parsing: booleans, fractional/truncated
            // numbers and non-finite values are refused (never coerced).
            fun integer(key: String, min: Long, max: Long): Long? {
                if (!json.has(key)) return null
                val raw = try { json.get(key) } catch (_: Exception) { return null }
                if (raw is Boolean || raw !is Number) return null
                val value = raw.toDouble()
                if (!value.isFinite()) return null
                val converted = value.toLong()
                if (converted.toDouble() != value) return null // fractional refused, never truncated
                return if (converted in min..max) converted else null
            }
            val total = integer("totalBytes", 1, 8L shl 30) ?: return null
            val entries = integer("entryCount", 1, 100_000) ?: return null
            val frame = integer("frameBytes", 4_096, 262_144) ?: return null
            val entry = integer("maximumEntryBytes", 1, total) ?: return null
            val reserve = integer("freeDiskReserveBytes", 0, 8L shl 30) ?: return null
            val pathMax = integer("maximumRelativePathBytes", 64, 4_096) ?: return null
            val linkMax = integer("maximumLinkTargetBytes", 64, 4_096) ?: return null
            return WorkspaceBudgetsView(total, entries.toInt(), frame.toInt(), entry, reserve,
                pathMax.toInt(), linkMax.toInt())
        }
    }
}

/** One regular-file copy the ORIGINAL import swap ACTUALLY preserved, with
 *  the digests/byte sizes the engine measured on the real custody moves
 *  (diverged prior bytes now in the owner-marked preserve tree, and the Core
 *  baseline revision that took their place). Paths are workspace-relative;
 *  no absolute path, no content, and nothing is reported for an entry whose
 *  bytes the engine never actually hashed. */
data class WorkspacePreservedCopy(
    val path: String,
    val preservedSha256: String,
    val preservedBytes: Long,
    val installedBaselineSha256: String,
    val installedBaselineBytes: Long,
)

/** What `importBeforeLaunch` actually applied, from the Core baseline.
 *  A repeat import into the STABLE lease directory swaps transactionally:
 *  `replacedSynced` prior copies were already proven synced (their backups
 *  were pruned on acknowledge); `preservedUnsynced` prior bytes remain
 *  recoverable in the owner-marked preserve tree; `independentUntouched`
 *  counts destination entries the snapshot never collided with (never
 *  touched — later exports may legitimately sync it). */
data class WorkspaceImportReceipt(
    val sessionKey: String,
    val createdCount: Int,
    val replacedSyncedCount: Int,
    val preservedUnsyncedCount: Int,
    val unchangedCount: Int,
    val conflictPaths: List<String>,
    val conflictsTruncated: Boolean,
    val appliedBytes: Long,
    /** Core-owned entries deliberately NOT mirrored (external links, FIFOs,
     *  unreadables). Reported honestly; they never appeared in the guest. */
    val skippedCount: Int,
    val budgets: WorkspaceBudgetsView,
    /** EXACT run identity the grant echoed at import (owner binding for the
     *  bounded recovery projection). Defaults to ABSENT so any legacy
     *  constructor keeps compiling and parsing byte-identically; an
     *  absent/empty value is NEVER published as recoverable metadata — the
     *  envelope omits the key and the Core-side pump merge rejects an
     *  unbound projection outright (LinuxShellPump.mergeWorkspaceRecovery
     *  plus its regression prove absence means unavailable, not zero). */
    val runID: String = "",
    /** Up to 16 digest-verified `swappedPreserved` copies (bounded, relative
     *  paths only). Entries the engine could not measure — symlink preserves,
     *  kind mismatches, pre-fact legacy journals — are simply ABSENT; the
     *  full `preservedUnsyncedCount` still reports the total honestly. */
    val preservedCopies: List<WorkspacePreservedCopy> = emptyList(),
    /** True when MORE verified preserved copies existed than the bound shows. */
    val preservedCopiesTruncated: Boolean = false,
)

data class WorkspaceConflictRecord(val path: String, val kind: String, val hasArtifact: Boolean)

/** Honest export verdicts. NOTHING here ever means "assume success":
 *  an uncertain reply is an explicit failure with preserved staging. */
sealed class WorkspaceExportOutcome {
    /** The Core workspace now equals the settled guest output for every
     *  changed entry; zero conflicts, zero failures. */
    data class Synced(
        val sessionKey: String,
        val created: Long,
        val replaced: Long,
        val directories: Long,
        val deleted: Long,
        val links: Long,
        val stagedRefusals: Int,
        val planDigest: String,
    ) : WorkspaceExportOutcome()

    /** Effects settled; some paths conflicted/failed. User bytes stayed,
     *  runtime bytes are recoverable under the session's durable index. */
    data class Conflict(
        val sessionKey: String,
        val status: String, // "conflict" | "aborted"
        val created: Long,
        val replaced: Long,
        val directories: Long,
        val deleted: Long,
        val links: Long,
        val conflicts: List<WorkspaceConflictRecord>,
        val conflictsTruncated: Boolean,
        val failed: Int,
        val stagedRefusals: Int,
        val indexDigest: String,
    ) : WorkspaceExportOutcome()

    /** No usable commit happened (or its result is UNKNOWN). `stagedPreserved`
     *  means Core kept received frames under the session for reconciliation;
     *  the outcome is NOT CLI success and never presented as such. */
    data class RecoverableFailure(val code: String, val stagedPreserved: Boolean, val sessionKey: String?) :
        WorkspaceExportOutcome()
}
