// SPDX-License-Identifier: MPL-2.0
package com.floe.android.workspacebridge

import android.content.Context
import android.os.Binder
import android.os.IBinder
import android.os.Parcel
import android.os.ParcelFileDescriptor
import android.os.Process
import com.floe.android.runtimeipc.RuntimePackages
import com.floe.android.runtimeipc.RuntimePeerVerifier
import org.json.JSONObject
import java.io.Closeable
import java.security.SecureRandom
import java.util.concurrent.atomic.AtomicLong

/**
 * The OPAQUE Core-side workspace grant. Created ONLY inside the Core app
 * process from a native-minted, proof-bound binding (metadata JSON cannot
 * mint a grant: `floe_linux_workspace_binding` re-derives the workspace from
 * the accepted Root + the ORIGINAL run/conversation/workspace stores and the
 * mint is single-use; `openSession` consumes it). The runtime receives the
 * grant as a strong Binder (Main transports it beside foregroundPermit,
 * outside model JSON) and can ONLY exercise these bounded transactions while
 * ALL of the following hold:
 *  * the caller is the exact counterpart package UID with matching
 *    signature (checked by `RuntimePeerVerifier.requireCallingPeer` on the
 *    Binder thread, BEFORE any async work or file IO — not just "some app
 *    signed with our key", and shared-UID admission is refused),
 *  * the original operation is still owned (`isOwned` callback from the
 *    trusted host: run active + foreground lease held + epoch current;
 *    model/tool arguments can never reach this object),
 *  * the native root epoch is unchanged (re-verified inside every native
 *    call — a generation change fences the session; no replay).
 *
 * Bulk bytes ride only as ParcelFileDescriptor streams; every control object
 * is one bounded JSON string. Core absolute workspace paths NEVER cross:
 * the runtime sees relative paths + opaque ids.
 */
class CoreWorkspaceGrant private constructor(
    private val context: Context,
    private val authority: WorkspaceNativeAuthority,
    private val isOwned: WorkspaceOwnershipProbe,
    private val bindingJson: JSONObject,
    val sessionKey: String,
    private val runtimePackage: String,
) : Binder(), Closeable {

    // Real IO gate (Main lifetime review): every dispatched file/native
    // transaction is counted between enter/exit; close() fences new entries
    // atomically, requests native cancellation, and DRAINS already-entered
    // operations before returning. No timeout release, no fake zero.
    private val ioGate = WorkspaceIOLatch()
    private val transactions = AtomicLong()
    private val dispatchLock = java.util.concurrent.locks.ReentrantLock()
    /** The LAST ACTUAL native EXPORT_FINISH reply for THIS grant, captured
     *  only from the real reply bytes (never synthesized, never a runtime
     *  success string). Retained across drained close so Main can confirm
     *  file-sync status from the Core-owned receipt before completing the
     *  native shell poll/job gate. Null or a non-`ok`/non-terminal reply is
     *  NOT success. */
    @Volatile
    private var exportReceiptBytes: ByteArray? = null

    val projectID: String = bindingJson.getString("projectID")
    val runID: String = bindingJson.getString("runID")
    val conversationID: String? = bindingJson.optString("conversationID").takeIf { it.isNotEmpty() }
    val workspaceID: String = bindingJson.getString("workspaceID")
    val rootEpoch: Long = bindingJson.getLong("rootEpoch")

    /** Identity echoed to the runtime inside GET_STATE only — the runtime
     *  compares it against the ORIGINAL shell.start identities. */
    fun stateJson(): JSONObject = JSONObject()
        .put("ok", true)
        .put("open", !ioGate.isFenced)
        .put("version", WorkspaceBridgeWire.VERSION)
        .put("projectID", projectID)
        .put("runID", runID)
        .put("rootEpoch", rootEpoch)
        .put("budgets", bindingJson.getJSONObject("budgets"))

    override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
        if (code == INTERFACE_TRANSACTION) {
            // Identity first, before anything else (RuntimeControlBinder discipline).
            RuntimePeerVerifier(context).requireCallingPeer(runtimePackage)
            reply?.writeString(WorkspaceBridgeWire.DESCRIPTOR)
            return true
        }
        if (code < WorkspaceBridgeWire.GET_STATE || code > WorkspaceBridgeWire.STATS) {
            return super.onTransact(code, data, reply, flags)
        }
        val peer = RuntimePeerVerifier(context)
        peer.requireCallingPeer(runtimePackage)
        require(reply != null && flags and IBinder.FLAG_ONEWAY == 0) { "grant requires a synchronous reply" }
        var incoming: ParcelFileDescriptor? = null
        val controlObject: JSONObject? = try {
            val control = WorkspaceParcelIO.readControl(data)
            incoming = WorkspaceParcelIO.readOptionalDescriptor(data)
            require(data.dataAvail() == 0) { "trailing request data" }
            JSONObject(control)
        } catch (_: Exception) {
            incoming?.close()
            incoming = null
            null
        }
        if (controlObject == null) {
            incoming?.close()
            reply?.let { writeError(it, "requestMalformed") }
            return true
        }
        // Enter the REAL IO gate BEFORE any native/file work. A fenced grant
        // refuses synchronously; an entered transaction is counted until its
        // actual file/native operation returned (close() drains on this).
        if (!ioGate.begin()) {
            incoming?.close()
            reply?.let { writeError(it, "grantClosed") }
            return true
        }
        dispatchLock.lock()
        try {
            // Recheck ownership + fence INSIDE the gate, before dispatch.
            if (ioGate.isFenced || !isOwned.isStillOwned()) {
                incoming?.close()
                reply?.let { writeError(it, if (ioGate.isFenced) "grantClosed" else "operationNoLongerOwned") }
                return true
            }
            transactions.incrementAndGet()
            val identity = Binder.clearCallingIdentity()
            try {
                handle(code, controlObject, incoming, requireNotNull(reply))
                return true
            } catch (_: WorkspaceBridgeException) {
                reply?.let { writeError(it, "nativeUnavailable") }
                return true
            } catch (_: Exception) {
                reply?.let { writeError(it, "grantInternal") }
                return true
            } finally {
                Binder.restoreCallingIdentity(identity)
                incoming?.close()
            }
        } finally {
            dispatchLock.unlock()
            ioGate.end()
        }
    }

    private fun handle(code: Int, control: JSONObject, incoming: ParcelFileDescriptor?, reply: Parcel) {
        when (code) {
            WorkspaceBridgeWire.GET_STATE -> {
                requireIdentityEcho(control)
                WorkspaceParcelIO.writeReply(reply, stateJson())
            }
            WorkspaceBridgeWire.BASELINE_BEGIN -> {
                WorkspaceParcelIO.writeReply(reply, JSONObject(String(authority.baselineBegin(sessionKey), Charsets.UTF_8)))
            }
            WorkspaceBridgeWire.BASELINE_HEADER -> {
                val index = control.getLong("index")
                WorkspaceParcelIO.writeReply(reply, JSONObject(String(authority.baselineHeader(sessionKey, index), Charsets.UTF_8)))
            }
            WorkspaceBridgeWire.BASELINE_DATA -> {
                val index = control.getLong("index")
                val rawFd = authority.baselineOpenData(sessionKey, index)
                if (rawFd < 0) {
                    WorkspaceParcelIO.writeReply(reply, JSONObject().put("ok", false).put("code", nativeFdCode(rawFd)))
                    return
                }
                val descriptor = ParcelFileDescriptor.adoptFd(rawFd)
                try {
                    WorkspaceParcelIO.writeReply(
                        reply,
                        JSONObject(String(authority.baselineHeader(sessionKey, index), Charsets.UTF_8)),
                        descriptor,
                    )
                } finally {
                    descriptor.close()
                }
            }
            WorkspaceBridgeWire.BASELINE_FINISH -> {
                WorkspaceParcelIO.writeReply(
                    reply,
                    JSONObject(String(
                        authority.baselineFinish(sessionKey, control.getLong("appliedCount"), control.getLong("appliedBytes")),
                        Charsets.UTF_8,
                    )),
                )
            }
            WorkspaceBridgeWire.EXPORT_BEGIN -> {
                WorkspaceParcelIO.writeReply(reply, JSONObject(String(authority.exportBegin(sessionKey), Charsets.UTF_8)))
            }
            WorkspaceBridgeWire.EXPORT_STAGE -> {
                val kind = control.optString("kind")
                val dataFd: Int = if (kind == "file") {
                    requireNotNull(incoming) { "file stage requires a descriptor" }.fd
                } else {
                    require(incoming == null) { "only file stages may carry a descriptor" }
                    -1
                }
                WorkspaceParcelIO.writeReply(
                    reply,
                    JSONObject(String(authority.exportStage(sessionKey, control.toString().toByteArray(Charsets.UTF_8), dataFd), Charsets.UTF_8)),
                )
            }
            WorkspaceBridgeWire.EXPORT_FINISH -> {
                val nativeReply = JSONObject(String(authority.exportFinish(sessionKey), Charsets.UTF_8))
                captureExportReceipt(nativeReply)
                WorkspaceParcelIO.writeReply(reply, nativeReply)
            }
            WorkspaceBridgeWire.ABORT -> {
                val reason = control.optString("reason").takeIf { it.isNotEmpty() } ?: "host-abort"
                WorkspaceParcelIO.writeReply(reply, JSONObject(String(authority.abort(sessionKey, reason), Charsets.UTF_8)))
            }
            WorkspaceBridgeWire.STATS -> {
                WorkspaceParcelIO.writeReply(reply, JSONObject(String(authority.stats(), Charsets.UTF_8)))
            }
            else -> writeError(reply, "unknownTransaction")
        }
    }

    private fun captureExportReceipt(nativeReply: JSONObject) {
        // Only an actual, well-formed, ok=true terminal receipt is retained;
        // errors leave the previous state untouched (null stays null =>
        // Main sees "no proof", never a fabricated success).
        if (!nativeReply.optBoolean("ok", false)) return
        val result = nativeReply.optString("result")
        if (result != "synced" && result != "conflict" && result != "aborted") return
        val text = nativeReply.toString()
        val bytes = text.toByteArray(Charsets.UTF_8)
        if (bytes.size > WorkspaceBridgeWire.MAX_CONTROL_BYTES) return
        exportReceiptBytes = bytes
    }

    /** Read-only: the retained Core-side export receipt for THIS grant, or
     *  null when no actual settled EXPORT_FINISH reply exists. Calling this
     *  performs NO transaction and cannot trigger effects. A defensive
     *  immutable copy is returned. */
    fun exportReceipt(): ByteArray? = exportReceiptBytes?.copyOf()

    private fun requireIdentityEcho(control: JSONObject) {
        // Exact case-sensitive comparison: owner UUID strings ride UNCHANGED
        // (same rule as the shell mailbox); a lowercase echo is a mismatch.
        require(control.optString("projectID") == projectID && control.optString("runID") == runID) {
            "identity mismatch"
        }
    }

    private fun writeError(reply: Parcel, code: String) {
        try {
            WorkspaceParcelIO.writeReply(
                reply,
                JSONObject().put("ok", false).put("code", code.take(64)),
            )
        } catch (_: Exception) {
            // A reply that cannot even carry a code is a transport failure;
            // the caller treats RemoteException honestly (no replay).
        }
    }

    /**
     * Synchronous drained close (Main pump ordering: grant.close() BEFORE
     * owned lease.close()/map removal). 1) atomically fence new transactions,
     * 2) request the native abort so in-flight streaming copies hit their
     * frame-boundary cancellation, 3) WAIT for every already-entered
     * file/native transaction to actually return, 4) only then close the
     * native session table. No timeout release and no fake zero counter:
     * if a Core-side export callback has not returned, close has not
     * returned, so the pump cannot release Root/FGS underneath it. Repeat
     * callers wait for the same drain and re-run the (idempotent) native
     * close; abort after terminal is an honest alreadyTerminal no-op.
     */
    override fun close() {
        ioGate.fence()
        val identity = Binder.clearCallingIdentity()
        try {
            runCatching { authority.abort(sessionKey, "grant-close") }
            ioGate.awaitDrained()
            check(authority.closeSession(sessionKey) == 0) { "workspace session close failed" }
        } finally {
            Binder.restoreCallingIdentity(identity)
        }
    }

    companion object {
        private val random = SecureRandom()

        /**
         * Mints and opens the grant inside the Core process.
         *  * `rootEpoch` MUST be the ACTUAL accepted native epoch the pump is
         *    running (never a guess, never 0);
         *  * `runID` is the ORIGINAL runtime-issued run identity from the
         *    shell.start payload (case-preserved);
         *  * `trustedCallID` — OPTIONAL ORIGINAL durable-job host call id in
         *    the exact frozen `jobs.<UUID>` shape captured from the trusted
         *    mailbox context (never a model value). A job-scoped grant
         *    survives a terminal parent run and dies only with real job
         *    settlement/cancellation; null (ordinary in-run call) keeps the
         *    original active-parent currency requirement;
         *  * `isOwned` is the host's real ownership predicate (run active +
         *    foreground lease held + ledger ownership); a grant with a
         *    fail-closed probe is inert, which is the intended absence of a
         *    commit authority;
         *  * `authority` is required (no default-true): without the native
         *    adapter there is no grant at all.
         *  * `refusalObserver` — OPTIONAL diagnostic-only sink
         *    (G03-R3 grant refusal observation): every null return below reports
         *    EXACTLY ONE closed fixed token (branch name, or the flat
         *    native reply code when it is an enumerated member of
         *    [NATIVE_REFUSAL_CODES]) before returning. The observer gates
         *    nothing, changes no admission/ownership outcome and never
         *    carries paths, digests, commands or reply bodies; absence
         *    (default null) preserves every existing call site byte-for-
         *    byte. Tokens are <=32 printable ASCII so the pump can ride
         *    them through its existing bounded stage recording.
         * Returns null (never a partially-usable object) when the workspace,
         * run, epoch or native session cannot be resolved.
         */
        fun create(
            contextCore: Context,
            rootEpoch: Long,
            runID: String,
            trustedCallID: String? = null,
            isOwned: WorkspaceOwnershipProbe,
            authority: WorkspaceNativeAuthority,
            refusalObserver: ((String) -> Unit)? = null,
        ): CoreWorkspaceGrant? {
            fun refuse(branch: String, nativeCode: String? = null): CoreWorkspaceGrant? {
                refusalObserver?.invoke(refusalToken(branch, nativeCode))
                return null
            }
            if (rootEpoch <= 0 || runID.length > WorkspaceBridgeWire.MAX_IDENTIFIER_CHARS)
                return refuse(REFUSAL_ARGUMENTS_INVALID)
            val corePackage = contextCore.packageName
            val packages = runCatching { RuntimePackages.forCore(corePackage) }.getOrNull()
                ?: return refuse(REFUSAL_PEER_REFUSED)
            // Own-process sanity: this factory only ever runs in the Core app.
            val verifier = RuntimePeerVerifier(contextCore)
            runCatching { verifier.verifyPeer(packages.runtime) }.getOrNull()
                ?: return refuse(REFUSAL_PEER_REFUSED)
            val grantID = randomGrantID()
            val bindingBytes = if (trustedCallID == null) {
                authority.binding(rootEpoch, runID, grantID)
            } else {
                authority.bindingForCall(rootEpoch, runID, trustedCallID, grantID)
            } ?: return refuse(REFUSAL_BINDING_UNPARSABLE)
            if (bindingBytes.size > WorkspaceBridgeWire.MAX_CONTROL_BYTES)
                return refuse(REFUSAL_BINDING_UNPARSABLE)
            val binding = runCatching { JSONObject(String(bindingBytes, Charsets.UTF_8)) }.getOrNull()
                ?: return refuse(REFUSAL_BINDING_UNPARSABLE)
            if (!binding.optBoolean("ok", false))
                return refuse(REFUSAL_BINDING_REFUSED, binding.optString("code").takeIf { it.isNotEmpty() })
            if (binding.optString("runID") != runID || binding.optLong("rootEpoch") != rootEpoch ||
                binding.optString("grantID") != grantID
            ) {
                return refuse(REFUSAL_IDENTITY_MISMATCH)
            }
            val openReply = runCatching {
                JSONObject(String(authority.openSession(bindingBytes), Charsets.UTF_8))
            }.getOrNull() ?: return refuse(REFUSAL_OPEN_UNPARSABLE)
            if (!openReply.optBoolean("ok", false))
                return refuse(REFUSAL_OPEN_REFUSED, openReply.optString("code").takeIf { it.isNotEmpty() })
            val sessionKey = openReply.optString("sessionKey")
            if (!sessionKey.matches(Regex(WorkspaceBridgeWire.SESSION_KEY_REGEX)))
                return refuse(REFUSAL_SESSION_KEY_MALFORMED)
            return CoreWorkspaceGrant(
                context = contextCore.applicationContext,
                authority = authority,
                isOwned = isOwned,
                bindingJson = binding,
                sessionKey = sessionKey,
                runtimePackage = packages.runtime,
            )
        }

        private fun randomGrantID(): String {
            val bytes = ByteArray(16)
            random.nextBytes(bytes)
            return bytes.joinToString("") { "%02x".format(it) }
        }

        private fun nativeFdCode(value: Int): String = when (value) {
            -1 -> "invalidArguments"
            -2 -> "noSession"
            -3 -> "proofRefused"
            -4 -> "budgetExceeded"
            -5 -> "ioFailed"
            -6 -> "cancelled"
            -7 -> "malformed"
            -8 -> "pathUnsafe"
            -9 -> "commitRefused"
            -10 -> "diskReserveUnmet"
            else -> "nativeError$value"
        }

        // MARK: Closed grant-refusal diagnostic vocabulary
        // (G03-R3 grant refusal observation). Fixed constants only — enumerated
        // from the ACTUAL null-return branches of [create] and the flat
        // frozen native reply codes; never paths, digests, commands or
        // reply bodies. The host readiness controller enumerates these
        // SAME strings in its KNOWN_STAGE_TOKENS closed set (membership,
        // not length, is the bound); every token is <=32 printable ASCII
        // so it survives the pump's boundedCode/reason grammar unchanged.

        const val REFUSAL_ARGUMENTS_INVALID = "grant_arguments_invalid"
        const val REFUSAL_PEER_REFUSED = "grant_peer_refused"
        const val REFUSAL_BINDING_UNPARSABLE = "grant_binding_unparsable"
        const val REFUSAL_BINDING_REFUSED = "grant_binding_refused"
        const val REFUSAL_IDENTITY_MISMATCH = "grant_identity_mismatch"
        const val REFUSAL_OPEN_UNPARSABLE = "grant_open_unparsable"
        const val REFUSAL_OPEN_REFUSED = "grant_open_refused"
        const val REFUSAL_SESSION_KEY_MALFORMED = "grant_session_key_malformed"

        val BRANCH_REFUSAL_TOKENS: Set<String> = setOf(
            REFUSAL_ARGUMENTS_INVALID, REFUSAL_PEER_REFUSED, REFUSAL_BINDING_UNPARSABLE,
            REFUSAL_BINDING_REFUSED, REFUSAL_IDENTITY_MISMATCH, REFUSAL_OPEN_UNPARSABLE,
            REFUSAL_OPEN_REFUSED, REFUSAL_SESSION_KEY_MALFORMED,
        )

        /** Flat CLOSED native reply codes: the fixed `code` members the
         *  frozen `floe_linux_workspace_binding(_for_call)` /
         *  `floe_linux_workspace_session_open` entries and the engine's
         *  flat wire codes can emit. PARAMETERIZED engine codes (for
         *  example `workspaceProofRefused:<hook>` or
         *  `workspaceIO:<stage>:<errno>`) are deliberately NOT enumerated:
         *  they fall back to the branch token, so no free text ever rides
         *  the observer. */
        val NATIVE_REFUSAL_CODES: Set<String> = setOf(
            "invalidArguments", "epochNotCurrent", "bindingUnavailable",
            "bindingMalformed", "bindingUnresolved", "jobCallMismatch",
            "grantNotMinted", "sessionOpenFailed", "workspaceNotConfigured",
        )

        /** Pure token selection (unit-testable without Android): the
         *  closed native code when it is an enumerated member, otherwise
         *  the branch token. Never concatenates, truncates or passes
         *  unknown text through. */
        fun refusalToken(branch: String, nativeCode: String?): String =
            nativeCode?.takeIf { it in NATIVE_REFUSAL_CODES } ?: branch

        /** Host-side process check used by tests/diagnostics only; the
         *  authoritative UID/signature gate is `requireCallingPeer` inside
         *  every transaction. */
        fun callerIsDistinctRuntimeUid(callerUid: Int, ownUid: Int): Boolean =
            callerUid != ownUid && callerUid != Process.myUid()
    }
}

/** The REAL ownership predicate: the trusted host supplies the actual run +
 *  foreground-lease + ledger state. It is not a model value, has no default,
 *  and its absence (or false) makes the grant inert. */
fun interface WorkspaceOwnershipProbe {
    fun isStillOwned(): Boolean
}
