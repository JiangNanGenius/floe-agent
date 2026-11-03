// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import java.util.concurrent.atomic.AtomicReference

/** Negative admission only. Original queued request/lease maps prove actual
 * work; clearing this fence can never release a lease or grant permission. */
internal class RuntimeEnvironmentTransactionFence {
    private val owner = AtomicReference<String?>()
    val active: Boolean get() = owner.get() != null
    internal val requestID: String? get() = owner.get()
    fun reserve(id: String) {
        require(id.isNotEmpty())
        check(owner.compareAndSet(null, id)) { "Environment transaction already owns admission" }
    }
    fun settleIfUnowned(actuallyOwned: (String) -> Boolean) {
        val id = owner.get() ?: return
        if (!actuallyOwned(id)) owner.compareAndSet(id, null)
    }
}
