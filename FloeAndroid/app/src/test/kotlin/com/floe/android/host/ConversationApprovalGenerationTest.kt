// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.*
import org.junit.Test

class ConversationApprovalGenerationTest {
    private val conversation = "11111111-1111-4111-8111-111111111111"
    private val run = "22222222-2222-4222-8222-222222222222"
    private val generation = "33333333-3333-4333-8333-333333333333"
    private val descriptor = "a".repeat(64)

    private fun page(
        gen: String = generation,
        revision: String = "generation:$gen",
        tool: String = "device.act",
        presentationGen: String = gen,
        details: String = """{"action":"back"}""",
        detailStatus: String = "available",
    ): ConversationWire.SnapshotPage {
        val json = """{"conversationID":"$conversation","runID":"$run","durableState":"waitingApproval",
          "revision":{"resourceID":"run.$run","version":"waitingApproval"},"isTerminal":false,
          "liveOwner":true,"durableWatermark":10,"pendingInputs":[],
          "pendingApproval":{"callID":"c1","tool":"$tool","reason":"Review","requestedAt":"2026-01-01T00:00:00Z",
          "generation":"$gen","presentation":{"status":"available","generation":"$presentationGen","tool":"$tool",
          "effect":"mutating","isSideEffecting":true,"riskLabels":[],"requestedScope":"local",
          "grantScope":"singleUse","workspaceVerified":false,"descriptorIdentity":"$descriptor",
          "detailStatus":"$detailStatus","actionDetails":$details}},
          "approvalRevision":{"resourceID":"approval.c1","version":"$revision"}}"""
        return requireNotNull(ConversationWire.decodeSnapshotPage(Json.parseToJsonElement(json)))
    }

    private fun builder() = ThreadProjectionBuilder(conversation).apply { selectedRunId = run }

    @Test fun exactActionAndPackageComeOnlyFromSameGenerationSnapshot() {
        val builder = builder()
        builder.applySnapshot(page(details = """{"action":"launch","packageName":"org.example.editor"}"""))
        val card = builder.build().pendingApprovals.single()
        assertTrue(card.identityVerified)
        assertTrue(card.scopeVerified)
        assertEquals("launch", card.actionKind)
        assertEquals("org.example.editor", card.actionPackage)
        assertEquals("generation:$generation", card.approvalRevision)
        assertEquals(card, builder.approvalBinding(run, "c1"))
    }

    @Test fun incompleteOrUnboundDetailsNeverAuthorizeAllow() {
        val pages = listOf(
            page(presentationGen = "44444444-4444-4444-8444-444444444444"),
            page(revision = "2026-01-01T00:00:00Z"),
            page(detailStatus = "unavailable"),
            page(details = """{"action":"launch","packageName":"org.example.app","extra":"x"}"""),
            page(tool = "workspace.writeFile"),
        )
        for (snapshot in pages) {
            val builder = builder()
            builder.applySnapshot(snapshot)
            assertFalse(builder.build().pendingApprovals.single().scopeVerified)
        }
    }

    @Test fun unversionedEventsCannotSupplyScopeOrRetireCurrentGeneration() {
        val builder = builder()
        val frame = HostRunEventFrame(runID = run, sequence = 5, kind = "approval",
            payload = Json.parseToJsonElement("""{"callID":"c1","tool":"device.act","scope":"other-app"}""").jsonObject,
            bytes = 0)
        builder.applyRunEvent(frame)
        assertTrue(builder.build().pendingApprovals.isEmpty())
        builder.applySnapshot(page())
        val card = builder.build().pendingApprovals.single()
        builder.applyRunEvent(frame.copy(sequence = 11,
            payload = Json.parseToJsonElement("""{"callID":"c1","outcome":"allowed"}""").jsonObject))
        assertEquals(card, builder.build().pendingApprovals.single())
    }

    @Test fun snapshotsAreImmutableAcrossGenerationChanges() {
        val builder = builder()
        builder.applySnapshot(page())
        val first = builder.build()
        val replacement = "44444444-4444-4444-8444-444444444444"
        builder.applySnapshot(page(gen = replacement))
        assertEquals(generation, first.pendingApprovals.single().requestGeneration)
        assertEquals(replacement, builder.build().pendingApprovals.single().requestGeneration)
    }
}
