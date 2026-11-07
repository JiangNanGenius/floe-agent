// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.optionalsplit

import android.app.Activity
import android.content.Context
import com.google.android.play.core.splitcompat.SplitCompat
import com.google.android.play.core.splitinstall.SplitInstallManager
import com.google.android.play.core.splitinstall.SplitInstallManagerFactory
import com.google.android.play.core.splitinstall.SplitInstallRequest
import com.google.android.play.core.splitinstall.SplitInstallSessionState
import com.google.android.play.core.splitinstall.SplitInstallStateUpdatedListener
import com.google.android.play.core.splitinstall.model.SplitInstallSessionStatus

/** Play requests only the declared feature; no APK download or package-install
 * permission, exactly as the Office preview does it. One parameterized
 * backend serves every on-demand split so a second component can never
 * become a parallel delivery framework. */
internal class PlayOptionalSplitBackend(
    private val context: Context,
    private val spec: OptionalComponentSpec,
    private val publish: (OptionalComponentState) -> Unit,
    private val refresh: () -> Unit,
    private val canRemove: () -> Boolean,
) : OptionalComponentBackend {
    private val manager: SplitInstallManager = SplitInstallManagerFactory.create(context)
    private val prefs = context.getSharedPreferences(spec.prefsName, Context.MODE_PRIVATE)
    private var sessionID = prefs.getInt("session", 0)
    private var confirmation: SplitInstallSessionState? = null
    private var requestEpoch = 0L
    private var starting = false
    private var cancelRequested = prefs.getBoolean("cancel", false)
    private var cancelIssued = 0
    private val listener = SplitInstallStateUpdatedListener { value -> onState(value) }

    init {
        manager.registerListener(listener)
        if (prefs.getBoolean("remove_pending", false) && spec.installed(context)) {
            publish(OptionalComponentState("remove_pending", removable = false))
        }
    }

    override fun install() {
        if (starting || sessionID > 0) return
        val epoch = ++requestEpoch
        starting = true
        cancelRequested = false
        cancelIssued = 0
        confirmation = null
        prefs.edit().putBoolean("starting", true).remove("cancel").commit()
        publish(OptionalComponentState("downloading"))
        manager.startInstall(
            SplitInstallRequest.newBuilder().addModule(spec.module).build())
            .addOnSuccessListener { id ->
                if (epoch != requestEpoch) return@addOnSuccessListener
                starting = false
                sessionID = id
                prefs.edit().remove("starting").putInt("session", id).commit()
                if (id == 0) {
                    prefs.edit().remove("session").remove("cancel").commit()
                    if (spec.installed(context)) {
                        publish(OptionalComponentState("installed")); refresh()
                    } else publish(OptionalComponentState("failed", failure = "play_install_unconfirmed"))
                } else if (cancelRequested) requestCancellation(id)
                else manager.getSessionState(id).addOnSuccessListener { onState(it) }
            }
            .addOnFailureListener {
                if (epoch != requestEpoch) return@addOnFailureListener
                starting = false
                prefs.edit().remove("starting").remove("cancel").commit()
                publish(OptionalComponentState("failed", failure = "play_delivery_failed"))
            }
    }

    private fun onState(value: SplitInstallSessionState) {
        if (value.sessionId() != sessionID || spec.module !in value.moduleNames()) return
        if (cancelRequested && value.status() in setOf(
                SplitInstallSessionStatus.PENDING, SplitInstallSessionStatus.DOWNLOADING,
                SplitInstallSessionStatus.REQUIRES_USER_CONFIRMATION)) {
            if (cancelIssued != sessionID) requestCancellation(sessionID)
            return
        }
        when (value.status()) {
            SplitInstallSessionStatus.INSTALLED -> {
                SplitCompat.install(context)
                prefs.edit().remove("session").remove("remove_pending").remove("cancel").commit()
                sessionID = 0
                cancelRequested = false
                confirmation = null
                if (spec.installed(context)) {
                    publish(OptionalComponentState("installed"))
                    refresh()
                } else {
                    publish(OptionalComponentState("failed", failure = "play_install_unconfirmed"))
                }
            }
            SplitInstallSessionStatus.REQUIRES_USER_CONFIRMATION -> {
                confirmation = value
                publish(OptionalComponentState("play_confirm"))
            }
            SplitInstallSessionStatus.DOWNLOADING,
            SplitInstallSessionStatus.PENDING,
            -> publish(OptionalComponentState(
                "downloading", value.bytesDownloaded(), value.totalBytesToDownload()))
            SplitInstallSessionStatus.INSTALLING,
            SplitInstallSessionStatus.DOWNLOADED,
            -> publish(OptionalComponentState(
                "installing", value.bytesDownloaded(), value.totalBytesToDownload()))
            SplitInstallSessionStatus.CANCELING -> publish(OptionalComponentState("cancelling"))
            SplitInstallSessionStatus.FAILED -> {
                prefs.edit().remove("session").remove("cancel").commit()
                sessionID = 0
                cancelRequested = false
                publish(OptionalComponentState("failed", failure = "play_delivery_${value.errorCode()}"))
            }
            SplitInstallSessionStatus.CANCELED -> {
                prefs.edit().remove("session").remove("cancel").commit()
                sessionID = 0
                cancelRequested = false
                confirmation = null
                publish(OptionalComponentState(if (spec.installed(context)) "installed" else "missing"))
            }
        }
    }

    override fun uninstall() {
        if (!canRemove()) return
        manager.deferredUninstall(listOf(spec.module))
            .addOnSuccessListener {
                prefs.edit().putBoolean("remove_pending", true).apply()
                publish(OptionalComponentState("remove_pending", removable = false))
            }
            .addOnFailureListener {
                publish(OptionalComponentState("failed", failure = "play_remove_failed"))
            }
    }

    override fun cancel() {
        cancelRequested = true
        cancelIssued = 0
        confirmation = null
        prefs.edit().putBoolean("cancel", true).commit()
        if (sessionID > 0) requestCancellation(sessionID)
        else if (starting) publish(OptionalComponentState("cancelling"))
        else {
            prefs.edit().remove("cancel").commit()
            publish(OptionalComponentState(if (spec.installed(context)) "installed" else "missing"))
        }
    }

    private fun requestCancellation(id: Int) {
        cancelIssued = id
        publish(OptionalComponentState("cancelling"))
        manager.cancelInstall(id).addOnFailureListener {
            publish(OptionalComponentState("failed", failure = "play_cancel_failed"))
        }
    }

    override fun onForeground(activity: Activity) {
        if (!spec.installed(context) && prefs.getBoolean("remove_pending", false)) {
            prefs.edit().remove("remove_pending").commit()
            publish(OptionalComponentState())
        }
        if (starting) return
        if (sessionID > 0) {
            manager.getSessionState(sessionID).addOnSuccessListener { onState(it) }
                .addOnFailureListener {
                    publish(OptionalComponentState("failed", failure = "play_install_unconfirmed"))
                }
        } else {
            val epoch = requestEpoch
            manager.sessionStates.addOnSuccessListener { values ->
                if (epoch != requestEpoch || starting || sessionID > 0) return@addOnSuccessListener
                val owned = values.filter { spec.module in it.moduleNames() }
                if (owned.size == 1) {
                    sessionID = owned.single().sessionId()
                    prefs.edit().putInt("session", sessionID).remove("starting").commit()
                    onState(owned.single())
                } else if (owned.size > 1 || prefs.getBoolean("starting", false)) {
                    publish(OptionalComponentState("failed", failure = "play_install_unconfirmed"))
                }
            }.addOnFailureListener {
                publish(OptionalComponentState("failed", failure = "play_install_unconfirmed"))
            }
        }
    }

    override fun confirm(activity: Activity) {
        if (sessionID <= 0) return
        manager.getSessionState(sessionID).addOnSuccessListener { pending ->
            if (pending.status() == SplitInstallSessionStatus.REQUIRES_USER_CONFIRMATION &&
                !activity.isFinishing && !activity.isDestroyed
            ) {
                runCatching {
                    manager.startConfirmationDialogForResult(pending, activity, 9494)
                }.onFailure {
                    publish(OptionalComponentState("failed", failure = "play_confirmation_failed"))
                }
            }
        }.addOnFailureListener {
            publish(OptionalComponentState("failed", failure = "play_confirmation_failed"))
        }
    }
}
