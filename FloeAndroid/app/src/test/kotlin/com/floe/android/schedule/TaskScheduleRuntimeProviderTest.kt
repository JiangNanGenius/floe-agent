// SPDX-License-Identifier: MPL-2.0
package com.floe.android.schedule

import com.floe.android.host.ScheduleEnvironmentAdmission
import com.floe.android.host.ScheduleEnvironmentWire
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure tests for the REAL runtime environment authority reader and the
 * after-success run-choice projection. They pin the closed refusal vocabulary,
 * metadata pass-through, malformed/empty semantics, bounds and the
 * authority-vs-visual precedence without Android, JNI or a runtime.
 */
class TaskScheduleRuntimeProviderTest {

    private fun obj(raw: String): JsonObject = Json.parseToJsonElement(raw) as JsonObject

    private fun jsonString(raw: String): String = raw.trimIndent()

    // ------------------------------------------------------- environment wire

    @Test
    fun projectMetadataKeepsEveryAuthorityField() {
        val parsed = ScheduleEnvironmentWire.parse(jsonString(
            """
            {"baseRevision":"rev-1","environments":[
             {"id":"env-1","kind":"project","ownerID":"11111111-1111-1111-1111-111111111111",
              "name":"Project env","state":"active","requiresRebuild":false,
              "executionBackend":"linuxPRoot","parentID":null,"templateID":"t1",
              "bytes":1234,"packageCount":7}]}
            """,
        ))
        assertTrue(parsed is TaskScheduleEnvironmentResult.Available)
        val row = (parsed as TaskScheduleEnvironmentResult.Available).environments.single()
        assertEquals("env-1", row.id)
        assertEquals("project", row.kind)
        assertEquals("11111111-1111-1111-1111-111111111111", row.ownerID)
        assertEquals("Project env", row.name)
        assertEquals("active", row.state)
        assertFalse(row.requiresRebuild)
        assertEquals("linuxPRoot", row.executionBackend)
        assertNull(row.parentID)
    }

    @Test
    fun anAuthoritativelyEmptyListStaysAvailable() {
        val parsed = ScheduleEnvironmentWire.parse(
            """{"baseRevision":"rev-1","environments":[]}""")
        assertTrue(parsed is TaskScheduleEnvironmentResult.Available)
        assertTrue((parsed as TaskScheduleEnvironmentResult.Available).environments.isEmpty())
    }

    @Test
    fun malformedRepliesNeverBecomeAnEmptySuccess() {
        assertEquals(
            TaskScheduleEnvironmentResult.Unavailable("metadataMalformed"),
            ScheduleEnvironmentWire.parse("not-json"),
        )
        assertEquals(
            TaskScheduleEnvironmentResult.Unavailable("metadataMalformed"),
            ScheduleEnvironmentWire.parse("""{"baseRevision":"rev-1"}"""),
        )
        assertEquals(
            TaskScheduleEnvironmentResult.Unavailable("metadataMalformed"),
            ScheduleEnvironmentWire.parse("""{"environments":{}}"""),
        )
        // Rows exist but none is a usable identity: malformed, not "none".
        assertEquals(
            TaskScheduleEnvironmentResult.Unavailable("metadataMalformed"),
            ScheduleEnvironmentWire.parse(
                """{"environments":[{"kind":"project","state":"active","requiresRebuild":false}]}""",
            ),
        )
    }

    @Test
    fun unknownKindsAndOversizedIdentifiersAreDroppedWithoutCoercion() {
        val parsed = ScheduleEnvironmentWire.parse(jsonString(
            """
            {"environments":[
             {"id":"env-ok","kind":"project","name":"Kept","state":"active","requiresRebuild":false,
              "executionBackend":"linuxPRoot"},
             {"id":"env-kind","kind":"sandbox","name":"Bad kind","state":"active","requiresRebuild":false},
             {"id":"${"x".repeat(129)}","kind":"project","name":"Too long","state":"active","requiresRebuild":false},
             {"id":"env-norebuild","kind":"project","name":"No flag","state":"active"},
             {"id":"env-session","kind":"session","ownerID":"c1","name":"Session","state":"active",
              "requiresRebuild":false,"executionBackend":"linuxPRoot","parentID":"env-ok"}]}
            """,
        ))
        val rows = (parsed as TaskScheduleEnvironmentResult.Available).environments
        assertEquals(listOf("env-ok", "env-session"), rows.map { it.id })
        assertEquals("env-ok", rows[1].parentID)
    }

    @Test
    fun theAuthorityListIsBoundedToTheWireCap() {
        val rows = (0 until 150).joinToString(",") { index ->
            """{"id":"env-$index","kind":"project","name":"Env $index","state":"active","requiresRebuild":false,"executionBackend":"linuxPRoot"}"""
        }
        val parsed = ScheduleEnvironmentWire.parse("""{"environments":[$rows]}""")
        val environments = (parsed as TaskScheduleEnvironmentResult.Available).environments
        assertEquals(ScheduleEnvironmentWire.MAX_ROWS, environments.size)
        assertEquals("env-0", environments.first().id)
        assertEquals("env-99", environments.last().id)
    }

    // ---------------------------------------------------------- admission gate

    @Test
    fun healthyExactBuildFactsAdmitTheRead() {
        assertNull(
            ScheduleEnvironmentAdmission.refusal(
                componentRefusal = null,
                protocol = 1,
                expectedProtocol = 1,
                identity = "runtime:pid42:gen" + "a".repeat(32),
                installPhase = "installed",
                rootfsReceiptDigest = "b".repeat(64),
                peerWellFormed = true,
                peerUid = 10123,
                ownUid = 10000,
            ),
        )
    }

    @Test
    fun staleOrMissingComponentIsRefusedBeforeAnyConnection() {
        assertEquals(
            "componentVersionStale",
            ScheduleEnvironmentAdmission.refusal(
                componentRefusal = "componentVersionStale",
                protocol = 1, expectedProtocol = 1,
                identity = "runtime:pid1:gen" + "a".repeat(32),
                installPhase = "installed", rootfsReceiptDigest = "b".repeat(64),
                peerWellFormed = true, peerUid = 10, ownUid = 1,
            ),
        )
        assertEquals(
            "componentIdentityMismatch",
            ScheduleEnvironmentAdmission.refusal(
                componentRefusal = "componentIdentityMismatch",
                protocol = 1, expectedProtocol = 1,
                identity = null, installPhase = null, rootfsReceiptDigest = null,
                peerWellFormed = false, peerUid = -1, ownUid = 1,
            ),
        )
    }

    @Test
    fun everyReadinessFailureHasItsOwnClosedToken() {
        fun refused(
            protocol: Int = 1,
            identity: String? = "runtime:pid42:gen" + "a".repeat(32),
            phase: String? = "installed",
            receipt: String? = "b".repeat(64),
            peerOk: Boolean = true,
            peerUid: Int = 10,
        ): String? = ScheduleEnvironmentAdmission.refusal(
            componentRefusal = null,
            protocol = protocol, expectedProtocol = 1,
            identity = identity, installPhase = phase,
            rootfsReceiptDigest = receipt, peerWellFormed = peerOk,
            peerUid = peerUid, ownUid = 1,
        )

        assertEquals("engineProtocolUnsupported", refused(protocol = 2))
        assertEquals("engineIdentityUnreported", refused(identity = null))
        assertEquals("engineIdentityUnreported", refused(identity = ""))
        assertEquals("rootfsUnverified", refused(phase = "failed"))
        assertEquals("rootfsUnverified", refused(receipt = "not-a-digest"))
        assertEquals("peerUnverified", refused(peerOk = false))
        assertEquals("peerUnverified", refused(peerUid = -1))
        assertEquals("peerUnverified", refused(peerUid = 1))
    }

    @Test
    fun processIdentityRequiresARealPidAnd32HexBootNonce() {
        val boot = "0123456789abcdef0123456789abcdef"
        assertEquals(
            "runtime:pid77:gen$boot",
            ScheduleEnvironmentAdmission.processIdentity(77, boot),
        )
        assertNull(ScheduleEnvironmentAdmission.processIdentity(0, boot))
        assertNull(ScheduleEnvironmentAdmission.processIdentity(-3, boot))
        assertNull(ScheduleEnvironmentAdmission.processIdentity(77, "abc"))
        assertNull(ScheduleEnvironmentAdmission.processIdentity(77, boot.uppercase()))
    }

    // -------------------------------------------------- after-success options

    @Test
    fun optionsDecodeRealRunChoicesAndDropRunlessRows() {
        val options = TaskScheduleWire.options(obj(
            """
            {"workspaces":[],"models":[],"environments":[],
             "runChoices":[
              {"runID":"11111111-1111-1111-1111-111111111111",
               "conversationID":"22222222-2222-2222-2222-222222222222",
               "label":"Quarterly report","state":"streamingModel",
               "startedAt":"2026-10-31T01:02:03.000Z",
               "workspaceID":"33333333-3333-3333-3333-333333333333"},
              {"label":"missing run id","state":"streamingModel"},
              {"runID":"44444444-4444-4444-4444-444444444444","label":""}],
             "defaultModelID":null,"currentTimezone":"UTC",
             "environmentSelectionAvailable":false}
            """,
        ))
        assertEquals(2, options.runChoices.size)
        val first = options.runChoices.first()
        assertEquals("Quarterly report", first.label)
        assertEquals("streamingModel", first.state)
        assertEquals(1_793_408_523_000L, first.startedAtMillis)
        assertEquals("33333333-3333-3333-3333-333333333333", first.workspaceID)
        assertEquals("44444444-4444-4444-4444-444444444444", options.runChoices[1].runID)
        assertEquals("", options.runChoices[1].label)
    }

    @Test
    fun nativeRunChoicesWinAndTheProjectFilterIsPresentationOnly() {
        val native = listOf(
            TaskScheduleRunChoice("a", "Native A", workspaceID = "ws-1"),
            TaskScheduleRunChoice("b", "Native B", workspaceID = "ws-2"),
            TaskScheduleRunChoice("c", "Native C", workspaceID = null),
        )
        val visual = listOf(
            TaskScheduleRunChoice("a", "Holder A", workspaceID = "ws-2"),
            TaskScheduleRunChoice("d", "Holder D", workspaceID = "ws-1"),
        )
        val forProjectOne = availableRunChoices(native, visual, "ws-1")
        assertEquals(listOf("a", "c", "d"), forProjectOne.map { it.runID })
        assertEquals("Native A", forProjectOne.first().label)

        val unbound = availableRunChoices(native, visual, null)
        assertEquals(listOf("a", "b", "c", "d"), unbound.map { it.runID })

        assertTrue(availableRunChoices(emptyList(), emptyList(), "ws-1").isEmpty())
    }

    @Test
    fun queuedRunNowResultIsATruthfulAcceptedRequestButNotALaunch() {
        val queued = TaskScheduleWire.dispatch(obj(
            """
            {"state":"queued","scheduleID":"s1","occurrenceID":"o1","runID":null,
             "conversationID":null,"nextFireAt":null,"code":null,
             "reason":"The task is queued and starts when the background dispatcher admits it."}
            """,
        ))
        assertTrue(queued?.queued == true)
        assertTrue(queued?.accepted == true)
        assertFalse(queued?.launched == true)

        val waiting = TaskScheduleWire.dispatch(obj(
            """{"state":"waiting","scheduleID":"s1","code":"exactAlarmPermission"}""",
        ))
        assertFalse(waiting?.accepted == true)
    }
}
