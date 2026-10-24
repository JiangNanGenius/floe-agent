// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Focused JVM tests for the terminal host controller's settings/lifecycle
 * surface (job-bdebb54ff6ff4403). AUTHORED SOURCE ONLY — not executed by the
 * authoring job. Everything here stays off the native transport: an unbound
 * controller must refuse before any JNI touch, and event routing is driven
 * through [G04TerminalHostController.handleEvent] with descriptor bytes.
 * No Android, no device, no real mailbox.
 */
class G04TerminalHostControllerTest {
    private fun newController(): G04TerminalHostController =
        G04TerminalHostController(CoroutineScope(Dispatchers.Unconfined), { null })

    @Test
    fun unboundControllerRefusesDurableToggleWithoutAnyNativeTouch() = runBlocking {
        val controller = newController()
        val reply = controller.setLanguageEnabled("python", false)
        assertTrue(reply is TerminalActionReply.Refused)
        assertEquals("hostUnbound", (reply as TerminalActionReply.Refused).code)
        // The projection mirrors ONLY committed durable state: an unbound
        // refusal changes nothing (settingsKnown stays false, no local lie).
        assertFalse(controller.languageSettingsSnapshot().settingsKnown)
        assertTrue(controller.isLanguageEnabled("python")) // unknown != disabled
    }

    @Test
    fun refusedCloseRetainsTheActualSessionHandleForReconciliation() = runBlocking {
        val controller = newController()
        // Seed only the existing projection; the unbound controller must
        // refuse before JNI and cannot claim physical session release.
        val field = G04TerminalHostController::class.java.getDeclaredField("sessionTokens")
        field.isAccessible = true
        @Suppress("UNCHECKED_CAST")
        val tokens = field.get(controller) as java.util.concurrent.ConcurrentHashMap<String, String>
        tokens["c1"] = "retained-native-session"
        val reply = controller.closeSession("c1")
        assertTrue(reply is TerminalActionReply.Refused)
        assertEquals("retained-native-session", tokens["c1"])
    }

    @Test
    fun capabilitiesReadBeforeBindYieldsNullAndClearsAvailability() = runBlocking {
        val controller = newController()
        assertNull(controller.capabilitiesFor("c1"))
        assertFalse(controller.availability().bound)
        assertFalse(controller.availability().capabilitiesKnown)
    }

    @Test
    fun parsesHonestDefaultsWhenDurableFieldsAreAbsent() {
        val controller = newController()
        val fields = Json.parseToJsonElement("""{"qualified":false,"attached":false}""") as JsonObject
        val parsed = controller.parseLanguageCapabilities(fields)
        assertFalse("absent settingsKnown must NOT be guessed true", parsed.settingsKnown)
        assertEquals(-1L, parsed.settingsRevision)
        assertTrue(parsed.enabled.isEmpty())
        assertTrue(parsed.serverStates.isEmpty())
    }

    @Test
    fun parsesFullDurableMirrorAndEmptyCodesNormalizeToNull() {
        val controller = newController()
        val fields = Json.parseToJsonElement(
            """{
              "qualified":true,"attached":true,"settingsKnown":true,"settingsRevision":3,
              "languageEnabled":{"python":false,"shell":true,"css":false},
              "serverStates":[
                {"language":"python","state":"unavailable","code":"toolMissing"},
                {"language":"shell","state":"ready","code":""}
              ]
            }""",
        ) as JsonObject
        val parsed = controller.parseLanguageCapabilities(fields)
        assertTrue(parsed.settingsKnown)
        assertEquals(3L, parsed.settingsRevision)
        assertEquals(false, parsed.enabled["python"])
        assertEquals(true, parsed.enabled["shell"])
        assertEquals("toolMissing", parsed.serverStates["python"]?.code)
        assertEquals("ready", parsed.serverStates["shell"]?.state)
        assertNull("empty native code must never surface as an empty label input",
            parsed.serverStates["shell"]?.code)
    }

    @Test
    fun languageStatusEventsFanOutToEverySubscriberAndSurviveRemoval() {
        val controller = newController()
        val first = mutableListOf<TerminalLanguageStatus>()
        val second = mutableListOf<TerminalLanguageStatus>()
        val removeFirst = controller.addLanguageStatusListener { first.add(it) }
        controller.addLanguageStatusListener { second.add(it) }
        val legacy = mutableListOf<TerminalLanguageStatus>()
        controller.setLanguageStatusListener { legacy.add(it) }
        val event = ("""{"type":"lspStatus","conversationID":"c1",""" +
            """"language":"css","state":"ready","code":""}""").toByteArray()
        assertTrue(controller.handleEvent(1L, event))
        assertEquals(1, first.size)
        assertEquals(1, second.size)
        assertEquals(1, legacy.size)
        removeFirst()
        assertTrue(controller.handleEvent(2L, event))
        assertEquals(1, first.size) // removed cleanly (multi-subscriber, no clobber)
        assertEquals(2, second.size)
    }

    @Test
    fun controlOverflowFenceReleasesWaitersAndNeverClaimsBound() {
        val controller = newController()
        val event = """{"type":"hostEventOverflow"}""".toByteArray()
        assertTrue(controller.handleEvent(1L, event))
        // Honest fence: local waiters are refused; availability flips to
        // unbound. Native IO/session receipts remain owned by Core (this
        // asserts NOTHING was fabricated either way).
        assertFalse(controller.availability().bound)
        assertFalse(controller.availability().capabilitiesKnown)
    }

    @Test
    fun malformedDescriptorsAreNotClaimedAsEvents() {
        val controller = newController()
        assertFalse(controller.handleEvent(1L, "not json".toByteArray()))
    }
}
