// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtimeipc

/**
 * The ONE closed mapping from a binder-handler failure to the bounded code
 * carried by the RuntimeWire failure envelope.
 *
 * Safety rule: a generic `IllegalStateException` is NEVER reported as
 * `runtime_not_ready` (the historical catch-all) because that code was used
 * as if it proved the request had not been admitted. A bind failure after the
 * kernel accepted the request would then let the host publish a fabricated
 * "nothing started" terminal. The uncertain code below names that ambiguity,
 * Receipt absence is not proof: records can be evicted or a request ID can
 * be reused. No generic exception proves that a request never ran.
 */
object RuntimeControlRefusal {
    /** The request's admission state cannot be proven from the failure alone. */
    const val UNCERTAIN = "runtime_state_unknown"

    /** Bounded closed code for `failure`, or null when it is not a refusal. */
    fun codeOf(failure: Exception): String? = when (failure) {
        // Ordered first: this is itself an IllegalStateException.
        is RuntimeOperationRefused -> failure.refusal.code
        is org.json.JSONException -> UNCERTAIN
        is IllegalArgumentException -> UNCERTAIN
        is IllegalStateException -> UNCERTAIN
        else -> null
    }
}
