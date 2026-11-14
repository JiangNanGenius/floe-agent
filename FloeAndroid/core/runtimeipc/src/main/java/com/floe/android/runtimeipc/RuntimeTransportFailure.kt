// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtimeipc

/**
 * A REAL transport loss on an established runtime channel: the binder is gone,
 * `transact` failed, or the peer's reply could not be read/verified as the
 * bounded v1 frame.
 *
 * It is deliberately distinct from a well-formed `{"ok":false,"code":...}`
 * replay: that refusal crossed the wire, the binder is still healthy, and the
 * connection must be REUSED (reopening it per refusal is exactly the
 * bind/link churn that overflowed the JNI global reference table on
 * Full 13). Callers may drop and reopen a channel only for this type.
 *
 * Extends [IllegalStateException] so every pre-existing `catch (Exception)` /
 * `catch (IllegalStateException)` path keeps its previous behavior.
 */
class RuntimeTransportFailure(
    message: String,
    cause: Throwable? = null,
) : IllegalStateException(message, cause)
