// SPDX-License-Identifier: MPL-2.0
package com.floe.android.credentials.debug

/**
 * Instrumentation-test fault injection for [DebugSealedEnrollment].
 *
 * Compiled into debug variants only. It never changes credential encryption or
 * release behaviour; it only simulates a cleanup failure after a successful
 * credential write so tests can prove that the durable consumption marker
 * blocks replay and cannot overwrite a later replacement.
 */
object DebugSealedEnrollmentTestHooks {
    @Volatile
    var failNextSessionCleanup: Boolean = false

    internal fun shouldFailSessionCleanup(): Boolean {
        if (!failNextSessionCleanup) return false
        failNextSessionCleanup = false
        return true
    }
}
