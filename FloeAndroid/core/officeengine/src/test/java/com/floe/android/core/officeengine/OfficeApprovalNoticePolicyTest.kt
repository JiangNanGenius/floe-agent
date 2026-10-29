// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Regression for the approval-notice query SHAPE rules
 * ([OfficeApprovalNoticePolicy]) of the G05-R3 owned-Office viewer surface
 * (office-approval107, 2026-10-28; device evidence: c16
 * calc-close-context-refusal — a captured Ask-first approval was reachable
 * only by closing the owned document, which correctly retired the context
 * and refused the approval stale).
 *
 * The notice channel exists so the foreground viewer can ASK the parent
 * whether its OWNING conversation currently holds a captured pending
 * approval — read-only, fail-closed, same-UID, launch-Intent capability
 * (same trust model as OfficeCloseAck). These tests pin the pure shape
 * gate so a blank/oversized/control-char token, a non-positive incarnation
 * or a blank/oversized owner id can never reach the parent lookup, and the
 * valid boundary (the same 256-char token bound the close-ack uses) is
 * accepted exactly.
 *
 * Authored unrun: Main runs the batch compile/test gate.
 */
class OfficeApprovalNoticePolicyTest {

    private fun validToken(length: Int = 24) = "t".repeat(length)

    @Test
    fun validQueryAcceptedWithExactFields() {
        val query = OfficeApprovalNoticePolicy.validateShape(
            token = "session-token-1",
            incarnation = 7L,
            ownerTaskId = "convo-1059CCF8-43B8-44B7-AC31-0A21F42EC989",
        )
        assertNotNull(query)
        assertEquals("session-token-1", query!!.sessionToken)
        assertEquals(7L, query.viewerIncarnation)
        assertEquals("convo-1059CCF8-43B8-44B7-AC31-0A21F42EC989", query.ownerTaskId)
    }

    @Test
    fun blankTokenRejected() {
        assertNull(
            OfficeApprovalNoticePolicy.validateShape(token = "", incarnation = 1L, ownerTaskId = "task"),
        )
        assertNull(
            OfficeApprovalNoticePolicy.validateShape(token = null, incarnation = 1L, ownerTaskId = "task"),
        )
    }

    @Test
    fun oversizedTokenRejectedAtBoundary() {
        assertNotNull(
            OfficeApprovalNoticePolicy.validateShape(
                token = validToken(OfficeApprovalNoticePolicy.MAX_TOKEN_CHARS),
                incarnation = 1L,
                ownerTaskId = "task",
            ),
        )
        assertNull(
            OfficeApprovalNoticePolicy.validateShape(
                token = validToken(OfficeApprovalNoticePolicy.MAX_TOKEN_CHARS + 1),
                incarnation = 1L,
                ownerTaskId = "task",
            ),
        )
    }

    @Test
    fun controlCharactersRejectedInTokenAndOwner() {
        assertNull(
            OfficeApprovalNoticePolicy.validateShape(token = "a\u0000b", incarnation = 1L, ownerTaskId = "task"),
        )
        assertNull(
            OfficeApprovalNoticePolicy.validateShape(token = "tok", incarnation = 1L, ownerTaskId = "a\u007fb"),
        )
    }

    @Test
    fun nonPositiveIncarnationRejected() {
        assertNull(
            OfficeApprovalNoticePolicy.validateShape(token = "tok", incarnation = 0L, ownerTaskId = "task"),
        )
        assertNull(
            OfficeApprovalNoticePolicy.validateShape(token = "tok", incarnation = -3L, ownerTaskId = "task"),
        )
        assertNull(
            OfficeApprovalNoticePolicy.validateShape(token = "tok", incarnation = null, ownerTaskId = "task"),
        )
    }

    @Test
    fun blankOrOversizedOwnerRejected() {
        assertNull(
            OfficeApprovalNoticePolicy.validateShape(token = "tok", incarnation = 1L, ownerTaskId = ""),
        )
        assertNull(
            OfficeApprovalNoticePolicy.validateShape(token = "tok", incarnation = 1L, ownerTaskId = null),
        )
        assertNull(
            OfficeApprovalNoticePolicy.validateShape(
                token = "tok",
                incarnation = 1L,
                ownerTaskId = "o".repeat(OfficeApprovalNoticePolicy.MAX_OWNER_CHARS + 1),
            ),
        )
        assertNotNull(
            OfficeApprovalNoticePolicy.validateShape(
                token = "tok",
                incarnation = 1L,
                ownerTaskId = "o".repeat(OfficeApprovalNoticePolicy.MAX_OWNER_CHARS),
            ),
        )
    }
}
