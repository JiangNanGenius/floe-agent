// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtimeipc

/**
 * Closed pre-admission states only; no command/path/provider text crosses IPC.
 *
 * Entries describe concrete runtime admission checks. The code alone does
 * not prove that an earlier request with the same identity was never admitted:
 * callers must use the authoritative request and lease settlement protocol.
 * Generic failures remain separate from these diagnostic codes.
 */
enum class RuntimeAdmissionRefusal(val code: String) {
    ENVIRONMENT_TRANSACTION_BUSY("environment_transaction_busy"),
    ENVIRONMENT_TRANSACTION_REQUIRES_IDLE("environment_transaction_requires_idle"),

    /** An environment transaction start must use the one-shot agent role. */
    ENVIRONMENT_TRANSACTION_REQUIRES_ONESHOT("environment_transaction_requires_oneshot"),

    /** The Core-issued foreground operation permit is no longer active. */
    FOREGROUND_INACTIVE("runtime_foreground_inactive"),

    /** The kernel's own foreground-ownership predicate refused the request. */
    FOREGROUND_REQUIRED("runtime_foreground_required"),

    /** A shell/stdio start arrived without the owned workspace grant binder. */
    WORKSPACE_GRANT_MISSING("runtime_workspace_grant_missing"),

    /** A real stop drain is in progress: admission is fenced, not crashed. */
    STOPPING("runtime_stopping"),

    /** The single control executor is inside the typed storage-maintenance lane. */
    STORAGE_MAINTENANCE("runtime_storage_maintenance"),

    /** Install/first-use preflight requires whole-runtime idleness. */
    ALREADY_OWNS_WORK("runtime_already_owns_work"),

    /** An install/first-use preflight is preparing and holds the exclusive lane. */
    EXCLUSIVE_LANE("runtime_exclusive_lane"),

    /** The bounded control receipt table is full of live records. */
    CONTROL_BUSY("runtime_control_busy"),

    /** The bounded control executor queue refused the request before admission. */
    CONTROL_QUEUE_FULL("runtime_control_queue_full"),
}
class RuntimeOperationRefused(val refusal: RuntimeAdmissionRefusal) : IllegalStateException(refusal.code)
