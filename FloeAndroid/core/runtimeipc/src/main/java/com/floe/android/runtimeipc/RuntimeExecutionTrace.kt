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
    }

    fun mark(stage: Stage) {
        try { Log.i("FloeLinuxStart", stage.name) }
        catch (_: Exception) { /* Logging is observational, including JVM hosts. */ }
    }
}
