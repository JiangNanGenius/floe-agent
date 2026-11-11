// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import com.floe.android.workspacebridge.StagedEntry
import com.floe.android.workspacebridge.WorkspaceBridgeException
import com.floe.android.workspacebridge.WorkspaceCancelSignal
import com.floe.android.workspacebridge.WorkspaceImportReceipt
import org.json.JSONObject
import java.io.File

/**
 * N07 R1 repair — HOT workspace input sync into a LIVE runtime-UID task
 * workspace.
 *
 * WHY this exists: a `skill.read` whose pinned bundle was staged Core-side
 * AFTER the task's shell session opened used to report `visibleInGuest=false`
 * and the live guest session hit ENOENT on the exact returned path — the
 * staged bytes crossed into the guest only at the NEXT `shell.start` import
 * boundary, never while the session stayed alive. This executor is the
 * runtime half of the repair: ONE bounded, NON-EXECUTING round trip that
 * commits the Core workspace's currently-missing entries into the LIVE
 * workspace directory through the EXISTING participant new-inputs import
 * (`RuntimeWorkspaceSession.importNewInputs`): journal-owned staging outside
 * the destination, digest-verified PFD streaming, atomic missing-only
 * publication (pre-existing guest bytes are NEVER renamed, replaced or
 * deleted), and per-entry adoption into the live owner's import baseline so
 * the later export stays honest. No process is spawned, no lease is
 * acquired, no command/cwd/env field exists in the closed payload, and no
 * second shell or GUI is started.
 *
 * Safety contract (enforced here, not by the caller):
 *  * The destination is the LIVE workspace of the exact project: the
 *    operations layer resolves the live owner (or the retained deferred
 *    export) for the payload's projectID; this executor re-proves the
 *    directory is the canonical `Workspaces/<projectID>` child before any
 *    byte moves. A missing/foreign/settled workspace is the honest
 *    `workspaceNotLive` refusal — never a fresh import into a dead tree.
 *  * Identity is proven by the grant, not the payload: the Core-side mint
 *    re-derives the workspace from the ORIGINAL run/conversation rows and
 *    the native epoch; the runtime session echoes projectID/runID and the
 *    engine re-validates ownership on every transaction. The payload's
 *    projectID/runID are grammar-checked canonical UUIDs only.
 *  * The caller (LinuxRuntimeOperations) holds the workspaceGate across the
 *    whole transfer, serializing it against starts and the whole-UID
 *    export/deferred-export paths; an install/first-use preflight owning
 *    the UID is refused (`runtimeBusy`) instead of racing its full swap.
 *  * Cancellation is cooperative and honest: a cancelled transfer keeps
 *    every already-created entry (adopted into the owner baseline by the
 *    original swap) and never touches existing entries; the caller's
 *    drained grant close aborts an in-flight transfer at its next frame
 *    boundary.
 *
 * JVM-testable by construction: every filesystem/Binder effect arrives
 * through the [InputSyncHarness] closures; the decision logic under test is
 * production code (the preflight executor precedent).
 */
internal class InputSyncWorkspace(
    /** The ORIGINAL participant new-inputs import (the caller binds
     *  `RuntimeWorkspaceSession.importNewInputs`); the executor cannot
     *  forget the owner-baseline adoption callback. */
    val importNewInputs: (WorkspaceCancelSignal, InputSyncBaseline) -> WorkspaceImportReceipt,
    val close: () -> Unit,
)

/** The live owner's baseline adoption surface (the ORIGINAL
 *  `RuntimeWorkspaceSession.adoptNewInput` bound reference). */
internal fun interface InputSyncBaseline {
    fun adopt(sourceSessionKey: String, index: Long, entry: StagedEntry)
}

/** The live workspace facts for one exact project, re-read on every call. */
internal class LiveInputSyncWorkspace(
    val workspaceRoot: File,
    val baseline: InputSyncBaseline,
)

internal class InputSyncHarness(
    /** The canonical `Workspaces` root (identity re-proof anchor). */
    val workspacesRoot: File,
    /** The LIVE workspace for the exact project, or null when no owner /
     *  deferred export currently serves it. */
    val liveWorkspace: (projectID: String) -> LiveInputSyncWorkspace?,
    /** Factory for the REAL grant-bound transfer session (or a test
     *  double). It receives the executor's already-canonical identities and
     *  the re-proved workspace directory. */
    val openWorkspace: (projectID: String, runID: String, workspace: File) -> InputSyncWorkspace,
    /** Install/first-use preflight exclusivity (the UID is not ours to
     *  write into while an exclusive lane owns it). */
    val exclusiveWork: () -> Boolean,
)

internal object RuntimeWorkspaceInputSync {

    /** The CLOSED control field set. Any command-like key fails here, by
     *  construction, before any file work. */
    internal val ALLOWED_FIELDS = setOf("projectID", "runID")

    /** The closed refusal vocabulary (bounded tokens; never paths, payloads
     *  or free text). */
    internal const val REFUSED_NOT_LIVE = "workspaceNotLive"
    internal const val REFUSED_BUSY = "runtimeBusy"
    internal const val REFUSED_IDENTITY = "workspaceIdentityChanged"
    internal const val REFUSED_INPUTS = "newWorkspaceInputsUnavailable"
    internal const val REFUSED_TRANSFER = "workspaceTransferFailed"

    /** The bounded bridge-failure codes mapped verbatim (the reviewed
     *  kernel vocabulary); anything else collapses to REFUSED_TRANSFER. */
    private val BRIDGE_CODES = setOf(
        "grantClosed", "grantIdentityMismatch", "operationNoLongerOwned",
        "baselineUnavailable", "sessionKeyInvalid", "journalUnavailable",
        "journalCollision", "newInputPathUnavailable", "snapshotPathUnsafe",
        "snapshotDataMissing", "snapshotHeaderMismatch", "snapshotTableShort",
        "budgetExceeded", "diskReserveUnmet", "transportUncertain",
        "importCancelled", "importFailed", "inputBaselineAdoptionFailed",
        "inputBaselineAdoptionUncertain",
    )

    fun execute(harness: InputSyncHarness, payload: JSONObject,
                cancelled: () -> Boolean): JSONObject {
        require(payload.keys().asSequence().all { it in ALLOWED_FIELDS }) { "syncFieldsInvalid" }
        // Core identities travel as ORIGINAL bytes (Swift UUID.uuidString is
        // UPPER-CASE canonical); only the grammar is validated here, never a
        // case transform. Ownership is decided by the grant, exactly as for
        // shell.start.
        val projectID = canonicalUUID(payload.getString("projectID"))
        val runID = canonicalUUID(payload.getString("runID"))
        if (harness.exclusiveWork()) return refused(REFUSED_BUSY)
        // N07 R2 repair — an UNCHECKED engine failure at a destination/
        // identity/session boundary is honestly UNCONFIRMED (the transfer
        // never ran, or may have partially applied; the read-side probe
        // re-answers visibility), carrying a bounded same-request `phase`
        // token so one fresh device case discriminates the boundary — never
        // a bare `operation_failed` receipt (which collapses to a generic
        // unconfirmed) and never a fabricated refusal/success. The typed
        // refusal vocabulary and every in-transfer failure check are
        // unchanged: those still map to the bounded `refused` codes below.
        val live = try {
            harness.liveWorkspace(projectID)
        } catch (failure: Exception) {
            return unconfirmed("liveWorkspace")
        } ?: return refused(REFUSED_NOT_LIVE)
        // Identity re-proof: the destination MUST be the canonical
        // `Workspaces/<projectID>` directory the live owner serves — never a
        // scratch, journal or caller-influenced path.
        val identityOK = try {
            val expected = File(harness.workspacesRoot.canonicalFile, projectID).canonicalFile
            live.workspaceRoot.canonicalFile == expected && live.workspaceRoot.isDirectory
        } catch (failure: Exception) {
            return unconfirmed("identity")
        }
        if (!identityOK) return refused(REFUSED_IDENTITY)
        val session = try {
            harness.openWorkspace(projectID, runID, live.workspaceRoot)
        } catch (failure: Exception) {
            return unconfirmed("openSession")
        }
        try {
            val receipt = session.importNewInputs(
                WorkspaceCancelSignal { cancelled() }, live.baseline)
            // The participant start applies the same two gates: unsupported
            // Core entries or any conflict refuse the WHOLE answer (the
            // destination itself was only ever added to, never replaced).
            if (receipt.skippedCount != 0 || receipt.conflictPaths.isNotEmpty()) {
                return refused(REFUSED_INPUTS)
            }
            return JSONObject()
                .put("state", "ok")
                .put("created", receipt.createdCount)
                .put("retained", receipt.retainedExistingCount)
        } catch (failure: WorkspaceBridgeException) {
            return refused(failure.code.takeIf { it in BRIDGE_CODES } ?: REFUSED_TRANSFER)
        } catch (failure: Exception) {
            // Any other engine failure (adoption refusal, unexpected IO) is
            // still an honest typed refusal of THIS transfer — never a
            // partial success and never an unbounded error text.
            return refused(REFUSED_TRANSFER)
        } finally {
            // The transfer is additions-only; a close failure after a real
            // receipt never rewrites the answered outcome, and after a
            // failure it never masks the original refusal. Leftover journals
            // are the original sweep's recoverable input.
            runCatching { session.close() }
        }
    }

    private fun refused(code: String): JSONObject =
        JSONObject().put("state", "refused").put("code", code)

    /** An UNCHECKED engine failure at one named boundary: honestly
     *  `unconfirmed` (never a fabricated refusal/success), with a bounded
     *  same-request `phase` token so one fresh device case discriminates
     *  where the live publish actually failed. Typed lowercase token only. */
    private fun unconfirmed(phase: String): JSONObject =
        JSONObject().put("state", "unconfirmed").put("code", "engineException")
            .put("phase", phase.take(48))

    /** Same uppercase-canonical grammar rule as the preflight (one shared
     *  implementation): validate the ACTUAL Core identity form and return
     *  the ORIGINAL bytes unchanged. */
    private fun canonicalUUID(text: String): String =
        RuntimeWorkspacePreflight.canonicalUUID(text)
}
