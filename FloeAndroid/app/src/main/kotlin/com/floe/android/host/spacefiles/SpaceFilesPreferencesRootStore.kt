// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.spacefiles

import android.content.Context

/** App-private metadata store. It holds no credential and confers no access. */
internal class SpaceFilesPreferencesRootStore(context: Context) : SpaceFilesRootStore {
    private val preferences = context.applicationContext
        .getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    override fun read(): List<SpaceFilesRoot> =
        SpaceFilesRootCodec.decode(preferences.getString(KEY_ROOTS, null))

    override fun write(roots: List<SpaceFilesRoot>) {
        preferences.edit().putString(KEY_ROOTS, SpaceFilesRootCodec.encode(roots)).apply()
    }

    private companion object {
        const val PREFERENCES_NAME = "floe_space_files"
        const val KEY_ROOTS = "roots.v1"
    }
}
