// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PhoneControlJsonTest {
    @Test
    fun passwordFieldIsAbsentFromTheAgentJson() {
        val shaped = PhoneControlTreeShaper.shape(
            raw = listOf(
                testRawNode(path = emptyList(), className = "android.widget.FrameLayout"),
                testRawNode(
                    path = listOf(0),
                    password = true,
                    text = "hunter2",
                    contentDescription = "PIN 1234",
                    viewId = "com.example.app:id/password",
                ),
            ),
            request = PhoneControlObserveRequest(),
            redactAllText = false,
            depthLimited = false,
            nodeLimited = false,
        )
        val observation = testObservation(nodes = shaped.nodes)
        val json = PhoneControlJson.observation(observation)
        assertFalse(json.contains("hunter2"))
        assertFalse(json.contains("PIN 1234"))
        val root = JSONObject(json)
        assertEquals(PhoneControlJson.OBSERVATION_SCHEMA, root.getString("schema"))
        assertEquals(2, root.getJSONArray("nodes").length())
        val field = root.getJSONArray("nodes").getJSONObject(1)
        assertTrue(field.isNull("text"))
        assertTrue(field.isNull("contentDescription"))
        assertTrue(field.getBoolean("password"))
        assertTrue(field.getBoolean("redacted"))
    }

    @Test
    fun actionReceiptNeverEchoesSetTextPayload() {
        val action = PhoneControlAction.SetText("n1", "very-secret-payload")
        assertFalse(action.toString().contains("very-secret-payload"))
        val result = PhoneControlActionResult(
            action = action.wireName,
            dispatch = PhoneControlDispatch.ACCEPTED,
            gestureCompleted = null,
            observation = testObservation(),
            screenChanged = true,
            note = "re-observed",
        )
        val json = PhoneControlJson.actionResult(result)
        assertFalse(json.contains("very-secret-payload"))
        val root = JSONObject(json)
        assertEquals("setText", root.getString("action"))
        assertEquals("ACCEPTED", root.getString("dispatch"))
        assertTrue(root.getBoolean("screenChanged"))
        assertEquals(
            PhoneControlJson.OBSERVATION_SCHEMA,
            root.getJSONObject("observation").getString("schema"),
        )
    }

    @Test
    fun ownerJsonUsesOnlyTaskAndRunIdentity() {
        val status = PhoneControlStatus(
            connected = true,
            enabled = true,
            blocker = null,
            activeOwner = testOwner(),
            fenceGeneration = 9,
            pageGeneration = 10,
            screenshotSupport = PhoneControlScreenshotSupport.WINDOW,
        )
        val root = JSONObject(PhoneControlJson.status(status))
        assertEquals(PhoneControlJson.STATUS_SCHEMA, root.getString("schema"))
        assertEquals(9L, root.getLong("fenceGeneration"))
        assertEquals("WINDOW", root.getString("screenshotSupport"))
        val owner = root.getJSONObject("activeOwner")
        assertEquals(
            "11111111-1111-1111-1111-111111111111",
            owner.getString("taskID"),
        )
        assertEquals(
            "22222222-2222-2222-2222-222222222222",
            owner.getString("runID"),
        )
        assertFalse(owner.has("environmentID"))
        assertFalse(owner.has("jobID"))
    }

    @Test
    fun transportCapIsExplicitRatherThanSilentlyDroppingNodes() {
        val nodes = (0 until 310).map { index ->
            testNode(ref = "n$index", depth = index)
        }
        val json = PhoneControlJson.observation(testObservation(nodes = nodes))
        val root = JSONObject(json)
        assertEquals(310, root.getInt("nodeCount"))
        assertEquals(300, root.getJSONArray("nodes").length())
        assertTrue(root.getBoolean("transportTruncated"))
    }
}
