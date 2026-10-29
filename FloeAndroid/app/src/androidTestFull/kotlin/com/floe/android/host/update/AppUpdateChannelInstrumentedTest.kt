// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

import android.Manifest
import android.content.ComponentName
import android.content.pm.PackageManager
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Full-channel packaging contract: the GitHub APK declares the install
 * permission (also required by the pre-existing bundled runtime installer) and
 * registers the app-self-update receiver/service. Main runs this once in the
 * combined Alpha14 verification batch.
 */
@RunWith(AndroidJUnit4::class)
class AppUpdateChannelInstrumentedTest {

    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    @Test
    fun fullChannelDeclaresInstallPermission() {
        val info = context.packageManager.getPackageInfo(
            context.packageName,
            PackageManager.GET_PERMISSIONS,
        )
        val permissions = info.requestedPermissions?.toList() ?: emptyList()
        assertTrue(permissions.contains(Manifest.permission.REQUEST_INSTALL_PACKAGES))
    }

    @Test
    fun fullChannelRegistersUpdateReceiverAndService() {
        val receiver = ComponentName(context.packageName, AppUpdateInstallReceiver::class.java.name)
        val service = ComponentName(context.packageName, AppUpdateDownloadService::class.java.name)
        assertNotNull(context.packageManager.getReceiverInfo(receiver, 0))
        assertNotNull(context.packageManager.getServiceInfo(service, 0))
    }

    @Test
    fun fullChannelExposesUpdaterCapability() {
        assertTrue(AppUpdateFeature.available)
    }
}
