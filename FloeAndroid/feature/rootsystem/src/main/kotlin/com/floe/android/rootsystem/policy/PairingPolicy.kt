// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.policy

/**
 * Pairing input and lifecycle policy. Pairing is never inferred from App start:
 * it happens only after an explicit user action, with exactly six ASCII digits
 * held in RAM. Forgetting pairing trust is separate from stopping the live
 * service and from revoking task grants.
 */
object PairingPolicy {

    const val CODE_LENGTH = 6

    fun sanitize(input: String): String =
        input.filter { it in '0'..'9' }.take(CODE_LENGTH)

    fun canSubmit(input: String): Boolean =
        input.length == CODE_LENGTH && input.all { it in '0'..'9' }

    fun sanitizeToCharArray(input: String): CharArray = sanitize(input).toCharArray()

    fun wipe(code: CharArray) {
        code.fill('\u0000')
    }

    fun shouldPairOnStart(): Boolean = false

    fun statusAfterStart(hasTrust: Boolean, serviceAlive: Boolean): String = when {
        serviceAlive -> "service_alive"
        hasTrust -> "paired"
        else -> "pair_required"
    }

    fun statusAfterForget(serviceAlive: Boolean): String =
        if (serviceAlive) "service_alive_pairing_cleared" else "pair_required"
}
