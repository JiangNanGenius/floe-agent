// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

/** Evaluate the transform against the current value while holding the shared lock. */
internal fun <T> updateSettingsAtomically(
    lock: Any, read: () -> T, write: (T) -> Unit, transform: (T) -> T,
) = synchronized(lock) { write(transform(read())) }
