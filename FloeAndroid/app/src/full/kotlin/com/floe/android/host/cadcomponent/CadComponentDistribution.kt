// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.cadcomponent

import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.floe.android.FloeApplication
import com.floe.android.MainActivity
import com.floe.android.R
import com.floe.android.host.optionalsplit.FullOptionalSplitBackend
import com.floe.android.host.optionalsplit.OptionalComponentState
import com.floe.android.host.optionalsplit.OptionalComponentSpec
import com.floe.android.host.optionalsplit.OptionalSplitInstallResults
import kotlinx.coroutines.CoroutineScope

/** GitHub distribution binding for the CAD preview split. The download,
 * verification and PackageInstaller session live in the shared optional-split
 * backend parameterized by this spec, never in a CAD-parallel framework. */
internal object CadComponentDistribution {
    internal val SPEC = OptionalComponentSpec(
        module = CadComponentController.MODULE,
        prefsName = "cad_component_install",
        stagingDir = "CadComponent",
        assetName = { CadComponentController.assetName() },
        resultAction = "com.floe.cad.COMPONENT_INSTALL_RESULT",
        resultReceiver = CadComponentInstallReceiver::class.java,
        downloadService = CadComponentDownloadService::class.java,
        installed = { CadComponentController.installed(it) },
    )

    fun installed(context: Context): Boolean = runCatching {
        CadComponentController.MODULE in context.packageManager
            .getPackageInfo(context.packageName, 0).splitNames.orEmpty()
    }.getOrDefault(false)

    fun create(context: Context, scope: CoroutineScope,
        publish: (CadComponentState) -> Unit, refresh: () -> Unit,
        canRemove: () -> Boolean): CadComponentBackend =
        FullOptionalSplitBackend(context, SPEC, scope, publish, refresh, canRemove)
}

class CadComponentInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val app = context.applicationContext as? FloeApplication ?: return
        OptionalSplitInstallResults.dispatch(
            CadComponentDistribution.SPEC, app.cadComponent::onInstallResult, intent)
    }
}

/** Scoped data-sync lifetime for the CAD component download, never an idle
 * keep-alive. Mirrors the Office download service notification contract. */
class CadComponentDownloadService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(
            CHANNEL, getString(R.string.cad_module_title), NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 9496,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val cancel = PendingIntent.getBroadcast(this, 9497,
            Intent(this, CadComponentStopReceiver::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        startForeground(9495, NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(getString(R.string.cad_module_title))
            .setContentText(getString(R.string.cad_component_downloading))
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .addAction(0, getString(R.string.cancel), cancel)
            .build())
        return START_NOT_STICKY
    }

    companion object {
        private const val CHANNEL = "cad_component_download"
    }
}

class CadComponentStopReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        (context.applicationContext as? FloeApplication)?.cadComponent?.cancel()
    }
}
