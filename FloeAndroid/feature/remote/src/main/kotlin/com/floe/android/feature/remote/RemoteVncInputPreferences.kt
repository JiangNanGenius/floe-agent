// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.remote

import android.content.Context

/** Device presentation preference only; contains no remote host or task data. */
internal class RemoteVncInputPreferences(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences("floe_vnc_input", Context.MODE_PRIVATE)
    fun load(): VncInputMode = VncInputMode.restore(preferences.getString("mode", null))
    fun save(mode: VncInputMode) { preferences.edit().putString("mode", mode.value).apply() }
}
