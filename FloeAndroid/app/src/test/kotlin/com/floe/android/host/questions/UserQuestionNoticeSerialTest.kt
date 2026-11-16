// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.questions

import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class UserQuestionNoticeSerialTest {
    @Test
    fun notificationSideEffectAndIdentityUpdateCannotInterleaveWithCancellation() {
        val executor = Executors.newFixedThreadPool(2)
        val notifyStarted = CountDownLatch(1)
        val finishNotify = CountDownLatch(1)
        val cancelSubmitted = CountDownLatch(1)
        val events = Collections.synchronizedList(mutableListOf<String>())
        try {
            val post = executor.submit {
                UserQuestionNoticeSerial.run {
                    events.add("notify")
                    notifyStarted.countDown()
                    check(finishNotify.await(5, TimeUnit.SECONDS))
                    events.add("identity")
                }
            }
            assertTrue(notifyStarted.await(5, TimeUnit.SECONDS))
            val cancel = executor.submit {
                cancelSubmitted.countDown()
                UserQuestionNoticeSerial.run { events.add("cancel") }
            }
            assertTrue(cancelSubmitted.await(5, TimeUnit.SECONDS))
            finishNotify.countDown()
            post.get(5, TimeUnit.SECONDS)
            cancel.get(5, TimeUnit.SECONDS)
            assertEquals(listOf("notify", "identity", "cancel"), events.toList())
        } finally {
            finishNotify.countDown()
            executor.shutdownNow()
        }
    }
}
