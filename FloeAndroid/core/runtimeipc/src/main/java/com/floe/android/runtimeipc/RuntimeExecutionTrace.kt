// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtimeipc

import android.util.Log

/** Closed lifecycle events only: never commands, IDs, paths, payloads or errors.
 * Callers emit at finite start/finish boundaries, not per output byte/poll.
 * Diagnostic logging cannot change command admission or resource ownership. */
object RuntimeExecutionTrace {
    enum class Stage {
        PUMP_REGISTER,
        PUMP_OWNED,
        PUMP_GRANT,
        PUMP_GRANT_READY,
        PUMP_DISPATCH,
        PUMP_REQUEST_ACCEPTED,
        PUMP_RECEIPT_RETURNED,
        PUMP_SESSION_READY,
        PUMP_ADMISSION_REFUSED,
        PUMP_START_EXCEPTION,
        PUMP_WATCH_ENTER,
        PUMP_WATCH_COMPLETED,
        PUMP_WATCH_FAILED,
        PUMP_WATCH_WAITING,
        PUMP_WATCH_UNKNOWN,
        PUMP_WATCH_EXCEPTION,
        PUMP_FINISHED,
        PUMP_STOP_REQUEST,
        PUMP_STOP_SESSION,
        KERNEL_START_ENTER,
        KERNEL_ADMISSION_CHECK,
        KERNEL_QUEUED,
        KERNEL_EXECUTOR_ENTER,
        KERNEL_OPERATIONS_READY,
        KERNEL_EXECUTE_ENTER,
        KERNEL_RESULT_READY,
        KERNEL_EXECUTE_EXCEPTION,
        KERNEL_REQUEST_RETURNED,
        OPS_START_ENTER,
        OPS_RECOVER,
        OPS_CONFIGURE,
        OPS_ACQUIRE,
        OPS_ACQUIRED,
        OPS_MATERIALIZE,
        OPS_MATERIALIZED,
        OPS_IMPORT,
        OPS_IMPORTED,
        WORKSPACE_IMPORT_FIRST_CHANGE_APPLIED,
        WORKSPACE_IMPORT_PRIOR_RESTORED,
        WORKSPACE_IMPORT_NEW_REVERTED,
        WORKSPACE_IMPORT_RESTORE_INCOMPLETE,
        OPS_BUILD_SPEC,
        OPS_SPEC_READY,
        OPS_SPAWN,
        OPS_SPAWN_ACCEPTED,
        OPS_BIND_STARTED,
        OPS_PUMP_ENTER,
        OPS_PUMP_ENDED,
        OPS_FINISH_RETURNED,
        OPS_START_EXCEPTION,
        OPS_PUMP_EXCEPTION,
        // G07.3A multi-session stop/permit boundary. ADDITIVE enum-only marks:
        // no id, command, path, binder token or payload ever reaches the log.
        // They distinguish a target-scoped stop from a genuine global one and
        // show whether a foreground permit was retired by real settlement or
        // lost while its work was still live.
        STOP_TARGET_ACCEPTED,
        STOP_GLOBAL_ACCEPTED,
        STOP_GLOBAL_PERMIT_LOSS,
        STOP_GLOBAL_SERVICE_LOSS,
        PERMIT_RETIRED,
    }

    fun mark(stage: Stage) {
        try { Log.i("FloeLinuxStart", stage.name) }
        catch (_: Exception) { /* Logging is observational, including JVM hosts. */ }
    }

    /**
     * Bounded cold-materialization progress: counts/durations only, never a
     * path, ID, command or payload. Emitted at start, every 1024 copied
     * entries, before the durability barrier, and after publication. This is
     * the diagnostic seam that distinguishes copy latency from a barrier or
     * publication stall; it cannot change admission or ownership.
     */
    fun materializeProgress(phase: String, entries: Long, bytes: Long, elapsedMillis: Long) {
        try {
            Log.i("FloeLinuxStart",
                "OPS_MATERIALIZE_PROGRESS phase=$phase entries=$entries bytes=$bytes elapsedMs=$elapsedMillis")
        } catch (_: Exception) { /* Logging is observational, including JVM hosts. */ }
    }
}
