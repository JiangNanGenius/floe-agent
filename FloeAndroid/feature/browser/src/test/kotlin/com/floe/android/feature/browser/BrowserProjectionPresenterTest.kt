// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.browser

import com.floe.android.feature.browser.api.BrowserProjectionSnapshot
import com.floe.android.feature.browser.api.BrowserTabRow
import com.floe.android.feature.browser.internal.BrowserProjectionPresenter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private const val TASK = "11111111-1111-1111-1111-111111111111"
private const val OTHER = "22222222-2222-2222-2222-222222222222"
private const val WORKSPACE = "33333333-3333-3333-3333-333333333333"
private const val RECEIPT = "44444444-4444-4444-4444-444444444444"

private fun snapshot(
    ownerTask: String = TASK,
    ownerWorkspace: String = WORKSPACE,
    ownerEpoch: Long = 7,
    visible: String? = TASK,
    presentationShow: Boolean? = null,
    presentationId: String? = null,
    handoffReceiptId: String? = null,
    handoffReturning: Boolean = false,
    handoffNeedsContinue: Boolean = false,
    returningControl: Boolean = false,
    surfaceKind: String = "ready",
    detail: String? = null,
    tabs: List<BrowserTabRow> = listOf(BrowserTabRow("t1", "https://example.com", "Example", true)),
    activeTabId: String? = "t1",
    userControls: Boolean = false,
    error: String? = null,
) = BrowserProjectionSnapshot(
    ownerTaskId = ownerTask,
    ownerWorkspaceId = ownerWorkspace,
    ownerRootEpoch = ownerEpoch,
    visibleTaskId = visible,
    presentationShow = presentationShow,
    presentationId = presentationId,
    handoffReceiptId = handoffReceiptId,
    handoffReturning = handoffReturning,
    handoffNeedsContinue = handoffNeedsContinue,
    handoffNotified = false,
    handoffError = error,
    returningControl = returningControl,
    surfaceStateKind = surfaceKind,
    surfaceStateDetail = detail,
    tabs = tabs,
    activeTabId = activeTabId,
    isUserControlling = userControls,
    addressText = tabs.firstOrNull()?.url ?: "",
    isEditingAddress = false,
    technicalAddress = tabs.firstOrNull()?.url,
    isDisplayingLocalPreview = false,
)

class BrowserProjectionPresenterTest {
    private fun presenter() = BrowserProjectionPresenter(TASK, WORKSPACE, 7)

    @Test
    fun exactOwnerBindingIsProjected() {
        val p = presenter()
        p.apply(snapshot())
        assertTrue(p.currentState().bound)
        assertEquals("t1", p.currentState().projection?.activeTabId)
    }

    @Test
    fun foreignOwnerTaskIsRefused() {
        val p = presenter()
        p.apply(snapshot(ownerTask = OTHER))
        assertFalse(p.currentState().bound)
        assertEquals(BrowserProjectionPresenter.UNBOUND_FOREIGN, p.currentState().unboundReason)
        assertNull(p.currentState().projection)
    }

    @Test
    fun staleRootEpochIsRefused() {
        val p = presenter()
        p.apply(snapshot(ownerEpoch = 6))
        assertFalse(p.currentState().bound)
        // A later, correct epoch rebinds.
        p.apply(snapshot(ownerEpoch = 7))
        assertTrue(p.currentState().bound)
    }

    @Test
    fun changedWorkspaceBindingIsRefused() {
        val p = presenter()
        p.apply(snapshot(ownerWorkspace = "99999999-9999-9999-9999-999999999999"))
        assertFalse(p.currentState().bound)
    }

    @Test
    fun otherTaskVisibilityMakesThisPanelInert() {
        val p = presenter()
        p.apply(snapshot(visible = OTHER))
        assertFalse(p.currentState().bound)
        assertEquals(BrowserProjectionPresenter.UNBOUND_OTHER_TASK, p.currentState().unboundReason)
    }

    @Test
    fun userControlCannotBeClearedLocallyByTabFacts() {
        // The takeover fence is projection-driven only: a load event within
        // the SAME projection (surfaceKind loading) keeps isUserControlling.
        val p = presenter()
        p.apply(snapshot(userControls = true, handoffReceiptId = RECEIPT, surfaceKind = "needsUser", detail = "User takeover is active"))
        assertTrue(p.controlBanner().userControls)
        assertEquals(RECEIPT, p.controlBanner().receiptId)
        p.apply(snapshot(userControls = true, handoffReceiptId = RECEIPT, surfaceKind = "loading", tabs = listOf(BrowserTabRow("t2", "https://other.test", "Other", true)), activeTabId = "t2"))
        // Even after tab churn, control is still the user's until the native
        // projection says otherwise:
        assertTrue(p.controlBanner().userControls)
        assertFalse(p.controlBanner().returning)
    }

    @Test
    fun continueButtonCarriesNativeReceiptOnlyWhenReceiptExists() {
        val p = presenter()
        p.apply(snapshot())
        assertNull(p.controlBanner().receiptId)
        p.apply(snapshot(handoffReceiptId = RECEIPT, handoffNeedsContinue = true))
        val banner = p.controlBanner()
        assertEquals(RECEIPT, banner.receiptId)
        assertTrue(banner.needsContinue)
    }

    @Test
    fun returningControlIsHonestUntilDelivery() {
        val p = presenter()
        p.apply(snapshot(handoffReceiptId = RECEIPT, returningControl = true))
        val banner = p.controlBanner()
        assertTrue(banner.returning)
        assertEquals(RECEIPT, banner.receiptId)
    }

    @Test
    fun panelAttentionRaisedExactlyOncePerPresentationId() {
        val p = presenter()
        p.apply(snapshot(presentationShow = true, presentationId = "req-1"))
        assertTrue(p.currentState().panelRequestsUserAttention)
        // A repeated identical request does not re-raise.
        p.apply(snapshot(presentationShow = true, presentationId = "req-1"))
        assertFalse(p.currentState().panelRequestsUserAttention)
        p.acknowledgeAttention()
        // A NEW presentation id raises again.
        p.apply(snapshot(presentationShow = true, presentationId = "req-2"))
        assertTrue(p.currentState().panelRequestsUserAttention)
        // hide requests never raise attention.
        p.apply(snapshot(presentationShow = false, presentationId = "req-3"))
        assertFalse(p.currentState().panelRequestsUserAttention)
    }

    @Test
    fun errorProjectionKeepsNativeDetailForHonestRendering() {
        val p = presenter()
        p.apply(snapshot(error = "delivery failed", handoffReceiptId = RECEIPT))
        assertEquals("delivery failed", p.controlBanner().errorMessage)
    }

    @Test
    fun listenersSeeEveryAcceptedProjectionInOrder() {
        val p = presenter()
        val seen = mutableListOf<String>()
        p.addListener { seen += it.projection?.surfaceStateKind ?: "-" }
        p.apply(snapshot(surfaceKind = "ready"))
        p.apply(snapshot(surfaceKind = "loading"))
        p.apply(snapshot(ownerEpoch = 1)) // refused, publishes unbound "-"
        assertEquals(listOf("ready", "loading", "-"), seen)
    }

    @Test
    fun tabsAreProjectionOwnedAndEmptyWhenUnbound() {
        val p = presenter()
        assertTrue(p.tabs().isEmpty())
        p.apply(snapshot(tabs = (1..6).map { BrowserTabRow("t$it", "https://e$it.test", "E$it", it == 1) }))
        assertEquals(6, p.tabs().size)
        p.unbind("gone")
        assertTrue(p.tabs().isEmpty())
    }
}
