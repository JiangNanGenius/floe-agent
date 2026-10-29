// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

import android.Manifest
import android.content.ComponentName
import android.content.pm.PackageManager
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertFalse
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Play-channel exclusion contract (plan P6.7 / user requirement): the Play
 * product must physically exclude the GitHub updater — no install permission,
 * no update receiver/service, no entry point. Updates arrive through Google
 * Play only.
 */
@RunWith(AndroidJUnit4::class)
class AppUpdateAbsentInstrumentedTest {

    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    @Test
    fun playChannelHasNoInstallPermission() {
        val info = context.packageManager.getPackageInfo(
            context.packageName,
            PackageManager.GET_PERMISSIONS,
        )
        val permissions = info.requestedPermissions?.toList() ?: emptyList()
        assertFalse(permissions.contains(Manifest.permission.REQUEST_INSTALL_PACKAGES))
    }

    @Test
    fun playChannelDeclaresNoUpdateComponents() {
        val receiver = ComponentName(
            context.packageName,
            "com.floe.android.host.update.AppUpdateInstallReceiver",
        )
        val service = ComponentName(
            context.packageName,
            "com.floe.android.host.update.AppUpdateDownloadService",
        )
        try {
            context.packageManager.getReceiverInfo(receiver, 0)
            fail("Play package declares the GitHub update receiver")
        } catch (_: PackageManager.NameNotFoundException) {
            // expected: physically absent
        }
        try {
            context.packageManager.getServiceInfo(service, 0)
            fail("Play package declares the GitHub download service")
        } catch (_: PackageManager.NameNotFoundException) {
            // expected: physically absent
        }
    }

    @Test
    fun playChannelReportsUpdaterUnavailable() {
        assertFalse(AppUpdateFeature.available)
    }
}
