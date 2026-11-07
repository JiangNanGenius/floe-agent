// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.cadcomponent

import android.content.Context
import com.floe.android.host.components.ComponentDirectoryCommit
import java.io.File

/** Accounting and explicit reclaim only. Old verified files remain recoverable
 * across the upgrade; only the signed split satisfies new preview admission.
 * Reuse the existing no-link filesystem transaction helper so previous and
 * partial directories are accounted for and removed with the same rules. */
internal object LegacyCadCache {
    const val LEGACY_ROOT = "PreviewComponents"
    const val LEGACY_COMPONENT = "cad-v1"

    private fun store(context: Context) = ComponentDirectoryCommit(
        File(context.filesDir, LEGACY_ROOT), LEGACY_COMPONENT)

    fun cacheBytes(context: Context): Long = store(context).storedBytes()

    fun clear(context: Context): Boolean = runCatching {
        val cache = store(context)
        cache.uninstall()
        cache.storedBytes() == 0L
    }.getOrDefault(false)
}
