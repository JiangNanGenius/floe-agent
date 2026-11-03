// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtimeipc

/** Closed pre-admission states only; no command/path/provider text crosses IPC. */
enum class RuntimeAdmissionRefusal(val code: String) {
    ENVIRONMENT_TRANSACTION_BUSY("environment_transaction_busy"),
    ENVIRONMENT_TRANSACTION_REQUIRES_IDLE("environment_transaction_requires_idle"),
}
class RuntimeOperationRefused(val refusal: RuntimeAdmissionRefusal) : IllegalStateException(refusal.code)
