// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officecomponent

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

/** Scoped data-sync lifetime, never an idle/background keep-alive. */
class OfficeComponentDownloadService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, getString(R.string.office_module_title), NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 9492, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val cancel = PendingIntent.getBroadcast(this, 9493, Intent(this, OfficeComponentStopReceiver::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        startForeground(9491, NotificationCompat.Builder(this, CHANNEL).setSmallIcon(applicationInfo.icon)
            .setContentTitle(getString(R.string.office_module_title))
            .setContentText(getString(R.string.office_component_downloading)).setContentIntent(open)
            .setOngoing(true).setOnlyAlertOnce(true).setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .addAction(0, getString(R.string.cancel), cancel).build())
        return START_NOT_STICKY
    }
    companion object { private const val CHANNEL = "office_component_download" }
}
class OfficeComponentStopReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        (context.applicationContext as? FloeApplication)?.officeComponent?.cancel()
    }
}
