// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.server

import com.floe.android.contracts.SensitiveUiLabelBaseline
import com.floe.android.contracts.SensitiveUiLabelIdentity

/** In-memory hashes of previously observed button labels and direct text children. */
internal object UiSensitiveBaseline {
    data class Key(
        val packageName: String?, val windowId: Int, val displayId: Int,
        val path: List<Int>, val className: String, val viewId: String?,
    )

    data class Entry(val fingerprint: String, val safeParent: Key? = null)

    private fun key(value: SensitiveUiLabelIdentity) = Key(
        value.packageName, value.windowId, value.displayId, value.path, value.className, value.viewId,
    )

    fun fromSnapshot(values: List<SensitiveUiLabelBaseline>): Map<Key, Entry> =
        values.associate { key(it.identity) to Entry(it.digest, it.safeParent?.let(::key)) }
}
