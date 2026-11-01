// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure regression for the FULL inline pairing notification.
 *
 * These tests pin the actual safety contract rather than the notification
 * rendering: a token belongs to exactly one open session and one submission,
 * stale/cancelled/replayed actions cannot pair, the code is exactly six ASCII
 * digits, only the explicit receiver component is accepted, and the pairing
 * port is always the App's own fresh discovery (never Intent extras).
 */
class PairingNotificationPolicyTest {

    private var now = 1_000L
    private var nonceCount = 0
    private var epochCount = 100L

    private fun session(): PairingNotificationSession =
        PairingNotificationSession(
            nonceSource = { "nonce-${nonceCount++}" },
            epochSource = { epochCount++ },
            requestCodeSource = { 700 + nonceCount },
            elapsedMillis = { now },
        )

    private fun digits(value: String): CharArray = value.toCharArray()

    // ---------------------------------------------------------- availability

    @Test
    fun availabilityDistinguishesApiPermissionAndSystemBlocks() {
        assertEquals(
            PairingNotificationPolicy.Availability.UNSUPPORTED,
            PairingNotificationPolicy.availability(28, true, true, false),
        )
        assertEquals(
            PairingNotificationPolicy.Availability.UNSUPPORTED,
            PairingNotificationPolicy.availability(29, true, true, false),
        )
        // API 30-32 has wireless pairing but no POST_NOTIFICATIONS runtime grant.
        assertEquals(
            PairingNotificationPolicy.Availability.AVAILABLE,
            PairingNotificationPolicy.availability(30, false, true, false),
        )
        assertEquals(
            PairingNotificationPolicy.Availability.PERMISSION_REQUIRED,
            PairingNotificationPolicy.availability(33, false, true, false),
        )
        assertEquals(
            PairingNotificationPolicy.Availability.NOTIFICATIONS_BLOCKED,
            PairingNotificationPolicy.availability(33, true, false, false),
        )
        assertEquals(
            PairingNotificationPolicy.Availability.CHANNEL_BLOCKED,
            PairingNotificationPolicy.availability(33, true, true, true),
        )
        assertEquals(
            PairingNotificationPolicy.Availability.AVAILABLE,
            PairingNotificationPolicy.availability(33, true, true, false),
        )
    }

    @Test
    fun boundedProgressServiceNeverOverwritesTheInlineReplyNotification() {
        assertNotEquals(
            PairingNotificationPolicy.CHANNEL_ID,
            PairingNotificationPolicy.SERVICE_CHANNEL_ID,
        )
        assertNotEquals(
            PairingNotificationPolicy.NOTIFICATION_ID,
            PairingNotificationPolicy.SERVICE_NOTIFICATION_ID,
        )
    }

    // ------------------------------------------------------------- code input

    @Test
    fun onlyExactlySixAsciiDigitsAreAccepted() {
        assertTrue(PairingNotificationPolicy.isValidCode(digits("123456")))
        assertFalse(PairingNotificationPolicy.isValidCode(digits("12345")))
        assertFalse(PairingNotificationPolicy.isValidCode(digits("1234567")))
        assertFalse(PairingNotificationPolicy.isValidCode(digits("12a456")))
        assertFalse(PairingNotificationPolicy.isValidCode(digits(" 23456")))
        assertFalse(PairingNotificationPolicy.isValidCode(digits("１２３４５６")))
        assertFalse(PairingNotificationPolicy.isValidCode(null))
    }

    @Test
    fun remoteInputIsCopiedWithoutCreatingAStringAndInvalidInputIsRejected() {
        val copied = PairingNotificationPolicy.readCode(StringBuilder("654321"))
        assertEquals("654321", copied?.concatToString())
        copied?.fill('\u0000')

        assertNull(PairingNotificationPolicy.readCode(StringBuilder("65432")))
        assertNull(PairingNotificationPolicy.readCode(StringBuilder("65432x")))
        assertNull(PairingNotificationPolicy.readCode(null))
    }

    // ---------------------------------------------------------- token lifecycle

    @Test
    fun acceptedSubmissionConsumesTokenAndReplayCannotPairAgain() {
        val session = session()
        val token = session.open()
        assertEquals(
            PairingNotificationPolicy.Decision.ACCEPTED,
            session.authorize(token.nonce, token.epoch, token.generation, digits("123456"), now),
        )
        assertEquals(
            PairingNotificationPolicy.Decision.STALE,
            session.authorize(token.nonce, token.epoch, token.generation, digits("123456"), now),
        )
    }

    @Test
    fun nonceEpochOrGenerationMismatchIsStale() {
        val session = session()
        val token = session.open()
        assertEquals(
            PairingNotificationPolicy.Decision.STALE,
            session.authorize("other", token.epoch, token.generation, digits("123456"), now),
        )
        assertEquals(
            PairingNotificationPolicy.Decision.STALE,
            session.authorize(token.nonce, token.epoch + 1, token.generation, digits("123456"), now),
        )
        assertEquals(
            PairingNotificationPolicy.Decision.STALE,
            session.authorize(token.nonce, token.epoch, token.generation + 1, digits("123456"), now),
        )
        // None of the stale attempts consumed the real token.
        assertEquals(
            PairingNotificationPolicy.Decision.ACCEPTED,
            session.authorize(token.nonce, token.epoch, token.generation, digits("123456"), now),
        )
    }

    @Test
    fun cancelInvalidatesAndANewSessionCannotReviveTheOldNotification() {
        val session = session()
        val old = session.open()
        session.close()
        assertEquals(
            PairingNotificationPolicy.Decision.STALE,
            session.authorize(old.nonce, old.epoch, old.generation, digits("123456"), now),
        )
        assertNull(session.reissue())
        val fresh = session.open()
        assertNotEquals(old.epoch, fresh.epoch)
        assertEquals(
            PairingNotificationPolicy.Decision.STALE,
            session.authorize(old.nonce, old.epoch, old.generation, digits("123456"), now),
        )
        assertEquals(
            PairingNotificationPolicy.Decision.ACCEPTED,
            session.authorize(
                fresh.nonce, fresh.epoch, fresh.generation, digits("123456"), now),
        )
    }

    @Test
    fun reissueReplacesThePreviousNotificationToken() {
        val session = session()
        val first = session.open()
        val second = session.reissue()
        checkNotNull(second)
        assertNotEquals(first.nonce, second.nonce)
        assertEquals(
            PairingNotificationPolicy.Decision.STALE,
            session.authorize(first.nonce, first.epoch, first.generation, digits("123456"), now),
        )
        assertEquals(
            PairingNotificationPolicy.Decision.ACCEPTED,
            session.authorize(second.nonce, second.epoch, second.generation, digits("123456"), now),
        )
    }

    @Test
    fun sessionEpochSurvivesReissueAndFencesLatePermissionForANewSession() {
        val session = session()
        session.open()
        val epoch = session.currentEpoch()
        checkNotNull(epoch)
        session.reissue()
        assertEquals(epoch, session.currentEpoch())
        session.close()
        assertNull(session.currentEpoch())
        session.open()
        assertNotEquals(epoch, session.currentEpoch())
    }

    @Test
    fun boundedLifetimeExpiresTheOpenNotificationToken() {
        val session = session()
        val token = session.open()
        now += PairingNotificationSession.TOKEN_LIFETIME_MILLIS + 1
        assertEquals(
            PairingNotificationPolicy.Decision.EXPIRED,
            session.authorize(token.nonce, token.epoch, token.generation, digits("123456"), now),
        )
        // Expiry does not turn a stale action into a fresh pairing; the host
        // must issue a new notification token.
        assertEquals(
            PairingNotificationPolicy.Decision.EXPIRED,
            session.authorize(token.nonce, token.epoch, token.generation, digits("123456"), now),
        )
    }

    @Test
    fun invalidCodeIsRejectedWithoutSilentlyPairingOrConsumingTheOpenToken() {
        val session = session()
        val token = session.open()
        assertEquals(
            PairingNotificationPolicy.Decision.INVALID_CODE,
            session.authorize(token.nonce, token.epoch, token.generation, digits("12345"), now),
        )
        assertEquals(
            PairingNotificationPolicy.Decision.INVALID_CODE,
            session.authorize(token.nonce, token.epoch, token.generation, digits("12345x"), now),
        )
        assertEquals(
            PairingNotificationPolicy.Decision.ACCEPTED,
            session.authorize(token.nonce, token.epoch, token.generation, digits("123456"), now),
        )
    }

    @Test
    fun closedSessionHasNoCurrentTokenForANotification() {
        val session = session()
        session.open()
        session.close()
        assertNull(session.currentToken())
        assertFalse(session.isOpen())
    }

    // ------------------------------------------------------------- intent scope

    @Test
    fun onlyTheExplicitOwnedReceiverComponentIsAccepted() {
        val clazz = PairingCodeReceiver::class.java.name
        val pkg = "com.floe.agent.full.dev"
        assertTrue(
            PairingNotificationPolicy.ownsReply(
                PairingNotificationPolicy.ACTION_REPLY, clazz, pkg, clazz, pkg),
        )
        assertFalse(
            PairingNotificationPolicy.ownsReply(
                "com.example.ACTION", clazz, pkg, clazz, pkg),
        )
        assertFalse(
            PairingNotificationPolicy.ownsReply(
                PairingNotificationPolicy.ACTION_REPLY,
                PairingCodeReceiver::class.java.name + "X", pkg, clazz, pkg),
        )
        assertFalse(
            PairingNotificationPolicy.ownsReply(
                PairingNotificationPolicy.ACTION_REPLY, clazz, "com.example", clazz, pkg),
        )
        assertFalse(
            PairingNotificationPolicy.ownsReply(
                PairingNotificationPolicy.ACTION_REPLY, null, null, clazz, pkg),
        )
    }

    // ---------------------------------------------------------------- pairing port

    @Test
    fun freshDiscoveredPairingPortWinsAndManualFallbackIsValidated() {
        assertEquals(
            37123,
            PairingNotificationPolicy.selectPairingPort(37123, "1"),
        )
        assertEquals(
            42000,
            PairingNotificationPolicy.selectPairingPort(null, "42000"),
        )
        assertNull(PairingNotificationPolicy.selectPairingPort(null, "0"))
        assertNull(PairingNotificationPolicy.selectPairingPort(null, "65536"))
        assertNull(PairingNotificationPolicy.selectPairingPort(null, "not-a-port"))
        // A stale/out-of-range discovered value never overrides a valid manual
        // port; the real controller still enforces its own 1..65535 range.
        assertEquals(
            40000,
            PairingNotificationPolicy.selectPairingPort(70000, "40000"),
        )
    }
}
