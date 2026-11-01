// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.ticket

import java.util.concurrent.atomic.AtomicBoolean

/**
 * Exactly-once terminal settlement guard. The first caller wins; duplicate
 * completion/cancel/error paths are refused without rewriting a receipt.
 */
internal class SettlementGate {
    private val settled = AtomicBoolean(false)

    fun trySettle(): Boolean = settled.compareAndSet(false, true)

    fun isSettled(): Boolean = settled.get()
}
