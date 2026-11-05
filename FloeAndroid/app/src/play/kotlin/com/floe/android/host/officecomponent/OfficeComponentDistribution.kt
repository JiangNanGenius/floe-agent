// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officecomponent

import android.app.Activity
import android.content.Context
import com.google.android.play.core.splitcompat.SplitCompat
import com.google.android.play.core.splitinstall.SplitInstallManagerFactory
import com.google.android.play.core.splitinstall.SplitInstallRequest
import com.google.android.play.core.splitinstall.SplitInstallSessionState
import com.google.android.play.core.splitinstall.SplitInstallStateUpdatedListener
import com.google.android.play.core.splitinstall.model.SplitInstallSessionStatus
import kotlinx.coroutines.CoroutineScope

/** Play requests only the declared feature; no APK download or package-install permission. */
internal object OfficeComponentDistribution {
    fun installed(context: Context): Boolean = OfficeComponentController.MODULE in
        SplitInstallManagerFactory.create(context).installedModules
    fun create(context: Context, scope: CoroutineScope, publish: (OfficeComponentState) -> Unit,
        refresh: () -> Unit, canRemove: () -> Boolean): OfficeComponentBackend =
        PlayOfficeComponentBackend(context, publish, refresh, canRemove)
}

private class PlayOfficeComponentBackend(private val context: Context,
    private val publish: (OfficeComponentState) -> Unit, private val refresh: () -> Unit,
    private val canRemove: () -> Boolean) : OfficeComponentBackend {
    private val manager = SplitInstallManagerFactory.create(context)
    private val prefs = context.getSharedPreferences("office_play_delivery", Context.MODE_PRIVATE)
    private var sessionID = prefs.getInt("session", 0)
    private var confirmation: SplitInstallSessionState? = null
    private var issuedConfirmation = 0
    private val listener = SplitInstallStateUpdatedListener { value -> onState(value) }
    init {
        manager.registerListener(listener)
        if (prefs.getBoolean("remove_pending", false) && OfficeComponentDistribution.installed(context))
            publish(OfficeComponentState("remove_pending", removable = false))
    }
    override fun install() {
        manager.startInstall(SplitInstallRequest.newBuilder().addModule(OfficeComponentController.MODULE).build())
            .addOnSuccessListener { id ->
                sessionID = id
                if (id == 0 && OfficeComponentDistribution.installed(context)) { refresh(); return@addOnSuccessListener }
                prefs.edit().putInt("session", id).apply()
                manager.getSessionState(id).addOnSuccessListener { onState(it) }
            }.addOnFailureListener { publish(OfficeComponentState("failed", failure = "play_delivery_failed")) }
        publish(OfficeComponentState("downloading"))
    }
    private fun onState(value: SplitInstallSessionState) {
        if (value.sessionId() != sessionID || OfficeComponentController.MODULE !in value.moduleNames()) return
        when (value.status()) {
            SplitInstallSessionStatus.INSTALLED -> {
                SplitCompat.install(context)
                prefs.edit().remove("session").remove("remove_pending").apply()
                confirmation = null
                if (OfficeComponentDistribution.installed(context)) {
                    publish(OfficeComponentState("installed")); refresh()
                } else publish(OfficeComponentState("failed", failure = "play_install_unconfirmed"))
            }
            SplitInstallSessionStatus.REQUIRES_USER_CONFIRMATION -> {
                confirmation = value; publish(OfficeComponentState("play_confirm"))
            }
            SplitInstallSessionStatus.DOWNLOADING,
            SplitInstallSessionStatus.PENDING -> publish(OfficeComponentState("downloading", value.bytesDownloaded(), value.totalBytesToDownload()))
            SplitInstallSessionStatus.INSTALLING,
            SplitInstallSessionStatus.DOWNLOADED -> publish(OfficeComponentState("installing", value.bytesDownloaded(), value.totalBytesToDownload()))
            SplitInstallSessionStatus.FAILED -> {
                prefs.edit().remove("session").apply(); publish(OfficeComponentState("failed", failure = "play_delivery_${value.errorCode()}"))
            }
            SplitInstallSessionStatus.CANCELED -> {
                prefs.edit().remove("session").apply(); confirmation = null; publish(OfficeComponentState())
            }
        }
    }
    override fun onForeground(activity: Activity) {
        if (sessionID > 0) manager.getSessionState(sessionID).addOnSuccessListener { onState(it) }
        if (!OfficeComponentDistribution.installed(context)) prefs.edit().remove("remove_pending").apply()
    }
    override fun confirm(activity: Activity) {
        if (sessionID <= 0) return
        manager.getSessionState(sessionID).addOnSuccessListener { pending ->
            if (pending.status() == SplitInstallSessionStatus.REQUIRES_USER_CONFIRMATION &&
                !activity.isFinishing && !activity.isDestroyed) {
                runCatching { manager.startConfirmationDialogForResult(pending, activity, 9494) }
                    .onFailure { publish(OfficeComponentState("failed", failure = "play_confirmation_failed")) }
            }
        }.addOnFailureListener { publish(OfficeComponentState("failed", failure = "play_confirmation_failed")) }
    }
    override fun uninstall() {
        if (!canRemove()) return
        manager.deferredUninstall(listOf(OfficeComponentController.MODULE))
            .addOnSuccessListener {
                prefs.edit().putBoolean("remove_pending", true).apply()
                publish(OfficeComponentState("remove_pending", removable = false))
            }.addOnFailureListener { publish(OfficeComponentState("failed", failure = "play_remove_failed")) }
    }
    override fun cancel() {
        if (sessionID > 0) manager.cancelInstall(sessionID)
        confirmation = null
    }
}
