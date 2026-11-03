// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.creative

import com.floe.android.feature.canvas.CreativeAvailability
import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.workbench.ui.state.MediaReturnEditorAction
import com.floe.android.feature.workbench.ui.state.MediaReturnOpenRequest
import com.floe.android.feature.workbench.ui.state.mediaReturnEditorAction
import com.floe.android.feature.workbench.ui.state.mediaReturnRequestIsValid
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Authored source-level tests for generation-notification return navigation.
 *
 * They pin the OPAQUE token / registered claim / captured context / live epoch
 * authorization policy, the one-shot rotation/re-delivery behaviour and the
 * existing-editor handoff policy. They use no Android/native/provider seam and
 * are NOT executed by this source-only stage; the integrated App batch owns
 * that run.
 */
class GenerationReturnNavigationTest {
    private val opaqueToken = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private val requestID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private val secondRequestID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    private val jobID = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    private val projectID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
    private val otherProjectID = "ffffffff-ffff-4fff-8fff-ffffffffffff"
    private val ownerID = "11111111-1111-4111-8111-111111111111"
    private val workspaceID = "22222222-2222-4222-8222-222222222222"

    @Before
    fun resetNavigation() {
        GenerationReturnNavigation.resetForTest()
    }

    private fun snapshot(
        token: String = opaqueToken,
        registered: Boolean = true,
        storage: CreativeStorageLayer? = CreativeStorageLayer.AppOwned,
        origin: CreativeOriginContext? = CreativeOriginContext.standalone(),
        startedAt: Long = 1_000L,
    ): GenerationReturnClaimSnapshot = GenerationReturnClaimSnapshot(
        token = token,
        jobID = jobID,
        epoch = 42L,
        projectID = projectID,
        registered = registered,
        storage = storage,
        origin = origin,
        startedAtElapsedMillis = startedAt,
    )

    private fun authorize(
        claim: GenerationReturnClaimSnapshot? = snapshot(),
        token: String? = opaqueToken,
        now: Long = 2_000L,
        liveEpoch: Long? = 42L,
        availability: CreativeAvailability = CreativeAvailability.Available,
    ): GenerationReturnDecision = authorizeGenerationReturn(
        requestToken = token,
        claim = claim,
        nowElapsedMillis = now,
        liveEpoch = liveEpoch,
        availability = availability,
    )

    private fun target(
        token: String = opaqueToken,
        project: String = projectID,
    ): GenerationReturnTarget = GenerationReturnTarget(
        token = token,
        jobID = jobID,
        epoch = 42L,
        projectID = project,
        storage = CreativeStorageLayer.AppOwned,
        origin = CreativeOriginContext.standalone(),
    )

    @Test
    fun `registered live claim with captured context authorizes the exact project`() {
        val decision = authorize()
        assertTrue(decision is GenerationReturnDecision.Authorized)
        val authorized = (decision as GenerationReturnDecision.Authorized).target
        assertEquals(opaqueToken, authorized.token)
        assertEquals(jobID, authorized.jobID)
        assertEquals(42L, authorized.epoch)
        assertEquals(projectID, authorized.projectID)
        assertEquals(CreativeStorageLayer.AppOwned, authorized.storage)
        assertEquals(CreativeOriginContext.standalone(), authorized.origin)
    }

    @Test
    fun `explicit workspace storage and real origin are preserved exactly`() {
        val storage = CreativeStorageLayer.Workspace(workspaceID)
        val origin = CreativeOriginContext(
            kind = CreativeOriginContext.WORKSPACE,
            ownerID = ownerID,
            environmentID = "env-1",
        )
        val decision = authorize(
            snapshot(storage = storage, origin = origin))
        assertTrue(decision is GenerationReturnDecision.Authorized)
        val authorized = (decision as GenerationReturnDecision.Authorized).target
        assertEquals(storage, authorized.storage)
        assertEquals(origin, authorized.origin)
    }

    @Test
    fun `unknown token never authorizes`() {
        val decision = authorize(claim = null)
        assertEquals(
            GenerationReturnRejection.UNKNOWN_TOKEN,
            (decision as GenerationReturnDecision.Rejected).reason,
        )
    }

    @Test
    fun `path shaped and non opaque tokens are rejected before lookup`() {
        for (value in listOf(
            null,
            "",
            "project",
            "/data/user/0/com.floe.android/files/x",
            "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
        )) {
            val decision = authorize(token = value)
            assertEquals(
                GenerationReturnRejection.INVALID_REQUEST,
                (decision as GenerationReturnDecision.Rejected).reason,
            )
        }
    }

    @Test
    fun `claim token mismatch is refused`() {
        val decision = authorize(
            claim = snapshot(token = secondRequestID))
        assertEquals(
            GenerationReturnRejection.TOKEN_MISMATCH,
            (decision as GenerationReturnDecision.Rejected).reason,
        )
    }

    @Test
    fun `service start claim without a native registered lease never navigates`() {
        val decision = authorize(snapshot(registered = false))
        assertEquals(
            GenerationReturnRejection.NOT_REGISTERED,
            (decision as GenerationReturnDecision.Rejected).reason,
        )
    }

    @Test
    fun `claim without captured storage context never navigates`() {
        val decision = authorize(snapshot(storage = null))
        assertEquals(
            GenerationReturnRejection.NO_CONTEXT,
            (decision as GenerationReturnDecision.Rejected).reason,
        )
    }

    @Test
    fun `expired claim is refused but the exact bound is still allowed`() {
        val ttl = GenerationReturnNavigation.CLAIM_TTL_MILLIS
        val expired = authorize(now = 1_000L + ttl + 1L)
        assertEquals(
            GenerationReturnRejection.EXPIRED,
            (expired as GenerationReturnDecision.Rejected).reason,
        )
        val atBound = authorize(now = 1_000L + ttl)
        assertTrue(atBound is GenerationReturnDecision.Authorized)
    }

    @Test
    fun `another or missing live epoch refuses the same project root`() {
        val wrong = authorize(liveEpoch = 41L)
        assertEquals(
            GenerationReturnRejection.EPOCH_MISMATCH,
            (wrong as GenerationReturnDecision.Rejected).reason,
        )
        val missing = authorize(liveEpoch = null)
        assertEquals(
            GenerationReturnRejection.EPOCH_MISMATCH,
            (missing as GenerationReturnDecision.Rejected).reason,
        )
        val nonPositive = authorize(liveEpoch = 0L)
        assertEquals(
            GenerationReturnRejection.EPOCH_MISMATCH,
            (nonPositive as GenerationReturnDecision.Rejected).reason,
        )
    }

    @Test
    fun `unavailable creative host refuses navigation`() {
        val decision = authorize(availability = CreativeAvailability.WaitingForRuntime)
        assertEquals(
            GenerationReturnRejection.HOST_UNAVAILABLE,
            (decision as GenerationReturnDecision.Rejected).reason,
        )
    }

    @Test
    fun `implicit storage and malformed origin are refused`() {
        val blankWorkspace = authorize(
            snapshot(storage = CreativeStorageLayer.Workspace("")))
        assertEquals(
            GenerationReturnRejection.NO_CONTEXT,
            (blankWorkspace as GenerationReturnDecision.Rejected).reason,
        )
        val badOrigin = authorize(
            snapshot(
                origin = CreativeOriginContext(
                    kind = CreativeOriginContext.WORKSPACE,
                    ownerID = "not-a-uuid",
                )))
        assertEquals(
            GenerationReturnRejection.INVALID_REQUEST,
            (badOrigin as GenerationReturnDecision.Rejected).reason,
        )
    }

    @Test
    fun `same intent re-delivery across rotation is one shot`() {
        assertTrue(GenerationReturnNavigation.submit(requestID, opaqueToken))
        // Activity recreation re-delivers the SAME PendingIntent request id.
        assertFalse(GenerationReturnNavigation.submit(requestID, opaqueToken))
        assertEquals(
            requestID,
            GenerationReturnNavigation.pending.value?.requestID,
        )
        assertTrue(GenerationReturnNavigation.approve(requestID, target()))
        assertTrue(GenerationReturnNavigation.consumeApproved(requestID))
        assertNull(GenerationReturnNavigation.approved.value)
        // A later rotation must not reopen the same request.
        assertFalse(GenerationReturnNavigation.submit(requestID, opaqueToken))
        assertNull(GenerationReturnNavigation.pending.value)
    }

    @Test
    fun `a new notification tap with a new request id may reopen the live project`() {
        assertTrue(GenerationReturnNavigation.submit(requestID, opaqueToken))
        assertTrue(GenerationReturnNavigation.approve(requestID, target()))
        assertTrue(GenerationReturnNavigation.consumeApproved(requestID))
        assertTrue(
            GenerationReturnNavigation.submit(secondRequestID, opaqueToken))
        assertEquals(
            secondRequestID,
            GenerationReturnNavigation.pending.value?.requestID,
        )
    }

    @Test
    fun `a newer tap clears an older approval that was not consumed`() {
        assertTrue(GenerationReturnNavigation.submit(requestID, opaqueToken))
        assertTrue(GenerationReturnNavigation.approve(requestID, target()))
        assertNotNull(GenerationReturnNavigation.approved.value)
        assertTrue(
            GenerationReturnNavigation.submit(secondRequestID, opaqueToken))
        assertNull(GenerationReturnNavigation.approved.value)
        assertEquals(
            secondRequestID,
            GenerationReturnNavigation.pending.value?.requestID,
        )
    }

    @Test
    fun `a refused fence dismissal can never publish an approval`() {
        assertTrue(GenerationReturnNavigation.submit(requestID, opaqueToken))
        assertTrue(GenerationReturnNavigation.dismiss(requestID))
        assertNull(GenerationReturnNavigation.pending.value)
        assertFalse(GenerationReturnNavigation.approve(requestID, target()))
        assertNull(GenerationReturnNavigation.approved.value)
        // The dismissed request id is spent; rotation cannot resurrect it.
        assertFalse(GenerationReturnNavigation.submit(requestID, opaqueToken))
    }

    @Test
    fun `approval must match the pending opaque token`() {
        assertTrue(GenerationReturnNavigation.submit(requestID, opaqueToken))
        assertFalse(
            GenerationReturnNavigation.approve(
                requestID, target(token = secondRequestID)),
        )
        assertNotNull(GenerationReturnNavigation.pending.value)
        assertNull(GenerationReturnNavigation.approved.value)
    }

    @Test
    fun `a newer tap supersedes an older unconsumed request`() {
        assertTrue(GenerationReturnNavigation.submit(requestID, opaqueToken))
        assertTrue(
            GenerationReturnNavigation.submit(secondRequestID, opaqueToken))
        assertEquals(
            secondRequestID,
            GenerationReturnNavigation.pending.value?.requestID,
        )
        // The older resolution can no longer publish/route.
        assertFalse(GenerationReturnNavigation.approve(requestID, target()))
        assertNull(GenerationReturnNavigation.approved.value)
        assertTrue(
            GenerationReturnNavigation.approve(
                secondRequestID, target(project = otherProjectID)))
        assertEquals(
            otherProjectID,
            GenerationReturnNavigation.approved.value?.target?.projectID,
        )
    }

    @Test
    fun `only our private action and same app component admit a return`() {
        assertFalse(
            GenerationReturnNavigation.submitFromIntent(
                action = "android.intent.action.MAIN",
                componentPackage = "com.floe.android",
                ownPackage = "com.floe.android",
                requestID = requestID,
                token = opaqueToken,
            ),
        )
        assertFalse(
            GenerationReturnNavigation.submitFromIntent(
                action = GenerationReturnNavigation.ACTION_RETURN,
                componentPackage = "com.example.other",
                ownPackage = "com.floe.android",
                requestID = requestID,
                token = opaqueToken,
            ),
        )
        assertFalse(
            GenerationReturnNavigation.submitFromIntent(
                action = GenerationReturnNavigation.ACTION_RETURN,
                componentPackage = null,
                ownPackage = "com.floe.android",
                requestID = requestID,
                token = opaqueToken,
            ),
        )
        assertFalse(
            GenerationReturnNavigation.submitFromIntent(
                action = GenerationReturnNavigation.ACTION_RETURN,
                componentPackage = "com.floe.android",
                ownPackage = "com.floe.android",
                requestID = requestID,
                token = "/data/user/0/com.floe.android/files/project",
            ),
        )
        assertTrue(
            GenerationReturnNavigation.submitFromIntent(
                action = GenerationReturnNavigation.ACTION_RETURN,
                componentPackage = "com.floe.android",
                ownPackage = "com.floe.android",
                requestID = requestID,
                token = opaqueToken,
            ),
        )
    }

    @Test
    fun `same editor context focuses and different project retires before reopen`() {
        val request = MediaReturnOpenRequest(
            requestID = requestID,
            sequence = 7L,
            projectID = projectID,
            expectedEpoch = 42L,
            storage = CreativeStorageLayer.AppOwned,
            origin = CreativeOriginContext.standalone(),
        )
        assertEquals(
            MediaReturnEditorAction.OPEN_NEW,
            mediaReturnEditorAction(null, null, null, request),
        )
        assertEquals(
            MediaReturnEditorAction.FOCUS_EXISTING,
            mediaReturnEditorAction(
                projectID,
                CreativeStorageLayer.AppOwned,
                CreativeOriginContext.standalone(),
                request,
            ),
        )
        assertEquals(
            MediaReturnEditorAction.REOPEN_AFTER_RETIRE,
            mediaReturnEditorAction(
                otherProjectID,
                CreativeStorageLayer.AppOwned,
                CreativeOriginContext.standalone(),
                request,
            ),
        )
        // Same id but a different explicit storage/origin is NOT the same
        // authority and must not silently keep the old editor.
        assertEquals(
            MediaReturnEditorAction.REOPEN_AFTER_RETIRE,
            mediaReturnEditorAction(
                projectID,
                CreativeStorageLayer.Workspace(workspaceID),
                CreativeOriginContext.standalone(),
                request,
            ),
        )
        assertEquals(
            MediaReturnEditorAction.REOPEN_AFTER_RETIRE,
            mediaReturnEditorAction(
                projectID,
                CreativeStorageLayer.AppOwned,
                CreativeOriginContext(
                    CreativeOriginContext.WORKSPACE, ownerID = ownerID),
                request,
            ),
        )
    }

    @Test
    fun `return open request bounds are validated`() {
        val request = MediaReturnOpenRequest(
            requestID = requestID,
            sequence = 1L,
            projectID = projectID,
            expectedEpoch = 42L,
            storage = CreativeStorageLayer.AppOwned,
            origin = null,
        )
        assertTrue(mediaReturnRequestIsValid(request))
        assertFalse(mediaReturnRequestIsValid(request.copy(requestID = "")))
        assertFalse(mediaReturnRequestIsValid(request.copy(sequence = 0L)))
        assertFalse(mediaReturnRequestIsValid(request.copy(projectID = " ")))
        assertFalse(mediaReturnRequestIsValid(request.copy(expectedEpoch = 0L)))
        assertFalse(
            mediaReturnRequestIsValid(
                request.copy(projectID = "p".repeat(129))),
        )
    }
    @Test
    fun `export notification uses the same one shot media return owner`() {
        assertTrue(GenerationReturnNavigation.submitExportFromIntent(
            com.floe.android.core.workbenchmedia.export.MediaExportReturns.ACTION,
            "app", "app", requestID, opaqueToken))
        assertEquals(GenerationReturnNavigation.Source.EXPORT, GenerationReturnNavigation.pending.value!!.source)
        assertFalse(GenerationReturnNavigation.submitExportFromIntent(
            com.floe.android.core.workbenchmedia.export.MediaExportReturns.ACTION,
            "app", "app", requestID, opaqueToken))
    }
    @Test
    fun `export action rejects a foreign component and path shaped identity`() {
        assertFalse(GenerationReturnNavigation.submitExportFromIntent(
            com.floe.android.core.workbenchmedia.export.MediaExportReturns.ACTION,
            "foreign", "app", requestID, opaqueToken))
        assertFalse(GenerationReturnNavigation.submitExportFromIntent(
            com.floe.android.core.workbenchmedia.export.MediaExportReturns.ACTION,
            "app", "app", requestID, "/files/project"))
        assertNull(GenerationReturnNavigation.pending.value)
    }
    @Test
    fun `new export tap supersedes unconsumed generation approval and shares ordering`() {
        assertTrue(GenerationReturnNavigation.submit(requestID, opaqueToken))
        assertTrue(GenerationReturnNavigation.approve(requestID, target()))
        val older = GenerationReturnNavigation.approved.value!!.sequence
        assertTrue(GenerationReturnNavigation.submitExportFromIntent(
            com.floe.android.core.workbenchmedia.export.MediaExportReturns.ACTION,
            "app", "app", secondRequestID, opaqueToken))
        assertNull(GenerationReturnNavigation.approved.value)
        assertTrue(GenerationReturnNavigation.approve(secondRequestID, target()))
        val newer = GenerationReturnNavigation.approved.value!!
        assertTrue(newer.sequence > older)
        assertEquals(GenerationReturnNavigation.Source.EXPORT, newer.targetSource)
    }
    @Test
    fun `new generation tap supersedes unconsumed export approval`() {
        assertTrue(GenerationReturnNavigation.submitExportFromIntent(
            com.floe.android.core.workbenchmedia.export.MediaExportReturns.ACTION,
            "app", "app", requestID, opaqueToken))
        assertTrue(GenerationReturnNavigation.approve(requestID, target()))
        assertTrue(GenerationReturnNavigation.submit(secondRequestID, opaqueToken))
        assertNull(GenerationReturnNavigation.approved.value)
        assertFalse(GenerationReturnNavigation.approve(requestID, target()))
        assertEquals(GenerationReturnNavigation.Source.GENERATION, GenerationReturnNavigation.pending.value!!.source)
    }
    @Test
    fun `unknown or cold process export refuses before feature navigation`() {
        assertEquals(GenerationReturnDecision.Rejected(GenerationReturnRejection.UNKNOWN_TOKEN),
            com.floe.android.host.notification.resolveExportReturn(opaqueToken, 42L, CreativeAvailability.Available))
    }

}
