// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.ipc

import android.os.Binder
import android.os.Bundle
import android.os.IBinder
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * In-process publication point for the embedded service binder.
 *
 * The server process (shell UID 2000 or root UID 0) publishes only through the
 * Full-only FloeSystemProvider. This hub stores the binder for the App process;
 * a binder from an external Shizuku manager, a third-party app or an unexpected
 * UID is never accepted, and a token mismatch is rejected when a token is
 * expected.
 */
internal object BinderHub {

    data class Published(
        val mode: String,
        val token: String,
        val binder: IBinder,
        val serverUid: Int,
        val serverPid: Int,
        val appVersionCode: Long,
        val signingSha256: String,
        val protocolVersion: Int,
        val tokenVerified: Boolean,
    )

    private val gate = Any()
    private val published = LinkedHashMap<String, Published>()
    private val expectedTokens = HashMap<String, String>()
    private val listeners = ArrayList<(Published) -> Unit>()

    fun expectToken(mode: String, token: String) {
        synchronized(gate) { expectedTokens[mode] = token }
    }

    fun clearExpectedToken(mode: String) {
        synchronized(gate) { expectedTokens.remove(mode) }
    }

    sealed interface AcceptResult {
        data class Ok(val published: Published) : AcceptResult
        data class Rejected(val code: String) : AcceptResult
    }

    fun accept(callerUid: Int, callerPid: Int, extras: Bundle?): AcceptResult {
        if (extras == null) return AcceptResult.Rejected("extras")
        if (callerPid <= 1) return AcceptResult.Rejected("identity")
        val mode = extras.getString(BinderProtocol.KEY_SERVER_MODE) ?: return AcceptResult.Rejected("mode")
        if (mode != BinderProtocol.MODE_ADB && mode != BinderProtocol.MODE_ROOT) {
            return AcceptResult.Rejected("mode")
        }
        val expectedUid = if (mode == BinderProtocol.MODE_ADB) 2000 else 0
        if (callerUid != expectedUid) return AcceptResult.Rejected("caller_uid")

        val binder = extras.getBinder(BinderProtocol.KEY_BINDER)
            ?: return AcceptResult.Rejected("binder")
        if (!binder.pingBinder()) return AcceptResult.Rejected("binder_dead")
        val token = extras.getString(BinderProtocol.KEY_TOKEN) ?: return AcceptResult.Rejected("token")
        val serverPid = extras.getInt(BinderProtocol.KEY_SERVER_PID)
        val serverUid = extras.getInt(BinderProtocol.KEY_SERVER_UID)
        val appVersion = extras.getLong(BinderProtocol.KEY_APP_VERSION)
        val signing = extras.getString(BinderProtocol.KEY_SIGNING_SHA256) ?: return AcceptResult.Rejected("signing")
        val protocol = extras.getInt(BinderProtocol.KEY_PROTOCOL, -1)
        // serverPid is supplied by the service; the provider's Binder caller PID
        // is the actual process that published, so the two must agree.
        if (serverUid != expectedUid || serverPid <= 0 || serverPid != callerPid) {
            return AcceptResult.Rejected("identity")
        }
        if (appVersion <= 0 || signing.length != 64) return AcceptResult.Rejected("metadata")
        if (protocol != BinderProtocol.VERSION) return AcceptResult.Rejected("protocol")

        val expected = synchronized(gate) { expectedTokens[mode] }
        val verified = expected != null && constantTimeEquals(expected, token)
        if (expected != null && !verified) return AcceptResult.Rejected("token")

        val record = Published(
            mode = mode,
            token = token,
            binder = binder,
            serverUid = serverUid,
            serverPid = serverPid,
            appVersionCode = appVersion,
            signingSha256 = signing,
            protocolVersion = protocol,
            tokenVerified = verified,
        )
        val replaced = synchronized(gate) {
            val old = published.put(mode, record)
            old
        }
        if (replaced?.binder !== binder) {
            runCatching {
                binder.linkToDeath({
                    removeIfSame(mode, binder)
                }, 0)
            }
        }
        notify(record)
        return AcceptResult.Ok(record)
    }

    fun peek(mode: String): Published? = synchronized(gate) {
        val record = published[mode] ?: return null
        if (!record.binder.pingBinder()) {
            published.remove(mode)
            return null
        }
        record
    }

    fun clear(mode: String) {
        synchronized(gate) { published.remove(mode) }
    }

    fun await(mode: String, timeoutMillis: Long): Published? {
        val current = peek(mode)
        if (current != null) return current
        val latch = CountDownLatch(1)
        val listener: (Published) -> Unit = { if (it.mode == mode) latch.countDown() }
        synchronized(gate) { listeners.add(listener) }
        return try {
            if (latch.await(timeoutMillis, TimeUnit.MILLISECONDS)) peek(mode) else null
        } finally {
            synchronized(gate) { listeners.remove(listener) }
        }
    }

    fun findByBinder(mode: String, binder: IBinder): Published? = synchronized(gate) {
        published[mode]?.takeIf { it.binder === binder }
    }

    fun removeIfSame(mode: String, binder: IBinder) {
        synchronized(gate) {
            if (published[mode]?.binder === binder) published.remove(mode)
        }
    }

    private fun notify(record: Published) {
        val copy = synchronized(gate) { listeners.toList() }
        copy.forEach { runCatching { it(record) } }
    }

    private fun constantTimeEquals(a: String, b: String): Boolean {
        return MessageDigest.isEqual(a.toByteArray(Charsets.UTF_8), b.toByteArray(Charsets.UTF_8))
    }

    /** A small app-side handle returned to the server so it can watch App process death. */
    class AppHandle : Binder()
}
