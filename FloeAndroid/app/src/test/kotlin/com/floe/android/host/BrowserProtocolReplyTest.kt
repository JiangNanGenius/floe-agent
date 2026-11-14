// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test

class BrowserProtocolReplyTest {
    @Test fun webViewStringEnvelopeDeliversReadableSemanticNodes() {
        val snapshot = """{"revision":2,"nodes":[{"role":"h1","text":"Example Domain"},{"role":"a","text":"Learn more"}]}"""
        val wire = JsonPrimitive(snapshot).toString()
        val actual = Json.parseToJsonElement(browserProtocolReply(wire)).jsonObject
        assertEquals("Example Domain", actual["nodes"]!!.jsonArray[0].jsonObject["text"]!!.jsonPrimitive.content)
        assertEquals("a", actual["nodes"]!!.jsonArray[1].jsonObject["role"]!!.jsonPrimitive.content)
    }

    @Test fun statusEventsAndEscapedTextSurviveTransportDecoding() {
        for (value in listOf(
            """{"readyState":"complete","textFound":true,"revision":3}""",
            """[{"method":"Page.loadEventFired","detail":"中文 \\"quoted\\"\\nnext"}]""",
        )) assertEquals(value, browserProtocolReply(JsonPrimitive(value).toString()))
    }

    @Test fun nullObjectsAndInvalidRepliesAreNotInvented() {
        for (value in listOf("null", "{}", "[]", "true", "42", "invalid", "\"unterminated")) {
            assertEquals(value, browserProtocolReply(value))
        }
    }

    @Test fun nestedStringPayloadIsDecodedOnlyOnce() {
        val inner = JsonPrimitive("{\"nodes\":[]}").toString()
        assertEquals(inner, browserProtocolReply(JsonPrimitive(inner).toString()))
    }
}
