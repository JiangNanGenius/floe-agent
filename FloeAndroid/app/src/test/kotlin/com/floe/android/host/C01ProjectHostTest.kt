// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * C01 project host projection. Authored NOTRUN — Main runs the focused JVM
 * filter. Pure wire/payload checks only; the native library owns all durable
 * CAS, root, assignment and deletion authority.
 */
class C01ProjectHostTest {

    private val projectId = "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9"

    @Test
    fun projectRevisionIsTheOuterResourceAndTheExactPersistedUpdatedAt() {
        val revision = ProjectWire.revision(projectId.lowercase(),
            "2026-11-02T00:00:00.000Z")
        assertEquals("project.0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9", revision.resourceID)
        assertEquals("2026-11-02T00:00:00.000Z", revision.version)
    }

    @Test
    fun listPayloadCarriesOnlyBoundedLimitAndOffset() {
        val payload = ProjectWire.listPayload(limit = 100, offset = 0)
        assertEquals(setOf("limit", "offset"), payload.keys)
        assertEquals("100", payload["limit"].toString())
        assertEquals("0", payload["offset"].toString())
    }

    @Test
    fun listDecodeKeepsExactRevisionAndTaskCountAndDropsMalformedRows() {
        val value = Json.parseToJsonElement(
            """
            {"projects":[
              {"projectID":"$projectId","name":"Alpha","revision":"2026-11-02T00:00:00.000Z","createdAt":"2026-11-01T00:00:00.000Z","updatedAt":"2026-11-02T00:00:00.000Z","taskCount":3},
              {"projectID":"MISSING-REVISION","name":"Bad"},
              {"name":"No identity","revision":"x"}
            ],"hasMore":false}
            """.trimIndent(),
        )
        val rows = checkNotNull(ProjectWire.decodeList(value))
        assertEquals(1, rows.size)
        assertEquals(projectId, rows.single().id)
        assertEquals("2026-11-02T00:00:00.000Z", rows.single().revision)
        assertEquals(3, rows.single().taskCount)
        assertNull(ProjectWire.decodeList(Json.parseToJsonElement("{}")))
    }

    @Test
    fun detailDecodeReportsRootStateTasksAndTruncationWithoutInventingData() {
        val value = Json.parseToJsonElement(
            """
            {"projectID":"$projectId","name":"Alpha","revision":"rev-1",
             "createdAt":"c","updatedAt":"rev-1","taskCount":2,
             "rootState":"missing","rootIssue":"workspaceComponentUnsafe",
             "tasksTruncated":true,
             "tasks":[
               {"conversationID":"C1","title":"Pinned","purpose":"ordinary","updatedAt":"u1","pinned":true,"archived":false},
               {"conversationID":"C2","title":"Old","purpose":"ordinary","updatedAt":"u2","pinned":false,"archived":true}
             ]}
            """.trimIndent(),
        )
        val detail = checkNotNull(ProjectWire.decodeDetail(value))
        assertEquals("missing", detail.rootState)
        assertEquals("workspaceComponentUnsafe", detail.rootIssue)
        assertTrue(detail.tasksTruncated)
        assertEquals(listOf("C1", "C2"), detail.tasks.map { it.conversationId })
        assertTrue(detail.tasks[0].pinned)
        assertTrue(detail.tasks[1].archived)
        assertNull(ProjectWire.decodeDetail(Json.parseToJsonElement("{}")))
    }

    @Test
    fun assignmentRequiresAnExplicitAssignedAcknowledgement() {
        val assigned = ProjectWire.decodeAssignment(Json.parseToJsonElement(
            """
            {"projectID":"$projectId","conversationID":"C1","revision":"rev-2",
             "assigned":true,"alreadyAssigned":false,"filesMoved":false,
             "fenceSettled":true}
            """.trimIndent()), projectId)
        val receipt = checkNotNull(assigned)
        assertTrue(receipt.assigned)
        assertFalse(receipt.alreadyAssigned)
        assertNull(ProjectWire.decodeAssignment(Json.parseToJsonElement(
            """{"projectID":"$projectId","assigned":false}"""), projectId))
    }

    @Test
    fun deleteReceiptCarriesRetainedRootAndHonestRemovalFailure() {
        val retained = checkNotNull(ProjectWire.decodeDelete(Json.parseToJsonElement(
            """
            {"projectID":"$projectId","deleted":true,"rootRetained":true,
             "retainedRelativeRoot":"Projects/$projectId","fencesSettled":true}
            """.trimIndent()), projectId))
        assertTrue(retained.deleted)
        assertTrue(retained.rootRetained)
        assertEquals("Projects/$projectId", retained.retainedRelativeRoot)
        assertNull(retained.rootRemoveError)

        val failed = checkNotNull(ProjectWire.decodeDelete(Json.parseToJsonElement(
            """
            {"projectID":"$projectId","deleted":true,"rootRetained":true,
             "rootRemoval":"failed","rootRemoveError":"rmdirFailed:39"}
            """.trimIndent()), projectId))
        assertTrue(failed.rootRetained)
        assertEquals("failed", failed.rootRemoval)
        assertEquals("rmdirFailed:39", failed.rootRemoveError)
        assertNull(ProjectWire.decodeDelete(Json.parseToJsonElement(
            """{"projectID":"$projectId","deleted":false}"""), projectId))
    }
}
