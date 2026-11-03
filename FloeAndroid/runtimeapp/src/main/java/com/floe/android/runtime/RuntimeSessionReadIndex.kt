// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import java.util.concurrent.ConcurrentHashMap

/** Output remains readable while a stopped process exports its workspace.
 * These entries do not participate in execution admission or quiescence.
 * Their original held lease still owns the real release obligation. */
internal class RuntimeSessionReadIndex<T : Any>(
    private val running: Map<String, T>,
    private val completed: Map<String, T>,
) {
    private val settling = ConcurrentHashMap<String, T>()

    fun find(id: String): T? = running[id] ?: settling[id] ?: completed[id]

    /** Publish BEFORE removing the process from the running census. */
    fun beginSettlement(id: String, owner: T) {
        check(running[id] === owner || settling[id] === owner)
        val prior = settling.putIfAbsent(id, owner)
        check(prior == null || prior === owner)
    }

    /** Called only AFTER the real completion has been published. */
    fun endSettlement(id: String, owner: T) {
        settling.remove(id, owner)
    }
}
