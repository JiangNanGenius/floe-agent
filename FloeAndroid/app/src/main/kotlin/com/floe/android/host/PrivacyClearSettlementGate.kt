// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** One clear owns terminal publication until all of its mutations have finished. */
internal class PrivacyClearSettlementGate {
    class Ticket internal constructor() {
        internal val finishing = AtomicBoolean(false)
    }

    private val active = AtomicReference<Ticket?>(null)

    fun acquire(): Ticket? {
        val ticket = Ticket()
        return if (active.compareAndSet(null, ticket)) ticket else null
    }

    fun finish(ticket: Ticket, publish: () -> Unit): Boolean {
        if (active.get() !== ticket || !ticket.finishing.compareAndSet(false, true)) {
            return false
        }
        try {
            publish()
        } finally {
            active.compareAndSet(ticket, null)
        }
        return true
    }
}
