// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import com.floe.android.runtimeipc.RuntimePackages
import com.floe.android.runtimeipc.RuntimePeerVerifier

/** Explicit Core settings action for THIS UID's LAN permission; never starts work. */
class RuntimeAccessActivity : Activity() {
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        try { RuntimePeerVerifier(this).verifyPeer(RuntimePackages.forRuntime(packageName).core) }
        catch (_: SecurityException) { finish(); return }
        if (Build.VERSION.SDK_INT < 37 || checkSelfPermission(PERMISSION) == PackageManager.PERMISSION_GRANTED) {
            finish(); return
        }
        if (state != null) return // the framework owns the existing permission request
        val history = getSharedPreferences("runtime-access", MODE_PRIVATE)
        if (history.getBoolean("lan-requested", false) && !shouldShowRequestPermissionRationale(PERMISSION)) {
            startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                android.net.Uri.parse("package:$packageName")))
            finish()
        } else {
            history.edit().putBoolean("lan-requested", true).apply()
            requestPermissions(arrayOf(PERMISSION), 1)
        }
    }
    override fun onRequestPermissionsResult(code: Int, permissions: Array<out String>, grants: IntArray) {
        super.onRequestPermissionsResult(code, permissions, grants)
        if (code == 1) finish()
    }
    companion object { const val PERMISSION = "android.permission.ACCESS_LOCAL_NETWORK" }
}
