// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.optionalsplit

import android.content.Context
import com.floe.android.host.update.SharedPrefsUpdateStore

/** Persist session ownership under one process-wide admission lock. System
 * PackageInstaller still validates and commits every package atomically. */
internal object PackageInstallAdmission {
    val lock = Any()
    private val stores = listOf("office_component_install", "cad_component_install")

    fun optionalSessions(context: Context): Set<Int> = stores.mapNotNull { name ->
        context.getSharedPreferences(name, Context.MODE_PRIVATE)
            .getInt("session", -1).takeIf { it >= 0 }
    }.toSet()

    fun requireComponentSlot(context: Context) {
        check(SharedPrefsUpdateStore(context).pendingInstallJson == null) { "app_update_pending" }
        check(optionalSessions(context).isEmpty()) { "component_install_pending" }
    }
}
