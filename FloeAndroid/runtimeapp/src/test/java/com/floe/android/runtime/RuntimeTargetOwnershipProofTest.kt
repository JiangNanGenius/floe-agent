// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Registry binding and native lease boundaries for target-only cleanup. */
class RuntimeTargetOwnershipProofTest {

    private val conversationID = "D5D5D5D5-2222-4333-8444-555555555555"
    private val projectID = "3F2A9C41-77B0-4E5D-9A18-2C6B40D1E9F7"
    private val pathDigest = "a".repeat(64)

    private fun project(
        id: String = "c-1",
        ownerID: String = pathDigest,
        name: String = projectID,
        state: String = "active",
    ) = EnvironmentRecordView(id = id, kind = "project", ownerID = ownerID,
        name = name, parentID = null, state = state)

    private fun session(
        id: String = "s-1",
        ownerID: String = conversationID,
        parentID: String? = "c-1",
        state: String = "active",
    ) = EnvironmentRecordView(id = id, kind = "session", ownerID = ownerID,
        name = "", parentID = parentID, state = state)

    /** THE regression: the exact real default private-task registry shape
     *  (project ownerID = path digest, name = canonical project UUID, both
     *  records durably "active", session chained to the project) PROVES the
     *  target. Pre-fix this returned false forever. */
    @Test
    fun realDefaultPrivateTaskRegistryShapeProvesOwnership() {
        assertTrue(proveTargetOwnership(listOf(project(), session()), projectID, conversationID))
    }

    /** A registry that keys the project container by the UUID directly
     *  (alternate binding) also proves — exact string equality only. */
    @Test
    fun uuidKeyedProjectOwnerAlternativeProves() {
        val record = project(ownerID = projectID, name = "")
        assertTrue(proveTargetOwnership(listOf(record, session()), projectID, conversationID))
    }

    /** An empty registry NEVER invents ownership (explicit Main decision). */
    @Test
    fun emptyRegistryNeverInventsOwnership() {
        assertFalse(proveTargetOwnership(emptyList(), projectID, conversationID))
    }

    /** Foreign material only: a different project's container proves nothing
     *  for this target — no first-project fallback, no prefix/name folding. */
    @Test
    fun foreignProjectRecordsRefuse() {
        val foreign = project(id = "c-9", ownerID = "f".repeat(64),
            name = "11111111-2222-4333-8444-555555555555")
        assertFalse(proveTargetOwnership(listOf(foreign, session(parentID = "c-9")),
            projectID, conversationID))
    }

    /** Case-sensitive binding: the canonical uppercase spelling only. */
    @Test
    fun caseFoldedProjectNameRefuses() {
        val folded = project(name = projectID.lowercase())
        assertFalse(proveTargetOwnership(listOf(folded, session()), projectID, conversationID))
    }

    /** A session container bound to ANOTHER project contradicts the claimed
     *  (conversation, project) pairing and refuses the whole proof. */
    @Test
    fun sessionChainedToForeignProjectRefuses() {
        val foreignProject = project(id = "c-2", ownerID = "e".repeat(64),
            name = "22222222-3333-4444-8555-666666666666")
        assertFalse(proveTargetOwnership(
            listOf(project(), foreignProject, session(parentID = "c-2")),
            projectID, conversationID))
    }

    /** `deleting` is the one deferring record state: a teardown genuinely in
     *  progress is never raced by the wipe. */
    @Test
    fun deletingRecordsDefer() {
        assertFalse(proveTargetOwnership(
            listOf(project(state = "deleting"), session()), projectID, conversationID))
        assertFalse(proveTargetOwnership(
            listOf(project(), session(state = "deleting")), projectID, conversationID))
    }

    /** Durable healthy states prove: `active` is the normal persistent state
     *  (not a live-lease signal) and an explicitly `stopped` record is a
     *  settled binding. Liveness is gated by the handshake/supervisor/busy/
     *  live-session checks before this proof. */
    @Test
    fun durableHealthyStatesProve() {
        assertTrue(proveTargetOwnership(
            listOf(project(state = "stopped"), session(state = "stopped")),
            projectID, conversationID))
    }

    /** A project binding with no session records for this conversation still
     *  proves (the session chain rule applies only to existing sessions). */
    @Test
    fun projectBindingWithoutSessionsProves() {
        assertTrue(proveTargetOwnership(listOf(project()), projectID, conversationID))
    }

    /** Another conversation's session records are irrelevant to this
     *  target's proof (they neither chain nor refuse). */
    @Test
    fun foreignConversationSessionsDoNotAffectProof() {
        val foreignSession = session(id = "s-2",
            ownerID = "44444444-5555-4666-8777-888888888888", parentID = null)
        assertTrue(proveTargetOwnership(
            listOf(project(), session(), foreignSession), projectID, conversationID))
    }

    /** The bounded parent walk: a 4-hop chain still binds; a 5-hop chain
     *  refuses (never an unbounded registry scan). */
    @Test
    fun parentChainWalkIsBounded() {
        fun link(id: String, parent: String?) =
            EnvironmentRecordView(id, "session", "x", "", parent, "active")
        val fourHop = listOf(project(),
            session(parentID = "h1"), link("h1", "h2"), link("h2", "h3"), link("h3", "c-1"))
        assertTrue(proveTargetOwnership(fourHop, projectID, conversationID))
        val fiveHop = listOf(project(),
            session(parentID = "h1"), link("h1", "h2"), link("h2", "h3"),
            link("h3", "h4"), link("h4", "c-1"))
        assertFalse(proveTargetOwnership(fiveHop, projectID, conversationID))
    }

    @Test
    fun malformedOrPendingNativeLeaseNeverAllowsCleanup() {
        assertTrue(nativeLeaseStateAllowsCleanup(false, false))
        for (facts in listOf(
            true to false, false to true, true to true,
            null to false, false to null, "false" to false,
            false to "false", 0 to false, false to 0,
        )) {
            assertFalse(nativeLeaseStateAllowsCleanup(facts.first, facts.second))
        }
    }

    @Test
    fun missingOrUnknownRegistryStateRefuses() {
        for (state in listOf("", "unknown", "ACTIVE")) {
            assertFalse(proveTargetOwnership(listOf(project(state = state), session()), projectID, conversationID))
            assertFalse(proveTargetOwnership(listOf(project(), session(state = state)), projectID, conversationID))
        }
        assertFalse(proveTargetOwnership(listOf(project(id = ""), session()), projectID, conversationID))
        assertFalse(proveTargetOwnership(listOf(project(), session(id = "")), projectID, conversationID))
    }

    @Test
    fun projectNameWithoutItsRegistryOwnerShapeIsNotProof() {
        for (owner in listOf("", "foreign", "a".repeat(63), "g".repeat(64))) {
            assertFalse(proveTargetOwnership(listOf(project(ownerID = owner), session()), projectID, conversationID))
        }
    }

    @Test
    fun ambiguousProjectBindingsRefuse() {
        assertFalse(proveTargetOwnership(
            listOf(project(), project(id = "c-2"), session()), projectID, conversationID,
        ))
    }
}
