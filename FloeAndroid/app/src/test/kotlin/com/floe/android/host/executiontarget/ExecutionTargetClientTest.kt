// SPDX-License-Identifier: MPL-2.0
//
// C02 wire-client tests. The fake transport returns canned trusted-host JSON
// and the exact request is inspected; no native bridge, SSH or App action is
// invoked.
package com.floe.android.host.executiontarget

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class ExecutionTargetClientTest {
    private val json = Json { ignoreUnknownKeys = true }

    private class Recorder(
        private val responder: (String) -> String,
    ) : C02TargetTransport {
        val requests = mutableListOf<String>()
        override fun exchange(request: String): String {
            requests += request
            return responder(request)
        }
    }

    @Test
    fun snapshotParsesTargetAndNeverSendsAPath() {
        val recorder = Recorder {
            """
            {"ok":true,"schema":"floe.target/19","taskID":"11111111-1111-1111-1111-111111111111",
             "remoteExecutionAllowed":true,"hasUsableLocalEnvironment":true,"canCreateInitialTarget":true,
             "localEnvironments":[{"id":"env-a","name":"Linux A","kind":"session","state":"active","requiresRebuild":false}],
             "remoteHosts":[{"id":"22222222-2222-2222-2222-222222222222","displayName":"Build host","isExecutionEnvironment":true,"sshConfigured":true}],
             "target":{"taskID":"11111111-1111-1111-1111-111111111111","revision":3,"kind":"localLinux",
               "environmentID":"env-a","workspaceID":"33333333-3333-3333-3333-333333333333",
               "rootEpoch":7,"provenance":"migrated","remoteOS":null,"remoteHostID":null}}
            """.trimIndent()
        }
        val client = C02TargetClient(recorder)
        val snapshot = client.snapshot("11111111-1111-1111-1111-111111111111")
        assertEquals(3L, snapshot.target?.revision)
        assertEquals("localLinux", snapshot.target?.kind)
        assertEquals("env-a", snapshot.localEnvironments.single().id)
        assertEquals("Build host", snapshot.remoteHosts.single().displayName)
        val request = json.parseToJsonElement(recorder.requests.single()).jsonObject
        assertEquals(19, request["version"]!!.jsonPrimitive.content.toInt())
        assertEquals("c02.target.snapshot", request["operation"]!!.jsonPrimitive.content)
        assertFalse(recorder.requests.single().contains("remoteRootPath"))
        assertFalse(recorder.requests.single().contains("/home/"))
    }

    @Test
    fun initializeSendsOnlyTrustedIDsAndExplicitChoice() {
        val recorder = Recorder {
            """{"ok":true,"target":{"taskID":"11111111-1111-1111-1111-111111111111","revision":1,
               "kind":"localLinux","environmentID":"env-a","workspaceID":"33333333-3333-3333-3333-333333333333",
               "rootEpoch":7,"provenance":"explicitUserSelection"}}"""
        }
        val client = C02TargetClient(recorder)
        val target = client.initialize(
            taskID = "11111111-1111-1111-1111-111111111111",
            kind = "localLinux",
            environmentID = "env-a",
            hostID = null,
        )
        assertEquals(1L, target.revision)
        val request = json.parseToJsonElement(recorder.requests.single()).jsonObject
        val destination = request["destination"]!!.jsonObject
        assertEquals("localLinux", destination["kind"]!!.jsonPrimitive.content)
        assertTrue(destination["explicitUserChoice"]!!.jsonPrimitive.boolean)
        assertEquals("env-a", destination["environmentID"]!!.jsonPrimitive.content)
        assertFalse(destination.containsKey("remoteRootPath"))
        assertFalse(destination.containsKey("workspaceRoot"))
    }

    @Test
    fun migrationRequestCarriesRevisionAndTimeout() {
        val recorder = Recorder {
            """{"ok":true,"target":{"taskID":"11111111-1111-1111-1111-111111111111","revision":4,
               "kind":"ssh","environmentID":"ssh-host","workspaceID":"33333333-3333-3333-3333-333333333333",
               "rootEpoch":7,"provenance":"migrated","remoteHostID":"22222222-2222-2222-2222-222222222222",
               "remoteOS":"linux","remoteArchitecture":"aarch64","remoteGeneration":"boot-1"},
               "migration":{"id":"44444444-4444-4444-4444-444444444444","taskID":"11111111-1111-1111-1111-111111111111",
               "phase":"committed","revision":4,"cancellationRequested":false,
               "affectedWork":{"liveRuns":0,"liveChildRuns":0,"activeJobs":0,"shellSessions":0,"managedServices":0,"unknownOutcomes":0,"files":0,"bytes":0},
               "source":{"taskID":"11111111-1111-1111-1111-111111111111","revision":3,"kind":"localLinux","environmentID":"env-a","workspaceID":"33333333-3333-3333-3333-333333333333","rootEpoch":7,"provenance":"explicitUserSelection"},
               "destination":{"taskID":"11111111-1111-1111-1111-111111111111","revision":4,"kind":"ssh","environmentID":"ssh-host","workspaceID":"33333333-3333-3333-3333-333333333333","rootEpoch":7,"provenance":"migrated","remoteHostID":"22222222-2222-2222-2222-222222222222"}}}"""
        }
        val client = C02TargetClient(recorder)
        val receipt = client.beginMigration(
            taskID = "11111111-1111-1111-1111-111111111111",
            expectedRevision = 3,
            kind = "ssh",
            environmentID = null,
            hostID = "22222222-2222-2222-2222-222222222222",
            drainTimeoutSeconds = 45,
        )
        assertEquals("committed", receipt.migration?.phase)
        assertEquals(4L, receipt.target.revision)
        val request = json.parseToJsonElement(recorder.requests.single()).jsonObject
        assertEquals(3L, request["expectedRevision"]!!.jsonPrimitive.long)
        assertEquals(45, request["drainTimeoutSeconds"]!!.jsonPrimitive.content.toInt())
        assertFalse(request.containsKey("remoteRootPath"))
    }

    @Test
    fun failureSurfacesChallengeWithoutTrustingIt() {
        val recorder = Recorder {
            """{"ok":false,"code":"hostKeyApprovalRequired","retryable":false,
               "message":"Confirm the SSH host key before using this host.",
               "challenge":{"id":"55555555-5555-5555-5555-555555555555",
                 "taskID":"11111111-1111-1111-1111-111111111111",
                 "hostID":"22222222-2222-2222-2222-222222222222",
                 "address":"host.example","port":22,"keyType":"ssh-ed25519",
                 "fingerprintSHA256":"SHA256:abcdefghijklmnopqrstuvwxyz0123456789",
                 "kind":"firstUse","expiresAt":"2026-11-02T00:00:00.000Z"}}"""
        }
        val client = C02TargetClient(recorder)
        try {
            client.checkMigration(
                taskID = "11111111-1111-1111-1111-111111111111",
                expectedRevision = 1,
                kind = "ssh",
                environmentID = null,
                hostID = "22222222-2222-2222-2222-222222222222",
            )
            fail("expected host-key challenge")
        } catch (failure: C02TargetFailure) {
            assertEquals("hostKeyApprovalRequired", failure.code)
            assertEquals("ssh-ed25519", failure.challenge?.keyType)
            assertEquals("firstUse", failure.challenge?.kind)
        }
    }
}
