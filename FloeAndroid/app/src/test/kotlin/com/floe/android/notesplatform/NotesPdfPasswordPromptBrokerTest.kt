// SPDX-License-Identifier: MPL-2.0
package com.floe.android.notesplatform

import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class NotesPdfPasswordPromptBrokerTest {
    @Test fun answerTransfersCopyAndClearsCallerBuffer() = runBlocking {
        val broker = NotesPdfPasswordPromptBroker { true }
        val task = async(start = CoroutineStart.UNDISPATCHED) { broker.requestPassword("protected.pdf") }
        val input = "test-password".toCharArray()
        assertTrue(broker.answer(broker.prompt.value!!.id, input))
        assertTrue(input.all { it == '\u0000' })
        val result = task.await()!!
        assertEquals("test-password", String(result))
        result.fill('\u0000')
        assertNull(broker.prompt.value)
    }

    @Test fun cancelledRequestFencesLateAnswer() = runBlocking {
        val broker = NotesPdfPasswordPromptBroker { true }
        val task = async(start = CoroutineStart.UNDISPATCHED) { broker.requestPassword("one.pdf") }
        val old = broker.prompt.value!!.id
        task.cancelAndJoin()
        assertNull(broker.prompt.value)
        val input = "late".toCharArray()
        assertFalse(broker.answer(old, input))
        assertTrue(input.all { it == '\u0000' })
    }

    @Test fun explicitCancelKeepsBrokerUsableAndDoesNotRetargetOldAnswer() = runBlocking {
        val broker = NotesPdfPasswordPromptBroker { true }
        val first = async(start = CoroutineStart.UNDISPATCHED) { broker.requestPassword("one.pdf") }
        val old = broker.prompt.value!!.id
        broker.cancelPending()
        assertNull(first.await())
        val next = async(start = CoroutineStart.UNDISPATCHED) { broker.requestPassword("two.pdf") }
        val current = broker.prompt.value!!.id
        assertNotEquals(old, current)
        assertFalse(broker.answer(old, "old".toCharArray()))
        assertEquals(current, broker.prompt.value!!.id)
        broker.cancelPending(current)
        assertNull(next.await())
    }

    @Test fun noForegroundOrRootDoesNotPublishPrompt() = runBlocking {
        val broker = NotesPdfPasswordPromptBroker { false }
        assertNull(broker.requestPassword("protected.pdf"))
        assertNull(broker.prompt.value)
    }
}
