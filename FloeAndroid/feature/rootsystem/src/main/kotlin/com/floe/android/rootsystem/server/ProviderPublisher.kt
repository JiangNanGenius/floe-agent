// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.server

import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.util.Log
import com.floe.android.rootsystem.ipc.BinderProtocol
import com.floe.android.rootsystem.ipc.FloeSystemProvider

/**
 * Publishes the server binder through the App-owned provider.
 *
 * The call goes through [AppProviderClient], which uses the platform's external
 * provider entry point. This process has no ActivityManager ProcessRecord, so a
 * normal ContentResolver call is refused before it reaches the provider (see
 * [AppProviderClient]). The provider call also restarts the App process when it
 * was killed, so an App death after the service started does not require
 * re-pairing. The returned App handle is watched with a death recipient; a dead
 * App process triggers another publication attempt. Only the App package's
 * provider authority is used.
 */
internal class ProviderPublisher(
    private val identity: ServerIdentity,
    private val token: String,
    private val binder: IBinder,
    private val initialDeadlineMillis: Long = INITIAL_PUBLICATION_WINDOW_MILLIS,
    private val hasClient: (() -> Boolean)? = null,
    private val onInitialPublicationFailed: (() -> Unit)? = null,
    private val onPublished: (() -> Unit)? = null,
) {
    private val authority = identity.packageName + FloeSystemProvider.AUTHORITY_SUFFIX
    private val thread = HandlerThread("floe-system-publish").apply { start() }
    private val handler = Handler(thread.looper)
    private val retry = PublishBackoff()

    // The initial watchdog must not share the publisher queue: AppProviderClient
    // performs a synchronous Binder/provider call, and a hung provider call
    // would otherwise also block the deadline. The server prepares the main
    // looper before constructing this publisher, so this Handler is independent.
    private val mainHandler = Handler(Looper.getMainLooper())
    private val initialDeadline = Runnable { checkInitialDeadline() }

    @Volatile
    private var stopped = false

    @Volatile
    private var publishedOnce = false
    private var appHandle: IBinder? = null
    private var lastFailureCode: String? = null

    fun start() {
        handler.post(::publishOnce)
        // The App waits 12 s for adoption. If the very first publication never
        // succeeds, exit instead of orphaning an endlessly retrying UID 2000
        // process. A successful publication or a verified App adoption removes
        // this deadline so the already-verified reconnect behaviour is kept.
        if (initialDeadlineMillis > 0) {
            mainHandler.postDelayed(initialDeadline, initialDeadlineMillis)
        }
    }

    /** Verified App adoption; the publication reply itself may have been lost. */
    fun cancelInitialDeadline() {
        mainHandler.removeCallbacks(initialDeadline)
    }

    fun stop() {
        stopped = true
        cancelInitialDeadline()
        appHandle?.let { handle ->
            runCatching { handle.unlinkToDeath(appDeath, 0) }
        }
        appHandle = null
        handler.removeCallbacksAndMessages(null)
        thread.quitSafely()
    }

    private fun publishOnce() {
        if (stopped) return
        val extras = Bundle().apply {
            putBinder(BinderProtocol.KEY_BINDER, binder)
            putString(BinderProtocol.KEY_TOKEN, token)
            putString(BinderProtocol.KEY_SERVER_MODE, identity.mode)
            putInt(BinderProtocol.KEY_SERVER_UID, identity.serverUid)
            putInt(BinderProtocol.KEY_SERVER_PID, identity.serverPid)
            putString(BinderProtocol.KEY_PACKAGE, identity.packageName)
            putLong(BinderProtocol.KEY_APP_VERSION, identity.appVersionCode)
            putString(BinderProtocol.KEY_SIGNING_SHA256, identity.signingSha256)
            putInt(BinderProtocol.KEY_PROTOCOL, BinderProtocol.VERSION)
        }
        when (
            val result = AppProviderClient.call(
                authority = authority,
                userId = identity.userId,
                method = FloeSystemProvider.METHOD_SEND_BINDER,
                arg = token,
                extras = extras,
            )
        ) {
            is AppProviderClient.Result.Failed -> {
                reportFailure(result.code)
                scheduleRetry()
            }
            is AppProviderClient.Result.Reply -> {
                val client = result.reply?.getBinder(BinderProtocol.KEY_CLIENT)
                if (client != null && runCatching { client.pingBinder() }.getOrDefault(false)) {
                    // Mark success before any further Binder call (linkToDeath)
                    // so a concurrent initial-deadline check cannot exit a
                    // service whose publication was already accepted.
                    publishedOnce = true
                    cancelInitialDeadline()
                    attachAppHandle(client)
                    retry.reset()
                    lastFailureCode = null
                    Log.i(LOG_TAG, "publish_ok")
                    onPublished?.invoke()
                    return
                }
                // The provider executed but refused the publication (unknown
                // token/UID/PID/metadata) or returned no client handle.
                reportFailure(FAILURE_REJECTED)
                scheduleRetry()
            }
        }
    }

    private fun reportFailure(code: String) {
        if (lastFailureCode == code) return
        lastFailureCode = code
        Log.w(LOG_TAG, "publish_failed:" + code)
    }

    private fun attachAppHandle(client: IBinder) {
        if (appHandle === client) return
        appHandle?.let { old -> runCatching { old.unlinkToDeath(appDeath, 0) } }
        appHandle = client
        runCatching { client.linkToDeath(appDeath, 0) }
    }

    private val appDeath = IBinder.DeathRecipient {
        appHandle = null
        if (!stopped) {
            handler.postDelayed(::publishOnce, APP_DEATH_RETRY_MILLIS)
        }
    }

    private fun scheduleRetry() {
        if (stopped) return
        handler.postDelayed(::publishOnce, retry.nextDelayMillis())
    }

    private fun checkInitialDeadline() {
        // A verified App describe() means the publication was adopted even if
        // this publisher never saw the reply; keep the reconnect behaviour.
        if (stopped || publishedOnce || hasClient?.invoke() == true) return
        stopped = true
        handler.removeCallbacksAndMessages(null)
        Log.w(LOG_TAG, "publish_initial_timeout")
        onInitialPublicationFailed?.invoke()
    }

    private companion object {
        const val LOG_TAG = "FloeSystemPublish"
        const val FAILURE_REJECTED = "provider_rejected"
        const val APP_DEATH_RETRY_MILLIS = 500L

        /** App adoption waits 12 s; allow AMS/provider start slack, then exit. */
        const val INITIAL_PUBLICATION_WINDOW_MILLIS = 20_000L
    }
}
