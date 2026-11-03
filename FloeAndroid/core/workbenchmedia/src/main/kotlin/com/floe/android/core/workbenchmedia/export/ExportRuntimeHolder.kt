// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.export

/**
 * The mediaProcessing service and the App-DI session must share exactly one
 * process-scoped export registry. A second session is refused by the factory;
 * the service never creates a fallback registry.
 */
internal object ExportRuntimeHolder {
    @Volatile private var runtime: ExportRuntime? = null

    fun install(candidate: ExportRuntime): Boolean = synchronized(this) {
        if (runtime != null) return false
        runtime = candidate
        true
    }

    fun current(): ExportRuntime? = runtime

    /**
     * Releases the process registry only when [candidate] is still the installed
     * owner. Returns true after the registry is actually empty; a foreign
     * candidate never clears another session's registry.
     */
    fun clear(candidate: ExportRuntime): Boolean = synchronized(this) {
        if (runtime === candidate) {
            runtime = null
            true
        } else {
            false
        }
    }
}
