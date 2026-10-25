// SPDX-License-Identifier: MPL-2.0
package com.floe.android.workspacebridge

/**
 * The synchronous native Core authority surface. This interface is the
 * EXACT shape of Main's `core/swiftbridge` JNI adapter
 * (LinuxWorkspaceNative.kt + floe_linux_workspace_jni.cpp): JSON replies are
 * raw standard UTF-8 bounded to 64 KiB; identifiers are ASCII <= 64 chars;
 * a missing or uncertain native reply is NEVER replayed (state is unknown).
 *
 * Only the Core app process ever implements/holds this. The runtime process
 * never loads swiftbridge: it talks to the opaque grant Binder instead
 * (`RuntimeWorkspaceSession`), which the Core grant resolves through this
 * interface. `dataFd` parameters are CALLER-OWNED: the native side reads
 * but never closes them. `baselineOpenData` returns a NEW owned fd (>= 0) or
 * a negative typed code; the Java caller must wrap it in a
 * ParcelFileDescriptor exactly once and close it after the binder reply.
 */
interface WorkspaceNativeAuthority {
    /** Mint the proof-bound grant metadata JSON for an ORDINARY in-run call
     *  (the ORIGINAL parent run must be non-terminal), or null when the
     *  trusted workspace/run/epoch cannot be resolved (fail closed; never
     *  guesses). */
    fun binding(rootEpoch: Long, runID: String, grantID: String): ByteArray?

    /** Mint for the ORIGINAL durable-job owner: `toolCallID` must carry the
     *  exact frozen `jobs.<UUID>` host call id captured from the trusted
     *  mailbox context (Main adapter). The grant then survives a TERMINAL
     *  parent run, and is revoked only by real job settlement/cancellation
     *  (original row terminal or absent from both original live signals).
     *  Null toolCallID behaves like `binding(...)`. */
    fun bindingForCall(rootEpoch: Long, runID: String, toolCallID: String?, grantID: String): ByteArray?

    /** Mint for the G04-R2 UI operation lease (real terminal/LSP admission):
     *  `operationID` is the native-issued canonical UUID of the LIVE
     *  `beginG04WorkspaceOperation` conversation lease that the trusted Swift
     *  host registered IN-PROCESS before `shell.start`; `runID` is the SAME
     *  open step's native-issued UI interaction identity (NOT a model Run).
     *  The mint succeeds ONLY against that still-attached registry token, the
     *  still-validating domain lease and the ORIGINAL conversation-owned
     *  workspace row; unregistered/revoked/foreign/mismatched replies null.
     *  This is NOT a fallback from the run/job lanes and never a boolean
     *  bypass. DEFAULT null so an authority that does not implement the
     *  operation lane FAILS CLOSED (no grant) and every existing fake/impl
     *  compiles unchanged. */
    fun bindingForOperation(rootEpoch: Long, operationID: String, runID: String, grantID: String): ByteArray? = null

    /** Open the native session for a minted binding JSON. Reply JSON carries
     *  {"ok":true,"sessionKey":...} or {"ok":false,"code":...}. */
    fun openSession(bindingJson: ByteArray): ByteArray

    fun baselineBegin(sessionKey: String): ByteArray
    fun baselineHeader(sessionKey: String, index: Long): ByteArray

    /** >= 0: a NEW owned read-only descriptor for the entry bytes.
     *  Negative: typed refusal (the caller maps it to a bounded code). */
    fun baselineOpenData(sessionKey: String, index: Long): Int

    fun baselineFinish(sessionKey: String, appliedCount: Long, appliedBytes: Long): ByteArray

    fun exportBegin(sessionKey: String): ByteArray

    /** Stages one received entry; `dataFd` is caller-owned and is NOT closed
     *  here. Regular-file headers require a valid fd; directory/symlink
     *  headers use -1. */
    fun exportStage(sessionKey: String, headerJson: ByteArray, dataFd: Int): ByteArray

    /** Preflight + CAS commit under the original managed-writer mutation
     *  lock; returns the outcome JSON (synced | conflict | aborted | error). */
    fun exportFinish(sessionKey: String): ByteArray

    fun abort(sessionKey: String, reason: String): ByteArray

    /** Marks the native session terminal and fences it (returns native
     *  status int; 0 is success). */
    fun closeSession(sessionKey: String): Int

    fun stats(): ByteArray
    fun sweep(nowSeconds: Long, graceSeconds: Long): ByteArray
}

/** Cooperative cancellation, polled at every frame/entry boundary. Main
 *  wires this to the pump's proven stop intent (mailbox `shouldStop` or the
 *  owned-work registry), never to a model argument. */
fun interface WorkspaceCancelSignal {
    fun shouldCancel(): Boolean
}

/** Transport/native refusal with a bounded code (no paths, no payloads).
 *  `recovery` optionally carries the transaction's OWN measured terminal
 *  evidence (for example the reverse-restore counts of a cancelled import
 *  swap). It is produced ONLY by the original journal engine on the failing
 *  path and is bounded to relative identities and counters. HANDOFF STATUS
 *  (job-150dee8e1ed14ba1): the kernel failed terminal now carries this
 *  object plus the original typed code additively, and the host pump
 *  publishes it on the ORIGINAL failed-start claim ONLY after the real
 *  drain/quiescence AND the original grant/CoreIO close, re-bound to the
 *  exact grant session key, run UUID and current native epoch; anything
 *  foreign/unbound/stale/malformed stays ABSENT (never zeroed) and every
 *  legacy failure keeps its old generic settlement. The journal remains the
 *  audit truth; calling it device-proven rollback requires Main's actual
 *  supported mid-import cancel fixture on the installed build. */
class WorkspaceBridgeException(
    val code: String,
    cause: Throwable? = null,
    val recovery: org.json.JSONObject? = null,
) : Exception(code, cause)
