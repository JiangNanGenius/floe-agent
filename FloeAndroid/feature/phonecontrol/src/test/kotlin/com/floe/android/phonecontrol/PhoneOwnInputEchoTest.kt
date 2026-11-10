// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Regression for the dedicated Samsung API33 case (Full code105): a task-owned
 * automatic keyguard unlock succeeded and phone.observe returned ok, but the
 * next launch parked in phone_presence_required with no intervening human
 * input. Delayed keyguard echoes are the attribution scenario tested here;
 * the device trace did not capture an accessibility event timestamp.
 *
 * The timestamps below replay the actual closed unlock trace offsets
 * (attempt start at 0): reveal accepted ~+990ms, keypad dispatched ~+1680ms,
 * submit tap ~+1760ms, observed UNLOCKED at ~+2420ms. The delayed echo at
 * +12470ms carrying a +1760ms timestamp is a synthetic regression input,
 * not a captured event.
 */
class PhoneOwnInputEchoTest {

    @Test fun lateKeyguardDismissEchoStaysAttributedToTheTask() {
        val echo = PhoneOwnInputEcho()
        echo.noteOwnInput(0L)          // attempt start / wake
        echo.noteOwnInput(990L)        // reveal swipe accepted
        echo.noteOwnInput(1_680L)      // keypad entry dispatched
        echo.noteOwnInput(1_760L)      // submit tap dispatched (last own input)
        // The platform delivers the dismiss echo ~10s later, but the event
        // keeps the dispatch's own timestamp: it is task input, never a
        // human touch.
        assertTrue(echo.isOwnEcho(1_760L))
        assertTrue(echo.isOwnEcho(1_700L))
        // A genuine human touch at the echo's ARRIVAL instant carries its own
        // fresh timestamp and must stay human.
        assertFalse(echo.isOwnEcho(12_470L))
    }

    @Test fun echoHorizonCoversObservedKeyguardDismiss() {
        val echo = PhoneOwnInputEcho()
        echo.noteOwnInput(10_000L)                 // submit tap
        // Unlock observed ~680ms later on the actual device: echoes stamped
        // anywhere up to the bounded horizon still belong to the task.
        assertTrue(echo.isOwnEcho(10_680L))
        assertTrue(echo.isOwnEcho(11_500L))        // last dispatch + 1500ms
        assertFalse(echo.isOwnEcho(11_501L))       // past the bounded horizon
    }

    @Test fun freshTimestampedTouchAfterWindowIsHuman() {
        val echo = PhoneOwnInputEcho()
        echo.noteOwnInput(5_000L)
        // One second after the horizon a real user grab carries its own fresh
        // timestamp: it must not be attributed to the task.
        assertFalse(echo.isOwnEcho(7_000L))
        assertFalse(echo.isOwnEcho(6_501L))
    }

    @Test fun laterDispatchOpensFreshWindowAndCannotAbsorbBetweenTouch() {
        val echo = PhoneOwnInputEcho()
        echo.noteOwnInput(1_000L)                  // task unlock input
        echo.noteOwnInput(4_000L)                  // later, separate dispatch
        // A human touch between the two windows is neither inside the expired
        // first window nor the second one.
        assertFalse(echo.isOwnEcho(2_500L))
        // The second dispatch is its own transaction.
        assertTrue(echo.isOwnEcho(4_500L))
    }

    @Test fun burstInsideHorizonIsOneTransaction() {
        val echo = PhoneOwnInputEcho()
        echo.noteOwnInput(1_000L)
        echo.noteOwnInput(1_200L)
        echo.noteOwnInput(1_400L)
        // The window opens at the first dispatch and extends to the last
        // dispatch plus the horizon; early burst echoes stay task input.
        assertTrue(echo.isOwnEcho(1_000L))
        assertTrue(echo.isOwnEcho(2_900L))         // 1_400 + 1_500
        assertFalse(echo.isOwnEcho(2_901L))
    }

    @Test fun generationStampSlightlyBeforeNoteIsStillOwnInput() {
        val echo = PhoneOwnInputEcho()
        echo.noteOwnInput(2_000L)
        // A framework-scheduled stamp can precede the note by a few ms.
        assertTrue(echo.isOwnEcho(1_800L))
        assertFalse(echo.isOwnEcho(1_700L))        // outside the small skew
    }

    @Test fun withoutAnyOwnInputNothingIsAnEcho() {
        val echo = PhoneOwnInputEcho()
        assertFalse(echo.hasOwnInput)
        assertFalse(echo.isOwnEcho(0L))
        assertFalse(echo.isOwnEcho(99_999L))
    }

    @Test fun noInputAfterSessionStartLeavesHumanTouchHuman() {
        // Models the host rule that needs a genuinely recent interaction:
        // with no own dispatch recorded, any touch is a real user touch.
        val echo = PhoneOwnInputEcho()
        assertFalse(echo.isOwnEcho(123_456L))
    }
}
