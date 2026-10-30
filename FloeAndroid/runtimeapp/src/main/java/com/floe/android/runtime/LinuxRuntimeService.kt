// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import android.app.Service
import android.content.Intent
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import com.floe.android.runtimeipc.RuntimeControlBinder
import com.floe.android.runtimeipc.RuntimeExecutionTrace
import com.floe.android.runtimeipc.RuntimeExecutionTrace.Stage
import com.floe.android.runtimeipc.RuntimeForegroundPermit
import com.floe.android.runtimeipc.RuntimePackages
import com.floe.android.runtimeipc.RuntimePeerVerifier
import com.floe.android.runtimeipc.RuntimeWire
import java.util.IdentityHashMap

/** Bound to Core's real foreground work. Intents never admit or restore commands. */
class LinuxRuntimeService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private val kernel get() = (application as RuntimeApplication).kernel
    private lateinit var control: RuntimeControlBinder

    /**
     * ONE retained foreground permit per admitted work operation, with the
     * exact admitted `RuntimeWire.Request.id` set it authorized. This is
     * lifecycle ownership metadata only, never a new grant or approval. The
     * exact ids are what let a normally settled participant (A) be pruned
     * instead of being mistaken for a lost permit that would stop B.
     */
    private class RetainedPermit {
        val requestIDs: MutableSet<String> = LinkedHashSet()
    }

    private val permits = IdentityHashMap<IBinder, RetainedPermit>()

    private val inspectOwnership = object : Runnable {
        override fun run() {
            // Snapshot tokens/ids under the map lock; the Binder isActive call
            // MUST run outside it (the permit implementation is Core-owned).
            val snapshot = synchronized(permits) {
                permits.entries.map { it.key to it.value.requestIDs.toSet() }
            }
            if (snapshot.isNotEmpty()) {
                val views = snapshot.map { (permit, ids) ->
                    ForegroundPermitOwnership.PermitView(
                        token = permit,
                        requestIDs = ids,
                        active = RuntimeForegroundPermit.isActive(this@LinuxRuntimeService, permit),
                    )
                }
                // Positive ownership facts from the real runtime state:
                // pending start, retained lease/failed lease, live
                // Running.startID and a deferred export's OWNER start id.
                val owned = kernel.ownedRequestIDs()
                val plan = ForegroundPermitOwnership.plan(views, owned)
                for ((permit, ids) in snapshot) {
                    val live = ids.intersect(owned)
                    if (plan.retire.any { it === permit }) {
                        // Retire ONLY if the association did not gain a newer
                        // admitted id while this decision was being made.
                        if (retireIfUnchanged(permit, ids)) {
                            // Stage-only diagnosis: retired by REAL settlement,
                            // never by permit inactivity or an elapsed budget.
                            RuntimeExecutionTrace.mark(Stage.PERMIT_RETIRED)
                        }
                    } else {
                        // A permit that still owns exact work keeps its full
                        // association; only an actually settled id is dropped
                        // from a mixed association.
                        val settled = ids - live
                        synchronized(permits) { permits[permit]?.requestIDs?.removeAll(settled) }
                    }
                }
                if (plan.activePermitLoss) {
                    // ORIGINAL fail-closed global stop: an inactive/dead
                    // permit still owns exact work. A normally settled
                    // participant never reaches this branch (retired above).
                    // A retained fence still re-requests on the next poll; the
                    // kernel coalesces a queued global drain and re-drains once
                    // an earlier drain completed with real ownership left.
                    if (!kernel.isStopping) {
                        RuntimeExecutionTrace.mark(Stage.STOP_GLOBAL_PERMIT_LOSS)
                    }
                    kernel.requestStop()
                }
            }
            // Settled associations were retired by the exact-id pass above.
            // An unknown/new association is never cleared here: a concurrent
            // admission keeps it and the next callback examines it again.
            if (kernel.hasOwnedWork()) handler.postDelayed(this, 1_000)
        }
    }

    override fun onCreate() {
        super.onCreate()
        RuntimePeerVerifier(this).verifyPeer(RuntimePackages.forRuntime(packageName).core)
        control = RuntimeControlBinder(this) { request, permit, workspaceGrant ->
            // R3: the first-use NON-EXECUTING workspace preflight is real
            // foreground-owned work (file IO under an owned grant), so its
            // permit is retained exactly like install/shell admission: loss
            // of the owning foreground stops it, and ownership survives the
            // stop request until the helper actually settles.
            val admitsWork = request.operation == "install.start" || request.operation == "shell.start" ||
                request.operation == RuntimeWire.PREFLIGHT
            if (admitsWork) {
                check(RuntimeForegroundPermit.isActive(this, permit)) { "Foreground operation is not active" }
            }
            val response = kernel.exchange(request, workspaceGrant) { RuntimeForegroundPermit.isActive(this, permit) }
            if (admitsWork) try { retainPermit(checkNotNull(permit), request.id) }
            catch (_: Exception) {
                // Admission exists but its exact foreground ownership could
                // not be recorded: the ORIGINAL fail-closed global stop is
                // retained (a lost active permit is never treated as a
                // settled participant).
                RuntimeExecutionTrace.mark(Stage.STOP_GLOBAL_PERMIT_LOSS)
                kernel.requestStop()
            }
            response
        }
        kernel.onChanged = { _ -> handler.post {
            handler.removeCallbacks(inspectOwnership)
            // A service/binding/token callback is a stop request, never exit
            // proof. The exact-id pass retires only actually settled work, so
            // an idle callback never clears a concurrently admitted permit.
            handler.post(inspectOwnership)
        } }
    }

    /**
     * Associate the admitted request with THIS permit. The exact id set lets
     * retirement wait for the runtime's own ownership to settle.
     */
    private fun retainPermit(permit: IBinder, requestID: String) {
        synchronized(permits) {
            permits.getOrPut(permit) { RetainedPermit() }.requestIDs.add(requestID)
        }
        // Examine the fresh exact association even if the admission settles
        // very quickly; a settled entry is retired without any stop.
        handler.removeCallbacks(inspectOwnership)
        handler.post(inspectOwnership)
    }

    /** Retire exactly the snapshot association; a concurrently added newer
     *  admitted id makes the association change and defers retirement. */
    private fun retireIfUnchanged(permit: IBinder, expected: Set<String>): Boolean =
        synchronized(permits) {
            val current = permits[permit] ?: return@synchronized true
            if (current.requestIDs != expected) return@synchronized false
            permits.remove(permit)
            true
        }

    private fun clearPermits() {
        synchronized(permits) { permits.clear() }
    }

    override fun onBind(intent: Intent?): IBinder = control
    override fun onUnbind(intent: Intent?): Boolean {
        // The LAST client binding is gone: this is a genuine service-ownership
        // loss, so the ORIGINAL global stop and fence remain correct.
        if (kernel.hasOwnedWork()) {
            RuntimeExecutionTrace.mark(Stage.STOP_GLOBAL_SERVICE_LOSS)
            kernel.requestStop()
        }
        return false
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        stopSelf(startId)
        return START_NOT_STICKY
    }
    override fun onDestroy() {
        handler.removeCallbacks(inspectOwnership)
        kernel.onChanged = null
        // Component teardown is genuine global ownership loss: the fence and
        // every live workload stop until real quiescence.
        RuntimeExecutionTrace.mark(Stage.STOP_GLOBAL_SERVICE_LOSS)
        kernel.requestStop()
        clearPermits()
        super.onDestroy()
    }
}
