// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import java.security.SecureRandom

/**
 * Pure, RAM-only policy for the FULL-channel inline pairing notification.
 *
 * The notification is a convenience for one specific platform obstacle: on
 * some devices (verified on Samsung API 33) bringing Floe to the foreground
 * dismisses Android's wireless-debugging pairing dialog before the user can
 * type the code. The pairing notification therefore carries a real
 * [android.app.RemoteInput] reply action so the user can enter the six-digit
 * code while the Settings dialog stays in front.
 *
 * Security invariants pinned here (and in [PairingNotificationSession]):
 *  - a reply is accepted only for the CURRENT open process-local session;
 *  - the token is a 128-bit random nonce plus a random epoch and a monotonic
 *    generation, all held in RAM only;
 *  - one accepted submission consumes the token, so a replayed notification
 *    or a delivered-but-stale PendingIntent cannot pair twice;
 *  - closing/cancelling (or a process restart) invalidates every older token;
 *  - only the exact six ASCII digits are accepted; the code is never copied
 *    into a string, log, preference or notification body here;
 *  - notification availability is classified explicitly instead of relying
 *    on `notify()` throwing/silently dropping on API 33+.
 *
 * This file deliberately has no Android imports so the policy can be tested
 * as a plain JVM unit test.
 */
internal object PairingNotificationPolicy {

    /** Explicit-component reply action; never exported or broadcast implicitly. */
    const val ACTION_REPLY = "com.floe.android.host.deviceaccess.PAIRING_CODE_REPLY"

    /** RemoteInput result key. The value is read straight into a CharArray. */
    const val KEY_CODE = "com.floe.android.host.deviceaccess.PAIRING_CODE"

    const val EXTRA_NONCE = "com.floe.android.host.deviceaccess.PAIRING_NONCE"
    const val EXTRA_EPOCH = "com.floe.android.host.deviceaccess.PAIRING_EPOCH"
    const val EXTRA_GENERATION = "com.floe.android.host.deviceaccess.PAIRING_GENERATION"

    const val CHANNEL_ID = "floe_device_pairing"
    const val NOTIFICATION_ID = 0x0F10

    /** Low-importance progress notification for the bounded pairing FGS. */
    const val SERVICE_CHANNEL_ID = "floe_device_pairing_service"
    const val SERVICE_NOTIFICATION_ID = 0x0F11

    const val CODE_LENGTH = 6

    /** Wireless debugging itself exists only on API 30+. */
    const val WIRELESS_PAIRING_API = 30

    enum class Availability {
        /** A real inline reply notification can be posted now. */
        AVAILABLE,
        /** API 33+ POST_NOTIFICATIONS has not been granted yet. */
        PERMISSION_REQUIRED,
        /** App-level notifications (or the permission) are switched off. */
        NOTIFICATIONS_BLOCKED,
        /** The user blocked this app's pairing channel specifically. */
        CHANNEL_BLOCKED,
        /** API < 30: wireless pairing does not exist; USB setup is unchanged. */
        UNSUPPORTED,
    }

    enum class Decision {
        /** Token and code are valid; the token is now consumed. */
        ACCEPTED,
        /** Token belongs to a closed/cancelled/replaced/consumed session. */
        STALE,
        /** The open notification token outlived its bounded lifetime. */
        EXPIRED,
        /** The current token is valid but the entered value is not six digits. */
        INVALID_CODE,
    }

    fun availability(
        sdkInt: Int,
        permissionGranted: Boolean,
        notificationsEnabled: Boolean,
        channelBlocked: Boolean,
    ): Availability {
        if (sdkInt < WIRELESS_PAIRING_API) return Availability.UNSUPPORTED
        if (sdkInt >= 33 && !permissionGranted) return Availability.PERMISSION_REQUIRED
        if (!notificationsEnabled) return Availability.NOTIFICATIONS_BLOCKED
        if (channelBlocked) return Availability.CHANNEL_BLOCKED
        return Availability.AVAILABLE
    }

    /** True only for exactly six ASCII digits; never trims arbitrary text. */
    fun isValidCode(code: CharArray?): Boolean =
        code != null && code.size == CODE_LENGTH && code.all { it in '0'..'9' }

    /**
     * Copies a RemoteInput CharSequence into a caller-owned CharArray without
     * creating an intermediate String. Invalid content wipes the partial copy
     * and returns null.
     */
    fun readCode(input: CharSequence?): CharArray? {
        if (input == null || input.length != CODE_LENGTH) return null
        val out = CharArray(CODE_LENGTH)
        for (index in 0 until CODE_LENGTH) {
            val char = input[index]
            if (char !in '0'..'9') {
                out.fill('\u0000')
                return null
            }
            out[index] = char
        }
        return out
    }

    /**
     * The reply broadcast must be the explicit component this App created.
     * Anything else (an implicit intent, another package or another class) is
     * dropped before a token is even examined.
     */
    fun ownsReply(
        action: String?,
        componentClass: String?,
        componentPackage: String?,
        expectedClass: String,
        expectedPackage: String,
    ): Boolean = action == ACTION_REPLY &&
        componentClass == expectedClass &&
        componentPackage == expectedPackage

    /**
     * The port is always re-read from the App's own discovery/manual field at
     * submission time. A notification Intent never carries a port, so it can
     * never override this: a fresh discovered pairing port wins over a stale
     * manual fallback.
     */
    fun selectPairingPort(discoveredPort: Int?, manualInput: String): Int? {
        if (discoveredPort != null && discoveredPort in 1..65535) return discoveredPort
        return AdbPairingPortDiscovery.parsePort(manualInput)
    }
}

/**
 * RAM-only notification token gate. All methods are synchronized because the
 * host may close the session on the main thread while an IO pairing coroutine
 * settles a failed attempt.
 */
internal class PairingNotificationSession(
    private val nonceSource: () -> String = { secureNonce() },
    private val epochSource: () -> Long = { SECURE_RANDOM.nextLong() and Long.MAX_VALUE },
    private val requestCodeSource: () -> Int =
        { SECURE_RANDOM.nextInt(Int.MAX_VALUE - 1) + 1 },
    private val elapsedMillis: () -> Long = { System.nanoTime() / 1_000_000L },
) {
    internal data class Token(
        val nonce: String,
        val epoch: Long,
        val generation: Long,
        val requestCode: Int,
    )

    private var sessionOpen = false
    private var epoch = 0L
    private var generation = 0L
    private var activeToken: Token? = null
    private var issuedAtMillis = 0L

    @Synchronized
    fun isOpen(): Boolean = sessionOpen

    @Synchronized
    fun currentToken(): Token? = activeToken

    /** Session epoch remains stable across token reissue; close/new open changes it. */
    @Synchronized
    fun currentEpoch(): Long? = if (sessionOpen) epoch else null

    /** Opens a new user session; the random epoch makes old tokens dead. */
    @Synchronized
    fun open(): Token {
        sessionOpen = true
        epoch = epochSource()
        generation = 0L
        return issue()
    }

    /** Replaces the current notification token while the session stays open. */
    @Synchronized
    fun reissue(): Token? {
        if (!sessionOpen) return null
        return issue()
    }

    /** Cancel/success/close/forget/root-stop all invalidate every older token. */
    @Synchronized
    fun close() {
        sessionOpen = false
        activeToken = null
        issuedAtMillis = 0L
    }

    @Synchronized
    fun authorize(
        nonce: String?,
        epoch: Long,
        generation: Long,
        code: CharArray?,
        nowMillis: Long = elapsedMillis(),
    ): PairingNotificationPolicy.Decision {
        if (!sessionOpen) return PairingNotificationPolicy.Decision.STALE
        val token = activeToken ?: return PairingNotificationPolicy.Decision.STALE
        if (nonce == null || nonce != token.nonce ||
            epoch != token.epoch || generation != token.generation
        ) {
            return PairingNotificationPolicy.Decision.STALE
        }
        if (nowMillis < issuedAtMillis ||
            nowMillis - issuedAtMillis > TOKEN_LIFETIME_MILLIS
        ) {
            return PairingNotificationPolicy.Decision.EXPIRED
        }
        if (!PairingNotificationPolicy.isValidCode(code)) {
            return PairingNotificationPolicy.Decision.INVALID_CODE
        }
        // Exactly-once: a delivered action or a replayed PendingIntent sees a
        // token that no longer exists.
        activeToken = null
        return PairingNotificationPolicy.Decision.ACCEPTED
    }

    private fun issue(): Token {
        val token = Token(
            nonce = nonceSource(),
            epoch = epoch,
            generation = ++generation,
            requestCode = requestCodeSource(),
        )
        activeToken = token
        issuedAtMillis = elapsedMillis()
        return token
    }

    companion object {
        /** Generous but bounded; the Android dialog itself is short-lived. */
        const val TOKEN_LIFETIME_MILLIS = 10 * 60 * 1000L

        private val SECURE_RANDOM = SecureRandom()
        private val HEX = "0123456789abcdef".toCharArray()

        private fun secureNonce(): String {
            val bytes = ByteArray(16)
            SECURE_RANDOM.nextBytes(bytes)
            val chars = CharArray(bytes.size * 2)
            try {
                for (index in bytes.indices) {
                    val value = bytes[index].toInt() and 0xFF
                    chars[index * 2] = HEX[value ushr 4]
                    chars[index * 2 + 1] = HEX[value and 0x0F]
                }
                return String(chars)
            } finally {
                bytes.fill(0)
                chars.fill('\u0000')
            }
        }
    }
}
