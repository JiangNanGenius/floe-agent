// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.sftp

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class C05SFTPClientTest {
    private val json = Json { ignoreUnknownKeys = true }

    private class RecordingTransport(
        private val response: String,
    ) : C05SFTPTransport {
        var request: String = ""
        override fun exchange(request: String): String {
            this.request = request
            return response
        }
    }

    private val owner = C05SFTPOwner(
        token = "test-owner-123", nativeEpoch = 7, taskID = "00000000-0000-0000-0000-000000000001")

    @Test
    fun capabilitiesUseChannel18() {
        val transport = RecordingTransport(
            """{"ok":true,"coreReady":true,"maximumLanes":8,"schema":"floe.sftp/18"}"""
        )
        val client = C05SFTPClient(transport)
        assertTrue(client.capabilities())
        val objectValue = json.parseToJsonElement(transport.request).jsonObject
        assertEquals("18", objectValue["version"]!!.jsonPrimitive.content)
        assertEquals("c05.sftp.capabilities", objectValue["operation"]!!.jsonPrimitive.content)
    }

    @Test
    fun listParsesEntriesAndBounds() {
        val transport = RecordingTransport(
            """{"ok":true,"operation":"c05.sftp.list","path":"/home/test","canonicalPath":"/home/test","entries":[{"name":"a.txt","path":"/home/test/a.txt","isDirectory":false,"bytes":3,"revision":"sftp1:3:1:0"}],"nextOffset":1,"truncated":false}"""
        )
        val client = C05SFTPClient(transport)
        val page = client.list("lane-1", "/home/test", 0, 50, owner)
        assertEquals("/home/test", page.path)
        assertEquals(1, page.entries.size)
        assertEquals("a.txt", page.entries[0].name)
        val request = json.parseToJsonElement(transport.request).jsonObject
        assertEquals("lane-1", request["laneID"]!!.jsonPrimitive.content)
        assertEquals("7", request["owner"]!!.jsonObject["nativeEpoch"]!!.jsonPrimitive.content)
    }

    @Test
    fun failureCarriesHostKeyChallenge() {
        val transport = RecordingTransport(
            """{"ok":false,"code":"hostKeyChallenge","reason":"hostKeyConfirmationRequired","retryable":false,"challenge":{"id":"00000000-0000-0000-0000-00000000000a","profileID":"00000000-0000-0000-0000-00000000000b","address":"lab.example","port":22,"keyType":"ssh-ed25519","fingerprintSHA256":"SHA256:new","kind":"firstUse"}}"""
        )
        val client = C05SFTPClient(transport)
        try {
            client.connect("00000000-0000-0000-0000-00000000000b", owner)
            fail("expected failure")
        } catch (failure: C05SFTPFailure) {
            assertEquals("hostKeyChallenge", failure.code)
            assertEquals("SHA256:new", failure.challenge?.fingerprintSHA256)
            assertEquals(false, failure.challenge?.changed)
        }
    }

    @Test
    fun uploadChunkIsBoundedAndBase64Encoded() {
        val transport = RecordingTransport(
            """{"ok":true,"operation":"c05.sftp.upload.write","transfer":{"id":"t1","kind":"upload","remotePath":"/home/test/a","displayName":"a","state":"running","bytesDone":3,"totalBytes":3}}"""
        )
        val client = C05SFTPClient(transport)
        client.writeUpload("t1", 0, byteArrayOf(1, 2, 3), owner)
        val request = json.parseToJsonElement(transport.request).jsonObject
        assertEquals("AQID", request["dataBase64"]!!.jsonPrimitive.content)
        assertEquals("0", request["offset"]!!.jsonPrimitive.content)
    }
}
