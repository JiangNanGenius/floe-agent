// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import android.content.Context
import android.os.IBinder
import com.floe.android.runtimeipc.RuntimeExecutionTrace
import com.floe.android.runtimeipc.RuntimeExecutionTrace.Stage
import com.floe.android.runtimeipc.RuntimeWire
import org.json.JSONObject
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/** Implemented by the native-authority + installer + real process composition. */
internal interface RuntimeOperations {
    fun execute(request: RuntimeWire.Request, workspaceGrant: IBinder?, cancelled: () -> Boolean): JSONObject
    fun isExecuting(): Boolean
    /** Memory-only pages/progress. No disk, native, process waits or network. */
    fun snapshot(request: RuntimeWire.Request): JSONObject?
    fun validateCancellation(request: RuntimeWire.Request)
    fun stopOwnedWork(request: RuntimeWire.Request? = null)
    fun hasOwnedWork(): Boolean
    /** Install / first-use preflight: still exclusive with every workload. */
    fun hasExclusiveWork(): Boolean
    /**
     * Every exact admitted work request id that still owns runtime work:
     * pending start, retained lease/failed lease, live [Running.startID],
     * install, preflight and a retained deferred export's OWNER start id.
     * Only positive removal from this set settles a permit association.
     */
    fun ownedRequestIDs(): Set<String>
}

/** Bounded transient IPC receipts, not the main App's durable BackgroundJobStore. */
class RuntimeKernel(context: Context) {
    private val context = context.applicationContext
    private val executor = ThreadPoolExecutor(1, 1, 30, TimeUnit.SECONDS,
        ArrayBlockingQueue(8)) { work -> Thread(work, "floe-linux-control") }.apply { allowCoreThreadTimeOut(true) }
    // Per-target cancellation lane. The ORIGINAL single-slot queue claimed at
    // most one stop and silently dropped every additional distinct target
    // while that drain was pending; once two interactive sessions each own a
    // foreground permit, each accepted target stop must be delivered. This
    // stays ONE serialized lane with a bounded queue and a lossless handoff
    // (see BoundedStopDispatcher): no unbounded queue, no concurrent stop.
    private val stopExecutor = BoundedStopDispatcher(BoundedStopDispatcher.DEFAULT_CAPACITY)
    private val count = AtomicInteger()
    // G03-R3 first-start admission repair: the stopping fence is a
    // monitor-serialized lifecycle state machine, not two free atomics.
    // A stale fence leaked by a pump-thread-converged release used to
    // refuse the NEXT start (the brand-new ordinary New task's first tool
    // run) deterministically between KERNEL_START_ENTER and
    // KERNEL_ADMISSION_CHECK — see RuntimeStoppingFence for the actual
    // device evidence and the preserved ORIGINAL rules. Every raise/settle
    // transition keeps the requestStop/executor semantics byte-for-byte;
    // the read-only `status` metadata path merely READS the fence.
    private val fence = RuntimeStoppingFence { hasOwnedWork() }
    private val pendingInstallID = AtomicReference<String?>()
    // G07.3A: concurrent starts each have their own pending wire id; a
    // session-less stop may address any ONE of them by exact id.
    private val pendingShellIDs: MutableSet<String> = java.util.concurrent.ConcurrentHashMap.newKeySet()
    // Target-scoped stops that arrived for a still-admitted request. The
    // queued request consults this set before it creates operations/spawns,
    // so a stop for A can never be lost while the operations object is being
    // built; the request's own finally removes only its own id. This is a
    // lifecycle note, never a grant or an admission bypass.
    private val targetStoppedIDs: MutableSet<String> = java.util.concurrent.ConcurrentHashMap.newKeySet()
    private val pendingPreflightID = AtomicReference<String?>()
    // REAL engine PROCESS generation, measured identity — never an auth
    // token and never a random success flag: the kernel object is created
    // once per runtime process instance (held by RuntimeApplication), so
    // pid + this boot nonce identify exactly one live peer generation.
    // Authentication stays exclusively in RuntimePeerVerifier and
    // RuntimeForegroundPermit; the trusted host readiness controller reads
    // these fields over the already-authenticated binder and refuses a
    // silent generation swap.
    private val runtimeBootToken: String get() = RuntimeProcessIdentity.bootToken
    private val runtimePid: Int get() = RuntimeProcessIdentity.pid
    private val receipts = LinkedHashMap<String, JSONObject>()
    @Volatile private var operations: RuntimeOperations? = null
    @Volatile var onChanged: ((Boolean) -> Unit)? = null

    fun hasOwnedWork(): Boolean = count.get() > 0 || operations?.hasOwnedWork() == true
    fun isExecuting(): Boolean = operations?.isExecuting() == true

    fun exchange(request: RuntimeWire.Request, workspaceGrant: IBinder?, foregroundAllowed: () -> Boolean): JSONObject {
        val traceStart = request.operation == "shell.start"
        if (traceStart) RuntimeExecutionTrace.mark(Stage.KERNEL_START_ENTER)
        if (request.operation == "status") {
            val reply = JSONObject()
                .put("protocol", RuntimeWire.VERSION).put("foreground", foregroundAllowed())
                .put("active", hasOwnedWork()).put("stopping", fence.isStopping)
                .put("localNetworkGranted", android.os.Build.VERSION.SDK_INT < 37 || context.checkSelfPermission(
                    RuntimeAccessActivity.PERMISSION) == android.content.pm.PackageManager.PERMISSION_GRANTED)
                // Loading metadata or binding the component does not enable a tool.
                .put("modelExecutionReady", false)
                // Actual applied guest resolver state (additive diagnostics;
                // counts/classes only, never raw server addresses).
                .put("resolver", RuntimeNetworkConfiguration.statusSnapshot())
                // Process-generation identity for the host's live anchoring.
                .put("runtimePid", runtimePid).put("runtimeBootToken", runtimeBootToken)
                // The workload contract version is advertised ONLY when this
                // kernel genuinely runs a single-slot executor with the
                // exclusive-start admission below. It is the engine's own real
                // attestation; an idle check belongs to the host ingest.
                .put("workloadContractVersion", MULTI_WORKLOAD_CONTRACT)
            // G07.1 terminal04 (ADDITIVE, diagnostics only): this engine
            // process's OWN settled phase composition for its most recent
            // workload. Absent until a first terminal; stage names and
            // integer durations only — no command, path, payload or id. A
            // metadata read never consults or changes it.
            LinuxRuntimePhaseTiming.lastSummary()?.let { reply.put("lastTerminalPhases", it) }
            return reply
        }
        if (request.operation == "request.status") {
            require(request.payload.keys().asSequence().toSet() == setOf("requestID"))
            val id = request.payload.getString("requestID")
            return synchronized(receipts) {
                receipts[id]?.let { JSONObject(it.toString()) }
                    ?: JSONObject().put("state", "unknown")
            }
        }
        operations?.snapshot(request)?.let { return it }
        if (request.operation == "install.cancel" || request.operation == "shell.cancel" ||
            request.operation == RuntimeWire.PREFLIGHT_CANCEL
        ) {
            // Urgent stop is never queued behind a download/materialization.
            if (request.operation == "install.cancel" && pendingInstallID.get() == request.payload.optString("requestID")) {
                require(request.payload.keys().asSequence().toSet() == setOf("requestID"))
            } else if (request.operation == "shell.cancel" && pendingShellIDs.contains(request.payload.optString("requestID"))) {
                require(request.payload.keys().asSequence().toSet() == setOf("requestID"))
            } else if (request.operation == RuntimeWire.PREFLIGHT_CANCEL &&
                pendingPreflightID.get() == request.payload.optString("requestID")
            ) {
                require(request.payload.keys().asSequence().toSet() == setOf("requestID"))
            } else checkNotNull(operations).validateCancellation(request)
            requestStop(request)
            return JSONObject().put("state", "stop_requested")
        }
        val metadataOnly = request.operation == "install.status" || request.operation == "environment.list"
        // G03-R3 cleanup lane: data-deletion obligations must stay serviceable
        // while shell/model admission is fenced (the caller carries NO
        // foreground permit for them). This exemption is ONLY for the typed
        // scoped wipe; stopping still refuses, no grant is accepted/required,
        // and the receiver performs its own busy/quiescence deferral first.
        val cleanupLane = request.operation == RuntimeWire.CLEANUP
        if (request.operation == "shell.start" || request.operation == RuntimeWire.PREFLIGHT)
            check(workspaceGrant != null) { "Owned workspace grant is required" }
        check(metadataOnly || cleanupLane || foregroundAllowed()) { "Foreground work ownership is required" }
        check(!fence.isStopping) { "Runtime is stopping" }
        synchronized(receipts) {
            receipts[request.id]?.let { return JSONObject(it.toString()) }
            if (request.operation == "install.start" || request.operation == RuntimeWire.PREFLIGHT) {
                // Install / first-use preflight stay EXCLUSIVE: they rewrite or
                // mirror shared state and must never race a live workload.
                if (traceStart) RuntimeExecutionTrace.mark(Stage.KERNEL_ADMISSION_CHECK)
                check(!hasOwnedWork()) { "Runtime already owns work" }
            } else if (request.operation == "shell.start") {
                // G07.3A: concurrent workloads are admitted by ROLE/CAPACITY in
                // LinuxRuntimeOperations (2 interactive + ONE shared Agent/run), but
                // never while an install or first-use preflight owns the UID.
                if (traceStart) RuntimeExecutionTrace.mark(Stage.KERNEL_ADMISSION_CHECK)
                check(operations?.hasExclusiveWork() != true) { "Runtime is preparing an exclusive lane" }
            }
            while (receipts.size >= 64) {
                val evict = receipts.entries.firstOrNull { it.value.optString("state") in setOf("completed", "failed") }
                    ?: error("Runtime control is busy")
                receipts.remove(evict.key)
            }
            receipts[request.id] = JSONObject().put("requestID", request.id).put("state", "queued")
            count.incrementAndGet() // reserve admission before another Binder call
            if (request.operation == "install.start") pendingInstallID.set(request.id)
            if (request.operation == "shell.start") pendingShellIDs.add(request.id)
            if (request.operation == RuntimeWire.PREFLIGHT) pendingPreflightID.set(request.id)
        }
        if (traceStart) RuntimeExecutionTrace.mark(Stage.KERNEL_QUEUED)
        try {
            executor.execute {
                if (traceStart) RuntimeExecutionTrace.mark(Stage.KERNEL_EXECUTOR_ENTER)
                update(request.id, JSONObject().put("state", "running"))
                try {
                    // A target-scoped stop for THIS admission is refused here
                    // exactly like the global fence; a sibling's stop is not
                    // in this set and never refuses this request.
                    check(!fence.isStopping && request.id !in targetStoppedIDs &&
                        (metadataOnly || cleanupLane || foregroundAllowed()))
                    // All native loading, disk work and real command admission
                    // happen on this owned IO thread, never on Binder/Main.
                    // G03-R3 first-start admission repair: the REAL owned-work
                    // release (finish() success) notifies the fence, so a stop
                    // that arrived while the pump thread was still draining
                    // converges at the actual completion instead of leaking a
                    // stale fence into the next admission.
                    val runtime = operations ?: LinuxRuntimeOperations(
                        context, onOwnedWorkReleased = { fence.settleAfterOwnedWorkReleased() },
                    ).also { operations = it }
                    if (traceStart) RuntimeExecutionTrace.mark(Stage.KERNEL_OPERATIONS_READY)
                    check(!fence.isStopping && request.id !in targetStoppedIDs &&
                        (metadataOnly || cleanupLane || foregroundAllowed()))
                    if (traceStart) RuntimeExecutionTrace.mark(Stage.KERNEL_EXECUTE_ENTER)
                    val result = runtime.execute(request, workspaceGrant) {
                        fence.isStopping || request.id in targetStoppedIDs ||
                            (!metadataOnly && !foregroundAllowed())
                    }
                    if (traceStart) RuntimeExecutionTrace.mark(Stage.KERNEL_RESULT_READY)
                    RuntimeWire.bounded(result.toString())
                    update(request.id, JSONObject().put("state", "completed").put("result", result))
                } catch (failure: Exception) {
                    if (traceStart) RuntimeExecutionTrace.mark(Stage.KERNEL_EXECUTE_EXCEPTION)
                    // Never reflect command lines, paths, output or native error
                    // descriptions into Android system logs or generic notices.
                    // The generic terminal skeleton stays byte-identical.
                    // G03-R3 failed-start receipt handoff (job-150dee8e1ed14ba1):
                    // ONLY the original workspace-bridge transaction may add
                    // its own bounded typed code plus its OWN journal-measured
                    // reverse-restore evidence to THIS kernel record, and only
                    // within the closed size bound. The host pump re-binds the
                    // identity to the exact grant session key, run and native
                    // epoch and publishes it on the ORIGINAL claim only after
                    // the real drain/quiescence and grant close; anything it
                    // cannot bind is dropped. No other exception type can
                    // reach these keys, and nothing here is a new reader,
                    // registry or authority: it is the same transient receipt.
                    val failed = JSONObject().put("state", "failed").put("code", "operation_failed")
                    (failure as? com.floe.android.workspacebridge.WorkspaceBridgeException)
                        ?.let { bridge ->
                            failedStartReceiptAddenda(bridge.code, bridge.recovery?.toString())?.let {
                                failed.put("failureCode", it.first)
                                failed.put("recovery", JSONObject(it.second))
                            }
                        }
                    update(request.id, failed)
                } finally {
                    pendingInstallID.compareAndSet(request.id, null)
                    pendingShellIDs.remove(request.id)
                    pendingPreflightID.compareAndSet(request.id, null)
                    // Only this request's own target note retires here; a
                    // sibling's target remains queued/idempotent.
                    targetStoppedIDs.remove(request.id)
                    count.decrementAndGet()
                    if (traceStart) RuntimeExecutionTrace.mark(Stage.KERNEL_REQUEST_RETURNED)
                    fence.settleAfterRequestDrained()
                    onChanged?.invoke(fence.isStopping)
                }
            }
        } catch (_: RejectedExecutionException) {
            pendingInstallID.compareAndSet(request.id, null)
            pendingShellIDs.remove(request.id)
            pendingPreflightID.compareAndSet(request.id, null)
            targetStoppedIDs.remove(request.id)
            count.decrementAndGet()
            synchronized(receipts) { receipts.remove(request.id) }
            throw IllegalStateException("Runtime control queue full")
        }
        onChanged?.invoke(false)
        return JSONObject().put("requestID", request.id).put("state", "queued")
    }

    /**
     * Stop entry. A NON-NULL request is one exact target-scoped cancellation
     * (`shell.cancel` / `install.cancel` / `workspace.preflight.cancel`) and
     * MUST NOT raise the global admission fence: closing TTY A may not refuse
     * B's queued input/resize or B's next start. A null request is the
     * ORIGINAL genuine global stop (service ownership loss / teardown): it
     * still raises the fence, coalesces the global drain and holds every
     * admission until the engine's real ownership reads empty.
     */
    fun requestStop(request: RuntimeWire.Request? = null) {
        if (request != null) {
            // The payload's own request id is the only id a session-less
            // cancellation may address. If that admission is still queued or
            // running, record the target so it refuses before operations or a
            // session exists; a settled/other id is never added.
            targetRequestID(request)?.let {
                if (isActiveAdmission(it)) targetStoppedIDs.add(it)
            }
            RuntimeExecutionTrace.mark(Stage.STOP_TARGET_ACCEPTED)
            stopExecutor.dispatch {
                try { operations?.stopOwnedWork(request) }
                catch (_: Exception) {
                    // Keep only this target's owned work/lease. A failed
                    // exact stop is not permission to widen to siblings.
                }
            }
            onChanged?.invoke(fence.isStopping)
            return
        }
        // ORIGINAL global rule: raise + single queue claim under the fence
        // monitor; exactly one queued global drain at a time; the tail clears
        // only while the engine provably owns nothing. The claim is global
        // only, so a queued target stop can never suppress a genuine global
        // drain (the old single claim did exactly that).
        val claimed = fence.beginStop()
        if (claimed) {
            RuntimeExecutionTrace.mark(Stage.STOP_GLOBAL_ACCEPTED)
            try {
                stopExecutor.dispatch {
                    try { operations?.stopOwnedWork(null) }
                    catch (_: Exception) {
                        // Keep owned work/leases and the stopping notice. An
                        // inability to stop is not permission to tear down
                        // their directories.
                    } finally {
                        fence.stopDrained()
                        onChanged?.invoke(fence.isStopping)
                    }
                }
            } catch (failure: IllegalStateException) {
                // No public shutdown path exists; if it is ever hit, the
                // drain was NOT accepted. Release only the queue claim, keep
                // the fence while real ownership remains, and surface the
                // honest rejection instead of running a second stop inline.
                fence.stopDrained()
                onChanged?.invoke(fence.isStopping)
                throw failure
            }
        }
        fence.settleAfterRaise()
        onChanged?.invoke(true)
    }

    val isStopping: Boolean get() = fence.isStopping

    /** Exact request id carried by a target-scoped cancellation, if any. */
    private fun targetRequestID(request: RuntimeWire.Request): String? = when (request.operation) {
        "shell.cancel", "install.cancel", RuntimeWire.PREFLIGHT_CANCEL ->
            request.payload.optString("requestID").takeIf { it.isNotEmpty() }
        else -> null
    }

    /** A receipt is an admission only while it is queued or executing. */
    private fun isActiveAdmission(id: String): Boolean = synchronized(receipts) {
        receipts[id]?.optString("state").let { it == "queued" || it == "running" }
    }

    /**
     * Every exact owned request id: queued/running work-admitting admissions
     * before the operations object exists, plus the operations' own pending,
     * live, retained-lease and deferred-owner ids. Permit associations retire
     * only when their ids are absent from this positive set.
     */
    fun ownedRequestIDs(): Set<String> {
        val ids = HashSet<String>()
        pendingInstallID.get()?.let(ids::add)
        pendingPreflightID.get()?.let(ids::add)
        ids.addAll(pendingShellIDs)
        operations?.ownedRequestIDs()?.let(ids::addAll)
        return ids
    }

    private fun update(id: String, value: JSONObject) {
        value.put("requestID", id)
        synchronized(receipts) { receipts[id] = value }
    }

    companion object {
        /** Real single-workload engine contract (single-slot executor plus
         *  the exclusive-start admission above). Ingested as a FACT only
         *  while the engine additionally reports itself idle. */
        const val WORKLOAD_CONTRACT = "floe-single-workload-v1"
        /** G07.3A real concurrent contract (2 interactive + 1 shared execution). */
        const val MULTI_WORKLOAD_CONTRACT = "floe-multi-workload-v2"

        /**
         * G03-R3 failed-start receipt handoff (job-150dee8e1ed14ba1): the
         * closed bounded form of the ORIGINAL workspace-bridge failure's
         * addenda. Purely local decision, no state: the typed token must be
         * printable ASCII <= 48 chars (no paths, no output, no line breaks),
         * and the transaction's own journal-measured recovery JSON must fit
         * the 4 KiB envelope ceiling. Anything else (including a missing
         * recovery object) returns null so the failed receipt stays the
         * byte-identical legacy skeleton. The host pump performs the full
         * closed-grammar parse, identity re-bind and drain-ordering before
         * publication; this is only the emitter-side size/type ceiling.
         */
        internal fun failedStartReceiptAddenda(
            code: String, recoveryJson: String?,
        ): Pair<String, String>? {
            val recovery = recoveryJson?.takeIf {
                it.toByteArray(Charsets.UTF_8).size <= FAILED_START_MAX_JSON_BYTES
            } ?: return null
            val token = code.takeIf {
                it.length in 1..48 && it.all { c -> c.code in 0x21..0x7e }
            } ?: return null
            return token to recovery
        }

        private const val FAILED_START_MAX_JSON_BYTES = 4_096
    }
}
