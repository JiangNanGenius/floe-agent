// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.bridge.WorkspaceSourceNative
import com.floe.android.core.officeengine.OfficeRequestPolicy
import com.floe.android.core.officeengine.OfficeSaveOriginalHandoffPolicy
import com.floe.android.host.officereview.OfficeConflictArtifacts
import java.io.File
import java.nio.file.Files

/**
 * Exact facts the App-side original save needs from the ONE live owned
 * operation. Answered ONLY from the controller's lock for the exact
 * session/generation/owner; every field is an observed fact, never a claim.
 */
internal data class OfficeOriginalCommitFacts(
    val taskID: String,
    val workspaceID: String,
    val nativeEpoch: Long,
    val hostGeneration: Long,
    val logicalPath: String,
    val sourceID: String?,
    /** The opaque workspace CAS revision observed at open (never fabricated). */
    val sourceRevision: String?,
    /** The CURRENT authoritative baseline the CAS expects the original to
     *  carry (the open-time snapshot digest until a real commit updates it). */
    val expectedOriginalSHA256: String,
    /** Canonical path of the App-owned working copy (the verified source). */
    val sourcePath: String,
)

/** Honest terminal of ONE local workspace original commit. */
internal sealed class OfficeOriginalCommitOutcome {
    /** The workspace original now carries the verified replacement bytes. */
    data class Committed(val sha256: String, val bytes: Long) : OfficeOriginalCommitOutcome()

    /** Proven pre-write refusal: the original's actual bytes differ (a real
     *  conflict), the lease/ownership was refused, or the generation
     *  retired. The original is byte-intact per actual readback. */
    data class Conflict(val detail: String?) : OfficeOriginalCommitOutcome()

    /** Cancellation was honored with the original intact per readback. */
    data class Cancelled(val detail: String?) : OfficeOriginalCommitOutcome()

    /** The outcome could not be proven (post-commit IO/receipt error with
     *  the original neither matching the baseline nor the replacement, an
     *  unreadable readback, or an internal failure). Everything is retained;
     *  nothing is retried. */
    data class Unknown(val detail: String?) : OfficeOriginalCommitOutcome()
}

/**
 * The local workspace-CAS authority for the manual original save. The ONLY
 * production implementation is the trusted source-host native lane (the
 * same `G04WorkspaceComposition.liveAccess` -> owned write lease ->
 * `WorkspaceFileService.replaceBinaryFile` CAS the Core model path uses);
 * fakes drive the same production host in the JVM regressions. Never a raw
 * path overwrite, never a new installer/tool alias.
 */
internal interface OfficeOriginalCommitPort {
    fun commit(
        facts: OfficeOriginalCommitFacts,
        source: OfficeSaveOriginalVerifiedCopy,
        sourcePath: String,
    ): OfficeOriginalCommitOutcome
}

/** Production port: one bounded blocking native hop (the caller thread is
 *  the module's dedicated handoff thread; the Swift hop blocks it on a
 *  semaphore, exactly like the reviewed source-host ladder hops). */
internal object NativeOfficeOriginalCommitPort : OfficeOriginalCommitPort {
    private const val REPLY_BYTES = 4096

    override fun commit(
        facts: OfficeOriginalCommitFacts,
        source: OfficeSaveOriginalVerifiedCopy,
        sourcePath: String,
    ): OfficeOriginalCommitOutcome {
        val reply = ByteArray(REPLY_BYTES)
        val written = try {
            WorkspaceSourceNative.saveOriginal(
                epoch = facts.nativeEpoch,
                taskID = facts.taskID,
                workspaceID = facts.workspaceID,
                logicalPath = facts.logicalPath,
                expectedOriginalSHA256 = facts.expectedOriginalSHA256,
                expectedSourceSHA256 = source.sha256,
                expectedSourceBytes = source.bytes,
                sourcePath = sourcePath,
                reply = reply,
            )
        } catch (linkage: LinkageError) {
            // An older installed Core lacks the symbol: honest unknown, never
            // a pretend commit (same doctrine as the media-egress lane).
            return OfficeOriginalCommitOutcome.Unknown("nativeLaneUnavailable")
        } catch (error: Exception) {
            return OfficeOriginalCommitOutcome.Unknown(error.javaClass.simpleName.take(64))
        }
        if (written < 0) {
            return when (written) {
                // Identity/generation/lease refusals are proven pre-write
                // facts, shaped by the native authority itself. A honoured
                // cancellation rides the reply body ("local":"cancelled"),
                // not a typed negative status.
                WorkspaceSourceNativeStatus.identityRefused,
                WorkspaceSourceNativeStatus.generationFenced,
                WorkspaceSourceNativeStatus.notInstalled,
                -> OfficeOriginalCommitOutcome.Conflict("nativeRefused:$written")
                else -> OfficeOriginalCommitOutcome.Unknown("nativeStatus:$written")
            }
        }
        return parseReply(reply, written)
    }

    private fun parseReply(reply: ByteArray, written: Int): OfficeOriginalCommitOutcome {
        val body = runCatching { String(reply, 0, written, Charsets.UTF_8) }.getOrNull()
            ?: return OfficeOriginalCommitOutcome.Unknown("replyUnreadable")
        val local = readJsonString(body, "local") ?: return OfficeOriginalCommitOutcome.Unknown("replyMalformed")
        val detail = readJsonString(body, "detail")
        return when (local) {
            "committed" -> {
                val sha = readJsonString(body, "committedSHA256")
                    ?.takeIf { it.matches(Regex("^[0-9a-f]{64}$")) }
                    ?: return OfficeOriginalCommitOutcome.Unknown("replyMalformed")
                val bytes = readJsonLong(body, "committedBytes") ?: 0L
                if (bytes < 1L) return OfficeOriginalCommitOutcome.Unknown("replyMalformed")
                OfficeOriginalCommitOutcome.Committed(sha, bytes)
            }
            "conflict", "refused" -> OfficeOriginalCommitOutcome.Conflict(detail)
            "cancelled" -> OfficeOriginalCommitOutcome.Cancelled(detail)
            else -> OfficeOriginalCommitOutcome.Unknown(detail)
        }
    }

    private fun readJsonString(body: String, key: String): String? {
        val token = "\"$key\":\""
        val start = body.indexOf(token)
        if (start < 0) return null
        val from = start + token.length
        val end = body.indexOf('"', from)
        if (end < 0) return null
        return body.substring(from, end)
    }

    private fun readJsonLong(body: String, key: String): Long? {
        val token = "\"$key\":"
        val start = body.indexOf(token)
        if (start < 0) return null
        var end = start + token.length
        while (end < body.length && body[end] != ',' && body[end] != '}') end++
        return body.substring(start + token.length, end).trim().toLongOrNull()
    }
}

/** Typed negative status mirror for the source-host native lane (the subset
 *  the original-save hop can return before its reply body exists; the full
 *  space lives in [WorkspaceSourceNative]'s documentation). */
private object WorkspaceSourceNativeStatus {
    const val notInstalled = -501
    const val generationFenced = -502
    const val identityRefused = -505
}

/**
 * One verified working copy measured by the App itself (never a module
 * claim): the canonical App-owned file, its independent digest and size.
 */
internal data class OfficeSaveOriginalVerifiedCopy(
    val sha256: String,
    val bytes: Long,
)

/**
 * Controller-supplied facts for the ONE live owned operation, plus the
 * owner-fenced callbacks. [markCommitted] updates the durable baseline ONLY
 * after a proven commit (with the committed bytes); [stillOwned] re-proves
 * the exact operation immediately before any positive answer; a null
 * [pushOriginal] means this document carries no provider binding.
 */
internal data class OfficeSaveOriginalOperation(
    val baselineSha256: String,
    val baselineBytes: Long,
    val commit: OfficeOriginalCommitFacts,
    val stillOwned: () -> Boolean,
    val markCommitted: (sha256: String, bytes: Long) -> Unit,
    /** Releases the controller's in-flight fence; invoked exactly once by
     *  [OfficeSaveOriginalHost.accept] on EVERY path after the facts were
     *  acquired, so a duplicate notice can never clear another handoff's
     *  mark and a second handoff can never interleave with this one. */
    val releaseInFlight: () -> Unit,
    /**
     * ONE provider journal push over the EXISTING journaled headless ladder
     * (the same `savePathToProvider` call the Core model path makes). The
     * host invokes it AT MOST ONCE per explicit save action, on the handoff
     * lane itself, and correlates its typed terminal into the final verdict —
     * never fire-and-forget, never a retry. A throwing or null-answer push
     * is an unknown provider outcome, never evidence the external original
     * was updated.
     */
    val pushOriginal: (suspend () -> WorkspaceSourceResult?)?,
)

/**
 * How the provider leg of ONE explicit save action concluded, derived purely
 * from the EXISTING journaled ladder's typed terminal. The ladder's durable
 * rows already carry the recovery identity; this correlation only decides
 * what the App may honestly claim about THIS action.
 */
internal enum class OfficeOriginalProviderSync {
    /** The ladder proved the provider now carries the bytes ("ok"). */
    SYNCED,

    /** The sync is honestly pending / unavailable / refused / unknown
     *  (providerOffline with a pending journal row, revoked, readOnly,
     *  rePickRequired, runtimeUnavailable, unbound, cancelled, ioFailed,
     *  failed, a missing lane, a throwing push, ...). Nothing here claims
     *  the external original changed. */
    PENDING,

    /** The provider side carries a conflicting version (conflict /
     *  driftAtClaim / sourceChangedSinceImport) — a human reconciles it
     *  through the existing journal UI. */
    CONFLICT,
}

/**
 * Maps ONE ladder result to [OfficeOriginalProviderSync]. Only the ladder's
 * own "ok" terminal proves the provider leg; everything else is honest
 * incomplete (PENDING) or a provider-side conflict (CONFLICT). Pure and
 * JVM-testable.
 */
internal fun officeOriginalProviderSync(result: WorkspaceSourceResult?): OfficeOriginalProviderSync =
    when (result?.status) {
        "ok" -> OfficeOriginalProviderSync.SYNCED
        "conflict", "sourceChangedSinceImport" -> OfficeOriginalProviderSync.CONFLICT
        else -> OfficeOriginalProviderSync.PENDING
    }

/**
 * App-side orchestration of ONE manual workspace original save
 * (OFC-SAVE-REOPEN). Framework-free and JVM-testable: every IO surface is an
 * injected port/closure, so the regressions drive the REAL decision chain.
 *
 * Order of truth (nothing is "saved" before the last positive step):
 *  1. The controller resolves the EXACT owned operation for the notice's
 *     session/generation under its lock (owner, epoch, VIEWING, engine
 *     generation) and marks the handoff in flight.
 *  2. The App independently re-reads and re-digests its OWN working copy and
 *     requires it to equal the notice's claimed facts byte-for-byte; the
 *     bounded OOXML structure check runs on the same bytes.
 *  3. Byte-identical with the authoritative baseline -> an honest UNCHANGED
 *     (nothing to commit; the provider leg still correlates once below when
 *     a source is attached). Otherwise the REAL native CAS runs: the
 *     original must still carry the baseline digest, else a proven conflict.
 *  4. A proven commit MUST name the exact verified working-copy bytes
 *     (digest and size). The production native contract guarantees the
 *     exact source, so a mismatched receipt proves nothing about this save:
 *     it is an invalid/unknown answer, never a successful requested save.
 *  5. A proven commit updates the durable baseline (repeat saves can never
 *     fight stale open-time metadata) and only then may the answer be
 *     positive. When a provider binding exists, the EXISTING journaled
 *     ladder runs ONCE, awaited on this handoff lane under the SAME owner
 *     fence, and its typed terminal correlates the verdict:
 *     synced -> ACCEPTED / UNCHANGED; pending/unavailable/unknown ->
 *     ACCEPTED_SOURCE_PENDING / UNCHANGED_SOURCE_PENDING; provider conflict
 *     -> ACCEPTED_SOURCE_CONFLICT / UNCHANGED_SOURCE_CONFLICT. A
 *     local-saved/source-pending answer is NEVER a blanket "saved": the
 *     module keeps the editor open and surfaces the actionable notice.
 *  6. Conflict/cancel/unknown answer REJECTED: the original stays untouched
 *     (the native readback decides — never "throw means untouched"), the
 *     working copy and every recovery artifact are retained, and nothing is
 *     retried silently.
 */
internal class OfficeSaveOriginalHost(
    private val commitPort: OfficeOriginalCommitPort,
    private val operation: (sessionToken: String, generation: Long) -> OfficeSaveOriginalOperation?,
    private val verifyWorkingCopy: (file: File, notice: OfficeSaveOriginalHandoffPolicy.SaveOriginalNotice) -> OfficeSaveOriginalVerifiedCopy?,
    private val workingCopyFile: (path: String) -> File,
) {

    /**
     * Runs on the module's dedicated handoff thread; the native CAS hop and
     * (when attached) the bounded journaled provider push both run on this
     * lane so the single returned verdict correlates the WHOLE action. One
     * of the [OfficeSaveOriginalHandoffPolicy] verdicts — never an exception.
     */
    suspend fun accept(notice: OfficeSaveOriginalHandoffPolicy.SaveOriginalNotice): Int {
        val op = operation(notice.sessionToken, notice.generation)
            ?: return OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_REFUSED
        try {
            val working = verifyWorkingCopy(workingCopyFile(op.commit.sourcePath), notice)
                ?: return OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_REJECTED
            if (working.sha256 == op.baselineSha256 && working.bytes == op.baselineBytes) {
                // Nothing to commit: the verified working copy still equals
                // the authoritative original. Re-prove ownership, then (when
                // a source is attached) correlate the provider leg ONCE for
                // this explicit save — the editor must never close as if
                // fully synced while the external original is unproven.
                if (!op.stillOwned()) {
                    return OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_REFUSED
                }
                return when (val sync = pushSync(op)) {
                    null -> OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_UNCHANGED
                    OfficeOriginalProviderSync.SYNCED ->
                        OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_UNCHANGED
                    OfficeOriginalProviderSync.PENDING ->
                        OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_UNCHANGED_SOURCE_PENDING
                    OfficeOriginalProviderSync.CONFLICT ->
                        OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_UNCHANGED_SOURCE_CONFLICT
                }
            }
            val workingPath = runCatching { workingCopyFile(op.commit.sourcePath).canonicalPath }.getOrNull()
                ?: return OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_REJECTED
            val outcome = commitPort.commit(op.commit, working, workingPath)
            return when (outcome) {
                is OfficeOriginalCommitOutcome.Committed -> {
                    // The native authority must answer with the EXACT bytes
                    // the App measured and asked to commit. A mismatched
                    // receipt violates the production contract and invents
                    // byte proof — the honest answer is invalid/unknown with
                    // everything retained, never a successful requested save.
                    if (outcome.sha256 != working.sha256 || outcome.bytes != working.bytes) {
                        return OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_REJECTED
                    }
                    op.markCommitted(outcome.sha256, outcome.bytes)
                    if (!op.stillOwned()) {
                        // The commit landed but the mount has gone (close,
                        // switch, replacement): the durable workspace file
                        // is the authority and the next open stages it
                        // fresh; a dead mount is never told "saved".
                        OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_REFUSED
                    } else {
                        // The commit is proven; the durable baseline already
                        // advanced and survives whatever the provider leg
                        // does next. The provider outcome correlates the
                        // verdict: a non-"ok" ladder terminal NEVER looks
                        // wholly saved in the module.
                        when (val sync = pushSync(op)) {
                            null -> OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_ACCEPTED
                            OfficeOriginalProviderSync.SYNCED ->
                                OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_ACCEPTED
                            OfficeOriginalProviderSync.PENDING ->
                                OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_ACCEPTED_SOURCE_PENDING
                            OfficeOriginalProviderSync.CONFLICT ->
                                OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_ACCEPTED_SOURCE_CONFLICT
                        }
                    }
                }
                is OfficeOriginalCommitOutcome.Conflict,
                is OfficeOriginalCommitOutcome.Cancelled,
                is OfficeOriginalCommitOutcome.Unknown,
                -> OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_REJECTED
            }
        } finally {
            op.releaseInFlight()
        }
    }

    /**
     * Runs the attached provider push EXACTLY ONCE on this handoff lane and
     * classifies its typed terminal. Returns null when this document has no
     * provider binding (the local answer alone decides). A throwing or
     * null-answer push is PENDING (unknown) — never evidence the external
     * original updated, and never an exception to the caller.
     */
    private suspend fun pushSync(op: OfficeSaveOriginalOperation): OfficeOriginalProviderSync? {
        val push = op.pushOriginal ?: return null
        return officeOriginalProviderSync(runCatching { push() }.getOrNull())
    }
}

/**
 * Working-copy verification shared by the production controller join and the
 * regressions: the ACTUAL supplied input must be a plain file (never a
 * symlink — the file itself may have been swapped for a link after the
 * controller canonicalized its path), canonical containment under the
 * App-owned working root, a plain regular bounded file at the resolved
 * path, an independent streaming digest that must equal the notice claim,
 * and the SAME bounded OOXML magic/structure verifier the review lane uses.
 * Any mismatch is a refusal to commit, never a silent overwrite of the
 * original.
 */
internal object OfficeSaveOriginalVerification {
    const val MAX_WORKING_COPY_BYTES = OfficeRequestPolicy.MAX_STAGED_BYTES

    fun verify(
        file: File,
        workingRoot: File,
        notice: OfficeSaveOriginalHandoffPolicy.SaveOriginalNotice,
    ): OfficeSaveOriginalVerifiedCopy? {
        // Inspect the real input BEFORE following it: canonicalization
        // resolves every link, so a symlink check on the canonical path can
        // never see a link that the App was actually handed.
        if (Files.isSymbolicLink(file.toPath())) return null
        val canonical = runCatching { file.canonicalFile }.getOrNull() ?: return null
        val root = runCatching { workingRoot.canonicalFile }.getOrNull() ?: return null
        if (canonical.path != root.path && !canonical.path.startsWith(root.path + File.separator)) {
            return null
        }
        if (!canonical.isFile || Files.isSymbolicLink(canonical.toPath())) return null
        if (notice.workingCopyBytes < 1L || notice.workingCopyBytes > MAX_WORKING_COPY_BYTES) return null
        if (canonical.length() != notice.workingCopyBytes) return null
        val digest = OfficeConflictArtifacts.digest(canonical) ?: return null
        if (digest.first != notice.workingCopySha256 || digest.second != notice.workingCopyBytes) return null
        val structure = OfficeRequestPolicy.verifyStagedOutput(canonical, notice.format)
        if (!structure.verified) return null
        return OfficeSaveOriginalVerifiedCopy(digest.first, digest.second)
    }
}
