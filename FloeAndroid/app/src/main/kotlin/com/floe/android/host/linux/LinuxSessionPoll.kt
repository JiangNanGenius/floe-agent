// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** A poll must not use the live connection while settlement closes it.
 * Retired reads still fetch the runtime's actual output/cursor; a terminal
 * ownership proof alone is never substituted for command output. */
internal suspend fun <T> pollWithSettlement(
    settlement: Mutex,
    isSettled: () -> Boolean,
    live: suspend () -> T,
    retired: suspend () -> T,
): T = settlement.withLock {
    if (isSettled()) retired() else live()
}
