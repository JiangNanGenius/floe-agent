// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.server

import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import com.floe.android.rootsystem.ipc.BinderProtocol
import com.floe.android.rootsystem.ipc.FloeSystemProvider

/**
 * Publishes the server binder through the App-owned provider.
 *
 * The provider call also restarts the App process when it was killed, so an App
 * death after the service started does not require re-pairing. The returned App
 * handle is watched with a death recipient; a dead App process triggers another
 * publication attempt. Only the App package's provider authority is used.
 */
internal class ProviderPublisher(
    context: Context,
    private val identity: ServerIdentity,
    private val token: String,
    private val binder: IBinder,
    private val onPublished: (() -> Unit)? = null,
) {
    private val appContext = context.applicationContext ?: context
    private val authority = identity.packageName + FloeSystemProvider.AUTHORITY_SUFFIX
    private val uri: Uri = Uri.parse("content://$authority")
    private val thread = HandlerThread("floe-system-publish").apply { start() }
    private val handler = Handler(thread.looper)

    @Volatile
    private var stopped = false
    private var appHandle: IBinder? = null
    private var delayMillis = INITIAL_DELAY_MILLIS

    fun start() {
        handler.post(::publishOnce)
    }

    fun stop() {
        stopped = true
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
        val reply = try {
            appContext.contentResolver.call(
                uri,
                FloeSystemProvider.METHOD_SEND_BINDER,
                token,
                extras,
            )
        } catch (_: Throwable) {
            null
        }
        val client = reply?.getBinder(BinderProtocol.KEY_CLIENT)
        if (client != null && client.pingBinder()) {
            attachAppHandle(client)
            delayMillis = INITIAL_DELAY_MILLIS
            onPublished?.invoke()
            return
        }
        scheduleRetry()
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
        val delay = delayMillis
        delayMillis = (delayMillis * 2).coerceAtMost(MAX_DELAY_MILLIS)
        handler.postDelayed(::publishOnce, delay)
    }

    private companion object {
        const val INITIAL_DELAY_MILLIS = 250L
        const val MAX_DELAY_MILLIS = 10_000L
        const val APP_DEATH_RETRY_MILLIS = 500L
    }
}
